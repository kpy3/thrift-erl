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
-export([generate/3, check/3, clean/1]).

-include("thrift_generator.hrl").

%% Tokens carry {Line, Column} locations (columns are 1-based,
%% codepoint-counted by the scanner).

-type token() :: {atom(), loc()} | {atom(), loc(), term()}.

-type loc() :: pos_integer() | {pos_integer(), pos_integer()}.

-export_type([token/0, loc/0]).

-export_type([generate_opts/0]).

%% The invocation-wide option axes. Each one applies only to
%% definitions without an explicit annotation of its own (`record'
%% repr, `record' unions, `list' sets and `alias' typedefs inject
%% nothing — the annotation-free defaults stay as they are).
-type generate_opts() :: #{
    repr => record | map | native,
    union_type => record | sum,
    set => list | sets | ordset,
    typedef_type => alias | nominal
}.

-doc """
Full pipeline: load (with includes), semantic analysis, code emission,
write to `OutDir`.

Writes one `<module>.erl` per generated module (types, and
client/server/handler per service) and a `<mod>_types.hrl` next to
every types module. Files whose on-disk content already matches are
left untouched, so regenerating an unchanged IDL does not churn mtimes
(and recompiles).

`Opts` carries the invocation-wide axes; each applies only to
definitions without an explicit annotation of its own: `repr`
(`record`, the default, `map` or `native`) for structures and
exceptions without `erl.struct_type`, `union_type` (`record` or `sum`)
for unions without `erl.union_type`, `set` (`list`, the default,
`sets` or `ordset`) for sets without `erl.set`, and `typedef_type`
(`alias`, the default, or `nominal`) for typedefs without `erl.type`.
A file-wide namespace default overrides the option for its file.

Returns the generated modules with their paths (and the include path
when one was written).
""".
-spec generate(file:filename_all(), file:filename_all(), generate_opts()) ->
    {ok, [#{module := module(), path := file:filename_all(), hrl => file:filename_all()}]}
    | {error, term()}.
generate(ThriftFile, OutDir, Opts) ->
    with_sources(ThriftFile, Opts, fun(Sources) ->
        ok = filelib:ensure_dir(filename:join(OutDir, "x")),
        write_all(Sources, OutDir, [])
    end).

-doc """
The generate pipeline without writing: load (with includes), semantic
analysis, code emission — the same in-memory sources `generate/3`
writes.
""".
-spec sources(file:filename_all(), generate_opts()) ->
    {ok, [thrift_generator_emitter:source()]} | {error, term()}.
sources(ThriftFile, Opts) ->
    maybe
        SemanticOpts ?= semantic_opts(Opts),
        {ok, Loaded} ?= thrift_generator_loader:load(ThriftFile),
        {ok, Model} ?= thrift_generator_semantic:analyze(Loaded, SemanticOpts),
        {ok, thrift_generator_emitter:sources(Model)}
    else
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

-doc """
CI gate: verifies the generated sources are up to date without
writing. Runs the same pipeline as `generate/3` and requires every
artifact to already exist in `OutDir` with the exact content this
input would produce. Returns `ok`, or `{error, {stale, Paths}}` with
the drifted (missing or differing) files.
""".
-spec check(file:filename_all(), file:filename_all(), generate_opts()) ->
    ok | {error, {stale, [file:filename_all()]}} | {error, term()}.
check(ThriftFile, OutDir, Opts) ->
    with_sources(ThriftFile, Opts, fun(Sources) ->
        case stale_sources(Sources, OutDir, []) of
            [] -> ok;
            Stale -> {error, {stale, lists:reverse(Stale)}}
        end
    end).

with_sources(ThriftFile, Opts, Fun) ->
    case sources(ThriftFile, Opts) of
        {ok, Sources} -> Fun(Sources);
        {error, Reason} -> {error, Reason}
    end.

-doc """
Deletes the generator's files from `OutDir`: every `.erl` and `.hrl`
whose second line carries the `Autogenerated by Thrift Generator`
banner. The banner — not the current IDL — decides, so files left
behind by drifted inputs (a removed service, a deleted IDL file) are
cleaned up too, and anything not carrying the banner is left alone.
Returns the deleted paths, or `{error, {delete, Path, Reason}}` after
the first failing removal.
""".
-spec clean(file:filename_all()) -> {ok, [file:filename_all()]} | {error, term()}.
clean(OutDir) ->
    case file:list_dir(OutDir) of
        {ok, Names} ->
            Candidates = [filename:join(OutDir, Name) || Name <- Names],
            delete_all([Path || Path <- Candidates, is_generated_file(Path)]);
        %% nothing was ever generated there — a no-op, not a failure
        {error, enoent} ->
            {ok, []};
        {error, Reason} ->
            {error, Reason}
    end.

%% The generator's ownership mark: the second line of every .erl and
%% .hrl it writes (the first line is a bare `%%'). Version-agnostic —
%% the banner prefix stops right before the opening parenthesis.

-define(GENERATED_BANNER, <<"%%\n%% Autogenerated by Thrift Generator (">>).

is_generated_file(Path) ->
    case filename:extension(Path) of
        ".erl" -> carries_banner(Path);
        ".hrl" -> carries_banner(Path);
        _ -> false
    end.

carries_banner(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Device} ->
            %% pread answers a short head for a short file, so the
            %% strict equality also rejects eof and truncated banners
            Head = file:pread(Device, 0, byte_size(?GENERATED_BANNER)),
            ok = file:close(Device),
            Head =:= {ok, ?GENERATED_BANNER};
        {error, _} ->
            false
    end.

delete_all([]) ->
    {ok, []};
delete_all(Paths) ->
    delete_all(Paths, []).

delete_all([Path | Rest], Acc) ->
    case file:delete(Path) of
        ok -> delete_all(Rest, [Path | Acc]);
        {error, Reason} -> {error, {delete, Path, Reason}}
    end;
delete_all([], Acc) ->
    {ok, lists:reverse(Acc)}.

-spec stale_sources([thrift_generator_emitter:source()], file:filename_all(), [file:filename_all()]) ->
    [file:filename_all()].
stale_sources([#{module := Module, source := Source} = Entry | Rest], OutDir, Acc) ->
    Base = atom_to_list(Module),
    ErlPath = filename:join(OutDir, Base ++ ".erl"),
    Acc1 = stale_path(ErlPath, Source, Acc),
    case Entry of
        #{hrl := HrlSource} when HrlSource =/= undefined ->
            Acc2 = stale_path(hrl_path(OutDir, Base), HrlSource, Acc1),
            stale_sources(Rest, OutDir, Acc2);
        _ ->
            stale_sources(Rest, OutDir, Acc1)
    end;
stale_sources([], _OutDir, Acc) ->
    Acc.

stale_path(Path, Source, Acc) ->
    case disk_differs(Path, Source) of
        true -> [Path | Acc];
        false -> Acc
    end.

disk_differs(Path, Source) ->
    file:read_file(Path) =/= {ok, Source}.

%% Validates the public option axes of generate/3, sources/2 and
%% check/3: only the four known keys, each with its exact atom values.
%% Unknown keys are rejected — a typo like `typedef' would otherwise
%% silently fall back to the built-in defaults. (No empty-map clause:
%% the `#{}' pattern matches ANY map, so the key check below must see
%% every input.)

-spec semantic_opts(term()) -> generate_opts().
semantic_opts(Opts) when is_map(Opts) ->
    case maps:keys(Opts) -- [repr, union_type, set, typedef_type] of
        [] ->
            #{
                repr => axis_opt(repr, [record, map, native], Opts, record),
                union_type => axis_opt(union_type, [record, sum], Opts, record),
                set => axis_opt(set, [list, sets, ordset], Opts, list),
                typedef_type => axis_opt(typedef_type, [alias, nominal], Opts, alias)
            };
        _ ->
            erlang:error({badarg, Opts})
    end;
semantic_opts(Opts) ->
    erlang:error({badarg, Opts}).

-spec axis_opt(repr | union_type | set | typedef_type, [atom()], generate_opts(), atom()) -> atom().
axis_opt(Key, Allowed, Opts, Default) ->
    Value = maps:get(Key, Opts, Default),
    case is_atom(Value) andalso lists:member(Value, Allowed) of
        true -> Value;
        false -> erlang:error({badarg, {Key, Value}})
    end.

write_all([#{module := Module, source := Source} = Entry | Rest], OutDir, Acc) ->
    Base = atom_to_list(Module),
    Path = filename:join(OutDir, Base ++ ".erl"),
    case write_if_changed(Path, Source) of
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

%% An unchanged file is skipped, not rewritten: regenerating an
%% untouched IDL keeps mtimes (and therefore downstream recompiles)
%% stable.

-spec write_if_changed(file:filename_all(), binary()) -> ok | {error, term()}.
write_if_changed(Path, Source) ->
    case file:read_file(Path) of
        {ok, Source} -> ok;
        _ -> file:write_file(Path, Source)
    end.

write_hrl(#{hrl := Source}, OutDir, Base) when Source =/= undefined ->
    Path = hrl_path(OutDir, Base),
    case write_if_changed(Path, Source) of
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
        {ok, Tokens, _EndLoc} ?= tokens(Filename),
        ast(Tokens)
    else
        {error, Reason} -> {error, Reason};
        {error, Reason, _} -> {error, Reason}
    end.

-doc "Lexes and parses an IDL snippet given as text, without a file marker.".
-spec parse_string(string() | binary()) -> {ok, ast_node()} | {error, term()}.
parse_string(Snippet) ->
    maybe
        {ok, Tokens, _EndLoc} ?= thrift_lexer:string(unicode:characters_to_list(Snippet)),
        ast(Tokens)
    else
        {error, Reason} -> {error, Reason};
        {error, Reason, _} -> {error, Reason}
    end.
