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

-module(thrift_erl_reconnecting_client).

-moduledoc """
One connection to a Thrift server with automatic reconnection and
call statistics.

A gen_server wrapper over `thrift_erl_client`. The wrapped client keeps
its no-reconnect contract — any connection failure kills it — and this
process observes the death, reconnects with exponential backoff and
fails the calls that arrive in between with `{error, disconnected}`.
Declared and application exceptions are protocol replies: the client
survives them, so they only count in the statistics, they never
reconnect.

Reconnection is event-driven: a `'DOWN'` from the client (or a failed
connect) schedules the next attempt after a delay that starts at
`reconnect_min` (default 500 ms) and doubles up to `reconnect_max`
(default 30000 ms); a successful connect resets it. Calls fail fast
instead of blocking on a reconnect — a pool can route to another
worker immediately. Only the initial connect blocks the start (at
most the `timeout` option): like the reference Apache
`thrift_reconnecting_client`, the wrapper starts happily against a
server that is down and keeps trying.

`get_stats/1` is the health-check surface for pool owners:

```
#{connected := boolean(), calls_ok := N, calls_failed := N,
  connects := N, connect_failures := N}
```

`get_and_reset_stats/1` returns the same map and zeroes the counters
(`connected` stays live). Options are the `thrift_erl_client` map plus
`reconnect_min` and `reconnect_max` (milliseconds).

The `on_event` handler passes through to the wrapped client unchanged,
so it sees the call-level `call_ok` / `call_error` events; the
connection axis adds this wrapper's own events — `connected`,
`connect_failed`, `disconnected` (see `thrift_erl_events`).
""".

-behaviour(gen_server).

-export([
    start/1,
    start_link/1,
    stop/1,
    call/4,
    oneway/4,
    get_stats/1,
    get_and_reset_stats/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0, stats/0]).

-include_lib("kernel/include/logger.hrl").

-type options() :: #{
    host := inet:socket_address() | inet:hostname(),
    port := inet:port_number(),
    service := module(),
    %% everything below passes through to `thrift_erl_client` unchanged
    transport => thrift_erl_socket:transport(),
    protocol => binary | compact | module(),
    timeout => pos_integer(),
    max_frame_size => pos_integer(),
    http_path => binary(),
    ssl_opts => [ssl:tls_client_option()],
    multiplex => binary(),
    active_n => pos_integer(),
    reconnect_min => pos_integer(),
    reconnect_max => pos_integer(),
    %% passes through to `thrift_erl_client'; this wrapper adds the
    %% connection-axis events on top
    on_event => thrift_erl_events:handler()
}.

-type stats() :: #{
    connected := boolean(),
    calls_ok := non_neg_integer(),
    calls_failed := non_neg_integer(),
    connects := non_neg_integer(),
    connect_failures := non_neg_integer()
}.

-define(DEFAULT_RECONNECT_MIN, 500).
-define(DEFAULT_RECONNECT_MAX, 30000).

-record(state, {
    opts :: options(),
    protocol :: module(),
    child :: undefined | pid(),
    monitor :: undefined | reference(),
    reconnect_delay = 0 :: non_neg_integer(),
    reconnect_min :: pos_integer(),
    reconnect_max :: pos_integer(),
    calls_ok = 0 :: non_neg_integer(),
    calls_failed = 0 :: non_neg_integer(),
    connects = 0 :: non_neg_integer(),
    connect_failures = 0 :: non_neg_integer(),
    handler :: thrift_erl_events:handler()
}).

-doc """
Starts the reconnecting client and links it to the caller.

The initial connect attempt blocks for at most the `timeout` option,
but a server that is down does not fail the start — the wrapper keeps
retrying in the background. A failed init (a bad protocol or
`on_event` option) answers `{error, Reason}` only: the trapping around
the start shields the caller from the failed child's exit race, the
same dance `thrift_erl_client` does.
""".
-spec start_link(options()) -> gen_server:start_ret().
start_link(Opts) ->
    process_flag(trap_exit, true),
    Result = gen_server:start_link(?MODULE, Opts, []),
    process_flag(trap_exit, false),
    Result.

-doc """
Starts the reconnecting client without linking — for owners that
monitor instead, such as pool workers.
""".
-spec start(options()) -> gen_server:start_ret().
start(Opts) ->
    gen_server:start(?MODULE, Opts, []).

-doc "Stops the wrapper and the client it currently holds.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-doc """
Calls `Function` with `Args` (declaration order, wire representation)
through the wrapped client.

Fails immediately with `{error, disconnected}` while the wrapper has
no connection; exceptions reported by the server come back unchanged
and keep the connection.
""".
-spec call(pid(), binary(), [term()], pos_integer() | infinity) ->
    {ok, term()} | {error, term()}.
call(Pid, Function, Args, Timeout) ->
    gen_server:call(Pid, {call, Function, Args, Timeout}, infinity).

-doc "Sends a one-way call; the server never answers.".
-spec oneway(pid(), binary(), [term()], pos_integer() | infinity) -> ok | {error, term()}.
oneway(Pid, Function, Args, Timeout) ->
    gen_server:call(Pid, {oneway, Function, Args, Timeout}, infinity).

-doc "Returns the connection state and the call/connect counters.".
-spec get_stats(pid()) -> stats().
get_stats(Pid) ->
    gen_server:call(Pid, get_stats).

-doc "Returns the statistics and zeroes the counters (`connected` stays live).".
-spec get_and_reset_stats(pid()) -> stats().
get_and_reset_stats(Pid) ->
    gen_server:call(Pid, get_and_reset_stats).

%% gen_server callbacks

-doc false.
-spec init(options()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    %% A bad protocol is a configuration error: fail the start the same
    %% way the plain client would. A dead server is not: this wrapper
    %% exists to outlive it.
    case {thrift_erl_options:protocol_module(Opts), thrift_erl_options:on_event(Opts)} of
        {{ok, Protocol}, {ok, Handler}} ->
            State =
                #state{
                    opts = Opts,
                    protocol = Protocol,
                    reconnect_min = maps:get(reconnect_min, Opts, ?DEFAULT_RECONNECT_MIN),
                    reconnect_max = maps:get(reconnect_max, Opts, ?DEFAULT_RECONNECT_MAX),
                    handler = Handler
                },
            {ok, connect(State)};
        {{error, Reason}, _} ->
            {stop, {protocol, Reason}};
        {_, {error, Reason}} ->
            {stop, Reason}
    end.

-doc false.
-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, term(), #state{}}.
handle_call({call, _Function, _Args, _Timeout}, _From, #state{child = undefined} = State) ->
    {reply, {error, disconnected}, State#state{calls_failed = State#state.calls_failed + 1}};
handle_call({call, Function, Args, Timeout}, _From, #state{child = Child} = State) ->
    case child_call(fun() -> thrift_erl_client:call(Child, Function, Args, Timeout) end) of
        {ok, Reply} ->
            {reply, {ok, Reply}, State#state{calls_ok = State#state.calls_ok + 1}};
        {error, Reason} ->
            {reply, {error, Reason}, State#state{calls_failed = State#state.calls_failed + 1}}
    end;
handle_call({oneway, _Function, _Args, _Timeout}, _From, #state{child = undefined} = State) ->
    {reply, {error, disconnected}, State#state{calls_failed = State#state.calls_failed + 1}};
handle_call({oneway, Function, Args, Timeout}, _From, #state{child = Child} = State) ->
    case child_call(fun() -> thrift_erl_client:oneway(Child, Function, Args, Timeout) end) of
        ok ->
            {reply, ok, State#state{calls_ok = State#state.calls_ok + 1}};
        {error, Reason} ->
            {reply, {error, Reason}, State#state{calls_failed = State#state.calls_failed + 1}}
    end;
handle_call(get_stats, _From, State) ->
    {reply, stats(State), State};
handle_call(get_and_reset_stats, _From, State) ->
    Reset =
        State#state{
            calls_ok = 0,
            calls_failed = 0,
            connects = 0,
            connect_failures = 0
        },
    {reply, stats(State), Reset}.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
%% The client dies on every connection failure by contract; this is
%% the reconnect trigger.

handle_info({'DOWN', Monitor, process, _Child, Reason}, #state{monitor = Monitor} = State) ->
    Delay = next_delay(State),
    thrift_erl_events:emit(State#state.handler, disconnected, #{
        reason => Reason, retry_in_ms => Delay
    }),
    erlang:send_after(Delay, self(), reconnect),
    {noreply, State#state{child = undefined, monitor = undefined, reconnect_delay = Delay}};
handle_info(reconnect, #state{child = undefined} = State) ->
    {noreply, connect(State)};
handle_info(reconnect, State) ->
    %% A stale retry after a connect already succeeded.
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{child = undefined}) ->
    ok;
terminate(_Reason, #state{child = Child}) ->
    %% Best effort: the child may be dying already.
    try
        thrift_erl_client:stop(Child)
    catch
        _:_ -> ok
    end,
    ok.

%%--------------------------------------------------------------------
%% Connect and backoff
%%--------------------------------------------------------------------

%% A child dying mid-call exits the gen_server:call in this process
%% (the monitor inside the call sees the death first); the wrapper must
%% outlive it and answer the caller — the 'DOWN' handler reconnects.

-spec child_call(fun(() -> R)) -> R | {error, disconnected}.
child_call(Fun) ->
    try
        Fun()
    catch
        exit:_Reason:_Stack -> {error, disconnected}
    end.

-spec connect(#state{}) -> #state{}.
connect(#state{protocol = Protocol, handler = Handler} = State) ->
    Opts = (State#state.opts)#{protocol => Protocol},
    case thrift_erl_client:start(Opts) of
        {ok, Child} ->
            thrift_erl_events:emit(Handler, connected, #{}),
            State#state{
                child = Child,
                monitor = monitor(process, Child),
                reconnect_delay = 0,
                connects = State#state.connects + 1
            };
        {error, Reason} ->
            Delay = next_delay(State),
            ?LOG_WARNING(#{
                domain => [thrift],
                msg => "connect failed, retrying",
                reason => Reason,
                retry_in => Delay
            }),
            thrift_erl_events:emit(Handler, connect_failed, #{
                reason => Reason, retry_in_ms => Delay
            }),
            erlang:send_after(Delay, self(), reconnect),
            State#state{
                child = undefined,
                monitor = undefined,
                reconnect_delay = Delay,
                connect_failures = State#state.connect_failures + 1
            }
    end.

%% Schedules the first retry after a client death: the delay counter
%% was reset by the last successful connect, so this starts at the
%% minimum.

-spec next_delay(#state{}) -> pos_integer().
next_delay(#state{reconnect_delay = 0, reconnect_min = Min}) ->
    Min;
next_delay(#state{reconnect_delay = Delay, reconnect_max = Max}) ->
    erlang:min(2 * Delay, Max).

-spec stats(#state{}) -> stats().
stats(#state{} = State) ->
    #{
        connected => State#state.child =/= undefined,
        calls_ok => State#state.calls_ok,
        calls_failed => State#state.calls_failed,
        connects => State#state.connects,
        connect_failures => State#state.connect_failures
    }.
