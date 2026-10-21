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

%% Handler for the multiplexed-server coverage; functions mirror
%% `thrift_runtime_test_service2:service_info/0`. The answers differ from
%% `thrift_runtime_test_handler` under the same function names (add
%% multiplies, echo marks its source) so a test can tell the services
%% apart.

-module(thrift_runtime_test_handler2).

-export([add/2, echo/1, ping/0, notify/1]).

-spec add(integer(), integer()) -> {ok, integer()}.
add(A, B) ->
    {ok, A * B}.

-spec echo(binary()) -> {ok, binary()}.
echo(M) ->
    {ok, <<"echo2:", M/binary>>}.

-spec ping() -> {ok, undefined}.
ping() ->
    {ok, undefined}.

-spec notify(binary()) -> ok.
notify(M) ->
    case whereis(thrift_runtime_test_sink) of
        undefined ->
            ok;
        Pid ->
            Pid ! {notified2, M},
            ok
    end.
