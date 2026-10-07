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

-module(thrift_generator_namespace).

-moduledoc """
Builds the payload record for a `namespace` header node.
""".

-include("thrift_generator.hrl").

-export([build_node/2]).

-doc """
Builds a namespace payload: the language `Scope` (or `<<"*">>`) and
the namespace `Name`.
""".
-spec build_node(namespace_scope(), namespace_name()) -> namespace_().
build_node(Scope, Name) ->
    #thrift_generator_namespace{
        scope = Scope,
        name = Name
    }.
