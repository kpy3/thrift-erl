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

%% Unit tests for the public API surface: the protocol and
%% representation axes of `thrift_erl`, the record engine's
%% auto-detection and conversions, strict facade decoding, frame
%% splitting, and the client's queueing/failure behavior (against a
%% real loopback server or a mute TCP peer).

-module(thrift_erl_facade_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    protocol_module_axis_test/0,
    facade_roundtrip_test/0,
    facade_strict_decode_test/0,
    facade_convert_test/0,
    record_engine_autodetect_test/0,
    record_engine_repr_test/0,
    record_engine_map_mode_test/0,
    record_engine_wire_passthrough_test/0,
    native_repr_test/0,
    encode_bad_value_shape_test/0,
    encode_strict_test/0,
    decode_bad_repr_test/0,
    decode_record_of_map_mode_test/0,
    options_defaults_test/0,
    extract_message_framed_test/0,
    extract_message_buffered_test/0,
    client_queue_serializes_test/0,
    client_start_unlinked_test/0,
    client_stop_with_pending_test/0,
    client_peer_close_fails_pending_test/0,
    client_call_timeout_test/0
]).

-define(SERVICE, thrift_erl_test_service).
-define(FIXTURE, thrift_erl_record_fixture).

%%--------------------------------------------------------------------
%% Protocol axis

protocol_module_axis_test() ->
    ?assertEqual({ok, thrift_erl_binary}, thrift_erl:protocol_module(binary)),
    ?assertEqual({ok, thrift_erl_compact}, thrift_erl:protocol_module(compact)),
    ?assertEqual({ok, thrift_erl_json}, thrift_erl:protocol_module(json)),
    %% the module axis verifies the callback set
    ?assertEqual({ok, thrift_erl_binary}, thrift_erl:protocol_module(thrift_erl_binary)),
    ?assertEqual({ok, thrift_erl_compact}, thrift_erl:protocol_module(thrift_erl_compact)),
    ?assertEqual({ok, thrift_erl_json}, thrift_erl:protocol_module(thrift_erl_json)),
    ?assertMatch({error, {bad_protocol, ?MODULE, _}}, thrift_erl:protocol_module(?MODULE)),
    ?assertMatch(
        {error, {bad_protocol, no_such_protocol_xyz, _}},
        thrift_erl:protocol_module(no_such_protocol_xyz)
    ),
    ?assertEqual({error, {bad_protocol, <<"binary">>}}, thrift_erl:protocol_module(<<"binary">>)),
    ok.

%%--------------------------------------------------------------------
%% Facade: encode/decode over the representation axis

facade_roundtrip_test() ->
    Desc = point_desc(),
    Record = {point, 1, 2},
    {ok, FromRecord} = thrift_erl:encode(Desc, Record),
    %% every input representation encodes to the same bytes
    ?assertEqual({ok, FromRecord}, thrift_erl:encode(Desc, #{x => 1, y => 2})),
    ?assertEqual({ok, FromRecord}, thrift_erl:encode(Desc, #{<<"x">> => 1, <<"y">> => 2})),
    ?assertEqual(
        {ok, FromRecord},
        thrift_erl:encode(Desc, #{'__struct__' => point, x => 1, y => 2})
    ),
    %% the protocol module axis drives the same codec
    ?assertEqual({ok, FromRecord}, thrift_erl:encode(Desc, Record, thrift_erl_binary)),
    ?assertEqual({ok, Record}, thrift_erl:decode(Desc, FromRecord, record)),
    ?assertEqual({ok, #{x => 1, y => 2}}, thrift_erl:decode(Desc, FromRecord, map)),
    Struct = #{'__struct__' => point, x => 1, y => 2},
    ?assertEqual({ok, Struct}, thrift_erl:decode(Desc, FromRecord, struct)),
    case otp_release() >= 29 of
        true ->
            {ok, Native} = thrift_erl:decode(Desc, FromRecord, native),
            ?assert(thrift_erl_native:is_native(Native)),
            %% a native record encodes back to the same bytes
            ?assertEqual({ok, FromRecord}, thrift_erl:encode(Desc, Native));
        false ->
            ?assertEqual(
                {error, {unsupported_repr, native}},
                thrift_erl:decode(Desc, FromRecord, native)
            )
    end,
    ok.

facade_strict_decode_test() ->
    Desc = point_desc(),
    {ok, Bin} = thrift_erl:encode(Desc, {point, 1, 2}),
    ?assertEqual({error, trailing}, thrift_erl:decode(Desc, <<Bin/binary, 0>>, record)),
    ?assertEqual(
        {error, truncated},
        thrift_erl:decode(Desc, binary:part(Bin, 0, byte_size(Bin) - 1), record)
    ),
    ok.

facade_convert_test() ->
    TagIndex = #{
        point => point_desc(),
        wrap => {struct, {ref, ?FIXTURE, <<"Wrap">>}},
        loose => {struct, {ref, ?FIXTURE, <<"Loose">>}}
    },
    ?assertEqual({ok, #{x => 1, y => 2}}, thrift_erl:convert(TagIndex, {point, 1, 2}, map)),
    ?assertEqual(
        {ok, {point, 1, 2}},
        thrift_erl:convert(TagIndex, #{'__struct__' => point, x => 1, y => 2}, record)
    ),
    %% conversion recurses into nested structs
    {ok, Nested} = thrift_erl:convert(TagIndex, {wrap, {point, 1, 2}}, struct),
    ?assertEqual(wrap, maps:get('__struct__', Nested)),
    ?assertEqual(point, maps:get('__struct__', maps:get(p, Nested))),
    %% a map-mode struct has no record to produce
    ?assertEqual(
        {error, {no_record, loose}},
        thrift_erl:convert(TagIndex, #{'__struct__' => loose, s => <<"v">>}, record)
    ),
    case otp_release() >= 29 of
        true ->
            {ok, Native} = thrift_erl:convert(TagIndex, {point, 1, 2}, native),
            ?assertEqual(1, records:get(x, Native));
        false ->
            ?assertEqual(
                {error, {unsupported_repr, native}},
                thrift_erl:convert(TagIndex, {point, 1, 2}, native)
            )
    end,
    ok.

%%--------------------------------------------------------------------
%% Record engine

record_engine_autodetect_test() ->
    Desc = point_desc(),
    Wire = #{<<"x">> => 1, <<"y">> => 2},
    ?assertEqual(Wire, thrift_erl_record:to_wire(Desc, {point, 1, 2})),
    ?assertEqual(Wire, thrift_erl_record:to_wire(Desc, #{x => 1, y => 2})),
    ?assertEqual(Wire, thrift_erl_record:to_wire(Desc, #{<<"x">> => 1, <<"y">> => 2})),
    ?assertEqual(
        Wire,
        thrift_erl_record:to_wire(Desc, #{'__struct__' => point, x => 1, y => 2})
    ),
    %% undefined fields are dropped, not encoded
    ?assertEqual(#{<<"x">> => 1}, thrift_erl_record:to_wire(Desc, {point, 1, undefined})),
    ok.

record_engine_repr_test() ->
    Wrap = {struct, {ref, ?FIXTURE, <<"Wrap">>}},
    Wire = #{<<"p">> => #{<<"x">> => 1, <<"y">> => 2}},
    ?assertEqual({wrap, {point, 1, 2}}, thrift_erl_record:from_wire(Wrap, Wire, record)),
    ?assertEqual(#{p => #{x => 1, y => 2}}, thrift_erl_record:from_wire(Wrap, Wire, map)),
    ?assertEqual(
        #{'__struct__' => wrap, p => #{'__struct__' => point, x => 1, y => 2}},
        thrift_erl_record:from_wire(Wrap, Wire, struct)
    ),
    %% fields missing on the wire decode as undefined, not crash
    Point = point_desc(),
    ?assertEqual(
        {point, 1, undefined},
        thrift_erl_record:from_wire(Point, #{<<"x">> => 1}, record)
    ),
    case otp_release() >= 29 of
        true ->
            %% native nests the same way: every record-mode struct on the
            %% path becomes a native record of its own
            WrapNative = thrift_erl_record:from_wire(Wrap, Wire, native),
            {_, _, Fields} = thrift_erl_native:fields(WrapNative),
            ?assertEqual(wrap, records:get_name(WrapNative)),
            ?assertEqual(1, records:get(x, maps:get(p, Fields)));
        false ->
            ok
    end,
    ok.

record_engine_map_mode_test() ->
    Bag = {struct, {ref, ?FIXTURE, <<"Bag">>}},
    %% a record-mode child inside a map-mode parent converts recursively
    {ok, Bin} = thrift_erl:encode(Bag, #{p => {point, 1, 2}}),
    ?assertEqual({ok, #{p => #{x => 1, y => 2}}}, thrift_erl:decode(Bag, Bin, map)),
    %% a map-mode struct has no record to produce: the `record` target
    %% is the same {error, {no_record, Tag}} convert/3 answers
    ?assertEqual({error, {no_record, bag}}, thrift_erl:decode(Bag, Bin, record)),
    %% {map, binary} structs take wire keys on input; the `map` target
    %% normalizes them to atoms
    BinKeys = {struct, {ref, ?FIXTURE, <<"BinKeys">>}},
    {ok, BinKeysBin} = thrift_erl:encode(BinKeys, #{<<"s">> => <<"v">>}),
    ?assertEqual({ok, #{s => <<"v">>}}, thrift_erl:decode(BinKeys, BinKeysBin, map)),
    ok.

record_engine_wire_passthrough_test() ->
    %% an inline descriptor carries no identity: values pass through
    Inline = {struct, {struct, [{1, default, {base, i32}, <<"v">>, undefined}]}},
    Value = #{<<"v">> => 5},
    ?assertEqual(Value, thrift_erl_record:to_wire(Inline, Value)),
    ?assertEqual(Value, thrift_erl_record:from_wire(Inline, Value, record)),
    %% a ref whose target has no record_fields entry is wire too
    Plain = {struct, {ref, ?FIXTURE, <<"Unknown">>}},
    ?assertEqual(Value, thrift_erl_record:to_wire(Plain, Value)),
    ?assertEqual(Value, thrift_erl_record:from_wire(Plain, Value, struct)),
    ok.

%% The EEP-79 axis: native records minted from the descriptor, read
%% through the `records` module, and accepted back by the auto-detector.

native_repr_test() ->
    case otp_release() >= 29 of
        false ->
            ?assertEqual(false, thrift_erl_native:supported());
        true ->
            Desc = point_desc(),
            {ok, Bin} = thrift_erl:encode(Desc, {point, 1, 2}),
            {ok, Native} = thrift_erl:decode(Desc, Bin, native),
            %% identity: the descriptor's module, the record tag
            ?assertEqual(?FIXTURE, records:get_module(Native)),
            ?assertEqual(point, records:get_name(Native)),
            {_, _, FieldMap} = thrift_erl_native:fields(Native),
            ?assertEqual(#{x => 1, y => 2}, FieldMap),
            %% fields missing on the wire decode as undefined
            {ok, PartialBin} = thrift_erl:encode(Desc, #{x => 1}),
            {ok, Partial} = thrift_erl:decode(Desc, PartialBin, native),
            ?assertEqual(#{x => 1, y => undefined}, element(3, thrift_erl_native:fields(Partial))),
            %% auto-detection: the native record normalizes to wire
            Wire = #{<<"x">> => 1, <<"y">> => 2},
            ?assertEqual(Wire, thrift_erl_record:to_wire(Desc, Native)),
            %% version drift: a newer definition's extra field is ignored,
            %% a declared field missing from the record is skipped
            Newer = thrift_erl_native:create(?FIXTURE, point, [{x, 1}, {y, 2}, {z, <<"extra">>}]),
            ?assertEqual(Wire, thrift_erl_record:to_wire(Desc, Newer)),
            Older = thrift_erl_native:create(?FIXTURE, point, [{x, 7}]),
            ?assertEqual(#{<<"x">> => 7}, thrift_erl_record:to_wire(Desc, Older)),
            %% a native record of another struct is a badrecord, as with tuples
            Wrap = {struct, {ref, ?FIXTURE, <<"Wrap">>}},
            ?assertError({badrecord, _}, thrift_erl:encode(Wrap, Native)),
            %% map-mode structs mint native records too
            Bag = {struct, {ref, ?FIXTURE, <<"Bag">>}},
            {ok, BagBin} = thrift_erl:encode(Bag, #{p => {point, 5, 6}}),
            {ok, BagNative} = thrift_erl:decode(Bag, BagBin, native),
            ?assertEqual(bag, records:get_name(BagNative)),
            %% the axis is protocol-independent
            {ok, JsonBin} = thrift_erl:encode(Desc, {point, 3, 4}, json),
            {ok, JsonNative} = thrift_erl:decode(Desc, JsonBin, native, json),
            ?assertEqual(4, records:get(y, JsonNative)),
            %% tuple records stay tuples
            ?assertNot(thrift_erl_native:is_native({point, 1, 2}))
    end,
    ok.

%% A value that matches no representation answers the same tagged
%% error the codecs use for scalar mismatches, instead of crashing the
%% caller with function_clause.

encode_bad_value_shape_test() ->
    Desc = point_desc(),
    ?assertEqual(
        {error, {value_does_not_match_type, 42}},
        thrift_erl:encode(Desc, 42)
    ),
    ?assertEqual(
        {error, {value_does_not_match_type, [1, 2]}},
        thrift_erl:encode(Desc, [1, 2])
    ),
    %% the record tag must match the descriptor's
    ?assertMatch(
        {error, {value_does_not_match_type, {other, 1, 2}}},
        thrift_erl:encode(Desc, {other, 1, 2})
    ),
    %% map-mode structs reject non-maps the same way
    Bag = {struct, {ref, ?FIXTURE, <<"Bag">>}},
    ?assertMatch(
        {error, {value_does_not_match_type, 9}},
        thrift_erl:encode(Bag, 9)
    ),
    ok.

%% strict=true checks the top-level map/struct-map input against the
%% declared fields; the default keeps the silent drop.

encode_strict_test() ->
    Desc = point_desc(),
    %% default: unknown keys are dropped silently
    ?assertMatch(
        {ok, _},
        thrift_erl:encode(Desc, #{x => 1, y => 2, zzz => 3})
    ),
    ?assertMatch(
        {error, {unknown_fields, [zzz]}},
        thrift_erl:encode(Desc, #{x => 1, y => 2, zzz => 3}, binary, #{strict => true})
    ),
    %% declared fields pass, atom or binary keyed
    ?assertMatch(
        {ok, _},
        thrift_erl:encode(Desc, #{x => 1, <<"y">> => 2}, binary, #{strict => true})
    ),
    %% a struct-map's __struct__ key is identity metadata, not a field
    ?assertMatch(
        {ok, _},
        thrift_erl:encode(Desc, #{'__struct__' => point, x => 1, y => 2}, binary, #{
            strict => true
        })
    ),
    %% a record tuple input has nothing to check
    ?assertMatch(
        {ok, _},
        thrift_erl:encode(Desc, {point, 1, 2}, binary, #{strict => true})
    ),
    %% map-mode structs are checked against their own key type
    Loose = {struct, {ref, ?FIXTURE, <<"Loose">>}},
    ?assertMatch(
        {error, {unknown_fields, [nope]}},
        thrift_erl:encode(Loose, #{s => <<"ok">>, nope => 1}, binary, #{strict => true})
    ),
    ok.

decode_bad_repr_test() ->
    Desc = point_desc(),
    {ok, Bin} = thrift_erl:encode(Desc, {point, 1, 2}),
    ?assertEqual({error, {bad_repr, maps}}, thrift_erl:decode(Desc, Bin, maps)),
    ?assertEqual({error, {bad_repr, whatever}}, thrift_erl:decode(Desc, Bin, whatever, compact)),
    ok.

%% A map-representation struct has no record to produce: decode answers
%% the same {error, {no_record, Tag}} convert/3 answers for it, instead
%% of silently returning an atom-keyed map.

decode_record_of_map_mode_test() ->
    Loose = {struct, {ref, ?FIXTURE, <<"Loose">>}},
    {ok, Bin} = thrift_erl:encode(Loose, #{s => <<"x">>}),
    ?assertEqual({error, {no_record, loose}}, thrift_erl:decode(Loose, Bin, record)),
    %% the map representation keeps working
    ?assertEqual({ok, #{s => <<"x">>}}, thrift_erl:decode(Loose, Bin, map)),
    ok.

%% The shared option defaults and the timeout umbrella.

options_defaults_test() ->
    ?assertEqual(5000, thrift_erl_options:idle_timeout(#{})),
    ?assertEqual(1000, thrift_erl_options:idle_timeout(#{timeout => 1000})),
    ?assertEqual(300, thrift_erl_options:idle_timeout(#{timeout => 1000, idle_timeout => 300})),
    %% the umbrella fills both meanings until a specific key splits them
    ?assertEqual(1000, thrift_erl_options:handshake_timeout(#{timeout => 1000})),
    ?assertEqual(250, thrift_erl_options:handshake_timeout(#{timeout => 1000, handshake_timeout => 250})),
    ?assertEqual(700, thrift_erl_options:connect_timeout(#{timeout => 1000, connect_timeout => 700})),
    ?assertEqual(framed, thrift_erl_options:transport(#{})),
    ?assertEqual(65536, thrift_erl_options:max_frame_size(#{max_frame_size => 65536})),
    ?assertEqual(7, thrift_erl_options:active_n(#{active_n => 7})),
    ?assertEqual(<<"/thrift">>, thrift_erl_options:http_path(#{http_path => <<"/thrift">>})),
    ?assertEqual({ok, thrift_erl_compact}, thrift_erl_options:protocol_module(#{protocol => compact})),
    ?assertMatch(
        {error, {bad_protocol, nope, _}},
        thrift_erl_options:protocol_module(#{protocol => nope})
    ),
    ok.

%%--------------------------------------------------------------------
%% Frame splitting

extract_message_framed_test() ->
    Max = 1024,
    ?assertEqual(
        {ok, <<"ABCD">>, <<>>},
        thrift_erl_socket:extract_message(<<4:32, "ABCD">>, framed, thrift_erl_binary, Max)
    ),
    ?assertEqual(more, thrift_erl_socket:extract_message(<<4:32, "AB">>, framed, thrift_erl_binary, Max)),
    ?assertEqual(more, thrift_erl_socket:extract_message(<<4>>, framed, thrift_erl_binary, Max)),
    %% the size prefix is checked before the payload arrives
    ?assertEqual(
        {error, frame_too_large},
        thrift_erl_socket:extract_message(<<2000:32, "junk">>, framed, thrift_erl_binary, Max)
    ),
    %% frames assembled byte by byte, nothing dropped or duplicated
    Two = <<8:32, "12345678", 2:32, "AB">>,
    ?assertEqual({[<<"12345678">>, <<"AB">>], <<>>}, drip(Two)),
    ok.

extract_message_buffered_test() ->
    Max = 1024,
    Desc = {struct, {struct, [{1, default, {base, i32}, <<"a">>, undefined}]}},
    {ok, Payload} = thrift_erl_binary:encode(Desc, #{<<"a">> => 5}),
    Message = iolist_to_binary(thrift_erl_binary:encode_message(call, <<"f">>, 7, Payload)),
    ?assertEqual(
        {ok, Message, <<>>},
        thrift_erl_socket:extract_message(Message, buffered, thrift_erl_binary, Max)
    ),
    %% a truncated but valid encoding is `more`, not an error
    ?assertEqual(
        more,
        thrift_erl_socket:extract_message(
            binary:part(Message, 0, byte_size(Message) - 1), buffered, thrift_erl_binary, Max
        )
    ),
    %% two messages back to back: one off, one left over
    ?assertEqual(
        {ok, Message, Message},
        thrift_erl_socket:extract_message(
            <<Message/binary, Message/binary>>, buffered, thrift_erl_binary, Max
        )
    ),
    ?assertMatch(
        {error, {bad_frame, _}},
        thrift_erl_socket:extract_message(<<255, 255, 255, 255>>, buffered, thrift_erl_binary, Max)
    ),
    %% max_frame_size bounds a buffered message the same way it bounds
    %% the framed length prefix: truncated growth past the cap and a
    %% complete message over the cap are both rejected
    Truncated = binary:part(Message, 0, byte_size(Message) - 1),
    ?assertEqual(
        {error, frame_too_large},
        thrift_erl_socket:extract_message(
            Truncated, buffered, thrift_erl_binary, byte_size(Truncated) - 1
        )
    ),
    ?assertEqual(
        more,
        thrift_erl_socket:extract_message(
            Truncated, buffered, thrift_erl_binary, byte_size(Truncated)
        )
    ),
    ?assertEqual(
        {error, frame_too_large},
        thrift_erl_socket:extract_message(
            Message, buffered, thrift_erl_binary, byte_size(Message) - 1
        )
    ),
    %% a complete message extracts from an over-cap buffer (the leftover
    %% is then judged on its own)
    ?assertEqual(
        {ok, Message, Message},
        thrift_erl_socket:extract_message(
            <<Message/binary, Message/binary>>, buffered, thrift_erl_binary, byte_size(Message)
        )
    ),
    ok.

%%--------------------------------------------------------------------
%% Client behaviors

client_queue_serializes_test() ->
    with_server(#{}, fun(Port) ->
        {ok, Client} =
            thrift_erl_client:start_link(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
        try
            Parent = self(),
            [
                spawn(fun() ->
                    Parent ! {res, N, thrift_erl_client:call(Client, <<"add">>, [N, N], 5000)}
                end)
             || N <- lists:seq(1, 5)
            ],
            Results =
                lists:sort([
                    receive
                        {res, N, R} ->
                            {N, R}
                    after 5000 ->
                        erlang:error(queue_reply_timeout)
                    end
                 || _ <- lists:seq(1, 5)
                ]),
            ?assertEqual([{N, {ok, 2 * N}} || N <- lists:seq(1, 5)], Results)
        after
            stop_quietly(Client)
        end
    end).

client_start_unlinked_test() ->
    %% `start/1` is the pool-worker entry: unlinked, same behavior
    with_server(#{}, fun(Port) ->
        {ok, Client} = thrift_erl_client:start(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
        try
            ?assertEqual({ok, 4}, thrift_erl_client:call(Client, <<"add">>, [1, 3], 5000))
        after
            stop_quietly(Client)
        end
    end).

client_stop_with_pending_test() ->
    {Port, Peer} = raw_peer(),
    {ok, Client} = thrift_erl_client:start(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
    wait_peer(),
    Caller = self(),
    spawn(fun() -> Caller ! {res, thrift_erl_client:call(Client, <<"add">>, [1, 2], 5000)} end),
    timer:sleep(100),
    %% stop answers the pending call instead of leaving it hanging
    ok = thrift_erl_client:stop(Client),
    assert_caller_result({error, closed}),
    Peer ! close,
    ok.

client_peer_close_fails_pending_test() ->
    {Port, Peer} = raw_peer(),
    {ok, Client} = thrift_erl_client:start(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
    wait_peer(),
    Caller = self(),
    spawn(fun() -> Caller ! {res, thrift_erl_client:call(Client, <<"add">>, [1, 2], 5000)} end),
    timer:sleep(100),
    %% the dead peer reaches the pending caller as a socket close
    Peer ! close,
    assert_caller_result({error, closed}),
    assert_dead(Client),
    ok.

client_call_timeout_test() ->
    {Port, Peer} = raw_peer(),
    {ok, Client} = thrift_erl_client:start(#{host => "127.0.0.1", port => Port, service => ?SERVICE}),
    wait_peer(),
    %% the mute peer never answers: the per-call timer fires
    ?assertEqual({error, timeout}, thrift_erl_client:call(Client, <<"add">>, [1, 2], 200)),
    assert_dead(Client),
    Peer ! close,
    ok.

%%--------------------------------------------------------------------
%% Helpers

-spec point_desc() -> thrift_erl_binary:type_desc().
point_desc() ->
    {struct, {ref, ?FIXTURE, <<"Point">>}}.

%% Native records (EEP-79) and their `records` module exist from OTP 29
%% on; every native assertion is gated on the running release so the
%% suite stays green across the CI matrix.

-spec otp_release() -> non_neg_integer().
otp_release() ->
    list_to_integer(erlang:system_info(otp_release)).

-spec assert_caller_result(term()) -> ok.
assert_caller_result(Expected) ->
    ?assertEqual(
        Expected,
        receive
            {res, R} ->
                R
        after 2000 ->
            erlang:error(pending_not_answered)
        end
    ),
    ok.

-spec assert_dead(pid()) -> ok.
assert_dead(Pid) ->
    timer:sleep(50),
    ?assertNot(erlang:is_process_alive(Pid)),
    ok.

%% Feeds the stream one byte at a time; answers every complete frame in
%% order plus whatever incomplete tail is left.

-spec drip(binary()) -> {[binary()], binary()}.
drip(Bytes) ->
    drip(Bytes, <<>>, []).

-spec drip(binary(), binary(), [binary()]) -> {[binary()], binary()}.
drip(<<Byte, Rest/binary>>, Buffer, Frames) ->
    Next = <<Buffer/binary, Byte>>,
    case thrift_erl_socket:extract_message(Next, framed, thrift_erl_binary, 1024) of
        {ok, Message, Leftover} ->
            drip(Rest, Leftover, [Message | Frames]);
        more ->
            drip(Rest, Next, Frames)
    end;
drip(<<>>, Buffer, Frames) ->
    {lists:reverse(Frames), Buffer}.

%% The Test fun receives the ephemeral server port; the server owns the
%% lifecycle, the caller cleans up the client.

-spec with_server(map(), fun((inet:port_number()) -> term())) -> term().
with_server(Opts, Test) ->
    Base = #{port => 0, handler => thrift_erl_test_handler, service => ?SERVICE},
    {ok, Server} = thrift_erl_server:start_link(maps:merge(Base, Opts)),
    try
        {ok, Port} = thrift_erl_server:port(Server),
        Test(Port)
    after
        stop_quietly(Server)
    end.

-spec stop_quietly(pid()) -> ok.
stop_quietly(Server) ->
    try thrift_erl_server:stop(Server) of
        ok ->
            ok;
        _Other ->
            ok
    catch
        _:_ ->
            ok
    end.

%% A mute TCP endpoint: accepts one connection and never speaks. The
%% accepted socket stays with the peer process; `close` tears everything
%% down.

-spec raw_peer() -> {inet:port_number(), pid()}.
raw_peer() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Parent = self(),
    Peer =
        spawn_link(fun() ->
            {ok, Socket} = gen_tcp:accept(Listen),
            Parent ! peer_up,
            raw_peer_loop(Socket, Listen)
        end),
    {Port, Peer}.

-spec raw_peer_loop(gen_tcp:socket(), gen_tcp:socket()) -> ok.
raw_peer_loop(Socket, Listen) ->
    receive
        close ->
            gen_tcp:close(Socket),
            gen_tcp:close(Listen),
            ok;
        {tcp_closed, Socket} ->
            gen_tcp:close(Listen),
            ok;
        {tcp_error, Socket, _} ->
            gen_tcp:close(Listen),
            ok
    end.

-spec wait_peer() -> ok.
wait_peer() ->
    receive
        peer_up ->
            ok
    after 2000 ->
        erlang:error(peer_not_accepted)
    end.
