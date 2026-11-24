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

-module(thrift_bench_regression_test).

-moduledoc "Deterministic checks for the paired benchmark statistics.".

-include_lib("stdlib/include/assert.hrl").

-export([
    paired_ratio_uses_throughput_direction_test/0,
    constant_ratio_has_degenerate_interval_test/0,
    wide_interval_is_inconclusive_test/0,
    median_handles_even_sample_count_test/0,
    schema_rows_use_current_head_module_facade_test/0,
    schema_cases_run_end_to_end_with_default_repr_test/0,
    rewrite_resolved_refs_rewrites_keys_and_values_test/0
]).

paired_ratio_uses_throughput_direction_test() ->
    Samples = [{100, 110, 1000} || _ <- lists:seq(1, 15)],
    #{ratio := Ratio, pass := false} = thrift_bench_regression:evaluate(Samples, 0.99),
    ?assert(abs(Ratio - 100 / 110) < 1.0e-12),
    ok.

constant_ratio_has_degenerate_interval_test() ->
    Samples = [{100, 100, 1000} || _ <- lists:seq(1, 15)],
    #{ratio := 1.0, ci_low := 1.0, ci_high := 1.0, pass := true} =
        thrift_bench_regression:evaluate(Samples, 0.99),
    ok.

wide_interval_is_inconclusive_test() ->
    Samples = lists:flatmap(
        fun(_) -> [{100, 100, 1000}, {50, 100, 1000}, {150, 100, 1000}] end,
        lists:seq(1, 11)
    ),
    #{
        ratio := Ratio,
        ci_low := CiLow,
        pass := false,
        inconclusive := true
    } = thrift_bench_regression:evaluate(Samples, 0.99),
    ?assertEqual(1.0, Ratio),
    ?assert(CiLow < 0.99),
    ok.

median_handles_even_sample_count_test() ->
    ?assertEqual(2.5, thrift_bench_regression:median([4, 1, 3, 2])),
    ok.

%% The schema family compares the runtime's advanced descriptor call with
%% the generated type-first facade on the same head-side modules and
%% codecs: the base side carries the literal `{struct, {ref, Module, Name}}'
%% descriptor into `thrift_runtime', the head side carries the module and
%% canonical type atom into the generated `encode/3'/`decode/3'. Both
%% sides must reference the current head module — historical wrappers are
%% never executed here.

schema_rows_use_current_head_module_facade_test() ->
    Value = #{
        <<"string_thing">> => <<"hi">>,
        <<"byte_thing">> => 1,
        <<"i32_thing">> => 2,
        <<"i64_thing">> => 3
    },
    Spec = #{
        id => <<"Xtruct">>,
        struct => <<"Xtruct">>,
        value => Value,
        base_prefix => <<"goldentest">>,
        base_module => goldentest080a_types,
        head_prefix => <<"goldentest">>,
        head_module => goldentesthead_types
    },
    Wire = <<"encoded-wire-bytes">>,
    Encode = thrift_bench_regression:schema_case(Spec, encode, Value, #{}),
    ?assertEqual({<<"Xtruct">>, binary, schema, encode}, maps:get(key, Encode)),
    ?assertEqual(
        {encode, {runtime, {struct, {ref, goldentesthead_types, <<"Xtruct">>}}, Value, #{}}},
        maps:get(base, Encode)
    ),
    ?assertEqual(
        {encode, {facade, goldentesthead_types, xtruct, Value, #{}}},
        maps:get(head, Encode)
    ),
    Decode = thrift_bench_regression:schema_case(Spec, decode, Wire, #{repr => record}),
    ?assertEqual({<<"Xtruct">>, binary, schema, decode}, maps:get(key, Decode)),
    ?assertEqual(
        {decode, {runtime, {struct, {ref, goldentesthead_types, <<"Xtruct">>}}, Wire, #{repr => record}}},
        maps:get(base, Decode)
    ),
    ?assertEqual(
        {decode, {facade, goldentesthead_types, xtruct, Wire, #{repr => record}}},
        maps:get(head, Decode)
    ),
    ok.

%% `schema_cases/1' is the production entry point behind those rows: it
%% resolves the struct's representation through the head module's
%% introspection (`repr_mode_of' + the default-repr mapping), encodes the
%% value through the runtime binary engine to build the decode wire
%% bytes, and filters on THRIFT_BENCH_ENTRY=schema with
%% THRIFT_BENCH_PROTOCOL=binary. The row shapes still come out of
%% `schema_case/4', so this test pins the end-to-end plumbing instead of
%% only the literal row shape.

schema_cases_run_end_to_end_with_default_repr_test() ->
    Spec = #{
        id => <<"Xtruct">>,
        struct => <<"Xtruct">>,
        value => #{
            <<"string_thing">> => <<"hi">>,
            <<"byte_thing">> => 1,
            <<"i32_thing">> => 2,
            <<"i64_thing">> => 3
        },
        base_prefix => <<"goldentest">>,
        base_module => goldentest080a_types,
        head_prefix => <<"fixture">>,
        head_module => thrift_bench_schema_head_types
    },
    with_schema_env(
        "binary",
        fun() ->
            [Encode, Decode] = thrift_bench_regression:schema_cases(Spec),
            ?assertEqual({<<"Xtruct">>, binary, schema, encode}, maps:get(key, Encode)),
            ?assertEqual(
                {encode, {facade, thrift_bench_schema_head_types, xtruct, maps:get(value, Spec), #{}}},
                maps:get(head, Encode)
            ),
            %% Xtruct is a tuple-record struct on the head module, so the
            %% default-repr mapping supplies `record' on the decode row.
            ?assertEqual({<<"Xtruct">>, binary, schema, decode}, maps:get(key, Decode)),
            ?assertMatch(
                {decode,
                    {runtime, {struct, {ref, thrift_bench_schema_head_types, <<"Xtruct">>}}, _, #{
                        repr := record
                    }}},
                maps:get(base, Decode)
            ),
            ?assertMatch(
                {decode, {facade, thrift_bench_schema_head_types, xtruct, _, #{repr := record}}},
                maps:get(head, Decode)
            )
        end
    ),
    %% Selection stays binary-only: any other protocol drops the rows.
    with_schema_env(
        "compact",
        fun() -> ?assertEqual([], thrift_bench_regression:schema_cases(Spec)) end
    ),
    ok.

with_schema_env(Protocol, Fun) ->
    EntryPrev = os:getenv("THRIFT_BENCH_ENTRY"),
    ProtocolPrev = os:getenv("THRIFT_BENCH_PROTOCOL"),
    os:putenv("THRIFT_BENCH_ENTRY", "schema"),
    os:putenv("THRIFT_BENCH_PROTOCOL", Protocol),
    try
        Fun()
    after
        restore_env("THRIFT_BENCH_ENTRY", EntryPrev),
        restore_env("THRIFT_BENCH_PROTOCOL", ProtocolPrev)
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).

%% The rename walk must stay shape-agnostic: a resolved reference can
%% sit in a map key as well as in a value, and both sides are retargeted.

rewrite_resolved_refs_rewrites_keys_and_values_test() ->
    RefMap = #{<<"old">> => <<"new">>},
    Model = #{
        {resolved_ref, <<"old">>, <<"T">>, #{}} =>
            {resolved_ref, <<"old">>, <<"T">>, #{}},
        <<"plain">> => {list, {resolved_ref, <<"old">>, <<"T">>, #{}}, #{}}
    },
    ?assertEqual(
        #{
            {resolved_ref, <<"new">>, <<"T">>, #{}} =>
                {resolved_ref, <<"new">>, <<"T">>, #{}},
            <<"plain">> => {list, {resolved_ref, <<"new">>, <<"T">>, #{}}, #{}}
        },
        thrift_bench_regression:rewrite_resolved_refs(Model, RefMap)
    ),
    ok.
