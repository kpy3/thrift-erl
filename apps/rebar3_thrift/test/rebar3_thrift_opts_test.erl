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

%% Unit tests for the {thrift, [...]} option axes of the provider: the
%% config terms are read into the generator's generate_opts() map and
%% an invalid value fails with a renderable error instead of a raw
%% badarg. End-to-end provider runs (rebar3 state mocked) stay
%% untested — the plugin delegates everything else to the generator's
%% own file-level suites.

-module(rebar3_thrift_opts_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    defaults_test/0,
    axes_test/0,
    bad_value_test/0,
    bad_opt_rendering_test/0
]).

defaults_test() ->
    ?assertEqual(
        {ok, #{repr => record, union_type => record, set => list, typedef_type => alias}},
        rebar3_thrift:thrift_gen_opts([])
    ),
    ok.

axes_test() ->
    ?assertEqual(
        {ok, #{repr => map, union_type => sum, set => ordset, typedef_type => nominal}},
        rebar3_thrift:thrift_gen_opts([
            {files, ["src/my_api.thrift"]},
            {out_dir, "src"},
            {repr, map},
            {union_type, sum},
            {set, ordset},
            {typedef_type, nominal}
        ])
    ),
    ok.

%% Config terms are unchecked by rebar3: a string where the atom is
%% meant must fail the provider with a rendered message, not crash
%% rebar3 with a raw badarg.

bad_value_test() ->
    ?assertEqual(
        {error, {bad_opt, {repr, "map", [record, map, native]}}},
        rebar3_thrift:thrift_gen_opts([{repr, "map"}])
    ),
    ?assertEqual(
        {error, {bad_opt, {set, gb_sets, [list, sets, ordset]}}},
        rebar3_thrift:thrift_gen_opts([{set, gb_sets}])
    ),
    ok.

bad_opt_rendering_test() ->
    ?assertEqual(
        "invalid value \"map\" for the {thrift, repr} option (expected one of: record | map | native)",
        unicode:characters_to_list(
            rebar3_thrift:format_error({bad_opt, {repr, "map", [record, map, native]}})
        )
    ),
    ok.
