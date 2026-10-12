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

-module(thrift_generator_diagnostic).

-moduledoc """
Error rendering shared by the CLI and the rebar3 plugin.

Located problems — lexer/parser errors and the semantic pass findings,
both carrying a file path and a line — render in the rebar3/elp style:
a source excerpt with a gutter and a `╰──` marker naming the problem.
The marker sits under the construct's first non-blank column; the
scanner carries no columns, so the line is as precise as the pipeline
gets. When the source cannot be read back, carries no such line, or
the error names no location at all, the compact `path:line: message`
form answers instead. The source lookup is injectable — tests and the
`--compact-errors` switch feed a resolver that always errors.
""".

-export([format/1, format/2]).

-export_type([source_fun/0]).

%% The source resolver: a file path in, the source text — or any error
%% term when the text is unavailable. `auto' reads the named files from
%% disk.
-type source_fun() :: auto | fun((unicode:chardata()) -> {ok, binary()} | {error, term()}).

-spec format(term()) -> unicode:chardata().
format(Reason) ->
    format(Reason, fun read_source/1).

-spec format(term(), source_fun()) -> unicode:chardata().
format(Reason, auto) ->
    format(Reason, fun read_source/1);
format({parse, Path, {Line, Module, Term}}, Source) when is_integer(Line) ->
    unwrap(located(Path, Line, unicode:characters_to_binary(Module:format_error(Term)), Source));
format({parse, Path, Reason}, _Source) ->
    io_lib:format("~ts: ~0p", [Path, Reason]);
format(Errors, Source) when is_list(Errors) ->
    Rendered = [
        located(File, Line, unicode:characters_to_binary(Message), Source)
     || {File, Line, Message} <- Errors
    ],
    %% compact lines read as one continuous report; excerpt blocks need
    %% a blank line between them
    Joiner =
        case
            lists:any(
                fun
                    ({rich, _}) -> true;
                    ({compact, _}) -> false
                end,
                Rendered
            )
        of
            true -> "\n\n";
            false -> "\n"
        end,
    lists:join(Joiner, [Text || {_, Text} <- Rendered]);
format({cycle, Path}, _Source) ->
    io_lib:format("include cycle involving ~ts", [Path]);
format({duplicate_module, Name, First, Second}, _Source) ->
    io_lib:format("module ~ts declared twice: ~ts and ~ts", [Name, First, Second]);
format({write_error, Path, Reason}, _Source) ->
    io_lib:format("cannot write ~ts: ~0p", [Path, Reason]);
format({stale, Paths}, _Source) ->
    io_lib:format(
        "generated sources are out of date (run the generator to refresh):~n~ts",
        [[io_lib:format("  ~ts~n", [Path]) || Path <- Paths]]
    );
format(Reason, _Source) ->
    io_lib:format("~0p", [Reason]).

%% One located problem: the excerpt block when the file reads back and
%% carries the line, the compact line otherwise.

-spec located(unicode:chardata(), integer(), binary(), source_fun()) ->
    {rich, unicode:chardata()} | {compact, unicode:chardata()}.
located(Path, Line, Message, Source) ->
    Compact = {compact, io_lib:format("~ts:~b: ~ts", [Path, Line, Message])},
    case Source(Path) of
        {ok, Bin} ->
            case source_line(Bin, Line) of
                {ok, Text} ->
                    {rich, excerpt(Path, Line, Message, Text)};
                error ->
                    Compact
            end;
        _Error ->
            Compact
    end.

unwrap({_Kind, Text}) ->
    Text.

%% The excerpt block:

%%   ┌─ ping.thrift:9:
%%   │
%% 9 │ PingReply ping(1: PingRequest request),
%%   │ ╰── duplicate field id 1 (already used by message)

excerpt(Path, Line, Message, LineText) ->
    Number = integer_to_binary(Line),
    Pad = binary:copy(<<" ">>, byte_size(Number)),
    Caret = binary:copy(<<" ">>, leading_blanks(LineText)),
    %% the gutter's `│' is three bytes but one display column: the
    %% continuation indent counts display columns
    MarkerColumn = byte_size(Number) + 3 + leading_blanks(LineText) + 4,
    [
        Pad,
        " ┌─ ",
        Path,
        ":",
        Number,
        ":\n",
        Pad,
        " │\n",
        Number,
        " │ ",
        LineText,
        "\n",
        Pad,
        " │ ",
        Caret,
        marker(Message, MarkerColumn)
    ].

%% `╰── message' with the message's continuation lines indented to its
%% column (parser messages carry embedded newlines).

marker(Message, Column) ->
    Indent = binary:copy(<<" ">>, Column),
    %% /utf8 is load-bearing: a plain binary literal keeps one byte per
    %% character, truncating every box-drawing glyph
    [<<"╰── "/utf8>> | lists:join(<<"\n", Indent/binary>>, binary:split(Message, <<"\n">>, [global]))].

%% The one source line the error names, tabs expanded so the marker
%% stays aligned, CR stripped so it does not leak into the excerpt.

source_line(Source, Line) when Line >= 1 ->
    Lines = binary:split(Source, <<"\n">>, [global]),
    try lists:nth(Line, Lines) of
        Text -> {ok, binary:replace(binary:replace(Text, <<"\t">>, <<"    ">>, [global]), <<"\r">>, <<>>, [global])}
    catch
        _:_ ->
            error
    end;
source_line(_Source, _Line) ->
    error.

leading_blanks(<<" ", Rest/binary>>) ->
    1 + leading_blanks(Rest);
leading_blanks(_) ->
    0.

read_source(Path) ->
    file:read_file(Path).
