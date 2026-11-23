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

-module(thrift_generator_emitter_record).

-moduledoc """
The typed record declaration of a struct definition.

`record_form/3` builds the `-record' attribute a record-mode struct
carries in both the types module (local type references) and its hrl
(remote references under `qualify`); `const_literal/1` renders a
resolved constant value as syntax, shared with the constant macros and
functions.
""".

-export([record_form/3, const_literal/1]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

%% The typed record declaration: each field carries its type — in the
%% .erl local references resolve to the module's exported aliases, in
%% the hrl (qualify) every reference is remote. Non-required fields add
%% `| undefined' — the value an absent wire field leaves behind;
%% `required' fields have none.

-doc "The typed record declaration of a record-mode struct (remote type references under `qualify`).".
-spec record_form(#tg_struct{}, binary(), #ectx{}) -> erl_syntax:forms().
record_form(S, Prefix, Ctx) ->
    Anno = erl_anno:new(0),
    TypedFields = [
        {typed_record_field,
            case F#tg_field.default of
                undefined ->
                    {record_field, Anno, {atom, Anno, thrift_generator_ir:field_atom(F#tg_field.name)}};
                Default ->
                    Expr = set_default_expr(F#tg_field.type, const_literal(Default)),
                    {record_field, Anno, {atom, Anno, thrift_generator_ir:field_atom(F#tg_field.name)},
                        erl_syntax:revert(Expr)}
            end,
            field_type_node(F, Ctx)}
     || F <- S#tg_struct.fields
    ],
    [{attribute, Anno, record, {thrift_generator_ir:record_tag_of(S, Prefix), TypedFields}}].

-spec field_type_node(#tg_field{}, #ectx{}) -> erl_syntax:syntaxTree().
field_type_node(F, Ctx) ->
    Type = thrift_generator_ir:erlang_type(F#tg_field.type, Ctx),
    case F#tg_field.required of
        required ->
            Type;
        _ ->
            thrift_generator_emitter_syntax:undefined_union(Type)
    end.

%% A set field's default literal is wire-shaped (a list); under a
%% sets/ordset impl the record default builds the declared collection
%% instead, so a constructed record matches the field's emitted type.

-spec set_default_expr(thrift_type(), erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
set_default_expr({set, _, Ann}, Default) ->
    case thrift_generator_ir:set_impl(Ann) of
        list ->
            Default;
        sets ->
            thrift_generator_emitter_syntax:application(sets, from_list, [Default]);
        ordset ->
            thrift_generator_emitter_syntax:application(ordsets, from_list, [Default])
    end;
set_default_expr(_Type, Default) ->
    Default.

%% Constants carry resolved values: enum references as member name
%% binaries, containers as tagged lists/maps. Enum members surface as
%% atoms; maps as maps with literal keys.

-spec const_literal(const_value()) -> erl_syntax:syntaxTree().
const_literal({ref, Name}) ->
    thrift_generator_emitter_syntax:abstract(binary_to_atom(Name, utf8));
const_literal({list, Values}) ->
    erl_syntax:list([const_literal(V) || V <- Values]);
const_literal({map, KVs}) ->
    erl_syntax:map_expr([
        erl_syntax:map_field_assoc(const_literal(K), const_literal(V))
     || {K, V} <- KVs
    ]);
const_literal(Value) ->
    thrift_generator_emitter_syntax:abstract(Value).
