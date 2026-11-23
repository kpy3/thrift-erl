# thrift_generator

The IDL compiler of [thrift-erl](https://github.com/kpy3/thrift-erl):
parses Thrift IDL, applies semantic checks and emits Erlang source —
wire codecs specialized per struct, typed clients, servers, handler
behaviours and introspection exports — binary-compatible with the
stock Apache Thrift implementation.

The generated `<mod>_types` module exposes a type-first codec facade —
`encode(Type, Value[, Options])`, `decode(Type, Binary[, Options])`,
`convert(Type, Value, Repr)` and `descriptor(Type)` — over the
specialized codecs; `struct_info/1`, `enum_info/1`, `function_info/2`
and `service_info/0` provide advanced introspection. The direct codec
entries stay exported for the runtime's dispatch but are classified
internal. Migrating from the per-struct wrappers of earlier releases?
See
[docs/public-api-migration.md](https://github.com/kpy3/thrift-erl/blob/master/docs/public-api-migration.md).

The generated code depends on
[`thrift_runtime`](https://hex.pm/packages/thrift_runtime) and nothing
else; this package is a build-time tool and never ships to production.

Most users meet this compiler through the
[`rebar3_thrift`](https://hex.pm/packages/rebar3_thrift) plugin, which
wraps it into `rebar3 thrift`. Use this package directly for
programmatic generation or scripting.

## Library use

```erlang
%% rebar.config
{deps, [thrift_generator]}.
```

```erlang
{ok, _} = thrift_generator:generate("src/ping.thrift", #{out_dir => "src"}),
%% CI freshness gate: fails when artifacts are missing or stale:
ok = thrift_generator:check("src/ping.thrift", #{out_dir => "src"}),
%% sweep generated files, including ones orphaned by a deleted IDL:
{ok, _} = thrift_generator:clean("src").
```

The options map (`#{}` = all defaults) names the output directory
(`out_dir`, `"src"` by default) and carries five axes, each applied
only where the IDL carries no explicit annotation of its own:
`#{repr => record | map | native, union_type => record | sum,
set => list | sets | ordset, typedef_type => alias | nominal,
enum_case => preserve | lower}`. Unknown keys and invalid values are
returned as `{error, {unknown_option, Key}}` / `{error, {bad_option,
{Key, Value, Allowed}}}` before anything is written.

## Standalone CLI

A self-contained escript is attached to the
[GitHub releases](https://github.com/kpy3/thrift-erl/releases) (or
build one from a checkout with `rebar3 as prod escriptize`):

```console
$ thrift_generator generate src/ping.thrift -o src
```

Errors render located rich blocks (line, caret on the exact column)
in the terminal; `--compact-errors` switches to `path:line[:col]`
records. The companion `thrift_generator check src/ping.thrift -o src`
verifies freshness instead of writing, and `thrift_generator clean -o
src` sweeps the generated files.

See the [repository README](https://github.com/kpy3/thrift-erl) for
the IDL language coverage, codegen annotations (`erl.*`) and the
generated-code contract.

## License

Apache-2.0 — see
[LICENSE.md](https://github.com/kpy3/thrift-erl/blob/master/LICENSE.md).
