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

%% Unit tests for the {thrift, [...]} options of the provider: the config
%% proplist is read into the generator's normalized generate_opts() map
%% (host-only `files' stripped, `out_dir' defaulted) and an invalid value
%% fails with the same reason the library's normalize/1 reports, rendered
%% by the shared formatter. End-to-end provider runs (rebar3 state
%% mocked) stay untested — the plugin delegates everything else to the
%% generator's own file-level suites.

-module(rebar3_thrift_opts_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    defaults_test/0,
    axes_test/0,
    bad_value_test/0,
    unknown_option_test/0,
    bad_out_dir_test/0,
    clean_out_dir_test/0,
    bad_opt_rendering_test/0,
    duplicate_keys_first_wins_test/0
]).

defaults_test() ->
    ?assertEqual(
        {ok, #{
            out_dir => "src",
            repr => record,
            union_type => record,
            set => list,
            typedef_type => alias,
            enum_case => preserve
        }},
        rebar3_thrift:thrift_gen_opts([])
    ),
    ok.

axes_test() ->
    ?assertEqual(
        {ok, #{
            out_dir => "src",
            repr => map,
            union_type => sum,
            set => ordset,
            typedef_type => nominal,
            enum_case => lower
        }},
        rebar3_thrift:thrift_gen_opts([
            {files, ["src/my_api.thrift"]},
            {repr, map},
            {union_type, sum},
            {set, ordset},
            {typedef_type, nominal},
            {enum_case, lower}
        ])
    ),
    %% an explicit out_dir rides through; the host-only `files' key
    %% never reaches the normalized generator options
    ?assertEqual(
        {ok, #{
            out_dir => "generated",
            repr => record,
            union_type => record,
            set => list,
            typedef_type => alias,
            enum_case => preserve
        }},
        rebar3_thrift:thrift_gen_opts([
            {files, ["idl/my_api.thrift"]},
            {out_dir, "generated"}
        ])
    ),
    ok.

%% Config terms are unchecked by rebar3: a string where the atom is
%% meant must fail the provider with a rendered message, not crash
%% rebar3 with a raw badarg — the same reason the library reports.

bad_value_test() ->
    ?assertEqual(
        {error, {bad_option, {repr, "map", [record, map, native]}}},
        rebar3_thrift:thrift_gen_opts([{repr, "map"}])
    ),
    ?assertEqual(
        {error, {bad_option, {set, gb_sets, [list, sets, ordset]}}},
        rebar3_thrift:thrift_gen_opts([{set, gb_sets}])
    ),
    ?assertEqual(
        {error, {bad_option, {enum_case, "lower", [preserve, lower]}}},
        rebar3_thrift:thrift_gen_opts([{enum_case, "lower"}])
    ),
    ok.

%% A config typo is an unknown option, exactly like a bad key passed to
%% the library facade.

unknown_option_test() ->
    ?assertEqual(
        {error, {unknown_option, reper}},
        rebar3_thrift:thrift_gen_opts([{reper, map}])
    ),
    ok.

%% out_dir takes only chardata; anything else is a bad_option naming the
%% allowed kinds, like every other axis.

bad_out_dir_test() ->
    ?assertEqual(
        {error, {bad_option, {out_dir, 42, [string, binary]}}},
        rebar3_thrift:thrift_gen_opts([{out_dir, 42}])
    ),
    ?assertEqual(
        {error, {bad_option, {out_dir, ["/x" | 42], [string, binary]}}},
        rebar3_thrift:thrift_gen_opts([{out_dir, ["/x" | 42]}])
    ),
    ok.

%% The clean hook validates its out dir through the shared contract
%% before deleting anything: an invalid configured value answers the
%% shared bad_option reason (rendered by the provider's format_error/1
%% like every other option error) and the deletion never runs; a valid
%% value — or an absent key, defaulting to "src" — answers the resolved
%% dir. The do/1 wiring itself stays untested like the rest of the
%% host rebar3 API (it needs a rebar_state).

clean_out_dir_test() ->
    ?assertEqual({ok, "src"}, rebar3_thrift_clean:out_dir([])),
    ?assertEqual({ok, "gen"}, rebar3_thrift_clean:out_dir([{out_dir, "gen"}])),
    ?assertEqual(
        {error, {bad_option, {out_dir, 42, [string, binary]}}},
        rebar3_thrift_clean:out_dir([{out_dir, 42}])
    ),
    ?assertEqual(
        {error, {bad_option, {out_dir, ["/x" | 42], [string, binary]}}},
        rebar3_thrift_clean:out_dir([{out_dir, ["/x" | 42]}])
    ),
    %% the shared reason renders through the same formatter the command
    %% path uses
    ?assertEqual(
        "invalid value for out_dir: 42 (allowed: string, binary)",
        unicode:characters_to_list(
            rebar3_thrift_clean:format_error({bad_option, {out_dir, 42, [string, binary]}})
        )
    ),
    ok.

%% The provider renders option errors through the shared formatter, so
%% the console shows exactly what the standalone tool prints.

bad_opt_rendering_test() ->
    ?assertEqual(
        "invalid value for repr: \"map\" (allowed: record, map, native)",
        unicode:characters_to_list(
            rebar3_thrift:format_error({bad_option, {repr, "map", [record, map, native]}})
        )
    ),
    ?assertEqual(
        "unknown option reper",
        unicode:characters_to_list(rebar3_thrift:format_error({unknown_option, reper}))
    ),
    ok.

%% A duplicate key keeps the first occurrence, exactly like the
%% proplists lookup the provider answered before the map conversion: a
%% later value never overrides an earlier one (and a bad later value
%% must not fail a config the first entry already settled).

duplicate_keys_first_wins_test() ->
    ?assertMatch(
        {ok, #{repr := map}},
        rebar3_thrift:thrift_gen_opts([{repr, map}, {repr, native}])
    ),
    ?assertMatch(
        {ok, #{repr := native}},
        rebar3_thrift:thrift_gen_opts([{repr, native}, {repr, "bad"}])
    ),
    ok.
