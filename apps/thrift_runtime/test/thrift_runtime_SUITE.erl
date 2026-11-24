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
    empty_result_payload_uses_service_info/1,
    nonvoid_result_without_success_keeps_badkey/1,
    compact_framed_calls/1,
    compact_buffered_calls/1,
    json_framed_calls/1,
    json_buffered_calls/1,
    http_calls/1,
    declared_exception/1,
    application_exception/1,
    invalid_void_handler_result/1,
    invalid_nonvoid_handler_result/1,
    oneway_invalid_result/1,
    oneway_invalid_result_http/1,
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
    client_stats_queue_full/1,
    rpc_hook_undef_is_raised/1
]).

all() ->
    [
        framed_calls,
        buffered_calls,
        empty_result_payload_uses_service_info,
        nonvoid_result_without_success_keeps_badkey,
        compact_framed_calls,
        compact_buffered_calls,
        json_framed_calls,
        json_buffered_calls,
        http_calls,
        declared_exception,
        application_exception,
        invalid_void_handler_result,
        invalid_nonvoid_handler_result,
        oneway_invalid_result,
        oneway_invalid_result_http,
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
        client_stats_queue_full,
        rpc_hook_undef_is_raised
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
        ?assertEqual(ok, call(Client, <<"ping">>, [])),
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

%% A reply whose result struct carries no success field: the void
%% function (declared without a `reply' descriptor) answers the bare
%% atom `ok', while a non-void function with an equally empty payload
%% keeps its historical `{ok, undefined}' — voidness comes from the
%% service description, never from the payload being empty. A raw peer
%% answers an empty result struct per protocol, something the normal
%% server stack cannot send for a non-void function (its encoder writes
%% the success field whenever the function declares a reply type).

empty_result_payload_uses_service_info(_Config) ->
    lists:foreach(
        fun(Protocol) ->
            with_empty_payload_peer(Protocol, fun(Client) ->
                ?assertEqual(ok, call(Client, <<"ping">>, [])),
                ?assertEqual({ok, undefined}, call(Client, <<"add">>, [2, 3]))
            end)
        end,
        [thrift_runtime_binary, thrift_runtime_compact, thrift_runtime_json]
    ),
    ok.

%% A non-void result whose decoded map has no `success' entry must keep
%% the historical failure mode: the client process crashes with
%% `badkey' (its terminate releases the pending caller with `{error,
%% closed}'), not silently answer `{ok, undefined}'. Neither the generic
%% engine nor the generated codecs can produce that map (both skip
%% unknown wire ids), but a custom protocol module — a supported client
%% option — can; the mystery protocol test double injects an unknown key
%% into every decoded struct map.

nonvoid_result_without_success_keeps_badkey(_Config) ->
    with_empty_payload_peer(thrift_runtime_test_mystery_protocol, fun(Client) ->
        %% the linked client crashes on purpose; keep the exit a message
        process_flag(trap_exit, true),
        Self = self(),
        spawn(fun() ->
            Self ! {mystery_result, call(Client, <<"add">>, [2, 3])}
        end),
        %% terminate answers the pending call while dying
        ?assertEqual(
            {error, closed},
            receive
                {mystery_result, R} ->
                    R
            after 5000 ->
                erlang:error(no_mystery_result)
            end
        ),
        receive
            {'EXIT', Client, {{badkey, <<"success">>}, _}} ->
                ok
        after 1000 ->
            erlang:error(client_did_not_crash_with_badkey)
        end,
        ?assertNot(is_process_alive(Client))
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

%% The strict handler-result contract: the legacy void answer `{ok,
%% undefined}' is an unsupported result now, not a compatibility shim.
%% The call is answered with INTERNAL_ERROR and exactly one `handler_error'
%% event, and the connection stays usable.

invalid_void_handler_result(_Config) ->
    with_event_server(#{}, fun(Client) ->
        ?assertMatch(
            {error, {application_exception, <<"internal error">>, 6, <<"INTERNAL_ERROR">>}},
            call(Client, <<"badPing">>, [])
        ),
        wait_handler_error(<<"badPing">>, {bad_result, {ok, undefined}}),
        assert_no_handler_error(),
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3]))
    end).

%% A bare `ok' stays unsupported for a non-void function: INTERNAL_ERROR
%% plus one `handler_error' event.

invalid_nonvoid_handler_result(_Config) ->
    with_event_server(#{}, fun(Client) ->
        ?assertMatch(
            {error, {application_exception, <<"internal error">>, 6, <<"INTERNAL_ERROR">>}},
            call(Client, <<"badAdd">>, [])
        ),
        wait_handler_error(<<"badAdd">>, {bad_result, ok}),
        assert_no_handler_error()
    end).

%% An invalid oneway result cannot be answered on the wire (nothing is
%% ever sent back); it surfaces as one `handler_error' event only. The
%% handler itself ran to completion — its side effect arrived.

oneway_invalid_result(_Config) ->
    with_event_server(#{}, fun(Client) ->
        true = register(thrift_runtime_test_sink, self()),
        try
            ok = thrift_runtime_client:oneway(Client, <<"badNotify">>, [<<"fire">>], 5000),
            receive
                {bad_notified, <<"fire">>} ->
                    ok
            after 2000 ->
                erlang:error(oneway_not_delivered)
            end,
            wait_handler_error(<<"badNotify">>, {bad_result, {ok, undefined}}),
            assert_no_handler_error()
        after
            unregister(thrift_runtime_test_sink)
        end
    end).

%% Over HTTP the acknowledgement is exactly the (empty) 200 owed to every
%% request, sent before the handler runs: an invalid oneway result adds
%% one `handler_error' event and no second response. A raw socket pins
%% both halves — one response with an empty body, then silence.

oneway_invalid_result_http(_Config) ->
    Self = self(),
    Events = fun(E) -> Self ! {suite_event, E} end,
    {ok, Server} =
        thrift_runtime_server:start_link(#{
            port => 0,
            transport => http,
            handler => ?HANDLER,
            service => ?SERVICE,
            on_event => Events
        }),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, raw}, {active, false}]),
        try
            ok = raw_http_oneway(Sock, <<"badNotify">>),
            wait_handler_error(<<"badNotify">>, {bad_result, {ok, undefined}}),
            assert_no_handler_error(),
            %% the valid oneway is acknowledged exactly once too, with no event
            ok = raw_http_oneway(Sock, <<"notify">>),
            assert_no_handler_error()
        after
            gen_tcp:close(Sock)
        end
    after
        thrift_runtime_server:stop(Server)
    end.

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
                ?assertEqual(ok, call(Beta, <<"ping">>, [])),
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
        ?assertEqual(ok, call(Client, <<"ping">>, [])),
        ok = thrift_runtime_client:oneway(Client, <<"notify">>, [<<"x">>], 5000),
        ?assertEqual({error, unknown_function}, call(Client, <<"nope">>, [])),
        ?assertEqual(
            {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}},
            call(Client, <<"boom">>, [])
        ),
        ?assertEqual(#{calls_ok => 3, calls_failed => 2}, thrift_runtime_client:get_stats(Client)),
        ?assertEqual(
            #{calls_ok => 3, calls_failed => 2}, thrift_runtime_client:get_and_reset_stats(Client)
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
        ?assertEqual(ok, call(Client, <<"ping">>, [])),
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

%% A server (and client) whose on_event collector forwards every event
%% to the test process as `{suite_event, Event}'.

-spec with_event_server(map(), fun((pid()) -> term())) -> term().
with_event_server(Overrides, Test) ->
    Self = self(),
    Events = fun(E) -> Self ! {suite_event, E} end,
    with_server(Overrides#{on_event => Events}, Test).

%% Waits for the `handler_error' event of one invalid handler result;
%% events from the client's side of the connection are skipped over.

-spec wait_handler_error(binary(), term()) -> ok.
wait_handler_error(Function, Reason) ->
    receive
        {suite_event, #{type := handler_error, function := Function, reason := Reason}} ->
            ok;
        {suite_event, _} ->
            wait_handler_error(Function, Reason)
    after 5000 ->
        erlang:error({no_handler_error, Function, Reason})
    end.

%% One invalid result means exactly one event: a short drain must not
%% reveal a second `handler_error'.

-spec assert_no_handler_error() -> ok.
assert_no_handler_error() ->
    receive
        {suite_event, #{type := handler_error} = Event} ->
            erlang:error({unexpected_handler_error, Event});
        {suite_event, _} ->
            assert_no_handler_error()
    after 300 ->
        ok
    end.

%%--------------------------------------------------------------------
%% Raw HTTP helpers
%%--------------------------------------------------------------------

%% POSTs one oneway message over a raw socket and pins the acknowledgement:
%% exactly one response, 200 with an empty body, then silence on the wire.

-spec raw_http_oneway(gen_tcp:socket(), binary()) -> ok.
raw_http_oneway(Sock, Name) ->
    Params = {struct, {struct, [{1, default, {base, string}, <<"m">>, undefined}]}},
    {ok, Payload} = thrift_runtime_binary:encode(Params, #{<<"m">> => <<"fire">>}),
    Message = iolist_to_binary(thrift_runtime_binary:encode_message(oneway, Name, 0, Payload)),
    Request = thrift_runtime_http:request(<<"localhost">>, <<"/">>, [], Message),
    ok = gen_tcp:send(Sock, iolist_to_binary(Request)),
    {200, <<>>} = recv_http_response(Sock),
    %% The acknowledgement is pinned by the silence that follows: 400 ms
    %% is far beyond loopback latency yet short enough to keep the suite
    %% honest — a second response would arrive well inside the window.
    {error, timeout} = gen_tcp:recv(Sock, 0, 400),
    ok.

-spec recv_http_response(gen_tcp:socket()) -> {100..599, binary()}.
recv_http_response(Sock) ->
    recv_http_response(Sock, <<>>).

recv_http_response(Sock, Buffer) ->
    case thrift_runtime_http:extract_response(Buffer, 64 * 1024 * 1024) of
        {ok, {Code, _Headers, Body}, _Leftover} ->
            {Code, Body};
        more ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_http_response(Sock, <<Buffer/binary, Data/binary>>)
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

%% A raw framed peer that answers every request with a reply whose
%% result struct is empty — no success field, no exception field. The
%% envelope fields (name, seqid) are echoed from the request, so the
%% client accepts the reply; only the payload shape is controlled here.

-spec with_empty_payload_peer(module(), fun((pid()) -> term())) -> term().
with_empty_payload_peer(Protocol, Test) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Peer = spawn_link(fun() -> empty_payload_peer(Listen, Protocol) end),
    {ok, Client} =
        thrift_runtime_client:start_link(#{
            host => "127.0.0.1", port => Port, service => ?SERVICE, protocol => Protocol
        }),
    try
        Test(Client)
    after
        %% the regression case crashes the client on purpose
        try
            thrift_runtime_client:stop(Client)
        catch
            _:_ -> ok
        end,
        Peer ! close
    end.

-spec empty_payload_peer(inet:socket(), module()) -> ok.
empty_payload_peer(Listen, Protocol) ->
    {ok, Sock} = gen_tcp:accept(Listen, 5000),
    empty_payload_loop(Sock, Protocol).

-spec empty_payload_loop(inet:socket(), module()) -> ok.
empty_payload_loop(Sock, Protocol) ->
    receive
        close ->
            gen_tcp:close(Sock),
            ok
    after 0 ->
        case gen_tcp:recv(Sock, 4, 5000) of
            {ok, <<Len:32/big-signed>>} ->
                {ok, Frame} = gen_tcp:recv(Sock, Len, 5000),
                {ok, call, Name, SeqId, _Tail} = Protocol:decode_message(Frame),
                {ok, Empty} = Protocol:encode({struct, {struct, []}}, #{}),
                Reply = iolist_to_binary(Protocol:encode_message(reply, Name, SeqId, Empty)),
                ok = gen_tcp:send(Sock, <<(byte_size(Reply)):32/big-signed, Reply/binary>>),
                empty_payload_loop(Sock, Protocol);
            _Closed ->
                %% the client went away (stopped or crashed)
                gen_tcp:close(Sock),
                ok
        end
    end.

%% An exported-but-broken hook (raises undef from inside) must crash the
%% call, not silently fall back to the descriptor engine: the fallback
%% exists for missing hooks and stale codecs after a reload, not for
%% bugs in generated code.

rpc_hook_undef_is_raised(_Config) ->
    {ok, Server} = thrift_runtime_server:start_link(#{
        port => 0,
        handler => ?HANDLER,
        service => thrift_runtime_test_hooked_service,
        name => rpc_hook_undef_server
    }),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} = thrift_runtime_client:start_link(#{
            host => "127.0.0.1", port => Port, service => thrift_runtime_test_hooked_service
        }),
        %% Only after the starts: their exit-shielding dance restores
        %% trap_exit to false, and the linked client dies on the
        %% re-raised undef below.
        process_flag(trap_exit, true),
        Result =
            try
                _ = call(Client, <<"echo">>, [<<"x">>]),
                fallback_masked_the_bug
            catch
                exit:Reason -> {crashed, Reason}
            end,
        ?assertMatch({crashed, {{undef, _}, _}}, Result),
        ?assertNot(is_process_alive(Client)),
        receive
            {'EXIT', Client, _} -> ok
        after 0 -> ok
        end
    after
        thrift_runtime_server:stop(Server)
    end.
