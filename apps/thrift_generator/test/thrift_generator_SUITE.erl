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

%% Common Test coverage for whole IDL files: the canonical Apache
%% ThriftTest.thrift must parse completely, its Erlang-annotated fork
%% must additionally carry the `erl.*` annotations onto the AST, and
%% malformed files must be rejected.

-module(thrift_generator_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("thrift_generator/include/thrift_generator.hrl").
-include_lib("thrift_generator/include/thrift_generator_model.hrl").

-export([all/0]).
-export([
    parse_thrift_test_idl/1,
    parse_erlang_thrift_test_idl/1,
    reject_reserved_keyword/1,
    reject_syntax_error/1,
    semantic_pipeline/1,
    loader_cycle/1,
    loader_shared_namespace_modules/1,
    loader_shared_namespace_module_key_normalization/1,
    loader_shared_namespace_module_key_collision_after_normalization/1,
    loader_unresolved_duplicate_module/1,
    loader_missing_include/1,
    loader_namespace_prefix/1,
    loader_namespace_error/1,
    utf8_doc_and_const/1,
    utf8_invalid_file_rejected/1,
    same_struct_names_coexist/1,
    cross_module_typedef/1,
    cross_module_exception_typedef/1,
    cross_module_include_qualifier/1,
    cross_module_direct_dispatch/1,
    base_fields_guarded_encode/1,
    required_encode_map_pattern/1,
    union_encode_count/1,
    required_decode_bitmask/1,
    required_decode_order_many/1,
    empty_union_no_dead_code/1,
    json_fast_path_helpers/1,
    repr_direct_converters/1,
    onepass_cells_exist/1,
    repr_native_binary_encoders/1,
    repr_native_binary_decoders/1,
    repr_native_native_and_index/1,
    repr_native_facade_routing/1,
    repr_wide_struct/1,
    compact_enum_literals/1,
    compact_static_headers/1,
    rpc_specialized_codecs/1,
    rpc_loopback_hooks/1,
    rpc_loopback_fallback/1,
    generated_loopback_buffered/1,
    generated_loopback_framed/1,
    standalone_generate_check_clean/1,
    getting_started_example/1,
    generated_map_mode/1,
    generated_native_repr/1,
    generated_set_impl/1
]).

all() ->
    [
        parse_thrift_test_idl,
        parse_erlang_thrift_test_idl,
        reject_reserved_keyword,
        reject_syntax_error,
        semantic_pipeline,
        loader_cycle,
        loader_shared_namespace_modules,
        loader_shared_namespace_module_key_normalization,
        loader_shared_namespace_module_key_collision_after_normalization,
        loader_unresolved_duplicate_module,
        loader_missing_include,
        loader_namespace_prefix,
        loader_namespace_error,
        utf8_doc_and_const,
        utf8_invalid_file_rejected,
        same_struct_names_coexist,
        cross_module_typedef,
        cross_module_exception_typedef,
        cross_module_include_qualifier,
        cross_module_direct_dispatch,
        base_fields_guarded_encode,
        required_encode_map_pattern,
        union_encode_count,
        required_decode_bitmask,
        required_decode_order_many,
        empty_union_no_dead_code,
        json_fast_path_helpers,
        repr_direct_converters,
        onepass_cells_exist,
        repr_native_binary_encoders,
        repr_native_binary_decoders,
        repr_native_native_and_index,
        repr_native_facade_routing,
        repr_wide_struct,
        compact_enum_literals,
        compact_static_headers,
        rpc_specialized_codecs,
        rpc_loopback_hooks,
        rpc_loopback_fallback,
        generated_loopback_buffered,
        generated_loopback_framed,
        standalone_generate_check_clean,
        getting_started_example,
        generated_map_mode,
        generated_native_repr,
        generated_set_impl
    ].

parse_thrift_test_idl(Config) ->
    Doc = parse_data_file(Config, "ThriftTest.thrift"),
    #thrift_generator_document{headers = Headers, definitions = Definitions} =
        Doc#thrift_generator_node.payload,

    Namespaces = [N || N <- Headers, is_payload(N, #thrift_generator_namespace{})],
    ?assertEqual(18, length(Namespaces)),

    Counts = count_by_kind(Definitions),
    ?assertEqual(
        #{
            thrift_generator_struct => 25,
            thrift_generator_union => 1,
            thrift_generator_exception => 2,
            thrift_generator_enum => 1,
            thrift_generator_service => 2,
            thrift_generator_typedef => 2,
            thrift_generator_constant => 1
        },
        Counts
    ),

    Xtruct = find_definition(Definitions, thrift_generator_struct, <<"Xtruct">>),
    #thrift_generator_struct{fields = XtructFields} = Xtruct#thrift_generator_node.payload,
    ?assertEqual(
        [
            {1, default, {base, string, #{}}, <<"string_thing">>},
            {4, default, {base, i8, #{}}, <<"byte_thing">>},
            {9, default, {base, i32, #{}}, <<"i32_thing">>},
            {11, default, {base, i64, #{}}, <<"i64_thing">>}
        ],
        field_tuples(XtructFields)
    ),

    Numberz = find_definition(Definitions, thrift_generator_enum, <<"Numberz">>),
    #thrift_generator_enum{values = NumberzValues} = Numberz#thrift_generator_node.payload,
    ?assertEqual(
        [<<"ONE">>, <<"TWO">>, <<"THREE">>, <<"FIVE">>, <<"SIX">>, <<"EIGHT">>],
        [Name || {Name, _, _, _} <- NumberzValues]
    ),
    ?assertEqual([1, undefined, undefined, 5, undefined, 8], [Value || {_, Value, _, _} <- NumberzValues]),

    Service = find_definition(Definitions, thrift_generator_service, <<"ThriftTest">>),
    #thrift_generator_service{functions = Functions} = Service#thrift_generator_node.payload,
    ?assertEqual(23, length(Functions)),

    Oneway = find_function(Functions, <<"testOneway">>),
    #thrift_generator_function{oneway = true, return_type = void} =
        Oneway#thrift_generator_node.payload,

    MultiException = find_function(Functions, <<"testMultiException">>),
    #thrift_generator_function{throws = Throws} = MultiException#thrift_generator_node.payload,
    ?assertEqual(
        [{ref, <<"Xception">>, #{}}, {ref, <<"Xception2">>, #{}}],
        [Type || T <- Throws, #thrift_generator_field{type = Type} <- [payload(T)]]
    ),

    MyNumberz = find_definition(Definitions, thrift_generator_constant, <<"myNumberz">>),
    #thrift_generator_constant{value = {ref, <<"Numberz.ONE">>}} =
        MyNumberz#thrift_generator_node.payload,

    ok.

parse_erlang_thrift_test_idl(Config) ->
    Doc = parse_data_file(Config, "ErlangThriftTest.thrift"),
    #thrift_generator_document{headers = Headers, definitions = Definitions} =
        Doc#thrift_generator_node.payload,

    ?assertEqual(35, length(Definitions)),

    ErlNamespace = find_header(Headers, <<"erl">>),
    ?assertEqual(#{set => <<"sets">>}, ErlNamespace#thrift_generator_node.annotations),

    UserId = find_definition(Definitions, thrift_generator_typedef, <<"UserId">>),
    ?assertEqual(#{type => <<"nominal">>}, UserId#thrift_generator_node.annotations),

    %% erl.set annotates the type, so it stays in the dotted binary
    %% form inside the type; the typedef node itself stays clean
    UserIds = find_definition(Definitions, thrift_generator_typedef, <<"UserIds">>),
    #thrift_generator_typedef{
        type = {set, {base, string, #{}}, #{<<"erl.set">> := <<"ordset">>}}
    } =
        UserIds#thrift_generator_node.payload,
    ?assertEqual(#{}, UserIds#thrift_generator_node.annotations),

    CrazyNesting = find_definition(Definitions, thrift_generator_struct, <<"CrazyNesting">>),
    #thrift_generator_struct{fields = CrazyFields} = CrazyNesting#thrift_generator_node.payload,
    [
        #thrift_generator_node{
            payload = #thrift_generator_field{
                type = {set, {ref, <<"Insanity">>, #{}}, #{<<"erl.set">> := <<"ordset">>}}
            }
        }
    ] =
        [
            F
         || F <- CrazyFields,
            #thrift_generator_field{name = <<"set_field">>} <- [F#thrift_generator_node.payload]
        ],

    Bonk = find_definition(Definitions, thrift_generator_struct, <<"Bonk">>),
    ?assertEqual(<<"map">>, maps:get(struct_type, Bonk#thrift_generator_node.annotations)),
    ?assertEqual(<<"atom">>, maps:get('struct_type.map.key_type', Bonk#thrift_generator_node.annotations)),

    SomeUnion = find_definition(Definitions, thrift_generator_union, <<"SomeUnion">>),
    ?assertEqual(#{union_type => <<"sum">>}, SomeUnion#thrift_generator_node.annotations),

    ok.

reject_reserved_keyword(Config) ->
    BadFile = write_snippet(Config, "reserved.thrift", <<"struct catch {}">>),
    ?assertMatch({error, _}, thrift_generator:parse_file(BadFile)).

reject_syntax_error(Config) ->
    BadFile = write_snippet(Config, "broken.thrift", <<"struct">>),
    ?assertMatch({error, _}, thrift_generator:parse_file(BadFile)).

%% The full pipeline over a real include graph: loading, module naming
%% from `namespace erl`, cross-module references (types, constants, enum
%% members, inherited service functions) and default values taken from
%% constants.

semantic_pipeline(Config) ->
    MainPath = data_file(Config, "semantic/main.thrift"),
    SharedPath = data_file(Config, "semantic/shared/shared.thrift"),

    {ok, Loaded} = thrift_generator_loader:load(MainPath),
    ?assertEqual([<<"main">>, <<"shared">>], [E#tg_loaded.name || E <- Loaded]),
    [MainEntry, SharedEntry] = Loaded,
    ?assertEqual([SharedPath], MainEntry#tg_loaded.includes),
    ?assertEqual([], SharedEntry#tg_loaded.includes),

    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    %% Loaded order is the contract: the root stays first in the model.
    [MainMod, SharedMod] = Model#tg_model.modules,
    ?assertEqual(<<"main">>, MainMod#tg_module.name),

    MainDefinitions = (MainEntry#tg_loaded.doc#thrift_generator_node.payload)#thrift_generator_document.definitions,
    MainServiceNode = find_definition(MainDefinitions, thrift_generator_service, <<"MainService">>),
    ?assertEqual(
        <<"shared.BaseService">>,
        (MainServiceNode#thrift_generator_node.payload)#thrift_generator_service.extends
    ),

    Consts = MainMod#tg_module.consts,
    ?assertEqual([<<"KIND">>, <<"BASE">>], [C#tg_const.name || C <- Consts]),
    KindValue = hd([C#tg_const.value || C <- Consts, C#tg_const.name =:= <<"KIND">>]),
    ?assertEqual(<<"ONE">>, KindValue),
    BaseValue = hd([C#tg_const.value || C <- Consts, C#tg_const.name =:= <<"BASE">>]),
    ?assertEqual(10, BaseValue),

    [Color] = MainMod#tg_module.enums,
    ?assertEqual([{1, <<"RED">>}, {2, <<"GREEN">>}, {10, <<"BLUE">>}], Color#tg_enum.values),

    [Outer, Failed] = MainMod#tg_module.structs,
    ?assertEqual(struct, Outer#tg_struct.kind),
    ?assertEqual(
        [{<<"inner">>, undefined}, {<<"count">>, 10}, {<<"seen_at">>, undefined}],
        [
            {F#tg_field.name, F#tg_field.default}
         || F <- Outer#tg_struct.fields
        ]
    ),
    ?assertEqual(exception, Failed#tg_struct.kind),

    [MainService] = MainMod#tg_module.services,
    ?assertEqual(
        [<<"ping">>, <<"area">>, <<"fetch">>, <<"fire">>],
        [F#tg_function.name || F <- MainService#tg_service.functions]
    ),

    [Fetch] = [F || F <- MainService#tg_service.functions, F#tg_function.name =:= <<"fetch">>],
    [#tg_field{type = {ref, <<"Failed">>, #{}}}] = Fetch#tg_function.throws,

    %% The included module is analyzed on its own terms.
    ?assertEqual(<<"shared">>, SharedMod#tg_module.name),
    SharedEnums = SharedMod#tg_module.enums,
    [NumberzShared] = SharedEnums,
    ?assertEqual([{1, <<"ONE">>}, {2, <<"TWO">>}], NumberzShared#tg_enum.values),
    ?assertEqual(
        [<<"Inner">>, <<"Boom">>],
        [S#tg_struct.name || S <- SharedMod#tg_module.structs]
    ),
    [BaseService] = SharedMod#tg_module.services,
    ?assertEqual([<<"ping">>, <<"area">>], [F#tg_function.name || F <- BaseService#tg_service.functions]),

    ok.

%% A cross-module reference to a typedef (shared.Timestamp) resolves in
%% the defining module's context and lands in the generated descriptor
%% as the aliased type; the fixture file exercises the `#' comment form
%% and a doc block before the typedef on the way.

cross_module_typedef(Config) ->
    ok = generate_modules(data_file(Config, "semantic/main.thrift")),
    {struct, Fields} = 'main_types':struct_info(<<"Outer">>),
    SeenAt = lists:keyfind(3, 1, Fields),
    ?assertEqual({base, i64}, element(3, SeenAt)),
    ok.

%% A typedef alias to a cross-module exception stays an alias in the
%% semantic model, but the emitted throw descriptor resolves to the
%% defining exception's types module.
cross_module_exception_typedef(Config) ->
    _ = write_snippet(
        Config,
        "throw_alias_included.thrift",
        <<"namespace erl included\nexception E {}\n">>
    ),
    Root = write_snippet(
        Config,
        "throw_alias_root.thrift",
        <<
            "include \"throw_alias_included.thrift\"\n"
            "namespace erl root\n"
            "typedef included.E E\n"
            "service Api { void f() throws (1: E e) }\n"
        >>
    ),
    ok = generate_modules(Root),
    ?assertMatch(
        [{1, _, {struct, {ref, 'included_types', <<"E">>}}, <<"e">>, _}],
        root_types:function_info(<<"f">>, exceptions)
    ),
    ok.

loader_cycle(Config) ->
    CycleA = data_file(Config, "semantic/cycle_a.thrift"),
    ?assertMatch({error, {cycle, CycleA}}, thrift_generator_loader:load(CycleA)).

%% The Apache qualification spelling: a dotted reference's qualifier is
%% the included file's base name, which differs from the target's module
%% key (the erl namespace value). Types, constants and the module-key
%% spelling all resolve; the generated descriptor points at the real
%% types module.

cross_module_include_qualifier(Config) ->
    IncluderPath = data_file(Config, "semantic/qualified/includer.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(IncluderPath),
    ?assertEqual(
        [<<"qualified_includer">>, <<"qualified_includee">>],
        [E#tg_loaded.name || E <- Loaded]
    ),

    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [IncluderMod, IncludeeMod] = Model#tg_model.modules,
    ?assertEqual(<<"qualified_includee">>, IncludeeMod#tg_module.name),

    [Holder] = IncluderMod#tg_module.structs,
    ?assertEqual(
        [
            {ref, <<"includee.Payload">>, #{}},
            {ref, <<"includee.Color">>, #{}},
            {ref, <<"includee.Stamp">>, #{}},
            {ref, <<"qualified_includee.Payload">>, #{}}
        ],
        [F#tg_field.type || F <- Holder#tg_struct.fields]
    ),

    [Cap] = [C || C <- IncluderMod#tg_module.consts, C#tg_const.name =:= <<"Cap">>],
    ?assertEqual(7, Cap#tg_const.value),

    ok = generate_modules(IncluderPath),
    {struct, Fields} = 'qualified_includer_types':struct_info(<<"Holder">>),
    PayloadField = lists:keyfind(1, 1, Fields),
    ?assertEqual(
        {struct, {ref, 'qualified_includee_types', <<"Payload">>}},
        element(3, PayloadField)
    ),
    EnumField = lists:keyfind(2, 1, Fields),
    ?assertEqual({enum, [{1, 'RED'}, {2, 'BLUE'}]}, element(3, EnumField)),
    TypedefField = lists:keyfind(3, 1, Fields),
    ?assertEqual({base, i64}, element(3, TypedefField)),
    ByModuleField = lists:keyfind(4, 1, Fields),
    ?assertEqual(
        {struct, {ref, 'qualified_includee_types', <<"Payload">>}},
        element(3, ByModuleField)
    ),
    ok.

cross_module_direct_dispatch(Config) ->
    ok = generate_modules(data_file(Config, "semantic/main.thrift")),
    Value = #{
        <<"inner">> => #{<<"name">> => <<"nested">>},
        <<"count">> => 10,
        <<"seen_at">> => 123456789
    },
    lists:foreach(fun(Protocol) -> check_cross_module_protocol(Protocol, Value) end, [binary, compact, json]).

check_cross_module_protocol(Protocol, Value) ->
    {Runtime, GenericEncode, GenericDecode, Encode, Decode} =
        case Protocol of
            binary ->
                {
                    thrift_runtime_binary,
                    fun thrift_runtime_binary:encode/2,
                    fun thrift_runtime_binary:decode/2,
                    fun main_types:encode_main_outer_wire/1,
                    fun main_types:decode_main_outer_wire/1
                };
            compact ->
                {
                    thrift_runtime_compact,
                    fun thrift_runtime_compact:encode/2,
                    fun thrift_runtime_compact:decode/2,
                    fun main_types:encode_main_outer_compact/1,
                    fun main_types:decode_main_outer_compact/1
                };
            json ->
                {
                    thrift_runtime_json,
                    fun thrift_runtime_json:encode/2,
                    fun thrift_runtime_json:decode/2,
                    fun main_types:encode_main_outer_json/1,
                    fun main_types:decode_main_outer_json/1
                }
        end,
    Inline = {struct, main_types:struct_info(<<"Outer">>)},
    {ok, GenericIo} = GenericEncode(Inline, Value),
    {ok, DirectIo} = Encode(Value),
    Wire = iolist_to_binary(GenericIo),
    ?assertEqual(Wire, iolist_to_binary(DirectIo)),
    ?assertEqual({ok, Value, <<>>}, GenericDecode(Inline, Wire)),
    ?assertEqual({ok, Value, <<>>}, Decode(Wire)),
    BadValue = Value#{<<"inner">> := #{<<"name">> => 42}},
    ?assertEqual(GenericEncode(Inline, BadValue), Encode(BadValue)),
    lists:foreach(
        fun(Size) ->
            Prefix = binary:part(Wire, 0, Size),
            ?assertEqual(GenericDecode(Inline, Prefix), Decode(Prefix))
        end,
        lists:seq(0, byte_size(Wire) - 1)
    ),
    assert_without_runtime_dispatch(Runtime, fun() -> {ok, _} = Encode(Value) end),
    assert_without_runtime_dispatch(Runtime, fun() -> {ok, _, _} = Decode(Wire) end).

assert_without_runtime_dispatch(Runtime, Fun) ->
    Key = {Runtime, codec_mfa, shared_types},
    _ = persistent_term:erase(Key),
    Fun(),
    ?assertEqual(missing, persistent_term:get(Key, missing)).

%% Base-type fields in the binary and compact encode chains fold the
%% type/range check into the map-match clause guard and place the payload
%% straight into the chunk — no {ok, E} wrapper and no destructure case
%% per field (the JSON emitter already emits this shape). The assertions
%% pin the payload right next to the field header; the {ok, E} form has
%% a bound variable there instead.

base_fields_guarded_encode(Config) ->
    Path = write_snippet(
        Config,
        "guarded.thrift",
        <<
            "namespace erl guarded\n"
            "struct S {\n"
            "  1: optional i32 n,\n"
            "  2: optional string s,\n"
            "  3: optional bool b,\n"
            "  4: optional double d\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    Patterns = [
        %% binary: i32 payload segment right after the header literal
        <<"1:16\\/big-signed>>,\\s*<<V:32\\/big-signed>>">>,
        %% binary: string length segment right after the header literal
        <<"2:16\\/big-signed>>,\\s*\\[<<\\(byte_size\\(V\\)\\):32\\/big-signed>>">>,
        %% binary: bool literal payload right after the header literal
        <<"3:16\\/big-signed>>,\\s*<<\"\\\\001\">>">>,
        %% binary: double payload right after the header literal
        <<"4:16\\/big-signed>>,\\s*<<\\(erlang:float\\(V\\)\\):64\\/big-float>>">>,
        %% compact: varint payload call right after the static header
        %% literal (chain-opening field, LastId = 0, Delta = 1)
        <<"<<\"\\\\025\">>,\\s*enc_varint_z\\(V\\)">>,
        %% compact: double payload right after the header call
        <<"enc_header\\(4, LastId, 7\\),\\s*<<\\(erlang:float\\(V\\)\\):64\\/little-float>>">>
    ],
    lists:foreach(
        fun(P) ->
            ?assertMatch({match, _}, re:run(Src, P, [dotall]), #{pattern => P})
        end,
        Patterns
    ),
    ok.

%% The required-field encode check matches the required keys in one map
%% pattern on the valid path and builds the missing-names list only on
%% the error branch; structs without required fields carry no check at
%% all (the old empty-comprehension case is not emitted).

required_encode_map_pattern(Config) ->
    Path = write_snippet(
        Config,
        "reqshape.thrift",
        <<
            "namespace erl reqshape\n"
            "struct R {\n"
            "  1: required string s,\n"
            "  2: required i32 n,\n"
            "  3: optional bool b\n"
            "}\n"
            "struct NoReq {\n"
            "  1: optional i32 x\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    %% one map-pattern clause per protocol (binary, compact, json)
    ?assertMatch(
        {match, [_, _, _]},
        re:run(Src, <<"#\\{<<\"s\">> := _,\\s*<<\"n\">> := _\\}">>, [dotall, global])
    ),
    %% the missing list survives on the error branch only
    ?assertMatch(
        {match, _},
        re:run(Src, <<"missing_required_fields,\\s*\\[\\s*N\\s*\\|\\|\\s*N\\s*<-\\s*\\[<<\"s\">>,\\s*<<\"n\">>\\]">>, [
            dotall
        ])
    ),
    %% no empty comprehension for structs without required fields
    ?assertEqual(nomatch, re:run(Src, <<"N\\s*<-\\s*\\[\\]">>, [dotall])),
    ok.

%% The union encode check counts present fields arithmetically — no
%% intermediate list comprehension on the valid path; the union_empty
%% and union_multiple error terms are unchanged.

union_encode_count(Config) ->
    Path = write_snippet(
        Config,
        "unionshape.thrift",
        <<
            "namespace erl unionshape\n"
            "union U {\n"
            "  1: optional i32 a,\n"
            "  2: optional string b\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    ?assertMatch(
        {match, _},
        re:run(Src, <<"maps:is_key\\(<<\"a\">>, Value\\) of\\s*true\\s*->\\s*1;\\s*false\\s*->\\s*0">>, [dotall])
    ),
    %% the list-comprehension count is gone
    ?assertEqual(
        nomatch,
        re:run(Src, <<"N\\s*<-\\s*\\[<<\"a\">>,\\s*<<\"b\">>\\],\\s*maps:is_key">>, [dotall])
    ),
    ?assertMatch({match, _}, re:run(Src, <<"union_empty">>, [])),
    ?assertMatch({match, _}, re:run(Src, <<"union_multiple">>, [])),
    ok.

%% Required-presence tracking on decode is a bitmask: one bit per
%% required field in ascending id order, `bor' on a decoded field, the
%% full mask matched as a literal at the stop byte; the missing-names
%% list (ascending id order, DoubleReq pins the generic engines' order)
%% is rebuilt only on the error branch. No list keydelete, map remove,
%% or maps:values on the valid path.

required_decode_bitmask(Config) ->
    Path = write_snippet(
        Config,
        "reqmask.thrift",
        <<
            "namespace erl reqmask\n"
            "struct R {\n"
            "  1: required string s,\n"
            "  2: required i32 n,\n"
            "  3: optional bool b\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    %% full mask literal (fields s=bit 1, n=bit 2) at the stop byte:
    %% binary and compact loops close on it, json closes in _done
    %% the wire decoder and every repr decoder share the bitmask STOP
    %% clauses, so the count is at least the two wire shapes
    ?assertMatch({match, [_, _ | _]}, re:run(Src, <<"<<0,\\s*Rest\\/binary>>, 3, Acc">>, [global])),
    ?assertMatch({match, _}, re:run(Src, <<"_done\\(3, Acc, Rest\\)">>, [])),
    %% decoded required fields set their bit
    ?assertMatch({match, [_, _, _ | _]}, re:run(Src, <<"Req bor 1">>, [global])),
    ?assertMatch({match, [_, _, _ | _]}, re:run(Src, <<"Req bor 2">>, [global])),
    %% missing names are rebuilt from the mask only on the error branch
    ?assertMatch({match, _}, re:run(Src, <<"Req band B\\s*=:=\\s*0">>, [dotall])),
    %% the list/map tracking is gone
    ?assertEqual(nomatch, re:run(Src, <<"keydelete">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"maps:remove">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"maps:values">>, [])),
    ok.

%% Deliberate pin: the decode missing-names order is deterministic
%% ascending field id, even past the 32-field flatmap boundary where the
%% generic engines' required map switches to unspecified hash order.
%% Fields are declared in reverse id order to make the pin meaningful.

required_decode_order_many(Config) ->
    Fields = [
        ["  ", integer_to_binary(I), ": required i32 f", integer_to_binary(I)]
     || I <- lists:seq(40, 1, -1)
    ],
    Path = write_snippet(
        Config,
        "bigreq.thrift",
        iolist_to_binary(["namespace erl bigreq\nstruct R {\n", lists:join(",\n", Fields), "\n}\n"])
    ),
    ok = generate_modules(Path),
    Expected = [<<"f", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 40)],
    lists:foreach(
        fun({Decode, Wire}) ->
            ?assertEqual({error, {decode, {missing_required_fields, Expected}}}, Decode(Wire))
        end,
        [
            {fun bigreq_types:decode_bigreq_r_wire/1, <<0>>},
            {fun bigreq_types:decode_bigreq_r_compact/1, <<0>>},
            {fun bigreq_types:decode_bigreq_r_json/1, <<"{}">>}
        ]
    ),
    ok.

%% An empty union's check can never hand off to the encode chain, so the
%% chain is not emitted at all — generated modules stay clean under
%% warnings_as_errors (a dead chain entry function would break user
%% builds).

empty_union_no_dead_code(Config) ->
    Path = write_snippet(
        Config,
        "emptyunion.thrift",
        <<
            "namespace erl emptyunion\n"
            "union E {\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    ?assertEqual(nomatch, re:run(Src, <<"encode_emptyunion_e_wire_fields">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"encode_emptyunion_e_compact_fields">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"encode_emptyunion_e_json_fields">>, [])),
    ?assertMatch({match, _}, re:run(Src, <<"union_empty">>, [])),
    ?assertMatch([{ok, _, _}], thrift_generator_emitter:compile_sources(Model)),
    ok.

%% JSON string/number helpers scan in one pass without per-byte list
%% accumulation: plain string runs return a binary:part slice (the
%% legacy cons loop only runs past the first escape), number tokens come
%% back as slices with a float flag, and json_escape returns plain
%% binaries untouched. (The pins match erl_prettypr's concrete layout.)

json_fast_path_helpers(Config) ->
    Path = write_snippet(
        Config,
        "jsonfast.thrift",
        <<
            "namespace erl jsonfast\n"
            "struct S {\n"
            "  1: optional string s,\n"
            "  2: optional i32 n\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    %% plain-run string scanner with zero-copy slices
    ?assertMatch({match, _}, re:run(Src, <<"json_scan_string_plain">>, [])),
    ?assertMatch({match, _}, re:run(Src, <<"binary:part">>, [])),
    %% escape detection folded into a two-argument json_escape (no
    %% forwarder call, plain prefixes returned as-is)
    ?assertMatch({match, _}, re:run(Src, <<"json_escape\\(Rest, Orig\\)">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"json_escape_needed">>, [])),
    %% single-byte plain strings return immediately, without the scan loop
    ?assertMatch({match, _}, re:run(Src, <<"json_escape\\(<<C:8/big-unsigned>>, Orig\\)">>, [])),
    %% the list-based number classification is gone
    ?assertEqual(nomatch, re:run(Src, <<"lists:last">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"lists:any">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"json_float_marker">>, [])),
    ok.

%% Direct representation converters: record-mode structs emit
%% `repr_to_wire_<name>` / `repr_from_wire_<name>` with literal field
%% atoms and binary names, registered in a `repr_index/1` the runtime
%% probes instead of walking descriptors. Behavior must match the
%% descriptor engine exactly, including the binary-key-first lookup and
%% the error terms. (The pins match erl_prettypr's concrete layout.)

repr_direct_converters(Config) ->
    Path = write_snippet(
        Config,
        "reprdirect.thrift",
        <<
            "namespace erl reprdirect\n"
            "struct Inner {\n"
            "  1: required string s\n"
            "}\n"
            "struct Outer {\n"
            "  1: optional string s,\n"
            "  2: optional i32 n,\n"
            "  3: optional Inner inner,\n"
            "  4: optional list<Inner> inners\n"
            "}\n"
            "union U {\n"
            "  1: optional string s\n"
            "} (erl.union_type = \"sum\")\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    %% the converters live in their own module: the types module's codec
    %% sections stay byte-identical (BEAM layout is a measured variable)
    [#{source := TypesSrc}, #{source := Src}] = thrift_generator_emitter:sources(Model),
    ?assertEqual(nomatch, re:run(TypesSrc, <<"repr_to_wire">>, [])),
    ?assertMatch({match, _}, re:run(Src, <<"repr_index\\(">>, [])),
    ?assertMatch({match, _}, re:run(Src, <<"repr_to_wire_outer\\(">>, [])),
    ?assertMatch({match, _}, re:run(Src, <<"repr_from_wire_outer\\(">>, [])),
    ?assertMatch({match, _}, re:run(Src, <<"repr_to_wire_inner\\(">>, [])),
    Compiled = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun({ok, Name, Beam}) ->
            {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam)
        end,
        Compiled
    ),
    CacheKey = {thrift_runtime_record, repr_mfa, reprdirect_types},
    _ = persistent_term:erase(CacheKey),
    Outer = {struct, {ref, reprdirect_types, <<"Outer">>}},
    Wire = #{<<"s">> => <<"a">>, <<"n">> => 3, <<"inner">> => #{<<"s">> => <<"b">>}},
    %% map-shaped inputs keep the descriptor's maps:from_list path: it is
    %% faster than the generated map_put chain and must not probe repr_index
    ?assertEqual(Wire, thrift_runtime_record:to_wire(Outer, Wire)),
    ?assertEqual(undefined, persistent_term:get(CacheKey, undefined)),
    %% tuple record input, nested tuple converted too
    ?assertEqual(
        Wire,
        thrift_runtime_record:to_wire(Outer, {reprdirect_outer, <<"a">>, 3, {reprdirect_inner, <<"b">>}, undefined})
    ),
    %% atom-keyed and binary-keyed map inputs agree; unknown keys drop
    ?assertEqual(Wire, thrift_runtime_record:to_wire(Outer, #{s => <<"a">>, n => 3, inner => #{s => <<"b">>}})),
    ?assertEqual(Wire, thrift_runtime_record:to_wire(Outer, Wire#{unknown => 1})),
    %% a binary key wins over the atom key for the same field
    ?assertEqual(
        #{<<"s">> => <<"w">>},
        thrift_runtime_record:to_wire(Outer, #{s => <<"a">>, <<"s">> => <<"w">>})
    ),
    %% a present binary key converts even when its value is undefined
    ?assertEqual(
        #{<<"s">> => undefined},
        thrift_runtime_record:to_wire(Outer, #{<<"s">> => undefined})
    ),
    %% from_wire: record carries every field, map/struct only the present ones
    ?assertEqual(
        {reprdirect_outer, <<"a">>, undefined, undefined, undefined},
        thrift_runtime_record:from_wire(Outer, #{<<"s">> => <<"a">>}, record)
    ),
    ?assertEqual(#{s => <<"a">>}, thrift_runtime_record:from_wire(Outer, #{<<"s">> => <<"a">>}, map)),
    ?assertEqual(
        #{'__struct__' => reprdirect_outer, s => <<"a">>},
        thrift_runtime_record:from_wire(Outer, #{<<"s">> => <<"a">>}, struct)
    ),
    %% nested lists convert element-wise
    ?assertEqual(
        {reprdirect_outer, undefined, undefined, undefined, [{reprdirect_inner, <<"x">>}]},
        thrift_runtime_record:from_wire(Outer, #{<<"inners">> => [#{<<"s">> => <<"x">>}]}, record)
    ),
    %% error terms match the descriptor engine
    ?assertError(
        {value_does_not_match_type, {wrong, 1, 2, 3, 4}},
        thrift_runtime_record:to_wire(Outer, {wrong, 1, 2, 3, 4})
    ),
    %% a tuple of the wrong arity is not this struct's record: the direct
    %% converter deliberately rejects it where the descriptor engine
    %% silently truncated (documented divergence)
    ?assertError(
        {value_does_not_match_type, {reprdirect_outer, <<"a">>}},
        thrift_runtime_record:to_wire(Outer, {reprdirect_outer, <<"a">>})
    ),
    %% sum unions get no converter: the index answers error, the verdict
    %% caches as false, and the descriptor engine converts the value
    UnionDesc = {struct, {ref, reprdirect_types, <<"U">>}},
    ?assertEqual(#{<<"s">> => <<"v">>}, thrift_runtime_record:to_wire(UnionDesc, {s, <<"v">>})),
    %% the fast path left its verdicts in the dispatch cache
    Cache = persistent_term:get(CacheKey),
    ?assertMatch(#{<<"Outer">> := {_, _, _}}, Cache),
    ?assertMatch(#{<<"U">> := false}, Cache),
    %% native target round-trips through the emitted create call (OTP 29+)
    case thrift_runtime_native:supported() of
        true ->
            Native = thrift_runtime_record:from_wire(Outer, Wire, native),
            ?assert(thrift_runtime_native:is_native(Native)),
            ?assertEqual(Wire, thrift_runtime_record:to_wire(Outer, Native));
        false ->
            ok
    end,
    _ = persistent_term:erase(CacheKey),
    ok.

%% The flat accumulator chain in repr_to_wire/repr_from_wire MUST stay
%% flat: embedding it into case branches doubles the form tree per
%% field, and a 100-field struct hangs the compiler. This case keeps a
%% wide struct in the fixture set so a regression of the chain shape
%% fails fast instead of timing CI out.

repr_wide_struct(Config) ->
    Fields = [
        io_lib:format("  ~p: optional i32 f~p~n", [I, I])
     || I <- lists:seq(1, 60)
    ],
    Path = write_snippet(
        Config,
        "reprwide.thrift",
        iolist_to_binary([
            "namespace erl reprwide\n",
            "struct Wide {\n",
            Fields,
            "}\n"
        ])
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := _TypesSrc}, #{source := ReprSrc}] = thrift_generator_emitter:sources(Model),
    %% a flat chain is linear in the field count; a nested one explodes
    ?assert(byte_size(ReprSrc) < 500000),
    [{ok, reprwide_types, _}, {ok, reprwide_types_repr, _}] =
        thrift_generator_emitter:compile_sources(Model),
    ok.

%% Compact enum encode: the zigzag-varint of an enum value the
%% generator knows is computed at emission and emitted as a byte
%% literal, not recomputed per call. zigzag(1) = 2, zigzag(-2) = 3.
%% (The pins match erl_prettypr's concrete layout.)

compact_enum_literals(Config) ->
    Path = write_snippet(
        Config,
        "enumlit.thrift",
        <<
            "namespace erl enumlit\n"
            "enum Color {\n"
            "  RED = 1,\n"
            "  BLUE = -2,\n"
            "  HIGH = 64,\n"
            "  NEGATIVE = -65\n"
            "}\n"
            "struct Paint {\n"
            "  1: optional Color c,\n"
            "  2: optional i32 n\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    ?assertNotEqual(nomatch, binary:match(Src, <<"'RED' ->">>), "RED clause"),
    ?assertNotEqual(nomatch, binary:match(Src, <<"{ok, [<<\"\\002\">>]">>), "zigzag(1) literal"),
    ?assertNotEqual(nomatch, binary:match(Src, <<"{ok, [<<\"\\003\">>]">>), "zigzag(-2) literal"),
    %% known values never reach the runtime varint call
    ?assertEqual(nomatch, re:run(Src, <<"enc_varint_z\\(1\\)">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_varint_z\\(-2\\)">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_varint_z\\(64\\)">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_varint_z\\(-65\\)">>, [])),
    ?assertMatch([{ok, _, _}, {ok, _, _}], lists:sort(thrift_generator_emitter:compile_sources(Model))),
    ok = generate_modules(Path),
    Paint = {struct, enumlit_types:struct_info(<<"Paint">>)},
    lists:foreach(
        fun(Atom) ->
            Value = #{<<"c">> => Atom},
            {ok, GenericIo} = thrift_runtime_compact:encode(Paint, Value),
            {ok, DirectIo} = enumlit_types:encode_enumlit_paint_compact(Value),
            Wire = iolist_to_binary(GenericIo),
            ?assertEqual(Wire, iolist_to_binary(DirectIo)),
            ?assertEqual({ok, Value, <<>>}, enumlit_types:decode_enumlit_paint_compact(Wire)),
            ?assertEqual({ok, Value, <<>>}, thrift_runtime_compact:decode(Paint, Wire))
        end,
        ['RED', 'BLUE', 'HIGH', 'NEGATIVE']
    ),
    ok.

%% Compact field headers: when the previous field is required (or the
%% field opens the chain), LastId is known at generation and the header
%% is emitted as bytes instead of a runtime enc_header call — Delta = 1
%% with the i32 nibble 5 is <<21>>; Delta = 18 after required field 2
%% is the two-part [<<5>>, <<40>>] (zigzag(20)); a negative Delta after
%% out-of-order ids is [<<5>>, <<6>>] (the same two-part the runtime
%% enc_header produces). After an optional field LastId stays dynamic
%% and the runtime call remains. (Pins match the concrete layout.)

compact_static_headers(Config) ->
    Path = write_snippet(
        Config,
        "statichead.thrift",
        <<
            "namespace erl statichead\n"
            "struct R {\n"
            "  1: required i32 a,\n"
            "  2: required i32 b,\n"
            "  20: required i32 e,\n"
            "  3: optional i32 c,\n"
            "  4: optional i32 d\n"
            "}\n"
            "struct B {\n"
            "  1: required bool flag,\n"
            "  2: required list<i32> nums,\n"
            "  5: required i32 x,\n"
            "  6: optional i32 y\n"
            "}\n"
            "struct High {\n"
            "  9: required i32 high,\n"
            "  64: required i64 wide\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    %% static headers for fields 1, 2, 20, 3 — no runtime enc_header call
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(1,">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(2,">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(20,">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(3,">>, [])),
    ?assertNotEqual(nomatch, binary:match(Src, <<"<<\"\\025\">>">>), "Delta=1 header <<21>>"),
    ?assertNotEqual(nomatch, binary:match(Src, <<"[<<\"\\005\">>, [<<\"(\">>]]">>), "Delta=18 two-part header"),
    ?assertNotEqual(
        nomatch, binary:match(Src, <<"[<<\"\\005\">>, [<<\"\\006\">>]]">>), "negative Delta two-part header"
    ),
    %% field 4 follows an optional field: LastId is dynamic there
    ?assertMatch({match, _}, re:run(Src, <<"enc_header\\(4, LastId, 5\\)">>, [])),
    %% struct B: bool and container predecessors are required too, so
    %% every link is static — the bool value nibbles are the literals
    %% <<17>>/<<18>>, the list link emits <<25>> (Delta = 1, nibble 9),
    %% and the closing link never reads the delta base at all
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(1,">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(2,">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(5,">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(6,">>, [])),
    ?assertNotEqual(nomatch, binary:match(Src, <<"<<\"\\021\">>">>)),
    ?assertNotEqual(nomatch, binary:match(Src, <<"<<\"\\022\">>">>)),
    ?assertNotEqual(nomatch, binary:match(Src, <<"<<\"\\031\">>">>)),
    ?assertNotEqual(nomatch, binary:match(Src, <<"encode_statichead_b_compact_fields_f4(Value, _LastId)">>)),
    %% struct High crosses both varint boundaries without a runtime fallback
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(9,">>, [])),
    ?assertEqual(nomatch, re:run(Src, <<"enc_header\\(64,">>, [])),
    ?assertMatch([{ok, _, _}, {ok, _, _}], lists:sort(thrift_generator_emitter:compile_sources(Model))),
    ok = generate_modules(Path),
    High = {struct, statichead_types:struct_info(<<"High">>)},
    HighValue = #{<<"high">> => 7, <<"wide">> => 1000000},
    {ok, HighGenericIo} = thrift_runtime_compact:encode(High, HighValue),
    {ok, HighDirectIo} = statichead_types:encode_statichead_high_compact(HighValue),
    HighWire = iolist_to_binary(HighGenericIo),
    ?assertEqual(HighWire, iolist_to_binary(HighDirectIo)),
    ?assertEqual({ok, HighValue, <<>>}, statichead_types:decode_statichead_high_compact(HighWire)),
    ?assertEqual({ok, HighValue, <<>>}, thrift_runtime_compact:decode(High, HighWire)),
    ok.

%% Facade-level one-pass measurement cells exist: the bench harness
%% exposes an `onepass` case family keyed {Id, Repr, onepass, Op},
%% pairing the explicit two-pass baseline with the facade fast path.
%% The cells exist before the fast path does; head then measures the
%% same code, so the baseline run must read ratio ~= 1.00.

onepass_cells_exist(Config) ->
    Path = write_snippet(
        Config,
        "onepasspin.thrift",
        <<
            "namespace erl onepasspin\n"
            "struct Inner {\n"
            "  1: required string s\n"
            "}\n"
            "struct Outer {\n"
            "  1: required string id,\n"
            "  2: required Inner inner\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Compiled = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun({ok, Name, Beam}) ->
            {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam)
        end,
        Compiled
    ),
    Spec = #{
        id => <<"Outer">>,
        struct => <<"Outer">>,
        value => #{<<"id">> => <<"o-1">>, <<"inner">> => #{<<"s">> => <<"v">>}},
        base_prefix => <<"onepasspin">>,
        base_module => onepasspin_types,
        head_prefix => <<"onepasspin">>,
        head_module => onepasspin_types
    },
    CellKeys = [maps:get(key, C) || C <- thrift_bench_regression:onepass_cases(Spec)],
    ?assertMatch(
        [{<<"Outer">>, record, onepass, decode} | _],
        [K || K = {_, record, onepass, decode} <- CellKeys]
    ),
    ok.

%% Repr-native binary encoders read the record tuple or the map
%% directly: no wire-map materialization. Bytes must equal the
%% wire-map encode for every accepted input shape; wrong shapes answer
%% the same unwrapped {error, {value_does_not_match_type, V}} the
%% conversion layer raises today.

repr_native_binary_encoders(Config) ->
    Path = write_snippet(
        Config,
        "reprnativeenc.thrift",
        <<
            "namespace erl reprnativeenc\n"
            "struct Inner {\n"
            "  1: required string s\n"
            "}\n"
            "struct Outer {\n"
            "  1: required string id,\n"
            "  2: required Inner inner,\n"
            "  3: optional i32 n\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    ?assertMatch({match, _}, re:run(Src, <<"encode_reprnativeenc_outer_wire_from_record\\(">>)),
    ?assertMatch({match, _}, re:run(Src, <<"encode_reprnativeenc_outer_wire_from_map\\(">>)),
    ?assertNotEqual(nomatch, binary:match(Src, <<"{reprnativeenc_outer,">>)),
    Compiled = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun({ok, Name, Beam}) ->
            {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam)
        end,
        Compiled
    ),
    Mod = reprnativeenc_types,
    Name = <<"Outer">>,
    Desc = {struct, {ref, Mod, Name}},
    Wire = #{<<"id">> => <<"o-1">>, <<"inner">> => #{<<"s">> => <<"v">>}, <<"n">> => 7},
    {ok, ExpectedIo} = thrift_runtime_binary:encode(Desc, Wire),
    Expected = iolist_to_binary(ExpectedIo),
    %% record input
    {ok, RecIo} = Mod:encode_reprnativeenc_outer_wire_from_record(
        {reprnativeenc_outer, <<"o-1">>, {reprnativeenc_inner, <<"v">>}, 7}
    ),
    ?assertEqual(Expected, iolist_to_binary(RecIo)),
    %% atom-keyed map input: the absent optional key is skipped, so
    %% the bytes equal the wire encode of the map WITHOUT field 3
    {ok, MapIo} = Mod:encode_reprnativeenc_outer_wire_from_map(#{id => <<"o-1">>, inner => #{s => <<"v">>}}),
    {ok, NoNOk} = thrift_runtime_binary:encode(Desc, maps:remove(<<"n">>, Wire)),
    ?assertEqual(iolist_to_binary(NoNOk), iolist_to_binary(MapIo)),
    %% binary-keyed map input accepted with identical bytes
    {ok, BinMapIo} = Mod:encode_reprnativeenc_outer_wire_from_map(Wire),
    ?assertEqual(Expected, iolist_to_binary(BinMapIo)),
    %% __struct__ map input: tag dropped, declared fields encoded
    {ok, StructIo} = Mod:encode_reprnativeenc_outer_wire_from_map(
        #{'__struct__' => reprnativeenc_outer, id => <<"o-1">>, inner => #{s => <<"v">>}, n => 7}
    ),
    ?assertEqual(Expected, iolist_to_binary(StructIo)),
    %% wrong tag: unwrapped conversion-style error
    ?assertEqual(
        {error, {value_does_not_match_type, {wrong_tag, <<"o-1">>, {reprnativeenc_inner, <<"v">>}, 7}}},
        Mod:encode_reprnativeenc_outer_wire_from_record({wrong_tag, <<"o-1">>, {reprnativeenc_inner, <<"v">>}, 7})
    ),
    %% nested value in the wrong shape: unwrapped error with the nested value
    ?assertEqual(
        {error, {value_does_not_match_type, #{<<"s">> => <<"v">>}}},
        Mod:encode_reprnativeenc_outer_wire_from_record(
            {reprnativeenc_outer, <<"o-1">>, #{<<"s">> => <<"v">>}, 7}
        )
    ),
    %% non-tuple/non-map input: unwrapped error
    ?assertEqual(
        {error, {value_does_not_match_type, not_a_value}},
        Mod:encode_reprnativeenc_outer_wire_from_record(not_a_value)
    ),
    ok.

%% Repr-native binary decoders build the record tuple / atom-keyed
%% map / struct map directly from the wire bytes, with the wire
%% chain's skip, `more` and required-bitmask semantics.

repr_native_binary_decoders(Config) ->
    Path = write_snippet(
        Config,
        "reprnativedec.thrift",
        <<
            "namespace erl reprnativedec\n"
            "struct Inner {\n"
            "  1: required string s\n"
            "}\n"
            "struct Outer {\n"
            "  1: required string id,\n"
            "  2: required Inner inner,\n"
            "  3: optional i32 n\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    ?assertMatch({match, _}, re:run(Src, <<"decode_reprnativedec_outer_wire_record\\(">>)),
    ?assertMatch({match, _}, re:run(Src, <<"decode_reprnativedec_outer_wire_map\\(">>)),
    ?assertMatch({match, _}, re:run(Src, <<"decode_reprnativedec_outer_wire_struct\\(">>)),
    Compiled = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun({ok, Name, Beam}) ->
            {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam)
        end,
        Compiled
    ),
    Mod = reprnativedec_types,
    Desc = {struct, {ref, Mod, <<"Outer">>}},
    Wire = #{<<"id">> => <<"o-1">>, <<"inner">> => #{<<"s">> => <<"v">>}, <<"n">> => 7},
    {ok, Io} = thrift_runtime_binary:encode(Desc, Wire),
    Bin = iolist_to_binary(Io),
    {ok, WireBack, <<>>} = thrift_runtime_binary:decode(Desc, Bin),
    %% record: tuple, absent optionals as undefined
    {ok, Rec, <<>>} = Mod:decode_reprnativedec_outer_wire_record(Bin),
    ?assertEqual({reprnativedec_outer, <<"o-1">>, {reprnativedec_inner, <<"v">>}, 7}, Rec),
    {ok, RecNoN, <<>>} = Mod:decode_reprnativedec_outer_wire_record(
        iolist_to_binary(element(2, thrift_runtime_binary:encode(Desc, maps:remove(<<"n">>, Wire))))
    ),
    ?assertEqual({reprnativedec_outer, <<"o-1">>, {reprnativedec_inner, <<"v">>}, undefined}, RecNoN),
    %% map: atom keys, present only
    {ok, MapBack, <<>>} = Mod:decode_reprnativedec_outer_wire_map(Bin),
    ?assertEqual(#{id => <<"o-1">>, inner => #{s => <<"v">>}, n => 7}, MapBack),
    %% struct: atom map plus the identity tag
    {ok, StructBack, <<>>} = Mod:decode_reprnativedec_outer_wire_struct(Bin),
    ?assertEqual(
        #{
            '__struct__' => reprnativedec_outer,
            id => <<"o-1">>,
            inner => #{'__struct__' => reprnativedec_inner, s => <<"v">>},
            n => 7
        },
        StructBack
    ),
    %% truncated input asks for more, exactly like the wire decoder
    ?assertEqual(more, Mod:decode_reprnativedec_outer_wire_record(binary:part(Bin, 0, byte_size(Bin) - 1))),
    ?assertEqual(WireBack, thrift_runtime_record:to_wire(Desc, Rec)),
    ok.

%% The repr index hands out the per-repr encoder/decoder pair by
%% struct name; the native decoder builds the EEP-79 record at the STOP
%% byte with literal field atoms (OTP 29+).

repr_native_native_and_index(Config) ->
    Path = write_snippet(
        Config,
        "reprnativenative.thrift",
        <<
            "namespace erl reprnativenative\n"
            "struct Item {\n"
            "  1: required string s,\n"
            "  2: optional i32 n\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [#{source := Src} | _] = thrift_generator_emitter:sources(Model),
    ?assertMatch({match, _}, re:run(Src, <<"binary_repr_codec\\(">>)),
    ?assertMatch({match, _}, re:run(Src, <<"decode_reprnativenative_item_wire_native\\(">>)),
    Compiled = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun({ok, Name, Beam}) ->
            {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam)
        end,
        Compiled
    ),
    Mod = reprnativenative_types,
    {ok, {EncRec, DecRec}} = Mod:binary_repr_codec(<<"Item">>, record),
    ?assertEqual(encode_reprnativenative_item_wire_from_record, EncRec),
    ?assertEqual(decode_reprnativenative_item_wire_record, DecRec),
    {ok, {_EncMap, DecStruct}} = Mod:binary_repr_codec(<<"Item">>, struct),
    ?assertEqual(decode_reprnativenative_item_wire_struct, DecStruct),
    %% the native pair exists on every OTP: the OTP-28 unsupported_repr
    %% gate lives in the facade, not the index
    {ok, {_, DecNative0}} = Mod:binary_repr_codec(<<"Item">>, native),
    ?assertEqual(decode_reprnativenative_item_wire_native, DecNative0),
    ?assertEqual(error, Mod:binary_repr_codec(<<"Nope">>, record)),
    case thrift_runtime_native:supported() of
        true ->
            Desc = {struct, {ref, Mod, <<"Item">>}},
            Wire = #{<<"s">> => <<"v">>, <<"n">> => 1},
            {ok, Io} = thrift_runtime_binary:encode(Desc, Wire),
            Bin = iolist_to_binary(Io),
            {ok, Native, <<>>} = Mod:decode_reprnativenative_item_wire_native(Bin),
            ?assert(thrift_runtime_native:is_native(Native)),
            ?assertEqual(Wire, thrift_runtime_record:to_wire(Desc, Native)),
            ?assertEqual(Wire, thrift_runtime_record:to_wire(Desc, Native));
        false ->
            ok
    end,
    ok.

%% Facade routing: thrift_runtime decode/3 and encode/2 take the
%% one-pass path underneath for eligible inputs and fall back to the
%% two-pass conversion otherwise, with identical bytes, values and
%% error terms on every shape.

repr_native_facade_routing(Config) ->
    Path = write_snippet(
        Config,
        "reprnativefacade.thrift",
        <<
            "namespace erl reprnativefacade\n"
            "struct Inner {\n"
            "  1: required string s\n"
            "}\n"
            "struct Outer {\n"
            "  1: required string id,\n"
            "  2: required Inner inner,\n"
            "  3: optional i32 n\n"
            "}\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Compiled = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun({ok, Name, Beam}) ->
            {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam)
        end,
        Compiled
    ),
    Mod = reprnativefacade_types,
    Desc = {struct, {ref, Mod, <<"Outer">>}},
    Wire = #{<<"id">> => <<"o-1">>, <<"inner">> => #{<<"s">> => <<"v">>}, <<"n">> => 7},
    {ok, Io} = thrift_runtime_binary:encode(Desc, Wire),
    Bin = iolist_to_binary(Io),
    %% the facade decode equals the two-pass result
    {ok, Rec} = thrift_runtime:decode(Desc, Bin, #{repr => record}),
    ?assertEqual({reprnativefacade_outer, <<"o-1">>, {reprnativefacade_inner, <<"v">>}, 7}, Rec),
    {ok, Map} = thrift_runtime:decode(Desc, Bin, #{repr => map}),
    ?assertEqual(#{id => <<"o-1">>, inner => #{s => <<"v">>}, n => 7}, Map),
    {ok, Struct} = thrift_runtime:decode(Desc, Bin, #{repr => struct}),
    ?assertEqual(
        #{
            '__struct__' => reprnativefacade_outer,
            id => <<"o-1">>,
            inner => #{'__struct__' => reprnativefacade_inner, s => <<"v">>},
            n => 7
        },
        Struct
    ),
    %% decode of a record-mode struct under map mode keeps working;
    %% truncated and trailing behave as today
    {error, truncated} = thrift_runtime:decode(Desc, binary:part(Bin, 0, byte_size(Bin) - 1), #{
        repr => record
    }),
    {error, trailing} = thrift_runtime:decode(Desc, <<Bin/binary, 0>>, #{repr => record}),
    %% encode/2 from every accepted shape equals the wire encode
    {ok, EncRec} = thrift_runtime:encode(Desc, Rec),
    ?assertEqual(Bin, EncRec),
    {ok, EncMap} = thrift_runtime:encode(Desc, Map),
    ?assertEqual(Bin, EncMap),
    %% binary-keyed wire map input keeps identical bytes (Review Focus 1)
    {ok, EncWire} = thrift_runtime:encode(Desc, Wire),
    ?assertEqual(Bin, EncWire),
    %% __struct__ map input encodes identically (Review Focus 2)
    {ok, EncStruct} = thrift_runtime:encode(Desc, Struct),
    ?assertEqual(Bin, EncStruct),
    %% wrong-tag tuple: the unwrapped conversion error (Review Focus 5)
    ?assertEqual(
        {error, {value_does_not_match_type, {wrong, <<"o-1">>, {reprnativefacade_inner, <<"v">>}, 7}}},
        thrift_runtime:encode(Desc, {wrong, <<"o-1">>, {reprnativefacade_inner, <<"v">>}, 7})
    ),
    %% mixed nesting (record holding a wire-map nested value): the
    %% fast path rejects it, the facade retries two-pass and answers
    %% exactly what the two-pass path answers today — success
    Mixed = {reprnativefacade_outer, <<"o-1">>, #{<<"s">> => <<"v">>}, 7},
    {ok, EncMixed} = thrift_runtime:encode(Desc, Mixed),
    TwoPassMixed = begin
        WireMixed = thrift_runtime_record:to_wire(Desc, Mixed),
        iolist_to_binary(element(2, thrift_runtime_binary:encode(Desc, WireMixed)))
    end,
    ?assertEqual(TwoPassMixed, EncMixed),
    %% non-eligible input falls back with today's error
    ?assertEqual(
        {error, {value_does_not_match_type, not_a_value}},
        thrift_runtime:encode(Desc, not_a_value)
    ),
    %% the fast path left its verdicts in the dispatch cache
    CacheKey = {thrift_runtime_binary, repr_codec_mfa, Mod},
    Cache = persistent_term:get(CacheKey),
    ?assertMatch(#{{<<"Outer">>, record} := {_, _}}, Cache),
    ?assertMatch(#{{<<"Outer">>, map} := {_, _}}, Cache),
    _ = persistent_term:erase(CacheKey),
    ok.

%% RPC params/result hooks: the generated service info carries
%% specialized per-protocol codec pairs for the synthetic params and
%% result structs. They must match the generic descriptor engine
%% byte-for-byte, including truncation and type errors; oneway functions
%% carry no result hook.

rpc_specialized_codecs(Config) ->
    ok = generate_modules(data_file(Config, "semantic/main.thrift")),
    #{<<"MainService">> := Fns} = main_types:service_info(),
    #{<<"ping">> := Ping, <<"area">> := Area, <<"fetch">> := Fetch, <<"fire">> := Fire} = Fns,
    lists:foreach(
        fun(Protocol) ->
            check_rpc_params(Protocol, Area, #{<<"w">> => 3, <<"h">> => 4}, #{<<"w">> => <<"x">>, <<"h">> => 4}),
            check_rpc_params(Protocol, Fetch, #{<<"id">> => 5}, #{<<"id">> => <<"x">>}),
            check_rpc_params(Protocol, Ping, #{}, undefined),
            check_rpc_params(Protocol, Fire, #{<<"code">> => 42}, undefined),
            check_rpc_result(Protocol, Area, 12, <<"b">>, #{<<"message">> => <<"boom">>}),
            check_rpc_result(Protocol, Fetch, #{<<"name">> => <<"5">>}, <<"f">>, #{
                <<"reason">> => <<"negative id">>
            }),
            check_rpc_result(Protocol, Ping, undefined, undefined, undefined),
            #{codecs := FireCodecs} = Fire,
            ?assertNot(maps:is_key(result, maps:get(Protocol, FireCodecs)))
        end,
        [thrift_runtime_binary, thrift_runtime_compact, thrift_runtime_json]
    ),
    ok.

check_rpc_params(Protocol, Info, Value, BadValue) ->
    #{params := ParamsDesc, codecs := #{Protocol := #{params := {Mod, Enc, Dec}}}} = Info,
    ?assertEqual(main_types, Mod),
    {ok, GenericIo} = Protocol:encode(ParamsDesc, Value),
    Wire = iolist_to_binary(GenericIo),
    {ok, DirectIo} = apply(Mod, Enc, [Value]),
    ?assertEqual(Wire, iolist_to_binary(DirectIo)),
    ?assertEqual({ok, Value, <<>>}, Protocol:decode(ParamsDesc, Wire)),
    ?assertEqual({ok, Value, <<>>}, apply(Mod, Dec, [Wire])),
    case BadValue of
        undefined ->
            ok;
        _ ->
            ?assertEqual(Protocol:encode(ParamsDesc, BadValue), apply(Mod, Enc, [BadValue]))
    end,
    lists:foreach(
        fun(Size) ->
            Prefix = binary:part(Wire, 0, Size),
            ?assertEqual(Protocol:decode(ParamsDesc, Prefix), apply(Mod, Dec, [Prefix]))
        end,
        lists:seq(0, byte_size(Wire) - 1)
    ).

check_rpc_result(Protocol, Info, SuccessValue, ExceptionField, ExceptionValue) ->
    Reply = maps:get(reply, Info, undefined),
    Exceptions = maps:get(exceptions, Info, []),
    Fields =
        case Reply of
            undefined -> Exceptions;
            _ -> [{0, default, Reply, <<"success">>, undefined} | Exceptions]
        end,
    ResultDesc = {struct, {struct, Fields}},
    #{codecs := #{Protocol := #{result := {Mod, Enc, Dec}}}} = Info,
    ?assertEqual(main_types, Mod),
    Value =
        case Reply of
            undefined -> #{};
            _ -> #{<<"success">> => SuccessValue}
        end,
    check_rpc_value(Protocol, ResultDesc, Mod, Enc, Dec, Value),
    case ExceptionField of
        undefined ->
            ok;
        _ ->
            check_rpc_value(Protocol, ResultDesc, Mod, Enc, Dec, #{ExceptionField => ExceptionValue})
    end.

check_rpc_value(Protocol, Desc, Mod, Enc, Dec, Value) ->
    {ok, GenericIo} = Protocol:encode(Desc, Value),
    Wire = iolist_to_binary(GenericIo),
    {ok, DirectIo} = apply(Mod, Enc, [Value]),
    ?assertEqual(Wire, iolist_to_binary(DirectIo)),
    ?assertEqual({ok, Value, <<>>}, Protocol:decode(Desc, Wire)),
    ?assertEqual({ok, Value, <<>>}, apply(Mod, Dec, [Wire])),
    lists:foreach(
        fun(Size) ->
            Prefix = binary:part(Wire, 0, Size),
            ?assertEqual(Protocol:decode(Desc, Prefix), apply(Mod, Dec, [Prefix]))
        end,
        lists:seq(0, byte_size(Wire) - 1)
    ).

%% Hook-path proof: the hooked service descriptor keeps the generated
%% codecs but corrupts every descriptor leaf type, so a successful call
%% is only possible when client and server both use the specialized
%% hooks instead of the generic descriptor engine.

rpc_loopback_hooks(Config) ->
    ok = generate_modules(data_file(Config, "semantic/main.thrift")),
    {ok, Server} = thrift_runtime_server:start_link(#{
        port => 0,
        handler => thrift_generator_rpc_wire_handler,
        service => thrift_generator_rpc_hooked_service,
        name => rpc_hooks_server
    }),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} = thrift_runtime_client:start_link(#{
            host => "127.0.0.1",
            port => Port,
            service => thrift_generator_rpc_hooked_service
        }),
        try
            ?assertEqual({ok, 12}, thrift_runtime_client:call(Client, <<"area">>, [3, 4], 5000)),
            ?assertMatch(
                {ok, #{<<"name">> := <<"5">>}},
                thrift_runtime_client:call(Client, <<"fetch">>, [5], 5000)
            ),
            ?assertMatch(
                {error, {exception, <<"Failed">>, #{<<"reason">> := <<"negative id">>}}},
                thrift_runtime_client:call(Client, <<"fetch">>, [-1], 5000)
            ),
            ?assertEqual({ok, undefined}, thrift_runtime_client:call(Client, <<"ping">>, [], 5000)),
            ?assertEqual(ok, thrift_runtime_client:oneway(Client, <<"fire">>, [42], 5000))
        after
            thrift_runtime_client:stop(Client)
        end
    after
        thrift_runtime_server:stop(Server)
    end.

%% Fallback proof: without the codecs key the same generated stack keeps
%% working on the generic descriptor path.

rpc_loopback_fallback(Config) ->
    ok = generate_modules(data_file(Config, "semantic/main.thrift")),
    {ok, Server} = thrift_runtime_server:start_link(#{
        port => 0,
        handler => thrift_generator_rpc_wire_handler,
        service => thrift_generator_rpc_stripped_service,
        name => rpc_fallback_server
    }),
    try
        {ok, Port} = thrift_runtime_server:port(Server),
        {ok, Client} = thrift_runtime_client:start_link(#{
            host => "127.0.0.1",
            port => Port,
            service => thrift_generator_rpc_stripped_service
        }),
        try
            ?assertEqual({ok, 12}, thrift_runtime_client:call(Client, <<"area">>, [3, 4], 5000)),
            ?assertMatch(
                {ok, #{<<"name">> := <<"5">>}},
                thrift_runtime_client:call(Client, <<"fetch">>, [5], 5000)
            ),
            ?assertMatch(
                {error, {exception, <<"Failed">>, #{<<"reason">> := <<"negative id">>}}},
                thrift_runtime_client:call(Client, <<"fetch">>, [-1], 5000)
            ),
            ?assertEqual({ok, undefined}, thrift_runtime_client:call(Client, <<"ping">>, [], 5000))
        after
            thrift_runtime_client:stop(Client)
        end
    after
        thrift_runtime_server:stop(Server)
    end.

%% Two files may share a namespace for generated identifiers. Their module
%% keys disambiguate by basename, while prefixes, include qualifiers and
%% record tags keep the shared namespace value.
loader_shared_namespace_modules(Config) ->
    One = data_file(Config, "semantic/dup_one.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(One),
    ?assertEqual([<<"dup_one">>, <<"dup_two">>], [E#tg_loaded.name || E <- Loaded]),
    ?assertEqual([<<"duplicated">>, <<"duplicated">>], [E#tg_loaded.prefix || E <- Loaded]),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [OneMod, TwoMod] = Model#tg_model.modules,
    ?assertEqual([<<"duplicated">>, <<"duplicated">>], [OneMod#tg_module.prefix, TwoMod#tg_module.prefix]),
    ok = generate_modules(One),
    {struct, Fields} = dup_one_types:struct_info(<<"One">>),
    OtherField = lists:keyfind(2, 1, Fields),
    ?assertEqual({struct, {ref, dup_two_types, <<"Two">>}}, element(3, OtherField)),
    ?assertEqual({duplicated_one, [x, other]}, dup_one_types:record_fields(<<"One">>)),
    ?assertEqual({duplicated_two, [y]}, dup_two_types:record_fields(<<"Two">>)),
    ok.

%% When even file basenames cannot make module keys unique, the original
%% duplicate error remains — silently choosing either file would make
%% cross-file references ambiguous.
%% Collision-fallback module keys use the same atom-safe normalization as
%% identifier prefixes, scoped to the basename candidate: hyphens/spaces
%% collapse, a leading digit is guarded, and the shared identifier prefix
%% remains untouched.
loader_shared_namespace_module_key_normalization(Config) ->
    Content = <<"namespace erl shared\nstruct Thing { 1: i32 value }\n">>,
    First = write_nested_snippet(Config, "normal_a/hy-phen.thrift", Content),
    Second = write_nested_snippet(Config, "normal_b/space name.thrift", Content),
    Third = write_nested_snippet(Config, "normal_c/2fast.thrift", Content),
    Root = write_snippet(
        Config,
        "normalized_root.thrift",
        <<
            "include \"normal_a/hy-phen.thrift\"\n"
            "include \"normal_b/space name.thrift\"\n"
            "include \"normal_c/2fast.thrift\"\n"
            "namespace erl root\n"
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Root),
    ?assertEqual(<<"hy-phen">>, thrift_generator_loader:include_qualifier(First)),
    ?assertEqual(<<"space name">>, thrift_generator_loader:include_qualifier(Second)),
    ?assertEqual(<<"2fast">>, thrift_generator_loader:include_qualifier(Third)),
    ?assertEqual(
        [<<"root">>, <<"hy_phen">>, <<"space_name">>, <<"_2fast">>],
        [E#tg_loaded.name || E <- Loaded]
    ),
    ?assertEqual(
        [<<"root">>, <<"shared">>, <<"shared">>, <<"shared">>],
        [E#tg_loaded.prefix || E <- Loaded]
    ),
    ok = generate_modules(Root),
    ?assertMatch({file, _}, code:is_loaded(hy_phen_types)),
    ?assertMatch({file, _}, code:is_loaded(space_name_types)),
    ?assertMatch({file, _}, code:is_loaded('_2fast_types')),
    ?assertEqual({shared_thing, [value]}, hy_phen_types:record_fields(<<"Thing">>)),
    ok.

%% Normalization may itself collide. That stays conservative: the original
%% namespace collision is rejected rather than inventing a second naming
%% scheme or choosing an arbitrary winner.
loader_shared_namespace_module_key_collision_after_normalization(Config) ->
    Content = <<"namespace erl shared\nstruct Thing { 1: i32 value }\n">>,
    First = write_nested_snippet(Config, "normalized_collision_a/a-b.thrift", Content),
    Second = write_nested_snippet(Config, "normalized_collision_b/a b.thrift", Content),
    Root = write_snippet(
        Config,
        "normalized_collision_root.thrift",
        <<
            "include \"normalized_collision_a/a-b.thrift\"\n"
            "include \"normalized_collision_b/a b.thrift\"\n"
            "namespace erl root\n"
        >>
    ),
    FirstAbs = unicode:characters_to_binary(filename:absname(First)),
    SecondAbs = unicode:characters_to_binary(filename:absname(Second)),
    ?assertMatch(
        {error, {duplicate_module, <<"shared">>, FirstAbs, SecondAbs}},
        thrift_generator_loader:load(Root)
    ),
    ok.

loader_unresolved_duplicate_module(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    First = filename:join(Priv, "same_ns_a/shared.thrift"),
    Second = filename:join(Priv, "same_ns_b/shared.thrift"),
    ok = filelib:ensure_dir(First),
    ok = filelib:ensure_dir(Second),
    Content = <<"namespace erl shared\nstruct Thing { 1: i32 value }\n">>,
    ok = file:write_file(First, Content),
    ok = file:write_file(Second, Content),
    Root = write_snippet(
        Config,
        "same_ns_root.thrift",
        <<
            "include \"same_ns_a/shared.thrift\"\n"
            "include \"same_ns_b/shared.thrift\"\n"
            "namespace erl root\n"
        >>
    ),
    FirstAbs = unicode:characters_to_binary(filename:absname(First)),
    SecondAbs = unicode:characters_to_binary(filename:absname(Second)),
    ?assertMatch(
        {error, {duplicate_module, <<"shared">>, FirstAbs, SecondAbs}},
        thrift_generator_loader:load(Root)
    ),
    ok.

loader_missing_include(Config) ->
    Missing = data_file(Config, "semantic/does_not_exist.thrift"),
    ?assertMatch(
        {error, {parse, Missing, _}},
        thrift_generator_loader:load(data_file(Config, "semantic/missing_include.thrift"))
    ).

%% The erl/wildcard namespace becomes the generated identifier prefix:
%% lowercased, non-identifier runs collapsed, leading digits guarded.
%% Other scopes (java etc.) are not our naming concern.

loader_namespace_prefix(Config) ->
    Prefixed = write_snippet(
        Config,
        "prefixed.thrift",
        <<"namespace erl demo.App2\nstruct Point { 1: i32 x }\n">>
    ),
    {ok, [Entry]} = thrift_generator_loader:load(Prefixed),
    ?assertEqual(<<"demo.App2">>, Entry#tg_loaded.name),
    ?assertEqual(<<"demo_app2">>, Entry#tg_loaded.prefix),

    Digits = write_snippet(
        Config,
        "digits.thrift",
        <<"namespace * _2Fast\nstruct P { 1: i32 x }\n">>
    ),
    {ok, [DigitsEntry]} = thrift_generator_loader:load(Digits),
    ?assertEqual(<<"_2fast">>, DigitsEntry#tg_loaded.prefix),

    Foreign = write_snippet(
        Config,
        "foreign.thrift",
        <<"namespace java com.foo.bar\nstruct P { 1: i32 x }\n">>
    ),
    {ok, [ForeignEntry]} = thrift_generator_loader:load(Foreign),
    ?assertEqual(<<"foreign">>, ForeignEntry#tg_loaded.name),
    %% No usable namespace: the file base name becomes the prefix, so
    %% same-named structs of namespace-less files still never collide.
    ?assertEqual(<<"foreign">>, ForeignEntry#tg_loaded.prefix),

    %% End to end: the prefix lands in the emitted record tag and the
    %% generated module atom.
    {ok, Model} = thrift_generator_semantic:analyze([Entry]),
    Sources = thrift_generator_emitter:sources(Model),
    [
        #{
            module := demo_App2_types,
            source := Src,
            hrl := Hrl
        }
        | _
    ] = Sources,
    ?assertMatch(
        {match, _},
        re:run(Src, <<"-record\\(demo_app2_point,\\{x :: integer\\(\\) \\| undefined\\}\\)\\.">>)
    ),
    %% the alias keeps the IDL name; the prefix lands on the record tag
    ?assertMatch({match, _}, re:run(Src, <<"-type 'Point'\\(\\) :: #demo_app2_point\\{\\}\\.">>)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-type ">>)),
    ok.

%% A namespace that normalizes to nothing is a load error, not a
%% silently empty prefix of a declared namespace.

%% IDL text is UTF-8: Cyrillic doc comments land in -doc and Cyrillic
%% string constants print as <<"текст">>, not latin1 byte lists (the
%% file path — the loader — was reading bytes one per char).

utf8_doc_and_const(Config) ->
    %% /utf8 on every non-ASCII literal: erlc silently truncates plain
    %% binary literals above byte 255, so without it both the IDL
    %% fixture and the expected snippets arrive pre-mangled.
    Path = write_snippet(
        Config,
        "cyrillic.thrift",
        <<
            "namespace erl demo\n"
            "/**\n"
            " * Значение в JSON, согласно [RFC7159].\n"
            " */\n"
            "struct Value { 1: optional string data }\n"
            "/// Приветствие.\n"
            "const string GREETING = \"привет\"\n"/utf8
        >>
    ),
    {ok, Loaded} = thrift_generator_loader:load(Path),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    %% single-file document: exactly one types module comes back; the
    %% struct's IDL doc comment lands above its hrl record declaration
    %% (the direct codec functions are internal, the facade module-level)
    #{source := Src, hrl := Hrl} = hd(thrift_generator_emitter:sources(Model)),
    ?assertMatch({_, _}, binary:match(Hrl, <<"% Значение в JSON"/utf8>>)),
    ?assertMatch({_, _}, binary:match(Src, <<"demo_greeting() -> <<\"привет\">>."/utf8>>)),
    ok.

%% A file that is not valid UTF-8 is a clean error, not a cryptic
%% lexer failure or silently mangled text.

utf8_invalid_file_rejected(Config) ->
    Bad = write_snippet(Config, "bad_utf8.thrift", <<255, 254, 47, 42>>),
    ?assertMatch({error, {invalid_utf8, Bad}}, thrift_generator:parse_file(Bad)),
    ok.

loader_namespace_error(Config) ->
    Empty = write_snippet(
        Config,
        "empty_ns.thrift",
        <<"namespace erl _\nstruct P { 1: i32 x }\n">>
    ),
    ?assertMatch(
        {error, {namespace, _, <<"_">>}},
        thrift_generator_loader:load(Empty)
    ).

%% The scenario the prefix exists for: two files declaring the same
%% struct name coexist once each carries its own namespace — distinct
%% record tags, distinct type aliases, one compilation unit.

same_struct_names_coexist(Config) ->
    Included = write_snippet(
        Config,
        "second_ns.thrift",
        <<"namespace erl second\nstruct Point { 1: string y }\n">>
    ),
    MainContent =
        "namespace erl first\n"
        "include \"" ++
            unicode:characters_to_list(Included) ++
            "\"\n"
            "struct Point { 1: i32 x }\n",
    Main = write_snippet(
        Config,
        "first_ns.thrift",
        unicode:characters_to_binary(MainContent)
    ),
    {ok, Loaded} = thrift_generator_loader:load(Main),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) ->
                {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) ->
                erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),
    ?assertEqual({first_point, [x]}, first_types:record_fields(<<"Point">>)),
    ?assertEqual({second_point, [y]}, second_types:record_fields(<<"Point">>)),
    {ok, Bin1} = first_types:encode(point, {first_point, 7}),
    {ok, Bin2} = second_types:encode(point, {second_point, <<"hey">>}),
    ?assertEqual({ok, {first_point, 7}}, first_types:decode(point, Bin1)),
    ?assertEqual({ok, {second_point, <<"hey">>}}, second_types:decode(point, Bin2)),
    ok.

%% End-to-end through the generated stack: main.thrift → compiled
%% modules → server + typed client. Struct arguments and results cross
%% the wire as records; the declared exception comes back typed.

generated_loopback_buffered(Config) ->
    generated_loopback(Config, buffered).

generated_loopback_framed(Config) ->
    generated_loopback(Config, framed).

-spec generated_loopback(ct:config(), buffered | framed) -> ok.
generated_loopback(Config, Transport) ->
    ok = generate_modules(data_file(Config, "semantic/main.thrift")),
    {ok, Server} = main_main_service_server:start_link(#{
        port => 0,
        handler => thrift_generator_test_handler,
        transport => Transport
    }),
    try
        {ok, Port} = main_main_service_server:port(Server),
        {ok, Client} = main_main_service_client:start_link(#{
            host => "127.0.0.1", port => Port, transport => Transport
        }),
        try
            ?assertEqual({ok, undefined}, main_main_service_client:ping(Client)),
            ?assertEqual({ok, 12}, main_main_service_client:area(Client, 3, 4)),
            ?assertEqual(
                {ok, {shared_inner, <<"5">>}},
                main_main_service_client:fetch(Client, 5)
            ),
            ?assertEqual(
                {error, {exception, {main_failed, <<"negative id">>}}},
                main_main_service_client:fetch(Client, -1)
            ),
            check_oneway(Client)
        after
            main_main_service_client:stop(Client)
        end
    after
        main_main_service_server:stop(Server)
    end.

%% The root README's Getting Started example, compiled and executed so
%% its names cannot drift: the ping.thrift IDL and the ping_handler
%% module are the README's verbatim sources, and every codec call below
%% is a README snippet (record values are plain tuples here because the
%% suite cannot include the generated hrl at its own compile time; the
%% README spells them with record syntax).

-spec getting_started_example(ct:config()) -> ok.
getting_started_example(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Path = write_snippet(
        Config,
        "ping.thrift",
        <<
            "namespace erl ping.api\n"
            "\n"
            "struct PingRequest {\n"
            "  1: required string message\n"
            "}\n"
            "\n"
            "struct PingReply {\n"
            "  1: required string message,\n"
            "  2: i64 at_millis\n"
            "}\n"
            "\n"
            "exception NoSuchMessage {\n"
            "  1: string text\n"
            "}\n"
            "\n"
            "service Ping {\n"
            "  PingReply ping(1: PingRequest request) throws(1: NoSuchMessage err),\n"
            "  oneway void poke()\n"
            "}\n"
        >>
    ),
    {ok, _} = thrift_generator:generate(Path, #{out_dir => PrivDir}),
    lists:foreach(
        fun(File) ->
            {ok, Mod, Beam} = compile:file(filename:join(PrivDir, File), [binary, {i, PrivDir}]),
            {module, Mod} = code:load_binary(Mod, File, Beam)
        end,
        [
            "ping_api_types.erl",
            "ping_api_ping_client.erl",
            "ping_api_ping_server.erl",
            "ping_api_ping_handler.erl"
        ]
    ),
    ok = file:write_file(
        filename:join(PrivDir, "ping_handler.erl"),
        <<
            "-module(ping_handler).\n"
            "-include(\"ping_api_types.hrl\").\n"
            "\n"
            "-behaviour(ping_api_ping_handler).\n"
            "\n"
            "-export([ping/1, poke/0]).\n"
            "\n"
            "ping(#ping_api_ping_request{message = <<\"bad\">>}) ->\n"
            "    {error, {exception, #ping_api_no_such_message{text = <<\"nope\">>}}};\n"
            "ping(#ping_api_ping_request{message = Msg}) ->\n"
            "    {ok, #ping_api_ping_reply{message = <<\"pong: \", Msg/binary>>, at_millis = 0}}.\n"
            "\n"
            "poke() -> {ok, undefined}.\n"
        >>
    ),
    {ok, ping_handler, HandlerBeam} = compile:file(
        filename:join(PrivDir, "ping_handler.erl"), [binary, {i, PrivDir}]
    ),
    {module, ping_handler} = code:load_binary(ping_handler, "ping_handler.erl", HandlerBeam),
    %% the README codec facade snippets
    Req = {ping_api_ping_request, <<"hi">>},
    {ok, Bin} = ping_api_types:encode(ping_request, Req),
    {ok, Req} = ping_api_types:decode(ping_request, Bin),
    {ok, Map} = ping_api_types:decode(ping_request, Bin, #{repr => map}),
    ?assertEqual(#{message => <<"hi">>}, Map),
    {ok, Struct} = ping_api_types:decode(ping_request, Bin, #{repr => struct}),
    ?assertEqual(ping_api_ping_request, maps:get('__struct__', Struct)),
    {ok, Req} = ping_api_types:convert(ping_request, Struct, record),
    ?assertEqual(
        {error, {unknown_fields, [extra]}},
        ping_api_types:encode(ping_request, #{message => <<"hi">>, extra => 1}, #{strict => true})
    ),
    {ok, Compact} = ping_api_types:encode(ping_request, Req, #{protocol => compact}),
    {ok, Req} = ping_api_types:decode(ping_request, Compact, #{protocol => compact}),
    {ok, Json} = ping_api_types:encode(ping_request, Req, #{protocol => json}),
    {ok, Req} = ping_api_types:decode(ping_request, Json, #{protocol => json}),
    {ok, Desc} = ping_api_types:descriptor(ping_request),
    ?assertEqual({ok, Compact}, thrift_runtime:encode(Desc, Req, #{protocol => compact})),
    ?assertEqual({ok, Map}, thrift_runtime:decode(Desc, Bin, #{repr => map})),
    ?assertEqual({ok, Struct}, thrift_runtime:convert(Desc, Map, struct)),
    %% the README server/client snippet (an ephemeral port instead of 9090)
    {ok, Server} = ping_api_ping_server:start_link(#{port => 0, handler => ping_handler}),
    try
        {ok, Port} = ping_api_ping_server:port(Server),
        {ok, Client} = ping_api_ping_client:start_link(#{host => "127.0.0.1", port => Port}),
        try
            ?assertEqual(
                {ok, {ping_api_ping_reply, <<"pong: hi">>, 0}},
                ping_api_ping_client:ping(Client, {ping_api_ping_request, <<"hi">>})
            ),
            ?assertEqual(
                {error, {exception, {ping_api_no_such_message, <<"nope">>}}},
                ping_api_ping_client:ping(Client, {ping_api_ping_request, <<"bad">>})
            ),
            ok = ping_api_ping_client:poke(Client)
        after
            ok = ping_api_ping_client:stop(Client)
        end
    after
        ok = ping_api_ping_server:stop(Server)
    end.

%% The standalone CLI end to end, over the real prod escript: explicit
%% generate/check/clean commands, the `src' default output dir, the
%% freshness gate, banner-ownership clean (a hand-written file survives,
%% a nonexistent directory is a no-op) and the rejection of the legacy
%% implicit-file and `--check' grammars with usage.

-spec standalone_generate_check_clean(ct:config()) -> ok.
standalone_generate_check_clean(Config) ->
    Escript = build_prod_escript(),
    Priv = proplists:get_value(priv_dir, Config),
    Work = filename:join(Priv, "cli_work"),
    Out = filename:join(Work, "src"),
    ok = filelib:ensure_dir(filename:join(Out, "keep")),
    Idl = write_snippet(
        Config,
        "cli_standalone.thrift",
        <<"namespace erl cli_standalone\nstruct Point { 1: i32 x }\n">>
    ),
    Erl = filename:join(Out, "cli_standalone_types.erl"),
    Hrl = filename:join(Out, "cli_standalone_types.hrl"),
    Repr = filename:join(Out, "cli_standalone_types_repr.erl"),

    %% generate with the default out dir: files land in src/ of the cwd
    %% (record repr: the types module and its repr-converter module)
    {0, GenOut} = run_cli(Escript, ["generate", Idl], Work),
    ?assertMatch({_, _}, binary:match(GenOut, <<"Generated 2 module(s)">>)),
    ?assert(filelib:is_file(Erl)),
    ?assert(filelib:is_file(Hrl)),
    {ok, GenBin} = file:read_file(Erl),
    ?assertMatch({_, _}, binary:match(GenBin, <<"Autogenerated by Thrift Generator">>)),

    %% check passes on fresh output
    {0, CheckOut} = run_cli(Escript, ["check", Idl], Work),
    ?assertMatch({_, _}, binary:match(CheckOut, <<"up to date">>)),

    %% dirty one artifact: the gate fails and names the drift
    ok = file:write_file(Erl, <<"%% tampered\n">>),
    {1, DriftOut} = run_cli(Escript, ["check", Idl], Work),
    ?assertMatch({_, _}, binary:match(DriftOut, <<"out of date">>)),
    ?assertMatch({_, _}, binary:match(DriftOut, <<"cli_standalone_types.erl">>)),

    %% regenerate repairs the drift (and rewrites the tampered file)
    {0, _} = run_cli(Escript, ["generate", Idl], Work),
    {0, _} = run_cli(Escript, ["check", Idl], Work),

    %% clean removes only banner-owned files; a hand-written file next to
    %% them survives; a nonexistent directory is a successful no-op
    Hand = filename:join(Out, "hand_written.erl"),
    ok = file:write_file(Hand, <<"-module(hand_written).\n">>),
    {0, _} = run_cli(Escript, ["clean", "-o", filename:join(Priv, "no_such_dir")], Work),
    ?assert(filelib:is_file(Erl)),
    {0, CleanOut} = run_cli(Escript, ["clean"], Work),
    ?assertMatch({_, _}, binary:match(CleanOut, <<"Removed 3 generator-owned files">>)),
    ?assertNot(filelib:is_file(Erl)),
    ?assertNot(filelib:is_file(Hrl)),
    ?assertNot(filelib:is_file(Repr)),
    ?assert(filelib:is_file(Hand)),
    %% a second clean has nothing to remove
    {0, AgainOut} = run_cli(Escript, ["clean"], Work),
    ?assertMatch({_, _}, binary:match(AgainOut, <<"no generator-owned files">>)),

    %% the legacy grammar is rejected with usage, not remapped
    {1, ImplicitOut} = run_cli(Escript, [Idl], Work),
    assert_usage(ImplicitOut),
    {1, LegacyCheckOut} = run_cli(Escript, ["generate", Idl, "--check"], Work),
    assert_usage(LegacyCheckOut),
    {1, _} = run_cli(Escript, ["check", Idl, "--check"], Work),
    ok.

%% Builds _build/prod/bin/thrift_generator from the repo root and
%% returns its path. Slow on a cold build — this case is the real-CLI
%% acceptance scenario, so it pays the escriptize cost on purpose.
build_prod_escript() ->
    Rebar3 =
        case os:find_executable("rebar3") of
            false -> ct:fail("rebar3 not found on PATH");
            Path -> Path
        end,
    Root = repo_root(),
    {0, _} = run_cli(Rebar3, ["as", "prod", "escriptize"], Root),
    filename:join(Root, "_build/prod/bin/thrift_generator").

%% The suite runs from _build/test/lib/thrift_generator: four levels up
%% is the repo root (the umbrella's _build dir sits right there).
repo_root() ->
    LibDir = code:lib_dir(thrift_generator),
    filename:dirname(filename:dirname(filename:dirname(filename:dirname(LibDir)))).

%% Runs the CLI (or any executable) with the given args in Dir; returns
%% the exit status and the merged stdout/stderr output.
run_cli(Executable, Args, Dir) ->
    Port = open_port({spawn_executable, Executable}, [
        {args, Args},
        {cd, Dir},
        use_stdio,
        stderr_to_stdout,
        binary,
        exit_status
    ]),
    collect_cli(Port, []).

collect_cli(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_cli(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after 120000 ->
        port_close(Port),
        ct:fail(cli_timeout)
    end.

assert_usage(Output) ->
    ?assertMatch({_, _}, binary:match(Output, <<"Usage:">>)).

-spec check_oneway(pid()) -> ok.
check_oneway(Client) ->
    Sink = self(),
    true = register(thrift_generator_test_sink, Sink),
    try
        ok = main_main_service_client:fire(Client, 42),
        receive
            {fired, 42} -> ok
        after 5000 -> exit(oneway_not_delivered)
        end
    after
        case whereis(thrift_generator_test_sink) of
            Sink -> unregister(thrift_generator_test_sink);
            _ -> ok
        end
    end.

%% End-to-end over the map-mode fixture: structs declared with
%% `erl.struct_type = "map"` travel as maps (both key types), the
%% record-mode parent keeps its record with map-mode children inside.

-spec generated_map_mode(ct:config()) -> ok.
generated_map_mode(Config) ->
    MainPath = data_file(Config, "mapmode/mapmode.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(MainPath),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) ->
                {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam);
            ({error, {Name, Errors}}) ->
                erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),
    %% the representation contract: map mode for both key types, record
    %% mode for the parent
    ?assertEqual({map, atom}, mapmode_types:record_fields(<<"Point">>)),
    ?assertEqual({map, binary}, mapmode_types:record_fields(<<"BinPoint">>)),
    ?assertEqual({mapmode_nest, [p, b]}, mapmode_types:record_fields(<<"Nest">>)),
    %% the hrl keeps records only for record-mode structs
    {value, #{hrl := Hrl}} =
        lists:search(
            fun(E) -> maps:get(module, E) =:= mapmode_types end,
            thrift_generator_emitter:sources(Model)
        ),
    ?assertMatch(
        {match, _},
        re:run(
            Hrl,
            <<"-record\\(mapmode_nest,\\{p :: mapmode_types:'Point'\\(\\) \\| undefined,">>
        )
    ),
    ?assertMatch(
        {match, _},
        re:run(Hrl, <<"b :: mapmode_types:'BinPoint'\\(\\) \\| undefined\\}\\)\\.">>)
    ),
    ?assertMatch(nomatch, re:run(Hrl, <<"-record\\(mapmode_point">>)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-record\\(mapmode_binpoint">>)),
    %% the codec axis on a map-mode struct: the default target is the map
    {ok, PointBin} = mapmode_types:encode(point, #{x => 1, y => 2}),
    ?assertEqual({ok, #{x => 1, y => 2}}, mapmode_types:decode(point, PointBin)),
    ?assertEqual(
        %% struct maps are tagged by the wire name — map-mode structs
        %% have no record tag
        {ok, #{'__struct__' => point, x => 1, y => 2}},
        mapmode_types:decode(point, PointBin, #{repr => struct})
    ),
    %% native records (EEP-79, OTP 29+): the generated codec forwards the
    %% axis to the runtime engine untouched
    case native_supported() of
        true ->
            {ok, PointNative} = mapmode_types:decode(point, PointBin, #{repr => native}),
            ?assertEqual(mapmode_types, records:get_module(PointNative)),
            ?assertEqual(point, records:get_name(PointNative)),
            ?assertEqual({ok, PointBin}, mapmode_types:encode(point, PointNative));
        false ->
            ?assertEqual(
                {error, {unsupported_repr, native}},
                mapmode_types:decode(point, PointBin, #{repr => native})
            )
    end,
    ?assertEqual(
        {error, {no_record, point}},
        mapmode_types:convert(point, #{'__struct__' => point, x => 1, y => 2}, record)
    ),
    {ok, NestBin} =
        mapmode_types:encode(nest, {mapmode_nest, #{x => 1, y => 2}, #{<<"x">> => 5}}),
    ?assertEqual(
        {ok, {mapmode_nest, #{x => 1, y => 2}, #{<<"x">> => 5}}},
        mapmode_types:decode(nest, NestBin)
    ),
    %% e2e: maps over the wire, both key types, declared exception
    {ok, Server} =
        mapmode_map_svc_server:start_link(#{port => 0, handler => thrift_generator_mapmode_handler}),
    try
        {ok, Port} = mapmode_map_svc_server:port(Server),
        {ok, Client} = mapmode_map_svc_client:start_link(#{host => "127.0.0.1", port => Port}),
        try
            ?assertEqual(
                {ok, #{x => 2, y => 1}},
                mapmode_map_svc_client:reflect(Client, #{x => 1, y => 2})
            ),
            ?assertEqual(
                {ok, {mapmode_nest, #{x => 1, y => 2}, #{<<"x">> => 101}}},
                mapmode_map_svc_client:wrap(Client, #{x => 1, y => 2})
            ),
            ?assertEqual({ok, 12}, mapmode_map_svc_client:area(Client, 3, 4)),
            ?assertEqual(
                {error, {exception, {mapmode_oops, <<"negative width">>}}},
                mapmode_map_svc_client:area(Client, -1, 4)
            )
        after
            mapmode_map_svc_client:stop(Client)
        end
    after
        main_main_service_server:stop(Server)
    end.

%% End-to-end over the `--repr native` axis: definitions without an
%% explicit `erl.struct_type` generate as native-representation structs —
%% no record declarations anywhere, `{native, Tag}` contracts, the codec
%% defaults to runtime-minted native records (OTP 29; older releases
%% answer `{error, {unsupported_repr, native}}`). Handlers speak the
%% low-level record axis (atom-key maps) on every release.

-spec generated_native_repr(ct:config()) -> ok.
generated_native_repr(Config) ->
    MainPath = data_file(Config, "nativerepr/nativedemo.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(MainPath),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded, #{repr => native}),
    lists:foreach(
        fun
            ({ok, Name, Beam}) ->
                {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam);
            ({error, {Name, Errors}}) ->
                erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),
    %% the representation contract: native mode tagged by the snake-cased
    %% wire name, no generated from_map, no record declarations in the hrl
    ?assertEqual({native, point}, nativedemo_types:record_fields(<<"Point">>)),
    ?assertEqual({native, oops}, nativedemo_types:record_fields(<<"Oops">>)),
    ?assertEqual(
        false,
        erlang:function_exported(nativedemo_types, nativedemo_point_from_map, 1)
    ),
    {value, #{hrl := Hrl}} =
        lists:search(
            fun(E) -> maps:get(module, E) =:= nativedemo_types end,
            thrift_generator_emitter:sources(Model)
        ),
    ?assertMatch(nomatch, re:run(Hrl, <<"-record\\(nativedemo_point">>)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-type nativedemo_point\\(\\)">>)),
    %% codec roundtrip: map and record axes on every release
    {ok, PointBin} = nativedemo_types:encode(point, #{x => 1, label => <<"p">>}),
    ?assertEqual(
        {ok, #{x => 1, label => <<"p">>}},
        nativedemo_types:decode(point, PointBin, #{repr => map})
    ),
    ?assertEqual(
        {error, {no_record, point}},
        nativedemo_types:decode(point, PointBin, #{repr => record})
    ),
    {ok, Server} =
        nativedemo_nat_svc_server:start_link(#{port => 0, handler => thrift_generator_nativedemo_handler}),
    try
        {ok, Port} = nativedemo_nat_svc_server:port(Server),
        {ok, Client} = nativedemo_nat_svc_client:start_link(#{host => "127.0.0.1", port => Port}),
        try
            %% scalar results ride the wire untouched on every release
            ?assertEqual({ok, 12}, nativedemo_nat_svc_client:area(Client, 3, 4)),
            case native_supported() of
                true ->
                    {ok, PointNative} = nativedemo_types:decode(point, PointBin),
                    ?assertEqual(nativedemo_types, records:get_module(PointNative)),
                    ?assertEqual(point, records:get_name(PointNative)),
                    ?assertEqual(
                        {ok, PointBin}, nativedemo_types:encode(point, PointNative)
                    ),
                    ?assertEqual(
                        {ok, #{x => 1, label => <<"p">>}},
                        nativedemo_types:convert(point, PointNative, map)
                    ),
                    ?assertEqual(
                        {error, {no_record, point}},
                        nativedemo_types:convert(point, PointNative, record)
                    ),
                    %% e2e: generated clients decode replies through the
                    %% low-level record axis (atom-key maps for native
                    %% structs, same as map mode) — native records are
                    %% the codec axis, not the wire-call surface
                    ?assertEqual(
                        {ok, #{x => -1, label => <<"p">>}},
                        nativedemo_nat_svc_client:reflect(Client, #{x => 1, label => <<"p">>})
                    ),
                    ?assertEqual(
                        {error, {exception, #{why => <<"negative x">>}}},
                        nativedemo_nat_svc_client:reflect(Client, #{x => -5, label => <<"p">>})
                    );
                false ->
                    ?assertEqual(
                        {error, {unsupported_repr, native}},
                        nativedemo_types:decode(point, PointBin)
                    )
            end
        after
            nativedemo_nat_svc_client:stop(Client)
        end
    after
        nativedemo_nat_svc_server:stop(Server)
    end.

%% End-to-end over the Erlang-annotated fixture: an `erl.set = "ordset"`
%% annotation survives the whole pipeline — the descriptor carries
%% `ordset`, decode builds a real ordset (sorted, deduplicated) in both
%% representations and encode takes it back — while unannotated sets
%% stay plain wire lists.

-spec generated_set_impl(ct:config()) -> ok.
generated_set_impl(Config) ->
    MainPath = data_file(Config, "ErlangThriftTest.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(MainPath),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) ->
                {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam);
            ({error, {Name, Errors}}) ->
                erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),
    %% the file-wide erl.set default applies to unannotated sets; the
    %% explicit ordset on set_field wins over it — both in one struct
    {struct, CrazyFields} = test_types:struct_info(<<"CrazyNesting">>),
    {value, {2, optional, {set, {struct, {ref, test_types, <<"Insanity">>}}, ordset}, <<"set_field">>, undefined}} =
        lists:search(fun(F) -> element(4, F) =:= <<"set_field">> end, CrazyFields),
    {struct, VersioningFields} = test_types:struct_info(<<"VersioningTestV2">>),
    {value, {9, default, {set, {base, i32}, sets}, <<"newset">>, undefined}} =
        lists:search(fun(F) -> element(4, F) =:= <<"newset">> end, VersioningFields),
    %% codec roundtrip: duplicates and arbitrary order on the way in, a
    %% real ordset on the way out, map and record representations alike
    Full = #{userMap => #{'ONE' => 1}, xtructs => []},
    Empty = #{userMap => #{}, xtructs => []},
    Value = #{
        string_field => <<"s">>,
        set_field => [Full, Empty, Full],
        list_field => [],
        binary_field => <<"b">>
    },
    {ok, Bin} = test_types:encode(crazy_nesting, Value),
    {ok, #{set_field := MapOrdset}} = test_types:decode(crazy_nesting, Bin, #{repr => map}),
    ?assertEqual(lists:usort([Full, Empty]), MapOrdset),
    {ok, Rec} = test_types:decode(crazy_nesting, Bin),
    {test_crazy_nesting, <<"s">>, RecOrdset, [], <<"b">>, undefined} = Rec,
    ?assertEqual(
        lists:usort([{test_insanity, #{'ONE' => 1}, []}, {test_insanity, #{}, []}]),
        RecOrdset
    ),
    %% encode passes values through as given, so the duplicated wire
    %% above does not reproduce verbatim; the normalized value does
    {ok, NormBin} =
        test_types:encode(
            crazy_nesting,
            #{
                string_field => <<"s">>,
                set_field => lists:usort([Full, Empty]),
                list_field => [],
                binary_field => <<"b">>
            }
        ),
    ?assertEqual({ok, NormBin}, test_types:encode(crazy_nesting, Rec)),
    %% the file-wide sets default: unannotated sets decode as sets
    %% collections, encode takes them back (a sets input — no coercion)
    {ok, VBin} = test_types:encode(versioning_test_v2, #{newset => sets:from_list([3, 1, 2])}),
    {ok, #{newset := NewSet}} = test_types:decode(versioning_test_v2, VBin, #{repr => map}),
    ?assertEqual(sets:from_list([1, 2, 3]), NewSet),
    ?assertEqual({ok, VBin}, test_types:encode(versioning_test_v2, #{newset => NewSet})),
    ok.

%% Generates and loads the modules for the semantic fixture. Safe to
%% call repeatedly: `code:load_binary` replaces prior versions.

-spec generate_modules(binary()) -> ok.
generate_modules(MainPath) ->
    {ok, Loaded} = thrift_generator_loader:load(MainPath),
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) ->
                {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam);
            ({error, {Name, Errors}}) ->
                erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),
    ok.

%% Helpers

%% Native records (EEP-79) exist from OTP 29 on; the CI matrix runs 28 too.
native_supported() ->
    list_to_integer(erlang:system_info(otp_release)) >= 29.

parse_data_file(Config, Name) ->
    File = filename:join(proplists:get_value(data_dir, Config), Name),
    {ok, Doc} = thrift_generator:parse_file(File),
    Doc.

data_file(Config, Relative) ->
    %% The loader deals in absolute binary paths.
    unicode:characters_to_binary(
        filename:join(proplists:get_value(data_dir, Config), Relative)
    ).

write_snippet(Config, Name, Content) ->
    Path = filename:join(proplists:get_value(priv_dir, Config), Name),
    ok = file:write_file(Path, Content),
    Path.

write_nested_snippet(Config, RelativePath, Content) ->
    Path = filename:join(proplists:get_value(priv_dir, Config), RelativePath),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content),
    Path.

is_payload(Node, RecordSample) ->
    element(1, Node#thrift_generator_node.payload) =:= element(1, RecordSample).

count_by_kind(Definitions) ->
    lists:foldl(
        fun(Node, Acc) -> maps:update_with(Node#thrift_generator_node.type_module, fun(V) -> V + 1 end, 1, Acc) end,
        #{},
        Definitions
    ).

find_definition(Definitions, KindModule, Name) ->
    [Node] = [
        N
     || N <- Definitions,
        N#thrift_generator_node.type_module =:= KindModule,
        definition_name(N) =:= Name
    ],
    Node.

definition_name(#thrift_generator_node{payload = Payload}) ->
    element(2, Payload).

find_header(Headers, Scope) ->
    [Node] = [
        N
     || N <- Headers,
        is_payload(N, #thrift_generator_namespace{}),
        (N#thrift_generator_node.payload)#thrift_generator_namespace.scope =:= Scope
    ],
    Node.

find_function(Functions, Name) ->
    [Node] = [
        F
     || F <- Functions,
        (F#thrift_generator_node.payload)#thrift_generator_function.name =:= Name
    ],
    Node.

field_tuples(Fields) ->
    [
        {Id, Required, Type, FieldName}
     || F <- Fields,
        #thrift_generator_field{id = Id, required = Required, type = Type, name = FieldName} <-
            [F#thrift_generator_node.payload]
    ].

payload(Node) ->
    Node#thrift_generator_node.payload.
