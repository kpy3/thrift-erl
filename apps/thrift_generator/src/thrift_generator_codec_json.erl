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

-module(thrift_generator_codec_json).

-moduledoc """
Specialized JSON wire codecs emitted into the types module: per struct
an `encode_<X>_json/1` (wire map → `{ok, iodata()} | {error, _}`), a
`decode_<X>_json/1` (binary → `{ok, WireMap, Rest} | more | {error,
_}`, consuming the message envelope's closing `]` like the top-level
generic decode) and a `json_codec/1` dispatcher (`{ok, {Encode,
Decode}} | error` by wire struct name). The clauses mirror the generic
engine (`thrift_erl_json`) byte for byte and error term for error term
— the same discipline as the binary and compact emitters, proven by
the PropEr equivalence properties and the negative battery in
`thrift_codec_test`.

Shape of the generated encode: a chain of per-field functions building
the list of `"id":{"tag":value}` chunks in declaration order (absent
fields fall through), the entry wrapping it in `{...}` with commas
joined exactly like the generic `lists:join`. The decode is a
fields/field/after-function triple walking the JSON object with the
shared scanner primitives (`json_skip_ws`, `json_expect`,
`json_scan_string`, `json_scan_number` — emitted once per module, when
something calls them) and a per-id/tag dispatch whose unknown-id clause
delegates to the exported `thrift_erl_json:skip_by_tag/2`.

Every type tag (`"i32"`, `"str"`, `"rec"`, ...) and the
`"id":{"tag":` field prefixes are compile-time literals. Doubles use
the shared `json_format_double` (16 fractional digits), map keys are
restricted to scalars and enums — a map over any other key type degrades
to constant `type_not_supported` errors, and so does `uuid` anywhere.
Nested same-module struct refs call the sibling's decode body (the
`]`-fold belongs to the top level only); cross-module refs go through
the generic engine, which probes the target module's `json_codec/1`.

Forms are built as raw `erl_parse` trees — patterns, guards and the
`try ... catch` key conversions have no convenient `erl_syntax`
constructors — so `erl_pp` renders them; doc and spec attributes stay
syntax trees like everywhere else in the emitter.
""".

-export([export_entries/2, module_forms/2]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

%% The raw `erl_parse' vocabulary is shared with the binary and compact
%% codec emitters; the JSON-specific shapes (tags, scanner primitives,
%% key text conversions) stay local to this module.

-import(thrift_generator_codec_ast, [
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

%% Helper call graph: a helper is emitted when any generated form
%% mentions it, and its own dependencies come along.

-define(HELPER_DEPS, #{
    json_scan_string => [json_scan_string_body],
    json_scan_string_body => [json_hex_value],
    json_scan_number => [json_take_number, json_classify_number],
    json_classify_number => [json_float_marker],
    json_escape => [json_escape_byte]
}).

-define(HELPERS, [
    json_skip_ws,
    json_expect,
    json_scan_string,
    json_scan_string_body,
    json_hex_value,
    json_scan_number,
    json_take_number,
    json_classify_number,
    json_float_marker,
    json_escape,
    json_escape_byte,
    json_format_double,
    json_dup_keys,
    json_field_id
]).

-define(ANNO, erl_anno:new(0)).

-type wire_type() :: thrift_generator_codec:wire_type().
-type ast() :: thrift_generator_codec_ast:ast().

%%--------------------------------------------------------------------
%% Module assembly
%%--------------------------------------------------------------------

-doc "The `-export/1` entries of the JSON wire codecs: `json_codec/1` plus one pair per struct.".
-spec export_entries(#tg_module{}, #ectx{}) -> [{atom(), arity()}].
export_entries(Mod, Ctx) ->
    [{json_codec, 1}] ++
        lists:append([
            [{Encode, 1}, {Decode, 1}]
         || {Encode, Decode} <- [json_pair(S, Ctx) || S <- Mod#tg_module.structs]
        ]).

-doc """
Every JSON wire-codec form of the module: per-struct encode/decode
functions, container and scanner helpers, `json_codec/1`.
""".
-spec module_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
module_forms(Mod, Ctx) ->
    WireTypes = [wtype(F#tg_field.type, Ctx) || S <- Mod#tg_module.structs, F <- S#tg_struct.fields],
    Enums = thrift_generator_codec:enum_registry(WireTypes, #{}),
    Blocks = lists:append([
        [
            thrift_generator_emitter_syntax:section_form(
                io_lib:format("~s json wire codecs", [thrift_generator_emitter:section_label(S)])
            )
        ] ++
            struct_forms(S, Ctx, Enums)
     || S <- Mod#tg_module.structs
    ]),
    Containers = lists:usort(
        lists:append([containers_json(T) || T <- WireTypes])
    ),
    ContainerForms = lists:append([container_forms(C, Ctx, Enums) || C <- Containers]),
    Codec = json_codec_forms(Mod, Ctx),
    Blocks ++
        ContainerForms ++
        %% The scanner and conversion helper set is derived from the
        %% calls the struct, container and codec forms actually make,
        %% closed over ?HELPER_DEPS — the same usage-based discipline as
        %% the binary emitter's dec_string and the compact emitter's
        %% varint helpers.
        lists:append([
            helper_forms(Name)
         || Name <- ?HELPERS,
            lists:member(Name, used_helpers(Blocks ++ ContainerForms ++ Codec))
        ]) ++
        Codec.

%% The JSON container set of one field type: like
%% thrift_generator_codec:containers/1, but a map whose key no JSON
%% object can carry cuts off its key/value subtrees — the map itself
%% compiles to constant-error functions and nothing nested under it is
%% ever called, so emitting those helpers would leave them unused.

-spec containers_json(wire_type()) -> [wire_type()].
containers_json({list, T}) ->
    [{list, T} | containers_json(T)];
containers_json({set, T, _Impl}) ->
    [{set, T} | containers_json(T)];
containers_json({map, K, V}) ->
    case map_key_supported(K) of
        supported -> [{map, K, V} | containers_json(K) ++ containers_json(V)];
        unsupported -> [{map, K, V}]
    end;
containers_json(_) ->
    [].

-spec used_helpers(erl_syntax:forms()) -> [atom()].
used_helpers(Forms) ->
    closure(collect_calls(Forms)).

-spec collect_calls(erl_syntax:forms()) -> [atom()].
collect_calls(Tree) when is_list(Tree) ->
    lists:append([collect_calls(T) || T <- Tree]);
collect_calls({call, _ANNO, {atom, _ANNO2, Name}, _Args}) ->
    [Name];
collect_calls(Tuple) when is_tuple(Tuple) ->
    collect_calls(tuple_to_list(Tuple));
collect_calls(_Other) ->
    [].

-spec closure([atom()]) -> [atom()].
closure(Calls) ->
    closure(lists:usort(Calls), []).

closure([], Acc) ->
    Acc;
closure([Name | Rest], Acc) ->
    Deps = [D || D <- maps:get(Name, ?HELPER_DEPS, []), not lists:member(D, Rest ++ Acc)],
    closure(Rest ++ Deps, [Name | Acc]).

%%--------------------------------------------------------------------
%% Names
%%--------------------------------------------------------------------

-spec json_pair(#tg_struct{} | binary(), #ectx{}) -> {atom(), atom()}.
json_pair(S, Ctx) when is_record(S, tg_struct) ->
    Name = S#tg_struct.name,
    json_pair(Name, Ctx);
json_pair(Name, Ctx) when is_binary(Name) ->
    Prefix = thrift_generator_codec:typed_prefix(
        thrift_generator_codec:current_prefix(Ctx), thrift_generator_names:snake(Name)
    ),
    {
        binary_to_atom(<<"encode_", Prefix/binary, "_json">>, utf8),
        binary_to_atom(<<"decode_", Prefix/binary, "_json">>, utf8)
    }.

-spec struct_json_pair(binary(), #ectx{}) -> {atom(), atom()}.
struct_json_pair(Name, Ctx) ->
    json_pair(Name, Ctx).

-spec enc_name(wire_type(), #{integer() => pos_integer()}) -> atom().
enc_name(T, Enums) ->
    binary_to_atom(<<"enc_", (thrift_generator_codec:type_name(T, Enums))/binary, "_j">>, utf8).

-spec dec_name(wire_type(), #{integer() => pos_integer()}) -> atom().
dec_name(T, Enums) ->
    binary_to_atom(<<"dec_", (thrift_generator_codec:type_name(T, Enums))/binary, "_j">>, utf8).

%%--------------------------------------------------------------------
%% Per-struct blocks
%%--------------------------------------------------------------------

-spec struct_forms(#tg_struct{}, #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
struct_forms(S, Ctx, Enums) ->
    {Encode, Decode} = json_pair(S, Ctx),
    FieldTypes = [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields],
    encode_forms(S, Encode, FieldTypes, Ctx, Enums) ++
        decode_forms(S, Decode, FieldTypes, Ctx, Enums).

%%--------------------------------------------------------------------
%% Encode side
%%--------------------------------------------------------------------

%% Entry clauses (map guard, required/union check) plus a chain of
%% per-field functions building the chunk list; the entry joins the
%% chunks with commas inside the braces, exactly the generic
%% encode_struct_j shape.

-spec encode_forms(#tg_struct{}, atom(), [wire_type()], #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
encode_forms(S, Encode, FieldTypes, Ctx, Enums) ->
    Chain = atom_concat(Encode, <<"_fields">>),
    %% The checks hand off to the FIRST chain function; with no fields
    %% the chain name itself is the empty chunk list.
    Entry =
        case S#tg_struct.fields of
            [] -> Chain;
            _ -> chain_fn_name(Chain, 1)
        end,
    Wrap =
        'case'(call_local(Entry, [v("Value")]), [
            ok_bind_clause(
                v("Chunks"),
                ok_t(
                    list_lit([
                        bin_lit(<<"{">>),
                        remote(lists, join, [bin_lit(<<",">>), v("Chunks")]),
                        bin_lit(<<"}">>)
                    ])
                )
            ),
            error_clause()
        ]),
    CheckBody =
        case S#tg_struct.kind of
            union -> union_check(S#tg_struct.fields, Wrap);
            _ -> required_check(S#tg_struct.fields, Wrap)
        end,
    Doc =
        <<
            "Encodes the wire representation (a map keyed by binary field"
            " names) with the JSON protocol, byte-compatible with"
            " thrift_erl_json:encode/2."
        >>,
    thrift_generator_emitter_syntax:doc_form(S#tg_struct.doc, Doc) ++
        [
            spec_form(Encode, 1, [t_fun([t_map_exact()], t_union([t_ok(t_atom(iodata)), t_error()]))]),
            {function, ?ANNO, Encode, 1, [encode_entry_clause(CheckBody), encode_error_clause()]}
        ] ++ chain_forms(Chain, lists:zip(S#tg_struct.fields, FieldTypes), Ctx, Enums, 1).

-spec chain_forms(
    atom(), [{#tg_field{}, wire_type()}], #ectx{}, #{integer() => pos_integer()}, pos_integer()
) ->
    erl_syntax:forms().
chain_forms(Chain, [], _Ctx, _Enums, _N) ->
    %% Zero fields: the chain name itself is the empty chunk list.
    [{function, ?ANNO, Chain, 1, [clause([v("_Value")], none, [ok_t(nil())])]}];
chain_forms(Chain, Fields, Ctx, Enums, 1) when Fields =/= [] ->
    chain_fns(Chain, Fields, Ctx, Enums, 1).

%% The field functions proper: each appends its chunk in front of the
%% remaining chunk list; the last one answers the empty list.

-spec chain_fns(
    atom(), [{#tg_field{}, wire_type()}], #ectx{}, #{integer() => pos_integer()}, pos_integer()
) ->
    erl_syntax:forms().
chain_fns(_Chain, [], _Ctx, _Enums, _N) ->
    [];
chain_fns(Chain, [{F, T}], Ctx, Enums, N) ->
    [chain_fn(Chain, N, F, T, ok_t(nil()), Ctx, Enums)];
chain_fns(Chain, [{F, T} | Rest], Ctx, Enums, N) ->
    Next = call_local(chain_fn_name(Chain, N + 1), [v("Value")]),
    [chain_fn(Chain, N, F, T, Next, Ctx, Enums)] ++ chain_fns(Chain, Rest, Ctx, Enums, N + 1).

-spec chain_fn(
    atom(), pos_integer(), #tg_field{}, wire_type(), ast(), #ectx{} | undefined, #{integer() => pos_integer()}
) ->
    erl_syntax:forms().
chain_fn(Chain, N, F, {base, uuid}, Next, _Ctx, _Enums) ->
    %% A present uuid field never produces a chunk: the constant error
    %% fires before the value is read. An absent one skips on to the
    %% rest of the chain, like any other field.
    Body =
        'case'(v("Value"), [
            clause([map_exact(name_lit(F#tg_field.name), v("_V"))], none, [uuid_error()]),
            clause([v("_")], none, [Next])
        ]),
    {function, ?ANNO, chain_fn_name(Chain, N), 1, [clause([v("Value")], none, [Body])]};
chain_fn(Chain, N, F, T, Next, Ctx, Enums) ->
    %% The whole `"id":{"tag":` prefix is one literal.
    Prefix =
        bin_lit(
            iolist_to_binary([
                $", integer_to_binary(F#tg_field.id), <<"\":{\"">>, json_tag(T), <<"\":">>
            ])
        ),
    Body =
        'case'(v("Value"), [
            clause([map_exact(name_lit(F#tg_field.name), v("V"))], none, [
                'case'(encode_json_expr(T, v("V"), Ctx, Enums), [
                    clause([tuple_t([at(ok), v("E")])], none, [
                        'case'(Next, [
                            ok_bind_clause(
                                v("RestChunks"),
                                ok_t(cons(list_lit([Prefix, v("E"), bin_lit(<<"}">>)]), v("RestChunks")))
                            ),
                            error_clause()
                        ])
                    ]),
                    error_clause()
                ])
            ]),
            clause([v("_")], none, [Next])
        ]),
    {function, ?ANNO, chain_fn_name(Chain, N), 1, [clause([v("Value")], none, [Body])]}.

-spec chain_fn_name(atom(), pos_integer()) -> atom().
chain_fn_name(Chain, N) ->
    atom_concat(Chain, <<"_f", (integer_to_binary(N))/binary>>).

%%--------------------------------------------------------------------
%% Wire-type encode expressions
%%--------------------------------------------------------------------

%% Encode expressions: {ok, iodata()} | {error, _}, byte-identical to
%% the generic engine's encode_j clauses. Encodes bind nothing — the
%% case variables are the outer value.

-spec encode_json_expr(wire_type(), ast(), #ectx{} | undefined, #{integer() => pos_integer()}) -> ast().
encode_json_expr({base, bool}, V, _Ctx, _Enums) ->
    'case'(V, [
        clause([at(true)], none, [ok_t(bin_lit(<<"true">>))]),
        clause([at(false)], none, [ok_t(bin_lit(<<"false">>))]),
        mismatch_tail(V)
    ]);
encode_json_expr({base, B}, V, _Ctx, _Enums) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    'case'(V, [
        clause(
            [v("_")],
            [int_range(B, V)],
            [ok_t(remote(erlang, integer_to_binary, [V]))]
        ),
        clause([v("_")], none, [err_encode(mismatch(V))])
    ]);
encode_json_expr({base, double}, V, _Ctx, _Enums) ->
    'case'(V, [
        clause([v("_")], [remote(erlang, is_number, [V])], [
            ok_t(call_local(json_format_double, [V]))
        ]),
        mismatch_tail(V)
    ]);
encode_json_expr({base, S}, V, _Ctx, _Enums) when S =:= string; S =:= binary ->
    'case'(V, [
        clause([v("_")], [remote(erlang, is_binary, [V])], [
            ok_t(list_lit([i(34), call_local(json_escape, [V]), i(34)]))
        ]),
        mismatch_tail(V)
    ]);
%% The uuid refusals case on their argument: the constant itself reads
%% nothing (the generic ignores the value too), but the callers' pair
%% clauses bind the value/input for every other type — a plain constant
%% would leave those bindings unused and fail warnings_as_errors.
encode_json_expr({base, uuid}, V, _Ctx, _Enums) ->
    'case'(V, [clause([v("_")], none, [uuid_error()])]);
encode_json_expr({enum, Desc}, V, _Ctx, _Enums) ->
    'case'(remote(thrift_erl_protocol, enum_to_int, [enum_desc_lit(Desc), V]), [
        ok_bind_clause(v("Int"), ok_t(remote(erlang, integer_to_binary, [v("Int")]))),
        clause([at(error)], none, [err_encode(tuple_t([at(unknown_enum_value), V]))])
    ]);
encode_json_expr({struct, {ref, TypesMod, Local}}, V, Ctx, _Enums) ->
    struct_encode_call(TypesMod, Local, V, Ctx);
encode_json_expr({list, _} = T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]);
encode_json_expr({set, _, _} = T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]);
encode_json_expr({set, _} = T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]);
encode_json_expr({map, _, _} = T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]).

-spec int_range(atom(), ast()) -> ast().
int_range(B, V) ->
    {Low, High} = int_bounds(B),
    {op, ?ANNO, 'andalso', {op, ?ANNO, '>=', V, i(Low)}, {op, ?ANNO, '=<', V, i(High)}}.

-spec int_bounds(atom()) -> {integer(), integer()}.
int_bounds(i8) ->
    {-128, 127};
int_bounds(i16) ->
    {-32768, 32767};
int_bounds(i32) ->
    {-2147483648, 2147483647};
int_bounds(i64) ->
    {-(1 bsl 63), (1 bsl 63) - 1}.

-spec struct_encode_call(module(), binary(), ast(), #ectx{}) -> ast().
struct_encode_call(TypesMod, Local, V, Ctx) ->
    case TypesMod =:= types_module_atom(Ctx#ectx.current) of
        true ->
            {Encode, _Decode} = struct_json_pair(Local, Ctx),
            call_local(Encode, [V]);
        false ->
            remote(thrift_erl_json, encode, [literal({struct, {ref, TypesMod, Local}}), V])
    end.

-spec struct_decode_call(module(), binary(), ast(), #ectx{}) -> ast().
%% Nested same-module refs call the body (no `]`-fold); cross-module
%% refs go through the runtime's non-folding nested entry, which probes
%% the specialized pair and falls back to the generic nested decode.
struct_decode_call(TypesMod, Local, Bin, Ctx) ->
    case TypesMod =:= types_module_atom(Ctx#ectx.current) of
        true ->
            {_Encode, Decode} = struct_json_pair(Local, Ctx),
            call_local(decode_body_name(Decode), [Bin]);
        false ->
            remote(thrift_erl_json, decode_nested, [literal({struct, {ref, TypesMod, Local}}), Bin])
    end.

%% The emitter derives the types-module atom from the module key with
%% the same rule (`sanitize(Name) ++ "_types"`); #ectx.current keeps the
%% binary key, so the comparison has to rebuild the atom. A case body,
%% not a guard — binary_to_atom is not guard-legal.
-spec types_module_atom(binary()) -> module().
types_module_atom(Name) ->
    binary_to_atom(<<(thrift_generator_emitter:sanitize(Name))/binary, "_types">>, utf8).

%%--------------------------------------------------------------------
%% Decode side
%%--------------------------------------------------------------------

-spec decode_forms(#tg_struct{}, atom(), [wire_type()], #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
decode_forms(S, Decode, FieldTypes, Ctx, Enums) ->
    Fields = S#tg_struct.fields,
    FieldsName = atom_concat(Decode, <<"_fields">>),
    FieldName = atom_concat(Decode, <<"_field">>),
    AfterName = atom_concat(Decode, <<"_after">>),
    DoneName = atom_concat(Decode, <<"_done">>),
    BodyName = decode_body_name(Decode),
    Required = required_map_lit([
        {F#tg_field.id, F#tg_field.name}
     || {F, _T} <- lists:zip(Fields, FieldTypes),
        F#tg_field.required =:= required
    ]),
    Doc =
        <<
            "Decodes the JSON protocol into the wire representation,"
            " byte-compatible with thrift_erl_json:decode/2; `more` on"
            " truncated input, unknown fields skipped by wire tag."
        >>,
    thrift_generator_emitter_syntax:doc_form(S#tg_struct.doc, Doc) ++
        [
            spec_form(Decode, 1, [
                t_fun(
                    [t_atom(binary)],
                    t_union([
                        t_ok(tuple_t_type([t_map_loose(), t_atom(binary)])),
                        t_atom_lit(more),
                        t_error()
                    ])
                )
            ]),
            %% Top level: the envelope's closing bracket is folded in
            %% (the generic decode_struct_top shape).
            {function, ?ANNO, Decode, 1, [
                clause([v("Binary")], [remote(erlang, is_binary, [v("Binary")])], [
                    'case'(call_local(BodyName, [v("Binary")]), [
                        clause(
                            [
                                tuple_t([
                                    at(ok),
                                    v("Map"),
                                    bin_pat([{i(93), default, default}, {v("Rest"), default, [binary]}])
                                ])
                            ],
                            none,
                            [ok3(v("Map"), v("Rest"))]
                        ),
                        other_tail()
                    ])
                ])
            ]},
            {function, ?ANNO, BodyName, 1, [
                clause([v("Binary")], [remote(erlang, is_binary, [v("Binary")])], [
                    'case'(call_local(json_expect, [v("Binary"), i(123)]), [
                        ok_bind_clause(v("Rest"), call_local(FieldsName, [v("Rest"), Required, map_empty()])),
                        other_tail()
                    ])
                ])
            ]},
            {function, ?ANNO, FieldsName, 3, fields_clauses(FieldName, AfterName, DoneName)},
            {function, ?ANNO, FieldName, 3, field_clauses(Decode)},
            {function, ?ANNO, atom_concat(Decode, <<"_field_value">>), 4,
                dispatch_clauses(lists:zip(Fields, FieldTypes), Ctx, Enums)},
            {function, ?ANNO, AfterName, 3, after_clauses(FieldsName, DoneName)},
            {function, ?ANNO, DoneName, 3, done_clauses()}
        ].

%% One flat literal — a folded map_put over #{} would render as
%% `(#{})#{3 => ...}` and the compiler warns on updating a literal.

-spec required_map_lit([{integer(), binary()}]) -> ast().
required_map_lit(Required) ->
    {map, ?ANNO, [{map_field_assoc, ?ANNO, i(Id), name_lit(Name)} || {Id, Name} <- Required]}.

-spec decode_body_name(atom()) -> atom().
decode_body_name(Decode) ->
    atom_concat(Decode, <<"_body">>).

%% The loop: whitespace, then either the closing brace (required scan),
%% the end of input (more), or one field and its separator.

-spec fields_clauses(atom(), atom(), atom()) -> [ast()].
fields_clauses(FieldName, AfterName, DoneName) ->
    [
        clause(
            [v("Bin"), v("Req"), v("Acc")],
            none,
            [
                'case'(call_local(json_skip_ws, [v("Bin")]), [
                    clause(
                        [bin_pat([{i(125), default, default}, {v("Rest"), default, [binary]}])],
                        none,
                        [call_local(DoneName, [v("Req"), v("Acc"), v("Rest")])]
                    ),
                    clause([bin_pat([])], none, [at(more)]),
                    clause([v("Rest0")], none, [
                        'case'(call_local(FieldName, [v("Rest0"), v("Req"), v("Acc")]), [
                            clause(
                                [tuple_t([at(ok), v("Acc1"), v("Req1"), v("Rest1")])],
                                none,
                                [call_local(AfterName, [v("Rest1"), v("Req1"), v("Acc1")])]
                            ),
                            other_tail()
                        ])
                    ])
                ])
            ]
        )
    ].

-spec after_clauses(atom(), atom()) -> [ast()].
after_clauses(FieldsName, DoneName) ->
    [
        clause([v("Bin"), v("Req"), v("Acc")], none, [
            'case'(call_local(json_skip_ws, [v("Bin")]), [
                clause(
                    [bin_pat([{i(44), default, default}, {v("Rest"), default, [binary]}])],
                    none,
                    [call_local(FieldsName, [v("Rest"), v("Req"), v("Acc")])]
                ),
                clause(
                    [bin_pat([{i(125), default, default}, {v("Rest"), default, [binary]}])],
                    none,
                    [call_local(DoneName, [v("Req"), v("Acc"), v("Rest")])]
                ),
                clause([bin_pat([])], none, [at(more)]),
                clause([v("_")], none, [err_decode(at(bad_structure))])
            ])
        ])
    ].

-spec done_clauses() -> [ast()].
done_clauses() ->
    [
        clause([v("Req"), v("Acc"), v("Rest")], none, [
            'case'(remote(maps, values, [v("Req")]), [
                clause([nil()], none, [ok3(v("Acc"), v("Rest"))]),
                clause([v("Missing")], none, [
                    err_decode(tuple_t([at(missing_required_fields), v("Missing")]))
                ])
            ])
        ])
    ].

%% One `"id":{"tag":value}` entry: the scan pipeline up to the value,
%% then the per-id/tag dispatch — which already consumed the entry's
%% closing `}' and marks required presence. The value/name bindings
%% stay in the dispatch's answer ({ok, Value, Rest, Req1, NamePut});
%% the field answers {ok, Acc1, Req1, Rest} for the fields loop.

-spec field_clauses(atom()) -> [ast()].
field_clauses(Decode) ->
    Dispatch = atom_concat(Decode, <<"_field_value">>),
    [
        clause([v("Bin"), v("Req"), v("Acc")], none, [
            'case'(call_local(json_scan_string, [v("Bin")]), [
                clause([tuple_t([at(ok), v("IdText"), v("Rest0")])], none, [
                    'case'(call_local(json_field_id, [v("IdText")]), [
                        ok_bind_clause(
                            v("Id"),
                            'case'(call_local(json_expect, [v("Rest0"), i(58)]), [
                                ok_bind_clause(
                                    v("Rest1"),
                                    'case'(call_local(json_expect, [v("Rest1"), i(123)]), [
                                        ok_bind_clause(
                                            v("Rest2"),
                                            'case'(call_local(json_scan_string, [v("Rest2")]), [
                                                clause([tuple_t([at(ok), v("Tag"), v("Rest3")])], none, [
                                                    'case'(call_local(json_expect, [v("Rest3"), i(58)]), [
                                                        ok_bind_clause(
                                                            v("Rest4"),
                                                            'case'(
                                                                call_local(Dispatch, [
                                                                    v("Id"),
                                                                    v("Tag"),
                                                                    v("Rest4"),
                                                                    v("Req")
                                                                ]),
                                                                [
                                                                    clause(
                                                                        [
                                                                            tuple_t([
                                                                                at(ok),
                                                                                v("V"),
                                                                                v("Rest5"),
                                                                                v("Req1"),
                                                                                v("NamePut")
                                                                            ])
                                                                        ],
                                                                        none,
                                                                        [
                                                                            tuple_t([
                                                                                at(ok),
                                                                                put_acc(v("NamePut"), v("V"), v("Acc")),
                                                                                v("Req1"),
                                                                                v("Rest5")
                                                                            ])
                                                                        ]
                                                                    ),
                                                                    other_tail()
                                                                ]
                                                            )
                                                        ),
                                                        other_tail()
                                                    ])
                                                ]),
                                                other_tail()
                                            ])
                                        ),
                                        other_tail()
                                    ])
                                ),
                                other_tail()
                            ])
                        ),
                        other_tail()
                    ])
                ]),
                other_tail()
            ])
        ])
    ].

%% The accumulator update: unknown ids leave the map untouched.

-spec put_acc(ast(), ast(), ast()) -> ast().
put_acc(NamePut, V, Acc) ->
    'case'(NamePut, [
        clause([at(undefined)], none, [Acc]),
        clause([v("_")], none, [map_put(Acc, NamePut, V)])
    ]).

%% Per-id/tag clauses: the right tag decodes and marks required
%% presence, a wrong one is a field_type_mismatch, a uuid field matches
%% only the empty tag and constant-errors, unknown ids skip by tag.

-spec dispatch_clauses([{#tg_field{}, wire_type()}], #ectx{}, #{integer() => pos_integer()}) -> [ast()].
dispatch_clauses(FieldTypes, Ctx, Enums) ->
    lists:append([field_value_clauses(F, T, Ctx, Enums) || {F, T} <- FieldTypes]) ++
        [skip_clause()].

-spec field_value_clauses(#tg_field{}, wire_type(), #ectx{}, #{integer() => pos_integer()}) -> [ast()].
field_value_clauses(F, {base, uuid}, _Ctx, _Enums) ->
    %% tag(j_unsupported) is the empty string: the field matches only
    %% `""` and then constant-errors, exactly the generic path. The
    %% unused tail parameters stay underscored — the constant error
    %% reads neither the input nor the required map.
    [
        clause(
            [i(F#tg_field.id), bin_pat([]), v("_Bin"), v("_Req")],
            none,
            [uuid_decode_error()]
        ),
        mismatch_clause(F#tg_field.id)
    ];
field_value_clauses(F, T, Ctx, Enums) ->
    Id = F#tg_field.id,
    [
        clause(
            [i(Id), bin_lit(json_tag(T)), v("Bin"), v("Req")],
            none,
            [
                %% The value decode case is the SUBJECT of the outer
                %% case: names its branches bind (V, Rest, the
                %% catch-all) stay in scope after it, so the outer
                %% destructure and catch-all carry distinct names.
                'case'(decode_json_expr(T, v("Bin"), Ctx, Enums), [
                    clause([tuple_t([at(ok), v("Val"), v("RestOut")])], none, [
                        'case'(call_local(json_expect, [v("RestOut"), i(125)]), [
                            ok_bind_clause(
                                v("RestBrace"),
                                tuple_t([
                                    at(ok),
                                    v("Val"),
                                    v("RestBrace"),
                                    mark_present(i(Id), v("Req")),
                                    name_lit(F#tg_field.name)
                                ])
                            ),
                            %% The subject case exports `Other' (its
                            %% catch-all branch binds it) — a different
                            %% name here keeps this handler a fresh bind.
                            other_clause("OtherExpect")
                        ])
                    ]),
                    other_clause("OtherDispatch")
                ])
            ]
        ),
        mismatch_clause(Id)
    ].

-spec mismatch_clause(integer()) -> ast().
mismatch_clause(Id) ->
    clause([i(Id), v("_Tag"), v("_Bin"), v("_Req")], none, [
        err_decode(tuple_t([at(field_type_mismatch), i(Id)]))
    ]).

-spec mark_present(ast(), ast()) -> ast().
mark_present(Id, Req) ->
    'case'(Req, [
        clause([{map, ?ANNO, [{map_field_exact, ?ANNO, Id, v("_")}]}], none, [
            remote(maps, remove, [Id, Req])
        ]),
        clause([v("_")], none, [Req])
    ]).

-spec skip_clause() -> ast().
skip_clause() ->
    %% Like every dispatch clause, the skip consumes the field entry's
    %% closing brace before answering the 5-tuple.
    clause([v("_Id"), v("Tag"), v("Bin"), v("Req")], none, [
        'case'(remote(thrift_erl_json, skip_by_tag, [v("Tag"), v("Bin")]), [
            ok_bind_clause(
                v("Rest"),
                'case'(call_local(json_expect, [v("Rest"), i(125)]), [
                    ok_bind_clause(
                        v("Rest1"),
                        tuple_t([
                            at(ok), at(undefined), v("Rest1"), v("Req"), at(undefined)
                        ])
                    ),
                    other_clause("OtherSkipExpect")
                ])
            ),
            other_tail()
        ])
    ]).

-spec decode_json_expr(wire_type(), ast(), #ectx{} | undefined, #{integer() => pos_integer()}) -> ast().
decode_json_expr({base, bool}, Bin, _Ctx, _Enums) ->
    'case'(call_local(json_skip_ws, [Bin]), [
        clause([bin_pat([{pat_str(<<"true">>), default, default}, {v("Rest"), default, [binary]}])], none, [
            ok3(at(true), v("Rest"))
        ]),
        clause([bin_pat([{pat_str(<<"false">>), default, default}, {v("Rest"), default, [binary]}])], none, [
            ok3(at(false), v("Rest"))
        ]),
        clause([bin_pat([])], none, [at(more)]),
        clause([v("_")], none, [err_decode(tuple_t([at(bad_value_for_base_type), at(bool)]))])
    ]);
decode_json_expr({base, B}, Bin, _Ctx, _Enums) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    %% The catch-all exports `OtherDecode', not `Other': callers wrap
    %% this case as their subject, and a same-name handler after the
    %% subject would be an unsafe re-bind.
    'case'(call_local(json_scan_number, [Bin]), [
        clause([tuple_t([at(ok), tuple_pat([at(int), v("V")]), v("Rest")])], none, [ok3(v("V"), v("Rest"))]),
        clause([tuple_t([at(ok), tuple_pat([at(float), v("_")]), v("_")])], none, [
            err_decode(tuple_t([at(bad_value_for_base_type), at(B)]))
        ]),
        other_clause("OtherDecode")
    ]);
decode_json_expr({base, double}, Bin, _Ctx, _Enums) ->
    'case'(call_local(json_scan_number, [Bin]), [
        clause([tuple_t([at(ok), tuple_pat([at(float), v("V")]), v("Rest")])], none, [ok3(v("V"), v("Rest"))]),
        clause([tuple_t([at(ok), tuple_pat([at(int), v("V")]), v("Rest")])], none, [
            ok3(remote(erlang, float, [v("V")]), v("Rest"))
        ]),
        other_clause("OtherDecode")
    ]);
decode_json_expr({base, S}, Bin, _Ctx, _Enums) when S =:= string; S =:= binary ->
    call_local(json_scan_string, [Bin]);
decode_json_expr({base, uuid}, Bin, _Ctx, _Enums) ->
    'case'(Bin, [clause([v("_")], none, [uuid_decode_error()])]);
decode_json_expr({enum, Desc}, Bin, _Ctx, _Enums) ->
    'case'(call_local(json_scan_number, [Bin]), [
        clause([tuple_t([at(ok), tuple_pat([at(int), v("Int")]), v("Rest")])], none, [
            'case'(remote(thrift_erl_protocol, enum_from_int, [enum_desc_lit(Desc), v("Int")]), [
                ok_bind_clause(v("Atom"), ok3(v("Atom"), v("Rest"))),
                clause([at(error)], none, [ok3(v("Int"), v("Rest"))])
            ])
        ]),
        other_clause("OtherDecode")
    ]);
decode_json_expr({struct, {ref, TypesMod, Local}}, Bin, Ctx, _Enums) ->
    struct_decode_call(TypesMod, Local, Bin, Ctx);
decode_json_expr({list, _} = T, Bin, _Ctx, Enums) ->
    call_local(dec_name(T, Enums), [Bin]);
decode_json_expr({set, _, _} = T, Bin, _Ctx, Enums) ->
    call_local(dec_name(T, Enums), [Bin]);
decode_json_expr({set, _} = T, Bin, _Ctx, Enums) ->
    call_local(dec_name(T, Enums), [Bin]);
decode_json_expr({map, _, _} = T, Bin, _Ctx, Enums) ->
    call_local(dec_name(T, Enums), [Bin]).

%%--------------------------------------------------------------------
%% Container helpers
%%--------------------------------------------------------------------

-spec container_forms(wire_type(), #ectx{}, #{integer() => pos_integer()}) -> erl_syntax:forms().
container_forms({Kind, _} = T, Ctx, Enums) when Kind =:= list; Kind =:= set ->
    Elem = thrift_generator_codec:elem_type(T),
    Tag = bin_lit(json_tag(Elem)),
    Enc = enc_name(T, Enums),
    Dec = dec_name(T, Enums),
    EncElems = atom_concat(Enc, <<"_elems">>),
    DecElems = atom_concat(Dec, <<"_elems">>),
    %% A uuid element encodes as the empty tag and errors on the first
    %% real element; the empty list itself still encodes.
    EncElemsForms =
        case Elem of
            {base, uuid} ->
                [
                    {function, ?ANNO, EncElems, 1, [
                        clause([nil()], none, [ok_t(nil())]),
                        uuid_error_clause(1)
                    ]}
                ];
            _ ->
                [
                    {function, ?ANNO, EncElems, 1, [
                        clause([nil()], none, [ok_t(nil())]),
                        clause([cons(v("V"), v("Rest"))], none, [
                            'case'(encode_json_expr(Elem, v("V"), Ctx, Enums), [
                                ok_bind_clause(
                                    v("E"),
                                    'case'(call_local(EncElems, [v("Rest")]), [
                                        ok_bind_clause(v("RestIo"), ok_t(cons(v("E"), v("RestIo")))),
                                        error_clause()
                                    ])
                                ),
                                error_clause()
                            ])
                        ])
                    ]}
                ]
        end,
    DecElemsForms = dec_elems_forms(Elem, DecElems, Ctx, Enums),
    [
        {function, ?ANNO, Enc, 1, [
            clause([v("Values")], [remote(erlang, is_list, [v("Values")])], [
                'case'(call_local(EncElems, [v("Values")]), [
                    ok_bind_clause(
                        v("Es"),
                        ok_t(
                            list_lit([
                                list_lit([
                                    bin_lit(<<"[\"">>),
                                    Tag,
                                    bin_lit(<<"\",">>),
                                    remote(erlang, integer_to_binary, [call_local(length, [v("Values")])]),
                                    %% An empty array has no comma after the size.
                                    'case'(v("Es"), [
                                        clause([nil()], none, [nil()]),
                                        clause([v("_")], none, [bin_lit(<<",">>)])
                                    ])
                                ]),
                                remote(lists, join, [bin_lit(<<",">>), v("Es")]),
                                bin_lit(<<"]">>)
                            ])
                        )
                    ),
                    error_clause()
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, Dec, 1, dec_seq_clauses(Tag, DecElems)}
    ] ++ EncElemsForms ++ DecElemsForms;
container_forms({map, K, V} = T, Ctx, Enums) ->
    case map_key_supported(K) of
        unsupported ->
            %% A map whose key no JSON object key can carry compiles to
            %% {j_unsupported, {map, K, V}} as a whole: constant errors
            %% both ways, even for the empty map. A supported key with
            %% any value type keeps the full machinery — uuid values
            %% error per pair, exactly the generic compile.
            Desc = literal(T),
            [
                {function, ?ANNO, enc_name(T, Enums), 1, [
                    clause([v("_Value")], none, [
                        err_encode(tuple_t([at(type_not_supported), Desc, at(json)]))
                    ])
                ]},
                {function, ?ANNO, dec_name(T, Enums), 1, [
                    clause([v("_Bin")], none, [
                        err_decode(tuple_t([at(type_not_supported), Desc, at(json)]))
                    ])
                ]}
            ];
        supported ->
            container_map_forms(T, K, V, Ctx, Enums)
    end.

-spec map_key_supported(wire_type()) -> supported | unsupported.
map_key_supported({base, uuid}) ->
    unsupported;
map_key_supported({base, _B}) ->
    supported;
map_key_supported({enum, _Desc}) ->
    supported;
map_key_supported(_T) ->
    unsupported.

-spec container_map_forms(wire_type(), wire_type(), wire_type(), #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
container_map_forms(T, K, V, Ctx, Enums) ->
    Enc = enc_name(T, Enums),
    Dec = dec_name(T, Enums),
    EncPairs = atom_concat(Enc, <<"_pairs">>),
    DecPairs = atom_concat(Dec, <<"_pairs">>),
    DecPair = atom_concat(Dec, <<"_pair">>),
    KeyText = atom_concat(Enc, <<"_keytext">>),
    KeyFromText = atom_concat(Dec, <<"_key">>),
    SortFun =
        {'fun', ?ANNO,
            {clauses, [
                clause([tuple_pat([v("A"), v("_")]), tuple_pat([v("B"), v("_")])], none, [
                    {op, ?ANNO, '=<', v("A"), v("B")}
                ])
            ]}},
    [
        {function, ?ANNO, Enc, 1, [
            clause([v("Value")], [remote(erlang, is_map, [v("Value")])], [
                'case'(call_local(EncPairs, [remote(maps, to_list, [v("Value")])]), [
                    clause([tuple_t([at(ok), v("Pairs")])], none, [
                        {match, ?ANNO, v("Sorted"), remote(lists, sort, [SortFun, v("Pairs")])},
                        'case'(call_local(json_dup_keys, [v("Sorted")]), [
                            clause([at(false)], none, [
                                ok_t(
                                    list_lit([
                                        list_lit([
                                            bin_lit(<<"[\"">>),
                                            bin_lit(json_tag(K)),
                                            bin_lit(<<"\",\"">>),
                                            bin_lit(json_tag(V)),
                                            bin_lit(<<"\",">>),
                                            remote(erlang, integer_to_binary, [
                                                call_local(length, [v("Sorted")])
                                            ]),
                                            bin_lit(<<",{">>)
                                        ]),
                                        remote(lists, join, [
                                            bin_lit(<<",">>),
                                            {lc, ?ANNO, v("Chunk"), [
                                                {generate, ?ANNO, tuple_pat([v("_"), v("Chunk")]), v("Sorted")}
                                            ]}
                                        ]),
                                        bin_lit(<<"}]">>)
                                    ])
                                )
                            ]),
                            clause([at(true)], none, [err_encode(at(duplicate_json_keys))])
                        ])
                    ]),
                    error_clause()
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, EncPairs, 1, [
            clause([nil()], none, [ok_t(nil())]),
            clause([cons(tuple_pat([v("K"), v("V")]), v("Rest"))], none, [
                'case'(call_local(KeyText, [v("K")]), [
                    ok_bind_clause(
                        v("KeyText"),
                        'case'(encode_json_expr(V, v("V"), Ctx, Enums), [
                            ok_bind_clause(
                                v("ValIo"),
                                'case'(call_local(EncPairs, [v("Rest")]), [
                                    ok_bind_clause(
                                        v("RestPairs"),
                                        ok_t(
                                            cons(
                                                tuple_t([
                                                    v("KeyText"),
                                                    list_lit([
                                                        i(34),
                                                        call_local(json_escape, [v("KeyText")]),
                                                        i(34),
                                                        i(58),
                                                        v("ValIo")
                                                    ])
                                                ]),
                                                v("RestPairs")
                                            )
                                        )
                                    ),
                                    error_clause()
                                ])
                            ),
                            error_clause()
                        ])
                    ),
                    error_clause()
                ])
            ])
        ]},
        {function, ?ANNO, KeyText, 1, key_text_clauses(K)},
        {function, ?ANNO, Dec, 1, dec_map_clauses(bin_lit(json_tag(K)), bin_lit(json_tag(V)), DecPairs)},
        {function, ?ANNO, KeyFromText, 1, key_from_text_clauses(K)},
        {function, ?ANNO, DecPairs, 3, dec_pairs_clauses(DecPairs, DecPair)}
    ] ++ dec_pair_form(V, KeyFromText, DecPair, Ctx, Enums).

%% The enum descriptor ({Int, Atom} pairs) as a literal AST — the same
%% shape `struct_info/1` hands the generic engines.

-spec enum_desc_lit([{integer(), atom()}]) -> ast().
enum_desc_lit(Desc) ->
    list_lit([tuple_t([i(Int), at(Atom)]) || {Int, Atom} <- Desc]).

%% A literal string segment inside a binary PATTERN — the bare
%% `{string, _}' node (a whole bin tree like bin_lit/1 is illegal
%% there).

-spec pat_str(binary()) -> ast().
pat_str(Bin) ->
    {string, ?ANNO, unicode:characters_to_list(Bin)}.

%% The encoded text of one map key — the generic encode_key_text
%% narrowed to the declared key type.

-spec key_text_clauses(wire_type()) -> [ast()].
key_text_clauses({base, S}) when S =:= string; S =:= binary ->
    [
        clause([v("V")], [remote(erlang, is_binary, [v("V")])], [ok_t(v("V"))]),
        mismatch_fn_tail()
    ];
key_text_clauses({base, bool}) ->
    [
        clause([at(true)], none, [ok_t(bin_lit(<<"true">>))]),
        clause([at(false)], none, [ok_t(bin_lit(<<"false">>))]),
        clause([v("V")], none, [err_encode(mismatch(v("V")))])
    ];
key_text_clauses({base, double}) ->
    [
        clause([v("V")], [remote(erlang, is_number, [v("V")])], [
            ok_t(remote(erlang, iolist_to_binary, [call_local(json_format_double, [v("V")])]))
        ]),
        clause([v("V")], none, [err_encode(mismatch(v("V")))])
    ];
key_text_clauses({base, B}) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    [
        clause([v("V")], [int_range(B, v("V"))], [ok_t(remote(erlang, integer_to_binary, [v("V")]))]),
        clause([v("V")], none, [err_encode(mismatch(v("V")))])
    ];
key_text_clauses({enum, Desc}) ->
    [
        clause([v("V")], none, [
            'case'(remote(thrift_erl_protocol, enum_to_int, [enum_desc_lit(Desc), v("V")]), [
                ok_bind_clause(v("Int"), ok_t(remote(erlang, integer_to_binary, [v("Int")]))),
                clause([at(error)], none, [err_encode(tuple_t([at(unknown_enum_value), v("V")]))])
            ])
        ])
    ].

-spec key_from_text_clauses(wire_type()) -> [ast()].
key_from_text_clauses({base, S}) when S =:= string; S =:= binary ->
    [clause([v("Text")], none, [ok_t(v("Text"))])];
key_from_text_clauses({base, bool}) ->
    [
        clause([bin_lit(<<"true">>)], none, [ok_t(at(true))]),
        clause([bin_lit(<<"false">>)], none, [ok_t(at(false))]),
        clause([v("_")], none, [err_decode(at(bad_map_key))])
    ];
key_from_text_clauses({base, double}) ->
    [
        clause([v("Text")], none, [
            try_catch(
                ok_t(remote(erlang, binary_to_float, [v("Text")])),
                [
                    clause([v("_"), v("_")], none, [
                        try_catch(
                            ok_t(remote(erlang, float, [remote(erlang, binary_to_integer, [v("Text")])])),
                            [clause([v("_"), v("_")], none, [err_decode(at(bad_map_key))])]
                        )
                    ])
                ]
            )
        ])
    ];
key_from_text_clauses({base, _B}) ->
    [
        clause([v("Text")], none, [
            try_catch(
                ok_t(remote(erlang, binary_to_integer, [v("Text")])),
                [clause([v("_"), v("_")], none, [err_decode(at(bad_map_key))])]
            )
        ])
    ];
key_from_text_clauses({enum, Desc}) ->
    [
        clause([v("Text")], none, [
            try_catch(
                [
                    {match, ?ANNO, v("Int"), remote(erlang, binary_to_integer, [v("Text")])},
                    'case'(remote(thrift_erl_protocol, enum_from_int, [enum_desc_lit(Desc), v("Int")]), [
                        ok_bind_clause(v("Atom"), ok_t(v("Atom"))),
                        clause([at(error)], none, [ok_t(v("Int"))])
                    ])
                ],
                [clause([v("_"), v("_")], none, [err_decode(at(bad_map_key))])]
            )
        ])
    ].

%% `try Body catch Class:Reason:Stack -> Handler end' as a raw tree —
%% the key conversions mirror the generic engine's try/catch fallbacks.
%% In the abstract format a `C:R:S' handler is a clause with ONE
%% pattern, the tuple of the three; handlers come in as `[Class,
%% Reason]' and the stack variable is added here (erl_pp prints only
%% this shape).

-spec try_catch(ast() | [ast()], [ast()]) -> ast().
try_catch(Body, CatchClauses) ->
    WithStack = [
        {clause, ?ANNO, [tuple_t(clause_pats(Clause) ++ [v("_St")])], clause_guards(Clause), clause_body(Clause)}
     || {clause, _, _, _, _} = Clause <- CatchClauses
    ],
    {'try', ?ANNO, wrap_body(Body), [], WithStack, []}.

-spec clause_pats(ast()) -> [ast()].
clause_pats({clause, _, Pats, _, _}) ->
    Pats.

-spec clause_guards(ast()) -> [ast()] | ast().
clause_guards({clause, _, _, G, _}) ->
    G.

-spec clause_body(ast()) -> [ast()].
clause_body({clause, _, _, _, B}) ->
    B.

-spec wrap_body(ast() | [ast()]) -> [ast()].
wrap_body(Body) when is_list(Body) ->
    Body;
wrap_body(Body) ->
    [Body].

%% The `Truncated' condition of the generic classify_number: the input
%% ends inside a literal that the next bytes could still complete.

-spec truncated_guard(ast(), ast()) -> ast().
truncated_guard(Rest, Last) ->
    %% An orelse chain, not lists:member/2 — this is a catch GUARD and
    %% only guard BIFs are legal there.
    Marks = lists:foldl(
        fun(Mark, Acc) -> {op, ?ANNO, 'orelse', {op, ?ANNO, '=:=', Last, i(Mark)}, Acc} end,
        {op, ?ANNO, '=:=', Last, i(45)},
        [46, 101, 69, 43]
    ),
    {op, ?ANNO, 'andalso', {op, ?ANNO, '=:=', Rest, bin_lit(<<>>)}, Marks}.

%% The sequence decode: `[` , element tag (literal match), `,`, size,
%% the optional comma, the element loop — the generic decode_sequence_j.

-spec dec_seq_clauses(ast(), atom()) -> [ast()].
dec_seq_clauses(Tag, DecElems) ->
    [
        clause([v("Bin")], none, [
            'case'(call_local(json_expect, [v("Bin"), i(91)]), [
                ok_bind_clause(
                    v("Rest0"),
                    'case'(call_local(json_scan_string, [v("Rest0")]), [
                        clause([tuple_t([at(ok), v("Obs"), v("Rest1")])], none, [
                            'case'(
                                v("Obs"),
                                tag_clauses(Tag, DecElems) ++
                                    [
                                        clause([v("_")], none, [
                                            err_decode(tuple_t([at(element_type_mismatch), v("Obs")]))
                                        ])
                                    ]
                            )
                        ]),
                        other_tail()
                    ])
                ),
                other_tail()
            ])
        ])
    ].

-spec tag_clauses(ast(), atom()) -> [ast()].
tag_clauses(Tag, DecElems) ->
    [
        clause([Tag], none, [
            'case'(call_local(json_expect, [v("Rest1"), i(44)]), [
                ok_bind_clause(
                    v("Rest2"),
                    'case'(call_local(json_scan_number, [v("Rest2")]), [
                        clause(
                            [tuple_t([at(ok), tuple_pat([at(int), v("Size")]), v("Rest3")])],
                            [
                                {op, ?ANNO, 'andalso', remote(erlang, is_integer, [v("Size")]),
                                    {op, ?ANNO, '>=', v("Size"), i(0)}}
                            ],
                            [
                                'case'(
                                    v("Size"),
                                    [
                                        %% An empty array closes right after the
                                        %% size — no comma.
                                        clause([i(0)], none, [call_local(DecElems, [i(0), v("Rest3"), nil()])]),
                                        clause([v("Size")], none, [
                                            'case'(call_local(json_expect, [v("Rest3"), i(44)]), [
                                                ok_bind_clause(
                                                    v("Rest4"),
                                                    call_local(DecElems, [
                                                        v("Size"),
                                                        v("Rest4"),
                                                        nil()
                                                    ])
                                                ),
                                                other_tail()
                                            ])
                                        ])
                                    ]
                                )
                            ]
                        ),
                        clause([tuple_t([at(ok), tuple_pat([at(float), v("_")]), v("_")])], none, [
                            err_decode(at(bad_sequence_size))
                        ]),
                        other_tail()
                    ])
                ),
                other_tail()
            ])
        ])
    ].

-spec dec_elems_forms(wire_type(), atom(), #ectx{}, #{integer() => pos_integer()}) -> [erl_syntax:forms()].
dec_elems_forms({base, uuid}, DecElems, _Ctx, _Enums) ->
    [
        {function, ?ANNO, DecElems, 3, [
            clause([i(0), v("Bin"), v("Acc")], none, [
                'case'(call_local(json_expect, [v("Bin"), i(93)]), [
                    ok_bind_clause(v("Rest"), ok3(remote(lists, reverse, [v("Acc")]), v("Rest"))),
                    other_tail()
                ])
            ]),
            uuid_decode_error_clause(3)
        ]}
    ];
dec_elems_forms(Elem, DecElems, Ctx, Enums) ->
    [
        {function, ?ANNO, DecElems, 3, [
            clause([i(0), v("Bin"), v("Acc")], none, [
                'case'(call_local(json_expect, [v("Bin"), i(93)]), [
                    ok_bind_clause(v("Rest"), ok3(remote(lists, reverse, [v("Acc")]), v("Rest"))),
                    other_tail()
                ])
            ]),
            clause([i(1), v("Bin"), v("Acc")], none, [
                'case'(decode_json_expr(Elem, v("Bin"), Ctx, Enums), [
                    %% The value case is the subject of the outer case: its
                    %% branch names (V, Rest, the catch-all) stay in scope
                    %% after it, so the destructure and handlers below use
                    %% distinct names.
                    clause([tuple_t([at(ok), v("ElemV"), v("ElemRest")])], none, [
                        'case'(call_local(json_expect, [v("ElemRest"), i(93)]), [
                            ok_bind_clause(
                                v("Rest1"),
                                ok3(remote(lists, reverse, [cons(v("ElemV"), v("Acc"))]), v("Rest1"))
                            ),
                            other_clause("OtherElemExpect")
                        ])
                    ]),
                    other_clause("OtherElem")
                ])
            ]),
            clause([v("N"), v("Bin"), v("Acc")], [{op, ?ANNO, '>', v("N"), i(1)}], [
                'case'(decode_json_expr(Elem, v("Bin"), Ctx, Enums), [
                    clause([tuple_t([at(ok), v("ElemV"), v("ElemRest")])], none, [
                        'case'(call_local(json_expect, [v("ElemRest"), i(44)]), [
                            ok_bind_clause(
                                v("Rest1"),
                                call_local(DecElems, [
                                    {op, ?ANNO, '-', v("N"), i(1)},
                                    v("Rest1"),
                                    cons(v("ElemV"), v("Acc"))
                                ])
                            ),
                            other_clause("OtherElemExpect")
                        ])
                    ]),
                    other_clause("OtherElem")
                ])
            ])
        ]}
    ].

-spec dec_map_clauses(ast(), ast(), atom()) -> [ast()].
dec_map_clauses(KeyTag, ValTag, DecPairs) ->
    [
        clause([v("Bin")], none, [
            'case'(call_local(json_expect, [v("Bin"), i(91)]), [
                ok_bind_clause(
                    v("Rest0"),
                    'case'(call_local(json_scan_string, [v("Rest0")]), [
                        clause([tuple_t([at(ok), v("KeyTag"), v("Rest1")])], none, [
                            'case'(v("KeyTag"), [
                                clause([KeyTag], none, [
                                    'case'(call_local(json_expect, [v("Rest1"), i(44)]), [
                                        ok_bind_clause(
                                            v("Rest2"),
                                            'case'(call_local(json_scan_string, [v("Rest2")]), [
                                                clause([tuple_t([at(ok), v("ValTag"), v("Rest3")])], none, [
                                                    'case'(v("ValTag"), [
                                                        clause([ValTag], none, [
                                                            dec_map_tail(DecPairs)
                                                        ]),
                                                        clause([v("_")], none, [
                                                            err_decode(
                                                                tuple_t([at(element_type_mismatch), v("ValTag")])
                                                            )
                                                        ])
                                                    ])
                                                ]),
                                                other_tail()
                                            ])
                                        ),
                                        other_tail()
                                    ])
                                ]),
                                clause([v("_")], none, [
                                    err_decode(tuple_t([at(element_type_mismatch), v("KeyTag")]))
                                ])
                            ])
                        ]),
                        other_tail()
                    ])
                ),
                other_tail()
            ])
        ])
    ].

-spec dec_map_tail(atom()) -> ast().
dec_map_tail(DecPairs) ->
    'case'(call_local(json_expect, [v("Rest3"), i(44)]), [
        ok_bind_clause(
            v("Rest4"),
            'case'(call_local(json_scan_number, [v("Rest4")]), [
                clause(
                    [tuple_t([at(ok), tuple_pat([at(int), v("Size")]), v("Rest5")])],
                    [
                        {op, ?ANNO, 'andalso', remote(erlang, is_integer, [v("Size")]),
                            {op, ?ANNO, '>=', v("Size"), i(0)}}
                    ],
                    [
                        'case'(call_local(json_expect, [v("Rest5"), i(44)]), [
                            ok_bind_clause(
                                v("Rest6"),
                                'case'(call_local(json_expect, [v("Rest6"), i(123)]), [
                                    ok_bind_clause(
                                        v("Rest7"),
                                        'case'(call_local(DecPairs, [v("Size"), v("Rest7"), map_empty()]), [
                                            ok3_bind_clause(
                                                v("Pairs"),
                                                v("Rest8"),
                                                'case'(
                                                    call_local(json_expect, [v("Rest8"), i(93)]),
                                                    [
                                                        ok_bind_clause(v("Rest9"), ok3(v("Pairs"), v("Rest9"))),
                                                        other_tail()
                                                    ]
                                                )
                                            ),
                                            other_tail()
                                        ])
                                    ),
                                    other_tail()
                                ])
                            ),
                            other_tail()
                        ])
                    ]
                ),
                clause([tuple_t([at(ok), tuple_pat([at(float), v("_")]), v("_")])], none, [
                    err_decode(at(bad_sequence_size))
                ]),
                other_tail()
            ])
        ),
        other_tail()
    ]).

-spec dec_pairs_clauses(atom(), atom()) -> [ast()].
dec_pairs_clauses(DecPairs, DecPair) ->
    %% DecPair is a real function (its own module-level form), so the
    %% result destructure here re-binds nothing the inlined body would
    %% have exported.
    [
        clause([i(0), v("Bin"), v("Acc")], none, [
            'case'(call_local(json_expect, [v("Bin"), i(125)]), [
                ok_bind_clause(v("Rest"), ok3(v("Acc"), v("Rest"))),
                other_tail()
            ])
        ]),
        clause([i(1), v("Bin"), v("Acc")], none, [
            'case'(call_local(json_scan_string, [v("Bin")]), [
                clause([tuple_t([at(ok), v("KeyText"), v("Rest0")])], none, [
                    'case'(call_local(DecPair, [v("KeyText"), v("Rest0")]), [
                        clause([tuple_t([at(ok), v("Key"), tuple_pat([v("Value"), v("Rest1")])])], none, [
                            'case'(call_local(json_expect, [v("Rest1"), i(125)]), [
                                ok_bind_clause(v("Rest2"), ok3(map_put(v("Acc"), v("Key"), v("Value")), v("Rest2"))),
                                other_tail()
                            ])
                        ]),
                        other_tail()
                    ])
                ]),
                other_tail()
            ])
        ]),
        clause([v("N"), v("Bin"), v("Acc")], [{op, ?ANNO, '>', v("N"), i(1)}], [
            'case'(call_local(json_scan_string, [v("Bin")]), [
                clause([tuple_t([at(ok), v("KeyText"), v("Rest0")])], none, [
                    'case'(call_local(DecPair, [v("KeyText"), v("Rest0")]), [
                        clause([tuple_t([at(ok), v("Key"), tuple_pat([v("Value"), v("Rest1")])])], none, [
                            'case'(call_local(json_expect, [v("Rest1"), i(44)]), [
                                ok_bind_clause(
                                    v("Rest2"),
                                    call_local(DecPairs, [
                                        {op, ?ANNO, '-', v("N"), i(1)},
                                        v("Rest2"),
                                        map_put(v("Acc"), v("Key"), v("Value"))
                                    ])
                                ),
                                other_tail()
                            ])
                        ]),
                        other_tail()
                    ])
                ]),
                other_tail()
            ])
        ])
    ].

%% One pair: `:`, the value decode, then the key text conversion — the
%% generic decode_pair_j order.

%% One pair as its own function: `:`, the value decode, then the key
%% text conversion — the generic decode_pair_j order, answering
%% {ok, Key, {Value, Rest}}. A function (not an inlined tree) keeps the
%% loop's destructure free of the body's exported names.

-spec dec_pair_form(wire_type(), atom(), atom(), #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
dec_pair_form(V, KeyFromText, DecPair, Ctx, Enums) ->
    [
        {function, ?ANNO, DecPair, 2, [
            clause([v("KeyText"), v("Bin")], none, [
                'case'(call_local(json_expect, [v("Bin"), i(58)]), [
                    ok_bind_clause(
                        v("Rest0"),
                        'case'(decode_json_expr(V, v("Rest0"), Ctx, Enums), [
                            ok3_bind_clause(
                                v("Value"),
                                v("Rest1"),
                                'case'(call_local(KeyFromText, [v("KeyText")]), [
                                    ok_bind_clause(v("Key"), ok3(v("Key"), tuple_t([v("Value"), v("Rest1")]))),
                                    %% The value case above exports `Other' — a
                                    %% distinct name keeps this handler fresh.
                                    other_clause("OtherPairKey")
                                ])
                            ),
                            other_tail()
                        ])
                    ),
                    %% The value case is nested in the subject chain —
                    %% its exported `Other' would make a same-name
                    %% handler here an unsafe re-bind.
                    other_clause("OtherPairDecode")
                ])
            ])
        ]}
    ].

%%--------------------------------------------------------------------
%% json_codec/1
%%--------------------------------------------------------------------

-spec json_codec_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
json_codec_forms(Mod, Ctx) ->
    Clauses =
        [
            clause([name_lit(S#tg_struct.name)], none, [
                tuple_t([
                    at(ok),
                    {tuple, ?ANNO, [
                        {'fun', ?ANNO, {function, element(1, json_pair(S, Ctx)), 1}},
                        %% The pair's decode is the non-folding body: the
                        %% envelope's closing `]` belongs to the top-level
                        %% entry points, which wrap it themselves.
                        {'fun', ?ANNO, {function, decode_body_name(element(2, json_pair(S, Ctx))), 1}}
                    ]}
                ])
            ])
         || S <- Mod#tg_module.structs
        ] ++
            [clause([v("_Name")], none, [at(error)])],
    thrift_generator_emitter_syntax:doc_form(
        undefined,
        <<
            "The specialized JSON codec pair by wire struct name:"
            " `error` for names this module does not define. The decode"
            " side is the non-folding struct body: folding the envelope's"
            " closing `]` is the caller's (the runtime's top-level entry"
            " points') job."
        >>
    ) ++
        [
            spec_form(json_codec, 1, [
                t_fun(
                    [t_atom(binary)],
                    t_union([
                        t_ok(
                            tuple_t_type([
                                t_fun([t_atom(term)], t_atom(term)),
                                t_fun([t_atom(term)], t_atom(term))
                            ])
                        ),
                        t_atom_lit(error)
                    ])
                )
            ]),
            {function, ?ANNO, json_codec, 1, Clauses}
        ].

%%--------------------------------------------------------------------
%% Shared helper emission (mirrors of the generic JSON engine)
%%--------------------------------------------------------------------

-spec helper_forms(atom()) -> erl_syntax:forms().
helper_forms(json_skip_ws) ->
    [
        {function, ?ANNO, json_skip_ws, 1, [
            clause(
                [bin_pat([{v("C"), i(8), [big, unsigned]}, {v("Rest"), default, [binary]}])],
                [
                    {op, ?ANNO, 'orelse',
                        {op, ?ANNO, 'orelse',
                            {op, ?ANNO, 'orelse', {op, ?ANNO, '=:=', v("C"), i(32)}, {op, ?ANNO, '=:=', v("C"), i(9)}},
                            {op, ?ANNO, '=:=', v("C"), i(13)}},
                        {op, ?ANNO, '=:=', v("C"), i(10)}}
                ],
                [call_local(json_skip_ws, [v("Rest")])]
            ),
            clause([v("Bin")], none, [v("Bin")])
        ]}
    ];
helper_forms(json_expect) ->
    [
        {function, ?ANNO, json_expect, 2, [
            clause([v("Bin"), v("C")], none, [
                'case'(call_local(json_skip_ws, [v("Bin")]), [
                    clause(
                        [bin_pat([{v("C"), i(8), [big, unsigned]}, {v("Rest"), default, [binary]}])],
                        none,
                        [ok_t(v("Rest"))]
                    ),
                    clause([bin_pat([])], none, [at(more)]),
                    clause([v("_")], none, [err_decode(at(bad_structure))])
                ])
            ])
        ]}
    ];
helper_forms(json_scan_string) ->
    [
        {function, ?ANNO, json_scan_string, 1, [
            clause([v("Bin")], none, [
                'case'(call_local(json_skip_ws, [v("Bin")]), [
                    clause(
                        [bin_pat([{i(34), default, default}, {v("Rest"), default, [binary]}])],
                        none,
                        [call_local(json_scan_string_body, [v("Rest"), nil()])]
                    ),
                    clause([bin_pat([])], none, [at(more)]),
                    clause([v("_")], none, [err_decode(at(bad_string))])
                ])
            ])
        ]}
    ];
helper_forms(json_scan_string_body) ->
    [
        {function, ?ANNO, json_scan_string_body, 2, [
            clause(
                [bin_pat([{i(34), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [ok3(remote(erlang, iolist_to_binary, [remote(lists, reverse, [v("Acc")])]), v("Rest"))]
            ),
            clause(
                [bin_pat([{pat_str(<<"\\\"">>), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [call_local(json_scan_string_body, [v("Rest"), cons(i(34), v("Acc"))])]
            ),
            clause(
                [bin_pat([{pat_str(<<"\\\\">>), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [call_local(json_scan_string_body, [v("Rest"), cons(i(92), v("Acc"))])]
            ),
            clause(
                [bin_pat([{pat_str(<<"\\b">>), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [call_local(json_scan_string_body, [v("Rest"), cons(i(16#08), v("Acc"))])]
            ),
            clause(
                [bin_pat([{pat_str(<<"\\f">>), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [call_local(json_scan_string_body, [v("Rest"), cons(i(16#0C), v("Acc"))])]
            ),
            clause(
                [bin_pat([{pat_str(<<"\\n">>), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [call_local(json_scan_string_body, [v("Rest"), cons(i(16#0A), v("Acc"))])]
            ),
            clause(
                [bin_pat([{pat_str(<<"\\r">>), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [call_local(json_scan_string_body, [v("Rest"), cons(i(16#0D), v("Acc"))])]
            ),
            clause(
                [bin_pat([{pat_str(<<"\\t">>), default, default}, {v("Rest"), default, [binary]}]), v("Acc")],
                none,
                [call_local(json_scan_string_body, [v("Rest"), cons(i(16#09), v("Acc"))])]
            ),
            clause(
                [
                    bin_pat([
                        {pat_str(<<"\\u">>), default, default},
                        {v("H1"), i(8), [big, unsigned]},
                        {v("H2"), i(8), [big, unsigned]},
                        {v("H3"), i(8), [big, unsigned]},
                        {v("H4"), i(8), [big, unsigned]},
                        {v("Rest"), default, [binary]}
                    ]),
                    v("Acc")
                ],
                none,
                [
                    'case'(call_local(json_hex_value, [list_lit([v("H1"), v("H2"), v("H3"), v("H4")])]), [
                        clause(
                            [tuple_t([at(ok), v("CodePoint")])],
                            [
                                {op, ?ANNO, 'andalso', {op, ?ANNO, '>=', v("CodePoint"), i(16#D800)},
                                    {op, ?ANNO, '=<', v("CodePoint"), i(16#DFFF)}}
                            ],
                            [err_decode(at(bad_string_escape))]
                        ),
                        ok_bind_clause(
                            v("CodePoint"),
                            call_local(json_scan_string_body, [
                                v("Rest"),
                                cons(bin_seg(v("CodePoint"), default, [utf8]), v("Acc"))
                            ])
                        ),
                        clause([at(error)], none, [err_decode(at(bad_string_escape))])
                    ])
                ]
            ),
            clause(
                [bin_pat([{v("C"), i(8), [big, unsigned]}, {v("Rest"), default, [binary]}]), v("Acc")],
                [{op, ?ANNO, '>=', v("C"), i(16#20)}],
                [call_local(json_scan_string_body, [v("Rest"), cons(v("C"), v("Acc"))])]
            ),
            clause(
                [bin_pat([{v("C"), i(8), [big, unsigned]}, {v("_Rest"), default, [binary]}]), v("_Acc")],
                [{op, ?ANNO, '<', v("C"), i(16#20)}],
                [err_decode(at(bad_string))]
            ),
            clause([bin_pat([]), v("_Acc")], none, [at(more)])
        ]}
    ];
helper_forms(json_hex_value) ->
    [
        {function, ?ANNO, json_hex_value, 1, [
            clause([v("Digits")], none, [
                try_catch(
                    ok_t(
                        remote(erlang, binary_to_integer, [
                            remote(erlang, iolist_to_binary, [v("Digits")]),
                            i(16)
                        ])
                    ),
                    [clause([v("_"), v("_")], none, [at(error)])]
                )
            ])
        ]}
    ];
helper_forms(json_scan_number) ->
    [
        {function, ?ANNO, json_scan_number, 1, [
            clause([v("Bin")], none, [
                'case'(call_local(json_skip_ws, [v("Bin")]), [
                    clause([bin_pat([])], none, [at(more)]),
                    clause([v("Bin1")], none, [
                        'case'(
                            {match, ?ANNO, tuple_pat([v("Token"), v("Rest")]),
                                call_local(json_take_number, [v("Bin1"), nil()])},
                            [
                                clause([v("_Match")], none, [
                                    'case'(call_local(json_classify_number, [v("Token"), v("Rest")]), [
                                        ok_bind_clause(v("Number"), ok3(v("Number"), v("Rest"))),
                                        other_tail()
                                    ])
                                ])
                            ]
                        )
                    ])
                ])
            ])
        ]}
    ];
helper_forms(json_take_number) ->
    [
        {function, ?ANNO, json_take_number, 2, [
            clause(
                [
                    bin_pat([{v("C"), i(8), [big, unsigned]}, {v("Rest"), default, [binary]}]),
                    v("Acc")
                ],
                [
                    {op, ?ANNO, 'orelse',
                        {op, ?ANNO, 'orelse',
                            {op, ?ANNO, 'orelse',
                                {op, ?ANNO, 'orelse',
                                    {op, ?ANNO, 'orelse',
                                        {op, ?ANNO, 'andalso', {op, ?ANNO, '>=', v("C"), i(48)},
                                            {op, ?ANNO, '=<', v("C"), i(57)}},
                                        {op, ?ANNO, '=:=', v("C"), i(45)}},
                                    {op, ?ANNO, '=:=', v("C"), i(43)}},
                                {op, ?ANNO, '=:=', v("C"), i(46)}},
                            {op, ?ANNO, '=:=', v("C"), i(101)}},
                        {op, ?ANNO, '=:=', v("C"), i(69)}}
                ],
                [call_local(json_take_number, [v("Rest"), cons(v("C"), v("Acc"))])]
            ),
            clause([v("Rest"), v("Acc")], none, [
                tuple_t([remote(lists, reverse, [v("Acc")]), v("Rest")])
            ])
        ]}
    ];
helper_forms(json_classify_number) ->
    [
        {function, ?ANNO, json_classify_number, 2, [
            clause([nil(), bin_pat([])], none, [at(more)]),
            clause([nil(), v("_Rest")], none, [err_decode(at(bad_number))]),
            clause([v("Token"), v("Rest")], none, [
                {match, ?ANNO, v("Text"), remote(erlang, iolist_to_binary, [v("Token")])},
                {match, ?ANNO, v("Last"), remote(lists, last, [v("Token")])},
                %% A literal cut off at the end of input mid-float may
                %% still be completed by the next bytes: more, not an
                %% error.
                'case'(call_local(json_float_marker, [v("Token")]), [
                    clause([at(true)], none, [
                        try_catch(
                            ok_t(tuple_t([at(float), remote(erlang, binary_to_float, [v("Text")])])),
                            [
                                clause([v("_"), v("_")], [truncated_guard(v("Rest"), v("Last"))], [at(more)]),
                                clause([v("_"), v("_")], none, [err_decode(at(bad_number))])
                            ]
                        )
                    ]),
                    clause([at(false)], none, [
                        try_catch(
                            ok_t(tuple_t([at(int), remote(erlang, binary_to_integer, [v("Text")])])),
                            [
                                clause([v("_"), v("_")], [truncated_guard(v("Rest"), v("Last"))], [at(more)]),
                                clause([v("_"), v("_")], none, [err_decode(at(bad_number))])
                            ]
                        )
                    ])
                ])
            ])
        ]}
    ];
helper_forms(json_float_marker) ->
    [
        {function, ?ANNO, json_float_marker, 1, [
            clause([v("Token")], none, [
                remote(lists, any, [
                    {'fun', ?ANNO,
                        {clauses, [
                            clause([v("C")], none, [
                                {op, ?ANNO, 'orelse',
                                    {op, ?ANNO, 'orelse', {op, ?ANNO, '=:=', v("C"), i(46)},
                                        {op, ?ANNO, '=:=', v("C"), i(101)}},
                                    {op, ?ANNO, '=:=', v("C"), i(69)}}
                            ])
                        ]}},
                    v("Token")
                ])
            ])
        ]}
    ];
helper_forms(json_escape) ->
    [
        {function, ?ANNO, json_escape, 1, [
            clause([v("Bin")], none, [
                {lc, ?ANNO, call_local(json_escape_byte, [v("B")]), [
                    {b_generate, ?ANNO, bin_pat([{v("B"), i(8), [big, unsigned]}]), v("Bin")}
                ]}
            ])
        ]}
    ];
helper_forms(json_escape_byte) ->
    [
        {function, ?ANNO, json_escape_byte, 1, [
            clause([i(34)], none, [bin_lit(<<"\\\"">>)]),
            clause([i(92)], none, [bin_lit(<<"\\\\">>)]),
            clause([i(8)], none, [bin_lit(<<"\\b">>)]),
            clause([i(12)], none, [bin_lit(<<"\\f">>)]),
            clause([i(10)], none, [bin_lit(<<"\\n">>)]),
            clause([i(13)], none, [bin_lit(<<"\\r">>)]),
            clause([i(9)], none, [bin_lit(<<"\\t">>)]),
            clause([v("B")], [{op, ?ANNO, '<', v("B"), i(16#20)}], [
                remote(erlang, iolist_to_binary, [
                    {call, ?ANNO, {remote, ?ANNO, {atom, ?ANNO, io_lib}, {atom, ?ANNO, format}}, [
                        bin_lit(<<"\\u~4.16.0b">>),
                        list_lit([v("B")])
                    ]}
                ])
            ]),
            clause([v("B")], none, [bin_seg(v("B"), i(8), [big, unsigned])])
        ]}
    ];
helper_forms(json_format_double) ->
    [
        {function, ?ANNO, json_format_double, 1, [
            clause([v("V")], none, [
                {call, ?ANNO, {remote, ?ANNO, {atom, ?ANNO, io_lib}, {atom, ?ANNO, format}}, [
                    bin_lit(<<"~.*f">>),
                    list_lit([i(16), remote(erlang, float, [v("V")])])
                ]}
            ])
        ]}
    ];
helper_forms(json_dup_keys) ->
    [
        {function, ?ANNO, json_dup_keys, 1, [
            clause(
                [cons(tuple_pat([v("K"), v("_")]), cons(tuple_pat([v("K"), v("_")]), v("_")))],
                none,
                [at(true)]
            ),
            clause([cons(v("_"), v("Rest"))], none, [call_local(json_dup_keys, [v("Rest")])]),
            clause([nil()], none, [at(false)])
        ]}
    ];
helper_forms(json_field_id) ->
    [
        {function, ?ANNO, json_field_id, 1, [
            clause([v("Text")], none, [
                try_catch(
                    ok_t(remote(erlang, binary_to_integer, [v("Text")])),
                    [clause([v("_"), v("_")], none, [err_decode(at(bad_field_id))])]
                )
            ])
        ]}
    ].

%%--------------------------------------------------------------------
%% Shared error shapes
%%--------------------------------------------------------------------

-spec uuid_error() -> ast().
uuid_error() ->
    err_encode(tuple_t([at(type_not_supported), tuple_t([at(base), at(uuid)]), at(json)])).

-spec uuid_decode_error() -> ast().
uuid_decode_error() ->
    err_decode(tuple_t([at(type_not_supported), tuple_t([at(base), at(uuid)]), at(json)])).

-spec uuid_error_clause(arity()) -> ast().
uuid_error_clause(Arity) ->
    clause([v("_" ++ integer_to_list(I)) || I <- lists:seq(1, Arity)], none, [uuid_error()]).

-spec uuid_decode_error_clause(arity()) -> ast().
uuid_decode_error_clause(Arity) ->
    clause([v("_" ++ integer_to_list(I)) || I <- lists:seq(1, Arity)], none, [uuid_decode_error()]).

%%--------------------------------------------------------------------
%% Type helpers
%%--------------------------------------------------------------------

-spec wtype(thrift_type(), #ectx{}) -> wire_type().
wtype(Type, Ctx) ->
    thrift_generator_emitter:type_desc(Type, Ctx).

%% The JSON type tags of the generic engine's tag/1, computed at emit
%% time — the generated code carries them as literals.

-spec json_tag(wire_type()) -> binary().
json_tag({base, bool}) ->
    <<"tf">>;
json_tag({base, double}) ->
    <<"dbl">>;
json_tag({base, B}) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    atom_to_binary(B, utf8);
json_tag({base, S}) when S =:= string; S =:= binary ->
    <<"str">>;
json_tag({base, uuid}) ->
    <<>>;
json_tag({enum, _Desc}) ->
    <<"i32">>;
json_tag({list, _T}) ->
    <<"lst">>;
json_tag({set, _T, _Impl}) ->
    <<"set">>;
json_tag({set, _T}) ->
    <<"set">>;
json_tag({map, K, _V}) ->
    %% A map whose key no JSON object key can carry compiles to
    %% {j_unsupported, _} — the generic engine tags it with the empty
    %% string (its uuid twin gets the same below).
    case map_key_supported(K) of
        supported -> <<"map">>;
        unsupported -> <<>>
    end;
json_tag({struct, _Ref}) ->
    <<"rec">>.
