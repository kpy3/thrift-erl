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
field names), with the same contracts as `thrift_erl_binary:encode/2`
and `thrift_erl_binary:decode/2`. The module-level `binary_codec/1`
hands the function pair out by wire struct name; `thrift_erl_binary`
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
sibling wire functions; cross-module references go through
`thrift_erl_binary:encode/2` and `decode/2`, which re-enter the codec
probe. Containers get private `enc_*/dec_*` helpers named after the
rendered element type; enum members are inlined as case clauses at
every use site.

Forms are built as raw `erl_parse` trees — patterns, binary segment
options and guards have no convenient `erl_syntax` constructors — so
`erl_pp` renders them; doc and spec attributes stay syntax trees like
everywhere else in the emitter.
""".

-export([export_entries/2, module_forms/2]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

-define(ANNO, erl_anno:new(0)).

%% The wire descriptor vocabulary of `thrift_generator_emitter:type_desc/2`
%% — the same shape the runtime codecs consume.

-type wire_type() ::
    {base, atom()}
    | {enum, [{integer(), atom()}]}
    | {list, wire_type()}
    | {set, wire_type(), list | sets | ordset}
    %% `containers/1' normalizes sets to the two-tuple shape.
    | {set, wire_type()}
    | {map, wire_type(), wire_type()}
    | {struct, {ref, module(), binary()}}.

%% A raw `erl_parse' tree (stdlib exports no type for them); the doc and
%% spec attributes and the returned form list stay syntax trees.

-type ast() :: tuple().

%%--------------------------------------------------------------------
%% Module assembly
%%--------------------------------------------------------------------

-doc "The `-export/1` entries of the wire codecs: `binary_codec/1` plus one pair per struct.".
-spec export_entries(#tg_module{}, #ectx{}) -> [{atom(), arity()}].
export_entries(Mod, Ctx) ->
    [{binary_codec, 1}] ++
        lists:append([
            [{Encode, 1}, {Decode, 1}]
         || {Encode, Decode} <- [wire_pair(S, Ctx) || S <- Mod#tg_module.structs]
        ]).

-doc "Every wire-codec form of the module: per-struct encode/decode functions, container helpers, `binary_codec/1`.".
-spec module_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
module_forms(Mod, Ctx) ->
    WireTypes = [wtype(F#tg_field.type, Ctx) || S <- Mod#tg_module.structs, F <- S#tg_struct.fields],
    Enums = enum_registry(WireTypes, #{}),
    lists:append([
        [
            thrift_generator_emitter_syntax:section_form(
                io_lib:format("~s wire codecs", [thrift_generator_emitter:section_label(S)])
            )
        ] ++
            struct_forms(S, Ctx, Enums)
     || S <- Mod#tg_module.structs
    ]) ++
        helper_forms(WireTypes, Ctx, Enums) ++
        binary_codec_forms(Mod, Ctx).

%% Distinct inline enum descriptors of the module, numbered by first
%% appearance: a wire `{enum, _}` descriptor carries no IDL name and the
%% private helpers need one for their rendered names.

-spec enum_registry([wire_type()], #{integer() => pos_integer()}) -> #{integer() => pos_integer()}.
enum_registry([], Acc) ->
    Acc;
enum_registry([{enum, Desc} | Rest], Acc) ->
    Key = erlang:phash2(Desc),
    case Acc of
        #{Key := _} -> enum_registry(Rest, Acc);
        _ -> enum_registry(Rest, Acc#{Key => map_size(Acc) + 1})
    end;
enum_registry([T | Rest], Acc) ->
    enum_registry(children(T) ++ Rest, Acc).

-spec children(wire_type()) -> [wire_type()].
children({list, T}) -> [T];
children({set, T, _Impl}) -> [T];
children({map, K, V}) -> [K, V];
children(_) -> [].

%%--------------------------------------------------------------------
%% Names
%%--------------------------------------------------------------------

-spec wire_pair(#tg_struct{} | binary(), #ectx{}) -> {atom(), atom()}.
wire_pair(#tg_struct{name = Name}, Ctx) ->
    wire_pair(Name, Ctx);
wire_pair(Name, Ctx) when is_binary(Name) ->
    Prefix = typed_prefix(current_prefix(Ctx), thrift_generator_names:snake(Name)),
    {
        binary_to_atom(<<"encode_", Prefix/binary, "_wire">>, utf8),
        binary_to_atom(<<"decode_", Prefix/binary, "_wire">>, utf8)
    }.

-spec struct_wire_pair(binary(), #ectx{}) -> {atom(), atom()}.
struct_wire_pair(Name, Ctx) ->
    wire_pair(Name, Ctx).

-spec typed_prefix(binary(), binary()) -> binary().
typed_prefix(<<>>, Name) ->
    Name;
typed_prefix(Prefix, Name) ->
    <<Prefix/binary, "_", Name/binary>>.

-spec current_prefix(#ectx{}) -> binary().
current_prefix(Ctx) ->
    (maps:get(Ctx#ectx.current, Ctx#ectx.modules))#tg_module.prefix.

%% Helper names render from the type structure; enum descriptors render
%% by their registry index, cross-module struct references qualify with
%% the target module tag — collision-free within the module.

-spec type_name(wire_type(), #{integer() => pos_integer()}) -> binary().
type_name({base, B}, _Enums) ->
    atom_to_binary(B, utf8);
type_name({enum, Desc}, Enums) ->
    <<"enum", (integer_to_binary(maps:get(erlang:phash2(Desc), Enums)))/binary>>;
type_name({list, T}, Enums) ->
    <<"list_", (type_name(T, Enums))/binary>>;
type_name({set, T, _Impl}, Enums) ->
    type_name({set, T}, Enums);
type_name({set, T}, Enums) ->
    <<"set_", (type_name(T, Enums))/binary>>;
type_name({map, K, V}, Enums) ->
    <<"map_", (type_name(K, Enums))/binary, "_", (type_name(V, Enums))/binary>>;
type_name({struct, {ref, TypesMod, Local}}, _Enums) ->
    <<(module_tag(TypesMod))/binary, "_", (thrift_generator_names:snake(Local))/binary>>.

-spec module_tag(module()) -> binary().
module_tag(TypesMod) ->
    binary:replace(atom_to_binary(TypesMod, utf8), <<"_types">>, <<>>).

-spec enc_name(wire_type(), #{integer() => pos_integer()}) -> atom().
enc_name(T, Enums) ->
    binary_to_atom(<<"enc_", (type_name(T, Enums))/binary>>, utf8).

-spec dec_name(wire_type(), #{integer() => pos_integer()}) -> atom().
dec_name(T, Enums) ->
    binary_to_atom(<<"dec_", (type_name(T, Enums))/binary>>, utf8).

%%--------------------------------------------------------------------
%% Per-struct blocks
%%--------------------------------------------------------------------

-spec struct_forms(#tg_struct{}, #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
struct_forms(S, Ctx, Enums) ->
    {Encode, Decode} = wire_pair(S, Ctx),
    FieldTypes = [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields],
    encode_forms(S, Encode, FieldTypes, Ctx, Enums) ++
        decode_forms(S, Decode, FieldTypes, Ctx, Enums).

%% Encode side: entry clauses (map guard, required/union check) plus a
%% chain of per-field functions assembling iodata forward — the same
%% difference-list shape the generic engine's encode_fields_c walks.

-spec encode_forms(#tg_struct{}, atom(), [wire_type()], #ectx{}, #{integer() => pos_integer()}) ->
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
            union -> union_check(S#tg_struct.fields, Entry);
            _ -> required_check(S#tg_struct.fields, Entry)
        end,
    Doc =
        <<
            "Encodes the wire representation (a map keyed by binary field"
            " names) with the binary protocol, byte-compatible with"
            " thrift_erl_binary:encode/2."
        >>,
    thrift_generator_emitter_syntax:doc_form(S#tg_struct.doc, Doc) ++
        [
            spec_form(Encode, 1, [t_fun([t_map_exact()], t_union([t_ok(t_atom(iodata)), t_error()]))]),
            {function, ?ANNO, Encode, 1, [encode_entry_clause(CheckBody), encode_error_clause()]}
        ] ++ chain_forms(Chain, lists:zip(S#tg_struct.fields, FieldTypes), Ctx, Enums, 1).

-spec encode_entry_clause(ast()) -> ast().
encode_entry_clause(CheckBody) ->
    clause([v("Value")], [remote(erlang, is_map, [v("Value")])], [CheckBody]).

-spec encode_error_clause() -> ast().
encode_error_clause() ->
    clause([v("Value")], none, [err_encode(mismatch(v("Value")))]).

%% The union check counts present fields by name (declaration order);
%% the required check collects the missing names in declaration order —
%% both mirror check_present_fields of the generic engine.

-spec union_check([#tg_field{}], atom()) -> ast().
union_check(Fields, Chain) ->
    Names = [name_lit(F#tg_field.name) || F <- Fields],
    'case'(
        lc(v("N"), [{generate, ?ANNO, v("N"), list_lit(Names)}, key_filter(v("N"), v("Value"), true)]),
        [
            clause([cons(v("_"), nil())], none, [call_local(Chain, [v("Value")])]),
            clause([nil()], none, [err_encode(at(union_empty))]),
            clause([v("_")], none, [err_encode(at(union_multiple))])
        ]
    ).

-spec required_check([#tg_field{}], atom()) -> ast().
required_check(Fields, Chain) ->
    Required = [F || F <- Fields, F#tg_field.required =:= required],
    Names = [name_lit(F#tg_field.name) || F <- Required],
    'case'(
        lc(v("N"), [{generate, ?ANNO, v("N"), list_lit(Names)}, key_filter(v("N"), v("Value"), false)]),
        [
            clause([nil()], none, [call_local(Chain, [v("Value")])]),
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

%% One function per field, declaration order: field K encodes its value
%% (when present) and conses its header chunk in front of the encoding
%% of the remaining fields; absent fields fall through to the next
%% function and the last one closes with the stop byte.

-spec chain_forms(
    atom(), [{#tg_field{}, wire_type()}], #ectx{}, #{integer() => pos_integer()}, pos_integer()
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
    atom(), [{#tg_field{}, wire_type()}], #ectx{}, #{integer() => pos_integer()}, pos_integer()
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
    atom(), pos_integer(), #tg_field{}, wire_type(), ast(), #ectx{}, #{integer() => pos_integer()}
) ->
    ast().
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

-spec chain_fn_name(atom(), pos_integer()) -> atom().
chain_fn_name(Chain, N) ->
    atom_concat(Chain, <<"_f", (integer_to_binary(N))/binary>>).

%%--------------------------------------------------------------------
%% Decode side
%%--------------------------------------------------------------------

-spec decode_forms(#tg_struct{}, atom(), [wire_type()], #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
decode_forms(S, Decode, FieldTypes, Ctx, Enums) ->
    Fields = S#tg_struct.fields,
    FieldsName = atom_concat(Decode, <<"_fields">>),
    Required =
        lists:keysort(
            1,
            [
                {F#tg_field.id, F#tg_field.name}
             || {F, _T} <- lists:zip(Fields, FieldTypes),
                F#tg_field.required =:= required
            ]
        ),
    Doc =
        <<
            "Decodes the binary protocol into the wire representation,"
            " byte-compatible with thrift_erl_binary:decode/2; `more` on"
            " truncated input, unknown field ids skipped by wire type."
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
            {function, ?ANNO, Decode, 1, [
                clause([v("Binary")], [remote(erlang, is_binary, [v("Binary")])], [
                    call_local(FieldsName, [v("Binary"), required_lit(Required), map_empty()])
                ])
            ]},
            {function, ?ANNO, FieldsName, 3,
                decode_field_clauses(lists:zip(Fields, FieldTypes), FieldsName, Ctx, Enums)}
        ].

%% Stop byte closes the struct (missing required fields in ascending id
%% order, matching the generic engine's required map); the header clause
%% matches by field id with the wire byte folded into the guard; the
%% tail clause asks for more bytes.

-spec decode_field_clauses([{#tg_field{}, wire_type()}], atom(), #ectx{}, #{integer() => pos_integer()}) ->
    [ast()].
decode_field_clauses(FieldPairs, FieldsName, Ctx, Enums) ->
    Required = [F || {F, _T} <- FieldPairs, F#tg_field.required =:= required],
    StopClause =
        case Required of
            %% No required fields: the stop byte just closes the struct,
            %% without the missing-fields scan.
            [] ->
                clause(
                    [bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]), v("_Req"), v("Acc")],
                    none,
                    [ok3(v("Acc"), v("Rest"))]
                );
            _ ->
                clause(
                    [bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]), v("Req"), v("Acc")],
                    none,
                    [
                        'case'(
                            lc(
                                v("N"),
                                [
                                    {generate, ?ANNO, tuple_pat([v("_"), v("N")]), v("Req")},
                                    key_filter(v("N"), v("Acc"), false)
                                ]
                            ),
                            [
                                clause([nil()], none, [ok3(v("Acc"), v("Rest"))]),
                                clause([v("Missing")], none, [
                                    err_decode(tuple_t([at(missing_required_fields), v("Missing")]))
                                ])
                            ]
                        )
                    ]
                )
        end,
    HeaderClause =
        clause([header_pat(), v("Req"), v("Acc")], none, [
            'case'(
                v("Id"),
                field_clauses(FieldPairs, FieldsName, Ctx, Enums) ++ [skip_clause(FieldsName)]
            )
        ]),
    MoreClause =
        clause(
            [v("Bin"), v("_Req"), v("_Acc")],
            [{op, ?ANNO, '<', call_local(byte_size, [v("Bin")]), i(3)}],
            [at(more)]
        ),
    [StopClause, HeaderClause, MoreClause].

-spec field_clauses([{#tg_field{}, wire_type()}], atom(), #ectx{}, #{integer() => pos_integer()}) ->
    [ast()].
field_clauses(FieldPairs, FieldsName, Ctx, Enums) ->
    lists:append([
        field_clauses_one(F, T, FieldsName, Ctx, Enums)
     || {F, T} <- FieldPairs
    ]).

%% Two clauses per known id: the right wire type decodes and recurses, a
%% wrong one is a field_type_mismatch — the generic engine's three-way
%% by_id match split by construction.

-spec field_clauses_one(#tg_field{}, wire_type(), atom(), #ectx{}, #{integer() => pos_integer()}) ->
    [ast()].
field_clauses_one(F, T, FieldsName, Ctx, Enums) ->
    Id = F#tg_field.id,
    Wire = wire_byte(T),
    %% Only required fields need dropping from the remaining-required
    %% list — optional and default fields recurse with it unchanged.
    ReqExpr =
        case F#tg_field.required of
            required ->
                remote(lists, keydelete, [i(Id), i(1), v("Req")]);
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
        'case'(remote(thrift_erl_binary, skip_by_wire, [v("Type"), v("Rest")]), [
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
%% Both work on wire descriptors — struct fields and container elements
%% share them.

%% Suffixing the inline case variables (Dbl, Int, Vd, Rd) keeps sibling
%% inline cases — the map pair's key and value decodes — from rebinding
%% the same names, which erl_lint reports as unsafe variables.

-spec encode_wire_expr(wire_type(), ast(), #ectx{} | undefined, #{integer() => pos_integer()}, string()) -> ast().
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
struct_encode_call(TypesMod, Local, V, Ctx) when TypesMod =:= Ctx#ectx.current ->
    {Encode, _Decode} = struct_wire_pair(Local, Ctx),
    call_local(Encode, [V]);
struct_encode_call(TypesMod, Local, V, _Ctx) ->
    remote(thrift_erl_binary, encode, [literal({struct, {ref, TypesMod, Local}}), V]).

-spec struct_decode_call(module(), binary(), ast(), #ectx{}) -> ast().
struct_decode_call(TypesMod, Local, Bin, Ctx) when TypesMod =:= Ctx#ectx.current ->
    {_Encode, Decode} = struct_wire_pair(Local, Ctx),
    call_local(Decode, [Bin]);
struct_decode_call(TypesMod, Local, Bin, _Ctx) ->
    remote(thrift_erl_binary, decode, [literal({struct, {ref, TypesMod, Local}}), Bin]).

-spec decode_wire_expr(wire_type(), ast(), #ectx{} | undefined, #{integer() => pos_integer()}, string()) -> ast().
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

-spec helper_forms([wire_type()], #ectx{}, #{integer() => pos_integer()}) -> erl_syntax:forms().
helper_forms(WireTypes, Ctx, Enums) ->
    Containers = lists:usort(lists:append([containers(T) || T <- WireTypes])),
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

-spec containers(wire_type()) -> [wire_type()].
containers({list, T}) -> [{list, T} | containers(T)];
containers({set, T, _Impl}) -> [{set, T} | containers(T)];
containers({map, K, V}) -> [{map, K, V} | containers(K) ++ containers(V)];
containers(_) -> [].

-spec elem_type({list, wire_type()} | {set, wire_type()}) -> wire_type().
elem_type({list, T}) -> T;
elem_type({set, T}) -> T.

-spec container_forms(wire_type(), #ectx{}, #{integer() => pos_integer()}) -> erl_syntax:forms().
container_forms({Kind, _} = T, Ctx, Enums) when Kind =:= list; Kind =:= set ->
    %% The container header carries the ELEMENT's wire byte; the
    %% container's own byte only appears in the field header.
    Wire = wire_byte(elem_type(T)),
    Enc = enc_name(T, Enums),
    Dec = dec_name(T, Enums),
    Elem = elem_type(T),
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

-spec encode_elem_expr(wire_type(), ast(), #ectx{}, #{integer() => pos_integer()}, string()) -> ast().
encode_elem_expr({base, B}, V, _Ctx, _Enums, Suffix) ->
    encode_base_expr(B, V, Suffix);
encode_elem_expr({enum, _} = T, V, _Ctx, _Enums, Suffix) ->
    encode_wire_expr(T, V, undefined, #{}, Suffix);
encode_elem_expr({struct, {ref, TypesMod, Local}}, V, Ctx, _Enums, _Suffix) ->
    struct_encode_call(TypesMod, Local, V, Ctx);
encode_elem_expr(T, V, _Ctx, Enums, _Suffix) ->
    call_local(enc_name(T, Enums), [V]).

-spec decode_elem_expr(wire_type(), ast(), #ectx{}, #{integer() => pos_integer()}, string()) -> ast().
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
%% binary_codec/1
%%--------------------------------------------------------------------

-spec binary_codec_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
binary_codec_forms(Mod, Ctx) ->
    Clauses =
        [
            clause([name_lit(S#tg_struct.name)], none, [
                tuple_t([
                    at(ok),
                    tuple_t([
                        {'fun', ?ANNO, {function, Encode, 1}},
                        {'fun', ?ANNO, {function, Decode, 1}}
                    ])
                ])
            ])
         || {S, {Encode, Decode}} <- [{S, wire_pair(S, Ctx)} || S <- Mod#tg_module.structs]
        ] ++ [clause([v("_")], none, [at(error)])],
    Doc =
        <<
            "The binary-protocol wire codecs of this module's structs, by wire"
            " struct name: `{ok, {Encode, Decode}}' where `Encode/1` takes the"
            " wire map to `{ok, iodata()} | {error, _}' and `Decode/1` takes a"
            " binary to `{ok, WireMap, Rest} | more | {error, _}' -- the same"
            " contracts as `thrift_erl_binary:encode/2` and `decode/2'."
            " Unknown names answer `error'; `thrift_erl_binary' probes this"
            " export to dispatch named-struct references to the specialized"
            " code."
        >>,
    thrift_generator_emitter_syntax:doc_form(undefined, Doc) ++
        [
            spec_form(binary_codec, 1, [
                t_fun(
                    [t_atom(binary)],
                    t_union([
                        t_ok(tuple_t_type([t_atom('fun'), t_atom('fun')])),
                        t_atom_lit(error)
                    ])
                )
            ]),
            {function, ?ANNO, binary_codec, 1, Clauses}
        ].

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
    clause([v("Other")], none, [v("Other")]).

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

%% The 4-byte length header of a string segment, shared by the
%% dec_string clauses.

-spec len_pat() -> ast().
len_pat() ->
    bin_pat([{v("Len"), i(32), [big, signed]}, {v("_"), default, [binary]}]).

-spec bin_lit(binary()) -> ast().
bin_lit(Bin) ->
    {bin, ?ANNO, [{bin_element, ?ANNO, {string, ?ANNO, unicode:characters_to_list(Bin)}, default, default}]}.

-spec name_lit(binary()) -> ast().
name_lit(Bin) ->
    bin_lit(Bin).

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

-spec required_lit([{integer(), binary()}]) -> ast().
required_lit(Pairs) ->
    list_lit([tuple_t([i(Id), name_lit(Name)]) || {Id, Name} <- Pairs]).

-spec atom_concat(atom(), binary()) -> atom().
atom_concat(Atom, Suffix) ->
    binary_to_atom(<<(atom_to_binary(Atom, utf8))/binary, Suffix/binary>>, utf8).

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
