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

-module(thrift_codec_test).

-moduledoc """
Equivalence properties and the negative battery for the specialized
binary wire codecs the generator emits into types modules.

The specialized entry (`{struct, {ref, Module, Name}}` descriptors,
dispatched through the module's `binary_codec/1`) must behave exactly
like the generic engine (`{struct, {Kind, Fields}}` inline descriptors
interpreted by `thrift_erl_binary`): identical bytes, identical values
and identical error terms. The generic side is itself proven by the
golden-byte tests and the golden interop suite, so equivalence here
makes the specialized code transitively correct.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("thrift_generator_model.hrl").

-define(NUMTESTS, 300).

%% Shallow structs for the random properties: scalar fields, a nested
%% struct reference, bools, an exception kind, a union, an empty struct,
%% optional/default fields. Deep container nesting is covered by the
%% deterministic battery — random generation over those types is too
%% slow for PropEr's generator interpreter.
-define(STRUCTS, [
    <<"Xtruct">>,
    <<"Xtruct2">>,
    <<"Xtruct3">>,
    <<"Bools">>,
    <<"Xception">>,
    <<"Xception2">>,
    <<"SomeUnion">>,
    <<"EmptyStruct">>,
    <<"OneField">>,
    <<"VersioningTestV1">>,
    <<"VersioningTestV2">>,
    <<"BoolTest">>,
    <<"StructA">>,
    <<"StructB">>,
    <<"OptionalBinary">>
]).

%% Deep-container structs, exercised by the battery with fixed value
%% shapes (all fields, partial fields, empty containers).
-define(DEEP_STRUCTS, [
    <<"Insanity">>,
    <<"CrazyNesting">>,
    <<"NestedMixedx2">>,
    <<"NestedListsI32x2">>,
    <<"NestedListsI32x3">>,
    <<"NestedListsBonk">>,
    <<"ListBonks">>,
    <<"LargeDeltas">>,
    <<"ListTypeVersioningV1">>,
    <<"ListTypeVersioningV2">>,
    <<"OptionalSetDefaultTest">>,
    <<"GuessProtocolStruct">>
]).

%%--------------------------------------------------------------------
%% Properties
%%--------------------------------------------------------------------

proper_test_() ->
    [
        {"specialized wire codecs match the generic engine (PropEr)",
            {timeout, 300, fun() -> check(prop_wire_matches_generic()) end}},
        {"specialized wire prefixes never complete (PropEr)",
            {timeout, 300, fun() -> check(prop_wire_prefix_never_completes()) end}}
    ].

%% Silent success; on failure re-run with output so the shrunk
%% counterexample lands in the EUnit log.

check(Prop) ->
    ok = load_fixture(),
    case
        proper:quickcheck(Prop, [
            {numtests, ?NUMTESTS},
            {start_size, 2},
            {on_output, fun(_, _) -> ok end},
            long_result
        ])
    of
        true ->
            ok;
        Failed ->
            io:put_chars("PropEr failure, re-running with output:\n"),
            proper:quickcheck(Prop, [
                {numtests, ?NUMTESTS},
                {start_size, 2},
                long_result
            ]),
            ?assertEqual(true, Failed)
    end.

%% Random wire values of the generated structs: the specialized entry
%% (ref descriptor -> binary_codec/1) and the generic engine (inline
%% descriptor -> the compiled-scheme interpreter) agree byte for byte,
%% and decode agrees on whatever encode produced.

prop_wire_matches_generic() ->
    ?FORALL(
        {Name, Value},
        ?LET(Name, oneof(?STRUCTS), {Name, wire_value_gen(Name)}),
        begin
            Inline = {struct, goldentest_types:struct_info(Name)},
            Ref = {struct, {ref, goldentest_types, Name}},
            Generic = normalize(thrift_erl_binary:encode(Inline, Value)),
            Specialized = normalize(thrift_erl_binary:encode(Ref, Value)),
            case {Generic, Specialized} of
                {{ok, Bytes}, {ok, Bytes}} ->
                    thrift_erl_binary:decode(Inline, Bytes) =:=
                        thrift_erl_binary:decode(Ref, Bytes);
                {Same, Same} ->
                    true;
                {_, _} ->
                    false
            end
        end
    ).

%% Every proper prefix of a valid specialized encoding asks for more —
%% the truncation semantics the buffered transport builds on.

prop_wire_prefix_never_completes() ->
    ?FORALL(
        {Name, Value},
        ?LET(Name, oneof(?STRUCTS), {Name, wire_value_gen(Name)}),
        begin
            Ref = {struct, {ref, goldentest_types, Name}},
            case thrift_erl_binary:encode(Ref, Value) of
                {ok, IoData} ->
                    Bytes = iolist_to_binary(IoData),
                    broken_prefixes(Name, Bytes) =:= [];
                _Other ->
                    %% Invalid values never produce bytes to prefix.
                    true
            end
        end
    ).

%% The prefixes of `Bytes' that the struct's specialized decode answers
%% with something other than `more' — the property wants none.

broken_prefixes(Name, Bytes) ->
    {ok, {_Encode, Decode}} = goldentest_types:binary_codec(Name),
    [
        binary:part(Bytes, 0, N)
     || N <- lists:seq(1, byte_size(Bytes) - 1),
        P <- [binary:part(Bytes, 0, N)],
        Decode(P) =/= more
    ].

%%--------------------------------------------------------------------
%% Negative battery: exact error terms, specialized and generic
%%--------------------------------------------------------------------

negative_battery_test() ->
    ok = load_fixture(),
    Inline = fun(Name) -> {struct, goldentest_types:struct_info(Name)} end,
    Ref = fun(Name) -> {struct, {ref, goldentest_types, Name}} end,
    Enc = fun(Desc, Value) -> normalize(thrift_erl_binary:encode(Desc, Value)) end,

    %% Missing required field (CrazyNesting's list_field, id 3).
    Crazy = <<"CrazyNesting">>,
    MissingValue = #{<<"string_field">> => <<"x">>, <<"binary_field">> => <<"b">>},
    MissingError = {error, {encode, {missing_required_fields, [<<"list_field">>]}}},
    ?assertEqual(
        {MissingError, MissingError},
        {Enc(Inline(Crazy), MissingValue), Enc(Ref(Crazy), MissingValue)}
    ),

    %% Decode-time missing required: the stop byte alone.
    MissingStop = <<0>>,
    ExpectedMissing = {error, {decode, {missing_required_fields, [<<"list_field">>]}}},
    ?assertEqual(ExpectedMissing, thrift_erl_binary:decode(Inline(Crazy), MissingStop)),
    ?assertEqual(ExpectedMissing, thrift_erl_binary:decode(Ref(Crazy), MissingStop)),

    %% Union rules: empty and multiple fields present (SomeUnion's first
    %% two field names come from the descriptor, not hard-coded).
    {union, UnionFields} = goldentest_types:struct_info(<<"SomeUnion">>),
    [N1, N2 | _] = [FieldName || {_, _, _, FieldName, _} <- UnionFields],
    UnionEmptyError = {error, {encode, union_empty}},
    ?assertEqual(
        {UnionEmptyError, UnionEmptyError},
        {Enc(Inline(<<"SomeUnion">>), #{}), Enc(Ref(<<"SomeUnion">>), #{})}
    ),
    UnionMultiple = #{N1 => true, N2 => <<"x">>},
    UnionMultipleError = {error, {encode, union_multiple}},
    ?assertEqual(
        {UnionMultipleError, UnionMultipleError},
        {Enc(Inline(<<"SomeUnion">>), UnionMultiple), Enc(Ref(<<"SomeUnion">>), UnionMultiple)}
    ),

    %% Known id with the wrong wire type: field_type_mismatch.
    WrongWire = <<8, 0, 4, 0, 0, 0, 1, 0>>,
    ExpectedMismatch = {error, {decode, {field_type_mismatch, 4}}},
    ?assertEqual(ExpectedMismatch, thrift_erl_binary:decode(Inline(<<"Xtruct">>), WrongWire)),
    ?assertEqual(ExpectedMismatch, thrift_erl_binary:decode(Ref(<<"Xtruct">>), WrongWire)),

    %% Container headers: element type mismatch and bad sizes.
    BadElem = <<15, 0, 2, 8, 0, 0, 0, 0, 0>>,
    ?assertEqual(
        {error, {decode, {element_type_mismatch, 8}}},
        thrift_erl_binary:decode(Ref(<<"Insanity">>), BadElem)
    ),
    BadMapType = <<13, 0, 1, 11, 10, 0, 0, 0, 0, 0>>,
    ?assertEqual(
        {error, {decode, map_type_mismatch}},
        thrift_erl_binary:decode(Ref(<<"Insanity">>), BadMapType)
    ),
    BadMapSize = <<13, 0, 1, 8, 10, 255, 255, 255, 255, 0>>,
    ?assertEqual(
        {error, {decode, bad_map_size}},
        thrift_erl_binary:decode(Ref(<<"Insanity">>), BadMapSize)
    ),
    BadSeqSize = <<15, 0, 2, 12, 255, 255, 255, 255, 0>>,
    ?assertEqual(
        {error, {decode, bad_sequence_size}},
        thrift_erl_binary:decode(Ref(<<"Insanity">>), BadSeqSize)
    ),

    %% Negative string length.
    BadString = <<11, 0, 1, 255, 255, 255, 255>>,
    ?assertEqual(
        {error, {decode, bad_string_length}},
        thrift_erl_binary:decode(Ref(<<"Xtruct">>), BadString)
    ),

    %% Unknown field ids are skipped by wire type.
    Unknown = <<10, 0, 99, 0, 0, 0, 0, 0, 0, 0, 1, 11, 0, 1, 0, 0, 0, 1, $a, 0>>,
    ExpectedSkip = {ok, #{<<"string_thing">> => <<"a">>}, <<>>},
    ?assertEqual(ExpectedSkip, thrift_erl_binary:decode(Inline(<<"Xtruct">>), Unknown)),
    ?assertEqual(ExpectedSkip, thrift_erl_binary:decode(Ref(<<"Xtruct">>), Unknown)),

    %% Wrong value shapes: bad enum atom, bad scalar type, non-map struct.
    BadEnum = #{<<"userMap">> => #{'NOPE' => 1}, <<"xtructs">> => []},
    EnumError = {error, {encode, {unknown_enum_value, 'NOPE'}}},
    ?assertEqual(
        {EnumError, EnumError},
        {Enc(Inline(<<"Insanity">>), BadEnum), Enc(Ref(<<"Insanity">>), BadEnum)}
    ),
    BadScalar = #{<<"byte_thing">> => <<"x">>},
    ScalarError = {error, {encode, {value_does_not_match_type, <<"x">>}}},
    ?assertEqual(
        {ScalarError, ScalarError},
        {Enc(Inline(<<"Xtruct">>), BadScalar), Enc(Ref(<<"Xtruct">>), BadScalar)}
    ),
    StructValueError = {error, {encode, {value_does_not_match_type, 42}}},
    ?assertEqual(
        {StructValueError, StructValueError},
        {Enc(Inline(<<"Xtruct">>), 42), Enc(Ref(<<"Xtruct">>), 42)}
    ),

    %% Unknown enum integers pass through on decode (an Insanity
    %% userMap key of 99 stays 99), and plain i32 fields round-trip.
    UnknownEnumKey = <<13, 0, 1, 8, 10, 0, 0, 0, 1, 0, 0, 0, 99, 0, 0, 0, 0, 0, 0, 0, 1, 0>>,
    ?assertEqual(
        {ok, #{<<"userMap">> => #{99 => 1}}, <<>>},
        thrift_erl_binary:decode(Ref(<<"Insanity">>), UnknownEnumKey)
    ),
    I32Field = <<8, 0, 9, 0, 0, 0, 9, 0>>,
    ?assertEqual(
        {ok, #{<<"i32_thing">> => 9}, <<>>},
        thrift_erl_binary:decode(Ref(<<"Xtruct">>), I32Field)
    ),
    ok.

deep_battery_test() ->
    ok = load_fixture(),
    lists:foreach(fun deep_struct_case/1, ?DEEP_STRUCTS).

%% For every deep struct: a full value (every field present), a partial
%% one (first field only) and an empty map — the specialized and generic
%% codecs must agree on bytes, decoded values and errors alike.

deep_struct_case(Name) ->
    {Kind, Fields} = goldentest_types:struct_info(Name),
    Values =
        [
            value_shape(Fields, full),
            value_shape(Fields, first),
            #{}
        ] ++
            case Kind of
                union -> [union_two_fields(Fields)];
                _ -> []
            end,
    lists:foreach(
        fun(Value) ->
            Inline = {struct, goldentest_types:struct_info(Name)},
            Ref = {struct, {ref, goldentest_types, Name}},
            Generic = normalize(thrift_erl_binary:encode(Inline, Value)),
            Specialized = normalize(thrift_erl_binary:encode(Ref, Value)),
            ?assertEqual(Generic, Specialized),
            case Generic of
                {ok, Bytes} ->
                    ?assertEqual(
                        thrift_erl_binary:decode(Inline, Bytes),
                        thrift_erl_binary:decode(Ref, Bytes)
                    ),
                    %% Every proper prefix asks for more.
                    {ok, {_Encode, Decode}} = goldentest_types:binary_codec(Name),
                    lists:foreach(
                        fun(Prefix) -> ?assertEqual(more, Decode(Prefix)) end,
                        [binary:part(Bytes, 0, N) || N <- lists:seq(1, byte_size(Bytes) - 1)]
                    );
                _ ->
                    ok
            end
        end,
        Values
    ).

value_shape([], _Shape) ->
    #{};
value_shape(Fields, full) ->
    maps:from_list([
        {Name, field_sample(Type)}
     || {_Id, _Req, Type, Name, _Default} <- Fields
    ]);
value_shape([{_Id, _Req, Type, Name, _Default} | _], first) ->
    #{Name => field_sample(Type)}.

union_two_fields([]) ->
    #{};
union_two_fields(Fields) ->
    N1 = element(4, hd(Fields)),
    N2 = element(4, lists:last(Fields)),
    #{N1 => field_sample(element(3, hd(Fields))), N2 => field_sample(element(3, lists:last(Fields)))}.

%% A small valid sample per wire type: empty containers, minimal scalars
%% and a one-field struct for references.

field_sample({base, bool}) ->
    true;
field_sample({base, i8}) ->
    1;
field_sample({base, i16}) ->
    2;
field_sample({base, i32}) ->
    3;
field_sample({base, i64}) ->
    4;
field_sample({base, double}) ->
    1.5;
field_sample({base, S}) when S =:= string; S =:= binary -> <<"x">>;
field_sample({base, uuid}) ->
    <<1:128>>;
field_sample({enum, Desc}) ->
    case [Atom || {_V, Atom} <- Desc] of
        [Atom | _] -> Atom;
        [] -> 1
    end;
field_sample({list, _T}) ->
    [];
field_sample({set, _T, _Impl}) ->
    [];
field_sample({map, _K, _V}) ->
    #{};
field_sample({struct, {ref, Module, Name}}) ->
    {_Kind, Fields} = Module:struct_info(Name),
    value_shape(Fields, full).

unknown_name_test() ->
    ok = load_fixture(),
    %% binary_codec answers error for unknown names, and the ref path
    %% falls back to the generic unknown_struct report.
    ?assertEqual(error, goldentest_types:binary_codec(<<"Nope">>)),
    ?assertEqual(
        {error, {decode, {unknown_struct, {goldentest_types, <<"Nope">>}}}},
        thrift_erl_binary:decode({struct, {ref, goldentest_types, <<"Nope">>}}, <<0>>)
    ),
    ok.

%%--------------------------------------------------------------------
%% Wire value generators (the wire representation: binary field names)
%%--------------------------------------------------------------------

wire_value_gen(Name) ->
    ?SIZED(Size, wire_value_gen(Name, Size)).

wire_value_gen(Name, Size) ->
    case goldentest_types:struct_info(Name) of
        error ->
            erlang:exit({bad_struct_name, Name, code:is_loaded(goldentest_types)});
        SF ->
            {Kind, Fields} = SF,
            struct_value_gen(Kind, Fields, Size)
    end.

struct_value_gen(union, Fields, _Size) ->
    %% Unions carry zero or one field; both shapes are valid inputs.
    case Fields of
        [] ->
            return(#{});
        _ ->
            frequency([
                {2, return(#{})},
                {8,
                    ?LET(
                        F,
                        oneof(Fields),
                        ?LET(V, field_value_gen(element(3, F), 2), #{element(4, F) => V})
                    )}
            ])
    end;
struct_value_gen(_Kind, Fields, Size) ->
    Entries = [
        frequency([
            {4, ?LET(V, field_value_gen(Type, Size), {Name, V})},
            {1, absent}
        ])
     || {_Id, _Req, Type, Name, _Default} <- Fields
    ],
    ?LET(Pairs, Entries, maps:from_list([Pair || {_, V} = Pair <- Pairs, V =/= absent])).

field_value_gen({base, bool}, _Size) ->
    oneof([true, false]);
field_value_gen({base, i8}, _Size) ->
    integer(-128, 127);
field_value_gen({base, i16}, _Size) ->
    integer(-32768, 32767);
field_value_gen({base, i32}, _Size) ->
    integer(-2147483648, 2147483647);
field_value_gen({base, i64}, _Size) ->
    integer(-9223372036854775808, 9223372036854775807);
field_value_gen({base, double}, _Size) ->
    float();
field_value_gen({base, S}, _Size) when S =:= string; S =:= binary ->
    binary();
field_value_gen({base, uuid}, _Size) ->
    ?LET(Bytes, vector(16, byte()), iolist_to_binary(Bytes));
field_value_gen({enum, Desc}, _Size) ->
    Atoms = [Atom || {_Value, Atom} <- Desc],
    frequency([{8, oneof(Atoms)}, {1, integer(-2, 12)}]);
field_value_gen({list, T}, Size) ->
    list(field_value_gen(T, Size div 2));
field_value_gen({set, T, _Impl}, Size) ->
    list(field_value_gen(T, Size div 2));
field_value_gen({map, K, V}, Size) ->
    map(field_value_gen(K, Size div 2), field_value_gen(V, Size div 2));
field_value_gen({struct, {ref, Module, Name}}, Size) ->
    {Kind, Fields} = Module:struct_info(Name),
    struct_value_gen(Kind, Fields, Size div 2).

%%--------------------------------------------------------------------
%% Fixture
%%--------------------------------------------------------------------

normalize({ok, IoData}) when is_list(IoData) orelse is_binary(IoData) ->
    {ok, iolist_to_binary(IoData)};
normalize(Other) ->
    Other.

load_fixture() ->
    case code:is_loaded(goldentest_types) of
        {file, _} ->
            ok;
        false ->
            DataDir = filename:join(code:lib_dir(thrift_generator), "test/thrift_golden_SUITE_data"),
            {ok, Loaded} = thrift_generator_loader:load(filename:join(DataDir, "ThriftTest.thrift")),
            {ok, Model0} = thrift_generator_semantic:analyze(Loaded),
            Model = Model0#tg_model{
                modules = [M#tg_module{name = <<"goldentest">>} || M <- Model0#tg_model.modules]
            },
            lists:foreach(
                fun
                    ({ok, Name, Beam}) ->
                        {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam);
                    ({error, Reason}) ->
                        erlang:error({generated_compile_failed, Reason})
                end,
                thrift_generator_emitter:compile_sources(Model)
            ),
            ok
    end.
