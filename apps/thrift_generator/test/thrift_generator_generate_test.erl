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

%% File-level tests for the generate and check frontends (legacy /3
%% forms and the new /1,/2 options-map forms): real IDL files in a
%% temp directory, artifacts on disk, drift detection and the
%% unchanged-file write skip. In-memory pipeline coverage lives in
%% thrift_generator_test.

-module(thrift_generator_generate_test).

-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").

-export([
    options_normalize_test/0,
    generate_check_up_to_date_test/0,
    generate_check_modified_file_test/0,
    generate_check_missing_file_test/0,
    generate_check_repr_drift_test/0,
    generate_check_option_axes_test/0,
    generate_and_check_new_api_test/0,
    generate_bad_opts_test/0,
    generate_skips_unchanged_test/0,
    clean_removes_generated_files_test/0,
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
        {ok, Generated} = thrift_generator:generate(File, OutDir, #{}),
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
        ?assertEqual(ok, thrift_generator:check(File, OutDir, #{})),
        ok
    after
        rm_rf(Dir)
    end.

generate_check_modified_file_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, OutDir, #{}),
        #{path := StalePath} = entry_for(checkgate_pinger_server, Generated),
        ok = file:write_file(StalePath, <<"-module(tampered).">>),
        ?assertEqual({error, {stale, [StalePath]}}, thrift_generator:check(File, OutDir, #{})),
        ok
    after
        rm_rf(Dir)
    end.

generate_check_missing_file_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, OutDir, #{}),
        #{hrl := HrlPath} = entry_for(checkgate_types, Generated),
        ok = file:delete(HrlPath),
        ?assertEqual({error, {stale, [HrlPath]}}, thrift_generator:check(File, OutDir, #{})),

        %% a fresh directory has nothing yet — every artifact is stale
        ?assertMatch(
            {error, {stale, [_ | _]}},
            thrift_generator:check(File, filename:join(Dir, "fresh"), #{})
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
        {ok, _} = thrift_generator:generate(File, OutDir, #{repr => record}),
        {error, {stale, Stale}} = thrift_generator:check(File, OutDir, #{repr => map}),
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
        Opts = #{union_type => sum, set => sets, typedef_type => nominal},
        {ok, _} = thrift_generator:generate(File, OutDir, Opts),
        ?assertEqual(ok, thrift_generator:check(File, OutDir, Opts)),
        {error, {stale, Stale}} = thrift_generator:check(File, OutDir, #{}),
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
            thrift_generator:generate(File, OutDir, #{unknown => 1})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {repr, tuple, [record, map, native]}}},
            thrift_generator:generate(File, OutDir, #{repr => tuple})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {union_type, tagged, [record, sum]}}},
            thrift_generator:generate(File, OutDir, #{union_type => tagged})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {set, gb_sets, [list, sets, ordset]}}},
            thrift_generator:generate(File, OutDir, #{set => gb_sets})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {typedef_type, record, [alias, nominal]}}},
            thrift_generator:generate(File, OutDir, #{typedef_type => record})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {out_dir, 42, [string, binary]}}},
            thrift_generator:generate(File, OutDir, #{out_dir => 42})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ?assertEqual(
            {error, {bad_option, {options, atoms, [map]}}},
            thrift_generator:generate(File, OutDir, atoms)
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        %% check goes through the same validation
        ?assertEqual(
            {error, {unknown_option, unknown}},
            thrift_generator:check(File, OutDir, #{unknown => 1})
        ),
        ?assertNot(filelib:is_dir(OutDir)),
        ok
    after
        rm_rf(Dir)
    end.

%% The new /1,/2 forms: generate/2 takes out_dir from the options map,
%% generate/1 (and check/1) in a temporary working directory default to
%% ./src, freshness still depends on the exact options, and the /1,/2
%% artifacts are byte-identical to the transitional /3 output.

generate_and_check_new_api_test() ->
    Dir = tmp_dir(),
    {ok, Cwd} = file:get_cwd(),
    try
        File = write_idl(Dir),
        OutOld = filename:join(Dir, "out_old"),
        OutNew = filename:join(Dir, "out_new"),
        {ok, OldArtifacts} = thrift_generator:generate(File, OutOld, #{}),
        {ok, NewArtifacts} = thrift_generator:generate(File, #{out_dir => OutNew}),
        ?assertEqual(artifact_bytes(OldArtifacts), artifact_bytes(NewArtifacts)),
        ?assertEqual(ok, thrift_generator:check(File, #{out_dir => OutNew})),

        %% a different repr regenerates different sources: the new check
        %% form reports them stale the same way check/3 does
        {error, {stale, Stale}} = thrift_generator:check(File, #{out_dir => OutNew, repr => map}),
        ?assert(lists:member(filename:join(OutNew, "checkgate_types.erl"), Stale)),

        %% /1 forms from a temporary working directory use ./src
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

%% An unchanged artifact is skipped, not rewritten: with the generated
%% files made read-only a second generate still succeeds (a rewrite
%% would fail with eacces), and a tampered file is written back.

generate_skips_unchanged_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, OutDir, #{}),
        #{path := ErlPath, hrl := HrlPath} = entry_for(checkgate_types, Generated),
        {ok, ErlSource} = file:read_file(ErlPath),
        ok = file:change_mode(ErlPath, 8#444),
        ok = file:change_mode(HrlPath, 8#444),
        ?assertMatch({ok, _}, thrift_generator:generate(File, OutDir, #{})),

        ok = file:change_mode(ErlPath, 8#644),
        ok = file:write_file(ErlPath, <<"-module(tampered).">>),
        ?assertMatch({ok, _}, thrift_generator:generate(File, OutDir, #{})),
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
        {ok, Generated} = thrift_generator:generate(File, OutDir, #{}),
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
