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

-module(thrift_bench_rpc_handler).

-moduledoc """
Echo handler for the loopback RPC benchmark (`thrift_bench_rpc`). Mirrors
the `ThriftTest` functions the benchmark calls; arguments arrive as wire
values (no `record_api`), so every function simply returns its argument.
""".

-export([testVoid/0, testString/1, testStruct/1, testList/1]).

-spec testVoid() -> ok.
testVoid() ->
    ok.

-spec testString(binary()) -> {ok, binary()}.
testString(Thing) ->
    {ok, Thing}.

-spec testStruct(map()) -> {ok, map()}.
testStruct(Thing) ->
    {ok, Thing}.

-spec testList([integer()]) -> {ok, [integer()]}.
testList(Thing) ->
    {ok, Thing}.
