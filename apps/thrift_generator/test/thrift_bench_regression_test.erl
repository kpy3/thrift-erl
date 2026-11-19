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
    median_handles_even_sample_count_test/0
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
