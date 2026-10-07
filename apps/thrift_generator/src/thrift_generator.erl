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

-module(thrift_generator).

-moduledoc """
Front end of the Thrift IDL generator: turns IDL files into tokens and
an AST of `#thrift_generator_node{}` records.

The pipeline is `tokens/1` -> `ast/1`; `parse_file/1` and
`parse_string/1` wrap both steps. Every parsed file gets a synthetic
`__file__` marker appended so the document node knows which file the
AST came from; the path is kept as given (not reduced to a base name)
because include resolution needs the directory.
""".

-export([tokens/1, ast/1, parse_file/1, parse_string/1]).
-export([generate/3]).

-include("thrift_generator.hrl").

-type token() :: {atom(), pos_integer()} | {atom(), pos_integer(), term()}.

-export_type([token/0]).

-export_type([generate_opts/0]).

-type generate_opts() :: #{}.

-doc """
Full pipeline: load (with includes), semantic analysis, code emission,
write to `OutDir`.

Writes one `<module>.erl` per generated module (types, and
client/server/handler per service). `Opts` is reserved for future
tuning; pass `#{}`. Returns the generated modules with their paths.
""".
-spec generate(file:filename_all(), file:filename_all(), generate_opts()) ->
    {ok, [#{module := module(), path := file:filename_all()}]} | {error, term()}.
generate(ThriftFile, OutDir, _Opts) ->
    maybe
        {ok, Loaded} ?= thrift_generator_loader:load(ThriftFile),
        {ok, Model} ?= thrift_generator_semantic:analyze(Loaded),
        ok ?= filelib:ensure_dir(filename:join(OutDir, "x")),
        write_all(thrift_generator_emitter:sources(Model), OutDir, [])
    else
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

write_all([{Module, Source} | Rest], OutDir, Acc) ->
    Path = filename:join(OutDir, atom_to_list(Module) ++ ".erl"),
    case file:write_file(Path, Source) of
        ok -> write_all(Rest, OutDir, [#{module => Module, path => Path} | Acc]);
        {error, Reason} -> {error, {write_error, Path, Reason}}
    end;
write_all([], _OutDir, Acc) ->
    {ok, lists:reverse(Acc)}.

-doc """
Reads and lexes an IDL file, appending a `__file__` marker with the
path as given.
""".
-spec tokens(file:filename_all()) ->
    {ok, [token()], pos_integer()}
    | {error, {pos_integer(), module(), term()} | term(), pos_integer()}.
tokens(Filename) ->
    maybe
        {ok, Data} ?= file:read_file(Filename),
        DataString = binary:bin_to_list(Data),
        FilenameString = unicode:characters_to_list(Filename),
        Marker = "\n__file__ \"" ++ FilenameString ++ "\"",
        thrift_lexer:string(DataString ++ Marker)
    end.

-doc "Parses a token list into a document AST node.".
-spec ast([token()]) -> {ok, ast_node()} | {error, term()}.
ast(Tokens) ->
    thrift_parser:parse(Tokens).

-doc "Reads, lexes and parses an IDL file in one step.".
-spec parse_file(file:filename_all()) -> {ok, ast_node()} | {error, term()}.
parse_file(Filename) ->
    maybe
        {ok, Tokens, _EndLine} ?= tokens(Filename),
        ast(Tokens)
    else
        {error, Reason} -> {error, Reason};
        {error, Reason, _} -> {error, Reason}
    end.

-doc "Lexes and parses an IDL snippet given as text, without a file marker.".
-spec parse_string(string() | binary()) -> {ok, ast_node()} | {error, term()}.
parse_string(Snippet) ->
    maybe
        {ok, Tokens, _EndLine} ?= thrift_lexer:string(unicode:characters_to_list(Snippet)),
        ast(Tokens)
    else
        {error, Reason} -> {error, Reason};
        {error, Reason, _} -> {error, Reason}
    end.
