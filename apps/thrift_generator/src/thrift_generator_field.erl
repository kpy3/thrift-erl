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

-module(thrift_generator_field).

-moduledoc """
Builds the payload record for a field node inside structs, unions,
exceptions, function arguments and `throws`.
""".

-include("thrift_generator.hrl").

-export([build_node/5]).

-doc """
Builds a field payload: numeric `Id` (implicit ids stay `undefined`
until the semantic pass), requiredness, `Type`, `Name` and the
optional default value.
""".
-spec build_node(
    integer() | undefined,
    requiredness(),
    thrift_type(),
    field_name(),
    const_value() | undefined
) ->
    field_().
build_node(Id, Required, Type, Name, Default) ->
    #thrift_generator_field{
        id = Id,
        required = Required,
        type = Type,
        name = Name,
        default = Default
    }.
