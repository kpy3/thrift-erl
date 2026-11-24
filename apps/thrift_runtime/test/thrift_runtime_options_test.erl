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

%% Unit tests for the strict endpoint option normalizers of
%% `thrift_runtime_options`: plain client, reconnecting client, server,
%% acceptor and graceful stop. The tests pin the exact error terms, the
%% deterministic unknown/missing ordering, the full normalized default
%% maps and every accepted value family.

-module(thrift_runtime_options_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    client_error_terms_test/0,
    client_defaults_test/0,
    client_timeout_precedence_test/0,
    client_value_families_test/0,
    server_mode_test/0,
    server_defaults_test/0,
    server_value_families_test/0,
    acceptor_options_test/0,
    reconnecting_options_test/0,
    stop_options_test/0
]).

%%--------------------------------------------------------------------
%% Plain client
%%--------------------------------------------------------------------

client_error_terms_test() ->
    Base = #{host => "localhost", port => 9090, service => svc},
    ?assertEqual(
        {error, {bad_option, {options, bad, [map]}}}, thrift_runtime_options:client_options(bad)
    ),
    ?assertEqual({error, {missing_option, host}}, thrift_runtime_options:client_options(#{})),
    ?assertEqual(
        {error, {missing_option, port}}, thrift_runtime_options:client_options(#{host => "localhost"})
    ),
    ?assertEqual(
        {error, {missing_option, service}},
        thrift_runtime_options:client_options(#{host => "localhost", port => 9090})
    ),
    %% unknown keys report the first one in sorted order
    ?assertEqual(
        {error, {unknown_option, aaa}},
        thrift_runtime_options:client_options(Base#{zzz => true, aaa => 1})
    ),
    ?assertEqual(
        {error, {bad_option, {transport, unix, [framed, buffered, http]}}},
        thrift_runtime_options:client_options(Base#{transport => unix})
    ),
    %% protocol errors come straight from the protocol axis
    ?assertEqual(
        {error, {bad_protocol, <<"binary">>}},
        thrift_runtime_options:client_options(Base#{protocol => <<"binary">>})
    ),
    %% server-only keys are unknown on a client
    ?assertEqual(
        {error, {unknown_option, handshake_timeout}},
        thrift_runtime_options:client_options(Base#{handshake_timeout => 1000})
    ),
    ok.

client_defaults_test() ->
    ?assertEqual(
        {ok, client_normalized()},
        thrift_runtime_options:client_options(#{host => "localhost", port => 9090, service => svc})
    ),
    %% the named axis values resolve to their modules
    ?assertMatch(
        {ok, #{protocol := thrift_runtime_compact}},
        thrift_runtime_options:client_options(#{host => "h", port => 1, service => svc, protocol => compact})
    ),
    ?assertMatch(
        {ok, #{protocol := thrift_runtime_json}},
        thrift_runtime_options:client_options(#{host => "h", port => 1, service => svc, protocol => json})
    ),
    %% a custom module must exist and export the protocol callbacks
    ?assertMatch(
        {error, {bad_protocol, no_such_protocol_xyz, _}},
        thrift_runtime_options:client_options(#{
            host => "h",
            port => 1,
            service => svc,
            protocol => no_such_protocol_xyz
        })
    ),
    ok.

client_timeout_precedence_test() ->
    Base = #{host => "h", port => 1, service => svc},
    {ok, #{timeout := 1000, connect_timeout := 1000}} =
        thrift_runtime_options:client_options(Base#{timeout => 1000}),
    {ok, #{timeout := 5000, connect_timeout := 2000}} =
        thrift_runtime_options:client_options(Base#{connect_timeout => 2000}),
    %% the specific key wins while the umbrella stays available
    {ok, #{timeout := 1000, connect_timeout := 2000}} =
        thrift_runtime_options:client_options(Base#{timeout => 1000, connect_timeout => 2000}),
    ?assertEqual(
        {error, {bad_option, {timeout, 0, [pos_integer, infinity]}}},
        thrift_runtime_options:client_options(Base#{timeout => 0})
    ),
    ?assertEqual(
        {error, {bad_option, {connect_timeout, soon, [pos_integer, infinity]}}},
        thrift_runtime_options:client_options(Base#{connect_timeout => soon})
    ),
    ok.

client_value_families_test() ->
    Base = #{host => "h", port => 1, service => svc},
    %% every host form the socket layer accepts stays valid
    [
        {ok, #{host := H}} = thrift_runtime_options:client_options(Base#{host := H})
     || H <- ["localhost", <<"localhost">>, localhost, {127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
    ],
    %% the port range
    {ok, #{port := 0}} = thrift_runtime_options:client_options(Base#{port := 0}),
    {ok, #{port := 65535}} = thrift_runtime_options:client_options(Base#{port := 65535}),
    ?assertEqual(
        {error, {bad_option, {port, 65536, [port]}}},
        thrift_runtime_options:client_options(Base#{port := 65536})
    ),
    ?assertEqual(
        {error, {bad_option, {port, -1, [port]}}},
        thrift_runtime_options:client_options(Base#{port := -1})
    ),
    %% service is an atom only, never loaded or invoked
    ?assertEqual(
        {error, {bad_option, {service, <<"svc">>, [module]}}},
        thrift_runtime_options:client_options(Base#{service := <<"svc">>})
    ),
    %% the transport enum
    {ok, #{transport := buffered}} = thrift_runtime_options:client_options(Base#{transport => buffered}),
    {ok, #{transport := http}} = thrift_runtime_options:client_options(Base#{transport => http}),
    %% positive-integer limits, and the queue depth that also takes infinity
    {ok, #{max_frame_size := 1, active_n := 1, max_queue_depth := 7}} =
        thrift_runtime_options:client_options(Base#{
            max_frame_size => 1,
            active_n => 1,
            max_queue_depth => 7
        }),
    {ok, #{max_queue_depth := infinity}} =
        thrift_runtime_options:client_options(Base#{max_queue_depth => infinity}),
    ?assertEqual(
        {error, {bad_option, {max_frame_size, 0, [pos_integer]}}},
        thrift_runtime_options:client_options(Base#{max_frame_size => 0})
    ),
    ?assertEqual(
        {error, {bad_option, {active_n, 0, [pos_integer]}}},
        thrift_runtime_options:client_options(Base#{active_n => 0})
    ),
    ?assertEqual(
        {error, {bad_option, {max_queue_depth, 0, [pos_integer, infinity]}}},
        thrift_runtime_options:client_options(Base#{max_queue_depth => 0})
    ),
    %% binary HTTP path and multiplex name
    {ok, #{http_path := <<"/rpc">>, multiplex := <<"svc">>}} =
        thrift_runtime_options:client_options(Base#{http_path => <<"/rpc">>, multiplex => <<"svc">>}),
    ?assertEqual(
        {error, {bad_option, {http_path, "/rpc", [binary]}}},
        thrift_runtime_options:client_options(Base#{http_path => "/rpc"})
    ),
    ?assertEqual(
        {error, {bad_option, {multiplex, svc, [undefined, binary]}}},
        thrift_runtime_options:client_options(Base#{multiplex => svc})
    ),
    %% TLS options: a list, or the explicit `undefined'
    {ok, #{ssl_opts := []}} = thrift_runtime_options:client_options(Base#{ssl_opts => []}),
    {ok, #{ssl_opts := undefined}} = thrift_runtime_options:client_options(Base#{ssl_opts => undefined}),
    ?assertEqual(
        {error, {bad_option, {ssl_opts, true, [undefined, list]}}},
        thrift_runtime_options:client_options(Base#{ssl_opts => true})
    ),
    %% the observability handler: undefined, a fun of arity one or {M, F, A}
    Fun = fun(_Event) -> ok end,
    Mfa = {?MODULE, handle_event, [self()]},
    {ok, #{on_event := Fun}} = thrift_runtime_options:client_options(Base#{on_event => Fun}),
    {ok, #{on_event := Mfa}} = thrift_runtime_options:client_options(Base#{on_event => Mfa}),
    BadFun = fun() -> ok end,
    ?assertEqual(
        {error, {bad_option, {on_event, BadFun, [undefined, 'fun', mfa]}}},
        thrift_runtime_options:client_options(Base#{on_event => BadFun})
    ),
    ?assertEqual(
        {error, {bad_option, {on_event, {m, f}, [undefined, 'fun', mfa]}}},
        thrift_runtime_options:client_options(Base#{on_event => {m, f}})
    ),
    ok.

%% The full normalized map of a minimal client, shared with the
%% reconnecting-client assertions.

client_normalized() ->
    #{
        host => "localhost",
        port => 9090,
        service => svc,
        transport => framed,
        protocol => thrift_runtime_binary,
        timeout => 5000,
        connect_timeout => 5000,
        max_frame_size => 64 * 1024 * 1024,
        active_n => 100,
        max_queue_depth => infinity,
        http_path => <<"/">>,
        ssl_opts => undefined,
        multiplex => undefined,
        on_event => undefined
    }.

%%--------------------------------------------------------------------
%% Server and acceptor
%%--------------------------------------------------------------------

server_mode_test() ->
    ?assertEqual({error, {missing_option, port}}, thrift_runtime_options:server_options(#{})),
    ?assertEqual(
        {error, {missing_option, service}}, thrift_runtime_options:server_options(#{port => 0})
    ),
    %% the single mode reports its missing keys in `service', then `handler' order
    ?assertEqual(
        {error, {missing_option, handler}},
        thrift_runtime_options:server_options(#{port => 0, service => svc})
    ),
    {ok, #{name := my_server}} = thrift_runtime_options:server_options(
        #{port => 0, service => svc, handler => hdl, name => my_server}
    ),
    %% mixing the single and multiplex modes rejects the services value
    Services = #{<<"First">> => #{handler => h1, service => s1}},
    ?assertEqual(
        {error, {bad_option, {services, Services, [single_service_or_multiplex]}}},
        thrift_runtime_options:server_options(
            #{port => 0, service => svc, handler => hdl, services => Services}
        )
    ),
    ?assertEqual(
        {error, {bad_option, {services, Services, [single_service_or_multiplex]}}},
        thrift_runtime_options:server_options(#{port => 0, service => svc, services => Services})
    ),
    %% the multiplex mode needs nothing else
    {ok, #{services := Services}} = thrift_runtime_options:server_options(
        #{port => 0, services => Services}
    ),
    %% a malformed nested shape reports the top-level `services' option
    Malformed = [
        #{<<"First">> => #{handler => h1}},
        #{<<"First">> => #{handler => h1, service => s1, extra => x}},
        #{<<"First">> => #{handler => <<"h1">>, service => s1}},
        #{<<"First">> => not_a_map},
        #{first => #{handler => h1, service => s1}},
        not_a_map,
        [<<"First">>]
    ],
    [
        ?assertEqual(
            {error, {bad_option, {services, Bad, [service_map]}}},
            thrift_runtime_options:server_options(#{port => 0, services => Bad})
        )
     || Bad <- Malformed
    ],
    ok.

server_defaults_test() ->
    ?assertEqual(
        {ok, #{
            port => 0,
            service => svc,
            handler => hdl,
            transport => framed,
            protocol => thrift_runtime_binary,
            timeout => 5000,
            handshake_timeout => 5000,
            idle_timeout => 5000,
            max_frame_size => 64 * 1024 * 1024,
            max_connections => 1024,
            active_n => 100,
            backlog => 1024,
            ssl_opts => undefined,
            on_event => undefined,
            record_api => false,
            types => undefined,
            name => thrift_runtime_server
        }},
        thrift_runtime_options:server_options(#{port => 0, service => svc, handler => hdl})
    ),
    %% specific server timeouts override the umbrella, which stays available
    {ok, #{timeout := 1000, handshake_timeout := 2000, idle_timeout := 1000}} =
        thrift_runtime_options:server_options(#{
            port => 0,
            service => svc,
            handler => hdl,
            timeout => 1000,
            handshake_timeout => 2000
        }),
    %% the multiplex mode carries no single-mode keys
    Services = #{<<"First">> => #{handler => h1, service => s1}},
    {ok, Mux} = thrift_runtime_options:server_options(#{port => 0, services => Services}),
    ?assertNot(maps:is_key(service, Mux)),
    ?assertNot(maps:is_key(handler, Mux)),
    ok.

server_value_families_test() ->
    Base = #{port => 0, service => svc, handler => hdl},
    %% atom-only handler, service and types; boolean record_api
    ?assertEqual(
        {error, {bad_option, {handler, <<"hdl">>, [module]}}},
        thrift_runtime_options:server_options(Base#{handler := <<"hdl">>})
    ),
    {ok, #{types := types_mod, record_api := true}} =
        thrift_runtime_options:server_options(Base#{types => types_mod, record_api => true}),
    {ok, #{types := undefined, record_api := false}} =
        thrift_runtime_options:server_options(Base#{types => undefined}),
    ?assertEqual(
        {error, {bad_option, {types, <<"types">>, [undefined, module]}}},
        thrift_runtime_options:server_options(Base#{types => <<"types">>})
    ),
    ?assertEqual(
        {error, {bad_option, {record_api, yes, [boolean]}}},
        thrift_runtime_options:server_options(Base#{record_api => yes})
    ),
    %% positive-integer limits
    {ok, #{max_connections := 1, backlog := 1}} =
        thrift_runtime_options:server_options(Base#{max_connections => 1, backlog => 1}),
    ?assertEqual(
        {error, {bad_option, {max_connections, 0, [pos_integer]}}},
        thrift_runtime_options:server_options(Base#{max_connections => 0})
    ),
    ?assertEqual(
        {error, {bad_option, {backlog, 0, [pos_integer]}}},
        thrift_runtime_options:server_options(Base#{backlog => 0})
    ),
    %% server timeouts accept infinity
    {ok, #{idle_timeout := infinity}} =
        thrift_runtime_options:server_options(Base#{idle_timeout => infinity}),
    ?assertEqual(
        {error, {bad_option, {handshake_timeout, 0, [pos_integer, infinity]}}},
        thrift_runtime_options:server_options(Base#{handshake_timeout => 0})
    ),
    %% server TLS options
    {ok, #{ssl_opts := [{certfile, "cert.pem"}]}} =
        thrift_runtime_options:server_options(Base#{ssl_opts => [{certfile, "cert.pem"}]}),
    ?assertEqual(
        {error, {bad_option, {ssl_opts, true, [undefined, list]}}},
        thrift_runtime_options:server_options(Base#{ssl_opts => true})
    ),
    %% deterministic unknown keys: sorted first
    ?assertEqual(
        {error, {unknown_option, aaa}},
        thrift_runtime_options:server_options(Base#{zzz => true, aaa => 1})
    ),
    ok.

acceptor_options_test() ->
    Base = #{port => 0, service => svc, handler => hdl},
    %% the acceptor contract is the server contract minus the name
    {ok, Accept} = thrift_runtime_options:acceptor_options(Base),
    ?assertNot(maps:is_key(name, Accept)),
    ?assertEqual(
        {error, {unknown_option, name}}, thrift_runtime_options:acceptor_options(Base#{name => my_server})
    ),
    %% both service modes and their errors apply unchanged
    ?assertEqual(
        {error, {missing_option, service}}, thrift_runtime_options:acceptor_options(#{port => 0})
    ),
    Services = #{<<"First">> => #{handler => h1, service => s1}},
    {ok, #{services := Services}} = thrift_runtime_options:acceptor_options(
        #{port => 0, services => Services}
    ),
    ?assertEqual(
        {error, {bad_option, {services, Services, [single_service_or_multiplex]}}},
        thrift_runtime_options:acceptor_options(Base#{services => Services})
    ),
    ok.

%%--------------------------------------------------------------------
%% Reconnecting client
%%--------------------------------------------------------------------

reconnecting_options_test() ->
    Base = #{host => "localhost", port => 9090, service => svc},
    Client = client_normalized(),
    ?assertEqual(
        {ok, Client#{reconnect_min => 500, reconnect_max => 30000}},
        thrift_runtime_options:reconnecting_options(Base)
    ),
    %% every client key passes through, the queue depth included
    {ok, #{max_queue_depth := 7, reconnect_min := 250, reconnect_max := 5000}} =
        thrift_runtime_options:reconnecting_options(
            Base#{max_queue_depth => 7, reconnect_min => 250, reconnect_max => 5000}
        ),
    %% a reversed pair is rejected on the max value
    ?assertEqual(
        {error, {bad_option, {reconnect_max, 10, [gte_reconnect_min]}}},
        thrift_runtime_options:reconnecting_options(Base#{reconnect_min => 100, reconnect_max => 10})
    ),
    %% reconnect bounds are positive integers
    ?assertEqual(
        {error, {bad_option, {reconnect_min, 0, [pos_integer]}}},
        thrift_runtime_options:reconnecting_options(Base#{reconnect_min => 0})
    ),
    ?assertEqual(
        {error, {bad_option, {reconnect_max, infinity, [pos_integer]}}},
        thrift_runtime_options:reconnecting_options(Base#{reconnect_max => infinity})
    ),
    %% client-family errors apply unchanged
    ?assertEqual(
        {error, {bad_protocol, <<"binary">>}},
        thrift_runtime_options:reconnecting_options(Base#{protocol => <<"binary">>})
    ),
    ?assertEqual(
        {error, {unknown_option, max_connections}},
        thrift_runtime_options:reconnecting_options(Base#{max_connections => 10})
    ),
    ok.

%%--------------------------------------------------------------------
%% Graceful stop
%%--------------------------------------------------------------------

stop_options_test() ->
    ?assertEqual({ok, #{}}, thrift_runtime_options:stop_options(#{})),
    ?assertEqual({ok, #{drain => 0}}, thrift_runtime_options:stop_options(#{drain => 0})),
    ?assertEqual(
        {ok, #{drain => infinity}}, thrift_runtime_options:stop_options(#{drain => infinity})
    ),
    ?assertEqual(
        {error, {bad_option, {options, bad, [map]}}}, thrift_runtime_options:stop_options(bad)
    ),
    ?assertEqual(
        {error, {unknown_option, drian}}, thrift_runtime_options:stop_options(#{drian => 0})
    ),
    ?assertEqual(
        {error, {bad_option, {drain, -1, [non_neg_integer, infinity]}}},
        thrift_runtime_options:stop_options(#{drain => -1})
    ),
    ?assertEqual(
        {error, {bad_option, {drain, 1.5, [non_neg_integer, infinity]}}},
        thrift_runtime_options:stop_options(#{drain => 1.5})
    ),
    ok.
