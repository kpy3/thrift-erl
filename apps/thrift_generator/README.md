# thrift_generator

The IDL compiler of [thrift-erl](https://github.com/kpy3/thrift-erl):
parses Thrift IDL, applies semantic checks and emits Erlang source —
wire codecs specialized per struct, typed clients, servers, handler
behaviours and introspection exports — binary-compatible with the
stock Apache Thrift implementation.

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
ok = thrift_generator:generate("src/ping.thrift", "src", #{}),
%% CI freshness gate: fails when artifacts are missing or stale:
ok = thrift_generator:check("src/ping.thrift", "src", #{}),
%% sweep generated files, including ones orphaned by a deleted IDL:
ok = thrift_generator:clean("src").
```

The options map (`#{}` = defaults) carries four axes, each applied
only where the IDL carries no explicit annotation of its own:
`#{repr => record | map | native, union_type => record | sum,
set => list | sets | ordset, typedef_type => alias | nominal}`.

## Standalone CLI

A self-contained escript is attached to the
[GitHub releases](https://github.com/kpy3/thrift-erl/releases) (or
build one from a checkout with `rebar3 as prod escriptize`):

```console
$ thrift_generator -o src src/ping.thrift
```

Errors render located rich blocks (line, caret on the exact column)
in the terminal; `--compact-errors` switches to `path:line[:col]`
records, `--check` verifies freshness instead of writing.

See the [repository README](https://github.com/kpy3/thrift-erl) for
the IDL language coverage, codegen annotations (`erl.*`) and the
generated-code contract.

## License

Apache-2.0 — see
[LICENSE.md](https://github.com/kpy3/thrift-erl/blob/master/LICENSE.md).
