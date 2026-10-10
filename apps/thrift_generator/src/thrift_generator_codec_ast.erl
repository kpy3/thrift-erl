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

-module(thrift_generator_codec_ast).

-moduledoc """
Raw `erl_parse` vocabulary shared by the specialized wire-codec emitters
(`thrift_generator_codec` for the binary protocol and its compact/JSON
siblings).

Patterns, binary segment options, guards and comprehension qualifiers
have no convenient `erl_syntax` constructors, so the codec emitters
build raw trees and let `erl_pp` render them; doc and spec attributes
stay syntax trees like everywhere else in the emitter. Everything here
is protocol-agnostic — the binary- and compact-specific shapes (fixed
width headers, length prefixes) stay in their emitters.
""".

-export([
    v/1,
    i/1,
    at/1,
    call_local/2,
    remote/3,
    tuple_t/1,
    tuple_pat/1,
    tuple_t_type/1,
    cons/2,
    nil/0,
    list_lit/1,
    clause/3,
    error_clause/0,
    ok_bind_clause/2,
    ok3_bind_clause/3,
    mismatch_tail/1,
    mismatch_fn_tail/0,
    more_tail/0,
    other_tail/0,
    other_clause/1,
    'case'/2,
    lc/2,
    map_exact/2,
    map_empty/0,
    map_put/3,
    bin_seg/3,
    bin_pat/1,
    bin_lit/1,
    name_lit/1,
    ok_t/1,
    ok3/2,
    err_encode/1,
    err_decode/1,
    mismatch/1,
    literal/1,
    atom_concat/2,
    encode_entry_clause/1,
    encode_error_clause/0,
    union_check/2,
    required_check/2,
    key_filter/3,
    fun_type/2,
    t_atom/1,
    t_atom_lit/1,
    t_map_exact/0,
    t_map_loose/0,
    t_ok/1,
    t_error/0,
    t_union/1,
    t_fun/2,
    spec_form/3
]).

-define(ANNO, erl_anno:new(0)).

-include("thrift_generator_model.hrl").

%% A raw `erl_parse' tree (stdlib exports no type for them); the doc and
%% spec attributes and the returned form list stay syntax trees.

-type ast() :: tuple().

-export_type([ast/0]).

%%--------------------------------------------------------------------
%% AST helpers (raw erl_parse trees)
%%--------------------------------------------------------------------

-spec v(string()) -> ast().
v(Name) ->
    {var, ?ANNO, list_to_atom(Name)}.

-spec i(integer()) -> ast().
i(N) ->
    {integer, ?ANNO, N}.

-spec at(atom()) -> ast().
at(A) ->
    {atom, ?ANNO, A}.

-spec call_local(atom(), [ast()]) -> ast().
call_local(F, Args) ->
    {call, ?ANNO, {atom, ?ANNO, F}, Args}.

-spec remote(module(), atom(), [ast()]) -> ast().
remote(M, F, Args) ->
    {call, ?ANNO, {remote, ?ANNO, {atom, ?ANNO, M}, {atom, ?ANNO, F}}, Args}.

-spec tuple_t([ast()]) -> ast().
tuple_t(Elements) ->
    {tuple, ?ANNO, Elements}.

-spec tuple_pat([ast()]) -> ast().
tuple_pat(Elements) ->
    {tuple, ?ANNO, Elements}.

-spec tuple_t_type([ast()]) -> ast().
tuple_t_type(Elements) ->
    {type, ?ANNO, tuple, Elements}.

-spec cons(ast(), ast()) -> ast().
cons(H, T) ->
    {cons, ?ANNO, H, T}.

-spec nil() -> ast().
nil() ->
    {nil, ?ANNO}.

-spec list_lit([ast()]) -> ast().
list_lit(Elements) ->
    lists:foldr(fun cons/2, nil(), Elements).

%% The guard is an ergonomic single guard sequence (`none` or a flat
%% test list); the modern abstract format wants `[]` for no guard and a
%% list of sequences otherwise, so both shapes are translated here.

-spec clause([ast()], none | [ast()], [ast()]) -> ast().
clause(Patterns, Guard, Body) ->
    {clause, ?ANNO, Patterns, guard_sequence(Guard), Body}.

-spec guard_sequence(none | [ast()]) -> [[ast()]].
guard_sequence(none) ->
    [];
guard_sequence(Tests) ->
    [Tests].

%% The `{error, _} = Err -> Err` passthrough shared by every fallible
%% step of the generated code.

-spec error_clause() -> ast().
error_clause() ->
    clause([{match, ?ANNO, tuple_t([at(error), v("_")]), v("Err")}], none, [v("Err")]).

%% The clause shapes shared by the generated code: binding the payload
%% of an {ok, ...} result and the fall-through tails of value cases.

-spec ok_bind_clause(ast(), ast()) -> ast().
ok_bind_clause(Bind, Body) ->
    clause([tuple_t([at(ok), Bind])], none, [Body]).

-spec ok3_bind_clause(ast(), ast(), ast()) -> ast().
ok3_bind_clause(BindValue, BindRest, Body) ->
    clause([tuple_t([at(ok), BindValue, BindRest])], none, [Body]).

-spec mismatch_tail(ast()) -> ast().
mismatch_tail(V) ->
    clause([v("_")], none, [err_encode(mismatch(V))]).

%% Function-clause tail for the container helpers: unlike the case
%% clauses above there is no outer binding to fall back on, so the head
%% must bind the value it reports.

-spec mismatch_fn_tail() -> ast().
mismatch_fn_tail() ->
    clause([v("Value")], none, [err_encode(mismatch(v("Value")))]).

-spec more_tail() -> ast().
more_tail() ->
    clause([v("_")], none, [at(more)]).

-spec other_tail() -> ast().
other_tail() ->
    other_clause("Other").

%% The catch-all with an optional explicit name: cases that NEST (an
%% inline element decode inside the loop case that consumes it) must not
%% reuse the variable, or erl_lint reports the rebinding as unsafe.

-spec other_clause(string()) -> ast().
other_clause(Name) ->
    clause([v(Name)], none, [v(Name)]).

-spec 'case'(ast(), [ast()]) -> ast().
'case'(Expr, Clauses) ->
    {'case', ?ANNO, Expr, Clauses}.

-spec lc(ast(), [ast()]) -> ast().
lc(Template, Qualifiers) ->
    {lc, ?ANNO, Template, Qualifiers}.

-spec map_exact(ast(), ast()) -> ast().
map_exact(K, V) ->
    {map, ?ANNO, [{map_field_exact, ?ANNO, K, V}]}.

-spec map_empty() -> ast().
map_empty() ->
    {map, ?ANNO, []}.

-spec map_put(ast(), ast(), ast()) -> ast().
map_put(Base, K, V) ->
    {map, ?ANNO, Base, [{map_field_assoc, ?ANNO, K, V}]}.

-spec bin_seg(ast(), ast() | default, [atom()] | default) -> ast().
bin_seg(Expr, Size, Types) ->
    {bin, ?ANNO, [{bin_element, ?ANNO, Expr, Size, Types}]}.

-spec bin_pat([{ast(), ast() | default, [atom()] | default}]) -> ast().
bin_pat(Segments) ->
    {bin, ?ANNO, [{bin_element, ?ANNO, P, S, T} || {P, S, T} <- Segments]}.

-spec bin_lit(binary()) -> ast().
bin_lit(Bin) ->
    {bin, ?ANNO, [{bin_element, ?ANNO, {string, ?ANNO, unicode:characters_to_list(Bin)}, default, default}]}.

-spec name_lit(binary()) -> ast().
name_lit(Bin) ->
    bin_lit(Bin).

-spec ok_t(ast()) -> ast().
ok_t(Value) ->
    tuple_t([at(ok), Value]).

-spec ok3(ast(), ast()) -> ast().
ok3(Value, Rest) ->
    tuple_t([at(ok), Value, Rest]).

-spec err_encode(ast()) -> ast().
err_encode(Reason) ->
    tuple_t([at(error), tuple_t([at(encode), Reason])]).

-spec err_decode(ast()) -> ast().
err_decode(Reason) ->
    tuple_t([at(error), tuple_t([at(decode), Reason])]).

-spec mismatch(ast()) -> ast().
mismatch(Value) ->
    tuple_t([at(value_does_not_match_type), Value]).

-spec literal(term()) -> ast().
literal(Term) when is_atom(Term) ->
    at(Term);
literal(Term) when is_binary(Term) ->
    bin_lit(Term);
literal(Term) when is_tuple(Term) ->
    tuple_t([literal(Element) || Element <- tuple_to_list(Term)]).

-spec atom_concat(atom(), binary()) -> atom().
atom_concat(Atom, Suffix) ->
    binary_to_atom(<<(atom_to_binary(Atom, utf8))/binary, Suffix/binary>>, utf8).

%%--------------------------------------------------------------------
%% Struct entry checks
%%--------------------------------------------------------------------

%% The entry clauses of a specialized encode function: the map guard with
%% the value_does_not_match_type fallthrough, mirroring the generic
%% engines' non-map struct handling.

-spec encode_entry_clause(ast()) -> ast().
encode_entry_clause(CheckBody) ->
    clause([v("Value")], [remote(erlang, is_map, [v("Value")])], [CheckBody]).

-spec encode_error_clause() -> ast().
encode_error_clause() ->
    %% The same shape as the container mismatch tail: bind the value and
    %% report it.
    mismatch_fn_tail().

%% The union check counts present fields by name (declaration order);
%% the required check collects the missing names in declaration order —
%% both mirror check_present_fields of the generic engines. `Call' is
%% the protocol-specific handoff expression (the first chain function
%% with its arguments).

-spec union_check([#tg_field{}], ast()) -> ast().
union_check(Fields, Call) ->
    Names = [name_lit(F#tg_field.name) || F <- Fields],
    'case'(
        lc(v("N"), [{generate, ?ANNO, v("N"), list_lit(Names)}, key_filter(v("N"), v("Value"), true)]),
        [
            clause([cons(v("_"), nil())], none, [Call]),
            clause([nil()], none, [err_encode(at(union_empty))]),
            clause([v("_")], none, [err_encode(at(union_multiple))])
        ]
    ).

-spec required_check([#tg_field{}], ast()) -> ast().
required_check(Fields, Call) ->
    Required = [F || F <- Fields, F#tg_field.required =:= required],
    Names = [name_lit(F#tg_field.name) || F <- Required],
    'case'(
        lc(v("N"), [{generate, ?ANNO, v("N"), list_lit(Names)}, key_filter(v("N"), v("Value"), false)]),
        [
            clause([nil()], none, [Call]),
            clause([v("Missing")], none, [
                err_encode(tuple_t([at(missing_required_fields), v("Missing")]))
            ])
        ]
    ).

%% Comprehension filters are bare expressions in the abstract format —
%% the `{filter, _}' wrapper exists only in erl_syntax trees.

-spec key_filter(ast(), ast(), boolean()) -> ast().
key_filter(N, Map, true) ->
    remote(maps, is_key, [N, Map]);
key_filter(N, Map, false) ->
    {op, ?ANNO, 'not', remote(maps, is_key, [N, Map])}.

%%--------------------------------------------------------------------
%% Type AST helpers
%%--------------------------------------------------------------------

-spec fun_type([ast()], ast()) -> ast().
fun_type(Args, Ret) ->
    {type, ?ANNO, 'fun', [{type, ?ANNO, product, Args}, Ret]}.

-spec t_atom(atom()) -> ast().
t_atom(Name) ->
    {type, ?ANNO, Name, []}.

-spec t_atom_lit(atom()) -> ast().
t_atom_lit(A) ->
    {atom, ?ANNO, A}.

-spec t_map_exact() -> ast().
t_map_exact() ->
    {type, ?ANNO, map, [{type, ?ANNO, map_field_exact, [t_atom(binary), t_atom(term)]}]}.

-spec t_map_loose() -> ast().
t_map_loose() ->
    {type, ?ANNO, map, [{type, ?ANNO, map_field_assoc, [t_atom(binary), t_atom(term)]}]}.

-spec t_ok(ast()) -> ast().
t_ok(Type) ->
    {type, ?ANNO, tuple, [{atom, ?ANNO, ok}, Type]}.

-spec t_error() -> ast().
t_error() ->
    {type, ?ANNO, tuple, [{atom, ?ANNO, error}, t_atom(term)]}.

-spec t_union([ast()]) -> ast().
t_union(Options) ->
    {type, ?ANNO, union, Options}.

-spec t_fun([ast()], ast()) -> ast().
t_fun(Args, Ret) ->
    fun_type(Args, Ret).

-spec spec_form(atom(), arity(), [ast()]) -> {attribute, erl_anno:anno(), spec, term()}.
spec_form(Name, Arity, Types) ->
    {attribute, ?ANNO, spec, {{Name, Arity}, Types}}.
