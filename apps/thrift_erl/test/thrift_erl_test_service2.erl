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

%% A second service descriptor for the multiplexed-server coverage.
%% Deliberately declares the SAME function names as
%% `thrift_erl_test_service' (add, echo, ping, notify) — the multiplex
%% tests rely on the two services answering differently under the same
%% plain names, which proves the `Service:' prefix actually routed.

-module(thrift_erl_test_service2).

-behaviour(thrift_erl_service).

-export([service_info/0]).

-spec service_info() -> thrift_erl_service:service_info().
service_info() ->
    #{
        <<"add">> => #{
            name => <<"add">>,
            oneway => false,
            params =>
                {struct,
                    {struct, [
                        {1, default, {base, i32}, <<"a">>, undefined},
                        {2, default, {base, i32}, <<"b">>, undefined}
                    ]}},
            reply => {base, i32}
        },
        <<"echo">> => #{
            name => <<"echo">>,
            oneway => false,
            params =>
                {struct,
                    {struct, [
                        {1, default, {base, string}, <<"m">>, undefined}
                    ]}},
            reply => {base, string}
        },
        <<"ping">> => #{
            name => <<"ping">>,
            oneway => false,
            params => {struct, {struct, []}}
            %% void: no reply descriptor
        },
        <<"notify">> => #{
            name => <<"notify">>,
            oneway => true,
            params =>
                {struct,
                    {struct, [
                        {1, default, {base, string}, <<"m">>, undefined}
                    ]}}
        }
    }.
