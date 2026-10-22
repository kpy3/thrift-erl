%% Copyright 2026 Sergei Yelin
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(thrift_runtime_json).

-moduledoc """
The Apache Thrift JSON protocol: every value is a JSON document
whose shape carries the Thrift types. A message is the array
`[1,"name",type,seqid,payload]`; a struct is an object keyed by
field id where every value is a one-key object naming the type
(`"i32"`, `"str"`, `"rec"`, ...); a list or set is
`["i32",2,1,2]`, a map `["i32","i32",2,{"1":10}]`. Wire-compatible
with the vendored Apache `thrift_json_protocol` — the golden suite
runs the official JSON client against a JSON server of ours.

One deliberate bend to fit this codebase's pure-codec shape: the
envelope's closing `]` is folded into the TOP-LEVEL struct decode
(`decode/2` on a struct consumes one optional trailing `]`), and
`decode_message/1` returns the payload including it. Nested values
are never touched by this — a struct inside a list keeps the `]`
that closes the list — but it makes the payload self-contained: the
completeness probe of the buffered transport (an empty descriptor
over the message tail) accounts for every byte exactly, like it
does for the binary and compact protocols.

Struct keys of maps are limited to what a JSON object key can carry:
booleans, integers, doubles and strings. A map keyed by a struct,
list, set or map compiles to `{j_unsupported, ...}` and both encode
and decode refuse it (the reference implementation would produce
invalid JSON). `uuid` is likewise uncarryable. Doubles are written
with 16 fractional digits, mirroring the reference round-trip.

Descriptors compile once (see `thrift_runtime_binary`, the type
vocabulary is shared): inline `{struct, {Kind, Fields}}` descriptors
are memoized per process under exact equality, `{struct, {ref, M,
N}}` schemas resolve through `M:struct_info/1` into a
`persistent_term` cache. Generated types modules also probe their
specialized `json_codec/1` pair — the encode side everywhere, the
decode side carries the non-folding struct body and the bracket
fold is applied by whichever top-level entry calls it (`decode/2`,
never `decode_nested/2`). Decoding is
strict — declared fields whose type tag disagrees with the
descriptor are rejected, unknown fields are skipped by their wire
tag, required fields must be present, trailing bytes answer
`{error, trailing}`.
""".

-behaviour(thrift_runtime_protocol).

-export([
    encode/2,
    decode/2,
    decode_nested/2,
    encode_message/4,
    decode_message/1,
    encode_application_exception/2,
    decode_application_exception/1,
    skip_by_tag/2
]).

-export_type([j_type/0, j_struct/0, decode_result/1]).

-define(DOUBLE_PRECISION, 16).

-type base_type() :: thrift_runtime_binary:base_type().
-type enum_desc() :: thrift_runtime_binary:enum_desc().
-type type_desc() :: thrift_runtime_binary:type_desc().
-type struct_value() :: thrift_runtime_binary:struct_value().
-type message_type() :: thrift_runtime_binary:message_type().
-type decode_result(Value) :: thrift_runtime_binary:decode_result(Value).

%% Compiled type descriptors: shapes only, the JSON type tags are
%% derived on the fly by tag/1 (one small clause match on the hot path,
%% unlike compact where the nibble had to ride in the descriptor).
-type j_type() ::
    {j_base, base_type()}
    | {j_enum, enum_desc()}
    | {j_list, j_type()}
    | {j_set, j_type()}
    | {j_map, j_type(), j_type()}
    | {j_struct, j_struct()}
    | {j_ref, module(), binary()}
    %% A map whose key type no JSON object key can carry, or the uuid
    %% base: the original descriptor is kept for the error message.
    | {j_unsupported, type_desc()}.

-type j_struct() :: #{
    kind := struct | union | exception,
    fields := [{integer(), j_type(), binary()}],
    by_id := #{integer() => {j_type(), binary()}},
    required := #{integer() => binary()},
    required_names := [binary()]
}.

-doc "Encodes `Value` as `Type`, or fails with a tagged error.".
-spec encode(thrift_runtime_binary:type_desc(), term()) -> {ok, iodata()} | {error, term()}.
encode({struct, {ref, Module, Name}}, Value) ->
    encode_resolved(Module, Name, Value);
encode({struct, {Kind, Fields}}, Value) when is_atom(Kind), is_list(Fields) ->
    encode_struct_j(memo_compiled(Kind, Fields), Value);
encode(TypeDesc, Value) ->
    case compile_type(TypeDesc) of
        error ->
            {error, {encode, {bad_type, TypeDesc}}};
        Compiled ->
            encode_j(Compiled, Value)
    end.

-doc """
Decodes one value of `Type` from the front of `Binary`; the rest comes
back, `more` marks a valid but truncated input.

On a struct the optional closing `]` of a message envelope is consumed
after the struct proper (see the moduledoc).
""".
-spec decode(thrift_runtime_binary:type_desc(), binary()) -> decode_result(term()).
decode({struct, {ref, Module, Name}}, Bin) ->
    case json_codec(Module, Name) of
        {ok, CodecModule, _EncodeName, DecodeName} ->
            try
                %% The generated pair decodes the struct proper; the
                %% envelope's closing bracket folds here, exactly like
                %% decode_struct_top below.
                fold_bracket(CodecModule:DecodeName(Bin))
            catch
                error:undef:Stack ->
                    case erlang:function_exported(CodecModule, DecodeName, 1) of
                        true ->
                            erlang:raise(error, undef, Stack);
                        false ->
                            thrift_runtime_protocol:codec_stale(?MODULE, Module, Name),
                            decode_top_generic(Module, Name, Bin)
                    end
            end;
        error ->
            decode_top_generic(Module, Name, Bin)
    end;
decode({struct, {Kind, Fields}}, Bin) when is_atom(Kind), is_list(Fields) ->
    decode_struct_top(memo_compiled(Kind, Fields), Bin);
decode(TypeDesc, Bin) when is_binary(Bin) ->
    case compile_type(TypeDesc) of
        error ->
            {error, {decode, {bad_type, TypeDesc}}};
        Compiled ->
            decode_j(Compiled, Bin)
    end;
decode(_TypeDesc, _Bin) ->
    more.

-doc """
Non-folding struct decode for refs nested inside containers and struct
fields: probes the generated JSON codec pair and falls back to the
generic nested decode.

The envelope's closing `]` is NOT consumed — only the top-level
`decode/2` entry points fold it (see the moduledoc).
""".
-spec decode_nested(thrift_runtime_binary:type_desc(), binary()) -> decode_result(term()).
decode_nested({struct, {ref, Module, Name}}, Bin) ->
    case json_codec(Module, Name) of
        {ok, CodecModule, _EncodeName, DecodeName} ->
            try
                CodecModule:DecodeName(Bin)
            catch
                error:undef:Stack ->
                    case erlang:function_exported(CodecModule, DecodeName, 1) of
                        true ->
                            erlang:raise(error, undef, Stack);
                        false ->
                            thrift_runtime_protocol:codec_stale(?MODULE, Module, Name),
                            decode_nested_generic(Module, Name, Bin)
                    end
            end;
        error ->
            decode_nested_generic(Module, Name, Bin)
    end.

-spec decode_top_generic(module(), binary(), binary()) -> decode_result(term()).
decode_top_generic(Module, Name, Bin) ->
    case resolve_compiled(Module, Name) of
        {ok, Compiled} ->
            decode_struct_top(Compiled, Bin);
        {error, _} = Error ->
            Error
    end.

-spec decode_nested_generic(module(), binary(), binary()) -> decode_result(term()).
decode_nested_generic(Module, Name, Bin) ->
    case resolve_compiled(Module, Name) of
        {ok, Compiled} ->
            decode_struct_j(Compiled, Bin);
        {error, _} = Error ->
            Error
    end.

-doc """
Encodes a message envelope around `Payload` (already encoded as a
struct): the JSON array `[1,"name",type,seqid,payload]`. The closing
bracket is written here and consumed by the payload's top-level
struct decode on the way back.
""".
-spec encode_message(thrift_runtime_binary:message_type(), binary(), non_neg_integer(), iodata()) ->
    iodata().
encode_message(Type, Name, SeqId, Payload) ->
    [
        <<"[1,\"">>,
        escape(Name),
        <<"\",">>,
        integer_to_binary(thrift_runtime_protocol:message_type_id(Type)),
        <<",">>,
        integer_to_binary(SeqId),
        <<",">>,
        Payload,
        <<"]">>
    ].

-doc """
Decodes a message envelope.

Returns `{ok, Type, Name, SeqId, Payload}` where `Payload` spans the
struct object plus the envelope's closing `]` — exactly the bytes the
strict struct decode consumes — then `more` for a truncated envelope
or a tagged error otherwise.
""".
-spec decode_message(binary()) ->
    {ok, thrift_runtime_binary:message_type(), binary(), non_neg_integer(), binary()}
    | more
    | {error, term()}.
decode_message(Bin) ->
    maybe
        {ok, Rest0} ?= expect_char(Bin, $[),
        {ok, Version, Rest1} ?= scan_number(Rest0),
        ok ?= check_version(Version),
        {ok, Rest2} ?= expect_char(Rest1, $,),
        {ok, Name, Rest3} ?= scan_string(Rest2),
        {ok, Rest4} ?= expect_char(Rest3, $,),
        {ok, TypeNum, Rest5} ?= scan_number(Rest4),
        {ok, Type} ?= message_type(TypeNum),
        {ok, Rest6} ?= expect_char(Rest5, $,),
        {ok, SeqIdNum, Rest7} ?= scan_number(Rest6),
        ok ?= check_seqid(SeqIdNum),
        SeqId = int_of(SeqIdNum),
        {ok, Rest8} ?= expect_char(Rest7, $,),
        {ok, Rest9} ?= skip_by_tag(<<"rec">>, Rest8),
        {ok, Rest10} ?= expect_char(Rest9, $]),
        PayloadStart = byte_size(Bin) - byte_size(Rest8),
        PayloadLength = byte_size(Bin) - byte_size(Rest10) - PayloadStart,
        {ok, Type, Name, SeqId, binary:part(Bin, PayloadStart, PayloadLength)}
    else
        more ->
            more;
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Encodes `TApplicationException` as an EXCEPTION message payload
(a struct object; the envelope writes the bracket).
""".
-spec encode_application_exception(binary(), non_neg_integer()) ->
    {ok, iodata()} | {error, term()}.
encode_application_exception(Message, Code) ->
    thrift_runtime_protocol:encode_application_exception(?MODULE, Message, Code).

-doc "Decodes `TApplicationException` from an EXCEPTION message payload.".
-spec decode_application_exception(binary()) -> decode_result(thrift_runtime_binary:application_exception()).
decode_application_exception(Bin) ->
    thrift_runtime_protocol:decode_application_exception(?MODULE, Bin).

%%--------------------------------------------------------------------
%% Compiled descriptor encoding
%%--------------------------------------------------------------------

-spec encode_j(j_type(), term()) -> {ok, iodata()} | {error, term()}.
encode_j({j_base, bool}, true) ->
    {ok, <<"true">>};
encode_j({j_base, bool}, false) ->
    {ok, <<"false">>};
encode_j({j_base, B}, V) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    encode_int(B, V);
encode_j({j_base, double}, V) when is_number(V) ->
    {ok, format_double(V)};
encode_j({j_base, S}, V) when S =:= string; S =:= binary ->
    case is_binary(V) of
        true -> {ok, [$", escape(V), $"]};
        false -> {error, {encode, {value_does_not_match_type, V}}}
    end;
encode_j({j_enum, Desc}, V) ->
    case thrift_runtime_protocol:enum_to_int(Desc, V) of
        {ok, Int} -> {ok, integer_to_binary(Int)};
        error -> {error, {encode, {unknown_enum_value, V}}}
    end;
encode_j({Coll, CElem}, Values) when (Coll =:= j_list orelse Coll =:= j_set), is_list(Values) ->
    %% list and set share the wire shape: a type-tagged, sized array
    case encode_elements_j(CElem, Values) of
        {ok, ElementIo} ->
            %% An empty array is ["i32",0] - no comma after the size.
            SizeSep =
                case ElementIo of
                    [] -> [];
                    _ -> <<",">>
                end,
            {ok, [
                [<<"[\"">>, tag(CElem), <<"\",">>, integer_to_binary(length(Values)), SizeSep],
                lists:join(<<",">>, ElementIo),
                <<"]">>
            ]};
        {error, _} = Error ->
            Error
    end;
encode_j({j_map, CKey, CVal}, Value) when is_map(Value) ->
    encode_map_j(CKey, CVal, Value);
encode_j({j_struct, Compiled}, Value) when is_map(Value) ->
    encode_struct_j(Compiled, Value);
encode_j({j_ref, Module, Name}, Value) when is_map(Value) ->
    encode_resolved(Module, Name, Value);
encode_j({j_unsupported, Desc}, _Value) ->
    {error, {encode, {type_not_supported, Desc, json}}};
encode_j(_Compiled, Value) ->
    {error, {encode, {value_does_not_match_type, Value}}}.

%% The range-checked integer literal, shared by value and map-key
%% encoding.
-spec encode_int(base_type(), term()) -> {ok, iodata()} | {error, term()}.
encode_int(B, V) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    case in_range(B, V) of
        true -> {ok, integer_to_binary(V)};
        false -> {error, {encode, {value_does_not_match_type, V}}}
    end.

-spec encode_elements_j(j_type(), [term()]) -> {ok, iodata()} | {error, term()}.
encode_elements_j(_CElem, []) ->
    {ok, []};
encode_elements_j(CElem, [V | Rest]) ->
    case encode_j(CElem, V) of
        {ok, Encoded} ->
            case encode_elements_j(CElem, Rest) of
                {ok, RestIo} -> {ok, [Encoded | RestIo]};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec encode_map_j(j_type(), j_type(), map()) -> {ok, iodata()} | {error, term()}.
encode_map_j(CKey, CVal, Value) ->
    case encoded_pairs_j(CKey, CVal, maps:to_list(Value), []) of
        {ok, Pairs} ->
            %% Object keys must be unique, so pairs are sorted by their
            %% encoded key text and collisions are refused.
            Sorted = lists:sort(fun({A, _}, {B, _}) -> A =< B end, Pairs),
            case has_duplicate_keys(Sorted) of
                false ->
                    {ok, [
                        [
                            <<"[\"">>,
                            tag(CKey),
                            <<"\",\"">>,
                            tag(CVal),
                            <<"\",">>,
                            integer_to_binary(length(Sorted)),
                            <<",{">>
                        ],
                        lists:join(<<",">>, [Chunk || {_, Chunk} <- Sorted]),
                        <<"}]">>
                    ]};
                true ->
                    {error, {encode, duplicate_json_keys}}
            end;
        {error, _} = Error ->
            Error
    end.

-spec encoded_pairs_j(j_type(), j_type(), [{term(), term()}], [{binary(), iodata()}]) ->
    {ok, [{binary(), iodata()}]} | {error, term()}.
encoded_pairs_j(_CKey, _CVal, [], Acc) ->
    {ok, lists:reverse(Acc)};
encoded_pairs_j(CKey, CVal, [{K, V} | Rest], Acc) ->
    maybe
        {ok, KeyText} ?= encode_key_text(CKey, K),
        {ok, ValIo} ?= encode_j(CVal, V),
        Chunk = [[$", escape(KeyText), $"], $:, ValIo],
        encoded_pairs_j(CKey, CVal, Rest, [{KeyText, Chunk} | Acc])
    else
        {error, Reason} ->
            {error, Reason}
    end.

%% The text a map key of the given type leaves in a JSON object key:
%% strings as themselves, numbers and booleans in their literal form.
-spec encode_key_text(j_type(), term()) -> {ok, binary()} | {error, term()}.
encode_key_text({j_base, S}, V) when S =:= string; S =:= binary ->
    case is_binary(V) of
        true -> {ok, V};
        false -> {error, {encode, {value_does_not_match_type, V}}}
    end;
encode_key_text({j_base, bool}, true) ->
    {ok, <<"true">>};
encode_key_text({j_base, bool}, false) ->
    {ok, <<"false">>};
encode_key_text({j_base, double}, V) when is_number(V) ->
    {ok, iolist_to_binary(format_double(V))};
encode_key_text({j_base, B}, V) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    encode_int(B, V);
encode_key_text({j_enum, Desc}, V) ->
    case thrift_runtime_protocol:enum_to_int(Desc, V) of
        {ok, Int} -> {ok, integer_to_binary(Int)};
        error -> {error, {encode, {unknown_enum_value, V}}}
    end;
encode_key_text({j_unsupported, Desc}, _V) ->
    {error, {encode, {type_not_supported, Desc, json}}};
encode_key_text(_CKey, V) ->
    {error, {encode, {value_does_not_match_type, V}}}.

-spec has_duplicate_keys([{binary(), term()}]) -> boolean().
has_duplicate_keys([{K, _}, {K, _} | _]) ->
    true;
has_duplicate_keys([_ | Rest]) ->
    has_duplicate_keys(Rest);
has_duplicate_keys([]) ->
    false.

-spec format_double(number()) -> string().
format_double(V) ->
    %% The reference writes doubles with 16 fractional digits; the
    %% same round-trip through binary_to_float is exact.
    io_lib:format("~.*f", [?DOUBLE_PRECISION, float(V)]).

%%--------------------------------------------------------------------
%% Structs
%%--------------------------------------------------------------------

-spec encode_struct_j(j_struct(), struct_value()) -> {ok, iodata()} | {error, term()}.
encode_struct_j(#{kind := Kind, fields := Fields, required_names := ReqNames}, Map) ->
    case check_present_fields(Kind, ReqNames, Fields, Map) of
        ok ->
            case present_field_chunks(Fields, Map, []) of
                {ok, Chunks} ->
                    {ok, [<<"{">>, lists:join(<<",">>, Chunks), <<"}">>]};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Present declared fields in declaration order; every field is the
%% `"id":{"tag":value}` object.
-spec present_field_chunks([{integer(), j_type(), binary()}], struct_value(), [iodata()]) ->
    {ok, [iodata()]} | {error, term()}.
present_field_chunks([], _Map, Acc) ->
    {ok, lists:reverse(Acc)};
present_field_chunks([{Id, CJType, Name} | Rest], Map, Acc) ->
    case Map of
        #{Name := Value} ->
            case encode_j(CJType, Value) of
                {ok, ValIo} ->
                    Chunk = [
                        [$", integer_to_binary(Id), $", $:],
                        <<"{\"">>,
                        tag(CJType),
                        <<"\":">>,
                        ValIo,
                        <<"}">>
                    ],
                    present_field_chunks(Rest, Map, [Chunk | Acc]);
                {error, _} = Error ->
                    Error
            end;
        _ ->
            present_field_chunks(Rest, Map, Acc)
    end.

-spec check_present_fields(
    struct | union | exception, [binary()], [{integer(), j_type(), binary()}], struct_value()
) ->
    ok | {error, term()}.
check_present_fields(Kind, ReqNames, Fields, Map) ->
    thrift_runtime_protocol:check_present_fields(
        Kind, ReqNames, Fields, Map, fun({_Id, _CJType, Name}) -> Name end
    ).

%% The top-level struct decode folds the envelope's closing bracket
%% (see the moduledoc); nested struct decodes never see one.
-spec decode_struct_top(j_struct(), binary()) -> decode_result(struct_value()).
decode_struct_top(Compiled, Bin) ->
    fold_bracket(decode_struct_j(Compiled, Bin)).

-spec fold_bracket(decode_result(struct_value())) -> decode_result(struct_value()).
fold_bracket({ok, Map, <<"]", Rest/binary>>}) ->
    {ok, Map, Rest};
fold_bracket(Other) ->
    Other.

-spec decode_struct_j(j_struct(), binary()) -> decode_result(struct_value()).
decode_struct_j(#{by_id := ById, required := Required}, Bin) ->
    case expect_char(Bin, ${) of
        {ok, Rest} ->
            decode_struct_fields_j(ById, Required, Rest, #{});
        Other ->
            Other
    end.

-spec decode_struct_fields_j(
    #{integer() => {j_type(), binary()}}, #{integer() => binary()}, binary(), struct_value()
) ->
    decode_result(struct_value()).
decode_struct_fields_j(ById, Required, Bin, Acc) ->
    case skip_ws(Bin) of
        <<"}", Rest/binary>> ->
            struct_fields_done(Required, Acc, Rest);
        <<>> ->
            more;
        Rest0 ->
            case decode_struct_field_j(ById, Required, Rest0, Acc) of
                {ok, Acc1, Required1, Rest1} ->
                    after_struct_field_j(ById, Required1, Rest1, Acc1);
                Other ->
                    Other
            end
    end.

-spec after_struct_field_j(
    #{integer() => {j_type(), binary()}}, #{integer() => binary()}, binary(), struct_value()
) ->
    decode_result(struct_value()).
after_struct_field_j(ById, Required, Bin, Acc) ->
    case skip_ws(Bin) of
        <<",", Rest/binary>> ->
            decode_struct_fields_j(ById, Required, Rest, Acc);
        <<"}", Rest/binary>> ->
            struct_fields_done(Required, Acc, Rest);
        <<>> ->
            more;
        _ ->
            {error, {decode, bad_structure}}
    end.

%% The struct object closed: every still-registered required field is
%% missing.
-spec struct_fields_done(#{integer() => binary()}, struct_value(), binary()) ->
    {ok, struct_value(), binary()} | {error, term()}.
struct_fields_done(Required, Acc, Rest) ->
    case maps:values(Required) of
        [] -> {ok, Acc, Rest};
        Missing -> {error, {decode, {missing_required_fields, Missing}}}
    end.

%% One `"id":{"tag":value}` entry: declared fields check the tag
%% against the descriptor, unknown ids skip by the wire tag.
-spec decode_struct_field_j(
    #{integer() => {j_type(), binary()}}, #{integer() => binary()}, binary(), struct_value()
) ->
    {ok, struct_value(), #{integer() => binary()}, binary()} | more | {error, term()}.
decode_struct_field_j(ById, Required, Bin, Acc) ->
    maybe
        {ok, IdText, Rest0} ?= scan_string(Bin),
        {ok, Id} ?= field_id(IdText),
        {ok, Rest1} ?= expect_char(Rest0, $:),
        {ok, Rest2} ?= expect_char(Rest1, ${),
        {ok, Tag, Rest3} ?= scan_string(Rest2),
        {ok, Rest4} ?= expect_char(Rest3, $:),
        {ok, Value, Rest5, Required1} ?= field_value_j(ById, Required, Id, Tag, Rest4),
        {ok, Rest6} ?= expect_char(Rest5, $}),
        Name = element(2, maps:get(Id, ById, {undefined, undefined})),
        {ok, maybe_put(Name, Value, Acc), Required1, Rest6}
    else
        more ->
            more;
        {error, Reason} ->
            {error, Reason}
    end.

-spec field_value_j(
    #{integer() => {j_type(), binary()}},
    #{integer() => binary()},
    integer(),
    binary(),
    binary()
) ->
    {ok, term(), binary(), #{integer() => binary()}} | more | {error, term()}.
field_value_j(ById, Required, Id, Tag, Bin) ->
    case ById of
        #{Id := {CJType, _Name}} ->
            case tag(CJType) =:= Tag of
                true ->
                    case decode_j(CJType, Bin) of
                        {ok, Value, Rest} ->
                            {ok, Value, Rest, thrift_runtime_protocol:mark_present(Required, Id)};
                        Other ->
                            Other
                    end;
                false ->
                    {error, {decode, {field_type_mismatch, Id}}}
            end;
        _ ->
            case skip_by_tag(Tag, Bin) of
                {ok, Rest} -> {ok, undefined, Rest, Required};
                Other -> Other
            end
    end.

-spec field_id(binary()) -> {ok, integer()} | {error, term()}.
field_id(Text) ->
    try
        {ok, binary_to_integer(Text)}
    catch
        _:_ -> {error, {decode, bad_field_id}}
    end.

-spec maybe_put(binary() | undefined, term(), struct_value()) -> struct_value().
maybe_put(undefined, _Value, Acc) ->
    Acc;
maybe_put(Name, Value, Acc) ->
    Acc#{Name => Value}.

%%--------------------------------------------------------------------
%% Containers
%%--------------------------------------------------------------------

-spec decode_j(j_type(), binary()) -> decode_result(term()).
decode_j({j_base, bool}, Bin) ->
    case skip_ws(Bin) of
        <<"true", Rest/binary>> -> {ok, true, Rest};
        <<"false", Rest/binary>> -> {ok, false, Rest};
        <<>> -> more;
        _ -> {error, {decode, {bad_value_for_base_type, bool}}}
    end;
decode_j({j_base, B}, Bin) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    case scan_number(Bin) of
        {ok, {int, V}, Rest} -> {ok, V, Rest};
        {ok, {float, _}, _} -> {error, {decode, {bad_value_for_base_type, B}}};
        Other -> Other
    end;
decode_j({j_base, double}, Bin) ->
    case scan_number(Bin) of
        {ok, {float, V}, Rest} -> {ok, V, Rest};
        {ok, {int, V}, Rest} -> {ok, float(V), Rest};
        Other -> Other
    end;
decode_j({j_base, S}, Bin) when S =:= string; S =:= binary ->
    scan_string(Bin);
decode_j({j_enum, Desc}, Bin) ->
    case scan_number(Bin) of
        {ok, {int, Int}, Rest} ->
            case thrift_runtime_protocol:enum_from_int(Desc, Int) of
                {ok, Atom} -> {ok, Atom, Rest};
                error -> {ok, Int, Rest}
            end;
        Other ->
            Other
    end;
decode_j({Coll, CElem}, Bin) when Coll =:= j_list; Coll =:= j_set ->
    decode_sequence_j(CElem, Bin);
decode_j({j_map, CKey, CVal}, Bin) ->
    decode_map_j(CKey, CVal, Bin);
decode_j({j_struct, Compiled}, Bin) ->
    decode_struct_j(Compiled, Bin);
decode_j({j_ref, Module, Name}, Bin) ->
    case resolve_compiled(Module, Name) of
        {ok, Compiled} ->
            %% Nested: no bracket fold here, only the top-level struct
            %% decode consumes the envelope's `]`.
            decode_struct_j(Compiled, Bin);
        {error, _} = Error ->
            Error
    end;
decode_j({j_unsupported, Desc}, _Bin) ->
    {error, {decode, {type_not_supported, Desc, json}}};
decode_j(_Compiled, _Bin) ->
    {error, {decode, bad_value}}.

-spec decode_sequence_j(j_type(), binary()) -> decode_result([term()]).
decode_sequence_j(CElem, Bin) ->
    maybe
        {ok, Rest0} ?= expect_char(Bin, $[),
        {ok, Tag, Rest1} ?= scan_string(Rest0),
        ok ?= check_tag(Tag, CElem),
        {ok, Rest2} ?= expect_char(Rest1, $,),
        {ok, Size, Rest3} ?= scan_number(Rest2),
        ok ?= check_size(Size),
        {ok, Rest4} ?= comma_unless_empty(size_of(Size), Rest3),
        {ok, Elements, Rest5} ?= decode_elements_j(CElem, size_of(Size), Rest4, []),
        {ok, Elements, Rest5}
    else
        more ->
            more;
        {error, Reason} ->
            {error, Reason}
    end.

%% A non-empty list writes a comma between the size and the elements;
%% an empty one closes right after the size.
-spec comma_unless_empty(non_neg_integer(), binary()) -> {ok, binary()} | more | {error, term()}.
comma_unless_empty(0, Bin) ->
    {ok, Bin};
comma_unless_empty(_N, Bin) ->
    expect_char(Bin, $,).

-spec decode_elements_j(j_type(), non_neg_integer(), binary(), [term()]) ->
    decode_result([term()]).
%% The last element consumes the closing bracket itself.
decode_elements_j(_CElem, 0, Bin, Acc) ->
    case expect_char(Bin, $]) of
        {ok, Rest} -> {ok, lists:reverse(Acc), Rest};
        Other -> Other
    end;
decode_elements_j(CElem, 1, Bin, Acc) ->
    case decode_j(CElem, Bin) of
        {ok, Value, Rest} ->
            case expect_char(Rest, $]) of
                {ok, Rest1} -> {ok, lists:reverse([Value | Acc]), Rest1};
                Other -> Other
            end;
        Other ->
            Other
    end;
decode_elements_j(CElem, N, Bin, Acc) when N > 1 ->
    case decode_j(CElem, Bin) of
        {ok, Value, Rest0} ->
            case expect_char(Rest0, $,) of
                {ok, Rest1} -> decode_elements_j(CElem, N - 1, Rest1, [Value | Acc]);
                Other -> Other
            end;
        Other ->
            Other
    end.

-spec decode_map_j(j_type(), j_type(), binary()) -> decode_result(map()).
decode_map_j(CKey, CVal, Bin) ->
    maybe
        {ok, Rest0} ?= expect_char(Bin, $[),
        {ok, KeyTag, Rest1} ?= scan_string(Rest0),
        ok ?= check_tag(KeyTag, CKey),
        {ok, Rest2} ?= expect_char(Rest1, $,),
        {ok, ValTag, Rest3} ?= scan_string(Rest2),
        ok ?= check_tag(ValTag, CVal),
        {ok, Rest4} ?= expect_char(Rest3, $,),
        {ok, Size, Rest5} ?= scan_number(Rest4),
        ok ?= check_size(Size),
        {ok, Rest6} ?= expect_char(Rest5, $,),
        {ok, Rest7} ?= expect_char(Rest6, ${),
        {ok, Pairs, Rest8} ?= decode_pairs_j(CKey, CVal, size_of(Size), Rest7, #{}),
        {ok, Rest9} ?= expect_char(Rest8, $]),
        {ok, Pairs, Rest9}
    else
        more ->
            more;
        {error, Reason} ->
            {error, Reason}
    end.

-spec decode_pairs_j(j_type(), j_type(), non_neg_integer(), binary(), map()) ->
    decode_result(map()).
%% Object keys arrive as JSON strings; their text is the encoded form
%% of the key value. The last pair (or the empty object's brace)
%% consumes the closing bracket.
decode_pairs_j(_CKey, _CVal, 0, Bin, Acc) ->
    case expect_char(Bin, $}) of
        {ok, Rest} -> {ok, Acc, Rest};
        Other -> Other
    end;
decode_pairs_j(CKey, CVal, 1, Bin, Acc) ->
    case scan_string(Bin) of
        {ok, KeyText, Rest0} ->
            case decode_pair_j(CKey, CVal, KeyText, Rest0) of
                {ok, Key, Value, Rest1} ->
                    case expect_char(Rest1, $}) of
                        {ok, Rest2} -> {ok, Acc#{Key => Value}, Rest2};
                        Other -> Other
                    end;
                Other ->
                    Other
            end;
        Other ->
            Other
    end;
decode_pairs_j(CKey, CVal, N, Bin, Acc) when N > 1 ->
    case scan_string(Bin) of
        {ok, KeyText, Rest0} ->
            case decode_pair_j(CKey, CVal, KeyText, Rest0) of
                {ok, Key, Value, Rest1} ->
                    case expect_char(Rest1, $,) of
                        {ok, Rest2} -> decode_pairs_j(CKey, CVal, N - 1, Rest2, Acc#{Key => Value});
                        Other -> Other
                    end;
                Other ->
                    Other
            end;
        Other ->
            Other
    end.

-spec decode_pair_j(j_type(), j_type(), binary(), binary()) ->
    {ok, term(), term(), binary()} | more | {error, term()}.
decode_pair_j(CKey, CVal, KeyText, Bin) ->
    case expect_char(Bin, $:) of
        {ok, Rest0} ->
            case decode_j(CVal, Rest0) of
                {ok, Value, Rest1} ->
                    case key_from_text(CKey, KeyText) of
                        {ok, Key} -> {ok, Key, Value, Rest1};
                        {error, _} = Error -> Error
                    end;
                Other ->
                    Other
            end;
        Other ->
            Other
    end.

-spec key_from_text(j_type(), binary()) -> {ok, term()} | {error, term()}.
key_from_text({j_base, S}, Text) when S =:= string; S =:= binary ->
    {ok, Text};
key_from_text({j_base, bool}, <<"true">>) ->
    {ok, true};
key_from_text({j_base, bool}, <<"false">>) ->
    {ok, false};
key_from_text({j_base, bool}, _) ->
    {error, {decode, bad_map_key}};
key_from_text({j_base, double}, Text) ->
    try
        {ok, binary_to_float(Text)}
    catch
        _:_ -> double_key_from_int(Text)
    end;
key_from_text({j_base, _B}, Text) ->
    try
        {ok, binary_to_integer(Text)}
    catch
        _:_ -> {error, {decode, bad_map_key}}
    end;
key_from_text({j_enum, Desc}, Text) ->
    try
        Int = binary_to_integer(Text),
        case thrift_runtime_protocol:enum_from_int(Desc, Int) of
            {ok, Atom} -> {ok, Atom};
            error -> {ok, Int}
        end
    catch
        _:_ -> {error, {decode, bad_map_key}}
    end;
key_from_text({j_unsupported, Desc}, _Text) ->
    {error, {decode, {type_not_supported, Desc, json}}};
key_from_text(_CKey, _Text) ->
    {error, {decode, bad_map_key}}.

%% An integer literal is also a valid double map key.
-spec double_key_from_int(binary()) -> {ok, float()} | {error, term()}.
double_key_from_int(Text) ->
    try
        {ok, float(binary_to_integer(Text))}
    catch
        _:_ -> {error, {decode, bad_map_key}}
    end.

-spec check_tag(binary(), j_type()) -> ok | {error, term()}.
check_tag(Tag, CJType) ->
    case Tag =:= tag(CJType) of
        true -> ok;
        false -> {error, {decode, {element_type_mismatch, Tag}}}
    end.

-spec check_size({int, term()} | {float, term()}) -> ok | {error, term()}.
check_size({int, Size}) when is_integer(Size), Size >= 0 ->
    ok;
check_size(_) ->
    {error, {decode, bad_sequence_size}}.

-spec size_of({int, integer()}) -> non_neg_integer().
size_of({int, Size}) ->
    Size.

-spec int_of({int, integer()}) -> integer().
int_of({int, V}) ->
    V.

-spec check_version({int, term()} | {float, term()}) -> ok | {error, term()}.
check_version({int, 1}) ->
    ok;
check_version({int, Version}) ->
    {error, {decode, {bad_version, Version}}};
check_version(_) ->
    {error, {decode, bad_version}}.

-spec check_seqid({int, term()} | {float, term()}) -> ok | {error, term()}.
check_seqid({int, SeqId}) when is_integer(SeqId), SeqId >= 0 ->
    ok;
check_seqid(_) ->
    {error, {decode, bad_seqid}}.

-spec message_type({int, term()} | {float, term()}) -> {ok, message_type()} | {error, term()}.
message_type({int, 1}) ->
    {ok, call};
message_type({int, 2}) ->
    {ok, reply};
message_type({int, 3}) ->
    {ok, exception};
message_type({int, 4}) ->
    {ok, oneway};
message_type({int, Num}) ->
    {error, {decode, {unknown_message_type, Num}}};
message_type(_) ->
    {error, {decode, bad_envelope}}.

%%--------------------------------------------------------------------
%% Skipping unknown values by wire tag
%%--------------------------------------------------------------------

-doc """
Skips one JSON value of wire tag `Tag` (e.g. `<<"i32">>`, `<<"lst">>`)
at the front of `Binary`; the rest comes back, `more` marks a valid but
truncated input. Exported for generated JSON codecs: their decode loops
skip unknown struct fields through this function, keeping
skip-on-unknown-field semantics in one place.
""".
-spec skip_by_tag(binary(), binary()) -> {ok, binary()} | more | {error, term()}.
skip_by_tag(<<"tf">>, Bin) ->
    case skip_ws(Bin) of
        <<"true", Rest/binary>> -> {ok, Rest};
        <<"false", Rest/binary>> -> {ok, Rest};
        <<>> -> more;
        _ -> {error, {decode, bad_structure}}
    end;
skip_by_tag(Tag, Bin) when
    Tag =:= <<"dbl">>;
    Tag =:= <<"i8">>;
    Tag =:= <<"i16">>;
    Tag =:= <<"i32">>;
    Tag =:= <<"i64">>
->
    case scan_number(Bin) of
        {ok, _, Rest} -> {ok, Rest};
        Other -> Other
    end;
skip_by_tag(<<"str">>, Bin) ->
    case scan_string(Bin) of
        {ok, _, Rest} -> {ok, Rest};
        Other -> Other
    end;
skip_by_tag(<<"rec">>, Bin) ->
    skip_struct(Bin);
skip_by_tag(Tag, Bin) when Tag =:= <<"lst">>; Tag =:= <<"set">> ->
    maybe
        {ok, Rest0} ?= expect_char(Bin, $[),
        {ok, ElemTag, Rest1} ?= scan_string(Rest0),
        {ok, Rest2} ?= expect_char(Rest1, $,),
        {ok, Size, Rest3} ?= scan_number(Rest2),
        ok ?= check_size(Size),
        {ok, Rest4} ?= comma_unless_empty(size_of(Size), Rest3),
        {ok, Rest5} ?= skip_elements(ElemTag, size_of(Size), Rest4),
        {ok, Rest6} ?= expect_char(Rest5, $]),
        {ok, Rest6}
    else
        more -> more;
        {error, _} = Error -> Error
    end;
skip_by_tag(<<"map">>, Bin) ->
    maybe
        {ok, Rest0} ?= expect_char(Bin, $[),
        {ok, _KeyTag, Rest1} ?= scan_string(Rest0),
        {ok, Rest2} ?= expect_char(Rest1, $,),
        {ok, ValTag, Rest3} ?= scan_string(Rest2),
        {ok, Rest4} ?= expect_char(Rest3, $,),
        {ok, Size, Rest5} ?= scan_number(Rest4),
        ok ?= check_size(Size),
        {ok, Rest6} ?= expect_char(Rest5, $,),
        {ok, Rest7} ?= expect_char(Rest6, ${),
        {ok, Rest8} ?= skip_pairs(ValTag, size_of(Size), Rest7),
        {ok, Rest9} ?= expect_char(Rest8, $}),
        {ok, Rest10} ?= expect_char(Rest9, $]),
        {ok, Rest10}
    else
        more -> more;
        {error, _} = Error -> Error
    end;
skip_by_tag(Tag, _Bin) ->
    {error, {decode, {unknown_wire_type, Tag}}}.

-spec skip_struct(binary()) -> {ok, binary()} | more | {error, term()}.
skip_struct(Bin) ->
    case expect_char(Bin, ${) of
        {ok, Rest} ->
            skip_struct_fields(Rest);
        Other ->
            Other
    end.

-spec skip_struct_fields(binary()) -> {ok, binary()} | more | {error, term()}.
skip_struct_fields(Bin) ->
    case skip_ws(Bin) of
        <<"}", Rest/binary>> ->
            {ok, Rest};
        <<>> ->
            more;
        Rest0 ->
            case skip_struct_field(Rest0) of
                {ok, Rest1} ->
                    skip_struct_after_field(Rest1);
                Other ->
                    Other
            end
    end.

-spec skip_struct_after_field(binary()) -> {ok, binary()} | more | {error, term()}.
skip_struct_after_field(Bin) ->
    case skip_ws(Bin) of
        <<",", Rest/binary>> ->
            skip_struct_fields(Rest);
        <<"}", Rest/binary>> ->
            {ok, Rest};
        <<>> ->
            more;
        _ ->
            {error, {decode, bad_structure}}
    end.

-spec skip_struct_field(binary()) -> {ok, binary()} | more | {error, term()}.
skip_struct_field(Bin) ->
    maybe
        {ok, _IdText, Rest0} ?= scan_string(Bin),
        {ok, Rest1} ?= expect_char(Rest0, $:),
        {ok, Rest2} ?= expect_char(Rest1, ${),
        {ok, Tag, Rest3} ?= scan_string(Rest2),
        {ok, Rest4} ?= expect_char(Rest3, $:),
        {ok, Rest5} ?= skip_by_tag(Tag, Rest4),
        {ok, Rest6} ?= expect_char(Rest5, $}),
        {ok, Rest6}
    else
        more -> more;
        {error, _} = Error -> Error
    end.

-spec skip_elements(binary(), non_neg_integer(), binary()) -> {ok, binary()} | more | {error, term()}.
%% The caller consumes the closing bracket after the last element.
skip_elements(_ElemTag, 0, Bin) ->
    {ok, Bin};
skip_elements(ElemTag, 1, Bin) ->
    skip_by_tag(ElemTag, Bin);
skip_elements(ElemTag, N, Bin) when N > 1 ->
    case skip_by_tag(ElemTag, Bin) of
        {ok, Rest0} ->
            case expect_char(Rest0, $,) of
                {ok, Rest1} -> skip_elements(ElemTag, N - 1, Rest1);
                Other -> Other
            end;
        Other ->
            Other
    end.

-spec skip_pairs(binary(), non_neg_integer(), binary()) -> {ok, binary()} | more | {error, term()}.
%% The caller consumes the closing bracket after the last pair; keys
%% are skipped as strings, values by their wire tag.
skip_pairs(_ValTag, 0, Bin) ->
    {ok, Bin};
skip_pairs(ValTag, 1, Bin) ->
    case scan_string(Bin) of
        {ok, _KeyText, Rest0} ->
            case expect_char(Rest0, $:) of
                {ok, Rest1} -> skip_by_tag(ValTag, Rest1);
                Other -> Other
            end;
        Other ->
            Other
    end;
skip_pairs(ValTag, N, Bin) when N > 1 ->
    case scan_string(Bin) of
        {ok, _KeyText, Rest0} ->
            case expect_char(Rest0, $:) of
                {ok, RestColon} ->
                    skip_pairs_value(ValTag, N, RestColon);
                Other ->
                    Other
            end;
        Other ->
            Other
    end.

-spec skip_pairs_value(binary(), non_neg_integer(), binary()) ->
    {ok, binary()} | more | {error, term()}.
skip_pairs_value(ValTag, N, Bin) ->
    case skip_by_tag(ValTag, Bin) of
        {ok, Rest1} ->
            case expect_char(Rest1, $,) of
                {ok, Rest2} -> skip_pairs(ValTag, N - 1, Rest2);
                Other -> Other
            end;
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% JSON scanning primitives
%%--------------------------------------------------------------------

-spec skip_ws(binary()) -> binary().
skip_ws(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    skip_ws(Rest);
skip_ws(Bin) ->
    Bin.

-spec expect_char(binary(), char()) -> {ok, binary()} | more | {error, term()}.
expect_char(Bin, C) ->
    case skip_ws(Bin) of
        <<C, Rest/binary>> ->
            {ok, Rest};
        <<>> ->
            more;
        _ ->
            {error, {decode, bad_structure}}
    end.

%% Reads a JSON string token (leading whitespace allowed). Every byte
%% outside the escapes goes through as-is — UTF-8 included.
-spec scan_string(binary()) -> {ok, binary(), binary()} | more | {error, term()}.
scan_string(Bin) ->
    case skip_ws(Bin) of
        <<"\"", Rest/binary>> ->
            scan_string_body(Rest, []);
        <<>> ->
            more;
        _ ->
            {error, {decode, bad_string}}
    end.

-spec scan_string_body(binary(), [binary() | char()]) -> {ok, binary(), binary()} | more | {error, term()}.
scan_string_body(<<"\"", Rest/binary>>, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc)), Rest};
scan_string_body(<<"\\\"", Rest/binary>>, Acc) ->
    scan_string_body(Rest, [$" | Acc]);
scan_string_body(<<"\\\\", Rest/binary>>, Acc) ->
    scan_string_body(Rest, [$\\ | Acc]);
scan_string_body(<<"\\b", Rest/binary>>, Acc) ->
    scan_string_body(Rest, [16#08 | Acc]);
scan_string_body(<<"\\f", Rest/binary>>, Acc) ->
    scan_string_body(Rest, [16#0C | Acc]);
scan_string_body(<<"\\n", Rest/binary>>, Acc) ->
    scan_string_body(Rest, [16#0A | Acc]);
scan_string_body(<<"\\r", Rest/binary>>, Acc) ->
    scan_string_body(Rest, [16#0D | Acc]);
scan_string_body(<<"\\t", Rest/binary>>, Acc) ->
    scan_string_body(Rest, [16#09 | Acc]);
scan_string_body(<<"\\u", H1, H2, H3, H4, Rest/binary>>, Acc) ->
    case hex_value([H1, H2, H3, H4]) of
        {ok, CodePoint} when CodePoint >= 16#D800, CodePoint =< 16#DFFF ->
            {error, {decode, bad_string_escape}};
        {ok, CodePoint} ->
            scan_string_body(Rest, [<<CodePoint/utf8>> | Acc]);
        error ->
            {error, {decode, bad_string_escape}}
    end;
scan_string_body(<<C, Rest/binary>>, Acc) when C >= 16#20 ->
    scan_string_body(Rest, [C | Acc]);
scan_string_body(<<C, _/binary>>, _Acc) when C < 16#20 ->
    {error, {decode, bad_string}};
scan_string_body(<<>>, _Acc) ->
    more.

-spec hex_value([char()]) -> {ok, non_neg_integer()} | error.
hex_value(Digits) ->
    try
        {ok, binary_to_integer(iolist_to_binary(Digits), 16)}
    catch
        _:_ ->
            error
    end.

%% Reads a JSON number token: an integer or a decimal/exponent float.
%% A token cut off at the end of input mid-literal asks for more.
-spec scan_number(binary()) ->
    {ok, {int, integer()} | {float, float()}, binary()} | more | {error, term()}.
scan_number(Bin) ->
    case skip_ws(Bin) of
        <<>> ->
            more;
        Bin1 ->
            {Token, Rest} = take_number(Bin1, []),
            case classify_number(Token, Rest) of
                {ok, Number} ->
                    {ok, Number, Rest};
                Other ->
                    Other
            end
    end.

-spec take_number(binary(), [char()]) -> {[char()], binary()}.
take_number(<<C, Rest/binary>>, Acc) when
    (C >= $0 andalso C =< $9); C =:= $-; C =:= $+; C =:= $.; C =:= $e; C =:= $E
->
    take_number(Rest, [C | Acc]);
take_number(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

-spec classify_number([char()], binary()) ->
    {ok, {int, integer()} | {float, float()}} | more | {error, term()}.
classify_number([], <<>>) ->
    more;
classify_number([], _Rest) ->
    {error, {decode, bad_number}};
classify_number(Token, Rest) ->
    Text = iolist_to_binary(Token),
    %% A literal cut off at the end of input mid-float ("1.", "1e")
    %% may still be completed by the next bytes: more, not an error.
    Last = lists:last(Token),
    Truncated =
        Rest =:= <<>> andalso
            (Last =:= $. orelse Last =:= $e orelse Last =:= $E orelse Last =:= $+ orelse Last =:= $-),
    case has_float_marker(Token) of
        true ->
            try
                {ok, {float, binary_to_float(Text)}}
            catch
                _:_ when Truncated =:= true ->
                    more;
                _:_ ->
                    {error, {decode, bad_number}}
            end;
        false ->
            try
                {ok, {int, binary_to_integer(Text)}}
            catch
                _:_ when Truncated =:= true ->
                    more;
                _:_ ->
                    {error, {decode, bad_number}}
            end
    end.

%% A float literal has a dot or an exponent (a lone leading `-` or `+`
%% does not make one).
-spec has_float_marker([char()]) -> boolean().
has_float_marker(Token) ->
    lists:any(fun(C) -> C =:= $. orelse C =:= $e orelse C =:= $E end, Token).

%% Escape table matches the vendored Apache reference (Apache-2.0):
%% quote, backslash, control characters; UTF-8 passes through as-is.
-spec escape(binary()) -> binary().
escape(Bin) ->
    <<<<(escape_byte(B))/binary>> || <<B>> <= Bin>>.

-spec escape_byte(byte()) -> binary().
escape_byte($") -> <<"\\\"">>;
escape_byte($\\) -> <<"\\\\">>;
escape_byte($\b) -> <<"\\b">>;
escape_byte($\f) -> <<"\\f">>;
escape_byte($\n) -> <<"\\n">>;
escape_byte($\r) -> <<"\\r">>;
escape_byte($\t) -> <<"\\t">>;
escape_byte(B) when B < 16#20 -> iolist_to_binary(io_lib:format("\\u~4.16.0b", [B]));
escape_byte(B) -> <<B>>.

%%--------------------------------------------------------------------
%% Descriptor compilation
%%--------------------------------------------------------------------

-spec compile_type(type_desc()) -> j_type() | error.
compile_type({base, uuid}) ->
    {j_unsupported, {base, uuid}};
compile_type({base, B}) ->
    {j_base, B};
compile_type({enum, Desc}) ->
    {j_enum, Desc};
compile_type({list, T}) ->
    case compile_type(T) of
        error -> error;
        CT -> {j_list, CT}
    end;
compile_type({set, T}) ->
    case compile_type(T) of
        error -> error;
        CT -> {j_set, CT}
    end;
compile_type({set, T, _Impl}) ->
    compile_type({set, T});
compile_type({map, K, V}) ->
    case {compile_type(K), compile_map_key(K), compile_type(V)} of
        {error, _, _} ->
            error;
        {_, error, _} ->
            {j_unsupported, {map, K, V}};
        {CK, ok, CV} ->
            {j_map, CK, CV}
    end;
compile_type({struct, {ref, Module, Name}}) ->
    {j_ref, Module, Name};
compile_type({struct, {Kind, Fields}}) when is_atom(Kind), is_list(Fields) ->
    {j_struct, compile_struct(Kind, Fields)};
compile_type(_) ->
    error.

%% Only scalars and enums can live in a JSON object key.
-spec compile_map_key(type_desc()) -> ok | error.
compile_map_key({base, B}) when B =/= uuid ->
    ok;
compile_map_key({enum, _Desc}) ->
    ok;
compile_map_key(_) ->
    error.

-spec compile_struct(struct | union | exception, [thrift_runtime_binary:field_desc()]) -> j_struct().
compile_struct(Kind, Fields) ->
    Compiled = [{Id, compile_type(T), Name} || {Id, _R, T, Name, _D} <- Fields],
    #{
        kind => Kind,
        fields => [{Id, CT, Name} || {Id, CT, Name} <- Compiled],
        by_id => #{Id => {CT, Name} || {Id, CT, Name} <- Compiled},
        required => #{Id => Name || {Id, required, _T, Name, _D} <- Fields},
        %% Declaration order, so `missing_required_fields` lists names
        %% the way the descriptor reads.
        required_names => [Name || {_Id, required, _T, Name, _D} <- Fields]
    }.

-spec resolve_struct(module(), binary()) -> {ok, j_struct()} | error.
resolve_struct(Module, Name) ->
    thrift_runtime_protocol:resolve_struct(?MODULE, Module, Name, fun compile_struct/2).

%% The shared resolve-then-encode shape of the top-level ref entry and
%% the nested `j_ref' encoding. A generated module's specialized JSON
%% codec (found through the `json_codec/1' probe) takes precedence over
%% the compiled-scheme interpreter; JSON encode has no envelope-fold
%% asymmetry, so the same pair serves top-level and nested refs.
-spec encode_resolved(module(), binary(), term()) -> {ok, iodata()} | {error, term()}.
encode_resolved(Module, Name, Value) ->
    case json_codec(Module, Name) of
        {ok, CodecModule, EncodeName, _DecodeName} ->
            try
                CodecModule:EncodeName(Value)
            catch
                %% The types module was reloaded without this codec:
                %% drop the stale pair and take the generic path, same
                %% as a probe miss. An undef from a still-installed
                %% codec (a genuine bug) is re-raised.
                error:undef:Stack ->
                    case erlang:function_exported(CodecModule, EncodeName, 1) of
                        true ->
                            erlang:raise(error, undef, Stack);
                        false ->
                            thrift_runtime_protocol:codec_stale(?MODULE, Module, Name),
                            encode_ref_generic(Module, Name, Value)
                    end
            end;
        error ->
            encode_ref_generic(Module, Name, Value)
    end.

-spec encode_ref_generic(module(), binary(), term()) -> {ok, iodata()} | {error, term()}.
encode_ref_generic(Module, Name, Value) ->
    case resolve_struct(Module, Name) of
        {ok, Compiled} ->
            encode_struct_j(Compiled, Value);
        error ->
            {error, {encode, {unknown_struct, {Module, Name}}}}
    end.

%% The decode counterpart; callers pick the fold or no-fold struct
%% decode over the compiled schema.
-spec resolve_compiled(module(), binary()) -> {ok, j_struct()} | {error, term()}.
resolve_compiled(Module, Name) ->
    case resolve_struct(Module, Name) of
        {ok, Compiled} ->
            {ok, Compiled};
        error ->
            {error, {decode, {unknown_struct, {Module, Name}}}}
    end.

-spec json_codec(module(), binary()) -> {ok, module(), atom(), atom()} | error.
json_codec(Module, Name) ->
    thrift_runtime_protocol:codec(?MODULE, Module, Name, json_codec).

%% Inline `{Kind, Fields}` descriptors (params structs of
%% `function_info/2`) are literals, so the per-process memo hits on
%% pointer equality and a miss compiles into a capped list.
-spec memo_compiled(struct | union | exception, [thrift_runtime_binary:field_desc()]) -> j_struct().
memo_compiled(Kind, Fields) ->
    thrift_runtime_protocol:memo_compiled(?MODULE, {Kind, Fields}, Kind, Fields, fun compile_struct/2).

%%--------------------------------------------------------------------
%% Type tags and scalar helpers
%%--------------------------------------------------------------------

-spec tag(j_type()) -> binary().
tag({j_base, bool}) ->
    <<"tf">>;
tag({j_base, double}) ->
    <<"dbl">>;
tag({j_base, B}) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    atom_to_binary(B, utf8);
tag({j_base, S}) when S =:= string; S =:= binary ->
    <<"str">>;
tag({j_enum, _Desc}) ->
    <<"i32">>;
tag({j_list, _CElem}) ->
    <<"lst">>;
tag({j_set, _CElem}) ->
    <<"set">>;
tag({j_map, _CKey, _CVal}) ->
    <<"map">>;
tag({j_struct, _Compiled}) ->
    <<"rec">>;
tag({j_ref, _Module, _Name}) ->
    <<"rec">>;
tag({j_unsupported, _Desc}) ->
    <<>>.

-spec in_range(base_type(), term()) -> boolean().
in_range(i8, V) when is_integer(V) ->
    V >= -128 andalso V =< 127;
in_range(i16, V) when is_integer(V) ->
    V >= -32768 andalso V =< 32767;
in_range(i32, V) when is_integer(V) ->
    V >= -2147483648 andalso V =< 2147483647;
in_range(i64, V) when is_integer(V) ->
    V >= -9223372036854775808 andalso V =< 9223372036854775807;
in_range(_B, _V) ->
    false.
