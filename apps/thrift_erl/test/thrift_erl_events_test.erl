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

%% The `on_event' observability surface: dispatch isolation (a crashing
%% handler must never reach the caller), option validation, and the
%% event catalogue over live loopback endpoints — one event per
%% caller-facing client answer (call_ok/call_error), the connection
%% axis of the reconnecting wrapper, and the server-side connection
%% lifecycle plus handler errors.
%%
%% Handlers forward events straight into the test mailbox; the receive
%% helpers match only `collect' messages, so in-flight answers from
%% spawned callers never collide.

-module(thrift_erl_events_test).

-include_lib("eunit/include/eunit.hrl").

-define(SERVICE, thrift_erl_test_service).
-define(HANDLER, thrift_erl_test_handler).

%% The `{M, F, A}' handler forms below reach these dynamically — the
%% compiler needs the exports to accept the local fun references.

-export([collect/2, explode/0]).

%%--------------------------------------------------------------------
%% Handler dispatch

undefined_handler_costs_nothing_test() ->
    ok = thrift_erl_events:emit(undefined, call_ok, #{function => <<"x">>}),
    ok = thrift_erl_events:dispatch(undefined, #{type => connected}).

fun_handler_receives_the_event_test() ->
    Self = self(),
    ok = thrift_erl_events:emit(collector(Self), call_ok, #{function => <<"add">>}),
    ?assertMatch(
        {collect, #{type := call_ok, function := <<"add">>}},
        receive
            M -> M
        after 1000 -> erlang:error(no_event)
        end
    ).

mfa_handler_gets_the_event_appended_test() ->
    ok = thrift_erl_events:emit({?MODULE, collect, [self()]}, connected, #{}),
    ?assertMatch(
        {collect, #{type := connected}},
        receive
            M -> M
        after 1000 -> erlang:error(no_event)
        end
    ).

collect(Pid, Event) ->
    Pid ! {collect, Event}.

crashing_handlers_are_isolated_test() ->
    Self = self(),
    ?assertEqual(
        ok,
        thrift_erl_events:emit(fun(_) -> erlang:error(deliberate) end, call_ok, #{})
    ),
    ?assertEqual(
        ok,
        thrift_erl_events:emit({?MODULE, explode, []}, call_ok, #{})
    ),
    %% the emitting process is untouched
    Self ! fine,
    ?assertEqual(
        fine,
        receive
            M -> M
        after 0 -> no
        end
    ).

explode() ->
    erlang:error(deliberate).

%%--------------------------------------------------------------------
%% Option validation

on_event_option_validation_test() ->
    ?assertEqual({ok, undefined}, thrift_erl_options:on_event(#{})),
    ?assertEqual({ok, undefined}, thrift_erl_options:on_event(#{on_event => undefined})),
    Fun = fun(_) -> ok end,
    ?assertEqual({ok, Fun}, thrift_erl_options:on_event(#{on_event => Fun})),
    ?assertEqual(
        {ok, {?MODULE, collect, [self()]}},
        thrift_erl_options:on_event(#{on_event => {?MODULE, collect, [self()]}})
    ),
    Bad = [1, <<"x">>, fun erlang:phash2/2, {?MODULE, collect}, {?MODULE, collect, self()}],
    lists:foreach(
        fun(Value) ->
            ?assertEqual(
                {error, {on_event, Value}}, thrift_erl_options:on_event(#{on_event => Value})
            )
        end,
        Bad
    ).

bad_option_fails_the_start_test() ->
    %% the intentionally failed starts below crash-report otherwise
    quiet(),
    Port = free_port(),
    ?assertEqual(
        {error, {on_event, 42}},
        thrift_erl_client:start_link(opts(Port, #{on_event => 42}))
    ),
    ?assertEqual(
        {error, {on_event, 42}},
        thrift_erl_reconnecting_client:start_link(opts(Port, #{on_event => 42}))
    ),
    %% the acceptor validates before it starts accepting; the ephemeral
    %% listen socket it opened for the attempt is closed again
    ?assertEqual(
        {error, {shutdown, {failed_to_start_child, acceptor, {on_event, 42}}}},
        thrift_erl_server:start_link(#{name => thrift_erl_events_bad_server, port => 0, on_event => 42})
    ).

%%--------------------------------------------------------------------
%% Client events: one per caller-facing answer

client_call_events_test() ->
    quiet(),
    Port = free_port(),
    Server = server_on(Port, undefined),
    Events = collector(self()),
    {ok, Client} = thrift_erl_client:start_link(opts(Port, #{on_event => Events})),
    try
        ?assertEqual({ok, 5}, thrift_erl_client:call(Client, <<"add">>, [2, 3], 5000)),
        ?assertMatch(
            [#{type := call_ok, function := <<"add">>, duration_us := D, oneway := false}] when
                is_integer(D) andalso D >= 0,
            take_events(1)
        ),

        %% A declared exception is a failed call with the same reason
        %% the caller sees.
        {error, _} = thrift_erl_client:call(Client, <<"boom">>, [], 5000),
        ?assertMatch(
            [#{type := call_error, function := <<"boom">>, oneway := false}],
            take_events(1)
        ),

        %% A handler crash is a protocol-level application exception for
        %% the client; the server-side handler_error event is covered
        %% in the server test.
        ?assertMatch(
            {error, {application_exception, _, 6, _}},
            thrift_erl_client:call(Client, <<"boomInternal">>, [], 5000)
        ),
        [E3] = take_events(1),
        ?assertMatch(#{type := call_error, function := <<"boomInternal">>}, E3),
        ?assert(is_map_key(reason, E3)),

        %% A oneway is answered as soon as the bytes are out.
        ?assertEqual(ok, thrift_erl_client:oneway(Client, <<"notify">>, [<<"x">>], 5000)),
        ?assertMatch(
            [#{type := call_ok, function := <<"notify">>, oneway := true}], take_events(1)
        ),

        %% An unknown function fails locally; the connection stays.
        ?assertEqual(
            {error, unknown_function}, thrift_erl_client:call(Client, <<"nope">>, [], 5000)
        ),
        ?assertMatch(
            [#{type := call_error, function := <<"nope">>, reason := unknown_function}],
            take_events(1)
        ),

        %% The stats and the events tell the same story.
        ?assertMatch(#{calls_ok := 2, calls_failed := 3}, thrift_erl_client:get_stats(Client))
    after
        thrift_erl_client:stop(Client),
        ok = thrift_erl_server:stop(Server)
    end.

client_queue_full_event_test() ->
    quiet(),
    Port = free_port(),
    Server = server_on(Port, undefined),
    Events = collector(self()),
    %% A zero-depth queue rejects every call before it is queued.
    {ok, Client} =
        thrift_erl_client:start_link(opts(Port, #{on_event => Events, max_queue_depth => 0})),
    try
        ?assertEqual({error, queue_full}, thrift_erl_client:call(Client, <<"add">>, [2, 3], 5000)),
        ?assertMatch(
            [#{type := call_error, function := <<"add">>, reason := queue_full}], take_events(1)
        ),
        ?assertMatch(#{calls_failed := 1}, thrift_erl_client:get_stats(Client))
    after
        thrift_erl_client:stop(Client),
        ok = thrift_erl_server:stop(Server)
    end.

%% The connection drops under an in-flight call: the pending call and
%% whatever is queued behind it all get `closed' events, in that order.

client_closed_events_test() ->
    quiet(),
    {Port, Peer} = mute_listener(),
    Events = collector(self()),
    {ok, Client} = thrift_erl_client:start_link(opts(Port, #{on_event => Events, timeout => 200})),
    try
        Caller = self(),
        spawn(fun() ->
            Caller ! {res, thrift_erl_client:call(Client, <<"add">>, [2, 3], 5000)}
        end),
        wait_request(),
        %% The oneway queues behind the in-flight call; its enqueue is
        %% spawned too (the caller would otherwise block on the answer
        %% that only the close below produces) and gets a moment to
        %% land in the queue before the connection drops.
        spawn(fun() ->
            thrift_erl_client:oneway(Client, <<"notify">>, [<<"x">>], 5000)
        end),
        timer:sleep(100),
        Peer ! close,
        ?assertEqual(
            {error, closed},
            receive
                {res, R} -> R
            after 3000 ->
                erlang:error(pending_not_answered)
            end
        ),
        [E1, E2] = take_events(2),
        ?assertMatch(#{type := call_error, function := <<"add">>, reason := closed}, E1),
        ?assertMatch(#{type := call_error, function := <<"notify">>, reason := closed}, E2)
    after
        %% the drop already stopped the client
        try
            thrift_erl_client:stop(Client)
        catch
            _:_ -> ok
        end
    end.

%%--------------------------------------------------------------------
%% Reconnecting wrapper: the connection axis

reconnecting_connection_events_test() ->
    quiet(),
    Port = free_port(),
    Server = server_on(Port, undefined),
    Events = collector(self()),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(
        opts(Port, #{on_event => Events, reconnect_min => 50, reconnect_max => 200})
    ),
    try
        ?assertMatch([#{type := connected}], wait_for_events(connected, 1)),

        %% The server disappears: the wrapped client dies and the
        %% wrapper schedules the retry.
        ok = thrift_erl_server:stop(Server),
        [D] = wait_for_events(disconnected, 1),
        ?assert(is_map_key(reason, D)),
        ?assert(maps:get(retry_in_ms, D) >= 50),

        %% connect_failed events stream in while nothing listens.
        [CF] = wait_for_events(connect_failed, 1),
        ?assert(is_map_key(reason, CF)),
        ?assert(maps:get(retry_in_ms, CF) >= 50),

        %% The call-level events come from the wrapped child with the
        %% same handler; the second server lives in its own try so its
        %% stop never references a variable of this try's body.
        reconnect_again(Port, Wrapper)
    after
        thrift_erl_reconnecting_client:stop(Wrapper),
        %% the in-body stop may not have run if an assertion failed
        %% first; a default-named server left behind poisons every
        %% later suite
        try
            thrift_erl_server:stop(Server)
        catch
            _:_ -> ok
        end
    end.

reconnect_again(Port, Wrapper) ->
    Server2 = server_on(Port, undefined),
    try
        ok = wait_connected(Wrapper),
        ?assertMatch(
            #{connected := true}, thrift_erl_reconnecting_client:get_stats(Wrapper)
        ),
        ?assertEqual({ok, 5}, thrift_erl_reconnecting_client:call(Wrapper, <<"add">>, [2, 3], 5000)),
        ?assertMatch(
            [#{type := call_ok, function := <<"add">>}], wait_for_events(call_ok, 1)
        )
    after
        thrift_erl_server:stop(Server2)
    end.

wait_connected(Wrapper) ->
    wait_stats(Wrapper, fun(#{connected := Connected}) -> Connected end),
    ok.

%%--------------------------------------------------------------------
%% Server events

server_connection_and_handler_events_test() ->
    quiet(),
    Port = free_port(),
    Events = collector(self()),
    Server = server_on(Port, Events),
    {ok, Client} = thrift_erl_client:start_link(opts(Port, #{})),
    try
        %% The connection announces itself with its peer endpoint.
        [O] = wait_for_events(connection_open, 1),
        ?assertMatch({_, _}, maps:get(peer, O)),

        %% A handler crash reaches the event stream with the handler's
        %% own reason; the client still gets its application exception.
        ?assertMatch(
            {error, {application_exception, _, 6, _}},
            thrift_erl_client:call(Client, <<"boomInternal">>, [], 5000)
        ),
        ?assertMatch(
            [#{type := handler_error, function := <<"boomInternal">>, reason := deliberate}],
            wait_for_events(handler_error, 1)
        ),

        %% Stopping the server closes the connection with a reason.
        ok = thrift_erl_server:stop(Server),
        [C] = wait_for_events(connection_closed, 1),
        ?assert(is_map_key(reason, C))
    after
        %% The server stop above closed the connection and the client
        %% stops itself on tcp_closed, so by the time this block runs
        %% the client may already be gone — its stop then races a
        %% noproc, which is the expected outcome here.
        try
            thrift_erl_client:stop(Client)
        catch
            exit:noproc -> ok
        end,
        %% the in-body stop may not have run if an assertion failed
        %% first; a default-named server left behind poisons every
        %% later suite
        try
            thrift_erl_server:stop(Server)
        catch
            _:_ -> ok
        end
    end.

%%--------------------------------------------------------------------
%% Helpers

server_on(Port, Events) ->
    {ok, Server} = start_server(Port, Events),
    %% Bound through this helper call so after-block try-stops see a
    %% safe variable even when assertions fail before the in-body stops.
    Server.

%% Silences the SASL crash/supervisor reports of intentionally failed
%% gen_server starts: they log at level `error', so `error' — the old
%% value here — passed them straight through to the CI log.

quiet() ->
    logger:set_primary_config(level, none).

opts(Port, Overrides) ->
    maps:merge(
        #{
            host => "127.0.0.1",
            port => Port,
            service => ?SERVICE,
            transport => framed,
            timeout => 200
        },
        Overrides
    ).

start_server(Port, Events) ->
    Base = #{port => Port, handler => ?HANDLER, service => ?SERVICE},
    thrift_erl_server:start_link(
        case Events of
            undefined -> Base;
            _ -> Base#{on_event => Events}
        end
    ).

collector(Pid) ->
    fun(E) -> Pid ! {collect, E} end.

take_events(N) ->
    take_events(N, []).

take_events(0, Acc) ->
    lists:reverse(Acc);
take_events(N, Acc) ->
    receive
        {collect, E} -> take_events(N - 1, [E | Acc])
    after 3000 ->
        erlang:error({events_timeout, N})
    end.

%% Waits for `N' events of the given type; anything else in between is
%% skipped over.

wait_for_events(Type, N) ->
    wait_for_events(Type, N, 6000).

wait_for_events(_Type, 0, _Timeout) ->
    [];
wait_for_events(Type, N, Timeout) ->
    receive
        {collect, #{type := Type} = E} -> [E | wait_for_events(Type, N - 1, Timeout)];
        {collect, _} -> wait_for_events(Type, N, Timeout)
    after Timeout ->
        erlang:error({event_timeout, Type})
    end.

%% A raw listener the test controls: the client connects to it, the
%% server side never speaks — a call stays in flight until the test
%% acts. The peer process keeps the accepted socket open (it must not
%% close, or the client would see a disconnect instead of an in-flight
%% call) and tears down on `close'.

-spec mute_listener() -> {inet:port_number(), pid()}.
mute_listener() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Parent = self(),
    Peer =
        spawn(fun() ->
            {ok, Sock} = gen_tcp:accept(Listen, 2000),
            {ok, _Head} = gen_tcp:recv(Sock, 0, 2000),
            Parent ! request_seen,
            receive
                close ->
                    gen_tcp:close(Sock),
                    gen_tcp:close(Listen)
            end
        end),
    {Port, Peer}.

wait_request() ->
    receive
        request_seen ->
            ok
    after 3000 ->
        erlang:error(request_not_seen)
    end.

free_port() ->
    {ok, Listen} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Listen),
    gen_tcp:close(Listen),
    Port.

-spec wait_stats(pid(), fun((thrift_erl_reconnecting_client:stats()) -> boolean())) -> ok.
wait_stats(Wrapper, Pred) ->
    wait_stats(Wrapper, Pred, 40).

-spec wait_stats(
    pid(), fun((thrift_erl_reconnecting_client:stats()) -> boolean()), non_neg_integer()
) -> ok.
wait_stats(_Wrapper, _Pred, 0) ->
    erlang:error(stats_timeout);
wait_stats(Wrapper, Pred, N) ->
    case Pred(thrift_erl_reconnecting_client:get_stats(Wrapper)) of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_stats(Wrapper, Pred, N - 1)
    end.
