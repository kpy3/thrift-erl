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

-ifndef(THRIFT_GENERATOR_MODEL_HRL).
-define(THRIFT_GENERATOR_MODEL_HRL, true).

-include("thrift_generator.hrl").

%% --------------------------------------------------------------------
%% Semantic model: the normalized, validated IR that the code emitter
%% consumes. Built by thrift_generator_semantic from parsed AST nodes
%% (see thrift_generator.hrl for the shared vocabulary: thrift_type(),
%% const_value(), erl_annotations(), doc(), requiredness()).
%%
%% Type references are resolved during analysis: every typed position
%% carries resolved_thrift_type() values whose {resolved_ref, ModuleKey,
%% LocalName, Ann} nodes name the defining module directly, so emission
%% needs no second resolution pass. Enum members in default values and
%% constants resolve to member name binaries.
%% --------------------------------------------------------------------

%% Internal annotation key of a resolved reference that was written with a
%% qualified spelling (`includee.Payload'): the value is the original
%% `Qualifier.Name' binary. The emission layer renders qualified spellings
%% as remote aliases of the resolved module, while plain spellings keep
%% their legacy name-based rendering (inherited service functions resolve
%% the bare name against the emitting module). The key contains a dash,
%% which IDL annotation keys (identifiers) can never carry, so a written
%% annotation cannot collide with it.
-define(TG_REF_SOURCE, <<"resolved-source">>).
%% --------------------------------------------------------------------

%% One struct/union/exception member field. Fields written without an
%% explicit id get implicit negative ids (-1, -2, ... in declaration
%% order) — the Thrift legacy rule; never renumber them.
-record(tg_field, {
    id :: integer(),
    required :: requiredness(),
    type :: resolved_thrift_type(),
    name :: binary(),
    default :: const_value() | undefined,
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
    line = 0 :: non_neg_integer(),
    %% 1-based column of the opening token (for diagnostics)
    col = 0 :: non_neg_integer()
}).

%% Enum: members ordered by declaration, implicit values numbered by
%% the semantic pass (n + 1, starting from 0). Duplicate values are a
%% validation error, so value/name pairs are unique both ways.
-record(tg_enum, {
    name :: binary(),
    values :: [{integer(), binary()}],
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer(),
    %% 1-based column of the opening token (for diagnostics)
    col = 0 :: non_neg_integer()
}).

-record(tg_typedef, {
    name :: binary(),
    type :: resolved_thrift_type(),
    erl = #{} :: erl_annotations(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer(),
    %% 1-based column of the opening token (for diagnostics)
    col = 0 :: non_neg_integer()
}).

%% Constant with its value fully resolved (references replaced by the
%% referenced literal or enum member name).
-record(tg_const, {
    name :: binary(),
    type :: resolved_thrift_type(),
    value :: const_value(),
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer(),
    %% 1-based column of the opening token (for diagnostics)
    col = 0 :: non_neg_integer()
}).

-record(tg_function, {
    name :: binary(),
    oneway :: boolean(),
    return_type :: resolved_thrift_type() | void,
    params :: [#tg_field{}],
    throws :: [#tg_field{}],
    doc = undefined :: doc()
}).

%% Service with inherited functions merged in (parent functions first);
%% the source `extends` spelling remains available on the parsed AST.
-record(tg_service, {
    name :: binary(),
    functions :: [#tg_function{}],
    doc = undefined :: doc(),
    line = 0 :: non_neg_integer(),
    %% 1-based column of the opening token (for diagnostics)
    col = 0 :: non_neg_integer()
}).

%% One IDL file = one module. `name` comes from `namespace erl` (or
%% `namespace *`), falling back to the file base name without the
%% .thrift extension — this is the name used to qualify references
%% from including files and to name generated modules. `prefix` comes
%% from the same namespace (empty without one): the identifier prefix
%% every generated record tag, type alias, derived function name and
%% constant macro carries, so same-named definitions of different
%% files keep coexisting once both hrl files land in one compilation.
-record(tg_module, {
    name :: binary(),
    prefix = <<>> :: binary(),
    path :: binary(),
    structs = [] :: [#tg_struct{}],
    enums = [] :: [#tg_enum{}],
    typedefs = [] :: [#tg_typedef{}],
    consts = [] :: [#tg_const{}],
    services = [] :: [#tg_service{}]
}).

%% The whole compilation unit: the root module plus every transitively
%% included module, in load order (root first).
-record(tg_model, {
    modules :: [#tg_module{}]
}).

%% The emitter's cross-module resolution context: the loaded modules by
%% name, the emitted types-module atoms, and the module whose
%% definitions are being emitted (the scope reference targets resolve
%% against). Shared by the core emitter and the service emitter.

-type module_key() :: binary().

-record(ectx, {
    %% binary module name -> #tg_module{}
    modules :: #{module_key() => #tg_module{}},
    %% binary module name -> emitted types module atom
    type_modules :: #{module_key() => module()},
    current :: undefined | module_key(),
    %% hrl context: type references qualify with the defining module —
    %% the hrl carries no type definitions, and remote types compile at
    %% the include site without the defining types module
    qualify = false :: boolean()
}).

%% --------------------------------------------------------------------
%% Codec emission plan: the single per-types-module inventory the
%% specialized-codec backends (binary, compact, JSON) and the emitter
%% share, built once per types module by
%% thrift_generator_codec_plan:build/2. Declared structs always precede
%% the synthetic RPC structs in every ordered view; the enum registry
%% numbering and the container inventory derive from that order, so the
%% backends emit byte-identical code from one shared calculation.
%% --------------------------------------------------------------------

%% One planned struct: the struct plus its per-field wire types in field
%% order — the same wire types struct_info/1 carries in each field
%% descriptor.
-record(tg_codec_struct, {
    struct :: #tg_struct{},
    field_types :: [thrift_generator_codec_common:wire_type()]
}).

-record(tg_codec_plan, {
    module :: #tg_module{},
    ctx :: #ectx{},
    declared = [] :: [#tg_codec_struct{}],
    rpc = [] :: [#tg_codec_struct{}],
    wire_types = [] :: [thrift_generator_codec_common:wire_type()],
    enums = #{} :: thrift_generator_codec_common:registry(),
    %% The binary/compact container inventory; JSON derives its own from
    %% wire_types with the unsupported-map cutoff.
    containers = [] :: [thrift_generator_codec_common:wire_type()],
    %% Protocol -> wire struct name -> {Encode, Decode}.
    codec_names = #{} :: #{wire | compact | json => #{binary() => {atom(), atom()}}}
}).

%% One entry handed from the loader to the semantic pass.
-record(tg_loaded, {
    name :: binary(),
    prefix = <<>> :: binary(),
    path :: binary(),
    includes :: [binary()],
    doc :: ast_node()
}).

-endif.
