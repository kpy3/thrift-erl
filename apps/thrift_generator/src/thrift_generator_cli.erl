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
thrift_generator <file.thrift> [-o <out_dir>] [--repr record|map|native]
thrift_generator generate <file.thrift> [-o <out_dir>] [--repr record|map|native]
```

Argument parsing rides on the stdlib `argparse` module (usage/help
included); `generate` stays accepted as an optional subcommand — the
file operand selects the action. Runs the full pipeline (load with
includes, semantic analysis, emit) and writes the generated Erlang
sources to `out_dir` (default: the current directory). `--repr` picks
the value representation generated for definitions without an explicit
`erl.struct_type` annotation (`record`, the default, `map` or
`native`).
""".

-export([main/1]).
-export([format_error/1]).

-spec main([string()]) -> no_return().
main(RawArgs) ->
    Args =
        case RawArgs of
            ["generate" | Rest] -> Rest;
            _ -> RawArgs
        end,
    Options = #{progname => "thrift_generator"},
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
                    case Parsed of
                        #{file := File} ->
                            run(File, maps:get(out_dir, Parsed, <<".">>), maps:get(repr, Parsed, record));
                        _ ->
                            parse_error("missing <file.thrift> operand", Options)
                    end
            end;
        {error, Reason} ->
            parse_error(argparse:format_error(Reason), Options)
    end.

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
            }
        ]
    }.

run(File, OutDir, Repr) ->
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
            io:format(standard_error, "thrift_generator: ~ts~n", [format_error(Reason)]),
            halt(1)
    end.

format_error({parse, Path, {Line, Module, Term}}) when is_integer(Line) ->
    io_lib:format("~ts:~b: ~ts", [Path, Line, Module:format_error(Term)]);
format_error({parse, Path, Reason}) ->
    io_lib:format("~ts: ~0p", [Path, Reason]);
format_error({cycle, Path}) ->
    io_lib:format("include cycle involving ~ts", [Path]);
format_error({duplicate_module, Name, First, Second}) ->
    io_lib:format("module ~ts declared twice: ~ts and ~ts", [Name, First, Second]);
format_error(Errors) when is_list(Errors) ->
    lists:join(
        "\n",
        [io_lib:format("~ts:~b: ~ts", [File, Line, Message]) || {File, Line, Message} <- Errors]
    );
format_error({write_error, Path, Reason}) ->
    io_lib:format("cannot write ~ts: ~0p", [Path, Reason]);
format_error(Reason) ->
    io_lib:format("~0p", [Reason]).
