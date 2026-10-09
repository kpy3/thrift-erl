# thrift-generator

An alternative Apache Thrift generator and runtime library for Erlang.
It takes Thrift IDL and generates Erlang code for types, clients and
servers that is binary-protocol compatible with the stock Apache Thrift
implementation (verified both ways by golden interop tests against the
official 0.25.0 runtime over buffered and framed transports).

## Layout

```
apps/thrift_generator/   IDL parser (leex/yecc), semantics, emitter, CLI
apps/thrift_erl/         runtime: binary, compact & JSON protocols, transports, server, client
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

-export([ping/1, poke/0]).

ping(#ping_api_pingrequest{message = <<"bad">>}) ->
    {error, {exception, <<"NoSuchMessage">>, #ping_api_nosuchmessage{text = <<"nope">>}}};
ping(#ping_api_pingrequest{message = Msg}) ->
    {ok, #ping_api_pingreply{message = <<"pong: ", Msg/binary>>, at_millis = 0}}.

poke() -> {ok, undefined}.
```

Server and client:

```erlang
{ok, Server} = 'Ping_server':start_link(#{port => 9090, handler => ping_handler}),
{ok, Client} = 'Ping_client':start_link(#{host => "127.0.0.1", port => 9090}),
{ok, #ping_api_pingreply{message = <<"pong: hi">>}} =
    'Ping_client':ping(Client, #ping_api_pingrequest{message = <<"hi">>}),
%% a declared exception comes back typed:
{error, {exception, <<"NoSuchMessage">>, #ping_api_nosuchmessage{}}} =
    'Ping_client':ping(Client, #ping_api_pingrequest{message = <<"bad">>}),
ok = 'Ping_client':stop(Client),
ok = 'Ping_server':stop(Server).
```

`start_link` options (a map at creation time, not app env):

- `transport` — `framed` (the default), `buffered`, or `http`;
- `protocol` — `binary` (the default), `compact`, `json`, or any
  module implementing the `thrift_erl_protocol` behaviour;
- server: `port`, `handler`, `max_frame_size`, `max_connections`,
  `timeout` (the umbrella: TLS handshake and inter-message silence),
  `handshake_timeout` / `idle_timeout` (naming each meaning
  specifically), `active_n`, `backlog`;
- client: `host`, `port`, `timeout` (connect and TLS handshake;
  per-call timeouts ride the call itself; `connect_timeout` overrides
  the umbrella), `max_frame_size`, `active_n`.

## Representations and protocols

Structs live in two independent axes. The **protocol** axis picks the
wire format (`binary`, `compact` and `json` are built in; any
`thrift_erl_protocol` module plugs in). The **representation** axis
(`thrift_erl:repr()`) picks the in-process shape:

- `record` — the generated record (the default for plain structs);
- `map` — plain atom-key maps matching the IDL field names;
- `struct` — `#{__struct__ => Tag, Field => Value, ...}`, the tagged
  map that survives round-trips without record definitions in scope;
- `native` — EEP-79 native records (OTP 29+): a real datatype minted
  from the struct descriptor, no compiled definitions needed to read
  it (`records:get/2`, `records:get_name/1`, ...). Older releases
  answer `{error, {unsupported_repr, native}}`.

`encode/2` accepts any representation and auto-detects it; `decode/3`
produces the requested one. `thrift_erl:encode/4` takes an options map
on top: `strict => true` fails a map/struct-map input carrying keys
that match no declared field (`{error, {unknown_fields, Keys}}`)
instead of dropping them silently. A value that matches no
representation answers `{error, {value_does_not_match_type, Value}}`
from every entry point. Every struct in `<mod>_types.erl` gets a
fixed set of codec functions (prefix = the `erl` namespace prefix, then the lowercased struct name):

```erlang
{ok, Bin} = ping_api_types:ping_api_encode_pingrequest(Req),
{ok, Req} = ping_api_types:ping_api_decode_pingrequest(Bin),                  %% record
{ok, Map} = ping_api_types:ping_api_decode_pingrequest(Bin, map),             %% atom-key map
{ok, Struct} = ping_api_types:ping_api_decode_pingrequest(Bin, struct),
{ok, Req} = ping_api_types:ping_api_pingrequest_from_map(Map),
%% the protocol goes into the last argument of every codec:
{ok, Bin} = ping_api_types:ping_api_encode_pingrequest(Req, my_protocol_mod).
```

Decoding is strict: trailing bytes answer `{error, trailing}`,
truncation `{error, truncated}`.

`convert/2` reshapes typed values without touching bytes (it also
lives on `thrift_erl:convert/3` for hand-written descriptors):

```erlang
{ok, Map} = ping_api_types:convert(Req, map),
{ok, Req} = ping_api_types:convert(Struct, record).
%% map-mode structs (erl.struct_type = "map") have no record to
%% produce: the record target answers {error, {no_record, Tag}} in
%% convert/2, convert/3 and decode alike.
```

The representation of a struct can also be pinned in the IDL with
`erl.struct_type = "map"` — values become maps at the wire boundary in
clients, servers and codecs (keys are atoms by default;
`erl.struct_type.map.key_type = "binary"` keeps wire keys).

Native records keep the representation uniform all the way down: a
nested struct decodes into a native record of its own, and a native
record encodes back to the same bytes as the tuple record would. The
runtime mints values dynamically (no `-record #` declarations are
emitted), so pattern matching one requires declaring `-record #name{}`
in the consumer — reading through the `records` module needs nothing:

```erlang
{ok, Req} = ping_api_types:ping_api_decode_pingrequest(Bin, native),
<<"hi">> = records:get(message, Req),
{ok, Bin} = ping_api_types:ping_api_encode_pingrequest(Req).   %% auto-detected
```

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
{ok, Bin} = ping_api_types:ping_api_encode_pingrequest(Req, thrift_erl_compact),
{ok, Req, <<>>} = thrift_erl_compact:decode(ping_api_types:struct_info(<<"PingRequest">>), Bin).
```

The same values take up to ~2.5× fewer wire bytes than binary on
container-heavy structs (see Performance). Booleans ride in the field header nibble;
`uuid` is the one Thrift type the compact format cannot carry and is
rejected at encode/decode time. Interop with the stock Apache runtime
is covered in both directions: the golden suite runs the official
compact client (`thrift_client_util:new(..., [{protocol, compact}])`)
against our compact server on both transports, and the benchmark
proves the official reader accepts our compact bytes struct by struct.

### The JSON protocol

`thrift_erl_json` implements the Apache JSON wire format: a message is
the array `[1,"name",type,seqid,payload]`, a struct is an object keyed
by field id where every value is a one-key object naming the type
(`{"1":{"i32":5}}`), a list or set is `["i32",2,1,2]`, and a map is an
object with stringified keys (`["i32","i32",2,{"1":10}]`). Every
`protocol` slot accepts the atom `json` exactly like the other built
ins:

```erlang
{ok, Server} = 'Ping_server':start_link(#{
    port => 9090, handler => ping_handler, protocol => json
}),
{ok, Client} = 'Ping_client':start_link(#{
    host => "127.0.0.1", port => 9090, protocol => json, transport => buffered
}),
{ok, Bin} = ping_api_types:ping_api_encode_pingrequest(Req, thrift_erl_json),
{ok, Req, <<>>} = thrift_erl_json:decode(ping_api_types:struct_info(<<"PingRequest">>), Bin).
```

Two bends are documented on the module: the envelope's closing bracket
is folded into the top-level struct decode (which keeps the buffered
transport's completeness probe byte-exact), and map keys are limited to
what a JSON object key can carry — booleans, numbers, strings, enums —
while a struct-keyed map and `uuid` are refused by encode and decode
alike. Interop with the stock Apache runtime is covered in both
directions: the golden suite runs the official JSON client
(`thrift_client_util:new(..., [{protocol, json}])`) against our JSON
server on both transports, and the benchmark proves the official reader
accepts our JSON messages struct by struct.

## The HTTP transport

`transport => http` turns every Thrift exchange into one HTTP/1.1
request-response pair: the client POSTs the encoded message to
`http_path` (default `"/"`), the server answers with the reply in the
response body, and the connection stays open for the next call
(keep-alive). The protocol axis is untouched — binary, compact and
json all ride in the body:

```erlang
{ok, Server} = 'Ping_server':start_link(#{
    port => 9090, handler => ping_handler, transport => http
}),
{ok, Client} = 'Ping_client':start_link(#{
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

`thrift_erl_client` is deliberately connection-per-process with no
automatic reconnection: any failure fails the outstanding calls and
stops the process, so a pool sees the death immediately and replaces
the worker. The unlinked `thrift_erl_client:start/1` (plus
`service => 'Ping_server'`) is the pool-worker entry:

```erlang
ClientOpts = #{host => "127.0.0.1", port => 9090, service => 'Ping_server'},

%% poolboy
{ok, Pool} = poolboy:start_link(#{
    worker_module => {thrift_erl_client, start, [ClientOpts]},
    size => 10, max_overflow => 5
}),
Reply = poolboy:transaction(Pool, fun(C) -> thrift_erl_client:call(C, <<"poke">>, [], 5000) end).

%% pooler
%% in config: {[{pools, [[{name, ping}, {max_count, 10}, {init_count, 2},
%%                        {start_mfa, {thrift_erl_client, start, [ClientOpts]}}]]}]}
Client = pooler:take_member(ping),
try thrift_erl_client:call(Client, <<"poke">>, [], 5000)
after pooler:return_member(ping, Client, ok) end.
```

`stop/1` answers outstanding calls with `{error, closed}` instead of
leaving them hanging. Sockets run in `{active, N}` delivery mode, so a
dead peer is noticed even on an idle connection. Calls are serialized
per connection; concurrent callers queue in order.

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
    #{host => "localhost", port => 9090, service => 'Ping_server',
      reconnect_min => 500, reconnect_max => 30000}
),
{ok, undefined} = thrift_erl_reconnecting_client:call(Client, <<"poke">>, [], 5000),

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
        <<"Widgets">> => #{handler => WidgetsHandler, service => 'Widgets_server'},
        <<"Users">>   => #{handler => UsersHandler,   service => 'Users_server'}
    }
}),

%% clients pick their service; function names stay plain
{ok, Widgets} = thrift_erl_client:start_link(
    #{host => "localhost", port => 9090, service => 'Widgets_server', multiplex => <<"Widgets">>}),
{ok, Users} = thrift_erl_client:start_link(
    #{host => "localhost", port => 9090, service => 'Users_server', multiplex => <<"Users">>}),
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
    port => 9090, handler => ping_handler, service => 'Ping_server',
    ssl_opts => [{certs_keys, [#{certfile => "cert.pem", keyfile => "key.pem"}]}]
}),

%% client: verify the server
{ok, Client} = thrift_erl_client:start_link(#{
    host => "localhost", port => 9090, service => 'Ping_server',
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
  `ordsets`; the default keeps the plain wire list — deliberately
  unlike the official Erlang runtime, which decodes every set into
  `sets:set()`: parity with Apache is on the wire, not in the
  in-process term. The passthrough costs nothing and keeps hand-written
  2-tuple descriptors intact, while `erl.set = "sets"` reproduces the
  official representation where wanted. The annotation sits
  after the whole `set<...>` type (on the field or the typedef —
  inside the angle brackets it would annotate the element). The same
  annotation on the `namespace erl` (or `namespace *`) header —
  `namespace erl my.service (erl.set = "sets")` — sets the file-wide
  default for every set in the document (the migration path from the
  official runtime's `sets:set()` representation); an explicit
  per-type annotation wins. Set-typed record defaults are wrapped in
  the constructor call (`sets:from_list([...])`) in the generated
  hrl and inline records. The wire
  encoding is identical for all three; records in the generated hrl get
  `sets:set(E)` / `ordsets:ordset(E)` types;
- `erl.type = "nominal"` on a typedef — `-nominal` instead of an alias;
- `erl.*` annotations are filtered out at parse time, all others are
  preserved.

Introspection in the spirit of the official generator: `struct_info/1`,
`enum_info/1`, `function_info/2`, `record_fields/1`, `service_info/0`,
`tag_index/0` and `convert/2` in `<mod>_types.erl`.

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

The **JSON protocol** runs the same payload set on both sides —
`thrift_erl_json` against the vendored `thrift_json_protocol`
(87 B / 110 B / 6.7 KB on the wire; decode is measured at message
level, since the official JSON reader primes on a whole message):

| case | operation | thrift_erl | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (87 B)      | encode | 796 K/s | 109 K/s | 7.3x |
| Xtruct             | decode | 84 K/s  | 66 K/s  | 1.3x |
| Xtruct2 (110 B)    | encode | 587 K/s | 60 K/s  | 9.8x |
| Xtruct2            | decode | 51 K/s  | 46 K/s  | 1.1x |
| Insanity (6.7 KB)  | encode | 5.7 K/s | 1.2 K/s | 4.8x |
| Insanity           | decode | 1.1 K/s | 1.1 K/s | 1.0x |

Encode is several times faster because the official side formats every
token through `io_lib`; on decode both sides scan the same text, so the
gap is small.

Only the speedup ratios on the same machine are meaningful; run
`./scripts/bench` to get numbers for your hardware.

## License

Apache License 2.0. The lexer/parser are derived from Apache Thrift
(Pinterest, 2017) with attribution preserved; the vendored fixture
`vendor/apache-thrift-erl` is Apache Thrift 0.25.0 (see
`vendor/apache-thrift-erl/README-VENDORED.md`).
