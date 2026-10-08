# thrift-generator

An alternative Apache Thrift generator and runtime library for Erlang.
It takes Thrift IDL and generates Erlang code for types, clients and
servers that is binary-protocol compatible with the stock Apache Thrift
implementation (verified both ways by golden interop tests against the
official 0.25.0 runtime over buffered and framed transports).

## Layout

```
apps/thrift_generator/   IDL parser (leex/yecc), semantics, emitter, CLI
apps/thrift_erl/         runtime: binary & compact protocols, transports, server, client
apps/rebar3_thrift/      rebar3 plugin (the thrift provider)
vendor/apache-thrift-erl official Apache Thrift Erlang runtime (0.25.0),
                         test profile only — the golden interop fixture
```

Generated code depends only on `thrift_erl` (kernel + stdlib).
The generator is never a runtime dependency.

## Build and tests

Requires Erlang/OTP 28+.

```
rebar3 compile
rebar3 eunit        # unit tests + 5 PropEr codec properties
rebar3 ct           # loopback scenarios + golden interop
rebar3 dialyzer
rebar3 xref
rebar3 fmt
./scripts/bench     # manual codec benchmark (not part of the suites)
```

## CLI

```
rebar3 as prod escriptize
_build/prod/bin/thrift_generator generate my_api.thrift -o src
```

This generates `<mod>_types.erl` plus a `<mod>_types.hrl` include (one
pair per IDL file) and three modules per service: `<Svc>_client.erl`,
`<Svc>_server.erl`, `<Svc>_handler.erl`.

## rebar3 plugin

In the consumer project's `rebar.config`:

```erlang
{plugins, [rebar3_thrift]},

{thrift, [
    {files, ["src/my_api.thrift"]},
    {out_dir, "src"}
]},

%% regenerate before every compilation:
{provider_hooks, [{pre, [{compile, {default, thrift}}]}]}
```

For local development the plugin is attached via `_checkouts/`:

```
mkdir -p _checkouts
ln -s /path/to/thrift-generator/apps/rebar3_thrift _checkouts/rebar3_thrift
ln -s /path/to/thrift-generator/apps/thrift_generator _checkouts/thrift_generator
```

## Example

IDL (`src/ping.thrift`):

```thrift
namespace erl ping.api

struct PingRequest {
  1: required string message
}

struct PingReply {
  1: required string message,
  2: i64 at_millis
}

exception NoSuchMessage {
  1: string text
}

service Ping {
  PingReply ping(1: PingRequest request) throws(1: NoSuchMessage err),
  oneway void poke()
}
```

Handler (include the generated header; when a thrift file includes
others, bring their `<mod>_types.hrl` files in first — the generated
headers say which):

```erlang
-module(ping_handler).
-include("ping_api_types.hrl").

-behaviour('Ping_handler').

-export([ping/1, poke/1]).

ping(#pingrequest{message = <<"bad">>}) ->
    {error, {exception, <<"NoSuchMessage">>, #nosuchmessage{text = <<"nope">>}}};
ping(#pingrequest{message = Msg}) ->
    {ok, #pingreply{message = <<"pong: ", Msg/binary>>, at_millis = 0}}.

poke(_Req) -> {ok, undefined}.
```

Server and client:

```erlang
{ok, Server} = 'Ping_server':start_link(#{port => 9090, handler => ping_handler}),
{ok, Client} = 'Ping_client':start_link(#{host => "127.0.0.1", port => 9090}),
{ok, #pingreply{message = <<"pong: hi">>}} =
    'Ping_client':ping(Client, #pingrequest{message = <<"hi">>}),
%% a declared exception comes back typed:
{error, {exception, <<"NoSuchMessage">>, #nosuchmessage{}}} =
    'Ping_client':ping(Client, #pingrequest{message = <<"bad">>}),
ok = 'Ping_client':stop(Client),
ok = 'Ping_server':stop(Server).
```

`start_link` options (a map at creation time, not app env):

- `transport` — `framed` (the default) or `buffered`;
- `protocol` — `binary` (the default), `compact`, or any module
  implementing the `thrift_erl_protocol` behaviour;
- server: `port`, `handler`, `max_frame_size`, `max_connections`,
  `timeout`, `backlog`;
- client: `host`, `port`, `timeout` (connect and per-call),
  `max_frame_size`.

## Representations and protocols

Structs live in two independent axes. The **protocol** axis picks the
wire format (`binary` and `compact` are built in; any
`thrift_erl_protocol` module plugs in; `native`-style EEP-79 records
are reserved for a future milestone). The **representation** axis
(`thrift_erl:repr()`) picks the in-process shape:

- `record` — the generated record (the default for plain structs);
- `map` — plain atom-key maps matching the IDL field names;
- `struct` — `#{__struct__ => Tag, Field => Value, ...}`, the tagged
  map that survives round-trips without record definitions in scope.

`encode/2` accepts any representation and auto-detects it; `decode/3`
produces the requested one. Every struct in `<mod>_types.erl` gets a
fixed set of codec functions (prefix = lowercased struct name):

```erlang
{ok, Bin} = ping_api_types:encode_pingrequest(Req),
{ok, Req} = ping_api_types:decode_pingrequest(Bin),                  %% record
{ok, Map} = ping_api_types:decode_pingrequest(Bin, map),             %% atom-key map
{ok, Struct} = ping_api_types:decode_pingrequest(Bin, struct),
{ok, Req} = ping_api_types:pingrequest_from_map(Map),
%% protocol is the third argument everywhere:
{ok, Bin} = ping_api_types:encode_pingrequest(Req, my_protocol_mod).
```

Decoding is strict: trailing bytes answer `{error, trailing}`,
truncation `{error, truncated}`.

`convert/2` reshapes typed values without touching bytes (it also
lives on `thrift_erl:convert/3` for hand-written descriptors):

```erlang
{ok, Map} = ping_api_types:convert(Req, map),
{ok, Req} = ping_api_types:convert(Struct, record).
%% map-mode structs (erl.struct_type = "map") have no record to
%% produce: convert(_, record) answers {error, {no_record, Tag}}.
```

The representation of a struct can also be pinned in the IDL with
`erl.struct_type = "map"` — values become maps at the wire boundary in
clients, servers and codecs (keys are atoms by default;
`erl.struct_type.map.key_type = "binary"` keeps wire keys).

Enums get `color_to_int/1` / `color_from_int/1` helpers, constants get
zero-argument functions plus `-define` macros for scalars, and the
header file declares typed records, record/enum aliases and those
macros.

### The compact protocol

`thrift_erl_compact` implements the Apache compact wire format: zigzag
varint integers, delta-encoded field ids, nibble-packed type tags and
collections whose header carries the element type. Every `protocol`
slot accepts the atom `compact` — clients, servers, the facade and the
generated codecs all resolve it through `thrift_erl:protocol_module/1`
the same way as `binary`:

```erlang
{ok, Server} = 'Ping_server':start_link(#{
    port => 9090, handler => ping_handler, protocol => compact
}),
{ok, Client} = 'Ping_client':start_link(#{
    host => "127.0.0.1", port => 9090, protocol => compact, transport => buffered
}),
{ok, Bin} = ping_api_types:encode_pingrequest(Req, thrift_erl_compact),
{ok, Req} = thrift_erl_compact:decode(ping_api_types:pingrequest_struct_info(), Bin).
```

The same values take up to ~2.5× fewer wire bytes than binary on
container-heavy structs (see Performance). Booleans ride in the field header nibble;
`uuid` is the one Thrift type the compact format cannot carry and is
rejected at encode/decode time. Interop with the stock Apache runtime
is covered in both directions: the golden suite runs the official
compact client (`thrift_client_util:new(..., [{protocol, compact}])`)
against our compact server on both transports, and the benchmark
proves the official reader accepts our compact bytes struct by struct.

## Pooling

`thrift_erl_client` is deliberately connection-per-process with no
automatic reconnection: any failure fails the outstanding calls and
stops the process, so a pool sees the death immediately and replaces
the worker. Use it as a poolboy/pooler worker:

```erlang
%% poolboy
{ok, Pool} = poolboy:start_link(#{
    worker_module => {'Ping_client', start, [#{host => "127.0.0.1", port => 9090}]},
    size => 10, max_overflow => 5
}),
Reply = poolboy:transaction(Pool, fun(C) -> 'Ping_client':call(C, <<"ping">>, [], 5000) end).

%% pooler
%% in config: {[{pools, [[{name, ping}, {max_count, 10}, {init_count, 2},
%%                        {start_mfa, {'Ping_client', start, [Opts]}}]]}]}
Client = pooler:take_member(ping),
try 'Ping_client':call(Client, <<"ping">>, [], 5000)
after pooler:return_member(ping, Client, ok) end.
```

`start/1` (unlinked) exists exactly for such owners; `stop/1` answers
outstanding calls with `{error, closed}` instead of leaving them
hanging. Sockets run in `{active, N}` delivery mode, so a dead peer is
noticed even on an idle connection. Calls are serialized per
connection; concurrent callers queue in order.

## Reconnecting client

When the caller is not a pool but a long-lived consumer,
`thrift_erl_reconnecting_client` wraps the simple client with
automatic reconnection and statistics. The wrapped client keeps its
no-reconnect contract; the wrapper observes its death, retries with
exponential backoff (`reconnect_min` → doubled → `reconnect_max`,
defaults 500 ms / 30 s) and fails calls that arrive in between with
`{error, disconnected}`. A server that is down does not fail the
start — the wrapper keeps trying, like the reference Apache
`thrift_reconnecting_client`:

```erlang
{ok, Client} = thrift_erl_reconnecting_client:start_link(
    #{host => "localhost", port => 9090, service => 'Ping_thrift',
      reconnect_min => 500, reconnect_max => 30000}
),
{ok, Pong} = thrift_erl_reconnecting_client:call(Client, <<"ping">>, [], 5000),

%% the pool health-check surface
#{connected := true, calls_ok := 3, calls_failed := 0,
  connects := 1, connect_failures := 0} =
    thrift_erl_reconnecting_client:get_stats(Client),
thrift_erl_reconnecting_client:get_and_reset_stats(Client).
```

Server-reported exceptions are protocol replies: they come back
unchanged and never reconnect. Every failed retry is logged at
warning level (`domain => [thrift]`).

## Multiplexed services

Several services can share one port. The server hosts them by name;
clients opt in with `multiplex`, which prefixes every outgoing message
name with `<<"Service:function">>` (the Apache multiplexed protocol
convention — replies keep the plain function name, so nothing else
changes):

```erlang
%% server: host two services on one port
{ok, Server} = thrift_erl_server:start_link(#{
    port => 9090,
    services => #{
        <<"Widgets">> => #{handler => WidgetsHandler, service => 'Widgets_thrift'},
        <<"Users">>   => #{handler => UsersHandler,   service => 'Users_thrift'}
    }
}),

%% clients pick their service; function names stay plain
{ok, Widgets} = thrift_erl_client:start_link(
    #{host => "localhost", port => 9090, service => 'Widgets_thrift', multiplex => <<"Widgets">>}),
{ok, Users} = thrift_erl_client:start_link(
    #{host => "localhost", port => 9090, service => 'Users_thrift', multiplex => <<"Users">>}),
```

A generated server/client pair takes the same options — pass
`services` to the generated server module or `multiplex` to the
generated client, everything else is unchanged. The dispatch is strict
in multiplexed mode: a name whose prefix is not a hosted service (or a
plain name) is refused with the `UNKNOWN_METHOD` application
exception, and the connection stays usable. A single-service server
stays liberal: it answers plain names and keeps answering names that
carry any `Service:' prefix, so a multiplexed client pointed at a
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
{ok, Server} = thrift_erl_server:start_link(#{
    port => 9090, handler => PingHandler, service => 'Ping_thrift',
    ssl_opts => [{certs_keys, [#{certfile => "cert.pem", keyfile => "key.pem"}]}]
}),

%% client: verify the server
{ok, Client} = thrift_erl_client:start_link(#{
    host => "localhost", port => 9090, service => 'Ping_thrift',
    ssl_opts => [{verify, verify_peer}, {cacerts, CaDer},
                 {server_name_indication, "localhost"}]
})
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

## Namespaces

A `namespace erl` (or the `namespace *` fallback) does two things:

- names the generated modules, as before (`namespace erl demo.widgets`
  → `demo_widgets_types.erl`, `demo_widgets_types.hrl`);
- prefixes every generated identifier of the file — record tags, type
  aliases, derived function names (`encode_demo_widgets_point`),
  constant macros — so same-named structs of different files coexist
  once both hrl files land in one compilation. The value is normalized:
  lowercased, non-identifier runs collapsed to `_`, a leading digit
  guarded (`_2fast`); a value that normalizes to nothing is a load
  error. Wire names stay untouched: `struct_info(<<"Point">>)`,
  `enum_info(<<"Color">>)` and enum member atoms are exactly as
  declared, so the binary protocol contract does not move. Without an
  `erl`/`*` namespace nothing is prefixed (other scopes such as
  `namespace java` are not our naming concern).

## Codegen annotations

- `erl.struct_type = "map"` — emit the struct as a map
  (plus `erl.struct_type.map.key_type = "atom"` for atom keys);
  the default is records;
- `erl.set = "sets" | "ordset"` — the in-process set implementation a
  decoded set is built into: `sets` (the v2 `sets` module) or
  `ordsets`; the default keeps the plain wire list. The annotation sits
  after the whole `set<...>` type (on the field or the typedef —
  inside the angle brackets it would annotate the element). The wire
  encoding is identical for all three; records in the generated hrl get
  `sets:set(E)` / `ordsets:ordset(E)` types;
- `erl.type = "nominal"` on a typedef — `-nominal` instead of an alias;
- `erl.*` annotations are filtered out at parse time, all others are
  preserved.

Introspection in the spirit of the official generator: `struct_info/1`,
`enum_info/1`, `function_info/2`, `record_fields/1`, `service_info/0`
in `<mod>_types.erl`.

## Performance

The codec hot path is benchmarked against the vendored official Apache
Thrift 0.25.0 Erlang runtime with `scripts/bench` (erlperf, continuous
mode, average of three 500 ms samples ± sample stddev, single process;
knobs via `BENCH_WARMUP`, `BENCH_SAMPLES`, `BENCH_SAMPLE_MS`). The
benchmark is a hand-run script, not a test suite. Reference numbers
include a fresh membuffer transport and protocol per operation, which
its API requires; both sides run on the same ThriftTest payloads. Our
codec compiles type descriptors once — referenced structs in a shared
`persistent_term` cache, inline descriptors in a per-process memo — so
nested schemas are never re-resolved per wire occurrence.

| case | operation | thrift_erl | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (42 B)     | encode | 4.37 M/s | 902 K/s | 4.8x |
| Xtruct            | decode | 1.96 M/s | 431 K/s | 4.5x |
| Xtruct2 (51 B)    | encode | 1.89 M/s | 623 K/s | 3.0x |
| Xtruct2           | decode | 1.05 M/s | 230 K/s | 4.6x |
| Insanity (3.2 KB) | encode | 31.8 K/s | 8.4 K/s | 3.8x |
| Insanity          | decode | 16.8 K/s | 5.0 K/s | 3.4x |

The **compact protocol** runs the same payload set on both sides —
`thrift_erl_compact` against the vendored `thrift_compact_protocol`
(28 B / 24 B / 1.2 KB on the wire, roughly half the binary encoding):

| case | operation | thrift_erl | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (28 B)      | encode | 2.88 M/s | 500 K/s | 5.8x |
| Xtruct             | decode | 2.04 M/s | 401 K/s | 5.1x |
| Xtruct2 (24 B)     | encode | 1.50 M/s | 398 K/s | 3.8x |
| Xtruct2            | decode | 945 K/s  | 253 K/s | 3.7x |
| Insanity (1.2 KB)  | encode | 19.5 K/s | 9.3 K/s | 2.1x |
| Insanity           | decode | 16.7 K/s | 4.6 K/s | 3.6x |

Only the speedup ratios on the same machine are meaningful; run
`./scripts/bench` to get numbers for your hardware.

## Roadmap

Done through M9 (SSL, the reconnecting client, multiplexed services)
plus the compact protocol off schedule. Remaining off schedule (the
axis/option slots are reserved): a JSON protocol, an HTTP transport,
native EEP-79 records.

## License

Apache License 2.0. The lexer/parser are derived from Apache Thrift
(Pinterest, 2017) with attribution preserved; the vendored fixture
`vendor/apache-thrift-erl` is Apache Thrift 0.25.0 (see
`vendor/apache-thrift-erl/README-VENDORED.md`).
