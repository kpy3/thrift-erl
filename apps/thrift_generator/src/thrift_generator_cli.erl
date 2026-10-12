%% Copyright 2026 Sergei Yelin
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(thrift_generator_cli).

-moduledoc """
Command-line front end (escript entry point).

```
thrift_generator <file.thrift> [-o <out_dir>] [--repr record|map|native] [--check]
thrift_generator generate <file.thrift> [-o <out_dir>] [--repr record|map|native] [--check]
```

Argument parsing rides on the stdlib `argparse` module (usage/help
included); `generate` stays accepted as an optional subcommand — the
file operand selects the action. Runs the full pipeline (load with
includes, semantic analysis, emit) and writes the generated Erlang
sources to `out_dir` (default: the current directory). `--repr` picks
the value representation generated for definitions without an explicit
`erl.struct_type` annotation (`record`, the default, `map` or
`native`). `--check` verifies instead of writing: every generated
artifact must already exist in `out_dir` with the exact content this
input would produce — drift (missing or stale files) exits 1, so the
flag works as a CI freshness gate.

Errors render as rebar3/elp-style source excerpts (the offending line
under a gutter, a `╰──` marker naming the problem); `--compact-errors`
switches to one-line `path:line: message` entries. The rendering is
shared with the rebar3 plugin through `format_error/1`.
""".

-export([main/1]).
-export([format_error/1]).

-define(PROGNAME, "thrift_generator").

-spec main([string()]) -> no_return().
main(RawArgs) ->
    Args =
        case RawArgs of
            ["generate" | Rest] -> Rest;
            _ -> RawArgs
        end,
    Options = #{progname => ?PROGNAME},
    %% argparse has no built-in help switch, and a required positional
    %% would win over `-h', so `file' is optional in the spec and both
    %% the help request and its presence are checked here.
    case argparse:parse(Args, command(), Options) of
        {ok, Parsed, _Path, _Cmd} ->
            case maps:get(help, Parsed, false) of
                true ->
                    io:put_chars([argparse:help(command(), Options), $\n]),
                    halt(0);
                false ->
                    run_parsed(Parsed, Options)
            end;
        {error, Reason} ->
            parse_error(argparse:format_error(Reason), Options)
    end.

-spec run_parsed(argparse:arg_map(), #{progname => string()}) -> no_return().
run_parsed(#{file := File} = Parsed, _Options) ->
    OutDir = maps:get(out_dir, Parsed, <<".">>),
    Repr = maps:get(repr, Parsed, record),
    Resolver =
        case maps:get(compact_errors, Parsed, false) of
            true -> fun(_Path) -> {error, compact_errors} end;
            false -> auto
        end,
    case maps:get(check, Parsed, false) of
        true -> check(File, OutDir, Repr, Resolver);
        false -> run(File, OutDir, Repr, Resolver)
    end;
run_parsed(_Parsed, Options) ->
    parse_error("missing <file.thrift> operand", Options).

-spec parse_error(unicode:chardata(), #{progname => string()}) -> no_return().
parse_error(Message, Options) ->
    io:format(standard_error, "error: ~ts~n~ts~n", [
        Message, argparse:help(command(), Options)
    ]),
    halt(1).

-spec command() -> argparse:command().
command() ->
    #{
        arguments => [
            #{
                name => help,
                short => $h,
                long => "-help",
                type => boolean,
                help => ["print this help and exit"]
            },
            #{
                name => file,
                %% Positional arguments are required by default in
                %% argparse; `-h' must stay answerable without one.
                required => false,
                help => {"<file.thrift>", ["IDL document to compile"]}
            },
            #{
                name => out_dir,
                short => $o,
                long => "-out-dir",
                type => binary,
                default => <<".">>,
                help => {"[-o <out_dir>]", ["directory for generated .erl files (default: .)"]}
            },
            #{
                name => repr,
                long => "-repr",
                type => {atom, [record, map, native]},
                default => record,
                help =>
                    {"[--repr record|map|native]", [
                        "representation for definitions without an explicit"
                        " erl.struct_type annotation (default: record)"
                    ]}
            },
            #{
                name => check,
                long => "-check",
                type => boolean,
                help => [
                    "verify the generated sources are up to date instead"
                    " of writing; exits 1 on drift (missing or stale files)"
                ]
            },
            #{
                name => compact_errors,
                long => "-compact-errors",
                type => boolean,
                help => [
                    "print errors as one-line path:line: message entries"
                    " instead of the default source-excerpt blocks"
                ]
            }
        ]
    }.

run(File, OutDir, Repr, Resolver) ->
    case thrift_generator:generate(File, OutDir, #{repr => Repr}) of
        {ok, Generated} ->
            io:format("Generated ~b module(s) in ~ts:~n", [
                length(Generated), unicode:characters_to_list(OutDir)
            ]),
            lists:foreach(
                fun(#{path := Path} = Entry) ->
                    io:format("  ~ts~n", [unicode:characters_to_list(Path)]),
                    case Entry of
                        #{hrl := Hrl} when Hrl =/= undefined ->
                            io:format("  ~ts~n", [unicode:characters_to_list(Hrl)]);
                        _ ->
                            ok
                    end
                end,
                Generated
            ),
            halt(0);
        {error, Reason} ->
            io:format(standard_error, "~ts~n", [thrift_generator_diagnostic:format(Reason, Resolver)]),
            halt(1)
    end.

check(File, OutDir, Repr, Resolver) ->
    case thrift_generator:check(File, OutDir, #{repr => Repr}) of
        ok ->
            io:format("~ts: generated sources are up to date in ~ts~n", [
                unicode:characters_to_list(File), unicode:characters_to_list(OutDir)
            ]),
            halt(0);
        {error, {stale, Paths}} ->
            io:format(standard_error, "~ts~n", [thrift_generator_diagnostic:format({stale, Paths}, Resolver)]),
            halt(1);
        {error, Reason} ->
            io:format(standard_error, "~ts~n", [thrift_generator_diagnostic:format(Reason, Resolver)]),
            halt(1)
    end.

%% The rendering itself lives in thrift_generator_diagnostic — the CLI
%% and the rebar3 plugin share one formatter.

format_error(Reason) ->
    thrift_generator_diagnostic:format(Reason).
