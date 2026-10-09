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

-module(thrift_erl_compact).

-moduledoc """
Thrift compact protocol: value and message codecs as pure functions,
wire-compatible with the Apache TCompactProtocol (the vendored 0.25.0
Erlang implementation is the golden reference).

The compact format differs from the binary protocol in four ways, all
handled here:

- integers travel as ULEB128 varints, signed values zigzag-encoded
  (field ids too); the message seqid is a plain varint;
- doubles are little-endian;
- a struct field header packs the type into a nibble next to the field
  id: ids within 1..15 of the previously written/read field id travel
  as a delta in the high nibble, otherwise a zigzag varint id follows
  the type byte. A boolean field has no payload — its nibble
  (`16#01`/`16#02`) IS the value; booleans as collection elements are
  one cbool byte (1/2);
- collection sizes up to 14 fit the header byte's high nibble; a size
  of 15 in the nibble means a varint size follows.

Type descriptors, struct values, `more`-on-truncation semantics and the
error shapes match `thrift_erl_binary` — the two codecs are
interchangeable behind `thrift_erl:protocol/0`.

The `uuid` base type has no compact encoding (it postdates the format):
compiling a descriptor containing one succeeds, and encoding or decoding
through it fails with `{type_not_supported, {base, uuid}, compact}`.

Like the binary codec, descriptors are compiled before use — compact
type nibbles precomputed, struct fields indexed by id — with `{ref, ...}`
schemas cached in `persistent_term` and inline descriptors memoized per
process. See `thrift_erl_binary`'s moduledoc for the caching contract.
""".

-export([
    encode/2,
    decode/2,
    encode_message/4,
    decode_message/1,
    encode_application_exception/2,
    decode_application_exception/1
]).

-behaviour(thrift_erl_protocol).

-export_type([decode_result/1]).

-type decode_result(Value) :: thrift_erl_binary:decode_result(Value).

%% A compiled type descriptor: the compact nibble precomputed next to
%% every kind. `k_unsupported` marks a type with no compact encoding
%% (the `uuid` base type); it fails on use with a dedicated error.

-type nibble() :: 0..16#0F.

-type k_type() ::
    {k_base, nibble(), thrift_erl_binary:base_type()}
    | {k_enum, nibble(), thrift_erl_binary:enum_desc()}
    | {k_list, nibble(), k_type()}
    | {k_set, nibble(), k_type()}
    | {k_map, nibble(), nibble(), nibble(), k_type(), k_type()}
    | {k_struct, nibble(), k_struct()}
    | {k_ref, nibble(), module(), binary()}
    | {k_unsupported, thrift_erl_binary:type_desc(), compact}.

%% A compiled struct: fields in declaration order for encoding, an id
%% index for decoding, and the required subset for both checks.

-type k_struct() :: #{
    kind := struct | union | exception,
    fields := [{Id :: integer(), k_type(), Name :: binary()}],
    by_id := #{integer() => {k_type(), Name :: binary()}},
    required := #{integer() => Name :: binary()},
    required_names := [binary()]
}.

%% Compact type nibbles (the high bits of a field/collection header).
-define(CT_TRUE, 16#01).
-define(CT_FALSE, 16#02).
-define(CT_BYTE, 16#03).
-define(CT_I16, 16#04).
-define(CT_I32, 16#05).
-define(CT_I64, 16#06).
-define(CT_DOUBLE, 16#07).
-define(CT_BINARY, 16#08).
-define(CT_LIST, 16#09).
-define(CT_SET, 16#0A).
-define(CT_MAP, 16#0B).
-define(CT_STRUCT, 16#0C).

-define(PROTOCOL_ID, 16#82).
-define(VERSION_1, 16#01).
-define(VERSION_MASK, 16#1F).
-define(TYPE_BITS, 16#07).

%% Message envelope constants (the wire type bytes of the binary
%% protocol, reused here for the header nibble).
-define(STOP, 16#00).

%%--------------------------------------------------------------------
%% Values
%%--------------------------------------------------------------------

-doc "Encodes `Value` as `Type`, or fails with a tagged error.".
-spec encode(thrift_erl_binary:type_desc(), term()) -> {ok, iodata()} | {error, term()}.
encode({struct, {ref, Module, Name}}, Value) when is_map(Value) ->
    encode_resolved(Module, Name, Value);
encode({struct, {Kind, Fields}} = Desc, Value) when is_atom(Kind), is_list(Fields), is_map(Value) ->
    encode_struct_k(memo_compiled(Desc, Kind, Fields), Value);
encode({struct, _}, Value) ->
    {error, {encode, {value_does_not_match_type, Value}}};
encode(TypeDesc, Value) ->
    case compile_type(TypeDesc) of
        error ->
            {error, {encode, {value_does_not_match_type, Value}}};
        KType ->
            encode_k(KType, Value)
    end.

-doc """
Decodes a value of `Type` from the front of `Binary`.

Returns `{ok, Value, Rest}`, `more` when `Binary` is a truncated valid
encoding, or a tagged error.
""".
-spec decode(thrift_erl_binary:type_desc(), binary()) -> decode_result(term()).
decode({struct, {ref, Module, Name}}, Bin) when is_binary(Bin) ->
    decode_ref_struct(Module, Name, Bin);
decode({struct, {Kind, Fields}} = Desc, Bin) when is_atom(Kind), is_list(Fields), is_binary(Bin) ->
    decode_struct_k(memo_compiled(Desc, Kind, Fields), Bin);
decode(TypeDesc, Bin) when is_binary(Bin) ->
    case compile_type(TypeDesc) of
        error ->
            {error, {decode, bad_value}};
        KType ->
            decode_k(KType, Bin)
    end.

%% The shared resolve-then-encode shape of the top-level ref entry and
%% the nested `k_ref' encoding.
-spec encode_resolved(module(), binary(), term()) -> {ok, iodata()} | {error, term()}.
encode_resolved(Module, Name, Value) ->
    case resolve_struct(Module, Name) of
        {ok, Compiled} ->
            encode_struct_k(Compiled, Value);
        error ->
            {error, {encode, {unknown_struct, {Module, Name}}}}
    end.

-spec encode_k(k_type(), term()) -> {ok, iodata()} | {error, term()}.
encode_k({k_base, _N, bool}, true) ->
    {ok, <<?CT_TRUE>>};
encode_k({k_base, _N, bool}, false) ->
    {ok, <<?CT_FALSE>>};
encode_k({k_base, _N, i8}, V) when is_integer(V), V >= -128, V =< 127 ->
    {ok, <<V:8/big-signed>>};
encode_k({k_base, _N, i16}, V) when is_integer(V), V >= -32768, V =< 32767 ->
    {ok, zigzag_varint(V)};
encode_k({k_base, _N, i32}, V) when is_integer(V), V >= -2147483648, V =< 2147483647 ->
    {ok, zigzag_varint(V)};
encode_k({k_base, _N, i64}, V) when
    is_integer(V), V >= -9223372036854775808, V =< 9223372036854775807
->
    {ok, zigzag_varint(V)};
encode_k({k_base, _N, double}, V) when is_number(V) ->
    {ok, <<(float(V)):64/little-float>>};
encode_k({k_base, _N, S}, V) when S =:= string; S =:= binary ->
    encode_binary_k(V);
encode_k({k_enum, _N, Desc}, V) ->
    case thrift_erl_protocol:enum_to_int(Desc, V) of
        {ok, Int} -> {ok, zigzag_varint(Int)};
        error -> {error, {encode, {unknown_enum_value, V}}}
    end;
encode_k({k_list, N, KElem}, Values) when is_list(Values) ->
    encode_sequence_k(N, KElem, Values);
encode_k({k_set, N, KElem}, Values) when is_list(Values) ->
    encode_sequence_k(N, KElem, Values);
encode_k({k_map, _N, KKey, KVal, KElem, KVElem}, Value) when is_map(Value) ->
    encode_map_k(KKey, KVal, KElem, KVElem, Value);
encode_k({k_struct, _N, Compiled}, Value) when is_map(Value) ->
    encode_struct_k(Compiled, Value);
encode_k({k_ref, _N, Module, Name}, Value) when is_map(Value) ->
    encode_resolved(Module, Name, Value);
encode_k({k_unsupported, Desc, compact}, _V) ->
    {error, {encode, {type_not_supported, Desc, compact}}};
encode_k(_Type, Value) ->
    {error, {encode, {value_does_not_match_type, Value}}}.

-spec encode_binary_k(binary()) -> {ok, iodata()} | {error, term()}.
encode_binary_k(V) when is_binary(V) ->
    {ok, [varint(byte_size(V)), V]};
encode_binary_k(V) ->
    {error, {encode, {value_does_not_match_type, V}}}.

-spec decode_k(k_type(), binary()) -> decode_result(term()).
decode_k({k_base, _N, bool}, Bin) ->
    %% Standalone boolean: a collection element or a skipped-in-value
    %% position; struct fields carry the value in the header nibble.
    case Bin of
        <<?CT_TRUE, Rest/binary>> -> {ok, true, Rest};
        <<?CT_FALSE, Rest/binary>> -> {ok, false, Rest};
        <<_, _/binary>> -> {error, {decode, bad_bool_value}};
        _ -> more
    end;
decode_k({k_base, _N, i8}, <<V:8/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode_k({k_base, _N, i16}, Bin) ->
    decode_zigzag(Bin);
decode_k({k_base, _N, i32}, Bin) ->
    decode_zigzag(Bin);
decode_k({k_base, _N, i64}, Bin) ->
    decode_zigzag(Bin);
decode_k({k_base, _N, double}, <<V:64/little-float, Rest/binary>>) ->
    {ok, V, Rest};
decode_k({k_base, _N, S}, Bin) when S =:= string; S =:= binary ->
    decode_binary_k(Bin);
decode_k({k_enum, _N, Desc}, Bin) ->
    case decode_zigzag(Bin) of
        {ok, Int, Rest} ->
            case thrift_erl_protocol:enum_from_int(Desc, Int) of
                {ok, Atom} -> {ok, Atom, Rest};
                error -> {ok, Int, Rest}
            end;
        Other ->
            Other
    end;
decode_k({Collection, _N, KElem}, Bin) when Collection =:= k_list; Collection =:= k_set ->
    %% list and set share the wire format: the header carries the
    %% element nibble and size, there is nothing else to tell apart
    case decode_collection_header(Bin) of
        {ok, {Observed, Size}, Rest} ->
            case nibble_matches(Observed, KElem) of
                true -> decode_elements_k(KElem, Size, Rest, []);
                false -> {error, {decode, {element_type_mismatch, Observed}}}
            end;
        Other ->
            Other
    end;
decode_k({k_map, _N, KKey, KVal, CKey, CVal}, Bin) ->
    decode_map_k(KKey, KVal, CKey, CVal, Bin);
decode_k({k_struct, _N, Compiled}, Bin) ->
    decode_struct_k(Compiled, Bin);
decode_k({k_ref, _N, Module, Name}, Bin) ->
    decode_ref_struct(Module, Name, Bin);
decode_k({k_unsupported, Desc, compact}, _Bin) ->
    {error, {decode, {type_not_supported, Desc, compact}}};
decode_k({k_base, _N, B}, Bin) when is_binary(Bin) ->
    case byte_size(Bin) >= base_size(B) of
        true -> {error, {decode, {bad_value_for_base_type, B}}};
        false -> more
    end;
decode_k(_Type, Bin) when is_binary(Bin) ->
    {error, {decode, bad_value}}.

-spec decode_binary_k(binary()) -> decode_result(binary()).
decode_binary_k(Bin) ->
    case decode_varint(Bin) of
        {ok, Length, Rest} when byte_size(Rest) >= Length ->
            <<V:Length/binary, Tail/binary>> = Rest,
            {ok, V, Tail};
        {ok, _Length, _Rest} ->
            more;
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% Structs
%%--------------------------------------------------------------------

-spec encode_struct_k(k_struct(), thrift_erl_binary:struct_value()) -> {ok, iodata()} | {error, term()}.
encode_struct_k(#{kind := Kind, fields := Fields, required_names := ReqNames}, Map) ->
    case check_present_fields(Kind, ReqNames, Fields, Map) of
        ok ->
            encode_fields_k(Fields, Map, 0);
        {error, _} = Error ->
            Error
    end.

%% Fields build forward: the recursion returns the tail iodata, each
%% written field conses its chunk in front of it. `LastId` is the last
%% WRITTEN field id (absent fields do not move it — deltas are against
%% what is actually on the wire, like the Apache writer).

-spec encode_fields_k([{integer(), k_type(), binary()}], thrift_erl_binary:struct_value(), integer()) ->
    {ok, iodata()} | {error, term()}.
encode_fields_k([], _Map, _LastId) ->
    {ok, [?STOP]};
encode_fields_k([{Id, {k_base, _, bool}, Name} | Rest], Map, LastId) ->
    case Map of
        %% The field's value rides in the header nibble: no payload bytes.
        #{Name := Value} ->
            case bool_nibble(Value) of
                {ok, Nibble} ->
                    case encode_fields_k(Rest, Map, Id) of
                        {ok, RestIo} -> {ok, [field_header(Id, LastId, Nibble) | RestIo]};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            encode_fields_k(Rest, Map, LastId)
    end;
encode_fields_k([{Id, KType, Name} | Rest], Map, LastId) ->
    case Map of
        #{Name := Value} ->
            case encode_k(KType, Value) of
                {ok, Encoded} ->
                    case encode_fields_k(Rest, Map, Id) of
                        {ok, RestIo} ->
                            {ok, [
                                [
                                    field_header(Id, LastId, k_wire(KType)),
                                    Encoded
                                ]
                                | RestIo
                            ]};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            encode_fields_k(Rest, Map, LastId)
    end.

-spec bool_nibble(term()) -> {ok, ?CT_TRUE | ?CT_FALSE} | {error, term()}.
bool_nibble(true) ->
    {ok, ?CT_TRUE};
bool_nibble(false) ->
    {ok, ?CT_FALSE};
bool_nibble(Value) ->
    {error, {encode, {value_does_not_match_type, Value}}}.

-spec field_header(integer(), integer(), ?CT_TRUE..?CT_STRUCT) -> iodata().
field_header(Id, LastId, Nibble) ->
    Delta = Id - LastId,
    case Delta > 0 andalso Delta < 16 of
        true ->
            <<((Delta bsl 4) bor Nibble)>>;
        false ->
            [<<Nibble>>, zigzag_varint(Id)]
    end.

-spec decode_struct_k(k_struct(), binary()) -> decode_result(thrift_erl_binary:struct_value()).
decode_struct_k(#{by_id := ById, required := Required}, Bin) ->
    decode_struct_fields_k(ById, Required, Bin, 0, #{}).

-spec decode_struct_fields_k(
    #{integer() => {k_type(), binary()}},
    #{integer() => binary()},
    binary(),
    integer(),
    thrift_erl_binary:struct_value()
) ->
    decode_result(thrift_erl_binary:struct_value()).
decode_struct_fields_k(_ById, Required, <<?STOP, Rest/binary>>, _LastId, Acc) ->
    case maps:values(Required) of
        [] -> {ok, Acc, Rest};
        Missing -> {error, {decode, {missing_required_fields, Missing}}}
    end;
decode_struct_fields_k(ById, Required, <<Header:8/big-unsigned, Rest/binary>>, LastId, Acc) ->
    Nibble = Header band 16#0F,
    case Header bsr 4 of
        %% High nibble zero: the id travels as a zigzag varint i16.
        0 ->
            case decode_zigzag(Rest) of
                {ok, Id, Rest1} ->
                    decode_field_k(ById, Required, Id, Nibble, Rest1, Id, Acc);
                Other ->
                    Other
            end;
        Delta ->
            Id = LastId + Delta,
            decode_field_k(ById, Required, Id, Nibble, Rest, Id, Acc)
    end;
decode_struct_fields_k(_ById, _Required, Bin, _LastId, _Acc) when byte_size(Bin) < 1 ->
    more.

-spec decode_field_k(
    #{integer() => {k_type(), binary()}},
    #{integer() => binary()},
    integer(),
    non_neg_integer(),
    binary(),
    integer(),
    thrift_erl_binary:struct_value()
) ->
    decode_result(thrift_erl_binary:struct_value()).
decode_field_k(ById, Required, Id, Nibble, Bin, LastId, Acc) ->
    case ById of
        #{Id := {KType, Name}} ->
            case nibble_matches(Nibble, KType) of
                true ->
                    case decode_field_value_k(KType, Nibble, Bin) of
                        {ok, Value, Rest} ->
                            decode_struct_fields_k(
                                ById, mark_present(Required, Id), Rest, LastId, Acc#{Name => Value}
                            );
                        more ->
                            more;
                        {error, _} = Error ->
                            Error
                    end;
                false ->
                    {error, {decode, {field_type_mismatch, Id}}}
            end;
        #{} ->
            case skip_nibble(Nibble, Bin) of
                {ok, Rest} -> decode_struct_fields_k(ById, Required, Rest, LastId, Acc);
                more -> more;
                {error, _} = Error -> Error
            end
    end.

-spec mark_present(#{integer() => binary()}, integer()) -> #{integer() => binary()}.
mark_present(Required, Id) ->
    case Required of
        #{Id := _} -> maps:remove(Id, Required);
        #{} -> Required
    end.

%% A boolean field's payload rides in the header nibble; every other
%% type decodes from the bytes after the header.

-spec decode_field_value_k(k_type(), non_neg_integer(), binary()) -> decode_result(term()).
decode_field_value_k({k_base, _, bool}, Nibble, Bin) when Nibble =:= ?CT_TRUE; Nibble =:= ?CT_FALSE ->
    {ok, Nibble =:= ?CT_TRUE, Bin};
decode_field_value_k(KType, _Nibble, Bin) ->
    decode_k(KType, Bin).

%% Field type check: the observed nibble against the compiled type. For
%% a boolean field either boolean nibble matches; for everything else
%% the nibble is the type.

-spec nibble_matches(non_neg_integer(), k_type()) -> boolean().
nibble_matches(N, {k_base, _, bool}) ->
    %% Both boolean nibbles name the type; the value IS the nibble.
    N =:= ?CT_TRUE orelse N =:= ?CT_FALSE;
nibble_matches(N, {k_base, Expected, _}) ->
    N =:= Expected;
nibble_matches(N, {k_enum, Expected, _}) ->
    N =:= Expected;
nibble_matches(N, {k_list, Expected, _}) ->
    N =:= Expected;
nibble_matches(N, {k_set, Expected, _}) ->
    N =:= Expected;
nibble_matches(N, {k_map, Expected, _, _, _, _}) ->
    N =:= Expected;
nibble_matches(N, {k_struct, Expected, _}) ->
    N =:= Expected;
nibble_matches(N, {k_ref, Expected, _, _}) ->
    N =:= Expected;
%% A type the compact protocol cannot carry never matches: decoding a
%% known id with such a descriptor reports a field type mismatch.
nibble_matches(_N, {k_unsupported, _, _}) ->
    false.

%% Same check for compile results that carry no nested payload.
-spec k_wire(k_type()) -> non_neg_integer().
k_wire({k_base, N, _}) -> N;
k_wire({k_enum, N, _}) -> N;
k_wire({k_list, N, _}) -> N;
k_wire({k_set, N, _}) -> N;
k_wire({k_map, N, _, _, _, _}) -> N;
k_wire({k_struct, N, _}) -> N;
k_wire({k_ref, N, _, _}) -> N;
k_wire({k_unsupported, _, _}) -> 0.

-spec check_present_fields(
    struct | union | exception, [binary()], [{integer(), k_type(), binary()}], thrift_erl_binary:struct_value()
) ->
    ok | {error, term()}.
check_present_fields(union, _ReqNames, Fields, Map) ->
    Present = [Name || {_, _, Name} <- Fields, maps:is_key(Name, Map)],
    case length(Present) of
        1 -> ok;
        0 -> {error, {encode, union_empty}};
        _ -> {error, {encode, union_multiple}}
    end;
check_present_fields(_Kind, ReqNames, _Fields, Map) ->
    case all_present(ReqNames, Map) of
        true ->
            ok;
        false ->
            Missing = [Name || Name <- ReqNames, not maps:is_key(Name, Map)],
            {error, {encode, {missing_required_fields, Missing}}}
    end.

-spec all_present([binary()], thrift_erl_binary:struct_value()) -> boolean().
all_present(Names, Map) ->
    thrift_erl_protocol:all_present(Names, Map).

%%--------------------------------------------------------------------
%% Containers
%%--------------------------------------------------------------------

-spec encode_sequence_k(non_neg_integer(), k_type(), [term()]) -> {ok, iodata()} | {error, term()}.
encode_sequence_k(_N, KElem, Values) ->
    case encode_elements_k(KElem, Values) of
        {ok, Encoded} ->
            %% The collection header carries the ELEMENT type nibble —
            %% list and set are indistinguishable on the wire.
            {ok, [collection_header(k_wire(KElem), length(Values)), Encoded]};
        Error ->
            Error
    end.

-spec encode_elements_k(k_type(), [term()]) -> {ok, iodata()} | {error, term()}.
encode_elements_k(_KElem, []) ->
    {ok, []};
encode_elements_k(KElem, [V | Rest]) ->
    case encode_k(KElem, V) of
        {ok, Encoded} ->
            case encode_elements_k(KElem, Rest) of
                {ok, RestIo} -> {ok, [Encoded | RestIo]};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Up to 14 elements share the header byte with the type nibble; 15 in
%% the nibble means a varint size follows.

-spec collection_header(non_neg_integer(), non_neg_integer()) -> iodata().
collection_header(N, Size) when Size < 15 ->
    <<((Size bsl 4) bor N)>>;
collection_header(N, Size) ->
    [<<(16#F0 bor N)>>, varint(Size)].

-spec decode_collection_header(binary()) ->
    {ok, {non_neg_integer(), non_neg_integer()}, binary()} | more | {error, term()}.
decode_collection_header(<<Header:8/big-unsigned, Rest/binary>>) ->
    Nibble = Header band 16#0F,
    case Header bsr 4 of
        15 ->
            case decode_varint(Rest) of
                {ok, Size, Rest1} -> {ok, {Nibble, Size}, Rest1};
                Other -> Other
            end;
        Size ->
            {ok, {Nibble, Size}, Rest}
    end;
decode_collection_header(<<>>) ->
    more.

-spec decode_elements_k(k_type(), non_neg_integer(), binary(), [term()]) ->
    decode_result([term()]).
decode_elements_k(_KElem, 0, Rest, Acc) ->
    {ok, lists:reverse(Acc), Rest};
decode_elements_k(KElem, N, Bin, Acc) ->
    case decode_k(KElem, Bin) of
        {ok, Value, Rest} -> decode_elements_k(KElem, N - 1, Rest, [Value | Acc]);
        Other -> Other
    end.

-spec encode_map_k(non_neg_integer(), non_neg_integer(), k_type(), k_type(), map()) ->
    {ok, iodata()} | {error, term()}.
encode_map_k(_KKey, _KVal, _CKey, _CVal, Value) when map_size(Value) =:= 0 ->
    {ok, <<0>>};
encode_map_k(KKey, KVal, CKey, CVal, Value) ->
    case encoded_pairs_k(CKey, CVal, maps:to_list(Value)) of
        {ok, Pairs} ->
            %% Sorted by encoded key bytes, like the binary codec, so a
            %% map round-trips to the same bytes regardless of term order.
            Sorted = lists:sort(fun({KE, _}, {KE1, _}) -> KE =< KE1 end, Pairs),
            {ok, [
                [varint(map_size(Value)), <<((KKey bsl 4) bor KVal)>>],
                [[KE, VE] || {KE, VE} <- Sorted]
            ]};
        Error ->
            Error
    end.

-spec encoded_pairs_k(k_type(), k_type(), [{term(), term()}]) ->
    {ok, [{iodata(), iodata()}]} | {error, term()}.
encoded_pairs_k(_CKey, _CVal, []) ->
    {ok, []};
encoded_pairs_k(CKey, CVal, [{K, V} | Rest]) ->
    maybe
        {ok, KE} ?= encode_k(CKey, K),
        {ok, VE} ?= encode_k(CVal, V),
        case encoded_pairs_k(CKey, CVal, Rest) of
            {ok, RestPairs} -> {ok, [{KE, VE} | RestPairs]};
            {error, _} = Error -> Error
        end
    else
        {error, Reason} ->
            {error, Reason}
    end.

-spec decode_map_k(non_neg_integer(), non_neg_integer(), k_type(), k_type(), binary()) ->
    decode_result(map()).
decode_map_k(KKey, KVal, CKey, CVal, Bin) ->
    case decode_varint(Bin) of
        {ok, 0, Rest} ->
            {ok, #{}, Rest};
        {ok, _Size, Rest} when byte_size(Rest) =:= 0 ->
            more;
        {ok, Size, <<Types:8/big-unsigned, Rest/binary>>} when Size > 0 ->
            case {Types bsr 4, Types band 16#0F} of
                {KKey, KVal} ->
                    decode_pairs_k(CKey, CVal, Size, Rest, #{});
                _ ->
                    {error, {decode, map_type_mismatch}}
            end;
        Other ->
            Other
    end.

-spec decode_pairs_k(k_type(), k_type(), non_neg_integer(), binary(), map()) ->
    decode_result(map()).
decode_pairs_k(_CKey, _CVal, 0, Rest, Acc) ->
    {ok, Acc, Rest};
decode_pairs_k(CKey, CVal, N, Bin, Acc) ->
    case decode_k(CKey, Bin) of
        {ok, K, Rest} ->
            case decode_k(CVal, Rest) of
                {ok, V, Rest1} -> decode_pairs_k(CKey, CVal, N - 1, Rest1, Acc#{K => V});
                Other -> Other
            end;
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% Wire-type skipping (forward compatibility)
%%--------------------------------------------------------------------

-spec skip_nibble(non_neg_integer(), binary()) -> {ok, binary()} | more | {error, term()}.
skip_nibble(N, Bin) when N =:= ?CT_TRUE; N =:= ?CT_FALSE ->
    {ok, Bin};
skip_nibble(?CT_BYTE, <<_, Rest/binary>>) ->
    {ok, Rest};
skip_nibble(?CT_BYTE, Bin) when byte_size(Bin) < 1 ->
    more;
skip_nibble(N, Bin) when N =:= ?CT_I16; N =:= ?CT_I32; N =:= ?CT_I64 ->
    case decode_varint(Bin) of
        {ok, _, Rest} -> {ok, Rest};
        Other -> Other
    end;
skip_nibble(?CT_DOUBLE, <<_:8/binary, Rest/binary>>) ->
    {ok, Rest};
skip_nibble(?CT_DOUBLE, Bin) when byte_size(Bin) < 8 ->
    more;
skip_nibble(?CT_BINARY, Bin) ->
    case decode_varint(Bin) of
        {ok, Length, Rest} when byte_size(Rest) >= Length ->
            <<_:Length/binary, Tail/binary>> = Rest,
            {ok, Tail};
        {ok, _, _} ->
            more;
        Other ->
            Other
    end;
skip_nibble(?CT_STRUCT, Bin) ->
    skip_struct(Bin);
skip_nibble(N, Bin) when N =:= ?CT_LIST; N =:= ?CT_SET ->
    case decode_collection_header(Bin) of
        %% The header carries the ELEMENT nibble; skip that many of those.
        {ok, {ElemNibble, Size}, Rest} -> skip_elements(ElemNibble, Size, Rest);
        Other -> Other
    end;
skip_nibble(?CT_MAP, Bin) ->
    skip_map(Bin);
skip_nibble(N, _) ->
    {error, {decode, {unknown_wire_type, N}}}.

-spec skip_struct(binary()) -> {ok, binary()} | more | {error, term()}.
skip_struct(<<?STOP, Rest/binary>>) ->
    {ok, Rest};
skip_struct(<<Header:8/big-unsigned, Rest/binary>>) ->
    Nibble = Header band 16#0F,
    case Header bsr 4 of
        0 ->
            case decode_zigzag(Rest) of
                {ok, _Id, Rest1} ->
                    case skip_nibble(Nibble, Rest1) of
                        {ok, Rest2} -> skip_struct(Rest2);
                        Other -> Other
                    end;
                Other ->
                    Other
            end;
        _Delta ->
            case skip_nibble(Nibble, Rest) of
                {ok, Rest1} -> skip_struct(Rest1);
                Other -> Other
            end
    end;
skip_struct(Bin) when byte_size(Bin) < 1 ->
    more.

-spec skip_elements(non_neg_integer(), non_neg_integer(), binary()) ->
    {ok, binary()} | more | {error, term()}.
skip_elements(_Nibble, 0, Rest) ->
    {ok, Rest};
skip_elements(Nibble, N, Bin) ->
    case skip_nibble(Nibble, Bin) of
        {ok, Rest} -> skip_elements(Nibble, N - 1, Rest);
        Other -> Other
    end.

-spec skip_map(binary()) -> {ok, binary()} | more | {error, term()}.
skip_map(Bin) ->
    case decode_varint(Bin) of
        {ok, 0, Rest} ->
            {ok, Rest};
        {ok, _Size, Rest} when byte_size(Rest) =:= 0 ->
            more;
        {ok, Size, <<Types:8/big-unsigned, Rest/binary>>} when Size > 0 ->
            skip_pairs(Types bsr 4, Types band 16#0F, Size, Rest);
        Other ->
            Other
    end.

-spec skip_pairs(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary()) ->
    {ok, binary()} | more | {error, term()}.
skip_pairs(_Key, _Val, 0, Rest) ->
    {ok, Rest};
skip_pairs(Key, Val, N, Bin) ->
    case skip_nibble(Key, Bin) of
        {ok, Rest} ->
            case skip_nibble(Val, Rest) of
                {ok, Rest1} -> skip_pairs(Key, Val, N - 1, Rest1);
                Other -> Other
            end;
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% Message envelope
%%--------------------------------------------------------------------

-doc """
Encodes a message envelope around `Payload` (already encoded as a
struct): protocol id, version-and-type byte, varint seqid, name string.
""".
-spec encode_message(thrift_erl_binary:message_type(), binary(), non_neg_integer(), iodata()) ->
    iodata().
encode_message(Type, Name, SeqId, Payload) ->
    TypeB = thrift_erl_protocol:message_type_id(Type),
    [
        <<?PROTOCOL_ID, (?VERSION_1 bor (TypeB bsl 5))>>,
        varint(SeqId),
        varint(byte_size(Name)),
        Name,
        Payload
    ].

-doc """
Decodes a message envelope.

Returns `{ok, Type, Name, SeqId, Tail}` where `Tail` is every byte
after the name (the struct payload plus anything that follows it),
`more`, or a tagged error. Only the current compact version (1) is
accepted — the format has no legacy variant.
""".
-spec decode_message(binary()) ->
    {ok, thrift_erl_binary:message_type(), binary(), non_neg_integer(), binary()}
    | more
    | {error, term()}.
decode_message(<<?PROTOCOL_ID, VersionAndType, Rest/binary>>) ->
    case VersionAndType band ?VERSION_MASK of
        ?VERSION_1 ->
            TypeB = (VersionAndType bsr 5) band ?TYPE_BITS,
            case thrift_erl_protocol:message_type(TypeB) of
                {ok, Type} ->
                    decode_message_name(Type, Rest);
                error ->
                    {error, {decode, {unknown_message_type, TypeB}}}
            end;
        Version ->
            {error, {decode, {bad_protocol_version, Version}}}
    end;
decode_message(Bin) when byte_size(Bin) < 2 ->
    more;
decode_message(_) ->
    {error, {decode, bad_envelope}}.

-spec decode_message_name(thrift_erl_binary:message_type(), binary()) ->
    {ok, thrift_erl_binary:message_type(), binary(), non_neg_integer(), binary()}
    | more
    | {error, term()}.
decode_message_name(Type, Bin) ->
    case decode_varint(Bin) of
        {ok, SeqId, Rest1} ->
            case decode_binary_k(Rest1) of
                {ok, Name, Rest2} -> {ok, Type, Name, SeqId, Rest2};
                Other -> Other
            end;
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% TApplicationException
%%--------------------------------------------------------------------

-doc """
Encodes `TApplicationException` as an EXCEPTION message payload.
""".
-spec encode_application_exception(binary(), non_neg_integer()) ->
    {ok, iodata()} | {error, term()}.
encode_application_exception(Message, Code) ->
    thrift_erl_protocol:encode_application_exception(?MODULE, Message, Code).

-doc """
Decodes `TApplicationException` from an EXCEPTION message payload.

Unknown fields are skipped per the usual struct rules.
""".
-spec decode_application_exception(binary()) ->
    decode_result(thrift_erl_binary:application_exception()).
decode_application_exception(Bin) ->
    thrift_erl_protocol:decode_application_exception(?MODULE, Bin).

%%--------------------------------------------------------------------
%% Descriptor compilation
%%--------------------------------------------------------------------

-spec compile_type(thrift_erl_binary:type_desc()) -> k_type() | error.
compile_type({base, uuid}) ->
    {k_unsupported, {base, uuid}, compact};
compile_type({base, B}) ->
    case base_nibble(B) of
        error -> error;
        N -> {k_base, N, B}
    end;
compile_type({enum, Desc}) ->
    {k_enum, ?CT_I32, Desc};
compile_type({list, T}) ->
    case compile_type(T) of
        error -> error;
        K -> {k_list, ?CT_LIST, K}
    end;
compile_type({set, T}) ->
    case compile_type(T) of
        error -> error;
        K -> {k_set, ?CT_SET, K}
    end;
compile_type({set, T, _Impl}) ->
    compile_type({set, T});
compile_type({map, K0, V0}) ->
    case {compile_type(K0), compile_type(V0)} of
        {error, _} -> error;
        {_, error} -> error;
        {K, V} -> {k_map, ?CT_MAP, k_wire(K), k_wire(V), K, V}
    end;
compile_type({struct, {ref, Module, Name}}) ->
    {k_ref, ?CT_STRUCT, Module, Name};
compile_type({struct, {Kind, Fields}}) when is_atom(Kind), is_list(Fields) ->
    {k_struct, ?CT_STRUCT, compile_struct(Kind, Fields)};
compile_type(_) ->
    error.

-spec base_nibble(thrift_erl_binary:base_type() | term()) -> non_neg_integer() | error.
base_nibble(bool) -> ?CT_TRUE;
base_nibble(i8) -> ?CT_BYTE;
base_nibble(i16) -> ?CT_I16;
base_nibble(i32) -> ?CT_I32;
base_nibble(i64) -> ?CT_I64;
base_nibble(double) -> ?CT_DOUBLE;
base_nibble(string) -> ?CT_BINARY;
base_nibble(binary) -> ?CT_BINARY;
base_nibble(_) -> error.

-spec compile_struct(struct | union | exception, [thrift_erl_binary:field_desc()]) -> k_struct().
compile_struct(Kind, Fields) ->
    Compiled = [{Id, compile_type(T), Name} || {Id, _R, T, Name, _D} <- Fields],
    %% A field whose type failed to compile carries `error` — it errors
    %% in encode_k/decode_k before any header is written or matched.
    #{
        kind => Kind,
        fields => [{Id, K, Name} || {Id, K, Name} <- Compiled],
        by_id => #{Id => {K, Name} || {Id, K, Name} <- Compiled},
        required => #{Id => Name || {Id, required, _T, Name, _D} <- Fields},
        required_names => [Name || {_Id, required, _T, Name, _D} <- Fields]
    }.

-spec resolve_struct(module(), binary()) -> {ok, k_struct()} | error.
resolve_struct(Module, Name) ->
    thrift_erl_protocol:resolve_struct(?MODULE, Module, Name, fun compile_struct/2).

-spec decode_ref_struct(module(), binary(), binary()) -> decode_result(thrift_erl_binary:struct_value()).
decode_ref_struct(Module, Name, Bin) ->
    case resolve_struct(Module, Name) of
        {ok, Compiled} ->
            decode_struct_k(Compiled, Bin);
        error ->
            {error, {decode, {unknown_struct, {Module, Name}}}}
    end.

-spec memo_compiled(thrift_erl_binary:type_desc(), struct | union | exception, [
    thrift_erl_binary:field_desc()
]) ->
    k_struct().
memo_compiled(Desc, Kind, Fields) ->
    thrift_erl_protocol:memo_compiled(?MODULE, Desc, Kind, Fields, fun compile_struct/2).

%%--------------------------------------------------------------------
%% Varint and zigzag
%%--------------------------------------------------------------------

-spec varint(non_neg_integer()) -> iodata().
varint(V) when V < 16#80 ->
    [<<V>>];
varint(V) ->
    [<<((V band 16#7F) bor 16#80)>> | varint(V bsr 7)].

-spec decode_varint(binary()) -> decode_result(non_neg_integer()).
decode_varint(Bin) ->
    decode_varint(Bin, 0, 0).

-spec decode_varint(binary(), non_neg_integer(), non_neg_integer()) ->
    decode_result(non_neg_integer()).
%% A ULEB128 varint of a 64-bit value is at most 10 bytes: the 10th
%% byte (shift 63) must be terminal.
decode_varint(<<B, Rest/binary>>, Shift, Acc) when B >= 16#80, Shift < 63 ->
    decode_varint(Rest, Shift + 7, Acc bor ((B band 16#7F) bsl Shift));
decode_varint(<<B, Rest/binary>>, Shift, Acc) when B < 16#80 ->
    {ok, Acc bor (B bsl Shift), Rest};
decode_varint(<<_, _/binary>>, Shift, _Acc) when Shift >= 63 ->
    {error, {decode, bad_varint}};
decode_varint(_Bin, _Shift, _Acc) ->
    more.

-spec to_zigzag(integer()) -> non_neg_integer().
to_zigzag(V) ->
    16#FFFFFFFFFFFFFFFF band ((V bsl 1) bxor (V bsr 63)).

-spec from_zigzag(non_neg_integer()) -> integer().
from_zigzag(V) ->
    (V bsr 1) bxor -(V band 1).

-spec zigzag_varint(integer()) -> iodata().
zigzag_varint(V) ->
    varint(to_zigzag(V)).

-spec decode_zigzag(binary()) -> decode_result(integer()).
decode_zigzag(Bin) ->
    case decode_varint(Bin) of
        {ok, V, Rest} -> {ok, from_zigzag(V), Rest};
        Other -> Other
    end.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

-spec base_size(thrift_erl_binary:base_type()) -> non_neg_integer().
base_size(bool) -> 1;
base_size(i8) -> 1;
base_size(i16) -> 2;
base_size(i32) -> 4;
base_size(i64) -> 8;
base_size(double) -> 8;
base_size(string) -> 0;
base_size(binary) -> 0.
