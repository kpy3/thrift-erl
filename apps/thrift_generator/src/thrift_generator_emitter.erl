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

-module(thrift_generator_emitter).

-moduledoc """
Turns the semantic model into Erlang modules.

Per IDL file a `<mod>_types.erl` is emitted: records for structs (map
representation via the `erl.struct_type = "map"` annotation), the
introspection surface (`struct_info/1`, `enum_info/1`,
`function_info/2`, `service_info/0`) and the record-field index
(`record_fields/1`) that `thrift_erl_record` uses to bridge records
and the wire.

Per service: `<svc>_handler.erl` (the `-callback` behaviour),
`<svc>_server.erl` (a `thrift_erl_service` implementation plus the
server entry points) and `<svc>_client.erl` (typed call wrappers that
convert records at the boundary).

Forms are built with `erl_syntax` and rendered with `erl_prettypr`.
Descriptors are plain data: most function bodies are `abstract/1` of
the descriptor terms, which keeps the emitter declarative.
`compile_sources/1` compiles the same forms in memory for tests.
""".

-export([sources/1, compile_sources/1]).

-export_type([compiled/0, source/0]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

-define(DEFAULT_TIMEOUT, 5000).

-type compiled() ::
    {ok, module(), binary()}
    | {error, {module(), [tuple()]}}.

%% One generated artifact: the module source plus, for types modules,
%% the `<mod>_types.hrl` include (records, types, constant macros).
-type source() :: #{
    module := module(),
    source := binary(),
    hrl => binary()
}.

-type module_key() :: binary().

%% Wire-level descriptor terms — the same shapes thrift_erl_binary and
%% thrift_erl_record consume.

-type desc() :: term().

%% Cross-module resolution context.
-record(ctx, {
    %% binary module name -> #tg_module{}
    modules :: #{module_key() => #tg_module{}},
    %% binary module name -> emitted types module atom
    type_modules :: #{module_key() => module()},
    current :: undefined | module_key()
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Renders every generated module as a source map with its hrl when present.".
-spec sources(#tg_model{}) -> [source()].
sources(Model) ->
    [
        #{
            module => Name,
            source => format(Forms),
            hrl =>
                case HrlForms of
                    undefined -> undefined;
                    _ -> format(HrlForms)
                end
        }
     || {Name, Forms, HrlForms} <- module_triplets(Model)
    ].

-doc "Compiles every generated module in memory (`compile:forms`).".
-spec compile_sources(#tg_model{}) -> [compiled()].
compile_sources(Model) ->
    [
        compile_one(Name, Forms)
     || {Name, Forms} <- module_forms(Model)
    ].

%%--------------------------------------------------------------------
%% Module assembly
%%--------------------------------------------------------------------

-spec module_forms(#tg_model{}) -> [{module(), erl_syntax:forms()}].
module_forms(Model) ->
    [{Name, Forms} || {Name, Forms, _Hrl} <- module_triplets(Model)].

-spec module_triplets(#tg_model{}) ->
    [{module(), erl_syntax:forms(), erl_syntax:forms() | undefined}].
module_triplets(Model) ->
    Ctx0 = #ctx{
        modules = #{M#tg_module.name => M || M <- Model#tg_model.modules},
        type_modules =
            #{
                M#tg_module.name => types_module_atom(M#tg_module.name)
             || M <- Model#tg_model.modules
            },
        current = undefined
    },
    lists:append([
        module_sources(Mod, Ctx0#ctx{current = Mod#tg_module.name})
     || Mod <- Model#tg_model.modules
    ]).

-spec module_sources(#tg_module{}, #ctx{}) ->
    [{module(), erl_syntax:forms(), erl_syntax:forms() | undefined}].
module_sources(Mod, Ctx) ->
    TypesMod = types_module_atom(Mod#tg_module.name),
    ServiceForms = [
        service_sources(Svc, Mod, Ctx)
     || Svc <- Mod#tg_module.services
    ],
    [
        {TypesMod, types_forms(Mod, Ctx), types_hrl_forms(Mod, Ctx)}
        | lists:append(ServiceForms)
    ].

%%--------------------------------------------------------------------
%% <mod>_types.erl
%%--------------------------------------------------------------------

-spec types_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
types_forms(Mod, Ctx) ->
    TypesMod = types_module_atom(Mod#tg_module.name),
    Records = [
        record_form(S, Mod#tg_module.prefix)
     || S <- Mod#tg_module.structs,
        record_mode(S)
    ],
    Exports =
        [
            export_form([
                {struct_info, 1},
                {enum_info, 1},
                {function_info, 2},
                {service_info, 0},
                {record_fields, 1},
                {tag_index, 0},
                {convert, 2}
            ]),
            export_form(struct_codec_entries(Mod)),
            export_form(enum_helper_entries(Mod)),
            export_form(const_entries(Mod))
        ],
    header(TypesMod, types_doc(Mod)) ++
        Records ++
        [
            %% The types module declares every record for consumers;
            %% introspection forms reference them by name, not usage.
            nowarn_unused_record_form()
        ] ++
        Exports ++
        struct_info_forms(Mod, Ctx) ++
        enum_info_forms(Mod) ++
        function_info_forms(Mod, Ctx) ++
        service_info_forms(Mod, Ctx) ++
        record_fields_forms(Mod) ++
        struct_codec_forms(Mod, Ctx) ++
        tag_index_forms(Mod, Ctx) ++
        enum_helper_forms(Mod) ++
        const_forms(Mod).

%%--------------------------------------------------------------------
%% <mod>_types.hrl
%%--------------------------------------------------------------------

%% The include consumers bring in: typed records, record and enum
%% aliases, and macros for scalar constants. Records are also declared
%% inline in the .erl (compile_sources runs without includes), so the
%% two files must never both be included into one compilation.

-spec types_hrl_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
types_hrl_forms(Mod, Ctx) ->
    Guard = hrl_guard(Mod),
    Header =
        [
            " Copyright 2026 Sergei Yelin",
            "",
            " Licensed under the Apache License, Version 2.0 (the \"License\");",
            " you may not use this file except in compliance with the License.",
            " You may obtain a copy of the License at",
            "",
            "     http://www.apache.org/licenses/LICENSE-2.0",
            "",
            " Generated from " ++ unicode:characters_to_list(Mod#tg_module.path) ++ ". Do not edit."
        ] ++ hrl_include_note(Mod, Ctx),
    [
        erl_syntax:comment(Header),
        %% Preprocessor directives have no erl_parse form (epp consumes
        %% them), so they render as plain attribute trees; -endif must
        %% not carry the parens — epp rejects `-endif()` — hence the
        %% raw-text marker handled by format/1. Macro names are
        %% variable nodes: uppercase atoms would print quoted.
        erl_syntax:attribute(erl_syntax:atom(ifndef), [
            erl_syntax:variable(atom_to_list(Guard))
        ]),
        erl_syntax:attribute(erl_syntax:atom(define), [
            erl_syntax:variable(atom_to_list(Guard)), erl_syntax:atom(true)
        ])
    ] ++
        hrl_record_forms(Mod, Ctx) ++
        hrl_enum_forms(Mod) ++
        hrl_const_forms(Mod) ++
        [
            {raw_text, <<"-endif.\n">>}
        ].

-spec hrl_guard(#tg_module{}) -> atom().
hrl_guard(Mod) ->
    Sanitized = binary:replace(Mod#tg_module.name, <<".">>, <<"_">>, [global]),
    binary_to_atom(<<(string:uppercase(Sanitized))/binary, "_HRL">>, utf8).

%% Typed record fields may reference records declared in another
%% module's hrl (an included thrift document); the compiler resolves
%% #tag{} at the include site, so those hrl files must be included
%% first. Enum and typedef references compile to scalar/term types and
%% need no include.

-spec hrl_include_note(#tg_module{}, #ctx{}) -> [string()].
hrl_include_note(Mod, Ctx) ->
    Deps =
        lists:usort([
            Dep
         || S <- Mod#tg_module.structs,
            F <- S#tg_struct.fields,
            Dep <- [record_dep_module(F#tg_field.type, Ctx)],
            Dep =/= undefined,
            Dep =/= Ctx#ctx.current
        ]),
    case Deps of
        [] ->
            [];
        _ ->
            Files = [atom_to_list(types_module_atom(D)) ++ ".hrl" || D <- Deps],
            [
                "",
                " Include " ++ string:join(Files, ", ") ++
                    " before this file:"
                    " typed record fields below reference records declared there."
            ]
    end.

-spec record_dep_module(thrift_type(), #ctx{}) -> module_key() | undefined.
record_dep_module({list, T, _}, Ctx) ->
    record_dep_module(T, Ctx);
record_dep_module({set, T, _}, Ctx) ->
    record_dep_module(T, Ctx);
record_dep_module({map, K, V, _}, Ctx) ->
    case record_dep_module(K, Ctx) of
        undefined -> record_dep_module(V, Ctx);
        Dep -> Dep
    end;
record_dep_module({ref, Name, _}, Ctx) ->
    {ModKey, Local} =
        case binary:split(Name, <<".">>) of
            [M, L] -> {M, L};
            [L] -> {Ctx#ctx.current, L}
        end,
    case find_struct(maps:get(ModKey, Ctx#ctx.modules, undefined), Local) of
        {ok, S} ->
            case record_mode(S) of
                true -> ModKey;
                false -> undefined
            end;
        error ->
            undefined
    end;
record_dep_module(_, _) ->
    undefined.

-spec hrl_record_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
hrl_record_forms(Mod, Ctx) ->
    lists:append([
        hrl_struct_forms(S, Ctx)
     || S <- Mod#tg_module.structs,
        record_mode(S)
    ]).

-spec hrl_struct_forms(#tg_struct{}, #ctx{}) -> erl_syntax:forms().
hrl_struct_forms(S, Ctx) ->
    Anno = erl_anno:new(0),
    Tag = record_tag(current_prefix(Ctx), S#tg_struct.name),
    TypedFields = [
        {typed_record_field,
            case F#tg_field.default of
                undefined ->
                    {record_field, Anno, {atom, Anno, field_atom(F#tg_field.name)}};
                Default ->
                    {record_field, Anno, {atom, Anno, field_atom(F#tg_field.name)},
                        erl_syntax:revert(const_literal(Default))}
            end,
            erlang_type(F#tg_field.type, Ctx)}
     || F <- S#tg_struct.fields
    ],
    RecordForm =
        {attribute, Anno, record, {Tag, TypedFields}},
    TypeAlias =
        {attribute, Anno, type, {Tag, {type, Anno, record, [{atom, Anno, Tag}]}, []}},
    [RecordForm, TypeAlias].

-spec hrl_enum_forms(#tg_module{}) -> erl_syntax:forms().
hrl_enum_forms(Mod) ->
    [
        {attribute, erl_anno:new(0), type,
            {record_tag(Mod#tg_module.prefix, E#tg_enum.name), enum_type_node(E#tg_enum.values), []}}
     || E <- Mod#tg_module.enums
    ].

-spec enum_type_node([{integer(), binary()}]) -> erl_syntax:syntaxTree().
enum_type_node(Values) ->
    Anno = erl_anno:new(0),
    Atoms = [{atom, Anno, enum_atom(Name)} || {_Value, Name} <- Values],
    case Atoms of
        [One] -> One;
        Many -> {type, Anno, union, Many}
    end.

%% Macros only for scalar and enum-member constants; containers have no
%% literal macro form worth generating — they get the function.

-spec hrl_const_forms(#tg_module{}) -> erl_syntax:forms().
hrl_const_forms(Mod) ->
    lists:append([
        [
            erl_syntax:attribute(erl_syntax:atom(define), [
                erl_syntax:variable(
                    unicode:characters_to_list(const_macro_name(Mod#tg_module.prefix, C#tg_const.name))
                ),
                const_literal(C#tg_const.value)
            ])
        ]
     || C <- Mod#tg_module.consts,
        scalar_const(C)
    ]).

%% The constant macro mirrors the (prefixed) function name, macro-style:
%% the namespace prefix is uppercased, the declared name stays as is —
%% without a namespace the macro keeps the exact declared name.

-spec const_macro_name(binary(), binary()) -> binary().
const_macro_name(<<>>, Name) ->
    Name;
const_macro_name(Prefix, Name) ->
    <<(string:uppercase(Prefix))/binary, "_", Name/binary>>.

-spec scalar_const(#tg_const{}) -> boolean().
scalar_const(#tg_const{value = {ref, _}}) ->
    true;
scalar_const(#tg_const{value = {list, _}}) ->
    false;
scalar_const(#tg_const{value = {map, _}}) ->
    false;
scalar_const(_Const) ->
    true.

%%--------------------------------------------------------------------
%% Per-struct codec functions
%%--------------------------------------------------------------------

-spec struct_codec_entries(#tg_module{}) -> [{atom(), arity()}].
struct_codec_entries(Mod) ->
    lists:append([
        [
            {binary_to_atom(<<"encode_", Prefix/binary>>, utf8), 1},
            {binary_to_atom(<<"encode_", Prefix/binary>>, utf8), 2},
            {binary_to_atom(<<"decode_", Prefix/binary>>, utf8), 1},
            {binary_to_atom(<<"decode_", Prefix/binary>>, utf8), 2},
            {binary_to_atom(<<"decode_", Prefix/binary>>, utf8), 3}
        ] ++
            case record_mode(S) of
                true -> [{binary_to_atom(<<Prefix/binary, "_from_map">>, utf8), 1}];
                false -> []
            end
     || S <- Mod#tg_module.structs,
        Prefix <- [typed_prefix(Mod#tg_module.prefix, string:lowercase(S#tg_struct.name))]
    ]).

-spec struct_codec_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
struct_codec_forms(Mod, Ctx) ->
    lists:append([
        struct_codec_one(S, Ctx)
     || S <- Mod#tg_module.structs
    ]).

-spec struct_codec_one(#tg_struct{}, #ctx{}) -> erl_syntax:forms().
struct_codec_one(S, Ctx) ->
    Prefix = typed_prefix(current_prefix(Ctx), string:lowercase(S#tg_struct.name)),
    Encode = binary_to_atom(<<"encode_", Prefix/binary>>, utf8),
    Decode = binary_to_atom(<<"decode_", Prefix/binary>>, utf8),
    DefaultRepr =
        case record_mode(S) of
            true -> record;
            false -> map
        end,
    Desc = struct_ref(S, Ctx),
    Anno = erl_anno:new(0),
    ResultType = fun(Ok) -> ok_error_type(Anno, Ok, error_term_type(Anno)) end,
    EncodeSpec = fun(Arity) ->
        {attribute, Anno, spec,
            {{Encode, Arity}, [
                fun_type(
                    [value_type(S, Ctx)] ++
                        lists:duplicate(Arity - 1, raw_type(term)),
                    ResultType({type, Anno, binary, []})
                )
            ]}}
    end,
    DecodeSpec = fun(Arity) ->
        {attribute, Anno, spec,
            {{Decode, Arity}, [
                fun_type(
                    [raw_type(binary)] ++ lists:duplicate(Arity - 1, raw_type(term)),
                    ResultType(term_type())
                )
            ]}}
    end,
    fn_form(Encode, [
        fn_clause(
            [erl_syntax:variable("Value")],
            application(thrift_erl, encode, [abstract(Desc), erl_syntax:variable("Value")])
        )
    ]) ++
        fn_form(Encode, [
            fn_clause(
                [erl_syntax:variable("Value"), erl_syntax:variable("Protocol")],
                application(thrift_erl, encode, [
                    abstract(Desc), erl_syntax:variable("Value"), erl_syntax:variable("Protocol")
                ])
            )
        ]) ++
        [EncodeSpec(1), EncodeSpec(2)] ++
        fn_form(Decode, [
            fn_clause(
                [erl_syntax:variable("Binary")],
                application(thrift_erl, decode, [
                    abstract(Desc), erl_syntax:variable("Binary"), abstract(DefaultRepr)
                ])
            )
        ]) ++
        fn_form(Decode, [
            fn_clause(
                [erl_syntax:variable("Binary"), erl_syntax:variable("Repr")],
                application(thrift_erl, decode, [
                    abstract(Desc), erl_syntax:variable("Binary"), erl_syntax:variable("Repr")
                ])
            )
        ]) ++
        fn_form(Decode, [
            fn_clause(
                [
                    erl_syntax:variable("Binary"),
                    erl_syntax:variable("Repr"),
                    erl_syntax:variable("Protocol")
                ],
                application(thrift_erl, decode, [
                    abstract(Desc),
                    erl_syntax:variable("Binary"),
                    erl_syntax:variable("Repr"),
                    erl_syntax:variable("Protocol")
                ])
            )
        ]) ++
        [DecodeSpec(1), DecodeSpec(2), DecodeSpec(3)] ++
        case record_mode(S) of
            true ->
                FromMap = binary_to_atom(<<Prefix/binary, "_from_map">>, utf8),
                [
                    {attribute, Anno, spec,
                        {{FromMap, 1}, [
                            fun_type([raw_type(map)], term_type())
                        ]}}
                ] ++
                    fn_form(FromMap, [
                        fn_clause(
                            [erl_syntax:variable("Map")],
                            erl_syntax:tuple([
                                erl_syntax:atom(ok),
                                application(thrift_erl_record, from_wire, [
                                    abstract(Desc),
                                    application(thrift_erl_record, to_wire, [
                                        abstract(Desc), erl_syntax:variable("Map")
                                    ]),
                                    abstract(record)
                                ])
                            ])
                        )
                    ]);
            false ->
                []
        end.

-spec term_type() -> erl_syntax:syntaxTree().
term_type() ->
    {type, erl_anno:new(0), term, []}.

%% Shared spec vocabulary: `Ok | ErrorArm`, the `{error, term()}` arm,
%% and the record type of a generated record tag.

-spec ok_error_type(erl_anno:anno(), erl_syntax:syntaxTree(), erl_syntax:syntaxTree()) ->
    erl_syntax:syntaxTree().
ok_error_type(Anno, OkInner, ErrorArm) ->
    {type, Anno, union, [
        {type, Anno, tuple, [{atom, Anno, ok}, OkInner]},
        ErrorArm
    ]}.

-spec error_term_type(erl_anno:anno()) -> erl_syntax:syntaxTree().
error_term_type(Anno) ->
    {type, Anno, tuple, [{atom, Anno, error}, {type, Anno, term, []}]}.

-spec record_type(atom()) -> erl_syntax:syntaxTree().
record_type(Tag) ->
    {type, erl_anno:new(0), record, [{atom, erl_anno:new(0), Tag}]}.

-spec list_type(thrift_type(), #ctx{}) -> erl_syntax:syntaxTree().
list_type(T, Ctx) ->
    {type, erl_anno:new(0), list, [erlang_type(T, Ctx)]}.

-spec nowarn_unused_record_form() -> erl_syntax:syntaxTree().
nowarn_unused_record_form() ->
    erl_syntax:attribute(erl_syntax:atom(compile), [
        erl_syntax:abstract([nowarn_unused_record])
    ]).

-spec struct_ref(#tg_struct{}, #ctx{}) -> desc().
struct_ref(S, Ctx) ->
    {struct, {ref, types_module_atom(Ctx#ctx.current), S#tg_struct.name}}.

%% The identity tag a struct value carries: the (prefixed) record tag in
%% record mode, the lowercased wire name in map mode — no record exists
%% there, so the struct representation tags it by name. The same rule
%% thrift_erl_record applies when it builds struct maps, so convert/2
%% finds every struct by the tag its own values carry.

-spec struct_index_tag(#tg_struct{}, binary()) -> atom().
struct_index_tag(S, Prefix) ->
    case record_mode(S) of
        true -> record_tag(Prefix, S#tg_struct.name);
        false -> record_tag(<<>>, S#tg_struct.name)
    end.

%% The input side of encode_: a record (record mode) or a map — both
%% normalize inside thrift_erl_record:to_wire.

-spec value_type(#tg_struct{}, #ctx{}) -> erl_syntax:syntaxTree().
value_type(S, Ctx) ->
    case record_mode(S) of
        true ->
            Tag = record_tag(current_prefix(Ctx), S#tg_struct.name),
            {type, erl_anno:new(0), union, [record_type(Tag), raw_type(map)]};
        false ->
            raw_type(map)
    end.

%%--------------------------------------------------------------------
%% Tag index and convert
%%--------------------------------------------------------------------

-spec tag_index_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
tag_index_forms(Mod, Ctx) ->
    Anno = erl_anno:new(0),
    Pairs = [
        {struct_index_tag(S, current_prefix(Ctx)), struct_ref(S, Ctx)}
     || S <- Mod#tg_module.structs
    ],
    [
        {attribute, Anno, spec,
            {{tag_index, 0}, [
                fun_type(
                    [],
                    {remote_type, Anno, [
                        {atom, Anno, thrift_erl}, {atom, Anno, tag_index}, []
                    ]}
                )
            ]}},
        {attribute, Anno, spec,
            {{convert, 2}, [
                fun_type(
                    [
                        term_type(),
                        {remote_type, Anno, [
                            {atom, Anno, thrift_erl}, {atom, Anno, repr}, []
                        ]}
                    ],
                    {type, Anno, union, [
                        {type, Anno, tuple, [{atom, Anno, ok}, term_type()]},
                        {type, Anno, tuple, [{atom, Anno, error}, term_type()]}
                    ]}
                )
            ]}}
    ] ++
        fn_form(tag_index, [fn_clause([], abstract(maps:from_list(Pairs)))]) ++
        fn_form(convert, [
            fn_clause(
                [erl_syntax:variable("Value"), erl_syntax:variable("Repr")],
                application(thrift_erl, convert, [
                    application(
                        types_module_atom(Ctx#ctx.current), tag_index, []
                    ),
                    erl_syntax:variable("Value"),
                    erl_syntax:variable("Repr")
                ])
            )
        ]).

%%--------------------------------------------------------------------
%% Enum helpers
%%--------------------------------------------------------------------

-spec enum_helper_entries(#tg_module{}) -> [{atom(), arity()}].
enum_helper_entries(Mod) ->
    lists:append([
        [
            {binary_to_atom(<<Prefix/binary, "_to_int">>, utf8), 1},
            {binary_to_atom(<<Prefix/binary, "_from_int">>, utf8), 1}
        ]
     || E <- Mod#tg_module.enums,
        Prefix <- [typed_prefix(Mod#tg_module.prefix, string:lowercase(E#tg_enum.name))]
    ]).

-spec enum_helper_forms(#tg_module{}) -> erl_syntax:forms().
enum_helper_forms(Mod) ->
    lists:append([
        enum_helper_one(E, typed_prefix(Mod#tg_module.prefix, string:lowercase(E#tg_enum.name)))
     || E <- Mod#tg_module.enums
    ]).

-spec enum_helper_one(#tg_enum{}, binary()) -> erl_syntax:forms().
enum_helper_one(E, Prefix) ->
    ToInt = binary_to_atom(<<Prefix/binary, "_to_int">>, utf8),
    FromInt = binary_to_atom(<<Prefix/binary, "_from_int">>, utf8),
    %% The literal descriptor — the same list enum_info/1 returns — so
    %% the helpers do not even call themselves.
    DescExpr = abstract(enum_desc(E)),
    Anno = erl_anno:new(0),
    V = erl_syntax:variable("Value"),
    Int = erl_syntax:variable("Int"),
    Atom = erl_syntax:variable("Atom"),
    OkTuple = fun(Value) ->
        erl_syntax:tuple([erl_syntax:atom(ok), Value])
    end,
    Keyfind = fun(Key, Pos) ->
        erl_syntax:application(erl_syntax:atom(lists), erl_syntax:atom(keyfind), [
            Key, abstract(Pos), DescExpr
        ])
    end,
    %% keyfind answers the whole {Key, Value} pair; each helper keeps
    %% only its own half and underscores the other so the unused pattern
    %% variable stays warning-free.
    MatchClause = fun(Pattern, Result) ->
        erl_syntax:clause([Pattern], none, [OkTuple(Result)])
    end,
    Underscore = fun(Name) -> erl_syntax:variable("_" ++ Name) end,
    ToIntPair = erl_syntax:tuple([Int, Underscore("Atom")]),
    FromIntPair = erl_syntax:tuple([Underscore("Int"), Atom]),
    MissClause = erl_syntax:clause([erl_syntax:atom(false)], none, [erl_syntax:atom(error)]),
    Guard = fun(Fun) ->
        erl_syntax:conjunction([
            erl_syntax:application(erl_syntax:atom(Fun), [V])
        ])
    end,
    Union = fun(OkType) -> ok_error_type(Anno, OkType, {atom, Anno, error}) end,
    [
        {attribute, Anno, spec,
            {{ToInt, 1}, [
                fun_type([{type, Anno, union, [raw_type(atom), raw_type(integer)]}], Union(raw_type(integer)))
            ]}},
        {attribute, Anno, spec,
            {{FromInt, 1}, [
                fun_type([raw_type(integer)], Union(raw_type(atom)))
            ]}}
    ] ++
        fn_form(ToInt, [
            erl_syntax:clause([V], Guard(is_atom), [
                erl_syntax:case_expr(Keyfind(V, 2), [MatchClause(ToIntPair, Int), MissClause])
            ]),
            erl_syntax:clause([V], Guard(is_integer), [OkTuple(V)])
        ]) ++
        fn_form(FromInt, [
            erl_syntax:clause([V], none, [
                erl_syntax:case_expr(Keyfind(V, 1), [MatchClause(FromIntPair, Atom), MissClause])
            ])
        ]).

%%--------------------------------------------------------------------
%% Constants
%%--------------------------------------------------------------------

-spec const_entries(#tg_module{}) -> [{atom(), arity()}].
const_entries(Mod) ->
    [
        {binary_to_atom(typed_prefix(Mod#tg_module.prefix, C#tg_const.name), utf8), 0}
     || C <- Mod#tg_module.consts
    ].

-spec const_forms(#tg_module{}) -> erl_syntax:forms().
const_forms(Mod) ->
    lists:append([
        [
            {attribute, erl_anno:new(0), spec,
                {{binary_to_atom(typed_prefix(Mod#tg_module.prefix, C#tg_const.name), utf8), 0}, [
                    fun_type([], const_spec_type(C#tg_const.type))
                ]}}
        ] ++
            fn_form(binary_to_atom(typed_prefix(Mod#tg_module.prefix, C#tg_const.name), utf8), [
                fn_clause([], const_literal(C#tg_const.value))
            ])
     || C <- Mod#tg_module.consts
    ]).

%% Constant spec types without a resolution context: refs (enum
%% members) surface as term, containers mirror erlang_type/2.

-spec const_spec_type(thrift_type()) -> erl_syntax:syntaxTree().
const_spec_type({base, B, _}) ->
    base_erlang_type(B);
const_spec_type({list, T, _}) ->
    {type, erl_anno:new(0), list, [const_spec_type(T)]};
const_spec_type({set, T, _}) ->
    {type, erl_anno:new(0), list, [const_spec_type(T)]};
const_spec_type({map, K, V, _}) ->
    Anno = erl_anno:new(0),
    {type, Anno, map, [
        {type, Anno, map_field_assoc, [const_spec_type(K), const_spec_type(V)]}
    ]};
const_spec_type({ref, _, _}) ->
    raw_type(term).

%% Constants carry resolved values: enum references as member name
%% binaries, containers as tagged lists/maps. Enum members surface as
%% atoms; maps as maps with literal keys.

-spec const_literal(const_value()) -> erl_syntax:syntaxTree().
const_literal({ref, Name}) ->
    abstract(binary_to_atom(Name, utf8));
const_literal({list, Values}) ->
    erl_syntax:list([const_literal(V) || V <- Values]);
const_literal({map, KVs}) ->
    erl_syntax:map_expr([
        erl_syntax:map_field_assoc(const_literal(K), const_literal(V))
     || {K, V} <- KVs
    ]);
const_literal(Value) ->
    abstract(Value).

-spec types_doc(#tg_module{}) -> binary().
types_doc(Mod) ->
    unicode:characters_to_binary(
        io_lib:format(
            "Generated from ~ts. Do not edit."
            " Introspection: struct_info/1, enum_info/1, function_info/2,"
            " service_info/0; record mapping: record_fields/1.",
            [Mod#tg_module.path]
        )
    ).

-spec record_form(#tg_struct{}, binary()) -> erl_syntax:syntaxTree().
record_form(S, Prefix) ->
    Fields = [
        case F#tg_field.default of
            undefined ->
                erl_syntax:record_field(erl_syntax:atom(field_atom(F#tg_field.name)));
            Default ->
                erl_syntax:record_field(
                    erl_syntax:atom(field_atom(F#tg_field.name)), abstract(Default)
                )
        end
     || F <- S#tg_struct.fields
    ],
    erl_syntax:attribute(
        erl_syntax:atom(record),
        [erl_syntax:atom(record_tag(Prefix, S#tg_struct.name)), erl_syntax:tuple(Fields)]
    ).

-spec record_mode(#tg_struct{}) -> boolean().
record_mode(S) ->
    not is_map_key(struct_type, S#tg_struct.erl) orelse
        maps:get(struct_type, S#tg_struct.erl) =/= <<"map">>.

-spec struct_info_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
struct_info_forms(Mod, Ctx) ->
    Clauses = [
        fn_clause([abstract(S#tg_struct.name)], abstract(struct_desc(S, Ctx)))
     || S <- Mod#tg_module.structs
    ],
    total_form(struct_info, Clauses).

-spec struct_desc(#tg_struct{}, #ctx{}) -> desc().
struct_desc(S, Ctx) ->
    {S#tg_struct.kind, [field_desc(F, Ctx) || F <- S#tg_struct.fields]}.

-spec field_desc(#tg_field{}, #ctx{}) -> desc().
field_desc(F, Ctx) ->
    {F#tg_field.id, F#tg_field.required, type_desc(F#tg_field.type, Ctx), F#tg_field.name, F#tg_field.default}.

-spec enum_info_forms(#tg_module{}) -> erl_syntax:forms().
enum_info_forms(Mod) ->
    Clauses = [
        fn_clause(
            [abstract(E#tg_enum.name)],
            abstract([{Value, enum_atom(Name)} || {Value, Name} <- E#tg_enum.values])
        )
     || E <- Mod#tg_module.enums
    ],
    total_form(enum_info, Clauses).

%% Every introspection lookup ends in the same catch-all clause: an
%% unknown key answers `error`, mirroring the official generator.
-spec total_form(atom(), [erl_syntax:syntaxTree()]) -> erl_syntax:forms().
total_form(Name, Clauses) ->
    fn_form(Name, Clauses ++ [fn_clause([wildcard()], abstract(error))]).

-spec function_info_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
function_info_forms(Mod, Ctx) ->
    Clauses =
        lists:append([
            [
                fn_clause(
                    [abstract(F#tg_function.name), abstract(params)],
                    abstract(params_desc(F, Ctx))
                ),
                fn_clause(
                    [abstract(F#tg_function.name), abstract(oneway)],
                    abstract(F#tg_function.oneway)
                ),
                fn_clause(
                    [abstract(F#tg_function.name), abstract(reply)],
                    abstract(reply_desc(F, Ctx))
                ),
                fn_clause(
                    [abstract(F#tg_function.name), abstract(exceptions)],
                    abstract(exceptions_desc(F, Ctx))
                )
            ]
         || F <- service_functions(Mod)
        ]),
    fn_form(
        function_info,
        Clauses ++ [fn_clause([wildcard(), wildcard()], abstract(error))]
    ).

-spec service_functions(#tg_module{}) -> [#tg_function{}].
service_functions(Mod) ->
    lists:append([S#tg_service.functions || S <- Mod#tg_module.services]).

-spec params_desc(#tg_function{}, #ctx{}) -> desc().
params_desc(F, Ctx) ->
    {struct, {struct, [field_desc(P, Ctx) || P <- F#tg_function.params]}}.

-spec reply_desc(#tg_function{}, #ctx{}) -> desc() | undefined.
reply_desc(F, Ctx) ->
    case F#tg_function.return_type of
        void ->
            undefined;
        Type ->
            type_desc(Type, Ctx)
    end.

-spec exceptions_desc(#tg_function{}, #ctx{}) -> [desc()].
exceptions_desc(F, Ctx) ->
    [field_desc(T, Ctx) || T <- F#tg_function.throws].

-spec service_info_forms(#tg_module{}, #ctx{}) -> erl_syntax:forms().
service_info_forms(Mod, Ctx) ->
    Entries = [
        {S#tg_service.name, service_entry(S#tg_service.functions, Ctx, #{})}
     || S <- Mod#tg_module.services
    ],
    fn_form(service_info, [fn_clause([], abstract(maps:from_list(Entries)))]).

-spec service_entry([#tg_function{}], #ctx{}, map()) -> map().
service_entry([], _Ctx, Acc) ->
    Acc;
service_entry([F | Rest], Ctx, Acc0) ->
    Acc1 = Acc0#{
        F#tg_function.name => #{
            name => F#tg_function.name,
            oneway => F#tg_function.oneway,
            params => params_desc(F, Ctx)
        }
    },
    Acc2 =
        case reply_desc(F, Ctx) of
            undefined ->
                Acc1;
            Reply ->
                maps:update_with(
                    F#tg_function.name, fun(Info) -> Info#{reply => Reply} end, Acc1
                )
        end,
    case exceptions_desc(F, Ctx) of
        [] ->
            service_entry(Rest, Ctx, Acc2);
        Exceptions ->
            Acc3 = maps:update_with(
                F#tg_function.name, fun(Info) -> Info#{exceptions => Exceptions} end, Acc2
            ),
            service_entry(Rest, Ctx, Acc3)
    end.

-spec record_fields_forms(#tg_module{}) -> erl_syntax:forms().
record_fields_forms(Mod) ->
    Clauses = [
        fn_clause([abstract(S#tg_struct.name)], abstract(fields_decl(S, Mod#tg_module.prefix)))
     || S <- Mod#tg_module.structs
    ],
    fn_form(record_fields, Clauses ++ [fn_clause([wildcard()], abstract(none))]).

%% The record_fields contract: record mode answers {Tag, FieldAtoms},
%% map mode answers {map, KeyType} (default atom keys); structs with no
%% clause fall through to `none` — the wire passthrough.

-spec fields_decl(#tg_struct{}, binary()) -> {atom(), [atom()]} | {map, atom | binary}.
fields_decl(S, Prefix) ->
    case record_mode(S) of
        true ->
            {record_tag(Prefix, S#tg_struct.name), [
                field_atom(F#tg_field.name)
             || F <- S#tg_struct.fields
            ]};
        false ->
            {map, map_key_type(S)}
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
%% Type descriptors
%%--------------------------------------------------------------------

-spec type_desc(thrift_type(), #ctx{}) -> desc().
type_desc({base, B, _}, _Ctx) ->
    {base, B};
type_desc({list, T, _}, Ctx) ->
    {list, type_desc(T, Ctx)};
type_desc({set, T, Ann}, Ctx) ->
    {set, type_desc(T, Ctx), set_impl(Ann)};
type_desc({map, K, V, _}, Ctx) ->
    {map, type_desc(K, Ctx), type_desc(V, Ctx)};
type_desc({ref, Name, _}, Ctx) ->
    case binary:split(Name, <<".">>) of
        [ModKey, Local] ->
            qualified_desc(ModKey, Local, Ctx);
        [Local] ->
            local_desc(Local, Ctx)
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

-spec qualified_desc(module_key(), binary(), #ctx{}) -> desc().
qualified_desc(ModKey, Local, Ctx) ->
    Module = maps:get(ModKey, Ctx#ctx.modules, undefined),
    TypesMod = maps:get(ModKey, Ctx#ctx.type_modules, undefined),
    case find_struct(Module, Local) of
        {ok, _S} ->
            {struct, {ref, TypesMod, Local}};
        error ->
            case find_enum(Module, Local) of
                {ok, E} ->
                    {enum, enum_desc(E)};
                error ->
                    error({unresolved_type, ModKey, Local})
            end
    end.

-spec local_desc(binary(), #ctx{}) -> desc().
local_desc(Name, Ctx) ->
    Module = maps:get(Ctx#ctx.current, Ctx#ctx.modules),
    case find_struct(Module, Name) of
        {ok, _S} ->
            {struct, {ref, types_module_atom(Ctx#ctx.current), Name}};
        error ->
            case find_enum(Module, Name) of
                {ok, E} ->
                    {enum, enum_desc(E)};
                error ->
                    case find_typedef(Module, Name) of
                        {ok, Type} ->
                            type_desc(Type, Ctx);
                        error ->
                            %% Inherited service functions reference the
                            %% parent module's types; resolve across
                            %% every loaded module.
                            cross_module_desc(Name, Ctx)
                    end
            end
    end.

-spec cross_module_desc(binary(), #ctx{}) -> desc().
cross_module_desc(Name, Ctx) ->
    Hits = [
        {ModKey, Kind}
     || {ModKey, Module} <- maps:to_list(Ctx#ctx.modules),
        Kind <- [
            case find_struct(Module, Name) of
                {ok, _} ->
                    struct;
                error ->
                    case find_enum(Module, Name) of
                        {ok, _} -> enum;
                        error -> none
                    end
            end
        ],
        Kind =/= none
    ],
    case lists:usort(Hits) of
        [{ModKey, struct}] ->
            {struct, {ref, types_module_atom(ModKey), Name}};
        [{ModKey, enum}] ->
            Module = maps:get(ModKey, Ctx#ctx.modules),
            {ok, E} = find_enum(Module, Name),
            {enum, enum_desc(E)};
        _ ->
            error({unresolved_type, Name})
    end.

-spec find_struct(#tg_module{} | undefined, binary()) -> {ok, #tg_struct{}} | error.
find_struct(undefined, _) ->
    error;
find_struct(Module, Name) ->
    case [S || S <- Module#tg_module.structs, S#tg_struct.name =:= Name] of
        [S | _] ->
            {ok, S};
        [] ->
            error
    end.

-spec find_enum(#tg_module{} | undefined, binary()) -> {ok, #tg_enum{}} | error.
find_enum(undefined, _) ->
    error;
find_enum(Module, Name) ->
    case [E || E <- Module#tg_module.enums, E#tg_enum.name =:= Name] of
        [E | _] ->
            {ok, E};
        [] ->
            error
    end.

-spec find_typedef(#tg_module{}, binary()) -> {ok, thrift_type()} | error.
find_typedef(Module, Name) ->
    case [T || T <- Module#tg_module.typedefs, T#tg_typedef.name =:= Name] of
        [#tg_typedef{type = Type} | _] ->
            {ok, Type};
        [] ->
            error
    end.

-spec enum_desc(#tg_enum{}) -> [{integer(), atom()}].
enum_desc(E) ->
    [{Value, enum_atom(Name)} || {Value, Name} <- E#tg_enum.values].

-spec enum_atom(binary()) -> atom().
enum_atom(Name) ->
    binary_to_atom(Name, utf8).

-spec field_atom(binary()) -> atom().
field_atom(Name) ->
    binary_to_atom(Name, utf8).

-spec record_tag(binary(), binary()) -> atom().
record_tag(Prefix, Name) ->
    binary_to_atom(typed_prefix(Prefix, lowercase(Name)), utf8).

%% The module's namespace-derived identifier prefix: prepended (with a
%% separating underscore) to every record tag, type alias, derived
%% function name and constant macro of that module; empty without a
%% declared erl/wildcard namespace.

-spec typed_prefix(binary(), binary()) -> binary().
typed_prefix(<<>>, Name) ->
    Name;
typed_prefix(Prefix, Name) ->
    <<Prefix/binary, "_", Name/binary>>.

-spec current_prefix(#ctx{}) -> binary().
current_prefix(Ctx) ->
    (maps:get(Ctx#ctx.current, Ctx#ctx.modules))#tg_module.prefix.

-spec lowercase(binary()) -> binary().
lowercase(Bin) ->
    string:lowercase(Bin).

-spec types_module_atom(module_key()) -> module().
types_module_atom(Name) ->
    binary_to_atom(<<(sanitize(Name))/binary, "_types">>, utf8).

-spec sanitize(binary()) -> binary().
sanitize(Name) ->
    binary:replace(Name, <<".">>, <<"_">>, [global]).

%%--------------------------------------------------------------------
%% Service modules
%%--------------------------------------------------------------------

-spec service_sources(#tg_service{}, #tg_module{}, #ctx{}) ->
    [{module(), erl_syntax:forms(), undefined}].
service_sources(Svc, Mod, Ctx) ->
    TypesMod = maps:get(Mod#tg_module.name, Ctx#ctx.type_modules),
    HandlerMod = service_module(Svc#tg_service.name, handler),
    ServerMod = service_module(Svc#tg_service.name, server),
    ClientMod = service_module(Svc#tg_service.name, client),
    [
        {HandlerMod, handler_forms(Svc, Mod, HandlerMod, Ctx), undefined},
        {ServerMod, server_forms(Svc, TypesMod, ServerMod), undefined},
        {ClientMod, client_forms(Svc, TypesMod, ServerMod, ClientMod), undefined}
    ].

-spec service_module(binary(), handler | server | client) -> module().
service_module(Name, Kind) ->
    binary_to_atom(<<(sanitize(Name))/binary, (kind_suffix(Kind))/binary>>, utf8).

-spec kind_suffix(handler | server | client) -> binary().
kind_suffix(handler) ->
    <<"_handler">>;
kind_suffix(server) ->
    <<"_server">>;
kind_suffix(client) ->
    <<"_client">>.

-spec handler_forms(#tg_service{}, #tg_module{}, module(), #ctx{}) -> erl_syntax:forms().
handler_forms(Svc, Mod, HandlerMod, Ctx) ->
    Doc =
        unicode:characters_to_binary(
            io_lib:format(
                "Handler behaviour for the ~ts service. Implement every"
                " callback and pass the module as `handler` when starting"
                " the server; struct arguments arrive as records.",
                [Svc#tg_service.name]
            )
        ),
    %% Callback specs mention record types for struct-typed params, so
    %% the handler declares the records of every struct the service's
    %% signatures can reach (transitively through struct fields) — and
    %% only those, so generated handlers compile warning-free even when
    %% the IDL declares many unused structs.
    Needed = service_struct_names(Svc, Mod),
    Records = [
        record_form(S, Mod#tg_module.prefix)
     || S <- Mod#tg_module.structs,
        record_mode(S),
        lists:member(S#tg_struct.name, Needed)
    ],
    Callbacks = lists:append([callback_form(F, Ctx) || F <- Svc#tg_service.functions]),
    header(HandlerMod, Doc) ++
        [
            %% Records here appear only in -callback spec types, which
            %% the compiler does not count as usage.
            nowarn_unused_record_form()
        ] ++
        Records ++
        Callbacks.

%% Names of the module's struct-mode definitions reachable from the
%% service's parameter, reply and throws types.
-spec service_struct_names(#tg_service{}, #tg_module{}) -> [binary()].
service_struct_names(Svc, Mod) ->
    ByName = #{S#tg_struct.name => S || S <- Mod#tg_module.structs},
    Seeds =
        lists:usort([
            Name
         || F <- Svc#tg_service.functions,
            T <- function_types(F),
            Name <- ref_names(T),
            is_map_key(Name, ByName)
        ]),
    expand_structs(Seeds, ByName, #{}).

-spec function_types(#tg_function{}) -> [thrift_type()].
function_types(F) ->
    [T || P <- F#tg_function.params, T <- [P#tg_field.type]] ++
        case F#tg_function.return_type of
            void -> [];
            T -> [T]
        end ++
        [P#tg_field.type || P <- F#tg_function.throws].

-spec ref_names(thrift_type()) -> [binary()].
ref_names({ref, Name, _}) ->
    [Name];
ref_names({list, T, _}) ->
    ref_names(T);
ref_names({set, T, _}) ->
    ref_names(T);
ref_names({map, K, V, _}) ->
    ref_names(K) ++ ref_names(V);
ref_names(_) ->
    [].

-spec expand_structs([binary()], #{binary() => #tg_struct{}}, #{binary() => true}) -> [binary()].
expand_structs([], _ByName, Seen) ->
    maps:keys(Seen);
expand_structs([Name | Rest], ByName, Seen) ->
    case is_map_key(Name, Seen) of
        true ->
            expand_structs(Rest, ByName, Seen);
        false ->
            FieldRefs = [
                ref_names(F#tg_field.type)
             || {_, S} <- maps:to_list(ByName),
                S#tg_struct.name =:= Name,
                F <- S#tg_struct.fields
            ],
            expand_structs(lists:append(FieldRefs) ++ Rest, ByName, Seen#{Name => true})
    end.

-spec callback_form(#tg_function{}, #ctx{}) -> erl_syntax:forms().
callback_form(F, Ctx) ->
    ParamTypes = [erlang_type(Field#tg_field.type, Ctx) || Field <- F#tg_function.params],
    RetType = remote_type(thrift_erl_service, handler_result),
    FunType = fun_type(ParamTypes, RetType),
    callback_attribute(F#tg_function.name, length(ParamTypes), FunType).

%% -callback Name/Arity :: FunType — the payload mixes a tree with a
%% name/arity pair, so it is assembled by hand rather than abstracted.

-spec callback_attribute(binary(), arity(), erl_syntax:syntaxTree()) -> erl_syntax:forms().
callback_attribute(Name, Arity, FunType) ->
    [{attribute, erl_anno:new(0), callback, {{function_atom(Name), Arity}, [FunType]}}].

-spec server_forms(#tg_service{}, module(), module()) -> erl_syntax:forms().
server_forms(Svc, TypesMod, ServerMod) ->
    Doc =
        unicode:characters_to_binary(
            io_lib:format(
                "Server entry points for the ~ts service. `start_link/1`"
                " takes the same options map as `thrift_erl_server`"
                " (minus `service`).",
                [Svc#tg_service.name]
            )
        ),
    V = var_fun(),
    MapUpdate =
        erl_syntax:map_expr(
            V("Opts"),
            [
                %% The plain atom, not ?MODULE: `revert_forms' does not
                %% expand macros.
                map_field(service, abstract(ServerMod)),
                map_field(record_api, abstract(true)),
                map_field(types, abstract(TypesMod))
            ]
        ),
    header(ServerMod, Doc) ++
        [attribute(behaviour, thrift_erl_service)] ++
        [
            export_form([{service_info, 0}, {start_link, 1}, {stop, 1}, {port, 1}])
        ] ++
        %% The runtime serves one service: pick it out of the types
        %% module's per-file map.
        fn_form(service_info, [
            erl_syntax:clause([], none, [
                erl_syntax:application(erl_syntax:atom(maps), erl_syntax:atom(get), [
                    abstract(Svc#tg_service.name),
                    application(TypesMod, service_info, [])
                ])
            ])
        ]) ++
        fn_form(start_link, [
            erl_syntax:clause(
                [V("Opts")], none, [application(thrift_erl_server, start_link, [MapUpdate])]
            )
        ]) ++
        fn_form(stop, [
            erl_syntax:clause(
                [V("Pid")], none, [application(thrift_erl_server, stop, [V("Pid")])]
            )
        ]) ++
        fn_form(port, [
            erl_syntax:clause(
                [V("Pid")], none, [application(thrift_erl_server, port, [V("Pid")])]
            )
        ]).

-spec client_forms(#tg_service{}, module(), module(), module()) -> erl_syntax:forms().
client_forms(Svc, TypesMod, ServerMod, ClientMod) ->
    Doc =
        unicode:characters_to_binary(
            io_lib:format(
                "Typed client for the ~ts service. `start_link/1` takes the"
                " same options map as `thrift_erl_client` (minus `service`)."
                " Struct arguments and results are converted to records at"
                " the boundary.",
                [Svc#tg_service.name]
            )
        ),
    ClientFns = [client_fn(F, TypesMod) || F <- Svc#tg_service.functions],
    header(ClientMod, Doc) ++
        [
            export_form(
                lists:append([Exports || {Exports, _} <- ClientFns]) ++ [{start_link, 1}, {stop, 1}]
            )
        ] ++
        lists:append([Forms || {_, Forms} <- ClientFns]) ++
        start_link_form(ServerMod) ++
        stop_form().

%% One wrapper pair per function: `Name/N` applies the default timeout,
%% `Name/(N+1)` the call itself. Non-oneway replies come back through
%% `thrift_erl_record:call_result_from_wire`, so records surface here.

-spec client_fn(#tg_function{}, module()) ->
    {[erl_syntax:forms()], [erl_syntax:forms()]}.
client_fn(F, TypesMod) ->
    Name = function_atom(F#tg_function.name),
    NParams = length(F#tg_function.params),
    ShortArgs = [erl_syntax:variable("Client")] ++ param_vars(NParams),
    LongArgs = ShortArgs ++ [erl_syntax:variable("Timeout")],
    ShortCall = erl_syntax:application(
        erl_syntax:atom(Name), ShortArgs ++ [abstract(?DEFAULT_TIMEOUT)]
    ),
    WireArgs =
        erl_syntax:application(
            erl_syntax:atom(thrift_erl_record),
            erl_syntax:atom(args_to_wire),
            [
                application(TypesMod, function_info, [abstract(F#tg_function.name), abstract(params)]),
                erl_syntax:list(param_vars(NParams))
            ]
        ),
    WireName = abstract(F#tg_function.name),
    LongBody =
        case F#tg_function.oneway of
            true ->
                [client_bridge_call(oneway, WireName, WireArgs)];
            false ->
                RawCall = client_bridge_call(call, WireName, WireArgs),
                [
                    erl_syntax:application(
                        erl_syntax:atom(thrift_erl_record),
                        erl_syntax:atom(call_result_from_wire),
                        [
                            application(TypesMod, function_info, [
                                abstract(F#tg_function.name), abstract(reply)
                            ]),
                            application(TypesMod, function_info, [
                                abstract(F#tg_function.name), abstract(exceptions)
                            ]),
                            RawCall
                        ]
                    )
                ]
        end,
    ShortClause = erl_syntax:clause(ShortArgs, none, [ShortCall]),
    LongClause = erl_syntax:clause(LongArgs, none, LongBody),
    Exports = [{Name, NParams + 1}, {Name, NParams + 2}],
    Forms =
        fn_form(Name, [ShortClause]) ++
            fn_form(Name, [LongClause]) ++
            spec_form(F, NParams + 1, oneway_ret(F)) ++
            spec_form(F, NParams + 2, call_ret()),
    {Exports, Forms}.

%% The long-form wrapper delegates to `thrift_erl_client` either the
%% oneway or the request/response call; both take the same shape.
-spec client_bridge_call(oneway | call, erl_syntax:syntaxTree(), erl_syntax:syntaxTree()) ->
    erl_syntax:syntaxTree().
client_bridge_call(Method, FunName, WireArgs) ->
    erl_syntax:application(
        erl_syntax:atom(thrift_erl_client),
        erl_syntax:atom(Method),
        [
            erl_syntax:variable("Client"),
            FunName,
            WireArgs,
            erl_syntax:variable("Timeout")
        ]
    ).

-spec param_vars(pos_integer()) -> [erl_syntax:syntaxTree()].
param_vars(N) ->
    [erl_syntax:variable("P" ++ integer_to_list(I)) || I <- lists:seq(1, N)].

-spec spec_form(#tg_function{}, arity(), erl_syntax:syntaxTree()) -> erl_syntax:forms().
spec_form(F, Arity, RetType) ->
    ArgTypes = [raw_type(pid)] ++ lists:duplicate(Arity - 1, raw_type(term)),
    FunType = fun_type(ArgTypes, RetType),
    [{attribute, erl_anno:new(0), spec, {{function_atom(F#tg_function.name), Arity}, [FunType]}}].

-spec call_ret() -> erl_syntax:syntaxTree().
call_ret() ->
    remote_type(thrift_erl_client, call_result).

%% `ok | {error, term()}` for oneway, `thrift_erl_client:call_result()`
%% for regular calls.

-spec oneway_ret(#tg_function{}) -> erl_syntax:syntaxTree().
oneway_ret(F) ->
    case F#tg_function.oneway of
        true ->
            Anno = erl_anno:new(0),
            ok_error_type(Anno, term_type(), error_term_type(Anno));
        false ->
            call_ret()
    end.

-spec start_link_form(module()) -> erl_syntax:forms().
start_link_form(ServerMod) ->
    MapUpdate =
        erl_syntax:map_expr(
            erl_syntax:variable("Opts"),
            [map_field(service, abstract(ServerMod))]
        ),
    fn_form(start_link, [
        erl_syntax:clause(
            [erl_syntax:variable("Opts")],
            none,
            [
                erl_syntax:application(
                    erl_syntax:atom(thrift_erl_client),
                    erl_syntax:atom(start_link),
                    [MapUpdate]
                )
            ]
        )
    ]).

-spec stop_form() -> erl_syntax:forms().
stop_form() ->
    fn_form(stop, [
        erl_syntax:clause(
            [erl_syntax:variable("Pid")],
            none,
            [
                erl_syntax:application(
                    erl_syntax:atom(thrift_erl_client),
                    erl_syntax:atom(stop),
                    [erl_syntax:variable("Pid")]
                )
            ]
        )
    ]).

%%--------------------------------------------------------------------
%% Erlang type mapping (specs and callbacks)
%%--------------------------------------------------------------------

-spec erlang_type(thrift_type(), #ctx{}) -> erl_syntax:syntaxTree().
erlang_type({base, B, _}, _) ->
    base_erlang_type(B);
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
erlang_type({ref, Name, _}, Ctx) ->
    case binary:split(Name, <<".">>) of
        [ModKey, Local] ->
            Module = maps:get(ModKey, Ctx#ctx.modules, undefined),
            ref_type(find_struct(Module, Local), module_prefix(ModKey, Ctx));
        [Local] ->
            Module = maps:get(Ctx#ctx.current, Ctx#ctx.modules),
            ref_type(find_struct(Module, Local), current_prefix(Ctx))
    end.

-spec base_erlang_type(base_type()) -> erl_syntax:syntaxTree().
base_erlang_type(bool) ->
    raw_type(boolean);
base_erlang_type(B) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    raw_type(integer);
base_erlang_type(double) ->
    raw_type(float);
base_erlang_type(S) when S =:= string; S =:= binary; S =:= uuid ->
    raw_type(binary).

-spec module_prefix(module_key(), #ctx{}) -> binary().
module_prefix(ModKey, Ctx) ->
    case maps:get(ModKey, Ctx#ctx.modules, undefined) of
        undefined -> <<>>;
        Mod -> Mod#tg_module.prefix
    end.

-spec ref_type({ok, #tg_struct{}} | error, binary()) -> erl_syntax:syntaxTree().
ref_type({ok, S}, Prefix) ->
    case record_mode(S) of
        true -> record_type(record_tag(Prefix, S#tg_struct.name));
        false -> raw_type(map)
    end;
ref_type(error, _Prefix) ->
    %% Enums and typedefs surface as their scalar element types.
    raw_type(term).

-spec raw_type(atom()) -> erl_syntax:syntaxTree().
raw_type(map) ->
    {type, erl_anno:new(0), map, any};
raw_type(Name) ->
    {type, erl_anno:new(0), Name, []}.

-spec remote_type(module(), atom()) -> erl_syntax:syntaxTree().
remote_type(Module, Name) ->
    Anno = erl_anno:new(0),
    {remote_type, Anno, [{atom, Anno, Module}, {atom, Anno, Name}, []]}.

-spec fun_type([erl_syntax:syntaxTree()], erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
fun_type(ParamTypes, RetType) ->
    Anno = erl_anno:new(0),
    {type, Anno, 'fun', [{type, Anno, product, ParamTypes}, RetType]}.

-spec function_atom(binary()) -> atom().
function_atom(Name) ->
    binary_to_atom(Name, utf8).

%%--------------------------------------------------------------------
%% erl_syntax helpers
%%--------------------------------------------------------------------

-spec var_fun() -> fun((string()) -> erl_syntax:syntaxTree()).
var_fun() ->
    fun erl_syntax:variable/1.

-spec header(module(), binary()) -> erl_syntax:forms().
header(ModuleName, DocBinary) ->
    [
        erl_syntax:comment([
            " Copyright 2026 Sergei Yelin",
            "",
            " Licensed under the Apache License, Version 2.0 (the \"License\");",
            " you may not use this file except in compliance with the License.",
            " You may obtain a copy of the License at",
            "",
            "     http://www.apache.org/licenses/LICENSE-2.0"
        ]),
        erl_syntax:attribute(erl_syntax:atom(module), [erl_syntax:atom(ModuleName)]),
        erl_syntax:attribute(
            erl_syntax:atom(moduledoc),
            [erl_syntax:string(unicode:characters_to_list(DocBinary))]
        )
    ].

%% The attribute payload must be a term (tuples of {name, arity},
%% record field tuples, descriptor data) or a syntax tree; both print
%% as literal syntax.

-spec attribute(atom(), term() | erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
attribute(Name, Payload) ->
    erl_syntax:attribute(
        erl_syntax:atom(Name),
        [abstract(Payload)]
    ).

%% -export() entries must be `arity_qualifier' trees — `abstract' tuples
%% print the same but `revert_forms' rejects them.

-spec export_form([{atom(), arity()}]) -> erl_syntax:syntaxTree().
export_form(Entries) ->
    erl_syntax:attribute(
        erl_syntax:atom(export),
        [
            erl_syntax:list([
                erl_syntax:arity_qualifier(erl_syntax:atom(F), erl_syntax:integer(A))
             || {F, A} <- Entries
            ])
        ]
    ).

-spec fn_form(atom(), [erl_syntax:syntaxTree()]) -> erl_syntax:forms().
fn_form(Name, Clauses) ->
    [erl_syntax:function(erl_syntax:atom(Name), Clauses)].

-spec fn_clause([erl_syntax:syntaxTree()], erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
fn_clause(Patterns, Body) ->
    erl_syntax:clause(Patterns, none, [Body]).

%% The catch-all pattern: the variable `_`, not the atom `'_'` (which
%% `abstract/1` would build and which only matches itself).

-spec wildcard() -> erl_syntax:syntaxTree().
wildcard() ->
    erl_syntax:variable("_").

%% Binaries holding printable text print as `<<"text">>' — byte-list
%% form would swamp the generated descriptors.

%% Recursive so printable binaries print as `<<"text">>' at any depth —
%% the stock `abstract/1' renders nested binaries as byte lists.

-spec abstract(term()) -> erl_syntax:syntaxTree().
abstract(Term) when is_binary(Term) ->
    case printable(Term) of
        true -> erl_syntax:binary([erl_syntax:binary_field(erl_syntax:string(unicode:characters_to_list(Term)))]);
        false -> erl_syntax:abstract(Term)
    end;
abstract(Term) when is_tuple(Term) ->
    erl_syntax:tuple([abstract(Element) || Element <- tuple_to_list(Term)]);
abstract(Term) when is_list(Term) ->
    erl_syntax:list([abstract(Element) || Element <- Term]);
abstract(Term) when is_map(Term) ->
    erl_syntax:map_expr([
        erl_syntax:map_field_assoc(abstract(Key), abstract(Value))
     || Key := Value <- Term
    ]);
abstract(Term) ->
    erl_syntax:abstract(Term).

-spec printable(binary()) -> boolean().
printable(<<>>) ->
    true;
printable(<<C, Rest/binary>>) when C >= 32, C =< 126 ->
    printable(Rest);
printable(_) ->
    false.

-spec map_field(atom(), erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
map_field(Key, Value) ->
    erl_syntax:map_field_assoc(erl_syntax:atom(Key), Value).

-spec application(module(), atom(), [erl_syntax:syntaxTree()]) -> erl_syntax:syntaxTree().
application(Module, Name, Args) ->
    erl_syntax:application(
        erl_syntax:module_qualifier(erl_syntax:atom(Module), erl_syntax:atom(Name)),
        Args
    ).

%% Callback and spec attributes carry raw `erl_parse' type nodes
%% (`erl_prettypr' cannot lay them), so those attributes are built and
%% rendered as raw forms (`erl_pp'), while everything else stays trees.

-spec format(erl_syntax:forms()) -> binary().
format(Forms) ->
    unicode:characters_to_binary(lists:append([format_form(F) || F <- Forms])).

-spec format_form(erl_syntax:forms() | erl_syntax:syntaxTree()) -> string().
format_form({raw_text, Text}) ->
    unicode:characters_to_list(Text);
format_form({tree, _, _, _} = Tree) ->
    [erl_prettypr:format(Tree), "\n"];
format_form(RawForm) ->
    erl_pp:form(RawForm).

%%--------------------------------------------------------------------
%% In-memory compilation
%%--------------------------------------------------------------------

-spec compile_one(module(), erl_syntax:forms()) -> compiled().
compile_one(Name, Forms) ->
    case compile:forms(erl_syntax:revert_forms(Forms), [return, binary]) of
        {ok, Name, Beam, _Warnings} ->
            {ok, Name, Beam};
        {error, Errors, _Warnings} ->
            {error, {Name, Errors}}
    end.
