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

-module(thrift_erl_binary).

-moduledoc """
Thrift binary protocol: value and message codecs as pure functions.

Encoding takes a type descriptor — the same shape the generated
`struct_info/1`, `enum_info/1` and `function_info/2` introspection
functions return — and produces iodata. Decoding consumes a binary and
returns the remaining bytes, so callers can stream.

Structs travel as maps keyed by binary field names. On decode, unknown
field ids are skipped by wire type, so newer writers stay readable.

Decoding distinguishes `more` (the binary is a truncated but otherwise
valid encoding — read more bytes and retry) from `{error, _}` (the bytes
cannot be a valid encoding). That is what lets the buffered transport
parse incrementally off a socket.

Before encoding or decoding, a descriptor is compiled: wire type bytes
are precomputed, struct fields are indexed by id in a map, and the
required fields are separated out. `{ref, Module, Name}` schemas are
compiled once and cached in `persistent_term` under their names, so
resolving a nested struct is a constant-time lookup. Inline
`{Kind, Fields}` descriptors (such as the `function_info/2` params
structs) are memoized per process under exact equality — generated
descriptors are literals, so the memo hit is a pointer comparison. The
caches assume generated types modules are never hot-swapped between
incompatible versions.
""".

-export([
    encode/2,
    decode/2,
    encode_message/4,
    decode_message/1,
    encode_application_exception/2,
    decode_application_exception/1,
    type_id/1,
    struct_fields/1
]).

%% The exported encode/decode/message functions are the
%% thrift_erl_protocol callbacks under the same names.
-behaviour(thrift_erl_protocol).

-export_type([
    base_type/0,
    type_desc/0,
    field_desc/0,
    struct_desc/0,
    enum_desc/0,
    struct_value/0,
    message_type/0,
    application_exception/0,
    decode_result/1
]).

%% Wire type ids (TType) and message envelope constants of the binary
%% protocol.

-define(STOP, 0).
-define(BOOL, 2).
-define(I8, 3).
-define(DOUBLE, 4).
-define(I16, 6).
-define(I32, 8).
-define(I64, 10).
-define(STRING, 11).
-define(STRUCT, 12).
-define(MAP, 13).
-define(SET, 14).
-define(LIST, 15).
-define(UUID, 16).

-define(VERSION_1, 16#80010000).

-type base_type() :: bool | i8 | i16 | i32 | i64 | double | string | binary | uuid.
-type requiredness() :: required | optional | default.
-type enum_desc() :: [{integer(), atom()}].
%% A struct descriptor is either the full `{Kind, Fields}` tuple or a
%% `{ref, Module, Name}` resolved through `Module:struct_info/1` — the
%% indirection keeps recursive descriptors finite.
-type struct_desc() :: {struct | union | exception, [field_desc()]} | {ref, module(), binary()}.
-type field_desc() :: {
    Id :: integer(),
    requiredness(),
    type_desc(),
    Name :: binary(),
    Default :: term()
}.
-type type_desc() ::
    {base, base_type()}
    | {enum, enum_desc()}
    | {list, type_desc()}
    | {set, type_desc()}
    | {set, type_desc(), set_impl()}
    | {map, type_desc(), type_desc()}
    | {struct, struct_desc()}.

%% The in-process representation a decoded set is built into. `list`
%% keeps the wire list as is; `sets`/`ordset` name the stdlib collection
%% the representation layer (`thrift_erl_record`) builds from it. This
%% codec — the wire layer — encodes and decodes lists regardless; the
%% third element only has to be tolerated here so generated descriptors
%% pass through.

-type set_impl() :: list | sets | ordset.

%% Generic struct representation: binary field names to values.

-type struct_value() :: #{binary() := term()}.

-type message_type() :: call | reply | exception | oneway.

-type application_exception() :: #{
    message := binary(),
    code := non_neg_integer(),
    name := binary()
}.

-type decode_result(Value) ::
    {ok, Value, binary()}
    | more
    | {error, term()}.

%% Compiled descriptors: the same schema with wire type bytes
%% precomputed. Every tag carries its wire byte in position 2; list,
%% set and map additionally carry the element wire bytes so container
%% headers need no type lookup.

-type c_type() ::
    {c_base, non_neg_integer(), base_type()}
    | {c_enum, non_neg_integer(), enum_desc()}
    | {c_list, non_neg_integer(), non_neg_integer(), c_type()}
    | {c_set, non_neg_integer(), non_neg_integer(), c_type()}
    | {c_map, non_neg_integer(), non_neg_integer(), non_neg_integer(), c_type(), c_type()}
    | {c_struct, non_neg_integer(), c_struct()}
    | {c_ref, non_neg_integer(), module(), binary()}.

%% A compiled struct: fields in declaration order for encoding, an id
%% index (with the wire byte folded in) for decoding, and the required
%% subset for both checks.
-type c_struct() :: #{
    kind := struct | union | exception,
    fields := [{Id :: integer(), Wire :: non_neg_integer(), Name :: binary(), c_type()}],
    by_id := #{integer() => {Wire :: non_neg_integer(), c_type(), Name :: binary()}},
    required := #{integer() => Name :: binary()},
    required_names := [binary()]
}.

%%--------------------------------------------------------------------
%% Values
%%--------------------------------------------------------------------

-doc "Encodes `Value` as `Type`, or fails with a tagged error.".
-spec encode(type_desc(), term()) -> {ok, iodata()} | {error, term()}.
encode({struct, {ref, Module, Name}} = Ref, Value) when is_map(Value) ->
    case resolve_struct(Module, Name) of
        {ok, Compiled} ->
            encode_struct_c(Compiled, Value);
        error ->
            {error, {encode, {unknown_struct, Ref}}}
    end;
encode({struct, {Kind, Fields}} = Desc, Value) when is_atom(Kind), is_list(Fields), is_map(Value) ->
    encode_struct_c(memo_compiled(Desc, Kind, Fields), Value);
encode({struct, _}, Value) ->
    {error, {encode, {value_does_not_match_type, Value}}};
encode(TypeDesc, Value) ->
    case compile_type(TypeDesc) of
        error ->
            {error, {encode, {value_does_not_match_type, Value}}};
        CType ->
            encode_c(CType, Value)
    end.

-doc """
Decodes a value of `Type` from the front of `Binary`.

Returns `{ok, Value, Rest}`, `more` when `Binary` is a truncated valid
encoding, or a tagged error.
""".
-spec decode(type_desc(), binary()) -> decode_result(term()).
decode({struct, {ref, Module, Name}}, Bin) when is_binary(Bin) ->
    decode_ref_struct(Module, Name, Bin);
decode({struct, {Kind, Fields}} = Desc, Bin) when is_atom(Kind), is_list(Fields), is_binary(Bin) ->
    decode_struct_c(memo_compiled(Desc, Kind, Fields), Bin);
decode(TypeDesc, Bin) when is_binary(Bin) ->
    case compile_type(TypeDesc) of
        error ->
            {error, {decode, bad_value}};
        CType ->
            decode_c(CType, Bin)
    end.

-spec encode_c(c_type(), term()) -> {ok, iodata()} | {error, term()}.
encode_c({c_base, _W, bool}, true) ->
    {ok, <<1>>};
encode_c({c_base, _W, bool}, false) ->
    {ok, <<0>>};
encode_c({c_base, _W, i8}, V) when is_integer(V), V >= -128, V =< 127 ->
    {ok, <<V:8/big-signed>>};
encode_c({c_base, _W, i16}, V) when is_integer(V), V >= -32768, V =< 32767 ->
    {ok, <<V:16/big-signed>>};
encode_c({c_base, _W, i32}, V) when is_integer(V), V >= -2147483648, V =< 2147483647 ->
    {ok, <<V:32/big-signed>>};
encode_c({c_base, _W, i64}, V) when
    is_integer(V), V >= -9223372036854775808, V =< 9223372036854775807
->
    {ok, <<V:64/big-signed>>};
encode_c({c_base, _W, double}, V) when is_number(V) ->
    {ok, <<(float(V)):64/big-float>>};
encode_c({c_base, _W, uuid}, V) when is_binary(V), byte_size(V) =:= 16 ->
    {ok, V};
encode_c({c_base, _W, string}, V) when is_binary(V) ->
    {ok, [int32(byte_size(V)), V]};
encode_c({c_base, _W, binary}, V) when is_binary(V) ->
    {ok, [int32(byte_size(V)), V]};
encode_c({c_enum, _W, Desc}, V) ->
    case enum_to_int(Desc, V) of
        {ok, Int} -> {ok, int32(Int)};
        error -> {error, {encode, {unknown_enum_value, V}}}
    end;
encode_c({c_list, _W, ElemW, CElem}, Values) when is_list(Values) ->
    encode_sequence_c(ElemW, CElem, Values);
encode_c({c_set, _W, ElemW, CElem}, Values) when is_list(Values) ->
    encode_sequence_c(ElemW, CElem, Values);
encode_c({c_map, _W, KeyW, ValW, CKey, CVal}, Value) when is_map(Value) ->
    encode_map_c(KeyW, ValW, CKey, CVal, Value);
encode_c({c_struct, _W, Compiled}, Value) when is_map(Value) ->
    encode_struct_c(Compiled, Value);
encode_c({c_ref, _W, Module, Name} = CRef, Value) when is_map(Value) ->
    case resolve_struct(Module, Name) of
        {ok, Compiled} ->
            encode_struct_c(Compiled, Value);
        error ->
            {error, {encode, {unknown_struct, c_ref_to_desc(CRef)}}}
    end;
encode_c(_Type, Value) ->
    {error, {encode, {value_does_not_match_type, Value}}}.

-spec decode_c(c_type(), binary()) -> decode_result(term()).
decode_c({c_base, _W, bool}, <<1, Rest/binary>>) ->
    {ok, true, Rest};
decode_c({c_base, _W, bool}, <<0, Rest/binary>>) ->
    {ok, false, Rest};
decode_c({c_base, _W, i8}, <<V:8/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode_c({c_base, _W, i16}, <<V:16/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode_c({c_base, _W, i32}, <<V:32/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode_c({c_base, _W, i64}, <<V:64/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode_c({c_base, _W, double}, <<V:64/big-float, Rest/binary>>) ->
    {ok, V, Rest};
decode_c({c_base, _W, uuid}, <<V:16/binary, Rest/binary>>) ->
    {ok, V, Rest};
decode_c({c_base, _W, S}, Bin) when S =:= string; S =:= binary ->
    decode_string(Bin);
decode_c({c_enum, _W, Desc}, Bin) ->
    case decode_i32(Bin) of
        {ok, Int, Rest} ->
            case enum_from_int(Desc, Int) of
                {ok, Atom} -> {ok, Atom, Rest};
                error -> {ok, Int, Rest}
            end;
        Other ->
            Other
    end;
decode_c({c_list, _W, ElemW, CElem}, Bin) ->
    decode_sequence_c(ElemW, CElem, Bin);
decode_c({c_set, _W, ElemW, CElem}, Bin) ->
    decode_sequence_c(ElemW, CElem, Bin);
decode_c({c_map, _W, KeyW, ValW, CKey, CVal}, Bin) ->
    decode_map_c(KeyW, ValW, CKey, CVal, Bin);
decode_c({c_struct, _W, Compiled}, Bin) ->
    decode_struct_c(Compiled, Bin);
decode_c({c_ref, _W, Module, Name}, Bin) ->
    decode_ref_struct(Module, Name, Bin);
%% Short fixed-size inputs ask for more bytes; anything else that fell
%% through is a value the declared type cannot produce.
decode_c({c_base, _W, B}, Bin) when is_binary(Bin) ->
    case byte_size(Bin) >= base_size(B) of
        true -> {error, {decode, {bad_value_for_base_type, B}}};
        false -> more
    end;
decode_c(_Type, Bin) when is_binary(Bin) ->
    {error, {decode, bad_value}}.

%%--------------------------------------------------------------------
%% Message envelope
%%--------------------------------------------------------------------

-doc """
Encodes a message envelope around `Payload` (already encoded as a
struct).

Always writes the strict format (version 1); `decode_message/1` also
reads the legacy headerless format.
""".
-spec encode_message(message_type(), binary(), non_neg_integer(), iodata()) -> iodata().
encode_message(Type, Name, SeqId, Payload) ->
    [
        <<(?VERSION_1 bor thrift_erl_protocol:message_type_id(Type)):32/big-unsigned>>,
        int32(byte_size(Name)),
        Name,
        int32(SeqId),
        Payload
    ].

-doc """
Decodes a message envelope.

Returns `{ok, Type, Name, SeqId, Tail}` where `Tail` is every byte
after the seqid (the struct payload plus anything that follows it),
`more`, or a tagged error. The payload length is not part of the
envelope, so the struct payload must be decoded from `Tail` and any
trailing bytes ignored.
""".
-spec decode_message(binary()) ->
    {ok, message_type(), binary(), non_neg_integer(), binary()}
    | more
    | {error, term()}.
decode_message(<<16#80, 1, 0, TypeByte, Rest/binary>>) ->
    maybe
        {ok, Type} ?= message_type_or(TypeByte),
        {ok, Name, Rest1} ?= decode_string(Rest),
        {ok, SeqId, Rest2} ?= decode_i32(Rest1),
        {ok, Type, Name, SeqId, Rest2}
    else
        {error, Reason} ->
            {error, Reason};
        more ->
            more
    end;
decode_message(<<Length:32/big-signed, _/binary>> = Bin) when Length >= 0 ->
    %% Legacy (pre-versioning) envelope: name string, type byte, seqid.
    maybe
        {ok, Name, Rest} ?= decode_string(Bin),
        PayloadAndRest ?= ensure(Rest, 5),
        <<TypeByte, SeqId:32/big-signed, Rest1/binary>> = PayloadAndRest,
        {ok, Type} ?= message_type_or(TypeByte),
        {ok, Type, Name, SeqId, Rest1}
    else
        {error, Reason} ->
            {error, Reason};
        more ->
            more
    end;
decode_message(<<Length:32/big-signed, _/binary>>) when Length < 0 ->
    {error, {decode, bad_envelope}};
decode_message(Bin) when byte_size(Bin) < 4 ->
    more;
decode_message(_) ->
    {error, {decode, bad_envelope}}.

%%--------------------------------------------------------------------
%% TApplicationException
%%--------------------------------------------------------------------

-doc """
Encodes `TApplicationException` as an EXCEPTION message payload.

Codes follow the Thrift specification: 0 unknown, 1 unknown method,
2 invalid message type, 3 wrong method name, 4 bad sequence id,
5 missing result, 6 internal error, 7 protocol error.
""".
-spec encode_application_exception(binary(), non_neg_integer()) ->
    {ok, iodata()} | {error, term()}.
encode_application_exception(Message, Code) ->
    encode(
        {struct, thrift_erl_protocol:application_exception_desc()},
        #{<<"message">> => Message, <<"code">> => Code}
    ).

-doc """
Decodes `TApplicationException` from an EXCEPTION message payload.

Unknown fields are skipped per the usual struct rules.
""".
-spec decode_application_exception(binary()) -> decode_result(application_exception()).
decode_application_exception(Bin) ->
    case decode({struct, thrift_erl_protocol:application_exception_desc()}, Bin) of
        {ok, #{<<"message">> := Message} = Map, Rest} ->
            {ok,
                #{
                    message => Message,
                    code => maps:get(<<"code">>, Map, 0),
                    name => thrift_erl_protocol:application_exception_name(maps:get(<<"code">>, Map, 0))
                },
                Rest};
        {ok, Map, Rest} ->
            {ok,
                #{
                    message => <<>>,
                    code => maps:get(<<"code">>, Map, 0),
                    name => thrift_erl_protocol:application_exception_name(maps:get(<<"code">>, Map, 0))
                },
                Rest};
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% Descriptor compilation
%%--------------------------------------------------------------------

-spec compile_type(type_desc()) -> c_type() | error.
compile_type({base, B}) ->
    case base_wire(B) of
        error -> error;
        W -> {c_base, W, B}
    end;
compile_type({enum, Desc}) ->
    {c_enum, ?I32, Desc};
compile_type({list, T}) ->
    case compile_type(T) of
        error -> error;
        CT -> {c_list, ?LIST, c_wire(CT), CT}
    end;
compile_type({set, T}) ->
    case compile_type(T) of
        error -> error;
        CT -> {c_set, ?SET, c_wire(CT), CT}
    end;
compile_type({set, T, _Impl}) ->
    compile_type({set, T});
compile_type({map, K, V}) ->
    case {compile_type(K), compile_type(V)} of
        {error, _} -> error;
        {_, error} -> error;
        {CK, CV} -> {c_map, ?MAP, c_wire(CK), c_wire(CV), CK, CV}
    end;
compile_type({struct, {ref, Module, Name}}) ->
    {c_ref, ?STRUCT, Module, Name};
compile_type({struct, {Kind, Fields}}) when is_atom(Kind), is_list(Fields) ->
    {c_struct, ?STRUCT, compile_struct(Kind, Fields)};
compile_type(_) ->
    error.

-spec c_wire(c_type() | error) -> non_neg_integer().
%% The `error` wire byte is unreachable on encode: a field whose type
%% failed to compile errors in `encode_c/2` before any header is built,
%% and on decode it only ever mismatches the observed wire byte.
c_wire(error) -> 0;
c_wire({c_base, W, _B}) -> W;
c_wire({c_enum, W, _D}) -> W;
c_wire({c_list, W, _EW, _E}) -> W;
c_wire({c_set, W, _EW, _E}) -> W;
c_wire({c_map, W, _KW, _VW, _K, _V}) -> W;
c_wire({c_struct, W, _C}) -> W;
c_wire({c_ref, W, _M, _N}) -> W.

-spec compile_struct(struct | union | exception, [field_desc()]) -> c_struct().
compile_struct(Kind, Fields) ->
    Compiled = [{Id, compile_type(T), Name} || {Id, _R, T, Name, _D} <- Fields],
    #{
        kind => Kind,
        fields => [{Id, c_wire(CT), Name, CT} || {Id, CT, Name} <- Compiled],
        by_id => #{Id => {c_wire(CT), CT, Name} || {Id, CT, Name} <- Compiled},
        required => #{Id => Name || {Id, required, _T, Name, _D} <- Fields},
        %% Declaration order, so `missing_required_fields` lists names
        %% the way the descriptor reads.
        required_names => [Name || {_Id, required, _T, Name, _D} <- Fields]
    }.

%% Resolves a `{ref, Module, Name}` schema, compiling it on first use.
%% The persistent_term cache is written once per schema; racing writers
%% put equal values. Generated types modules are static per load, so no
%% invalidation is needed — hot-swapping between incompatible versions
%% is not a supported scenario (see the moduledoc).
-spec resolve_struct(module(), binary()) -> {ok, c_struct()} | error.
resolve_struct(Module, Name) ->
    Key = {?MODULE, schema, Module, Name},
    case persistent_term:get(Key, error) of
        error ->
            case Module:struct_info(Name) of
                {Kind, Fields} when is_atom(Kind), is_list(Fields) ->
                    Compiled = compile_struct(Kind, Fields),
                    persistent_term:put(Key, Compiled),
                    {ok, Compiled};
                error ->
                    error
            end;
        Compiled ->
            {ok, Compiled}
    end.

-spec decode_ref_struct(module(), binary(), binary()) -> decode_result(struct_value()).
decode_ref_struct(Module, Name, Bin) ->
    case resolve_struct(Module, Name) of
        {ok, Compiled} ->
            decode_struct_c(Compiled, Bin);
        error ->
            {error, {decode, {unknown_struct, {Module, Name}}}}
    end.

%% Compiles an inline `{Kind, Fields}` descriptor (like the params
%% structs of `function_info/2`), memoized per process. Generated
%% `service_info/0` descriptors are literals — the same object on every
%% call — so the exact-equality scan short-circuits on pointer equality
%% and a hit costs nanoseconds; a miss compiles and inserts at the head
%% of a capped list, so pathological callers cannot grow the memo.
-define(MEMO_KEY, {?MODULE, compiled_structs}).
-define(MEMO_LIMIT, 8).

-spec memo_compiled(type_desc(), struct | union | exception, [field_desc()]) -> c_struct().
memo_compiled(Desc, Kind, Fields) ->
    case erlang:get(?MEMO_KEY) of
        undefined ->
            Compiled = compile_struct(Kind, Fields),
            erlang:put(?MEMO_KEY, [{Desc, Compiled}]),
            Compiled;
        Entries when is_list(Entries) ->
            case lists:keyfind(Desc, 1, Entries) of
                {_Desc, Compiled} ->
                    Compiled;
                false ->
                    Compiled = compile_struct(Kind, Fields),
                    erlang:put(?MEMO_KEY, lists:sublist([{Desc, Compiled} | Entries], ?MEMO_LIMIT)),
                    Compiled
            end;
        _ ->
            Compiled = compile_struct(Kind, Fields),
            erlang:put(?MEMO_KEY, [{Desc, Compiled}]),
            Compiled
    end.

-spec c_ref_to_desc(c_type()) -> type_desc().
c_ref_to_desc({c_ref, _W, Module, Name}) ->
    {struct, {ref, Module, Name}}.

%%--------------------------------------------------------------------
%% Structs
%%--------------------------------------------------------------------

-spec encode_struct_c(c_struct(), struct_value()) -> {ok, iodata()} | {error, term()}.
encode_struct_c(#{kind := Kind, fields := Fields, required_names := ReqNames}, Map) ->
    case check_present_fields(Kind, ReqNames, Fields, Map) of
        ok ->
            encode_fields_c(Fields, Map);
        {error, _} = Error ->
            Error
    end.

%% Builds the field chunks forward (no reversal): the recursion returns
%% the tail iodata and each field conses its `[header, value]` chunk in
%% front of it.
-spec encode_fields_c(
    [{integer(), non_neg_integer(), binary(), c_type()}], struct_value()
) -> {ok, iodata()} | {error, term()}.
encode_fields_c([], _Map) ->
    {ok, [?STOP]};
encode_fields_c([{Id, W, Name, CType} | Rest], Map) ->
    case Map of
        #{Name := Value} ->
            case encode_c(CType, Value) of
                {ok, Encoded} ->
                    case encode_fields_c(Rest, Map) of
                        {ok, RestIo} ->
                            {ok, [[<<W:8/big-unsigned, Id:16/big-signed>>, Encoded] | RestIo]};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            encode_fields_c(Rest, Map)
    end.

-spec check_present_fields(struct | union | exception, [binary()], [tuple()], struct_value()) ->
    ok | {error, term()}.
check_present_fields(union, _ReqNames, Fields, Map) ->
    Present = [Name || {_, _, Name, _CT} <- Fields, maps:is_key(Name, Map)],
    case length(Present) of
        1 -> ok;
        0 -> {error, {encode, union_empty}};
        _ -> {error, {encode, union_multiple}}
    end;
check_present_fields(_Kind, ReqNames, _Fields, Map) ->
    %% Fast path walks the (usually empty) required list with early
    %% exit; the full missing list is only built on the error path.
    case all_present(ReqNames, Map) of
        true ->
            ok;
        false ->
            Missing = [Name || Name <- ReqNames, not maps:is_key(Name, Map)],
            {error, {encode, {missing_required_fields, Missing}}}
    end.

-spec all_present([binary()], struct_value()) -> boolean().
all_present([], _Map) ->
    true;
all_present([Name | Rest], Map) ->
    case Map of
        #{Name := _} -> all_present(Rest, Map);
        #{} -> false
    end.

-spec decode_struct_c(c_struct(), binary()) -> decode_result(struct_value()).
decode_struct_c(#{by_id := ById, required := Required}, Bin) ->
    decode_struct_fields_c(ById, Required, Bin, #{}).

-spec decode_struct_fields_c(
    #{integer() => {non_neg_integer(), c_type(), binary()}}, #{integer() => binary()}, binary(), struct_value()
) ->
    decode_result(struct_value()).
decode_struct_fields_c(_ById, Required, <<?STOP, Rest/binary>>, Acc) ->
    case maps:values(Required) of
        [] -> {ok, Acc, Rest};
        Missing -> {error, {decode, {missing_required_fields, Missing}}}
    end;
decode_struct_fields_c(ById, Required, <<TypeByte:8/big-unsigned, Id:16/big-signed, Rest/binary>>, Acc) ->
    case ById of
        %% The stored wire byte unifies against TypeByte, so one map
        %% lookup settles both the id and the type check.
        #{Id := {TypeByte, CType, Name}} ->
            case decode_c(CType, Rest) of
                {ok, Value, Rest1} ->
                    Required1 =
                        case Required of
                            #{Id := _} -> maps:remove(Id, Required);
                            #{} -> Required
                        end,
                    decode_struct_fields_c(ById, Required1, Rest1, Acc#{Name => Value});
                more ->
                    more;
                {error, _} = Error ->
                    Error
            end;
        #{Id := _OtherWire} ->
            {error, {decode, {field_type_mismatch, Id}}};
        #{} ->
            case skip_by_wire(TypeByte, Rest) of
                {ok, Rest1} -> decode_struct_fields_c(ById, Required, Rest1, Acc);
                more -> more;
                {error, _} = Error -> Error
            end
    end;
decode_struct_fields_c(_ById, _Required, Bin, _Acc) when byte_size(Bin) < 3 ->
    more.

%%--------------------------------------------------------------------
%% Containers
%%--------------------------------------------------------------------

-spec encode_sequence_c(non_neg_integer(), c_type(), [term()]) -> {ok, iodata()} | {error, term()}.
encode_sequence_c(ElemW, CElem, Values) ->
    case encode_elements_c(CElem, Values) of
        {ok, Encoded} ->
            {ok, [[<<ElemW:8/big-unsigned>>, int32(length(Values))], Encoded]};
        Error ->
            Error
    end.

-spec encode_elements_c(c_type(), [term()]) -> {ok, iodata()} | {error, term()}.
encode_elements_c(_CElem, []) ->
    {ok, []};
encode_elements_c(CElem, [V | Rest]) ->
    case encode_c(CElem, V) of
        {ok, Encoded} ->
            case encode_elements_c(CElem, Rest) of
                {ok, RestIo} -> {ok, [Encoded | RestIo]};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec encode_map_c(non_neg_integer(), non_neg_integer(), c_type(), c_type(), map()) ->
    {ok, iodata()} | {error, term()}.
encode_map_c(KeyW, ValW, CKey, CVal, Value) ->
    case encoded_pairs_c(CKey, CVal, maps:to_list(Value)) of
        {ok, Pairs} ->
            Sorted = lists:sort(fun({KE, _}, {KE1, _}) -> KE =< KE1 end, Pairs),
            {ok, [
                [<<KeyW:8/big-unsigned, ValW:8/big-unsigned>>, int32(length(Sorted))],
                [[KE, VE] || {KE, VE} <- Sorted]
            ]};
        Error ->
            Error
    end.

-spec encoded_pairs_c(c_type(), c_type(), [{term(), term()}]) ->
    {ok, [{iodata(), iodata()}]} | {error, term()}.
encoded_pairs_c(_CKey, _CVal, []) ->
    {ok, []};
encoded_pairs_c(CKey, CVal, [{K, V} | Rest]) ->
    maybe
        {ok, KE} ?= encode_c(CKey, K),
        {ok, VE} ?= encode_c(CVal, V),
        case encoded_pairs_c(CKey, CVal, Rest) of
            {ok, RestPairs} -> {ok, [{KE, VE} | RestPairs]};
            {error, _} = Error -> Error
        end
    else
        {error, Reason} ->
            {error, Reason}
    end.

-spec decode_sequence_c(non_neg_integer(), c_type(), binary()) -> decode_result([term()]).
decode_sequence_c(_ElemW, _CElem, <<_, Size:32/big-signed, _/binary>>) when Size < 0 ->
    {error, {decode, bad_sequence_size}};
decode_sequence_c(ElemW, CElem, <<ElemW:8/big-unsigned, Size:32/big-signed, Rest/binary>>) when Size >= 0 ->
    decode_elements_c(CElem, Size, Rest, []);
decode_sequence_c(_ElemW, _CElem, <<TypeByte:8/big-unsigned, _:32/big-signed, _/binary>>) ->
    {error, {decode, {element_type_mismatch, TypeByte}}};
decode_sequence_c(_ElemW, _CElem, Bin) when byte_size(Bin) < 5 ->
    more.

-spec decode_elements_c(c_type(), non_neg_integer(), binary(), [term()]) ->
    decode_result([term()]).
decode_elements_c(_CElem, 0, Rest, Acc) ->
    {ok, lists:reverse(Acc), Rest};
decode_elements_c(CElem, N, Bin, Acc) ->
    case decode_c(CElem, Bin) of
        {ok, Value, Rest} -> decode_elements_c(CElem, N - 1, Rest, [Value | Acc]);
        Other -> Other
    end.

-spec decode_map_c(non_neg_integer(), non_neg_integer(), c_type(), c_type(), binary()) ->
    decode_result(map()).
decode_map_c(
    _KeyW, _ValW, _CKey, _CVal, <<_, _, Size:32/big-signed, _/binary>>
) when Size < 0 ->
    {error, {decode, bad_map_size}};
decode_map_c(
    KeyW, ValW, CKey, CVal, <<KeyW:8/big-unsigned, ValW:8/big-unsigned, Size:32/big-signed, Rest/binary>>
) when Size >= 0 ->
    decode_pairs_c(CKey, CVal, Size, Rest, #{});
decode_map_c(_KeyW, _ValW, _CKey, _CVal, <<_, _, _:32/big-signed, _/binary>>) ->
    {error, {decode, map_type_mismatch}};
decode_map_c(_KeyW, _ValW, _CKey, _CVal, Bin) when byte_size(Bin) < 6 ->
    more.

-spec decode_pairs_c(c_type(), c_type(), non_neg_integer(), binary(), map()) ->
    decode_result(map()).
decode_pairs_c(_CKey, _CVal, 0, Rest, Acc) ->
    {ok, Acc, Rest};
decode_pairs_c(CKey, CVal, N, Bin, Acc) ->
    case decode_c(CKey, Bin) of
        {ok, K, Rest} ->
            case decode_c(CVal, Rest) of
                {ok, V, Rest1} -> decode_pairs_c(CKey, CVal, N - 1, Rest1, Acc#{K => V});
                Other -> Other
            end;
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% Wire-type skipping (forward compatibility)
%%--------------------------------------------------------------------

%% Skips a value of a raw wire type, used for struct fields with ids the
%% descriptor does not know.

-spec skip_by_wire(non_neg_integer(), binary()) -> {ok, binary()} | more | {error, term()}.
skip_by_wire(?BOOL, <<_, Rest/binary>>) ->
    {ok, Rest};
skip_by_wire(?I8, <<_, Rest/binary>>) ->
    {ok, Rest};
skip_by_wire(?I16, <<_:2/binary, Rest/binary>>) ->
    {ok, Rest};
skip_by_wire(?I32, <<_:4/binary, Rest/binary>>) ->
    {ok, Rest};
skip_by_wire(?I64, <<_:8/binary, Rest/binary>>) ->
    {ok, Rest};
skip_by_wire(?DOUBLE, <<_:8/binary, Rest/binary>>) ->
    {ok, Rest};
skip_by_wire(?UUID, <<_:16/binary, Rest/binary>>) ->
    {ok, Rest};
skip_by_wire(?STRING, Bin) ->
    case decode_string(Bin) of
        {ok, _, Rest} -> {ok, Rest};
        Other -> Other
    end;
skip_by_wire(?STRUCT, Bin) ->
    skip_struct(Bin);
skip_by_wire(?MAP, <<KeyType:8/big-unsigned, ValType:8/big-unsigned, Size:32/big-signed, Rest/binary>>) when
    Size >= 0
->
    skip_pairs(KeyType, ValType, Size, Rest);
skip_by_wire(?MAP, Bin) when byte_size(Bin) < 6 ->
    more;
skip_by_wire(Type, <<ElemType:8/big-unsigned, Size:32/big-signed, Rest/binary>>) when
    (Type =:= ?LIST orelse Type =:= ?SET) andalso Size >= 0
->
    skip_elements(ElemType, Size, Rest);
skip_by_wire(Type, <<_, _:32/big-signed, _/binary>>) when Type =:= ?LIST orelse Type =:= ?SET ->
    {error, {decode, bad_sequence_size}};
skip_by_wire(Type, Bin) when (Type =:= ?LIST orelse Type =:= ?SET), byte_size(Bin) < 5 ->
    more;
skip_by_wire(TypeByte, _) ->
    {error, {decode, {unknown_wire_type, TypeByte}}}.

-spec skip_struct(binary()) -> {ok, binary()} | more | {error, term()}.
skip_struct(<<?STOP, Rest/binary>>) ->
    {ok, Rest};
skip_struct(<<TypeByte:8/big-unsigned, _:16/big-signed, Rest/binary>>) ->
    case skip_by_wire(TypeByte, Rest) of
        {ok, Rest1} -> skip_struct(Rest1);
        Other -> Other
    end;
skip_struct(Bin) when byte_size(Bin) < 3 ->
    more.

-spec skip_pairs(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary()) ->
    {ok, binary()} | more | {error, term()}.
skip_pairs(_Key, _Val, 0, Rest) ->
    {ok, Rest};
skip_pairs(Key, Val, N, Bin) ->
    case skip_by_wire(Key, Bin) of
        {ok, Rest} ->
            case skip_by_wire(Val, Rest) of
                {ok, Rest1} -> skip_pairs(Key, Val, N - 1, Rest1);
                Other -> Other
            end;
        Other ->
            Other
    end.

-spec skip_elements(non_neg_integer(), non_neg_integer(), binary()) ->
    {ok, binary()} | more | {error, term()}.
skip_elements(_Elem, 0, Rest) ->
    {ok, Rest};
skip_elements(Elem, N, Bin) ->
    case skip_by_wire(Elem, Bin) of
        {ok, Rest} -> skip_elements(Elem, N - 1, Rest);
        Other -> Other
    end.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

-spec decode_string(binary()) -> decode_result(binary()).
decode_string(<<Length:32/big-signed, _/binary>> = Bin) when Length >= 0, byte_size(Bin) >= 4 + Length ->
    <<_:4/binary, V:Length/binary, Rest/binary>> = Bin,
    {ok, V, Rest};
decode_string(<<Length:32/big-signed, _/binary>>) when Length >= 0 ->
    more;
decode_string(Bin) when byte_size(Bin) < 4 ->
    more;
decode_string(_) ->
    {error, {decode, bad_string_length}}.

-spec decode_i32(binary()) -> decode_result(integer()).
decode_i32(<<V:32/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode_i32(Bin) when byte_size(Bin) < 4 ->
    more.

-spec ensure(binary(), non_neg_integer()) -> binary() | more.
ensure(Bin, N) when byte_size(Bin) >= N ->
    Bin;
ensure(_Bin, _N) ->
    more.

-spec int32(integer()) -> binary().
int32(N) ->
    <<N:32/big-signed>>.

-spec base_size(base_type()) -> non_neg_integer().
base_size(bool) -> 1;
base_size(i8) -> 1;
base_size(i16) -> 2;
base_size(i32) -> 4;
base_size(i64) -> 8;
base_size(double) -> 8;
base_size(uuid) -> 16;
base_size(string) -> 0;
base_size(binary) -> 0.

%% Total counterpart of `type_id/1` for compilation: an unknown base
%% name yields `error` so the codec reports it as a value/type mismatch
%% instead of crashing.
-spec base_wire(base_type() | term()) -> non_neg_integer() | error.
base_wire(bool) -> ?BOOL;
base_wire(i8) -> ?I8;
base_wire(i16) -> ?I16;
base_wire(i32) -> ?I32;
base_wire(i64) -> ?I64;
base_wire(double) -> ?DOUBLE;
base_wire(uuid) -> ?UUID;
base_wire(string) -> ?STRING;
base_wire(binary) -> ?STRING;
base_wire(_) -> error.

-spec type_id(type_desc()) -> non_neg_integer().
type_id({base, bool}) -> ?BOOL;
type_id({base, i8}) -> ?I8;
type_id({base, i16}) -> ?I16;
type_id({base, i32}) -> ?I32;
type_id({base, i64}) -> ?I64;
type_id({base, double}) -> ?DOUBLE;
type_id({base, uuid}) -> ?UUID;
type_id({base, S}) when S =:= string; S =:= binary -> ?STRING;
type_id({enum, _}) -> ?I32;
type_id({list, _}) -> ?LIST;
type_id({set, _}) -> ?SET;
type_id({set, _, _}) -> ?SET;
type_id({map, _, _}) -> ?MAP;
type_id({struct, _}) -> ?STRUCT.

-doc """
Returns the field descriptors of a struct type descriptor
(`{struct, {Kind, Fields}}`), resolving `{struct, {ref, M, N}}`
through `M:struct_info/1`.
""".
-spec struct_fields(type_desc()) -> [field_desc()].
struct_fields({struct, {ref, Module, Name}}) ->
    {_, Fields} = Module:struct_info(Name),
    Fields;
struct_fields({struct, {_Kind, Fields}}) ->
    Fields.

-spec message_type(non_neg_integer()) -> {ok, message_type()} | error.
message_type(1) -> {ok, call};
message_type(2) -> {ok, reply};
message_type(3) -> {ok, exception};
message_type(4) -> {ok, oneway};
message_type(_) -> error.

-spec message_type_or(non_neg_integer()) -> {ok, message_type()} | {error, term()}.
message_type_or(TypeByte) ->
    case message_type(TypeByte) of
        {ok, Type} -> {ok, Type};
        error -> {error, {decode, {unknown_message_type, TypeByte}}}
    end.

-spec enum_to_int(enum_desc(), atom() | integer()) -> {ok, integer()} | error.
enum_to_int(Desc, V) when is_atom(V) ->
    case lists:keyfind(V, 2, Desc) of
        {Int, V} -> {ok, Int};
        false -> error
    end;
enum_to_int(_Desc, V) when is_integer(V) ->
    {ok, V}.

-spec enum_from_int(enum_desc(), integer()) -> {ok, atom()} | error.
enum_from_int(Desc, Int) ->
    case lists:keyfind(Int, 1, Desc) of
        {Int, Atom} -> {ok, Atom};
        false -> error
    end.
