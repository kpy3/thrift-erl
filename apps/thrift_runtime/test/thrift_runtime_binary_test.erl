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

%% Golden-byte tests against the Thrift binary protocol specification:
%% every expected byte sequence below was written out by hand from the
%% wire format, not produced by this implementation.

-module(thrift_runtime_binary_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    primitives_golden_test/0,
    string_and_uuid_golden_test/0,
    containers_golden_test/0,
    struct_golden_test/0,
    struct_unknown_field_skipped_test/0,
    struct_required_missing_test/0,
    union_rules_test/0,
    enum_golden_test/0,
    message_envelope_golden_test/0,
    message_envelope_legacy_decode_test/0,
    application_exception_roundtrip_test/0,
    truncated_returns_more_test/0,
    roundtrip_nested_test/0
]).

primitives_golden_test() ->
    ?assertEqual({ok, <<1>>}, enc({base, bool}, true)),
    ?assertEqual({ok, <<0>>}, enc({base, bool}, false)),
    ?assertEqual({ok, <<255>>}, enc({base, i8}, -1)),
    ?assertEqual({ok, <<1, 44>>}, enc({base, i16}, 300)),
    ?assertEqual({ok, <<0, 0, 0, 1>>}, enc({base, i32}, 1)),
    ?assertEqual({ok, <<255, 255, 255, 255>>}, enc({base, i32}, -1)),
    ?assertEqual({ok, <<0, 0, 0, 0, 0, 0, 0, 42>>}, enc({base, i64}, 42)),
    %% 1.0 = 3FF0 0000 0000 0000, big-endian IEEE 754.
    ?assertEqual({ok, <<63, 240, 0, 0, 0, 0, 0, 0>>}, enc({base, double}, 1.0)),
    ok.

string_and_uuid_golden_test() ->
    ?assertEqual({ok, <<0, 0, 0, 2, $h, $i>>}, enc({base, string}, <<"hi">>)),
    ?assertEqual({ok, <<0, 0, 0, 0>>}, enc({base, binary}, <<>>)),
    %% UUID travels as 16 raw bytes, textual order.
    Uuid = <<16#01, 16#23, 16#45, 16#67, 16#89, 16#ab, 16#cd, 16#ef, 0, 0, 0, 0, 0, 0, 0, 16#01>>,
    ?assertEqual({ok, Uuid}, enc({base, uuid}, Uuid)),
    ok.

containers_golden_test() ->
    %% list<i32> [1, 2]: type i32=8, size 2, then elements.
    ?assertEqual(
        {ok, <<8, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2>>},
        enc({list, {base, i32}}, [1, 2])
    ),
    %% set<string> {"a"}: type string=11, size 1.
    ?assertEqual({ok, <<11, 0, 0, 0, 1, 0, 0, 0, 1, $a>>}, enc({set, {base, string}}, [<<"a">>])),
    %% map<string, i32> {"a" => 1}: ktype 11, vtype 8, size 1.
    ?assertEqual(
        {ok, <<11, 8, 0, 0, 0, 1, 0, 0, 0, 1, $a, 0, 0, 0, 1>>},
        enc({map, {base, string}, {base, i32}}, #{<<"a">> => 1})
    ),
    %% Empty containers.
    ?assertEqual({ok, <<8, 0, 0, 0, 0>>}, enc({list, {base, i32}}, [])),
    ?assertEqual({ok, <<11, 8, 0, 0, 0, 0>>}, enc({map, {base, string}, {base, i32}}, #{})),
    ok.

struct_golden_test() ->
    Desc =
        {struct,
            {struct, [
                {1, default, {base, string}, <<"name">>, undefined},
                {2, default, {base, i32}, <<"count">>, undefined}
            ]}},
    %% Field: type byte, i16 id, value; stop byte 0.
    ?assertEqual(
        {ok, <<11, 0, 1, 0, 0, 0, 2, $o, $k, 8, 0, 2, 0, 0, 0, 7, 0>>},
        enc(Desc, #{<<"name">> => <<"ok">>, <<"count">> => 7})
    ),
    %% Absent fields are simply not written.
    ?assertEqual({ok, <<8, 0, 2, 0, 0, 0, 7, 0>>}, enc(Desc, #{<<"count">> => 7})),
    %% Empty struct is just the stop byte.
    ?assertEqual({ok, <<0>>}, enc(Desc, #{})),
    Value = #{<<"name">> => <<"x">>, <<"count">> => -3},
    ?assertEqual({ok, {Value, <<>>}}, roundtrip(Desc, Value)),
    ok.

struct_unknown_field_skipped_test() ->
    %% Wire has field id 9 (unknown, i64) before field 1; decoding skips it.
    Wire = <<10, 0, 9, 0, 0, 0, 0, 0, 0, 0, 99, 11, 0, 1, 0, 0, 0, 1, $a, 0>>,
    Desc = {struct, {struct, [{1, default, {base, string}, <<"name">>, undefined}]}},
    ?assertEqual({ok, #{<<"name">> => <<"a">>}, <<>>}, dec(Desc, Wire)),
    ok.

struct_required_missing_test() ->
    Desc = {struct, {struct, [{1, required, {base, i32}, <<"n">>, undefined}]}},
    ?assertMatch({error, {encode, {missing_required_fields, [<<"n">>]}}}, enc(Desc, #{})),
    %% Wire struct that omits the required field fails on decode.
    ?assertMatch({error, {decode, {missing_required_fields, [<<"n">>]}}}, dec(Desc, <<0>>)),
    ok.

union_rules_test() ->
    Desc =
        {struct,
            {union, [
                {1, default, {base, i32}, <<"a">>, undefined},
                {2, default, {base, string}, <<"b">>, undefined}
            ]}},
    ?assertMatch({error, {encode, union_empty}}, enc(Desc, #{})),
    ?assertMatch(
        {error, {encode, union_multiple}},
        enc(Desc, #{<<"a">> => 1, <<"b">> => <<"x">>})
    ),
    ?assertEqual({ok, <<8, 0, 1, 0, 0, 0, 5, 0>>}, enc(Desc, #{<<"a">> => 5})),
    ok.

enum_golden_test() ->
    Desc = {enum, [{1, one}, {2, two}]},
    ?assertEqual({ok, <<0, 0, 0, 2>>}, enc(Desc, two)),
    %% Integers pass through unchanged.
    ?assertEqual({ok, <<0, 0, 0, 9>>}, enc(Desc, 9)),
    %% Decode maps back to atoms; unknown ints stay ints.
    ?assertEqual({ok, {one, <<>>}}, roundtrip(Desc, one)),
    ?assertEqual({ok, {9, <<>>}}, roundtrip(Desc, 9)),
    ?assertMatch({error, {encode, _}}, enc(Desc, nope)),
    ok.

message_envelope_golden_test() ->
    %% Strict envelope: version 0x8001, type call=1, name "f", seqid 7.
    ?assertEqual(
        <<128, 1, 0, 1, 0, 0, 0, 1, $f, 0, 0, 0, 7, 0>>,
        iolist_to_binary(thrift_runtime_binary:encode_message(call, <<"f">>, 7, <<0>>))
    ),
    ?assertEqual(
        {ok, call, <<"f">>, 7, <<0>>},
        thrift_runtime_binary:decode_message(<<128, 1, 0, 1, 0, 0, 0, 1, $f, 0, 0, 0, 7, 0>>)
    ),
    ?assertEqual(
        {ok, oneway, <<"g">>, 0, <<11, 0, 1, $x>>},
        thrift_runtime_binary:decode_message(
            iolist_to_binary(thrift_runtime_binary:encode_message(oneway, <<"g">>, 0, <<11, 0, 1, $x>>))
        )
    ),
    %% Truncated envelope asks for more, never errors.
    ?assertEqual(more, thrift_runtime_binary:decode_message(<<128, 1, 0, 1, 0, 0>>)),
    ok.

message_envelope_legacy_decode_test() ->
    %% Legacy envelope: name string, raw type byte, seqid.
    Legacy = <<0, 0, 0, 1, $f, 2, 0, 0, 0, 9, 8, 0, 1, 0, 0, 0, 4, 0>>,
    ?assertEqual(
        {ok, reply, <<"f">>, 9, <<8, 0, 1, 0, 0, 0, 4, 0>>},
        thrift_runtime_binary:decode_message(Legacy)
    ),
    ok.

application_exception_roundtrip_test() ->
    {ok, Encoded} = thrift_runtime_binary:encode_application_exception(<<"boom">>, 6),
    ?assertEqual(
        {ok, #{message => <<"boom">>, code => 6, name => <<"INTERNAL_ERROR">>}, <<>>},
        thrift_runtime_binary:decode_application_exception(iolist_to_binary(Encoded))
    ),
    ok.

truncated_returns_more_test() ->
    ?assertEqual(more, dec({base, i32}, <<0, 0>>)),
    ?assertEqual(more, dec({base, string}, <<0, 0, 0, 5, $a>>)),
    ?assertEqual(more, dec({list, {base, i8}}, <<3, 0, 0, 0, 2, 1>>)),
    ?assertEqual(more, dec({map, {base, i8}, {base, i8}}, <<3, 3, 0, 0, 0, 1, 5>>)),
    Desc = {struct, {struct, [{1, default, {base, i32}, <<"n">>, undefined}]}},
    ?assertEqual(more, dec(Desc, <<8, 0, 1, 0>>)),
    ok.

roundtrip_nested_test() ->
    Point =
        {struct,
            {struct, [
                {1, required, {base, i32}, <<"x">>, undefined},
                {2, required, {base, i32}, <<"y">>, undefined}
            ]}},
    Desc =
        {struct,
            {struct, [
                {1, default, {list, Point}, <<"points">>, undefined},
                {2, default, {map, {base, string}, {set, {base, i64}}}, <<"index">>, undefined},
                {3, default, {base, uuid}, <<"token">>, undefined}
            ]}},
    Uuid = <<1:128>>,
    Value = #{
        <<"points">> => [#{<<"x">> => 1, <<"y">> => 2}],
        <<"index">> => #{<<"k">> => [1, 2, 3]},
        <<"token">> => Uuid
    },
    ?assertEqual({ok, {Value, <<>>}}, roundtrip(Desc, Value)),
    ok.

%% Helpers

enc(Type, Value) ->
    case thrift_runtime_binary:encode(Type, Value) of
        {ok, IOData} -> {ok, iolist_to_binary(IOData)};
        Error -> Error
    end.

dec(Type, Bin) ->
    case thrift_runtime_binary:decode(Type, Bin) of
        {ok, Value, Rest} -> {ok, Value, Rest};
        Other -> Other
    end.

roundtrip(Type, Value) ->
    {ok, Bin} = enc(Type, Value),
    case thrift_runtime_binary:decode(Type, Bin) of
        {ok, V, Rest} -> {ok, {V, Rest}};
        Other -> Other
    end.
