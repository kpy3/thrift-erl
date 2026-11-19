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

-module(thrift_generator_rpc_hooked_service).

-moduledoc """
Service descriptor for the RPC hook proof in `thrift_generator_SUITE':
the generated `MainService' info with deliberately corrupted descriptor
types (names kept, every leaf type replaced) but intact `codecs' hooks.
A successful call through this descriptor is only possible when both the
client and the server use the specialized hooks; the generic engine
would fail on the corrupted types.
""".

-export([service_info/0]).

-spec service_info() -> thrift_runtime_service:service_info().
service_info() ->
    #{<<"MainService">> := Fns} = main_types:service_info(),
    maps:from_list([{Fn, corrupt(Info)} || {Fn, Info} <- maps:to_list(Fns)]).

corrupt(Info0) ->
    Info = Info0#{params := corrupt_desc(maps:get(params, Info0))},
    case Info of
        #{reply := Reply} -> Info#{reply := corrupt_desc(Reply)};
        _ -> Info
    end.

corrupt_desc({struct, {struct, Fields}}) ->
    {struct, {struct, [corrupt_field(F) || F <- Fields]}};
corrupt_desc(_) ->
    {base, binary}.

corrupt_field({Id, Required, Type, Name, Default}) ->
    {Id, Required, corrupt_desc(Type), Name, Default}.
