# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-10-09

Initial release. An alternative Apache Thrift IDL generator and the
`thrift_erl` runtime library for Erlang/OTP 28+. Generated code is
binary-compatible with the stock Apache Thrift implementation (verified
both ways by golden interop tests against the official 0.25.0 Erlang
runtime) and depends only on `thrift_erl` — kernel and stdlib, no
external dependencies. The generator itself is never a runtime
dependency.

### Generator (`thrift_generator`)

- Thrift IDL pipeline: leex/yecc lexer and parser → semantic analysis →
  emitter. Doc comments (`/** ... */`, `///`) are carried into the
  generated code as `-moduledoc` / `-doc`.
- Semantic validation: unresolved type and constant references, name
  collisions (record tags, enum value prefixes, constants against
  generated functions) and `erl.*` annotation values
  (`erl.struct_type`, `erl.struct_type.map.key_type`, `erl.set`).
- Output per IDL file: `<mod>_types.erl` plus a `<mod>_types.hrl`
  include; per service: `<Svc>_client.erl`, `<Svc>_server.erl` and the
  `<Svc>_handler.erl` behaviour.
- Per-struct codecs (`encode_x`, `decode_x`, `x_from_map`,
  `tag_index/0`, `convert/2`), per-enum int↔atom helpers, constants as
  zero-argument functions plus `-define` macros for scalars.
- Apache-compatible introspection: `struct_info/1`, `enum_info/1`,
  `function_info/2`; plus `record_fields/1`, `service_info/0`,
  `tag_index/0`, `convert/2` and `sources/1`.
- `namespace erl` / `namespace *`: names the generated modules and
  prefixes every generated identifier (record tags, type aliases,
  function names, macros), so same-named structs of different files
  coexist in one compilation. Wire names (`struct_info(<<"Point">>)`)
  and enum atoms stay untouched.
- Codegen annotations: `erl.struct_type = "map"` (with
  `erl.struct_type.map.key_type`), `erl.set = "sets" | "ordset"` and
  `erl.type = "nominal"` for typedefs. `erl.*` annotations are consumed
  by the generator; all other annotations are preserved.
- Distribution: a CLI escript (`thrift_generator generate my_api.thrift
  -o src`) and the `rebar3 thrift` plugin provider (`files` / `out_dir`,
  typically wired as a pre-compile hook).

### Runtime (`thrift_erl`)

- Three wire protocols built in — `binary`, `compact` (zigzag varints,
  delta-encoded field ids, nibble-packed type tags) and `json` (the
  Apache JSON wire format) — resolved through the `thrift_erl_protocol`
  behaviour, so any module can plug into every `protocol` slot.
- Four in-process representations behind one facade
  (`thrift_erl:encode/decode/convert`): `record` (generated records),
  `map` (atom-key maps), `struct` (tagged maps) and `native` (EEP-79
  native records, OTP 29+; older releases answer
  `{error, {unsupported_repr, native}}`). Encode auto-detects the
  input; decode is strict — trailing bytes answer `{error, trailing}`,
  truncation `{error, truncated}`.
- Transports: `buffered`, `framed` and `http` — one Thrift exchange per
  HTTP/1.1 request-response pair with keep-alive; a oneway gets an
  empty 200 response; Content-Length framing with body size caps on
  both ends.
- TLS on both ends: `ssl_opts` switches the socket to
  `ssl:listen`/`ssl:connect`; the handshake runs in the connect path
  under the configured timeouts, and a failed handshake closes the
  connection.
- Server: supervisor → acceptor → connection processes, event-driven
  `{active, N}` I/O (no passive recv loops), an idle timeout instead of
  recv timeouts, and `max_connections` / `max_frame_size` caps.
- Client: one connection per process with no automatic reconnection —
  any failure fails the outstanding calls and stops the process, which
  makes it a pool worker out of the box (unlinked `start/1`). Calls are
  serialized; the queue is bounded with enqueue-time deadlines;
  `stop/1` answers outstanding calls with `{error, closed}`.
- Reconnecting client wrapper: exponential backoff (`reconnect_min`
  doubling up to `reconnect_max`), fail-fast `{error, disconnected}`
  during an outage, and call statistics (`get_stats`,
  `get_and_reset_stats`) for pool health checks. Server-reported
  exceptions are protocol replies and never trigger a reconnect.
- Multiplexed services: several services on one port; `multiplex =>
  <<"Service">>` prefixes outgoing message names as
  `Service:function` (the Apache multiplexed convention). Dispatch is
  strict in multiplexed mode and liberal on a single-service server.

### Testing and tooling

- EUnit unit suites, Common Test end-to-end scenarios and PropEr codec
  properties.
- Golden interop suite against the vendored official Apache Thrift
  0.25.0 Erlang runtime, in both directions, over the buffered, framed
  and HTTP transports, in the binary, compact and JSON protocols,
  including the official multiplexed client.
- Codec benchmark (`scripts/bench`, erlperf): `thrift_erl` against the
  official runtime on the same ThriftTest payloads — binary, compact
  and JSON, encode and decode (numbers in the README).
- Quality gates in CI (OTP 28 and 29 matrix): compile with
  `warnings_as_errors`, elvis, hank, xref, dialyzer, EUnit, Common Test
  and elp lint.

### License

Apache License 2.0. The lexer and parser are derived from Apache Thrift
(Pinterest, 2017) with attribution preserved; the vendored golden
fixture is Apache Thrift 0.25.0 (see
`vendor/apache-thrift-erl/README-VENDORED.md`).
