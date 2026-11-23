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

-module(thrift_generator_emitter_repr).

-moduledoc """
Emission of the direct representation converters a record-mode types
module carries: `repr_to_wire_<struct>/1` and `repr_from_wire_<struct>/2`
with literal field atoms and binary names, registered in `repr_index/1`.

`thrift_runtime_record' probes the index once per struct and caches the
function pair in persistent_term, the same dispatch contract the codec
indexes use. The emitted converters must match the descriptor engine of
`thrift_runtime_record' exactly: tuple inputs skip `undefined` fields, map
inputs accept the binary field name first and the field atom second and
keep present `undefined` values, `record` targets carry every declared
field (missing as `undefined`), `map`/`struct` targets carry the present
fields only, and a native target mints the record with every declared
field in declaration order. Nested values convert through the public
`thrift_runtime_record' entry points, so a nested value in the native
representation or from a hand-written module still lands on its own
correct path.

Only record-mode structs get converters: sum unions, map-mode and
native-mode structs stay on the descriptor engine (`repr_index' answers
`error' for them), as do hand-written modules without the index.
""".

-export([source_forms/2]).

-include("thrift_generator_model.hrl").

-import(thrift_generator_codec_ast, [
    v/1,
    at/1,
    clause/3,
    'case'/2,
    lc/2,
    map_empty/0,
    map_put/3,
    bin_lit/1,
    list_lit/1,
    tuple_t/1,
    remote/3,
    literal/1
]).

-define(ANNO, erl_anno:new(0)).

-type ast() :: thrift_generator_codec_ast:ast().

%%--------------------------------------------------------------------
%% Module source
%%--------------------------------------------------------------------

%% The converters live in their own `<mod>_types_repr' module: the types
%% module's codec sections stay byte-identical to a build without
%% converters, and generated-code layout is a measured performance
%% variable (BEAM code layout sensitivity). Modules without convertible
%% structs emit no repr module at all. The runtime calls the per-struct
%% converters by cached name, so they are exported alongside the index.

-spec source_forms(#tg_module{}, #ectx{}) -> [{module(), erl_syntax:forms(), undefined}].
source_forms(Mod, Ctx) ->
    Structs = [S || S <- Mod#tg_module.structs, convertible(S)],
    case Structs of
        [] ->
            [];
        _ ->
            ReprMod = repr_module(Mod),
            Forms =
                thrift_generator_emitter_syntax:header(ReprMod, Mod#tg_module.path) ++
                    [{attribute, ?ANNO, moduledoc, false}] ++
                    thrift_generator_emitter_syntax:exports_forms(export_entries(Structs)) ++
                    lists:append([
                        to_wire_forms(S, Ctx) ++ from_wire_forms(S, Mod, Ctx)
                     || S <- Structs
                    ]) ++
                    index_forms(Structs),
            [{ReprMod, Forms, undefined}]
    end.

-spec repr_module(#tg_module{}) -> module().
repr_module(Mod) ->
    TypesMod = thrift_generator_names:types_module_atom(Mod#tg_module.name),
    binary_to_atom(<<(atom_to_binary(TypesMod, utf8))/binary, "_repr">>, utf8).

-spec export_entries([#tg_struct{}]) -> [{atom(), arity()}].
export_entries(Structs) ->
    [{repr_index, 1}] ++
        lists:append([
            [{to_wire_name(S), 1}, {from_wire_name(S), 2}]
         || S <- Structs
        ]).

%%--------------------------------------------------------------------
%% Module forms
%%--------------------------------------------------------------------

%% v1 covers the default record mode only; the index answers `error'
%% for every other definition and the runtime keeps its descriptor path.

-spec convertible(#tg_struct{}) -> boolean().
convertible(S) ->
    %% An empty union has no value to convert; its dead converter would
    %% only grow the module.
    thrift_generator_ir:has_record(S) andalso
        not (S#tg_struct.kind =:= union andalso S#tg_struct.fields =:= []).

-spec to_wire_name(#tg_struct{}) -> atom().
to_wire_name(S) ->
    prefixed_name(<<"repr_to_wire_">>, S).

-spec from_wire_name(#tg_struct{}) -> atom().
from_wire_name(S) ->
    prefixed_name(<<"repr_from_wire_">>, S).

-spec prefixed_name(binary(), #tg_struct{}) -> atom().
prefixed_name(Prefix, S) ->
    binary_to_atom(<<Prefix/binary, (thrift_generator_names:snake(S#tg_struct.name))/binary>>, utf8).

-spec index_forms([#tg_struct{}]) -> [erl_syntax:forms()].
index_forms(Structs) ->
    Clauses =
        [
            clause([bin_lit(S#tg_struct.name)], none, [
                tuple_t([at(ok), tuple_t([at(to_wire_name(S)), at(from_wire_name(S))])])
            ])
         || S <- Structs
        ] ++ [clause([v("_")], none, [at(error)])],
    [
        {attribute, ?ANNO, spec,
            {{repr_index, 1}, [
                thrift_generator_emitter_syntax:fun_type(
                    [{type, ?ANNO, binary, [{integer, ?ANNO, 0}, {integer, ?ANNO, 8}]}],
                    {type, ?ANNO, union, [
                        {type, ?ANNO, tuple, [
                            {atom, ?ANNO, ok},
                            {type, ?ANNO, tuple, [
                                {type, ?ANNO, atom, []},
                                {type, ?ANNO, atom, []}
                            ]}
                        ]},
                        {atom, ?ANNO, error}
                    ]}
                )
            ]}},
        {function, ?ANNO, repr_index, 1, Clauses}
    ].

%%--------------------------------------------------------------------
%% repr_to_wire_<struct>/1
%%--------------------------------------------------------------------

-spec to_wire_forms(#tg_struct{}, #ectx{}) -> [erl_syntax:forms()].
to_wire_forms(S, Ctx) ->
    Fields = S#tg_struct.fields,
    Tag = tag(S, Ctx),
    Vars = [v("F" ++ integer_to_list(I)) || I <- lists:seq(1, length(Fields))],
    %% Tuple input: `undefined' fields are skipped (struct_to_wire).
    Indexed = lists:zip(Fields, lists:seq(1, length(Fields))),
    TupleBody = maps_chain([
        skip_undefined_step(Field, I, Var, Ctx)
     || {{Field, I}, Var} <- lists:zip(Indexed, Vars)
    ]),
    %% Map input: the binary name wins over the field atom, a present
    %% key converts even when its value is `undefined'
    %% (declared_to_wire), `__struct__' is identity metadata.
    MapVar = v("M"),
    MapBody = maps_chain([
        map_key_step(Field, I, MapVar, Ctx)
     || {Field, I} <- lists:zip(Fields, lists:seq(1, length(Fields)))
    ]),
    [
        {function, ?ANNO, to_wire_name(S), 1, [
            clause([tuple_t([at(Tag) | Vars])], none, TupleBody),
            clause([MapVar], [remote(erlang, is_map, [MapVar])], MapBody),
            clause([v("Value")], none, [
                remote(erlang, error, [tuple_t([at(value_does_not_match_type), v("Value")])])
            ])
        ]}
    ].

%%--------------------------------------------------------------------
%% repr_from_wire_<struct>/2
%%--------------------------------------------------------------------

-spec from_wire_forms(#tg_struct{}, #tg_module{}, #ectx{}) -> [erl_syntax:forms()].
from_wire_forms(S, Mod, Ctx) ->
    Fields = S#tg_struct.fields,
    Tag = tag(S, Ctx),
    %% record target: every declared field, missing as `undefined'
    %% (struct_from_wire).
    Indexed = lists:zip(Fields, lists:seq(1, length(Fields))),
    %% A fieldless struct never reads the input: bind it as `_Value' to
    %% keep warnings_as_errors quiet, and skip the empty chain.
    ValueVar =
        case Fields of
            [] -> v("_Value");
            _ -> v("Value")
        end,
    RecordBody = tuple_t([at(Tag) | [field_or_undefined(F, I, at(record), Ctx) || {F, I} <- Indexed]]),
    %% map/struct targets keep the present fields only (wire_to_fields).
    MapBody = maps_chain([present_field_step(F, I, at(map), Ctx) || {F, I} <- Indexed]),
    StructChain = maps_chain([present_field_step(F, I, at(struct), Ctx) || {F, I} <- Indexed]),
    StructBody =
        case Fields of
            [] -> [map_assoc(map_empty(), at('__struct__'), at(Tag))];
            _ -> StructChain ++ [map_assoc(lists:last(StructChain), at('__struct__'), at(Tag))]
        end,
    %% Native records carry every declared field in declaration order,
    %% missing ones as `undefined' (thrift_runtime_native:create/3).
    NativeBody = remote(thrift_runtime_native, create, [
        at(types_module(Mod)),
        at(Tag),
        list_lit([
            tuple_t([at(field_atom(F#tg_field.name)), field_or_undefined(F, I, at(native), Ctx)])
         || {F, I} <- Indexed
        ])
    ]),
    [
        {function, ?ANNO, from_wire_name(S), 2, [
            clause([at(record), ValueVar], none, [RecordBody]),
            clause([at(map), ValueVar], none, MapBody),
            clause([at(struct), ValueVar], none, StructBody),
            clause([at(native), ValueVar], none, [NativeBody])
        ]}
    ].

%%--------------------------------------------------------------------
%% Field-level shapes
%%--------------------------------------------------------------------

%% A flat chain `Acc1 = case ..., Acc2 = case ..., ...' over `#{}':
%% each step is a case answering the accumulator unchanged when the
%% field is absent. The chain MUST stay flat: embedding the accumulator
%% into the case branches doubles the form tree per field (2^N on wide
%% structs — a 100-field Insanity hung the compiler).

-spec maps_chain([fun((ast()) -> ast())]) -> [ast()].
maps_chain(Steps) ->
    {FormsRev, LastAcc} = lists:foldl(
        fun(Step, {Forms, Acc}) ->
            Out = acc_var(length(Forms) + 1),
            Form = {match, ?ANNO, Out, Step(Acc)},
            {[Form | Forms], Out}
        end,
        {[], map_empty()},
        Steps
    ),
    lists:reverse(FormsRev, [LastAcc]).

acc_var(I) ->
    v("Acc" ++ integer_to_list(I)).

%% `Acc#{K => V}' as a VALUE: the flat chain binds it outside. Creating
%% the map outright on an empty literal base avoids the compiler's
%% "expression updates a literal" warning (generated modules compile
%% with warnings_as_errors).

-spec map_assoc(ast(), ast(), ast()) -> ast().
map_assoc({map, _, []}, K, V) ->
    {map, ?ANNO, [{map_field_assoc, ?ANNO, K, V}]};
map_assoc(Acc, K, V) ->
    map_put(Acc, K, V).

-spec skip_undefined_step(#tg_field{}, pos_integer(), ast(), #ectx{}) -> fun((ast()) -> ast()).
skip_undefined_step(Field, I, Var, Ctx) ->
    Val = value_var(I),
    Key = bin_lit(Field#tg_field.name),
    Type = field_type(Field, Ctx),
    fun(Acc) ->
        'case'(Var, [
            clause([at(undefined)], none, [Acc]),
            clause([Val], none, [map_assoc(Acc, Key, to_wire_expr(Type, Val))])
        ])
    end.

%% Deeply nested map-pattern cases stress the BEAM match compiler on
%% wide structs, so map reads are `maps:find' chains: plain tuple
%% patterns compile linearly and the binary-name-first precedence stays
%% explicit.

-spec map_key_step(#tg_field{}, pos_integer(), ast(), #ectx{}) -> fun((ast()) -> ast()).
map_key_step(Field, I, MapVar, Ctx) ->
    Val = value_var(I),
    Key = bin_lit(Field#tg_field.name),
    Type = field_type(Field, Ctx),
    fun(Acc) ->
        'case'(remote(maps, find, [Key, MapVar]), [
            clause([tuple_t([at(ok), Val])], none, [map_assoc(Acc, Key, to_wire_expr(Type, Val))]),
            clause([at(error)], none, [atom_key_step(Field, Val, Key, Type, MapVar, Acc)])
        ])
    end.

atom_key_step(Field, Val, Key, Type, MapVar, Acc) ->
    'case'(remote(maps, find, [at(field_atom(Field#tg_field.name)), MapVar]), [
        clause([tuple_t([at(ok), Val])], none, [map_assoc(Acc, Key, to_wire_expr(Type, Val))]),
        clause([at(error)], none, [Acc])
    ]).

-spec field_or_undefined(#tg_field{}, pos_integer(), ast(), #ectx{}) -> ast().
field_or_undefined(Field, I, Repr, Ctx) ->
    Val = value_var(I),
    'case'(remote(maps, find, [bin_lit(Field#tg_field.name), v("Value")]), [
        clause([tuple_t([at(ok), Val])], none, [
            from_wire_expr(field_type(Field, Ctx), Val, Repr)
        ]),
        clause([at(error)], none, [at(undefined)])
    ]).

-spec present_field_step(#tg_field{}, pos_integer(), ast(), #ectx{}) -> fun((ast()) -> ast()).
present_field_step(Field, I, Repr, Ctx) ->
    Val = value_var(I),
    WireName = bin_lit(Field#tg_field.name),
    Key = at(field_atom(Field#tg_field.name)),
    Type = field_type(Field, Ctx),
    fun(Acc) ->
        'case'(remote(maps, find, [WireName, v("Value")]), [
            clause([tuple_t([at(ok), Val])], none, [
                map_assoc(Acc, Key, from_wire_expr(Type, Val, Repr))
            ]),
            clause([at(error)], none, [Acc])
        ])
    end.

%% Every field case binds its own variable: Erlang's single assignment
%% forbids reusing one name across the sibling cases of a clause body.

-spec value_var(pos_integer()) -> ast().
value_var(I) ->
    v("V" ++ integer_to_list(I)).

%%--------------------------------------------------------------------
%% Value conversion expressions
%%--------------------------------------------------------------------

%% Scalars and enums are representation-invariant; structs and
%% containers convert. Nested structs go through the public runtime
%% entry: its probe cache makes the hop cheap, and the native-input
%% pre-check plus hand-written fallbacks stay exactly where the
%% descriptor engine has them.

%% Container element variables carry their nesting depth: a container
%% inside a container would otherwise shadow the outer comprehension's
%% variable, and generated modules compile with warnings_as_errors.

-spec to_wire_expr(ast(), ast()) -> ast().
to_wire_expr(Type, Value) ->
    to_wire_expr(Type, Value, 0).

to_wire_expr({struct, {ref, Module, Name}}, Value, _Depth) ->
    remote(thrift_runtime_record, to_wire, [literal({struct, {ref, Module, Name}}), Value]);
to_wire_expr({list, Elem}, Value, Depth) ->
    lc(to_wire_expr(Elem, elem_var(Depth), Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}]);
to_wire_expr({set, Elem}, Value, Depth) ->
    lc(to_wire_expr(Elem, elem_var(Depth), Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}]);
to_wire_expr({set, Elem, list}, Value, Depth) ->
    lc(to_wire_expr(Elem, elem_var(Depth), Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}]);
to_wire_expr({set, Elem, ordset}, Value, Depth) ->
    lc(to_wire_expr(Elem, elem_var(Depth), Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}]);
to_wire_expr({set, Elem, sets}, Value, Depth) ->
    lc(to_wire_expr(Elem, elem_var(Depth), Depth + 1), [
        {generate, ?ANNO, elem_var(Depth), remote(sets, to_list, [Value])}
    ]);
to_wire_expr({map, KeyType, ValType}, Value, Depth) ->
    remote(maps, fold, [
        fold_fun(KeyType, ValType, Depth, fun to_wire_expr/3),
        map_empty(),
        Value
    ]);
to_wire_expr(_Type, Value, _Depth) ->
    Value.

-spec from_wire_expr(ast(), ast(), ast()) -> ast().
from_wire_expr(Type, Value, Repr) ->
    from_wire_expr(Type, Value, Repr, 0).

-spec from_wire_expr(ast(), ast(), ast(), non_neg_integer()) -> ast().
from_wire_expr({struct, {ref, Module, Name}}, Value, Repr, _Depth) ->
    remote(thrift_runtime_record, from_wire, [literal({struct, {ref, Module, Name}}), Value, Repr]);
from_wire_expr({list, Elem}, Value, Repr, Depth) ->
    lc(from_wire_expr(Elem, elem_var(Depth), Repr, Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}]);
from_wire_expr({set, Elem}, Value, Repr, Depth) ->
    lc(from_wire_expr(Elem, elem_var(Depth), Repr, Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}]);
from_wire_expr({set, Elem, list}, Value, Repr, Depth) ->
    lc(from_wire_expr(Elem, elem_var(Depth), Repr, Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}]);
from_wire_expr({set, Elem, ordset}, Value, Repr, Depth) ->
    remote(ordsets, from_list, [
        lc(from_wire_expr(Elem, elem_var(Depth), Repr, Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}])
    ]);
from_wire_expr({set, Elem, sets}, Value, Repr, Depth) ->
    remote(sets, from_list, [
        lc(from_wire_expr(Elem, elem_var(Depth), Repr, Depth + 1), [{generate, ?ANNO, elem_var(Depth), Value}])
    ]);
from_wire_expr({map, KeyType, ValType}, Value, Repr, Depth) ->
    remote(maps, fold, [
        fold_fun(KeyType, ValType, Depth, fun(K, V, D) -> from_wire_expr(K, V, Repr, D) end),
        map_empty(),
        Value
    ]);
from_wire_expr(_Type, Value, _Repr, _Depth) ->
    Value.

fold_fun(KeyType, ValType, Depth, Conv) ->
    Key = v("K" ++ integer_to_list(Depth)),
    Val = elem_var(Depth),
    Acc = v("FoldAcc" ++ integer_to_list(Depth)),
    {'fun', ?ANNO,
        {clauses, [
            clause([Key, Val, Acc], none, [
                map_put(Acc, Conv(KeyType, Key, Depth + 1), Conv(ValType, Val, Depth + 1))
            ])
        ]}}.

elem_var(Depth) ->
    v("E" ++ integer_to_list(Depth)).

%%--------------------------------------------------------------------
%% Naming (mirrors thrift_generator_emitter's rules)
%%--------------------------------------------------------------------

-spec field_type(#tg_field{}, #ectx{}) -> ast().
field_type(Field, Ctx) ->
    thrift_generator_ir:type_desc(Field#tg_field.type, Ctx).

-spec field_atom(binary()) -> atom().
field_atom(Name) ->
    thrift_generator_ir:field_atom(Name).

-spec tag(#tg_struct{}, #ectx{}) -> atom().
tag(S, Ctx) ->
    thrift_generator_ir:record_tag_of(S, thrift_generator_names:current_prefix(Ctx)).

-spec types_module(#tg_module{}) -> module().
types_module(Mod) ->
    thrift_generator_names:types_module_atom(Mod#tg_module.name).
