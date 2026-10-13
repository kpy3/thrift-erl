# thrift-erl

A complete Apache Thrift stack for Erlang: an IDL compiler, a runtime
library and a rebar3 plugin. What the compiler emits — and the runtime
that code depends on — is wire-compatible with the stock Apache Thrift
implementation, verified both ways by golden interop tests against the
official 0.25.0 runtime over buffered and framed transports, and
against its official compact, JSON, HTTP and multiplexed clients.

## Contents

- [Compared to Apache Thrift](#compared-to-apache-thrift)
  - [What you gain](#what-you-gain)
  - [Where the in-process contract differs](#where-the-in-process-contract-differs)
- [Layout](#layout)
- [Build and tests](#build-and-tests)
- [CLI](#cli)
- [rebar3 plugin](#rebar3-plugin)
- [Example](#example)
- [Representations and protocols](#representations-and-protocols)
  - [One struct, four representations](#one-struct-four-representations)
  - [The compact protocol](#the-compact-protocol)
  - [The JSON protocol](#the-json-protocol)
- [The HTTP transport](#the-http-transport)
- [Pooling](#pooling)
- [Reconnecting client](#reconnecting-client)
- [Observability](#observability)
- [Multiplexed services](#multiplexed-services)
- [TLS](#tls)
- [Namespaces](#namespaces)
- [Codegen annotations](#codegen-annotations)
- [Performance](#performance)
- [License](#license)

## Compared to Apache Thrift

Parity with Apache Thrift is the hard requirement here, not the
selling point, and it is tested rather than assumed: two-way golden
interop against the vendored official runtime — binary, compact and
JSON protocols over buffered, framed and HTTP transports, multiplexed
services included — plus PropEr properties pinning the specialized
codecs byte-for-byte to the generic engine on every protocol. Where
the in-process contract differs, it is deliberate.

### What you gain

- **Specialized codecs on the hot path.** The emitter compiles a
  per-struct wire codec into every generated module, and named struct
  references dispatch straight into it — no descriptor interpretation
  at runtime (the generic engine remains for introspection, inline
  descriptors and as the equivalence reference). Measured 4–7× on the
  binary protocol, 2.4–6× on compact and up to 10× on JSON encode
  against the official 0.25.0 Erlang runtime (see Performance;
  reproducible with `./scripts/bench`).
- **Errors are values.** Decoding answers `{error, trailing}` /
  `{error, truncated}` instead of throwing; a declared server
  exception comes back to the client typed, as
  `{error, {exception, Record}}` — the value's representation
  identifies the exception.
- **Four in-process representations.** Records (default), plain atom
  maps, tagged struct-maps, or EEP-79 native records on OTP 29 —
  selectable per struct, uniform all the way down, reshaped without
  touching bytes via `convert/2`. Sum-typed unions, atom enums and a
  selectable set implementation come with the IDL mapping.
- **A runtime with no dependencies.** `thrift_erl` stands on kernel
  and stdlib alone, generated code depends on nothing else, and the
  generator itself never ships to production.
- **Modern OTP.** Requires OTP 28+, old data structures (dicts, sets v1, etc)
  dropped, `-nominal` typedefs, and `-doc`/`-moduledoc`
  propagated from IDL doc comments into the generated modules.
- **Operational surface.** Graceful drain on server stop, a
  reconnecting client with backoff, per-worker statistics for pool
  health checks, crash-isolated `on_event` observability callbacks —
  on top of TLS, multiplexed services and an HTTP/1.1 transport.
- **Codegen tooling.** A rebar3 plugin with a `--check` freshness gate
  for CI, unchanged-file skipping so regeneration does not churn
  mtimes, and introspection exports (`struct_info/1`, `enum_info/1`,
  `function_info/2`, ...).

### Where the in-process contract differs

- Sets decode to plain wire lists by default; `erl.set = "sets"`
  reproduces the official `sets:set()` representation per type or
  file-wide (see [Codegen annotations](#codegen-annotations)) — parity
  is on the wire, not in the in-process term.
- Field defaults live in the generated record literals, not in decode:
  a missing optional field decodes as `undefined`; the default value is
  what a hand-constructed record carries.
- An unknown enum value on the wire passes through decode as the raw
  integer (forward compatibility with newer schemas); encode rejects
  values with no enum member (`{error, {unknown_enum_value, V}}`).
- The HTTP transport speaks an HTTP/1.1 subset with Content-Length
  framing only — no chunked encoding — and a oneway call is still a
  request/response exchange: the server answers 200 before running the
  handler, so the client and server never desynchronize.

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
rebar3 eunit        # unit tests + 10 PropEr codec properties
rebar3 ct           # loopback scenarios + golden interop
rebar3 dialyzer
rebar3 xref
rebar3 fmt
scripts/lint-elp    # ELP static analysis gate (needs the elp binary)
./scripts/bench     # manual codec benchmark (not part of the suites)
```

## CLI

```
rebar3 as prod escriptize
_build/prod/bin/thrift_generator generate my_api.thrift -o src
```

This generates `<mod>_types.erl` plus a `<mod>_types.hrl` include (one
pair per IDL file) and three modules per service —
`<prefix>_<svc>_client.erl`, `<prefix>_<svc>_server.erl`,
`<prefix>_<svc>_handler.erl`, where `<prefix>` is the file's
namespace-derived identifier prefix and `<svc>` is the snake-cased
service name (`Ping` in `namespace erl ping.api` generates
`ping_api_ping_client.erl` and friends). Files whose on-disk content
already matches are left untouched, so regenerating an unchanged IDL
does not churn mtimes.

The full flag set (`generate` stays accepted as an optional
subcommand):

- `-h` / `--help` — print the usage and exit;
- `-o` / `--out-dir <dir>` — directory for the generated sources
  (default: the current directory);
- `--repr record|map|native` — the value representation
  (`erl.struct_type`) for definitions without an explicit annotation
  of their own (default: record);
- `--union-type record|sum` — the union representation
  (`erl.union_type`) for unions without an explicit annotation
  (default: record);
- `--set list|sets|ordset` — the in-process set implementation
  (`erl.set`) for sets without an explicit annotation (default: list);
- `--typedef-type alias|nominal` — the typedef flavor (`erl.type`)
  for typedefs without an explicit annotation (default: alias);
- `--check` — verify freshness instead of writing (see below);
- `--compact-errors` — one-line error entries (see below).

Each of the four option axes picks the generated flavor only where the
IDL carries no explicit annotation of its own: an explicit annotation
wins, and a file-wide namespace default (`erl.set` / `erl.union_type`
on the `namespace erl` header) overrides the flag for its file.

Errors render as rebar3/elp-style source excerpts — the offending
line under a gutter, a `╰──` marker naming the problem. Positions
carry columns (the scanner threads `{Line, Column}` pairs through
lexer, parser and semantic pass), so the marker sits on the exact
column:

```
  ┌─ my_api.thrift:9:23:
  │
9 │ PingReply ping(1: PingRequest request) throws(1: NoSuchMessage err),
  │                      ╰── duplicate field id 1 (already used by message)
```

`--compact-errors` switches to one-line `path:line[:column]: message`
entries (the form the rebar3 plugin falls back to when the source file
cannot be read back).

`--check` verifies instead of writing: it fails (exit 1, listing the
drifted files) unless every generated artifact already exists in the
out dir with the exact content the IDL would produce — a CI freshness
gate:

```
_build/prod/bin/thrift_generator --check my_api.thrift -o src
```

## rebar3 plugin

In the consumer project's `rebar.config`:

```erlang
{plugins, [rebar3_thrift]},

{thrift, [
    {files, ["src/my_api.thrift"]},
    {out_dir, "src"},
    {repr, record},        %% record | map | native
    {union_type, record},  %% record | sum
    {set, list},           %% list | sets | ordset
    {typedef_type, alias}  %% alias | nominal
]},

%% regenerate before every compilation:
{provider_hooks, [{pre, [{compile, {default, thrift}}]}]}
```

The four option axes mirror the standalone generator's flags and apply
only to definitions without an explicit annotation of their own — a
file-wide namespace default overrides the option for its file. An
invalid value fails the provider with a rendered
`{bad_opt, {Key, Value, Allowed}}` error instead of a raw crash, and
the freshness checks (`rebar3 thrift --check` and the CLI `--check`)
count artifacts as stale unless they were generated with the same
option values.

`rebar3 thrift` regenerates the sources (unchanged files are not
rewritten). `rebar3 thrift --check` verifies freshness instead of
writing and fails the build when any generated artifact is missing or
stale relative to the IDL:

```
rebar3 thrift --check
```

`rebar3 thrift clean` deletes the generated files from the out dir:
every `.erl`/`.hrl` carrying the generator's `Autogenerated by Thrift
Generator` banner. The banner — not the current IDL — decides, so
files orphaned by a removed service or a deleted IDL are cleaned up
too, and anything not carrying the banner is left alone. To delete on
project cleanup, hook the namespaced clean provider into `rebar3
clean`:

```erlang
{provider_hooks, [{post, [{clean, {thrift, clean}}]}]}
```

For local development the plugin is attached via `_checkouts/`:

```
mkdir -p _checkouts
ln -s /path/to/thrift-erl/apps/rebar3_thrift _checkouts/rebar3_thrift
ln -s /path/to/thrift-erl/apps/thrift_generator _checkouts/thrift_generator
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

-behaviour(ping_api_ping_handler).

-export([ping/1, poke/0]).

ping(#ping_api_ping_request{message = <<"bad">>}) ->
    {error, {exception, #ping_api_no_such_message{text = <<"nope">>}}};
ping(#ping_api_ping_request{message = Msg}) ->
    {ok, #ping_api_ping_reply{message = <<"pong: ", Msg/binary>>, at_millis = 0}}.

poke() -> {ok, undefined}.
```

Server and client:

```erlang
{ok, Server} = ping_api_ping_server:start_link(#{port => 9090, handler => ping_handler}),
{ok, Client} = ping_api_ping_client:start_link(#{host => "127.0.0.1", port => 9090}),
{ok, #ping_api_ping_reply{message = <<"pong: hi">>}} =
    ping_api_ping_client:ping(Client, #ping_api_ping_request{message = <<"hi">>}),
%% a declared exception comes back typed:
{error, {exception, #ping_api_no_such_message{}}} =
    ping_api_ping_client:ping(Client, #ping_api_ping_request{message = <<"bad">>}),
ok = ping_api_ping_client:stop(Client),
ok = ping_api_ping_server:stop(Server).
```

`start_link` options (a map at creation time, not app env):

- `service` — the module implementing the `thrift_erl_service`
  behaviour (for generated services, `<prefix>_<svc>_server`);
  required by the client and by a single-service server (a multiplexed
  server passes `services` instead) — the generated server supplies
  its own;
- `transport` — `framed` (the default), `buffered`, or `http`;
- `protocol` — `binary` (the default), `compact`, `json`, or any
  module implementing the `thrift_erl_protocol` behaviour;
- server: `port`, `handler`, `name` (the locally registered name of
  the supervisor, default `thrift_erl_server`), `max_frame_size`,
  `max_connections`, `timeout` (the umbrella: TLS handshake and
  inter-message silence), `handshake_timeout` / `idle_timeout` (naming
  each meaning specifically), `active_n`, `backlog`;
- client: `host`, `port`, `timeout` (connect and TLS handshake;
  per-call timeouts ride the call itself; `connect_timeout` overrides
  the umbrella), `max_frame_size`, `active_n`, `max_queue_depth` (how
  many calls may wait while another is on the wire; overflow answers
  `{error, queue_full}`; the default `infinity` keeps the classic
  unbounded queue);
- both: `on_event` — the observability callback (see
  [Observability](#observability)).

A plain `stop/1` takes the server down at once. `stop/2` with
`#{drain => Timeout}` shuts down gracefully first: the listen socket
closes, idle connections are dropped, and connections with an
in-flight request answer it before exiting. The call returns when the
last connection is gone — or at the deadline (`infinity` allowed; the
deadline never fails the call, whatever it leaves over is then
swept by the normal supervised stop, which lets a still-running
exchange finish and fails the calls only of connections that cannot
finish):

```erlang
ok = ping_api_ping_server:stop(Server, #{drain => 10_000}).
```

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

### One struct, four representations

Decoding the same `PingRequest` bytes in the four representations —
only the record needs its hrl include, the maps and the native record
need nothing:

```erlang
{ok, Req}    = ping_api_types:ping_api_decode_ping_request(Bin),         %% record (the default)
{ok, Map}    = ping_api_types:ping_api_decode_ping_request(Bin, map),    %% plain atom-key map
{ok, Struct} = ping_api_types:ping_api_decode_ping_request(Bin, struct), %% tagged map
{ok, Native} = ping_api_types:ping_api_decode_ping_request(Bin, native), %% EEP-79 (OTP 29+)
```

The value each binding carries:

```erlang
Req = #ping_api_ping_request{message = <<"hi">>},
Map = #{message => <<"hi">>},
Struct = #{__struct__ => ping_api_ping_request, message => <<"hi">>},
%% Native is a native record: pattern-matching it takes a compiled
%% -record declaration, reading it takes nothing:
<<"hi">> = records:get(message, Native).
```

Details worth knowing: a field absent on the wire is absent from the
maps (the record carries `undefined` in its slot instead), and the
`__struct__` tag is the same record tag the record repr uses. Every
struct in `<mod>_types.erl` gets a fixed set of codec functions
(prefix = the `erl` namespace prefix, then the lowercased struct name):

```erlang
{ok, Req} = ping_api_types:ping_api_ping_request_from_map(Map),
%% the protocol goes into the last argument of every codec:
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Req, my_protocol_mod).
```

Encoding accepts any representation and auto-detects it — every form
encodes back to the same bytes:

```erlang
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Req),
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Map),
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Struct),
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Native).
```

On the facade `thrift_erl:encode/2` accepts any representation and
auto-detects it, `thrift_erl:decode/3` produces the requested one, and
`thrift_erl:encode/4` takes an options map on top: `strict => true`
fails a map/struct input carrying keys that match no declared field
(`{error, {unknown_fields, Keys}}`) instead of dropping them silently:

```erlang
{error, {unknown_fields, [extra]}} =
    thrift_erl:encode(ping_api_types:struct_info(<<"PingRequest">>),
                      #{message => <<"hi">>, extra => 1}, binary, #{strict => true}).
```

Decoding is strict: trailing bytes answer `{error, trailing}`,
truncation `{error, truncated}`. A value that matches no
representation answers `{error, {value_does_not_match_type, Value}}`
from every entry point.

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
{ok, Req} = ping_api_types:ping_api_decode_ping_request(Bin, native),
<<"hi">> = records:get(message, Req),
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Req).   %% auto-detected
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
{ok, Server} = ping_api_ping_server:start_link(#{
    port => 9090, handler => ping_handler, protocol => compact
}),
{ok, Client} = ping_api_ping_client:start_link(#{
    host => "127.0.0.1", port => 9090, protocol => compact, transport => buffered
}),
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Req, thrift_erl_compact),
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
{ok, Server} = ping_api_ping_server:start_link(#{
    port => 9090, handler => ping_handler, protocol => json
}),
{ok, Client} = ping_api_ping_client:start_link(#{
    host => "127.0.0.1", port => 9090, protocol => json, transport => buffered
}),
{ok, Bin} = ping_api_types:ping_api_encode_ping_request(Req, thrift_erl_json),
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

`thrift_erl_client` is deliberately connection-per-process with no
automatic reconnection: any failure fails the outstanding calls and
stops the process, so a pool sees the death immediately and replaces
the worker. The unlinked `thrift_erl_client:start/1` (plus
`service => ping_api_ping_server`) is the pool-worker entry:

```erlang
ClientOpts = #{host => "127.0.0.1", port => 9090, service => ping_api_ping_server},

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
per connection; concurrent callers queue in order. Each worker also
carries counters for pool health checks:
`thrift_erl_client:get_stats/1` answers `#{calls_ok, calls_failed}`
(every `{error, _}` answer counts failed, a declared exception
included) and `get_and_reset_stats/1` zeroes them.

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
    #{host => "localhost", port => 9090, service => ping_api_ping_server,
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

## Observability

Clients, reconnecting wrappers and servers accept `on_event`: an
observability callback — `undefined` (the default), a fun of arity 1,
or `{Module, Function, Args}` (the event is appended to `Args`, so the
handler can carry its own context — a pool id, an ETS table). Dispatch
is synchronous in the emitting process and crash-isolated: a handler
exception is discarded and never reaches the caller, the client or the
server. Handlers must still be fast — they run on the call path.

```erlang
%% a client: one event per caller-facing answer, a plain fun
{ok, Client} = thrift_erl_client:start_link(#{
    host => "localhost", port => 9090, service => ping_api_ping_server,
    on_event => fun(#{type := Type, function := Fun, duration_us := Us}) ->
                        logger:info("thrift ~ts ~ts: ~p us", [Type, Fun, Us])
                end}),

%% a server: {M, F, Args} carries context, the event rides last
%% (the call becomes my_metrics:record(<<"Ping">>, Event))
{ok, Server} = thrift_erl_server:start_link(#{
    port => 9090, handler => ping_handler, service => ping_api_ping_server,
    on_event => {my_metrics, record, [<<"Ping">>]}}).
```

The catalogue — one map per event, `type` first (the full contract
lives in the `thrift_erl_events` moduledoc):

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
`start_link/1` accepts the same options map as the runtime modules.

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
        <<"Widgets">> => #{handler => WidgetsHandler, service => shop_widgets_server},
        <<"Users">>   => #{handler => UsersHandler,   service => shop_users_server}
    }
}),

%% clients pick their service; function names stay plain
{ok, Widgets} = thrift_erl_client:start_link(
    #{host => "localhost", port => 9090, service => shop_widgets_server, multiplex => <<"Widgets">>}),
{ok, Users} = thrift_erl_client:start_link(
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
{ok, Server} = thrift_erl_server:start_link(#{
    port => 9090, handler => ping_handler, service => ping_api_ping_server,
    ssl_opts => [{certs_keys, [#{certfile => "cert.pem", keyfile => "key.pem"}]}]
}),

%% client: verify the server
{ok, Client} = thrift_erl_client:start_link(#{
    host => "localhost", port => 9090, service => ping_api_ping_server,
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

- `erl.struct_type = "map"` — emit the struct as a map (keys are
  atoms by default; `erl.struct_type.map.key_type = "binary"` keeps
  the wire's binary keys); the default is records;
- `erl.struct_type = "native"` — EEP-79 native records on OTP 29+
  (what the values look like is covered under
  [Representations and protocols](#representations-and-protocols));
- `erl.union_type = "sum"` — a union as a sum type of tuples
  `{FieldAtom, Value}`: no record (the hrl carries only the type
  alias), the wire shape stays the usual one field, and record- and
  sum-union representations interoperate; a file-wide default rides
  the `namespace erl` (or `namespace *`) header, an explicit
  annotation on the union wins;
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
nested schemas are never re-resolved per wire occurrence. The emitter
also writes specialized per-struct wire codecs into `<mod>_types.erl`
for all three protocols — `encode_<X>_wire`/`decode_<X>_wire`,
`encode_<X>_compact`/`decode_<X>_compact` and
`encode_<X>_json`/`decode_<X>_json`, each behind its `binary_codec/1`,
`compact_codec/1` or `json_codec/1` index — and named struct references
dispatch straight into them, with no descriptor interpretation on the
hot path. The generic engine remains for inline descriptors,
introspection and as the equivalence reference the PropEr suite pins
the specialized codecs to.

| case | operation | thrift_erl | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (42 B)     | encode | 2.54 M/s | 453 K/s | 5.6x |
| Xtruct            | decode | 1.36 M/s | 223 K/s | 6.1x |
| Xtruct2 (51 B)    | encode | 1.48 M/s | 327 K/s | 4.5x |
| Xtruct2           | decode | 794 K/s  | 119 K/s | 6.7x |
| Insanity (3.2 KB) | encode | 31.2 K/s | 4.4 K/s | 7.0x |
| Insanity          | decode | 14.0 K/s | 2.6 K/s | 5.4x |

The **compact protocol** runs the same payload set on both sides —
`thrift_erl_compact` against the vendored `thrift_compact_protocol`
(28 B / 24 B / 1.2 KB on the wire, roughly half the binary encoding):

| case | operation | thrift_erl | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (28 B)      | encode | 1.53 M/s | 252 K/s | 6.1x |
| Xtruct             | decode | 851 K/s  | 215 K/s | 4.0x |
| Xtruct2 (24 B)     | encode | 1.04 M/s | 204 K/s | 5.1x |
| Xtruct2            | decode | 541 K/s  | 130 K/s | 4.2x |
| Insanity (1.2 KB)  | encode | 11.9 K/s | 5.0 K/s | 2.4x |
| Insanity           | decode | 7.9 K/s  | 2.4 K/s | 3.3x |

The **JSON protocol** runs the same payload set on both sides —
`thrift_erl_json` against the vendored `thrift_json_protocol`
(87 B / 110 B / 6.7 KB on the wire; decode is measured at message
level, since the official JSON reader primes on a whole message):

| case | operation | thrift_erl | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (87 B)      | encode | 794 K/s | 113 K/s | 7.1x |
| Xtruct             | decode | 101 K/s | 63 K/s  | 1.6x |
| Xtruct2 (110 B)    | encode | 568 K/s | 57 K/s  | 10.1x |
| Xtruct2            | decode | 54 K/s  | 45 K/s  | 1.2x |
| Insanity (6.7 KB)  | encode | 5.3 K/s | 1.2 K/s | 4.5x |
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
