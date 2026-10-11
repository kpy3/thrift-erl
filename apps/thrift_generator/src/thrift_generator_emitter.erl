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
record-field index (`record_fields/1`) that `thrift_erl_record` uses
to bridge records and the wire.

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
    has_record/1,
    record_form/3,
    sanitize/1,
    section_label/1,
    sum_mode/1,
    type_desc/2
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
    Exports =
        thrift_generator_emitter_syntax:exports_forms([
            {struct_info, 1},
            {enum_info, 1},
            {function_info, 2},
            {service_info, 0},
            {record_fields, 1},
            {tag_index, 0},
            {convert, 2}
        ]) ++
            [thrift_generator_emitter_syntax:export_type_form(type_alias_entries(Mod))] ++
            thrift_generator_emitter_syntax:exports_forms(struct_codec_entries(Mod)) ++
            thrift_generator_emitter_syntax:exports_forms(thrift_generator_codec:export_entries(Mod, Ctx)) ++
            thrift_generator_emitter_syntax:exports_forms(thrift_generator_codec_compact:export_entries(Mod, Ctx)) ++
            thrift_generator_emitter_syntax:exports_forms(thrift_generator_codec_json:export_entries(Mod, Ctx)) ++
            thrift_generator_emitter_syntax:exports_forms(enum_helper_entries(Mod)) ++
            thrift_generator_emitter_syntax:exports_forms(const_entries(Mod)),
    thrift_generator_emitter_syntax:header(TypesMod, Mod#tg_module.path) ++
        Exports ++
        struct_type_forms(Mod, Ctx) ++
        struct_info_forms(Mod, Ctx) ++
        enum_info_forms(Mod) ++
        function_info_forms(Mod, Ctx) ++
        service_info_forms(Mod, Ctx) ++
        record_fields_forms(Mod) ++
        struct_codec_forms(Mod, Ctx) ++
        thrift_generator_codec:module_forms(Mod, Ctx) ++
        thrift_generator_codec_compact:module_forms(Mod, Ctx) ++
        thrift_generator_codec_json:module_forms(Mod, Ctx) ++
        tag_index_forms(Mod, Ctx) ++
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
        {type_alias(S#tg_struct.name), 0}
     || S <- Mod#tg_module.structs,
        not native_mode(S)
    ] ++
        [{type_alias(E#tg_enum.name), 0} || E <- Mod#tg_module.enums] ++
        [{type_alias(T#tg_typedef.name), 0} || T <- Mod#tg_module.typedefs].

-spec type_alias(binary()) -> atom().
type_alias(Name) ->
    binary_to_atom(Name, utf8).

%% Per struct/union/exception section: the record declaration (record
%% mode) and the exported alias — the record itself, the map shape or
%% the sum's tuple union.

-spec struct_type_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
struct_type_forms(Mod, Ctx) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(section_label(S))] ++
            struct_type_one(S, Mod#tg_module.prefix, Ctx)
     || S <- Mod#tg_module.structs
    ]).

-spec struct_type_one(#tg_struct{}, binary(), #ectx{}) -> erl_syntax:forms().
struct_type_one(S, Prefix, Ctx) ->
    Anno = erl_anno:new(0),
    RecordForm =
        case has_record(S) of
            true -> record_form(S, Prefix, Ctx);
            false -> []
        end,
    AliasForm =
        case alias_type_node(S, Ctx) of
            undefined -> [];
            Node -> [{attribute, Anno, type, {type_alias(S#tg_struct.name), Node, []}}]
        end,
    RecordForm ++ AliasForm.

%% The type a struct alias names: the record itself in record mode, the
%% map shape in map mode, the variant tuples in sum mode. Native-mode
%% structs declare no alias — their values are runtime-minted records.

-spec alias_type_node(#tg_struct{}, #ectx{}) -> erl_syntax:syntaxTree() | undefined.
alias_type_node(S, Ctx) ->
    case {sum_mode(S), record_mode(S), native_mode(S)} of
        {true, _, _} ->
            sum_type_node(S, Ctx);
        {false, true, _} ->
            Tag = record_tag(current_prefix(Ctx), S#tg_struct.name),
            {type, erl_anno:new(0), record, [{atom, erl_anno:new(0), Tag}]};
        {false, false, true} ->
            undefined;
        {false, false, false} ->
            map_type_node(S, Ctx)
    end.

%% The map shape of a map-mode struct: required fields exact (`:=`),
%% everything else associative (`=>`). Binary-keyed maps carry wire
%% names, not field atoms, so per-field requiredness is not expressible.

-spec map_type_node(#tg_struct{}, #ectx{}) -> erl_syntax:syntaxTree().
map_type_node(S, Ctx) ->
    Anno = erl_anno:new(0),
    case map_key_type(S) of
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
    [{atom, erl_anno:new(0), field_atom(F#tg_field.name)}, erlang_type(F#tg_field.type, Ctx)].

-spec typedef_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
typedef_forms(Mod, Ctx) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(section_label(T))] ++ typedef_one(T, Ctx)
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
        {attribute, Anno, Keyword, {type_alias(T#tg_typedef.name), erlang_type(T#tg_typedef.type, Ctx), []}}
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
        [thrift_generator_emitter_syntax:section_form(section_label(S))] ++
            record_form(S, Mod#tg_module.prefix, Ctx#ectx{qualify = true})
     || S <- Mod#tg_module.structs,
        has_record(S)
    ]).

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
%% the whole name — namespace prefix and snake-cased IDL name — is
%% uppercased (DEMO_KIND_VALUE).

-spec const_macro_name(binary(), binary()) -> binary().
const_macro_name(Prefix, Name) ->
    string:uppercase(typed_prefix(Prefix, thrift_generator_names:snake(Name))).

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
        Prefix <- [typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(S#tg_struct.name))]
    ]).

-spec struct_codec_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
struct_codec_forms(Mod, Ctx) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(section_label(S))] ++
            struct_codec_one(S, Ctx)
     || S <- Mod#tg_module.structs
    ]).

-spec struct_codec_one(#tg_struct{}, #ectx{}) -> erl_syntax:forms().
struct_codec_one(S, Ctx) ->
    Prefix = typed_prefix(current_prefix(Ctx), thrift_generator_names:snake(S#tg_struct.name)),
    Encode = binary_to_atom(<<"encode_", Prefix/binary>>, utf8),
    Decode = binary_to_atom(<<"decode_", Prefix/binary>>, utf8),
    %% A sum union has no record: its default representation is the
    %% tagged tuple, reached through the `record' axis. Map-mode
    %% structs default to their atom-keyed map, native-mode structs
    %% to the runtime-minted native record.
    DefaultRepr =
        case {sum_mode(S), record_mode(S), native_mode(S)} of
            {true, _, _} -> record;
            {false, true, _} -> record;
            {false, false, true} -> native;
            {false, false, false} -> map
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
                    [value_type(S)] ++
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
                "Decodes the whole binary into the struct's default"
                " representation (record, atom-keyed map, or the sum"
                " union's tagged tuple); trailing bytes or truncation"
                " fail the decode."
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

%% The input side of encode_: the definition's exported alias (record,
%% map and sum modes); native records are runtime-minted, so their input
%% stays term(). Record mode also accepts the wire-shaped map — both
%% normalize inside thrift_erl_record:to_wire.

-spec value_type(#tg_struct{}) -> erl_syntax:syntaxTree().
value_type(S) ->
    Alias = thrift_generator_emitter_syntax:user_type(type_alias(S#tg_struct.name)),
    case {sum_mode(S), record_mode(S), native_mode(S)} of
        {false, true, _} ->
            {type, erl_anno:new(0), union, [Alias, thrift_generator_emitter_syntax:raw_type(map)]};
        {false, false, true} ->
            thrift_generator_emitter_syntax:raw_type(term);
        _ ->
            Alias
    end.

%%--------------------------------------------------------------------
%% Tag index and convert
%%--------------------------------------------------------------------

-spec tag_index_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
tag_index_forms(Mod, Ctx) ->
    Anno = erl_anno:new(0),
    Pairs = lists:append([
        case sum_mode(S) of
            %% A sum-union value carries a field atom as its tag: every
            %% field indexes the union (the semantic rejects atoms
            %% claimed by two unions of one module).
            true ->
                [{field_atom(F#tg_field.name), struct_ref(S, Ctx)} || F <- S#tg_struct.fields];
            false ->
                [{struct_index_tag(S, current_prefix(Ctx)), struct_ref(S, Ctx)}]
        end
     || S <- Mod#tg_module.structs
    ]),
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
                " map-mode ones, sum-union field atoms for sums."
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
        Prefix <- [typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(E#tg_enum.name))]
    ]).

-spec enum_helper_forms(#tg_module{}) -> erl_syntax:forms().
enum_helper_forms(Mod) ->
    lists:append([
        [thrift_generator_emitter_syntax:section_form(section_label(E))] ++
            [
                {attribute, erl_anno:new(0), type, {type_alias(E#tg_enum.name), enum_type_node(E#tg_enum.values), []}}
            ] ++
            enum_helper_one(E, typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(E#tg_enum.name)))
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
        {binary_to_atom(typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(C#tg_const.name)), utf8), 0}
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
                thrift_generator_emitter_syntax:fn_clause([], const_literal(C#tg_const.value))
            ])
     || C <- Mod#tg_module.consts
    ]).

-spec const_name(#tg_module{}, #tg_const{}) -> atom().
const_name(Mod, C) ->
    binary_to_atom(typed_prefix(Mod#tg_module.prefix, thrift_generator_names:snake(C#tg_const.name)), utf8).

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

%% The divider label naming the IDL construct the following forms
%% implement (the declared name, not the derived tag).

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

%% The typed record declaration: each field carries its type — in the
%% .erl local references resolve to the module's exported aliases, in
%% the hrl (qualify) every reference is remote. Non-required fields add
%% `| undefined' — the value an absent wire field leaves behind;
%% `required' fields have none.

-spec record_form(#tg_struct{}, binary(), #ectx{}) -> erl_syntax:forms().
record_form(S, Prefix, Ctx) ->
    Anno = erl_anno:new(0),
    TypedFields = [
        {typed_record_field,
            case F#tg_field.default of
                undefined ->
                    {record_field, Anno, {atom, Anno, field_atom(F#tg_field.name)}};
                Default ->
                    Expr = set_default_expr(F#tg_field.type, const_literal(Default)),
                    {record_field, Anno, {atom, Anno, field_atom(F#tg_field.name)}, erl_syntax:revert(Expr)}
            end,
            field_type_node(F, Ctx)}
     || F <- S#tg_struct.fields
    ],
    [{attribute, Anno, record, {record_tag(Prefix, S#tg_struct.name), TypedFields}}].

-spec field_type_node(#tg_field{}, #ectx{}) -> erl_syntax:syntaxTree().
field_type_node(F, Ctx) ->
    Type = erlang_type(F#tg_field.type, Ctx),
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
    case set_impl(Ann) of
        list ->
            Default;
        sets ->
            thrift_generator_emitter_syntax:application(sets, from_list, [Default]);
        ordset ->
            thrift_generator_emitter_syntax:application(ordsets, from_list, [Default])
    end;
set_default_expr(_Type, Default) ->
    Default.

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

-spec struct_type(#tg_struct{}) -> record | map | native.
struct_type(S) ->
    case maps:get(struct_type, S#tg_struct.erl, undefined) of
        <<"map">> -> map;
        <<"native">> -> native;
        _ -> record
    end.

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
%% map mode answers {map, KeyType} (default atom keys), sum unions
%% answer {sum, FieldAtoms} — the runtime converts their {Tag, Value}
%% tuples by matching the atom against the field list; native mode
%% answers {native, Tag} — the tag runtime-minted records carry; structs
%% with no clause fall through to `none' — the wire passthrough.

-spec fields_decl(#tg_struct{}, binary()) ->
    {atom(), [atom()]} | {map, atom | binary} | {native, atom}.
fields_decl(S, Prefix) ->
    case {sum_mode(S), record_mode(S), native_mode(S)} of
        {true, _, _} ->
            {sum, [field_atom(F#tg_field.name) || F <- S#tg_struct.fields]};
        {false, true, _} ->
            {record_tag(Prefix, S#tg_struct.name), [
                field_atom(F#tg_field.name)
             || F <- S#tg_struct.fields
            ]};
        {false, false, true} ->
            %% No record declaration exists: the runtime mints native
            %% records under the snake-cased wire name.
            {native, record_tag(<<>>, S#tg_struct.name)};
        {false, false, false} ->
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

-doc """
Converts a model type into the wire descriptor vocabulary the runtime
codecs consume (resolving references, expanding typedefs and inlining
enum descriptors); shared with the codec emitter.
""".
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
                    %% A typedef from another module (base.Timestamp and
                    %% friends) resolves in its own module's context, so
                    %% refs inside its body stay home.
                    case find_typedef(Module, Local) of
                        {ok, Type} ->
                            type_desc(Type, Ctx#ectx{current = ModKey});
                        error ->
                            error({unresolved_type, ModKey, Local})
                    end
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
    binary_to_atom(typed_prefix(Prefix, thrift_generator_names:snake(Name)), utf8).

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
            qualified_ref_type(ModKey, Local, Ctx);
        [Local] when Ctx#ectx.qualify ->
            qualified_ref_type(Ctx#ectx.current, Local, Ctx);
        [Local] ->
            local_ref_type(Local, Ctx)
    end.

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
            thrift_generator_emitter_syntax:remote_type(types_module_atom(ModKey), Alias);
        error ->
            thrift_generator_emitter_syntax:raw_type(term)
    end.

-spec def_alias(#tg_module{} | undefined, binary()) -> {ok, atom()} | error.
def_alias(undefined, _Local) ->
    error;
def_alias(Module, Local) ->
    case find_struct(Module, Local) of
        {ok, S} ->
            case native_mode(S) of
                true -> error;
                false -> {ok, type_alias(Local)}
            end;
        error ->
            case find_enum(Module, Local) of
                {ok, _} ->
                    {ok, type_alias(Local)};
                error ->
                    case find_typedef(Module, Local) of
                        {ok, _} -> {ok, type_alias(Local)};
                        error -> error
                    end
            end
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
