# Generator reference

The complete contract of the IDL compiler: the library API, the
standalone CLI, the rebar3 plugin, what generation emits, and the
namespaces, annotations and naming rules that shape the output. The
[root README](../README.md) covers the normal path; this document owns
the rest. Old call shapes are mapped in
[Public API migration](public-api-migration.md).

## Library API

`thrift_generator` exports exactly `generate/1,2`, `check/1,2` and
`clean/1`; every frontend — library, CLI, plugin — feeds one validated
options map.

```erlang
{ok, _} = thrift_generator:generate("src/ping.thrift", #{out_dir => "src"}),
%% CI freshness gate: fails when artifacts are missing or stale:
ok = thrift_generator:check("src/ping.thrift", #{out_dir => "src"}),
%% sweep generated files, including ones orphaned by a deleted IDL:
{ok, _} = thrift_generator:clean("src").
```

The options map (`#{}` = all defaults) names the output directory
(`out_dir`, `"src"` by default) and carries five axes:

| key | values | default |
|---|---|---|
| `repr` | `record \| map \| native` | `record` |
| `union_type` | `record \| sum` | `record` |
| `set` | `list \| sets \| ordset` | `list` |
| `typedef_type` | `alias \| nominal` | `alias` |
| `enum_case` | `preserve \| lower` | `preserve` |

Each axis applies only where the IDL carries no explicit annotation of
its own. Precedence is strict and three-leveled, from weakest to
strongest:

1. the invocation default (an options entry or a CLI/plugin flag);
2. a file-wide annotation on the `namespace erl` (or `namespace *`)
   header;
3. an explicit per-definition annotation.

A stronger level always wins; nothing collapses or reorders them.
(`record` repr, `record` unions, `list` sets and `alias` typedefs
inject nothing — the annotation-free defaults stay as they are.)

Unknown keys and invalid values are returned as `{error,
{unknown_option, Key}}` / `{error, {bad_option, {Key, Value, Allowed}}}`
(a non-map options argument answers `{error, {bad_option, {options,
Value, [map]}}}`) before anything is written — the same terms the CLI
prints and the plugin renders.

The parser-level helpers (`tokens/1`, `ast/1`, `parse_file/1`,
`parse_string/1`) are not a public contract: they live on the internal
`thrift_generator_idl` module, which the loader pipeline and the test
suites call. The yecc-generated `thrift_parser` is likewise an
implementation module.

## Standalone CLI

A self-contained escript is attached to the GitHub releases; build one
from a checkout with:

```
rebar3 as prod escriptize
_build/prod/bin/thrift_generator generate my_api.thrift -o src
```

The commands are explicit — a bare file operand and the legacy
`--check` flag are rejected with the usage, not remapped:

- `thrift_generator generate <file.thrift> [flags]` — run the full
  pipeline and write the generated sources;
- `thrift_generator check <file.thrift> [flags]` — verify freshness
  instead of writing (see below);
- `thrift_generator clean [-o <out_dir>]` — delete the generated
  files from the out dir.

The full flag set for `generate` and `check`:

- `-h` / `--help` — print the usage and exit;
- `-o` / `--out-dir <dir>` — directory for the generated sources
  (default: `src`);
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
- `--enum-case preserve|lower` — the casing surfaced enum member atoms
  use (`erl.enum_case`) for enums without an explicit annotation
  (default: preserve);
- `--compact-errors` — one-line error entries (see below).

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

`check` verifies instead of writing: it fails (exit 1, listing the
drifted files) unless every generated artifact already exists in the
out dir with the exact content the IDL would produce — a CI freshness
gate. Freshness counts artifacts as stale unless they were generated
with the same option values.

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
    {typedef_type, alias}, %% alias | nominal
    {enum_case, preserve}  %% preserve | lower
]},

%% regenerate before every compilation:
{provider_hooks, [{pre, [{compile, {default, thrift}}]}]}
```

`{thrift, [...]}` keeps its shape — the host-only `files` key plus the
same keys as the options map. Every entry is validated by the
generator's own options contract: a config typo fails the provider
with the rendered `{unknown_option, Key}` error, an invalid value with
the rendered `{bad_option, {Key, Value, Allowed}}` error — the same
terms the library returns and the CLI prints — instead of a raw crash.

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
too, and anything not carrying the banner is left alone. The
configured out dir is validated through the same shared options
contract before anything is deleted. To delete on project cleanup,
hook the namespaced clean provider into `rebar3 clean`:

```erlang
{provider_hooks, [{post, [{clean, {thrift, clean}}]}]}
```

For local development the plugin is attached via `_checkouts/`:

```
mkdir -p _checkouts
ln -s /path/to/thrift-erl/apps/rebar3_thrift _checkouts/rebar3_thrift
ln -s /path/to/thrift-erl/apps/thrift_generator _checkouts/thrift_generator
```

## What generation emits

One `<mod>_types.erl` plus a `<mod>_types.hrl` include per IDL file
(the header declares typed records, record/enum aliases and constant
macros for scalars) and three modules per service —
`<prefix>_<svc>_client.erl`, `<prefix>_<svc>_server.erl`,
`<prefix>_<svc>_handler.erl`, where `<prefix>` is the file's
namespace-derived identifier prefix and `<svc>` is the snake-cased
service name (`Ping` in `namespace erl ping.api` generates
`ping_api_ping_client.erl` and friends). Files whose on-disk content
already matches are left untouched, so regenerating an unchanged IDL
does not churn mtimes.

Constants become zero-argument functions plus `-define` macros for
scalars; enums get `<enum>_to_int/1` / `<enum>_from_int/1` helpers.

## Namespaces

A `namespace erl` (or the `namespace *` fallback) does two things:

- names the generated modules (`namespace erl demo.widgets` →
  `demo_widgets_types.erl`, `demo_widgets_types.hrl`). If two files in
  one include graph claim the same namespace-derived module key, the
  collision group uses atom-safe normalized file basenames instead
  (`domain_config` → `domain_config_types` beside `domain_types`);
  identifier prefixes still share the namespace. If normalized
  basenames cannot make every key unique, loading fails with
  `duplicate_module` rather than choosing an arbitrary file;
- prefixes every generated identifier of the file — record tags, type
  aliases, derived helper names (`demo_widgets_color_to_int`),
  constant macros — so same-named structs of different files coexist
  once both hrl files land in one compilation. The value is
  normalized: lowercased, non-identifier runs collapsed to `_`, a
  leading digit guarded (`_2fast`); a value that normalizes to nothing
  is a load error. Wire names stay untouched:
  `struct_info(<<"Point">>)`, `enum_info(<<"Color">>)` and enum member
  atoms are exactly as declared, so the wire protocol contract does
  not move. Without an `erl`/`*` namespace nothing is prefixed (other
  scopes such as `namespace java` are not our naming concern).

## Codegen annotations

All annotations are `erl.*` keys; they are filtered out at parse time
and all others are preserved.

- `erl.struct_type = "map"` — emit the struct as a map (keys are
  atoms by default; `erl.struct_type.map.key_type = "binary"` keeps
  the wire's binary keys); the default is records;
- `erl.struct_type = "native"` — EEP-79 native records on OTP 29+
  (what the values look like is covered in
  [Advanced codecs](advanced-codecs.md));
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
  in-process term. The passthrough costs nothing and keeps
  hand-written 2-tuple descriptors intact, while `erl.set = "sets"`
  reproduces the official representation where wanted. The annotation
  sits after the whole `set<...>` type (on the field or the typedef —
  inside the angle brackets it would annotate the element). The same
  annotation on the `namespace erl` (or `namespace *`) header —
  `namespace erl my.service (erl.set = "sets")` — sets the file-wide
  default for every set in the document (the migration path from the
  official runtime's `sets:set()` representation); an explicit
  per-type annotation wins. Set-typed record defaults are wrapped in
  the constructor call (`sets:from_list([...])`) in the generated hrl
  and inline records. The wire encoding is identical for all three;
  records in the generated hrl get `sets:set(E)` / `ordsets:ordset(E)`
  types;
- `erl.record_name = "Name"` on a struct or exception — the verbatim
  record tag: the hrl record and `record_fields/1` key the struct by
  `Name` as written instead of the snake-cased struct name. This is
  the drop-in knob for codebases whose existing records carry the IDL
  casing verbatim (the official Erlang generator spells record tags
  exactly as the IDL does) — adopting this stack over a fork or over
  the official codegen then needs no value-transcoding layer at the
  term level. Rejected on a sum union (a sum type has no record to
  name) and on a native struct (native records mint their own tag);
- `erl.enum_case = "preserve" | "lower"` — the casing surfaced enum
  member atoms use: the `enum_info/1` pairs, the enum's type alias,
  the values constants and field defaults resolve to, and the
  generated `<mod>_<enum>_to_int/from_int` helpers. `lower`
  lowercases the declared member names (the official Erlang generator
  emits lowercase enum atoms); `preserve` keeps them verbatim.
  Per-enum annotation, or on the `namespace erl` (or `namespace *`)
  header as the file-wide default; the `--enum-case` flag / plugin
  option is the invocation default. Enum members travel as `i32` on
  the wire regardless, so the casing never moves a byte — only the
  atoms the code sees. Members of one enum that collide under the
  chosen casing (`X` and `x` under `lower`) fail generation with an
  explicit error: `to_int` could not tell them apart; members of
  different enums may share an atom freely;
- `erl.type = "nominal"` on a typedef — `-nominal` instead of an
  alias.

## Introspection

In the spirit of the official generator, every `<mod>_types.erl`
carries `struct_info/1`, `enum_info/1`, `function_info/2`,
`service_info/0` and `record_fields/1`. The schema facade
(`encode/decode/convert/descriptor`) is the documented entry point;
the direct codec entries stay exported for the runtime's dispatch but
are classified internal — see
[Advanced codecs](advanced-codecs.md#internal-codec-boundaries) for
that boundary.
