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

-module(thrift_generator_idl).

-moduledoc """
Internal IDL parsing front end.

The parser-level entries `tokens/1`, `ast/1`, `parse_file/1` and
`parse_string/1` back the loader pipeline and the test suites. They are
internal: their shapes follow the lexer/parser pair, not a stable public
contract, and `parse_file/1` appends a synthetic `__file__` marker to
the source, which the grammar consumes after the document's definitions.
""".

-export([tokens/1, ast/1, parse_file/1, parse_string/1]).

-include("thrift_generator.hrl").

%% Tokens carry {Line, Column} locations (columns are 1-based,
%% codepoint-counted by the scanner).

-type token() :: {atom(), loc()} | {atom(), loc(), term()}.

-type loc() :: pos_integer() | {pos_integer(), pos_integer()}.

-export_type([token/0, loc/0]).

-doc """
Internal: reads and lexes an IDL file, appending a `__file__` marker
with the path as given. Not a stable public contract.
""".
-spec tokens(file:filename_all()) ->
    {ok, [token()], loc()}
    | {error, {loc(), module(), term()} | term(), loc()}.
tokens(Filename) ->
    maybe
        {ok, Data} ?= file:read_file(Filename),
        {ok, DataString} ?= utf8_text(Data, Filename),
        FilenameString = unicode:characters_to_list(Filename),
        Marker = "\n__file__ \"" ++ FilenameString ++ "\"",
        thrift_lexer:string(DataString ++ Marker)
    end.

%% IDL text is UTF-8 by spec; the lexer wants codepoints, so the file
%% bytes decode once here — reading them byte-per-char (latin1) would
%% double-encode every doc comment and string constant downstream. An
%% invalid file is a clean error, not a cryptic lexer failure.

-spec utf8_text(binary(), file:filename_all()) ->
    {ok, string()} | {error, {invalid_utf8, file:filename_all()}}.
utf8_text(Data, Filename) ->
    case unicode:characters_to_list(Data, utf8) of
        Text when is_list(Text) -> {ok, Text};
        _ -> {error, {invalid_utf8, Filename}}
    end.

-doc "Internal: parses a token list into a document AST node. Not a stable public contract.".
-spec ast([token()]) -> {ok, ast_node()} | {error, term()}.
ast(Tokens) ->
    thrift_parser:parse(strip_detached_docs(Tokens)).

%% The grammar attaches `doc' comments to definitions and, inside
%% bodies, to fields, enum values and functions. Consecutive comments
%% merge into one doc (the official compiler concatenates them the same
%% way). A document-level doc before a header — or dangling at end of
%% input — has nothing to attach to; the official grammar treats any
%% comment there as whitespace, so those tokens are dropped.

-spec strip_detached_docs([token()]) -> [token()].
strip_detached_docs(Tokens) ->
    strip_detached_docs(Tokens, 0).

strip_detached_docs([], _Depth) ->
    [];
strip_detached_docs([{doc, Line, Text} | Rest], Depth) ->
    {Texts, Rest1} = collect_docs(Rest, [Text]),
    Merged = {doc, Line, join_docs(lists:reverse(Texts))},
    case (Depth =:= 0 andalso detached(Rest1)) orelse closing_delimiter(Rest1) of
        true ->
            strip_detached_docs(Rest1, Depth);
        false ->
            [Merged | strip_detached_docs(Rest1, Depth)]
    end;
strip_detached_docs([Token | Rest], Depth) ->
    Depth1 =
        case Token of
            {'{', _} -> Depth + 1;
            {'}', _} -> Depth - 1;
            _ -> Depth
        end,
    [Token | strip_detached_docs(Rest, Depth1)].

-spec collect_docs([token()], [binary()]) -> {[binary()], [token()]}.
collect_docs([{doc, _, Text} | Rest], Acc) ->
    collect_docs(Rest, [Text | Acc]);
collect_docs(Rest, Acc) ->
    {Acc, Rest}.

-spec join_docs([binary()]) -> binary().
join_docs(Texts) ->
    iolist_to_binary(lists:join(<<"\n">>, Texts)).

%% A doc is detached when the next meaningful token opens a header, the
%% file marker, or nothing — everything else (a definition start, or any
%% token inside a body) keeps it attached. A doc before a closing delimiter
%% has no definition to attach to either; Thrift treats it as whitespace.

-spec detached([token()]) -> boolean().
detached([{doc, _, _} | Rest]) ->
    detached(Rest);
detached([{T, _} | _]) when T =:= include; T =:= cpp_include; T =:= namespace; T =:= file ->
    true;
detached([]) ->
    true;
detached(_) ->
    false.

-spec closing_delimiter([token()]) -> boolean().
closing_delimiter([{T, _} | _]) when T =:= '}'; T =:= ')'; T =:= ']'; T =:= '>' ->
    true;
closing_delimiter(_) ->
    false.

-doc "Internal: reads, lexes and parses an IDL file in one step. Not a stable public contract.".
-spec parse_file(file:filename_all()) -> {ok, ast_node()} | {error, term()}.
parse_file(Filename) ->
    maybe
        {ok, Tokens, _EndLoc} ?= tokens(Filename),
        ast(Tokens)
    else
        {error, Reason} -> {error, Reason};
        {error, Reason, _} -> {error, Reason}
    end.

-doc "Internal: lexes and parses an IDL snippet given as text, without a file marker. Not a stable public contract.".
-spec parse_string(string() | binary()) -> {ok, ast_node()} | {error, term()}.
parse_string(Snippet) ->
    maybe
        {ok, Tokens, _EndLoc} ?= thrift_lexer:string(unicode:characters_to_list(Snippet)),
        ast(Tokens)
    else
        {error, Reason} -> {error, Reason};
        {error, Reason, _} -> {error, Reason}
    end.
