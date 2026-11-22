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

%% Unit tests for the emitter on inline snippets: every generated module
%% must compile in memory, load, and expose the introspection surface.
%% End-to-end calls through generated client/server live in
%% thrift_generator_SUITE.

-module(thrift_generator_emitter_test).

-include_lib("stdlib/include/assert.hrl").
-include_lib("thrift_generator/include/thrift_generator.hrl").
-include_lib("thrift_generator/include/thrift_generator_model.hrl").

-export([
    compile_all_modules_test/0,
    struct_info_descriptor_test/0,
    enum_info_descriptor_test/0,
    function_info_descriptor_test/0,
    service_info_descriptor_test/0,
    record_fields_and_defaults_test/0,
    map_representation_test/0,
    handler_callbacks_test/0,
    source_is_readable_text_test/0,
    types_hrl_content_test/0,
    schema_codec_api_test/0,
    schema_default_repr_test/0,
    schema_convert_is_typed_test/0,
    schema_onepass_and_fallback_test/0,
    enum_and_const_helpers_test/0,
    set_annotation_test/0,
    sum_union_test/0,
    service_method_name_clash_test/0,
    namespace_set_default_test/0,
    namespace_prefix_test/0,
    type_definitions_test/0,
    native_representation_test/0,
    repr_option_test/0,
    option_axes_test/0,
    doc_pipeline_test/0,
    record_name_annotation_test/0,
    enum_case_test/0
]).

-define(SNIPPET,
    "struct Inner { 1: string name }\n"
    "struct Outer { 1: Inner inner, 2: i32 count = 10 }\n"
    "enum Color { RED, GREEN = 10, BLUE }\n"
    "exception Failed { 1: string reason }\n"
    "const i32 BASE = 10\n"
    "service Svc {\n"
    "  void ping(),\n"
    "  i32 area(1: i32 w, 2: i32 h) throws (1: Failed f),\n"
    "  oneway void fire(1: i32 code),\n"
    "  Outer fetch(1: i64 id)\n"
    "}\n"
).

-define(NS_SNIPPET,
    "namespace erl demo.widgets\n"
    "struct Point { 1: i32 x = 5 }\n"
    "enum Color { RED, GREEN = 10 }\n"
    "const i32 BASE = 10\n"
    "const string GREETING = \"hi\"\n"
    "service Svc { void ping() }\n"
).

-define(SUM_SNIPPET,
    "namespace erl t (erl.union_type = \"sum\")\n"
    "union Value { 1: i64 int_val, 2: string str_val, 3: Inner nested }\n"
    "union Legacy { 1: i64 n } (erl.union_type = \"record\")\n"
    "struct Inner { 1: string name }\n"
).

-define(DOC_SNIPPET,
    "/// The request payload.\n"
    "struct Inner { /** Shape it. */ 1: string name }\n"
    "/** Color codes. */\n"
    "enum Color { RED, GREEN = 10 }\n"
    "const i32 BASE = 10\n"
    "/** Waves at the caller. */\n"
    "service Svc {\n"
    "  /** Ping it. */\n"
    "  void ping(),\n"
    "  /** Fire it. */\n"
    "  oneway void fire(1: i32 code)\n"
    "}\n"
).

-spec generate() -> [thrift_generator_emitter:compiled()].
generate() ->
    {ok, Doc} = thrift_generator:parse_string(?SNIPPET),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),
    Results.

%%--------------------------------------------------------------------

compile_all_modules_test() ->
    Results = generate(),
    Names = [Name || {ok, Name, _} <- Results],
    ?assertEqual([t_svc_client, t_svc_handler, t_svc_server, t_types, t_types_repr], lists:sort(Names)),
    ok.

struct_info_descriptor_test() ->
    generate(),
    ?assertEqual(
        {struct, [
            {1, default, {struct, {ref, t_types, <<"Inner">>}}, <<"inner">>, undefined},
            {2, default, {base, i32}, <<"count">>, 10}
        ]},
        t_types:struct_info(<<"Outer">>)
    ),
    ?assertEqual(
        {exception, [{1, default, {base, string}, <<"reason">>, undefined}]},
        t_types:struct_info(<<"Failed">>)
    ),
    ?assertEqual(error, t_types:struct_info(<<"Missing">>)),
    ok.

enum_info_descriptor_test() ->
    generate(),
    ?assertEqual([{0, 'RED'}, {10, 'GREEN'}, {11, 'BLUE'}], t_types:enum_info(<<"Color">>)),
    ?assertEqual(error, t_types:enum_info(<<"Nope">>)),
    ok.

function_info_descriptor_test() ->
    generate(),
    ?assertEqual(
        {struct,
            {struct, [
                {1, default, {base, i32}, <<"w">>, undefined},
                {2, default, {base, i32}, <<"h">>, undefined}
            ]}},
        t_types:function_info(<<"area">>, params)
    ),
    ?assertEqual(false, t_types:function_info(<<"area">>, oneway)),
    ?assertEqual({base, i32}, t_types:function_info(<<"area">>, reply)),
    ?assertEqual(
        [{1, default, {struct, {ref, t_types, <<"Failed">>}}, <<"f">>, undefined}],
        t_types:function_info(<<"area">>, exceptions)
    ),
    %% void functions have no reply descriptor.
    ?assertEqual(undefined, t_types:function_info(<<"ping">>, reply)),
    ?assertEqual([], t_types:function_info(<<"ping">>, exceptions)),
    %% oneway flags propagate; the wire reply type stays undefined.
    ?assertEqual(true, t_types:function_info(<<"fire">>, oneway)),
    ?assertEqual(error, t_types:function_info(<<"nope">>, params)),
    ok.

service_info_descriptor_test() ->
    generate(),
    %% The server module unwraps its service from the types module's
    %% per-file map: the runtime expects a flat function map.
    Info = t_svc_server:service_info(),
    ?assertEqual([<<"area">>, <<"fetch">>, <<"fire">>, <<"ping">>], lists:sort(maps:keys(Info))),
    ?assertEqual(true, maps:get(oneway, maps:get(<<"fire">>, Info))),
    ?assertEqual({base, i32}, maps:get(reply, maps:get(<<"area">>, Info))),
    %% The types module keeps all services of the file.
    ?assertEqual([<<"Svc">>], maps:keys(t_types:service_info())),
    ok.

record_fields_and_defaults_test() ->
    generate(),
    ?assertEqual({outer, [inner, count]}, t_types:record_fields(<<"Outer">>)),
    ?assertEqual(none, t_types:record_fields(<<"Missing">>)),
    ok.

map_representation_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "struct M { 1: i32 x } (erl.struct_type = \"map\")\n"
    ),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    [{ok, t_types, Beam}] = thrift_generator_emitter:compile_sources(Model),
    {module, t_types} = code:load_binary(t_types, "t_types.erl", Beam),
    ?assertEqual({map, atom}, t_types:record_fields(<<"M">>)),
    ok.

handler_callbacks_test() ->
    Results = generate(),
    {ok, t_svc_handler, Beam} = lists:keyfind(t_svc_handler, 2, Results),
    {module, t_svc_handler} = code:load_binary(t_svc_handler, "Svc_handler.erl", Beam),
    ?assertEqual(
        lists:sort([{fire, 1}, {ping, 0}, {fetch, 1}, {area, 2}]),
        lists:sort(t_svc_handler:behaviour_info(callbacks))
    ),
    ok.

source_is_readable_text_test() ->
    {ok, Doc} = thrift_generator:parse_string(?SNIPPET),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Sources = thrift_generator_emitter:sources(Model),
    ClientSrc = entry_source(t_svc_client, Sources),
    ?assertMatch(
        {match, _},
        re:run(ClientSrc, <<"area\\(Client, P1, P2\\) -> area\\(Client, P1, P2, 5000\\).">>)
    ),
    TypesSrc = entry_source(t_types, Sources),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-record\\(outer,\\{inner :: 'Inner'\\(\\) \\| undefined,">>)
    ),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-type 'Outer'\\(\\) :: #outer\\{\\}\\.">>)),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-export_type\\(\\['Inner'/0,'Outer'/0,'Failed'/0,'Color'/0\\]\\)\\.">>)
    ),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"struct_info\\(<<\"Outer\">>\\)">>)),
    ok.

types_hrl_content_test() ->
    {ok, Doc} = thrift_generator:parse_string(?SNIPPET),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Sources = thrift_generator_emitter:sources(Model),
    Hrl = entry_hrl(t_types, Sources),
    ?assertMatch({match, _}, re:run(Hrl, <<"-ifndef\\(T_HRL\\)\\.">>)),
    ?assertMatch({match, _}, re:run(Hrl, <<"-define\\(T_HRL, true\\)\\.">>)),
    ?assertMatch(
        {match, _},
        re:run(Hrl, <<"-record\\(outer,\\{inner :: t_types:'Inner'\\(\\) \\| undefined,">>)
    ),
    ?assertMatch({match, _}, re:run(Hrl, <<"count = 10 :: integer\\(\\) \\| undefined\\}\\)\\.">>)),
    %% Type definitions live in the types module and are referenced
    %% remotely; the hrl carries records and constant macros only.
    ?assertMatch(nomatch, re:run(Hrl, <<"-type ">>)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-export_type">>)),
    %% The banner names the generator with its version and is separated
    %% from the code by a blank line. The version comes from the running
    %% application so a release bump does not stale the assertion.
    {ok, Vsn} = application:get_key(thrift_generator, vsn),
    ?assertMatch(
        {match, _},
        re:run(Hrl, ["%% Autogenerated by Thrift Generator \\(", Vsn, "\\)"])
    ),
    ?assertMatch({match, _}, re:run(Hrl, <<"Do not edit\\.\\n\\n-ifndef">>)),
    TypesSrc = entry_source(t_types, Sources),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-type 'Outer'\\(\\) :: #outer\\{\\}\\.">>)),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-type 'Color'\\(\\) :: 'RED' \\| 'GREEN' \\| 'BLUE'\\.">>)),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-export_type\\(\\['Inner'/0,'Outer'/0,'Failed'/0,'Color'/0\\]\\)\\.">>)
    ),
    ?assertMatch({match, _}, re:run(Hrl, <<"-define\\(BASE, 10\\)\\.">>)),
    ?assertMatch({match, _}, re:run(Hrl, <<"-endif\\.">>)),
    ok.

%% The type-first schema facade: canonical type atoms (the snake-cased
%% IDL name, no namespace prefix) select the schema; encode/decode take
%% option maps whose defaults come from the schema; convert and
%% descriptor resolve the schema explicitly, never through a tag index.

schema_codec_api_test() ->
    generate(),
    Record = {outer, {inner, <<"x">>}, 42},
    Map = #{inner => #{name => <<"x">>}, count => 42},
    {ok, Bin} = t_types:encode(outer, Record),
    ?assertEqual({ok, Record}, t_types:decode(outer, Bin)),
    ?assertEqual({ok, Map}, t_types:decode(outer, Bin, #{repr => map})),
    %% struct representation: the tag survives as identity metadata
    {ok, Struct} = t_types:decode(outer, Bin, #{repr => struct}),
    ?assertEqual(outer, maps:get('__struct__', Struct)),
    %% typed conversion resolves the schema from the type atom
    ?assertEqual({ok, Record}, t_types:convert(outer, Struct, record)),
    ?assertEqual({ok, Map}, t_types:convert(outer, Record, map)),
    %% descriptors are the named refs the runtime one-pass dispatch needs
    ?assertEqual({ok, {struct, {ref, t_types, <<"Outer">>}}}, t_types:descriptor(outer)),
    ?assertEqual({ok, {struct, {ref, t_types, <<"Inner">>}}}, t_types:descriptor(inner)),
    %% unknown types answer everywhere the facade resolves them
    ?assertEqual({error, {unknown_type, missing}}, t_types:descriptor(missing)),
    ?assertEqual({error, {unknown_type, missing}}, t_types:encode(missing, #{})),
    ?assertEqual({error, {unknown_type, missing}}, t_types:encode(missing, #{}, #{})),
    ?assertEqual({error, {unknown_type, missing}}, t_types:decode(missing, Bin)),
    ?assertEqual({error, {unknown_type, missing}}, t_types:decode(missing, Bin, #{})),
    ?assertEqual({error, {unknown_type, missing}}, t_types:convert(missing, Record, record)),
    %% the old wrappers and the tag index are gone
    ?assertNot(erlang:function_exported(t_types, encode_outer, 1)),
    ?assertNot(erlang:function_exported(t_types, encode_outer, 2)),
    ?assertNot(erlang:function_exported(t_types, decode_outer, 1)),
    ?assertNot(erlang:function_exported(t_types, decode_outer, 2)),
    ?assertNot(erlang:function_exported(t_types, decode_outer, 3)),
    ?assertNot(erlang:function_exported(t_types, outer_from_map, 1)),
    ?assertNot(erlang:function_exported(t_types, convert, 2)),
    ?assertNot(erlang:function_exported(t_types, tag_index, 0)),
    %% the old wrappers of every other struct are gone too
    ?assertNot(erlang:function_exported(t_types, encode_inner, 1)),
    ?assertNot(erlang:function_exported(t_types, decode_failed, 1)),
    ?assertNot(erlang:function_exported(t_types, failed_from_map, 1)),
    %% whole-input decoding: trailing bytes and truncation fail
    ?assertEqual({error, trailing}, t_types:decode(outer, <<Bin/binary, 0>>)),
    ?assertEqual(
        {error, truncated},
        t_types:decode(outer, binary:part(Bin, 0, byte_size(Bin) - 1))
    ),
    %% compact and JSON travel through the same option vocabulary
    {ok, Compact} = t_types:encode(outer, Record, #{protocol => compact}),
    ?assertEqual(Bin =/= Compact, true),
    ?assertEqual({ok, Record}, t_types:decode(outer, Compact, #{protocol => compact})),
    ?assertEqual(
        {ok, Map},
        t_types:decode(outer, Compact, #{protocol => compact, repr => map})
    ),
    {ok, Json} = t_types:encode(outer, Record, #{protocol => json}),
    ?assertEqual({ok, Record}, t_types:decode(outer, Json, #{protocol => json})),
    ?assertEqual({ok, Map}, t_types:decode(outer, Json, #{protocol => json, repr => map})),
    %% strict encode checks the input map against the declared fields
    ?assertEqual(
        {error, {unknown_fields, [typo]}},
        t_types:encode(outer, #{inner => {inner, <<"x">>}, count => 1, typo => 2}, #{strict => true})
    ),
    %% option validation errors surface through the facade
    ?assertEqual({error, {unknown_option, repr}}, t_types:encode(outer, Record, #{repr => map})),
    ?assertEqual({error, {unknown_option, strict}}, t_types:decode(outer, Bin, #{strict => true})),
    %% the schema default fills an absent repr: a protocol-only options
    %% map decodes into the struct's default representation
    ?assertEqual({ok, Record}, t_types:decode(outer, Bin, #{protocol => binary})),
    %% a non-map options argument answers the documented bad_option error,
    %% it does not crash on map operations
    ?assertEqual(
        {error, {bad_option, {options, record, [map]}}},
        t_types:decode(outer, Bin, record)
    ),
    ok.

%% The schema-selected default representation: sum unions decode into
%% their tagged tuple, map-mode structs into the atom-keyed map,
%% record-mode structs into the record and native-mode structs into the
%% runtime-minted native record (or the unsupported_repr error on OTP 28).

schema_default_repr_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "namespace erl t (erl.union_type = \"sum\")\n"
        "union Value { 1: i64 int_val, 2: string str_val }\n"
        "struct M { 1: i32 x } (erl.struct_type = \"map\")\n"
        "struct P { 1: i32 y }\n"
        "struct N { 1: i32 z } (erl.struct_type = \"native\")\n"
    ),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),
    %% sum union: the tagged tuple is the default
    {ok, ValueBin} = t_types:encode(value, {str_val, <<"hi">>}),
    ?assertEqual({ok, {str_val, <<"hi">>}}, t_types:decode(value, ValueBin)),
    %% map mode: the atom-keyed map is the default
    {ok, MapBin} = t_types:encode(m, #{x => 1}),
    ?assertEqual({ok, #{x => 1}}, t_types:decode(m, MapBin)),
    %% record mode: the record is the default
    {ok, RecordBin} = t_types:encode(p, {p, 5}),
    ?assertEqual({ok, {p, 5}}, t_types:decode(p, RecordBin)),
    %% native mode: the runtime-minted record, or unsupported on OTP 28
    {ok, NativeBin} = t_types:encode(n, #{z => 3}),
    case thrift_runtime_native:supported() of
        true ->
            {ok, Native} = t_types:decode(n, NativeBin),
            ?assertEqual(n, records:get_name(Native)),
            ?assertEqual({ok, NativeBin}, t_types:encode(n, Native));
        false ->
            ?assertEqual({error, {unsupported_repr, native}}, t_types:decode(n, NativeBin))
    end,
    ok.

enum_and_const_helpers_test() ->
    generate(),
    ?assertEqual({ok, 0}, t_types:color_to_int('RED')),
    ?assertEqual({ok, 10}, t_types:color_to_int('GREEN')),
    ?assertEqual({ok, 11}, t_types:color_to_int('BLUE')),
    ?assertEqual({ok, 7}, t_types:color_to_int(7)),
    ?assertEqual(error, t_types:color_to_int(mauve)),
    ?assertEqual({ok, 'GREEN'}, t_types:color_from_int(10)),
    ?assertEqual(error, t_types:color_from_int(99)),
    ?assertEqual(10, t_types:base()),
    ok.

%% erl.set picks the in-process set implementation. The wire encoding
%% stays a list; descriptors carry the impl, hrl types name the stdlib
%% collection, decode/encode convert both ways.

set_annotation_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "typedef set<i32> (erl.set = \"ordset\") OrdInts\n"
        "struct Bag {\n"
        "  1: set<i32> plain,\n"
        "  2: set<i32> (erl.set = \"ordset\") ords,\n"
        "  3: set<string> (erl.set = \"sets\") tags,\n"
        "  4: set<set<i32>> nested,\n"
        "  5: OrdInts via_typedef\n"
        "}\n"
    ),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),

    %% Descriptors carry the impl as the third element; plain sets keep
    %% `list` and hand-written 2-tuples stay valid.
    ?assertEqual(
        {struct, [
            {1, default, {set, {base, i32}, list}, <<"plain">>, undefined},
            {2, default, {set, {base, i32}, ordset}, <<"ords">>, undefined},
            {3, default, {set, {base, string}, sets}, <<"tags">>, undefined},
            {4, default, {set, {set, {base, i32}, list}, list}, <<"nested">>, undefined},
            {5, default, {set, {base, i32}, ordset}, <<"via_typedef">>, undefined}
        ]},
        t_types:struct_info(<<"Bag">>)
    ),
    Sources = thrift_generator_emitter:sources(Model),
    Hrl = entry_hrl(t_types, Sources),
    ?assertMatch({match, _}, re:run(Hrl, <<"plain :: \\[integer\\(\\)\\]">>)),
    ?assertMatch({match, _}, re:run(Hrl, <<"ords :: ordsets:ordset\\(integer\\(\\)\\)">>)),
    ?assertMatch({match, _}, re:run(Hrl, <<"tags :: sets:set\\(binary\\(\\)\\)">>)),

    %% Encode accepts each implementation's input shape, decode builds
    %% it back: ordsets sort and dedup, sets v2 dedup.
    {ok, Bin} = t_types:encode(bag, #{
        plain => [9, 9, 1],
        ords => ordsets:from_list([3, 1, 2]),
        tags => sets:from_list([<<"b">>, <<"a">>]),
        nested => [ordsets:from_list([1, 2])],
        via_typedef => [7]
    }),
    {ok, Bag} = t_types:decode(bag, Bin, #{repr => map}),
    ?assertEqual(#{plain => [9, 9, 1]}, maps:with([plain], Bag)),
    ?assertEqual([1, 2, 3], maps:get(ords, Bag)),
    ?assertEqual(sets:from_list([<<"a">>, <<"b">>]), maps:get(tags, Bag)),
    ?assertEqual([[1, 2]], maps:get(nested, Bag)),
    ?assertEqual([7], maps:get(via_typedef, Bag)),

    %% Record representation: set fields become record elements of the
    %% same shapes, and encode auto-detects them back.
    {ok, Record} = t_types:decode(bag, Bin, #{repr => record}),
    {bag, Plain, Ords, Tags, Nested, ViaTypedef} = Record,
    ?assertEqual([9, 9, 1], Plain),
    ?assertEqual([1, 2, 3], Ords),
    ?assertEqual(sets:from_list([<<"a">>, <<"b">>]), Tags),
    ?assertEqual([[1, 2]], Nested),
    ?assertEqual([7], ViaTypedef),
    ?assertEqual({ok, Bin}, t_types:encode(bag, Record)),

    %% The wire codec itself stays list-shaped: 2-tuple descriptors and
    %% raw lists roundtrip through thrift_runtime_binary untouched.
    WireDesc = {set, {base, i32}},
    {ok, WireIo} = thrift_runtime_binary:encode(WireDesc, [1, 2]),
    WireBin = iolist_to_binary(WireIo),
    ?assertEqual({ok, [1, 2], <<>>}, thrift_runtime_binary:decode(WireDesc, WireBin)),
    ok.

%% The namespace-level erl.set is the file-wide default: unannotated
%% sets compile to the default impl, an explicit type-level annotation
%% wins, and a set field's record default builds the declared
%% collection instead of the wire-shaped literal.

%% erl.union_type = "sum" turns unions into tagged-tuple sums: no
%% record, the exported `'Name'()` alias in the types module is the
%% type, record_fields carries {sum, Atoms} and the type-first convert
%% resolves the union by its canonical type atom. The wire stays the
%% standard single-field struct.

sum_union_test() ->
    {ok, Doc} = thrift_generator:parse_string(?SUM_SNIPPET),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),

    ?assertEqual({sum, [int_val, str_val, nested]}, t_types:record_fields(<<"Value">>)),
    ?assertEqual({legacy, [n]}, t_types:record_fields(<<"Legacy">>)),
    ?assertEqual(
        {ok, {struct, {ref, t_types, <<"Value">>}}},
        t_types:descriptor(value)
    ),

    Sources = thrift_generator_emitter:sources(Model),
    Hrl = entry_hrl(t_types, Sources),
    TypesSrc = entry_source(t_types, Sources),
    %% the alias is the union's type — the original IDL name, in the
    %% types module; the hrl declares no record for the union
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-type 'Value'\\(\\) ::">>)),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"\\{int_val, integer\\(\\)\\}">>)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-record\\(value,">>)),

    {ok, Bin} = t_types:encode(value, {str_val, <<"hi">>}),
    {ok, {str_val, <<"hi">>}} = t_types:decode(value, Bin),
    {ok, NestedBin} = t_types:encode(value, {nested, {inner, <<"n">>}}),
    {ok, {nested, {inner, <<"n">>}}} = t_types:decode(value, NestedBin),

    %% typed conversion reshapes the payload; the tagged tuple survives
    %% every representation axis
    ?assertEqual({ok, {int_val, 7}}, t_types:convert(value, {int_val, 7}, record)),
    {ok, {nested, Payload}} = t_types:convert(value, {nested, {inner, <<"n">>}}, map),
    ?assertEqual(#{name => <<"n">>}, Payload),

    %% An unknown tag and a malformed wire union are tagged errors.
    ?assertMatch({error, {value_does_not_match_type, _}}, t_types:encode(value, {bogus, 1})),
    ?assertMatch({error, {invalid_union, _}}, t_types:decode(value, <<0>>)),
    ok.

%% Field atoms shared by several sum unions of one module are legal,
%% common Thrift (per-resource result unions). Each union's own encode/
%% decode stays exact, and the typed convert resolves the schema from
%% the type atom: the shared atom is no longer context-free — First's
%% `n' carries an i64, Second's an Inner, and conversion type-checks the
%% payload against the SELECTED union's field.

schema_convert_is_typed_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "namespace erl t (erl.union_type = \"sum\")\n"
        "struct Inner { 1: string name }\n"
        "union First { 1: i64 n, 2: Inner s }\n"
        "union Second { 1: Inner n }\n"
    ),
    Loaded = [
        #tg_loaded{name = <<"t">>, prefix = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}
    ],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),

    %% per-union codecs are exact regardless of the shared atom
    {ok, FirstBin} = t_types:encode(first, {n, 5}),
    {ok, {n, 5}} = t_types:decode(first, FirstBin),
    {ok, SecondBin} = t_types:encode(second, {n, {t_inner, <<"x">>}}),
    {ok, {n, {t_inner, <<"x">>}}} = t_types:decode(second, SecondBin),

    %% the typed convert picks each union's own schema: First's i64
    %% payload converts under `first', Second's Inner payload under
    %% `second' — no last-declaration-wins tag index
    {ok, {n, 5}} = t_types:convert(first, {n, 5}, map),
    {ok, {n, {t_inner, <<"x">>}}} = t_types:convert(second, {n, {t_inner, <<"x">>}}, record),
    %% the payload reshapes per the selected union's field type
    {ok, {n, #{name := <<"x">>}}} = t_types:convert(second, {n, {t_inner, <<"x">>}}, map),
    %% an i64 payload under Second's struct-typed field is a loud misuse,
    %% not a silent conversion
    ?assertError({value_does_not_match_type, _}, t_types:convert(second, {n, 5}, record)),
    ok.

%% The facade keeps the binary named-ref fast path: a generated encode
%% or decode reaches `thrift_runtime_binary's one-pass repr dispatch for
%% the literal ref descriptor — its persistent_term codec cache goes
%% cold -> populated with the struct's {Encode, Decode} pair — and the
%% cached one-pass functions agree with the facade answers. Mixed-
%% nesting values (a map-nested child inside a record parent) miss the
%% one-pass family and fall back to the two-pass path with identical
%% bytes and identical decode results.

schema_onepass_and_fallback_test() ->
    generate(),
    Record = {outer, {inner, <<"x">>}, 42},
    Desc = {struct, {ref, t_types, <<"Outer">>}},
    CacheKey = {thrift_runtime_binary, repr_codec_mfa, t_types},
    %% encode: the facade engages the one-pass dispatch — after a cold
    %% cache the repr codec probe cached Outer's {Name, repr} pair, and
    %% the cached one-pass encoder produces the identical bytes
    true = persistent_term:erase(CacheKey),
    {ok, Bin} = t_types:encode(outer, Record),
    {Encode, _} = maps:get({<<"Outer">>, record}, persistent_term:get(CacheKey)),
    {ok, EncodeIo} = t_types:Encode(Record),
    ?assertEqual(Bin, iolist_to_binary(EncodeIo)),
    %% decode: same engagement on the way back
    true = persistent_term:erase(CacheKey),
    {ok, Record} = t_types:decode(outer, Bin),
    {_, Decode} = maps:get({<<"Outer">>, record}, persistent_term:get(CacheKey)),
    ?assertEqual({ok, Record, <<>>}, t_types:Decode(Bin)),
    %% mixed nesting: the one-pass encoder answers a miss and the
    %% two-pass fallback produces identical bytes; the decode side is
    %% identical too, and strict whole-input behavior is preserved
    Mixed = {outer, #{name => <<"x">>}, 42},
    ?assertEqual({ok, Bin}, t_types:encode(outer, Mixed)),
    ?assertEqual(thrift_runtime:encode(Desc, Mixed), t_types:encode(outer, Mixed)),
    ?assertEqual({ok, Record}, t_types:decode(outer, Bin)),
    ?assertEqual({error, trailing}, t_types:decode(outer, <<Bin/binary, 0>>)),
    ?assertEqual(
        {error, truncated},
        t_types:decode(outer, binary:part(Bin, 0, byte_size(Bin) - 1))
    ),
    ok.

%% Same-named methods across two services of one file are legal Thrift
%% (per-service GetEvents): the name-keyed function_info/2 keeps the
%% last declaration's clauses, and every generated client embeds its own
%% service's params/reply/exceptions descriptors instead of resolving
%% through that table — a collision cannot hand one client another
%% service's descriptor (wrong field types on the wire).

service_method_name_clash_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "namespace erl t\n"
        "service First { list<i64> Get(1: string filter) }\n"
        "service Second { list<string> Get(1: i64 limit) }\n"
    ),
    Loaded = [#tg_loaded{name = <<"t">>, prefix = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),

    %% the name-keyed introspection table carries the last declaration
    ?assertEqual(
        {struct, {struct, [{1, default, {base, i64}, <<"limit">>, undefined}]}},
        t_types:function_info(<<"Get">>, params)
    ),

    Sources = thrift_generator_emitter:sources(Model),
    %% each client embeds its own descriptor and never resolves through
    %% the shared table
    FirstClient = entry_source(t_first_client, Sources),
    SecondClient = entry_source(t_second_client, Sources),
    ?assertMatch(nomatch, re:run(FirstClient, <<"function_info">>)),
    ?assertMatch(nomatch, re:run(SecondClient, <<"function_info">>)),
    ?assertMatch({match, _}, re:run(FirstClient, <<"filter">>)),
    ?assertMatch(nomatch, re:run(FirstClient, <<"limit">>)),
    ?assertMatch({match, _}, re:run(SecondClient, <<"limit">>)),
    ok.

%% `--repr native' (analyze/2 `#{repr => native}') materializes onto
%% unannotated structs and exceptions: no record anywhere (module or
%% hrl), record_fields carries {native, Tag}, the codec defaults to
%% runtime-minted native records (OTP 29), the `record' axis answers
%% {error, {no_record, Tag}} on every release, and unions keep their
%% own axis.

native_representation_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "struct P { 1: i32 x = 5, 2: string label }\n"
        "exception Oops { 1: string why }\n"
        "union V { 1: i32 n }\n"
    ),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded, #{repr => native}),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),

    ?assertEqual({native, p}, t_types:record_fields(<<"P">>)),
    ?assertEqual({native, oops}, t_types:record_fields(<<"Oops">>)),
    ?assertEqual({v, [n]}, t_types:record_fields(<<"V">>)),
    ?assertEqual(false, erlang:function_exported(t_types, p_from_map, 1)),
    ?assertEqual({ok, {struct, {ref, t_types, <<"P">>}}}, t_types:descriptor(p)),

    Hrl = entry_hrl(t_types, thrift_generator_emitter:sources(Model)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-record\\(p,">>)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-type p\\(\\)">>)),

    {ok, Bin} = t_types:encode(p, #{x => 7, label => <<"hi">>}),
    {ok, #{x := 7, label := <<"hi">>}} = t_types:decode(p, Bin, #{repr => map}),
    ?assertEqual({error, {no_record, p}}, t_types:decode(p, Bin, #{repr => record})),
    case thrift_runtime_native:supported() of
        true ->
            {ok, Native} = t_types:decode(p, Bin),
            ?assertEqual(t_types, records:get_module(Native)),
            ?assertEqual(p, records:get_name(Native)),
            ?assertEqual(7, records:get(x, Native)),
            ?assertEqual({ok, Bin}, t_types:encode(p, Native)),
            ?assertEqual(
                {ok, #{x => 7, label => <<"hi">>}},
                t_types:convert(p, Native, map)
            ),
            ?assertEqual({error, {no_record, p}}, t_types:convert(p, Native, record));
        false ->
            ?assertEqual({error, {unsupported_repr, native}}, t_types:decode(p, Bin))
    end,
    ok.

%% The repr option materializes onto unannotated structs and exceptions
%% only: an explicit erl.struct_type wins, unions never take the
%% injection, and `record' (the default) injects nothing.

repr_option_test() ->
    Snippet =
        "struct Plain { 1: i32 x }\n"
        "struct Ann { 1: i32 x } (erl.struct_type = \"record\")\n"
        "union U { 1: i32 n }\n"
        "exception E { 1: string m }\n",
    Loaded = fun() ->
        {ok, Doc} = thrift_generator:parse_string(Snippet),
        [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}]
    end,
    Annotations = fun(Model) ->
        [Mod] = Model#tg_model.modules,
        maps:from_list([
            {S#tg_struct.name, S#tg_struct.erl}
         || S <- Mod#tg_module.structs
        ])
    end,

    {ok, RecordModel} = thrift_generator_semantic:analyze(Loaded()),
    #{<<"Plain">> := RecordPlain, <<"Ann">> := RecordAnn, <<"U">> := RecordU} = Annotations(
        RecordModel
    ),
    ?assertEqual(false, maps:is_key(struct_type, RecordPlain)),
    ?assertEqual(<<"record">>, maps:get(struct_type, RecordAnn)),
    ?assertEqual(false, maps:is_key(struct_type, RecordU)),

    {ok, MapModel} = thrift_generator_semantic:analyze(Loaded(), #{repr => map}),
    #{<<"Plain">> := MapPlain, <<"Ann">> := MapAnn, <<"E">> := MapE, <<"U">> := MapU} = Annotations(
        MapModel
    ),
    ?assertEqual(<<"map">>, maps:get(struct_type, MapPlain)),
    ?assertEqual(<<"record">>, maps:get(struct_type, MapAnn)),
    ?assertEqual(<<"map">>, maps:get(struct_type, MapE)),
    ?assertEqual(false, maps:is_key(struct_type, MapU)),

    {ok, NativeModel} = thrift_generator_semantic:analyze(Loaded(), #{repr => native}),
    #{<<"Plain">> := NativePlain} = Annotations(NativeModel),
    ?assertEqual(<<"native">>, maps:get(struct_type, NativePlain)),
    ok.

%% The invocation-wide option axes (analyze/2 `#{union_type => sum, set
%% => sets, typedef_type => nominal}') generate the same artifacts the
%% matching annotations would: tagged-tuple sums, the chosen set
%% implementation and a -nominal typedef.

option_axes_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "union Value { 1: i64 n, 2: string s }\n"
        "struct Bag { 1: optional set<string> tags }\n"
        "typedef i64 Stamp\n"
    ),
    Loaded = [
        #tg_loaded{name = <<"t">>, prefix = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}
    ],
    {ok, Model} =
        thrift_generator_semantic:analyze(
            Loaded,
            #{union_type => sum, set => sets, typedef_type => nominal}
        ),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),

    ?assertEqual({sum, [n, s]}, t_types:record_fields(<<"Value">>)),
    ?assertEqual(
        {struct, [{1, optional, {set, {base, string}, sets}, <<"tags">>, undefined}]},
        t_types:struct_info(<<"Bag">>)
    ),
    TypesSrc = entry_source(t_types, thrift_generator_emitter:sources(Model)),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-nominal 'Stamp'\\(\\) :: integer\\(\\)\\.">>)),

    {ok, Bin} = t_types:encode(value, {n, 5}),
    {ok, {n, 5}} = t_types:decode(value, Bin),
    {ok, BagBin} = t_types:encode(bag, #{tags => sets:from_list([<<"a">>, <<"b">>])}),
    {ok, #{tags := Tags}} = t_types:decode(bag, BagBin, #{repr => map}),
    ?assertEqual(sets:from_list([<<"a">>, <<"b">>]), Tags),
    ok.

namespace_set_default_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "namespace erl t (erl.set = \"sets\")\n"
        "struct Bag {\n"
        "  1: set<i32> plain,\n"
        "  2: set<i32> (erl.set = \"ordset\") ords,\n"
        "  3: optional set<string> with_default = [ \"a\", \"b\" ]\n"
        "}\n"
    ),
    Loaded = [
        #tg_loaded{name = <<"t">>, prefix = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}
    ],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),

    ?assertEqual(
        {struct, [
            {1, default, {set, {base, i32}, sets}, <<"plain">>, undefined},
            {2, default, {set, {base, i32}, ordset}, <<"ords">>, undefined},
            {3, optional, {set, {base, string}, sets}, <<"with_default">>, [<<"a">>, <<"b">>]}
        ]},
        t_types:struct_info(<<"Bag">>)
    ),

    %% decode builds sets under the file default, the explicit ordset
    %% wins for its field; encode under `sets` takes a sets collection
    %% (no list coercion), list and ordset impls keep taking lists
    {ok, Bin} = t_types:encode(bag, #{plain => sets:from_list([3, 1, 2]), ords => [2, 1]}),
    {ok, #{plain := Plain, ords := Ords}} = t_types:decode(bag, Bin, #{repr => map}),
    ?assertEqual(sets:from_list([1, 2, 3]), Plain),
    ?assertEqual([1, 2], Ords),

    %% the hrl and the inline record wrap the record default in the
    %% impl constructor (the hrl also names the impl type); erl_prettypr
    %% folds long record fields across lines, so match on
    %% whitespace-normalised text
    Sources = thrift_generator_emitter:sources(Model),
    Flat = fun(Text) -> re:replace(Text, <<"\\s+">>, <<" ">>, [global, {return, binary}]) end,
    DefaultExprRe = <<"with_default = sets:from_list\\(\\[<<\"a\">>, <<\"b\">>\\]\\)">>,
    ?assertMatch({match, _}, re:run(Flat(entry_hrl(t_types, Sources)), DefaultExprRe)),
    ?assertMatch({match, _}, re:run(Flat(entry_source(t_types, Sources)), DefaultExprRe)),
    ?assertMatch(
        {match, _},
        re:run(
            Flat(entry_hrl(t_types, Sources)),
            <<"with_default = sets:from_list\\(\\[<<\"a\">>, <<\"b\">>\\]\\) :: sets:set\\(binary\\(\\)\\)">>
        )
    ),

    %% a hand-built record encodes under the same contract: the sets
    %% impl folds back to an element list on the wire. Decode of a
    %% missing optional field stays undefined — defaults live in the
    %% record literal, not in decode
    {ok, Bin2} = t_types:encode(bag, {t_bag, sets:from_list([1]), [2], undefined}),
    {ok, #{plain := Plain2, ords := Ords2}} = t_types:decode(bag, Bin2, #{repr => map}),
    ?assertEqual(sets:from_list([1]), Plain2),
    ?assertEqual([2], Ords2),
    ok.

%% A declared `namespace erl` (or `namespace *`) prefixes every
%% generated identifier of the module — record tag, type aliases,
%% derived function names, constant macro — while the wire names (the
%% struct_info/enum_info keys) and enum member atoms stay exactly as
%% declared. Services keep their own name-derived module atoms.

namespace_prefix_test() ->
    {ok, Doc} = thrift_generator:parse_string(?NS_SNIPPET),
    Loaded = [
        #tg_loaded{
            name = <<"demo.widgets">>,
            prefix = <<"demo_widgets">>,
            path = <<"t.thrift">>,
            includes = [],
            doc = Doc
        }
    ],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),
    ?assertEqual(
        [
            'demo_widgets_svc_client',
            'demo_widgets_svc_handler',
            'demo_widgets_svc_server',
            demo_widgets_types,
            demo_widgets_types_repr
        ],
        lists:sort([Name || {ok, Name, _} <- Results])
    ),

    %% The record contract and the codec functions carry the prefix;
    %% struct_info stays keyed by the wire name, the canonical type atom
    %% never does.
    ?assertEqual({demo_widgets_point, [x]}, demo_widgets_types:record_fields(<<"Point">>)),
    ?assertEqual(
        {struct, [{1, default, {base, i32}, <<"x">>, 5}]},
        demo_widgets_types:struct_info(<<"Point">>)
    ),
    Record = {demo_widgets_point, 5},
    {ok, Bin} = demo_widgets_types:encode(point, Record),
    ?assertEqual({ok, Record}, demo_widgets_types:decode(point, Bin)),
    ?assertEqual({ok, #{x => 5}}, demo_widgets_types:decode(point, Bin, #{repr => map})),
    ?assertEqual({ok, Record}, demo_widgets_types:convert(point, #{x => 5}, record)),
    ?assertEqual(
        {ok, {struct, {ref, demo_widgets_types, <<"Point">>}}},
        demo_widgets_types:descriptor(point)
    ),

    %% Enum helpers get the prefix; member atoms and enum_info do not.
    ?assertEqual({ok, 0}, demo_widgets_types:demo_widgets_color_to_int('RED')),
    ?assertEqual({ok, 'GREEN'}, demo_widgets_types:demo_widgets_color_from_int(10)),
    ?assertEqual([{0, 'RED'}, {10, 'GREEN'}], demo_widgets_types:enum_info(<<"Color">>)),

    %% Constant functions carry the prefix; scalar macros uppercase it.
    ?assertEqual(10, demo_widgets_types:demo_widgets_base()),
    ?assertEqual(<<"hi">>, demo_widgets_types:demo_widgets_greeting()),

    Sources = thrift_generator_emitter:sources(Model),
    Hrl = entry_hrl(demo_widgets_types, Sources),
    TypesSrc = entry_source(demo_widgets_types, Sources),
    ?assertMatch(
        {match, _},
        re:run(Hrl, <<"-record\\(demo_widgets_point,\\{x = 5 :: integer\\(\\) \\| undefined\\}\\)\\.">>)
    ),
    %% Type aliases keep the original IDL names — the namespace prefix
    %% never touches them.
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-type 'Point'\\(\\) :: #demo_widgets_point\\{\\}\\.">>)),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-type 'Color'\\(\\) :: 'RED' \\| 'GREEN'\\.">>)),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-export_type\\(\\['Point'/0,'Color'/0\\]\\)\\.">>)
    ),
    ?assertMatch({match, _}, re:run(Hrl, <<"-define\\(DEMO_WIDGETS_BASE, 10\\)\\.">>)),
    ok.

%% Named definitions export their original IDL names as type aliases
%% from the types module: map-mode structs alias their shape (required
%% fields exact `:=', optional associative `=>'), typedefs alias their
%% target (`-nominal' for erl.type = "nominal"), and the hrl stays
%% record-and-macro only.

type_definitions_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        "struct Point { 1: required i32 x, 2: optional i32 y }\n"
        "struct PointMap { 1: required i32 x, 2: optional i32 y }"
        " (erl.struct_type = \"map\")\n"
        "typedef i64 Millis\n"
        "typedef string Name (erl.type = \"nominal\")\n"
    ),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        thrift_generator_emitter:compile_sources(Model)
    ),
    Sources = thrift_generator_emitter:sources(Model),
    TypesSrc = entry_source(t_types, Sources),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-type 'PointMap'\\(\\) :: #\\{x := integer\\(\\), y => integer\\(\\)\\}\\.">>)
    ),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-type 'Millis'\\(\\) :: integer\\(\\)\\.">>)),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-nominal 'Name'\\(\\) :: binary\\(\\)\\.">>)),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-export_type\\(\\['Point'/0,'PointMap'/0,'Millis'/0,'Name'/0\\]\\)\\.">>)
    ),
    Hrl = entry_hrl(t_types, Sources),
    ?assertMatch(nomatch, re:run(Hrl, <<"-type ">>)),
    ?assertMatch(nomatch, re:run(Hrl, <<"-nominal">>)),
    ok.

%% IDL doc comments (/** */, ///) reach the generated code: as -doc on
%% the entity's functions (enum helpers, the constant, service
%% callbacks/methods), plus the service doc in the generated module
%% docs; every generated function carries a built-in -doc explaining
%% its contract. The type-first codec facade is module-level, so its
%% docs are the built-in contracts rather than per-struct IDL text.

doc_pipeline_test() ->
    {ok, Doc} = thrift_generator:parse_string(?DOC_SNIPPET),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    {ok, Model} = thrift_generator_semantic:analyze(Loaded),
    Results = thrift_generator_emitter:compile_sources(Model),
    %% the -doc attributes compile warning-free (warnings_as_errors is
    %% on inside compile_sources)
    lists:foreach(
        fun
            ({ok, _Name, _Beam}) -> ok;
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),
    Sources = thrift_generator_emitter:sources(Model),
    TypesSrc = doc_text(entry_source(t_types, Sources)),
    %% the type-first facade functions carry their built-in contracts
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-doc\\(\"Encodes `Value` of the struct selected by `Type`">>)
    ),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-doc\\(\"Decodes the whole binary into the struct's default">>)
    ),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"into representation `repr` \\(default: the struct's schema-selected">>)
    ),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-doc\\(\"Reshapes a typed value \\(record, struct-map">>)
    ),
    ?assertMatch(
        {match, _},
        re:run(TypesSrc, <<"-doc\\(\"Returns the named-ref descriptor">>)
    ),
    %% enum and constant docs
    ?assertMatch({match, _}, re:run(TypesSrc, <<"Color codes\\.\\\\n\\\\nMaps an enum member">>)),
    ?assertMatch({match, _}, re:run(TypesSrc, <<"-doc\\(\"The constant's value as declared">>)),
    %% client methods and handler callbacks carry the function's IDL doc
    ClientSrc = doc_text(entry_source(t_svc_client, Sources)),
    ?assertMatch({match, _}, re:run(ClientSrc, <<"Ping it\\.\\\\n\\\\nCalls ping and waits for">>)),
    ?assertMatch({match, _}, re:run(ClientSrc, <<"Sends the oneway fire">>)),
    HandlerSrc = doc_text(entry_source(t_svc_handler, Sources)),
    ?assertMatch({match, _}, re:run(HandlerSrc, <<"Ping it\\.\\\\n\\\\nHandler callback for ping">>)),
    ?assertMatch({match, _}, re:run(HandlerSrc, <<"oneway fire: called as">>)),
    %% the service doc lands in the generated module docs
    ?assertMatch({match, _}, re:run(ClientSrc, <<"Waves at the caller\\.">>)),
    ServerSrc = entry_source(t_svc_server, Sources),
    ?assertMatch({match, _}, re:run(ServerSrc, <<"Waves at the caller\\.">>)),
    ok.

%%--------------------------------------------------------------------

-spec entry(module(), [thrift_generator_emitter:source()]) -> thrift_generator_emitter:source().
entry(Module, Sources) ->
    {value, Entry} =
        lists:search(fun(E) -> maps:get(module, E) =:= Module end, Sources),
    Entry.

-spec entry_source(module(), [thrift_generator_emitter:source()]) -> binary().
entry_source(Module, Sources) ->
    maps:get(source, entry(Module, Sources)).

%% Doc attributes wrap their string literal one chunk per line; the
%% seams (`"' newline indentation `"') carry no content, so gluing them
%% restores the logical doc text for substring matching.

-spec doc_text(binary()) -> binary().
doc_text(Source) ->
    re:replace(Source, <<"\"\\n\\s*\"">>, <<>>, [global, {return, binary}]).

-spec entry_hrl(module(), [thrift_generator_emitter:source()]) -> binary().
entry_hrl(Module, Sources) ->
    maps:get(hrl, entry(Module, Sources)).

%% erl.record_name replaces the derived record tag everywhere the tag
%% surfaces — the hrl declaration, the type alias, record_fields/1 and
%% the schema codec facade — while struct_info stays keyed by the wire
%% name and codec function names stay derived.

record_name_annotation_test() ->
    {ok, Model} = analyze_model(
        "struct BankAccount { 1: required string id, 2: optional i64 balance } "
        "(erl.record_name = \"BankAccount\")\n"
        "service Svc { BankAccount get() }\n"
    ),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),
    Sources = thrift_generator_emitter:sources(Model),
    Hrl = entry_hrl(t_types, Sources),
    Source = entry_source(t_types, Sources),
    ?assertMatch({match, _}, re:run(Hrl, <<"-record\\('BankAccount',\\{">>)),
    ?assertMatch({match, _}, re:run(Source, <<"'BankAccount'\\(\\) :: #'BankAccount'\\{\\}">>)),
    ?assertEqual({'BankAccount', [id, balance]}, t_types:record_fields(<<"BankAccount">>)),
    ?assertEqual(
        {ok, {struct, {ref, t_types, <<"BankAccount">>}}},
        t_types:descriptor(bank_account)
    ),
    Value = {'BankAccount', <<"acc-1">>, 100},
    {ok, Bin} = t_types:encode(bank_account, Value),
    ?assertEqual({ok, Value}, t_types:decode(bank_account, Bin, #{repr => record})),
    ?assertEqual({struct, {ref, t_types, <<"BankAccount">>}}, t_types:function_info(<<"get">>, reply)),
    ok.

%% erl.enum_case = "lower" lowercases every surfaced member atom —
%% enum_info, the enum descriptors embedded in function_info, enum
%% member constants and defaults, the type alias — while per-enum
%% annotations override the invocation default and IDL references keep
%% validating against the declared names.

enum_case_test() ->
    {ok, Model} = analyze_model_opts(
        "enum Color { RED, GREEN = 10 }\n"
        "enum Keep { UPPER } (erl.enum_case = \"preserve\")\n"
        "const Color FIRST = Color.RED\n"
        "struct S { 1: Color c = Color.RED }\n"
        "service Svc { Color get(1: Color c) }\n",
        #{enum_case => lower}
    ),
    Results = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) -> {module, Name} = code:load_binary(Name, atom_to_list(Name), Beam);
            ({error, {Name, Errors}}) -> erlang:error({generated_module, Name, Errors})
        end,
        Results
    ),
    Sources = thrift_generator_emitter:sources(Model),
    Source = entry_source(t_types, Sources),
    ?assertMatch({match, _}, re:run(Source, <<"'Color'\\(\\) :: red \\| green">>)),
    ?assertMatch({match, _}, re:run(Source, <<"'Keep'\\(\\) :: 'UPPER'">>)),
    ?assertEqual([{0, red}, {10, green}], t_types:enum_info(<<"Color">>)),
    ?assertEqual([{0, 'UPPER'}], t_types:enum_info(<<"Keep">>)),
    ?assertEqual(<<"red">>, t_types:first()),
    {struct, {struct, [{1, default, {enum, [{0, red}, {10, green}]}, <<"c">>, undefined}]}} =
        t_types:function_info(<<"get">>, params),
    Value = #{c => green},
    {ok, Bin} = t_types:encode(s, #{c => green}),
    ?assertEqual({ok, Value}, t_types:decode(s, Bin, #{repr => map})),
    ok.

-spec analyze_model(string() | binary()) -> {ok, #tg_model{}} | {error, term()}.
analyze_model(Snippet) ->
    analyze_model_opts(Snippet, #{}).

-spec analyze_model_opts(string() | binary(), map()) -> {ok, #tg_model{}} | {error, term()}.
analyze_model_opts(Snippet, Opts) ->
    {ok, Doc} = thrift_generator:parse_string(Snippet),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    thrift_generator_semantic:analyze(Loaded, Opts).
