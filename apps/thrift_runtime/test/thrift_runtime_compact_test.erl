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

%% Unit tests for the compact codec: known wire bytes (cross-checked
%% against the Apache TCompactProtocol rules the vendored reference
%% implements), round-trips over every descriptor kind, the delta/long
%% field-header forms, boolean-in-nibble struct fields, unknown-field
%% skipping, message envelope, and `more`-on-truncation.

-module(thrift_runtime_compact_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    integer_encodings_test/0,
    double_and_string_test/0,
    bool_values_test/0,
    field_headers_test/0,
    struct_roundtrip_test/0,
    collections_test/0,
    skip_unknown_fields_test/0,
    message_envelope_test/0,
    application_exception_test/0,
    more_semantics_test/0,
    uuid_unsupported_test/0,
    enum_test/0
]).

%%--------------------------------------------------------------------
%% Integers: zigzag varint, known bytes

integer_encodings_test() ->
    ?assertEqual(<<2>>, encb({base, i32}, 1)),
    ?assertEqual(<<1>>, encb({base, i32}, -1)),
    ?assertEqual(<<0>>, encb({base, i32}, 0)),
    %% 300 -> zigzag 600 -> varint <<216, 4>>
    ?assertEqual(<<216, 4>>, encb({base, i32}, 300)),
    %% i16 extremes
    ?assertEqual(<<255, 255, 3>>, encb({base, i16}, -32768)),
    ?assertEqual(<<254, 255, 3>>, encb({base, i16}, 32767)),
    %% i64 extremes
    ?assertEqual(<<255, 255, 255, 255, 255, 255, 255, 255, 255, 1>>, encb({base, i64}, -1 bsl 63)),
    ?assertEqual(
        <<254, 255, 255, 255, 255, 255, 255, 255, 255, 1>>,
        encb({base, i64}, 16#7FFFFFFFFFFFFFFF)
    ),
    %% i8 stays a raw byte
    ?assertEqual(<<254>>, encb({base, i8}, -2)),
    %% decode reverses the encodings
    {ok, One, <<>>} = thrift_runtime_compact:decode({base, i32}, <<2>>),
    ?assertEqual(1, One),
    {ok, Min16, <<>>} = thrift_runtime_compact:decode({base, i16}, <<255, 255, 3>>),
    ?assertEqual(-32768, Min16),
    {ok, Max64, <<>>} =
        thrift_runtime_compact:decode({base, i64}, <<254, 255, 255, 255, 255, 255, 255, 255, 255, 1>>),
    ?assertEqual(16#7FFFFFFFFFFFFFFF, Max64),
    %% out-of-range values are refused, not truncated
    ?assertMatch({error, _}, thrift_runtime_compact:encode({base, i16}, 40000)),
    ok.

%%--------------------------------------------------------------------
%% Doubles are little-endian; strings carry a varint length

double_and_string_test() ->
    ?assertEqual(<<0, 0, 0, 0, 0, 0, 240, 63>>, encb({base, double}, 1.0)),
    ?assertEqual(<<0, 0, 0, 0, 0, 0, 0, 192>>, encb({base, double}, -2.0)),
    {ok, D, <<>>} = thrift_runtime_compact:decode({base, double}, <<0, 0, 0, 0, 0, 0, 240, 63>>),
    ?assertEqual(1.0, D),
    ?assertEqual(<<2, "ab">>, encb({base, string}, <<"ab">>)),
    ?assertEqual(<<0>>, encb({base, binary}, <<>>)),
    {ok, <<"hello">>, <<"more">>} = thrift_runtime_compact:decode({base, string}, <<5, "hellomore">>),
    ok.

%%--------------------------------------------------------------------
%% Booleans: cbool bytes in value positions

bool_values_test() ->
    %% standalone (collection element) values: 1 and 2
    ?assertEqual(<<1>>, encb({base, bool}, true)),
    ?assertEqual(<<2>>, encb({base, bool}, false)),
    {ok, true, <<>>} = thrift_runtime_compact:decode({base, bool}, <<1>>),
    {ok, false, <<>>} = thrift_runtime_compact:decode({base, bool}, <<2>>),
    %% list<bool>: the element nibble is CT_TRUE, elements are cbool bytes
    ?assertEqual(<<16#21, 1, 2>>, encb({list, {base, bool}}, [true, false])),
    {ok, [true, false], <<>>} = dec({list, {base, bool}}, <<16#21, 1, 2>>),
    %% the official Erlang runtime writes the boolean element nibble as
    %% CT_FALSE (2); both boolean nibbles read back the same way
    {ok, [true, false], <<>>} = dec({list, {base, bool}}, <<16#22, 1, 2>>),
    %% sets share the wire format with lists
    ?assertEqual(<<16#21, 1, 2>>, encb({set, {base, bool}}, [true, false])),
    {ok, [true, false], <<>>} = dec({set, {base, bool}}, <<16#21, 1, 2>>),
    %% anything but a boolean fails
    ?assertMatch({error, _}, thrift_runtime_compact:encode({base, bool}, 1)),
    ok.

%%--------------------------------------------------------------------
%% Struct field headers: delta short form, long form, boolean nibble

field_headers_test() ->
    %% fields 1 and 2: delta 1 short forms, types i32 (5) and string (8)
    Desc =
        {struct,
            {struct, [
                {1, default, {base, i32}, <<"a">>, undefined},
                {2, default, {base, string}, <<"b">>, undefined}
            ]}},
    Bin = encb(Desc, #{<<"a">> => 1, <<"b">> => <<"x">>}),
    ?assertEqual(<<16#15, 2, 16#18, 1, "x", 0>>, Bin),
    %% absent middle field: field 3 written, field 2 not — delta counts
    %% from the last WRITTEN id (1 -> 3, delta 2)
    Gapped =
        {struct,
            {struct, [
                {1, default, {base, i32}, <<"a">>, undefined},
                {2, default, {base, i32}, <<"gone">>, undefined},
                {3, default, {base, i32}, <<"c">>, undefined}
            ]}},
    ?assertEqual(<<16#15, 2, 16#25, 4, 0>>, encb(Gapped, #{<<"a">> => 1, <<"c">> => 2})),
    %% delta > 15 falls back to the long form: type byte then zigzag id
    Far =
        {struct,
            {struct, [
                {1, default, {base, i32}, <<"a">>, undefined},
                {20, default, {base, i32}, <<"z">>, undefined}
            ]}},
    %% type byte 5, zigzag(20)=40, value 3 -> zigzag 6
    ?assertEqual(<<16#15, 2, 5, 40, 6, 0>>, encb(Far, #{<<"a">> => 1, <<"z">> => 3})),
    %% a boolean field has no payload: the nibble IS the value
    BoolDesc = {struct, {struct, [{1, default, {base, bool}, <<"f">>, undefined}]}},
    ?assertEqual(<<16#11, 0>>, encb(BoolDesc, #{<<"f">> => true})),
    ?assertEqual(<<16#12, 0>>, encb(BoolDesc, #{<<"f">> => false})),
    %% long-form boolean: the type byte carries TRUE, the id follows
    FarBool = {struct, {struct, [{20, default, {base, bool}, <<"f">>, undefined}]}},
    ?assertEqual(<<1, 40, 0>>, encb(FarBool, #{<<"f">> => true})),
    %% decoding restores everything
    {ok, #{<<"a">> := 1, <<"b">> := <<"x">>}, <<>>} = dec(Desc, Bin),
    {ok, #{<<"f">> := true}, <<>>} = dec(FarBool, <<1, 40, 0>>),
    ok.

%%--------------------------------------------------------------------
%% Struct round-trips: refs, required, union, trailing bytes

struct_roundtrip_test() ->
    %% nested ref resolves through thrift_runtime_test_service (point)
    Wrap =
        {struct,
            {struct, [
                {1, default, {struct, {ref, thrift_runtime_test_service, <<"point">>}}, <<"p">>, undefined},
                {2, default, {base, i32}, <<"n">>, undefined}
            ]}},
    Value = #{<<"p">> => #{<<"x">> => -1, <<"y">> => 2}, <<"n">> => 7},
    Bin = encb(Wrap, Value),
    %% the wire shape: nested struct header 0x1C, inner fields, stop,
    %% then field 2 with delta 1
    ?assertEqual(<<16#1C, 16#15, 1, 16#15, 4, 0, 16#15, 14, 0>>, Bin),
    {ok, Value, <<>>} = dec(Wrap, Bin),
    %% trailing bytes come back
    {ok, #{<<"n">> := 7}, <<"tail">>} = dec(Wrap, <<Bin/binary, "tail">>),
    %% required field missing on decode
    Req = {struct, {struct, [{1, required, {base, i32}, <<"r">>, undefined}]}},
    ?assertMatch({error, {decode, {missing_required_fields, _}}}, dec(Req, <<0>>)),
    %% union: exactly one field
    Union =
        {struct,
            {union, [
                {1, default, {base, i32}, <<"a">>, undefined},
                {2, default, {base, i32}, <<"b">>, undefined}
            ]}},
    UnionBin = encb(Union, #{<<"b">> => 5}),
    {ok, #{<<"b">> := 5}, <<>>} = dec(Union, UnionBin),
    ?assertMatch({error, {encode, union_empty}}, thrift_runtime_compact:encode(Union, #{})),
    ?assertMatch(
        {error, {encode, union_multiple}},
        thrift_runtime_compact:encode(Union, #{<<"a">> => 1, <<"b">> => 2})
    ),
    ok.

%%--------------------------------------------------------------------
%% Collections: short and long headers, empty map, sorted map pairs

collections_test() ->
    %% size 14 fits the header byte's high nibble: (14<<4)|LIST nibble 9
    Seq14 = lists:seq(1, 14),
    ?assertEqual(16#E4, binary:first(encb({list, {base, i16}}, Seq14))),
    {ok, Seq14, <<>>} = dec({list, {base, i16}}, encb({list, {base, i16}}, Seq14)),
    %% size 15 sets the F nibble and a varint size follows
    Seq15 = lists:seq(1, 15),
    ?assertEqual(<<16#F4, 15>>, binary:part(encb({list, {base, i16}}, Seq15), 0, 2)),
    {ok, Seq15, <<>>} = dec({list, {base, i16}}, encb({list, {base, i16}}, Seq15)),
    %% sets share the list wire format: the header carries the element
    %% nibble, so a set<i32> encodes exactly like a list<i32>
    ?assertEqual(<<16#25, 2, 4>>, encb({set, {base, i32}}, [1, 2])),
    {ok, [1, 2], <<>>} = dec({set, {base, i32}}, <<16#25, 2, 4>>),
    %% empty map is the single zero byte
    ?assertEqual(<<0>>, encb({map, {base, i32}, {base, i32}}, #{})),
    {ok, #{}, <<>>} = dec({map, {base, i32}, {base, i32}}, <<0>>),
    %% non-empty map: varint size, key/value nibbles, pairs sorted by key
    MapBin = encb({map, {base, i32}, {base, i32}}, #{2 => 20, 1 => 10}),
    ?assertEqual(<<2, 85, 2, 20, 4, 40>>, MapBin),
    {ok, #{1 := 10, 2 := 20}, <<>>} = dec({map, {base, i32}, {base, i32}}, MapBin),
    %% nested collections: the inner header's nibble is checked against
    %% the compiled element type
    {ok, [[1, 2], [3]], <<>>} = dec({list, {list, {base, i32}}}, encb({list, {list, {base, i32}}}, [[1, 2], [3]])),
    %% a map as a struct field: the field nibble goes through the same
    %% type check as scalars
    MapField = {struct, {struct, [{1, default, {map, {base, i32}, {base, i32}}, <<"m">>, undefined}]}},
    {ok, #{<<"m">> := #{1 := 10}}, <<>>} = dec(MapField, encb(MapField, #{<<"m">> => #{1 => 10}})),
    ok.

%%--------------------------------------------------------------------
%% Unknown fields are skipped by compact type, decode continues

skip_unknown_fields_test() ->
    %% the descriptor knows only field 2; every case carries an unknown
    %% field 1 followed by the known one (delta 1 after id 1)
    Known = {struct, {struct, [{2, default, {base, i32}, <<"k">>, undefined}]}},
    %% unknown i32: the varint payload is skipped
    WithI32 = <<16#15, 216, 4, 16#15, 8, 0>>,
    {ok, #{<<"k">> := 4}, <<>>} = dec(Known, WithI32),
    %% unknown binary: length-prefixed payload skipped
    WithBin = <<16#18, 3, "abc", 16#15, 18, 0>>,
    {ok, #{<<"k">> := 9}, <<>>} = dec(Known, WithBin),
    %% unknown nested struct with its own field and stop
    WithStruct = <<16#1C, 16#15, 2, 0, 16#15, 4, 0>>,
    {ok, #{<<"k">> := 2}, <<>>} = dec(Known, WithStruct),
    %% unknown boolean: nothing beyond the header byte
    WithBool = <<16#12, 16#15, 2, 0>>,
    {ok, #{<<"k">> := 1}, <<>>} = dec(Known, WithBool),
    %% unknown list with one element: field header (nibble LIST),
    %% collection header (size 1, element nibble i32), element
    WithList = <<16#19, 16#15, 2, 16#15, 6, 0>>,
    {ok, #{<<"k">> := 3}, <<>>} = dec(Known, WithList),
    %% unknown list of binaries: elements are length-prefixed strings,
    %% the collection header's element nibble (BINARY) drives the skip
    WithStrings = <<16#19, 16#28, 1, "a", 1, "b", 16#15, 18, 0>>,
    {ok, #{<<"k">> := 9}, <<>>} = dec(Known, WithStrings),
    %% unknown map with one pair
    WithMap = <<16#1B, 1, 85, 2, 20, 16#15, 10, 0>>,
    {ok, #{<<"k">> := 5}, <<>>} = dec(Known, WithMap),
    ok.

%%--------------------------------------------------------------------
%% Message envelope: 0x82, version|type, varint seqid, name

message_envelope_test() ->
    ?assertEqual(
        <<16#82, 16#21, 1, 3, "add">>,
        iolist_to_binary(thrift_runtime_compact:encode_message(call, <<"add">>, 1, <<>>))
    ),
    %% each message type occupies the top three bits
    {ok, call, <<"f">>, 0, <<>>} = roundtrip_message(call),
    {ok, reply, <<"f">>, 0, <<>>} = roundtrip_message(reply),
    {ok, exception, <<"f">>, 0, <<>>} = roundtrip_message(exception),
    {ok, oneway, <<"f">>, 0, <<>>} = roundtrip_message(oneway),
    %% big seqid rides the varint
    {ok, reply, <<"f">>, 12345, <<>>} = roundtrip_message(reply, <<"f">>, 12345),
    %% payload survives untouched
    WithPayload =
        iolist_to_binary(thrift_runtime_compact:encode_message(call, <<"f">>, 1, <<9, 9>>)),
    {ok, call, <<"f">>, 1, <<9, 9>>} = thrift_runtime_compact:decode_message(WithPayload),
    %% bad version and unknown type are errors, not more
    ?assertMatch(
        {error, {decode, {bad_protocol_version, 2}}},
        thrift_runtime_compact:decode_message(<<16#82, 16#22, 0, 0>>)
    ),
    ?assertMatch(
        {error, {decode, {unknown_message_type, 7}}},
        thrift_runtime_compact:decode_message(<<16#82, 16#E1, 0>>)
    ),
    ok.

%%--------------------------------------------------------------------
%% TApplicationException round-trip in compact encoding

application_exception_test() ->
    %% field 1 message string, field 2 code as zigzag i32
    {ok, ExceptionIo} = thrift_runtime_compact:encode_application_exception(<<"boom">>, 6),
    Payload = iolist_to_binary(ExceptionIo),
    ?assertEqual(<<16#18, 4, "boom", 16#15, 12, 0>>, Payload),
    {ok, #{message := <<"boom">>, code := 6, name := <<"INTERNAL_ERROR">>}, <<>>} =
        thrift_runtime_compact:decode_application_exception(Payload),
    %% a message-less payload decodes with the defaults
    {ok, #{message := <<>>, code := 0, name := <<"UNKNOWN">>}, <<>>} =
        thrift_runtime_compact:decode_application_exception(<<0>>),
    ok.

%%--------------------------------------------------------------------
%% Every truncation of a valid encoding is `more`, never garbage

more_semantics_test() ->
    %% varint cut mid-stream
    ?assertEqual(more, thrift_runtime_compact:decode({base, i32}, <<216>>)),
    ?assertEqual(more, thrift_runtime_compact:decode({base, i64}, <<255, 255, 255>>)),
    %% binary payload shorter than its length
    ?assertEqual(more, thrift_runtime_compact:decode({base, string}, <<5, "abc">>)),
    %% double needs all 8 bytes
    ?assertEqual(more, thrift_runtime_compact:decode({base, double}, <<0, 0, 0, 0>>)),
    %% truncated struct: value without the stop byte
    SDesc = {struct, {struct, [{1, default, {base, i32}, <<"a">>, undefined}]}},
    ?assertEqual(more, dec(SDesc, <<16#15, 2>>)),
    %% truncated envelope: the header alone (id 0x82) is more, and every
    %% cut inside the fixed part (version byte, seqid, name) is more
    ?assertEqual(more, thrift_runtime_compact:decode_message(<<16#82>>)),
    ?assertEqual(more, thrift_runtime_compact:decode_message(<<16#82, 16#21, 1>>)),
    ?assertEqual(more, thrift_runtime_compact:decode_message(<<16#82, 16#21, 1, 3>>)),
    ?assertEqual(more, thrift_runtime_compact:decode_message(<<16#82, 16#21, 1, 3, "fu">>)),
    ok.

%%--------------------------------------------------------------------
%% uuid has no compact encoding

uuid_unsupported_test() ->
    ?assertMatch(
        {error, {encode, {type_not_supported, {base, uuid}, compact}}},
        thrift_runtime_compact:encode({base, uuid}, <<0:128>>)
    ),
    ?assertMatch(
        {error, {decode, {type_not_supported, {base, uuid}, compact}}},
        thrift_runtime_compact:decode({base, uuid}, <<0:128>>)
    ),
    %% the same refusal arrives from a struct field carrying one
    U = {struct, {struct, [{1, default, {base, uuid}, <<"u">>, undefined}]}},
    ?assertMatch(
        {error, {encode, {type_not_supported, {base, uuid}, compact}}},
        thrift_runtime_compact:encode(U, #{<<"u">> => <<0:128>>})
    ),
    ok.

%%--------------------------------------------------------------------
%% Enums: zigzag i32, unknown ints pass through

enum_test() ->
    Desc = {enum, [{1, 'ONE'}, {2, 'TWO'}]},
    %% zigzag(2) = 4
    ?assertEqual(<<4>>, encb(Desc, 'TWO')),
    {ok, 'TWO', <<>>} = dec(Desc, <<4>>),
    %% an unknown int comes back as itself (zigzag 99 -> 198 -> varint)
    {ok, 99, <<>>} = dec(Desc, <<198, 1>>),
    ok.

%%--------------------------------------------------------------------
%% Helpers

-spec roundtrip_message(thrift_runtime_binary:message_type()) ->
    {ok, thrift_runtime_binary:message_type(), binary(), non_neg_integer(), binary()}.
roundtrip_message(Type) ->
    roundtrip_message(Type, <<"f">>, 0).

-spec roundtrip_message(thrift_runtime_binary:message_type(), binary(), non_neg_integer()) ->
    {ok, thrift_runtime_binary:message_type(), binary(), non_neg_integer(), binary()}.
roundtrip_message(Type, Name, SeqId) ->
    Message = iolist_to_binary(thrift_runtime_compact:encode_message(Type, Name, SeqId, <<>>)),
    thrift_runtime_compact:decode_message(Message).

-spec encb(thrift_runtime_binary:type_desc(), term()) -> binary().
encb(Type, Value) ->
    {ok, Io} = thrift_runtime_compact:encode(Type, Value),
    iolist_to_binary(Io).

-spec dec(thrift_runtime_binary:type_desc(), iodata()) -> thrift_runtime_binary:decode_result(term()).
dec(Type, Bin) ->
    thrift_runtime_compact:decode(Type, iolist_to_binary(Bin)).
