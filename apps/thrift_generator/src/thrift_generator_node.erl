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

-module(thrift_generator_node).

-moduledoc """
Builds the payload record of an AST node from its kind atom and
constructor arguments.

The `type_module` field of #thrift_generator_node{} keeps carrying the
kind atom: the semantic pass dispatches on it, and the atom still
names the kind even though no per-kind module exists anymore.
""".

-export([build/2]).

-include("thrift_generator.hrl").

-doc "Builds the payload record of `Kind` from its constructor arguments.".
-spec build(module(), [term()]) -> term().
build(Kind, Args) when is_list(Args) ->
    case maps:get(Kind, ?NODE_BUILDERS, error) of
        {Tag, Fields} when length(Args) =:= length(Fields) ->
            list_to_tuple([Tag | Args]);
        {Tag, Fields} ->
            erlang:error({bad_node_args, Kind, Tag, Fields, Args});
        error ->
            erlang:error({unknown_node_kind, Kind})
    end.
