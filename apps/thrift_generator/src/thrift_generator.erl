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

%% The default value representation for definitions without an explicit
%% `erl.struct_type' annotation (`record' injects nothing — the
%% annotation-free default stays the tuple record). Unions keep their
%% own axis (`erl.union_type').
-type generate_opts() :: #{repr => record | map | native}.

-doc """
Full pipeline: load (with includes), semantic analysis, code emission,
write to `OutDir`.

Writes one `<module>.erl` per generated module (types, and
client/server/handler per service) and a `<mod>_types.hrl` next to
every types module. `Opts` understands `repr` — the representation
generated for definitions without an explicit `erl.struct_type`
annotation (`record`, the default, injects nothing; `map` and `native`
inject their annotation the same way an explicit one would).
Returns the generated modules with their paths (and the include path
when one was written).
""".
-spec generate(file:filename_all(), file:filename_all(), generate_opts()) ->
    {ok, [#{module := module(), path := file:filename_all(), hrl => file:filename_all()}]}
    | {error, term()}.
generate(ThriftFile, OutDir, Opts) ->
    maybe
        Repr ?= repr_opt(Opts),
        {ok, Loaded} ?= thrift_generator_loader:load(ThriftFile),
        {ok, Model} ?= thrift_generator_semantic:analyze(Loaded, #{repr => Repr}),
        ok ?= filelib:ensure_dir(filename:join(OutDir, "x")),
        write_all(thrift_generator_emitter:sources(Model), OutDir, [])
    else
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

-spec repr_opt(term()) -> record | map | native.
repr_opt(#{repr := Repr}) when Repr =:= record; Repr =:= map; Repr =:= native ->
    Repr;
repr_opt(#{} = Opts) when map_size(Opts) =:= 0 ->
    record;
repr_opt(Opts) ->
    erlang:error({badarg, Opts}).

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

-doc "Parses a token list into a document AST node.".
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
    case Depth =:= 0 andalso detached(Rest1) of
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
%% token inside a body) keeps it attached.

-spec detached([token()]) -> boolean().
detached([{doc, _, _} | Rest]) ->
    detached(Rest);
detached([{T, _} | _]) when T =:= include; T =:= cpp_include; T =:= namespace; T =:= file ->
    true;
detached([]) ->
    true;
detached(_) ->
    false.

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
