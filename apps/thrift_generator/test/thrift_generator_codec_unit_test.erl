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

-module(thrift_generator_codec_unit_test).

-moduledoc "Unit tests for protocol-independent codec emitter helpers.".

-include_lib("stdlib/include/assert.hrl").
-include_lib("thrift_generator/include/thrift_generator_model.hrl").

-export([
    colliding_enum_descriptors_test/0,
    equal_enum_descriptors_share_name_test/0,
    used_helpers_empty_test/0,
    used_helpers_nested_transitive_and_duplicate_test/0,
    used_helpers_cycle_test/0,
    codec_pair_names_test/0,
    export_entries_include_protocol_pairs_test/0,
    export_entries_empty_module_test/0
]).

colliding_enum_descriptors_test() ->
    {D1, D2} = find_enum_collision(0, #{}),
    Registry = thrift_generator_codec_common:enum_registry([{enum, D1}, {enum, D2}]),
    ?assertEqual(2, map_size(Registry)),
    ?assertNotEqual(
        thrift_generator_codec_common:type_name({enum, D1}, Registry),
        thrift_generator_codec_common:type_name({enum, D2}, Registry)
    ),
    ok.

equal_enum_descriptors_share_name_test() ->
    Desc = [{1, 'ONE'}],
    Registry = thrift_generator_codec_common:enum_registry([{enum, Desc}, {enum, Desc}]),
    ?assertEqual(1, map_size(Registry)),
    ?assertEqual(<<"enum1">>, thrift_generator_codec_common:type_name({enum, Desc}, Registry)),
    ok.

find_enum_collision(N, _Seen) when N >= 200000 ->
    erlang:error(no_enum_descriptor_collision);
find_enum_collision(N, Seen) ->
    Desc = [{N, 'A'}],
    Hash = erlang:phash2(Desc),
    case Seen of
        #{Hash := Other} ->
            {Other, Desc};
        _ ->
            find_enum_collision(N + 1, Seen#{Hash => Desc})
    end.

used_helpers_empty_test() ->
    ?assertEqual([], thrift_generator_codec_common:used_helpers([], #{})),
    ok.

used_helpers_nested_transitive_and_duplicate_test() ->
    Nested = thrift_generator_codec_ast:call_local(first, [
        thrift_generator_codec_ast:call_local(second, [])
    ]),
    Forms = [Nested, Nested],
    Deps = #{first => [third], second => [third], third => []},
    ?assertEqual(
        [first, second, third],
        lists:sort(thrift_generator_codec_common:used_helpers(Forms, Deps))
    ),
    ok.

used_helpers_cycle_test() ->
    Forms = [thrift_generator_codec_ast:call_local(first, [])],
    Deps = #{first => [second], second => [first]},
    ?assertEqual(
        [first, second],
        lists:sort(thrift_generator_codec_common:used_helpers(Forms, Deps))
    ),
    ok.

codec_pair_names_test() ->
    Empty = #ectx{
        modules = #{<<"demo">> => #tg_module{prefix = <<>>}},
        current = <<"demo">>
    },
    ?assertEqual(
        {encode_ping_request_wire, decode_ping_request_wire},
        thrift_generator_codec_common:codec_pair(wire, <<"PingRequest">>, Empty)
    ),
    Namespaced = Empty#ectx{
        modules = #{<<"demo">> => #tg_module{prefix = <<"my_api">>}}
    },
    ?assertEqual(
        {encode_my_api_ping_request_compact, decode_my_api_ping_request_compact},
        thrift_generator_codec_common:codec_pair(compact, <<"PingRequest">>, Namespaced)
    ),
    ?assertEqual(
        {encode_my_api_ping_request_json, decode_my_api_ping_request_json},
        thrift_generator_codec_common:codec_pair(json, <<"PingRequest">>, Namespaced)
    ),
    ok.

export_entries_include_protocol_pairs_test() ->
    Mod = #tg_module{
        name = <<"demo">>,
        structs = [#tg_struct{kind = struct, name = <<"PingRequest">>}]
    },
    Ctx = #ectx{modules = #{<<"demo">> => Mod}, current = <<"demo">>},
    ?assertEqual(
        [{binary_codec, 1}, {encode_ping_request_wire, 1}, {decode_ping_request_wire, 1}],
        thrift_generator_codec_common:export_entries(wire, Mod, Ctx)
    ),
    ?assertEqual(
        [{compact_codec, 1}, {encode_ping_request_compact, 1}, {decode_ping_request_compact, 1}],
        thrift_generator_codec_common:export_entries(compact, Mod, Ctx)
    ),
    ?assertEqual(
        [
            {json_codec, 1},
            {encode_ping_request_json, 1},
            {decode_ping_request_json, 1},
            {decode_ping_request_json_body, 1}
        ],
        thrift_generator_codec_common:export_entries(json, Mod, Ctx)
    ),
    ok.

export_entries_empty_module_test() ->
    Mod = #tg_module{name = <<"demo">>},
    Ctx = #ectx{modules = #{<<"demo">> => Mod}, current = <<"demo">>},
    ?assertEqual([{binary_codec, 1}], thrift_generator_codec_common:export_entries(wire, Mod, Ctx)),
    ?assertEqual([{compact_codec, 1}], thrift_generator_codec_common:export_entries(compact, Mod, Ctx)),
    ?assertEqual([{json_codec, 1}], thrift_generator_codec_common:export_entries(json, Mod, Ctx)),
    ok.
