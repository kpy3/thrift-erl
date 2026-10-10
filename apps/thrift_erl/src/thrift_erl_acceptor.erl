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

-export([start_link/1, stop/1, port/1, drain/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0]).

-include_lib("kernel/include/logger.hrl").

-type options() :: #{
    handler => module(),
    service => module(),
    services => #{binary() => #{handler := module(), service := module()}},
    transport => thrift_erl_socket:transport(),
    protocol => binary | compact | module(),
    max_frame_size => pos_integer(),
    max_connections => pos_integer(),
    %% the umbrella; `handshake_timeout` and `idle_timeout` name the
    %% two server-side meanings specifically
    timeout => pos_integer() | infinity,
    handshake_timeout => pos_integer() | infinity,
    idle_timeout => pos_integer() | infinity,
    active_n => pos_integer(),
    %% record representation bridge for handlers (see thrift_erl_record)
    record_api => boolean(),
    types => module(),
    backlog => pos_integer(),
    %% presence switches the listener to TLS; the handshake consumes
    %% `handshake_timeout` ms of silence before failing
    ssl_opts => [ssl:tls_server_option()],
    %% 0 binds an ephemeral port; read it back with port/1.
    port := inet:port_number()
}.

-record(state, {
    listen_socket :: thrift_erl_socket:socket(),
    connection_opts :: map(),
    max_connections :: pos_integer(),
    %% exactly one accept is in flight whenever below the cap
    accepting = false :: boolean(),
    connections = #{} :: #{reference() := pid()},
    %% drain: the listener is closed, no new connections are accepted,
    %% and the drain caller is answered once every connection is gone
    %% (or the deadline passes)
    draining = false :: boolean(),
    drain_from = undefined :: undefined | {pid(), gen_server:reply_tag()},
    drain_timer = undefined :: reference() | undefined
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

-doc """
Drains the listener: closes the listen socket, accepts nothing new, and
tells every live connection to stop — an idle one exits at once, one
with an in-flight request right after it answered. The drain completes
when the last connection is gone, or at the `Timeout` deadline
(`infinity` allowed); the deadline never fails the call: once it
passes, whatever is still connected is swept by the supervisor stop
that follows. The reply must be deferred (not answered from
`handle_call`) because observing connection exits requires the
`'DOWN'` messages only a live gen_server loop processes.
""".
-spec drain(pid(), timeout()) -> ok.
drain(Pid, infinity) ->
    gen_server:call(Pid, {drain, infinity}, infinity);
drain(Pid, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    gen_server:call(Pid, {drain, Timeout}, Timeout + 5000).

%% gen_server callbacks

-doc false.
-spec init(options()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    %% The supervisor shuts children down with exit(shutdown); trapping
    %% turns that into sys-driven terminate, which is what stops the
    %% live connections — without it they would survive the stop as
    %% orphans.
    process_flag(trap_exit, true),
    case thrift_erl_socket:listen(Opts) of
        {ok, ListenSocket} ->
            ConnectionOpts = maps:with(
                [
                    handler,
                    service,
                    services,
                    transport,
                    protocol,
                    max_frame_size,
                    timeout,
                    idle_timeout,
                    active_n,
                    record_api,
                    types
                ],
                Opts
            ),
            State =
                #state{
                    listen_socket = ListenSocket,
                    connection_opts = ConnectionOpts,
                    max_connections = thrift_erl_options:max_connections(Opts)
                },
            self() ! accept,
            {ok, State#state{accepting = true}};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
-spec handle_call(term(), {pid(), reference()}, #state{}) -> {reply, term(), #state{}}.
handle_call(port, _From, #state{listen_socket = {tcp, ListenSocket}} = State) ->
    {reply, inet:port(ListenSocket), State};
handle_call(port, _From, #state{listen_socket = {ssl, ListenSocket}} = State) ->
    {ok, {_Ip, Port}} = ssl:sockname(ListenSocket),
    {reply, {ok, Port}, State};
handle_call({drain, _Timeout}, _From, #state{draining = true} = State) ->
    {reply, ok, State};
handle_call({drain, Timeout}, From, State0) ->
    thrift_erl_socket:close(State0#state.listen_socket),
    Timer =
        case Timeout of
            infinity ->
                undefined;
            _ when is_integer(Timeout), Timeout >= 0 ->
                erlang:send_after(Timeout, self(), drain_deadline)
        end,
    State = State0#state{draining = true, drain_from = From, drain_timer = Timer},
    %% Every live connection is told to stop: the message queues behind
    %% the request it is processing (dispatch is synchronous inside its
    %% loop), so a busy connection finishes and answers the current
    %% exchange first, an idle one exits at once. Their exits are what
    %% complete the drain below.
    lists:foreach(fun(Pid) -> Pid ! drain end, maps:values(State#state.connections)),
    case map_size(State#state.connections) of
        0 ->
            {noreply, finish_drain(From, State)};
        _ ->
            {noreply, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, normal, #state{}}.
handle_info(accept, #state{draining = true} = State) ->
    %% Drain: the listen socket is closed. A pending accept message from
    %% before the drain lands here and must not open a new connection
    %% (or, with the socket gone, restart the accept loop).
    {noreply, State#state{accepting = false}};
handle_info(accept, #state{} = State) ->
    %% The in-flight accept is consumed: reset before (maybe) rescheduling.
    State0 = State#state{accepting = false},
    %% Sliced accept keeps this process responsive to calls (port/1)
    %% between waits; a plain infinity accept would swallow them.
    %% On TLS the handshake then blocks up to the handshake timeout —
    %% accepted but silent peers cannot pin the acceptor forever.
    HandshakeTimeout = thrift_erl_options:handshake_timeout(State#state.connection_opts),
    case thrift_erl_socket:accept(State#state.listen_socket, 250, HandshakeTimeout) of
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
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #state{connections = Connections} = State0) ->
    case maps:take(Ref, Connections) of
        {_Monitored, Connections1} ->
            State = State0#state{connections = Connections1},
            Drained =
                State#state.draining andalso
                    State#state.drain_from =/= undefined andalso
                    map_size(Connections1) =:= 0,
            case Drained of
                true -> {noreply, finish_drain(State#state.drain_from, State)};
                false -> {noreply, schedule_accept(State)}
            end;
        error ->
            {noreply, State0}
    end;
handle_info(drain_deadline, #state{drain_from = undefined} = State) ->
    %% A deadline that raced the drain completing.
    {noreply, State};
handle_info(drain_deadline, State) ->
    {noreply, finish_drain(State#state.drain_from, State)};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, #state{listen_socket = ListenSocket, connections = Connections}) ->
    thrift_erl_socket:close(ListenSocket),
    %% A connection can exit on its own between the last 'DOWN' bookkeeping
    %% and this sweep; a dead pid makes gen_server:stop throw noproc, which
    %% must not mask the shutdown.
    lists:foreach(
        fun(Pid) ->
            try thrift_erl_connection:stop(Pid) of
                _ -> ok
            catch
                _:_ -> ok
            end
        end,
        maps:values(Connections)
    ),
    ok.

%%--------------------------------------------------------------------
%% Connections
%%--------------------------------------------------------------------

-spec start_connection(thrift_erl_socket:socket(), #state{}) -> #state{}.
start_connection(Socket, #state{connections = Connections} = State) ->
    %% start (not start_link): connections are monitored only, so a
    %% crashing connection cannot take the listener with it.
    ConnectionOpts = (State#state.connection_opts)#{socket => Socket},
    case thrift_erl_connection:start(ConnectionOpts) of
        {ok, Pid} ->
            %% The socket is still owned here (and passive); hand it to
            %% the connection, then tell it to start reading.
            case thrift_erl_socket:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! go,
                    Ref = monitor(process, Pid),
                    State#state{connections = Connections#{Ref => Pid}};
                {error, _Reason} ->
                    %% The connection died before the handover.
                    thrift_erl_socket:close(Socket),
                    State
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{domain => [thrift], msg => "connection start failed", reason => Reason}),
            thrift_erl_socket:close(Socket),
            State
    end.

%% Schedules the next accept when below the connection cap; at the cap
%% stays silent — the next 'DOWN' resumes accepting.

-spec finish_drain(undefined | {pid(), gen_server:reply_tag()}, #state{}) -> #state{}.
finish_drain(From, #state{drain_timer = Timer} = State) ->
    case Timer of
        undefined -> ok;
        _ -> erlang:cancel_timer(Timer)
    end,
    reply_drain(From),
    State#state{drain_from = undefined, drain_timer = undefined}.

-spec reply_drain(undefined | {pid(), gen_server:reply_tag()}) -> ok.
reply_drain(undefined) ->
    ok;
reply_drain(From) ->
    gen_server:reply(From, ok).

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
