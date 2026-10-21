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

-module(thrift_runtime_events).

-moduledoc """
The runtime's observability callbacks: one `on_event` handler per
client or server, no dependencies.

The `on_event` option accepted by `thrift_runtime_client`,
`thrift_runtime_reconnecting_client` and `thrift_runtime_server` (it rides the
whitelisted connection options down to `thrift_runtime_connection`) is one
of:

- `undefined` (the default) — nothing is emitted and the emit sites
  cost a pattern match;
- a fun of arity 1 — called with each event;
- `{Module, Function, Args}` — `Module:Function(Args ++ [Event])`,
  so a handler can carry its own context (a pool id, an ETS table).

Dispatch is synchronous in the emitting process and crash-isolated: a
handler exception is discarded, it never reaches the caller, the
client or the server. Handlers must still be fast — they run on the
call path. Counting here complements, not replaces, `logger`: the
warning logs keep the stack traces and the exceptional traffic.

The event catalogue (one map per event, `type` first):

- `thrift_runtime_client`, one event per caller-facing answer, so counting
  `call_ok` / `call_error` reproduces `get_stats/1`:
  `#{type => call_ok, function => binary(), duration_us => N, oneway => boolean()}` —
  `duration_us` covers the queue wait and the wire round-trip, the
  same span the per-call timeout arms over;
  `#{type => call_error, function => binary(), reason => term(),
  duration_us => N, oneway => boolean()}` — the reason is whatever the
  caller receives (`queue_full`, `closed`, a timeout atom, a protocol
  error, a declared exception tuple, ...).
- `thrift_runtime_reconnecting_client` (the connection axis only; call
  events come from the wrapped client, which gets the same handler):
  `#{type => connected}`,
  `#{type => connect_failed, reason => term(), retry_in_ms => N}`,
  `#{type => disconnected, reason => term(), retry_in_ms => N}`.
- `thrift_runtime_connection` (server side):
  `#{type => connection_open, peer => {inet:ip_address(),
  inet:port_number()} | undefined}`,
  `#{type => connection_closed, reason => term()}`,
  `#{type => handler_error, function => binary(), reason => term()}` —
  a handler crash (reason is the handler's exception) or an unsupported
  handler result (reason is `{bad_result, Result}`); declared
  exceptions and protocol errors are answers, not handler errors.
""".

-export([emit/3, dispatch/2]).

-export_type([handler/0, event/0]).

-type handler() ::
    undefined
    | fun((event()) -> any())
    | {module(), atom(), [term()]}.

-type event() ::
    #{type := call_ok, function := binary(), duration_us := non_neg_integer(), oneway := boolean()}
    | #{
        type := call_error,
        function := binary(),
        reason := term(),
        duration_us := non_neg_integer(),
        oneway := boolean()
    }
    | #{type := connected}
    | #{type := connect_failed, reason := term(), retry_in_ms := pos_integer()}
    | #{type := disconnected, reason := term(), retry_in_ms := pos_integer()}
    | #{type := connection_open, peer := term()}
    | #{type := connection_closed, reason := term()}
    | #{type := handler_error, function := binary(), reason := term()}.

-doc """
Emits an event of `Type` unless the handler is `undefined` — the map
is not built on the no-handler path, which is the default one.
""".
-spec emit(handler(), atom(), map()) -> ok.
emit(undefined, _Type, _Fields) ->
    ok;
emit(Handler, Type, Fields) ->
    apply_handler(Handler, maps:merge(maps:remove(type, Fields), #{type => Type})).

-doc "Calls the handler with the event; handler exceptions are discarded.".
-spec dispatch(handler(), event()) -> ok.
dispatch(Handler, Event) ->
    apply_handler(Handler, Event).

%% The application itself is typed over any map: `emit/3' assembles the
%% event dynamically, which the precise `event()' union cannot express.

-spec apply_handler(handler(), map()) -> ok.
apply_handler(undefined, _Event) ->
    ok;
apply_handler(Handler, Event) when is_function(Handler, 1) ->
    try Handler(Event) of
        _ -> ok
    catch
        _:_ -> ok
    end;
apply_handler({Module, Function, Args}, Event) when is_atom(Module), is_atom(Function), is_list(Args) ->
    try erlang:apply(Module, Function, Args ++ [Event]) of
        _ -> ok
    catch
        _:_ -> ok
    end.
