# RPC and operations reference

The complete contract for calling and serving: client, server and
reconnecting options with their exact validation errors, lifecycle and
graceful drain, transports and HTTP, pooling, reconnection,
observability, multiplexing and TLS. The [root README](../README.md)
covers the normal path (one typed client/server round trip); this
document owns the rest. Old call shapes are mapped in
[Public API migration](public-api-migration.md).

## Results on both ends of the wire

Calls answer `ok` for a void or oneway result, `{ok, Value}` for a
non-void reply and `{error, {exception, ...}}` for a declared
exception — generated, dynamic (`thrift_runtime_client`) and
reconnecting callers alike. The handler side mirrors the shapes: a
void or oneway callback answers the bare atom `ok`, a non-void one
`{ok, Value}` or the exception tuple; the old void shape `{ok,
undefined}` is an unsupported result. An unsupported handler result
answers the call with `TApplicationException` `INTERNAL_ERROR` and
emits one `handler_error` event (oneway emits the event only), and
never changes the wire payload — a void function has no success field,
so `ok` is the existing empty result struct.

## Endpoint options

`start_link` options are a map at creation time, not app env. Every
endpoint validates its options map at start, before anything is
registered, bound or connected: an unknown key answers `{error,
{unknown_option, Key}}`, a missing required key `{error,
{missing_option, Key}}`, a bad value `{error, {bad_option, {Key, Value,
Allowed}}}`, a non-map argument `{error, {bad_option, {options, Value,
[map]}}}` — the `protocol` axis keeps its own `{error,
{bad_protocol, Value}}`, unwrapped. Unknown keys are reported in
sorted order; missing required keys in the endpoint's canonical order.
Nothing starts on the error path: an invalid server option leaves no
listener behind, an invalid client option never dials.

### Client

Required: `host`, `port`, `service`.

| key | values | default |
|---|---|---|
| `transport` | `framed \| buffered \| http` | `framed` |
| `protocol` | `binary \| compact \| json \| module()` | `binary` |
| `timeout` | pos integer or `infinity` | `5000` ms |
| `connect_timeout` | pos integer or `infinity` | the `timeout` umbrella |
| `max_frame_size` | pos integer | 64 MiB |
| `active_n` | pos integer | `100` |
| `max_queue_depth` | pos integer or `infinity` | `infinity` |
| `http_path` | binary | `<<"/">>` |
| `ssl_opts` | list or `undefined` | `undefined` |
| `multiplex` | binary or `undefined` | `undefined` |
| `on_event` | `undefined \| fun/1 \| {M, F, A}` | `undefined` |

`timeout` covers the connect and the TLS handshake; per-call timeouts
ride the call itself. `max_queue_depth` bounds how many calls may wait
while another is on the wire — `0` is rejected (`{error, {bad_option,
{max_queue_depth, 0, [pos_integer, infinity]}}}`: it used to mean
"reject every call", which is a configuration error now; overflow
already answers `{error, queue_full}` at any finite depth).

The generated `<prefix>_<svc>_client` modules take the same options map
with `service` already inserted; they also export an unlinked
`start/1` beside `start_link/1` (the pool-worker entry; see Pooling
below).

### Server

Required: `port`, plus exactly one service mode — `service` (the
module implementing the `thrift_runtime_service` behaviour; for
generated services, `<prefix>_<svc>_server`) plus `handler`, or a
`services` map of binary names to `#{handler := _, service := _}`
entries, both module-valued. Passing both modes answers `{error,
{bad_option, {services, Value, [single_service_or_multiplex]}}}`; a
malformed nested entry answers `{error, {bad_option, {services, Value,
[service_map]}}}`.

| key | values | default |
|---|---|---|
| `transport` | `framed \| buffered \| http` | `framed` |
| `protocol` | `binary \| compact \| json \| module()` | `binary` |
| `timeout` | pos integer or `infinity` | `5000` ms |
| `handshake_timeout` | pos integer or `infinity` | the `timeout` umbrella |
| `idle_timeout` | pos integer or `infinity` | the `timeout` umbrella |
| `max_frame_size` | pos integer | 64 MiB |
| `max_connections` | pos integer | `1024` |
| `active_n` | pos integer | `100` |
| `backlog` | pos integer | `1024` |
| `ssl_opts` | list or `undefined` | `undefined` |
| `on_event` | `undefined \| fun/1 \| {M, F, A}` | `undefined` |
| `record_api` | boolean | from the generated server |
| `types` | module or `undefined` | from the generated server |
| `name` | atom | `thrift_runtime_server` |

`timeout` is the umbrella (TLS handshake and inter-message silence);
`handshake_timeout` / `idle_timeout` name each meaning specifically
and override it. The direct `thrift_runtime_acceptor` accepts the same
set minus `name` — a `name` key there answers `{error,
{unknown_option, name}}`. Module-valued options require an atom only;
validation does not load or invoke the module, so generated-later and
remote-node modules stay valid configuration.

Generated typed servers inject their `service` before validation —
**only when the caller did not supply `services`**; `record_api` and
`types` are always injected — so their accepted keys are exactly the
runtime's, and the axis errors surface directly instead of as
unknown-key errors for the injection. A generated server passed
`services` hosts in multiplexed mode as-is.

### Reconnecting client

`thrift_runtime_reconnecting_client` takes the whole client contract
(`max_queue_depth` included) plus:

| key | values | default |
|---|---|---|
| `reconnect_min` | pos integer | `500` ms |
| `reconnect_max` | pos integer | `30000` ms |

When both bounds are explicitly provided, `reconnect_min =<
reconnect_max` is validated at start: a reversed pair answers
`{error, {bad_option, {reconnect_max, Max, [gte_reconnect_min]}}}`.

### Codec facade options

The codec `encode/3` / `decode/3` options maps are validated through
the same vocabulary; their exact key sets and error terms are owned by
[Advanced codecs](advanced-codecs.md#the-generated-facade).

## Lifecycle and graceful drain

A plain `stop/1` takes the server down at once. `stop/2` with
`#{drain => Timeout}` shuts down gracefully first: the listen socket
closes, idle connections are dropped, and connections with an
in-flight request answer it before exiting. The call returns when the
last connection is gone — or at the deadline (`infinity` allowed; the
deadline never fails the call, whatever it leaves over is then swept
by the normal supervised stop, which lets a still-running exchange
finish and fails the calls only of connections that cannot finish).
Invalid stop options answer the same strict error terms and change
nothing — the server keeps running:

```erlang
ok = ping_api_ping_server:stop(Server, #{drain => 10_000}).
```

`stop/2` accepts a map containing only `drain` (a non-negative
integer or `infinity`); `#{}` retains plain-stop behavior.

## Transports

The `transport` axis is independent of the protocol axis —
`buffered`, `framed` (the default) and `http` all carry binary,
compact and JSON alike. Sockets run in `{active, N}` delivery mode, so
a dead peer is noticed even on an idle connection.

### The HTTP transport

`transport => http` turns every Thrift exchange into one HTTP/1.1
request-response pair: the client POSTs the encoded message to
`http_path` (default `"/"`), the server answers with the reply in the
response body, and the connection stays open for the next call
(keep-alive). The protocol axis is untouched — binary, compact and
json all ride in the body:

```erlang
{ok, Server} = ping_api_ping_server:start_link(#{
    port => 9090, handler => ping_handler, transport => http
}),
{ok, Client} = ping_api_ping_client:start_link(#{
    host => "127.0.0.1", port => 9090, transport => http, http_path => <<"/thrift">>
}),
```

HTTP is request/response even where Thrift is not: a oneway gets an
(empty) response, and the client consumes it before the next call.
`max_frame_size` bounds the body on both ends; an unparseable request
is answered 400 (405 for a non-POST method) before the connection
closes, and a well-formed request carrying a bad Thrift payload gets
400 while the connection continues. Interop is covered in the golden
suite: the official HTTP client (`thrift_http_transport` over `httpc`)
runs the full ThriftTest battery against our HTTP server.

## Pooling

`thrift_runtime_client` is deliberately connection-per-process with no
automatic reconnection: any failure fails the outstanding calls and
stops the process, so a pool sees the death immediately and replaces
the worker. The unlinked `thrift_runtime_client:start/1` (plus
`service => ping_api_ping_server`) is the pool-worker entry; generated
clients export the same unlinked `start/1` beside `start_link/1` with
`service` already inserted:

```erlang
ClientOpts = #{host => "127.0.0.1", port => 9090, service => ping_api_ping_server},

%% poolboy
{ok, Pool} = poolboy:start_link(#{
    worker_module => {thrift_runtime_client, start, [ClientOpts]},
    size => 10, max_overflow => 5
}),
Reply = poolboy:transaction(Pool, fun(C) -> thrift_runtime_client:call(C, <<"poke">>, [], 5000) end).

%% pooler
%% in config: {[{pools, [[{name, ping}, {max_count, 10}, {init_count, 2},
%%                        {start_mfa, {thrift_runtime_client, start, [ClientOpts]}}]]}]}
Client = pooler:take_member(ping),
try thrift_runtime_client:call(Client, <<"poke">>, [], 5000)
after pooler:return_member(ping, Client, ok) end.
```

`stop/1` answers outstanding calls with `{error, closed}` instead of
leaving them hanging. Calls are serialized per connection; concurrent
callers queue in order. Each worker also carries counters for pool
health checks: `thrift_runtime_client:get_stats/1` answers `#{calls_ok,
calls_failed}` (every `{error, _}` answer counts failed, a declared
exception included) and `get_and_reset_stats/1` zeroes them.

## Reconnecting client

When the caller is not a pool but a long-lived consumer,
`thrift_runtime_reconnecting_client` wraps the simple client with
automatic reconnection and statistics. The wrapped client keeps its
no-reconnect contract; the wrapper observes its death, retries with
exponential backoff (`reconnect_min` → doubled → `reconnect_max`,
defaults 500 ms / 30 s) and fails calls that arrive in between with
`{error, disconnected}`. A server that is down does not fail the
start — the wrapper keeps trying, like the reference Apache
`thrift_reconnecting_client`:

```erlang
{ok, Client} = thrift_runtime_reconnecting_client:start_link(
    #{host => "localhost", port => 9090, service => ping_api_ping_server,
      reconnect_min => 500, reconnect_max => 30000}
),
ok = thrift_runtime_reconnecting_client:call(Client, <<"poke">>, [], 5000),

%% the pool health-check surface
#{connected := true, calls_ok := 3, calls_failed := 0,
  connects := 1, connect_failures := 0} =
    thrift_runtime_reconnecting_client:get_stats(Client),
thrift_runtime_reconnecting_client:get_and_reset_stats(Client).
```

Server-reported exceptions are protocol replies: they come back
unchanged and never reconnect. Every failed retry is logged at warning
level (`domain => [thrift]`).

## Observability

Clients, reconnecting wrappers and servers accept `on_event`: an
observability callback — `undefined` (the default), a fun of arity 1,
or `{Module, Function, Args}` (the event is appended to `Args`, so the
handler can carry its own context — a pool id, an ETS table). An
invalid value answers `{error, {bad_option, {on_event, Value,
[undefined, 'fun', mfa]}}}` at start. Dispatch is synchronous in the
emitting process and crash-isolated: a handler exception is discarded
and never reaches the caller, the client or the server. Handlers must
still be fast — they run on the call path.

```erlang
%% a client: one event per caller-facing answer, a plain fun
{ok, Client} = thrift_runtime_client:start_link(#{
    host => "localhost", port => 9090, service => ping_api_ping_server,
    on_event => fun(#{type := Type, function := Fun, duration_us := Us}) ->
                        logger:info("thrift ~ts ~ts: ~p us", [Type, Fun, Us])
                end}),

%% a server: {M, F, Args} carries context, the event rides last
%% (the call becomes my_metrics:record(<<"Ping">>, Event))
{ok, Server} = thrift_runtime_server:start_link(#{
    port => 9090, handler => ping_handler, service => ping_api_ping_server,
    on_event => {my_metrics, record, [<<"Ping">>]}}).
```

The catalogue — one map per event, `type` first (the full contract
lives in the `thrift_runtime_events` moduledoc):

- **client** — exactly one event per caller-facing answer, so counting
  them reproduces `get_stats/1`: `#{type => call_ok, function => Fun,
  duration_us => N, oneway => boolean()}` (the span covers the queue
  wait plus the wire round-trip — the same one the per-call timeout
  arms over) and `#{type => call_error, function => Fun, reason => R,
  duration_us => N, oneway => boolean()}`, where `reason` is exactly
  what the caller receives (`closed`, a timeout, a protocol error, a
  declared exception tuple, ...);
- **reconnecting wrapper** — the connection axis only (call events
  come from the wrapped client, which gets the same handler):
  `#{type => connected}`, `#{type => connect_failed, reason => R,
  retry_in_ms => N}`, `#{type => disconnected, reason => R,
  retry_in_ms => N}`;
- **server connection** — `#{type => connection_open, peer => Peer |
  undefined}`, `#{type => connection_closed, reason => R}` and
  `#{type => handler_error, function => Fun, reason => R}` — a handler
  crash or an unsupported handler result; declared exceptions and
  protocol errors are answers, not handler errors.

The generated client and server take `on_event` unchanged — their
`start_link/1` accepts the same options map as the runtime modules
(the generated client also has the unlinked `start/1`).

## Multiplexed services

Several services can share one port. The server hosts them by name;
clients opt in with `multiplex`, which prefixes every outgoing message
name with `<<"Service:function">>` (the Apache multiplexed protocol
convention — replies keep the plain function name, so nothing else
changes):

```erlang
%% server: host two services on one port
{ok, Server} = thrift_runtime_server:start_link(#{
    port => 9090,
    services => #{
        <<"Widgets">> => #{handler => WidgetsHandler, service => shop_widgets_server},
        <<"Users">>   => #{handler => UsersHandler,   service => shop_users_server}
    }
}),

%% clients pick their service; function names stay plain
{ok, Widgets} = thrift_runtime_client:start_link(
    #{host => "localhost", port => 9090, service => shop_widgets_server, multiplex => <<"Widgets">>}),
{ok, Users} = thrift_runtime_client:start_link(
    #{host => "localhost", port => 9090, service => shop_users_server, multiplex => <<"Users">>}),
```

A generated server/client pair takes the same options — pass
`services` to the generated server module or `multiplex` to the
generated client, everything else is unchanged. The dispatch is strict
in multiplexed mode: a name whose prefix is not a hosted service (or a
plain name) is refused with the `UNKNOWN_METHOD` application
exception, and the connection stays usable. A single-service server
stays liberal: it answers plain names and keeps answering names that
carry any `Service:` prefix, so a multiplexed client pointed at a
non-multiplexed service still finds its functions. The golden suite
covers the wire compatibility both ways: the official Apache
multiplexed client (`thrift_client_util:new_multiplexed`) runs against
our multiplexed server.

## TLS

Add `ssl_opts` to the server or the client and the connection becomes
TLS; without it everything stays plain TCP. The same `ssl_opts` list
is passed straight to `ssl:listen`/`ssl:connect`, so every standard
option (`certs_keys`, `verify`, `cacerts`, ...) applies:

```erlang
%% server: present a certificate
{ok, Server} = thrift_runtime_server:start_link(#{
    port => 9090, handler => ping_handler, service => ping_api_ping_server,
    ssl_opts => [{certs_keys, [#{certfile => "cert.pem", keyfile => "key.pem"}]}]
}),

%% client: verify the server
{ok, Client} = thrift_runtime_client:start_link(#{
    host => "localhost", port => 9090, service => ping_api_ping_server,
    ssl_opts => [{verify, verify_peer}, {cacerts, CaDer},
                 {server_name_indication, "localhost"}]}
)
```

The TLS handshake runs where the connection is established: on the
server between the transport accept and the handover to the connection
process (capped by the `timeout` option, so a silent peer cannot pin
the acceptor), on the client inside `start_link` (its connect
timeout). A failed handshake closes the connection: the client's
`start_link` answers `{error, Reason}`, the server logs and keeps
accepting. After the handshake nothing changes — framing, protocols,
representations and the `{active, N}` I/O are transport-agnostic.
Serve mutual TLS by adding client-certificate verification to the
server's `ssl_opts` (`{verify, verify_peer}, {fail_if_no_peer_cert,
true}`); the client presents `certs_keys` the same way.
