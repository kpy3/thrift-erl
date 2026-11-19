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

-module(thrift_generator_rpc_wire_handler).

-moduledoc """
Wire-value handler for the RPC codec hook tests in
`thrift_generator_SUITE'. Implements the `MainService' callbacks of the
semantic fixture without `record_api': arguments arrive and results leave
as wire values (maps, binaries, integers), exactly what the runtime's
params/result codecs produce and consume.
""".

-export([ping/0, area/2, fetch/1, fire/1]).

-spec ping() -> {ok, undefined}.
ping() ->
    {ok, undefined}.

-spec area(integer(), integer()) -> {ok, integer()}.
area(W, H) ->
    {ok, W * H}.

-spec fetch(integer()) -> {ok, map()} | {error, {exception, binary(), map()}}.
fetch(Id) when Id < 0 ->
    {error, {exception, <<"Failed">>, #{<<"reason">> => <<"negative id">>}}};
fetch(Id) ->
    {ok, #{<<"name">> => integer_to_binary(Id)}}.

-spec fire(integer()) -> ok.
fire(Code) when is_integer(Code) ->
    ok.
