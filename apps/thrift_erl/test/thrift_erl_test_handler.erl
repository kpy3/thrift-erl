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
    notify/1,
    slow/0
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
    {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}}.

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

%% Blocks until the ETS gate `thrift_erl_drain_gate` says `go` (or the
%% 10 s deadline passes, so a broken latch fails the case with a reply
%% instead of hanging a connection). Lets drain tests hold an in-flight
%% call for as long as they want.

-spec slow() -> {ok, binary()}.
slow() ->
    Gate = thrift_erl_drain_gate,
    ets:update_counter(Gate, entered, {2, 1}, {entered, 0}),
    wait_gate(Gate, 100).

-spec wait_gate(atom(), non_neg_integer()) -> {ok, binary()}.
wait_gate(_Gate, 0) ->
    {ok, <<"gave up">>};
wait_gate(Gate, Tries) ->
    case ets:lookup(Gate, go) of
        [{go, true}] ->
            {ok, <<"done">>};
        _ ->
            timer:sleep(20),
            wait_gate(Gate, Tries - 1)
    end.
