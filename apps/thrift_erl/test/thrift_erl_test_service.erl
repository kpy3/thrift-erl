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

%% Hand-written stand-in for a generated service description module,
%% used by the loopback Common Test suite.

-module(thrift_erl_test_service).

-behaviour(thrift_erl_service).

-export([service_info/0]).

-spec service_info() -> thrift_erl_service:service_info().
service_info() ->
    #{
        <<"add">> => #{
            name => <<"add">>,
            oneway => false,
            params =>
                {struct, [
                    {1, default, {base, i32}, <<"a">>, undefined},
                    {2, default, {base, i32}, <<"b">>, undefined}
                ]},
            reply => {base, i32}
        },
        <<"echo">> => #{
            name => <<"echo">>,
            oneway => false,
            params =>
                {struct, [
                    {1, default, {base, string}, <<"m">>, undefined}
                ]},
            reply => {base, string}
        },
        <<"size">> => #{
            name => <<"size">>,
            oneway => false,
            params =>
                {struct, [
                    {1, default, {list, {base, string}}, <<"items">>, undefined}
                ]},
            reply => {base, i32}
        },
        <<"deep">> => #{
            name => <<"deep">>,
            oneway => false,
            params =>
                {struct, [
                    {1, default, {struct, point_desc()}, <<"p">>, undefined}
                ]},
            reply => {struct, point_desc()}
        },
        <<"ping">> => #{
            name => <<"ping">>,
            oneway => false,
            params => {struct, []}
            %% void: no reply descriptor
        },
        <<"boom">> => #{
            name => <<"boom">>,
            oneway => false,
            params => {struct, []},
            reply => {base, string},
            exceptions => [
                {1, default, {struct, boom_desc()}, <<"b">>, undefined}
            ]
        },
        <<"boomInternal">> => #{
            name => <<"boomInternal">>,
            oneway => false,
            params => {struct, []},
            reply => {base, string}
        },
        <<"notify">> => #{
            name => <<"notify">>,
            oneway => true,
            params =>
                {struct, [
                    {1, default, {base, string}, <<"m">>, undefined}
                ]}
        }
    }.

-spec point_desc() -> thrift_erl_binary:struct_desc().
point_desc() ->
    {struct, [
        {1, default, {base, i32}, <<"x">>, undefined},
        {2, default, {base, i32}, <<"y">>, undefined}
    ]}.

-spec boom_desc() -> thrift_erl_binary:struct_desc().
boom_desc() ->
    {exception, [
        {1, default, {base, string}, <<"message">>, undefined}
    ]}.
