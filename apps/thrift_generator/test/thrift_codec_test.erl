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
binary, compact and JSON wire codecs the generator emits into types
modules.

The specialized entry (`{struct, {ref, Module, Name}}` descriptors,
dispatched through the module's `binary_codec/1` / `compact_codec/1` /
`json_codec/1`) must behave exactly like the generic engine
(`{struct, {Kind, Fields}}` inline descriptors interpreted by
`thrift_erl_binary` / `thrift_erl_compact` / `thrift_erl_json`):
identical bytes, identical values and identical error terms. The
generic side is itself proven by the golden-byte tests and the golden
interop suite, so equivalence here makes the specialized code
transitively correct.
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
            {timeout, 300, fun() -> check(prop_wire_prefix_never_completes()) end}},
        {"specialized compact codecs match the generic engine (PropEr)",
            {timeout, 300, fun() -> check(prop_compact_matches_generic()) end}},
        {"specialized compact prefixes never complete (PropEr)",
            {timeout, 300, fun() -> check(prop_compact_prefix_never_completes()) end}},
        {"specialized json codecs match the generic engine (PropEr)",
            {timeout, 300, fun() -> check(prop_json_matches_generic()) end}},
        {"specialized json prefixes never complete (PropEr)",
            {timeout, 300, fun() -> check(prop_json_prefix_never_completes()) end}}
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
%% (ref descriptor -> the codec probe) and the generic engine (inline
%% descriptor -> the compiled-scheme interpreter) agree byte for byte,
%% and decode agrees on whatever encode produced — for both the binary
%% and the compact protocol.

prop_wire_matches_generic() ->
    prop_matches_generic(thrift_erl_binary).

prop_compact_matches_generic() ->
    prop_matches_generic(thrift_erl_compact).

prop_matches_generic(Engine) ->
    ?FORALL(
        {Name, Value},
        ?LET(Name, oneof(?STRUCTS), {Name, wire_value_gen(Name)}),
        begin
            Inline = {struct, goldentest_types:struct_info(Name)},
            Ref = {struct, {ref, goldentest_types, Name}},
            Generic = normalize(Engine:encode(Inline, Value)),
            Specialized = normalize(Engine:encode(Ref, Value)),
            case {Generic, Specialized} of
                {{ok, Bytes}, {ok, Bytes}} ->
                    Engine:decode(Inline, Bytes) =:=
                        Engine:decode(Ref, Bytes);
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
    prop_prefix_never_completes(thrift_erl_binary, fun goldentest_types:binary_codec/1, fun not_more/1).

prop_compact_prefix_never_completes() ->
    prop_prefix_never_completes(
        thrift_erl_compact, fun goldentest_types:compact_codec/1, fun not_more/1
    ).

prop_json_matches_generic() ->
    prop_matches_generic(thrift_erl_json).

prop_json_prefix_never_completes() ->
    %% Unlike binary/compact, a JSON prefix cut inside a literal (`tru')
    %% errors in the generic engine too — the broken answer is a
    %% completed decode, not a non-`more' one.
    prop_prefix_never_completes(thrift_erl_json, fun goldentest_types:json_codec/1, fun completed/1).

not_more(Answer) ->
    Answer =/= more.

completed(Answer) ->
    case Answer of
        {ok, _, _} -> true;
        _ -> false
    end.

prop_prefix_never_completes(Engine, Codec, Broken) ->
    ?FORALL(
        {Name, Value},
        ?LET(Name, oneof(?STRUCTS), {Name, wire_value_gen(Name)}),
        begin
            Ref = {struct, {ref, goldentest_types, Name}},
            case Engine:encode(Ref, Value) of
                {ok, IoData} ->
                    Bytes = iolist_to_binary(IoData),
                    broken_prefixes(Codec(Name), Bytes, Broken) =:= [];
                _Other ->
                    %% Invalid values never produce bytes to prefix.
                    true
            end
        end
    ).

%% The prefixes of `Bytes' that the struct's specialized decode answers
%% with a broken value (per `Broken') — the property wants none.

broken_prefixes({ok, {_Encode, Decode}}, Bytes, Broken) ->
    [
        binary:part(Bytes, 0, N)
     || N <- lists:seq(1, byte_size(Bytes) - 1),
        P <- [binary:part(Bytes, 0, N)],
        Broken(Decode(P))
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

%% Compact protocol: exact error terms and wire shapes the specialized
%% codecs must reproduce — hand-computed bytes checked against the
%% generic engine on both sides.

compact_negative_battery_test() ->
    ok = load_fixture(),
    Inline = fun(Name) -> {struct, goldentest_types:struct_info(Name)} end,
    Ref = fun(Name) -> {struct, {ref, goldentest_types, Name}} end,
    Enc = fun(Desc, Value) -> normalize(thrift_erl_compact:encode(Desc, Value)) end,
    Dec = fun(Name, Bytes) ->
        {thrift_erl_compact:decode(Inline(Name), Bytes), thrift_erl_compact:decode(Ref(Name), Bytes)}
    end,

    %% Known id with the wrong nibble: field_type_mismatch (Xtruct's
    %% byte_thing sent as i32: delta 4, nibble 5, zigzag 1, stop).
    ?assertEqual(
        {{error, {decode, {field_type_mismatch, 4}}}, {error, {decode, {field_type_mismatch, 4}}}},
        Dec(<<"Xtruct">>, <<16#45, 2, 0>>)
    ),

    %% Unknown field id skipped by nibble, then a non-delta id arrives
    %% as nibble byte + zigzag varint.
    ?assertEqual(
        {{ok, #{<<"string_thing">> => <<"a">>}, <<>>}, {ok, #{<<"string_thing">> => <<"a">>}, <<>>}},
        Dec(<<"Xtruct">>, <<16#24, 10, 16#08, 2, 1, $a, 0>>)
    ),

    %% Booleans ride in the header nibble (CT_TRUE/CT_FALSE), no payload.
    ?assertEqual(
        {
            {ok, #{<<"im_true">> => true, <<"im_false">> => false}, <<>>},
            {ok, #{<<"im_true">> => true, <<"im_false">> => false}, <<>>}
        },
        Dec(<<"Bools">>, <<16#11, 16#12, 0>>)
    ),

    %% Decode-time missing required: the stop byte alone (StructB's ab).
    MissingStop = <<0>>,
    ExpectedMissing = {error, {decode, {missing_required_fields, [<<"ab">>]}}},
    ?assertEqual(
        {ExpectedMissing, ExpectedMissing},
        Dec(<<"StructB">>, MissingStop)
    ),

    %% Collection headers: element type mismatch carries the observed
    %% nibble; map type mismatch and the empty-map zero byte.
    ?assertEqual(
        {{error, {decode, {element_type_mismatch, 8}}}, {error, {decode, {element_type_mismatch, 8}}}},
        Dec(<<"Insanity">>, <<16#29, 16#08, 0>>)
    ),
    ?assertEqual(
        {{error, {decode, map_type_mismatch}}, {error, {decode, map_type_mismatch}}},
        Dec(<<"Insanity">>, <<16#1B, 1, 16#58, 0>>)
    ),
    ?assertEqual(
        {{ok, #{<<"userMap">> => #{}}, <<>>}, {ok, #{<<"userMap">> => #{}}, <<>>}},
        Dec(<<"Insanity">>, <<16#1B, 0, 0>>)
    ),

    %% An over-long varint is bad_varint (i64_thing: delta 11, nibble 6,
    %% then ten continuation bytes).
    ?assertEqual(
        {{error, {decode, bad_varint}}, {error, {decode, bad_varint}}},
        Dec(<<"Xtruct">>, <<16#B6, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>)
    ),

    %% Unknown enum integers decode to themselves (a userMap key of 99
    %% stays 99; the value is an i64).
    ?assertEqual(
        {{ok, #{<<"userMap">> => #{99 => 1}}, <<>>}, {ok, #{<<"userMap">> => #{99 => 1}}, <<>>}},
        Dec(<<"Insanity">>, <<16#1B, 1, 16#56, 198, 1, 2, 0>>)
    ),

    %% Union rules and wrong value shapes, byte-for-byte generic.
    {union, UnionFields} = goldentest_types:struct_info(<<"SomeUnion">>),
    [N1, N2 | _] = [FieldName || {_, _, _, FieldName, _} <- UnionFields],
    ?assertEqual(
        {{error, {encode, union_empty}}, {error, {encode, union_empty}}},
        {Enc(Inline(<<"SomeUnion">>), #{}), Enc(Ref(<<"SomeUnion">>), #{})}
    ),
    UnionMultiple = #{N1 => true, N2 => <<"x">>},
    ?assertEqual(
        {{error, {encode, union_multiple}}, {error, {encode, union_multiple}}},
        {Enc(Inline(<<"SomeUnion">>), UnionMultiple), Enc(Ref(<<"SomeUnion">>), UnionMultiple)}
    ),
    BadScalar = #{<<"byte_thing">> => 200},
    ?assertEqual(
        {
            {error, {encode, {value_does_not_match_type, 200}}},
            {error, {encode, {value_does_not_match_type, 200}}}
        },
        {Enc(Inline(<<"Xtruct">>), BadScalar), Enc(Ref(<<"Xtruct">>), BadScalar)}
    ),
    ?assertEqual(
        {
            {error, {encode, {value_does_not_match_type, 42}}},
            {error, {encode, {value_does_not_match_type, 42}}}
        },
        {Enc(Inline(<<"Xtruct">>), 42), Enc(Ref(<<"Xtruct">>), 42)}
    ),
    ok.

%% The uuid fixture: compact has no uuid encoding, so every path through
%% a uuid type must fail exactly like the generic engine — and the
%% uuid-free parts of the same structs must still encode and decode.

uuid_compact_battery_test() ->
    ok = load_uuid_fixture(),
    Inline = fun(Name) -> {struct, compactuuid_types:struct_info(Name)} end,
    Ref = fun(Name) -> {struct, {ref, compactuuid_types, Name}} end,
    Enc = fun(Desc, Value) -> normalize(thrift_erl_compact:encode(Desc, Value)) end,
    Dec = fun(Name, Bytes) ->
        {thrift_erl_compact:decode(Inline(Name), Bytes), thrift_erl_compact:decode(Ref(Name), Bytes)}
    end,
    UuidError = {error, {encode, {type_not_supported, {base, uuid}, compact}}},

    %% Any present uuid value fails the whole encode.
    ?assertEqual(
        {UuidError, UuidError},
        {Enc(Inline(<<"UuidBox">>), #{<<"id">> => <<1:128>>}), Enc(Ref(<<"UuidBox">>), #{<<"id">> => <<1:128>>})}
    ),
    ?assertEqual(
        {UuidError, UuidError},
        {
            Enc(Inline(<<"UuidBox">>), #{<<"history">> => [<<1:128>>]}),
            Enc(Ref(<<"UuidBox">>), #{<<"history">> => [<<1:128>>]})
        }
    ),
    ?assertEqual(
        {UuidError, UuidError},
        {
            Enc(Inline(<<"UuidBox">>), #{<<"tags">> => #{<<2:128>> => 1}}),
            Enc(Ref(<<"UuidBox">>), #{<<"tags">> => #{<<2:128>> => 1}})
        }
    ),

    %% The uuid-free shape encodes: empty list header with the uuid
    %% element nibble 0 (k_unsupported writes 0), empty map byte, stop.
    UuidFree = #{<<"history">> => [], <<"tags">> => #{}},
    UuidFreeBytes = <<16#39, 16#00, 16#1B, 0, 0>>,
    ?assertEqual(
        {{ok, UuidFreeBytes}, {ok, UuidFreeBytes}},
        {Enc(Inline(<<"UuidBox">>), UuidFree), Enc(Ref(<<"UuidBox">>), UuidFree)}
    ),

    %% A known uuid field never matches any nibble.
    ?assertEqual(
        {{error, {decode, {field_type_mismatch, 1}}}, {error, {decode, {field_type_mismatch, 1}}}},
        Dec(<<"UuidBox">>, <<16#1C, 0>>)
    ),

    %% An unknown struct-nibble id is skipped; a uuid-element list header
    %% matches no nibble (element_type_mismatch carries the observed 0).
    ?assertEqual(
        {{error, {decode, {element_type_mismatch, 0}}}, {error, {decode, {element_type_mismatch, 0}}}},
        Dec(<<"UuidBox">>, <<16#9C, 16#55, 2, 0, 16#09, 6, 16#00, 0>>)
    ),

    %% Empty maps bypass the uuid types entirely; non-empty ones fail on
    %% the first uuid key or value.
    ?assertEqual(
        {{ok, #{<<"tags">> => #{}}, <<>>}, {ok, #{<<"tags">> => #{}}, <<>>}},
        Dec(<<"UuidBox">>, <<16#4B, 0, 0>>)
    ),
    UuidTypeError = {error, {decode, {type_not_supported, {base, uuid}, compact}}},
    %% map<uuid, i32> with the declared types byte (key 0, value 5):
    %% the first pair's uuid KEY decode fails.
    ?assertEqual(
        {UuidTypeError, UuidTypeError},
        Dec(<<"UuidBox">>, <<16#4B, 1, 16#05, 16#AA, 0>>)
    ),
    %% map<i32, uuid> with the declared types byte (key 5, value 0):
    %% the uuid VALUE decode fails.
    ?assertEqual(
        {UuidTypeError, UuidTypeError},
        Dec(<<"UuidBox">>, <<16#5B, 1, 16#50, 2, 16#AA, 0>>)
    ),
    %% A types byte the declaration does not carry (key i32, value uuid
    %% against map<uuid, i32>) is a map_type_mismatch before any uuid
    %% decode runs.
    ?assertEqual(
        {{error, {decode, map_type_mismatch}}, {error, {decode, map_type_mismatch}}},
        Dec(<<"UuidBox">>, <<16#4B, 1, 16#50, 2, 16#AA, 0>>)
    ),

    %% Missing required fields: declaration order on encode, ascending
    %% field-id order on decode — DoubleReq declares 3 before 1 on
    %% purpose, so the two orders differ.
    ?assertEqual(
        {
            {error, {encode, {missing_required_fields, [<<"first">>, <<"second">>]}}},
            {error, {encode, {missing_required_fields, [<<"first">>, <<"second">>]}}}
        },
        {Enc(Inline(<<"DoubleReq">>), #{}), Enc(Ref(<<"DoubleReq">>), #{})}
    ),
    ?assertEqual(
        {
            {error, {decode, {missing_required_fields, [<<"second">>, <<"first">>]}}},
            {error, {decode, {missing_required_fields, [<<"second">>, <<"first">>]}}}
        },
        Dec(<<"DoubleReq">>, <<0>>)
    ),
    Full = #{<<"first">> => 1, <<"second">> => <<"x">>},
    FullBytes = <<16#35, 2, 16#08, 2, 1, $x, 0>>,
    ?assertEqual(
        {{ok, FullBytes}, {ok, FullBytes}},
        {Enc(Inline(<<"DoubleReq">>), Full), Enc(Ref(<<"DoubleReq">>), Full)}
    ),
    ok.

%% JSON protocol: hand-computed wire documents checked against the
%% generic engine on both sides, plus the envelope-bracket rules — the
%% top-level decode folds one optional `]', the nested entry
%% (decode_nested/2, what generated cross-module refs call) never does.

json_negative_battery_test() ->
    ok = load_fixture(),
    Inline = fun(Name) -> {struct, goldentest_types:struct_info(Name)} end,
    Ref = fun(Name) -> {struct, {ref, goldentest_types, Name}} end,
    Enc = fun(Desc, Value) -> normalize(thrift_erl_json:encode(Desc, Value)) end,
    Dec = fun(Name, Doc) ->
        {thrift_erl_json:decode(Inline(Name), Doc), thrift_erl_json:decode(Ref(Name), Doc)}
    end,

    %% Missing required fields: declaration order on encode, ascending
    %% field-id order on decode (CrazyNesting's list_field, StructB's ab).
    Crazy = <<"CrazyNesting">>,
    MissingValue = #{<<"string_field">> => <<"x">>, <<"binary_field">> => <<"b">>},
    MissingError = {error, {encode, {missing_required_fields, [<<"list_field">>]}}},
    ?assertEqual(
        {MissingError, MissingError},
        {Enc(Inline(Crazy), MissingValue), Enc(Ref(Crazy), MissingValue)}
    ),
    ?assertEqual(
        {
            {error, {decode, {missing_required_fields, [<<"ab">>]}}},
            {error, {decode, {missing_required_fields, [<<"ab">>]}}}
        },
        Dec(<<"StructB">>, <<"{}">>)
    ),

    %% Known id with the wrong type tag: field_type_mismatch.
    ?assertEqual(
        {{error, {decode, {field_type_mismatch, 4}}}, {error, {decode, {field_type_mismatch, 4}}}},
        Dec(<<"Xtruct">>, <<"{\"4\":{\"i32\":1}}">>)
    ),

    %% Unknown field ids are skipped by their wire tag.
    SkipDoc = <<"{\"99\":{\"i64\":1},\"1\":{\"str\":\"a\"}}">>,
    ExpectedSkip = {ok, #{<<"string_thing">> => <<"a">>}, <<>>},
    ?assertEqual({ExpectedSkip, ExpectedSkip}, Dec(<<"Xtruct">>, SkipDoc)),

    %% The envelope bracket: the top-level decode folds one optional
    %% `]' (message payloads), decode_nested/2 never does.
    Folded = <<"{\"1\":{\"str\":\"a\"}}]">>,
    ?assertEqual(
        {{ok, #{<<"string_thing">> => <<"a">>}, <<>>}, {ok, #{<<"string_thing">> => <<"a">>}, <<>>}},
        Dec(<<"Xtruct">>, Folded)
    ),
    ?assertEqual(
        {ok, #{<<"string_thing">> => <<"a">>}, <<"]">>},
        thrift_erl_json:decode_nested(Ref(<<"Xtruct">>), Folded)
    ),
    Trailing = <<"{\"1\":{\"str\":\"a\"}}x">>,
    ?assertEqual(
        {{ok, #{<<"string_thing">> => <<"a">>}, <<"x">>}, {ok, #{<<"string_thing">> => <<"a">>}, <<"x">>}},
        Dec(<<"Xtruct">>, Trailing)
    ),

    %% Container headers: element mismatches carry the observed tag
    %% (binary), float sizes are bad_sequence_size, unsupported key
    %% texts are bad_map_key, non-numbers are bad_number.
    ?assertEqual(
        {{error, {decode, {element_type_mismatch, <<"i64">>}}}, {error, {decode, {element_type_mismatch, <<"i64">>}}}},
        Dec(<<"Insanity">>, <<"{\"1\":{\"map\":[\"i64\",\"i64\",1,{\"1\":2}]}}">>)
    ),
    ?assertEqual(
        {{error, {decode, {element_type_mismatch, <<"i32">>}}}, {error, {decode, {element_type_mismatch, <<"i32">>}}}},
        Dec(<<"Insanity">>, <<"{\"2\":{\"lst\":[\"i32\",1,1]}}">>)
    ),
    ?assertEqual(
        {{error, {decode, bad_sequence_size}}, {error, {decode, bad_sequence_size}}},
        Dec(<<"Insanity">>, <<"{\"2\":{\"lst\":[\"rec\",1.5,2]}}">>)
    ),
    ?assertEqual(
        {{error, {decode, bad_map_key}}, {error, {decode, bad_map_key}}},
        Dec(<<"VersioningTestV2">>, <<"{\"10\":{\"map\":[\"i32\",\"i32\",1,{\"x\":5}]}}">>)
    ),
    ?assertEqual(
        {{error, {decode, bad_number}}, {error, {decode, bad_number}}},
        Dec(<<"Xtruct">>, <<"{\"4\":{\"i8\":true}}">>)
    ),

    %% Distinct map keys whose JSON texts collide (the enum atom 'ONE'
    %% and the integer 1 both write "1") are refused on encode.
    DuplicateKeys = #{<<"userMap">> => #{'ONE' => 2, 1 => 3}, <<"xtructs">> => []},
    DuplicateError = {error, {encode, duplicate_json_keys}},
    ?assertEqual(
        {DuplicateError, DuplicateError},
        {Enc(Inline(<<"Insanity">>), DuplicateKeys), Enc(Ref(<<"Insanity">>), DuplicateKeys)}
    ),

    %% Union rules and wrong value shapes, document for document generic.
    {union, UnionFields} = goldentest_types:struct_info(<<"SomeUnion">>),
    [N1, N2 | _] = [FieldName || {_, _, _, FieldName, _} <- UnionFields],
    ?assertEqual(
        {{error, {encode, union_empty}}, {error, {encode, union_empty}}},
        {Enc(Inline(<<"SomeUnion">>), #{}), Enc(Ref(<<"SomeUnion">>), #{})}
    ),
    UnionMultiple = #{N1 => true, N2 => <<"x">>},
    ?assertEqual(
        {{error, {encode, union_multiple}}, {error, {encode, union_multiple}}},
        {Enc(Inline(<<"SomeUnion">>), UnionMultiple), Enc(Ref(<<"SomeUnion">>), UnionMultiple)}
    ),
    BadScalar = #{<<"byte_thing">> => 200},
    ?assertEqual(
        {
            {error, {encode, {value_does_not_match_type, 200}}},
            {error, {encode, {value_does_not_match_type, 200}}}
        },
        {Enc(Inline(<<"Xtruct">>), BadScalar), Enc(Ref(<<"Xtruct">>), BadScalar)}
    ),
    ok.

%% The uuid fixture through the JSON protocol: like compact, every path
%% through a uuid type must fail exactly like the generic engine — a
%% uuid-keyed map is refused whole (even empty), while a uuid-valued
%% map and a uuid-element list keep their machinery and fail per pair
%% or per element.

uuid_json_battery_test() ->
    ok = load_uuid_fixture(),
    Inline = fun(Name) -> {struct, compactuuid_types:struct_info(Name)} end,
    Ref = fun(Name) -> {struct, {ref, compactuuid_types, Name}} end,
    Enc = fun(Desc, Value) -> normalize(thrift_erl_json:encode(Desc, Value)) end,
    Dec = fun(Name, Doc) ->
        {thrift_erl_json:decode(Inline(Name), Doc), thrift_erl_json:decode(Ref(Name), Doc)}
    end,
    UuidError = {error, {encode, {type_not_supported, {base, uuid}, json}}},

    %% Any present uuid field fails the whole encode.
    ?assertEqual(
        {UuidError, UuidError},
        {Enc(Inline(<<"UuidBox">>), #{<<"id">> => <<1:128>>}), Enc(Ref(<<"UuidBox">>), #{<<"id">> => <<1:128>>})}
    ),
    ?assertEqual(
        {UuidError, UuidError},
        {
            Enc(Inline(<<"UuidBox">>), #{<<"history">> => [<<1:128>>]}),
            Enc(Ref(<<"UuidBox">>), #{<<"history">> => [<<1:128>>]})
        }
    ),
    ?assertEqual(
        {UuidError, UuidError},
        {
            Enc(Inline(<<"UuidBox">>), #{<<"tags_rev">> => #{1 => <<1:128>>}}),
            Enc(Ref(<<"UuidBox">>), #{<<"tags_rev">> => #{1 => <<1:128>>}})
        }
    ),

    %% A uuid-KEYED map is refused whole — even the empty map compiles
    %% to j_unsupported and carries the map descriptor in the error.
    MapError = {error, {encode, {type_not_supported, {map, {base, uuid}, {base, i32}}, json}}},
    ?assertEqual(
        {MapError, MapError},
        {
            Enc(Inline(<<"UuidBox">>), #{<<"tags">> => #{}}),
            Enc(Ref(<<"UuidBox">>), #{<<"tags">> => #{}})
        }
    ),

    %% The uuid-free shape encodes: empty uuid-element list header with
    %% the empty tag, empty uuid-valued map with the empty value tag.
    UuidFree = #{<<"history">> => [], <<"tags_rev">> => #{}},
    {ok, UuidFreeIo} = thrift_erl_json:encode(Inline(<<"UuidBox">>), UuidFree),
    UuidFreeDoc = iolist_to_binary(UuidFreeIo),
    ?assertEqual(
        {{ok, UuidFreeDoc}, {ok, UuidFreeDoc}},
        {Enc(Inline(<<"UuidBox">>), UuidFree), Enc(Ref(<<"UuidBox">>), UuidFree)}
    ),

    %% A declared uuid field matches only the empty tag; any real tag is
    %% a field_type_mismatch before the uuid error can fire.
    UuidTypeError = {error, {decode, {type_not_supported, {base, uuid}, json}}},
    ?assertEqual(
        {{ok, #{<<"history">> => []}, <<>>}, {ok, #{<<"history">> => []}, <<>>}},
        Dec(<<"UuidBox">>, <<"{\"3\":{\"lst\":[\"\",0]}}">>)
    ),
    ?assertEqual(
        {UuidTypeError, UuidTypeError},
        Dec(<<"UuidBox">>, <<"{\"3\":{\"lst\":[\"\",1,{\"\":{}}}]}}">>)
    ),
    ?assertEqual(
        {UuidTypeError, UuidTypeError},
        Dec(<<"UuidBox">>, <<"{\"1\":{\"\":{}}}">>)
    ),
    ?assertEqual(
        {{error, {decode, {field_type_mismatch, 1}}}, {error, {decode, {field_type_mismatch, 1}}}},
        Dec(<<"UuidBox">>, <<"{\"1\":{\"str\":\"x\"}}">>)
    ),

    %% The uuid-keyed map's empty tag matches its header, then the whole
    %% value is refused; an empty uuid-VALUED map decodes fine and a
    %% pair fails on the uuid value.
    UuidMapError = {error, {decode, {type_not_supported, {map, {base, uuid}, {base, i32}}, json}}},
    ?assertEqual(
        {UuidMapError, UuidMapError},
        Dec(<<"UuidBox">>, <<"{\"4\":{\"\":[\"\",\"i32\",0,{}]}}">>)
    ),
    ?assertEqual(
        {{ok, #{<<"tags_rev">> => #{}}, <<>>}, {ok, #{<<"tags_rev">> => #{}}, <<>>}},
        Dec(<<"UuidBox">>, <<"{\"5\":{\"map\":[\"i32\",\"\",0,{}]}}">>)
    ),
    ?assertEqual(
        {UuidTypeError, UuidTypeError},
        Dec(<<"UuidBox">>, <<"{\"5\":{\"map\":[\"i32\",\"\",1,{\"1\":{\"\":{}}}]}}">>)
    ),
    ok.

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
            deep_struct_case_one(Name, Value, thrift_erl_binary, fun goldentest_types:binary_codec/1),
            deep_struct_case_one(Name, Value, thrift_erl_compact, fun goldentest_types:compact_codec/1),
            deep_struct_case_one(Name, Value, thrift_erl_json, fun goldentest_types:json_codec/1)
        end,
        Values
    ).

%% For one value and protocol: the specialized and generic codecs must
%% agree on bytes, decoded values and errors alike, and every proper
%% prefix of a successful encoding asks for more (binary/compact) or at
%% least never completes (json — a cut inside a literal errors there).

deep_struct_case_one(Name, Value, Engine, Codec) ->
    Inline = {struct, goldentest_types:struct_info(Name)},
    Ref = {struct, {ref, goldentest_types, Name}},
    Generic = normalize(Engine:encode(Inline, Value)),
    Specialized = normalize(Engine:encode(Ref, Value)),
    ?assertEqual(Generic, Specialized),
    case Generic of
        {ok, Bytes} ->
            ?assertEqual(
                Engine:decode(Inline, Bytes),
                Engine:decode(Ref, Bytes)
            ),
            %% Every proper prefix stays incomplete.
            {ok, {_Encode, Decode}} = Codec(Name),
            lists:foreach(
                fun(Prefix) ->
                    case Decode(Prefix) of
                        more -> ok;
                        {error, _} when Engine =:= thrift_erl_json -> ok;
                        Other -> ?assertEqual(more, Other)
                    end
                end,
                [binary:part(Bytes, 0, N) || N <- lists:seq(1, byte_size(Bytes) - 1)]
            );
        _ ->
            ok
    end.

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
    %% binary_codec, compact_codec and json_codec answer error for
    %% unknown names, and the ref paths fall back to the generic
    %% unknown_struct report.
    ?assertEqual(error, goldentest_types:binary_codec(<<"Nope">>)),
    ?assertEqual(error, goldentest_types:compact_codec(<<"Nope">>)),
    ?assertEqual(error, goldentest_types:json_codec(<<"Nope">>)),
    ?assertEqual(
        {error, {decode, {unknown_struct, {goldentest_types, <<"Nope">>}}}},
        thrift_erl_binary:decode({struct, {ref, goldentest_types, <<"Nope">>}}, <<0>>)
    ),
    ?assertEqual(
        {error, {decode, {unknown_struct, {goldentest_types, <<"Nope">>}}}},
        thrift_erl_compact:decode({struct, {ref, goldentest_types, <<"Nope">>}}, <<0>>)
    ),
    ?assertEqual(
        {error, {decode, {unknown_struct, {goldentest_types, <<"Nope">>}}}},
        thrift_erl_json:decode({struct, {ref, goldentest_types, <<"Nope">>}}, <<"{}">>)
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

%% A second fixture exercising the uuid base type, which the golden
%% ThriftTest variant deliberately omits (compact cannot carry uuid).

load_uuid_fixture() ->
    case code:is_loaded(compactuuid_types) of
        {file, _} ->
            ok;
        false ->
            DataDir = filename:join(code:lib_dir(thrift_generator), "test/thrift_codec_test_data"),
            {ok, Loaded} = thrift_generator_loader:load(filename:join(DataDir, "CompactUuid.thrift")),
            {ok, Model0} = thrift_generator_semantic:analyze(Loaded),
            Model = Model0#tg_model{
                modules = [M#tg_module{name = <<"compactuuid">>} || M <- Model0#tg_model.modules]
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
