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
Front end of the Thrift IDL generator.

The public generation operations are `generate/1,2`, `check/1,2` and
`clean/1`: every frontend (the library, the standalone CLI and the
rebar3 plugin) feeds the same validated options map through them. The
parser-level entries `tokens/1`, `ast/1`, `parse_file/1` and
`parse_string/1` stay exported — the loader pipeline and the test
suites call them — but they are internal: their shapes follow the
lexer/parser pair, not a stable public contract, and `parse_file/1`
appends a synthetic `__file__` marker to the source, which the grammar
consumes after the document's definitions.
""".

-export([tokens/1, ast/1, parse_file/1, parse_string/1]).
-export([generate/1, generate/2, check/1, check/2, clean/1]).

-include("thrift_generator.hrl").

%% Tokens carry {Line, Column} locations (columns are 1-based,
%% codepoint-counted by the scanner).

-type token() :: {atom(), loc()} | {atom(), loc(), term()}.

-type loc() :: pos_integer() | {pos_integer(), pos_integer()}.

-export_type([token/0, loc/0]).

-export_type([generate_opts/0]).

%% The invocation-wide option axes, normalized by
%% thrift_generator_options:normalize/1. Each axis applies only to
%% definitions without an explicit annotation of its own (`record'
%% repr, `record' unions, `list' sets and `alias' typedefs inject
%% nothing — the annotation-free defaults stay as they are); `out_dir'
%% names the directory artifacts are written to (`src' by default).
-type generate_opts() :: #{
    out_dir => file:filename_all(),
    repr => record | map | native,
    union_type => record | sum,
    set => list | sets | ordset,
    typedef_type => alias | nominal,
    enum_case => preserve | lower
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
definitions without an explicit annotation of its own: `out_dir`
(`"src"`, the default) names the output directory, `repr`
(`record`, the default, `map` or `native`) for structures and
exceptions without `erl.struct_type`, `union_type` (`record` or `sum`)
for unions without `erl.union_type`, `set` (`list`, the default,
`sets` or `ordset`) for sets without `erl.set`, `typedef_type`
(`alias`, the default, or `nominal`) for typedefs without `erl.type`,
and `enum_case` (`preserve`, the default, or `lower`) for enum members
without `erl.enum_case`. A file-wide namespace default overrides the
option for its file.

Invalid options — an unknown key, a bad value, a non-map — are
returned as `{error, {unknown_option, Key}}` or
`{error, {bad_option, ...}}` before the IDL is read and before
anything is written.

Returns the generated modules with their paths (and the include path
when one was written).
""".
-spec generate(file:filename_all(), generate_opts()) ->
    {ok, [#{module := module(), path := file:filename_all(), hrl => file:filename_all()}]}
    | {error, term()}.
generate(ThriftFile, Options) ->
    with_normalized(Options, fun(Opts) ->
        OutDir = maps:get(out_dir, Opts),
        with_sources(ThriftFile, maps:remove(out_dir, Opts), fun(Sources) ->
            ok = filelib:ensure_dir(filename:join(OutDir, "x")),
            write_all(Sources, OutDir, [])
        end)
    end).

-doc "Generates with default options; artifacts are written to `./src`.".
-spec generate(file:filename_all()) ->
    {ok, [#{module := module(), path := file:filename_all(), hrl => file:filename_all()}]}
    | {error, term()}.
generate(ThriftFile) ->
    generate(ThriftFile, #{}).

%% Options enter only through the shared normalizer: validation errors
%% are returned before the loader runs, so a bad options map never
%% causes a partial write.
-spec with_normalized(term(), fun((generate_opts()) -> Result)) ->
    Result | {error, term()}.
with_normalized(Options, Fun) ->
    case thrift_generator_options:normalize(Options) of
        {ok, Opts} -> Fun(Opts);
        {error, Reason} -> {error, Reason}
    end.

%% Internal: the generate pipeline without writing, shared by
%% generate and check through with_sources/3.
-spec sources(file:filename_all(), thrift_generator_semantic:generate_semantic_opts()) ->
    {ok, [thrift_generator_emitter:source()]} | {error, term()}.
sources(ThriftFile, Opts) ->
    maybe
        {ok, Loaded} ?= thrift_generator_loader:load(ThriftFile),
        {ok, Model} ?= thrift_generator_semantic:analyze(Loaded, Opts),
        {ok, thrift_generator_emitter:sources(Model)}
    else
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

-doc """
CI gate: verifies the generated sources are up to date without
writing. Runs the same pipeline as `generate/2` and requires every
artifact to already exist in the `out_dir` from `Opts` (default
`"src"`) with the exact content this input would produce. Returns `ok`,
or `{error, {stale, Paths}}` with the drifted (missing or differing)
files.
""".
-spec check(file:filename_all(), generate_opts()) ->
    ok | {error, {stale, [file:filename_all()]}} | {error, term()}.
check(ThriftFile, Options) ->
    with_normalized(Options, fun(Opts) ->
        OutDir = maps:get(out_dir, Opts),
        with_sources(ThriftFile, maps:remove(out_dir, Opts), fun(Sources) ->
            case stale_sources(Sources, OutDir, []) of
                [] -> ok;
                Stale -> {error, {stale, lists:reverse(Stale)}}
            end
        end)
    end).

-doc "Checks freshness with default options against `./src`.".
-spec check(file:filename_all()) -> ok | {error, {stale, [file:filename_all()]}} | {error, term()}.
check(ThriftFile) ->
    check(ThriftFile, #{}).

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
    %% filename:extension mirrors the path's stringness, so a binary out
    %% dir yields binary extensions — match both spellings
    case filename:extension(Path) of
        Ext when Ext =:= ".erl"; Ext =:= <<".erl">> ->
            carries_banner(Path);
        Ext when Ext =:= ".hrl"; Ext =:= <<".hrl">> ->
            carries_banner(Path);
        _ ->
            false
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
