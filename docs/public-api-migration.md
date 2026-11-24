# Public API migration

The public codec API and the generator tooling API are finalized as
one coherent surface each. This guide maps every old call shape to its
replacement. There are no compatibility shims: the transitional forms
were removed in the same release that introduced the options maps and
the type-first facade.

## Generator tooling (`thrift_generator`, CLI, `rebar3_thrift`)

Every frontend — the library, the standalone CLI and the rebar3
plugin — now feeds one validated options map: `out_dir` (default
`"src"`) plus the five axes (`repr`, `union_type`, `set`,
`typedef_type`, `enum_case`). Validation runs through a single
normalizer, so a bad option fails everywhere with the same reason:
`{error, {unknown_option, Key}}` for an unknown key and `{error,
{bad_option, {Key, Value, Allowed}}}` for a bad value (a non-map
options argument answers `{error, {bad_option, {options, Value,
[map]}}}`).

### Library

| Removed | Replacement |
|---|---|
| `generate(File, OutDir)` (positional out dir) | `generate(File, #{out_dir => OutDir})` |
| `generate(File, OutDir, Opts)` | `generate(File, Opts#{out_dir => OutDir})` |
| `check(File, OutDir)` (positional out dir) | `check(File, #{out_dir => OutDir})` |
| `check(File, OutDir, Opts)` | `check(File, Opts#{out_dir => OutDir})` |

`generate/1` and `check/1` are the same operations with every default
(`out_dir => "src"`); `clean/1` is unchanged. The parser-level helpers
`tokens/1`, `ast/1`, `parse_file/1` and `parse_string/1` stay exported
— the loader pipeline and the test suites call them — but they are
internal, not a stable public contract.

### CLI

| Removed | Replacement |
|---|---|
| `thrift_generator <file.thrift> [-o dir]` (implicit generate) | `thrift_generator generate <file.thrift> [-o dir]` |
| `thrift_generator --check <file.thrift> [-o dir]` | `thrift_generator check <file.thrift> [-o dir]` |

The commands are explicit: a bare file operand, an implicit
`generate` and the `--check` flag are rejected with the usage banner,
not remapped. `clean` (`thrift_generator clean [-o dir]`) is new in
this release. The flag set is unchanged and `-o` defaults to `src`.

### rebar3 plugin

| Removed | Replacement |
|---|---|
| `{bad_opt, {Key, Value, Allowed}}` provider error | the shared `{bad_option, {Key, Value, Allowed}}` reason, and `{unknown_option, Key}` for a config typo — rendered exactly like the CLI prints it |

`{thrift, [...]}` keeps its shape — the host-only `files` key plus the
same keys as the options map — and the hooked clean provider now
validates `out_dir` through the shared contract before deleting.

## Generated `<mod>_types` modules

Every struct, union and exception is selected by its canonical type
atom — the snake-cased IDL name, without the namespace prefix
(`Outer`, `bank_account`). The facade is module-level, so it no longer
carries per-struct IDL doc text.

| Removed | Replacement |
|---|---|
| `encode_<name>(Value)` | `encode(Type, Value)` |
| `encode_<name>(Value, Protocol)` | `encode(Type, Value, #{protocol => Protocol})` |
| `decode_<name>(Binary)` | `decode(Type, Binary)` |
| `decode_<name>(Binary, Repr)` | `decode(Type, Binary, #{repr => Repr})` |
| `decode_<name>(Binary, Repr, Protocol)` | `decode(Type, Binary, #{protocol => Protocol, repr => Repr})` |
| `<name>_from_map(Map)` | `decode(Type, Binary, #{repr => map})` on the wire, or `convert(Type, Value, map)` on a value |
| `convert(Value, Repr)` (tag-index inference) | `convert(Type, Value, Repr)` (explicit type) |
| `tag_index/0` | `descriptor(Type)` returns the named-ref descriptor directly |

The option maps are validated, not silently ignored:

- `encode/3` accepts exactly `protocol` (default `binary`) and `strict`
  (default `false`);
- `decode/3` accepts exactly `protocol` (default `binary`) and `repr`
  (default: the struct's schema-selected representation);
- unknown keys answer `{error, {unknown_option, Key}}`, a missing
  `repr` on the advanced runtime facade answers
  `{error, {missing_option, repr}}`, a non-boolean `strict` answers
  `{error, {bad_option, {strict, Value, [true, false]}}}`;
- a non-map options argument answers
  `{error, {bad_option, {options, Value, [map]}}}` instead of being
  treated as a positional protocol or repr;
- an unknown type atom answers `{error, {unknown_type, Type}}`
  everywhere the facade resolves it; when the same call also carries a
  non-map options argument, the `{error, {bad_option, {options, Value,
  [map]}}}` answer takes precedence — options are validated before the
  type is resolved.

Conversion is type-directed: the value's record tag, `__struct__` key
or native identity is never consulted. The old shared-sum-atom
ambiguity (a field atom shared across unions resolved to the last
union declaring it) disappears because the type is always explicit:

```erlang
%% before
{ok, Map} = ping_api_types:convert(Req, map),
%% after
{ok, Map} = ping_api_types:convert(ping_request, Req, map).
```

`strict => true` on `encode/3` checks a map/struct-map input against
the struct's declared fields and fails with
`{error, {unknown_fields, Keys}}` instead of dropping unknown keys.

The introspection exports are unchanged and remain advanced-public:
`struct_info/1`, `enum_info/1`, `function_info/2`, `service_info/0`.
Enum helpers (`<name>_to_int/1`, `<name>_from_int/1`), type aliases and
constant functions keep their shapes.

## Advanced `thrift_runtime` facade

The runtime facade is the same contract with explicit descriptors
instead of the type atom — for hand-written schemas, dynamic work and
custom protocol modules. It no longer has any transitional entry
points.

| Removed | Replacement |
|---|---|
| `encode(Desc, Value, Protocol)` (positional protocol) | `encode(Desc, Value, #{protocol => Protocol})` |
| `encode(Desc, Value, Protocol, Opts)` (`encode/4`) | `encode(Desc, Value, #{protocol => Protocol, strict => Strict})` |
| `decode(Desc, Binary, Repr)` (positional repr) | `decode(Desc, Binary, #{repr => Repr})` |
| `decode(Desc, Binary, Repr, Protocol)` (`decode/4`) | `decode(Desc, Binary, #{protocol => Protocol, repr => Repr})` |
| `convert(TagIndex, Value, Repr)` (tag-index map) | `convert(Desc, Value, Repr)` with the value's type descriptor |
| `thrift_runtime:tag_index/0` (exported type) | — (descriptors are values; `descriptor/1` on generated modules hands them out) |

Notes:

- `decode/3` requires the `repr` option: the advanced facade has no
  schema module to infer a default from (the generated facade fills the
  schema default for you).
- A tag-index map is not a descriptor: passing one to `convert/3`
  crashes as the programming error it is, exactly like any other
  invalid descriptor.
- `encode/2` (binary protocol) and the `protocol_module/1` /
  `repr_supported/1` helpers are unchanged.

## Source-level type references

The descriptor types are owned by the protocol behaviour module:
`thrift_runtime_protocol` exports the whole vocabulary (`type_desc()`,
`field_desc()`, `struct_desc()`, `enum_desc()`, `struct_value()`,
`base_type()`, `message_type()`, `application_exception()` and the
parameterized `decode_result(Value)`). Spell them through that module
where source used to reference the binary or record aliases:

| Old | New |
|---|---|
| `thrift_runtime_binary:type_desc()` (and the other descriptor types) | `thrift_runtime_protocol:type_desc()` |
| `thrift_runtime_binary:decode_result(Value)` | `thrift_runtime_protocol:decode_result(Value)` |
| `thrift_runtime_record:type_desc()` / `field_desc()` / `struct_desc()` | `thrift_runtime_protocol:type_desc()` / `field_desc()` / `struct_desc()` |

The protocol implementations keep only their private compiled
descriptor types (`c_type()` in `thrift_runtime_binary`, `k_type()` in
`thrift_runtime_compact`, `j_type()`/`j_struct()` in
`thrift_runtime_json`); no other module may reference them.

Endpoint `protocol` options (client, server/acceptor, connection and
reconnecting client) are typed `thrift_runtime:protocol()`: `binary`,
`compact`, `json` or a custom module implementing the
`thrift_runtime_protocol` behaviour.

## RPC results and generated client starts

The RPC result contract is the same shape on both ends of the wire:
`ok` for void and oneway, `{ok, Value}` for a non-void reply,
`{error, {exception, ...}}` for a declared exception. There are no
compatibility shims — the old void shape `{ok, undefined}` is
unsupported, not silently translated on the handler side. The wire
payload is unchanged throughout: a void function has no success field,
so `ok` is exactly the previous empty result struct, byte for byte.

### Client-side results

| Old | New |
|---|---|
| `{ok, undefined}` from a void call — plain, generated or reconnecting | `ok` (still a success for the reconnecting wrapper's statistics, still no reconnection) |
| `ok` from a oneway call | unchanged (`ok`) |
| `{ok, Value}` from a non-void call | unchanged |
| `{error, {exception, ...}}` declared exception answers | unchanged |
| `{error, {application_exception, ...}}` and transport errors | unchanged |

The normalization happens in the shared runtime client, so generated
typed clients, `thrift_runtime_client:call/4` and
`thrift_runtime_reconnecting_client:call/4` all answer the same
shapes, on every protocol and transport. The representation-conversion
seam keeps one compatibility mapping:
`thrift_runtime_record:call_result_from_wire(undefined, Exceptions,
{ok, undefined})` normalizes the legacy void shape to `ok` (and `ok`
passes through unchanged), so hand-written descriptor users see the
same contract.

### Handler results

| Old | New |
|---|---|
| `{ok, undefined}` from a void handler | `ok` |
| `{ok, undefined}` (or anything but `ok`) from a oneway handler — silently ignored | exactly `ok`; anything else is unsupported |
| `ok` from a void or oneway handler — treated as unsupported | `ok` (valid) |
| `{ok, Value}` from a non-void handler | unchanged |
| `{error, {exception, ...}}` declared-exception answers | unchanged |

An unsupported handler result — including the old void `{ok,
undefined}` — is answered exactly like any other invalid result: a
request/response call gets `TApplicationException` `INTERNAL_ERROR`
plus one `handler_error` event (`reason => {bad_result, Result}`), a
oneway call emits the event only. The HTTP oneway acknowledgement is
unchanged, and `thrift_runtime_record:result_to_wire(undefined,
Exceptions, ok)` preserves the void mapping for hand-written
descriptor users.

### Generated client `start/1`

Generated `<prefix>_<svc>_client` modules now export an unlinked
`start/1` beside `start_link/1`. It takes the same options map, with
`service` inserted exactly as for `start_link/1`, and delegates to
`thrift_runtime_client:start/1` — same ownership and monitor
semantics as `start_link/1` minus the link. It is the pool-worker
entry for generated clients, matching the runtime client's
`start/1`; nothing is removed.

## Internal entries (unchanged behavior, hidden from the docs)

The runtime dispatches through generated internals; they stay exported
but are classified `-doc false` in the generated modules:
`binary_codec/1`, `compact_codec/1`, `json_codec/1`,
`binary_repr_codec/2`, every direct `encode_<name>_wire/1`,
`decode_<name>_wire/1`, `encode_<name>_compact/1`,
`decode_<name>_compact/1`, `encode_<name>_json/1`,
`decode_<name>_json/1`, `record_fields/1` and the `<mod>_types_repr`
converters. Call the facade instead of these.

## Constants

Constants are arity-0 functions; the facade starts at arity 1, so a
constant may now be named `encode`, `decode`, `convert`, `descriptor`,
`tag_index` or like a removed wrapper (`encode_foo`, …). Semantic
analysis still rejects constants named like the generated enum helpers
(`<enum>_to_int`, `<enum>_from_int`).
