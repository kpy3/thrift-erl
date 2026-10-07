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

%% Unit tests for the emitter on inline snippets: every generated module
%% must compile in memory, load, and expose the introspection surface.
%% End-to-end calls through generated client/server live in
%% thrift_generator_SUITE.

-module(thrift_generator_emitter_test).

-include_lib("stdlib/include/assert.hrl").
-include_lib("thrift_generator/include/thrift_generator.hrl").
-include_lib("thrift_generator/include/thrift_generator_model.hrl").

-export([
    compile_all_modules_test/0,
    struct_info_descriptor_test/0,
    enum_info_descriptor_test/0,
    function_info_descriptor_test/0,
    service_info_descriptor_test/0,
    record_fields_and_defaults_test/0,
    map_representation_test/0,
    handler_callbacks_test/0,
    source_is_readable_text_test/0
]).

-define(SNIPPET,
    "struct Inner { 1: string name }\n"
    "struct Outer { 1: Inner inner, 2: i32 count = 10 }\n"
    "enum Color { RED, GREEN = 10, BLUE }\n"
    "exception Failed { 1: string reason }\n"
    "service Svc {\n"
    "  void ping(),\n"
    "  i32 area(1: i32 w, 2: i32 h) throws (1: Failed f),\n"
    "  oneway void fire(1: i32 code),\n"
    "  Outer fetch(1: i64 id)\n"
    "}\n"
).

-spec generate() -> [thrift_generator_emitter:compiled()].
generate() ->
    {ok, Doc} = thrift_generator:parse_string(?SNIPPET),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),
    Results.

%%--------------------------------------------------------------------

compile_all_modules_test() ->
    Results = generate(),
    Names = [Name || {ok, Name, _} <- Results],
    ?assertEqual(['Svc_client', 'Svc_handler', 'Svc_server', t_types], lists:sort(Names)),
    ok.

struct_info_descriptor_test() ->
    generate(),
    ?assertEqual(
        {struct, [
            {1, default, {struct, {ref, t_types, <<"Inner">>}}, <<"inner">>, undefined},
            {2, default, {base, i32}, <<"count">>, 10}
        ]},
        t_types:struct_info(<<"Outer">>)
    ),
    ?assertEqual(
        {exception, [{1, default, {base, string}, <<"reason">>, undefined}]},
        t_types:struct_info(<<"Failed">>)
    ),
    ?assertEqual(error, t_types:struct_info(<<"Missing">>)),
    ok.

enum_info_descriptor_test() ->
    generate(),
    ?assertEqual([{0, 'RED'}, {10, 'GREEN'}, {11, 'BLUE'}], t_types:enum_info(<<"Color">>)),
    ?assertEqual(error, t_types:enum_info(<<"Nope">>)),
    ok.

function_info_descriptor_test() ->
    generate(),
    ?assertEqual(
        {struct,
            {struct, [
                {1, default, {base, i32}, <<"w">>, undefined},
                {2, default, {base, i32}, <<"h">>, undefined}
            ]}},
        t_types:function_info(<<"area">>, params)
    ),
    ?assertEqual(false, t_types:function_info(<<"area">>, oneway)),
    ?assertEqual({base, i32}, t_types:function_info(<<"area">>, reply)),
    ?assertEqual(
        [{1, default, {struct, {ref, t_types, <<"Failed">>}}, <<"f">>, undefined}],
        t_types:function_info(<<"area">>, exceptions)
    ),
    %% void functions have no reply descriptor.
    ?assertEqual(undefined, t_types:function_info(<<"ping">>, reply)),
    ?assertEqual([], t_types:function_info(<<"ping">>, exceptions)),
    %% oneway flags propagate; the wire reply type stays undefined.
    ?assertEqual(true, t_types:function_info(<<"fire">>, oneway)),
    ?assertEqual(error, t_types:function_info(<<"nope">>, params)),
    ok.

service_info_descriptor_test() ->
    generate(),
    %% The server module unwraps its service from the types module's
    %% per-file map: the runtime expects a flat function map.
    Info = 'Svc_server':service_info(),
    ?assertEqual([<<"area">>, <<"fetch">>, <<"fire">>, <<"ping">>], lists:sort(maps:keys(Info))),
    ?assertEqual(true, maps:get(oneway, maps:get(<<"fire">>, Info))),
    ?assertEqual({base, i32}, maps:get(reply, maps:get(<<"area">>, Info))),
    %% The types module keeps all services of the file.
    ?assertEqual([<<"Svc">>], maps:keys(t_types:service_info())),
    ok.

record_fields_and_defaults_test() ->
    generate(),
    ?assertEqual({outer, [inner, count]}, t_types:record_fields(<<"Outer">>)),
    ?assertEqual(none, t_types:record_fields(<<"Missing">>)),
    ok.

map_representation_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "struct M { 1: i32 x } (erl.struct_type = \"map\")\n"
    ),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [{ok, t_types, Beam}] = thrift_generator_emitter:compile_sources(Model),
    {module, t_types} = code:load_binary(t_types, "t_types.erl", Beam),
    ?assertEqual(none, t_types:record_fields(<<"M">>)),
    ok.

handler_callbacks_test() ->
    Results = generate(),
    {ok, 'Svc_handler', Beam} = lists:keyfind('Svc_handler', 2, Results),
    {module, 'Svc_handler'} = code:load_binary('Svc_handler', "Svc_handler.erl", Beam),
    ?assertEqual(
        lists:sort([{fire, 1}, {ping, 0}, {fetch, 1}, {area, 2}]),
        lists:sort('Svc_handler':behaviour_info(callbacks))
    ),
    ok.

source_is_readable_text_test() ->
    {ok, Doc} = thrift_generator:parse_string(?SNIPPET),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Sources = thrift_generator_emitter:sources(Model),
    {_, ClientSrc} = lists:keyfind('Svc_client', 1, Sources),
    ?assertMatch(
        {match, _},
        re:run(ClientSrc, <<"area\\(Client, P1, P2\\) -> area\\(Client, P1, P2, 5000\\).">>)
    ),
    {_, TypesSrc} = lists:keyfind(t_types, 1, Sources),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-record\\(outer, \\{inner, count = 10\\}\\).">>)),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"struct_info\\(<<\"Outer\">>\\)">>)),
    ok.
