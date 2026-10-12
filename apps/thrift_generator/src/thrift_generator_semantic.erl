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

-module(thrift_generator_semantic).

-moduledoc """
Semantic analysis: turns documents loaded by `thrift_generator_loader`
into the validated `#tg_model{}` IR consumed by the code emitter.

The pass numbers enum members and implicit field ids, resolves constant
and enum references, merges inherited service functions and validates
the result: duplicate names and field ids, union field requiredness,
oneway function shapes, throw clauses pointing at exceptions,
unresolved type references, typedef cycles and constant type
mismatches. All errors are collected as `{File, Loc, Message}`
triples before failing, where `Loc` is a line number or a
`{Line, Column}` pair (whatever the error site knows).
""".

-export([analyze/1, analyze/2]).

-export_type([sem_error/0, loc/0]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

-type def_kind() :: struct | union | exception | enum | typedef | service | const.
%% An error position: a plain line number, or a {Line, Column} pair
%% when the site has the opening token's column (columns are 1-based).

-type loc() :: non_neg_integer() | {non_neg_integer(), non_neg_integer()}.

-type sem_error() :: {File :: binary(), Loc :: loc(), Message :: binary()}.

%% A resolved reference: which module the definition lives in, its name
%% within that module and its kind.

-type resolved_ref() :: {Module :: binary(), Name :: binary(), def_kind()}.

%% Per-module analysis context. The `all_*` indexes cover every loaded
%% module (for cross-module references); `analyzed` holds modules that
%% finished before this one — the loader's root-first list reversed
%% gives dependencies first, so `extends` into included modules can
%% look up finished models.

-record(ctx, {
    module = undefined :: binary() | undefined,
    file = undefined :: binary() | undefined,
    %% the file-wide set implementation from the namespace's erl.set
    set_default = list :: list | sets | ordset,
    %% the file-wide union representation from the namespace's
    %% erl.union_type (record by default, tagged-tuple sums via "sum")
    union_default = record :: record | sum,
    %% the invocation-wide representation for definitions without an
    %% explicit erl.struct_type (the generator's --repr option; unions
    %% keep their own axis and never take this injection)
    repr_default = record :: record | map | native,
    all_defs = #{} :: #{binary() => #{binary() => def_kind()}},
    all_const_values = #{} :: #{binary() => #{binary() => const_value()}},
    all_enum_members = #{} :: #{binary() => #{binary() => [binary()]}},
    all_typedefs = #{} :: #{binary() => #{binary() => thrift_type()}},
    analyzed = #{} :: #{binary() => #tg_module{}},
    errors = [] :: [sem_error()]
}).

-doc """
Analyzes loaded documents (root first, as returned by the loader) into
a model, or returns every validation error found.
""".
-spec analyze([#tg_loaded{}]) -> {ok, #tg_model{}} | {error, [sem_error()]}.
analyze(Loaded) ->
    analyze(Loaded, #{}).

-doc """
Analyzes with invocation-wide options: `repr` (`record`, the default,
`map` or `native`) is the representation generated for definitions
without an explicit `erl.struct_type` annotation.
""".
-spec analyze([#tg_loaded{}], #{repr => record | map | native}) ->
    {ok, #tg_model{}} | {error, [sem_error()]}.
analyze([Root | _] = Loaded, Opts) ->
    Ctx0 = #ctx{
        all_defs = index_defs(Loaded, fun def_kind/1),
        all_const_values = index_defs(Loaded, fun const_value_of/1),
        all_enum_members = index_defs(Loaded, fun enum_members_of/1),
        all_typedefs = index_defs(Loaded, fun typedef_type_of/1),
        repr_default = maps:get(repr, Opts, record),
        analyzed = #{}
    },
    {ModuleMap, Ctx} =
        lists:foldl(
            fun(L, {Acc, C}) ->
                C1 = C#ctx{module = L#tg_loaded.name, file = L#tg_loaded.path},
                {Module, C2} = analyze_module(L, C1),
                %% Publish the finished module for cross-module references
                %% (extends into an include, shared constants) made while
                %% analyzing later modules.
                Acc1 = Acc#{L#tg_loaded.name => Module},
                {Acc1, C2#ctx{analyzed = Acc1}}
            end,
            {#{}, Ctx0},
            lists:reverse(Loaded)
        ),
    case Ctx#ctx.errors of
        [] ->
            Modules = [maps:get(L#tg_loaded.name, ModuleMap) || L <- Loaded],
            {ok, #tg_model{root = Root#tg_loaded.name, modules = Modules}};
        Errors ->
            {error, lists:reverse(Errors)}
    end.

%%--------------------------------------------------------------------
%% Whole-unit indexes (one entry per loaded module)
%%--------------------------------------------------------------------

-spec index_defs([#tg_loaded{}], fun((ast_node()) -> V | skip)) -> #{binary() => #{binary() => V}}.
index_defs(Loaded, Extract) ->
    #{L#tg_loaded.name => local_defs(L, Extract) || L <- Loaded}.

-spec local_defs(#tg_loaded{}, fun((ast_node()) -> V | skip)) -> #{binary() => V}.
local_defs(Loaded, Extract) ->
    lists:foldl(
        fun(Node, Acc) ->
            case Extract(Node) of
                skip ->
                    Acc;
                Value ->
                    Name = element(2, Node#thrift_generator_node.payload),
                    Acc#{Name => Value}
            end
        end,
        #{},
        definitions(Loaded)
    ).

-spec definitions(#tg_loaded{}) -> [ast_node()].
definitions(Loaded) ->
    (Loaded#tg_loaded.doc#thrift_generator_node.payload)#thrift_generator_document.definitions.

-spec def_kind(ast_node()) -> def_kind() | skip.
def_kind(Node) ->
    case Node#thrift_generator_node.type_module of
        thrift_generator_struct -> struct;
        thrift_generator_union -> union;
        thrift_generator_exception -> exception;
        thrift_generator_enum -> enum;
        thrift_generator_typedef -> typedef;
        thrift_generator_constant -> const;
        thrift_generator_service -> service;
        _ -> skip
    end.

-spec const_value_of(ast_node()) -> const_value() | skip.
const_value_of(#thrift_generator_node{payload = #thrift_generator_constant{value = V}}) -> V;
const_value_of(_) -> skip.

-spec enum_members_of(ast_node()) -> [binary()] | skip.
enum_members_of(#thrift_generator_node{payload = #thrift_generator_enum{values = Values}}) ->
    [Name || {Name, _, _, _} <- Values];
enum_members_of(_) ->
    skip.

-spec typedef_type_of(ast_node()) -> thrift_type() | skip.
typedef_type_of(#thrift_generator_node{payload = #thrift_generator_typedef{type = T}}) -> T;
typedef_type_of(_) -> skip.

%%--------------------------------------------------------------------
%% Module analysis
%%--------------------------------------------------------------------

-spec analyze_module(#tg_loaded{}, #ctx{}) -> {#tg_module{}, #ctx{}}.
analyze_module(Loaded, Ctx00) ->
    Ctx0 = namespace_union_default(Loaded, namespace_set_default(Loaded, Ctx00)),
    Defs = definitions(Loaded),
    Ctx1 = check_duplicates(Defs, Ctx0),
    {Structs, Ctx2} = lists:foldl(fun analyze_struct/2, {[], Ctx1}, Defs),
    {Enums, Ctx3} = lists:foldl(fun analyze_enum/2, {[], Ctx2}, Defs),
    {Typedefs, Ctx4} = lists:foldl(fun analyze_typedef/2, {[], Ctx3}, Defs),
    {Consts, Ctx5} = lists:foldl(fun analyze_const/2, {[], Ctx4}, Defs),
    {Services, Ctx6} = analyze_services(Defs, Ctx5),
    Ctx7 = check_typedef_cycles(Typedefs, Ctx6),
    Module =
        #tg_module{
            name = Loaded#tg_loaded.name,
            prefix = Loaded#tg_loaded.prefix,
            path = Loaded#tg_loaded.path,
            includes = Loaded#tg_loaded.includes,
            structs = lists:reverse(Structs),
            enums = lists:reverse(Enums),
            typedefs = lists:reverse(Typedefs),
            consts = lists:reverse(Consts),
            services = lists:reverse(Services)
        },
    {Module, check_generated_names(Module, Ctx7)}.

%% The emitter derives function and record names by flattening
%% (lowercasing) definition names; two definitions that flatten to the
%% same generated name would produce a duplicate — reject at analysis
%% time with a readable error instead of a compiler crash later.

-spec check_generated_names(#tg_module{}, #ctx{}) -> #ctx{}.
check_generated_names(Module, Ctx) ->
    StructTags = [{thrift_generator_names:snake(S#tg_struct.name), S#tg_struct.line} || S <- Module#tg_module.structs],
    EnumPrefixes = [{thrift_generator_names:snake(E#tg_enum.name), E#tg_enum.line} || E <- Module#tg_module.enums],
    Ctx1 = check_flat_clashes(StructTags, "record tag", Ctx),
    Ctx2 = check_flat_clashes(EnumPrefixes, "enum helper prefix", Ctx1),
    %% Sum unions index convert/2 by their field atoms; two unions
    %% claiming one atom would make the lookup ambiguous.
    SumFields = [
        {F#tg_field.name, {S#tg_struct.line, S#tg_struct.col}}
     || S <- Module#tg_module.structs,
        S#tg_struct.kind =:= union,
        maps:get(union_type, S#tg_struct.erl, <<"record">>) =:= <<"sum">>,
        F <- S#tg_struct.fields
    ],
    Ctx3 = check_flat_clashes(SumFields, "sum union field", Ctx2),
    check_const_clashes(Module, Ctx3).

-spec check_flat_clashes([{binary(), loc()}], string(), #ctx{}) -> #ctx{}.
check_flat_clashes(Pairs, What, Ctx) ->
    ByName = maps:groups_from_list(fun({N, _}) -> N end, fun({_N, L}) -> L end, Pairs),
    maps:fold(
        fun
            (Name, Locs, C) when length(Locs) > 1 ->
                [First, _Second | _] = lists:sort(Locs),
                err(First, "duplicate ~ts ~ts", [What, Name], C);
            (_Name, _Lines, C) ->
                C
        end,
        Ctx,
        ByName
    ).

%% Constant functions live in one namespace with the generated codecs:
%% a constant named like a codec function or the shared convert/tag_index
%% entries would shadow or collide with them.

-spec check_const_clashes(#tg_module{}, #ctx{}) -> #ctx{}.
check_const_clashes(Module, Ctx) ->
    Generated =
        [<<"convert">>, <<"tag_index">>] ++
            [
                Prefix
             || S <- Module#tg_module.structs,
                Snake <- [thrift_generator_names:snake(S#tg_struct.name)],
                Prefix <- [
                    <<"encode_", Snake/binary>>,
                    <<"decode_", Snake/binary>>,
                    <<Snake/binary, "_from_map">>
                ]
            ] ++
            [
                <<(thrift_generator_names:snake(E#tg_enum.name))/binary, Suffix/binary>>
             || E <- Module#tg_module.enums,
                Suffix <- [<<"_to_int">>, <<"_from_int">>]
            ],
    lists:foldl(
        fun(C, C0) ->
            Snake = thrift_generator_names:snake(C#tg_const.name),
            case lists:member(Snake, Generated) of
                true ->
                    err(
                        {C#tg_const.line, C#tg_const.col},
                        "constant ~ts collides with a generated function name",
                        [C#tg_const.name],
                        C0
                    );
                false ->
                    C0
            end
        end,
        Ctx,
        Module#tg_module.consts
    ).

%% Duplicate definition names within one module are rejected whatever
%% kinds are involved (a const colliding with a struct is a clash).

-spec check_duplicates([ast_node()], #ctx{}) -> #ctx{}.
check_duplicates(Defs, Ctx) ->
    Names = [element(2, N#thrift_generator_node.payload) || N <- Defs],
    Duplicates = [Name || Name <- lists:usort(Names), count(Name, Names) > 1],
    lists:foldl(
        fun(Name, C) ->
            [Node | _] = [N || N <- Defs, element(2, N#thrift_generator_node.payload) =:= Name],
            err(loc(Node), "duplicate definition of ~ts", [Name], C)
        end,
        Ctx,
        Duplicates
    ).

-spec count(binary(), [binary()]) -> non_neg_integer().
count(Name, Names) ->
    length([N || N <- Names, N =:= Name]).

%% -- structs, unions, exceptions -------------------------------------
%% The three payload records share layout: element 2 is the name,
%% element 3 the field list.

-spec analyze_struct(ast_node(), {[#tg_struct{}], #ctx{}}) -> {[#tg_struct{}], #ctx{}}.
analyze_struct(Node, {Acc, Ctx}) ->
    case Node#thrift_generator_node.type_module of
        thrift_generator_struct -> build_struct(Node, struct, Acc, Ctx);
        thrift_generator_union -> build_struct(Node, union, Acc, Ctx);
        thrift_generator_exception -> build_struct(Node, exception, Acc, Ctx);
        _ -> {Acc, Ctx}
    end.

-spec build_struct(ast_node(), struct | union | exception, [#tg_struct{}], #ctx{}) ->
    {[#tg_struct{}], #ctx{}}.
build_struct(Node, Kind, Acc, Ctx0) ->
    %% struct, union and exception share the payload shape but arrive
    %% as three distinct records; named reads keep the fields visible
    %% to tooling
    {Name, FieldsRaw} =
        case Node#thrift_generator_node.payload of
            #thrift_generator_struct{name = N, fields = F} -> {N, F};
            #thrift_generator_union{name = N, fields = F} -> {N, F};
            #thrift_generator_exception{name = N, fields = F} -> {N, F}
        end,
    Line = Node#thrift_generator_node.line,
    {Fields, Ctx} = analyze_fields(FieldsRaw, Kind, Ctx0),
    Erl = struct_type_default(Kind, union_default_annotation(Node, Kind, Ctx), Ctx),
    Struct =
        #tg_struct{
            kind = Kind,
            name = Name,
            fields = Fields,
            erl = Erl,
            doc = Node#thrift_generator_node.doc,
            line = Line,
            col = Node#thrift_generator_node.col
        },
    Ctx1 = check_struct_annotations(Struct, Ctx),
    {[Struct | Acc], Ctx1}.

%% The file-wide union representation (the namespace header's
%% erl.union_type) is materialized onto every union without an explicit
%% annotation, so the emitter keeps reading the plain annotation.

-spec union_default_annotation(ast_node(), struct | union | exception, #ctx{}) -> erl_annotations().
union_default_annotation(Node, Kind, Ctx) ->
    Erl = Node#thrift_generator_node.annotations,
    case Kind =:= union andalso Ctx#ctx.union_default =:= sum andalso not maps:is_key(union_type, Erl) of
        true -> Erl#{union_type => <<"sum">>};
        false -> Erl
    end.

%% The invocation-wide representation (--repr) materializes onto every
%% struct and exception without an explicit annotation, so the emitter
%% keeps reading the plain annotation; `record' injects nothing — the
%% annotation-free default stays the tuple record. Unions keep their own
%% axis (erl.union_type) and never take this injection.

-spec struct_type_default(struct | union | exception, erl_annotations(), #ctx{}) ->
    erl_annotations().
struct_type_default(union, Erl, _Ctx) ->
    Erl;
struct_type_default(_Kind, Erl, Ctx) ->
    case Ctx#ctx.repr_default of
        record ->
            Erl;
        Repr when Repr =:= map; Repr =:= native ->
            case maps:is_key(struct_type, Erl) of
                true -> Erl;
                false -> Erl#{struct_type => atom_to_binary(Repr, utf8)}
            end
    end.

%% The erl.* struct annotations drive the representation axis in the
%% generated code; an unrecognized value would silently change meaning,
%% so analysis rejects it. erl.union_type is a union-only annotation.

-spec union_type_kind(#tg_struct{}, #ctx{}) -> #ctx{}.
union_type_kind(#tg_struct{kind = union}, Ctx) ->
    Ctx;
union_type_kind(S, Ctx) ->
    err({S#tg_struct.line, S#tg_struct.col}, "erl.union_type belongs on a union", [], Ctx).

-spec check_struct_annotations(#tg_struct{}, #ctx{}) -> #ctx{}.
check_struct_annotations(S, Ctx0) ->
    Erl = S#tg_struct.erl,
    Ctx1 =
        case maps:get(struct_type, Erl, undefined) of
            undefined -> Ctx0;
            <<"map">> -> Ctx0;
            <<"record">> -> Ctx0;
            <<"native">> -> Ctx0;
            Value -> err({S#tg_struct.line, S#tg_struct.col}, "unknown erl.struct_type ~ts", [Value], Ctx0)
        end,
    Ctx2 =
        case maps:get(union_type, Erl, undefined) of
            undefined ->
                Ctx1;
            UnionType when UnionType =:= <<"sum">>; UnionType =:= <<"record">> ->
                union_type_kind(S, Ctx1);
            UnionType ->
                err(
                    {S#tg_struct.line, S#tg_struct.col},
                    "unknown erl.union_type ~ts (expected \"record\" or \"sum\")",
                    [UnionType],
                    Ctx1
                )
        end,
    case maps:get('struct_type.map.key_type', Erl, undefined) of
        undefined ->
            Ctx2;
        KeyType when KeyType =:= <<"atom">>; KeyType =:= <<"binary">> ->
            case maps:get(struct_type, Erl, undefined) of
                <<"map">> ->
                    Ctx2;
                _ ->
                    err(
                        {S#tg_struct.line, S#tg_struct.col},
                        "erl.struct_type.map.key_type requires erl.struct_type = \"map\"",
                        [],
                        Ctx2
                    )
            end;
        KeyType ->
            err({S#tg_struct.line, S#tg_struct.col}, "unknown erl.struct_type.map.key_type ~ts", [KeyType], Ctx2)
    end.

%% Field conversion shared by structs/unions/exceptions and function
%% parameters/throws. Thrift legacy rule: fields without an explicit id
%% get negative ids (-1, -2, ...) in declaration order; existing ids
%% are never renumbered.

-spec analyze_fields([ast_node()], struct | union | exception, #ctx{}) ->
    {[#tg_field{}], #ctx{}}.
analyze_fields(FieldNodes, Kind, Ctx) ->
    analyze_fields(FieldNodes, Kind, 1, #{}, [], Ctx).

-spec analyze_fields(
    [ast_node()],
    struct | union | exception,
    pos_integer(),
    #{integer() => binary()},
    [#tg_field{}],
    #ctx{}
) -> {[#tg_field{}], #ctx{}}.
analyze_fields([], _Kind, _NextImplicit, _Seen, Acc, Ctx) ->
    {lists:reverse(Acc), Ctx};
analyze_fields([FieldNode | Rest], Kind, NextImplicit, Seen, Acc, Ctx0) ->
    #thrift_generator_field{
        id = RawId,
        required = Required,
        type = Type,
        name = FieldName,
        default = Default
    } = FieldNode#thrift_generator_node.payload,
    Loc = loc(FieldNode),
    {Id, Next} =
        case RawId of
            undefined ->
                {-NextImplicit, NextImplicit + 1};
            Explicit ->
                {Explicit, NextImplicit}
        end,
    Ctx1 =
        case Seen of
            #{Id := Other} ->
                err(Loc, "duplicate field id ~b (already used by ~ts)", [Id, Other], Ctx0);
            _ ->
                Ctx0
        end,
    Ctx2 =
        case {Kind, Required} of
            {union, required} ->
                err(Loc, "union field ~ts must be optional", [FieldName], Ctx1);
            _ ->
                Ctx1
        end,
    Ctx3 = validate_type(Type, Loc, Ctx2),
    Type1 = apply_set_default(Type, Ctx3),
    Ctx4 = reject_misplaced_set_impl(FieldNode#thrift_generator_node.annotations, Loc, Ctx3),
    {DefaultResolved, Ctx5} =
        case Default of
            undefined ->
                {undefined, Ctx4};
            _ ->
                case resolve_value(Default, #{}, Ctx4) of
                    {ok, Resolved} ->
                        {Resolved, Ctx4};
                    {error, Reason} ->
                        {undefined, err(Loc, "unresolved default value: ~ts", [format("~tp", [Reason])], Ctx4)}
                end
        end,
    Field =
        #tg_field{
            id = Id,
            required = Required,
            type = Type1,
            name = FieldName,
            default = DefaultResolved,
            erl = FieldNode#thrift_generator_node.annotations,
            doc = FieldNode#thrift_generator_node.doc
        },
    analyze_fields(Rest, Kind, Next, Seen#{Id => FieldName}, [Field | Acc], Ctx5).

%% -- enums -----------------------------------------------------------

-spec analyze_enum(ast_node(), {[#tg_enum{}], #ctx{}}) -> {[#tg_enum{}], #ctx{}}.
analyze_enum(Node, {Acc, Ctx}) ->
    case Node#thrift_generator_node.type_module of
        thrift_generator_enum ->
            #thrift_generator_enum{name = Name, values = Raw} = Node#thrift_generator_node.payload,
            Loc = loc(Node),
            {Pairs, Ctx1} = number_enum_values(Raw, Loc, -1, #{}, #{}, [], Ctx),
            Enum =
                #tg_enum{
                    name = Name,
                    values = lists:reverse(Pairs),
                    erl = Node#thrift_generator_node.annotations,
                    doc = Node#thrift_generator_node.doc,
                    line = Node#thrift_generator_node.line,
                    col = Node#thrift_generator_node.col
                },
            {[Enum | Acc], Ctx1};
        _ ->
            {Acc, Ctx}
    end.

-spec number_enum_values(
    [enum_value()],
    loc(),
    integer(),
    #{binary() => true},
    #{integer() => binary()},
    [{integer(), binary()}],
    #ctx{}
) -> {[{integer(), binary()}], #ctx{}}.
number_enum_values([], _Loc, _Prev, _Names, _Values, Acc, Ctx) ->
    {Acc, Ctx};
number_enum_values([{Name, RawValue, _Ann, _Doc} | Rest], Loc, Prev, Names, Values, Acc, Ctx0) ->
    Ctx1 =
        case Names of
            #{Name := true} ->
                err(Loc, "duplicate enum member ~ts", [Name], Ctx0);
            _ ->
                Ctx0
        end,
    Value =
        case RawValue of
            undefined ->
                Prev + 1;
            Explicit ->
                Explicit
        end,
    Ctx =
        case Values of
            #{Value := Other} ->
                err(
                    Loc,
                    "duplicate enum value ~b for member ~ts (already used by ~ts)",
                    [Value, Name, Other],
                    Ctx1
                );
            _ ->
                Ctx1
        end,
    number_enum_values(
        Rest, Loc, Value, Names#{Name => true}, Values#{Value => Name}, [{Value, Name} | Acc], Ctx
    ).

%% -- typedefs --------------------------------------------------------

-spec analyze_typedef(ast_node(), {[#tg_typedef{}], #ctx{}}) -> {[#tg_typedef{}], #ctx{}}.
analyze_typedef(Node, {Acc, Ctx}) ->
    case Node#thrift_generator_node.type_module of
        thrift_generator_typedef ->
            #thrift_generator_typedef{name = Name, type = Type} = Node#thrift_generator_node.payload,
            Loc = loc(Node),
            Ctx1 = validate_type(Type, Loc, Ctx),
            Ctx2 = reject_misplaced_set_impl(Node#thrift_generator_node.annotations, Loc, Ctx1),
            Typedef =
                #tg_typedef{
                    name = Name,
                    type = apply_set_default(Type, Ctx1),
                    erl = Node#thrift_generator_node.annotations,
                    doc = Node#thrift_generator_node.doc,
                    line = Node#thrift_generator_node.line,
                    col = Node#thrift_generator_node.col
                },
            {[Typedef | Acc], Ctx2};
        _ ->
            {Acc, Ctx}
    end.

%% Only pure local typedef-to-typedef chains can cycle: includes are
%% acyclic and recursion through structs is legal Thrift.

-spec check_typedef_cycles([#tg_typedef{}], #ctx{}) -> #ctx{}.
check_typedef_cycles(Typedefs, Ctx) ->
    LocalTypedefs = #{T#tg_typedef.name => T || T <- Typedefs},
    lists:foldl(
        fun(T, C) ->
            visit_typedef(T#tg_typedef.name, {T#tg_typedef.line, T#tg_typedef.col}, LocalTypedefs, #{}, C)
        end,
        Ctx,
        Typedefs
    ).

-spec visit_typedef(
    binary(), loc(), #{binary() => #tg_typedef{}}, #{binary() => true}, #ctx{}
) -> #ctx{}.
visit_typedef(Name, Loc, LocalTypedefs, Visiting, Ctx) ->
    case Visiting of
        #{Name := true} ->
            err(Loc, "typedef cycle through ~ts", [Name], Ctx);
        _ ->
            case LocalTypedefs of
                #{Name := #tg_typedef{type = {ref, Target, _}}} ->
                    case is_local_name(Target) andalso maps:is_key(Target, LocalTypedefs) of
                        true ->
                            visit_typedef(Target, Loc, LocalTypedefs, Visiting#{Name => true}, Ctx);
                        false ->
                            Ctx
                    end;
                _ ->
                    Ctx
            end
    end.

%% -- consts ----------------------------------------------------------

-spec analyze_const(ast_node(), {[#tg_const{}], #ctx{}}) -> {[#tg_const{}], #ctx{}}.
analyze_const(Node, {Acc, Ctx}) ->
    case Node#thrift_generator_node.type_module of
        thrift_generator_constant ->
            #thrift_generator_constant{name = Name, type = Type, value = Value} =
                Node#thrift_generator_node.payload,
            Loc = loc(Node),
            Ctx1 = validate_type(Type, Loc, Ctx),
            case resolve_value(Value, #{}, Ctx1) of
                {ok, Resolved} ->
                    Const =
                        #tg_const{
                            name = Name,
                            type = apply_set_default(Type, Ctx1),
                            value = Resolved,
                            erl = Node#thrift_generator_node.annotations,
                            doc = Node#thrift_generator_node.doc,
                            line = Node#thrift_generator_node.line,
                            col = Node#thrift_generator_node.col
                        },
                    case check_value(Type, Resolved, Ctx1) of
                        ok ->
                            {[Const | Acc], Ctx1};
                        {error, Msg} ->
                            {[Const | Acc], err(Loc, "constant ~ts: ~ts", [Name, Msg], Ctx1)}
                    end;
                {error, Reason} ->
                    {Acc, err(Loc, "constant ~ts: ~ts", [Name, format("~tp", [Reason])], Ctx1)}
            end;
        _ ->
            {Acc, Ctx}
    end.

%% Shallow type check of the resolved literal against the declared
%% type. Int literals pass for double; list literals pass for set;
%% local typedefs are expanded before matching.

-spec check_value(thrift_type(), const_value(), #ctx{}) -> ok | {error, binary()}.
check_value({ref, Ref, _}, Value, Ctx) ->
    case local_typedef_target(Ref, Ctx) of
        {ok, Target} ->
            check_value(Target, Value, Ctx);
        error ->
            check_named_value(Ref, Value, Ctx)
    end;
check_value({base, bool, _}, Value, _Ctx) when is_boolean(Value) ->
    ok;
check_value({base, B, _}, Value, _Ctx) when
    is_integer(Value), B =:= i8 orelse B =:= i16 orelse B =:= i32 orelse B =:= i64
->
    case in_range(B, Value) of
        true ->
            ok;
        false ->
            {error, format("integer ~b out of range for ~w", [Value, B])}
    end;
check_value({base, double, _}, Value, _Ctx) when is_number(Value) ->
    ok;
check_value({base, S, _}, Value, _Ctx) when is_binary(Value), S =:= string; S =:= binary ->
    ok;
check_value({base, uuid, _}, Value, _Ctx) when is_binary(Value), byte_size(Value) =:= 16 ->
    ok;
check_value({list, Elem, _}, {list, Items}, Ctx) ->
    check_each(lists:duplicate(length(Items), Elem), Items, Ctx);
check_value({set, Elem, _}, {list, Items}, Ctx) ->
    check_each(lists:duplicate(length(Items), Elem), Items, Ctx);
check_value({map, KeyType, ValType, _}, {map, Pairs}, Ctx) ->
    Keys = lists:duplicate(length(Pairs), KeyType),
    Vals = lists:duplicate(length(Pairs), ValType),
    case check_each(Keys, [K || {K, _} <- Pairs], Ctx) of
        ok ->
            check_each(Vals, [V || {_, V} <- Pairs], Ctx);
        KeyError ->
            KeyError
    end;
check_value(Type, Value, _Ctx) ->
    {error, format("value ~tp does not match type ~tw", [Value, Type])}.

%% A named type that is not a (local) typedef: enum members arrive as
%% binaries; struct/union/exception constants as map literals.

-spec check_named_value(binary(), const_value(), #ctx{}) -> ok | {error, binary()}.
check_named_value(Ref, Value, Ctx) when is_binary(Value) ->
    case enum_members(Ref, Ctx) of
        {ok, Members} ->
            case lists:member(Value, Members) of
                true ->
                    ok;
                false ->
                    {error, format("~ts is not a member of enum ~ts", [Value, Ref])}
            end;
        error ->
            {error, format("value ~ts does not match non-enum type ~ts", [Value, Ref])}
    end;
check_named_value(Ref, {map, _Pairs}, Ctx) ->
    case resolve_type_ref(Ref, Ctx) of
        {ok, {_, _, Kind}} when Kind =:= struct; Kind =:= union; Kind =:= exception ->
            ok;
        {ok, {_, _, Kind}} ->
            {error, format("map literal given for ~ts of kind ~w", [Ref, Kind])};
        error ->
            {error, format("unknown type ~ts", [Ref])}
    end;
check_named_value(Ref, Value, _Ctx) ->
    {error, format("value ~tp does not match type ~ts", [Value, Ref])}.

-spec check_each([thrift_type()], [const_value()], #ctx{}) -> ok | {error, binary()}.
check_each(Types, Values, Ctx) ->
    lists:foldl(
        fun
            ({T, V}, ok) -> check_value(T, V, Ctx);
            (_, Error) -> Error
        end,
        ok,
        lists:zip(Types, Values)
    ).

-spec local_typedef_target(binary(), #ctx{}) -> {ok, thrift_type()} | error.
local_typedef_target(Ref, Ctx) ->
    maps:find(Ref, maps:get(Ctx#ctx.module, Ctx#ctx.all_typedefs, #{})).

%% -- services --------------------------------------------------------

-spec analyze_services([ast_node()], #ctx{}) -> {[#tg_service{}], #ctx{}}.
analyze_services(Defs, Ctx) ->
    RawServices = [N || N <- Defs, N#thrift_generator_node.type_module =:= thrift_generator_service],
    ByName = #{service_name(N) => N || N <- RawServices},
    lists:foldl(
        fun(Node, {Acc, C0}) ->
            {Service, C1} = analyze_service(Node, ByName, #{}, C0),
            {[Service | Acc], C1}
        end,
        {[], Ctx},
        RawServices
    ).

-spec service_name(ast_node()) -> binary().
service_name(Node) ->
    (Node#thrift_generator_node.payload)#thrift_generator_service.name.

-spec analyze_service(ast_node(), #{binary() => ast_node()}, #{binary() => true}, #ctx{}) ->
    {#tg_service{}, #ctx{}}.
analyze_service(Node, ByName, InProgress, Ctx0) ->
    #thrift_generator_service{name = Name, extends = Extends, functions = RawFunctions} =
        Node#thrift_generator_node.payload,
    Loc = loc(Node),
    case InProgress of
        #{Name := true} ->
            {empty_service(Name), err(Loc, "service extends cycle through ~ts", [Name], Ctx0)};
        _ ->
            {ParentFunctions, Ctx1} =
                parent_functions(Extends, Loc, ByName, InProgress#{Name => true}, Ctx0),
            {Own, Ctx2} = analyze_functions(RawFunctions, Ctx1),
            {Merged, Ctx3} = merge_functions(ParentFunctions, Own, Loc, Ctx2),
            Service =
                #tg_service{
                    name = Name,
                    extends = Extends,
                    functions = Merged,
                    erl = Node#thrift_generator_node.annotations,
                    doc = Node#thrift_generator_node.doc,
                    line = Node#thrift_generator_node.line,
                    col = Node#thrift_generator_node.col
                },
            {Service, Ctx3}
    end.

-spec empty_service(binary()) -> #tg_service{}.
empty_service(Name) ->
    #tg_service{name = Name, extends = undefined, functions = []}.

-spec parent_functions(
    binary() | undefined,
    loc(),
    #{binary() => ast_node()},
    #{binary() => true},
    #ctx{}
) -> {[#tg_function{}], #ctx{}}.
parent_functions(undefined, _Loc, _ByName, _InProgress, Ctx) ->
    {[], Ctx};
parent_functions(ParentName, Loc, ByName, InProgress, Ctx0) when is_binary(ParentName) ->
    Ctx = validate_type({ref, ParentName, #{}}, Loc, Ctx0),
    case resolve_type_ref(ParentName, Ctx) of
        {ok, {Module, _, service}} when Module =:= Ctx#ctx.module ->
            case ByName of
                #{ParentName := ParentNode} ->
                    {#tg_service{functions = Fns}, C1} =
                        analyze_service(ParentNode, ByName, InProgress, Ctx),
                    {Fns, C1};
                _ ->
                    {[], err(Loc, "unknown service ~ts", [ParentName], Ctx)}
            end;
        {ok, {Module, LocalName, service}} ->
            included_service_functions(Module, LocalName, Loc, Ctx);
        _ ->
            {[], err(Loc, "~ts is not a service", [ParentName], Ctx)}
    end.

%% An `extends` into an included module: the parent's merged functions
%% come from that module's finished analysis (dependencies are
%% analyzed first).

-spec included_service_functions(binary(), binary(), loc(), #ctx{}) ->
    {[#tg_function{}], #ctx{}}.
included_service_functions(Module, LocalName, Loc, Ctx) ->
    Found =
        lists:filtermap(
            fun({_ModuleName, Model}) ->
                case [S || S <- Model#tg_module.services, S#tg_service.name =:= LocalName] of
                    [#tg_service{functions = Fns}] ->
                        {true, Fns};
                    _ ->
                        false
                end
            end,
            maps:to_list(maps:filter(fun(M, _) -> M =:= Module end, Ctx#ctx.analyzed))
        ),
    case Found of
        [Fns | _] ->
            {Fns, Ctx};
        [] ->
            {[], err(Loc, "unknown service ~ts", [LocalName], Ctx)}
    end.

-spec merge_functions([#tg_function{}], [#tg_function{}], loc(), #ctx{}) ->
    {[#tg_function{}], #ctx{}}.
merge_functions(Parent, Own, Loc, Ctx0) ->
    ParentNames = [F#tg_function.name || F <- Parent],
    Overridden = [Name || Name <- [F#tg_function.name || F <- Own], lists:member(Name, ParentNames)],
    Ctx =
        case Overridden of
            [] ->
                Ctx0;
            [First | _] ->
                err(Loc, "function ~ts overrides an inherited function", [First], Ctx0)
        end,
    {Parent ++ Own, Ctx}.

-spec analyze_functions([ast_node()], #ctx{}) -> {[#tg_function{}], #ctx{}}.
analyze_functions(Nodes, Ctx) ->
    {Fns, CtxEnd} =
        lists:foldl(
            fun(Node, {Acc, C0}) ->
                #thrift_generator_function{
                    oneway = Oneway,
                    return_type = ReturnType,
                    name = Name,
                    fields = Params,
                    throws = Throws
                } = Node#thrift_generator_node.payload,
                Loc = loc(Node),
                C1 =
                    case {Oneway, ReturnType, Throws} of
                        {true, void, []} ->
                            C0;
                        {true, _, _} ->
                            err(Loc, "oneway function ~ts must return void and throw nothing", [Name], C0);
                        _ ->
                            C0
                    end,
                C2 =
                    case ReturnType of
                        void ->
                            C1;
                        Type ->
                            validate_type(Type, Loc, C1)
                    end,
                {ParamsResolved, C3} = analyze_fields(Params, struct, C2),
                {ThrowsResolved, C4} = analyze_fields(Throws, struct, C3),
                C5 = validate_throws(ThrowsResolved, Loc, C4),
                Function =
                    #tg_function{
                        name = Name,
                        oneway = Oneway,
                        return_type = apply_set_default(ReturnType, C1),
                        params = ParamsResolved,
                        throws = ThrowsResolved,
                        doc = Node#thrift_generator_node.doc
                    },
                {[Function | Acc], C5}
            end,
            {[], Ctx},
            Nodes
        ),
    {lists:reverse(Fns), CtxEnd}.

%% Declared throw fields must reference exceptions.

-spec validate_throws([#tg_field{}], loc(), #ctx{}) -> #ctx{}.
validate_throws(Fields, Loc, Ctx) ->
    lists:foldl(
        fun
            %% Apache Thrift rejects `required` in a throws clause
            %% (0.18, THRIFT-5669): the flag has no wire meaning there.
            (#tg_field{name = Name, required = required}, C) ->
                err(Loc, "throw field ~ts cannot be required", [Name], C);
            (#tg_field{type = {ref, Ref, _}}, C) ->
                case resolve_type_ref(Ref, C) of
                    {ok, {_, _, exception}} ->
                        C;
                    {ok, {_, _, _}} ->
                        err(Loc, "throw field must be an exception, got ~ts", [Ref], C);
                    error ->
                        C
                end;
            (_, C) ->
                C
        end,
        Ctx,
        Fields
    ).

%%--------------------------------------------------------------------
%% Reference resolution and validation
%%--------------------------------------------------------------------

%% Validates every {ref, Name, _} inside a type (recursing through
%% containers) against the local module and every loaded module.

-spec validate_type(thrift_type(), loc(), #ctx{}) -> #ctx{}.
validate_type({ref, Name, _}, Loc, Ctx) ->
    case resolve_type_ref(Name, Ctx) of
        {ok, _} ->
            Ctx;
        error ->
            err(Loc, "unknown type ~ts", [Name], Ctx)
    end;
validate_type({list, Elem, _}, Loc, Ctx) ->
    validate_type(Elem, Loc, Ctx);
validate_type({set, Elem, Ann}, Loc, Ctx) ->
    Ctx1 = validate_set_impl(Ann, Loc, Ctx),
    validate_type(Elem, Loc, Ctx1);
validate_type({map, Key, Value, _}, Loc, Ctx) ->
    validate_type(Key, Loc, validate_type(Value, Loc, Ctx));
validate_type(_Base, _Loc, Ctx) ->
    Ctx.

%% The erl.set annotation picks the in-process set implementation
%% (`sets` v2 or `ordsets`); the wire encoding is unchanged either way.

-spec validate_set_impl(annotations(), loc(), #ctx{}) -> #ctx{}.
validate_set_impl(Ann, Loc, Ctx) ->
    case maps:find(<<"erl.set">>, Ann) of
        error ->
            Ctx;
        {ok, Impl} when Impl =:= <<"sets">>; Impl =:= <<"ordset">> ->
            Ctx;
        {ok, Impl} ->
            err(Loc, "unknown erl.set ~ts (expected \"sets\" or \"ordset\")", [Impl], Ctx)
    end.

%% `erl.set` only works as a type annotation (between the set<...> type
%% and the name); written after the name it would land on the field or
%% typedef node and be silently ignored, so reject it up front.

-spec reject_misplaced_set_impl(erl_annotations(), loc(), #ctx{}) -> #ctx{}.
reject_misplaced_set_impl(Ann, Loc, Ctx) ->
    case maps:is_key(set, Ann) of
        true ->
            err(
                Loc,
                "erl.set belongs between the set<...> type and the name, not after it",
                [],
                Ctx
            );
        false ->
            Ctx
    end.

%% The erl.set annotation on the `namespace erl` (or `*`) header is the
%% file-wide set implementation: every set type of the module without
%% an explicit annotation gets it injected during analysis, so the
%% emitter keeps reading the plain type annotation. The namespace pick
%% mirrors the loader: the erl scope wins over the wildcard one.

-spec namespace_set_default(#tg_loaded{}, #ctx{}) -> #ctx{}.
namespace_set_default(Loaded, Ctx) ->
    Headers = (Loaded#tg_loaded.doc#thrift_generator_node.payload)#thrift_generator_document.headers,
    case namespace_set_annotation(Headers, <<"erl">>) of
        undefined ->
            case namespace_set_annotation(Headers, <<"*">>) of
                undefined -> Ctx;
                Found -> apply_namespace_set_default(Found, Ctx)
            end;
        Found ->
            apply_namespace_set_default(Found, Ctx)
    end.

%% The erl.union_type annotation on the namespace header is the
%% file-wide union representation ("record", the default, or "sum" —
%% tagged tuples instead of records); explicit per-union annotations
%% win, everything else mirrors erl.set.

-spec namespace_union_default(#tg_loaded{}, #ctx{}) -> #ctx{}.
namespace_union_default(Loaded, Ctx) ->
    Headers = (Loaded#tg_loaded.doc#thrift_generator_node.payload)#thrift_generator_document.headers,
    case namespace_annotation(Headers, <<"erl">>, union_type) of
        undefined ->
            case namespace_annotation(Headers, <<"*">>, union_type) of
                undefined -> Ctx;
                Found -> apply_namespace_union_default(Found, Ctx)
            end;
        Found ->
            apply_namespace_union_default(Found, Ctx)
    end.

-spec namespace_annotation([ast_node()], binary(), atom()) -> {ast_node(), binary()} | undefined.
namespace_annotation(Headers, Scope, Key) ->
    Candidates = [
        {Node, maps:get(Key, Node#thrift_generator_node.annotations)}
     || Node <- Headers,
        namespace_scope_is(Node, Scope),
        maps:is_key(Key, Node#thrift_generator_node.annotations)
    ],
    case Candidates of
        [Found | _] -> Found;
        [] -> undefined
    end.

-spec namespace_set_annotation([ast_node()], binary()) -> {ast_node(), binary()} | undefined.
namespace_set_annotation(Headers, Scope) ->
    namespace_annotation(Headers, Scope, set).

-spec namespace_scope_is(ast_node(), binary()) -> boolean().
namespace_scope_is(Node, Scope) ->
    case Node#thrift_generator_node.payload of
        #thrift_generator_namespace{scope = NamespaceScope} -> NamespaceScope =:= Scope;
        _ -> false
    end.

-spec apply_namespace_set_default({ast_node(), binary()}, #ctx{}) -> #ctx{}.
apply_namespace_set_default({_Node, <<"sets">>}, Ctx) ->
    Ctx#ctx{set_default = sets};
apply_namespace_set_default({_Node, <<"ordset">>}, Ctx) ->
    Ctx#ctx{set_default = ordset};
apply_namespace_set_default({Node, Other}, Ctx) ->
    err(
        loc(Node),
        "unknown erl.set ~ts (expected \"sets\" or \"ordset\")",
        [Other],
        Ctx
    ).

-spec apply_namespace_union_default({ast_node(), binary()}, #ctx{}) -> #ctx{}.
apply_namespace_union_default({_Node, <<"record">>}, Ctx) ->
    Ctx#ctx{union_default = record};
apply_namespace_union_default({_Node, <<"sum">>}, Ctx) ->
    Ctx#ctx{union_default = sum};
apply_namespace_union_default({Node, Other}, Ctx) ->
    err(
        loc(Node),
        "unknown erl.union_type ~ts (expected \"record\" or \"sum\")",
        [Other],
        Ctx
    ).

%% Rewrites every set type without an explicit annotation into the
%% file-wide default; explicit annotations and the no-namespace case
%% leave the type untouched. Container shapes are preserved.

-spec apply_set_default(thrift_type(), #ctx{}) -> thrift_type().
apply_set_default({set, Elem, Ann}, Ctx) ->
    Elem1 = apply_set_default(Elem, Ctx),
    case maps:is_key(<<"erl.set">>, Ann) orelse Ctx#ctx.set_default =:= list of
        true ->
            {set, Elem1, Ann};
        false ->
            {set, Elem1, Ann#{<<"erl.set">> => atom_to_binary(Ctx#ctx.set_default, utf8)}}
    end;
apply_set_default({list, Elem, Ann}, Ctx) ->
    {list, apply_set_default(Elem, Ctx), Ann};
apply_set_default({map, Key, Value, Ann}, Ctx) ->
    {map, apply_set_default(Key, Ctx), apply_set_default(Value, Ctx), Ann};
apply_set_default(Type, _Ctx) ->
    Type.

%% A name without dots resolves locally; a dotted name resolves as
%% Module.Name across every loaded module.

-spec resolve_type_ref(binary(), #ctx{}) -> {ok, resolved_ref()} | error.
resolve_type_ref(Name, Ctx) ->
    case is_local_name(Name) of
        true ->
            case maps:get(Ctx#ctx.module, Ctx#ctx.all_defs, #{}) of
                #{Name := Kind} -> {ok, {Ctx#ctx.module, Name, Kind}};
                _ -> error
            end;
        false ->
            find_first(fun(Module) -> dotted_ref(Name, Module, Ctx) end, maps:keys(Ctx#ctx.all_defs))
    end.

%% Resolves `Name` as `Module.Name`: the part after the prefix must be
%% a definition of the module.
-spec dotted_ref(binary(), binary(), #ctx{}) -> {ok, resolved_ref()} | error.
dotted_ref(Name, Module, Ctx) ->
    case strip_prefix(Name, Module) of
        error ->
            error;
        Rest ->
            case maps:get(Module, Ctx#ctx.all_defs, #{}) of
                #{Rest := Kind} -> {ok, {Module, Rest, Kind}};
                _ -> error
            end
    end.

-spec enum_members(binary(), #ctx{}) -> {ok, [binary()]} | error.
enum_members(Ref, Ctx) ->
    case resolve_type_ref(Ref, Ctx) of
        {ok, {Module, Name, enum}} ->
            {ok, maps:get(Name, maps:get(Module, Ctx#ctx.all_enum_members, #{}), [])};
        _ ->
            error
    end.

%% Resolves constant and enum-member references in default values and
%% constants, with cycle protection. Local scope wins over included
%% modules; enum members resolve to their name binary.

-spec resolve_value(const_value(), #{binary() => true}, #ctx{}) ->
    {ok, const_value()} | {error, term()}.
resolve_value({ref, Ref}, Visited, Ctx) ->
    case Visited of
        #{Ref := true} ->
            {error, {reference_cycle, Ref}};
        _ ->
            case resolve_value_ref(Ref, Ctx) of
                {ok, {const, Value}} ->
                    resolve_value(Value, Visited#{Ref => true}, Ctx);
                {ok, {enum_member, Member}} ->
                    {ok, Member};
                error ->
                    {error, {unknown_reference, Ref}}
            end
    end;
resolve_value({list, Items}, Visited, Ctx) ->
    resolve_items(Items, Visited, Ctx, []);
resolve_value({map, Pairs}, Visited, Ctx) ->
    resolve_pairs(Pairs, Visited, Ctx, []);
resolve_value(Literal, _Visited, _Ctx) when
    is_boolean(Literal); is_integer(Literal); is_float(Literal); is_binary(Literal)
->
    {ok, Literal}.

-spec resolve_items([const_value()], #{binary() => true}, #ctx{}, [const_value()]) ->
    {ok, const_value()} | {error, term()}.
resolve_items([], _Visited, _Ctx, Acc) ->
    {ok, {list, lists:reverse(Acc)}};
resolve_items([Item | Rest], Visited, Ctx, Acc) ->
    case resolve_value(Item, Visited, Ctx) of
        {ok, Resolved} ->
            resolve_items(Rest, Visited, Ctx, [Resolved | Acc]);
        Error ->
            Error
    end.

-spec resolve_pairs(
    [{const_value(), const_value()}], #{binary() => true}, #ctx{}, [{const_value(), const_value()}]
) -> {ok, const_value()} | {error, term()}.
resolve_pairs([], _Visited, _Ctx, Acc) ->
    {ok, {map, lists:reverse(Acc)}};
resolve_pairs([{K, V} | Rest], Visited, Ctx, Acc) ->
    maybe
        {ok, KR} ?= resolve_value(K, Visited, Ctx),
        {ok, VR} ?= resolve_value(V, Visited, Ctx),
        resolve_pairs(Rest, Visited, Ctx, [{KR, VR} | Acc])
    end.

%% Reference shapes, tried in order: the whole name in the current
%% module (a constant, or a local Enum.Member), then the same shapes
%% inside any module (shared.CONST, shared.Numberz.ONE).

-spec resolve_value_ref(binary(), #ctx{}) ->
    {ok, {const, const_value()}} | {ok, {enum_member, binary()}} | error.
resolve_value_ref(Ref, Ctx) ->
    case try_const_and_enum(Ref, Ctx#ctx.module, Ctx) of
        {ok, _} = Found ->
            Found;
        error ->
            Others = [M || M <- maps:keys(Ctx#ctx.all_defs), M =/= Ctx#ctx.module],
            find_first(
                fun(M) ->
                    case strip_prefix(Ref, M) of
                        error -> error;
                        Name -> try_const_and_enum(Name, M, Ctx)
                    end
                end,
                Others
            )
    end.

-spec try_const_and_enum(binary(), binary(), #ctx{}) ->
    {ok, {const, const_value()}} | {ok, {enum_member, binary()}} | error.
try_const_and_enum(Name, Module, Ctx) ->
    Consts = maps:get(Module, Ctx#ctx.all_const_values, #{}),
    case Consts of
        #{Name := Value} ->
            {ok, {const, Value}};
        _ ->
            try_enum_member(Name, maps:get(Module, Ctx#ctx.all_enum_members, #{}))
    end.

%% `EnumName.Member` in an included module resolves to the member atom
%% when the enum declares it.
-spec try_enum_member(binary(), #{binary() := [binary()]}) ->
    {ok, {enum_member, binary()}} | error.
try_enum_member(Name, Enums) ->
    case split_member(Name) of
        {EnumName, Member} ->
            case Enums of
                #{EnumName := Members} -> member_if_declared(Member, Members);
                _ -> error
            end;
        error ->
            error
    end.

-spec member_if_declared(binary(), [binary()]) -> {ok, {enum_member, binary()}} | error.
member_if_declared(Member, Members) ->
    case lists:member(Member, Members) of
        true -> {ok, {enum_member, Member}};
        false -> error
    end.

%%--------------------------------------------------------------------
%% Small helpers
%%--------------------------------------------------------------------

-spec err(loc(), string(), [term()], #ctx{}) -> #ctx{}.
err(Loc, Format, Args, Ctx) ->
    Message = iolist_to_binary(io_lib:format(Format, Args)),
    Ctx#ctx{errors = [{Ctx#ctx.file, Loc, Message} | Ctx#ctx.errors]}.

%% The location of an AST node as an err/4 position.

-spec loc(ast_node()) -> loc().
loc(#thrift_generator_node{line = Line, col = 0}) -> Line;
loc(#thrift_generator_node{line = Line, col = Col}) -> {Line, Col}.

-spec is_local_name(binary()) -> boolean().
is_local_name(Name) ->
    binary:match(Name, <<".">>) =:= nomatch.

%% Strips `Module.` from `Name`; error when Name does not start with it
%% or nothing follows the prefix.

-spec strip_prefix(binary(), binary()) -> binary() | error.
strip_prefix(Name, Module) ->
    Prefix = <<Module/binary, ".">>,
    Size = byte_size(Prefix),
    case Name of
        <<Prefix:Size/binary, Rest/binary>> when Rest =/= <<>> ->
            Rest;
        _ ->
            error
    end.

%% Applies `Try` to candidates until one returns something other than
%% error; returns {ok, Value} or error.

-spec find_first(fun((binary()) -> {ok, V} | error), [binary()]) -> {ok, V} | error.
find_first(_Try, []) ->
    error;
find_first(Try, [Candidate | Rest]) ->
    case Try(Candidate) of
        error ->
            find_first(Try, Rest);
        {ok, _} = Found ->
            Found
    end.

-spec split_member(binary()) -> {binary(), binary()} | error.
split_member(Name) ->
    case binary:split(Name, <<".">>) of
        [EnumName, Member] ->
            {EnumName, Member};
        _ ->
            error
    end.

-spec in_range(i8 | i16 | i32 | i64, integer()) -> boolean().
in_range(i8, V) -> V >= -128 andalso V =< 127;
in_range(i16, V) -> V >= -32768 andalso V =< 32767;
in_range(i32, V) -> V >= -16#80000000 andalso V =< 16#7FFFFFFF;
in_range(i64, V) -> V >= -(1 bsl 63) andalso V =< (1 bsl 63) - 1.

-spec format(string(), [term()]) -> binary().
format(Format, Args) ->
    iolist_to_binary(io_lib:format(Format, Args)).
