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

-module(thrift_erl_props).

-moduledoc """
PropEr properties for the generic binary codec.

Each property is wrapped in `proper:quickcheck` so `rebar3 eunit` runs
them without an extra plugin. On failure the property is re-run with
PropEr's output enabled, which prints the shrunk counterexample.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% The module doubles as the `{ref, Module, Name}` target so the
%% indirection property exercises `Module:struct_info/1` for real.
-export([struct_info/1]).

-define(ENUM_DESC, [{0, red}, {1, green}, {2, blue}, {-7, weird}]).
-define(NUMTESTS, 300).

%%--------------------------------------------------------------------
%% Generators
%%--------------------------------------------------------------------

uuid() ->
    ?LET(Bytes, vector(16, byte()), list_to_binary(Bytes)).

base_type_value() ->
    oneof([
        {{base, bool}, oneof([true, false])},
        {{base, i8}, integer(-128, 127)},
        {{base, i16}, integer(-32768, 32767)},
        {{base, i32}, integer(-2147483648, 2147483647)},
        {{base, i64}, integer(-9223372036854775808, 9223372036854775807)},
        {{base, double}, float()},
        {{base, string}, binary()},
        {{base, binary}, binary()},
        {{base, uuid}, uuid()},
        {{enum, ?ENUM_DESC}, oneof([red, green, blue, weird])}
    ]).

type_value() ->
    ?SIZED(Size, type_value(Size)).

type_value(Size) when Size =< 1 ->
    base_type_value();
type_value(Size) ->
    frequency([
        {6, base_type_value()},
        {2, ?LET({T, V}, type_value(Size div 2), {{list, T}, list(V)})},
        {2, ?LET({T, V}, type_value(Size div 2), {{set, T}, list(V)})},
        {2,
            ?LET(
                {{KT, KV}, {VT, VV}},
                {type_value(Size div 2), type_value(Size div 2)},
                {{map, KT, VT}, map(KV, VV)}
            )},
        {2, struct_tv(Size)}
    ]).

struct_tv(Size) ->
    ?LET(
        TVs,
        vector(3, type_value(Size div 2)),
        begin
            Fields = field_descs(1, TVs),
            Value = maps:from_list(field_values(1, TVs)),
            {{struct, {struct, Fields}}, Value}
        end
    ).

field_descs(_I, []) ->
    [];
field_descs(I, [{T, _} | Rest]) ->
    [{I * 7, default, T, field_name(I), undefined} | field_descs(I + 1, Rest)].

field_values(_I, []) ->
    [];
field_values(I, [{_, V} | Rest]) ->
    [{field_name(I), V} | field_values(I + 1, Rest)].

field_name(I) ->
    <<"f", (integer_to_binary(I))/binary>>.

message_type_value() ->
    oneof([call, reply, exception, oneway]).

%%--------------------------------------------------------------------
%% Properties
%%--------------------------------------------------------------------

%% encode -> decode is the identity on the generic representation for
%% every type descriptor the generator can build (nested containers and
%% structs included).
prop_roundtrip() ->
    ?FORALL({T, V}, type_value(), roundtrip_ok(T, V)).

roundtrip_ok(T, V) ->
    case thrift_erl_binary:encode(T, V) of
        {ok, Encoded} ->
            case thrift_erl_binary:decode(T, iolist_to_binary(Encoded)) of
                {ok, V, <<>>} ->
                    true;
                Other ->
                    {roundtrip_broke, T, V, Other}
            end;
        {error, Reason} ->
            {encode_failed, T, V, Reason}
    end.

%% A strict prefix of a valid encoding never decodes completely: the
%% decoder asks for more or rejects, it never fabricates a value. Cut
%% points are sampled (every header byte, the last 8 bytes and evenly
%% spaced midpoints) — an exhaustive sweep over all prefixes is O(n^2)
%% and times out on deeply nested values.
prop_prefix_never_completes() ->
    ?FORALL({T, V}, ?SIZED(Size, resize(5, type_value(Size))), prefix_ok(T, V)).

prefix_ok(T, V) ->
    {ok, Encoded} = thrift_erl_binary:encode(T, V),
    Bin = iolist_to_binary(Encoded),
    lists:all(
        fun(K) -> prefix_incomplete(T, Bin, K) end,
        cut_points(byte_size(Bin))
    ).

-spec cut_points(non_neg_integer()) -> [non_neg_integer()].
cut_points(Size) ->
    Head = lists:seq(0, min(Size - 1, 11)),
    Tail = lists:seq(max(0, Size - 8), Size - 1),
    Mids = [K * Size div 24 || K <- lists:seq(1, 23), K * Size div 24 < Size],
    lists:usort(Head ++ Tail ++ Mids).

-spec prefix_incomplete(thrift_erl_binary:type_desc(), binary(), non_neg_integer()) -> boolean().
prefix_incomplete(T, Bin, K) ->
    case thrift_erl_binary:decode(T, binary:part(Bin, 0, K)) of
        more -> true;
        {error, _} -> true;
        {ok, _, Rest} -> byte_size(Rest) > 0
    end.

%% Strict envelope: encode_message -> decode_message roundtrips all four
%% header fields, the payload is the exact tail.
prop_message_roundtrip() ->
    ?FORALL(
        {Type, Name, SeqId, Payload},
        {message_type_value(), binary(), integer(0, 16#7fffffff), binary()},
        begin
            Message = iolist_to_binary(
                thrift_erl_binary:encode_message(Type, Name, SeqId, Payload)
            ),
            {ok, Type, Name, SeqId, Payload} =:= thrift_erl_binary:decode_message(Message)
        end
    ).

%% The legacy (headerless) envelope decodes to the same fields.
prop_legacy_envelope() ->
    ?FORALL(
        {TypeByte, Name, SeqId, Payload},
        {integer(1, 4), binary(), integer(0, 16#7fffffff), binary()},
        begin
            Message =
                <<(byte_size(Name)):32/big-signed, Name/binary, TypeByte:8, SeqId:32/big-signed, Payload/binary>>,
            Expected =
                {ok, message_type_atom(TypeByte), Name, SeqId, Payload},
            Expected =:= thrift_erl_binary:decode_message(Message)
        end
    ).

%% `{struct, {ref, Module, Name}}` encodes and decodes exactly like the
%% inline descriptor it resolves to.
prop_ref_matches_inline() ->
    ?FORALL(
        {X, Y},
        {integer(-1000, 1000), binary()},
        begin
            Inline =
                {struct,
                    {struct, [
                        {1, required, {base, i32}, <<"x">>, undefined},
                        {2, required, {base, string}, <<"y">>, undefined}
                    ]}},
            Ref = {struct, {ref, ?MODULE, <<"pt">>}},
            Value = #{<<"x">> => X, <<"y">> => Y},
            {ok, EncodedInline} = thrift_erl_binary:encode(Inline, Value),
            {ok, EncodedRef} = thrift_erl_binary:encode(Ref, Value),
            iolist_to_binary(EncodedInline) =:= iolist_to_binary(EncodedRef) andalso
                thrift_erl_binary:decode(Ref, iolist_to_binary(EncodedInline)) =:=
                    {ok, Value, <<>>}
        end
    ).

%%--------------------------------------------------------------------
%% EUnit wiring
%%--------------------------------------------------------------------

proper_test_() ->
    [
        {"codec roundtrip (PropEr)", {timeout, 180, fun() -> check(prop_roundtrip()) end}},
        {"strict prefix never completes (PropEr)",
            {timeout, 180, fun() ->
                check(prop_prefix_never_completes())
            end}},
        {"strict message roundtrip (PropEr)",
            {timeout, 60, fun() ->
                check(prop_message_roundtrip())
            end}},
        {"legacy message roundtrip (PropEr)",
            {timeout, 60, fun() ->
                check(prop_legacy_envelope())
            end}},
        {"ref indirection equals inline (PropEr)",
            {timeout, 60, fun() ->
                check(prop_ref_matches_inline())
            end}}
    ].

%% Silent success; on failure re-run with output so the shrunk
%% counterexample lands in the EUnit log.

-spec check(proper:outer_test()) -> ok.
check(Prop) ->
    case
        proper:quickcheck(Prop, [
            {numtests, ?NUMTESTS},
            {start_size, 2},
            {on_output, fun(_, _) -> ok end},
            long_result
        ])
    of
        true ->
            ok;
        Failed ->
            io:put_chars("PropEr failure, re-running with output:\n"),
            proper:quickcheck(Prop, [
                {numtests, ?NUMTESTS},
                {start_size, 2},
                long_result
            ]),
            ?assertEqual(true, Failed)
    end.

-spec message_type_atom(1 | 2 | 3 | 4) -> thrift_erl_binary:message_type().
message_type_atom(1) -> call;
message_type_atom(2) -> reply;
message_type_atom(3) -> exception;
message_type_atom(4) -> oneway.

%%--------------------------------------------------------------------
%% Ref target
%%--------------------------------------------------------------------

-doc false.
-spec struct_info(binary()) -> {struct, [thrift_erl_binary:field_desc()]} | error.
struct_info(<<"pt">>) ->
    {struct, [
        {1, required, {base, i32}, <<"x">>, undefined},
        {2, required, {base, string}, <<"y">>, undefined}
    ]};
struct_info(_) ->
    error.
