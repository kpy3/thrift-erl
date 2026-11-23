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
    export_entries_empty_module_test/0,
    codec_plan_collects_shared_metadata_test/0,
    rpc_plan_preserves_shapes_test/0,
    struct_call_local_binary_encode_test/0,
    struct_call_remote_compact_decode_test/0,
    struct_call_json_decode_body_test/0,
    enum_from_clauses_shared_table_test/0,
    integer_guard_sequence_test/0
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
        structs = [#tg_struct{kind = struct, name = <<"PingRequest">>, fields = []}]
    },
    Ctx = #ectx{modules = #{<<"demo">> => Mod}, current = <<"demo">>},
    Plan = thrift_generator_codec_plan:build(Mod, Ctx),
    ?assertEqual(
        [{binary_codec, 1}, {encode_ping_request_wire, 1}, {decode_ping_request_wire, 1}],
        thrift_generator_codec_common:export_entries(wire, Plan)
    ),
    ?assertEqual(
        [{compact_codec, 1}, {encode_ping_request_compact, 1}, {decode_ping_request_compact, 1}],
        thrift_generator_codec_common:export_entries(compact, Plan)
    ),
    ?assertEqual(
        [
            {json_codec, 1},
            {encode_ping_request_json, 1},
            {decode_ping_request_json, 1},
            {decode_ping_request_json_body, 1}
        ],
        thrift_generator_codec_common:export_entries(json, Plan)
    ),
    ok.

export_entries_empty_module_test() ->
    Mod = #tg_module{name = <<"demo">>},
    Ctx = #ectx{modules = #{<<"demo">> => Mod}, current = <<"demo">>},
    Plan = thrift_generator_codec_plan:build(Mod, Ctx),
    ?assertEqual([{binary_codec, 1}], thrift_generator_codec_common:export_entries(wire, Plan)),
    ?assertEqual([{compact_codec, 1}], thrift_generator_codec_common:export_entries(compact, Plan)),
    ?assertEqual([{json_codec, 1}], thrift_generator_codec_common:export_entries(json, Plan)),
    ok.

codec_plan_collects_shared_metadata_test() ->
    Seq = #tg_field{id = 1, required = required, type = {base, i32, #{}}, name = <<"seq">>, default = undefined},
    State = #tg_field{
        id = 2,
        required = default,
        type = {resolved_ref, <<"demo">>, <<"Status">>, #{}},
        name = <<"state">>,
        default = undefined
    },
    Request = #tg_struct{kind = struct, name = <<"PingRequest">>, fields = [Seq, State]},
    Ping = #tg_function{
        name = <<"ping">>,
        oneway = false,
        return_type = {base, i32, #{}},
        params = [Seq],
        throws = []
    },
    Status = #tg_enum{name = <<"Status">>, values = [{0, <<"ACTIVE">>}]},
    Mod = #tg_module{
        name = <<"demo">>,
        structs = [Request],
        enums = [Status],
        services = [#tg_service{name = <<"Ping">>, functions = [Ping]}]
    },
    Ctx = #ectx{
        modules = #{<<"demo">> => Mod},
        type_modules = #{<<"demo">> => demo_types},
        current = <<"demo">>
    },
    Plan = thrift_generator_codec_plan:build(Mod, Ctx),
    %% one declared entry; its field types are exactly the wire types
    %% struct_info/1 carries in each field descriptor
    [Declared] = Plan#tg_codec_plan.declared,
    ?assertEqual(Request, Declared#tg_codec_struct.struct),
    ?assertEqual(
        [element(3, thrift_generator_ir:field_desc(F, Ctx)) || F <- Request#tg_struct.fields],
        Declared#tg_codec_struct.field_types
    ),
    %% two RPC entries in params/result order
    [Params, Result] = Plan#tg_codec_plan.rpc,
    ?assertEqual(<<"Ping$ping$params">>, Params#tg_codec_struct.struct#tg_struct.name),
    ?assertEqual(<<"Ping$ping$result">>, Result#tg_codec_struct.struct#tg_struct.name),
    ?assertEqual([{base, i32}], Params#tg_codec_struct.field_types),
    ?assertEqual([{base, i32}], Result#tg_codec_struct.field_types),
    %% the flattened inventory keeps the declared-fields-first order
    ?assertEqual(
        Declared#tg_codec_struct.field_types ++
            Params#tg_codec_struct.field_types ++
            Result#tg_codec_struct.field_types,
        Plan#tg_codec_plan.wire_types
    ),
    %% one shared enum registry over the whole inventory
    ?assertEqual(1, map_size(Plan#tg_codec_plan.enums)),
    ?assertEqual(
        thrift_generator_codec_common:enum_registry(Plan#tg_codec_plan.wire_types),
        Plan#tg_codec_plan.enums
    ),
    %% the existing three protocol codec names, for declared and RPC structs
    ?assertEqual(
        {encode_ping_request_wire, decode_ping_request_wire},
        thrift_generator_codec_plan:codec_pair(wire, <<"PingRequest">>, Plan)
    ),
    ?assertEqual(
        {encode_ping_request_compact, decode_ping_request_compact},
        thrift_generator_codec_plan:codec_pair(compact, <<"PingRequest">>, Plan)
    ),
    ?assertEqual(
        {encode_ping_request_json, decode_ping_request_json},
        thrift_generator_codec_plan:codec_pair(json, <<"PingRequest">>, Plan)
    ),
    ?assertEqual(
        {'encode_ping$ping$params_wire', 'decode_ping$ping$params_wire'},
        thrift_generator_codec_plan:codec_pair(wire, <<"Ping$ping$params">>, Plan)
    ),
    ok.

rpc_plan_preserves_shapes_test() ->
    Payload = #tg_field{
        id = 1,
        required = required,
        type = {base, binary, #{}},
        name = <<"payload">>,
        default = undefined
    },
    Event = #tg_struct{kind = struct, name = <<"Event">>, fields = [Payload]},
    Note = #tg_field{
        id = 1,
        required = default,
        type = {base, string, #{}},
        name = <<"note">>,
        default = undefined
    },
    Notify = #tg_function{
        name = <<"notify">>,
        oneway = true,
        return_type = void,
        params = [Note],
        throws = []
    },
    Mod = #tg_module{
        name = <<"demo">>,
        structs = [Event],
        services = [#tg_service{name = <<"Events">>, functions = [Notify]}]
    },
    Ctx = #ectx{
        modules = #{<<"demo">> => Mod},
        type_modules = #{<<"demo">> => demo_types},
        current = <<"demo">>
    },
    Plan = thrift_generator_codec_plan:build(Mod, Ctx),
    %% oneway contributes only the params struct
    [OnlyParams] = Plan#tg_codec_plan.rpc,
    ?assertEqual(<<"Events$notify$params">>, OnlyParams#tg_codec_struct.struct#tg_struct.name),
    ?assertEqual([{base, string}], OnlyParams#tg_codec_struct.field_types),
    %% declared structs precede RPC structs in every ordered plan view
    Names = [
        CS#tg_codec_struct.struct#tg_struct.name
     || CS <- Plan#tg_codec_plan.declared ++ Plan#tg_codec_plan.rpc
    ],
    ?assertEqual([<<"Event">>, <<"Events$notify$params">>], Names),
    ?assertEqual([{base, binary}, {base, string}], Plan#tg_codec_plan.wire_types),
    ok.

%% A plan over a two-module context: `demo` (being generated, one
%% declared struct) and `other` (referenced cross-module).
struct_call_plan() ->
    Request = #tg_struct{kind = struct, name = <<"PingRequest">>, fields = []},
    Mod = #tg_module{name = <<"demo">>, prefix = <<>>, structs = [Request]},
    Other = #tg_module{name = <<"other">>, prefix = <<>>},
    Ctx = #ectx{
        modules = #{<<"demo">> => Mod, <<"other">> => Other},
        type_modules = #{<<"demo">> => demo_types, <<"other">> => other_types},
        current = <<"demo">>
    },
    thrift_generator_codec_plan:build(Mod, Ctx).

struct_call_local_binary_encode_test() ->
    Plan = struct_call_plan(),
    V = thrift_generator_codec_ast:v("V"),
    %% a same-module reference becomes a direct local sibling call
    ?assertEqual(
        thrift_generator_codec_ast:call_local(encode_ping_request_wire, [V]),
        thrift_generator_codec_plan:struct_call(wire, encode, demo_types, <<"PingRequest">>, V, Plan)
    ),
    ok.

struct_call_remote_compact_decode_test() ->
    Plan = struct_call_plan(),
    Bin = thrift_generator_codec_ast:v("Bin"),
    %% a cross-module reference calls the target types module directly,
    %% with the target's own (here: empty) namespace prefix
    ?assertEqual(
        thrift_generator_codec_ast:remote(other_types, decode_widget_compact, [Bin]),
        thrift_generator_codec_plan:struct_call(compact, decode, other_types, <<"Widget">>, Bin, Plan)
    ),
    ok.

struct_call_json_decode_body_test() ->
    Plan = struct_call_plan(),
    V = thrift_generator_codec_ast:v("V"),
    Bin = thrift_generator_codec_ast:v("Bin"),
    %% JSON encode stays on the plain name in both directions...
    ?assertEqual(
        thrift_generator_codec_ast:call_local(encode_ping_request_json, [V]),
        thrift_generator_codec_plan:struct_call(json, encode, demo_types, <<"PingRequest">>, V, Plan)
    ),
    ?assertEqual(
        thrift_generator_codec_ast:remote(other_types, encode_widget_json, [V]),
        thrift_generator_codec_plan:struct_call(json, encode, other_types, <<"Widget">>, V, Plan)
    ),
    %% ...while JSON decode selects the `_body` companion locally
    ?assertEqual(
        thrift_generator_codec_ast:call_local(decode_ping_request_json_body, [Bin]),
        thrift_generator_codec_plan:struct_call(json, decode, demo_types, <<"PingRequest">>, Bin, Plan)
    ),
    %% ...and remotely
    ?assertEqual(
        thrift_generator_codec_ast:remote(other_types, decode_widget_json_body, [Bin]),
        thrift_generator_codec_plan:struct_call(json, decode, other_types, <<"Widget">>, Bin, Plan)
    ),
    ok.

enum_from_clauses_shared_table_test() ->
    Int = thrift_generator_codec_ast:v("Int"),
    R = thrift_generator_codec_ast:v("R"),
    ?assertEqual(
        [
            thrift_generator_codec_ast:clause([thrift_generator_codec_ast:i(1)], none, [
                thrift_generator_codec_ast:ok3(thrift_generator_codec_ast:at('ONE'), R)
            ]),
            thrift_generator_codec_ast:clause([thrift_generator_codec_ast:i(2)], none, [
                thrift_generator_codec_ast:ok3(thrift_generator_codec_ast:at('TWO'), R)
            ]),
            thrift_generator_codec_ast:clause([thrift_generator_codec_ast:v("_")], none, [
                thrift_generator_codec_ast:ok3(Int, R)
            ])
        ],
        thrift_generator_codec_ast:enum_from_clauses([{1, 'ONE'}, {2, 'TWO'}], Int, R)
    ),
    ok.

integer_guard_sequence_test() ->
    V = thrift_generator_codec_ast:v("V"),
    A = erl_anno:new(0),
    ?assertEqual(
        [
            {call, A, {remote, A, {atom, A, erlang}, {atom, A, is_integer}}, [V]},
            {op, A, '>=', V, {integer, A, -128}},
            {op, A, '=<', V, {integer, A, 127}}
        ],
        thrift_generator_codec_ast:integer_guard(i8, V)
    ),
    ok.
