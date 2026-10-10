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

-module(thrift_erl_props).

-moduledoc """
PropEr properties for the generic codecs: binary, compact and JSON.

Each property is wrapped in `proper:quickcheck` so `rebar3 eunit` runs
them without an extra plugin. On failure the property is re-run with
PropEr's output enabled, which prints the shrunk counterexample.

The value generators respect each wire format's expressible set: the
compact protocol and JSON have no `uuid` encoding; JSON map keys can
only be base types or enums (a JSON object key is text); JSON doubles
print with 16 fractional digits, so subnormal magnitudes would not
roundtrip and the generator stays inside the printable range; JSON
strings carry valid UTF-8.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% The module doubles as the `{ref, Module, Name}` target so the
%% indirection property exercises `Module:struct_info/1` for real.
-export([struct_info/1]).

-define(ENUM_DESC, [{0, red}, {1, green}, {2, blue}, {-7, weird}]).
-define(NUMTESTS, 300).

-type proto() :: thrift_erl_binary | thrift_erl_compact | thrift_erl_json.

%%--------------------------------------------------------------------
%% Generators
%%--------------------------------------------------------------------

uuid() ->
    ?LET(Bytes, vector(16, byte()), list_to_binary(Bytes)).

%% JSON doubles print with 16 fractional digits; magnitudes at or above
%% ~1e-14 (and everything dyadic) roundtrip exactly, subnormals would
%% print to all zeros.

double_value(thrift_erl_json) ->
    frequency([
        {4, ?LET(N, integer(-999999999999999, 999999999999999), N * 1.0)},
        {2, ?LET(N, integer(-1048576, 1048576), N / 1024.0)},
        {1, 0.0}
    ]);
double_value(_) ->
    float().

%% JSON strings carry UTF-8; binary and compact move arbitrary bytes.

string_value(thrift_erl_json) ->
    %% Printable ASCII (exercises the JSON escapes: quote, backslash) or
    %% multi-byte UTF-8; surrogates and control codepoints excluded —
    %% this PropEr build has no utf8 generator.
    frequency([
        {2, ?LET(Cs, list(integer(16#20, 16#7E)), unicode:characters_to_binary(Cs))},
        {1,
            ?LET(
                Cs,
                list(oneof([integer(16#A0, 16#2FFF), integer(16#10000, 16#10FFFF)])),
                unicode:characters_to_binary(Cs)
            )}
    ]);
string_value(_) ->
    binary().

base_type_value(Proto) ->
    Uuid =
        case Proto of
            thrift_erl_binary -> [{{base, uuid}, uuid()}];
            _ -> []
        end,
    oneof(
        [
            {{base, bool}, oneof([true, false])},
            {{base, i8}, integer(-128, 127)},
            {{base, i16}, integer(-32768, 32767)},
            {{base, i32}, integer(-2147483648, 2147483647)},
            {{base, i64}, integer(-9223372036854775808, 9223372036854775807)},
            {{base, double}, double_value(Proto)},
            {{base, string}, string_value(Proto)},
            {{base, binary}, string_value(Proto)},
            {{enum, ?ENUM_DESC}, oneof([red, green, blue, weird])}
        ] ++ Uuid
    ).

type_value(Proto) ->
    ?SIZED(Size, type_value(Proto, Size)).

type_value(Proto, Size) when Size =< 1 ->
    base_type_value(Proto);
type_value(Proto, Size) ->
    frequency([
        {6, base_type_value(Proto)},
        {2, ?LET({T, V}, type_value(Proto, Size div 2), {{list, T}, list(V)})},
        {2, ?LET({T, V}, type_value(Proto, Size div 2), {{set, T}, list(V)})},
        {2,
            ?LET(
                {{KT, KV}, {VT, VV}},
                {key_type_value(Proto, Size div 2), type_value(Proto, Size div 2)},
                {{map, KT, VT}, map(KV, VV)}
            )},
        {2, struct_tv(Proto, Size)}
    ]).

%% A JSON object key is text, so only base types and enums can key a
%% map on the JSON wire; binary and compact take any type.

key_type_value(thrift_erl_json, _Size) ->
    base_type_value(thrift_erl_json);
key_type_value(Proto, Size) ->
    type_value(Proto, Size).

struct_tv(Proto, Size) ->
    ?LET(
        TVs,
        vector(3, type_value(Proto, Size div 2)),
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
%% structs included), on all three engines.

prop_roundtrip() ->
    ?FORALL({T, V}, type_value(thrift_erl_binary), roundtrip_ok(thrift_erl_binary, T, V)).

prop_roundtrip_compact() ->
    ?FORALL(
        {T, V},
        ?SIZED(Size, resize(6, type_value(thrift_erl_compact, Size))),
        roundtrip_ok(thrift_erl_compact, T, V)
    ).

prop_roundtrip_json() ->
    ?FORALL(
        {T, V},
        ?SIZED(Size, resize(6, type_value(thrift_erl_json, Size))),
        roundtrip_ok(thrift_erl_json, T, V)
    ).

roundtrip_ok(Proto, T, V) ->
    case encode(Proto, T, V) of
        {ok, Encoded} ->
            case decode(Proto, T, iolist_to_binary(Encoded)) of
                {ok, V, <<>>} ->
                    true;
                %% Proper prints the shrunk {T, V} counterexample on
                %% the output-enabled re-run; each protocol has its own
                %% property, so the engine is implied.
                _Other ->
                    false
            end;
        {error, _Reason} ->
            false
    end.

%% A strict prefix of a valid encoding never decodes completely: the
%% decoder asks for more or rejects, it never fabricates a value. Cut
%% points are sampled (every header byte, the last 8 bytes and evenly
%% spaced midpoints) — an exhaustive sweep over all prefixes is O(n^2)
%% and times out on deeply nested values.

prop_prefix_never_completes() ->
    ?FORALL(
        {T, V},
        ?SIZED(Size, resize(5, type_value(thrift_erl_binary, Size))),
        prefix_ok(thrift_erl_binary, T, V)
    ).

prop_prefix_never_completes_compact() ->
    ?FORALL(
        {T, V},
        ?SIZED(Size, resize(4, type_value(thrift_erl_compact, Size))),
        prefix_ok(thrift_erl_compact, T, V)
    ).

%% A bare JSON scalar has no framing: at top level "1" is already a
%% complete value, so a strict prefix of "10" legitimately decodes.
%% The message payload is always a struct, where truncation is always
%% detectable — the property runs on struct values.

prop_prefix_never_completes_json() ->
    ?FORALL(
        {T, V},
        ?SIZED(Size, resize(4, struct_tv(thrift_erl_json, Size))),
        prefix_ok(thrift_erl_json, T, V)
    ).

prefix_ok(Proto, T, V) ->
    {ok, Encoded} = encode(Proto, T, V),
    Bin = iolist_to_binary(Encoded),
    lists:all(
        fun(K) -> prefix_incomplete(Proto, T, Bin, K) end,
        cut_points(byte_size(Bin))
    ).

-spec cut_points(non_neg_integer()) -> [non_neg_integer()].
cut_points(Size) ->
    Head = lists:seq(0, min(Size - 1, 11)),
    Tail = lists:seq(max(0, Size - 8), Size - 1),
    Mids = [K * Size div 24 || K <- lists:seq(1, 23), K * Size div 24 < Size],
    lists:usort(Head ++ Tail ++ Mids).

-spec prefix_incomplete(proto(), term(), binary(), non_neg_integer()) -> boolean().
prefix_incomplete(Proto, T, Bin, K) ->
    case decode(Proto, T, binary:part(Bin, 0, K)) of
        more -> true;
        {error, _} -> true;
        {ok, _, Rest} -> byte_size(Rest) > 0
    end.

%% Strict envelope: encode_message -> decode_message roundtrips all four
%% header fields, the payload is the exact tail. The JSON envelope's
%% payload is struct-shaped text (its closing bracket folds into the
%% struct decode), so arbitrary payloads only hold for binary and
%% compact.

prop_message_roundtrip() ->
    ?FORALL(
        {Type, Name, SeqId, Payload},
        {message_type_value(), binary(), integer(0, 16#7fffffff), binary()},
        message_roundtrip_ok(thrift_erl_binary, Type, Name, SeqId, Payload)
    ).

%% The compact message seqid is a raw (unzigzagged) varint on both
%% sides — the official Erlang compact protocol writes it as {ui32, _}
%% — so the non-negative range is the contract; the binary protocol's
%% i32 seqid takes negatives.

prop_message_roundtrip_compact() ->
    ?FORALL(
        {Type, Name, SeqId, Payload},
        {message_type_value(), binary(), integer(0, 16#7fffffff), binary()},
        message_roundtrip_ok(thrift_erl_compact, Type, Name, SeqId, Payload)
    ).

message_roundtrip_ok(Proto, Type, Name, SeqId, Payload) ->
    Message = iolist_to_binary(encode_message(Proto, Type, Name, SeqId, Payload)),
    case decode_message(Proto, Message) of
        {ok, Type, Name, SeqId, Payload} ->
            true;
        _Other ->
            false
    end.

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

%% Explicit per-engine dispatch: test modules make no dynamic calls,
%% and the three engines share shapes but not module atoms.

-spec encode(proto(), term(), term()) -> {ok, iodata()} | {error, term()}.
encode(thrift_erl_binary, T, V) -> thrift_erl_binary:encode(T, V);
encode(thrift_erl_compact, T, V) -> thrift_erl_compact:encode(T, V);
encode(thrift_erl_json, T, V) -> thrift_erl_json:encode(T, V).

-spec decode(proto(), term(), binary()) -> thrift_erl_binary:decode_result(term()).
decode(thrift_erl_binary, T, Bin) -> thrift_erl_binary:decode(T, Bin);
decode(thrift_erl_compact, T, Bin) -> thrift_erl_compact:decode(T, Bin);
decode(thrift_erl_json, T, Bin) -> thrift_erl_json:decode(T, Bin).

-spec encode_message(proto(), atom(), binary(), integer(), binary()) -> iodata().
encode_message(thrift_erl_binary, T, N, S, P) -> thrift_erl_binary:encode_message(T, N, S, P);
encode_message(thrift_erl_compact, T, N, S, P) -> thrift_erl_compact:encode_message(T, N, S, P).

-spec decode_message(proto(), binary()) ->
    {ok, atom(), binary(), integer(), binary()} | more | {error, term()}.
decode_message(thrift_erl_binary, Bin) -> thrift_erl_binary:decode_message(Bin);
decode_message(thrift_erl_compact, Bin) -> thrift_erl_compact:decode_message(Bin).

%%--------------------------------------------------------------------
%% EUnit wiring
%%--------------------------------------------------------------------

proper_test_() ->
    [
        {"codec roundtrip (PropEr)", {timeout, 180, fun() -> check(prop_roundtrip()) end}},
        {"codec roundtrip compact (PropEr)",
            {timeout, 180, fun() ->
                check(prop_roundtrip_compact())
            end}},
        {"codec roundtrip json (PropEr)",
            {timeout, 180, fun() ->
                check(prop_roundtrip_json())
            end}},
        {"strict prefix never completes (PropEr)",
            {timeout, 180, fun() ->
                check(prop_prefix_never_completes())
            end}},
        {"strict prefix never completes compact (PropEr)",
            {timeout, 180, fun() ->
                check(prop_prefix_never_completes_compact())
            end}},
        {"strict prefix never completes json (PropEr)",
            {timeout, 180, fun() ->
                check(prop_prefix_never_completes_json())
            end}},
        {"strict message roundtrip (PropEr)",
            {timeout, 60, fun() ->
                check(prop_message_roundtrip())
            end}},
        {"strict message roundtrip compact (PropEr)",
            {timeout, 60, fun() ->
                check(prop_message_roundtrip_compact())
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
