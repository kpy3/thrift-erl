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

%% Handler implementing the callbacks generated from the semantic
%% fixture (`MainService`): the loopback cases run the full generated
%% stack — client wrappers, server dispatch, records at the boundary.
%% The record shapes mirror the emitted definitions: the `namespace
%% erl` of each fixture file prefixes the record tags (`shared_inner`
%% lives in shared.thrift, `main_failed` in main.thrift).

-module(thrift_generator_test_handler).

-export([ping/0, area/2, fetch/1, fire/1]).

-record(shared_inner, {name}).
-record(main_failed, {reason}).

-spec ping() -> {ok, undefined}.
ping() ->
    {ok, undefined}.

-spec area(integer(), integer()) -> {ok, integer()}.
area(W, H) ->
    {ok, W * H}.

-spec fetch(integer()) ->
    {ok, #shared_inner{}}
    | {error, {exception, binary(), #main_failed{}}}.
fetch(Id) when Id < 0 ->
    {error, {exception, <<"Failed">>, #main_failed{reason = <<"negative id">>}}};
fetch(Id) ->
    {ok, #shared_inner{name = integer_to_binary(Id)}}.

-spec fire(integer()) -> ok.
fire(Code) ->
    case whereis(thrift_generator_test_sink) of
        undefined ->
            ok;
        Pid ->
            Pid ! {fired, Code},
            ok
    end.
