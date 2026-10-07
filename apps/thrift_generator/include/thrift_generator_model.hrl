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

-ifndef(__thrift_generator_model__).
-define(__thrift_generator_model__, true).

-include("thrift_generator.hrl").

%% --------------------------------------------------------------------
%% Semantic model: the normalized, validated IR that the code emitter
%% consumes. Built by thrift_generator_semantic from parsed AST nodes
%% (see thrift_generator.hrl for the shared vocabulary: thrift_type(),
%% const_value(), erl_annotations(), doc(), requiredness()).
%%
%% Type references stay as {ref, Name, Ann} tuples; the semantic pass
%% validates that every reference resolves within its module or one of
%% its includes, but does not expand them. Enum members in default
%% values and constants resolve to member name binaries.
%% --------------------------------------------------------------------

%% One struct/union/exception member field. Fields written without an
%% explicit id get implicit negative ids (-1, -2, ... in declaration
%% order) — the Thrift legacy rule; never renumber them.
-record(tg_field, {
    id :: integer(),
    required :: requiredness(),
    type :: thrift_type(),
    name :: binary(),
    default :: const_value() | undefined,
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc()
}).

%% struct, union and exception share one shape; `kind` keeps the
%% distinction for the emitter and for validation.
-record(tg_struct, {
    kind :: struct | union | exception,
    name :: binary(),
    fields :: [#tg_field{}],
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer()
}).

%% Enum: members ordered by declaration, implicit values numbered by
%% the semantic pass (n + 1, starting from 0). Duplicate values are a
%% validation error, so value/name pairs are unique both ways.
-record(tg_enum, {
    name :: binary(),
    values :: [{integer(), binary()}],
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer()
}).

-record(tg_typedef, {
    name :: binary(),
    type :: thrift_type(),
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer()
}).

%% Constant with its value fully resolved (references replaced by the
%% referenced literal or enum member name).
-record(tg_const, {
    name :: binary(),
    type :: thrift_type(),
    value :: const_value(),
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer()
}).

-record(tg_function, {
    name :: binary(),
    oneway :: boolean(),
    return_type :: thrift_type() | void,
    params :: [#tg_field{}],
    throws :: [#tg_field{}],
    doc = undefined :: doc()
}).

%% Service with inherited functions merged in (parent functions first).
%% `extends` keeps the parent name as written for qualified resolution.
-record(tg_service, {
    name :: binary(),
    extends :: binary() | undefined,
    functions :: [#tg_function{}],
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer()
}).

%% One IDL file = one module. `name` comes from `namespace erl` (or
%% `namespace *`), falling back to the file base name without the
%% .thrift extension — this is the name used to qualify references
%% from including files and to name generated modules.
-record(tg_module, {
    name :: binary(),
    path :: binary(),
    includes = [] :: [binary()],
    structs = [] :: [#tg_struct{}],
    enums = [] :: [#tg_enum{}],
    typedefs = [] :: [#tg_typedef{}],
    consts = [] :: [#tg_const{}],
    services = [] :: [#tg_service{}]
}).

%% The whole compilation unit: the root module plus every transitively
%% included module, in load order (root first).
-record(tg_model, {
    root :: binary(),
    modules :: [#tg_module{}]
}).

%% One entry handed from the loader to the semantic pass.
-record(tg_loaded, {
    name :: binary(),
    path :: binary(),
    includes :: [binary()],
    doc :: ast_node()
}).

-endif.
