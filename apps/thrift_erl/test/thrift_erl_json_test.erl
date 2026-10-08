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

%% Unit tests for the JSON codec: known wire bytes (cross-checked
%% against the vendored Apache thrift_json_protocol, which produced
%% every vector here), escaping, map keys as JSON object keys, the
%% `]`-fold of the envelope's closing bracket into the top-level
%% struct decode, unknown-field skipping, application exceptions,
%% and `more`-on-truncation.

-module(thrift_erl_json_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    scalars_test/0,
    escaping_test/0,
    collections_test/0,
    map_keys_test/0,
    struct_roundtrip_test/0,
    skip_unknown_fields_test/0,
    message_envelope_test/0,
    envelope_roundtrip_test/0,
    application_exception_test/0,
    more_semantics_test/0,
    unsupported_types_test/0,
    enum_test/0,
    facade_test/0
]).

%%--------------------------------------------------------------------
%% Scalars: numbers as literals, doubles with 16 fractional digits

scalars_test() ->
    ?assertEqual(<<"1">>, encb({base, i32}, 1)),
    ?assertEqual(<<"-32768">>, encb({base, i16}, -32768)),
    ?assertEqual(<<"-9223372036854775808">>, encb({base, i64}, -16#8000000000000000)),
    ?assertEqual(<<"true">>, encb({base, bool}, true)),
    ?assertEqual(<<"false">>, encb({base, bool}, false)),
    %% the reference writes ~.*f with 16 fractional digits
    ?assertEqual(<<"3.2500000000000000">>, encb({base, double}, 3.25)),
    ?assertEqual(<<"1.0000000000000000">>, encb({base, double}, 1)),
    ?assertEqual(<<"\"ab\"">>, encb({base, string}, <<"ab">>)),
    %% decode reverses every scalar
    {ok, 7, <<>>} = dec({base, i32}, <<"7">>),
    {ok, true, <<>>} = dec({base, bool}, <<"true">>),
    {ok, 3.25, <<>>} = dec({base, double}, <<"3.2500000000000000">>),
    %% an integer literal also reads back as a double
    {ok, 3.0, <<>>} = dec({base, double}, <<"3">>),
    {ok, <<"ab">>, <<>>} = dec({base, binary}, <<"\"ab\"">>),
    %% range and shape checks refuse, not truncate
    ?assertMatch({error, _}, thrift_erl_json:encode({base, i16}, 40000)),
    ?assertMatch({error, _}, thrift_erl_json:encode({base, bool}, 1)),
    ?assertMatch({error, _}, thrift_erl_json:encode({base, string}, 5)),
    ok.

%%--------------------------------------------------------------------
%% Escaping: the reference's escape table, UTF-8 passes through

escaping_test() ->
    %% quote, backslash, the short escapes, \u00XX below 0x20; UTF-8
    %% and DEL pass through raw
    Raw = <<34, 92, 8, 12, 10, 13, 9, 27, 16#C3, 16#A9, 16#7F>>,
    Escaped = <<"\\\"\\\\\\b\\f\\n\\r\\t\\u001b", 16#C3, 16#A9, 16#7F>>,
    ?assertEqual(<<$", Escaped/binary, $">>, encb({base, string}, Raw)),
    {ok, Raw, <<>>} = dec({base, string}, <<$", Escaped/binary, $">>),
    %% a lone surrogate \u escape is refused
    ?assertMatch({error, _}, dec({base, string}, <<"\"\\ud800\"">>)),
    ok.

%%--------------------------------------------------------------------
%% Collections: ["tag",size,elements], empty without the comma

collections_test() ->
    ?assertEqual(<<"[\"i32\",2,1,2]">>, encb({list, {base, i32}}, [1, 2])),
    %% an empty collection has no comma after the size
    ?assertEqual(<<"[\"i32\",0]">>, encb({list, {base, i32}}, [])),
    %% sets share the list shape under the "set" tag
    SetBin = encb({set, {base, i32}}, [1]),
    ?assertEqual(<<"[\"i32\",1,1]">>, SetBin),
    {ok, [1], <<>>} = dec({set, {base, i32}}, SetBin),
    %% nested lists keep their brackets
    {ok, [[1, 2], [3]], <<>>} =
        dec({list, {list, {base, i32}}}, encb({list, {list, {base, i32}}}, [[1, 2], [3]])),
    %% booleans in a list are true/false literals
    ?assertEqual(<<"[\"tf\",2,true,false]">>, encb({list, {base, bool}}, [true, false])),
    ok.

%%--------------------------------------------------------------------
%% Map keys are JSON object keys: every scalar type has a text form

map_keys_test() ->
    Map = {map, {base, i32}, {base, i32}},
    Bin = encb(Map, #{2 => 20, 1 => 10}),
    ?assertEqual(<<"[\"i32\",\"i32\",2,{\"1\":10,\"2\":20}]">>, Bin),
    {ok, #{1 := 10, 2 := 20}, <<>>} = dec(Map, Bin),
    %% empty map: no comma, empty object
    ?assertEqual(<<"[\"i32\",\"i32\",0,{}]">>, encb(Map, #{})),
    {ok, #{}, <<>>} = dec(Map, <<"[\"i32\",\"i32\",0,{}]">>),
    %% booleans become "true"/"false"; pairs are sorted by key text
    BoolMap = encb({map, {base, bool}, {base, i32}}, #{true => 1, false => 0}),
    ?assertEqual(<<"[\"tf\",\"i32\",2,{\"false\":0,\"true\":1}]">>, BoolMap),
    {ok, #{true := 1, false := 0}, <<>>} = dec({map, {base, bool}, {base, i32}}, BoolMap),
    DoubleMap = encb({map, {base, double}, {base, i32}}, #{1.5 => 1}),
    ?assertEqual(<<"[\"dbl\",\"i32\",1,{\"1.5000000000000000\":1}]">>, DoubleMap),
    EnumMap = encb({map, {enum, [{1, 'ONE'}]}, {base, i32}}, #{'ONE' => 1}),
    ?assertEqual(<<"[\"i32\",\"i32\",1,{\"1\":1}]">>, EnumMap),
    {ok, #{'ONE' := 1}, <<>>} = dec({map, {enum, [{1, 'ONE'}]}, {base, i32}}, EnumMap),
    %% distinct Erlang keys whose text forms collide (1 and 1.0 both
    %% render as "1.0000000000000000") are refused: an object cannot
    %% carry both
    ?assertMatch(
        {error, {encode, duplicate_json_keys}},
        thrift_erl_json:encode(
            {map, {base, double}, {base, i32}},
            #{1 => 1, 1.0 => 2}
        )
    ),
    ok.

%%--------------------------------------------------------------------
%% Struct round-trips: field objects, refs, required, union

struct_roundtrip_test() ->
    Desc =
        {struct,
            {struct, [
                {1, default, {base, i32}, <<"a">>, undefined},
                {2, default, {base, string}, <<"b">>, undefined}
            ]}},
    %% every field is the "id":{"tag":value} object, declaration order
    Bin = encb(Desc, #{<<"a">> => 1, <<"b">> => <<"x">>}),
    ?assertEqual(<<"{\"1\":{\"i32\":1},\"2\":{\"str\":\"x\"}}">>, Bin),
    %% absent fields just don't appear
    ?assertEqual(<<"{\"2\":{\"str\":\"x\"}}">>, encb(Desc, #{<<"b">> => <<"x">>})),
    {ok, #{<<"a">> := 1, <<"b">> := <<"x">>}, <<>>} = dec(Desc, Bin),
    %% trailing bytes come back
    {ok, #{<<"a">> := 1}, <<"tail">>} = dec(Desc, <<"{\"1\":{\"i32\":1}}tail">>),
    %% nested ref resolves through thrift_erl_test_service (point)
    Wrap =
        {struct,
            {struct, [
                {1, default, {struct, {ref, thrift_erl_test_service, <<"point">>}}, <<"p">>, undefined},
                {2, default, {base, i32}, <<"n">>, undefined}
            ]}},
    Value = #{<<"p">> => #{<<"x">> => -1, <<"y">> => 2}, <<"n">> => 7},
    WrapBin = encb(Wrap, Value),
    ?assertEqual(
        <<"{\"1\":{\"rec\":{\"1\":{\"i32\":-1},\"2\":{\"i32\":2}}},\"2\":{\"i32\":7}}">>,
        WrapBin
    ),
    {ok, Value, <<>>} = dec(Wrap, WrapBin),
    %% required field missing on encode and on decode
    Req = {struct, {struct, [{1, required, {base, i32}, <<"r">>, undefined}]}},
    ?assertMatch({error, {encode, {missing_required_fields, _}}}, thrift_erl_json:encode(Req, #{})),
    ?assertMatch({error, {decode, {missing_required_fields, _}}}, dec(Req, <<"{}">>)),
    %% union: exactly one field
    Union =
        {struct,
            {union, [
                {1, default, {base, i32}, <<"a">>, undefined},
                {2, default, {base, i32}, <<"b">>, undefined}
            ]}},
    {ok, #{<<"b">> := 5}, <<>>} = dec(Union, encb(Union, #{<<"b">> => 5})),
    ?assertMatch({error, {encode, union_empty}}, thrift_erl_json:encode(Union, #{})),
    ?assertMatch(
        {error, {encode, union_multiple}},
        thrift_erl_json:encode(Union, #{<<"a">> => 1, <<"b">> => 2})
    ),
    ok.

%%--------------------------------------------------------------------
%% Unknown fields are skipped by wire tag, decode continues

skip_unknown_fields_test() ->
    Known = {struct, {struct, [{2, default, {base, i32}, <<"k">>, undefined}]}},
    {ok, #{<<"k">> := 4}, <<>>} = dec(Known, <<"{\"1\":{\"i32\":300},\"2\":{\"i32\":4}}">>),
    %% string content with braces and commas does not confuse the skip
    {ok, #{<<"k">> := 4}, <<>>} =
        dec(Known, <<"{\"1\":{\"str\":\"x,y]\"},\"2\":{\"i32\":4}}">>),
    {ok, #{<<"k">> := 4}, <<>>} =
        dec(Known, <<"{\"1\":{\"lst\":[\"str\",2,\"a\",\"b\"]},\"2\":{\"i32\":4}}">>),
    {ok, #{<<"k">> := 4}, <<>>} =
        dec(Known, <<"{\"1\":{\"map\":[\"i32\",\"i32\",1,{\"7\":8}]},\"2\":{\"i32\":4}}">>),
    %% unknown nested struct with escapes inside
    {ok, #{<<"k">> := 4}, <<>>} =
        dec(Known, <<"{\"1\":{\"rec\":{\"3\":{\"str\":\"a\\\"b\\\\c\"}}},\"2\":{\"i32\":4}}">>),
    %% an unknown field alone still decodes to the empty map
    {ok, #{}, <<>>} = dec(Known, <<"{\"1\":{\"i32\":1}}">>),
    ok.

%%--------------------------------------------------------------------
%% Message envelope: [1,"name",type,seqid,payload]

message_envelope_test() ->
    ?assertEqual(
        <<"[1,\"add\",1,3,{\"1\":{\"i32\":2}}]">>,
        iolist_to_binary(thrift_erl_json:encode_message(call, <<"add">>, 3, <<"{\"1\":{\"i32\":2}}">>))
    ),
    ok.

%% The payload of decode_message is exactly the struct object plus the
%% envelope's closing bracket — the bytes the strict top-level struct
%% decode consumes (the ]-fold, see the moduledoc).

envelope_roundtrip_test() ->
    Payload = encb(sdesc(), #{<<"a">> => 5}),
    WithBracket = <<Payload/binary, "]">>,
    {ok, call, <<"f">>, 0, WithBracket} = roundtrip_message(call, <<"f">>, 0, Payload),
    {ok, reply, <<"f">>, 0, WithBracket} = roundtrip_message(reply, <<"f">>, 0, Payload),
    {ok, exception, <<"f">>, 0, WithBracket} = roundtrip_message(exception, <<"f">>, 0, Payload),
    {ok, oneway, <<"f">>, 0, WithBracket} = roundtrip_message(oneway, <<"f">>, 0, Payload),
    %% big seqid, escaped name
    {ok, reply, <<"a\"b">>, 12345, WithBracket} =
        roundtrip_message(reply, <<"a\"b">>, 12345, Payload),
    %% bad version and unknown type are errors, not more
    ?assertMatch({error, _}, thrift_erl_json:decode_message(<<"[2,\"f\",1,0,{}]">>)),
    ?assertMatch({error, _}, thrift_erl_json:decode_message(<<"[1,\"f\",9,0,{}]">>)),
    ok.

%%--------------------------------------------------------------------
%% TApplicationException round-trip in JSON encoding

application_exception_test() ->
    %% field 1 message string, field 2 code i32
    {ok, ExceptionIo} = thrift_erl_json:encode_application_exception(<<"boom">>, 6),
    Payload = iolist_to_binary(ExceptionIo),
    ?assertEqual(<<"{\"1\":{\"str\":\"boom\"},\"2\":{\"i32\":6}}">>, Payload),
    {ok, #{message := <<"boom">>, code := 6, name := <<"INTERNAL_ERROR">>}, <<>>} =
        thrift_erl_json:decode_application_exception(Payload),
    %% a message-less payload decodes with the defaults
    {ok, #{message := <<>>, code := 0, name := <<"UNKNOWN">>}, <<>>} =
        thrift_erl_json:decode_application_exception(<<"{}">>),
    ok.

%%--------------------------------------------------------------------
%% Every truncation of a valid encoding is `more`, never garbage

more_semantics_test() ->
    %% scalars cut mid-token: a number may always continue
    ?assertEqual(more, dec({base, i32}, <<>>)),
    ?assertEqual(more, dec({base, i32}, <<"-">>)),
    ?assertEqual(more, dec({base, double}, <<"1.5e">>)),
    %% a cut string may close later
    ?assertEqual(more, dec({base, string}, <<"\"ab">>)),
    %% collections cut inside header, size and elements
    ?assertEqual(more, dec({list, {base, i32}}, <<"[">>)),
    ?assertEqual(more, dec({list, {base, i32}}, <<"[\"i32\"">>)),
    ?assertEqual(more, dec({list, {base, i32}}, <<"[\"i32\",2,1">>)),
    %% struct cut at every stage
    SDesc = sdesc(),
    ?assertEqual(more, dec(SDesc, <<>>)),
    ?assertEqual(more, dec(SDesc, <<"{">>)),
    ?assertEqual(more, dec(SDesc, <<"{\"1\"">>)),
    ?assertEqual(more, dec(SDesc, <<"{\"1\":{\"i32\":1}">>)),
    %% envelope: every strict prefix answers more
    Full = iolist_to_binary(
        thrift_erl_json:encode_message(call, <<"add">>, 3, <<"{\"1\":{\"i32\":2}}">>)
    ),
    Prefixes = [binary:part(Full, 0, N) || N <- lists:seq(1, byte_size(Full) - 1)],
    ?assert(lists:all(fun(P) -> more =:= thrift_erl_json:decode_message(P) end, Prefixes)),
    ok.

%%--------------------------------------------------------------------
%% uuid and struct-keyed maps have no JSON encoding

unsupported_types_test() ->
    ?assertMatch(
        {error, {encode, {type_not_supported, {base, uuid}, json}}},
        thrift_erl_json:encode({base, uuid}, <<0:128>>)
    ),
    ?assertMatch(
        {error, {decode, {type_not_supported, {base, uuid}, json}}},
        thrift_erl_json:decode({base, uuid}, <<0:128>>)
    ),
    StructKeyed =
        {map, {struct, {struct, [{1, default, {base, i32}, <<"a">>, undefined}]}}, {base, i32}},
    ?assertMatch(
        {error, {encode, {type_not_supported, {map, _, _}, json}}},
        thrift_erl_json:encode(StructKeyed, #{})
    ),
    ?assertMatch(
        {error, {decode, {type_not_supported, {map, _, _}, json}}},
        thrift_erl_json:decode(StructKeyed, <<"[\"map\",\"i32\",0,{}]">>)
    ),
    ok.

%%--------------------------------------------------------------------
%% Enums: plain integers on the wire, unknown ints pass through

enum_test() ->
    Desc = {enum, [{1, 'ONE'}, {2, 'TWO'}]},
    ?assertEqual(<<"2">>, encb(Desc, 'TWO')),
    {ok, 'TWO', <<>>} = dec(Desc, <<"2">>),
    {ok, 99, <<>>} = dec(Desc, <<"99">>),
    ?assertMatch({error, _}, thrift_erl_json:encode(Desc, 'NOPE')),
    ok.

%%--------------------------------------------------------------------
%% The facade drives the codec through protocol_module(json)

facade_test() ->
    Value = #{<<"a">> => 1, <<"b">> => <<"x">>},
    {ok, Wire} = thrift_erl:encode(sdesc(), Value, json),
    ?assertEqual(<<"{\"1\":{\"i32\":1},\"2\":{\"str\":\"x\"}}">>, Wire),
    %% strict decode: map representation, trailing, truncated
    {ok, #{<<"a">> := 1, <<"b">> := <<"x">>}} = thrift_erl:decode(sdesc(), Wire, map, json),
    ?assertEqual({error, trailing}, thrift_erl:decode(sdesc(), <<Wire/binary, " ">>, map, json)),
    ?assertEqual({error, truncated}, thrift_erl:decode(sdesc(), <<"{\"1\":">>, map, json)),
    ok.

%%--------------------------------------------------------------------
%% Helpers

-spec sdesc() -> thrift_erl_binary:type_desc().
sdesc() ->
    {struct,
        {struct, [
            {1, default, {base, i32}, <<"a">>, undefined},
            {2, default, {base, string}, <<"b">>, undefined}
        ]}}.

-spec encb(thrift_erl_binary:type_desc(), term()) -> binary().
encb(Type, Value) ->
    {ok, Io} = thrift_erl_json:encode(Type, Value),
    iolist_to_binary(Io).

-spec dec(thrift_erl_binary:type_desc(), iodata()) -> thrift_erl_binary:decode_result(term()).
dec(Type, Bin) ->
    thrift_erl_json:decode(Type, iolist_to_binary(Bin)).

-spec roundtrip_message(
    thrift_erl_binary:message_type(), binary(), non_neg_integer(), binary()
) ->
    {ok, thrift_erl_binary:message_type(), binary(), non_neg_integer(), binary()}.
roundtrip_message(Type, Name, SeqId, Payload) ->
    Message = iolist_to_binary(thrift_erl_json:encode_message(Type, Name, SeqId, Payload)),
    thrift_erl_json:decode_message(Message).
