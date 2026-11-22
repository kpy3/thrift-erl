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

-module(thrift_generator_codec).

-moduledoc """
Specialized binary-protocol wire codecs emitted into `<mod>_types.erl`.

For every struct, union and exception the module gets
`encode_<prefix>_wire/1` and `decode_<prefix>_wire/1`: direct
binary-pattern code over the wire representation (maps keyed by binary
field names), with the same contracts as `thrift_runtime_binary:encode/2`
and `thrift_runtime_binary:decode/2`. The module-level `binary_codec/1`
hands the function pair out by wire struct name; `thrift_runtime_binary`
probes that export whenever it meets a `{struct, {ref, Module, Name}}`
descriptor and dispatches to the specialized code, falling back to its
descriptor-driven engine for modules without the export (hand-written
descriptors, inline RPC param/result structs).

The generated code preserves the generic engine's observable
semantics: identical bytes for identical wire values and identical
error terms — `missing_required_fields` in declaration order on encode
and ascending field-id order on decode, `union_empty`/`union_multiple`,
`field_type_mismatch`, `element_type_mismatch`, `map_type_mismatch`,
`bad_map_size`, `bad_sequence_size`, `bad_string_length`, the
`more`-versus-error truncation distinction — and skips unknown field
ids by wire type. The thrift_codec_test equivalence properties pin all
of this against the generic engine.

Nesting: same-module struct references become direct calls to the
sibling wire functions; cross-module references call the target module's
exported codec directly with its own namespace prefix. Containers get
private `enc_*/dec_*` helpers named after the
rendered element type; enum members are inlined as case clauses at
every use site.

Forms are built as raw `erl_parse` trees — patterns, binary segment
options and guards have no convenient `erl_syntax` constructors — so
`erl_pp` renders them; doc and spec attributes stay syntax trees like
everywhere else in the emitter.
""".

-export([module_forms/2, repr_encode_export_entries/2]).
-export([repr_index_entries/1]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

%% The raw `erl_parse' vocabulary is shared with the compact/JSON codec
%% emitters; the binary-specific shapes (fixed-width headers, i32
%% length prefixes) stay local to this module.

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
    'case'/2,
    lc/2,
    map_exact/2,
    map_empty/0,
    map_put/3,
    bin_seg/3,
    bin_pat/1,
    bin_lit/1,
    list_lit/1,
    cons/2,
    nil/0,
    err_encode/1,
    mismatch/1,
    at/1,
    name_lit/1,
    ok_t/1,
    ok3/2,
    err_encode/1,
    err_decode/1,
    mismatch/1,
    atom_concat/2,
    encode_entry_clause/1,
    encode_error_clause/0,
    union_check/2,
    required_check/2,
    required_bits/1,
    required_bit/2,
    full_mask/1,
    missing_names/2,
    key_filter/3,
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

%% Parameter bundles for the repr emission helpers: passing the chain
%% context as one record keeps arities under the lint ceiling.
-record(rcc, {chain :: atom(), k :: non_neg_integer(), flavor :: record | map, ctx :: tuple(), enums :: map()}).
-record(rdc, {
    fields_name = undefined :: atom() | undefined,
    flavor = map :: record | map | struct | native,
    tag = undefined :: atom() | undefined,
    mod :: atom(),
    ctx :: tuple(),
    enums :: map()
}).

%% The wire descriptor vocabulary of `thrift_generator_emitter:type_desc/2`
%% — the same shape the runtime codecs consume.

-type wire_type() :: thrift_generator_codec_common:wire_type().

%% A raw `erl_parse' tree (stdlib exports no type for them); the doc and
%% spec attributes and the returned form list stay syntax trees.

-type ast() :: tuple().

%%--------------------------------------------------------------------
%% Module assembly
%%--------------------------------------------------------------------

-doc "Every wire-codec form of the module: per-struct encode/decode functions, container helpers, `binary_codec/1`.".
-spec module_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
module_forms(Mod, Ctx) ->
    %% The synthetic RPC codecs go last: the hooks in service_info reach
    %% them directly, and keeping the declared structs' code layout
    %% untouched matters more than grouping (BEAM layout sensitivity).
    ServiceStructs = thrift_generator_codec_common:service_structs(Mod),
    WireTypes = [
        wtype(F#tg_field.type, Ctx)
     || S <- Mod#tg_module.structs ++ ServiceStructs,
        F <- S#tg_struct.fields
    ],
    Enums = thrift_generator_codec_common:enum_registry(WireTypes),
    struct_blocks(Mod#tg_module.structs, <<"wire codecs">>, Ctx, Enums) ++
        helper_forms(WireTypes, Ctx, Enums) ++
        thrift_generator_codec_common:codec_index_forms(wire, Mod, Ctx) ++
        struct_blocks(ServiceStructs, <<"wire codecs">>, Ctx, Enums) ++
        repr_encode_forms(Mod#tg_module.structs, Ctx, Enums) ++
        repr_decode_forms(Mod#tg_module.structs, Ctx, Enums).

-spec struct_blocks([#tg_struct{}], binary(), #ectx{}, thrift_generator_codec_common:registry()) ->
    erl_syntax:forms().
struct_blocks(Structs, Label, Ctx, Enums) ->
    lists:append([
        [
            thrift_generator_emitter_syntax:section_form(
                io_lib:format("~s ~ts", [thrift_generator_emitter:section_label(S), Label])
            )
        ] ++
            struct_forms(S, Ctx, Enums)
     || S <- Structs
    ]).

%%--------------------------------------------------------------------
%% Names
%%--------------------------------------------------------------------

-spec enc_name(wire_type(), thrift_generator_codec_common:registry()) -> atom().
enc_name(T, Enums) ->
    binary_to_atom(<<"enc_", (thrift_generator_codec_common:type_name(T, Enums))/binary>>, utf8).

-spec dec_name(wire_type(), thrift_generator_codec_common:registry()) -> atom().
dec_name(T, Enums) ->
    binary_to_atom(<<"dec_", (thrift_generator_codec_common:type_name(T, Enums))/binary>>, utf8).

%%--------------------------------------------------------------------
%% Per-struct blocks
%%--------------------------------------------------------------------

-spec struct_forms(#tg_struct{}, #ectx{}, thrift_generator_codec_common:registry()) ->
    erl_syntax:forms().
struct_forms(S, Ctx, Enums) ->
    {Encode, Decode} = thrift_generator_codec_common:codec_pair(wire, S, Ctx),
    FieldTypes = [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields],
    encode_forms(S, Encode, FieldTypes, Ctx, Enums) ++
        decode_forms(S, Decode, FieldTypes, Ctx, Enums).

%% Encode side: entry clauses (map guard, required/union check) plus a
%% chain of per-field functions assembling iodata forward — the same
%% difference-list shape the generic engine's encode_fields_c walks.

-spec encode_forms(#tg_struct{}, atom(), [wire_type()], #ectx{}, thrift_generator_codec_common:registry()) ->
    erl_syntax:forms().
encode_forms(S, Encode, FieldTypes, Ctx, Enums) ->
    Chain = atom_concat(Encode, <<"_fields">>),
    %% The checks hand off to the FIRST chain function; with no fields
    %% the chain name itself is the terminator that closes the struct.
    Entry =
        case S#tg_struct.fields of
            [] -> Chain;
            _ -> chain_fn_name(Chain, 1)
        end,
    CheckBody =
        case S#tg_struct.kind of
            union -> union_check(S#tg_struct.fields, call_local(Entry, [v("Value")]));
            _ -> required_check(S#tg_struct.fields, call_local(Entry, [v("Value")]))
        end,
    thrift_generator_emitter_syntax:doc_false_form() ++
        [
            spec_form(Encode, 1, [t_fun([t_map_exact()], t_union([t_ok(t_atom(iodata)), t_error()]))]),
            {function, ?ANNO, Encode, 1, [encode_entry_clause(CheckBody), encode_error_clause()]}
        ] ++
        %% An empty union's check never hands off to the chain — emitting
        %% it would leave an unused function under warnings_as_errors.
        case {S#tg_struct.kind, S#tg_struct.fields} of
            {union, []} -> [];
            _ -> chain_forms(Chain, lists:zip(S#tg_struct.fields, FieldTypes), Ctx, Enums, 1)
        end.

%% One function per field, declaration order: field K encodes its value
%% (when present) and conses its header chunk in front of the encoding
%% of the remaining fields; absent fields fall through to the next
%% function and the last one closes with the stop byte.

-spec chain_forms(
    atom(), [{#tg_field{}, wire_type()}], #ectx{}, thrift_generator_codec_common:registry(), pos_integer()
) ->
    erl_syntax:forms().
chain_forms(Chain, [], _Ctx, _Enums, _N) ->
    %% Zero fields: the chain name itself is the terminator.
    [{function, ?ANNO, Chain, 1, [clause([v("_Value")], none, [ok_t(list_lit([i(0)]))])]}];
chain_forms(Chain, Fields, Ctx, Enums, 1) when Fields =/= [] ->
    chain_fns(Chain, Fields, Ctx, Enums, 1).

%% The field functions proper: the last one closes the struct with the
%% stop byte inline, so no terminator function follows the chain.

-spec chain_fns(
    atom(), [{#tg_field{}, wire_type()}], #ectx{}, thrift_generator_codec_common:registry(), pos_integer()
) ->
    erl_syntax:forms().
chain_fns(_Chain, [], _Ctx, _Enums, _N) ->
    [];
chain_fns(Chain, [{F, T}], Ctx, Enums, N) ->
    [chain_fn(Chain, N, F, T, ok_t(list_lit([i(0)])), Ctx, Enums)];
chain_fns(Chain, [{F, T} | Rest], Ctx, Enums, N) ->
    Next = call_local(chain_fn_name(Chain, N + 1), [v("Value")]),
    [chain_fn(Chain, N, F, T, Next, Ctx, Enums)] ++ chain_fns(Chain, Rest, Ctx, Enums, N + 1).

-spec chain_fn(
    atom(), pos_integer(), #tg_field{}, wire_type(), ast(), #ectx{}, thrift_generator_codec_common:registry()
) ->
    ast().
chain_fn(Chain, N, F, {base, _} = T, Next, _Ctx, _Enums) ->
    base_chain_fn(Chain, N, F, T, Next);
chain_fn(Chain, N, F, T, Next, Ctx, Enums) ->
    Header = header_bin(wire_byte(T), F#tg_field.id),
    Body =
        'case'(v("Value"), [
            clause([map_exact(name_lit(F#tg_field.name), v("V"))], none, [
                'case'(encode_wire_expr(T, v("V"), Ctx, Enums, ""), [
                    clause([tuple_t([at(ok), v("E")])], none, [
                        'case'(Next, [
                            ok_bind_clause(v("Rest"), ok_t(cons(list_lit([Header, v("E")]), v("Rest")))),
                            error_clause()
                        ])
                    ]),
                    error_clause()
                ])
            ]),
            clause([v("_")], none, [Next])
        ]),
    {function, ?ANNO, chain_fn_name(Chain, N), 1, [clause([v("Value")], none, [Body])]}.

%% Base-type fields fold the type/range check into the map-match clause
%% guard and place the payload straight into the chunk — no {ok, E}
%% wrapper and no destructure case per field. A present-but-wrong-type
%% value hits the unguarded present clause and reports the same
%% type_mismatch error the generic engine raises, before the rest of
%% the struct is encoded.

-spec base_chain_fn(atom(), pos_integer(), #tg_field{}, wire_type(), ast()) -> ast().
base_chain_fn(Chain, N, F, {base, B} = T, Next) ->
    Header = header_bin(wire_byte(T), F#tg_field.id),
    Name = name_lit(F#tg_field.name),
    Body =
        'case'(v("Value"), base_field_clauses(B, Name, Header, Next) ++ [clause([v("_")], none, [Next])]),
    {function, ?ANNO, chain_fn_name(Chain, N), 1, [clause([v("Value")], none, [Body])]}.

-spec base_field_clauses(atom(), ast(), ast(), ast()) -> [ast()].
base_field_clauses(B, Name, Header, Next) ->
    V = v("V"),
    Present =
        case B of
            bool ->
                [
                    base_present_clause(map_exact(Name, at(true)), none, Header, bin_lit(<<1>>), Next),
                    base_present_clause(map_exact(Name, at(false)), none, Header, bin_lit(<<0>>), Next)
                ];
            double ->
                [
                    base_present_clause(
                        map_exact(Name, V),
                        [remote(erlang, is_number, [V])],
                        Header,
                        bin_seg(remote(erlang, float, [V]), i(64), [big, float]),
                        Next
                    )
                ];
            S when S =:= string; S =:= binary ->
                [
                    base_present_clause(
                        map_exact(Name, V),
                        [remote(erlang, is_binary, [V])],
                        Header,
                        list_lit([i32_seg(call_local(byte_size, [V])), V]),
                        Next
                    )
                ];
            uuid ->
                [
                    base_present_clause(
                        map_exact(Name, V),
                        [
                            remote(erlang, is_binary, [V]),
                            {op, ?ANNO, '=:=', call_local(byte_size, [V]), i(16)}
                        ],
                        Header,
                        V,
                        Next
                    )
                ];
            _ ->
                Bits = bits(B),
                [
                    base_present_clause(
                        map_exact(Name, V),
                        [
                            remote(erlang, is_integer, [V]),
                            {op, ?ANNO, '>=', V, i(-(1 bsl (Bits - 1)))},
                            {op, ?ANNO, '=<', V, i((1 bsl (Bits - 1)) - 1)}
                        ],
                        Header,
                        bin_seg(V, i(Bits), [big, signed]),
                        Next
                    )
                ]
        end,
    Present ++ [clause([map_exact(Name, v("OtherV"))], none, [err_encode(mismatch(v("OtherV")))])].

-spec base_present_clause(ast(), [ast()] | none, ast(), ast(), ast()) -> ast().
base_present_clause(MapPat, Guard, Header, Payload, Next) ->
    clause([MapPat], Guard, [
        'case'(Next, [
            ok_bind_clause(v("Rest"), ok_t(cons(list_lit([Header, Payload]), v("Rest")))),
            error_clause()
        ])
    ]).

-spec chain_fn_name(atom(), pos_integer()) -> atom().
chain_fn_name(Chain, N) ->
    atom_concat(Chain, <<"_f", (integer_to_binary(N))/binary>>).

%%--------------------------------------------------------------------
%% Decode side
%%--------------------------------------------------------------------

-spec decode_forms(#tg_struct{}, atom(), [wire_type()], #ectx{}, thrift_generator_codec_common:registry()) ->
    erl_syntax:forms().
decode_forms(S, Decode, FieldTypes, Ctx, Enums) ->
    Fields = S#tg_struct.fields,
    FieldsName = atom_concat(Decode, <<"_fields">>),
    Bits = required_bits(Fields),
    thrift_generator_emitter_syntax:doc_false_form() ++
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
            {function, ?ANNO, Decode, 1, [
                clause([v("Binary")], [remote(erlang, is_binary, [v("Binary")])], [
                    call_local(FieldsName, [v("Binary"), i(0), map_empty()])
                ])
            ]},
            {function, ?ANNO, FieldsName, 3,
                decode_field_clauses(lists:zip(Fields, FieldTypes), Bits, FieldsName, Ctx, Enums)}
        ].

%% Stop byte closes the struct: the full required-presence bitmask is
%% matched as a literal, and the missing names (ascending id order,
%% matching the generic engine's required map) are rebuilt from the mask
%% only on the error branch; the header clause matches by field id with
%% the wire byte folded into the guard; the tail clause asks for more
%% bytes.

-spec decode_field_clauses(
    [{#tg_field{}, wire_type()}],
    [{integer(), pos_integer(), binary()}],
    atom(),
    #ectx{},
    thrift_generator_codec_common:registry()
) ->
    [ast()].
decode_field_clauses(FieldPairs, Bits, FieldsName, Ctx, Enums) ->
    StopClauses =
        case Bits of
            %% No required fields: the stop byte just closes the struct,
            %% without the missing-fields scan.
            [] ->
                [
                    clause(
                        [bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]), v("_Req"), v("Acc")],
                        none,
                        [ok3(v("Acc"), v("Rest"))]
                    )
                ];
            _ ->
                [
                    clause(
                        [
                            bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]),
                            i(full_mask(Bits)),
                            v("Acc")
                        ],
                        none,
                        [ok3(v("Acc"), v("Rest"))]
                    ),
                    clause(
                        [bin_pat([{i(0), default, default}, {v("_Rest"), default, [binary]}]), v("Req"), v("_Acc")],
                        none,
                        [err_decode(tuple_t([at(missing_required_fields), missing_names(Bits, v("Req"))]))]
                    )
                ]
        end,
    HeaderClause =
        clause([header_pat(), v("Req"), v("Acc")], none, [
            'case'(
                v("Id"),
                field_clauses(FieldPairs, Bits, FieldsName, Ctx, Enums) ++ [skip_clause(FieldsName)]
            )
        ]),
    MoreClause =
        clause(
            [v("Bin"), v("_Req"), v("_Acc")],
            [{op, ?ANNO, '<', call_local(byte_size, [v("Bin")]), i(3)}],
            [at(more)]
        ),
    StopClauses ++ [HeaderClause, MoreClause].

-spec field_clauses(
    [{#tg_field{}, wire_type()}],
    [{integer(), pos_integer(), binary()}],
    atom(),
    #ectx{},
    thrift_generator_codec_common:registry()
) ->
    [ast()].
field_clauses(FieldPairs, Bits, FieldsName, Ctx, Enums) ->
    lists:append([
        field_clauses_one(F, T, Bits, FieldsName, Ctx, Enums)
     || {F, T} <- FieldPairs
    ]).

%% Two clauses per known id: the right wire type decodes and recurses, a
%% wrong one is a field_type_mismatch — the generic engine's three-way
%% by_id match split by construction.

-spec field_clauses_one(
    #tg_field{},
    wire_type(),
    [{integer(), pos_integer(), binary()}],
    atom(),
    #ectx{},
    thrift_generator_codec_common:registry()
) ->
    [ast()].
field_clauses_one(F, T, Bits, FieldsName, Ctx, Enums) ->
    Id = F#tg_field.id,
    Wire = wire_byte(T),
    %% Only required fields set their presence bit — optional and default
    %% fields recurse with the mask unchanged.
    ReqExpr =
        case F#tg_field.required of
            required ->
                {op, ?ANNO, 'bor', v("Req"), i(required_bit(Id, Bits))};
            _ ->
                v("Req")
        end,
    [
        clause([i(Id)], [{op, ?ANNO, '=:=', v("Type"), i(Wire)}], [
            'case'(decode_wire_expr(T, v("Rest"), Ctx, Enums, ""), [
                ok3_bind_clause(
                    v("V"),
                    v("Rest1"),
                    call_local(FieldsName, [
                        v("Rest1"),
                        ReqExpr,
                        map_put(v("Acc"), name_lit(F#tg_field.name), v("V"))
                    ])
                ),
                clause([at(more)], none, [at(more)]),
                error_clause()
            ])
        ]),
        clause([i(Id)], none, [
            err_decode(tuple_t([at(field_type_mismatch), v("Id")]))
        ])
    ].

-spec skip_clause(atom()) -> ast().
skip_clause(FieldsName) ->
    clause([v("_")], none, [
        'case'(remote(thrift_runtime_binary, skip_by_wire, [v("Type"), v("Rest")]), [
            clause([tuple_t([at(ok), v("Rest1")])], none, [
                call_local(FieldsName, [v("Rest1"), v("Req"), v("Acc")])
            ]),
            clause([at(more)], none, [at(more)]),
            error_clause()
        ])
    ]).

%%--------------------------------------------------------------------
%% Wire-type encode/decode expressions
%%--------------------------------------------------------------------

%% Encode expressions: {ok, iodata()} | {error, _}, byte-identical to
%% the generic engine's encode_c/2 clauses. Decode expressions:
%% {ok, Value, Rest} | more | {error, _}, byte-identical to decode_c/2.
%% Both work on wire descriptors — container elements and non-base
%% struct fields share them (base-type struct fields are folded into
%% guarded map-match clauses by base_chain_fn/5 instead).

%% Suffixing the inline case variables (Dbl, Int, Vd, Rd) keeps sibling
%% inline cases — the map pair's key and value decodes — from rebinding
%% the same names, which erl_lint reports as unsafe variables.

-spec encode_wire_expr(wire_type(), ast(), #ectx{} | undefined, thrift_generator_codec_common:registry(), string()) ->
    ast().
encode_wire_expr({base, bool}, V, _Ctx, _Enums, _Suffix) ->
    'case'(V, [
        clause([at(true)], none, [ok_t(bin_lit(<<1>>))]),
        clause([at(false)], none, [ok_t(bin_lit(<<0>>))]),
        mismatch_tail(V)
    ]);
encode_wire_expr({base, S}, V, _Ctx, _Enums, _Suffix) when S =:= string; S =:= binary ->
    'case'(V, [
        clause([v("_")], [remote(erlang, is_binary, [V])], [
            ok_t(list_lit([i32_seg(call_local(byte_size, [V])), V]))
        ]),
        mismatch_tail(V)
    ]);
encode_wire_expr({base, double}, V, _Ctx, _Enums, Suffix) ->
    Dbl = v("Dbl" ++ Suffix),
    'case'(V, [
        clause([Dbl], [remote(erlang, is_number, [Dbl])], [
            ok_t(bin_seg(remote(erlang, float, [Dbl]), i(64), [big, float]))
        ]),
        mismatch_tail(V)
    ]);
encode_wire_expr({base, uuid}, V, _Ctx, _Enums, _Suffix) ->
    'case'(V, [
        clause(
            [v("_")],
            [remote(erlang, is_binary, [V]), {op, ?ANNO, '=:=', call_local(byte_size, [V]), i(16)}],
            [ok_t(V)]
        ),
        mismatch_tail(V)
    ]);
encode_wire_expr({base, B}, V, _Ctx, _Enums, _Suffix) ->
    Bits = bits(B),
    'case'(V, [
        clause(
            [v("_")],
            [
                remote(erlang, is_integer, [V]),
                {op, ?ANNO, '>=', V, i(-(1 bsl (Bits - 1)))},
                {op, ?ANNO, '=<', V, i((1 bsl (Bits - 1)) - 1)}
            ],
            [ok_t(bin_seg(V, i(Bits), [big, signed]))]
        ),
        clause([v("_")], none, [err_encode(mismatch(V))])
    ]);
encode_wire_expr({enum, Desc}, V, _Ctx, _Enums, Suffix) ->
    Int = v("Int" ++ Suffix),
    'case'(
        V,
        [
            clause([at(Atom)], none, [ok_t(bin_seg(i(Value), i(32), [big, signed]))])
         || {Value, Atom} <- Desc
        ] ++
            [
                clause([Int], [remote(erlang, is_integer, [Int])], [
                    ok_t(bin_seg(Int, i(32), [big, signed]))
                ]),
                clause([v("_")], [remote(erlang, is_atom, [V])], [
                    err_encode(tuple_t([at(unknown_enum_value), V]))
                ])
            ]
    );
encode_wire_expr({struct, {ref, TypesMod, Local}}, V, Ctx, _Enums, _Suffix) ->
    struct_encode_call(TypesMod, Local, V, Ctx);
encode_wire_expr({list, _} = T, V, _Ctx, Enums, _Suffix) ->
    call_local(enc_name(T, Enums), [V]);
encode_wire_expr({set, _, _} = T, V, _Ctx, Enums, _Suffix) ->
    call_local(enc_name(T, Enums), [V]);
encode_wire_expr({map, _, _} = T, V, _Ctx, Enums, _Suffix) ->
    call_local(enc_name(T, Enums), [V]).

-spec encode_base_expr(atom(), ast(), string()) -> ast().
encode_base_expr(B, V, Suffix) ->
    encode_wire_expr({base, B}, V, undefined, #{}, Suffix).

-spec struct_encode_call(module(), binary(), ast(), #ectx{}) -> ast().
struct_encode_call(TypesMod, Local, V, Ctx) ->
    case TypesMod =:= types_module_atom(Ctx#ectx.current) of
        true ->
            {Encode, _Decode} = thrift_generator_codec_common:codec_pair(wire, Local, Ctx),
            call_local(Encode, [V]);
        false ->
            {Encode, _Decode} = thrift_generator_codec_common:ref_codec_pair(wire, TypesMod, Local, Ctx),
            remote(TypesMod, Encode, [V])
    end.

-spec struct_decode_call(module(), binary(), ast(), #ectx{}) -> ast().
struct_decode_call(TypesMod, Local, Bin, Ctx) ->
    case TypesMod =:= types_module_atom(Ctx#ectx.current) of
        true ->
            {_Encode, Decode} = thrift_generator_codec_common:codec_pair(wire, Local, Ctx),
            call_local(Decode, [Bin]);
        false ->
            {_Encode, Decode} = thrift_generator_codec_common:ref_codec_pair(wire, TypesMod, Local, Ctx),
            remote(TypesMod, Decode, [Bin])
    end.

%% Same-module refs become direct sibling calls; the check rebuilds the
%% module atom from `#ectx.current', which keeps the binary key (`wtype'
%% derives the ref's module the same way). A case body, not a guard —
%% binary_to_atom is not guard-legal.
-spec types_module_atom(binary()) -> module().
types_module_atom(Name) ->
    binary_to_atom(<<(thrift_generator_emitter:sanitize(Name))/binary, "_types">>, utf8).

-spec decode_wire_expr(wire_type(), ast(), #ectx{} | undefined, thrift_generator_codec_common:registry(), string()) ->
    ast().
decode_wire_expr({base, bool}, Bin, _Ctx, _Enums, Suffix) ->
    R = v("R" ++ Suffix),
    'case'(Bin, [
        clause([bin_pat([{i(1), default, default}, {R, default, [binary]}])], none, [ok3(at(true), R)]),
        clause([bin_pat([{i(0), default, default}, {R, default, [binary]}])], none, [ok3(at(false), R)]),
        clause([bin_pat([{v("_"), default, default}, {v("_"), default, [binary]}])], none, [
            err_decode(tuple_t([at(bad_value_for_base_type), at(bool)]))
        ]),
        more_tail()
    ]);
decode_wire_expr({base, S}, Bin, _Ctx, _Enums, _Suffix) when S =:= string; S =:= binary ->
    call_local(dec_string, [Bin]);
decode_wire_expr({base, double}, Bin, _Ctx, _Enums, Suffix) ->
    int_decode_case(Bin, 64, [big, float], Suffix);
decode_wire_expr({base, uuid}, Bin, _Ctx, _Enums, Suffix) ->
    int_decode_case(Bin, 16, [binary], Suffix);
decode_wire_expr({base, B}, Bin, _Ctx, _Enums, Suffix) ->
    int_decode_case(Bin, bits(B), [big, signed], Suffix);
decode_wire_expr({enum, Desc}, Bin, _Ctx, _Enums, Suffix) ->
    Int = v("Int" ++ Suffix),
    R = v("R" ++ Suffix),
    'case'(Bin, [
        clause([bin_pat([{Int, i(32), [big, signed]}, {R, default, [binary]}])], none, [
            'case'(Int, enum_from_clauses(Desc, Int, R))
        ]),
        more_tail()
    ]);
decode_wire_expr({struct, {ref, TypesMod, Local}}, Bin, Ctx, _Enums, _Suffix) ->
    struct_decode_call(TypesMod, Local, Bin, Ctx);
decode_wire_expr({list, _} = T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]);
decode_wire_expr({set, _, _} = T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]);
decode_wire_expr({map, _, _} = T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]).

%% The fixed-size base decoder: a binary segment match or `more' —
%% never an error, exactly like the generic engine's decode_c/2 clauses.

-spec int_decode_case(ast(), non_neg_integer(), [atom()], string()) -> ast().
int_decode_case(Bin, Bits, Types, Suffix) ->
    Vd = v("Vd" ++ Suffix),
    Rd = v("Rd" ++ Suffix),
    'case'(Bin, [
        clause([bin_pat([{Vd, i(Bits), Types}, {Rd, default, [binary]}])], none, [ok3(Vd, Rd)]),
        more_tail()
    ]).

-spec decode_base_expr(atom(), ast(), string()) -> ast().
decode_base_expr(B, Bin, Suffix) ->
    decode_wire_expr({base, B}, Bin, undefined, #{}, Suffix).

-spec enum_from_clauses([{integer(), atom()}], ast(), ast()) -> [ast()].
enum_from_clauses(Desc, Int, R) ->
    [
        clause([i(Value)], none, [ok3(at(Atom), R)])
     || {Value, Atom} <- Desc
    ] ++ [clause([v("_")], none, [ok3(Int, R)])].

%%--------------------------------------------------------------------
%% Container helpers
%%--------------------------------------------------------------------

-spec helper_forms([wire_type()], #ectx{}, thrift_generator_codec_common:registry()) -> erl_syntax:forms().
helper_forms(WireTypes, Ctx, Enums) ->
    Containers = lists:usort(lists:append([thrift_generator_codec_common:containers(T) || T <- WireTypes])),
    %% dec_string exists only when some field type (at any depth)
    %% actually decodes a string, so string-free modules stay
    %% warning-free.
    DecString = [dec_string_form() || has_string(WireTypes)],
    DecString ++ lists:append([container_forms(C, Ctx, Enums) || C <- Containers]).

-spec has_string([wire_type()]) -> boolean().
has_string(Types) ->
    lists:any(
        fun
            ({base, B}) -> B =:= string orelse B =:= binary;
            (T) -> has_string(children(T))
        end,
        Types
    ).

-spec children(wire_type()) -> [wire_type()].
children({list, T}) -> [T];
children({set, T, _Impl}) -> [T];
children({map, K, V}) -> [K, V];
children(_) -> [].

-spec container_forms(wire_type(), #ectx{}, thrift_generator_codec_common:registry()) -> erl_syntax:forms().
container_forms({Kind, _} = T, Ctx, Enums) when Kind =:= list; Kind =:= set ->
    %% The container header carries the ELEMENT's wire byte; the
    %% container's own byte only appears in the field header.
    Wire = wire_byte(thrift_generator_codec_common:elem_type(T)),
    Enc = enc_name(T, Enums),
    Dec = dec_name(T, Enums),
    Elem = thrift_generator_codec_common:elem_type(T),
    EncElems = atom_concat(Enc, <<"_elems">>),
    DecElems = atom_concat(Dec, <<"_elems">>),
    [
        {function, ?ANNO, Enc, 1, [
            clause([v("Values")], [remote(erlang, is_list, [v("Values")])], [
                'case'(call_local(EncElems, [v("Values")]), [
                    clause([tuple_t([at(ok), v("Es")])], none, [
                        ok_t(
                            list_lit([
                                list_lit([
                                    bin_seg(i(Wire), i(8), [big, unsigned]), i32_seg(call_local(length, [v("Values")]))
                                ]),
                                v("Es")
                            ])
                        )
                    ]),
                    error_clause()
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, EncElems, 1, [
            clause([nil()], none, [ok_t(nil())]),
            clause([cons(v("V"), v("Rest"))], none, [
                'case'(encode_elem_expr(Elem, v("V"), Ctx, Enums, ""), [
                    clause([tuple_t([at(ok), v("E")])], none, [
                        'case'(call_local(EncElems, [v("Rest")]), [
                            ok_bind_clause(v("RestIo"), ok_t(cons(v("E"), v("RestIo")))),
                            error_clause()
                        ])
                    ]),
                    error_clause()
                ])
            ])
        ]},
        {function, ?ANNO, Dec, 1, [
            clause(
                [bin_pat([{v("_"), default, default}, {v("Size"), i(32), [big, signed]}, {v("_"), default, [binary]}])],
                [{op, ?ANNO, '<', v("Size"), i(0)}],
                [err_decode(at(bad_sequence_size))]
            ),
            clause(
                [
                    bin_pat([
                        {i(Wire), i(8), [big, unsigned]},
                        {v("Size"), i(32), [big, signed]},
                        {v("Rest"), default, [binary]}
                    ])
                ],
                none,
                [call_local(DecElems, [v("Size"), v("Rest"), nil()])]
            ),
            clause(
                [
                    bin_pat([
                        {v("T"), i(8), [big, unsigned]},
                        {v("_"), i(32), [big, signed]},
                        {v("_"), default, [binary]}
                    ])
                ],
                none,
                [err_decode(tuple_t([at(element_type_mismatch), v("T")]))]
            ),
            clause([v("_")], none, [at(more)])
        ]},
        {function, ?ANNO, DecElems, 3, [
            clause([i(0), v("Rest"), v("Acc")], none, [ok3(remote(lists, reverse, [v("Acc")]), v("Rest"))]),
            clause([v("N"), v("Bin"), v("Acc")], none, [
                'case'(decode_elem_expr(Elem, v("Bin"), Ctx, Enums, ""), [
                    clause([tuple_t([at(ok), v("V"), v("Rest")])], none, [
                        call_local(DecElems, [{op, ?ANNO, '-', v("N"), i(1)}, v("Rest"), cons(v("V"), v("Acc"))])
                    ]),
                    other_tail()
                ])
            ])
        ]}
    ];
container_forms({map, K, V} = T, Ctx, Enums) ->
    KeyWire = wire_byte(K),
    ValWire = wire_byte(V),
    Enc = enc_name(T, Enums),
    Dec = dec_name(T, Enums),
    EncPairs = atom_concat(Enc, <<"_pairs">>),
    DecPairs = atom_concat(Dec, <<"_pairs">>),
    SortFun =
        {'fun', ?ANNO,
            {clauses, [
                clause([tuple_pat([v("KE"), v("_")]), tuple_pat([v("KE1"), v("_")])], none, [
                    {op, ?ANNO, '=<', v("KE"), v("KE1")}
                ])
            ]}},
    [
        {function, ?ANNO, Enc, 1, [
            clause([v("Value")], [remote(erlang, is_map, [v("Value")])], [
                'case'(call_local(EncPairs, [remote(maps, to_list, [v("Value")]), nil()]), [
                    clause([tuple_t([at(ok), v("Pairs")])], none, [
                        {match, ?ANNO, v("Sorted"), remote(lists, sort, [SortFun, v("Pairs")])},
                        %% The header shape mirrors the generic engine's
                        %% encode_map_c exactly — both type bytes in one
                        %% segment then the size — so map keys nested in
                        %% map keys sort in the same term order on both
                        %% sides.
                        ok_t(
                            list_lit([
                                list_lit([
                                    {bin, ?ANNO, [
                                        {bin_element, ?ANNO, i(KeyWire), i(8), [big, unsigned]},
                                        {bin_element, ?ANNO, i(ValWire), i(8), [big, unsigned]}
                                    ]},
                                    i32_seg(call_local(length, [v("Sorted")]))
                                ]),
                                pairs_lc()
                            ])
                        )
                    ]),
                    error_clause()
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, EncPairs, 2, [
            clause([nil(), v("Acc")], none, [ok_t(remote(lists, reverse, [v("Acc")]))]),
            clause([cons(tuple_pat([v("K"), v("V")]), v("Rest")), v("Acc")], none, [
                'case'(encode_elem_expr(K, v("K"), Ctx, Enums, "K"), [
                    clause([tuple_t([at(ok), v("KE")])], none, [
                        'case'(encode_elem_expr(V, v("V"), Ctx, Enums, "V"), [
                            clause([tuple_t([at(ok), v("VE")])], none, [
                                call_local(EncPairs, [v("Rest"), cons(tuple_t([v("KE"), v("VE")]), v("Acc"))])
                            ]),
                            error_clause()
                        ])
                    ]),
                    error_clause()
                ])
            ])
        ]},
        {function, ?ANNO, Dec, 1, [
            clause(
                [
                    bin_pat([
                        {v("_"), default, default},
                        {v("_"), default, default},
                        {v("Size"), i(32), [big, signed]},
                        {v("_"), default, [binary]}
                    ])
                ],
                [{op, ?ANNO, '<', v("Size"), i(0)}],
                [err_decode(at(bad_map_size))]
            ),
            clause(
                [
                    bin_pat([
                        {i(KeyWire), i(8), [big, unsigned]},
                        {i(ValWire), i(8), [big, unsigned]},
                        {v("Size"), i(32), [big, signed]},
                        {v("Rest"), default, [binary]}
                    ])
                ],
                none,
                [call_local(DecPairs, [v("Size"), v("Rest"), map_empty()])]
            ),
            clause(
                [
                    bin_pat([
                        {v("_"), default, default},
                        {v("_"), default, default},
                        {v("_"), i(32), [big, signed]},
                        {v("_"), default, [binary]}
                    ])
                ],
                none,
                [err_decode(at(map_type_mismatch))]
            ),
            clause([v("_")], none, [at(more)])
        ]},
        {function, ?ANNO, DecPairs, 3, [
            clause([i(0), v("Rest"), v("Acc")], none, [ok3(v("Acc"), v("Rest"))]),
            clause([v("N"), v("Bin"), v("Acc")], none, [
                'case'(decode_elem_expr(K, v("Bin"), Ctx, Enums, "K"), [
                    clause([tuple_t([at(ok), v("K"), v("Rest")])], none, [
                        'case'(decode_elem_expr(V, v("Rest"), Ctx, Enums, "V"), [
                            clause([tuple_t([at(ok), v("V"), v("Rest1")])], none, [
                                call_local(DecPairs, [
                                    {op, ?ANNO, '-', v("N"), i(1)},
                                    v("Rest1"),
                                    map_put(v("Acc"), v("K"), v("V"))
                                ])
                            ]),
                            other_tail()
                        ])
                    ]),
                    other_tail()
                ])
            ])
        ]}
    ].

%% The encoded pairs of a map, in wire order (the generic engine sorts
%% the ENCODED pairs by iodata term order, so the generated code does
%% the same).

-spec pairs_lc() -> ast().
pairs_lc() ->
    {lc, ?ANNO, list_lit([v("KE"), v("VE")]), [
        {generate, ?ANNO, tuple_pat([v("KE"), v("VE")]), v("Sorted")}
    ]}.

%% Container element expressions: base and enum types inline at the use
%% site, struct references as struct calls, nested containers as helper
%% calls — the same dispatch the struct fields go through.

-spec encode_elem_expr(wire_type(), ast(), #ectx{}, thrift_generator_codec_common:registry(), string()) -> ast().
encode_elem_expr({base, B}, V, _Ctx, _Enums, Suffix) ->
    encode_base_expr(B, V, Suffix);
encode_elem_expr({enum, _} = T, V, _Ctx, _Enums, Suffix) ->
    encode_wire_expr(T, V, undefined, #{}, Suffix);
encode_elem_expr({struct, {ref, TypesMod, Local}}, V, Ctx, _Enums, _Suffix) ->
    struct_encode_call(TypesMod, Local, V, Ctx);
encode_elem_expr(T, V, _Ctx, Enums, _Suffix) ->
    call_local(enc_name(T, Enums), [V]).

-spec decode_elem_expr(wire_type(), ast(), #ectx{}, thrift_generator_codec_common:registry(), string()) -> ast().
decode_elem_expr({base, B}, Bin, _Ctx, _Enums, Suffix) ->
    decode_base_expr(B, Bin, Suffix);
decode_elem_expr({enum, _} = T, Bin, _Ctx, _Enums, Suffix) ->
    decode_wire_expr(T, Bin, undefined, #{}, Suffix);
decode_elem_expr({struct, {ref, TypesMod, Local}}, Bin, Ctx, _Enums, _Suffix) ->
    struct_decode_call(TypesMod, Local, Bin, Ctx);
decode_elem_expr(T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]).

%% The shared string/binary decoder — the generic engine's decode_string
%% clauses rendered verbatim.

-spec dec_string_form() -> ast().
dec_string_form() ->
    {function, ?ANNO, dec_string, 1, [
        clause(
            [{match, ?ANNO, len_pat(), v("Bin")}],
            [
                {op, ?ANNO, '>=', v("Len"), i(0)},
                {op, ?ANNO, '>=', call_local(byte_size, [v("Bin")]), {op, ?ANNO, '+', i(4), v("Len")}}
            ],
            [
                {match, ?ANNO,
                    bin_pat([
                        {v("_"), i(4), [binary]},
                        {v("V"), v("Len"), [binary]},
                        {v("Rest"), default, [binary]}
                    ]), v("Bin")},
                ok3(v("V"), v("Rest"))
            ]
        ),
        clause(
            [len_pat()],
            [{op, ?ANNO, '>=', v("Len"), i(0)}],
            [at(more)]
        ),
        clause([v("Bin")], [{op, ?ANNO, '<', call_local(byte_size, [v("Bin")]), i(4)}], [at(more)]),
        clause([v("_")], none, [err_decode(at(bad_string_length))])
    ]}.

%%--------------------------------------------------------------------
%% Wire vocabulary
%%--------------------------------------------------------------------

-spec wtype(thrift_type(), #ectx{}) -> wire_type().
wtype(Type, Ctx) ->
    thrift_generator_emitter:type_desc(Type, Ctx).

-spec wire_byte(wire_type()) -> non_neg_integer().
wire_byte({base, bool}) -> 2;
wire_byte({base, i8}) -> 3;
wire_byte({base, double}) -> 4;
wire_byte({base, i16}) -> 6;
wire_byte({base, i32}) -> 8;
wire_byte({base, i64}) -> 10;
wire_byte({base, B}) when B =:= string; B =:= binary -> 11;
wire_byte({base, uuid}) -> 16;
wire_byte({enum, _}) -> 8;
wire_byte({list, _}) -> 15;
wire_byte({set, _, _}) -> 14;
wire_byte({set, _}) -> 14;
wire_byte({map, _, _}) -> 13;
wire_byte({struct, _}) -> 12.

-spec bits(i8 | i16 | i32 | i64) -> 8 | 16 | 32 | 64.
bits(i8) -> 8;
bits(i16) -> 16;
bits(i32) -> 32;
bits(i64) -> 64.

%%--------------------------------------------------------------------
%% Binary-specific AST shapes
%%--------------------------------------------------------------------

-spec len_pat() -> ast().
len_pat() ->
    bin_pat([{v("Len"), i(32), [big, signed]}, {v("_"), default, [binary]}]).

%%--------------------------------------------------------------------
%% Repr-native decoders
%%--------------------------------------------------------------------

repr_decode_name(Decode, Flavor) ->
    B = atom_to_binary(Decode, utf8),
    binary_to_atom(<<B/binary, "_", (atom_to_binary(Flavor, utf8))/binary>>, utf8).

%% Decode chains mirror the wire loop: header dispatch by field id with
%% the wire byte in the guard, skip-by-wire for unknown ids, `more` on
%% truncation, the same required bitmask — only the accumulator and
%% the STOP result differ per representation. Unions decode exactly
%% like structs: the two-pass path never validates the field count on
%% decode (the generic engine's wire map is last-write-wins and the
%% conversion builds the value as-is), so the one-pass STOP must not
%% either; the exactly-one rule is enforced on encode only.

-spec repr_decode_forms([#tg_struct{}], #ectx{}, thrift_generator_codec_common:registry()) -> erl_syntax:forms().
repr_decode_forms(Structs, Ctx, Enums) ->
    Convertible = repr_convertible_structs(Structs),
    lists:append([repr_decode_struct_forms(S, Ctx, Enums) || S <- Convertible]) ++
        repr_decode_module_containers(Convertible, Ctx, Enums) ++
        case Convertible of
            [] -> [];
            _ -> repr_index_forms(Convertible, Ctx)
        end.

%% The repr codec index: per struct and representation, the
%% {Encode, Decode} pair of the one-pass functions. Sum unions, empty
%% unions and native-mode structs answer `error` (their values take
%% the descriptor path). `native` pairs the map-family encoder with
%% the native decoder (native input values convert via
%% thrift_runtime_native:fields/1 at the facade).

repr_index_forms(Convertible, Ctx) ->
    Clauses =
        lists:append([repr_index_clauses(S, Ctx) || S <- Convertible]) ++
            [clause([v("_"), v("_")], none, [at(error)])],
    thrift_generator_emitter_syntax:doc_false_form() ++
        [
            {attribute, ?ANNO, spec,
                {{binary_repr_codec, 2}, [
                    {type, ?ANNO, 'fun', [
                        {type, ?ANNO, product, [
                            {type, ?ANNO, binary, [{integer, ?ANNO, 0}, {integer, ?ANNO, 8}]},
                            {type, ?ANNO, union, [
                                {atom, ?ANNO, record},
                                {atom, ?ANNO, map},
                                {atom, ?ANNO, struct},
                                {atom, ?ANNO, native}
                            ]}
                        ]},
                        {type, ?ANNO, union, [
                            {type, ?ANNO, tuple, [
                                {atom, ?ANNO, ok},
                                {type, ?ANNO, tuple, [{type, ?ANNO, atom, []}, {type, ?ANNO, atom, []}]}
                            ]},
                            {atom, ?ANNO, error}
                        ]}
                    ]}
                ]}},
            {function, ?ANNO, binary_repr_codec, 2, Clauses}
        ].

repr_index_clauses(S, Ctx) ->
    {Encode, Decode} = thrift_generator_codec_common:codec_pair(wire, S, Ctx),
    MapPair = tuple_t([
        at(ok),
        tuple_t([at(repr_encode_name(Encode, map)), at(repr_decode_name(Decode, map))])
    ]),
    StructPair = tuple_t([
        at(ok),
        tuple_t([at(repr_encode_name(Encode, map)), at(repr_decode_name(Decode, struct))])
    ]),
    case thrift_generator_emitter:has_record(S) of
        true ->
            [
                clause([bin_lit(S#tg_struct.name), at(record)], none, [
                    tuple_t([
                        at(ok), tuple_t([at(repr_encode_name(Encode, record)), at(repr_decode_name(Decode, record))])
                    ])
                ]),
                clause([bin_lit(S#tg_struct.name), at(native)], none, [
                    tuple_t([
                        at(ok),
                        tuple_t([at(repr_encode_name(Encode, map)), at(repr_decode_name(Decode, native))])
                    ])
                ])
            ];
        false ->
            []
    end ++
        [
            clause([bin_lit(S#tg_struct.name), at(map)], none, [MapPair]),
            clause([bin_lit(S#tg_struct.name), at(struct)], none, [StructPair])
        ].

repr_decode_struct_forms(S, Ctx, Enums) ->
    {_Encode, Decode} = thrift_generator_codec_common:codec_pair(wire, S, Ctx),
    FieldTypes = [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields],
    Fields = S#tg_struct.fields,
    Bits = required_bits(Fields),
    Tag = thrift_generator_emitter:record_tag_of(S, thrift_generator_codec_common:current_prefix(Ctx)),
    StructTag =
        case thrift_generator_emitter:has_record(S) of
            true -> Tag;
            %% Map-mode structs tag their struct maps by the wire name
            %% (the same rule the descriptor engine's
            %% wire_to_struct_map(record_tag(Name)) follows).
            false -> binary_to_atom(thrift_generator_names:snake(S#tg_struct.name), utf8)
        end,
    ModAtom = types_module_atom(Ctx#ectx.current),
    K = length(FieldTypes),
    Base = #rdc{mod = ModAtom, ctx = Ctx, enums = Enums},
    MapForms = repr_decode_one(repr_decode_name(Decode, map), Fields, FieldTypes, Bits, K, Base#rdc{
        fields_name = atom_concat(repr_decode_name(Decode, map), <<"_fields">>),
        flavor = map,
        tag = undefined
    }),
    StructForms = repr_decode_one(repr_decode_name(Decode, struct), Fields, FieldTypes, Bits, K, Base#rdc{
        fields_name = atom_concat(repr_decode_name(Decode, struct), <<"_fields">>),
        flavor = struct,
        tag = StructTag
    }),
    case thrift_generator_emitter:has_record(S) of
        true ->
            RecName = repr_decode_name(Decode, record),
            NativeName = repr_decode_name(Decode, native),
            repr_decode_one(RecName, Fields, FieldTypes, Bits, K, Base#rdc{
                fields_name = atom_concat(RecName, <<"_fields">>), flavor = record, tag = Tag
            }) ++
                repr_decode_one(NativeName, Fields, FieldTypes, Bits, K, Base#rdc{
                    fields_name = atom_concat(NativeName, <<"_fields">>), flavor = native, tag = Tag
                }) ++
                MapForms ++ StructForms;
        false ->
            MapForms ++ StructForms
    end.

repr_decode_one(Name, Fields, FieldTypes, Bits, K, R) ->
    #rdc{fields_name = FieldsName} = R,
    [
        {function, ?ANNO, Name, 1, [
            clause([v("Binary")], [remote(erlang, is_binary, [v("Binary")])], [
                call_local(FieldsName, [v("Binary"), i(0), repr_acc_init(R#rdc.flavor, R#rdc.tag, K)])
            ])
        ]},
        {function, ?ANNO, FieldsName, 3, repr_decode_clauses(Fields, FieldTypes, Bits, R)}
    ].

repr_acc_init(record, Tag, K) ->
    tuple_t([at(Tag) | [at(undefined) || _ <- lists:seq(1, K)]]);
repr_acc_init(_Flavor, _Tag, _K) ->
    map_empty().

repr_decode_clauses(Fields, FieldTypes, Bits, R) ->
    #rdc{fields_name = FieldsName, flavor = Flavor, tag = Tag, mod = ModAtom} = R,
    StopAccPat =
        case Fields =:= [] andalso Flavor =:= native of
            true -> v("_Acc");
            false -> v("Acc")
        end,
    StopClauses =
        case Bits of
            [] ->
                [
                    clause(
                        [
                            bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]),
                            v("_Req"),
                            StopAccPat
                        ],
                        none,
                        [ok3(repr_stop_expr(Flavor, Tag, Fields, ModAtom, v("Acc")), v("Rest"))]
                    )
                ];
            _ ->
                [
                    clause(
                        [
                            bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]),
                            i(full_mask(Bits)),
                            v("Acc")
                        ],
                        none,
                        [ok3(repr_stop_expr(Flavor, Tag, Fields, ModAtom, v("Acc")), v("Rest"))]
                    ),
                    clause(
                        [
                            bin_pat([{i(0), default, default}, {v("_Rest"), default, [binary]}]),
                            v("Req"),
                            v("_Acc")
                        ],
                        none,
                        [err_decode(tuple_t([at(missing_required_fields), missing_names(Bits, v("Req"))]))]
                    )
                ]
        end,
    HeaderClause =
        clause([header_pat(), v("Req"), v("Acc")], none, [
            'case'(
                v("Id"),
                repr_field_clauses(Fields, FieldTypes, Bits, R) ++
                    [skip_clause(FieldsName)]
            )
        ]),
    MoreClause =
        clause(
            [v("Bin"), v("_Req"), v("_Acc")],
            [{op, ?ANNO, '<', call_local(byte_size, [v("Bin")]), i(3)}],
            [at(more)]
        ),
    StopClauses ++ [HeaderClause, MoreClause].

%% setelement accumulation: the STOP result is the accumulator itself
%% for record (the tuple is updated in place), a tag put for struct,
%% the map as-is for map.

repr_stop_expr(native, Tag, Fields, ModAtom, Acc) ->
    %% Every declared field, in declaration order, missing as
    %% undefined — the create/3 contract of thrift_runtime_native.
    remote(thrift_runtime_native, create, [
        at(ModAtom),
        at(Tag),
        list_lit([
            tuple_t([
                at(field_atom(F#tg_field.name)),
                remote(maps, get, [i(N), Acc, at(undefined)])
            ])
         || {F, N} <- lists:zip(Fields, lists:seq(1, length(Fields)))
        ])
    ]);
repr_stop_expr(Flavor, Tag, _Fields, _ModAtom, Acc) ->
    repr_stop_result(Flavor, Tag, Acc).

repr_stop_result(record, _Tag, Acc) ->
    Acc;
repr_stop_result(struct, Tag, Acc) ->
    map_put(Acc, at('__struct__'), at(Tag));
repr_stop_result(map, _Tag, Acc) ->
    Acc.

repr_field_clauses(Fields, FieldTypes, Bits, R) ->
    lists:append([
        repr_field_clause_one(F, T, N, Bits, R)
     || {{F, T}, N} <- lists:zip(lists:zip(Fields, FieldTypes), lists:seq(1, length(Fields)))
    ]).

repr_field_clause_one(F, T, N, Bits, R) ->
    #rdc{fields_name = FieldsName, flavor = Flavor, ctx = Ctx, enums = Enums} = R,
    Id = F#tg_field.id,
    Wire = wire_byte(T),
    ReqExpr =
        case F#tg_field.required of
            required -> {op, ?ANNO, 'bor', v("Req"), i(required_bit(Id, Bits))};
            _ -> v("Req")
        end,
    [
        clause([i(Id)], [{op, ?ANNO, '=:=', v("Type"), i(Wire)}], [
            'case'(repr_field_decode(T, v("Rest"), Flavor, Ctx, Enums, ""), [
                ok3_bind_clause(
                    v("V"),
                    v("Rest1"),
                    call_local(FieldsName, [
                        v("Rest1"),
                        ReqExpr,
                        repr_acc_put(Flavor, F, N, v("V"))
                    ])
                ),
                clause([at(more)], none, [at(more)]),
                error_clause()
            ])
        ]),
        clause([i(Id)], none, [
            err_decode(tuple_t([at(field_type_mismatch), v("Id")]))
        ])
    ].

repr_acc_put(record, _F, N, V) ->
    remote(erlang, setelement, [i(N + 1), v("Acc"), V]);
repr_acc_put(native, _F, N, V) ->
    %% Position-keyed like the record accumulator: the native STOP
    %% rebuilds the field list in declaration order from positions.
    map_put(v("Acc"), i(N), V);
repr_acc_put(_Flavor, F, _N, V) ->
    map_put(v("Acc"), at(field_atom(F#tg_field.name)), V).

%% Per-type decode of one bound binary into the target representation:
%% base and enum shapes are repr-invariant and reuse the wire
%% expression; structs recurse into the same-repr decoder (map-mode
%% targets answer to the map flavor); containers decode through the
%% repr helpers with set-impl upgrades.

repr_field_decode({struct, {ref, TypesMod, Local}}, Bin, Flavor, Ctx, Enums, Suffix) ->
    case repr_nested_route(TypesMod, Local, Flavor, Ctx) of
        {repr, NestedFlavor} ->
            repr_struct_decode_call(TypesMod, Local, Bin, NestedFlavor, Ctx);
        wire ->
            decode_wire_expr({struct, {ref, TypesMod, Local}}, Bin, Ctx, Enums, Suffix)
    end;
repr_field_decode({set, Elem, ordset}, Bin, Flavor, _Ctx, Enums, _Suffix) ->
    {Dec, _Aux} = repr_decode_container_names({set, Elem}, Enums, Flavor),
    'case'(call_local(Dec, [Bin]), [
        %% The struct loop consumes the triple and recurses on the rest,
        %% so the impl upgrade must stay inside the value slot.
        ok3_bind_clause(v("Vs"), v("RestSet"), ok3(remote(ordsets, from_list, [v("Vs")]), v("RestSet"))),
        clause([at(more)], none, [at(more)]),
        %% error_clause/0 binds the shared `Err' — unsafe next to the
        %% outer case's own error clause, so this one binds its own in
        %% the pattern (the error_clause shape, renamed).
        clause([{match, ?ANNO, tuple_t([at(error), v("_")]), v("ErrSet")}], none, [v("ErrSet")])
    ]);
repr_field_decode({set, Elem, sets}, Bin, Flavor, _Ctx, Enums, _Suffix) ->
    {Dec, _Aux} = repr_decode_container_names({set, Elem}, Enums, Flavor),
    'case'(call_local(Dec, [Bin]), [
        ok3_bind_clause(v("Vs"), v("RestSet"), ok3(remote(sets, from_list, [v("Vs")]), v("RestSet"))),
        clause([at(more)], none, [at(more)]),
        clause([{match, ?ANNO, tuple_t([at(error), v("_")]), v("ErrSet")}], none, [v("ErrSet")])
    ]);
repr_field_decode({set, Elem}, Bin, Flavor, _Ctx, Enums, _Suffix) ->
    {Dec, _Aux} = repr_decode_container_names({set, Elem}, Enums, Flavor),
    call_local(Dec, [Bin]);
repr_field_decode(T, Bin, Flavor, _Ctx, Enums, Suffix) ->
    case T of
        {list, _} ->
            {Dec, _Aux} = repr_decode_container_names(T, Enums, Flavor),
            call_local(Dec, [Bin]);
        {map, _, _} ->
            {Dec, _Aux} = repr_decode_container_names(T, Enums, Flavor),
            call_local(Dec, [Bin]);
        _ ->
            decode_wire_expr(T, Bin, undefined, Enums, Suffix)
    end.

repr_struct_decode_call(TypesMod, Local, Bin, Flavor, Ctx) ->
    {_Encode, Decode} =
        case TypesMod =:= types_module_atom(Ctx#ectx.current) of
            true -> thrift_generator_codec_common:codec_pair(wire, Local, Ctx);
            false -> thrift_generator_codec_common:ref_codec_pair(wire, TypesMod, Local, Ctx)
        end,
    Name = repr_decode_name(Decode, Flavor),
    case TypesMod =:= types_module_atom(Ctx#ectx.current) of
        true -> call_local(Name, [Bin]);
        false -> remote(TypesMod, Name, [Bin])
    end.

repr_decode_container_names(T, Enums, Flavor) ->
    Dec = dec_name(T, Enums),
    Suffix = <<"_", (atom_to_binary(Flavor, utf8))/binary>>,
    Base = atom_to_binary(Dec, utf8),
    AuxSuffix =
        case T of
            {map, _, _} -> <<"_pairs">>;
            _ -> <<"_elems">>
        end,
    {
        binary_to_atom(<<Base/binary, Suffix/binary>>, utf8),
        binary_to_atom(<<Base/binary, AuxSuffix/binary, Suffix/binary>>, utf8)
    }.

repr_decode_module_containers(Convertible, Ctx, Enums) ->
    WireTypes = lists:append([
        [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields]
     || S <- Convertible
    ]),
    Containers = repr_containers(WireTypes),
    lists:append([repr_decode_container_forms(C, record, Ctx, Enums) || C <- Containers]) ++
        lists:append([repr_decode_container_forms(C, map, Ctx, Enums) || C <- Containers]) ++
        lists:append([repr_decode_container_forms(C, struct, Ctx, Enums) || C <- Containers]) ++
        lists:append([repr_decode_container_forms(C, native, Ctx, Enums) || C <- Containers]).

repr_decode_container_forms({Kind, _} = T, Flavor, Ctx, Enums) when Kind =:= list; Kind =:= set ->
    Wire = wire_byte(thrift_generator_codec_common:elem_type(T)),
    {Dec, DecElems} = repr_decode_container_names(T, Enums, Flavor),
    Elem = thrift_generator_codec_common:elem_type(T),
    [
        {function, ?ANNO, Dec, 1, [
            %% The mismatch clauses mirror the generic engine: a
            %% negative size errors on any type byte, a non-matching
            %% type byte errors when the header is fully present, and
            %% only a short binary asks for more.
            clause(
                [
                    bin_pat([
                        {v("_"), default, default},
                        {v("Size"), i(32), [big, signed]},
                        {v("_Rest"), default, [binary]}
                    ])
                ],
                [{op, ?ANNO, '<', v("Size"), i(0)}],
                [err_decode(at(bad_sequence_size))]
            ),
            clause(
                [
                    bin_pat([
                        {i(Wire), i(8), [big, unsigned]},
                        {v("Size"), i(32), [big, signed]},
                        {v("Rest"), default, [binary]}
                    ])
                ],
                none,
                %% The elems tail carries the consumed rest out itself;
                %% `more` and `{error, _}` propagate unchanged.
                [call_local(DecElems, [v("Rest"), v("Size"), nil()])]
            ),
            clause(
                [
                    bin_pat([
                        {v("TypeByte"), i(8), [big, unsigned]},
                        {v("_"), i(32), [big, signed]},
                        {v("_"), default, [binary]}
                    ])
                ],
                none,
                [err_decode(tuple_t([at(element_type_mismatch), v("TypeByte")]))]
            ),
            clause([v("_")], none, [at(more)])
        ]},
        {function, ?ANNO, DecElems, 3, [
            clause([v("Rest"), i(0), v("Acc")], none, [ok3(remote(lists, reverse, [v("Acc")]), v("Rest"))]),
            clause(
                [
                    bin_pat([
                        {v("_"), default, default}, {v("_"), i(32), [big, signed]}, {v("_Rest"), default, [binary]}
                    ]),
                    v("Size"),
                    v("_Acc")
                ],
                [{op, ?ANNO, '<', v("Size"), i(0)}],
                [err_decode(at(bad_sequence_size))]
            ),
            clause([v("Rest"), v("Size"), v("Acc")], none, [
                'case'(repr_field_decode(Elem, v("Rest"), Flavor, Ctx, Enums, "E"), [
                    ok3_bind_clause(
                        v("V"),
                        v("Rest1"),
                        call_local(DecElems, [
                            v("Rest1"),
                            {op, ?ANNO, '-', v("Size"), i(1)},
                            cons(v("V"), v("Acc"))
                        ])
                    ),
                    clause([at(more)], none, [at(more)]),
                    error_clause()
                ])
            ])
        ]}
    ];
repr_decode_container_forms({map, KType, VType} = T, Flavor, Ctx, Enums) ->
    KWire = wire_byte(KType),
    VWire = wire_byte(VType),
    {Dec, DecPairs} = repr_decode_container_names(T, Enums, Flavor),
    [
        {function, ?ANNO, Dec, 1, [
            clause(
                [
                    bin_pat([
                        {v("_"), default, default},
                        {v("_"), default, default},
                        {v("Size"), i(32), [big, signed]},
                        {v("_"), default, [binary]}
                    ])
                ],
                [{op, ?ANNO, '<', v("Size"), i(0)}],
                [err_decode(at(bad_map_size))]
            ),
            clause(
                [
                    bin_pat([
                        {i(KWire), i(8), [big, unsigned]},
                        {i(VWire), i(8), [big, unsigned]},
                        {v("Size"), i(32), [big, signed]},
                        {v("Rest"), default, [binary]}
                    ])
                ],
                none,
                [call_local(DecPairs, [v("Rest"), v("Size"), map_empty()])]
            ),
            %% Non-matching type bytes with the header fully present —
            %% the generic engine's map_type_mismatch clause.
            clause(
                [
                    bin_pat([
                        {v("_"), default, default},
                        {v("_"), default, default},
                        {v("_"), i(32), [big, signed]},
                        {v("_"), default, [binary]}
                    ])
                ],
                none,
                [err_decode(at(map_type_mismatch))]
            ),
            clause([v("_")], none, [at(more)])
        ]},
        {function, ?ANNO, DecPairs, 3, [
            clause([v("Rest"), i(0), v("Acc")], none, [ok3(v("Acc"), v("Rest"))]),
            clause(
                [
                    bin_pat([
                        {v("_"), default, default}, {v("_"), i(32), [big, signed]}, {v("_Rest"), default, [binary]}
                    ]),
                    v("Size"),
                    v("_Acc")
                ],
                [{op, ?ANNO, '<', v("Size"), i(0)}],
                [err_decode(at(bad_map_size))]
            ),
            clause([v("Rest"), v("Size"), v("Acc")], none, [
                'case'(repr_field_decode(KType, v("Rest"), Flavor, Ctx, Enums, "K"), [
                    ok3_bind_clause(
                        v("K"),
                        v("Rest1"),
                        'case'(repr_field_decode(VType, v("Rest1"), Flavor, Ctx, Enums, "V"), [
                            ok3_bind_clause(
                                v("V"),
                                v("Rest2"),
                                call_local(DecPairs, [
                                    v("Rest2"),
                                    {op, ?ANNO, '-', v("Size"), i(1)},
                                    map_put(v("Acc"), v("K"), v("V"))
                                ])
                            ),
                            clause([at(more)], none, [at(more)]),
                            error_clause()
                        ])
                    ),
                    clause([at(more)], none, [at(more)]),
                    error_clause()
                ])
            ])
        ]}
    ].

%%--------------------------------------------------------------------
%% Repr-native encoder naming and exports
%%--------------------------------------------------------------------

%% The repr-native encoder names: the wire encode name suffixed with
%% the input representation. Shared between the emission below and the
%% types-module export list so both always agree.

-spec repr_encode_name(atom(), record | map) -> atom().
repr_encode_name(Encode, Flavor) ->
    B = atom_to_binary(Encode, utf8),
    Suffix =
        case Flavor of
            record -> <<"_from_record">>;
            map -> <<"_from_map">>
        end,
    binary_to_atom(<<B/binary, Suffix/binary>>, utf8).

%% Export entries of the repr-native encoders: per record-mode struct
%% the from_record/from_map pair, plus both flavors of every container
%% helper its fields use (map containers encode through a _pairs/2
%% helper, list/set through _elems/1).

-spec repr_index_entries(#tg_module{}) -> [{atom(), arity()}].
repr_index_entries(Mod) ->
    case repr_convertible_structs(Mod#tg_module.structs) of
        [] -> [];
        _ -> [{binary_repr_codec, 2}]
    end.

-spec repr_encode_export_entries(#tg_module{}, #ectx{}) -> [{atom(), arity()}].
repr_encode_export_entries(Mod, Ctx) ->
    Convertible = repr_convertible_structs(Mod#tg_module.structs),
    WireTypes = [
        wtype(F#tg_field.type, Ctx)
     || S <- Convertible,
        F <- S#tg_struct.fields
    ],
    StructPairs = [repr_codec_export_entries(S, Ctx) || S <- Convertible],
    Enums = thrift_generator_codec_common:enum_registry(WireTypes),
    EncContainerEntries = lists:append([
        repr_enc_container_entries(C, Enums)
     || C <- repr_containers(WireTypes)
    ]),
    DecContainerEntries = lists:append([
        repr_dec_container_entries(C, Enums)
     || C <- repr_containers(WireTypes)
    ]),
    ContainerEntries = EncContainerEntries ++ DecContainerEntries,
    lists:append(StructPairs) ++ ContainerEntries.

%% The export list of one convertible struct's repr family: the
%% from_record/from_map encoders (record only when the struct has a
%% record) and the map/struct decoders (record/native likewise).

repr_codec_export_entries(S, Ctx) ->
    {Encode, Decode} = thrift_generator_codec_common:codec_pair(wire, S, Ctx),
    EncEntries = [{repr_encode_name(Encode, map), 1}],
    Enc =
        case thrift_generator_emitter:has_record(S) of
            true -> [{repr_encode_name(Encode, record), 1} | EncEntries];
            false -> EncEntries
        end,
    DecEntries = [
        {repr_decode_name(Decode, map), 1},
        {repr_decode_name(Decode, struct), 1}
    ],
    Dec =
        case thrift_generator_emitter:has_record(S) of
            true ->
                [
                    {repr_decode_name(Decode, record), 1},
                    {repr_decode_name(Decode, native), 1}
                    | DecEntries
                ];
            false ->
                DecEntries
        end,
    Enc ++ Dec.

repr_enc_container_entries(C, Enums) ->
    {Rec, RecElems} = repr_container_names(C, Enums, record),
    {Map, MapElems} = repr_container_names(C, Enums, map),
    [{Rec, 1}, {Map, 1} | repr_container_aux_entries(C, RecElems, MapElems)].

repr_dec_container_entries(C, Enums) ->
    {RecD, RecDAux} = repr_decode_container_names(C, Enums, record),
    {MapD, MapDAux} = repr_decode_container_names(C, Enums, map),
    {StructD, StructDAux} = repr_decode_container_names(C, Enums, struct),
    {NativeD, NativeDAux} = repr_decode_container_names(C, Enums, native),
    [
        {RecD, 1},
        {RecDAux, 3},
        {MapD, 1},
        {MapDAux, 3},
        {StructD, 1},
        {StructDAux, 3},
        {NativeD, 1},
        {NativeDAux, 3}
    ].

repr_containers(WireTypes) ->
    lists:usort(lists:append([thrift_generator_codec_common:containers(T) || T <- WireTypes])).

%% The pairs helper of a map container takes the accumulator (arity 2);
%% the elems helper of a list/set container does not (arity 1).

-spec repr_container_aux_entries(wire_type(), atom(), atom()) -> [{atom(), arity()}].
repr_container_aux_entries({map, _, _}, RecPairs, MapPairs) ->
    [{RecPairs, 2}, {MapPairs, 2}];
repr_container_aux_entries(_C, RecElems, MapElems) ->
    [{RecElems, 1}, {MapElems, 1}].

%% The decode auxiliaries all take the looping arity (size and
%% accumulator plus the binary).

-spec repr_container_names(wire_type(), thrift_generator_codec_common:registry(), record | map) -> {atom(), atom()}.
repr_container_names(T, Enums, Flavor) ->
    Enc = enc_name(T, Enums),
    Suffix =
        case Flavor of
            record -> <<"_from_record">>;
            map -> <<"_from_map">>
        end,
    Base = atom_to_binary(Enc, utf8),
    AuxSuffix =
        case T of
            {map, _, _} -> <<"_pairs">>;
            _ -> <<"_elems">>
        end,
    {
        binary_to_atom(<<Base/binary, Suffix/binary>>, utf8),
        binary_to_atom(<<Base/binary, AuxSuffix/binary, Suffix/binary>>, utf8)
    }.

%%--------------------------------------------------------------------
%% Repr-native encoders
%%--------------------------------------------------------------------

%% One-pass encoders reading the target representation directly: the
%% record tuple by position, the map by field name — no wire-map
%% materialization between the caller and the wire bytes. Appended
%% after the wire sections: every existing function keeps its BEAM
%% layout position. Only record-mode structs with at least one field
%% get a family (empty unions never reach a chain; their wire entry
%% errors first, and emitting one would leave it unreachable).

-spec repr_encode_forms([#tg_struct{}], #ectx{}, thrift_generator_codec_common:registry()) -> erl_syntax:forms().
repr_encode_forms(Structs, Ctx, Enums) ->
    %% Every struct with fields gets the from_map encoder (its values
    %% are maps in map mode and map-repr inputs in record mode);
    %% from_record exists only for record-mode structs. Sum unions and
    %% empty unions stay on the wire path. Container helpers are
    %% module-level: the same container type used by several structs
    %% must be emitted exactly once.
    Convertible = repr_convertible_structs(Structs),
    lists:append([repr_encode_struct_forms(S, Ctx, Enums) || S <- Convertible]) ++
        repr_encode_module_containers(Convertible, Ctx, Enums).

repr_convertible_structs(Structs) ->
    %% Empty structs get entry-only encoders (the chain closes with the
    %% stop byte immediately); nested references from other structs'
    %% chains reach them, so they must exist. Tagged unions join the
    %% family too: the encode entries carry the exactly-one-field check
    %% (the decode side accepts whatever the wire carries, like the
    %% two-pass path). Sum unions, empty unions and native-mode structs
    %% stay on the descriptor path.
    [S || S <- Structs, repr_convertible(S)].

repr_convertible(#tg_struct{kind = struct}) ->
    true;
repr_convertible(#tg_struct{kind = union} = S) ->
    S#tg_struct.fields =/= [] andalso thrift_generator_emitter:has_record(S);
repr_convertible(_) ->
    false.

repr_encode_struct_forms(S, Ctx, Enums) ->
    {Encode, _Decode} = thrift_generator_codec_common:codec_pair(wire, S, Ctx),
    FieldTypes = [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields],
    MapName = repr_encode_name(Encode, map),
    MapForms =
        repr_encode_entry(S, MapName, undefined, FieldTypes, map) ++
            repr_encode_chain(S, MapName, FieldTypes, map, Ctx, Enums),
    case thrift_generator_emitter:has_record(S) of
        true ->
            Tag = thrift_generator_emitter:record_tag_of(S, thrift_generator_codec_common:current_prefix(Ctx)),
            RecName = repr_encode_name(Encode, record),
            repr_encode_entry(S, RecName, Tag, FieldTypes, record) ++
                repr_encode_chain(S, RecName, FieldTypes, record, Ctx, Enums) ++
                MapForms;
        false ->
            MapForms
    end.

repr_encode_module_containers(Convertible, Ctx, Enums) ->
    WireTypes = lists:append([
        [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields]
     || S <- Convertible
    ]),
    repr_encode_containers(WireTypes, Ctx, Enums).

%% Entry functions: the record family matches the whole tuple once and
%% hands the field values to the chain; the map family guards is_map.
%% A value of no accepted shape answers the unwrapped
%% {error, {value_does_not_match_type, V}} — the term the conversion
%% layer raises for it today (the wire family's wrapped codec error
%% stays on the wire path only).

repr_encode_entry(S, Name, Tag, FieldTypes, Flavor) ->
    K = length(FieldTypes),
    Chain = atom_concat(Name, <<"_fields">>),
    Vars = [v("F" ++ integer_to_list(I)) || I <- lists:seq(1, K)],
    EntryCall =
        case FieldTypes of
            [] ->
                %% Zero fields: the stop byte closes the struct.
                ok_t(list_lit([i(0)]));
            _ ->
                case Flavor of
                    record ->
                        call_local(chain_fn_name(Chain, 1), Vars);
                    map ->
                        call_local(chain_fn_name(Chain, 1), [v("Value")])
                end
        end,
    CheckBody =
        case S#tg_struct.kind of
            union when Flavor =:= record ->
                repr_union_check_record(Vars, EntryCall);
            union ->
                %% Map-flavor union values key fields by atom (the map
                %% representation) or by binary (a plain wire map); a
                %% field spelled both ways still counts once, mirroring
                %% the chain's binary-first lookup.
                repr_union_check_map(S#tg_struct.fields, EntryCall);
            _ ->
                %% The wire entry refuses missing required fields before
                %% encoding anything; the repr entries must answer the
                %% same error term, reading presence from the target
                %% representation directly.
                case Flavor of
                    record -> repr_required_check_record(S#tg_struct.fields, Vars, EntryCall);
                    map -> repr_required_check_map(S#tg_struct.fields, EntryCall)
                end
        end,
    HeadPat =
        case Flavor of
            record -> tuple_t([at(Tag) | [v("F" ++ integer_to_list(I)) || I <- lists:seq(1, K)]]);
            map -> v("Value")
        end,
    Guard =
        case Flavor of
            record -> none;
            map -> [remote(erlang, is_map, [v("Value")])]
        end,
    [
        {function, ?ANNO, Name, 1, [
            clause([HeadPat], Guard, [CheckBody]),
            clause([v("Value")], none, [repr_mismatch_error(v("Value"))])
        ]}
    ].

repr_mismatch_error(V) ->
    {tuple, ?ANNO, [{atom, ?ANNO, error}, tuple_t([at(value_does_not_match_type), V])]}.

%% Required presence for the repr entries: same error term and name
%% order as the wire `required_check/2', but presence reads the target
%% representation — a record position is present when it is not
%% `undefined'; a map key counts under its binary or atom spelling (the
%% map chain looks binary names up first, atom ones second).

repr_required_check_record(Fields, Vars, Call) ->
    Required = [F || F <- Fields, F#tg_field.required =:= required],
    case Required of
        [] ->
            Call;
        _ ->
            Pairs = lists:zip(Required, required_vars(Fields, Required, Vars)),
            Guards = [{op, ?ANNO, '=/=', Var, at(undefined)} || {_F, Var} <- Pairs],
            Missing = missing_required_lc([
                tuple_t([name_lit(F#tg_field.name), {op, ?ANNO, '=/=', Var, at(undefined)}])
             || {F, Var} <- Pairs
            ]),
            'case'(at(true), [
                clause([v("_")], Guards, [Call]),
                clause([v("_")], none, [err_encode(tuple_t([at(missing_required_fields), Missing]))])
            ])
    end.

required_vars(Fields, Required, Vars) ->
    Positions = [
        lists:keyfind(F#tg_field.id, 1, [
            {G#tg_field.id, I}
         || {I, G} <- lists:zip(lists:seq(1, length(Fields)), Fields)
        ])
     || F <- Required
    ],
    [lists:nth(I, Vars) || {_, I} <- Positions].

repr_required_check_map(Fields, Call) ->
    Required = [F || F <- Fields, F#tg_field.required =:= required],
    case Required of
        [] ->
            Call;
        _ ->
            Presence = [
                tuple_t([name_lit(F#tg_field.name), map_key_present(F, v("Value"))])
             || F <- Required
            ],
            AllPresent = lists:foldr(
                fun(F, Acc) -> {op, ?ANNO, 'andalso', map_key_present(F, v("Value")), Acc} end,
                at(true),
                Required
            ),
            Missing = missing_required_lc(Presence),
            'case'(AllPresent, [
                clause([at(true)], none, [Call]),
                clause([v("_")], none, [err_encode(tuple_t([at(missing_required_fields), Missing]))])
            ])
    end.

map_key_present(F, Map) ->
    {op, ?ANNO, 'orelse', remote(maps, is_key, [name_lit(F#tg_field.name), Map]),
        remote(maps, is_key, [at(field_atom(F#tg_field.name)), Map])}.

missing_required_lc(PresenceTuples) ->
    %% The filter is a bare expression: raw-AST qualifiers carry no
    %% `{filter, _}' wrapper (that shape is erl_syntax-only).
    lc(v("N"), [
        {generate, ?ANNO, tuple_pat([v("N"), v("P")]), list_lit(PresenceTuples)},
        {op, ?ANNO, 'not', v("P")}
    ]).

repr_union_check_record(Vars, Call) ->
    Counts = [
        'case'(Var, [
            clause([at(undefined)], none, [i(0)]),
            clause([v("_")], none, [i(1)])
        ])
     || Var <- Vars
    ],
    Sum = lists:foldl(fun(C, Acc) -> {op, ?ANNO, '+', Acc, C} end, hd(Counts), tl(Counts)),
    'case'(Sum, [
        clause([i(1)], none, [Call]),
        clause([i(0)], none, [err_encode(at(union_empty))]),
        clause([v("_")], none, [err_encode(at(union_multiple))])
    ]).

repr_union_check_map(Fields, Call) ->
    Counts = [
        'case'(map_key_present(F, v("Value")), [
            clause([at(true)], none, [i(1)]),
            clause([at(false)], none, [i(0)])
        ])
     || F <- Fields
    ],
    Sum = lists:foldl(fun(C, Acc) -> {op, ?ANNO, '+', Acc, C} end, hd(Counts), tl(Counts)),
    'case'(Sum, [
        clause([i(1)], none, [Call]),
        clause([i(0)], none, [err_encode(at(union_empty))]),
        clause([v("_")], none, [err_encode(at(union_multiple))])
    ]).

%% Chains: one function per field in declaration order, mirroring the
%% wire chain's call shape (each step calls the next — no nested
%% trees). Record chains carry the remaining field values; map chains
%% carry the map and read each field with binary-name-first lookup.

repr_encode_chain(S, Name, FieldTypes, Flavor, Ctx, Enums) ->
    Chain = atom_concat(Name, <<"_fields">>),
    K = length(FieldTypes),
    Pairs = lists:zip(lists:seq(1, K), lists:zip(S#tg_struct.fields, FieldTypes)),
    R = #rcc{chain = Chain, k = K, flavor = Flavor, ctx = Ctx, enums = Enums},
    repr_chain_fns(Pairs, R).

repr_chain_fns([], _R) ->
    [];
repr_chain_fns([{N, {F, T}}], R) ->
    [repr_chain_fn(N, F, T, ok_t(list_lit([i(0)])), R)];
repr_chain_fns([{N, {F, T}} | Rest], R) ->
    #rcc{chain = Chain, k = K, flavor = Flavor} = R,
    NextArgs =
        case Flavor of
            record -> [v("F" ++ integer_to_list(I)) || I <- lists:seq(N + 1, K)];
            map -> [v("Value")]
        end,
    Next = call_local(chain_fn_name(Chain, N + 1), NextArgs),
    [repr_chain_fn(N, F, T, Next, R)] ++ repr_chain_fns(Rest, R).

repr_chain_fn(N, F, T, Next, R) ->
    #rcc{chain = Chain, k = K, flavor = Flavor, ctx = Ctx, enums = Enums} = R,
    Header = header_bin(wire_byte(T), F#tg_field.id),
    Val =
        case Flavor of
            record -> v("F" ++ integer_to_list(N));
            map -> v("V")
        end,
    Body =
        case Flavor of
            record ->
                repr_record_field_body(T, Val, Header, Next, Ctx, Enums);
            map ->
                'case'(remote(maps, find, [name_lit(F#tg_field.name), v("Value")]), [
                    clause([tuple_t([at(ok), Val])], none, [
                        repr_field_step(T, Val, Header, Next, Flavor, Ctx, Enums)
                    ]),
                    clause([at(error)], none, [
                        'case'(remote(maps, find, [at(field_atom(F#tg_field.name)), v("Value")]), [
                            clause([tuple_t([at(ok), Val])], none, [
                                repr_field_step(T, Val, Header, Next, Flavor, Ctx, Enums)
                            ]),
                            clause([at(error)], none, [Next])
                        ])
                    ])
                ])
        end,
    Args =
        case Flavor of
            record -> [v("F" ++ integer_to_list(I)) || I <- lists:seq(N, K)];
            map -> [v("Value")]
        end,
    {function, ?ANNO, chain_fn_name(Chain, N), length(Args), [clause(Args, none, [Body])]}.

%% Record fields: skip undefined, then per-type guarded clauses for
%% base types (payload straight into the chunk, mirroring the wire
%% chain's base fast path) or a {ok, E} step for the rest.

repr_record_field_body({base, B}, Val, Header, Next, _Ctx, _Enums) ->
    %% The base clauses end with the mismatch clause — a bound record
    %% field is either undefined, valid, or an error; there is no
    %% absent-shape fallthrough like the wire chain's missing key.
    'case'(Val, repr_base_clauses(B, Header, Next));
repr_record_field_body(T, Val, Header, Next, Ctx, Enums) ->
    'case'(Val, [
        clause([at(undefined)], none, [Next]),
        clause([v("_V")], none, [repr_field_step(T, v("_V"), Header, Next, record, Ctx, Enums)])
    ]).

repr_field_step(T, Val, Header, Next, Flavor, Ctx, Enums) ->
    'case'(repr_field_encode(T, Val, Flavor, Ctx, Enums, ""), [
        clause([tuple_t([at(ok), v("E")])], none, [
            'case'(Next, [
                ok_bind_clause(v("Rest"), ok_t(cons(list_lit([Header, v("E")]), v("Rest")))),
                error_clause()
            ])
        ]),
        error_clause()
    ]).

%% The per-type encode expression for one bound value: base clauses
%% inline, enums reuse the wire shape, structs recurse into the same
%% repr's encoder, containers into the repr container helper.

repr_field_encode({base, B}, Val, _Flavor, _Ctx, _Enums, Suffix) ->
    'case'(Val, repr_base_value_clauses(B, Suffix));
repr_field_encode({enum, Desc}, Val, _Flavor, Ctx, Enums, Suffix) ->
    encode_wire_expr({enum, Desc}, Val, Ctx, Enums, Suffix);
repr_field_encode({struct, {ref, TypesMod, Local}}, Val, Flavor, Ctx, _Enums, _Suffix) ->
    %% A map-mode nested struct is a map in every representation (the
    %% conversion engine never builds a record for it), so the record
    %% chain reads it with the map encoder.
    NestedFlavor =
        case Flavor =:= record andalso not nested_has_record(TypesMod, Local, Ctx) of
            true -> map;
            false -> Flavor
        end,
    repr_struct_encode_call(TypesMod, Local, Val, NestedFlavor, Ctx);
repr_field_encode({set, Elem, sets}, Val, Flavor, _Ctx, Enums, _Suffix) ->
    {Enc, _Elems} = repr_container_names({set, Elem}, Enums, Flavor),
    call_local(Enc, [remote(sets, to_list, [Val])]);
repr_field_encode({set, Elem, ordset}, Val, Flavor, _Ctx, Enums, _Suffix) ->
    {Enc, _Elems} = repr_container_names({set, Elem}, Enums, Flavor),
    call_local(Enc, [Val]);
repr_field_encode(T, Val, Flavor, _Ctx, Enums, _Suffix) ->
    {Enc, _Elems} = repr_container_names(T, Enums, Flavor),
    call_local(Enc, [Val]).

%% Where a nested struct decode goes: a map-mode target answers with
%% its map decoder for atom keys, but a {map, binary} target's map
%% decoder would mint atom keys the conversion never produces — its
%% wire decoder IS its representation, so the nested call stays on the
%% wire function. Record-mode targets follow the parent's flavor.
repr_nested_route(TypesMod, Local, Flavor, Ctx) ->
    case nested_mode(TypesMod, Local, Ctx) of
        record ->
            {repr, Flavor};
        {map, atom} ->
            {repr, map};
        {map, binary} ->
            wire
    end.

nested_mode(TypesMod, Local, Ctx) ->
    case nested_module(TypesMod, Ctx) of
        undefined ->
            record;
        Mod ->
            case lists:search(fun(S) -> S#tg_struct.name =:= Local end, Mod#tg_module.structs) of
                {value, S} ->
                    case thrift_generator_emitter:has_record(S) of
                        true -> record;
                        false -> {map, thrift_generator_emitter:map_key_type(S)}
                    end;
                false ->
                    record
            end
    end.

nested_module(TypesMod, Ctx) ->
    case maps:get(TypesMod, Ctx#ectx.modules, undefined) of
        undefined ->
            nested_include_module(TypesMod, Ctx);
        M ->
            M
    end.

nested_include_module(TypesMod, Ctx) ->
    case maps:get(TypesMod, Ctx#ectx.include_modules, undefined) of
        undefined ->
            find_module_by_types_name(TypesMod, Ctx);
        Key ->
            maps:get(Key, Ctx#ectx.modules, undefined)
    end.

find_module_by_types_name(TypesMod, Ctx) ->
    Matches = [
        M
     || M <- maps:values(Ctx#ectx.modules),
        types_module_atom(M#tg_module.name) =:= TypesMod
    ],
    case Matches of
        [] -> undefined;
        [M | _] -> M
    end.

nested_has_record(TypesMod, Local, Ctx) ->
    nested_mode(TypesMod, Local, Ctx) =:= record.

repr_struct_encode_call(TypesMod, Local, V, Flavor, Ctx) ->
    {Encode, _Decode} =
        case TypesMod =:= types_module_atom(Ctx#ectx.current) of
            true -> thrift_generator_codec_common:codec_pair(wire, Local, Ctx);
            false -> thrift_generator_codec_common:ref_codec_pair(wire, TypesMod, Local, Ctx)
        end,
    Name = repr_encode_name(Encode, Flavor),
    case TypesMod =:= types_module_atom(Ctx#ectx.current) of
        true -> call_local(Name, [V]);
        false -> remote(TypesMod, Name, [V])
    end.

%% Base-type value clauses: the same guards and payloads the wire
%% chain's base clauses use, but matched against a bound value.

repr_base_clauses(B, Header, Next) ->
    [clause([at(undefined)], none, [Next])] ++ repr_base_present_clauses(B, Header, Next).

%% The record chain's base fast path: the guarded present clauses cons
%% the payload straight into the chunk, exactly like the wire chain's
%% base clauses — no {ok, E} wrapper per field.

repr_base_present_clauses(B, Header, Next) ->
    Wrap = fun(Payload) ->
        'case'(Next, [
            ok_bind_clause(v("Rest"), ok_t(cons(list_lit([Header, Payload]), v("Rest")))),
            error_clause()
        ])
    end,
    V = v("V"),
    Present =
        case B of
            bool ->
                [
                    clause([at(true)], none, [Wrap(bin_lit(<<1>>))]),
                    clause([at(false)], none, [Wrap(bin_lit(<<0>>))])
                ];
            double ->
                [
                    clause(
                        [V],
                        [remote(erlang, is_number, [V])],
                        [Wrap(bin_seg(remote(erlang, float, [V]), i(64), [big, float]))]
                    )
                ];
            S when S =:= string; S =:= binary ->
                [
                    clause(
                        [V],
                        [remote(erlang, is_binary, [V])],
                        [Wrap(list_lit([i32_seg(call_local(byte_size, [V])), V]))]
                    )
                ];
            uuid ->
                [
                    clause(
                        [V],
                        [
                            remote(erlang, is_binary, [V]),
                            {op, ?ANNO, '=:=', call_local(byte_size, [V]), i(16)}
                        ],
                        [Wrap(V)]
                    )
                ];
            _ ->
                Bits = bits(B),
                [
                    clause(
                        [V],
                        [
                            remote(erlang, is_integer, [V]),
                            {op, ?ANNO, '>=', V, i(-(1 bsl (Bits - 1)))},
                            {op, ?ANNO, '=<', V, i((1 bsl (Bits - 1)) - 1)}
                        ],
                        [Wrap(bin_seg(V, i(Bits), [big, signed]))]
                    )
                ]
        end,
    Present ++ [clause([v("OtherV")], none, [err_encode(mismatch(v("OtherV")))])].

repr_base_value_clauses(B, Suffix) ->
    V = v("V"),
    Present =
        case B of
            bool ->
                [
                    clause([at(true)], none, [ok_t(bin_lit(<<1>>))]),
                    clause([at(false)], none, [ok_t(bin_lit(<<0>>))])
                ];
            double ->
                [
                    clause(
                        [V],
                        [remote(erlang, is_number, [V])],
                        [ok_t(bin_seg(remote(erlang, float, [V]), i(64), [big, float]))]
                    )
                ];
            S when S =:= string; S =:= binary ->
                [
                    clause(
                        [V],
                        [remote(erlang, is_binary, [V])],
                        [ok_t(list_lit([i32_seg(call_local(byte_size, [V])), V]))]
                    )
                ];
            uuid ->
                [
                    clause(
                        [V],
                        [
                            remote(erlang, is_binary, [V]),
                            {op, ?ANNO, '=:=', call_local(byte_size, [V]), i(16)}
                        ],
                        [ok_t(V)]
                    )
                ];
            _ ->
                Bits = bits(B),
                [
                    clause(
                        [V],
                        [
                            remote(erlang, is_integer, [V]),
                            {op, ?ANNO, '>=', V, i(-(1 bsl (Bits - 1)))},
                            {op, ?ANNO, '=<', V, i((1 bsl (Bits - 1)) - 1)}
                        ],
                        [ok_t(bin_seg(V, i(Bits), [big, signed]))]
                    )
                ]
        end,
    Present ++ [clause([v("OtherV" ++ Suffix)], none, [err_encode(mismatch(v("OtherV" ++ Suffix)))])].

%% Repr container helpers: the wire container form with the element
%% encode expression replaced by the same-repr field encode.

repr_encode_containers(FieldTypes, Ctx, Enums) ->
    Containers = lists:usort(lists:append([thrift_generator_codec_common:containers(T) || T <- FieldTypes])),
    lists:append([repr_container_forms(C, record, Ctx, Enums) || C <- Containers]) ++
        lists:append([repr_container_forms(C, map, Ctx, Enums) || C <- Containers]).

repr_container_forms({Kind, _} = T, Flavor, Ctx, Enums) when Kind =:= list; Kind =:= set ->
    Wire = wire_byte(thrift_generator_codec_common:elem_type(T)),
    {Enc, EncElems} = repr_container_names(T, Enums, Flavor),
    Elem = thrift_generator_codec_common:elem_type(T),
    [
        {function, ?ANNO, Enc, 1, [
            clause([v("Values")], [remote(erlang, is_list, [v("Values")])], [
                'case'(call_local(EncElems, [v("Values")]), [
                    clause([tuple_t([at(ok), v("Es")])], none, [
                        ok_t(
                            list_lit([
                                list_lit([
                                    bin_seg(i(Wire), i(8), [big, unsigned]),
                                    i32_seg(call_local(length, [v("Values")]))
                                ]),
                                v("Es")
                            ])
                        )
                    ]),
                    error_clause()
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, EncElems, 1, [
            clause([nil()], none, [ok_t(nil())]),
            clause([cons(v("V"), v("Rest"))], none, [
                'case'(repr_field_encode(Elem, v("V"), Flavor, Ctx, Enums, ""), [
                    clause([tuple_t([at(ok), v("E")])], none, [
                        'case'(call_local(EncElems, [v("Rest")]), [
                            ok_bind_clause(v("RestIo"), ok_t(cons(v("E"), v("RestIo")))),
                            error_clause()
                        ])
                    ]),
                    error_clause()
                ])
            ])
        ]}
    ];
repr_container_forms({map, KType, VType} = T, Flavor, Ctx, Enums) ->
    KeyWire = wire_byte(KType),
    ValWire = wire_byte(VType),
    {Enc, EncPairs} = repr_container_names(T, Enums, Flavor),
    SortFun =
        {'fun', ?ANNO,
            {clauses, [
                clause([tuple_pat([v("KE"), v("_")]), tuple_pat([v("KE1"), v("_")])], none, [
                    {op, ?ANNO, '=<', v("KE"), v("KE1")}
                ])
            ]}},
    [
        {function, ?ANNO, Enc, 1, [
            clause([v("Value")], [remote(erlang, is_map, [v("Value")])], [
                'case'(call_local(EncPairs, [remote(maps, to_list, [v("Value")]), nil()]), [
                    clause([tuple_t([at(ok), v("Pairs")])], none, [
                        {match, ?ANNO, v("Sorted"), remote(lists, sort, [SortFun, v("Pairs")])},
                        %% The encoded-key term shape matches the wire
                        %% helper's, so the sort order (map pairs sort
                        %% by the encoded-key term) is identical. The
                        %% sorted accumulator holds `{KE, VE}' tuples;
                        %% flatten them into the iodata like the wire
                        %% helper's pairs_lc does.
                        ok_t(
                            list_lit([
                                list_lit([
                                    {bin, ?ANNO, [
                                        {bin_element, ?ANNO, i(KeyWire), i(8), [big, unsigned]},
                                        {bin_element, ?ANNO, i(ValWire), i(8), [big, unsigned]}
                                    ]},
                                    i32_seg(call_local(length, [v("Sorted")]))
                                ]),
                                pairs_lc()
                            ])
                        )
                    ]),
                    error_clause()
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, EncPairs, 2, [
            clause([nil(), v("Acc")], none, [ok_t(remote(lists, reverse, [v("Acc")]))]),
            clause([cons(tuple_pat([v("K"), v("V")]), v("Rest")), v("Acc")], none, [
                'case'(repr_field_encode(KType, v("K"), Flavor, Ctx, Enums, "K"), [
                    clause([tuple_t([at(ok), v("KE")])], none, [
                        'case'(repr_field_encode(VType, v("V"), Flavor, Ctx, Enums, "V"), [
                            clause([tuple_t([at(ok), v("VE")])], none, [
                                call_local(EncPairs, [v("Rest"), cons(tuple_t([v("KE"), v("VE")]), v("Acc"))])
                            ]),
                            error_clause()
                        ])
                    ]),
                    error_clause()
                ])
            ])
        ]}
    ].

-spec field_atom(binary()) -> atom().
field_atom(Name) ->
    binary_to_atom(Name, utf8).

-spec header_bin(non_neg_integer(), integer()) -> ast().
header_bin(Wire, Id) ->
    {bin, ?ANNO, [
        {bin_element, ?ANNO, i(Wire), i(8), [big, unsigned]},
        {bin_element, ?ANNO, i(Id), i(16), [big, signed]}
    ]}.

-spec header_pat() -> ast().
header_pat() ->
    {bin, ?ANNO, [
        {bin_element, ?ANNO, v("Type"), i(8), [big, unsigned]},
        {bin_element, ?ANNO, v("Id"), i(16), [big, signed]},
        {bin_element, ?ANNO, v("Rest"), default, [binary]}
    ]}.

-spec i32_seg(ast()) -> ast().
i32_seg(Expr) ->
    bin_seg(Expr, i(32), [big, signed]).
