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

%% File-level tests for generate/3 and check/3: real IDL files in a
%% temp directory, artifacts on disk, drift detection and the
%% unchanged-file write skip. In-memory pipeline coverage lives in
%% thrift_generator_test.

-module(thrift_generator_generate_test).

-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").

-export([
    generate_check_up_to_date_test/0,
    generate_check_modified_file_test/0,
    generate_check_missing_file_test/0,
    generate_check_repr_drift_test/0,
    generate_check_option_axes_test/0,
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

generate_check_up_to_date_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        {ok, Generated} = thrift_generator:generate(File, OutDir, #{}),
        Modules = [Module || #{module := Module} <- Generated],
        ?assertEqual(
            [checkgate_pinger_client, checkgate_pinger_handler, checkgate_pinger_server, checkgate_types],
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

%% Option validation: only the four known keys with their exact atom
%% values; anything else — an unknown key, a bad value, a non-map —
%% fails with badarg before any file is written.

generate_bad_opts_test() ->
    Dir = tmp_dir(),
    try
        File = write_idl(Dir),
        OutDir = filename:join(Dir, "out"),
        ?assertError({badarg, #{unknown := 1}}, thrift_generator:generate(File, OutDir, #{unknown => 1})),
        ?assertError({badarg, {repr, tuple}}, thrift_generator:generate(File, OutDir, #{repr => tuple})),
        ?assertError(
            {badarg, {union_type, tagged}}, thrift_generator:generate(File, OutDir, #{union_type => tagged})
        ),
        ?assertError({badarg, {set, gb_sets}}, thrift_generator:generate(File, OutDir, #{set => gb_sets})),
        ?assertError(
            {badarg, {typedef_type, record}},
            thrift_generator:generate(File, OutDir, #{typedef_type => record})
        ),
        ?assertError({badarg, atoms}, thrift_generator:generate(File, OutDir, atoms)),
        ok
    after
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
