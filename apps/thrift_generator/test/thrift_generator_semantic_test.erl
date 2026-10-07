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

%% Unit tests for the semantic pass on inline snippets. File-level
%% scenarios (includes, cycles) live in thrift_generator_SUITE.

-module(thrift_generator_semantic_test).

-include_lib("stdlib/include/assert.hrl").
-include_lib("thrift_generator/include/thrift_generator.hrl").
-include_lib("thrift_generator/include/thrift_generator_model.hrl").

-export([
    enum_numbering_test/0,
    implicit_field_ids_negative_test/0,
    duplicate_field_id_error_test/0,
    union_required_field_error_test/0,
    oneway_shape_error_test/0,
    throw_not_exception_error_test/0,
    unknown_type_error_test/0,
    const_enum_ref_test/0,
    const_chain_and_cycle_test/0,
    const_type_mismatch_error_test/0,
    typedef_cycle_error_test/0,
    service_extends_merge_test/0,
    override_inherited_error_test/0,
    recursive_struct_ok_test/0,
    default_from_const_test/0
]).

-spec analyze(string() | binary()) -> {ok, #tg_model{}} | {error, term()}.
analyze(Snippet) ->
    {ok, Doc} = thrift_generator:parse_string(Snippet),
    Loaded = [#tg_loaded{name = <<"t">>, path = <<"t.thrift">>, includes = [], doc = Doc}],
    thrift_generator_semantic:analyze(Loaded).

-spec model_module(#tg_model{}) -> #tg_module{}.
model_module(Model) ->
    hd(Model#tg_model.modules).

enum_numbering_test() ->
    {ok, Model} = analyze(<<"enum E { A, B = 5, C }">>),
    [#tg_enum{name = <<"E">>, values = Values}] = (model_module(Model))#tg_module.enums,
    ?assertEqual([{0, <<"A">>}, {5, <<"B">>}, {6, <<"C">>}], Values),
    ok.

implicit_field_ids_negative_test() ->
    {ok, Model} = analyze(<<"struct Legacy { string a, i32 b }">>),
    [#tg_struct{fields = Fields}] = (model_module(Model))#tg_module.structs,
    ?assertEqual([-1, -2], [F#tg_field.id || F <- Fields]),
    ok.

duplicate_field_id_error_test() ->
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, <<"duplicate field id 1 (already used by a)">>}]},
        analyze(<<"struct S { 1: i32 a, 1: i32 b }">>)
    ),
    ok.

union_required_field_error_test() ->
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, <<"union field x must be optional">>}]},
        analyze(<<"union U { 1: required i32 x }">>)
    ),
    ok.

oneway_shape_error_test() ->
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, _}]},
        analyze(<<"service S { oneway string fire() }">>)
    ),
    ok.

throw_not_exception_error_test() ->
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, <<"throw field must be an exception, got T">>}]},
        analyze(<<"struct T { 1: i32 x }\nservice S { void f() throws (1: T t) }">>)
    ),
    ok.

unknown_type_error_test() ->
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, <<"unknown type Missing">>}]},
        analyze(<<"struct S { 1: Missing m }">>)
    ),
    ok.

const_enum_ref_test() ->
    {ok, Model} = analyze(<<"enum E { A, B }\nconst E e = E.B\nconst list<E> es = [E.A, E.B]">>),
    Consts = (model_module(Model))#tg_module.consts,
    ?assertEqual(<<"B">>, hd([C#tg_const.value || C <- Consts, C#tg_const.name =:= <<"e">>])),
    ?assertEqual(
        {list, [<<"A">>, <<"B">>]},
        hd([C#tg_const.value || C <- Consts, C#tg_const.name =:= <<"es">>])
    ),
    ok.

const_chain_and_cycle_test() ->
    {ok, Model} = analyze(<<"const i32 A = B\nconst i32 B = 7">>),
    Consts = (model_module(Model))#tg_module.consts,
    ?assertEqual(7, hd([C#tg_const.value || C <- Consts, C#tg_const.name =:= <<"A">>])),
    ?assertMatch({error, _}, analyze(<<"const i32 A = B\nconst i32 B = A">>)),
    ?assertMatch({error, _}, analyze(<<"const i32 A = A">>)),
    ok.

const_type_mismatch_error_test() ->
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, _}]},
        analyze(<<"const i32 X = \"str\"">>)
    ),
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, _}]},
        analyze(<<"const byte B = 300">>)
    ),
    {ok, _} = analyze(<<"const double D = 5">>),
    {ok, _} = analyze(<<"const set<i32> S = [1, 2, 3]">>),
    ok.

typedef_cycle_error_test() ->
    {error, Errors1} = analyze(<<"typedef A B\ntypedef B C\ntypedef C A">>),
    ?assert(lists:any(fun({_, _, Msg}) -> Msg =:= <<"typedef cycle through B">> end, Errors1)),
    {error, Errors2} = analyze(<<"typedef B A\ntypedef A B">>),
    ?assert(lists:any(fun({_, _, Msg}) -> Msg =:= <<"typedef cycle through A">> end, Errors2)),
    ok.

service_extends_merge_test() ->
    {ok, Model} = analyze(
        <<
            "exception Boom { 1: string msg }\n"
            "service P { void ping(), i32 area(1: i32 w, 2: i32 h) throws (1: Boom b) }\n"
            "service C extends P { string echo(1: string m) }"
        >>
    ),
    [#tg_service{name = <<"C">>, functions = Fns}] =
        [S || S <- (model_module(Model))#tg_module.services, S#tg_service.name =:= <<"C">>],
    ?assertEqual([<<"ping">>, <<"area">>, <<"echo">>], [F#tg_function.name || F <- Fns]),
    ?assertEqual(3, length(Fns)),
    ok.

override_inherited_error_test() ->
    ?assertMatch(
        {error, [{<<"t.thrift">>, _, <<"function ping overrides an inherited function">>}]},
        analyze(<<"service P { void ping() }\nservice C extends P { void ping() }">>)
    ),
    ok.

recursive_struct_ok_test() ->
    %% "next" is a reserved IDL keyword; "tail" is not.
    {ok, Model} = analyze(<<"struct N { 1: optional N tail }">>),
    [#tg_struct{name = <<"N">>}] = (model_module(Model))#tg_module.structs,
    ok.

default_from_const_test() ->
    {ok, Model} = analyze(<<"const i32 BASE = 10\nstruct S { 1: i32 x = BASE }">>),
    [#tg_struct{fields = [#tg_field{default = 10}]}] = (model_module(Model))#tg_module.structs,
    ok.
