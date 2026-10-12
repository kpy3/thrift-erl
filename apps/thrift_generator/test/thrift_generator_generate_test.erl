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
    generate_skips_unchanged_test/0
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
