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

-module(thrift_runtime_test_buggy_codec).

-moduledoc """
Broken stand-in for a generated RPC codec: both functions are exported
but call a module that does not exist, raising `undef` from INSIDE the
function — the genuine-bug case the runtime's hook fallback must
re-raise, not mask (a stale codec after a reload raises `undef` at the
call site with the function no longer exported).
""".

-export([encode/1, decode/1]).

-spec encode(term()) -> no_return().
encode(Value) ->
    _ = Value,
    missing_thrift_codec:encode(<<>>).

-spec decode(term()) -> no_return().
decode(Bin) ->
    _ = Bin,
    missing_thrift_codec:decode(<<>>).
