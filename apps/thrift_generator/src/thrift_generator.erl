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
`parse_string/1` wrap both steps. `parse_file/1` appends a synthetic
`__file__` marker to the source, which the grammar consumes after the
document's definitions; the AST document itself carries only headers
and definitions — module naming and include resolution work from the
paths the loader tracks.
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
client/server/handler per service) and a `<mod>_types.hrl` next to
every types module. `Opts` is reserved for future tuning; pass `#{}`.
Returns the generated modules with their paths (and the include path
when one was written).
""".
-spec generate(file:filename_all(), file:filename_all(), generate_opts()) ->
    {ok, [#{module := module(), path := file:filename_all(), hrl => file:filename_all()}]}
    | {error, term()}.
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

write_all([#{module := Module, source := Source} = Entry | Rest], OutDir, Acc) ->
    Base = atom_to_list(Module),
    Path = filename:join(OutDir, Base ++ ".erl"),
    case file:write_file(Path, Source) of
        ok ->
            case write_hrl(Entry, OutDir, Base) of
                {ok, HrlPath} ->
                    write_all(Rest, OutDir, [Entry#{path => Path, hrl => HrlPath} | Acc]);
                none ->
                    write_all(Rest, OutDir, [Entry#{path => Path} | Acc]);
                {error, Reason} ->
                    {error, {write_error, hrl_path(OutDir, Base), Reason}}
            end;
        {error, Reason} ->
            {error, {write_error, Path, Reason}}
    end;
write_all([], _OutDir, Acc) ->
    {ok, lists:reverse(Acc)}.

write_hrl(#{hrl := Source}, OutDir, Base) when Source =/= undefined ->
    Path = hrl_path(OutDir, Base),
    case file:write_file(Path, Source) of
        ok -> {ok, Path};
        {error, Reason} -> {error, Reason}
    end;
write_hrl(_Entry, _OutDir, _Base) ->
    none.

hrl_path(OutDir, Base) ->
    filename:join(OutDir, Base ++ ".hrl").

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
