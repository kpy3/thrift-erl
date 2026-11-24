# Advanced codecs reference

The complete contract for working below the generated facade: explicit
descriptors, the advanced runtime facade, every value representation,
streaming codecs, custom protocol modules, introspection and the
internal codec boundaries. The [root README](../README.md) covers the
normal path (the generated type-first facade); this document owns the
rest. Old call shapes are mapped in
[Public API migration](public-api-migration.md).

## Descriptor types

The descriptor and protocol vocabulary is owned by one module:
`thrift_runtime_protocol` exports `type_desc()`, `field_desc()`,
`struct_desc()`, `enum_desc()`, `struct_value()`, `base_type()`,
`message_type()`, `application_exception()` and the parameterized
`decode_result(Value)`. Spell every descriptor type through that
module in specs and source.

The protocol implementations keep only their private compiled
descriptor types (`c_type()` in `thrift_runtime_binary`, `k_type()` in
`thrift_runtime_compact`, `j_type()`/`j_struct()` in
`thrift_runtime_json`); no other module may reference them.

## The generated facade

Every generated `<mod>_types` module exposes the type-first codec
facade. `Type` selects the schema — the snake-cased IDL name, no
namespace prefix (`ping_request`, `bank_account`); both the canonical
type atom and the wire name are accepted by `struct_info/1`. The
options map carries the axes:

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

Details worth knowing: a field absent on the wire is absent from the
maps (the record carries `undefined` in its slot instead), and the
`__struct__` tag is the same record tag the record repr uses.

Encoding accepts any representation and auto-detects it — every form
encodes back to the same bytes:

```erlang
{ok, Bin} = ping_api_types:encode(ping_request, Req),
{ok, Bin} = ping_api_types:encode(ping_request, Map),
{ok, Bin} = ping_api_types:encode(ping_request, Struct),
{ok, Bin} = ping_api_types:encode(ping_request, Native).
```

The options map is validated, not silently ignored. `encode/3` accepts
exactly `protocol` (default `binary`) and `strict` (default `false`);
`decode/3` accepts exactly `protocol` and `repr` (absent `repr` falls
back to the struct's schema-selected default). Unknown keys answer
`{error, {unknown_option, Key}}`; a non-map options argument answers
`{error, {bad_option, {options, Value, [map]}}}` — there are no
positional protocol or repr forms; an unknown type atom answers
`{error, {unknown_type, Type}}` everywhere the facade resolves it
(options are validated before the type is resolved). `strict => true`
fails a map/struct-map input carrying keys that match no declared
field (`{error, {unknown_fields, Keys}}`) instead of dropping them
silently:

```erlang
{error, {unknown_fields, [extra]}} =
    ping_api_types:encode(ping_request, #{message => <<"hi">>, extra => 1}, #{strict => true}).
```

Decoding is strict: trailing bytes answer `{error, trailing}`,
truncation `{error, truncated}`. A value that matches no
representation answers `{error, {value_does_not_match_type, Value}}`
from every entry point.

Other protocols ride the same options vocabulary:

```erlang
{ok, Compact} = ping_api_types:encode(ping_request, Req, #{protocol => compact}),
{ok, Json} = ping_api_types:encode(ping_request, Req, #{protocol => json}).
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

The representation of a struct can also be pinned in the IDL with
`erl.struct_type = "map"` — values become maps at the wire boundary in
clients, servers and codecs (keys are atoms by default;
`erl.struct_type.map.key_type = "binary"` keeps wire keys). See the
[Generator reference](generator.md#codegen-annotations).

## The advanced runtime facade

For hand-written schemas and dynamic work the runtime exposes the same
contract with an explicit descriptor instead of the type atom. The
descriptor shape is the one `struct_info/1` returns; `descriptor/1` on
the generated module hands out named-ref descriptors directly:

```erlang
{ok, Desc} = ping_api_types:descriptor(ping_request),
{ok, Bin} = thrift_runtime:encode(Desc, Req),
{ok, Map} = thrift_runtime:decode(Desc, Bin, #{repr => map}),
{ok, Struct} = thrift_runtime:convert(Desc, Map, struct).
```

Differences from the generated facade: the advanced `decode/3`
requires the `repr` option — there is no schema module to infer a
default from, so a missing one answers `{error, {missing_option,
repr}}` — and the advanced `convert/3` takes the descriptor instead of
the type atom. Everything else — option keys, error terms, strict
decoding, the one-pass fast path — is identical. `encode/2` (binary
protocol) and the `protocol_module/1` / `repr_supported/1` helpers are
unchanged.

A tag-index map is not a descriptor: passing one to `convert/3` crashes
as the programming error it is, exactly like any other invalid
descriptor.

## Representations in depth

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

Conversion is type-directed: the value's record tag, `__struct__` key
or native identity is never consulted, so a field atom shared across
unions resolves to the type you named, not to the last union declaring
it.

Native records keep the representation uniform all the way down: a
nested struct decodes into a native record of its own, and a native
record encodes back to the same bytes as the tuple record would. The
runtime mints values dynamically (no `-record #` declarations are
emitted), so pattern matching one requires declaring `-record #name{}`
in the consumer — reading through the `records` module needs nothing:

```erlang
{ok, Req} = ping_api_types:decode(ping_request, Bin, #{repr => native}),
<<"hi">> = records:get(message, Req),
{ok, Bin} = ping_api_types:encode(ping_request, Req).   %% auto-detected
```

## The built-in protocols

### Binary

`thrift_runtime_binary` implements the Apache binary wire format — the
default everywhere.

Streaming and framing stay on the protocol modules, below the facade:
`thrift_runtime_binary:decode/2` answers `{ok, WireMap, Rest} | more |
{error, _}` so transports can feed partial buffers, and the
socket/framing layer (`thrift_runtime_socket:extract_message/4`) builds
frames and buffered messages on top.

### Compact

`thrift_runtime_compact` implements the Apache compact wire format:
zigzag varint integers, delta-encoded field ids, nibble-packed type
tags and collections whose header carries the element type. Every
`protocol` slot accepts the atom `compact` — clients, servers, the
facade and the generated codecs all resolve it through
`thrift_runtime:protocol_module/1` the same way as `binary`:

```erlang
{ok, Bin} = ping_api_types:encode(ping_request, Req, #{protocol => compact}),
{ok, Req, <<>>} = thrift_runtime_compact:decode(ping_api_types:struct_info(<<"PingRequest">>), Bin).
```

The same values take up to ~2.5× fewer wire bytes than binary on
container-heavy structs (see [Performance](performance.md)). Booleans
ride in the field header nibble; `uuid` is the one Thrift type the
compact format cannot carry and is rejected at encode/decode time.
Interop with the stock Apache runtime is covered in both directions:
the golden suite runs the official compact client
(`thrift_client_util:new(..., [{protocol, compact}])`) against our
compact server on both transports, and the benchmark proves the
official reader accepts our compact bytes struct by struct.

### JSON

`thrift_runtime_json` implements the Apache JSON wire format: a
message is the array `[1,"name",type,seqid,payload]`, a struct is an
object keyed by field id where every value is a one-key object naming
the type (`{"1":{"i32":5}}`), a list or set is `["i32",2,1,2]`, and a
map is an object with stringified keys (`["i32","i32",2,{"1":10}]`).
Every `protocol` slot accepts the atom `json` exactly like the other
built ins:

```erlang
{ok, Bin} = ping_api_types:encode(ping_request, Req, #{protocol => json}),
{ok, Req, <<>>} = thrift_runtime_json:decode(ping_api_types:struct_info(<<"PingRequest">>), Bin).
```

Two bends are documented on the module: the envelope's closing bracket
is folded into the top-level struct decode (which keeps the buffered
transport's completeness probe byte-exact), and map keys are limited
to what a JSON object key can carry — booleans, numbers, strings,
enums — while a struct-keyed map and `uuid` are refused by encode and
decode alike. Interop with the stock Apache runtime is covered in both
directions: the golden suite runs the official JSON client
(`thrift_client_util:new(..., [{protocol, json}])`) against our JSON
server on both transports, and the benchmark proves the official
reader accepts our JSON messages struct by struct.

## Custom protocol modules

Any module implementing the `thrift_runtime_protocol` behaviour plugs
into every `protocol` slot — the facade's `protocol` option, client
and server options — resolved through `thrift_runtime:protocol_module/1`,
which verifies the callback set. A protocol value that does not
resolve answers the axis' own `{error, {bad_protocol, Value}}` from
every entry point.

## Introspection

The generated modules carry introspection in the spirit of the
official generator: `struct_info/1` (inline descriptor, accepting the
canonical type atom or the wire name), `enum_info/1`, `function_info/2`,
`service_info/0` and `record_fields/1` in `<mod>_types.erl`.
`record_fields/1` is exported for the runtime's representation
dispatch and classified internal; the schema facade
`encode/decode/convert/descriptor` is the documented entry point.

Record-mode structs also generate a companion `<mod>_types_repr.erl`
with direct representation converters `repr_to_wire_<name>/1` /
`repr_from_wire_<name>/2` (literal field atoms, no descriptor walk)
registered in its `repr_index/1`; `thrift_runtime_record` dispatches
through it for tuple-record `to_wire` and `from_wire`. Map-shaped
`to_wire` keeps the descriptor's faster `maps:from_list` path. The
converters live outside the types module on purpose — generated-code
layout is a measured performance variable. Sum unions, map-mode and
native-mode structs get no converters and keep the descriptor engine.

## Internal codec boundaries

These modules and exports are internal: exported because the runtime
and generated code dispatch through them, but not a stable public
contract — call the facade instead of these.

- Generated per-struct wire codecs: `binary_codec/1`, `compact_codec/1`,
  `json_codec/1` hand out the `encode_<name>_wire/1`,
  `decode_<name>_wire/1`, `encode_<name>_compact/1`,
  `decode_<name>_compact/1`, `encode_<name>_json/1`,
  `decode_<name>_json/1` pairs, `binary_repr_codec/2`, `record_fields/1`
  and the `<mod>_types_repr` converters. They are classified
  `-doc false` in the generated modules.
- `thrift_runtime_record` — the representation engine
  (`to_wire/2`, `from_wire/2`), concerned only with values and
  representations.
- `thrift_runtime_rpc` — the RPC conversion boundary (call arguments
  and whole call results between the handler representation and the
  wire): `args_to_wire/2`, `args_from_wire/2`, `result_to_wire/3` and
  `call_result_from_wire/3`, plus the declared-exception lookup those
  operations use. Generated typed clients and the runtime connection
  call it directly. The RPC surface is documented in
  [RPC and operations](rpc.md).
- The generic engine — the interpreter the facade falls back to for
  hand-written descriptors and custom protocol modules, and the
  equivalence reference the PropEr suite pins the specialized codecs
  to byte-for-byte.
