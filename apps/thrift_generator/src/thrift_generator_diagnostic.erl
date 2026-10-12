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
both carrying a file path and a location — render in the rebar3/elp
style: a source excerpt with a gutter and a `╰──` marker naming the
problem. Locations may carry a column (`{Line, Column}` pairs thread
through from the lexer); the marker then sits on the exact column,
counted in codepoints of the tab-expanded line, falling back to the
first non-blank column for line-only locations. When the source cannot
be read back, carries no such line, or the error names no location at
all, the compact `path:line[:column]: message` form answers instead.
The source lookup is injectable — tests and the `--compact-errors`
switch feed a resolver that always errors.
""".

-export([format/1, format/2]).

-export_type([source_fun/0, loc/0]).

%% The source resolver: a file path in, the source text — or any error
%% term when the text is unavailable. `auto' reads the named files from
%% disk.
-type source_fun() :: auto | fun((unicode:chardata()) -> {ok, binary()} | {error, term()}).

%% A problem position: a line number, or a {Line, Column} pair when the
%% error site knows the opening token's column (columns are 1-based,
%% counted in codepoints).

-type loc() :: integer() | {integer(), integer()}.

-spec format(term()) -> unicode:chardata().
format(Reason) ->
    format(Reason, fun read_source/1).

-spec format(term(), source_fun()) -> unicode:chardata().
format(Reason, auto) ->
    format(Reason, fun read_source/1);
format({parse, Path, {Loc, Module, Term}}, Source) when
    is_integer(Loc); is_tuple(Loc) andalso tuple_size(Loc) =:= 2
->
    unwrap(located(Path, Loc, unicode:characters_to_binary(Module:format_error(Term)), Source));
format({parse, Path, Reason}, _Source) ->
    io_lib:format("~ts: ~0p", [Path, Reason]);
format(Errors, Source) when is_list(Errors) ->
    Rendered = [
        located(File, Loc, unicode:characters_to_binary(Message), Source)
     || {File, Loc, Message} <- Errors
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

-spec located(unicode:chardata(), loc(), binary(), source_fun()) ->
    {rich, unicode:chardata()} | {compact, unicode:chardata()}.
located(Path, Loc, Message, Source) ->
    Compact = {compact, compact(Path, Loc, Message)},
    case Source(Path) of
        {ok, Bin} ->
            case source_line(Bin, loc_line(Loc)) of
                {ok, Text} ->
                    {rich, excerpt(Path, Loc, Message, Text)};
                error ->
                    Compact
            end;
        _Error ->
            Compact
    end.

unwrap({_Kind, Text}) ->
    Text.

compact(Path, Loc, Message) ->
    case Loc of
        {Line, Col} -> io_lib:format("~ts:~b:~b: ~ts", [Path, Line, Col, Message]);
        Line -> io_lib:format("~ts:~b: ~ts", [Path, Line, Message])
    end.

loc_line({Line, _Col}) ->
    Line;
loc_line(Line) ->
    Line.

%% The excerpt block:

%%   ┌─ ping.thrift:9:23:
%%   │
%% 9 │ PingReply ping(1: PingRequest request),
%%   │ ╰── duplicate field id 1 (already used by message)

excerpt(Path, Loc, Message, LineText) ->
    Line = loc_line(Loc),
    Number = integer_to_binary(Line),
    Pad = binary:copy(<<" ">>, byte_size(Number)),
    CaretWidth =
        case Loc of
            {_, Col} -> caret_width(LineText, Col);
            _ -> leading_blanks(LineText)
        end,
    Caret = binary:copy(<<" ">>, CaretWidth),
    %% the gutter's `│' is three bytes but one display column: the
    %% continuation indent counts display columns
    MarkerColumn = byte_size(Number) + 3 + CaretWidth + 4,
    [
        Pad,
        " ┌─ ",
        Path,
        ":",
        Number,
        [
            case Loc of
                {_, Col0} -> [":", integer_to_binary(Col0)];
                _ -> []
            end
        ],
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

%% The one source line the error names, tabs expanded to tab stops so
%% the marker stays aligned, CR stripped so it does not leak into the
%% excerpt.

source_line(Source, Line) when Line >= 1 ->
    Lines = binary:split(Source, <<"\n">>, [global]),
    try lists:nth(Line, Lines) of
        Text -> {ok, expand_tabs(Text, 0)}
    catch
        _:_ ->
            error
    end;
source_line(_Source, _Line) ->
    error.

%% Tabs advance to the next tab stop every 4 columns — the same
%% accounting the scanner applies (xrl_opts tab_size 4 feeding leex's
%% adjust_col/tab_forward), so an exact {Line, Col} marker stays under
%% the offending text on tab-containing lines. CR is stripped; every
%% other byte is one column (only a tab following multibyte text could
%% notice the difference, and the scanner has the same simplification).

expand_tabs(Text, Column) ->
    case Text of
        <<$\t, Rest/binary>> ->
            Width = 4 - (Column rem 4),
            Pad = binary:copy(<<" ">>, Width),
            <<Pad/binary, (expand_tabs(Rest, Column + Width))/binary>>;
        <<$\r, Rest/binary>> ->
            expand_tabs(Rest, Column);
        <<Byte, Rest/binary>> ->
            <<Byte, (expand_tabs(Rest, Column + 1))/binary>>;
        <<>> ->
            <<>>
    end.

leading_blanks(<<" ", Rest/binary>>) ->
    1 + leading_blanks(Rest);
leading_blanks(_) ->
    0.

%% The marker column for an exact {Line, Col} location: the byte size of
%% the first Col-1 codepoints of the (tab-expanded) line. The lexer
%% counts columns in codepoints (leex adjust_col), while carets pad in
%% bytes, so multibyte text before the column shifts the byte offset —
%% walking the line keeps the two in agreement. A column past the line
%% end clamps to the line end; a non-UTF-8 tail stops the walk there.

caret_width(LineText, Col) when Col >= 1 ->
    caret_width(LineText, Col - 1, 0).

caret_width(_Rest, 0, Width) ->
    Width;
caret_width(<<C/utf8, Rest/binary>>, N, Width) ->
    caret_width(Rest, N - 1, Width + utf8_size(C));
caret_width(_, _, Width) ->
    Width.

utf8_size(C) when C < 16#80 -> 1;
utf8_size(C) when C < 16#800 -> 2;
utf8_size(C) when C < 16#10000 -> 3;
utf8_size(_) -> 4.

read_source(Path) ->
    file:read_file(Path).
