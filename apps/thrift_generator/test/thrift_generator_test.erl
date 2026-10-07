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

%% Unit tests for the IDL front end: lexing and parsing of inline
%% snippets. Whole-file coverage of the canonical ThriftTest.thrift
%% fixtures lives in thrift_generator_SUITE.

-module(thrift_generator_test).

-include_lib("stdlib/include/assert.hrl").
-include_lib("thrift_generator/include/thrift_generator.hrl").

-export([
    namespace_annotations_test/0,
    star_namespace_annotations_test/0,
    typedef_node_test/0,
    uuid_type_test/0,
    byte_alias_test/0,
    container_type_annotations_test/0,
    field_type_annotations_test/0,
    field_own_annotations_test/0,
    doc_comment_test/0,
    line_doc_comment_test/0,
    enum_values_test/0,
    empty_enum_test/0,
    const_literal_test/0,
    const_ref_test/0,
    oneway_test/0,
    implicit_field_ids_left_undefined_test/0,
    reserved_keyword_error_test/0,
    syntax_error_test/0
]).

namespace_annotations_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"namespace erl test (erl.set_type = \"sets_v2\")">>
    ),
    #thrift_generator_document{headers = [Namespace]} = Doc#thrift_generator_node.payload,
    #thrift_generator_namespace{scope = <<"erl">>, name = <<"test">>} =
        Namespace#thrift_generator_node.payload,
    ?assertEqual(#{set_type => <<"sets_v2">>}, Namespace#thrift_generator_node.annotations),
    ok.

star_namespace_annotations_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"namespace * test (erl.set_type = \"sets_v2\")">>
    ),
    #thrift_generator_document{headers = [Namespace]} = Doc#thrift_generator_node.payload,
    #thrift_generator_namespace{scope = <<"*">>, name = <<"test">>} =
        Namespace#thrift_generator_node.payload,
    ?assertEqual(#{set_type => <<"sets_v2">>}, Namespace#thrift_generator_node.annotations),
    ok.

typedef_node_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"typedef i64 UserId (erl.type = \"nominal\")">>
    ),
    #thrift_generator_document{definitions = [Typedef]} = Doc#thrift_generator_node.payload,
    #thrift_generator_typedef{name = <<"UserId">>, type = {base, i64, #{}}} =
        Typedef#thrift_generator_node.payload,
    ?assertEqual(#{type => <<"nominal">>}, Typedef#thrift_generator_node.annotations),
    ok.

uuid_type_test() ->
    {ok, Doc} = thrift_generator:parse_string(<<"struct S { 1: uuid id }">>),
    #thrift_generator_document{definitions = [Struct]} = Doc#thrift_generator_node.payload,
    #thrift_generator_struct{fields = [Field]} = Struct#thrift_generator_node.payload,
    #thrift_generator_field{type = {base, uuid, #{}}} = Field#thrift_generator_node.payload,
    ok.

byte_alias_test() ->
    {ok, Doc} = thrift_generator:parse_string(<<"struct S { 1: byte b }">>),
    #thrift_generator_document{definitions = [Struct]} = Doc#thrift_generator_node.payload,
    #thrift_generator_struct{fields = [Field]} = Struct#thrift_generator_node.payload,
    #thrift_generator_field{type = {base, i8, #{}}} = Field#thrift_generator_node.payload,
    ok.

container_type_annotations_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"struct S { 1: list<i32 (foo = \"bar\")> xs }">>
    ),
    #thrift_generator_document{definitions = [Struct]} = Doc#thrift_generator_node.payload,
    #thrift_generator_struct{fields = [Field]} = Struct#thrift_generator_node.payload,
    #thrift_generator_field{
        type = {list, {base, i32, #{<<"foo">> := <<"bar">>}}, #{}}
    } = Field#thrift_generator_node.payload,
    ok.

field_type_annotations_test() ->
    %% Annotations written between the type and the field name belong
    %% to the type; annotations after the name are the field's own.
    {ok, Doc} = thrift_generator:parse_string(
        <<"struct S { 1: set<string> (erl.set_type = \"ordset\") ids }">>
    ),
    #thrift_generator_document{definitions = [Struct]} = Doc#thrift_generator_node.payload,
    #thrift_generator_struct{fields = [Field]} = Struct#thrift_generator_node.payload,
    #thrift_generator_field{type = {set, {base, string, #{}}, #{<<"erl.set_type">> := <<"ordset">>}}} =
        Field#thrift_generator_node.payload,
    ?assertEqual(#{}, Field#thrift_generator_node.annotations),
    ok.

field_own_annotations_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"struct S { 1: set<string> ids (erl.set_type = \"ordset\") }">>
    ),
    #thrift_generator_document{definitions = [Struct]} = Doc#thrift_generator_node.payload,
    #thrift_generator_struct{fields = [Field]} = Struct#thrift_generator_node.payload,
    #thrift_generator_field{type = {set, {base, string, #{}}, #{}}} =
        Field#thrift_generator_node.payload,
    ?assertEqual(#{set_type => <<"ordset">>}, Field#thrift_generator_node.annotations),
    ok.

doc_comment_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"/** A struct.\n * Second line. */\nstruct S {}">>
    ),
    #thrift_generator_document{definitions = [Struct]} = Doc#thrift_generator_node.payload,
    ?assertEqual(<<"A struct.\nSecond line.">>, Struct#thrift_generator_node.doc),
    ok.

line_doc_comment_test() ->
    {ok, Doc} = thrift_generator:parse_string(<<"/// An enum.\nenum E { A }">>),
    #thrift_generator_document{definitions = [Enum]} = Doc#thrift_generator_node.payload,
    ?assertEqual(<<"An enum.">>, Enum#thrift_generator_node.doc),
    #thrift_generator_enum{values = [{<<"A">>, undefined, #{}, undefined}]} =
        Enum#thrift_generator_node.payload,
    ok.

enum_values_test() ->
    {ok, Doc} = thrift_generator:parse_string(<<"enum E { A, B = 5, C }">>),
    #thrift_generator_document{definitions = [Enum]} = Doc#thrift_generator_node.payload,
    #thrift_generator_enum{values = Values} = Enum#thrift_generator_node.payload,
    ?assertEqual(
        [
            {<<"A">>, undefined, #{}, undefined},
            {<<"B">>, 5, #{}, undefined},
            {<<"C">>, undefined, #{}, undefined}
        ],
        Values
    ),
    ok.

empty_enum_test() ->
    {ok, Doc} = thrift_generator:parse_string(<<"enum E {}">>),
    #thrift_generator_document{definitions = [Enum]} = Doc#thrift_generator_node.payload,
    #thrift_generator_enum{values = []} = Enum#thrift_generator_node.payload,
    ok.

const_literal_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"const map<i32, string> M = { 1 : \"a\", 2 : \"b\" }">>
    ),
    #thrift_generator_document{definitions = [Constant]} = Doc#thrift_generator_node.payload,
    #thrift_generator_constant{
        name = <<"M">>,
        type = {map, {base, i32, #{}}, {base, string, #{}}, #{}},
        value = {map, [{1, <<"a">>}, {2, <<"b">>}]}
    } = Constant#thrift_generator_node.payload,
    ok.

const_ref_test() ->
    {ok, Doc} = thrift_generator:parse_string(<<"const Numberz myNumberz = Numberz.ONE;">>),
    #thrift_generator_document{definitions = [Constant]} = Doc#thrift_generator_node.payload,
    #thrift_generator_constant{
        name = <<"myNumberz">>,
        type = {ref, <<"Numberz">>, #{}},
        value = {ref, <<"Numberz.ONE">>}
    } = Constant#thrift_generator_node.payload,
    ok.

oneway_test() ->
    {ok, Doc} = thrift_generator:parse_string(
        <<"service S { oneway void ping(), string echo(1: string msg) throws (1: E e) }">>
    ),
    #thrift_generator_document{definitions = [Service]} = Doc#thrift_generator_node.payload,
    #thrift_generator_service{functions = [Ping, Echo]} = Service#thrift_generator_node.payload,
    #thrift_generator_function{oneway = true, return_type = void, throws = []} =
        Ping#thrift_generator_node.payload,
    #thrift_generator_function{oneway = false, throws = [Throw]} = Echo#thrift_generator_node.payload,
    #thrift_generator_field{} = Throw#thrift_generator_node.payload,
    ok.

implicit_field_ids_left_undefined_test() ->
    {ok, Doc} = thrift_generator:parse_string(<<"struct Legacy { string a, i32 b }">>),
    #thrift_generator_document{definitions = [Struct]} = Doc#thrift_generator_node.payload,
    #thrift_generator_struct{fields = Fields} = Struct#thrift_generator_node.payload,
    ?assertMatch(
        [
            #thrift_generator_node{payload = #thrift_generator_field{id = undefined, name = <<"a">>}},
            #thrift_generator_node{payload = #thrift_generator_field{id = undefined, name = <<"b">>}}
        ],
        Fields
    ),
    ok.

reserved_keyword_error_test() ->
    ?assertMatch({error, _}, thrift_generator:parse_string(<<"struct catch {}">>)),
    ok.

syntax_error_test() ->
    ?assertMatch({error, _}, thrift_generator:parse_string(<<"struct">>)),
    ok.
