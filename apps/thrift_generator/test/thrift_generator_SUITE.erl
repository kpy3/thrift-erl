%% Copyright 2025 Sergei Yelin
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

-export([all/0]).
-export([
    parse_thrift_test_idl/1,
    parse_erlang_thrift_test_idl/1,
    reject_reserved_keyword/1,
    reject_syntax_error/1
]).

all() ->
    [
        parse_thrift_test_idl,
        parse_erlang_thrift_test_idl,
        reject_reserved_keyword,
        reject_syntax_error
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
    ?assertEqual(#{set_type => <<"sets_v2">>}, ErlNamespace#thrift_generator_node.annotations),

    UserId = find_definition(Definitions, thrift_generator_typedef, <<"UserId">>),
    ?assertEqual(#{type => <<"nominal">>}, UserId#thrift_generator_node.annotations),

    UserIds = find_definition(Definitions, thrift_generator_typedef, <<"UserIds">>),
    #thrift_generator_typedef{type = {set, {base, string, #{}}, #{}}} =
        UserIds#thrift_generator_node.payload,
    ?assertEqual(#{set_type => <<"ordset">>}, UserIds#thrift_generator_node.annotations),

    Bonk = find_definition(Definitions, thrift_generator_struct, <<"Bonk">>),
    ?assertEqual(<<"map">>, maps:get(struct_type, Bonk#thrift_generator_node.annotations)),
    ?assertEqual(<<"atom">>, maps:get('struct_type.map.key_type', Bonk#thrift_generator_node.annotations)),

    SomeUnion = find_definition(Definitions, thrift_generator_union, <<"SomeUnion">>),
    ?assertEqual(#{union_type => <<"union">>}, SomeUnion#thrift_generator_node.annotations),

    ok.

reject_reserved_keyword(Config) ->
    BadFile = write_snippet(Config, "reserved.thrift", <<"struct catch {}">>),
    ?assertMatch({error, _}, thrift_generator:parse_file(BadFile)).

reject_syntax_error(Config) ->
    BadFile = write_snippet(Config, "broken.thrift", <<"struct">>),
    ?assertMatch({error, _}, thrift_generator:parse_file(BadFile)).

%% Helpers

parse_data_file(Config, Name) ->
    File = filename:join(proplists:get_value(data_dir, Config), Name),
    {ok, Doc} = thrift_generator:parse_file(File),
    Doc.

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
