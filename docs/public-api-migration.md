# Public API migration

The public codec API is finalized as one coherent, type-first surface.
This guide maps every old call shape to its replacement. There are no
compatibility shims: the transitional forms were removed in the same
release that introduced the options maps and the type-first facade.

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
  everywhere the facade resolves it.

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
