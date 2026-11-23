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

-module(thrift_bench_schema_head_types).

-moduledoc """
Head-side schema fixture for the deterministic benchmark schema test
(`thrift_bench_regression_test`). Stands in for a generated types module:
the paired benchmark's real head beams are produced only by
`scripts/bench-regression`, so plain `rebar3 eunit` has none on the code
path. Exports the introspection the schema rows resolve through:
`record_fields/1` feeds the default-repr mapping, `struct_info/1` hands
the runtime engine the inline descriptor it encodes the decode wire
bytes from. Mirrors `Xtruct` of the golden `ThriftTest.idl`.
""".

-export([struct_info/1, record_fields/1]).

-spec struct_info(binary()) -> {struct, [tuple()]} | error.
struct_info(<<"Xtruct">>) ->
    {struct, [
        {1, optional, {base, string}, <<"string_thing">>, undefined},
        {4, optional, {base, i8}, <<"byte_thing">>, undefined},
        {9, optional, {base, i32}, <<"i32_thing">>, undefined},
        {11, optional, {base, i64}, <<"i64_thing">>, undefined}
    ]};
struct_info(_) ->
    error.

-spec record_fields(binary()) -> {atom(), [binary()]} | 'none'.
record_fields(<<"Xtruct">>) ->
    {xtruct, [<<"string_thing">>, <<"byte_thing">>, <<"i32_thing">>, <<"i64_thing">>]};
record_fields(_) ->
    none.
