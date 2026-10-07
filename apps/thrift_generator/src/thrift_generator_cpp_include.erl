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

-module(thrift_generator_cpp_include).

-moduledoc """
Builds the payload record for a `cpp_include` header node. Kept for
parser completeness; irrelevant to Erlang code generation.
""".

-include("thrift_generator.hrl").

-export([build_node/1]).

-doc "Builds a cpp_include payload: the included file path as written.".
-spec build_node(include_path()) -> cpp_include().
build_node(Path) ->
    #thrift_generator_cpp_include{path = Path}.
