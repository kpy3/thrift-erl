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
- [Build requirements](#build-requirements)
- [Getting started](#getting-started)
- [Encode, decode and convert](#encode-decode-and-convert)
- [Representations and protocols](#representations-and-protocols)
- [References](#references)
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
  descriptors and as the equivalence reference). Measured several-fold
  faster than the official 0.25.0 Erlang runtime across all three
  protocols (see [Performance](docs/performance.md); reproducible
  with `./scripts/bench`).
- **Errors are values.** Decoding answers `{error, trailing}` /
  `{error, truncated}` instead of throwing; a declared server
  exception comes back to the client typed, as
  `{error, {exception, Record}}` — the value's representation
  identifies the exception.
- **Four in-process representations.** Records (default), plain atom
  maps, tagged struct-maps, or EEP-79 native records on OTP 29 —
  selectable per struct, uniform all the way down, reshaped without
  touching bytes via the type-first `convert/3`. Sum-typed unions,
  atom enums and a selectable set implementation come with the IDL
  mapping.
- **A runtime with no dependencies.** `thrift_runtime` stands on kernel
  and stdlib alone, generated code depends on nothing else, and the
  generator itself never ships to production.
- **Modern OTP.** Requires OTP 28+, old data structures (dicts, sets v1, etc)
  dropped, `-nominal` typedefs, and `-doc`/`-moduledoc`
  propagated from IDL doc comments into the generated modules.
- **Operational surface.** Graceful drain on server stop, a
  reconnecting client with backoff, per-worker statistics for pool
  health checks, crash-isolated `on_event` observability callbacks —
  on top of TLS, multiplexed services and an HTTP/1.1 transport. See
  [RPC and operations](docs/rpc.md).
- **Codegen tooling.** A rebar3 plugin with a `--check` freshness gate
  for CI, unchanged-file skipping so regeneration does not churn
  mtimes, and introspection exports (`struct_info/1`, `enum_info/1`,
  `function_info/2`, ...). See the
  [Generator reference](docs/generator.md).

### Where the in-process contract differs

- Sets decode to plain wire lists by default; `erl.set = "sets"`
  reproduces the official `sets:set()` representation per type or
  file-wide (see [Codegen annotations](docs/generator.md#codegen-annotations))
  — parity is on the wire, not in the in-process term.
- Field defaults live in the generated record literals, not in decode:
  a missing optional field decodes as `undefined`; the default value is
  what a hand-constructed record carries.
- An unknown enum value on the wire passes through decode as the raw
  integer (forward compatibility with newer schemas); encode rejects
  values with no enum member (`{error, {unknown_enum_value, V}}`).
- The HTTP transport speaks an HTTP/1.1 subset with Content-Length
  framing only — no chunked encoding — and a oneway call is still a
  request/response exchange: the server answers 200 before running the
  handler, so the client and server never desynchronize. See
  [RPC and operations](docs/rpc.md#the-http-transport).

## Layout

```
apps/thrift_generator/   IDL parser (leex/yecc), semantics, emitter, CLI
apps/thrift_runtime/         runtime: binary, compact & JSON protocols, transports, server, client
apps/rebar3_thrift/      rebar3 plugin (the thrift provider)
vendor/apache-thrift-erl official Apache Thrift Erlang runtime (0.25.0),
                         test profile only — the golden interop fixture
```

Generated code depends only on `thrift_runtime` (kernel + stdlib).
The generator is never a runtime dependency.

## Build requirements

Requires Erlang/OTP 28+.

```
rebar3 compile
rebar3 eunit        # unit tests + PropEr codec properties
rebar3 ct           # loopback scenarios + golden interop
rebar3 dialyzer
rebar3 xref
rebar3 fmt
scripts/lint-elp    # ELP static analysis gate (needs the elp binary)
```

The benchmark scripts (`scripts/bench`, `scripts/bench-regression`,
`scripts/bench-rpc`) are manual tools, not part of the suites; see
[Performance](docs/performance.md).

## Getting started

Add the packages (Hex: `thrift_runtime`, `rebar3_thrift`; or the
checkout equivalents) and declare the IDL in `rebar.config`:

```erlang
{plugins, [rebar3_thrift]},
{deps, [thrift_runtime]},
{thrift, [{files, ["src/ping.thrift"]}]},
{provider_hooks, [{pre, [{compile, {default, thrift}}]}]}
```

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

`rebar3 compile` generates `ping_api_types.erl`/`ping_api_types.hrl`
plus `ping_api_ping_client/server/handler` (the namespace prefix
`ping.api` becomes `ping_api`; see
[Namespaces](docs/generator.md#namespaces)). Generation can also run
from the library or the standalone CLI — see the
[Generator reference](docs/generator.md).

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

poke() -> ok.
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

Calls answer `ok` for a void or oneway result, `{ok, Value}` for a
non-void reply and `{error, {exception, ...}}` for a declared
exception — generated, dynamic and reconnecting callers alike. Every
`start_link` option (transports, protocols, timeouts, TLS, pooling,
multiplexing, observability, graceful drain) and its exact validation
errors are documented in
[RPC and operations](docs/rpc.md).

## Encode, decode and convert

The generated types module is the normal entry point: `Type` selects
the schema (the snake-cased IDL name, no namespace prefix), the
options map carries the axes. Decoding the same `PingRequest` bytes in
the four representations — only the record needs its hrl include, the
maps and the native record need nothing:

```erlang
{ok, Req}    = ping_api_types:decode(ping_request, Bin),                    %% record (the default)
{ok, Map}    = ping_api_types:decode(ping_request, Bin, #{repr => map}),    %% plain atom-key map
{ok, Struct} = ping_api_types:decode(ping_request, Bin, #{repr => struct}), %% tagged map
{ok, Native} = ping_api_types:decode(ping_request, Bin, #{repr => native}), %% EEP-79 (OTP 29+)
```

The value each binding carries:

```erlang
Req = #ping_api_ping_request{message = <<"hi">>},
Map = #{message => <<"hi">>},
Struct = #{__struct__ => ping_api_ping_request, message = <<"hi">>},
%% Native is a native record: pattern-matching it takes a compiled
%% -record declaration, reading it takes nothing:
<<"hi">> = records:get(message, Native).
```

Encoding accepts any representation and auto-detects it — every form
encodes back to the same bytes:

```erlang
{ok, Bin} = ping_api_types:encode(ping_request, Req),
{ok, Bin} = ping_api_types:encode(ping_request, Map),
{ok, Bin} = ping_api_types:encode(ping_request, Struct),
{ok, Bin} = ping_api_types:encode(ping_request, Native).
```

`convert/3` reshapes typed values without touching bytes — the type is
explicit, so the value's own tag is never consulted:

```erlang
{ok, Map} = ping_api_types:convert(ping_request, Req, map),
{ok, Req} = ping_api_types:convert(ping_request, Struct, record).
%% map-mode structs (erl.struct_type = "map") have no record to
%% produce: the record target answers {error, {no_record, Tag}} in
%% convert/3 and decode alike.
```

Every protocol rides the same options vocabulary — `binary` (the
default), `compact`, `json`, or any module implementing the
`thrift_runtime_protocol` behaviour:

```erlang
{ok, Compact} = ping_api_types:encode(ping_request, Req, #{protocol => compact}),
{ok, Req} = ping_api_types:decode(ping_request, Compact, #{protocol => compact}),
{ok, Json} = ping_api_types:encode(ping_request, Req, #{protocol => json}),
{ok, Req} = ping_api_types:decode(ping_request, Json, #{protocol => json}).
```

The options map is validated, not silently ignored — unknown keys,
bad values and non-map arguments answer strict `{error, _}` terms —
and decoding is strict: trailing bytes answer `{error, trailing}`,
truncation `{error, truncated}`. Hand-written descriptors, the
advanced runtime facade, streaming codecs and custom protocols are
documented in [Advanced codecs](docs/advanced-codecs.md).

## Representations and protocols

Structs live in two independent axes. The **protocol** axis picks the
wire format (`binary`, `compact` and `json` are built in; any
`thrift_runtime_protocol` module plugs in). The **representation**
axis (`thrift_runtime:repr()`) picks the in-process shape:

- `record` — the generated record (the default for plain structs);
- `map` — plain atom-key maps matching the IDL field names;
- `struct` — `#{__struct__ => Tag, Field => Value, ...}`, the tagged
  map that survives round-trips without record definitions in scope;
- `native` — EEP-79 native records (OTP 29+): a real datatype minted
  from the struct descriptor, no compiled definitions needed to read
  it (`records:get/2`, `records:get_name/1`, ...). Older releases
  answer `{error, {unsupported_repr, native}}`.

The representation of a struct can also be pinned in the IDL with
`erl.struct_type = "map"` — values become maps at the wire boundary in
clients, servers and codecs. Unions can be sum types (`erl.union_type
= "sum"`), sets can decode into `sets`/`ordsets` (`erl.set`), typedefs
can be `-nominal` (`erl.type`) and enum member atoms can be lowercased
(`erl.enum_case`); the full annotation set, precedence rules and
namespaces live in the
[Generator reference](docs/generator.md#codegen-annotations).

## References

- [Generator reference](docs/generator.md) — library/CLI/plugin
  commands, generation axes and precedence, namespaces, annotations,
  naming, check/clean.
- [Advanced codecs](docs/advanced-codecs.md) — descriptors, the
  advanced runtime facade, representations in depth, streaming,
  custom protocols, introspection, internal codec boundaries.
- [RPC and operations](docs/rpc.md) — client/server/reconnecting
  options and errors, lifecycle and drain, transports and HTTP,
  pooling, observability, multiplexing, TLS.
- [Performance](docs/performance.md) — benchmark method, existing
  measurements, regression commands.
- [Public API migration](docs/public-api-migration.md) — every old
  call shape mapped to its replacement.

## License

Apache License 2.0. The lexer/parser are derived from Apache Thrift
(Pinterest, 2017) with attribution preserved; the vendored fixture
`vendor/apache-thrift-erl` is Apache Thrift 0.25.0 (see
`vendor/apache-thrift-erl/README-VENDORED.md`).
