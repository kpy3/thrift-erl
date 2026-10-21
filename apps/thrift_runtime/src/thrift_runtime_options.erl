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

-module(thrift_runtime_options).

-moduledoc """
The runtime's option surface in one place: defaults and typed getters.

Every endpoint parses its options at creation time from the map the
caller passes. This module keeps the defaults from drifting apart
across `thrift_runtime_acceptor`, `thrift_runtime_connection`,
`thrift_runtime_client` and `thrift_runtime_reconnecting_client`, and keeps
`timeout` from meaning three different things: it is the umbrella
standing in for every more specific timeout the caller does not name —

- `handshake_timeout` — server only: the TLS handshake slice between
  the transport accept and the handover;
- `idle_timeout` — server only: the maximum silence between messages;
- `connect_timeout` — client only: the connect and TLS handshake wait.

A specific key wins over the umbrella, the umbrella wins over the
default.
""".

-export([
    handshake_timeout/1,
    idle_timeout/1,
    connect_timeout/1,
    transport/1,
    protocol_module/1,
    max_frame_size/1,
    active_n/1,
    http_path/1,
    max_connections/1,
    on_event/1
]).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_MAX_FRAME_SIZE, 64 * 1024 * 1024).
-define(DEFAULT_ACTIVE_N, 100).
-define(DEFAULT_MAX_CONNECTIONS, 1024).
-define(DEFAULT_HTTP_PATH, <<"/">>).

%%--------------------------------------------------------------------
%% Timeouts
%%--------------------------------------------------------------------

%% The acceptor slices the accept wait itself (250 ms), so this value
%% only bounds the TLS handshake of an accepted-but-silent peer.

-doc "The TLS handshake timeout of the server side.".
-spec handshake_timeout(map()) -> pos_integer() | infinity.
handshake_timeout(Opts) ->
    umbrella(Opts, handshake_timeout).

-doc "The maximum silence between messages on the server side.".
-spec idle_timeout(map()) -> pos_integer() | infinity.
idle_timeout(Opts) ->
    umbrella(Opts, idle_timeout).

-doc "The connect and TLS handshake timeout of the client side.".
-spec connect_timeout(map()) -> pos_integer() | infinity.
connect_timeout(Opts) ->
    umbrella(Opts, connect_timeout).

%% `timeout` is the umbrella; the specific key, when present, wins.
%% A caller setting `timeout => infinity` gets a silent server or a
%% patient client — the specific keys exist to split that back apart.

-spec umbrella(map(), handshake_timeout | idle_timeout | connect_timeout) ->
    pos_integer() | infinity.
umbrella(Opts, Key) ->
    case Opts of
        #{Key := Specific} ->
            Specific;
        #{} ->
            maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)
    end.

%%--------------------------------------------------------------------
%% The rest of the shared defaults
%%--------------------------------------------------------------------

-doc "The transport axis: `framed` (default), `buffered` or `http`.".
-spec transport(map()) -> thrift_runtime_socket:transport().
transport(Opts) ->
    maps:get(transport, Opts, framed).

-doc """
The resolved protocol module: the named axis value (`binary`, `compact`,
`json`) through `thrift_runtime:protocol_module/1`, or the caller's own
implementation module.
""".
-spec protocol_module(map()) -> {ok, module()} | {error, term()}.
protocol_module(Opts) ->
    thrift_runtime:protocol_module(maps:get(protocol, Opts, binary)).

-doc "The framed-mode guard and HTTP body bound, default 64 MiB.".
-spec max_frame_size(map()) -> pos_integer().
max_frame_size(Opts) ->
    maps:get(max_frame_size, Opts, ?DEFAULT_MAX_FRAME_SIZE).

-doc "The `{active, N}` delivery batch size, default 100.".
-spec active_n(map()) -> pos_integer().
active_n(Opts) ->
    maps:get(active_n, Opts, ?DEFAULT_ACTIVE_N).

-doc "The client-side HTTP path, default `<<\"/\">>`.".
-spec http_path(map()) -> binary().
http_path(Opts) ->
    maps:get(http_path, Opts, ?DEFAULT_HTTP_PATH).

-doc "The live-connection cap, default 1024.".
-spec max_connections(map()) -> pos_integer().
max_connections(Opts) ->
    maps:get(max_connections, Opts, ?DEFAULT_MAX_CONNECTIONS).

-doc """
The `on_event` observability handler, default `undefined`; see
`thrift_runtime_events`. A malformed value fails the start, not the first
emit: the returned reason is `{on_event, Value}`.
""".
-spec on_event(map()) -> {ok, thrift_runtime_events:handler()} | {error, {on_event, term()}}.
on_event(Opts) ->
    case maps:get(on_event, Opts, undefined) of
        undefined ->
            {ok, undefined};
        Fun when is_function(Fun, 1) ->
            {ok, Fun};
        {Module, Function, Args} when is_atom(Module), is_atom(Function), is_list(Args) ->
            {ok, {Module, Function, Args}};
        Bad ->
            {error, {on_event, Bad}}
    end.
