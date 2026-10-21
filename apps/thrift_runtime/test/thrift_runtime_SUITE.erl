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

%% Loopback coverage of the runtime: a real server on an ephemeral
%% port, a real client over TCP, both transports (framed and buffered),
%% every reply shape (value, void, declared exception, application
%% exception) and one-way delivery.

-module(thrift_runtime_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    framed_calls/1,
    buffered_calls/1,
    compact_framed_calls/1,
    compact_buffered_calls/1,
    json_framed_calls/1,
    json_buffered_calls/1,
    http_calls/1,
    declared_exception/1,
    application_exception/1,
    oneway_delivery/1,
    many_sequential_calls/1,
    unknown_function_is_local_error/1,
    multiplexed_calls/1,
    multiplexed_unknown_service/1,
    plain_client_to_multiplexed_server/1,
    prefixed_name_to_plain_server/1,
    drain_waits_for_inflight_call/1,
    drain_deadline_expires/1,
    drain_closes_listener_and_idle_connections/1,
    handshake_timeout_reaches_acceptor/1,
    client_stats/1,
    client_stats_queue_full/1
]).

all() ->
    [
        framed_calls,
        buffered_calls,
        compact_framed_calls,
        compact_buffered_calls,
        json_framed_calls,
        json_buffered_calls,
        http_calls,
        declared_exception,
        application_exception,
        oneway_delivery,
        many_sequential_calls,
        unknown_function_is_local_error,
        multiplexed_calls,
        multiplexed_unknown_service,
        plain_client_to_multiplexed_server,
        prefixed_name_to_plain_server,
        drain_waits_for_inflight_call,
        drain_deadline_expires,
        drain_closes_listener_and_idle_connections,
        handshake_timeout_reaches_acceptor,
        client_stats,
        client_stats_queue_full
    ].

-define(SERVICE, thrift_runtime_test_service).
-define(HANDLER, thrift_runtime_test_handler).
-define(SERVICE2, thrift_runtime_test_service2).
-define(HANDLER2, thrift_runtime_test_handler2).

%%--------------------------------------------------------------------

framed_calls(_Config) ->
    with_server(#{transport => framed}, fun(Client) ->
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ?assertEqual({ok, <<"hello">>}, call(Client, <<"echo">>, [<<"hello">>])),
        ?assertEqual({ok, 3}, call(Client, <<"size">>, [[<<"a">>, <<"b">>, <<"c">>]])),
        ?assertEqual({ok, undefined}, call(Client, <<"ping">>, [])),
        ?assertEqual(
            {ok, #{<<"x">> => 2, <<"y">> => 1}}, call(Client, <<"deep">>, [#{<<"x">> => 1, <<"y">> => 2}])
        )
    end).

buffered_calls(_Config) ->
    with_server(#{transport => buffered}, fun(Client) ->
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ?assertEqual(
            {ok, #{<<"x">> => 9, <<"y">> => 8}}, call(Client, <<"deep">>, [#{<<"x">> => 8, <<"y">> => 9}])
        )
    end).

%% The compact protocol over both transports: the framed path is pure
%% codec, the buffered path additionally exercises the probe-decode in
%% extract_message, which skips the payload by wire type.

compact_framed_calls(_Config) ->
    protocol_calls(#{transport => framed, protocol => compact}).

compact_buffered_calls(_Config) ->
    protocol_calls(#{transport => buffered, protocol => compact}).

%% The JSON protocol over both transports; buffered additionally runs
%% the probe-decode in extract_message, whose completeness check relies
%% on the ]-fold of the envelope bracket. Reply, void and both
%% exception shapes go over the wire in one scenario.

json_framed_calls(_Config) ->
    protocol_calls(#{transport => framed, protocol => json}).

json_buffered_calls(_Config) ->
    protocol_calls(#{transport => buffered, protocol => json}).

%% The HTTP transport is protocol-agnostic: the same call battery rides
%% one POST per exchange with every built-in protocol in the body. The
%% oneway scenario proves the client consumes the (empty) response the
%% server owes even a fire-and-forget call.

http_calls(_Config) ->
    [protocol_calls(#{transport => http, protocol => P}) || P <- [binary, compact, json]],
    ok.

declared_exception(_Config) ->
    with_server(#{}, fun(Client) ->
        ?assertEqual(
            {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}},
            call(Client, <<"boom">>, [])
        ),
        %% The connection stays usable after an exception reply.
        ?assertEqual({ok, 1}, call(Client, <<"add">>, [1, 0]))
    end).

application_exception(_Config) ->
    with_server(#{}, fun(Client) ->
        ?assertMatch(
            {error, {application_exception, <<"internal error">>, 6, <<"INTERNAL_ERROR">>}},
            call(Client, <<"boomInternal">>, [])
        )
    end).

oneway_delivery(_Config) ->
    with_server(#{}, fun(Client) ->
        true = register(thrift_runtime_test_sink, self()),
        try
            ok = thrift_runtime_client:oneway(Client, <<"notify">>, [<<"fire">>], 5000),
            receive
                {notified, <<"fire">>} ->
                    ok
            after 2000 ->
                erlang:error(oneway_not_delivered)
            end
        after
            unregister(thrift_runtime_test_sink)
        end
    end).

many_sequential_calls(_Config) ->
    with_server(#{}, fun(Client) ->
        Results = [call(Client, <<"add">>, [N, N]) || N <- lists:seq(1, 50)],
        ?assertEqual([{ok, N * 2} || N <- lists:seq(1, 50)], Results)
    end).

unknown_function_is_local_error(_Config) ->
    with_server(#{}, fun(Client) ->
        ?assertEqual({error, unknown_function}, call(Client, <<"nope">>, []))
    end).

%% Two services on one port; each client prefixes with its service
%% name. The second service answers differently under the SAME function
%% names (add multiplies, echo marks), so the assertions prove the
%% `Service:' prefix actually routed the call.

multiplexed_calls(_Config) ->
    with_services_server(
        fun(Port) ->
            {ok, Alpha} = multiplex_client(Port, <<"Alpha">>, ?SERVICE),
            {ok, Beta} = multiplex_client(Port, <<"Beta">>, ?SERVICE2),
            try
                ?assertEqual({ok, 5}, call(Alpha, <<"add">>, [2, 3])),
                ?assertEqual({ok, 6}, call(Beta, <<"add">>, [2, 3])),
                ?assertEqual(
                    {ok, <<"hello">>}, call(Alpha, <<"echo">>, [<<"hello">>])
                ),
                ?assertEqual(
                    {ok, <<"echo2:hello">>}, call(Beta, <<"echo">>, [<<"hello">>])
                ),
                ?assertEqual({ok, undefined}, call(Beta, <<"ping">>, [])),
                true = register(thrift_runtime_test_sink, self()),
                try
                    ok = thrift_runtime_client:oneway(Beta, <<"notify">>, [<<"fire">>], 5000),
                    receive
                        {notified2, <<"fire">>} ->
                            ok
                    after 2000 ->
                        erlang:error(oneway_not_delivered)
                    end
                after
                    unregister(thrift_runtime_test_sink)
                end
            after
                thrift_runtime_client:stop(Alpha),
                thrift_runtime_client:stop(Beta)
            end
        end
    ).

%% A multiplexed client pointing at a service name the server does not
%% host gets the application-exception UNKNOWN_FUNCTION; the connection
%% survives the exchange.

multiplexed_unknown_service(_Config) ->
    with_services_server(
        fun(Port) ->
            {ok, Client} = multiplex_client(Port, <<"Nope">>, ?SERVICE),
            try
                ?assertMatch(
                    {error, {application_exception, <<"unknown function">>, 1, <<"UNKNOWN_METHOD">>}},
                    call(Client, <<"add">>, [2, 3])
                ),
                ?assertMatch(
                    {error, {application_exception, _, 1, _}}, call(Client, <<"add">>, [4, 5])
                )
            after
                thrift_runtime_client:stop(Client)
            end
        end
    ).

%% A multiplexed server is strict: a plain (unprefixed) name finds no
%% service and is refused with UNKNOWN_FUNCTION.

plain_client_to_multiplexed_server(_Config) ->
    with_services_server(
        fun(Port) ->
            {ok, Client} =
                thrift_runtime_client:start_link(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
            try
                ?assertMatch(
                    {error, {application_exception, <<"unknown function">>, 1, <<"UNKNOWN_METHOD">>}},
                    call(Client, <<"add">>, [2, 3])
                )
            after
                thrift_runtime_client:stop(Client)
            end
        end
    ).

%% The reverse stays compatible: a client that prefixes with ANY
%% service name still reaches the one service of a plain server, which
%% ignores the prefix in single-service mode.

prefixed_name_to_plain_server(_Config) ->
    {ok, Server} =
        thrift_runtime_server:start_link(#{port => 0, handler => ?HANDLER, service => ?SERVICE}),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} =
            thrift_runtime_client:start_link(#{
                host => "127.0.0.1", port => Port, service => ?SERVICE, multiplex => <<"Whatever">>
            }),
        try
            ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3]))
        after
            thrift_runtime_client:stop(Client)
        end
    after
        thrift_runtime_server:stop(Server)
    end.

%% Drain: the in-flight call is answered first, only then the stop
%% completes. The handler blocks on an ETS gate, so the scenario is
%% deterministic: while the gate is closed the drain cannot finish.
%% The handler module must be loaded up front: the connection resolves
%% `slow' with binary_to_existing_atom, and in a filtered run these
%% cases are the first to touch the handler at all.

drain_waits_for_inflight_call(_Config) ->
    {module, ?HANDLER} = code:ensure_loaded(?HANDLER),
    gate_on(),
    {ok, Server} = thrift_runtime_server:start_link(#{port => 0, handler => ?HANDLER, service => ?SERVICE}),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} = thrift_runtime_client:start_link(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
        try
            Self = self(),
            %% Unlinked workers reporting back: a late crash after the
            %% case must not poison the next one, and a caught crash is
            %% still visible in the received value.
            spawn(fun() ->
                Self !
                    {slow_result,
                        try
                            call(Client, <<"slow">>, [])
                        catch
                            C:R -> {crashed, C, R}
                        end}
            end),
            wait_gate_entered(),
            spawn(fun() ->
                Self !
                    {stop_result,
                        try
                            thrift_runtime_server:stop(Server, #{drain => 5000})
                        catch
                            C:R -> {crashed, C, R}
                        end}
            end),
            receive
                {stop_result, _} -> erlang:error(drain_finished_early)
            after 300 ->
                ok
            end,
            ets:insert(thrift_runtime_drain_gate, {go, true}),
            receive
                {slow_result, Result} -> ?assertEqual({ok, <<"done">>}, Result)
            after 5000 ->
                erlang:error(no_call_result)
            end,
            receive
                {stop_result, Stopped} -> ?assertEqual(ok, Stopped)
            after 5000 ->
                erlang:error(no_stop_result)
            end
        after
            %% The drained connection stops the client process too.
            try
                thrift_runtime_client:stop(Client)
            catch
                _:_ -> ok
            end
        end
    after
        try
            thrift_runtime_server:stop(Server)
        catch
            _:_ -> ok
        end,
        gate_off()
    end.

%% The deadline is a best-effort release, not a failure: with an
%% exchange still running, drain returns on schedule — and the
%% supervisor stop that follows still lets the busy connection answer
%% (the sweep is a graceful gen_server stop, not a kill).

drain_deadline_expires(_Config) ->
    {module, ?HANDLER} = code:ensure_loaded(?HANDLER),
    gate_on(),
    {ok, Server} = thrift_runtime_server:start_link(#{port => 0, handler => ?HANDLER, service => ?SERVICE}),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} = thrift_runtime_client:start_link(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
        try
            Self = self(),
            spawn(fun() ->
                Self !
                    {slow_result,
                        try
                            call(Client, <<"slow">>, [])
                        catch
                            C:R -> {crashed, C, R}
                        end}
            end),
            wait_gate_entered(),
            {_, Acceptor, worker, [thrift_runtime_acceptor]} =
                lists:keyfind(acceptor, 1, supervisor:which_children(Server)),
            T0 = erlang:monotonic_time(millisecond),
            ok = thrift_runtime_acceptor:drain(Acceptor, 200),
            ?assert(erlang:monotonic_time(millisecond) - T0 < 1000),
            %% The exchange did not finish: the gate is still closed.
            receive
                {slow_result, _} -> erlang:error(call_finished_early)
            after 0 ->
                ok
            end,
            ets:insert(thrift_runtime_drain_gate, {go, true}),
            receive
                {slow_result, Result} -> ?assertEqual({ok, <<"done">>}, Result)
            after 5000 ->
                erlang:error(no_call_result)
            end
        after
            try
                thrift_runtime_client:stop(Client)
            catch
                _:_ -> ok
            end
        end
    after
        try
            thrift_runtime_server:stop(Server)
        catch
            _:_ -> ok
        end,
        gate_off()
    end.

%% Drain closes the listener and disconnects the idle connections: a
%% new client is refused, the connected one is dropped, and the stop
%% completes without waiting for any deadline.

drain_closes_listener_and_idle_connections(_Config) ->
    {ok, Server} = thrift_runtime_server:start_link(#{port => 0, handler => ?HANDLER, service => ?SERVICE}),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} = thrift_runtime_client:start_link(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
        try
            Self = self(),
            spawn(fun() ->
                Self !
                    {stop_result,
                        try
                            thrift_runtime_server:stop(Server, #{drain => 5000})
                        catch
                            C:R -> {crashed, C, R}
                        end}
            end),
            receive
                {stop_result, Stopped} -> ?assertEqual(ok, Stopped)
            after 5000 ->
                erlang:error(no_stop_result)
            end,
            ?assertMatch(
                {error, _},
                thrift_runtime_client:start_link(#{host => "127.0.0.1", port => Port, service => ?SERVICE})
            ),
            Monitor = monitor(process, Client),
            receive
                {'DOWN', Monitor, process, Client, _Reason} -> ok
            after 2000 ->
                erlang:error(client_not_disconnected)
            end
        after
            try
                thrift_runtime_client:stop(Client)
            catch
                _:_ -> ok
            end
        end
    after
        try
            thrift_runtime_server:stop(Server)
        catch
            _:_ -> ok
        end
    end.

%% The acceptor stores only whitelisted connection options, and the
%% accept loop resolves `handshake_timeout' from that stored map: a key
%% missing from the whitelist would silently fall back to the 5000 ms
%% default instead of the value the caller named.

handshake_timeout_reaches_acceptor(_Config) ->
    {ok, Server} =
        thrift_runtime_server:start_link(#{
            port => 0, handler => ?HANDLER, service => ?SERVICE, handshake_timeout => 250
        }),
    try
        {_, Acceptor, worker, [thrift_runtime_acceptor]} =
            lists:keyfind(acceptor, 1, supervisor:which_children(Server)),
        %% element 3 of the module-private acceptor state: connection_opts
        ConnectionOpts = element(3, sys:get_state(Acceptor)),
        ?assertEqual(250, maps:get(handshake_timeout, ConnectionOpts)),
        %% what handle_info(accept) resolves the handshake slice from
        ?assertEqual(250, thrift_runtime_options:handshake_timeout(ConnectionOpts))
    after
        thrift_runtime_server:stop(Server)
    end.

%% Per-connection counters: every caller-facing answer is counted by
%% outcome, and get_and_reset_stats zeroes them.

client_stats(_Config) ->
    with_server(#{}, fun(Client) ->
        ?assertEqual(#{calls_ok => 0, calls_failed => 0}, thrift_runtime_client:get_stats(Client)),
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ok = thrift_runtime_client:oneway(Client, <<"notify">>, [<<"x">>], 5000),
        ?assertEqual({error, unknown_function}, call(Client, <<"nope">>, [])),
        ?assertEqual(
            {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}},
            call(Client, <<"boom">>, [])
        ),
        ?assertEqual(#{calls_ok => 2, calls_failed => 2}, thrift_runtime_client:get_stats(Client)),
        ?assertEqual(
            #{calls_ok => 2, calls_failed => 2}, thrift_runtime_client:get_and_reset_stats(Client)
        ),
        ?assertEqual(#{calls_ok => 0, calls_failed => 0}, thrift_runtime_client:get_stats(Client))
    end).

%% A call refused at the door (max_queue_depth) is a failed answer too;
%% the two queued calls still complete once the head moves.

client_stats_queue_full(_Config) ->
    {module, ?HANDLER} = code:ensure_loaded(?HANDLER),
    gate_on(),
    {ok, Server} = thrift_runtime_server:start_link(#{port => 0, handler => ?HANDLER, service => ?SERVICE}),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} =
            thrift_runtime_client:start_link(#{
                host => "127.0.0.1", port => Port, service => ?SERVICE, max_queue_depth => 1
            }),
        try
            Self = self(),
            spawn(fun() ->
                Self !
                    {r1,
                        try
                            call(Client, <<"slow">>, [])
                        catch
                            C:R -> {crashed, C, R}
                        end}
            end),
            wait_gate_entered(),
            spawn(fun() ->
                Self !
                    {r2,
                        try
                            call(Client, <<"slow">>, [])
                        catch
                            C:R -> {crashed, C, R}
                        end}
            end),
            timer:sleep(200),
            spawn(fun() ->
                Self !
                    {r3,
                        try
                            call(Client, <<"slow">>, [])
                        catch
                            C:R -> {crashed, C, R}
                        end}
            end),
            timer:sleep(200),
            ?assertEqual(#{calls_ok => 0, calls_failed => 1}, thrift_runtime_client:get_stats(Client)),
            ets:insert(thrift_runtime_drain_gate, {go, true}),
            Results = [recv(r1), recv(r2), recv(r3)],
            ?assertEqual({ok, <<"done">>}, lists:nth(1, Results)),
            ?assertEqual({ok, <<"done">>}, lists:nth(2, Results)),
            ?assertEqual({error, queue_full}, lists:nth(3, Results)),
            ?assertEqual(#{calls_ok => 2, calls_failed => 1}, thrift_runtime_client:get_stats(Client))
        after
            try
                thrift_runtime_client:stop(Client)
            catch
                _:_ -> ok
            end
        end
    after
        try
            thrift_runtime_server:stop(Server)
        catch
            _:_ -> ok
        end,
        gate_off()
    end.

%%--------------------------------------------------------------------
%% Helpers

%% The ETS gate the `slow' handler polls: `{go, false}' until the case
%% opens it, plus an `entered' counter the cases wait on to know the
%% handler is inside the call.

-spec gate_on() -> ok.
gate_on() ->
    _ = ets:new(thrift_runtime_drain_gate, [named_table, public, set]),
    ets:insert(thrift_runtime_drain_gate, {go, false}),
    ok.

-spec gate_off() -> ok.
gate_off() ->
    ets:delete(thrift_runtime_drain_gate),
    ok.

-spec wait_gate_entered() -> ok.
wait_gate_entered() ->
    wait_gate_entered(500).

wait_gate_entered(0) ->
    erlang:error(handler_did_not_enter);
wait_gate_entered(Tries) ->
    case ets:lookup(thrift_runtime_drain_gate, entered) of
        [{entered, N}] when N >= 1 ->
            ok;
        _ ->
            timer:sleep(10),
            wait_gate_entered(Tries - 1)
    end.

%% Waits for an unlinked worker's tagged result.

-spec recv(atom()) -> term().
recv(Tag) ->
    receive
        {Tag, Value} -> Value
    after 5000 ->
        erlang:error({no_result, Tag})
    end.

protocol_calls(Overrides) ->
    with_server(Overrides, fun(Client) ->
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ?assertEqual({ok, <<"hello">>}, call(Client, <<"echo">>, [<<"hello">>])),
        ?assertEqual({ok, 3}, call(Client, <<"size">>, [[<<"a">>, <<"b">>, <<"c">>]])),
        ?assertEqual({ok, undefined}, call(Client, <<"ping">>, [])),
        ?assertEqual(
            {ok, #{<<"x">> => 2, <<"y">> => 1}}, call(Client, <<"deep">>, [#{<<"x">> => 1, <<"y">> => 2}])
        ),
        ?assertEqual(
            {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}},
            call(Client, <<"boom">>, [])
        ),
        ?assertMatch(
            {error, {application_exception, <<"internal error">>, 6, <<"INTERNAL_ERROR">>}},
            call(Client, <<"boomInternal">>, [])
        ),
        ?assertEqual({ok, 1}, call(Client, <<"add">>, [1, 0]))
    end).

call(Client, Function, Args) ->
    thrift_runtime_client:call(Client, Function, Args, 5000).

-spec with_server(map(), fun((pid()) -> term())) -> term().
with_server(Overrides, Test) ->
    Base = #{
        port => 0,
        handler => ?HANDLER,
        service => ?SERVICE
    },
    ServerOpts = maps:merge(Base, Overrides),
    {ok, Server} = thrift_runtime_server:start_link(ServerOpts),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        ClientOpts = maps:merge(Base#{host => "127.0.0.1", port => Port}, Overrides),
        {ok, Client} = thrift_runtime_client:start_link(ClientOpts),
        try
            Test(Client)
        after
            thrift_runtime_client:stop(Client)
        end
    after
        thrift_runtime_server:stop(Server)
    end.

%% A multiplexed server hosting the given `ServiceName => {Handler,
%% Service}' pairs; the test gets the bound port and brings its own
%% clients.

-spec with_services_server(fun((inet:port_number()) -> term())) -> term().
with_services_server(Test) ->
    Services = #{
        <<"Alpha">> => #{handler => ?HANDLER, service => ?SERVICE},
        <<"Beta">> => #{handler => ?HANDLER2, service => ?SERVICE2}
    },
    {ok, Server} = thrift_runtime_server:start_link(#{port => 0, services => Services}),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        Test(Port)
    after
        thrift_runtime_server:stop(Server)
    end.

-spec multiplex_client(inet:port_number(), binary(), module()) -> {ok, pid()}.
multiplex_client(Port, Service, ServiceMod) ->
    thrift_runtime_client:start_link(#{
        host => "127.0.0.1", port => Port, service => ServiceMod, multiplex => Service
    }).
