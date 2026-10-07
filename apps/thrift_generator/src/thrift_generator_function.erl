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

-module(thrift_generator_function).

-moduledoc """
Builds the payload record for a service function node.
""".

-include("thrift_generator.hrl").

-export([build_node/5]).

-doc """
Builds a function payload: `oneway`ness, return type (`void` for
none), `Name`, argument field nodes and declared `throws` field nodes.
""".
-spec build_node(boolean(), thrift_type() | void, function_name(), [ast_node()], [ast_node()]) ->
    function_().
build_node(Oneway, ReturnType, Name, Fields, Throws) ->
    #thrift_generator_function{
        oneway = Oneway,
        return_type = ReturnType,
        name = Name,
        fields = Fields,
        throws = Throws
    }.
