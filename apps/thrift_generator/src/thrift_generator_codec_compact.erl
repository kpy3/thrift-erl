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

-module(thrift_generator_codec_compact).

-moduledoc """
Specialized compact-protocol wire codecs emitted into `<mod>_types.erl`.

The compact sibling of `thrift_generator_codec` (the binary protocol):
for every struct, union and exception the module gets
`encode_<prefix>_compact/1` and `decode_<prefix>_compact/1` with the
same contracts as `thrift_erl_compact:encode/2` and `decode/2`, plus
the module-level `compact_codec/1` handing the pair out by wire struct
name. `thrift_erl_compact` probes that export whenever it meets a
`{struct, {ref, Module, Name}}` descriptor and dispatches to the
specialized code, falling back to its descriptor-driven engine for
modules without the export (hand-written descriptors, inline RPC
param/result structs).

The generated code preserves the generic engine's observable semantics
byte for byte: ULEB128 varints, zigzag for i16/i32/i64 and field ids,
little-endian doubles, field headers as type nibble + delta against the
last WRITTEN field id, boolean values riding in the header nibble with
no payload, collection sizes up to 14 in the header nibble, map pairs
sorted by encoded-key term order, `missing_required_fields` in
declaration order on encode and ascending field-id order on decode,
identical error terms, and `more` on every truncated input. Unknown
field ids are skipped by nibble through the runtime's
`thrift_erl_compact:skip_nibble/2`. The thrift_codec_test equivalence
properties pin all of this against the generic engine.

The `uuid` base type has no compact encoding: encoding through a uuid
field or element fails with the generic engine's
`{type_not_supported, {base, uuid}, compact}` and no uuid field nibble
ever matches on decode (a `field_type_mismatch`).

Nesting and naming follow the binary emitter: same-module struct
references become direct calls to the sibling functions, cross-module
references go through `thrift_erl_compact:encode/2` and `decode/2`;
containers get private `*_c` helpers named after the rendered element
type (the suffix keeps them clear of the binary codec's helpers emitted
into the same module); enum members are inlined as case clauses at
every use site. The varint/zigzag/header machinery is shared per module
and emitted only when something actually calls it.

Forms are built as raw `erl_parse` trees — patterns, binary segment
options and guards have no convenient `erl_syntax` constructors — so
`erl_pp` renders them; doc and spec attributes stay syntax trees like
everywhere else in the emitter.
""".

-export([export_entries/2, module_forms/2]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

%% The raw `erl_parse' vocabulary is shared with the binary codec
%% emitter; the compact-specific shapes (varints, nibble headers,
%% delta fields) stay local to this module.

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

-define(ANNO, erl_anno:new(0)).

%% The wire descriptor vocabulary of `thrift_generator_emitter:type_desc/2'
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

%% Module-level helper names and what each statically calls; the
%% usage-based emission closes over these edges so scalar-only modules
%% stay warning-free.

-define(HELPER_DEPS, #{
    enc_header => [enc_varint_z],
    enc_varint_z => [enc_varint],
    dec_varint_z => [dec_varint],
    coll_header => [enc_varint],
    dec_coll_header => [dec_varint],
    dec_string_c => [dec_varint]
}).

%% Emission order of the module helpers (dec_varint renders two forms,
%% one per arity).

-define(HELPERS, [
    enc_header, enc_varint, enc_varint_z, dec_varint, dec_varint_z, coll_header, dec_coll_header, dec_string_c
]).

%%--------------------------------------------------------------------
%% Module assembly
%%--------------------------------------------------------------------

-doc "The `-export/1` entries of the compact wire codecs: `compact_codec/1` plus one pair per struct.".
-spec export_entries(#tg_module{}, #ectx{}) -> [{atom(), arity()}].
export_entries(Mod, Ctx) ->
    [{compact_codec, 1}] ++
        lists:append([
            [{Encode, 1}, {Decode, 1}]
         || {Encode, Decode} <- [compact_pair(S, Ctx) || S <- Mod#tg_module.structs]
        ]).

-doc """
Every compact wire-codec form of the module: per-struct encode/decode
functions, container and varint helpers, `compact_codec/1`.
""".
-spec module_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
module_forms(Mod, Ctx) ->
    WireTypes = [wtype(F#tg_field.type, Ctx) || S <- Mod#tg_module.structs, F <- S#tg_struct.fields],
    Enums = thrift_generator_codec:enum_registry(WireTypes, #{}),
    Blocks = lists:append([
        [
            thrift_generator_emitter_syntax:section_form(
                io_lib:format("~s compact wire codecs", [thrift_generator_emitter:section_label(S)])
            )
        ] ++
            struct_forms(S, Ctx, Enums)
     || S <- Mod#tg_module.structs
    ]),
    Containers = lists:usort(
        lists:append([thrift_generator_codec:containers(T) || T <- WireTypes])
    ),
    ContainerForms = lists:append([container_forms(C, Ctx, Enums) || C <- Containers]),
    Codec = compact_codec_forms(Mod, Ctx),
    Blocks ++
        ContainerForms ++
        %% The varint/header/string helper set is derived from the calls
        %% the struct, container and codec forms actually make, closed
        %% over ?HELPER_DEPS — the same usage-based discipline as the
        %% binary emitter's dec_string.
        lists:append([
            helper_forms(Name)
         || Name <- ?HELPERS, lists:member(Name, used_helpers(Blocks ++ ContainerForms ++ Codec))
        ]) ++
        Codec.

-spec used_helpers(erl_syntax:forms()) -> [atom()].
used_helpers(Forms) ->
    closure(collect_calls(Forms)).

-spec collect_calls(erl_syntax:forms()) -> [atom()].
collect_calls(Forms) ->
    lists:append([walk(Form) || Form <- Forms]).

-spec walk(term()) -> [atom()].
walk({call, _, {atom, _, Name}, _}) ->
    [Name];
walk(Term) when is_tuple(Term) ->
    walk(tuple_to_list(Term));
walk(Term) when is_list(Term) ->
    lists:append([walk(Element) || Element <- Term]);
walk(_) ->
    [].

-spec closure([atom()]) -> [atom()].
closure(Used) ->
    New = lists:usort(lists:append([maps:get(Name, ?HELPER_DEPS, []) || Name <- Used])) -- Used,
    case New of
        [] ->
            Used;
        _ ->
            closure(Used ++ New)
    end.

%%--------------------------------------------------------------------
%% Names
%%--------------------------------------------------------------------

-spec compact_pair(#tg_struct{} | binary(), #ectx{}) -> {atom(), atom()}.
compact_pair(#tg_struct{name = Name}, Ctx) ->
    compact_pair(Name, Ctx);
compact_pair(Name, Ctx) when is_binary(Name) ->
    Prefix = thrift_generator_codec:typed_prefix(
        thrift_generator_codec:current_prefix(Ctx), thrift_generator_names:snake(Name)
    ),
    {
        binary_to_atom(<<"encode_", Prefix/binary, "_compact">>, utf8),
        binary_to_atom(<<"decode_", Prefix/binary, "_compact">>, utf8)
    }.

-spec struct_compact_pair(binary(), #ectx{}) -> {atom(), atom()}.
struct_compact_pair(Name, Ctx) ->
    compact_pair(Name, Ctx).

-spec enc_name(wire_type(), #{integer() => pos_integer()}) -> atom().
enc_name(T, Enums) ->
    binary_to_atom(<<"enc_", (thrift_generator_codec:type_name(T, Enums))/binary, "_c">>, utf8).

-spec dec_name(wire_type(), #{integer() => pos_integer()}) -> atom().
dec_name(T, Enums) ->
    binary_to_atom(<<"dec_", (thrift_generator_codec:type_name(T, Enums))/binary, "_c">>, utf8).

%%--------------------------------------------------------------------
%% Per-struct blocks
%%--------------------------------------------------------------------

-spec struct_forms(#tg_struct{}, #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
struct_forms(S, Ctx, Enums) ->
    {Encode, Decode} = compact_pair(S, Ctx),
    FieldTypes = [wtype(F#tg_field.type, Ctx) || F <- S#tg_struct.fields],
    encode_forms(S, Encode, FieldTypes, Ctx, Enums) ++
        decode_forms(S, Decode, FieldTypes, Ctx, Enums).

%% Encode side: entry clauses (map guard, required/union check) plus a
%% chain of per-field functions assembling iodata forward. Each field
%% function carries the last WRITTEN field id so absent fields leave
%% the delta base untouched — the same walk as the generic engine's
%% encode_fields_k.

-spec encode_forms(#tg_struct{}, atom(), [wire_type()], #ectx{}, #{integer() => pos_integer()}) ->
    erl_syntax:forms().
encode_forms(S, Encode, FieldTypes, Ctx, Enums) ->
    Chain = atom_concat(Encode, <<"_fields">>),
    %% The checks hand off to the FIRST chain function with the initial
    %% last-written id 0; with no fields the chain name itself is the
    %% terminator that closes the struct.
    Entry =
        case S#tg_struct.fields of
            [] -> Chain;
            _ -> chain_fn_name(Chain, 1)
        end,
    CheckBody =
        case S#tg_struct.kind of
            union -> union_check(S#tg_struct.fields, call_local(Entry, [v("Value"), i(0)]));
            _ -> required_check(S#tg_struct.fields, call_local(Entry, [v("Value"), i(0)]))
        end,
    Doc =
        <<
            "Encodes the wire representation (a map keyed by binary field"
            " names) with the compact protocol, byte-compatible with"
            " thrift_erl_compact:encode/2."
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
    %% Zero fields: the chain name itself is the terminator.
    [
        {function, ?ANNO, Chain, 2, [
            clause([v("_Value"), v("_LastId")], none, [ok_t(list_lit([i(0)]))])
        ]}
    ];
chain_forms(Chain, Fields, Ctx, Enums, 1) when Fields =/= [] ->
    chain_fns(Chain, Fields, Ctx, Enums, 1).

%% The field functions proper: the last one closes the struct with the
%% stop byte inline, so no terminator function follows the chain. Each
%% field function makes TWO next calls: a present field hands its own id
%% over as the new delta base, an absent field leaves the incoming
%% LastId untouched.

-spec chain_fns(
    atom(), [{#tg_field{}, wire_type()}], #ectx{}, #{integer() => pos_integer()}, pos_integer()
) ->
    erl_syntax:forms().
chain_fns(_Chain, [], _Ctx, _Enums, _N) ->
    [];
chain_fns(Chain, [{F, T}], Ctx, Enums, N) ->
    [chain_fn(Chain, N, F, T, stop, Ctx, Enums)];
chain_fns(Chain, [{F, T} | Rest], Ctx, Enums, N) ->
    [chain_fn(Chain, N, F, T, {next, chain_fn_name(Chain, N + 1)}, Ctx, Enums)] ++
        chain_fns(Chain, Rest, Ctx, Enums, N + 1).

%% The two next steps of one field: (present-continuation, absent-continuation).

-spec next_calls({next, atom()} | stop, integer()) -> {ast(), ast()}.
next_calls(stop, _Id) ->
    {ok_t(list_lit([i(0)])), ok_t(list_lit([i(0)]))};
next_calls({next, Name}, Id) ->
    {call_local(Name, [v("Value"), i(Id)]), call_local(Name, [v("Value"), v("LastId")])}.

-spec chain_fn(
    atom(),
    pos_integer(),
    #tg_field{},
    wire_type(),
    {next, atom()} | stop,
    #ectx{} | undefined,
    #{integer() => pos_integer()}
) ->
    erl_syntax:forms().
chain_fn(Chain, N, F, {base, bool}, NextStep, _Ctx, _Enums) ->
    bool_chain_fn(Chain, N, F, NextStep);
chain_fn(Chain, N, F, {base, uuid}, NextStep, _Ctx, _Enums) ->
    chain_fn_uuid(Chain, N, F, NextStep);
chain_fn(Chain, N, F, T, NextStep, Ctx, Enums) ->
    Header = enc_header_call(F#tg_field.id, nibble(T)),
    {Present, Absent} = next_calls(NextStep, F#tg_field.id),
    Body =
        'case'(v("Value"), [
            clause([map_exact(name_lit(F#tg_field.name), v("V"))], none, [
                'case'(encode_compact_expr(T, v("V"), Ctx, Enums), [
                    clause([tuple_t([at(ok), v("E")])], none, [
                        'case'(Present, [
                            ok_bind_clause(
                                v("Rest"), ok_t(cons(list_lit([Header, v("E")]), v("Rest")))
                            ),
                            error_clause()
                        ])
                    ]),
                    error_clause()
                ])
            ]),
            clause([v("_")], none, [Absent])
        ]),
    {function, ?ANNO, chain_fn_name(Chain, N), 2, [clause([v("Value"), v("LastId")], none, [Body])]}.

%% A uuid field's encode is the constant `type_not_supported' error —
%% the link returns it as soon as the field is present (the generic
%% engine's fields loop stops at the first error), and falls through
%% when absent. The map binding stays underscored: the value never
%% reaches an expression.

-spec chain_fn_uuid(
    atom(), pos_integer(), #tg_field{}, {next, atom()} | stop
) ->
    erl_syntax:forms().
chain_fn_uuid(Chain, N, F, NextStep) ->
    {_Present, Absent} = next_calls(NextStep, F#tg_field.id),
    %% A last-link uuid reads neither the value nor the delta base: the
    %% present path is the constant error and the absent path is the
    %% stop — both bindings stay underscored there.
    LastPattern =
        case NextStep of
            stop -> v("_LastId");
            {next, _} -> v("LastId")
        end,
    Body =
        'case'(v("Value"), [
            clause([map_exact(name_lit(F#tg_field.name), v("_V"))], none, [
                err_encode(tuple_t([at(type_not_supported), tuple_t([at(base), at(uuid)]), at(compact)]))
            ]),
            clause([v("_")], none, [Absent])
        ]),
    {function, ?ANNO, chain_fn_name(Chain, N), 2, [clause([v("Value"), LastPattern], none, [Body])]}.

%% A boolean field's value rides in the header nibble: no payload, the
%% header helper takes the nibble from the value, and a non-boolean
%% value fails before the rest of the struct is encoded — the generic
%% engine's bool_nibble check rendered as case clauses.

-spec bool_chain_fn(atom(), pos_integer(), #tg_field{}, {next, atom()} | stop) -> erl_syntax:forms().
bool_chain_fn(Chain, N, F, NextStep) ->
    {Present, Absent} = next_calls(NextStep, F#tg_field.id),
    Body =
        'case'(v("Value"), [
            clause([map_exact(name_lit(F#tg_field.name), v("V"))], none, [
                'case'(v("V"), [
                    clause([at(true)], none, [nibble_next(Present, F#tg_field.id, 16#01)]),
                    clause([at(false)], none, [nibble_next(Present, F#tg_field.id, 16#02)]),
                    clause([v("_")], none, [err_encode(mismatch(v("V")))])
                ])
            ]),
            clause([v("_")], none, [Absent])
        ]),
    {function, ?ANNO, chain_fn_name(Chain, N), 2, [clause([v("Value"), v("LastId")], none, [Body])]}.

-spec nibble_next(ast(), integer(), non_neg_integer()) -> ast().
nibble_next(Next, Id, Nibble) ->
    'case'(Next, [
        ok_bind_clause(v("Rest"), ok_t(cons(enc_header_call(Id, Nibble), v("Rest")))),
        error_clause()
    ]).

-spec enc_header_call(integer(), non_neg_integer()) -> ast().
enc_header_call(Id, Nibble) ->
    call_local(enc_header, [i(Id), v("LastId"), i(Nibble)]).

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
    FieldsLoop = atom_concat(Decode, <<"_fields">>),
    FieldDispatch = atom_concat(Decode, <<"_field">>),
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
            "Decodes the compact protocol into the wire representation,"
            " byte-compatible with thrift_erl_compact:decode/2; `more` on"
            " truncated input, unknown field ids skipped by nibble."
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
                    call_local(FieldsLoop, [v("Binary"), required_map_lit(Required), map_empty(), i(0)])
                ])
            ]},
            {function, ?ANNO, FieldsLoop, 4, loop_clauses(Required, FieldDispatch)},
            {function, ?ANNO, FieldDispatch, 5, dispatch_clauses(lists:zip(Fields, FieldTypes), FieldsLoop, Ctx, Enums)}
        ].

%% The required map mirrors the generic engine's compiled struct: ids to
%% names, `maps:remove/2` marks a seen field, `maps:values/1` at the
%% stop byte reports the missing names.

-spec required_map_lit([{integer(), binary()}]) -> ast().
required_map_lit(Required) ->
    %% One flat literal: a folded map_put over #{} renders as
    %% `(#{})#{3 => ...}` and the compiler warns on updating a literal.
    {map, ?ANNO, [{map_field_assoc, ?ANNO, i(Id), name_lit(Name)} || {Id, Name} <- Required]}.

-spec loop_clauses([{integer(), binary()}], atom()) -> [ast()].
loop_clauses(Required, FieldDispatch) ->
    StopClause =
        case Required of
            %% No required fields: the stop byte just closes the struct,
            %% without the missing-fields scan.
            [] ->
                clause(
                    [
                        bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]),
                        v("_Req"),
                        v("Acc"),
                        v("_LastId")
                    ],
                    none,
                    [ok3(v("Acc"), v("Rest"))]
                );
            _ ->
                clause(
                    [
                        bin_pat([{i(0), default, default}, {v("Rest"), default, [binary]}]),
                        v("Req"),
                        v("Acc"),
                        v("_LastId")
                    ],
                    none,
                    [
                        'case'(remote(maps, values, [v("Req")]), [
                            clause([nil()], none, [ok3(v("Acc"), v("Rest"))]),
                            clause([v("Missing")], none, [
                                err_decode(tuple_t([at(missing_required_fields), v("Missing")]))
                            ])
                        ])
                    ]
                )
        end,
    HeaderClause =
        clause(
            [
                bin_pat([{v("Header"), i(8), [big, unsigned]}, {v("Rest"), default, [binary]}]),
                v("Req"),
                v("Acc"),
                v("LastId")
            ],
            none,
            [
                {match, ?ANNO, v("Nibble"), {op, ?ANNO, 'band', v("Header"), i(16#0F)}},
                'case'({op, ?ANNO, 'bsr', v("Header"), i(4)}, [
                    %% High nibble zero: the id travels as a zigzag varint.
                    clause([i(0)], none, [
                        'case'(call_local(dec_varint_z, [v("Rest")]), [
                            ok3_bind_clause(
                                v("Id"),
                                v("Rest1"),
                                call_local(FieldDispatch, [v("Id"), v("Nibble"), v("Rest1"), v("Req"), v("Acc")])
                            ),
                            other_tail()
                        ])
                    ]),
                    clause([v("Delta")], none, [
                        call_local(FieldDispatch, [
                            {op, ?ANNO, '+', v("LastId"), v("Delta")},
                            v("Nibble"),
                            v("Rest"),
                            v("Req"),
                            v("Acc")
                        ])
                    ])
                ])
            ]
        ),
    MoreClause =
        clause(
            [v("Bin"), v("_Req"), v("_Acc"), v("_LastId")],
            [{op, ?ANNO, '<', call_local(byte_size, [v("Bin")]), i(1)}],
            [at(more)]
        ),
    [StopClause, HeaderClause, MoreClause].

%% The dispatch is reached for every header: known ids match dedicated
%% clause pairs, unknown ones skip by nibble. Known fields pass their
%% own id as the new delta base — the generic engine's LastId = Id at
%% every decode_field_k call.

-spec dispatch_clauses([{#tg_field{}, wire_type()}], atom(), #ectx{}, #{integer() => pos_integer()}) ->
    [ast()].
dispatch_clauses(FieldPairs, FieldsLoop, Ctx, Enums) ->
    lists:append([field_clauses_one(F, T, FieldsLoop, Ctx, Enums) || {F, T} <- FieldPairs]) ++
        [skip_clause(FieldsLoop)].

%% Two clauses per known id: the right nibble decodes and recurses (a
%% wrong one is a field_type_mismatch), a uuid field never matches at
%% all — the generic engine's three-way by_id match split by
%% construction.

-spec field_clauses_one(#tg_field{}, wire_type(), atom(), #ectx{}, #{integer() => pos_integer()}) ->
    [ast()].
field_clauses_one(F, {base, uuid}, _FieldsLoop, _Ctx, _Enums) ->
    [mismatch_clause(F#tg_field.id)];
field_clauses_one(F, {base, bool}, FieldsLoop, _Ctx, _Enums) ->
    Id = F#tg_field.id,
    [
        clause(
            [i(Id), v("Nibble"), v("Bin"), v("Req"), v("Acc")],
            [
                {op, ?ANNO, 'orelse', {op, ?ANNO, '=:=', v("Nibble"), i(16#01)},
                    {op, ?ANNO, '=:=', v("Nibble"), i(16#02)}}
            ],
            [
                call_local(FieldsLoop, [
                    v("Bin"),
                    req_expr(F),
                    map_put(
                        v("Acc"),
                        name_lit(F#tg_field.name),
                        {op, ?ANNO, '=:=', v("Nibble"), i(16#01)}
                    ),
                    i(Id)
                ])
            ]
        ),
        mismatch_clause(Id)
    ];
field_clauses_one(F, T, FieldsLoop, Ctx, Enums) ->
    Id = F#tg_field.id,
    [
        clause(
            [i(Id), v("Nibble"), v("Bin"), v("Req"), v("Acc")],
            [{op, ?ANNO, '=:=', v("Nibble"), i(nibble(T))}],
            [
                'case'(decode_compact_expr(T, v("Bin"), Ctx, Enums, ""), [
                    ok3_bind_clause(
                        v("V"),
                        v("Rest"),
                        call_local(FieldsLoop, [
                            v("Rest"),
                            req_expr(F),
                            map_put(v("Acc"), name_lit(F#tg_field.name), v("V")),
                            i(Id)
                        ])
                    ),
                    clause([at(more)], none, [at(more)]),
                    error_clause()
                ])
            ]
        ),
        mismatch_clause(Id)
    ].

-spec mismatch_clause(integer()) -> ast().
mismatch_clause(Id) ->
    clause([i(Id), v("_Nibble"), v("_Bin"), v("_Req"), v("_Acc")], none, [
        err_decode(tuple_t([at(field_type_mismatch), i(Id)]))
    ]).

%% Only required fields need dropping from the remaining-required map —
%% optional and default fields recurse with it unchanged.

-spec req_expr(#tg_field{}) -> ast().
req_expr(#tg_field{required = required, id = Id}) ->
    remote(maps, remove, [i(Id), v("Req")]);
req_expr(_F) ->
    v("Req").

-spec skip_clause(atom()) -> ast().
skip_clause(FieldsLoop) ->
    clause([v("Id"), v("Nibble"), v("Bin"), v("Req"), v("Acc")], none, [
        'case'(remote(thrift_erl_compact, skip_nibble, [v("Nibble"), v("Bin")]), [
            ok_bind_clause(v("Rest"), call_local(FieldsLoop, [v("Rest"), v("Req"), v("Acc"), v("Id")])),
            clause([at(more)], none, [at(more)]),
            error_clause()
        ])
    ]).

%%--------------------------------------------------------------------
%% Wire-type encode/decode expressions
%%--------------------------------------------------------------------

%% Encode expressions: {ok, iodata()} | {error, _}, byte-identical to
%% the generic engine's encode_k/2 clauses. Decode expressions:
%% {ok, Value, Rest} | more | {error, _}, byte-identical to decode_k/2.
%% Both work on wire descriptors — struct fields and container elements
%% share them. Encodes bind nothing (the case variables are the outer
%% value); decodes suffix their inline variables ("Vd", "Rd", "Int",
%% "R", catch-all "Other") so nested cases — a map pair's key and value
%% decodes, an element case inside the loop case that consumes it —
%% never rebind each other's names, which erl_lint reports as unsafe
%% variables. The consuming loop and pair cases answer with their own
%% fresh names ("OtherLoop", "OtherPairK", "OtherPairV").

-spec encode_compact_expr(wire_type(), ast(), #ectx{} | undefined, #{integer() => pos_integer()}) -> ast().
encode_compact_expr({base, bool}, V, _Ctx, _Enums) ->
    'case'(V, [
        clause([at(true)], none, [ok_t(bin_seg(i(16#01), i(8), [big, unsigned]))]),
        clause([at(false)], none, [ok_t(bin_seg(i(16#02), i(8), [big, unsigned]))]),
        mismatch_tail(V)
    ]);
encode_compact_expr({base, i8}, V, _Ctx, _Enums) ->
    'case'(V, [
        clause(
            [v("_")],
            [
                remote(erlang, is_integer, [V]),
                {op, ?ANNO, '>=', V, i(-128)},
                {op, ?ANNO, '=<', V, i(127)}
            ],
            [ok_t(bin_seg(V, i(8), [big, signed]))]
        ),
        clause([v("_")], none, [err_encode(mismatch(V))])
    ]);
encode_compact_expr({base, B}, V, _Ctx, _Enums) when B =:= i16; B =:= i32; B =:= i64 ->
    'case'(V, [
        clause(
            [v("_")],
            [
                remote(erlang, is_integer, [V]),
                {op, ?ANNO, '>=', V, i(-(1 bsl (bits(B) - 1)))},
                {op, ?ANNO, '=<', V, i((1 bsl (bits(B) - 1)) - 1)}
            ],
            [ok_t(call_local(enc_varint_z, [V]))]
        ),
        clause([v("_")], none, [err_encode(mismatch(V))])
    ]);
encode_compact_expr({base, double}, V, _Ctx, _Enums) ->
    'case'(V, [
        clause([v("_")], [remote(erlang, is_number, [V])], [
            ok_t(bin_seg(remote(erlang, float, [V]), i(64), [little, float]))
        ]),
        mismatch_tail(V)
    ]);
encode_compact_expr({base, S}, V, _Ctx, _Enums) when S =:= string; S =:= binary ->
    'case'(V, [
        clause([v("_")], [remote(erlang, is_binary, [V])], [
            ok_t(list_lit([call_local(enc_varint, [call_local(byte_size, [V])]), V]))
        ]),
        mismatch_tail(V)
    ]);
encode_compact_expr({base, uuid}, _V, _Ctx, _Enums) ->
    err_encode(tuple_t([at(type_not_supported), tuple_t([at(base), at(uuid)]), at(compact)]));
encode_compact_expr({enum, Desc}, V, _Ctx, _Enums) ->
    'case'(
        V,
        [
            clause([at(Atom)], none, [ok_t(call_local(enc_varint_z, [i(Value)]))])
         || {Value, Atom} <- Desc
        ] ++
            [
                clause([v("_")], [remote(erlang, is_integer, [V])], [
                    ok_t(call_local(enc_varint_z, [V]))
                ]),
                clause([v("_")], [remote(erlang, is_atom, [V])], [
                    err_encode(tuple_t([at(unknown_enum_value), V]))
                ])
            ]
    );
encode_compact_expr({struct, {ref, TypesMod, Local}}, V, Ctx, _Enums) ->
    struct_encode_call(TypesMod, Local, V, Ctx);
encode_compact_expr({list, _} = T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]);
encode_compact_expr({set, _, _} = T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]);
encode_compact_expr({map, _, _} = T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]).

-spec encode_base_expr(atom(), ast()) -> ast().
encode_base_expr(B, V) ->
    encode_compact_expr({base, B}, V, undefined, #{}).

-spec struct_encode_call(module(), binary(), ast(), #ectx{}) -> ast().
struct_encode_call(TypesMod, Local, V, Ctx) when TypesMod =:= Ctx#ectx.current ->
    {Encode, _Decode} = struct_compact_pair(Local, Ctx),
    call_local(Encode, [V]);
struct_encode_call(TypesMod, Local, V, _Ctx) ->
    remote(thrift_erl_compact, encode, [literal({struct, {ref, TypesMod, Local}}), V]).

-spec struct_decode_call(module(), binary(), ast(), #ectx{}) -> ast().
struct_decode_call(TypesMod, Local, Bin, Ctx) when TypesMod =:= Ctx#ectx.current ->
    {_Encode, Decode} = struct_compact_pair(Local, Ctx),
    call_local(Decode, [Bin]);
struct_decode_call(TypesMod, Local, Bin, _Ctx) ->
    remote(thrift_erl_compact, decode, [literal({struct, {ref, TypesMod, Local}}), Bin]).

-spec decode_compact_expr(wire_type(), ast(), #ectx{} | undefined, #{integer() => pos_integer()}, string()) ->
    ast().
decode_compact_expr({base, bool}, Bin, _Ctx, _Enums, Suffix) ->
    R = v("R" ++ Suffix),
    'case'(Bin, [
        clause([bin_pat([{i(16#01), default, default}, {R, default, [binary]}])], none, [
            ok3(at(true), R)
        ]),
        clause([bin_pat([{i(16#02), default, default}, {R, default, [binary]}])], none, [
            ok3(at(false), R)
        ]),
        clause([bin_pat([{v("_"), default, default}, {v("_"), default, [binary]}])], none, [
            err_decode(at(bad_bool_value))
        ]),
        more_tail()
    ]);
decode_compact_expr({base, i8}, Bin, _Ctx, _Enums, Suffix) ->
    fixed_case(Bin, 8, [big, signed], Suffix);
decode_compact_expr({base, B}, Bin, _Ctx, _Enums, _Suffix) when B =:= i16; B =:= i32; B =:= i64 ->
    %% dec_varint_z already speaks the {ok, V, Rest} | more | {error, _}
    %% language — no binding case to wrap it in.
    call_local(dec_varint_z, [Bin]);
decode_compact_expr({base, double}, Bin, _Ctx, _Enums, Suffix) ->
    fixed_case(Bin, 64, [little, float], Suffix);
decode_compact_expr({base, S}, Bin, _Ctx, _Enums, _Suffix) when S =:= string; S =:= binary ->
    call_local(dec_string_c, [Bin]);
decode_compact_expr({base, uuid}, _Bin, _Ctx, _Enums, _Suffix) ->
    err_decode(tuple_t([at(type_not_supported), tuple_t([at(base), at(uuid)]), at(compact)]));
decode_compact_expr({enum, Desc}, Bin, _Ctx, _Enums, Suffix) ->
    Int = v("Int" ++ Suffix),
    R = v("R" ++ Suffix),
    'case'(call_local(dec_varint_z, [Bin]), [
        ok3_bind_clause(Int, R, 'case'(Int, enum_from_clauses(Desc, Int, R))),
        %% The catch-all participates in the suffix discipline: the case
        %% is inlined inside a consuming loop or pair case whose own
        %% catch-all carries a different name.
        other_clause("Other" ++ Suffix)
    ]);
decode_compact_expr({struct, {ref, TypesMod, Local}}, Bin, Ctx, _Enums, _Suffix) ->
    struct_decode_call(TypesMod, Local, Bin, Ctx);
decode_compact_expr({list, _} = T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]);
decode_compact_expr({set, _, _} = T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]);
decode_compact_expr({map, _, _} = T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]).

%% The fixed-size base decoder: a binary segment match or `more' —
%% never an error, exactly like the generic engine's i8/double clauses.

-spec fixed_case(ast(), non_neg_integer(), [atom()], string()) -> ast().
fixed_case(Bin, Bits, Types, Suffix) ->
    Vd = v("Vd" ++ Suffix),
    Rd = v("Rd" ++ Suffix),
    'case'(Bin, [
        clause([bin_pat([{Vd, i(Bits), Types}, {Rd, default, [binary]}])], none, [ok3(Vd, Rd)]),
        more_tail()
    ]).

-spec decode_base_expr(atom(), ast(), string()) -> ast().
decode_base_expr(B, Bin, Suffix) ->
    decode_compact_expr({base, B}, Bin, undefined, #{}, Suffix).

-spec enum_from_clauses([{integer(), atom()}], ast(), ast()) -> [ast()].
enum_from_clauses(Desc, Int, R) ->
    [
        clause([i(Value)], none, [ok3(at(Atom), R)])
     || {Value, Atom} <- Desc
    ] ++ [clause([v("_")], none, [ok3(Int, R)])].

%%--------------------------------------------------------------------
%% Container helpers
%%--------------------------------------------------------------------

-spec container_forms(wire_type(), #ectx{}, #{integer() => pos_integer()}) -> erl_syntax:forms().
container_forms({Kind, _} = T, Ctx, Enums) when Kind =:= list; Kind =:= set ->
    %% The container header carries the ELEMENT type nibble; the
    %% container's own nibble only appears in the field header. List
    %% and set share the wire format.
    Nib = nibble(thrift_generator_codec:elem_type(T)),
    Elem = thrift_generator_codec:elem_type(T),
    Enc = enc_name(T, Enums),
    Dec = dec_name(T, Enums),
    EncElems = atom_concat(Enc, <<"_elems">>),
    DecElems = atom_concat(Dec, <<"_elems">>),
    %% A direct uuid element never matches any header nibble in the
    %% generic engine (k_unsupported matches nothing), so the element
    %% loop would be unreachable code — not emitted at all.
    DecElemsForms =
        case Elem of
            {base, uuid} ->
                [];
            _ ->
                [
                    {function, ?ANNO, DecElems, 3, [
                        clause([i(0), v("Rest"), v("Acc")], none, [
                            ok3(remote(lists, reverse, [v("Acc")]), v("Rest"))
                        ]),
                        clause([v("N"), v("Bin"), v("Acc")], none, [
                            'case'(decode_elem_expr(Elem, v("Bin"), Ctx, Enums, ""), [
                                ok3_bind_clause(
                                    v("V"),
                                    v("Rest"),
                                    call_local(DecElems, [
                                        {op, ?ANNO, '-', v("N"), i(1)},
                                        v("Rest"),
                                        cons(v("V"), v("Acc"))
                                    ])
                                ),
                                other_clause("OtherLoop")
                            ])
                        ])
                    ]}
                ]
        end,
    [
        {function, ?ANNO, Enc, 1, [
            clause([v("Values")], [remote(erlang, is_list, [v("Values")])], [
                'case'(call_local(EncElems, [v("Values")]), [
                    ok_bind_clause(
                        v("Es"),
                        ok_t(
                            list_lit([
                                call_local(coll_header, [i(Nib), call_local(length, [v("Values")])]),
                                v("Es")
                            ])
                        )
                    ),
                    error_clause()
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, EncElems, 1,
            case Elem of
                {base, uuid} ->
                    %% The generic element loop fails on the first uuid
                    %% element before reading it; only the empty list
                    %% succeeds.
                    [
                        clause([nil()], none, [ok_t(nil())]),
                        uuid_error_clause(1)
                    ];
                _ ->
                    [
                        clause([nil()], none, [ok_t(nil())]),
                        clause([cons(v("V"), v("Rest"))], none, [
                            'case'(encode_elem_expr(Elem, v("V"), Ctx, Enums), [
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
                    ]
            end},
        {function, ?ANNO, Dec, 1, [
            clause([v("Bin")], none, [
                'case'(call_local(dec_coll_header, [v("Bin")]), [
                    %% A uuid element has no element loop, so the header
                    %% clause only reports the observed nibble — the size
                    %% and tail bindings stay underscored.
                    clause(
                        [tuple_t([at(ok), tuple_pat([v("Obs") | size_rest_pats(Elem)]), rest_pat(Elem)])],
                        none,
                        [
                            'case'(
                                v("Obs"),
                                elem_nibble_clauses(Nib, Elem, DecElems, v("Size"), v("Rest")) ++
                                    [
                                        clause([v("_")], none, [
                                            err_decode(tuple_t([at(element_type_mismatch), v("Obs")]))
                                        ])
                                    ]
                            )
                        ]
                    ),
                    other_tail()
                ])
            ])
        ]}
    ] ++ DecElemsForms;
container_forms({map, K, V} = T, Ctx, Enums) ->
    KeyNib = nibble(K),
    ValNib = nibble(V),
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
                'case'(call_local(map_size, [v("Value")]), [
                    %% An empty map is a single zero byte, no type byte.
                    clause([i(0)], none, [ok_t(bin_seg(i(0), i(8), [big, unsigned]))]),
                    clause([v("_")], none, [
                        'case'(call_local(EncPairs, [remote(maps, to_list, [v("Value")])]), [
                            clause([tuple_t([at(ok), v("Pairs")])], none, [
                                {match, ?ANNO, v("Sorted"), remote(lists, sort, [SortFun, v("Pairs")])},
                                ok_t(
                                    list_lit([
                                        list_lit([
                                            call_local(enc_varint, [call_local(map_size, [v("Value")])]),
                                            bin_seg(i((KeyNib bsl 4) bor ValNib), i(8), [big, unsigned])
                                        ]),
                                        pairs_lc()
                                    ])
                                )
                            ]),
                            error_clause()
                        ])
                    ])
                ])
            ]),
            mismatch_fn_tail()
        ]},
        {function, ?ANNO, EncPairs, 1,
            case {K, V} of
                {{base, uuid}, _} ->
                    %% The generic pair loop fails on the first uuid key
                    %% or value without reading either.
                    [clause([v("_Pairs")], none, [uuid_error()])];
                {_, {base, uuid}} ->
                    [clause([v("_Pairs")], none, [uuid_error()])];
                _ ->
                    [
                        clause([nil()], none, [ok_t(nil())]),
                        clause([cons(tuple_pat([v("K"), v("V")]), v("Rest"))], none, [
                            'case'(encode_elem_expr(K, v("K"), Ctx, Enums), [
                                ok_bind_clause(
                                    v("KE"),
                                    'case'(encode_elem_expr(V, v("V"), Ctx, Enums), [
                                        ok_bind_clause(
                                            v("VE"),
                                            'case'(call_local(EncPairs, [v("Rest")]), [
                                                ok_bind_clause(
                                                    v("RestPairs"),
                                                    ok_t(cons(tuple_t([v("KE"), v("VE")]), v("RestPairs")))
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
                    ]
            end},
        {function, ?ANNO, Dec, 1, [
            clause([v("Bin")], none, [
                'case'(call_local(dec_varint, [v("Bin")]), [
                    clause([tuple_t([at(ok), i(0), v("Rest")])], none, [ok3(map_empty(), v("Rest"))]),
                    clause(
                        [tuple_t([at(ok), v("_Size"), v("Rest")])],
                        [{op, ?ANNO, '=:=', call_local(byte_size, [v("Rest")]), i(0)}],
                        [at(more)]
                    ),
                    clause(
                        [
                            tuple_t([
                                at(ok),
                                v("Size"),
                                bin_pat([{v("Types"), i(8), [big, unsigned]}, {v("Rest"), default, [binary]}])
                            ])
                        ],
                        [{op, ?ANNO, '>', v("Size"), i(0)}],
                        [
                            'case'(
                                tuple_t([
                                    {op, ?ANNO, 'bsr', v("Types"), i(4)},
                                    {op, ?ANNO, 'band', v("Types"), i(16#0F)}
                                ]),
                                [
                                    clause([tuple_pat([i(KeyNib), i(ValNib)])], none, [
                                        call_local(DecPairs, [v("Size"), v("Rest"), map_empty()])
                                    ]),
                                    clause([v("_")], none, [err_decode(at(map_type_mismatch))])
                                ]
                            )
                        ]
                    ),
                    other_tail()
                ])
            ])
        ]},
        {function, ?ANNO, DecPairs, 3,
            case {K, V} of
                {{base, uuid}, _} ->
                    %% The first uuid key or value decode is the constant
                    %% error — the loop never reads or recurses.
                    [uuid_decode_error_clause(3)];
                {_, {base, uuid}} ->
                    [uuid_decode_error_clause(3)];
                _ ->
                    [
                        clause([i(0), v("Rest"), v("Acc")], none, [ok3(v("Acc"), v("Rest"))]),
                        clause([v("N"), v("Bin"), v("Acc")], none, [
                            'case'(decode_elem_expr(K, v("Bin"), Ctx, Enums, "K"), [
                                ok3_bind_clause(
                                    v("K"),
                                    v("Rest"),
                                    'case'(
                                        decode_elem_expr(V, v("Rest"), Ctx, Enums, "V"), [
                                            ok3_bind_clause(
                                                v("V"),
                                                v("Rest1"),
                                                call_local(DecPairs, [
                                                    {op, ?ANNO, '-', v("N"), i(1)},
                                                    v("Rest1"),
                                                    map_put(v("Acc"), v("K"), v("V"))
                                                ])
                                            ),
                                            other_clause("OtherPairV")
                                        ]
                                    )
                                ),
                                other_clause("OtherPairK")
                            ])
                        ])
                    ]
            end}
    ].

%% The element nibbles a collection header may carry for this element
%% type: a boolean element rides as one of the two cbool values, every
%% other type is exactly its nibble, and a direct uuid element matches
%% nothing (no clauses — the catch-all reports element_type_mismatch),
%% mirroring the generic engine's nibble_matches.

-spec elem_nibble_clauses(non_neg_integer(), wire_type(), atom(), ast(), ast()) -> [ast()].
elem_nibble_clauses(_Nib, {base, uuid}, _DecElems, _Size, _Rest) ->
    [];
elem_nibble_clauses(_Nib, {base, bool}, DecElems, Size, Rest) ->
    [
        clause([i(16#01)], none, [call_local(DecElems, [Size, Rest, nil()])]),
        clause([i(16#02)], none, [call_local(DecElems, [Size, Rest, nil()])])
    ];
elem_nibble_clauses(Nib, _Elem, DecElems, Size, Rest) ->
    [clause([i(Nib)], none, [call_local(DecElems, [Size, Rest, nil()])])].

%% The encoded pairs of a map, in wire order (the generic engine sorts
%% the ENCODED pairs by iodata term order, so the generated code does
%% the same).

-spec pairs_lc() -> ast().
pairs_lc() ->
    {lc, ?ANNO, list_lit([v("KE"), v("VE")]), [
        {generate, ?ANNO, tuple_pat([v("KE"), v("VE")]), v("Sorted")}
    ]}.

%% Value patterns that stay underscored where the encoded expression
%% never reads the value (a uuid encode is the constant error) — the
%% generated code must not warn on the unused binding.

%% The collection-header bindings: for a uuid element nothing consumes
%% the size or the tail, so both stay underscored.

-spec size_rest_pats(wire_type()) -> [ast()].
size_rest_pats({base, uuid}) ->
    [v("_Size")];
size_rest_pats(_) ->
    [v("Size")].

-spec rest_pat(wire_type()) -> ast().
rest_pat({base, uuid}) ->
    v("_Rest");
rest_pat(_) ->
    v("Rest").

%% The constant uuid errors, as body expressions and one-clause function
%% bodies — the encode tag on the encode side, the decode tag on the
%% decode side, mirroring the generic engine's encode_k/decode_k.

-spec uuid_error() -> ast().
uuid_error() ->
    err_encode(tuple_t([at(type_not_supported), tuple_t([at(base), at(uuid)]), at(compact)])).

-spec uuid_decode_error() -> ast().
uuid_decode_error() ->
    err_decode(tuple_t([at(type_not_supported), tuple_t([at(base), at(uuid)]), at(compact)])).

-spec uuid_error_clause(arity()) -> ast().
uuid_error_clause(Arity) ->
    clause([v("_" ++ integer_to_list(I)) || I <- lists:seq(1, Arity)], none, [uuid_error()]).

-spec uuid_decode_error_clause(arity()) -> ast().
uuid_decode_error_clause(Arity) ->
    clause([v("_" ++ integer_to_list(I)) || I <- lists:seq(1, Arity)], none, [uuid_decode_error()]).

%% Container element expressions: base and enum types inline at the use
%% site, struct references as struct calls, nested containers as helper
%% calls — the same dispatch the struct fields go through.

-spec encode_elem_expr(wire_type(), ast(), #ectx{}, #{integer() => pos_integer()}) -> ast().
encode_elem_expr({base, B}, V, _Ctx, _Enums) ->
    encode_base_expr(B, V);
encode_elem_expr({enum, _} = T, V, _Ctx, _Enums) ->
    encode_compact_expr(T, V, undefined, #{});
encode_elem_expr({struct, {ref, TypesMod, Local}}, V, Ctx, _Enums) ->
    struct_encode_call(TypesMod, Local, V, Ctx);
encode_elem_expr(T, V, _Ctx, Enums) ->
    call_local(enc_name(T, Enums), [V]).

-spec decode_elem_expr(wire_type(), ast(), #ectx{}, #{integer() => pos_integer()}, string()) -> ast().
decode_elem_expr({base, B}, Bin, _Ctx, _Enums, Suffix) ->
    decode_base_expr(B, Bin, Suffix);
decode_elem_expr({enum, _} = T, Bin, _Ctx, _Enums, Suffix) ->
    decode_compact_expr(T, Bin, undefined, #{}, Suffix);
decode_elem_expr({struct, {ref, TypesMod, Local}}, Bin, Ctx, _Enums, _Suffix) ->
    struct_decode_call(TypesMod, Local, Bin, Ctx);
decode_elem_expr(T, Bin, _Ctx, Enums, _Suffix) ->
    call_local(dec_name(T, Enums), [Bin]).

%%--------------------------------------------------------------------
%% Module helpers
%%--------------------------------------------------------------------

%% One emitted function per helper name (dec_varint renders two forms,
%% one per arity). Each mirrors the generic engine's function of the
%% same shape clause for clause.

-spec helper_forms(atom()) -> erl_syntax:forms().
helper_forms(enc_header) ->
    [
        {function, ?ANNO, enc_header, 3, [
            clause([v("Id"), v("LastId"), v("Nibble")], none, [
                {match, ?ANNO, v("Delta"), {op, ?ANNO, '-', v("Id"), v("LastId")}},
                'case'(
                    {op, ?ANNO, 'andalso', {op, ?ANNO, '>', v("Delta"), i(0)}, {op, ?ANNO, '<', v("Delta"), i(16)}},
                    [
                        clause([at(true)], none, [
                            bin_seg(
                                {op, ?ANNO, 'bor', {op, ?ANNO, 'bsl', v("Delta"), i(4)}, v("Nibble")},
                                i(8),
                                [big, unsigned]
                            )
                        ]),
                        clause([at(false)], none, [
                            list_lit([
                                bin_seg(v("Nibble"), i(8), [big, unsigned]),
                                call_local(enc_varint_z, [v("Id")])
                            ])
                        ])
                    ]
                )
            ])
        ]}
    ];
helper_forms(enc_varint) ->
    [
        {function, ?ANNO, enc_varint, 1, [
            clause([v("V")], [{op, ?ANNO, '<', v("V"), i(16#80)}], [
                list_lit([bin_seg(v("V"), i(8), [big, unsigned])])
            ]),
            clause([v("V")], none, [
                %% The cons itself is the result — the generic engine's
                %% `[Byte | varint(Rest)]' shape. An extra list wrapper would
                %% change the TERM, and map pairs sort by the encoded-key
                %% term, so the wire order would diverge.
                cons(
                    bin_seg(
                        {op, ?ANNO, 'bor', {op, ?ANNO, 'band', v("V"), i(16#7F)}, i(16#80)},
                        i(8),
                        [big, unsigned]
                    ),
                    call_local(enc_varint, [{op, ?ANNO, 'bsr', v("V"), i(7)}])
                )
            ])
        ]}
    ];
helper_forms(enc_varint_z) ->
    [
        {function, ?ANNO, enc_varint_z, 1, [
            clause([v("V")], none, [
                call_local(enc_varint, [
                    {op, ?ANNO, 'band', i(16#FFFFFFFFFFFFFFFF),
                        {op, ?ANNO, 'bxor', {op, ?ANNO, 'bsl', v("V"), i(1)}, {op, ?ANNO, 'bsr', v("V"), i(63)}}}
                ])
            ])
        ]}
    ];
helper_forms(dec_varint) ->
    [
        {function, ?ANNO, dec_varint, 1, [
            clause([v("Bin")], none, [call_local(dec_varint, [v("Bin"), i(0), i(0)])])
        ]},
        {function, ?ANNO, dec_varint, 3, [
            clause(
                [
                    bin_pat([{v("B"), default, default}, {v("Rest"), default, [binary]}]),
                    v("Shift"),
                    v("Acc")
                ],
                [{op, ?ANNO, '>=', v("B"), i(16#80)}, {op, ?ANNO, '<', v("Shift"), i(63)}],
                [
                    call_local(dec_varint, [
                        v("Rest"),
                        {op, ?ANNO, '+', v("Shift"), i(7)},
                        {op, ?ANNO, 'bor', v("Acc"),
                            {op, ?ANNO, 'bsl', {op, ?ANNO, 'band', v("B"), i(16#7F)}, v("Shift")}}
                    ])
                ]
            ),
            clause(
                [
                    bin_pat([{v("B"), default, default}, {v("Rest"), default, [binary]}]),
                    v("Shift"),
                    v("Acc")
                ],
                [{op, ?ANNO, '<', v("B"), i(16#80)}],
                [
                    tuple_t([
                        at(ok),
                        {op, ?ANNO, 'bor', v("Acc"), {op, ?ANNO, 'bsl', v("B"), v("Shift")}},
                        v("Rest")
                    ])
                ]
            ),
            clause(
                [
                    bin_pat([{v("_"), default, default}, {v("_"), default, [binary]}]),
                    v("Shift"),
                    v("_Acc")
                ],
                [{op, ?ANNO, '>=', v("Shift"), i(63)}],
                [err_decode(at(bad_varint))]
            ),
            clause([v("_Bin"), v("_Shift"), v("_Acc")], none, [at(more)])
        ]}
    ];
helper_forms(dec_varint_z) ->
    [
        {function, ?ANNO, dec_varint_z, 1, [
            clause([v("Bin")], none, [
                'case'(call_local(dec_varint, [v("Bin")]), [
                    ok3_bind_clause(
                        v("V"),
                        v("Rest"),
                        ok3(
                            {op, ?ANNO, 'bxor', {op, ?ANNO, 'bsr', v("V"), i(1)},
                                {op, ?ANNO, '-', {op, ?ANNO, 'band', v("V"), i(1)}}},
                            v("Rest")
                        )
                    ),
                    other_tail()
                ])
            ])
        ]}
    ];
helper_forms(coll_header) ->
    [
        {function, ?ANNO, coll_header, 2, [
            clause([v("Nib"), v("Size")], [{op, ?ANNO, '<', v("Size"), i(15)}], [
                bin_seg(
                    {op, ?ANNO, 'bor', {op, ?ANNO, 'bsl', v("Size"), i(4)}, v("Nib")},
                    i(8),
                    [big, unsigned]
                )
            ]),
            clause([v("Nib"), v("Size")], none, [
                list_lit([
                    bin_seg({op, ?ANNO, 'bor', i(16#F0), v("Nib")}, i(8), [big, unsigned]),
                    call_local(enc_varint, [v("Size")])
                ])
            ])
        ]}
    ];
helper_forms(dec_coll_header) ->
    [
        {function, ?ANNO, dec_coll_header, 1, [
            clause([bin_pat([{v("Header"), i(8), [big, unsigned]}, {v("Rest"), default, [binary]}])], none, [
                {match, ?ANNO, v("Nibble"), {op, ?ANNO, 'band', v("Header"), i(16#0F)}},
                'case'({op, ?ANNO, 'bsr', v("Header"), i(4)}, [
                    clause([i(15)], none, [
                        'case'(call_local(dec_varint, [v("Rest")]), [
                            ok3_bind_clause(
                                v("Size"), v("Rest1"), ok3(tuple_t([v("Nibble"), v("Size")]), v("Rest1"))
                            ),
                            other_tail()
                        ])
                    ]),
                    clause([v("Size")], none, [ok3(tuple_t([v("Nibble"), v("Size")]), v("Rest"))])
                ])
            ]),
            clause([{bin, ?ANNO, []}], none, [at(more)])
        ]}
    ];
helper_forms(dec_string_c) ->
    [
        {function, ?ANNO, dec_string_c, 1, [
            %% Takes the raw bytes and decodes the length varint itself —
            %% the generic engine's decode_binary_k shape.
            clause([v("Bin")], none, [
                'case'(call_local(dec_varint, [v("Bin")]), [
                    clause(
                        [tuple_t([at(ok), v("Len"), v("Rest")])],
                        [{op, ?ANNO, '>=', call_local(byte_size, [v("Rest")]), v("Len")}],
                        [
                            {match, ?ANNO,
                                bin_pat([
                                    {v("V"), v("Len"), [binary]},
                                    {v("Tail"), default, [binary]}
                                ]), v("Rest")},
                            ok3(v("V"), v("Tail"))
                        ]
                    ),
                    clause([tuple_pat([at(ok), v("_"), v("_")])], none, [at(more)]),
                    other_tail()
                ])
            ])
        ]}
    ].

%%--------------------------------------------------------------------
%% compact_codec/1
%%--------------------------------------------------------------------

-spec compact_codec_forms(#tg_module{}, #ectx{}) -> erl_syntax:forms().
compact_codec_forms(Mod, Ctx) ->
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
         || {S, {Encode, Decode}} <- [{S, compact_pair(S, Ctx)} || S <- Mod#tg_module.structs]
        ] ++ [clause([v("_")], none, [at(error)])],
    Doc =
        <<
            "The compact-protocol wire codecs of this module's structs, by wire"
            " struct name: `{ok, {Encode, Decode}}' where `Encode/1` takes the"
            " wire map to `{ok, iodata()} | {error, _}' and `Decode/1` takes a"
            " binary to `{ok, WireMap, Rest} | more | {error, _}' -- the same"
            " contracts as `thrift_erl_compact:encode/2` and `decode/2'."
            " Unknown names answer `error'; `thrift_erl_compact' probes this"
            " export to dispatch named-struct references to the specialized"
            " code."
        >>,
    thrift_generator_emitter_syntax:doc_form(undefined, Doc) ++
        [
            spec_form(compact_codec, 1, [
                t_fun(
                    [t_atom(binary)],
                    t_union([
                        t_ok(tuple_t_type([t_atom('fun'), t_atom('fun')])),
                        t_atom_lit(error)
                    ])
                )
            ]),
            {function, ?ANNO, compact_codec, 1, Clauses}
        ].

%%--------------------------------------------------------------------
%% Wire vocabulary
%%--------------------------------------------------------------------

-spec wtype(thrift_type(), #ectx{}) -> wire_type().
wtype(Type, Ctx) ->
    thrift_generator_emitter:type_desc(Type, Ctx).

%% Compact type nibbles (the high bits of a field/collection header);
%% the boolean entry is the cbool value a boolean ELEMENT rides as.

-spec nibble(wire_type()) -> non_neg_integer().
nibble({base, bool}) -> 16#01;
nibble({base, i8}) -> 16#03;
nibble({base, i16}) -> 16#04;
nibble({base, i32}) -> 16#05;
nibble({base, i64}) -> 16#06;
nibble({base, double}) -> 16#07;
nibble({base, B}) when B =:= string; B =:= binary -> 16#08;
nibble({base, uuid}) -> 16#00;
nibble({enum, _}) -> 16#05;
nibble({list, _}) -> 16#09;
nibble({set, _, _}) -> 16#0A;
nibble({set, _}) -> 16#0A;
nibble({map, _, _}) -> 16#0B;
nibble({struct, _}) -> 16#0C.

-spec bits(i16 | i32 | i64) -> 16 | 32 | 64.
bits(i16) -> 16;
bits(i32) -> 32;
bits(i64) -> 64.
