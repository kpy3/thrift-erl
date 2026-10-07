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
thrift_generator generate <file.thrift> [-o <out_dir>]
```

Runs the full pipeline (load with includes, semantic analysis, emit) and
writes the generated Erlang sources to `out_dir` (default: the current
directory).
""".

-export([main/1]).
-export([format_error/1]).

-spec main([string()]) -> no_return().
main(["generate", File | Rest]) ->
    case parse_out_dir(Rest) of
        {ok, OutDir} ->
            run(File, OutDir);
        {error, Usage} ->
            usage_error(Usage)
    end;
main(_Args) ->
    usage_error(usage()).

run(File, OutDir) ->
    case thrift_generator:generate(File, OutDir, #{}) of
        {ok, Generated} ->
            io:format("Generated ~b module(s) in ~ts:~n", [
                length(Generated), unicode:characters_to_list(OutDir)
            ]),
            lists:foreach(
                fun(#{path := Path}) ->
                    io:format("  ~ts~n", [unicode:characters_to_list(Path)])
                end,
                Generated
            ),
            halt(0);
        {error, Reason} ->
            io:format(standard_error, "thrift_generator: ~ts~n", [format_error(Reason)]),
            halt(1)
    end.

parse_out_dir([]) ->
    {ok, "."};
parse_out_dir(["-o", OutDir]) ->
    {ok, unicode:characters_to_binary(OutDir)};
parse_out_dir(["-o" ++ _ = Arg | _]) ->
    {error, "invalid option: " ++ Arg};
parse_out_dir([Arg | _]) ->
    {error, "unexpected argument: " ++ Arg}.

usage() ->
    "Usage: thrift_generator generate <file.thrift> [-o <out_dir>]\n"
    "\n"
    "  -o <out_dir>    directory for generated .erl files (default: .)".

usage_error(Message) ->
    io:format(standard_error, "~ts~n~n~ts~n", [Message, usage()]),
    halt(1).

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
