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

%% Loopback coverage of the reconnecting wrapper: live reconnect after
%% the server disappears (with backoff retries counted in between),
%% fail-fast calls against a dead port, exceptions that keep the
%% connection, oneway delivery and the statistics surface.
%%
%% The wrapper logs every failed retry at warning level by design; the
%% tests quiet the primary logger so the eunit output stays readable.
%% `none', not `error': SASL crash reports of intentionally failed
%% gen_server starts log at level `error' and would pass an `error'
%% primary straight through to the output.

-module(thrift_erl_reconnecting_test).

-include_lib("eunit/include/eunit.hrl").

-define(SERVICE, thrift_erl_test_service).
-define(HANDLER, thrift_erl_test_handler).

quiet() ->
    logger:set_primary_config(level, none).

reconnects_after_server_restart_test() ->
    quiet(),
    Port = free_port(),
    {ok, Server} = start_server(Port),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(
        opts(Port, #{reconnect_min => 50, reconnect_max => 200})
    ),
    try
        ?assertEqual({ok, 5}, call(Wrapper, <<"add">>, [2, 3])),
        ?assertMatch(#{connected := true, connects := 1, calls_ok := 1}, stats(Wrapper)),

        %% The server disappears: the wrapped client dies, the wrapper
        %% starts its backoff retries (all failing while nothing
        %% listens), then a server returns on the same port and the
        %% next retry connects.
        ok = thrift_erl_server:stop(Server),
        timer:sleep(300),
        DownStats = stats(Wrapper),
        ?assertMatch(#{connected := false}, DownStats),
        ?assert(maps:get(connect_failures, DownStats) >= 1),

        {ok, Server2} = start_server(Port),
        timer:sleep(500),
        ?assertEqual({ok, 7}, call(Wrapper, <<"add">>, [3, 4])),
        ReStats = stats(Wrapper),
        ?assertMatch(#{connected := true, connects := 2, calls_ok := 2}, ReStats),
        ?assert(maps:get(connect_failures, ReStats) >= 1),
        ok = thrift_erl_server:stop(Server2)
    after
        thrift_erl_reconnecting_client:stop(Wrapper)
    end.

call_while_disconnected_test() ->
    quiet(),
    %% A port with no listener: the wrapper starts (that is its point)
    %% and fails calls fast instead of blocking on the dead server.
    Port = free_port(),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(
        opts(Port, #{timeout => 200, reconnect_min => 50, reconnect_max => 200})
    ),
    try
        ?assertEqual({error, disconnected}, call(Wrapper, <<"add">>, [2, 3])),
        Disconnected = stats(Wrapper),
        ?assertMatch(
            #{connected := false, calls_failed := 1, connects := 0}, Disconnected
        ),
        ?assert(maps:get(connect_failures, Disconnected) >= 1)
    after
        thrift_erl_reconnecting_client:stop(Wrapper)
    end.

exceptions_keep_the_connection_test() ->
    quiet(),
    Port = free_port(),
    {ok, Server} = start_server(Port),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(opts(Port, #{})),
    try
        %% A declared exception is a protocol reply: counted as a
        %% failed call, but neither reconnected nor disconnecting.
        ?assertEqual(
            {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}},
            call(Wrapper, <<"boom">>, [])
        ),
        ?assertMatch(#{connected := true, calls_failed := 1, connects := 1}, stats(Wrapper)),
        %% The same connection still works.
        ?assertEqual({ok, 5}, call(Wrapper, <<"add">>, [2, 3])),
        ?assertMatch(#{calls_ok := 1, calls_failed := 1}, stats(Wrapper))
    after
        thrift_erl_reconnecting_client:stop(Wrapper),
        ok = thrift_erl_server:stop(Server)
    end.

oneway_through_wrapper_test() ->
    quiet(),
    Port = free_port(),
    {ok, Server} = start_server(Port),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(opts(Port, #{})),
    try
        true = register(thrift_erl_test_sink, self()),
        try
            ?assertEqual(
                ok, thrift_erl_reconnecting_client:oneway(Wrapper, <<"notify">>, [<<"fire">>], 5000)
            ),
            receive
                {notified, <<"fire">>} -> ok
            after 2000 ->
                erlang:error(oneway_not_delivered)
            end
        after
            unregister(thrift_erl_test_sink)
        end
    after
        thrift_erl_reconnecting_client:stop(Wrapper),
        ok = thrift_erl_server:stop(Server)
    end.

%% The child dies while a call is in flight: the wrapper must answer
%% {error, disconnected} and reconnect instead of dying with the
%% gen_server:call exit of the child call.

child_dies_during_call_test() ->
    quiet(),
    {Port, Peer} = mute_listener(),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(
        opts(Port, #{reconnect_min => 50, reconnect_max => 200})
    ),
    try
        Child = child_pid(),
        Caller = self(),
        spawn(fun() ->
            Caller ! {res, thrift_erl_reconnecting_client:call(Wrapper, <<"add">>, [2, 3], 5000)}
        end),
        wait_request(),
        erlang:exit(Child, kill),
        ?assertEqual(
            {error, disconnected},
            receive
                {res, R} -> R
            after 3000 ->
                erlang:error(pending_not_answered)
            end
        ),
        ?assert(erlang:is_process_alive(Wrapper)),
        ?assertMatch(#{calls_failed := 1}, stats(Wrapper)),
        %% the backoff reconnects to the still-listening port
        wait_stats(Wrapper, fun(#{connected := Connected}) -> Connected end),
        ?assertMatch(#{connects := 2}, stats(Wrapper))
    after
        thrift_erl_reconnecting_client:stop(Wrapper),
        Peer ! close
    end.

child_dies_during_oneway_test() ->
    quiet(),
    %% HTTP makes the oneway stay in flight: it waits for the (empty)
    %% response, and the mute peer never answers one.
    {Port, Peer} = mute_listener(),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(
        opts(Port, #{transport => http, reconnect_min => 50, reconnect_max => 200})
    ),
    try
        Child = child_pid(),
        Caller = self(),
        spawn(fun() ->
            Caller ! {res, thrift_erl_reconnecting_client:oneway(Wrapper, <<"notify">>, [<<"x">>], 5000)}
        end),
        wait_request(),
        erlang:exit(Child, kill),
        ?assertEqual(
            {error, disconnected},
            receive
                {res, R} -> R
            after 3000 ->
                erlang:error(pending_not_answered)
            end
        ),
        ?assert(erlang:is_process_alive(Wrapper))
    after
        thrift_erl_reconnecting_client:stop(Wrapper),
        Peer ! close
    end.

stats_reset_test() ->
    quiet(),
    Port = free_port(),
    {ok, Server} = start_server(Port),
    {ok, Wrapper} = thrift_erl_reconnecting_client:start_link(opts(Port, #{})),
    try
        ?assertEqual({ok, 5}, call(Wrapper, <<"add">>, [2, 3])),
        ?assertMatch(#{calls_ok := 1}, stats(Wrapper)),
        ?assertMatch(#{calls_ok := 1}, thrift_erl_reconnecting_client:get_and_reset_stats(Wrapper)),
        ?assertMatch(
            #{
                calls_ok := 0,
                calls_failed := 0,
                connects := 0,
                connect_failures := 0,
                connected := true
            },
            stats(Wrapper)
        )
    after
        thrift_erl_reconnecting_client:stop(Wrapper),
        ok = thrift_erl_server:stop(Server)
    end.

%%--------------------------------------------------------------------
%% Helpers

call(Wrapper, Function, Args) ->
    thrift_erl_reconnecting_client:call(Wrapper, Function, Args, 5000).

stats(Wrapper) ->
    thrift_erl_reconnecting_client:get_stats(Wrapper).

opts(Port, Overrides) ->
    maps:merge(
        #{
            host => "127.0.0.1",
            port => Port,
            service => ?SERVICE,
            transport => framed
        },
        Overrides
    ).

start_server(Port) ->
    thrift_erl_server:start_link(#{port => Port, handler => ?HANDLER, service => ?SERVICE}).

free_port() ->
    {ok, Listen} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Listen),
    gen_tcp:close(Listen),
    Port.

%% A raw listener the test controls: the client connects to it, the
%% server side never speaks — a call stays in flight until the test
%% acts. The peer process keeps the accepted socket open (it must not
%% close, or the client would see a disconnect instead of an in-flight
%% call) and tears down on `close`.

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

%% The wrapped client has no registered name; the test finds it by the
%% initial call proc_lib records in the process dictionary.

-spec child_pid() -> pid().
child_pid() ->
    Candidates =
        [
            P
         || P <- erlang:processes(),
            {dictionary, Dict} <- [process_info(P, dictionary)],
            proplists:get_value('$initial_call', Dict) =:= {thrift_erl_client, init, 1}
        ],
    case Candidates of
        [Child] -> Child;
        _ -> erlang:error(child_not_found)
    end.

-spec wait_stats(pid(), fun((thrift_erl_reconnecting_client:stats()) -> boolean())) -> ok.
wait_stats(Wrapper, Pred) ->
    wait_stats(Wrapper, Pred, 40).

-spec wait_stats(pid(), fun((thrift_erl_reconnecting_client:stats()) -> boolean()), non_neg_integer()) ->
    ok.
wait_stats(_Wrapper, _Pred, 0) ->
    erlang:error(stats_timeout);
wait_stats(Wrapper, Pred, N) ->
    case Pred(stats(Wrapper)) of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_stats(Wrapper, Pred, N - 1)
    end.
