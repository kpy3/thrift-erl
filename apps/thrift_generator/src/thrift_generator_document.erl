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

-module(thrift_generator_document).

-moduledoc """
Builds the payload record for the document (whole file) node.
""".

-include("thrift_generator.hrl").

-export([build_node/3]).

-doc """
Builds a document payload: the file name plus ordered header and
definition nodes.
""".
-spec build_node(file_name(), [ast_node()], [ast_node()]) -> document().
build_node(FileName, Headers, Definitions) ->
    #thrift_generator_document{
        filename = FileName,
        headers = Headers,
        definitions = Definitions
    }.
