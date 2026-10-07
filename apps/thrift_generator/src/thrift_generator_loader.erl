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

-module(thrift_generator_loader).

-moduledoc """
Loads an IDL compilation unit: the root file plus every transitively
included file.

Include paths resolve relative to the directory of the including file.
Circular includes are an error; diamond includes deduplicate. Each file
becomes one entry with its module name — taken from `namespace erl`
(or `namespace *`), falling back to the file base name without the
.thrift extension. Entries come back in pre-order (root first); paths
are absolute binaries.
""".

-export([load/1]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

-type mark() :: visiting | visited.

-doc """
Loads `Path` and its transitive includes, or fails on parse errors,
missing files, circular includes or two files claiming the same module
name.
""".
-spec load(file:filename_all()) -> {ok, [#tg_loaded{}]} | {error, term()}.
load(Path) ->
    Abs = to_abs(Path),
    try
        {Entries, _Marks} = visit(Abs, #{}, []),
        check_duplicate_modules(lists:reverse(Entries))
    catch
        throw:{load_error, Reason} -> {error, Reason}
    end.

-doc "Parses one file or throws a tagged load error.".
-spec visit(binary(), #{binary() => mark()}, [#tg_loaded{}]) ->
    {[#tg_loaded{}], #{binary() => mark()}}.
visit(Path, Marks, Acc) ->
    case Marks of
        #{Path := visited} ->
            {Acc, Marks};
        #{Path := visiting} ->
            throw({load_error, {cycle, Path}});
        _ ->
            Doc = parse(Path),
            Headers = document_headers(Doc),
            Name = module_name(Headers, Path),
            Includes = include_paths(Headers, Path),
            Entry = #tg_loaded{name = Name, path = Path, includes = Includes, doc = Doc},
            {Acc1, Marks1} = lists:foldl(
                fun(Include, {A, M}) -> visit(Include, M, A) end,
                {[Entry | Acc], Marks#{Path => visiting}},
                Includes
            ),
            {Acc1, Marks1#{Path := visited}}
    end.

-spec parse(binary()) -> ast_node().
parse(Path) ->
    case thrift_generator:parse_file(Path) of
        {ok, Doc} ->
            Doc;
        {error, Reason} ->
            throw({load_error, {parse, Path, Reason}})
    end.

-spec document_headers(ast_node()) -> [ast_node()].
document_headers(Doc) ->
    (Doc#thrift_generator_node.payload)#thrift_generator_document.headers.

-spec include_paths([ast_node()], binary()) -> [binary()].
include_paths(Headers, ParentPath) ->
    Dir = unicode:characters_to_list(filename:dirname(ParentPath)),
    [
        unicode:characters_to_binary(
            filename:absname(unicode:characters_to_list(IncludePath), Dir)
        )
     || #thrift_generator_node{payload = #thrift_generator_include{path = IncludePath}} <-
            Headers
    ].

%% The module name qualifies references from including files and names
%% generated modules: prefer the erl namespace, then the wildcard one,
%% then the file base name.

-spec module_name([ast_node()], binary()) -> binary().
module_name(Headers, Path) ->
    Namespaces = [
        {Scope, Name}
     || #thrift_generator_node{
            payload = #thrift_generator_namespace{scope = Scope, name = Name}
        } <-
            Headers
    ],
    Fallback = basename_sans_extension(Path),
    pick_namespace(Namespaces, <<"erl">>, pick_namespace(Namespaces, <<"*">>, Fallback)).

-spec pick_namespace([{binary(), binary()}], binary(), binary()) -> binary().
pick_namespace(Namespaces, Scope, Fallback) ->
    case lists:keyfind(Scope, 1, Namespaces) of
        {Scope, Name} -> Name;
        false -> Fallback
    end.

-spec basename_sans_extension(binary()) -> binary().
basename_sans_extension(Path) ->
    filename:basename(Path, <<".thrift">>).

-spec to_abs(file:filename_all()) -> binary().
to_abs(Path) ->
    unicode:characters_to_binary(
        filename:absname(unicode:characters_to_list(Path))
    ).

-spec check_duplicate_modules([#tg_loaded{}]) -> {ok, [#tg_loaded{}]} | {error, term()}.
check_duplicate_modules(Entries) ->
    Counts = lists:foldl(
        fun(Entry, Acc) -> maps:update_with(Entry#tg_loaded.name, fun(C) -> C + 1 end, 1, Acc) end,
        #{},
        Entries
    ),
    case [Name || Name := Count <- Counts, Count > 1] of
        [] ->
            {ok, Entries};
        [Name | _] ->
            [First, Second | _] = [E || E <- Entries, E#tg_loaded.name =:= Name],
            {error, {duplicate_module, Name, First#tg_loaded.path, Second#tg_loaded.path}}
    end.
