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

-module(thrift_runtime_test_hooked_service).

-moduledoc """
Hand-written service carrying a `codecs` hook that points at
`thrift_runtime_test_buggy_codec': the hook exists and is exported, but
raises `undef` from inside. The runtime must let that crash surface
instead of silently falling back to the descriptor engine.
""".

-behaviour(thrift_runtime_service).

-export([service_info/0]).

-spec service_info() -> thrift_runtime_service:service_info().
service_info() ->
    Info = maps:get(<<"echo">>, thrift_runtime_test_service:service_info()),
    #{
        <<"echo">> => Info#{
            codecs => #{
                thrift_runtime_binary => #{
                    params => {thrift_runtime_test_buggy_codec, encode, decode},
                    result => {thrift_runtime_test_buggy_codec, encode, decode}
                }
            }
        }
    }.
