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

-module(thrift_generator_ir).

-moduledoc """
Shared intermediate representation of the semantic model.

The layer every emitter consumes: model types lowered to the wire
descriptor vocabulary the runtime codecs consume (`type_desc/2`,
`params_desc/2`, `reply_desc/2`, `exceptions_desc/2`, `field_desc/2`),
the Erlang type syntax for specs (`erlang_type/2`), the representation
predicates (`has_record/1`, `struct_type/1`, `sum_mode/1`,
`native_mode/1`, `mode/1`, `map_key_type/1`) and the shared definition
naming (`field_atom/1`, `record_tag_of/2`, `enum_desc/1`,
`section_label/1`). Keeping the lowering here lets the codec, service
and representation emitters share one resolution algorithm instead of
reaching into the core emitter.
""".

-export([
    type_desc/2,
    erlang_type/2,
    params_desc/2,
    reply_desc/2,
    exceptions_desc/2,
    field_desc/2,
    has_record/1,
    struct_type/1,
    sum_mode/1,
    native_mode/1,
    mode/1,
    map_key_type/1,
    field_atom/1,
    record_tag_of/2,
    section_label/1,
    set_impl/1,
    enum_desc/1,
    enum_case/1,
    enum_atom/2
]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

%% Wire-level descriptor terms — the same shapes thrift_runtime_binary and
%% thrift_runtime_record consume.

-type desc() :: term().

%%--------------------------------------------------------------------
%% Type descriptors
%%--------------------------------------------------------------------

-doc """
Converts a model type into the wire descriptor vocabulary the runtime
codecs consume (expanding typedefs and inlining enum descriptors);
shared with the codec emitter. References are already resolved by the
semantic pass: the descriptor names the defining module directly.
""".
-spec type_desc(resolved_thrift_type(), #ectx{}) -> desc().
type_desc({base, B, _}, _Ctx) ->
    {base, B};
type_desc({list, T, _}, Ctx) ->
    {list, type_desc(T, Ctx)};
type_desc({set, T, Ann}, Ctx) ->
    {set, type_desc(T, Ctx), set_impl(Ann)};
type_desc({map, K, V, _}, Ctx) ->
    {map, type_desc(K, Ctx), type_desc(V, Ctx)};
type_desc({resolved_ref, ModKey, Local, _}, Ctx) ->
    Module = maps:get(ModKey, Ctx#ectx.modules, undefined),
    TypesMod = maps:get(ModKey, Ctx#ectx.type_modules, undefined),
    case find_def(Module, Local) of
        {struct, _S} ->
            {struct, {ref, TypesMod, Local}};
        {enum, E} ->
            {enum, enum_desc(E)};
        {typedef, Type} ->
            %% A typedef from another module (base.Timestamp and
            %% friends) resolves in its own module's context, so
            %% refs inside its body stay home.
            type_desc(Type, Ctx#ectx{current = ModKey});
        error ->
            error({unresolved_type, ModKey, Local})
    end.

%% The in-process set implementation carried in the descriptor. `list`
%% (the default, and the shape hand-written descriptors keep using)
%% leaves the wire list as is; `sets`/`ordset` name the stdlib module
%% whose from_list/to_list the runtime applies. The wire encoding is
%% identical for all three.

-spec set_impl(annotations()) -> list | sets | ordset.
set_impl(Ann) ->
    case maps:get(<<"erl.set">>, Ann, <<"list">>) of
        <<"sets">> ->
            sets;
        <<"ordset">> ->
            ordset;
        _ ->
            list
    end.

-spec find_def(#tg_module{} | undefined, binary()) ->
    {struct, #tg_struct{}} | {enum, #tg_enum{}} | {typedef, thrift_type()} | error.
find_def(undefined, _Name) ->
    error;
find_def(Module, Name) ->
    case [S || S <- Module#tg_module.structs, S#tg_struct.name =:= Name] of
        [S | _] ->
            {struct, S};
        [] ->
            case [E || E <- Module#tg_module.enums, E#tg_enum.name =:= Name] of
                [E | _] ->
                    {enum, E};
                [] ->
                    case [T || T <- Module#tg_module.typedefs, T#tg_typedef.name =:= Name] of
                        [#tg_typedef{type = Type} | _] -> {typedef, Type};
                        [] -> error
                    end
            end
    end.

-spec enum_desc(#tg_enum{}) -> [{integer(), atom()}].
enum_desc(E) ->
    [{Value, enum_atom(Name, enum_case(E))} || {Value, Name} <- E#tg_enum.values].

%% The member atom casing an enum's generated atoms use, materialized
%% by the semantic pass (per-enum annotation, else the namespace
%% default, else the invocation option).

-spec enum_case(#tg_enum{}) -> preserve | lower.
enum_case(E) ->
    case maps:get(enum_case, E#tg_enum.erl, undefined) of
        <<"lower">> -> lower;
        _ -> preserve
    end.

-spec enum_atom(binary(), preserve | lower) -> atom().
enum_atom(Name, preserve) ->
    binary_to_atom(Name, utf8);
enum_atom(Name, lower) ->
    binary_to_atom(list_to_binary(string:lowercase(binary_to_list(Name))), utf8).

-spec field_atom(binary()) -> atom().
field_atom(Name) ->
    binary_to_atom(Name, utf8).

-spec record_tag(binary(), binary()) -> atom().
record_tag(Prefix, Name) ->
    binary_to_atom(thrift_generator_names:typed_prefix(Prefix, thrift_generator_names:snake(Name)), utf8).

%% The record tag a record-mode struct's values carry: the erl.record_name
%% annotation verbatim when present (the annotation names the tag in
%% full — no namespace prefix is applied), the namespace-prefixed snake
%% case otherwise. Only the record branch consults the annotation: sum
%% unions carry field atoms and native structs mint runtime records,
%% and the semantic pass rejects the annotation there.

-doc "The record tag a record-mode struct's values carry.".
-spec record_tag_of(#tg_struct{}, binary()) -> atom().
record_tag_of(S, Prefix) ->
    case S#tg_struct.erl of
        #{record_name := Name} -> binary_to_atom(Name, utf8);
        _ -> record_tag(Prefix, S#tg_struct.name)
    end.

%%--------------------------------------------------------------------
%% Function descriptors
%%--------------------------------------------------------------------

-doc "The method's params struct as a wire descriptor.".
-spec params_desc(#tg_function{}, #ectx{}) -> desc().
params_desc(F, Ctx) ->
    {struct, {struct, [field_desc(P, Ctx) || P <- F#tg_function.params]}}.

-doc "The method's reply type as a wire descriptor, `undefined` for `void`.".
-spec reply_desc(#tg_function{}, #ectx{}) -> desc() | undefined.
reply_desc(F, Ctx) ->
    case F#tg_function.return_type of
        void ->
            undefined;
        Type ->
            type_desc(Type, Ctx)
    end.

-doc "The method's declared exceptions as wire descriptors.".
-spec exceptions_desc(#tg_function{}, #ectx{}) -> [desc()].
exceptions_desc(F, Ctx) ->
    [field_desc(T, Ctx) || T <- F#tg_function.throws].

-spec field_desc(#tg_field{}, #ectx{}) -> desc().
field_desc(F, Ctx) ->
    {
        F#tg_field.id,
        F#tg_field.required,
        type_desc(F#tg_field.type, Ctx),
        F#tg_field.name,
        default_term(F#tg_field.default)
    }.

%% Descriptor defaults are plain Erlang terms: the {list, ...}/{map,
%% ...} wrappers are an AST shape, introspection carries what the
%% official generator's struct_info would.

-spec default_term(const_value() | undefined) -> term().
default_term({list, Values}) ->
    [default_term(Value) || Value <- Values];
default_term({map, KVs}) ->
    #{default_term(K) => default_term(V) || {K, V} <- KVs};
default_term(Value) ->
    Value.

%%--------------------------------------------------------------------
%% Representation predicates
%%--------------------------------------------------------------------

%% Representations of a generated struct-family definition:
%%
%% - `record_mode' — the tuple record (structs and unions by default);
%% - `sum_mode' — unions only, the `erl.union_type = "sum"' form: the
%%   value is a `{FieldAtom, Value}' tagged tuple, no record exists;
%% - `native_mode' — `erl.struct_type = "native"': values are EEP-79
%%   native records the runtime mints, no record is declared;
%% - `erl.struct_type = "map"' is the atom-keyed map.

-spec record_mode(#tg_struct{}) -> boolean().
record_mode(S) ->
    struct_type(S) =:= record.

%% A declared record exists only for record-mode non-sum definitions:
%% a sum union's alias IS its type, and its values are tagged tuples.

-doc "Whether the definition declares a record (record mode, not a sum union).".
-spec has_record(#tg_struct{}) -> boolean().
has_record(S) ->
    record_mode(S) andalso not sum_mode(S).

-doc "Whether the union is generated as a tagged-tuple sum type.".
-spec sum_mode(#tg_struct{}) -> boolean().
sum_mode(S) ->
    S#tg_struct.kind =:= union andalso
        maps:get(union_type, S#tg_struct.erl, <<"record">>) =:= <<"sum">>.

-doc "Whether the struct is generated as runtime-minted native records.".
-spec native_mode(#tg_struct{}) -> boolean().
native_mode(S) ->
    struct_type(S) =:= native.

%% The representation axis of a definition, from its erl.struct_type;
%% sum unions keep their tagged-tuple form whatever the struct_type
%% says, and anything unrecognized falls back to the record.

-doc "The struct_type axis of a definition: `map`, `native`, or `record` when absent or unrecognized.".
-spec struct_type(#tg_struct{}) -> record | map | native.
struct_type(S) ->
    case maps:get(struct_type, S#tg_struct.erl, undefined) of
        <<"map">> -> map;
        <<"native">> -> native;
        _ -> record
    end.

%% The one representation axis the mode case sites dispatch on: sum
%% unions keep their tagged-tuple form whatever struct_type says,
%% otherwise the axis is the plain struct_type.

-spec mode(#tg_struct{}) -> sum | record | native | map.
mode(S) ->
    case sum_mode(S) of
        true -> sum;
        false -> struct_type(S)
    end.

-spec map_key_type(#tg_struct{}) -> atom | binary.
map_key_type(S) ->
    case maps:get('struct_type.map.key_type', S#tg_struct.erl, <<"atom">>) of
        <<"binary">> ->
            binary;
        _ ->
            atom
    end.

%%--------------------------------------------------------------------
%% Definition labeling
%%--------------------------------------------------------------------

%% The divider label naming the IDL construct the following forms
%% implement (the declared name, not the derived tag).

-doc "The section divider label naming an IDL definition (the declared name, not the derived tag).".
-spec section_label(#tg_struct{} | #tg_enum{} | #tg_typedef{}) -> string().
section_label(#tg_struct{kind = union, name = Name}) ->
    "Union " ++ unicode:characters_to_list(Name);
section_label(#tg_struct{kind = exception, name = Name}) ->
    "Exception " ++ unicode:characters_to_list(Name);
section_label(#tg_struct{name = Name}) ->
    "Struct " ++ unicode:characters_to_list(Name);
section_label(#tg_enum{name = Name}) ->
    "Enum " ++ unicode:characters_to_list(Name);
section_label(#tg_typedef{name = Name}) ->
    "Typedef " ++ unicode:characters_to_list(Name).

%%--------------------------------------------------------------------
%% Erlang type mapping (specs and callbacks)
%%--------------------------------------------------------------------

-spec erlang_type(resolved_thrift_type(), #ectx{}) -> erl_syntax:syntaxTree().
erlang_type({base, B, _}, _) ->
    thrift_generator_emitter_syntax:base_erlang_type(B);
erlang_type({list, T, _}, Ctx) ->
    list_type(T, Ctx);
erlang_type({set, T, Ann}, Ctx) ->
    %% Sets travel as lists on the wire (element type + count), exactly
    %% like the official generator emits them; erl.set only picks the
    %% in-process collection.
    case set_impl(Ann) of
        list ->
            list_type(T, Ctx);
        Impl ->
            %% sets:set(Elem) / ordsets:ordset(Elem) — the stdlib type
            %% names the in-process collection.
            {Module, TypeName} =
                case Impl of
                    sets -> {sets, set};
                    ordset -> {ordsets, ordset}
                end,
            Anno = erl_anno:new(0),
            {remote_type, Anno, [
                {atom, Anno, Module},
                {atom, Anno, TypeName},
                [erlang_type(T, Ctx)]
            ]}
    end;
erlang_type({map, K, V, _}, Ctx) ->
    Anno = erl_anno:new(0),
    {type, Anno, map, [{type, Anno, map_field_assoc, [erlang_type(K, Ctx), erlang_type(V, Ctx)]}]};
erlang_type({resolved_ref, ModKey, Local, Ann}, Ctx) ->
    %% Qualified spellings render as the defining module's remote alias.
    %% Plain spellings render by name in the emitting module — inherited
    %% service functions carry the parent's references, and the legacy
    %% handler specs resolve the bare name against the child.
    case {maps:is_key(?TG_REF_SOURCE, Ann), ModKey =:= Ctx#ectx.current} of
        {true, _} ->
            qualified_ref_type(ModKey, Local, Ctx);
        {false, true} when Ctx#ectx.qualify ->
            qualified_ref_type(ModKey, Local, Ctx);
        {false, true} ->
            local_ref_type(Local, Ctx);
        {false, false} ->
            case Ctx#ectx.qualify of
                true -> qualified_ref_type(Ctx#ectx.current, Local, Ctx);
                false -> local_ref_type(Local, Ctx)
            end
    end.

-spec list_type(thrift_type(), #ectx{}) -> erl_syntax:syntaxTree().
list_type(T, Ctx) ->
    {type, erl_anno:new(0), list, [erlang_type(T, Ctx)]}.

%% A local reference surfaces as the definition's exported alias; the
%% module's own aliases need no qualification. Enums and typedefs alias
%% too; native-mode structs declare no alias, unresolved refs stay
%% term().

-spec local_ref_type(binary(), #ectx{}) -> erl_syntax:syntaxTree().
local_ref_type(Local, Ctx) ->
    Module = maps:get(Ctx#ectx.current, Ctx#ectx.modules),
    case def_alias(Module, Local) of
        {ok, Alias} ->
            thrift_generator_emitter_syntax:user_type(Alias);
        error ->
            thrift_generator_emitter_syntax:raw_type(term)
    end.

-spec qualified_ref_type(module_key(), binary(), #ectx{}) -> erl_syntax:syntaxTree().
qualified_ref_type(ModKey, Local, Ctx) ->
    Module = maps:get(ModKey, Ctx#ectx.modules, undefined),
    case def_alias(Module, Local) of
        {ok, Alias} ->
            thrift_generator_emitter_syntax:remote_type(
                thrift_generator_names:types_module_atom(ModKey), Alias
            );
        error ->
            thrift_generator_emitter_syntax:raw_type(term)
    end.

-spec def_alias(#tg_module{} | undefined, binary()) -> {ok, atom()} | error.
def_alias(undefined, _Local) ->
    error;
def_alias(Module, Local) ->
    case find_def(Module, Local) of
        {struct, S} ->
            case native_mode(S) of
                true -> error;
                false -> {ok, type_alias(Local)}
            end;
        {enum, _E} ->
            {ok, type_alias(Local)};
        {typedef, _Type} ->
            {ok, type_alias(Local)};
        error ->
            error
    end.

-spec type_alias(binary()) -> atom().
type_alias(Name) ->
    binary_to_atom(Name, utf8).
