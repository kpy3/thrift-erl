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

-module(thrift_erl_acceptor).

-moduledoc """
Listens on a port and starts a connection process per client.

Connections are monitored (not linked): a crashing connection touches
neither the listener nor its siblings. `max_connections` caps live
connections; while at the cap no new accept is scheduled, and a
connection going down resumes accepting, which is the backpressure
mechanism.
""".

-behaviour(gen_server).

-export([start_link/1, stop/1, port/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0]).

-include_lib("kernel/include/logger.hrl").

-type options() :: #{
    handler := module(),
    service := module(),
    transport => thrift_erl_socket:transport(),
    max_frame_size => pos_integer(),
    max_connections => pos_integer(),
    timeout => pos_integer(),
    %% record representation bridge for handlers (see thrift_erl_record)
    record_api => boolean(),
    types => module(),
    backlog => pos_integer(),
    %% 0 binds an ephemeral port; read it back with port/1.
    port := inet:port_number(),
    %% registration name for the server supervisor (optional)
    name => atom()
}.

-record(state, {
    listen_socket :: gen_tcp:socket(),
    connection_opts :: map(),
    max_connections :: pos_integer(),
    %% exactly one accept is in flight whenever below the cap
    accepting = false :: boolean(),
    connections = #{} :: #{reference() := pid()}
}).

-doc """
Starts the listener.

`init` fails (stopping the server) if the port cannot be bound.
""".
-spec start_link(options()) -> gen_server:start_ret().
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-doc "Stops the listener; live connections are not affected.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-doc "Returns the port the listener bound (useful with `port = 0`).".
-spec port(pid()) -> {ok, inet:port_number()}.
port(Pid) ->
    gen_server:call(Pid, port).

%% gen_server callbacks

-doc false.
-spec init(options()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    case thrift_erl_socket:listen(Opts) of
        {ok, ListenSocket} ->
            ConnectionOpts = maps:with(
                [handler, service, transport, protocol, max_frame_size, timeout, record_api, types],
                Opts
            ),
            State =
                #state{
                    listen_socket = ListenSocket,
                    connection_opts = ConnectionOpts,
                    max_connections = maps:get(max_connections, Opts, 1024)
                },
            self() ! accept,
            {ok, State#state{accepting = true}};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
-spec handle_call(term(), {pid(), reference()}, #state{}) -> {reply, term(), #state{}}.
handle_call(port, _From, #state{listen_socket = ListenSocket} = State) ->
    {reply, inet:port(ListenSocket), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, normal, #state{}}.
handle_info(accept, #state{} = State) ->
    %% The in-flight accept is consumed: reset before (maybe) rescheduling.
    State0 = State#state{accepting = false},
    %% Sliced accept keeps this process responsive to calls (port/1)
    %% between waits; a plain infinity accept would swallow them.
    case gen_tcp:accept(State#state.listen_socket, 250) of
        {ok, Socket} ->
            State1 = start_connection(Socket, State0),
            {noreply, schedule_accept(State1)};
        {error, timeout} ->
            self() ! accept,
            {noreply, State0#state{accepting = true}};
        {error, closed} ->
            {stop, normal, State0};
        {error, Reason} ->
            ?LOG_ERROR(#{domain => [thrift], msg => "accept failed", reason => Reason}),
            {noreply, schedule_accept(State0)}
    end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #state{connections = Connections} = State) ->
    case maps:take(Ref, Connections) of
        {_Monitored, Connections1} ->
            {noreply, schedule_accept(State#state{connections = Connections1})};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, #state{listen_socket = ListenSocket, connections = Connections}) ->
    gen_tcp:close(ListenSocket),
    lists:foreach(fun thrift_erl_connection:stop/1, maps:values(Connections)),
    ok.

%%--------------------------------------------------------------------
%% Connections
%%--------------------------------------------------------------------

-spec start_connection(gen_tcp:socket(), #state{}) -> #state{}.
start_connection(Socket, #state{connections = Connections} = State) ->
    %% start (not start_link): connections are monitored only, so a
    %% crashing connection cannot take the listener with it.
    ConnectionOpts = (State#state.connection_opts)#{socket => Socket},
    case thrift_erl_connection:start(ConnectionOpts) of
        {ok, Pid} ->
            %% The socket is still owned here (and passive); hand it to
            %% the connection, then tell it to start reading.
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! go,
                    Ref = monitor(process, Pid),
                    State#state{connections = Connections#{Ref => Pid}};
                {error, _Reason} ->
                    %% The connection died before the handover.
                    gen_tcp:close(Socket),
                    State
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{domain => [thrift], msg => "connection start failed", reason => Reason}),
            gen_tcp:close(Socket),
            State
    end.

%% Schedules the next accept when below the connection cap; at the cap
%% stays silent — the next 'DOWN' resumes accepting.

-spec schedule_accept(#state{}) -> #state{}.
schedule_accept(#state{accepting = true} = State) ->
    State;
schedule_accept(#state{connections = Connections} = State) when
    map_size(Connections) < State#state.max_connections
->
    self() ! accept,
    State#state{accepting = true};
schedule_accept(#state{} = State) ->
    State#state{accepting = false}.
