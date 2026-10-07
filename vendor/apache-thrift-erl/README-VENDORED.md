# Vendored: Apache Thrift Erlang library (golden-interop test fixture)

Upstream: Apache Thrift, `lib/erl` from the official source release
**0.25.0**.

- Source tarball: `https://archive.apache.org/dist/thrift/0.25.0/thrift-0.25.0.tar.gz`
- SHA-256: `66da4707214c54c94bac082103dc67adaf9e08925662700f269170a7b534b214`
- License: Apache License 2.0 (see `LICENSE`, `NOTICE` in this directory).

Used **only** by the test profile as the golden reference for wire-format
interop tests (`thrift_golden_SUITE`): our client against the official
runtime's server and vice versa, on buffered and framed transports. It is
never a dependency of the generator or of `thrift_erl` in production
profiles.

The companion `ThriftTest.thrift` in this directory is the same file that
ships with the 0.25.0 tarball. The generated code checked in under
`apps/thrift_generator/priv/golden/gen-erl` was produced
by the pinned official compiler 0.25.0 (`thrift --gen erl`) from the
same file minus the `uuid` base type (which the official Erlang generator
does not support); the variant lives next to the generated code as
`apps/thrift_generator/test/thrift_golden_SUITE_data/ThriftTest.thrift`
(in the golden suite data dir) and is what both interop
sides are generated from. Codegen and runtime
versions must move together.

## Local modifications (kept minimal, documented here)

- OTP 29 compatibility patches: old-style `catch Expr` is deprecated and
  scheduled for removal, so every use is rewritten to an equivalent
  `try ... catch` (throw passes through, error/exit become `{'EXIT', _}`,
  normal returns behave identically):
  - `src/thrift_socket_transport.erl`: the factory's
    `catch gen_tcp:connect(...)`.
  - `src/thrift_sslsocket_transport.erl`: `catch ssl:handshake(...)`,
    `catch gen_tcp:connect(...)` and `catch ssl:connect(...)` in the
    factory, plus `catch gen_tcp:close(...)`.
  - `src/thrift_reconnecting_client.erl`: `catch thrift_client:call/3`
    in `handle_call`, the best-effort `catch thrift_client:close/1` and
    `catch thrift_client_util:new/4` in `try_connect/1`.
  - `src/thrift_socket_server.erl`: `catch gen_tcp:accept/1` in
    `acceptor_loop/1`.

Everything else — including `src/thrift.app.src` — is shipped as-is
(0.25.0 already removed `erlang:get_stacktrace/0`, `ssl:ssl_accept/2` and
`disk_log:lclose/1` usages).

Do not refactor or "improve" vendored code — the value of the golden
reference is that it stays recognizably upstream.
