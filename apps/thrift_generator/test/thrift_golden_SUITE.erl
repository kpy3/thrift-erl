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

-module(thrift_golden_SUITE).

-moduledoc """
Golden interop against the official Apache Thrift Erlang runtime
(vendored, pinned 0.25.0 — see `vendor/apache-thrift-erl`).

The committed files in `thrift_golden_SUITE_data/gen-erl` were produced
by the pinned official compiler 0.25.0 and are compiled at test time.
Our side is generated in memory from the same fixture
`thrift_golden_SUITE_data/ThriftTest.thrift` — the upstream ThriftTest
without the `uuid` base type, which the official Erlang generator
does not support (see the fixture header for details).
Three scenarios:

- our generated client against the official runtime's server (buffered —
  the official `thrift_server` is hard-wired to buffered);
- the official client against our server, buffered and framed.

Each scenario exercises primitives, nested structs, maps/sets/lists,
enums, typedefs, deep `testMapMap` nesting, declared exceptions in every
branch and a oneway call followed by more traffic on the same
connection.
""".

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").
-include_lib("thrift/include/golden/gen-erl/thrift_test_types.hrl").
-include("thrift_golden_records.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    our_client_official_server/1,
    official_client_our_server_buffered/1,
    official_client_our_server_framed/1,
    official_compact_client_our_server_buffered/1,
    official_compact_client_our_server_framed/1,
    official_json_client_our_server_buffered/1,
    official_json_client_our_server_framed/1,
    official_http_client_our_server/1,
    official_multiplexed_client_our_multiplexed_server/1
]).

-define(CLIENT_TIMEOUT, 10000).

all() ->
    [
        our_client_official_server,
        official_client_our_server_buffered,
        official_client_our_server_framed,
        official_compact_client_our_server_buffered,
        official_compact_client_our_server_framed,
        official_json_client_our_server_buffered,
        official_json_client_our_server_framed,
        official_http_client_our_server,
        official_multiplexed_client_our_multiplexed_server
    ].

init_per_suite(Config) ->
    %% The committed official generated code lives with the vendored
    %% official runtime (`thrift/include/golden/gen-erl`, copied into
    %% the build directory with the app); `code:lib_dir` points at the
    %% build copy in the test profile. The fixture is a reference
    %% artifact: nothing compiles it except this suite.
    GenDir = filename:join(code:lib_dir(thrift), "include/golden/gen-erl"),
    ok = compile_official_generated(GenDir, priv_dir(Config)),
    DataDir = proplists:get_value(data_dir, Config),
    ok = load_our_thrift_test_modules(DataDir),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Scenarios
%%--------------------------------------------------------------------

%% Our generated client <-> the vendored official server.
our_client_official_server(_Config) ->
    Port = free_port(),
    {ok, Server} = thrift_server:start_link(Port, thrift_test_thrift, thrift_golden_official_handler),
    {ok, Client} =
        goldentest_thrift_test_client:start_link(#{host => "127.0.0.1", port => Port, transport => buffered}),
    try
        true = register(thrift_golden_oneway_sink, self()),
        run_our_client_assertions(Client)
    after
        unregister(thrift_golden_oneway_sink),
        ok = goldentest_thrift_test_client:stop(Client),
        %% Unlink first: `thrift_server:stop/1` terminates the linked
        %% server with reason `stopped`, which would otherwise replace
        %% the test result (or a failure in the body) with `{'EXIT',
        %% stopped}`.
        true = unlink(Server),
        ok = thrift_server:stop(Server)
    end.

%% The official client <-> our server, buffered.
official_client_our_server_buffered(_Config) ->
    official_client_scenario(buffered).

%% The official client <-> our server, framed.
official_client_our_server_framed(_Config) ->
    official_client_scenario(framed).

%% The official compact client (`thrift_compact_protocol': zigzag
%% varints, delta field headers, nibble-packed collections) <-> our
%% compact server, on both transports. Full assertion battery: scalars,
%% doubles, nested structs, maps/sets/lists, an exception and a oneway.

official_compact_client_our_server_buffered(_Config) ->
    official_client_scenario(buffered, compact).

official_compact_client_our_server_framed(_Config) ->
    official_client_scenario(framed, compact).

%% The official JSON client (`thrift_json_protocol': every value a JSON
%% document whose shape carries the Thrift types) <-> our JSON server,
%% on both transports. Full assertion battery: scalars, doubles with
%% their 16-digit form, nested structs, maps as objects with stringified
%% keys, sets, lists, exceptions and a oneway.

official_json_client_our_server_buffered(_Config) ->
    official_client_scenario(buffered, json).

official_json_client_our_server_framed(_Config) ->
    official_client_scenario(framed, json).

%% The official HTTP client (`thrift_http_transport': one POST per
%% message through httpc, the binary protocol in the body) <-> our HTTP
%% server. The full assertion battery, including the oneway — whose
%% (empty) HTTP response the official side never reads, which must not
%% desync the next call.

official_http_client_our_server(_Config) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, Server} =
        goldentest_thrift_test_server:start_link(#{
            port => 0, handler => thrift_golden_our_handler, transport => http
        }),
    {ok, Port} = goldentest_thrift_test_server:port(Server),
    {ok, HttpTransport} = thrift_http_transport:new(
        "127.0.0.1:" ++ integer_to_list(Port),
        "/thrift/test",
        [{http_options, [{timeout, ?CLIENT_TIMEOUT}]}]
    ),
    {ok, Protocol0} = thrift_binary_protocol:new(HttpTransport),
    {ok, Client0} = thrift_client:new(Protocol0, thrift_test_thrift),
    try
        true = register(thrift_golden_oneway_sink, self()),
        run_official_client_assertions(Client0)
    after
        unregister(thrift_golden_oneway_sink),
        try
            thrift_client:close(Client0)
        catch
            _:_ -> ok
        end,
        ok = goldentest_thrift_test_server:stop(Server)
    end.

%% The official multiplexed client (`thrift_multiplexed_protocol' wraps
%% the binary protocol and prefixes every outgoing message name with
%% `ThriftTest:') <-> our multiplexed server hosting the service under
%% the same name. Wire-level proof that the `Service:' convention
%% matches the official implementation: calls, an exception and a
%% oneway over the shared connection.

official_multiplexed_client_our_multiplexed_server(_Config) ->
    {ok, Server} =
        goldentest_thrift_test_server:start_link(#{
            port => 0,
            %% The official multiplexed client is buffered by default.
            transport => buffered,
            services =>
                #{<<"ThriftTest">> => #{handler => thrift_golden_our_handler, service => goldentest_thrift_test_server}}
        }),
    {ok, Port} = goldentest_thrift_test_server:port(Server),
    {ok, [{_ServiceName, Client0}]} =
        thrift_client_util:new_multiplexed("127.0.0.1", Port, [{"ThriftTest", thrift_test_thrift}], [
            {recv_timeout, ?CLIENT_TIMEOUT}
        ]),
    try
        true = register(thrift_golden_oneway_sink, self()),
        {C1, {ok, <<"foo">>}} = thrift_client:call(Client0, testString, [<<"foo">>]),
        {C2, {ok, -42}} = thrift_client:call(C1, testByte, [-42]),
        {C3, {ok, 123456789012}} = thrift_client:call(C2, testI64, [123456789012]),

        X = #'thrift.test.Xtruct'{string_thing = <<"hi">>, byte_thing = -1, i32_thing = 7, i64_thing = 99},
        {C4, {ok, X}} = thrift_client:call(C3, testStruct, [X]),

        {C5, {ok, ok}} = thrift_client:call(C4, testException, [<<"fine">>]),
        {C6, {exception, Xception}} =
            try thrift_client:call(C5, testException, [<<"Xception">>]) of
                Unexpected -> erlang:error({unexpected_success, Unexpected})
            catch
                _:{_, {exception, _}} = Thrown -> Thrown
            end,
        ?assertEqual({'thrift.test.Xception', 1001, <<"Xception">>}, Xception),

        %% Oneway fires the sink; the connection stays usable afterwards.
        {_C7, {ok, ok}} = thrift_client:call(C6, testOneway, [1]),
        receive
            {fired, 1} -> ok
        after ?CLIENT_TIMEOUT ->
            erlang:error(oneway_not_delivered)
        end,
        {_C8, {ok, <<"after oneway">>}} = thrift_client:call(C6, testString, [<<"after oneway">>])
    after
        unregister(thrift_golden_oneway_sink),
        try
            thrift_client:close(Client0)
        catch
            _:_ -> ok
        end,
        ok = goldentest_thrift_test_server:stop(Server)
    end.

%%--------------------------------------------------------------------
%% Our client against the official server
%%--------------------------------------------------------------------

run_our_client_assertions(Client) ->
    ?assertEqual({ok, <<"foo">>}, goldentest_thrift_test_client:testString(Client, <<"foo">>)),
    ?assertEqual({ok, true}, goldentest_thrift_test_client:testBool(Client, true)),
    ?assertEqual({ok, false}, goldentest_thrift_test_client:testBool(Client, false)),
    ?assertEqual({ok, -42}, goldentest_thrift_test_client:testByte(Client, -42)),
    ?assertEqual({ok, 123456}, goldentest_thrift_test_client:testI32(Client, 123456)),
    ?assertEqual({ok, 123456789012}, goldentest_thrift_test_client:testI64(Client, 123456789012)),
    ?assertEqual({ok, 3.25}, goldentest_thrift_test_client:testDouble(Client, 3.25)),
    ?assertEqual({ok, <<1, 2, 3>>}, goldentest_thrift_test_client:testBinary(Client, <<1, 2, 3>>)),

    X = #goldentest_xtruct{string_thing = <<"hi">>, byte_thing = -1, i32_thing = 7, i64_thing = 99},
    ?assertEqual({ok, X}, goldentest_thrift_test_client:testStruct(Client, X)),
    X2 = #goldentest_xtruct2{byte_thing = 5, struct_thing = X, i32_thing = 77},
    ?assertEqual({ok, X2}, goldentest_thrift_test_client:testNest(Client, X2)),

    ?assertEqual({ok, #{1 => 10, 2 => 20}}, goldentest_thrift_test_client:testMap(Client, #{1 => 10, 2 => 20})),
    %% The official handler echoes the set through `sets`, so element
    %% order comes back in `sets` iteration order.
    {ok, ResultSet} = goldentest_thrift_test_client:testSet(Client, [1, 2, 3]),
    ?assertEqual([1, 2, 3], lists:sort(ResultSet)),
    ?assertEqual({ok, [1, 2, 3]}, goldentest_thrift_test_client:testList(Client, [1, 2, 3])),
    ?assertEqual({ok, 'SIX'}, goldentest_thrift_test_client:testEnum(Client, 'SIX')),
    ?assertEqual({ok, 77}, goldentest_thrift_test_client:testTypedef(Client, 77)),

    ExpectedMapMap =
        #{
            -4 => #{J => J || J <- lists:seq(-4, -1)},
            4 => #{J => J || J <- lists:seq(1, 4)}
        },
    ?assertEqual({ok, ExpectedMapMap}, goldentest_thrift_test_client:testMapMap(Client, 2)),

    ?assertEqual(
        {error, {exception, #goldentest_xception{errorCode = 1001, message = <<"Xception">>}}},
        goldentest_thrift_test_client:testException(Client, <<"Xception">>)
    ),
    ?assertEqual({ok, undefined}, goldentest_thrift_test_client:testException(Client, <<"fine">>)),

    ?assertEqual(
        {error, {exception, #goldentest_xception{errorCode = 1001, message = <<"This is not Xception2">>}}},
        goldentest_thrift_test_client:testMultiException(Client, <<"Xception">>, <<"x">>)
    ),
    ?assertEqual(
        {error,
            {exception, #goldentest_xception2{
                errorCode = 2002, struct_thing = #goldentest_xtruct{string_thing = <<"y">>}
            }}},
        goldentest_thrift_test_client:testMultiException(Client, <<"Xception2">>, <<"y">>)
    ),
    ?assertEqual(
        {ok, #goldentest_xtruct{string_thing = <<"y">>}},
        goldentest_thrift_test_client:testMultiException(Client, <<"fine">>, <<"y">>)
    ),

    %% Oneway fires the sink; the connection stays usable afterwards.
    ?assertEqual(ok, goldentest_thrift_test_client:testOneway(Client, 1)),
    receive
        {fired, 1} -> ok
    after ?CLIENT_TIMEOUT ->
        erlang:error(oneway_not_delivered)
    end,
    ?assertEqual({ok, <<"after oneway">>}, goldentest_thrift_test_client:testString(Client, <<"after oneway">>)).

%%--------------------------------------------------------------------
%% Official client against our server
%%--------------------------------------------------------------------

official_client_scenario(Transport) ->
    official_client_scenario(Transport, binary).

official_client_scenario(Transport, Protocol) ->
    {ok, Server} =
        goldentest_thrift_test_server:start_link(#{
            port => 0, handler => thrift_golden_our_handler, transport => Transport, protocol => Protocol
        }),
    {ok, Port} = goldentest_thrift_test_server:port(Server),
    {ok, Client0} =
        thrift_client_util:new("127.0.0.1", Port, thrift_test_thrift, [
            {protocol, Protocol}, {framed, Transport =:= framed}, {recv_timeout, ?CLIENT_TIMEOUT}
        ]),
    try
        true = register(thrift_golden_oneway_sink, self()),
        run_official_client_assertions(Client0)
    after
        unregister(thrift_golden_oneway_sink),
        try
            thrift_client:close(Client0)
        catch
            _:_ -> ok
        end,
        ok = goldentest_thrift_test_server:stop(Server)
    end.

run_official_client_assertions(C0) ->
    {C1, {ok, <<"foo">>}} = thrift_client:call(C0, testString, [<<"foo">>]),
    {C2, {ok, true}} = thrift_client:call(C1, testBool, [true]),
    {C3, {ok, -42}} = thrift_client:call(C2, testByte, [-42]),
    {C4, {ok, 123456}} = thrift_client:call(C3, testI32, [123456]),
    {C5, {ok, 123456789012}} = thrift_client:call(C4, testI64, [123456789012]),
    {C6, {ok, 3.25}} = thrift_client:call(C5, testDouble, [3.25]),
    {C7, {ok, <<1, 2, 3>>}} = thrift_client:call(C6, testBinary, [<<1, 2, 3>>]),

    X = #'thrift.test.Xtruct'{string_thing = <<"hi">>, byte_thing = -1, i32_thing = 7, i64_thing = 99},
    {C8, {ok, X}} = thrift_client:call(C7, testStruct, [X]),
    X2 = #'thrift.test.Xtruct2'{byte_thing = 5, struct_thing = X, i32_thing = 77},
    {C9, {ok, X2}} = thrift_client:call(C8, testNest, [X2]),

    {C10, {ok, MapDict}} =
        thrift_client:call(C9, testMap, [dict:from_list([{1, 10}, {2, 20}])]),
    ?assertEqual([{1, 10}, {2, 20}], lists:sort(dict:to_list(MapDict))),
    %% The official runtime hands sets back as `sets` collections.
    {C11, {ok, ResultSet}} = thrift_client:call(C10, testSet, [sets:from_list([1, 2, 3])]),
    true = sets:is_set(ResultSet),
    ?assertEqual([1, 2, 3], lists:sort(sets:to_list(ResultSet))),
    {C12, {ok, [1, 2, 3]}} = thrift_client:call(C11, testList, [[1, 2, 3]]),

    %% Enum values cross the wire as ints; each side applies its own
    %% atom mapping (theirs none).
    {C13, {ok, 6}} = thrift_client:call(C12, testEnum, [6]),
    {C14, {ok, 77}} = thrift_client:call(C13, testTypedef, [77]),

    {C15, {ok, MapMap}} = thrift_client:call(C14, testMapMap, [2]),
    ok = assert_official_map_map(MapMap),

    {C16, {ok, ok}} = thrift_client:call(C15, testException, [<<"fine">>]),
    {C17, {exception, Xception1}} =
        try thrift_client:call(C16, testException, [<<"Xception">>]) of
            Unexpected -> erlang:error({unexpected_success, Unexpected})
        catch
            _:{_, {exception, _}} = Thrown -> Thrown
        end,
    ?assertEqual({'thrift.test.Xception', 1001, <<"Xception">>}, Xception1),

    {C18, {exception, Xception2}} =
        try thrift_client:call(C17, testMultiException, [<<"Xception">>, <<"x">>]) of
            Unexpected2 -> erlang:error({unexpected_success, Unexpected2})
        catch
            _:{_, {exception, _}} = Thrown2 -> Thrown2
        end,
    ?assertEqual({'thrift.test.Xception', 1001, <<"This is not Xception2">>}, Xception2),

    {C19, {exception, Xception2b}} =
        try thrift_client:call(C18, testMultiException, [<<"Xception2">>, <<"y">>]) of
            Unexpected3 -> erlang:error({unexpected_success, Unexpected3})
        catch
            _:{_, {exception, _}} = Thrown3 -> Thrown3
        end,
    ?assertEqual(
        {'thrift.test.Xception2', 2002, #'thrift.test.Xtruct'{string_thing = <<"y">>}},
        Xception2b
    ),

    {C20, {ok, #'thrift.test.Xtruct'{string_thing = <<"y">>}}} =
        thrift_client:call(C19, testMultiException, [<<"fine">>, <<"y">>]),

    %% Oneway fires the sink; the connection stays usable afterwards.
    {_C21, {ok, ok}} = thrift_client:call(C20, testOneway, [1]),
    receive
        {fired, 1} -> ok
    after ?CLIENT_TIMEOUT ->
        erlang:error(oneway_not_delivered)
    end,
    {_C22, {ok, <<"after oneway">>}} = thrift_client:call(C20, testString, [<<"after oneway">>]).

assert_official_map_map(MapMap) ->
    ?assertEqual([-4, 4], lists:sort(dict:fetch_keys(MapMap))),
    Neg = dict:fetch(-4, MapMap),
    ?assertEqual([{J, J} || J <- lists:seq(-4, -1)], lists:sort(dict:to_list(Neg))),
    Pos = dict:fetch(4, MapMap),
    ?assertEqual([{J, J} || J <- lists:seq(1, 4)], lists:sort(dict:to_list(Pos))).

%%--------------------------------------------------------------------
%% Setup helpers
%%--------------------------------------------------------------------

priv_dir(Config) ->
    proplists:get_value(priv_dir, Config).

%% Compiles the committed officially generated sources in memory and
%% loads them. They only need their own headers, which sit next to them.
compile_official_generated(GenDir, _PrivDir) ->
    Files = filelib:wildcard(filename:join(GenDir, "*.erl")),
    ?assertNotEqual([], Files),
    lists:foreach(
        fun(File) ->
            case compile:file(File, [binary, {i, GenDir}, report_errors, return_errors]) of
                %% `binary` mode returns without the warnings element
                {ok, Module, Beam} ->
                    {module, Module} = code:load_binary(Module, File, Beam);
                {error, Errors, _Warnings} ->
                    erlang:error({official_compile_failed, File, Errors})
            end
        end,
        Files
    ),
    ok.

%% Generates and loads OUR modules for the same ThriftTest fixture the
%% official gen-erl was compiled from (the no-uuid variant in the suite
%% data dir). Our side is renamed as a whole: the committed official
%% code owns `thrift_test_types` (from the same `namespace * thrift.test`),
%% so module and the namespace-derived identifier prefix both become
%% `goldentest` and the two generations coexist in the test VM.
load_our_thrift_test_modules(DataDir) ->
    ThriftFile = filename:join(DataDir, "ThriftTest.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(ThriftFile),
    {ok, Model0} = thrift_generator_semantic:analyze(Loaded),
    Model = Model0#tg_model{
        modules = [
            Mod#tg_module{name = <<"goldentest">>, prefix = <<"goldentest">>}
         || Mod <- Model0#tg_model.modules
        ]
    },
    Beams = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) ->
                {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam);
            ({error, Reason}) ->
                erlang:error({our_compile_failed, Reason})
        end,
        Beams
    ),
    ok.

free_port() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.
