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

-ifndef(THRIFT_GENERATOR_HRL).
-define(THRIFT_GENERATOR_HRL, true).

%% Every module including this header re-exports the shared vocabulary
%% so elvis's export_used_types sees one definition point.
-export_type([
    erl_annotations/0,
    annotations/0,
    doc/0,
    base_type/0,
    type_ref/0,
    thrift_type/0,
    const_value/0,
    enum_value/0,
    requiredness/0,
    ast_node/0,
    document/0,
    include_/0,
    cpp_include/0,
    namespace_/0,
    constant/0,
    typedef/0,
    enum_/0,
    struct_/0,
    union_def/0,
    exception_/0,
    service/0,
    function_/0,
    field_/0,
    node_payload/0
]).

%% --------------------------------------------------------------------
%% Shared vocabulary: annotations, doc comments, Thrift types, constant
%% values. These are plain values shared by AST nodes; the nodes
%% themselves are records wrapped in the #thrift_generator_node{}
%% envelope below.
%% --------------------------------------------------------------------

%% Annotations of an AST node filtered down to the `erl.*` namespace:
%% the `erl.` prefix is stripped and keys become atoms.
-type erl_annotations() :: #{atom() := true | binary()}.

%% Annotations as written in the IDL, before any filtering; keys keep
%% their dotted form (e.g. `<<"erl.set_type">>`).
-type annotations() :: #{binary() := true | binary()}.

%% Doc comment text attached to a definition, field or enum value.
-type doc() :: binary() | undefined.

%% Built-in Thrift types. `uuid` requires Thrift >= 0.17.
-type base_type() :: bool | i8 | i16 | i32 | i64 | double | string | binary | uuid.

%% Reference to a user-defined type (struct, union, exception, enum or
%% typedef), resolved by the semantic pass.
-type type_ref() :: {ref, Name :: binary(), annotations()}.

%% Thrift types are uniform tagged tuples: every shape carries the
%% annotations written next to it, container element types nest
%% recursively.
-type thrift_type() ::
    {base, base_type(), annotations()}
    | type_ref()
    | {list, Element :: thrift_type(), annotations()}
    | {set, Element :: thrift_type(), annotations()}
    | {map, Key :: thrift_type(), Value :: thrift_type(), annotations()}.

%% A constant literal or a reference to another constant or enum
%% member; references are resolved by the semantic pass.
-type const_value() ::
    {ref, Name :: binary()}
    | boolean()
    | integer()
    | float()
    | binary()
    | {list, [const_value()]}
    | {map, [{const_value(), const_value()}]}.

%% One enum member: name, explicit value (implicit values stay
%% `undefined` until the semantic pass numbers them), annotations and
%% the doc comment.
-type enum_value() ::
    {Name :: binary(), Value :: integer() | undefined, annotations(), doc()}.

%% Field requiredness as written; `default` covers the case where
%% neither `required` nor `optional` was used.
-type requiredness() :: required | optional | default.

%% --------------------------------------------------------------------
%% AST nodes. Every parsed construct travels inside the
%% #thrift_generator_node{} envelope: `payload` is the kind-specific
%% record, `type_module` names the module that built it
%% (thrift_generator_<kind>), `annotations` holds the filtered `erl.*`
%% annotations and `doc` the attached doc comment. One module per
%% definition kind builds its payload record; see
%% thrift_generator_<kind>:build_node/N.
%% --------------------------------------------------------------------

-record(thrift_generator_node, {
    line = 0 :: non_neg_integer(),
    doc = undefined :: doc(),
    annotations = #{} :: erl_annotations(),
    payload :: term(),
    type_module = undefined :: module()
}).

-type ast_node() :: #thrift_generator_node{}.

-nominal file_name() :: binary().

-record(thrift_generator_document, {
    filename :: file_name(),
    headers :: [ast_node()],
    definitions :: [ast_node()]
}).
-type document() :: #thrift_generator_document{}.

-nominal include_path() :: binary().

-record(thrift_generator_include, {
    path :: include_path()
}).
-type include_() :: #thrift_generator_include{}.

-record(thrift_generator_cpp_include, {
    path :: include_path()
}).
-type cpp_include() :: #thrift_generator_cpp_include{}.

-nominal namespace_scope() :: binary().
-nominal namespace_name() :: binary().

-record(thrift_generator_namespace, {
    scope :: namespace_scope(),
    name :: namespace_name()
}).
-type namespace_() :: #thrift_generator_namespace{}.

-nominal constant_name() :: binary().

-record(thrift_generator_constant, {
    name :: constant_name(),
    type :: thrift_type(),
    value :: const_value()
}).
-type constant() :: #thrift_generator_constant{}.

-nominal typedef_name() :: binary().

-record(thrift_generator_typedef, {
    name :: typedef_name(),
    type :: thrift_type()
}).
-type typedef() :: #thrift_generator_typedef{}.

-nominal enum_name() :: binary().

-record(thrift_generator_enum, {
    name :: enum_name(),
    values :: [enum_value()]
}).
-type enum_() :: #thrift_generator_enum{}.

-nominal struct_name() :: binary().

-record(thrift_generator_struct, {
    name :: struct_name(),
    fields :: [ast_node()]
}).
-type struct_() :: #thrift_generator_struct{}.

-nominal union_name() :: binary().

-record(thrift_generator_union, {
    name :: union_name(),
    fields :: [ast_node()]
}).
-type union_def() :: #thrift_generator_union{}.

-nominal exception_name() :: binary().

-record(thrift_generator_exception, {
    name :: exception_name(),
    fields :: [ast_node()]
}).
-type exception_() :: #thrift_generator_exception{}.

-nominal service_name() :: binary().
-nominal service_parent() :: binary().

-record(thrift_generator_service, {
    name :: service_name(),
    extends :: service_parent() | undefined,
    functions :: [ast_node()]
}).
-type service() :: #thrift_generator_service{}.

-nominal function_name() :: binary().

-record(thrift_generator_function, {
    oneway :: boolean(),
    return_type :: thrift_type() | void,
    name :: function_name(),
    fields :: [ast_node()],
    throws :: [ast_node()]
}).
-type function_() :: #thrift_generator_function{}.

-nominal field_name() :: binary().

-record(thrift_generator_field, {
    id :: integer() | undefined,
    required :: requiredness(),
    type :: thrift_type(),
    name :: field_name(),
    default :: const_value() | undefined
}).
-type field_() :: #thrift_generator_field{}.

%% The payload of an envelope node: exactly one of the definition
%% records above (plus function and field payloads, which only appear
%% nested inside definitions).

-type node_payload() ::
    document()
    | include_()
    | cpp_include()
    | namespace_()
    | constant()
    | typedef()
    | enum_()
    | struct_()
    | union_def()
    | exception_()
    | service()
    | function_()
    | field_().

-endif.
