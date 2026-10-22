# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.1] — 2026-10-22

A codec-performance cycle. Ref-descriptor dispatch stops probing per
call, nested same-module references call their sibling codecs directly
instead of paying a full runtime dispatch, and the specialized JSON
codecs get a flatter encode chain and a single-clause decode dispatch.
The wire format, error semantics and the public API are unchanged: the
PropEr equivalence batteries (specialized vs generic, byte for byte on
all three protocols) and the golden interop suite guard every step.
The full gate is green on both OTP 28 and 29.

### Runtime (`thrift_runtime`)

- Ref-descriptor dispatch is cache-first. The first use of a generated
  module's codecs still probes and warms a `persistent_term` map, but
  every later call reads that map locally in the protocol module and
  invokes the target function directly — no hop through
  `thrift_runtime_protocol:codec/4`, which ablation measured at
  roughly a quarter of a dispatch call. That module remains the cold
  path (first use, probe miss, reload), and the stale-codec recovery
  (`undef` → `codec_stale/3` → re-probe → generic) is unchanged.

### Generator (`thrift_generator`)

- Same-module struct references emit a direct sibling call in the
  binary and compact codecs. The locality test compared the reference
  module atom against the binary module key and never fired, so every
  nested reference inside one file took the full runtime dispatch —
  the benchmark's `Insanity` struct makes about a hundred of them per
  operation. Binary encode of `Insanity` goes from 24.1 to 38.6 K/s;
  the JSON emitter had this right from the start.
- The JSON decode dispatch is a single clause per (id, tag) pair, and
  the decode body that the runtime dispatch calls by name is exported
  explicitly — a missing export used to silently disable the
  specialized JSON codecs (the fallback is byte-identical, so only the
  engaged-codec test and the bench could tell).
- The JSON encode chain accumulates chunks in reverse (one
  `lists:reverse` at the top; every chunk carries its own separator)
  and the base types fold their type check into guard clauses with the
  payload placed directly — about 8% faster, roughly 1.4× the generic
  engine on the same payloads.

### Performance

- README numbers re-measured on OTP 29 (an OTP 28 run confirms the
  ratios) after this cycle: 4.6–8.3× on binary, 2.6–5.9× on compact,
  10.1–16.8× on JSON encode and 1.1–1.5× on JSON decode against the
  official 0.25.0 Erlang runtime; the specialized codecs sit at
  0.9–1.5× of the generic engine across the matrix. No adopted change
  measured slower than what it replaced, and every row improved
  against the numbers this cycle started from. Three rows remain a few
  percent below the absolutes published with 0.6.1 (binary Xtruct
  encode, compact Xtruct2 encode, JSON Xtruct2 decode) — absolute
  throughput is machine- and day-dependent, the same-run speedup
  ratios are the meaningful axis.
- Measured and rejected, each rolled back by its own gate and recorded
  here so nobody pays for the experiment twice: caching external funs
  instead of MFA atoms (±0–6% with a flipping sign — the BEAM
  call-site export-entry cache erases the difference); flattening the
  compact encode chain into straight-line functions (5–10% slower
  than the chain — transition calls are noise next to payload work);
  a JSON decode pipeline without the name thread (strictly less
  bookkeeping, yet a stable −10% on JSON decode — a BEAM code-layout
  effect, not extra work).
- The bench script prints the specialized column first and labels its
  axes honestly: the specialized path is a ref-descriptor dispatch, the
  generic path is an inline descriptor with per-process memo.

## [0.7.0] — 2026-10-21

### All applications

- The runtime application is renamed to `thrift_runtime` ahead of the
  first hex.pm release: `thrift_erl` is already taken on the registry.
  Module names change with it (`thrift_erl_client` →
  `thrift_runtime_client` and so on); the wire format, public APIs and
  behaviour are unchanged.
- All three packages are wired for hexdocs.pm: rebar3_ex_doc runs as
  the hex doc provider from each package directory (`rebar3 ex_doc`
  is the local dry-run), every package carries its own README, and
  `scripts/hex-prepublish` copies the project CHANGELOG/LICENSE into
  the package directories before `rebar3 hex build`/`publish`. Doc
  glitches the docs pipeline surfaced are fixed along the way: broken
  `t:` type references, old-style `` `X' `` quoting that renders as
  unclosed backquotes (runtime sources and the codec index doc
  templates the generator emits), and a `%% @moduledoc` comment block
  in `thrift_runtime_json` that never reached the compiled docs chunk.

## [0.6.1] — 2026-10-13

A consolidation release. The server's specific `handshake_timeout`
option now actually reaches the accept loop it was documented for; the
generic JSON engine validates unions exactly like binary, compact and
the specialized codecs; README catches up with the generator and runtime
as they are; and the three protocol modules share their cold-path
plumbing instead of carrying three copies. The full gate is green on
both OTP 28 and 29.

### Runtime (`thrift_runtime`)

- The acceptor's connection-options whitelist silently dropped
  `handshake_timeout`: a server setting the specific key (without the
  `timeout` umbrella) ran TLS handshakes at the 5000 ms default. The key
  now passes the whitelist, and a regression test asserts end to end
  that it reaches the accept loop.

- The generic JSON engine's union validation now matches binary, compact
  and the specialized codecs: a map with one declared field plus extra
  undeclared keys encodes (undeclared keys are ignored, as every
  struct-kind always did) instead of answering `union_multiple`, and a
  map whose only key matches no declared field answers `union_empty`
  instead of encoding an empty union object that would not survive a
  re-encode.

- The codec probe (`binary_codec`/`compact_codec`/`json_codec` dispatch
  to the specialized per-struct codecs) and the union/required
  field-presence checks live in `thrift_runtime_protocol` once instead of
  three near-identical copies (~200 lines). The `persistent_term` cache
  key still names the protocol module and the probe still takes its funs
  fresh from the module on every call.

### Documentation

- README catches up: the specialized per-struct codecs exist on every
  protocol (the Performance section still described them as binary-only),
  the four invocation option axes (`--repr`, `--union-type`, `--set`,
  `--typedef-type`) are documented for both the CLI and the rebar3
  plugin, the `service` option (plus `max_queue_depth` and `name`) joins
  the start_link option list, the codegen-annotation catalogue grows
  `erl.union_type = "sum"` and `erl.struct_type = "native"` and documents
  the meaningful `key_type = "binary"`, and the representations section
  says everything once instead of twice.

### Generator (`thrift_generator`)

- Dead code out — unused exports (`thrift_runtime_binary:type_id/1`,
  `thrift_runtime_options:backlog/1`, `record_mode/1`), an inert `-doc` on
  the unexported `sources/2`, the write-only `erl` fields of four model
  records — followed by behavior-preserving simplifications: one
  `mode/1` dispatch instead of four three-boolean products, a shared
  namespace-default helper, direct map lookups, and a comments pass
  (history narration out, displaced blocks re-attached, `-doc` gaps
  filled).

### Testing and tooling

- The ssl suite's plain-client case no longer flakes the teardown the
  same way the server-events test did: the failed call stops the client
  (its design), so the after-block's bare stop races the client's death
  and raises `exit:noproc` on loaded runners; it now goes through the
  suite's quiet-stop helper like every other case with a client
  expected dead.

## [0.6.0] — 2026-10-12

Schema-shape freedom: the generator accepts legal, common Thrift it
used to reject — field atoms shared by several sum unions, same-named
methods across services of one file — and cross-module references
resolve by the included file's base name, the Apache Thrift spelling.
The invocation-wide option axes grow from one (`--repr`) to four and
reach the rebar3 plugin, which finally honors `repr` too. The CI gate
is clean on both OTP 28 and 29.

### Generator (`thrift_generator`)

- Three new invocation-wide option axes next to `--repr`, each applying
  only where the IDL carries no explicit annotation of its own (an
  explicit annotation wins, and a file-wide namespace default
  `erl.set` / `erl.union_type` beats the option for its file):
  `--union-type record|sum` materializes `erl.union_type` on unannotated
  unions, `--set list|sets|ordset` materializes `erl.set` on unannotated
  sets, and `--typedef-type alias|nominal` materializes `erl.type` on
  unannotated typedefs (the API map keys: `union_type`, `set`,
  `typedef_type`). The rebar3 plugin grows the same four axes (including
  the previously unplumbed `repr`) as `{thrift, [{repr, ...}, ...]}`
  config entries, validated with a rendered `{bad_opt, _}` error instead
  of a raw crash, and `check/3` treats them like `--repr`: artifacts
  count as stale unless regenerated with the exact same options.

- Several sum unions of one module may share a field name — legal,
  common Thrift (per-resource result unions) that the generator wrongly
  rejected with a `duplicate sum union field` error. The semantic no
  longer rejects the collision: every union's own encode/decode stays
  exact, and the module-level context-free `convert/3` resolves a
  shared atom to the last union declaring it (the generated `tag_index`
  doc spells this out), so a foreign union's value under a shared atom
  fails its payload type check loudly rather than converting silently.

- Same-named methods across two services of one file no longer break
  the generated code (per-service `GetEvents` is ordinary Thrift): the
  types module's name-keyed `function_info/2` keeps the last
  declaration's clauses instead of emitting duplicates that fail
  compilation under `warnings_as_errors`, and every generated client
  embeds its own service's params/reply/exceptions descriptors instead
  of resolving them through that table — a collision used to hand a
  client another service's descriptor, mis-encoding the wire.

- Cross-module references resolve under the Apache Thrift spelling:
  the dotted qualifier is the **included file's base name**
  (`include "payment_resource.thrift"` makes
  `payment_resource.PaymentResource` references), which previously only
  worked by coincidence — when the target's `namespace erl` value
  happened to equal its base name. Both spellings now always resolve,
  the base-name one and the module-key one; the generated descriptors
  and remote types point at the real types module of the target file.
  Two included files sharing a base name (different directories) leave
  the first module in the qualification index — such a reference is
  ambiguous in Apache Thrift too, and the module-key spelling still
  resolves exactly.

### Testing and tooling

- A teardown race in the server-events test no longer flakes the CI:
  the client stops itself when the socket closes (its design), so the
  after-block's cleanup stop can race the client's death and raise
  `exit:noproc` on loaded runners; the guard catches exactly that and
  nothing else.

## [0.5.0] — 2026-10-12

A name of its own and sharper edges: the project is **thrift-erl**,
generated service modules carry the file's prefix (no more cross-file
name collisions), declared exceptions surface as typed answers on the
client, IDL errors point at the exact column with a rendered source
excerpt, and the plugin can sweep generated files on project clean.
The CI gate is clean on both OTP 28 and 29.

### Breaking changes

- Generated service modules carry the file's identifier prefix and the
  snake-cased service name: `Ping` in `namespace erl ping.api` now
  generates `ping_api_ping_client` / `ping_api_ping_server` /
  `ping_api_ping_handler` instead of `'Ping_client'` / `'Ping_server'` /
  `'Ping_handler'` — same-named services of different IDL files no
  longer collide. Regenerate and update `-behaviour` and `service`
  references.
- Declared exceptions answer `{error, {exception, Value}}` on the
  generated client, and handlers signal them the same way: the value's
  representation — record tag, `__struct__` map, native record or
  sum-union tuple — identifies the exception. The explicit-name form
  `{error, {exception, Name, Value}}` stays valid for hand-written
  descriptors and map-representation exceptions (plain maps carry no
  identity) and remains the raw `thrift_runtime_client:call/4` wire-level
  shape.

### Project

- Renamed the project **thrift-erl**, after the flagship runtime
  library `thrift_runtime`: it has been a full Thrift stack for Erlang
  (IDL compiler, runtime, rebar3 plugin) for a while, not just a
  generator. Application and module names are unchanged — `thrift_runtime`
  is baked into all generated code and stays the public contract. The
  README now opens with a "Why over the official Apache Thrift
  runtime" summary.

### rebar3 plugin (`rebar3_thrift`)

- Generated sources can now be removed on project cleanup:
  `rebar3 thrift clean` deletes every `.erl`/`.hrl` in the configured
  out dir carrying the generator's `Autogenerated by Thrift Generator`
  banner (so orphans of removed services or deleted IDL files go too,
  and hand-written files stay), and
  `{provider_hooks, [{post, [{clean, {thrift, clean}}]}]}` in the
  consumer's `rebar.config` hooks the same cleanup into `rebar3 clean`.
  A missing out dir is a no-op, not an error.

### Generator (`thrift_generator`)

- Located errors (lexer/parser and semantic findings) render as
  rebar3/elp-style source excerpts by default — the offending line
  under a gutter, a `╰──` marker naming the problem. Positions are
  exact: the scanner threads `{Line, Column}` pairs through tokens,
  AST nodes and the semantic model, so the marker sits on the exact
  column (codepoint-counted, tab stops expanded like the scanner's)
  and the compact form reads `path:line:column: message`. Unreadable
  sources and unlocated errors fall back to the compact
  `path:line[:column]: message` line, which is also what the new
  `--compact-errors` CLI switch forces; the rebar3 plugin renders
  through the same formatter.
- The generated client and handler module docs word the boundary per
  the representations the service actually passes — `records`, `maps`,
  `native records`, `tagged tuples` for sum unions, or a neutral
  clause on a mix — instead of always claiming records under
  `--repr map`/`native`. Services over no struct-typed types carry no
  boundary sentence at all.
- Generated modules put an empty line between top-level definitions
  (`-type` blocks, `struct_info`/`enum_info`/`function_info`, codecs) —
  `-spec`/`-callback` contracts and `-doc` comments stay flush with
  their definition. `-doc`/`-moduledoc` strings are wrapped at word
  boundaries within 80 columns instead of erl_prettypr's mid-word
  cuts, so `` `start_link/1` ``-style references stay whole. Regenerate
  to pick the new layout up (`check/3` flags the drift).
- IDL keywords are accepted as field names, matching Apache Thrift
  0.18+ (THRIFT-5626): `1: i32 oneway` names the field `oneway`.
  Function, const, enum and type names keep the plain-identifier rule,
  as upstream.
- `required` in a `throws` clause is rejected by the semantic pass
  (`throw field X cannot be required`), matching Apache Thrift 0.18+
  (THRIFT-5669); `optional` and the default requiredness stay valid.

## [0.4.0] — 2026-10-11

Specialized codecs for every protocol, an observability surface, and
the operational niceties pools ask for: graceful drains, per-worker
statistics and event callbacks. The bench now measures what generated
code actually runs.

### Generator (`thrift_generator`)

- Specialized compact wire codecs: per struct `encode_<X>_compact/1` /
  `decode_<X>_compact/1` with the generic engine's byte-for-byte error
  semantics (declaration-order missing-required on encode,
  ascending-id on decode, `varint` returning `[Byte | Rest]` so the
  term shape — and with it the map-key sort order — stays identical),
  plus a `compact_codec/1` index keyed by the wire struct name.
  Equivalence is pinned by PropEr (roundtrip and prefix properties on
  both protocols) and a hand-computed negative battery.
- Specialized JSON wire codecs: the same contract with the `_json`
  suffix and a `json_codec/1` index. The envelope's closing `]` folds
  only at top-level entry points: the pair's decode side is the
  non-folding struct body, `thrift_runtime_json:decode/2` applies the
  fold, and the new `thrift_runtime_json:decode_nested/2` serves generated
  cross-module references fold-free (nested same-module references
  are local `_body` calls). Map keys outside the JSON object model
  (uuid, struct, list, set, map) answer constant `type_not_supported`
  errors even when the map is empty; uuid values under a supported
  key fail at the pair level.
- Plugin: `rebar3 thrift --check` (and the CLI `--check` flag)
  verifies that the generated sources are fresh — the same pipeline
  without writing, answering `{error, {stale, Paths}}` on drift.
  `write_all` skips unchanged files, so regeneration no longer bumps
  mtimes of identical outputs (no spurious recompiles).

### Runtime (`thrift_runtime`)

- Observability callbacks: the `on_event` option (absent, a 1-arity
  fun, or `{M, F, A}` with the event appended to the arguments) on the
  client, the reconnecting wrapper (passed down to its child) and the
  server (whitelisted through the acceptor into every connection).
  Dispatch is synchronous in the emitting process and crash-isolated;
  the default absent-handler path costs one pattern match and builds
  no event map. Events: `call_ok` / `call_error` — exactly one per
  caller-facing answer, counters matching `get_stats`; `connected` /
  `connect_failed` / `disconnected` on the wrapper's connection axis;
  `connection_open` / `connection_closed` / `handler_error` (handler
  crashes and unsupported results only — declared exceptions are
  protocol answers, not errors) on the server side. The option is
  validated at start, not at the first emit.
- Graceful server stop: `stop(Server, #{drain => Timeout})` closes
  the listen socket, tells every live connection to finish its
  in-flight request and exit, and answers `ok` once no connections
  remain or the deadline passes. The deadline never fails a call; a
  connection stuck past it is reaped by the supervised stop.
- Client statistics: `get_stats/1` and `get_and_reset_stats/1` report
  `#{calls_ok, calls_failed}` per worker — the same accounting the
  reconnecting wrapper aggregates, without the connection axis. A
  pending call closed by a connection failure counts as failed (the
  funnel covers terminate and queue-failure paths too).
- The reconnecting wrapper's and the server's `start_link` shield the
  caller from the failed-init exit race (the same trapping dance the
  plain client already did): a bad option answers `{error, Reason}`
  instead of killing the caller with the child's exit signal after
  the answer arrived.
- Server stop works on OTP 28 again: `supervisor:stop/1` only exists
  from OTP 29 on, so `thrift_runtime_server:stop/1` (and the drain path of
  `stop/2`) stops the supervisor as the gen_server it is —
  `gen_server:stop(Server, normal, infinity)`, waiting so a busy
  connection answers its in-flight request before its own shutdown.

### Testing and tooling

- The eunit output stays readable on negative tests: the suites that
  start intentionally-bad clients, wrappers and servers quiet the
  primary logger with level `none` (SASL crash reports log at level
  `error`, so the previous `error` level passed them straight through
  to the CI log), and the bad-option observability test silences too.
- Both toolchains analyze the native axis cleanly. Elvis parses raw
  sources without the preprocessor, so on an OTP-28 toolchain it
  cannot resolve the OTP-29 builtin `record()` in exported specs —
  `thrift_runtime_native` now exports the spec-level alias
  `native_record()` (opaque; `record()` on 29, `term()` on 28)
  instead. Dialyzer on 28 keeps the facade's native arms alive the
  same way: the release stubs answer through the unfoldable
  `supported()` rather than literals, and `native_to_wire/3` is
  preprocessor-split per release with the stub keeping the signature
  and raise contract.
- The elp lint gate fails on findings: the wrapper filters
  `--severity warning` out of the pinned release's JSON (elp itself
  always exits 0) and runs the deterministic `--no-connect` mode, the
  same one CI uses.
- CI publishes a coverage report; the README gained a
  differences-from-Apache section.
- PropEr properties for compact and JSON join the binary ones:
  roundtrip, prefix (always-`more` for binary and compact,
  never-completing for JSON) and representation conversion, plus deep
  batteries that run all three protocols.
- The codec benchmark measures the specialized path for all three
  protocols (ref descriptors through the codec probes) against the
  official runtime, and adds a generic-vs-specialized block per case —
  inline descriptor (the generic interpreter with its per-process
  schema memo) against the ref descriptor — with a byte-equality gate
  between the two paths before any timing.

## [0.3.0] — 2026-10-10

Generated code that reads like it was written: typed records and
IDL-named aliases, section comments, snake_case identifiers, and a
banner that carries the generator version. Unions can now be sums, the
target representation is a generator-level option, and IDL text is
UTF-8 end to end.

### Generator (`thrift_generator`)

- Typed generated code: every named definition exports its original IDL
  name as a type alias (`-type 'Invoice'()`, `-type 'Color'()`);
  records carry field types, with every non-required field `Type |
  undefined` (optional and default) and required fields bare; map-mode
  structs alias their shape with exact (`:=`) and associative (`=>`)
  fields; typedefs alias their target (`-nominal` under
  `erl.type = "nominal"`); enum members alias the atom union. Type
  definitions moved from the `.hrl` into `<mod>_types.erl`; the include
  keeps typed record declarations and constant macros only.
- Banner on every generated `.erl` and `.hrl`:
  `%% Autogenerated by Thrift Generator (<version>)` … `DO NOT EDIT`,
  with the version taken from the running application and blank lines
  separating each section comment from the code.
- Section comments: every struct, union, exception and enum block — the
  record/type forms in both files and the codec function groups —
  opens with a divider naming the IDL construct (`%% Struct Invoice`).
- Readable identifiers: derived names go through a snake_case pass
  (`InvoiceBankAccount` generates `domain_invoice_bank_account` and
  `encode_domain_invoice_bank_account`), constant functions snake-case
  too and macros uppercase the whole prefixed name (`DEMO_KIND_VALUE`).
  With no `namespace erl` the file base name becomes the prefix, so
  same-named structs of namespace-less files cannot collide.
- Sum unions: `erl.union_type = "sum"` (per union or as a
  `namespace erl *` default) drops the record — the value is
  `{FieldAtom, Value}`, so the exactly-one-field invariant holds by
  construction and is dialyzer-visible. The wire format is unchanged,
  and the sum representation is repr-invariant: all four views keep
  the tagged tuple and convert only the payload.
- `repr` option: `#{repr => record | map | native}` (CLI `--repr`,
  default `record`) materializes the chosen representation onto every
  struct and exception without an explicit `erl.struct_type`; an
  explicit annotation still wins. `native` generates no record
  declarations at all — `record_fields/1` exports `{native, Tag}`
  keyed by the snake-cased wire name, the same identity the runtime
  mints native records under.
- UTF-8 end to end: the IDL file is decoded once as UTF-8 — doc
  comments and string constants no longer double-encode, and invalid
  input answers `{error, {invalid_utf8, Path}}` instead of a cryptic
  lexer failure. Printable const binaries emit UTF-8 string segments
  instead of byte lists.
- The redundant `-compile([nowarn_unused_record])` is gone from the
  types modules: every declared record is referenced by its exported
  alias, so the modules compile clean under `warnings_as_errors`
  without the suppression.

### Runtime (`thrift_runtime`)

- Sum-union support: `record_fields/1` understands the
  `{sum, [FieldAtoms]}` mode and `tag_index` keys by field atoms.
  Decoding an empty or multi-field union raises `{invalid_union, Map}`,
  encoding a value that matches no field raises
  `{value_does_not_match_type, V}`.
- `thrift_runtime_names` mirrors the generator's snake_case pass, so native
  record tags, `tag_index` keys and map-mode `__struct__` tags agree
  with the generated identities.
- The specialized-codec cache stores only the fact of an export (not
  the funs), so eunit module reloads no longer serve purged funs.

## [0.2.0] — 2026-10-10

Specialized wire codecs, a file-wide set default, and the parser fixes
that make real-world official IDL documents parse: `#` comments in
every position, merged doc blocks, and cross-module typedef
references.

### Generator (`thrift_generator`)

- Specialized binary wire codecs emitted into `<mod>_types.erl`:
  per struct, `encode_<X>_wire/1` (wire map to iodata) and
  `decode_<X>_wire/1` (binary to `{ok, WireMap, Rest} | more |
  {error, _}`) with byte-for-byte the generic engine's error
  semantics, plus a `binary_codec/1` index keyed by the wire struct
  name. Required knowledge is decided at emit time — only required
  fields pay the keydelete and missing-scan clauses — so small structs
  are the win (Xtruct encode 18 vs 33 reductions/op, decode 16 vs 24)
  while deep payloads like Insanity stay at parity, dispatch
  amortizing over the walk.
- Parser: the official IDL's comment forms in every position — `#`
  line comments (still text inside string literals, the string rule
  wins on length), doc comments before `include`/`namespace`, a
  dangling doc at end of input, and consecutive doc blocks merged
  into one doc token, as the official compiler does.
- Emitter: cross-module references to typedefs resolve. A qualified
  name landing on an included file's `typedef` used to die with
  `{unresolved_type, Mod, Name}` at descriptor build time; the alias
  now resolves in its defining module's context, keeping refs inside
  the typedef body home while the result lands in the referencing
  module's descriptor.
- CLI: arguments parsed with the stdlib `argparse` module (shipped
  inside stdlib since OTP 28, so no new dependency), and the CLI gains
  `-h/--help`.
- Sets: a `namespace erl` (or `namespace *`) header may carry
  `erl.set = "sets" | "ordset"` as the file-wide default, injected
  into every set type of the document (the `erl` scope wins over the
  wildcard); record defaults of set-typed fields are wrapped in the
  impl constructor. The global default stays `list` — parity with
  Apache is on the wire. Writing `erl.set` after the name is now a
  semantic error instead of a silently ignored annotation.

### Runtime (`thrift_runtime`)

- Specialized-codec dispatch: named struct references probe the
  generated `binary_codec/1` export (hits and misses cached) and fall
  back to the generic engine when it is absent; `skip_by_wire/2` is
  exported for the generated skip clauses.
- Set implementations: the record engine covers `list`, `ordset` and
  `sets` end to end in both directions, including nested sets.

## [0.1.0] — 2026-10-09

Initial release. An alternative Apache Thrift IDL generator and the
`thrift_runtime` runtime library for Erlang/OTP 28+. Generated code is
binary-compatible with the stock Apache Thrift implementation (verified
both ways by golden interop tests against the official 0.25.0 Erlang
runtime) and depends only on `thrift_runtime` — kernel and stdlib, no
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

### Runtime (`thrift_runtime`)

- Three wire protocols built in — `binary`, `compact` (zigzag varints,
  delta-encoded field ids, nibble-packed type tags) and `json` (the
  Apache JSON wire format) — resolved through the `thrift_runtime_protocol`
  behaviour, so any module can plug into every `protocol` slot.
- Four in-process representations behind one facade
  (`thrift_runtime:encode/decode/convert`): `record` (generated records),
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
- Codec benchmark (`scripts/bench`, erlperf): `thrift_runtime` against the
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
