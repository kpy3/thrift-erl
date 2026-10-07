%% Copyright 2025 Sergei Yelin
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

-export_type([
    base_type/0,
    type_desc/0,
    field_desc/0,
    struct_desc/0,
    enum_desc/0,
    struct_value/0,
    message_type/0,
    application_exception/0
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
    | {map, type_desc(), type_desc()}
    | {struct, struct_desc()}.

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

%%--------------------------------------------------------------------
%% Values
%%--------------------------------------------------------------------

-doc "Encodes `Value` as `Type`, or fails with a tagged error.".
-spec encode(type_desc(), term()) -> {ok, iodata()} | {error, term()}.
encode({base, bool}, true) ->
    {ok, <<1>>};
encode({base, bool}, false) ->
    {ok, <<0>>};
encode({base, i8}, V) when is_integer(V), V >= -128, V =< 127 ->
    {ok, <<V:8/big-signed>>};
encode({base, i16}, V) when is_integer(V), V >= -32768, V =< 32767 ->
    {ok, <<V:16/big-signed>>};
encode({base, i32}, V) when is_integer(V), V >= -2147483648, V =< 2147483647 ->
    {ok, <<V:32/big-signed>>};
encode({base, i64}, V) when is_integer(V), V >= -9223372036854775808, V =< 9223372036854775807 ->
    {ok, <<V:64/big-signed>>};
encode({base, double}, V) when is_number(V) ->
    {ok, <<(float(V)):64/big-float>>};
encode({base, uuid}, V) when is_binary(V), byte_size(V) =:= 16 ->
    {ok, V};
encode({base, string}, V) when is_binary(V) ->
    {ok, [int32(byte_size(V)), V]};
encode({base, binary}, V) when is_binary(V) ->
    {ok, [int32(byte_size(V)), V]};
encode({enum, Desc}, V) ->
    case enum_to_int(Desc, V) of
        {ok, Int} -> encode({base, i32}, Int);
        error -> {error, {encode, {unknown_enum_value, V}}}
    end;
encode({list, Elem}, Values) when is_list(Values) ->
    encode_sequence(Elem, Values);
encode({set, Elem}, Values) when is_list(Values) ->
    encode_sequence(Elem, Values);
encode({map, Key, Val}, Value) when is_map(Value) ->
    encode_map(Key, Val, Value);
encode({struct, {ref, Module, Name}} = Ref, Value) when is_map(Value) ->
    case Module:struct_info(Name) of
        {Kind, Fields} when is_atom(Kind), is_list(Fields) ->
            encode({struct, {Kind, Fields}}, Value);
        error ->
            {error, {encode, {unknown_struct, Ref}}}
    end;
encode({struct, Desc}, Value) when is_map(Value) ->
    encode_struct(Desc, Value);
encode(_Type, Value) ->
    {error, {encode, {value_does_not_match_type, Value}}}.

-doc """
Decodes a value of `Type` from the front of `Binary`.

Returns `{ok, Value, Rest}`, `more` when `Binary` is a truncated valid
encoding, or a tagged error.
""".
-spec decode(type_desc(), binary()) -> decode_result(term()).
decode({base, bool}, <<1, Rest/binary>>) ->
    {ok, true, Rest};
decode({base, bool}, <<0, Rest/binary>>) ->
    {ok, false, Rest};
decode({base, i8}, <<V:8/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode({base, i16}, <<V:16/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode({base, i32}, <<V:32/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode({base, i64}, <<V:64/big-signed, Rest/binary>>) ->
    {ok, V, Rest};
decode({base, double}, <<V:64/big-float, Rest/binary>>) ->
    {ok, V, Rest};
decode({base, uuid}, <<V:16/binary, Rest/binary>>) ->
    {ok, V, Rest};
decode({base, S}, Bin) when S =:= string; S =:= binary ->
    decode_string(Bin);
decode({enum, Desc}, Bin) ->
    case decode({base, i32}, Bin) of
        {ok, Int, Rest} ->
            case enum_from_int(Desc, Int) of
                {ok, Atom} -> {ok, Atom, Rest};
                error -> {ok, Int, Rest}
            end;
        Other ->
            Other
    end;
decode({list, Elem}, Bin) ->
    decode_sequence(Elem, Bin);
decode({set, Elem}, Bin) ->
    decode_sequence(Elem, Bin);
decode({map, Key, Val}, Bin) ->
    decode_map(Key, Val, Bin);
decode({struct, {ref, Module, Name}}, Bin) ->
    case Module:struct_info(Name) of
        {Kind, Fields} when is_atom(Kind), is_list(Fields) ->
            decode({struct, {Kind, Fields}}, Bin);
        error ->
            {error, {decode, {unknown_struct, {Module, Name}}}}
    end;
decode({struct, Desc}, Bin) ->
    decode_struct(Desc, Bin);
%% Short fixed-size inputs ask for more bytes; anything else that fell
%% through is a value the declared type cannot produce.
decode({base, B}, Bin) when is_binary(Bin) ->
    case byte_size(Bin) >= base_size(B) of
        true -> {error, {decode, {bad_value_for_base_type, B}}};
        false -> more
    end;
decode(_Type, Bin) when is_binary(Bin) ->
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
        <<(?VERSION_1 bor message_type_id(Type)):32/big-unsigned>>,
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
        {struct, application_exception_desc()},
        #{<<"message">> => Message, <<"code">> => Code}
    ).

-doc """
Decodes `TApplicationException` from an EXCEPTION message payload.

Unknown fields are skipped per the usual struct rules.
""".
-spec decode_application_exception(binary()) -> decode_result(application_exception()).
decode_application_exception(Bin) ->
    case decode({struct, application_exception_desc()}, Bin) of
        {ok, #{<<"message">> := Message} = Map, Rest} ->
            {ok,
                #{
                    message => Message,
                    code => maps:get(<<"code">>, Map, 0),
                    name => application_exception_name(maps:get(<<"code">>, Map, 0))
                },
                Rest};
        {ok, Map, Rest} ->
            {ok,
                #{
                    message => <<>>,
                    code => maps:get(<<"code">>, Map, 0),
                    name => application_exception_name(maps:get(<<"code">>, Map, 0))
                },
                Rest};
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% Structs
%%--------------------------------------------------------------------

-spec encode_struct(struct_desc(), struct_value()) -> {ok, iodata()} | {error, term()}.
encode_struct({Kind, Fields}, Map) ->
    case check_present_fields(Kind, Fields, Map) of
        ok ->
            encode_fields(Fields, Map, []);
        {error, _} = Error ->
            Error
    end.

-spec encode_fields([field_desc()], struct_value(), [iodata()]) -> {ok, iodata()} | {error, term()}.
encode_fields([], _Map, Acc) ->
    {ok, [lists:reverse(Acc), ?STOP]};
encode_fields([{Id, _Required, Type, Name, _Default} | Rest], Map, Acc) ->
    case Map of
        #{Name := Value} ->
            case encode(Type, Value) of
                {ok, Encoded} ->
                    Header = <<(type_id(Type)):8/big-unsigned, Id:16/big-signed>>,
                    encode_fields(Rest, Map, [Encoded, Header | Acc]);
                Error ->
                    Error
            end;
        _ ->
            encode_fields(Rest, Map, Acc)
    end.

-spec check_present_fields(struct | union | exception, [field_desc()], struct_value()) ->
    ok | {error, term()}.
check_present_fields(union, Fields, Map) ->
    Present = [Name || {_, _, _, Name, _} <- Fields, maps:is_key(Name, Map)],
    case length(Present) of
        1 -> ok;
        0 -> {error, {encode, union_empty}};
        _ -> {error, {encode, union_multiple}}
    end;
check_present_fields(_Kind, Fields, Map) ->
    Missing = [Name || {_, required, _, Name, _} <- Fields, not maps:is_key(Name, Map)],
    case Missing of
        [] -> ok;
        _ -> {error, {encode, {missing_required_fields, Missing}}}
    end.

-spec decode_struct(struct_desc(), binary()) -> decode_result(struct_value()).
decode_struct(Desc, Bin) ->
    decode_struct_fields(Desc, Bin, required_fields(Desc), #{}).

-type required_map() :: #{integer() => {binary(), type_desc()}}.

-spec decode_struct_fields(struct_desc(), binary(), required_map(), struct_value()) ->
    decode_result(struct_value()).
decode_struct_fields(_Desc, <<?STOP, Rest/binary>>, Required, Acc) ->
    Missing = [Name || {Name, _} <- maps:values(Required)],
    case Missing of
        [] -> {ok, Acc, Rest};
        _ -> {error, {decode, {missing_required_fields, Missing}}}
    end;
decode_struct_fields(Desc, <<TypeByte:8/big-unsigned, Id:16/big-signed, Rest/binary>>, Required, Acc) ->
    case field_desc_for(Desc, Id) of
        {ok, {_, _, Type, Name, _Default}} ->
            case wire_type_id(Type) of
                TypeByte ->
                    case decode(Type, Rest) of
                        {ok, Value, Rest1} ->
                            decode_struct_fields(Desc, Rest1, maps:remove(Id, Required), Acc#{Name => Value});
                        more ->
                            more;
                        {error, _} = Error ->
                            Error
                    end;
                _ ->
                    {error, {decode, {field_type_mismatch, Id}}}
            end;
        error ->
            case skip_by_wire(TypeByte, Rest) of
                {ok, Rest1} -> decode_struct_fields(Desc, Rest1, Required, Acc);
                more -> more;
                {error, _} = Error -> Error
            end
    end;
decode_struct_fields(_Desc, Bin, _Required, _Acc) when byte_size(Bin) < 3 ->
    more.

-spec required_fields(struct_desc()) -> required_map().
required_fields({_, Fields}) ->
    maps:from_list([
        {Id, {Name, Type}}
     || {Id, required, Type, Name, _} <- Fields
    ]).

-spec field_desc_for(struct_desc(), integer()) -> {ok, field_desc()} | error.
field_desc_for({_, Fields}, Id) ->
    case lists:keyfind(Id, 1, Fields) of
        false -> error;
        Field -> {ok, Field}
    end.

%%--------------------------------------------------------------------
%% Containers
%%--------------------------------------------------------------------

-spec encode_sequence(type_desc(), [term()]) -> {ok, iodata()} | {error, term()}.
encode_sequence(Elem, Values) ->
    case encode_elements(Elem, Values, []) of
        {ok, Encoded} ->
            {ok, [[<<(type_id(Elem)):8/big-unsigned>>, int32(length(Values))], Encoded]};
        Error ->
            Error
    end.

-spec encode_elements(type_desc(), [term()], [iodata()]) -> {ok, iodata()} | {error, term()}.
encode_elements(_Elem, [], Acc) ->
    {ok, lists:reverse(Acc)};
encode_elements(Elem, [V | Rest], Acc) ->
    case encode(Elem, V) of
        {ok, Encoded} -> encode_elements(Elem, Rest, [Encoded | Acc]);
        Error -> Error
    end.

-spec encode_map(type_desc(), type_desc(), map()) -> {ok, iodata()} | {error, term()}.
encode_map(Key, Val, Value) ->
    case encoded_pairs(Key, Val, maps:to_list(Value), []) of
        {ok, Pairs} ->
            Sorted = lists:sort(fun({KE, _}, {KE1, _}) -> KE =< KE1 end, Pairs),
            {ok, [
                [<<(type_id(Key)):8/big-unsigned, (type_id(Val)):8/big-unsigned>>, int32(length(Sorted))],
                [[KE, VE] || {KE, VE} <- Sorted]
            ]};
        Error ->
            Error
    end.

-spec encoded_pairs(
    type_desc(), type_desc(), [{term(), term()}], [{iodata(), iodata()}]
) -> {ok, [{iodata(), iodata()}]} | {error, term()}.
encoded_pairs(_Key, _Val, [], Acc) ->
    {ok, lists:reverse(Acc)};
encoded_pairs(Key, Val, [{K, V} | Rest], Acc) ->
    maybe
        {ok, KE} ?= encode(Key, K),
        {ok, VE} ?= encode(Val, V),
        encoded_pairs(Key, Val, Rest, [{KE, VE} | Acc])
    else
        {error, Reason} ->
            {error, Reason}
    end.

-spec decode_sequence(type_desc(), binary()) -> decode_result([term()]).
decode_sequence(Elem, <<TypeByte:8/big-unsigned, Size:32/big-signed, Rest/binary>>) when Size >= 0 ->
    case wire_type_id(Elem) of
        TypeByte ->
            decode_elements(Elem, Size, Rest, []);
        _ ->
            {error, {decode, {element_type_mismatch, TypeByte}}}
    end;
decode_sequence(_Elem, <<_, _:32/big-signed, _/binary>>) ->
    {error, {decode, bad_sequence_size}};
decode_sequence(_Elem, Bin) when byte_size(Bin) < 5 ->
    more.
-spec decode_elements(type_desc(), non_neg_integer(), binary(), [term()]) -> decode_result([term()]).
decode_elements(_Elem, 0, Rest, Acc) ->
    {ok, lists:reverse(Acc), Rest};
decode_elements(Elem, N, Bin, Acc) ->
    case decode(Elem, Bin) of
        {ok, Value, Rest} -> decode_elements(Elem, N - 1, Rest, [Value | Acc]);
        Other -> Other
    end.

-spec decode_map(type_desc(), type_desc(), binary()) -> decode_result(map()).
decode_map(Key, Val, <<KeyTypeByte:8/big-unsigned, ValTypeByte:8/big-unsigned, Size:32/big-signed, Rest/binary>>) when
    Size >= 0
->
    case {wire_type_id(Key), wire_type_id(Val)} of
        {KeyTypeByte, ValTypeByte} ->
            decode_pairs(Key, Val, Size, Rest, #{});
        _ ->
            {error, {decode, map_type_mismatch}}
    end;
decode_map(_Key, _Val, <<_, _, _:32/big-signed, _/binary>>) ->
    {error, {decode, bad_map_size}};
decode_map(_Key, _Val, Bin) when byte_size(Bin) < 6 ->
    more.

-spec decode_pairs(type_desc(), type_desc(), non_neg_integer(), binary(), map()) -> decode_result(map()).
decode_pairs(_Key, _Val, 0, Rest, Acc) ->
    {ok, Acc, Rest};
decode_pairs(Key, Val, N, Bin, Acc) ->
    case decode(Key, Bin) of
        {ok, K, Rest} ->
            case decode(Val, Rest) of
                {ok, V, Rest1} -> decode_pairs(Key, Val, N - 1, Rest1, Acc#{K => V});
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

-spec wire_type_id(type_desc()) -> non_neg_integer().
wire_type_id(Type) ->
    type_id(Type).

-spec message_type_id(message_type()) -> non_neg_integer().
message_type_id(call) -> 1;
message_type_id(reply) -> 2;
message_type_id(exception) -> 3;
message_type_id(oneway) -> 4.

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

-spec application_exception_desc() -> struct_desc().
application_exception_desc() ->
    {exception, [
        {1, default, {base, string}, <<"message">>, undefined},
        {2, default, {base, i32}, <<"code">>, undefined}
    ]}.

-spec application_exception_name(non_neg_integer()) -> binary().
application_exception_name(0) -> <<"UNKNOWN">>;
application_exception_name(1) -> <<"UNKNOWN_METHOD">>;
application_exception_name(2) -> <<"INVALID_MESSAGE_TYPE">>;
application_exception_name(3) -> <<"WRONG_METHOD_NAME">>;
application_exception_name(4) -> <<"BAD_SEQUENCE_ID">>;
application_exception_name(5) -> <<"MISSING_RESULT">>;
application_exception_name(6) -> <<"INTERNAL_ERROR">>;
application_exception_name(7) -> <<"PROTOCOL_ERROR">>;
application_exception_name(_) -> <<"UNKNOWN">>.

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
