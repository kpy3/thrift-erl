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

%% File-level tests for the final generate/check/clean frontends (the
%% /1,/2 options-map forms): real IDL files in a temp directory,
%% artifacts on disk, drift detection and the unchanged-file write
%% skip. The public API shape and the pin against the pre-Series-2
%% fixture output live here too; in-memory pipeline coverage lives in
%% thrift_generator_test.

-module(thrift_generator_generate_test).

-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").

-export([
    public_api_shape_test/0,
    generate_matches_fixture_test/0,
    options_normalize_test/0,
    generate_check_up_to_date_test/0,
    generate_check_modified_file_test/0,
    generate_check_missing_file_test/0,
    generate_check_repr_drift_test/0,
    generate_check_option_axes_test/0,
    generate_default_out_dir_test/0,
    generate_bad_opts_test/0,
    generate_skips_unchanged_test/0,
    clean_removes_generated_files_test/0,
    clean_binary_out_dir_test/0,
    clean_missing_dir_test/0
]).

%% The module name comes from the (namespace-less) file name; one
%% struct and one service cover both artifact shapes (a types pair and
%% a service trio).

-define(FILE_SNIPPET,
    "struct Point { 1: required i32 x, 2: optional string note }\n"
    "service Pinger { void ping() }\n"
).

%% The shared options contract: normalize/1 fills every default, keeps
%% valid overrides (string or binary out_dir), and reports the first
%% error deterministically (keys checked in sorted order, so a bad
%% value on a key sorting before an unknown key wins).

options_normalize_test() ->
    Default = #{
        out_dir => "src",
        repr => record,
        union_type => record,
        set => list,
        typedef_type => alias,
        enum_case => preserve
    },
    ?assertEqual({ok, Default}, thrift_generator_options:normalize(#{})),
    ?assertEqual(
        {ok, Default#{out_dir => "gen"}},
        thrift_generator_options:normalize(#{out_dir => "gen"})
    ),
    ?assertEqual(
        {ok, Default#{out_dir => <<"gen">>}},
        thrift_generator_options:normalize(#{out_dir => <<"gen">>})
    ),
    ?assertEqual({ok, Default#{repr => map}}, thrift_generator_options:normalize(#{repr => map})),
    ?assertEqual(
        {ok, Default#{union_type => sum}},
        thrift_generator_options:normalize(#{union_type => sum})
    ),
    ?assertEqual({ok, Default#{set => sets}}, thrift_generator_options:normalize(#{set => sets})),
    ?assertEqual(
        {ok, Default#{set => ordset}},
        thrift_generator_options:normalize(#{set => ordset})
    ),
    ?assertEqual(
        {ok, Default#{typedef_type => nominal}},
        thrift_generator_options:normalize(#{typedef_type => nominal})
    ),
    ?assertEqual(
        {ok, Default#{enum_case => lower}},
        thrift_generator_options:normalize(#{enum_case => lower})
    ),
    ?assertEqual(
        {error, {unknown_option, bogus}},
        thrift_generator_options:normalize(#{bogus => true})
    ),
    ?assertEqual(
        {error, {bad_option, {repr, tuple, [record, map, native]}}},
        thrift_generator_options:normalize(#{repr => tuple})
    ),
    ?assertEqual(
        {error, {bad_option, {union_type, tagged, [record, sum]}}},
        thrift_generator_options:normalize(#{union_type => tagged})
    ),
    ?assertEqual(
        {error, {bad_option, {set, gb_sets, [list, sets, ordset]}}},
        thrift_generator_options:normalize(#{set => gb_sets})
    ),
    ?assertEqual(
        {error, {bad_option, {typedef_type, record, [alias, nominal]}}},
        thrift_generator_options:normalize(#{typedef_type => record})
    ),
    ?assertEqual(
        {error, {bad_option, {enum_case, upper, [preserve, lower]}}},
        thrift_generator_options:normalize(#{enum_case => upper})
    ),
    ?assertEqual(
        {error, {bad_option, {out_dir, 42, [string, binary]}}},
        thrift_generator_options:normalize(#{out_dir => 42})
    ),
    ?assertEqual(
        {error, {bad_option, {out_dir, ["/x" | 42], [string, binary]}}},
        thrift_generator_options:normalize(#{out_dir => ["/x" | 42]})
    ),
    %% deterministic first error: the bad enum_case (sorts first) is
    %% reported before the unknown key
    ?assertEqual(
        {error, {bad_option, {enum_case, upper, [preserve, lower]}}},
        thrift_generator_options:normalize(#{enum_case => upper, zzz_typo => true})
    ),
    ?assertEqual(
        {error, {bad_option, {options, atoms, [map]}}},
        thrift_generator_options:normalize(atoms)
    ),
    ok.

generate_check_up_to_date_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, #{out_dir => OutDir}),
        Modules = [Module || #{module := Module} <- Generated],
        ?assertEqual(
            [
                checkgate_pinger_client,
                checkgate_pinger_handler,
                checkgate_pinger_server,
                checkgate_types,
                checkgate_types_repr
            ],
            lists:sort(Modules)
        ),
        ?assertEqual(ok, thrift_generator:check(File, #{out_dir => OutDir})),
        ok
    after
        rm_rf(Dir)
    end.

generate_check_modified_file_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, #{out_dir => OutDir}),
        #{path := StalePath} = entry_for(checkgate_pinger_server, Generated),
        ok = file:write_file(StalePath, <<"-module(tampered).">>),
        ?assertEqual(
            {error, {stale, [StalePath]}},
            thrift_generator:check(File, #{out_dir => OutDir})
        ),
        ok
    after
        rm_rf(Dir)
    end.

generate_check_missing_file_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, #{out_dir => OutDir}),
        #{hrl := HrlPath} = entry_for(checkgate_types, Generated),
        ok = file:delete(HrlPath),
        ?assertEqual(
            {error, {stale, [HrlPath]}},
            thrift_generator:check(File, #{out_dir => OutDir})
        ),

        %% a fresh directory has nothing yet — every artifact is stale
        ?assertMatch(
            {error, {stale, [_ | _]}},
            thrift_generator:check(File, #{out_dir => filename:join(Dir, "fresh")})
        ),
        ok
    after
        rm_rf(Dir)
    end.

generate_check_repr_drift_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, _} = thrift_generator:generate(File, #{out_dir => OutDir, repr => record}),
        {error, {stale, Stale}} = thrift_generator:check(File, #{out_dir => OutDir, repr => map}),
        TypesErl = filename:join(OutDir, "checkgate_types.erl"),
        ?assert(lists:member(TypesErl, Stale)),
        ok
    after
        rm_rf(Dir)
    end.

%% The union/set/typedef option axes take part in the freshness gate
%% the same way --repr does: check passes only with the exact options
%% the artifacts were generated with.

generate_check_option_axes_test() ->
    Dir = tmp_dir(),
    try
        File = filename:join(Dir, "axesgate.thrift"),
        ok =
            file:write_file(
                File,
                "union Value { 1: i64 n }\n"
                "struct Bag { 1: optional set<string> tags }\n"
                "typedef i64 Stamp\n"
            ),
        OutDir = filename:join(Dir, "out"),
        Opts = #{out_dir => OutDir, union_type => sum, set => sets, typedef_type => nominal},
        {ok, _} = thrift_generator:generate(File, Opts),
        ?assertEqual(ok, thrift_generator:check(File, Opts)),
        {error, {stale, Stale}} = thrift_generator:check(File, #{out_dir => OutDir}),
        TypesErl = filename:join(OutDir, "axesgate_types.erl"),
        ?assert(lists:member(TypesErl, Stale)),
        ok
    after
        rm_rf(Dir)
    end.

%% Option validation: unknown keys, bad values and non-map options are
%% returned as errors (via the shared normalizer) before the loader
%% runs, and no artifact directory is created.

generate_bad_opts_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        ?assertEqual(
            {error, {unknown_option, unknown}},
            thrift_generator:generate(File, #{out_dir => OutDir, unknown => 1})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {repr, tuple, [record, map, native]}}},
            thrift_generator:generate(File, #{out_dir => OutDir, repr => tuple})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {union_type, tagged, [record, sum]}}},
            thrift_generator:generate(File, #{out_dir => OutDir, union_type => tagged})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {set, gb_sets, [list, sets, ordset]}}},
            thrift_generator:generate(File, #{out_dir => OutDir, set => gb_sets})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {typedef_type, record, [alias, nominal]}}},
            thrift_generator:generate(File, #{out_dir => OutDir, typedef_type => record})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {out_dir, 42, [string, binary]}}},
            thrift_generator:generate(File, #{out_dir => 42})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {options, atoms, [map]}}},
            thrift_generator:generate(File, atoms)
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        %% check goes through the same validation
        ?assertEqual(
            {error, {unknown_option, unknown}},
            thrift_generator:check(File, #{out_dir => OutDir, unknown => 1})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ok
    after
        rm_rf(Dir)
    end.

%% The /1 forms default the out dir to ./src under the current working
%% directory; freshness still depends on the exact options.

generate_default_out_dir_test() ->
    Dir = tmp_dir(),
    {ok, Cwd} = file:get_cwd(),
    try
        File = write_idl(Dir),
        WorkDir = filename:join(Dir, "work"),
        ok = file:make_dir(WorkDir),
        ok = file:set_cwd(WorkDir),
        {ok, _} = thrift_generator:generate(File),
        ?assert(filelib:is_file(filename:join("src", "checkgate_types.erl"))),
        ?assertEqual(ok, thrift_generator:check(File)),
        ok
    after
        ok = file:set_cwd(Cwd),
        rm_rf(Dir)
    end.

%% The /2 artifacts match the fixture output: the fixture files checked
%% in next to this suite were generated with the Series-1 API
%% (positional out dir) before the options unification; the Series-3
%% unlinked client start refreshed the client fixture. Both sides are
%% compared as parsed forms with positions and map-field order
%% normalized away: the project's eunit runs under cover, and a
%% cover-compiled generator beam emits map literals in a different
%% field order than a plain-compiled one (the compiler's
%% maps:from_list-to-literal rewrite does not run on cover's recompile)
%% — semantically irrelevant, so the pin ignores field order but still
%% compares every form, attribute, clause and literal exactly.

generate_matches_fixture_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, #{out_dir => OutDir}),
        ?assertEqual(fixture_forms(), artifact_forms(Generated)),
        ok
    after
        rm_rf(Dir)
    end.

%% The final public surface: generate/1,2, check/1,2 and clean/1 are the
%% only generation operations; the transitional /3 forms are gone. The
%% parser-level entries stay exported (the loader and the suites call
%% them) but are internal — see the module doc.

public_api_shape_test() ->
    ?assert(erlang:function_exported(thrift_generator, generate, 1)),
    ?assert(erlang:function_exported(thrift_generator, generate, 2)),
    ?assertNot(erlang:function_exported(thrift_generator, generate, 3)),
    ?assert(erlang:function_exported(thrift_generator, check, 1)),
    ?assert(erlang:function_exported(thrift_generator, check, 2)),
    ?assertNot(erlang:function_exported(thrift_generator, check, 3)),
    ?assert(erlang:function_exported(thrift_generator, clean, 1)),
    ?assert(erlang:function_exported(thrift_generator, tokens, 1)),
    ?assert(erlang:function_exported(thrift_generator, ast, 1)),
    ?assert(erlang:function_exported(thrift_generator, parse_file, 1)),
    ?assert(erlang:function_exported(thrift_generator, parse_string, 1)),
    ok.

%% An unchanged artifact is skipped, not rewritten: with the generated
%% files made read-only a second generate still succeeds (a rewrite
%% would fail with eacces), and a tampered file is written back.

generate_skips_unchanged_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, #{out_dir => OutDir}),
        #{path := ErlPath, hrl := HrlPath} = entry_for(checkgate_types, Generated),
        {ok, ErlSource} = file:read_file(ErlPath),
        ok = file:change_mode(ErlPath, 8#444),
        ok = file:change_mode(HrlPath, 8#444),
        ?assertMatch({ok, _}, thrift_generator:generate(File, #{out_dir => OutDir})),

        ok = file:change_mode(ErlPath, 8#644),
        ok = file:write_file(ErlPath, <<"-module(tampered).">>),
        ?assertMatch({ok, _}, thrift_generator:generate(File, #{out_dir => OutDir})),
        ?assertEqual({ok, ErlSource}, file:read_file(ErlPath)),
        ok
    after
        rm_rf(Dir)
    end.

%% clean/1 removes every banner-marked file — the current artifacts and
%% orphans from drifted inputs alike — and leaves everything else
%% (hand-written modules, non-Erlang files, the IDL itself) alone.

clean_removes_generated_files_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, #{out_dir => OutDir}),
        ok = file:write_file(filename:join(OutDir, "keep.erl"), <<"-module(keep).\n">>),
        ok = file:write_file(filename:join(OutDir, "notes.txt"), <<"notes\n">>),
        ok =
            file:write_file(
                filename:join(OutDir, "ghost_client.erl"),
                <<"%%\n%% Autogenerated by Thrift Generator (0.1.0)\n%%\n-module(ghost).\n">>
            ),
        {ok, Deleted} = thrift_generator:clean(OutDir),
        Expected =
            [Path || #{path := Path} <- Generated] ++
                [HrlPath || #{hrl := HrlPath} <- Generated, is_binary(HrlPath) orelse is_list(HrlPath)] ++
                [filename:join(OutDir, "ghost_client.erl")],
        ?assertEqual(lists:sort(Expected), lists:sort(Deleted)),
        ?assertNot(filelib:is_file(filename:join(OutDir, "ghost_client.erl"))),
        ?assert(filelib:is_file(filename:join(OutDir, "keep.erl"))),
        ?assert(filelib:is_file(filename:join(OutDir, "notes.txt"))),
        ?assert(filelib:is_file(File)),
        ?assertEqual({ok, []}, thrift_generator:clean(OutDir)),
        ok
    after
        rm_rf(Dir)
    end.

%% clean/1 takes any filename chardata: with a binary out dir the
%% banner-owned files must be found and deleted exactly like with the
%% string spelling (filename:extension mirrors the path's stringness).

clean_binary_out_dir_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = unicode:characters_to_binary(filename:join(Dir, "out")),
        {ok, Generated} = thrift_generator:generate(File, #{out_dir => OutDir}),
        {ok, Deleted} = thrift_generator:clean(OutDir),
        Expected =
            [Path || #{path := Path} <- Generated] ++
                [HrlPath || #{hrl := HrlPath} <- Generated, is_binary(HrlPath) orelse is_list(HrlPath)],
        ?assertEqual(lists:sort(Expected), lists:sort(Deleted)),
        ok
    after
        rm_rf(Dir)
    end.

clean_missing_dir_test() ->
    Dir = tmp_dir(),
    try
        ?assertEqual({ok, []}, thrift_generator:clean(filename:join(Dir, "never-generated"))),
        ok
    after
        rm_rf(Dir)
    end.

tmp_dir() ->
    Base = os:getenv("TMPDIR", "/tmp"),
    Dir =
        filename:join(
            Base, "thrift_generator_check_" ++ integer_to_list(erlang:unique_integer([positive]))
        ),
    ok = file:make_dir(Dir),
    Dir.

write_idl(Dir) ->
    Path = filename:join(Dir, "checkgate.thrift"),
    ok = file:write_file(Path, ?FILE_SNIPPET),
    Path.

entry_for(Module, Generated) ->
    {value, Entry} = lists:search(fun(E) -> maps:get(module, E) =:= Module end, Generated),
    Entry.

%% Artifact contents keyed by file name, so outputs written to
%% different directories compare byte-for-byte.

-spec artifact_bytes([#{module := module(), path := file:filename_all(), hrl => file:filename_all()}]) ->
    #{string() => {ok, binary()} | {error, term()}}.
artifact_bytes(Artifacts) ->
    maps:from_list(
        lists:flatmap(
            fun(#{module := Module, path := Path} = Entry) ->
                Base = atom_to_list(Module),
                [{Base ++ ".erl", file:read_file(Path)}] ++
                    case maps:get(hrl, Entry, undefined) of
                        undefined -> [];
                        HrlPath -> [{Base ++ ".hrl", file:read_file(HrlPath)}]
                    end
            end,
            Artifacts
        )
    ).

%% The fixture artifacts parsed to normalized abstract format, keyed by
%% file name, for the pin in generate_matches_fixture_test/0. The client
%% fixture carries the Series-3 `start/1` addition and the server fixture
%% the Series-3 multiplex-aware `service` injection; the rest is
%% Series-1 output, unchanged since.

-spec fixture_forms() -> #{string() => term()}.
fixture_forms() ->
    DataDir = filename:join(
        code:lib_dir(thrift_generator), "test/thrift_generator_generate_test_data"
    ),
    maps:from_list(
        lists:map(
            fun(Name) ->
                {ok, Bin} = file:read_file(filename:join(DataDir, Name)),
                {filename:basename(Name, ".fixture"), canonical_forms(Bin)}
            end,
            [
                %% the .erl.fixture suffix keeps rebar3 eunit's test
                %% discovery (every *.erl under test/ is a candidate
                %% test module) away from the fixture sources
                "checkgate_pinger_client.erl.fixture",
                "checkgate_pinger_handler.erl.fixture",
                "checkgate_pinger_server.erl.fixture",
                "checkgate_types.erl.fixture",
                "checkgate_types.hrl.fixture",
                "checkgate_types_repr.erl.fixture"
            ]
        )
    ).

-spec artifact_forms([#{module := module(), path := file:filename_all(), hrl => file:filename_all()}]) ->
    #{string() => term()}.
artifact_forms(Artifacts) ->
    maps:map(
        fun
            (_Name, {ok, Bin}) -> canonical_forms(Bin);
            (_Name, Other) -> Other
        end,
        artifact_bytes(Artifacts)
    ).

%% Parsing drops the banner comments (the input path they name is
%% environment-dependent) and the annotation pass zeroes every position:
%% map-field reordering shifts line breaks, and only the map field order
%% itself is normalized away, by sorting each map literal's fields.

-spec canonical_forms(binary()) -> term().
canonical_forms(Bin) ->
    {ok, Tokens, _End} = erl_scan:string(binary_to_list(Bin)),
    normalize(parse_forms(merge_strings(Tokens))).

%% Long doc strings are emitted as adjacent string literals
%% (`-moduledoc("..." "...")'), which the scanner returns as separate
%% tokens and erl_parse rejects inside attribute values; merging them is
%% the lexical concatenation the compiler applies.

-spec merge_strings([erl_scan:token()]) -> [erl_scan:token()].
merge_strings([{string, Anno, S1}, {string, _Anno2, S2} | Rest]) ->
    merge_strings([{string, Anno, S1 ++ S2} | Rest]);
merge_strings([Token | Rest]) ->
    [Token | merge_strings(Rest)];
merge_strings([]) ->
    [].

%% erl_parse:parse_form/1 takes exactly one form's tokens, so the stream
%% is split on the top-level dot tokens (generated code carries no
%% mid-form dots: floats and path strings are single tokens). The
%% preprocessor directives (-define, the include-guard conditionals,
%% ...) are epp-only and erl_parse rejects them by design: they are
%% compared by their normalized tokens — a content change still shows
%% up as a diff — while anything else unparseable is a genuine emitter
%% regression and must fail the test.

-spec parse_forms([erl_scan:token()]) -> [term()].
parse_forms(Tokens) ->
    [parse_form(FormTokens) || FormTokens <- split_forms(Tokens, [], [])].

-spec parse_form([erl_scan:token()]) -> term().
parse_form(FormTokens) ->
    case erl_parse:parse_form(FormTokens) of
        {ok, Form} ->
            Form;
        {error, _Error} ->
            preprocessor_form(FormTokens)
    end.

-spec preprocessor_form([erl_scan:token()]) -> term().
preprocessor_form([{'-', _}, {atom, _, Name} | _] = Tokens) when
    Name =:= define;
    Name =:= undef;
    Name =:= ifdef;
    Name =:= ifndef;
    Name =:= 'else';
    Name =:= endif;
    Name =:= include;
    Name =:= include_lib
->
    {pp_form, 0, Name, normalize(Tokens)};
preprocessor_form(_Tokens) ->
    erlang:error(parse_form_failed).

-spec split_forms([erl_scan:token()], [erl_scan:token()], [[erl_scan:token()]]) ->
    [[erl_scan:token()]].
split_forms([], [], Acc) ->
    lists:reverse(Acc);
split_forms([{dot, _} = Dot | Rest], Current, Acc) ->
    split_forms(Rest, [], [lists:reverse([Dot | Current]) | Acc]);
split_forms([Token | Rest], Current, Acc) ->
    split_forms(Rest, [Token | Current], Acc).

-spec normalize(term()) -> term().
normalize({map, _Anno, Fields}) ->
    {map, 0, lists:sort([normalize(Field) || Field <- Fields])};
normalize(Term) when is_tuple(Term), tuple_size(Term) >= 2 ->
    case is_anno(element(2, Term)) of
        true ->
            [Tag, _Anno | Rest] = tuple_to_list(Term),
            list_to_tuple([Tag, 0 | [normalize(Element) || Element <- Rest]]);
        false ->
            list_to_tuple([normalize(Element) || Element <- tuple_to_list(Term)])
    end;
normalize(Term) when is_tuple(Term) ->
    list_to_tuple([normalize(Element) || Element <- tuple_to_list(Term)]);
normalize(Term) when is_list(Term) ->
    [normalize(Element) || Element <- Term];
normalize(Term) ->
    Term.

%% In the abstract format (and the scanner's tokens) the annotation is
%% always the second tuple element, which lets the pass zero every
%% position — map-field reordering shifts line breaks — without touching
%% integer literals ({integer, Anno, N} keeps its N in third place).

is_anno(Anno) when is_integer(Anno) ->
    true;
is_anno({Line, Column}) when is_integer(Line), is_integer(Column) ->
    true;
is_anno(Items) when is_list(Items) ->
    true;
is_anno(_Anno) ->
    false.

rm_rf(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(
                fun(Entry) ->
                    Path = filename:join(Dir, Entry),
                    case filelib:is_dir(Path) andalso not is_symlink(Path) of
                        true -> rm_rf(Path);
                        false -> ok = file:delete(Path)
                    end
                end,
                Entries
            ),
            file:del_dir(Dir);
        {error, _Reason} ->
            ok
    end.

is_symlink(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} -> true;
        _ -> false
    end.
