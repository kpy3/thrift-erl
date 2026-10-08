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

-module(thrift_erl_reconnecting_test).

-include_lib("eunit/include/eunit.hrl").

-define(SERVICE, thrift_erl_test_service).
-define(HANDLER, thrift_erl_test_handler).

quiet() ->
    logger:set_primary_config(level, error).

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
