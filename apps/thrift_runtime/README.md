# thrift_runtime

The runtime library of [thrift-erl](https://github.com/kpy3/thrift-erl):
everything Thrift-compatible generated code needs at run time —
protocols, transports, a client, a server and the representation
engine — with no dependencies beyond kernel and stdlib.

Wire compatibility with the stock Apache Thrift implementation is
tested, not assumed: golden interop against the official Erlang
runtime on all three protocols, over buffered, framed and HTTP
transports, multiplexed services included.

## Add to your project

```erlang
%% rebar.config
{deps, [thrift_runtime]}.
```

In the common case you never call the runtime directly: generate
Erlang code from your Thrift IDL with the
[`thrift_generator`](https://hex.pm/packages/thrift_generator) package
(or the [`rebar3_thrift`](https://hex.pm/packages/rebar3_thrift)
plugin) and use the generated modules — specialized codecs, typed
clients, servers and handler behaviours. The generated code depends on
this package and nothing else.

A taste of the generated surface — the type-first codec facade, then
the RPC client:

```erlang
%% codecs: the type atom selects the schema, the options map the axes
{ok, Bin} = ping_api_types:encode(ping_request, #ping_api_ping_request{message = <<"hi">>}),
{ok, Map} = ping_api_types:decode(ping_request, Bin, #{repr => map}),
{ok, Rec} = ping_api_types:convert(ping_request, Map, record),
{ok, Compact} = ping_api_types:encode(ping_request, Rec, #{protocol => compact}),

%% RPC: typed client against a generated server module
{ok, Server} = ping_api_ping_server:start_link(#{port => 9090, handler => ping_handler}),
{ok, Client} = ping_api_ping_client:start_link(#{host => "127.0.0.1", port => 9090}),
{ok, Reply} = ping_api_ping_client:ping(Client, #ping_api_ping_request{message = <<"hi">>}),
%% a declared exception comes back typed:
{error, {exception, #ping_api_no_such_message{}}} =
    ping_api_ping_client:ping(Client, #ping_api_ping_request{message = <<"bad">>}),
ok = ping_api_ping_client:stop(Client),
ok = ping_api_ping_server:stop(Server).
```

A void or oneway call answers the bare atom `ok`, a non-void call
`{ok, Value}` and a declared exception `{error, {exception, ...}}` —
for generated, dynamic and reconnecting callers alike. Handlers answer
`ok` for void/oneway and `{ok, Value}` otherwise; anything else is an
unsupported result (`INTERNAL_ERROR` + one `handler_error` event) and
the wire payload never changes. Generated clients export an unlinked
`start/1` beside `start_link/1` for pool workers.

For hand-written schemas and dynamic work the runtime exposes the same
contract with explicit descriptors:
`thrift_runtime:encode(Desc, Value[, Options])`,
`thrift_runtime:decode(Desc, Binary, #{repr := Repr})` and
`thrift_runtime:convert(Desc, Value, Repr)`. See
[docs/public-api-migration.md](https://github.com/kpy3/thrift-erl/blob/master/docs/public-api-migration.md)
for the old → new call tables.

## What the package provides

- **Protocols**: `binary`, `compact` and `json` — or your own module
  implementing the `thrift_runtime_protocol` behaviour.
- **Transports**: `framed`, `buffered` and `http`, over TCP or TLS.
- **Client**: one connection per process, queued calls, per-call
  timeouts, statistics; a reconnecting wrapper with backoff for
  pool-style deployments.
- **Server**: a supervisor with an acceptor and per-connection
  processes, graceful drain, multiplexed services, max-frame and
  max-connection limits.
- **Representations**: records (default), plain atom maps, tagged
  struct maps or EEP-79 native records — selectable per struct,
  uniform all the way down, convertible without touching bytes.
- **A generic codec engine** driven by hand-written struct
  descriptors, for introspection and wire work without generated
  code; generated modules feed it via `struct_info/1`, `enum_info/1`
  and `function_info/2`.
- **Observability**: crash-isolated `on_event` callbacks on clients,
  servers and connections.

See the [repository README](https://github.com/kpy3/thrift-erl) for
the full guide: options, protocol and transport details, pooling, TLS,
multiplexing and performance.

## License

Apache-2.0 — see
[LICENSE.md](https://github.com/kpy3/thrift-erl/blob/master/LICENSE.md).
