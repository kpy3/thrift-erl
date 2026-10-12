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
    loader_duplicate_module/1,
    loader_missing_include/1,
    loader_namespace_prefix/1,
    loader_namespace_error/1,
    utf8_doc_and_const/1,
    utf8_invalid_file_rejected/1,
    same_struct_names_coexist/1,
    cross_module_typedef/1,
    cross_module_include_qualifier/1,
    generated_loopback_buffered/1,
    generated_loopback_framed/1,
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
        loader_duplicate_module,
        loader_missing_include,
        loader_namespace_prefix,
        loader_namespace_error,
        utf8_doc_and_const,
        utf8_invalid_file_rejected,
        same_struct_names_coexist,
        cross_module_typedef,
        cross_module_include_qualifier,
        generated_loopback_buffered,
        generated_loopback_framed,
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
    ?assertEqual(<<"main">>, Model#tg_model.root),
    [MainMod, SharedMod] = Model#tg_model.modules,

    ?assertEqual(<<"main">>, MainMod#tg_module.name),
    ?assertEqual([SharedPath], MainMod#tg_module.includes),

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
    ?assertEqual(<<"shared.BaseService">>, MainService#tg_service.extends),
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
    ok.

loader_duplicate_module(Config) ->
    One = data_file(Config, "semantic/dup_one.thrift"),
    Two = data_file(Config, "semantic/dup_two.thrift"),
    ?assertMatch(
        {error, {duplicate_module, <<"duplicated">>, One, Two}},
        thrift_generator_loader:load(One)
    ).

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
    %% single-file document: exactly one types module comes back
    #{source := Src} = hd(thrift_generator_emitter:sources(Model)),
    ?assertMatch({_, _}, binary:match(Src, <<"-doc(\"Значение в JSON"/utf8>>)),
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
    {ok, Bin1} = first_types:encode_first_point({first_point, 7}),
    {ok, Bin2} = second_types:encode_second_point({second_point, <<"hey">>}),
    ?assertEqual({ok, {first_point, 7}}, first_types:decode_first_point(Bin1)),
    ?assertEqual({ok, {second_point, <<"hey">>}}, second_types:decode_second_point(Bin2)),
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
    {ok, PointBin} = mapmode_types:encode_mapmode_point(#{x => 1, y => 2}),
    ?assertEqual({ok, #{x => 1, y => 2}}, mapmode_types:decode_mapmode_point(PointBin)),
    ?assertEqual(
        %% struct maps are tagged by the wire name — map-mode structs
        %% have no record tag
        {ok, #{'__struct__' => point, x => 1, y => 2}},
        mapmode_types:decode_mapmode_point(PointBin, struct)
    ),
    %% native records (EEP-79, OTP 29+): the generated codec forwards the
    %% axis to the runtime engine untouched
    case native_supported() of
        true ->
            {ok, PointNative} = mapmode_types:decode_mapmode_point(PointBin, native),
            ?assertEqual(mapmode_types, records:get_module(PointNative)),
            ?assertEqual(point, records:get_name(PointNative)),
            ?assertEqual({ok, PointBin}, mapmode_types:encode_mapmode_point(PointNative));
        false ->
            ?assertEqual(
                {error, {unsupported_repr, native}},
                mapmode_types:decode_mapmode_point(PointBin, native)
            )
    end,
    ?assertEqual(
        {error, {no_record, point}},
        mapmode_types:convert(#{'__struct__' => point, x => 1, y => 2}, record)
    ),
    {ok, NestBin} =
        mapmode_types:encode_mapmode_nest({mapmode_nest, #{x => 1, y => 2}, #{<<"x">> => 5}}),
    ?assertEqual(
        {ok, {mapmode_nest, #{x => 1, y => 2}, #{<<"x">> => 5}}},
        mapmode_types:decode_mapmode_nest(NestBin)
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
    {ok, PointBin} = nativedemo_types:encode_nativedemo_point(#{x => 1, label => <<"p">>}),
    ?assertEqual(
        {ok, #{x => 1, label => <<"p">>}},
        nativedemo_types:decode_nativedemo_point(PointBin, map)
    ),
    ?assertEqual(
        {error, {no_record, point}},
        nativedemo_types:decode_nativedemo_point(PointBin, record)
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
                    {ok, PointNative} = nativedemo_types:decode_nativedemo_point(PointBin),
                    ?assertEqual(nativedemo_types, records:get_module(PointNative)),
                    ?assertEqual(point, records:get_name(PointNative)),
                    ?assertEqual(
                        {ok, PointBin}, nativedemo_types:encode_nativedemo_point(PointNative)
                    ),
                    ?assertEqual(
                        {ok, #{x => 1, label => <<"p">>}},
                        nativedemo_types:convert(PointNative, map)
                    ),
                    ?assertEqual(
                        {error, {no_record, point}},
                        nativedemo_types:convert(PointNative, record)
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
                        nativedemo_types:decode_nativedemo_point(PointBin)
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
    {ok, Bin} = test_types:encode_test_crazy_nesting(Value),
    {ok, #{set_field := MapOrdset}} = test_types:decode_test_crazy_nesting(Bin, map),
    ?assertEqual(lists:usort([Full, Empty]), MapOrdset),
    {ok, Rec} = test_types:decode_test_crazy_nesting(Bin),
    {test_crazy_nesting, <<"s">>, RecOrdset, [], <<"b">>, undefined} = Rec,
    ?assertEqual(
        lists:usort([{test_insanity, #{'ONE' => 1}, []}, {test_insanity, #{}, []}]),
        RecOrdset
    ),
    %% encode passes values through as given, so the duplicated wire
    %% above does not reproduce verbatim; the normalized value does
    {ok, NormBin} =
        test_types:encode_test_crazy_nesting(
            #{
                string_field => <<"s">>,
                set_field => lists:usort([Full, Empty]),
                list_field => [],
                binary_field => <<"b">>
            }
        ),
    ?assertEqual({ok, NormBin}, test_types:encode_test_crazy_nesting(Rec)),
    %% the file-wide sets default: unannotated sets decode as sets
    %% collections, encode takes them back (a sets input — no coercion)
    {ok, VBin} = test_types:encode_test_versioning_test_v2(#{newset => sets:from_list([3, 1, 2])}),
    {ok, #{newset := NewSet}} = test_types:decode_test_versioning_test_v2(VBin, map),
    ?assertEqual(sets:from_list([1, 2, 3]), NewSet),
    ?assertEqual({ok, VBin}, test_types:encode_test_versioning_test_v2(#{newset => NewSet})),
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
