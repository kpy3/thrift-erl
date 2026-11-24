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

Per IDL file a `<mod>_types.erl` is emitted: records for structs and
unions (map representation via the `erl.struct_type = "map"`
annotation, tagged-tuple sums via `erl.union_type = "sum"` on a union
or its namespace header), the introspection surface (`struct_info/1`,
`enum_info/1`, `function_info/2`, `service_info/0`) and the
record-field index (`record_fields/1`) that `thrift_runtime_record` uses
to bridge records and the wire.

Per service: `<svc>_handler.erl` (the `-callback` behaviour),
`<svc>_server.erl` (a `thrift_runtime_service` implementation plus the
server entry points) and `<svc>_client.erl` (typed call wrappers that
convert records at the boundary).

Forms are built with `erl_syntax` and rendered with `erl_prettypr`.
Descriptors are plain data: most function bodies are `abstract/1` of
the descriptor terms, which keeps the emitter declarative.
`compile_sources/1` compiles the same forms in memory for tests.
""".

-export([
    sources/1,
    compile_sources/1
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

%% Wire-level descriptor terms — the same shapes thrift_runtime_binary and
%% thrift_runtime_record consume.

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
                M#tg_module.name => thrift_generator_names:types_module_atom(M#tg_module.name)
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
    TypesMod = thrift_generator_names:types_module_atom(Mod#tg_module.name),
    ServiceForms = [
        thrift_generator_emitter_service:service_sources(Svc, Mod, Ctx)
     || Svc <- Mod#tg_module.services
    ],
    [
        {TypesMod, types_forms(Mod, Ctx), types_hrl_forms(Mod, Ctx)}
        | lists:append(ServiceForms)
    ] ++ thrift_generator_emitter_repr:source_forms(Mod, Ctx).

%%--------------------------------------------------------------------
%% <mod>_types.erl
%%--------------------------------------------------------------------

-spec types_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
types_forms(Mod, Ctx) ->
    TypesMod = thrift_generator_names:types_module_atom(Mod#tg_module.name),
    Plan = thrift_generator_codec_plan:build(Mod, Ctx),
    Exports =
        thrift_generator_emitter_syntax:exports_forms([
            {struct_info, 1},
            {enum_info, 1},
            {function_info, 2},
            {service_info, 0},
            {record_fields, 1},
            {encode, 2},
            {encode, 3},
            {decode, 2},
            {decode, 3},
            {convert, 3},
            {descriptor, 1}
        ]) ++
            [thrift_generator_emitter_syntax:export_type_form(type_alias_entries(Mod))] ++
            thrift_generator_emitter_syntax:exports_forms(
                thrift_generator_codec_common:export_entries(wire, Plan)
            ) ++
            thrift_generator_emitter_syntax:exports_forms(
                thrift_generator_codec:repr_encode_export_entries(Mod, Ctx) ++
                    thrift_generator_codec:repr_index_entries(Mod)
            ) ++
            thrift_generator_emitter_syntax:exports_forms(
                thrift_generator_codec_common:export_entries(compact, Plan)
            ) ++
            thrift_generator_emitter_syntax:exports_forms(
                thrift_generator_codec_common:export_entries(json, Plan)
            ) ++
            thrift_generator_emitter_syntax:exports_forms(enum_helper_entries(Mod)) ++
            thrift_generator_emitter_syntax:exports_forms(const_entries(Mod)),
    thrift_generator_emitter_syntax:header(TypesMod, Mod#tg_module.path) ++
        Exports ++
        struct_type_forms(Mod, Ctx) ++
        struct_info_forms(Mod, Ctx) ++
        enum_info_forms(Mod) ++
        function_info_forms(Mod, Ctx) ++
        service_info_forms(Mod, Ctx, Plan) ++
        record_fields_forms(Mod) ++
        schema_codec_forms(Mod, Ctx) ++
        thrift_generator_codec:module_forms(Plan) ++
        thrift_generator_codec_compact:module_forms(Plan) ++
        thrift_generator_codec_json:module_forms(Plan) ++
        enum_helper_forms(Mod) ++
        typedef_forms(Mod, Ctx) ++
        const_forms(Mod).

%%--------------------------------------------------------------------
%% Type definitions
%%--------------------------------------------------------------------

%% Every named definition exports its type alias — the original IDL name
%% as the type atom (`'TimestampInterval'()') — from the types module.
%% The hrl carries only records and constant macros, so consumers
%% reference types remotely and only records need an include.

-spec type_alias_entries(#tg_module{}) -> [{atom(), 0}].
type_alias_entries(Mod) ->
    [
        {thrift_generator_ir:type_alias(S#tg_struct.name), 0}
     || S <- Mod#tg_module.structs,
        not thrift_generator_ir:native_mode(S)
    ] ++
        [{thrift_generator_ir:type_alias(E#tg_enum.name), 0} || E <- Mod#tg_module.enums] ++
        [{thrift_generator_ir:type_alias(T#tg_typedef.name), 0} || T <- Mod#tg_module.typedefs].

%% Per struct/union/exception section: the record declaration (record
%% mode) and the exported alias — the record itself, the map shape or
%% the sum's tuple union.

-spec struct_type_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
struct_type_forms(Mod, Ctx) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(thrift_generator_ir:section_label(S))] ++
            struct_type_one(S, Mod#tg_module.prefix, Ctx)
     || S <- Mod#tg_module.structs
    ]).

-spec struct_type_one(#tg_struct{}, binary(), #ectx{}) -> erl_syntax:forms().
struct_type_one(S, Prefix, Ctx) ->
    Anno = erl_anno:new(0),
    RecordForm =
        case thrift_generator_ir:has_record(S) of
            true -> thrift_generator_emitter_record:record_form(S, Prefix, Ctx);
            false -> []
        end,
    AliasForm =
        case alias_type_node(S, Ctx) of
            undefined -> [];
            Node -> [{attribute, Anno, type, {thrift_generator_ir:type_alias(S#tg_struct.name), Node, []}}]
        end,
    RecordForm ++ AliasForm.

%% The type a struct alias names: the record itself in record mode, the
%% map shape in map mode, the variant tuples in sum mode. Native-mode
%% structs declare no alias — their values are runtime-minted records.

-spec alias_type_node(#tg_struct{}, #ectx{}) -> erl_syntax:syntaxTree() | undefined.
alias_type_node(S, Ctx) ->
    case thrift_generator_ir:mode(S) of
        sum ->
            sum_type_node(S, Ctx);
        record ->
            Tag = thrift_generator_ir:record_tag_of(S, thrift_generator_names:current_prefix(Ctx)),
            {type, erl_anno:new(0), record, [{atom, erl_anno:new(0), Tag}]};
        native ->
            undefined;
        map ->
            map_type_node(S, Ctx)
    end.

%% The map shape of a map-mode struct: required fields exact (`:=`),
%% everything else associative (`=>`). Binary-keyed maps carry wire
%% names, not field atoms, so per-field requiredness is not expressible.

-spec map_type_node(#tg_struct{}, #ectx{}) -> erl_syntax:syntaxTree().
map_type_node(S, Ctx) ->
    Anno = erl_anno:new(0),
    case thrift_generator_ir:map_key_type(S) of
        binary ->
            {type, Anno, map, [
                {type, Anno, map_field_assoc, [{type, Anno, binary, []}, {type, Anno, term, []}]}
            ]};
        atom ->
            {type, Anno, map, [
                {type, Anno,
                    case F#tg_field.required of
                        required -> map_field_exact;
                        _ -> map_field_assoc
                    end,
                    field_type_pair(F, Ctx)}
             || F <- S#tg_struct.fields
            ]}
    end.

%% The per-field type node: the field atom with its emitted type —
%% shared by the map shape and the sum tuples.

-spec field_type_pair(#tg_field{}, #ectx{}) -> [erl_syntax:syntaxTree()].
field_type_pair(F, Ctx) ->
    [
        {atom, erl_anno:new(0), thrift_generator_ir:field_atom(F#tg_field.name)},
        thrift_generator_ir:erlang_type(F#tg_field.type, Ctx)
    ].

-spec typedef_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
typedef_forms(Mod, Ctx) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(thrift_generator_ir:section_label(T))] ++ typedef_one(T, Ctx)
     || T <- Mod#tg_module.typedefs
    ]).

%% `erl.type = "nominal"' turns the alias into a distinct -nominal type.

-spec typedef_one(#tg_typedef{}, #ectx{}) -> erl_syntax:forms().
typedef_one(T, Ctx) ->
    Anno = erl_anno:new(0),
    Keyword =
        case maps:get(type, T#tg_typedef.erl, undefined) of
            <<"nominal">> ->
                nominal;
            _ ->
                type
        end,
    [
        {attribute, Anno, Keyword,
            {
                thrift_generator_ir:type_alias(T#tg_typedef.name),
                thrift_generator_ir:erlang_type(T#tg_typedef.type, Ctx),
                []
            }}
    ].

%%--------------------------------------------------------------------
%% <mod>_types.hrl
%%--------------------------------------------------------------------

%% The include consumers bring in: typed record declarations and macros
%% for scalar constants. Type definitions live in the types module and
%% are referenced remotely from here, so no include chain is needed.
%% Records are also declared inline in the .erl (compile_sources runs
%% without includes), so the two files must never both be included into
%% one compilation.

-spec types_hrl_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
types_hrl_forms(Mod, Ctx) ->
    Guard = hrl_guard(Mod),
    [
        thrift_generator_emitter_syntax:banner_comment(Mod#tg_module.path),
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
        hrl_const_forms(Mod) ++
        [
            {raw_text, <<"-endif.\n">>}
        ].

-spec hrl_guard(#tg_module{}) -> atom().
hrl_guard(Mod) ->
    Sanitized = binary:replace(Mod#tg_module.name, <<".">>, <<"_">>, [global]),
    binary_to_atom(<<(string:uppercase(Sanitized))/binary, "_HRL">>, utf8).

-spec hrl_record_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
hrl_record_forms(Mod, Ctx) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(thrift_generator_ir:section_label(S))] ++
            doc_comment_forms(S#tg_struct.doc) ++
            thrift_generator_emitter_record:record_form(S, Mod#tg_module.prefix, Ctx#ectx{qualify = true})
     || S <- Mod#tg_module.structs,
        thrift_generator_ir:has_record(S)
    ]).

%% The struct's IDL doc comment above its hrl record declaration: the
%% direct codec functions are internal (`-doc false`) and the type-first
%% facade is module-level, so the record is the per-struct public
%% surface left to carry it.

-spec doc_comment_forms(binary() | undefined) -> erl_syntax:forms().
doc_comment_forms(undefined) ->
    [];
doc_comment_forms(Doc) ->
    Lines = binary:split(Doc, <<"\n">>, [global]),
    [erl_syntax:comment([["% ", unicode:characters_to_list(Line)] || Line <- Lines])].

%% The sum type of a `erl.union_type = "sum"' union: one {Tag, Payload}
%% tuple per field, payload types inline.

-spec sum_type_node(#tg_struct{}, #ectx{}) -> erl_syntax:syntaxTree().
sum_type_node(S, Ctx) ->
    Anno = erl_anno:new(0),
    Tuples = [
        {type, Anno, tuple, field_type_pair(F, Ctx)}
     || F <- S#tg_struct.fields
    ],
    case Tuples of
        [One] -> One;
        Many -> {type, Anno, union, Many}
    end.

-spec enum_type_node(#tg_enum{}) -> erl_syntax:syntaxTree().
enum_type_node(E) ->
    Anno = erl_anno:new(0),
    Atoms = [
        {atom, Anno, thrift_generator_ir:enum_atom(Name, thrift_generator_ir:enum_case(E))}
     || {_Value, Name} <- E#tg_enum.values
    ],
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
                thrift_generator_emitter_record:const_literal(C#tg_const.value)
            ])
        ]
     || C <- Mod#tg_module.consts,
        scalar_const(C)
    ]).

%% The constant macro mirrors the (prefixed) function name, macro-style:
%% the whole name — namespace prefix and snake-cased IDL name — is
%% uppercased (DEMO_KIND_VALUE).

-spec const_macro_name(binary(), binary()) -> binary().
const_macro_name(Prefix, Name) ->
    string:uppercase(thrift_generator_names:typed_prefix(Prefix, thrift_generator_names:snake(Name))).

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
%% Type-first schema codec facade
%%--------------------------------------------------------------------

%% The public codec surface of a types module: one `encode', `decode'
%% and `convert' per module, keyed by the canonical type atom — the
%% snake-cased IDL name without the namespace prefix (the module name
%% already namespaces). Every clause embeds the struct's named-ref
%% descriptor literally: binary calls engage the runtime's one-pass
%% repr codecs directly, with no map lookup by type atom. Unknown types
%% answer `{unknown_type, Type}'; a non-map options argument answers
%% the documented bad_option error instead of crashing on map
%% operations.

-spec schema_codec_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
schema_codec_forms(Mod, Ctx) ->
    Structs = Mod#tg_module.structs,
    [thrift_generator_emitter_syntax:section_form("Schema codec facade")] ++
        facade_encode_forms(Structs, Ctx) ++
        facade_decode_forms(Structs, Ctx) ++
        facade_convert_forms(Structs, Ctx) ++
        facade_descriptor_forms(Structs, Ctx).

%% The canonical type atom: the snake-cased IDL name as an atom, with no
%% namespace prefix — `PingRequest' -> `ping_request' in any module.

-spec facade_type(#tg_struct{}) -> atom().
facade_type(S) ->
    binary_to_atom(thrift_generator_names:snake(S#tg_struct.name), utf8).

%% The schema-selected default representation of a decode without an
%% explicit `repr' option: a sum union has no record, so its default is
%% the tagged tuple through the `record' axis; map-mode structs default
%% to their atom-keyed map, native-mode structs to the runtime-minted
%% native record.

-spec facade_default_repr(#tg_struct{}) -> record | native | map.
facade_default_repr(S) ->
    case thrift_generator_ir:mode(S) of
        sum -> record;
        record -> record;
        native -> native;
        map -> map
    end.

%% The result type of a default-representation decode: the definition's
%% own alias (the record, the map shape or the sum's tuple union), with
%% the runtime-minted native record staying opaque.

-spec facade_default_type(#tg_struct{}) -> erl_syntax:syntaxTree().
facade_default_type(S) ->
    case thrift_generator_ir:native_mode(S) of
        true -> thrift_generator_emitter_syntax:term_type();
        false -> thrift_generator_emitter_syntax:user_type(thrift_generator_ir:type_alias(S#tg_struct.name))
    end.

%% A literal atom type node (`inner') for the overloaded facade specs.

-spec facade_type_node(erl_anno:anno(), #tg_struct{}) -> erl_syntax:syntaxTree().
facade_type_node(Anno, S) ->
    {atom, Anno, facade_type(S)}.

-spec is_map_guard(erl_syntax:syntaxTree()) -> [[erl_syntax:syntaxTree()]].
is_map_guard(Var) ->
    [[erl_syntax:application(erl_syntax:atom(is_map), [Var])]].

-spec unknown_type_error(string()) -> erl_syntax:syntaxTree().
unknown_type_error(Var) ->
    erl_syntax:tuple([
        erl_syntax:atom(error),
        erl_syntax:tuple([erl_syntax:atom(unknown_type), erl_syntax:variable(Var)])
    ]).

%% The Task 1 documented error for a non-map options argument.

-spec bad_options_error() -> erl_syntax:syntaxTree().
bad_options_error() ->
    erl_syntax:tuple([
        erl_syntax:atom(error),
        erl_syntax:tuple([
            erl_syntax:atom(bad_option),
            erl_syntax:tuple([
                erl_syntax:atom(options),
                erl_syntax:variable("Options"),
                erl_syntax:list([erl_syntax:atom(map)])
            ])
        ])
    ]).

-spec facade_encode_forms([#tg_struct{}], #ectx{}) -> erl_syntax:forms().
facade_encode_forms(Structs, Ctx) ->
    Anno = erl_anno:new(0),
    Result = thrift_generator_emitter_syntax:ok_error_type(
        Anno, {type, Anno, binary, []}, thrift_generator_emitter_syntax:error_term_type(Anno)
    ),
    Spec2 =
        {attribute, Anno, spec, {
            {encode, 2},
            [
                thrift_generator_emitter_syntax:fun_type(
                    [facade_type_node(Anno, S), value_type(S)], Result
                )
             || S <- Structs
            ] ++
                [
                    thrift_generator_emitter_syntax:fun_type(
                        [{type, Anno, atom, []}, thrift_generator_emitter_syntax:raw_type(term)],
                        Result
                    )
                ]
        }},
    Spec3 =
        {attribute, Anno, spec, {
            {encode, 3},
            [
                thrift_generator_emitter_syntax:fun_type(
                    [facade_type_node(Anno, S), value_type(S), thrift_generator_emitter_syntax:raw_type(map)],
                    Result
                )
             || S <- Structs
            ] ++
                [
                    thrift_generator_emitter_syntax:fun_type(
                        [
                            {type, Anno, atom, []},
                            thrift_generator_emitter_syntax:raw_type(term),
                            thrift_generator_emitter_syntax:raw_type(term)
                        ],
                        Result
                    )
                ]
        }},
    thrift_generator_emitter_syntax:doc_form(
        undefined,
        <<
            "Encodes `Value` of the struct selected by `Type` with the binary"
            " protocol; `encode/3` with default options."
        >>
    ) ++
        [Spec2] ++
        thrift_generator_emitter_syntax:fn_form(encode, [
            thrift_generator_emitter_syntax:fn_clause(
                [erl_syntax:variable("Type"), erl_syntax:variable("Value")],
                erl_syntax:application(erl_syntax:atom(encode), [
                    erl_syntax:variable("Type"),
                    erl_syntax:variable("Value"),
                    thrift_generator_emitter_syntax:abstract(#{})
                ])
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            undefined,
            <<
                "Encodes `Value` of the struct selected by `Type`. Options: `protocol`"
                " (default `binary`) and `strict` (default `false`); an unknown"
                " `Type` answers `{error, {unknown_type, Type}}`."
            >>
        ) ++
        [Spec3] ++
        thrift_generator_emitter_syntax:fn_form(
            encode,
            [
                erl_syntax:clause(
                    [
                        thrift_generator_emitter_syntax:abstract(facade_type(S)),
                        erl_syntax:variable("Value"),
                        erl_syntax:variable("Options")
                    ],
                    is_map_guard(erl_syntax:variable("Options")),
                    [
                        thrift_generator_emitter_syntax:application(thrift_runtime, encode, [
                            thrift_generator_emitter_syntax:abstract(struct_ref(S, Ctx)),
                            erl_syntax:variable("Value"),
                            erl_syntax:variable("Options")
                        ])
                    ]
                )
             || S <- Structs
            ] ++
                [
                    erl_syntax:clause(
                        [
                            erl_syntax:variable("Type"),
                            erl_syntax:variable("_Value"),
                            erl_syntax:variable("Options")
                        ],
                        is_map_guard(erl_syntax:variable("Options")),
                        [unknown_type_error("Type")]
                    ),
                    thrift_generator_emitter_syntax:fn_clause(
                        [
                            erl_syntax:variable("_Type"),
                            erl_syntax:variable("_Value"),
                            erl_syntax:variable("Options")
                        ],
                        bad_options_error()
                    )
                ]
        ).

-spec facade_decode_forms([#tg_struct{}], #ectx{}) -> erl_syntax:forms().
facade_decode_forms(Structs, Ctx) ->
    Anno = erl_anno:new(0),
    Err = thrift_generator_emitter_syntax:error_term_type(Anno),
    Result = thrift_generator_emitter_syntax:ok_error_type(
        Anno, thrift_generator_emitter_syntax:term_type(), Err
    ),
    Binary = {type, Anno, binary, []},
    Spec2 =
        {attribute, Anno, spec, {
            {decode, 2},
            [
                thrift_generator_emitter_syntax:fun_type(
                    [facade_type_node(Anno, S), Binary],
                    thrift_generator_emitter_syntax:ok_error_type(Anno, facade_default_type(S), Err)
                )
             || S <- Structs
            ] ++
                [
                    thrift_generator_emitter_syntax:fun_type(
                        [{type, Anno, atom, []}, Binary], Result
                    )
                ]
        }},
    Spec3 =
        {attribute, Anno, spec,
            {
                {decode, 3},
                [
                    thrift_generator_emitter_syntax:fun_type(
                        [{type, Anno, atom, []}, Binary, thrift_generator_emitter_syntax:raw_type(map)],
                        Result
                    ),
                    thrift_generator_emitter_syntax:fun_type(
                        [
                            {type, Anno, atom, []},
                            Binary,
                            thrift_generator_emitter_syntax:raw_type(term)
                        ],
                        Result
                    )
                ]
            }},
    thrift_generator_emitter_syntax:doc_form(
        undefined,
        <<
            "Decodes the whole binary into the struct's default representation;"
            " `decode/3` with default options. Trailing bytes or truncation"
            " fail the decode."
        >>
    ) ++
        [Spec2] ++
        thrift_generator_emitter_syntax:fn_form(decode, [
            thrift_generator_emitter_syntax:fn_clause(
                [erl_syntax:variable("Type"), erl_syntax:variable("Binary")],
                erl_syntax:application(erl_syntax:atom(decode), [
                    erl_syntax:variable("Type"),
                    erl_syntax:variable("Binary"),
                    thrift_generator_emitter_syntax:abstract(#{})
                ])
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            undefined,
            <<
                "Decodes the whole binary into representation `repr` (default: the"
                " struct's schema-selected representation) with the given `protocol`"
                " (default `binary`). Trailing bytes or truncation fail the decode."
            >>
        ) ++
        [Spec3] ++
        thrift_generator_emitter_syntax:fn_form(
            decode,
            lists:append([
                [
                    %% repr present: the caller's map passes through
                    %% unchanged, no merge and no copy
                    erl_syntax:clause(
                        [
                            thrift_generator_emitter_syntax:abstract(facade_type(S)),
                            erl_syntax:variable("Binary"),
                            erl_syntax:match_expr(
                                erl_syntax:variable("Options"),
                                erl_syntax:map_expr([
                                    erl_syntax:map_field_exact(
                                        erl_syntax:atom(repr), erl_syntax:underscore()
                                    )
                                ])
                            )
                        ],
                        none,
                        [facade_decode_call(S, Ctx, erl_syntax:variable("Options"))]
                    ),
                    %% repr absent: the schema default goes in through a
                    %% literal update
                    erl_syntax:clause(
                        [
                            thrift_generator_emitter_syntax:abstract(facade_type(S)),
                            erl_syntax:variable("Binary"),
                            erl_syntax:variable("Options")
                        ],
                        is_map_guard(erl_syntax:variable("Options")),
                        [
                            facade_decode_call(
                                S,
                                Ctx,
                                erl_syntax:map_expr(
                                    erl_syntax:variable("Options"),
                                    [
                                        erl_syntax:map_field_assoc(
                                            erl_syntax:atom(repr),
                                            thrift_generator_emitter_syntax:abstract(facade_default_repr(S))
                                        )
                                    ]
                                )
                            )
                        ]
                    )
                ]
             || S <- Structs
            ]) ++
                [
                    erl_syntax:clause(
                        [
                            erl_syntax:variable("Type"),
                            erl_syntax:variable("_Binary"),
                            erl_syntax:variable("Options")
                        ],
                        is_map_guard(erl_syntax:variable("Options")),
                        [unknown_type_error("Type")]
                    ),
                    thrift_generator_emitter_syntax:fn_clause(
                        [
                            erl_syntax:variable("_Type"),
                            erl_syntax:variable("_Binary"),
                            erl_syntax:variable("Options")
                        ],
                        bad_options_error()
                    )
                ]
        ).

%% The facade decode body shared by both option paths: the descriptor is
%% schema-fixed, only the options argument differs (pass-through vs the
%% literal default update).

-spec facade_decode_call(#tg_struct{}, #ectx{}, erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
facade_decode_call(S, Ctx, OptionsTree) ->
    thrift_generator_emitter_syntax:application(thrift_runtime, decode, [
        thrift_generator_emitter_syntax:abstract(struct_ref(S, Ctx)),
        erl_syntax:variable("Binary"),
        OptionsTree
    ]).

-spec facade_convert_forms([#tg_struct{}], #ectx{}) -> erl_syntax:forms().
facade_convert_forms(Structs, Ctx) ->
    Anno = erl_anno:new(0),
    Err = thrift_generator_emitter_syntax:error_term_type(Anno),
    Result = thrift_generator_emitter_syntax:ok_error_type(
        Anno, thrift_generator_emitter_syntax:term_type(), Err
    ),
    Spec =
        {attribute, Anno, spec,
            {
                {convert, 3},
                [
                    thrift_generator_emitter_syntax:fun_type(
                        [
                            {type, Anno, atom, []},
                            thrift_generator_emitter_syntax:raw_type(term),
                            thrift_generator_emitter_syntax:remote_type(thrift_runtime, repr)
                        ],
                        Result
                    )
                ]
            }},
    thrift_generator_emitter_syntax:doc_form(
        undefined,
        <<
            "Reshapes a typed value (record, struct-map or native record, nested"
            " structures included) of the struct selected by `Type` into `Repr`,"
            " without touching bytes."
        >>
    ) ++
        [Spec] ++
        thrift_generator_emitter_syntax:fn_form(
            convert,
            [
                thrift_generator_emitter_syntax:fn_clause(
                    [
                        thrift_generator_emitter_syntax:abstract(facade_type(S)),
                        erl_syntax:variable("Value"),
                        erl_syntax:variable("Repr")
                    ],
                    thrift_generator_emitter_syntax:application(thrift_runtime, convert, [
                        thrift_generator_emitter_syntax:abstract(struct_ref(S, Ctx)),
                        erl_syntax:variable("Value"),
                        erl_syntax:variable("Repr")
                    ])
                )
             || S <- Structs
            ] ++
                [
                    thrift_generator_emitter_syntax:fn_clause(
                        [
                            erl_syntax:variable("Type"),
                            erl_syntax:variable("_Value"),
                            erl_syntax:variable("_Repr")
                        ],
                        unknown_type_error("Type")
                    )
                ]
        ).

-spec facade_descriptor_forms([#tg_struct{}], #ectx{}) -> erl_syntax:forms().
facade_descriptor_forms(Structs, Ctx) ->
    Anno = erl_anno:new(0),
    UnknownType =
        {type, Anno, tuple, [
            {atom, Anno, error},
            {type, Anno, tuple, [
                {atom, Anno, unknown_type}, {type, Anno, atom, []}
            ]}
        ]},
    Result =
        {type, Anno, union, [
            {type, Anno, tuple, [
                {atom, Anno, ok},
                thrift_generator_emitter_syntax:remote_type(thrift_runtime_protocol, type_desc)
            ]},
            UnknownType
        ]},
    Spec =
        {attribute, Anno, spec,
            {
                {descriptor, 1},
                [thrift_generator_emitter_syntax:fun_type([{type, Anno, atom, []}], Result)]
            }},
    thrift_generator_emitter_syntax:doc_form(
        undefined,
        <<
            "Returns the named-ref descriptor `thrift_runtime` consumes for `Type`,"
            " or `{error, {unknown_type, Type}}`."
        >>
    ) ++
        [Spec] ++
        thrift_generator_emitter_syntax:fn_form(
            descriptor,
            [
                thrift_generator_emitter_syntax:fn_clause(
                    [thrift_generator_emitter_syntax:abstract(facade_type(S))],
                    erl_syntax:tuple([
                        erl_syntax:atom(ok),
                        thrift_generator_emitter_syntax:abstract(struct_ref(S, Ctx))
                    ])
                )
             || S <- Structs
            ] ++
                [
                    thrift_generator_emitter_syntax:fn_clause(
                        [erl_syntax:variable("Type")],
                        unknown_type_error("Type")
                    )
                ]
        ).
-spec struct_ref(#tg_struct{}, #ectx{}) -> desc().
struct_ref(S, Ctx) ->
    {struct, {ref, thrift_generator_names:types_module_atom(Ctx#ectx.current), S#tg_struct.name}}.

%% The input side of encode: the definition's exported alias (record,
%% map and sum modes); native records are runtime-minted, so their input
%% stays term(). Record mode also accepts the wire-shaped map — both
%% normalize inside thrift_runtime_record:to_wire.

-spec value_type(#tg_struct{}) -> erl_syntax:syntaxTree().
value_type(S) ->
    Alias = thrift_generator_emitter_syntax:user_type(thrift_generator_ir:type_alias(S#tg_struct.name)),
    case thrift_generator_ir:mode(S) of
        record ->
            {type, erl_anno:new(0), union, [Alias, thrift_generator_emitter_syntax:raw_type(map)]};
        native ->
            thrift_generator_emitter_syntax:raw_type(term);
        sum ->
            Alias;
        map ->
            Alias
    end.

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
        Prefix <- [
            thrift_generator_names:typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(E#tg_enum.name))
        ]
    ]).

-spec enum_helper_forms(#tg_module{}) -> erl_syntax:forms().
enum_helper_forms(Mod) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(thrift_generator_ir:section_label(E))] ++
            [
                {attribute, erl_anno:new(0), type,
                    {thrift_generator_ir:type_alias(E#tg_enum.name), enum_type_node(E), []}}
            ] ++
            enum_helper_one(
                E,
                thrift_generator_names:typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(E#tg_enum.name))
            )
     || E <- Mod#tg_module.enums
    ]).

-spec enum_helper_one(#tg_enum{}, binary()) -> erl_syntax:forms().
enum_helper_one(E, Prefix) ->
    ToInt = binary_to_atom(<<Prefix/binary, "_to_int">>, utf8),
    FromInt = binary_to_atom(<<Prefix/binary, "_from_int">>, utf8),
    %% The literal descriptor — the same list enum_info/1 returns — so
    %% the helpers do not even call themselves.
    DescExpr = thrift_generator_emitter_syntax:abstract(thrift_generator_ir:enum_desc(E)),
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
        {
            binary_to_atom(
                thrift_generator_names:typed_prefix(
                    Mod#tg_module.prefix, thrift_generator_names:snake(C#tg_const.name)
                ),
                utf8
            ),
            0
        }
     || C <- Mod#tg_module.consts
    ].

-spec const_forms(#tg_module{}) -> erl_syntax:forms().
const_forms(Mod) ->
    lists:append([
        thrift_generator_emitter_syntax:doc_form(C#tg_const.doc, <<"The constant's value as declared in the IDL.">>) ++
            [
                {attribute, erl_anno:new(0), spec,
                    {{const_name(Mod, C), 0}, [
                        thrift_generator_emitter_syntax:fun_type([], const_spec_type(C#tg_const.type))
                    ]}}
            ] ++
            thrift_generator_emitter_syntax:fn_form(const_name(Mod, C), [
                thrift_generator_emitter_syntax:fn_clause(
                    [], thrift_generator_emitter_record:const_literal(C#tg_const.value)
                )
            ])
     || C <- Mod#tg_module.consts
    ]).

-spec const_name(#tg_module{}, #tg_const{}) -> atom().
const_name(Mod, C) ->
    binary_to_atom(
        thrift_generator_names:typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(C#tg_const.name)),
        utf8
    ).

%% Constant spec types without a resolution context: refs (enum
%% members) surface as term, containers mirror erlang_type/2.

-spec const_spec_type(resolved_thrift_type()) -> erl_syntax:syntaxTree().
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
const_spec_type({resolved_ref, _, _, _}) ->
    thrift_generator_emitter_syntax:raw_type(term).

%%--------------------------------------------------------------------
%% Introspection forms
%%--------------------------------------------------------------------

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
    {S#tg_struct.kind, [thrift_generator_ir:field_desc(F, Ctx) || F <- S#tg_struct.fields]}.

-spec enum_info_forms(#tg_module{}) -> erl_syntax:forms().
enum_info_forms(Mod) ->
    Clauses = [
        thrift_generator_emitter_syntax:fn_clause(
            [thrift_generator_emitter_syntax:abstract(E#tg_enum.name)],
            thrift_generator_emitter_syntax:abstract(thrift_generator_ir:enum_desc(E))
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
                    thrift_generator_emitter_syntax:abstract(thrift_generator_ir:params_desc(F, Ctx))
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
                    thrift_generator_emitter_syntax:abstract(thrift_generator_ir:reply_desc(F, Ctx))
                ),
                thrift_generator_emitter_syntax:fn_clause(
                    [
                        thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                        thrift_generator_emitter_syntax:abstract(exceptions)
                    ],
                    thrift_generator_emitter_syntax:abstract(thrift_generator_ir:exceptions_desc(F, Ctx))
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

%% Same-named methods across a module's services are legal Thrift and
%% common in the wild (per-service `GetEvents'), but function_info/2 is
%% method-name keyed — duplicate clauses could not even compile, so the
%% last declaration wins. Generated clients do not resolve through this
%% table: each wrapper embeds its own service's descriptors, so a
%% collision affects introspection only.

-spec service_functions(#tg_module{}) -> [#tg_function{}].
service_functions(Mod) ->
    All = lists:append([S#tg_service.functions || S <- Mod#tg_module.services]),
    {Kept, _Seen} =
        lists:foldr(
            fun(F, {KeptAcc, Seen}) ->
                case maps:is_key(F#tg_function.name, Seen) of
                    true -> {KeptAcc, Seen};
                    false -> {[F | KeptAcc], Seen#{F#tg_function.name => true}}
                end
            end,
            {[], #{}},
            All
        ),
    Kept.

-spec service_info_forms(#tg_module{}, #ectx{}, #tg_codec_plan{}) -> erl_syntax:forms().
service_info_forms(Mod, Ctx, Plan) ->
    TypesMod = thrift_generator_names:types_module_atom(Mod#tg_module.name),
    Entries = [
        {S#tg_service.name, service_entry(S#tg_service.name, S#tg_service.functions, TypesMod, Ctx, #{}, Plan)}
     || S <- Mod#tg_module.services
    ],
    thrift_generator_emitter_syntax:fn_form(service_info, [
        thrift_generator_emitter_syntax:fn_clause([], thrift_generator_emitter_syntax:abstract(maps:from_list(Entries)))
    ]).

-spec service_entry(binary(), [#tg_function{}], module(), #ectx{}, map(), #tg_codec_plan{}) -> map().
service_entry(_SvcName, [], _TypesMod, _Ctx, Acc, _Plan) ->
    Acc;
service_entry(SvcName, [F | Rest], TypesMod, Ctx, Acc, Plan) ->
    Info0 = #{
        name => F#tg_function.name,
        oneway => F#tg_function.oneway,
        params => thrift_generator_ir:params_desc(F, Ctx),
        codecs => rpc_codecs(SvcName, F, TypesMod, Plan)
    },
    Info1 =
        case thrift_generator_ir:reply_desc(F, Ctx) of
            undefined -> Info0;
            Reply -> Info0#{reply => Reply}
        end,
    Info =
        case thrift_generator_ir:exceptions_desc(F, Ctx) of
            [] -> Info1;
            Exceptions -> Info1#{exceptions => Exceptions}
        end,
    service_entry(SvcName, Rest, TypesMod, Ctx, Acc#{F#tg_function.name => Info}, Plan).

%% The specialized RPC codec hooks of one function, keyed by the
%% runtime protocol module: the runtime picks the entry of its protocol
%% and calls the params/result codecs directly, falling back to the
%% descriptor path when the key or the protocol is absent (hand-written
%% service modules, custom protocols).

-spec rpc_codecs(binary(), #tg_function{}, module(), #tg_codec_plan{}) -> map().
rpc_codecs(SvcName, F, TypesMod, Plan) ->
    maps:from_list([
        rpc_codec_entry(Protocol, SvcName, F, TypesMod, Plan)
     || Protocol <- [wire, compact, json]
    ]).

-spec rpc_codec_entry(wire | compact | json, binary(), #tg_function{}, module(), #tg_codec_plan{}) ->
    {module(), map()}.
rpc_codec_entry(Protocol, SvcName, F, TypesMod, Plan) ->
    {EncParams, DecParams} = thrift_generator_codec_plan:codec_pair(
        Protocol, thrift_generator_codec_common:rpc_struct_name(SvcName, F#tg_function.name, params), Plan
    ),
    Entry = #{params => {TypesMod, EncParams, DecParams}},
    Full =
        case F#tg_function.oneway of
            true ->
                Entry;
            false ->
                {EncResult, DecResult} = thrift_generator_codec_plan:codec_pair(
                    Protocol, thrift_generator_codec_common:rpc_struct_name(SvcName, F#tg_function.name, result), Plan
                ),
                Entry#{result => {TypesMod, EncResult, DecResult}}
        end,
    {rpc_protocol_module(Protocol), Full}.

-spec rpc_protocol_module(wire | compact | json) -> module().
rpc_protocol_module(wire) -> thrift_runtime_binary;
rpc_protocol_module(compact) -> thrift_runtime_compact;
rpc_protocol_module(json) -> thrift_runtime_json.

-spec record_fields_forms(#tg_module{}) -> erl_syntax:forms().
record_fields_forms(Mod) ->
    Clauses = [
        thrift_generator_emitter_syntax:fn_clause(
            [thrift_generator_emitter_syntax:abstract(S#tg_struct.name)],
            thrift_generator_emitter_syntax:abstract(fields_decl(S, Mod#tg_module.prefix))
        )
     || S <- Mod#tg_module.structs
    ],
    thrift_generator_emitter_syntax:doc_false_form() ++
        thrift_generator_emitter_syntax:fn_form(
            record_fields,
            Clauses ++
                [
                    thrift_generator_emitter_syntax:fn_clause(
                        [thrift_generator_emitter_syntax:wildcard()],
                        thrift_generator_emitter_syntax:abstract(none)
                    )
                ]
        ).

%% The record_fields contract: record mode answers {Tag, FieldAtoms},
%% map mode answers {map, KeyType} (default atom keys), sum unions
%% answer {sum, FieldAtoms} — the runtime converts their {Tag, Value}
%% tuples by matching the atom against the field list; native mode
%% answers {native, Tag} — the tag runtime-minted records carry; structs
%% with no clause fall through to `none' — the wire passthrough.

-spec fields_decl(#tg_struct{}, binary()) ->
    {atom(), [atom()]} | {map, atom | binary} | {native, atom}.
fields_decl(S, Prefix) ->
    case thrift_generator_ir:mode(S) of
        sum ->
            {sum, [thrift_generator_ir:field_atom(F#tg_field.name) || F <- S#tg_struct.fields]};
        record ->
            {thrift_generator_ir:record_tag_of(S, Prefix), [
                thrift_generator_ir:field_atom(F#tg_field.name)
             || F <- S#tg_struct.fields
            ]};
        native ->
            %% No record declaration exists: the runtime mints native
            %% records under the snake-cased wire name.
            {native, binary_to_atom(thrift_generator_names:snake(S#tg_struct.name), utf8)};
        map ->
            {map, thrift_generator_ir:map_key_type(S)}
    end.

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
