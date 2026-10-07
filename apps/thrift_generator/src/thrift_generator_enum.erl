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

-module(thrift_generator_enum).

-moduledoc """
Builds the payload record for an `enum` definition node.
""".

-include("thrift_generator.hrl").

-export([build_node/2]).

-doc """
Builds an enum payload: `Name` with its members. Members without an
explicit value carry `undefined` until the semantic pass numbers them.
""".
-spec build_node(enum_name(), [enum_value()]) -> enum_().
build_node(Name, Values) ->
    #thrift_generator_enum{
        name = Name,
        values = Values
    }.
