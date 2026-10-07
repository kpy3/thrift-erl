# thrift-generator

An alternative Apache Thrift generator and runtime library for Erlang.
It takes Thrift IDL and generates Erlang code for types, clients and
servers that is binary-protocol compatible with the stock Apache Thrift
implementation (verified both ways by golden interop tests against the
official 0.25.0 runtime over buffered and framed transports).

## Layout

```
apps/thrift_generator/   IDL parser (leex/yecc), semantics, emitter, CLI
apps/thrift_erl/         runtime: binary protocol, transports, server, client
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
```

## CLI

```
rebar3 as prod escriptize
_build/prod/bin/thrift_generator generate my_api.thrift -o src
```

This generates `<mod>_types.erl` (one per IDL file) and three modules
per service: `<Svc>_client.erl`, `<Svc>_server.erl`, `<Svc>_handler.erl`.

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

Handler (records are declared in `<mod>_types.erl`; names are the
struct names lowercased):

```erlang
-module(ping_handler).
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
- server: `port`, `handler`, `max_frame_size`, `max_connections`,
  `timeout`, `backlog`;
- client: `host`, `port`, `recv_timeout`.

## Codegen annotations

- `erl.struct_type = "map"` — emit the struct as a map
  (plus `erl.struct_type.map.key_type = "atom"` for atom keys);
  the default is records;
- `erl.type = "nominal"` on a typedef — `-nominal` instead of an alias;
- `erl.*` annotations are filtered out at parse time, all others are
  preserved.

Introspection in the spirit of the official generator: `struct_info/1`,
`enum_info/1`, `function_info/2`, `record_fields/1`, `service_info/0`
in `<mod>_types.erl`.

## License

Apache License 2.0. The lexer/parser are derived from Apache Thrift
(Pinterest, 2017) with attribution preserved; the vendored fixture
`vendor/apache-thrift-erl` is Apache Thrift 0.25.0 (see
`vendor/apache-thrift-erl/README-VENDORED.md`).
