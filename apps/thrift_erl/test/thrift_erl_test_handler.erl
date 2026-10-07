%% Copyright 2025 Sergei Yelin
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

%% Handler used by the loopback Common Test suite. Functions mirror
%% `thrift_erl_test_service:service_info/0`.

-module(thrift_erl_test_handler).

-export([
    add/2,
    echo/1,
    size/1,
    deep/1,
    ping/0,
    boom/0,
    boomInternal/0,
    notify/1
]).

-spec add(integer(), integer()) -> {ok, integer()}.
add(A, B) ->
    {ok, A + B}.

-spec echo(binary()) -> {ok, binary()}.
echo(M) ->
    {ok, M}.

-spec size(list()) -> {ok, non_neg_integer()}.
size(Items) ->
    {ok, length(Items)}.

-spec deep(map()) -> {ok, map()}.
deep(#{<<"x">> := X, <<"y">> := Y}) ->
    {ok, #{<<"x">> => Y, <<"y">> => X}}.

-spec ping() -> {ok, undefined}.
ping() ->
    {ok, undefined}.

-spec boom() -> {error, {exception, binary(), map()}}.
boom() ->
    {error, {exception, <<"b">>, #{<<"message">> => <<"as declared">>}}}.

-spec boomInternal() -> no_return().
boomInternal() ->
    erlang:error(deliberate).

%% One-way functions report to the registered sink process (the CT
%% case), when there is one.

-spec notify(binary()) -> ok.
notify(M) ->
    case whereis(thrift_erl_test_sink) of
        undefined ->
            ok;
        Pid ->
            Pid ! {notified, M},
            ok
    end.
