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

-export([
    sources/1,
    compile_sources/1,
    erlang_type/2,
    record_mode/1,
    record_form/2,
    sanitize/1
]).

-export_type([compiled/0, source/0]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

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

%% Wire-level descriptor terms — the same shapes thrift_erl_binary and
%% thrift_erl_record consume.

-type desc() :: term().

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-doc "Renders every generated module as a source map with its hrl when present.".
-spec sources(#tg_model{}) -> [source()].
sources(Model) ->
    [
        #{
            module => Name,
            source => thrift_generator_emitter_syntax:format(Forms),
            hrl =>
                case HrlForms of
                    undefined -> undefined;
                    _ -> thrift_generator_emitter_syntax:format(HrlForms)
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
    Ctx0 = #ectx{
        modules = #{M#tg_module.name => M || M <- Model#tg_model.modules},
        type_modules =
            #{
                M#tg_module.name => types_module_atom(M#tg_module.name)
             || M <- Model#tg_model.modules
            },
        current = undefined
    },
    lists:append([
        module_sources(Mod, Ctx0#ectx{current = Mod#tg_module.name})
     || Mod <- Model#tg_model.modules
    ]).

-spec module_sources(#tg_module{}, #ectx{}) ->
    [{module(), erl_syntax:forms(), erl_syntax:forms() | undefined}].
module_sources(Mod, Ctx) ->
    TypesMod = types_module_atom(Mod#tg_module.name),
    ServiceForms = [
        thrift_generator_emitter_service:service_sources(Svc, Mod, Ctx)
     || Svc <- Mod#tg_module.services
    ],
    [
        {TypesMod, types_forms(Mod, Ctx), types_hrl_forms(Mod, Ctx)}
        | lists:append(ServiceForms)
    ].

%%--------------------------------------------------------------------
%% <mod>_types.erl
%%--------------------------------------------------------------------

-spec types_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
types_forms(Mod, Ctx) ->
    TypesMod = types_module_atom(Mod#tg_module.name),
    Records = [
        record_form(S, Mod#tg_module.prefix)
     || S <- Mod#tg_module.structs,
        record_mode(S)
    ],
    Exports =
        [
            thrift_generator_emitter_syntax:export_form([
                {struct_info, 1},
                {enum_info, 1},
                {function_info, 2},
                {service_info, 0},
                {record_fields, 1},
                {tag_index, 0},
                {convert, 2}
            ]),
            thrift_generator_emitter_syntax:export_form(struct_codec_entries(Mod)),
            thrift_generator_emitter_syntax:export_form(enum_helper_entries(Mod)),
            thrift_generator_emitter_syntax:export_form(const_entries(Mod))
        ],
    thrift_generator_emitter_syntax:header(TypesMod, types_doc(Mod)) ++
        Records ++
        [
            %% The types module declares every record for consumers;
            %% introspection forms reference them by name, not usage.
            thrift_generator_emitter_syntax:nowarn_unused_record_form()
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

-spec types_hrl_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
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

-spec hrl_include_note(#tg_module{}, #ectx{}) -> [string()].
hrl_include_note(Mod, Ctx) ->
    Deps =
        lists:usort([
            Dep
         || S <- Mod#tg_module.structs,
            F <- S#tg_struct.fields,
            Dep <- [record_dep_module(F#tg_field.type, Ctx)],
            Dep =/= undefined,
            Dep =/= Ctx#ectx.current
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

-spec record_dep_module(thrift_type(), #ectx{}) -> module_key() | undefined.
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
            [L] -> {Ctx#ectx.current, L}
        end,
    case find_struct(maps:get(ModKey, Ctx#ectx.modules, undefined), Local) of
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

-spec hrl_record_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
hrl_record_forms(Mod, Ctx) ->
    lists:append([
        hrl_struct_forms(S, Ctx)
     || S <- Mod#tg_module.structs,
        record_mode(S)
    ]).

-spec hrl_struct_forms(#tg_struct{}, #ectx{}) -> erl_syntax:forms().
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

-spec struct_codec_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
struct_codec_forms(Mod, Ctx) ->
    lists:append([
        struct_codec_one(S, Ctx)
     || S <- Mod#tg_module.structs
    ]).

-spec struct_codec_one(#tg_struct{}, #ectx{}) -> erl_syntax:forms().
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
    Doc = S#tg_struct.doc,
    Anno = erl_anno:new(0),
    ResultType = fun(Ok) ->
        thrift_generator_emitter_syntax:ok_error_type(Anno, Ok, thrift_generator_emitter_syntax:error_term_type(Anno))
    end,
    EncodeSpec = fun(Arity) ->
        {attribute, Anno, spec,
            {{Encode, Arity}, [
                thrift_generator_emitter_syntax:fun_type(
                    [value_type(S, Ctx)] ++
                        lists:duplicate(Arity - 1, thrift_generator_emitter_syntax:raw_type(term)),
                    ResultType({type, Anno, binary, []})
                )
            ]}}
    end,
    DecodeSpec = fun(Arity) ->
        {attribute, Anno, spec,
            {{Decode, Arity}, [
                thrift_generator_emitter_syntax:fun_type(
                    [thrift_generator_emitter_syntax:raw_type(binary)] ++
                        lists:duplicate(Arity - 1, thrift_generator_emitter_syntax:raw_type(term)),
                    ResultType(thrift_generator_emitter_syntax:term_type())
                )
            ]}}
    end,
    thrift_generator_emitter_syntax:doc_form(
        Doc,
        <<"Encodes `Value` in any representation with the binary protocol.">>
    ) ++
        [EncodeSpec(1)] ++
        thrift_generator_emitter_syntax:fn_form(Encode, [
            thrift_generator_emitter_syntax:fn_clause(
                [erl_syntax:variable("Value")],
                thrift_generator_emitter_syntax:application(thrift_erl, encode, [
                    thrift_generator_emitter_syntax:abstract(Desc), erl_syntax:variable("Value")
                ])
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            Doc, <<"Encodes `Value` in any representation with the given protocol.">>
        ) ++
        [EncodeSpec(2)] ++
        thrift_generator_emitter_syntax:fn_form(Encode, [
            thrift_generator_emitter_syntax:fn_clause(
                [erl_syntax:variable("Value"), erl_syntax:variable("Protocol")],
                thrift_generator_emitter_syntax:application(thrift_erl, encode, [
                    thrift_generator_emitter_syntax:abstract(Desc),
                    erl_syntax:variable("Value"),
                    erl_syntax:variable("Protocol")
                ])
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            Doc,
            <<
                "Decodes the whole binary into the default representation"
                " (record for record-mode structs, map otherwise); trailing"
                " bytes or truncation fail the decode."
            >>
        ) ++
        [DecodeSpec(1)] ++
        thrift_generator_emitter_syntax:fn_form(Decode, [
            thrift_generator_emitter_syntax:fn_clause(
                [erl_syntax:variable("Binary")],
                thrift_generator_emitter_syntax:application(thrift_erl, decode, [
                    thrift_generator_emitter_syntax:abstract(Desc),
                    erl_syntax:variable("Binary"),
                    thrift_generator_emitter_syntax:abstract(DefaultRepr)
                ])
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            Doc, <<"Decodes the whole binary into the given `thrift_erl:repr()`.">>
        ) ++
        [DecodeSpec(2)] ++
        thrift_generator_emitter_syntax:fn_form(Decode, [
            thrift_generator_emitter_syntax:fn_clause(
                [erl_syntax:variable("Binary"), erl_syntax:variable("Repr")],
                thrift_generator_emitter_syntax:application(thrift_erl, decode, [
                    thrift_generator_emitter_syntax:abstract(Desc),
                    erl_syntax:variable("Binary"),
                    erl_syntax:variable("Repr")
                ])
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            Doc,
            <<
                "Decodes the whole binary into the given representation"
                " with the given protocol."
            >>
        ) ++
        [DecodeSpec(3)] ++
        thrift_generator_emitter_syntax:fn_form(Decode, [
            thrift_generator_emitter_syntax:fn_clause(
                [
                    erl_syntax:variable("Binary"),
                    erl_syntax:variable("Repr"),
                    erl_syntax:variable("Protocol")
                ],
                thrift_generator_emitter_syntax:application(thrift_erl, decode, [
                    thrift_generator_emitter_syntax:abstract(Desc),
                    erl_syntax:variable("Binary"),
                    erl_syntax:variable("Repr"),
                    erl_syntax:variable("Protocol")
                ])
            )
        ]) ++
        case record_mode(S) of
            true ->
                FromMap = binary_to_atom(<<Prefix/binary, "_from_map">>, utf8),
                thrift_generator_emitter_syntax:doc_form(
                    Doc, <<"Builds the record from a map keyed by field atoms or wire names.">>
                ) ++
                    [
                        {attribute, Anno, spec,
                            {{FromMap, 1}, [
                                thrift_generator_emitter_syntax:fun_type(
                                    [thrift_generator_emitter_syntax:raw_type(map)],
                                    thrift_generator_emitter_syntax:term_type()
                                )
                            ]}}
                    ] ++
                    thrift_generator_emitter_syntax:fn_form(FromMap, [
                        thrift_generator_emitter_syntax:fn_clause(
                            [erl_syntax:variable("Map")],
                            erl_syntax:tuple([
                                erl_syntax:atom(ok),
                                thrift_generator_emitter_syntax:application(thrift_erl_record, from_wire, [
                                    thrift_generator_emitter_syntax:abstract(Desc),
                                    thrift_generator_emitter_syntax:application(thrift_erl_record, to_wire, [
                                        thrift_generator_emitter_syntax:abstract(Desc), erl_syntax:variable("Map")
                                    ]),
                                    thrift_generator_emitter_syntax:abstract(record)
                                ])
                            ])
                        )
                    ]);
            false ->
                []
        end.
-spec list_type(thrift_type(), #ectx{}) -> erl_syntax:syntaxTree().
list_type(T, Ctx) ->
    {type, erl_anno:new(0), list, [erlang_type(T, Ctx)]}.
-spec struct_ref(#tg_struct{}, #ectx{}) -> desc().
struct_ref(S, Ctx) ->
    {struct, {ref, types_module_atom(Ctx#ectx.current), S#tg_struct.name}}.

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

-spec value_type(#tg_struct{}, #ectx{}) -> erl_syntax:syntaxTree().
value_type(S, Ctx) ->
    case record_mode(S) of
        true ->
            Tag = record_tag(current_prefix(Ctx), S#tg_struct.name),
            {type, erl_anno:new(0), union, [
                thrift_generator_emitter_syntax:record_type(Tag), thrift_generator_emitter_syntax:raw_type(map)
            ]};
        false ->
            thrift_generator_emitter_syntax:raw_type(map)
    end.

%%--------------------------------------------------------------------
%% Tag index and convert
%%--------------------------------------------------------------------

-spec tag_index_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
tag_index_forms(Mod, Ctx) ->
    Anno = erl_anno:new(0),
    Pairs = [
        {struct_index_tag(S, current_prefix(Ctx)), struct_ref(S, Ctx)}
     || S <- Mod#tg_module.structs
    ],
    [
        {attribute, Anno, spec,
            {{tag_index, 0}, [
                thrift_generator_emitter_syntax:fun_type(
                    [],
                    {remote_type, Anno, [
                        {atom, Anno, thrift_erl}, {atom, Anno, tag_index}, []
                    ]}
                )
            ]}},
        {attribute, Anno, spec,
            {{convert, 2}, [
                thrift_generator_emitter_syntax:fun_type(
                    [
                        thrift_generator_emitter_syntax:term_type(),
                        {remote_type, Anno, [
                            {atom, Anno, thrift_erl}, {atom, Anno, repr}, []
                        ]}
                    ],
                    {type, Anno, union, [
                        {type, Anno, tuple, [{atom, Anno, ok}, thrift_generator_emitter_syntax:term_type()]},
                        {type, Anno, tuple, [{atom, Anno, error}, thrift_generator_emitter_syntax:term_type()]}
                    ]}
                )
            ]}}
    ] ++
        thrift_generator_emitter_syntax:doc_form(
            undefined,
            <<
                "The struct tag -> descriptor map `thrift_erl:convert/3` takes:"
                " record tags for record-mode structs, wire names for"
                " map-mode ones."
            >>
        ) ++
        thrift_generator_emitter_syntax:fn_form(tag_index, [
            thrift_generator_emitter_syntax:fn_clause(
                [], thrift_generator_emitter_syntax:abstract(maps:from_list(Pairs))
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            undefined,
            <<
                "Reshapes a typed value (record or struct map, nested"
                " structures included) into `Repr` without touching bytes."
            >>
        ) ++
        thrift_generator_emitter_syntax:fn_form(convert, [
            thrift_generator_emitter_syntax:fn_clause(
                [erl_syntax:variable("Value"), erl_syntax:variable("Repr")],
                thrift_generator_emitter_syntax:application(thrift_erl, convert, [
                    thrift_generator_emitter_syntax:application(
                        types_module_atom(Ctx#ectx.current), tag_index, []
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
    DescExpr = thrift_generator_emitter_syntax:abstract(enum_desc(E)),
    Anno = erl_anno:new(0),
    V = erl_syntax:variable("Value"),
    Int = erl_syntax:variable("Int"),
    Atom = erl_syntax:variable("Atom"),
    OkTuple = fun(Value) ->
        erl_syntax:tuple([erl_syntax:atom(ok), Value])
    end,
    Keyfind = fun(Key, Pos) ->
        erl_syntax:application(erl_syntax:atom(lists), erl_syntax:atom(keyfind), [
            Key, thrift_generator_emitter_syntax:abstract(Pos), DescExpr
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
    Union = fun(OkType) -> thrift_generator_emitter_syntax:ok_error_type(Anno, OkType, {atom, Anno, error}) end,
    Doc = E#tg_enum.doc,
    thrift_generator_emitter_syntax:doc_form(
        Doc,
        <<
            "Maps an enum member atom to its integer value; integers pass"
            " through, anything else answers `error`."
        >>
    ) ++
        [
            {attribute, Anno, spec,
                {{ToInt, 1}, [
                    thrift_generator_emitter_syntax:fun_type(
                        [
                            {type, Anno, union, [
                                thrift_generator_emitter_syntax:raw_type(atom),
                                thrift_generator_emitter_syntax:raw_type(integer)
                            ]}
                        ],
                        Union(thrift_generator_emitter_syntax:raw_type(integer))
                    )
                ]}}
        ] ++
        thrift_generator_emitter_syntax:fn_form(ToInt, [
            erl_syntax:clause([V], Guard(is_atom), [
                erl_syntax:case_expr(Keyfind(V, 2), [MatchClause(ToIntPair, Int), MissClause])
            ]),
            erl_syntax:clause([V], Guard(is_integer), [OkTuple(V)])
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            Doc,
            <<
                "Maps an integer to the enum member atom; unknown values"
                " answer `error`."
            >>
        ) ++
        [
            {attribute, Anno, spec,
                {{FromInt, 1}, [
                    thrift_generator_emitter_syntax:fun_type(
                        [thrift_generator_emitter_syntax:raw_type(integer)],
                        Union(thrift_generator_emitter_syntax:raw_type(atom))
                    )
                ]}}
        ] ++
        thrift_generator_emitter_syntax:fn_form(FromInt, [
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
        thrift_generator_emitter_syntax:doc_form(C#tg_const.doc, <<"The constant's value as declared in the IDL.">>) ++
            [
                {attribute, erl_anno:new(0), spec,
                    {{binary_to_atom(typed_prefix(Mod#tg_module.prefix, C#tg_const.name), utf8), 0}, [
                        thrift_generator_emitter_syntax:fun_type([], const_spec_type(C#tg_const.type))
                    ]}}
            ] ++
            thrift_generator_emitter_syntax:fn_form(
                binary_to_atom(typed_prefix(Mod#tg_module.prefix, C#tg_const.name), utf8), [
                    thrift_generator_emitter_syntax:fn_clause([], const_literal(C#tg_const.value))
                ]
            )
     || C <- Mod#tg_module.consts
    ]).

%% Constant spec types without a resolution context: refs (enum
%% members) surface as term, containers mirror erlang_type/2.

-spec const_spec_type(thrift_type()) -> erl_syntax:syntaxTree().
const_spec_type({base, B, _}) ->
    thrift_generator_emitter_syntax:base_erlang_type(B);
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
    thrift_generator_emitter_syntax:raw_type(term).

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
                    erl_syntax:atom(field_atom(F#tg_field.name)), thrift_generator_emitter_syntax:abstract(Default)
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

-spec struct_info_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
struct_info_forms(Mod, Ctx) ->
    Clauses = [
        thrift_generator_emitter_syntax:fn_clause(
            [thrift_generator_emitter_syntax:abstract(S#tg_struct.name)],
            thrift_generator_emitter_syntax:abstract(struct_desc(S, Ctx))
        )
     || S <- Mod#tg_module.structs
    ],
    total_form(struct_info, Clauses).

-spec struct_desc(#tg_struct{}, #ectx{}) -> desc().
struct_desc(S, Ctx) ->
    {S#tg_struct.kind, [field_desc(F, Ctx) || F <- S#tg_struct.fields]}.

-spec field_desc(#tg_field{}, #ectx{}) -> desc().
field_desc(F, Ctx) ->
    {F#tg_field.id, F#tg_field.required, type_desc(F#tg_field.type, Ctx), F#tg_field.name, F#tg_field.default}.

-spec enum_info_forms(#tg_module{}) -> erl_syntax:forms().
enum_info_forms(Mod) ->
    Clauses = [
        thrift_generator_emitter_syntax:fn_clause(
            [thrift_generator_emitter_syntax:abstract(E#tg_enum.name)],
            thrift_generator_emitter_syntax:abstract([{Value, enum_atom(Name)} || {Value, Name} <- E#tg_enum.values])
        )
     || E <- Mod#tg_module.enums
    ],
    total_form(enum_info, Clauses).

%% Every introspection lookup ends in the same catch-all clause: an
%% unknown key answers `error`, mirroring the official generator.
-spec total_form(atom(), [erl_syntax:syntaxTree()]) -> erl_syntax:forms().
total_form(Name, Clauses) ->
    thrift_generator_emitter_syntax:fn_form(
        Name,
        Clauses ++
            [
                thrift_generator_emitter_syntax:fn_clause(
                    [thrift_generator_emitter_syntax:wildcard()], thrift_generator_emitter_syntax:abstract(error)
                )
            ]
    ).

-spec function_info_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
function_info_forms(Mod, Ctx) ->
    Clauses =
        lists:append([
            [
                thrift_generator_emitter_syntax:fn_clause(
                    [
                        thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                        thrift_generator_emitter_syntax:abstract(params)
                    ],
                    thrift_generator_emitter_syntax:abstract(params_desc(F, Ctx))
                ),
                thrift_generator_emitter_syntax:fn_clause(
                    [
                        thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                        thrift_generator_emitter_syntax:abstract(oneway)
                    ],
                    thrift_generator_emitter_syntax:abstract(F#tg_function.oneway)
                ),
                thrift_generator_emitter_syntax:fn_clause(
                    [
                        thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                        thrift_generator_emitter_syntax:abstract(reply)
                    ],
                    thrift_generator_emitter_syntax:abstract(reply_desc(F, Ctx))
                ),
                thrift_generator_emitter_syntax:fn_clause(
                    [
                        thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                        thrift_generator_emitter_syntax:abstract(exceptions)
                    ],
                    thrift_generator_emitter_syntax:abstract(exceptions_desc(F, Ctx))
                )
            ]
         || F <- service_functions(Mod)
        ]),
    thrift_generator_emitter_syntax:fn_form(
        function_info,
        Clauses ++
            [
                thrift_generator_emitter_syntax:fn_clause(
                    [thrift_generator_emitter_syntax:wildcard(), thrift_generator_emitter_syntax:wildcard()],
                    thrift_generator_emitter_syntax:abstract(error)
                )
            ]
    ).

-spec service_functions(#tg_module{}) -> [#tg_function{}].
service_functions(Mod) ->
    lists:append([S#tg_service.functions || S <- Mod#tg_module.services]).

-spec params_desc(#tg_function{}, #ectx{}) -> desc().
params_desc(F, Ctx) ->
    {struct, {struct, [field_desc(P, Ctx) || P <- F#tg_function.params]}}.

-spec reply_desc(#tg_function{}, #ectx{}) -> desc() | undefined.
reply_desc(F, Ctx) ->
    case F#tg_function.return_type of
        void ->
            undefined;
        Type ->
            type_desc(Type, Ctx)
    end.

-spec exceptions_desc(#tg_function{}, #ectx{}) -> [desc()].
exceptions_desc(F, Ctx) ->
    [field_desc(T, Ctx) || T <- F#tg_function.throws].

-spec service_info_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
service_info_forms(Mod, Ctx) ->
    Entries = [
        {S#tg_service.name, service_entry(S#tg_service.functions, Ctx, #{})}
     || S <- Mod#tg_module.services
    ],
    thrift_generator_emitter_syntax:fn_form(service_info, [
        thrift_generator_emitter_syntax:fn_clause([], thrift_generator_emitter_syntax:abstract(maps:from_list(Entries)))
    ]).

-spec service_entry([#tg_function{}], #ectx{}, map()) -> map().
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
        thrift_generator_emitter_syntax:fn_clause(
            [thrift_generator_emitter_syntax:abstract(S#tg_struct.name)],
            thrift_generator_emitter_syntax:abstract(fields_decl(S, Mod#tg_module.prefix))
        )
     || S <- Mod#tg_module.structs
    ],
    thrift_generator_emitter_syntax:fn_form(
        record_fields,
        Clauses ++
            [
                thrift_generator_emitter_syntax:fn_clause(
                    [thrift_generator_emitter_syntax:wildcard()], thrift_generator_emitter_syntax:abstract(none)
                )
            ]
    ).

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

-spec type_desc(thrift_type(), #ectx{}) -> desc().
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

-spec qualified_desc(module_key(), binary(), #ectx{}) -> desc().
qualified_desc(ModKey, Local, Ctx) ->
    Module = maps:get(ModKey, Ctx#ectx.modules, undefined),
    TypesMod = maps:get(ModKey, Ctx#ectx.type_modules, undefined),
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

-spec local_desc(binary(), #ectx{}) -> desc().
local_desc(Name, Ctx) ->
    Module = maps:get(Ctx#ectx.current, Ctx#ectx.modules),
    case find_struct(Module, Name) of
        {ok, _S} ->
            {struct, {ref, types_module_atom(Ctx#ectx.current), Name}};
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

-spec cross_module_desc(binary(), #ectx{}) -> desc().
cross_module_desc(Name, Ctx) ->
    Hits = [
        {ModKey, Kind}
     || {ModKey, Module} <- maps:to_list(Ctx#ectx.modules),
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
            Module = maps:get(ModKey, Ctx#ectx.modules),
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

-spec current_prefix(#ectx{}) -> binary().
current_prefix(Ctx) ->
    (maps:get(Ctx#ectx.current, Ctx#ectx.modules))#tg_module.prefix.

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
%% Erlang type mapping (specs and callbacks)
%%--------------------------------------------------------------------

-spec erlang_type(thrift_type(), #ectx{}) -> erl_syntax:syntaxTree().
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
erlang_type({ref, Name, _}, Ctx) ->
    case binary:split(Name, <<".">>) of
        [ModKey, Local] ->
            Module = maps:get(ModKey, Ctx#ectx.modules, undefined),
            ref_type(find_struct(Module, Local), module_prefix(ModKey, Ctx));
        [Local] ->
            Module = maps:get(Ctx#ectx.current, Ctx#ectx.modules),
            ref_type(find_struct(Module, Local), current_prefix(Ctx))
    end.
-spec module_prefix(module_key(), #ectx{}) -> binary().
module_prefix(ModKey, Ctx) ->
    case maps:get(ModKey, Ctx#ectx.modules, undefined) of
        undefined -> <<>>;
        Mod -> Mod#tg_module.prefix
    end.

-spec ref_type({ok, #tg_struct{}} | error, binary()) -> erl_syntax:syntaxTree().
ref_type({ok, S}, Prefix) ->
    case record_mode(S) of
        true -> thrift_generator_emitter_syntax:record_type(record_tag(Prefix, S#tg_struct.name));
        false -> thrift_generator_emitter_syntax:raw_type(map)
    end;
ref_type(error, _Prefix) ->
    %% Enums and typedefs surface as their scalar element types.
    thrift_generator_emitter_syntax:raw_type(term).
%%--------------------------------------------------------------------
%% In-memory compilation
%%--------------------------------------------------------------------

-spec compile_one(module(), erl_syntax:forms()) -> compiled().
compile_one(Name, Forms) ->
    %% warnings_as_errors: the emitter is the first consumer of its own
    %% output — a generated warning (a misplaced -doc, an unused
    %% variable) fails here instead of at the code generator's user.
    case compile:forms(erl_syntax:revert_forms(Forms), [return, binary, warnings_as_errors]) of
        {ok, Name, Beam, _Warnings} ->
            {ok, Name, Beam};
        {error, Errors, _Warnings} ->
            {error, {Name, Errors}}
    end.
