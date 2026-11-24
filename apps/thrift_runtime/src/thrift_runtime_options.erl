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
The runtime's option surface in one place: the defaults and the strict
creation-time validators.

Every endpoint parses its options at creation time through one
normalizer and consumes the fully normalized map — no endpoint re-reads
or re-defaults caller options afterwards. This module keeps the
defaults from drifting apart across `thrift_runtime_acceptor`,
`thrift_runtime_connection`, `thrift_runtime_client` and
`thrift_runtime_reconnecting_client`, and keeps `timeout` from meaning
three different things: it is the umbrella standing in for every more
specific timeout the caller does not name —

- `handshake_timeout` — server only: the TLS handshake slice between
  the transport accept and the handover;
- `idle_timeout` — server only: the maximum silence between messages;
- `connect_timeout` — client only: the connect and TLS handshake wait.

A specific key wins over the umbrella, the umbrella wins over the
default.

The codec facade's option maps (`codec_options/2`) live here too: one
validator for the advanced `thrift_runtime` encode/decode options,
strict key sets per direction, so the network and the codec surface
cannot drift apart.

The endpoint option normalizers (`client_options/1`,
`reconnecting_options/1`, `server_options/1`, `acceptor_options/1` and
`stop_options/1`) share one strict creation-time contract: a fixed
allowed-key set per endpoint, deterministic unknown/missing/bad errors,
and a fully normalized map — resolved protocol module, applied umbrella
timeouts, every default — that process initialization consumes instead
of re-reading raw caller maps.
""".

-export([
    codec_options/2,
    client_options/1,
    reconnecting_options/1,
    server_options/1,
    acceptor_options/1,
    stop_options/1
]).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_MAX_FRAME_SIZE, 64 * 1024 * 1024).
-define(DEFAULT_ACTIVE_N, 100).
-define(DEFAULT_MAX_CONNECTIONS, 1024).
-define(DEFAULT_HTTP_PATH, <<"/">>).
-define(DEFAULT_BACKLOG, 1024).
-define(DEFAULT_RECONNECT_MIN, 500).
-define(DEFAULT_RECONNECT_MAX, 30000).
-define(DEFAULT_SERVER_NAME, thrift_runtime_server).

%%--------------------------------------------------------------------
%% Codec facade options
%%--------------------------------------------------------------------

%% The codec facade validates its options up front instead of failing
%% halfway through a wire operation: the key set is fixed per direction,
%% every entry is validated against its axis, and the normalized map
%% carries the caller's values on top of the defaults. Unknown keys and
%% bad values are caller typos, not data conditions — they answer tagged
%% errors without touching the descriptor or the binary.

-doc """
Normalizes the codec facade's option map for one direction.

Encode accepts exactly `protocol` and `strict` (default `binary`,
`false`); decode accepts exactly `protocol` and `repr`, with `repr`
required — the advanced facade has no schema module from which to infer
a default representation. The `protocol` value resolves through
`thrift_runtime:protocol_module/1` and the normalized map carries the
resolved module, so the facade dispatches on it directly without a
second resolution; `repr` validates through
`thrift_runtime:repr_supported/1`, so `bad_protocol`, `bad_repr` and
`unsupported_repr` keep their existing forms. A non-map argument is a
bad options value, not a protocol: `{error, {bad_option, {options,
Value, [map]}}}`.
""".
-spec codec_options(term(), encode | decode) -> {ok, map()} | {error, term()}.
codec_options(Options, Direction) when is_map(Options) ->
    case codec_unknown(Options, Direction) of
        ok ->
            codec_values(Options, Direction);
        {error, _} = Error ->
            Error
    end;
codec_options(Value, _Direction) ->
    bad_options(Value).

%% Exactly these keys exist per direction; anything else is a typo the
%% caller must see, not an entry to ignore.

-spec codec_allowed(encode | decode) -> [atom()].
codec_allowed(encode) ->
    [protocol, strict];
codec_allowed(decode) ->
    [protocol, repr].

-spec codec_unknown(map(), encode | decode) -> ok | {error, {unknown_option, atom()}}.
codec_unknown(Options, Direction) ->
    Allowed = codec_allowed(Direction),
    case [Key || Key <- maps:keys(Options), not lists:member(Key, Allowed)] of
        [] ->
            ok;
        [Key | _] ->
            {error, {unknown_option, Key}}
    end.

%% Defaults first, then per-key validation; a bad value answers before
%% the codec could fail on it mid-operation.

-spec codec_values(map(), encode | decode) -> {ok, map()} | {error, term()}.
codec_values(Options, encode) ->
    with_strict(Options, #{protocol => binary, strict => false});
codec_values(Options, decode) ->
    with_repr(Options, #{protocol => binary}).

-spec with_strict(map(), map()) -> {ok, map()} | {error, term()}.
with_strict(Options, Normalized) ->
    case maps:get(strict, Options, false) of
        Strict when is_boolean(Strict) ->
            with_protocol(Options, Normalized#{strict => Strict});
        Bad ->
            {error, {bad_option, {strict, Bad, [true, false]}}}
    end.

-spec with_repr(map(), map()) -> {ok, map()} | {error, term()}.
with_repr(Options, Normalized) ->
    case Options of
        #{repr := Repr} ->
            case thrift_runtime:repr_supported(Repr) of
                ok ->
                    with_protocol(Options, Normalized#{repr => Repr});
                {error, _} = Error ->
                    Error
            end;
        #{} ->
            {error, {missing_option, repr}}
    end.

-spec with_protocol(map(), map()) -> {ok, map()} | {error, term()}.
with_protocol(Options, Normalized) ->
    Protocol = maps:get(protocol, Options, binary),
    case thrift_runtime:protocol_module(Protocol) of
        {ok, Mod} ->
            {ok, Normalized#{protocol => Mod}};
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Endpoint option normalizers
%%--------------------------------------------------------------------

%% Every endpoint answers the same error vocabulary:
%%
%% - `{error, {bad_option, {options, Value, [map]}}}' — a non-map argument;
%% - `{error, {unknown_option, Key}}' — a key outside the endpoint's set,
%%   the first one in sorted order when several are unknown;
%% - `{error, {missing_option, Key}}' — a required key absent, in the
%%   endpoint's canonical order;
%% - `{error, {bad_option, {Key, Value, Allowed}}}' — a value outside its
%%   family, or the protocol axis' own `bad_protocol' error.
%%
%% The pipeline runs the same stages for every endpoint: sorted unknown
%% keys first, then the endpoint's required/mode prelude, then a
%% fixed-order value walk, so several simultaneous errors always report
%% the same one first. Defaults merge only after the whole map
%% validates; a protocol value resolves once into its module and
%% module-valued options are atoms only — never loaded or invoked here,
%% so generated-later and remote-node modules stay valid configuration.

-doc """
Normalizes the plain client options.

`host`, `port` and `service` are required; accepted keys are the client
option type's fields. The normalized map carries the resolved protocol
module, `connect_timeout` resolved against the `timeout` umbrella, and
every default (`framed`, 5000 ms, 64 MiB, `active_n` 100, unbounded
queue, `<<"/">>`, no TLS/multiplex/handler).
""".
-spec client_options(term()) -> {ok, map()} | {error, term()}.
client_options(Options) ->
    endpoint_normalize(Options, fun client_prelude/1, client_order(), client_validators(), client).

-doc """
Normalizes the reconnecting client options.

The client contract plus `reconnect_min` and `reconnect_max` (default
500/30000 ms); every client key, `max_queue_depth` included, passes
through. An explicitly provided pair with `reconnect_max` below
`reconnect_min` answers `{error, {bad_option, {reconnect_max, Max,
[gte_reconnect_min]}}}`.
""".
-spec reconnecting_options(term()) -> {ok, map()} | {error, term()}.
reconnecting_options(Options) ->
    case reconnect_bounds(Options) of
        ok ->
            reconnecting_normalize(Options);
        Error ->
            Error
    end.

-doc """
Normalizes the server options.

`port` is required, plus exactly one service mode: `service` and
`handler`, or a `services` map of binary names to `#{handler := _,
service := _}` entries. Everything the acceptor accepts, plus `name`
(default `thrift_runtime_server`). Mixing a single-mode key with
`services` answers `{error, {bad_option, {services, Value,
[single_service_or_multiplex]}}}`; a malformed nested shape answers
`bad_option` for the top-level `services` value.
""".
-spec server_options(term()) -> {ok, map()} | {error, term()}.
server_options(Options) ->
    endpoint_normalize(Options, fun server_prelude/1, server_order(), server_validators(), server).

-doc """
Normalizes the direct acceptor options: the server contract without
`name`, which only `thrift_runtime_server` accepts.
""".
-spec acceptor_options(term()) -> {ok, map()} | {error, term()}.
acceptor_options(Options) ->
    endpoint_normalize(Options, fun server_prelude/1, acceptor_order(), server_validators(), acceptor).

-doc """
Normalizes the graceful-stop options: a map containing at most `drain`,
a non-negative integer or `infinity`. `#{}` normalizes to plain stop.
""".
-spec stop_options(term()) -> {ok, map()} | {error, term()}.
stop_options(Options) when is_map(Options) ->
    stop_unknown(endpoint_unknown(Options, [drain]), Options);
stop_options(Value) ->
    bad_options(Value).

%% The shared pipeline: shape (the function clauses above), sorted
%% unknown keys, the endpoint prelude, then the fixed-order value walk
%% whose `{ok, _}' result carries the protocol-resolved values into the
%% merge. Every stage returns `ok' or `{error, _}', and dispatches on
%% that through function clauses instead of nested cases.

-type endpoint() :: client | reconnecting | server | acceptor.
-type prelude() :: fun((map()) -> ok | {error, term()}).

-spec bad_options(term()) -> {error, term()}.
bad_options(Value) ->
    {error, {bad_option, {options, Value, [map]}}}.

-spec endpoint_normalize(term(), prelude(), [atom()], validators(), endpoint()) ->
    {ok, map()} | {error, term()}.
endpoint_normalize(Options, Prelude, Order, Validators, Endpoint) when is_map(Options) ->
    case endpoint_unknown(Options, Order) of
        ok ->
            endpoint_required(Prelude(Options), Options, Order, Validators, Endpoint);
        Error ->
            Error
    end;
endpoint_normalize(Value, _Prelude, _Order, _Validators, _Endpoint) ->
    bad_options(Value).

-spec endpoint_required(ok | {error, term()}, map(), [atom()], validators(), endpoint()) ->
    {ok, map()} | {error, term()}.
endpoint_required(ok, Options, Order, Validators, Endpoint) ->
    endpoint_validated(validated(Options, Order, Validators), Options, Endpoint);
endpoint_required(Error, _Options, _Order, _Validators, _Endpoint) ->
    Error.

-spec endpoint_validated({ok, map()} | {error, term()}, map(), endpoint()) ->
    {ok, map()} | {error, term()}.
endpoint_validated({ok, Resolved}, Options, Endpoint) ->
    {ok, merge_endpoint(Endpoint, Options, Resolved)};
endpoint_validated(Error, _Options, _Endpoint) ->
    Error.

-spec endpoint_unknown(map(), [atom()]) -> ok | {error, {unknown_option, atom()}}.
endpoint_unknown(Options, Allowed) ->
    case lists:sort([Key || Key <- maps:keys(Options), not lists:member(Key, Allowed)]) of
        [] ->
            ok;
        [Key | _] ->
            {error, {unknown_option, Key}}
    end.

-spec required(map(), [atom()]) -> ok | {error, {missing_option, atom()}}.
required(Options, [Key | Rest]) ->
    case maps:is_key(Key, Options) of
        true ->
            required(Options, Rest);
        false ->
            {error, {missing_option, Key}}
    end;
required(_Options, []) ->
    ok.

%% The value walk: every allowed key in its fixed order; a key with no
%% validator entry (only `host') passes through unchecked, everything
%% else answers `ok', `{ok, Transformed}' for the protocol resolution,
%% or the first `{error, _}' in key order.

-spec validated(map(), [atom()], validators()) -> {ok, map()} | {error, term()}.
validated(Options, Order, Validators) ->
    validated(Options, Order, Validators, #{}).

-spec validated(map(), [atom()], validators(), map()) -> {ok, map()} | {error, term()}.
validated(Options, [Key | Rest], Validators, Resolved) ->
    case maps:find(Key, Options) of
        error ->
            validated(Options, Rest, Validators, Resolved);
        {ok, Value} ->
            endpoint_value(maps:find(Key, Validators), Key, Value, Options, Rest, Validators, Resolved)
    end;
validated(_Options, [], _Validators, Resolved) ->
    {ok, Resolved}.

-spec endpoint_value(
    {ok, validator()} | error, atom(), term(), map(), [atom()], validators(), map()
) -> {ok, map()} | {error, term()}.
endpoint_value({ok, Validator}, Key, Value, Options, Rest, Validators, Resolved) ->
    case Validator(Value) of
        ok ->
            validated(Options, Rest, Validators, Resolved);
        {ok, Transformed} ->
            validated(Options, Rest, Validators, Resolved#{Key => Transformed});
        {error, _} = Error ->
            Error
    end;
endpoint_value(error, _Key, _Value, Options, Rest, Validators, Resolved) ->
    validated(Options, Rest, Validators, Resolved).

%% Endpoint key lists: the walk order doubles as the allowed set, so a
%% key is validated exactly once, in the same order for every caller.

-spec client_order() -> [atom()].
client_order() ->
    [
        host,
        port,
        service,
        transport,
        protocol,
        timeout,
        connect_timeout,
        max_frame_size,
        active_n,
        max_queue_depth,
        http_path,
        ssl_opts,
        multiplex,
        on_event
    ].

-spec reconnecting_order() -> [atom()].
reconnecting_order() ->
    client_order() ++ [reconnect_min, reconnect_max].

%% The direct acceptor rejects `name' (only `thrift_runtime_server'
%% accepts it); every other endpoint's walk order is its allowed set.

-spec acceptor_order() -> [atom()].
acceptor_order() ->
    lists:delete(name, server_order()).

-spec server_order() -> [atom()].
server_order() ->
    [
        port,
        service,
        handler,
        services,
        transport,
        protocol,
        timeout,
        handshake_timeout,
        idle_timeout,
        max_frame_size,
        max_connections,
        active_n,
        backlog,
        ssl_opts,
        on_event,
        record_api,
        types,
        name
    ].

%% The value families, one named predicate each; `validator/3' closes
%% the key and its allowed family over a predicate.

-type validator() :: fun((term()) -> ok | {ok, term()} | {error, term()}).
-type validators() :: #{atom() => validator()}.

-spec validator(atom(), [term()], fun((term()) -> boolean())) -> validator().
validator(Key, Allowed, Pred) ->
    fun(Value) -> valid(Key, Value, Allowed, Pred) end.

-spec valid(atom(), term(), [term()], fun((term()) -> boolean())) -> ok | {error, term()}.
valid(Key, Value, Allowed, Pred) ->
    case Pred(Value) of
        true ->
            ok;
        false ->
            {error, {bad_option, {Key, Value, Allowed}}}
    end.

-spec is_transport(term()) -> boolean().
is_transport(Value) ->
    Value =:= framed orelse Value =:= buffered orelse Value =:= http.

-spec is_port_number(term()) -> boolean().
is_port_number(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 65535.

-spec is_pos_integer(term()) -> boolean().
is_pos_integer(Value) ->
    is_integer(Value) andalso Value > 0.

-spec is_pos_infinity(term()) -> boolean().
is_pos_infinity(infinity) ->
    true;
is_pos_infinity(Value) ->
    is_integer(Value) andalso Value > 0.

-spec is_undefined_binary(term()) -> boolean().
is_undefined_binary(undefined) ->
    true;
is_undefined_binary(Value) ->
    is_binary(Value).

-spec is_undefined_list(term()) -> boolean().
is_undefined_list(undefined) ->
    true;
is_undefined_list(Value) ->
    is_list(Value).

%% The observability handler: undefined, a fun of arity one or {M, F, A}.

-spec on_event_value(term()) -> ok | {error, term()}.
on_event_value(undefined) ->
    ok;
on_event_value(Fun) when is_function(Fun, 1) ->
    ok;
on_event_value({Module, Function, Args}) when
    is_atom(Module), is_atom(Function), is_list(Args)
->
    ok;
on_event_value(Value) ->
    {error, {bad_option, {on_event, Value, [undefined, 'fun', mfa]}}}.

%% The protocol axis validates and resolves in one step: the walk's
%% resolved map carries the module, and the axis' own `bad_protocol'
%% errors pass through unchanged.

-spec client_validators() -> validators().
client_validators() ->
    #{
        port => validator(port, [port], fun is_port_number/1),
        service => validator(service, [module], fun is_atom/1),
        transport => validator(transport, [framed, buffered, http], fun is_transport/1),
        protocol => fun thrift_runtime:protocol_module/1,
        timeout => validator(timeout, [pos_integer, infinity], fun is_pos_infinity/1),
        connect_timeout => validator(connect_timeout, [pos_integer, infinity], fun is_pos_infinity/1),
        max_frame_size => validator(max_frame_size, [pos_integer], fun is_pos_integer/1),
        active_n => validator(active_n, [pos_integer], fun is_pos_integer/1),
        max_queue_depth => validator(max_queue_depth, [pos_integer, infinity], fun is_pos_infinity/1),
        http_path => validator(http_path, [binary], fun is_binary/1),
        ssl_opts => validator(ssl_opts, [undefined, list], fun is_undefined_list/1),
        multiplex => validator(multiplex, [undefined, binary], fun is_undefined_binary/1),
        on_event => fun on_event_value/1
    }.

-spec reconnecting_validators() -> validators().
reconnecting_validators() ->
    (client_validators())#{
        reconnect_min => validator(reconnect_min, [pos_integer], fun is_pos_integer/1),
        reconnect_max => validator(reconnect_max, [pos_integer], fun is_pos_integer/1)
    }.

-spec server_validators() -> validators().
server_validators() ->
    #{
        port => validator(port, [port], fun is_port_number/1),
        service => validator(service, [module], fun is_atom/1),
        handler => validator(handler, [module], fun is_atom/1),
        transport => validator(transport, [framed, buffered, http], fun is_transport/1),
        protocol => fun thrift_runtime:protocol_module/1,
        timeout => validator(timeout, [pos_integer, infinity], fun is_pos_infinity/1),
        handshake_timeout => validator(handshake_timeout, [pos_integer, infinity], fun is_pos_infinity/1),
        idle_timeout => validator(idle_timeout, [pos_integer, infinity], fun is_pos_infinity/1),
        max_frame_size => validator(max_frame_size, [pos_integer], fun is_pos_integer/1),
        max_connections => validator(max_connections, [pos_integer], fun is_pos_integer/1),
        active_n => validator(active_n, [pos_integer], fun is_pos_integer/1),
        backlog => validator(backlog, [pos_integer], fun is_pos_integer/1),
        ssl_opts => validator(ssl_opts, [undefined, list], fun is_undefined_list/1),
        on_event => fun on_event_value/1,
        record_api => validator(record_api, [boolean], fun is_boolean/1),
        types => validator(types, [undefined, module], fun is_atom_or_undefined/1),
        name => validator(name, [atom], fun is_atom/1)
    }.

-spec is_atom_or_undefined(term()) -> boolean().
is_atom_or_undefined(undefined) ->
    true;
is_atom_or_undefined(Value) ->
    is_atom(Value).

%% The client prelude names its required keys in their canonical order;
%% the server and the direct acceptor share the same prelude: `port' is
%% required, then exactly one service mode is pinned before the value
%% walk — the single pair, or the multiplex map.

-spec client_prelude(map()) -> ok | {error, term()}.
client_prelude(Options) ->
    required(Options, [host, port, service]).

-spec server_prelude(map()) -> ok | {error, term()}.
server_prelude(Options) ->
    server_mode_checked(required(Options, [port]), Options).

-spec server_mode_checked(ok | {error, term()}, map()) -> ok | {error, term()}.
server_mode_checked(ok, Options) ->
    server_mode(Options);
server_mode_checked(Error, _Options) ->
    Error.

-spec server_mode(map()) -> ok | {error, term()}.
server_mode(Options) ->
    case {maps:is_key(services, Options), maps:is_key(service, Options) orelse maps:is_key(handler, Options)} of
        {true, true} ->
            {error, {bad_option, {services, maps:get(services, Options), [single_service_or_multiplex]}}};
        {true, false} ->
            valid_services(maps:get(services, Options));
        {false, true} ->
            required(Options, [service, handler]);
        {false, false} ->
            {error, {missing_option, service}}
    end.

%% Every services entry is exactly `handler' and `service', both atoms,
%% under a binary name; any deviation reports the top-level value.

-spec valid_services(term()) -> ok | {error, term()}.
valid_services(Services) ->
    case is_map(Services) andalso maps:fold(fun valid_service/3, ok, Services) of
        ok ->
            ok;
        _ ->
            services_error(Services)
    end.

-spec services_error(term()) -> {error, term()}.
services_error(Services) ->
    {error, {bad_option, {services, Services, [service_map]}}}.

-spec valid_service(term(), term(), ok | error) -> ok | error.
valid_service(Name, Entry, ok) when is_binary(Name), is_map(Entry) ->
    case
        lists:sort(maps:keys(Entry)) =:= [handler, service] andalso
            is_atom(maps:get(handler, Entry)) andalso is_atom(maps:get(service, Entry))
    of
        true ->
            ok;
        false ->
            error
    end;
valid_service(_Name, _Entry, ok) ->
    error;
valid_service(_Name, _Entry, error) ->
    error.

%% The per-endpoint merge: validated caller values on top of the
%% defaults. Umbrella timeouts resolve here — the specific key wins, the
%% umbrella stays available under its own key.

-spec merge_endpoint(endpoint(), map(), map()) -> map().
merge_endpoint(Endpoint, Options, Resolved) ->
    Timeout = maps:get(timeout, Options, ?DEFAULT_TIMEOUT),
    Shared = Options#{
        transport => maps:get(transport, Options, framed),
        protocol => maps:get(protocol, Resolved, thrift_runtime_binary),
        timeout => Timeout,
        max_frame_size => maps:get(max_frame_size, Options, ?DEFAULT_MAX_FRAME_SIZE),
        active_n => maps:get(active_n, Options, ?DEFAULT_ACTIVE_N),
        ssl_opts => maps:get(ssl_opts, Options, undefined),
        on_event => maps:get(on_event, Options, undefined)
    },
    lists:foldl(
        fun({Key, Default}, Acc) ->
            Acc#{Key => maps:get(Key, Options, endpoint_default(Default, Timeout))}
        end,
        Shared,
        endpoint_extras(Endpoint)
    ).

%% `timeout_umbrella' marks the extras that fall back to the umbrella
%% value instead of a constant default.

-spec endpoint_default(term(), timeout()) -> term().
endpoint_default(timeout_umbrella, Timeout) ->
    Timeout;
endpoint_default(Default, _Timeout) ->
    Default.

-spec endpoint_extras(endpoint()) -> [{atom(), term()}].
endpoint_extras(client) ->
    [
        {connect_timeout, timeout_umbrella},
        {max_queue_depth, infinity},
        {http_path, ?DEFAULT_HTTP_PATH},
        {multiplex, undefined}
    ];
endpoint_extras(reconnecting) ->
    [
        {connect_timeout, timeout_umbrella},
        {max_queue_depth, infinity},
        {http_path, ?DEFAULT_HTTP_PATH},
        {multiplex, undefined},
        {reconnect_min, ?DEFAULT_RECONNECT_MIN},
        {reconnect_max, ?DEFAULT_RECONNECT_MAX}
    ];
endpoint_extras(server) ->
    [
        {handshake_timeout, timeout_umbrella},
        {idle_timeout, timeout_umbrella},
        {max_connections, ?DEFAULT_MAX_CONNECTIONS},
        {backlog, ?DEFAULT_BACKLOG},
        {record_api, false},
        {types, undefined},
        {name, ?DEFAULT_SERVER_NAME}
    ];
endpoint_extras(acceptor) ->
    lists:delete({name, ?DEFAULT_SERVER_NAME}, endpoint_extras(server)).

%% An explicitly provided reconnect pair with the max below the min is
%% a caller typo, not a retry policy; single-sided overrides keep their
%% historical freedom.

-spec reconnecting_normalize(map()) -> {ok, map()} | {error, term()}.
reconnecting_normalize(Options) ->
    endpoint_normalize(
        Options,
        fun client_prelude/1,
        reconnecting_order(),
        reconnecting_validators(),
        reconnecting
    ).

-spec reconnect_bounds(term()) -> ok | {error, term()}.
reconnect_bounds(Options) when is_map(Options) ->
    case {maps:get(reconnect_min, Options, undefined), maps:get(reconnect_max, Options, undefined)} of
        {Min, Max} when is_integer(Min), is_integer(Max), Max < Min ->
            {error, {bad_option, {reconnect_max, Max, [gte_reconnect_min]}}};
        _ ->
            ok
    end;
reconnect_bounds(_Options) ->
    ok.

-spec stop_unknown(ok | {error, term()}, map()) -> {ok, map()} | {error, term()}.
stop_unknown(ok, Options) ->
    stop_drain(Options);
stop_unknown(Error, _Options) ->
    Error.

-spec stop_drain(map()) -> {ok, map()} | {error, term()}.
stop_drain(#{drain := Drain}) ->
    case is_integer(Drain) andalso Drain >= 0 orelse Drain =:= infinity of
        true ->
            {ok, #{drain => Drain}};
        false ->
            {error, {bad_option, {drain, Drain, [non_neg_integer, infinity]}}}
    end;
stop_drain(#{}) ->
    {ok, #{}}.
