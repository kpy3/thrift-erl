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

-module(thrift_bench).

-moduledoc """
Manual codec-level benchmark of the protocol implementations in the
repository, measured with erlperf and driven from the same ThriftTest
fixture as the golden interop suite:

- **ours (binary)** — `thrift_erl_binary` over the introspection
  descriptors of the in-memory generated `goldentest_types` module;
- **ours (compact)** — `thrift_erl_compact` over the same descriptors;
- **reference (binary)** — the vendored Apache Thrift 0.25.0 Erlang
  runtime (`thrift_binary_protocol` over `thrift_membuffer_transport`)
  with the committed officially generated `thrift_test_types`;
- **reference (compact)** — the same runtime's
  `thrift_compact_protocol`.

Each case first proves the codecs agree: our bytes must decode back
through the official reader of the same protocol into the expected
record (both directions of wire compatibility, one per protocol), and
each of the four codecs must round-trip its own encoding. Only then
are encode and decode benchmarked separately, in erlperf continuous
mode: one discarded warmup sample followed by three 500 ms samples,
concurrency 1; the reported number is erlperf's average iterations per
second with the sample stddev. Encode numbers measure the write cost
only — the official membuffer transport keeps its bytes private,
identically for both protocols.

This is a hand-run script, not a test: run it with `scripts/bench` (or
`erl -pa _build/test/lib/*/ebin -run thrift_bench main`). Knobs come
from the environment: `BENCH_WARMUP` (default 1), `BENCH_SAMPLES`
(default 3), `BENCH_SAMPLE_MS` (default 500). Reference numbers include
a fresh membuffer transport and protocol per operation — that API has
no way to decode a bare binary, so the construction is part of its
codec cost. Throughput is hardware-dependent; only the speedup ratios
between the two implementations on the same machine are meaningful.
""".

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").
-include_lib("thrift/include/golden/gen-erl/thrift_test_types.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([main/1, run/0]).

-type case_spec() :: #{
    name := binary(),
    official_name := atom(),
    our_value := thrift_erl_binary:struct_value(),
    official_value := tuple(),
    official_check := fun((tuple()) -> ok)
}.
%% The throughput report erlperf returns in `full' mode, narrowed to
%% the fields this benchmark consumes.
-type throughput() :: #{average := float(), stddev := float()}.

-spec main([string()]) -> no_return().
main(_Args) ->
    try run() of
        ok ->
            erlang:halt(0)
    catch
        Class:Reason:Stack ->
            io:format("bench failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
            erlang:halt(1)
    end.

-doc "Runs every benchmark case and prints the report; without halting.".
-spec run() -> ok.
run() ->
    ok = setup(),
    xtruct(),
    xtruct2(),
    insanity(),
    ok.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

%% Flat struct of primitives — the codec floor.
xtruct() ->
    Our = xtruct_map(<<"hello thrift">>, -1, 123456, 123456789012),
    Official = official_xtruct(<<"hello thrift">>, -1, 123456, 123456789012),
    run_case(#{
        name => <<"Xtruct">>,
        official_name => 'thrift.test.Xtruct',
        our_value => Our,
        official_value => Official,
        official_check => fun(Decoded) -> ?assertEqual(Official, Decoded) end
    }).

%% One level of struct nesting.
xtruct2() ->
    OfficialInner = official_xtruct(<<"nested">>, 7, 42, 9000),
    Our =
        #{
            <<"byte_thing">> => 5,
            <<"struct_thing">> => xtruct_map(<<"nested">>, 7, 42, 9000),
            <<"i32_thing">> => 77
        },
    Official =
        #'thrift.test.Xtruct2'{byte_thing = 5, struct_thing = OfficialInner, i32_thing = 77},
    run_case(#{
        name => <<"Xtruct2">>,
        official_name => 'thrift.test.Xtruct2',
        our_value => Our,
        official_value => Official,
        official_check => fun(Decoded) -> ?assertEqual(Official, Decoded) end
    }).

%% Containers and an enum-keyed map — the heaviest fixture struct:
%% `userMap` is map<Numberz, UserId> (the official descriptor resolves
%% the enum to i32 and the typedef to i64) plus a long list of structs.
insanity() ->
    run_case(#{
        name => <<"Insanity">>,
        official_name => 'thrift.test.Insanity',
        our_value => our_insanity(),
        official_value => official_insanity(),
        official_check => fun insanity_check/1
    }).

%%--------------------------------------------------------------------
%% Comparison driver
%%--------------------------------------------------------------------

-spec run_case(case_spec()) -> ok.
run_case(#{name := Name, official_name := OfficialName} = Spec) ->
    #{our_value := OurValue, official_value := OfficialValue, official_check := Check} = Spec,
    Desc = {struct, goldentest_types:struct_info(Name)},
    {ok, Encoded} = thrift_erl_binary:encode(Desc, OurValue),
    BinaryWire = iolist_to_binary(Encoded),
    {ok, CompactEncoded} = thrift_erl_compact:encode(Desc, OurValue),
    CompactWire = iolist_to_binary(CompactEncoded),

    %% Correctness before timing. Each codec round-trips its own
    %% encoding, and the official reader of each protocol must accept
    %% our bytes for that protocol — the same wire-compatibility proof
    %% the golden suite runs over TCP, here at the codec level.
    {ok, OurDecoded, <<>>} = thrift_erl_binary:decode(Desc, BinaryWire),
    ?assertEqual(OurValue, OurDecoded),
    {_, {ok, OfficialDecoded}} = official_decode(BinaryWire, binary, OfficialName),
    Check(OfficialDecoded),
    {ok, OurCompactDecoded, <<>>} = thrift_erl_compact:decode(Desc, CompactWire),
    ?assertEqual(OurValue, OurCompactDecoded),
    {_, {ok, CompactDecoded}} = official_decode(CompactWire, compact, OfficialName),
    Check(CompactDecoded),

    OursEncode = erlbench(fun() -> {ok, _} = thrift_erl_binary:encode(Desc, OurValue) end),
    OursDecode = erlbench(fun() -> {ok, _, <<>>} = thrift_erl_binary:decode(Desc, BinaryWire) end),
    OursCompactEncode = erlbench(fun() -> {ok, _} = thrift_erl_compact:encode(Desc, OurValue) end),
    OursCompactDecode = erlbench(fun() -> {ok, _, <<>>} = thrift_erl_compact:decode(Desc, CompactWire) end),
    ReferenceBinaryEncode =
        erlbench(fun() -> ok = official_write(OfficialValue, OfficialName, binary) end),
    ReferenceBinaryDecode =
        erlbench(fun() -> {_, {ok, _}} = official_decode(BinaryWire, binary, OfficialName) end),
    ReferenceCompactEncode =
        erlbench(fun() -> ok = official_write(OfficialValue, OfficialName, compact) end),
    ReferenceCompactDecode =
        erlbench(fun() -> {_, {ok, _}} = official_decode(CompactWire, compact, OfficialName) end),

    Rows = [
        {<<"binary/encode">>, {measured, OursEncode}, {measured, ReferenceBinaryEncode}},
        {<<"binary/decode">>, {measured, OursDecode}, {measured, ReferenceBinaryDecode}},
        {<<"compact/encode">>, {measured, OursCompactEncode}, {measured, ReferenceCompactEncode}},
        {<<"compact/decode">>, {measured, OursCompactDecode}, {measured, ReferenceCompactDecode}}
    ],
    io:put_chars([
        format_report(
            Name,
            [{binary, byte_size(BinaryWire)}, {compact, byte_size(CompactWire)}],
            Rows
        ),
        $\n
    ]),
    ok.

-spec xtruct_map(binary(), integer(), integer(), integer()) -> thrift_erl_binary:struct_value().
xtruct_map(StringThing, ByteThing, I32Thing, I64Thing) ->
    #{
        <<"string_thing">> => StringThing,
        <<"byte_thing">> => ByteThing,
        <<"i32_thing">> => I32Thing,
        <<"i64_thing">> => I64Thing
    }.

-spec official_xtruct(binary(), integer(), integer(), integer()) -> #'thrift.test.Xtruct'{}.
official_xtruct(StringThing, ByteThing, I32Thing, I64Thing) ->
    #'thrift.test.Xtruct'{
        string_thing = StringThing,
        byte_thing = ByteThing,
        i32_thing = I32Thing,
        i64_thing = I64Thing
    }.

-spec our_insanity() -> thrift_erl_binary:struct_value().
our_insanity() ->
    #{
        <<"userMap">> => #{
            'ONE' => 1, 'TWO' => 2, 'THREE' => 3, 'FIVE' => 5, 'SIX' => 6, 'EIGHT' => 8
        },
        <<"xtructs">> => [xtruct_map(<<"x">>, K rem 128, K, K * 1000) || K <- lists:seq(1, 100)]
    }.

-spec official_insanity() -> #'thrift.test.Insanity'{}.
official_insanity() ->
    UserMap = dict:from_list([{1, 1}, {2, 2}, {3, 3}, {5, 5}, {6, 6}, {8, 8}]),
    #'thrift.test.Insanity'{
        userMap = UserMap,
        xtructs = [insanity_element(K) || K <- lists:seq(1, 100)]
    }.

-spec insanity_element(integer()) -> #'thrift.test.Xtruct'{}.
insanity_element(K) ->
    official_xtruct(<<"x">>, K rem 128, K, K * 1000).

-spec insanity_check(#'thrift.test.Insanity'{}) -> ok.
insanity_check(#'thrift.test.Insanity'{userMap = Dict, xtructs = Xs}) ->
    ?assertEqual([insanity_element(K) || K <- lists:seq(1, 100)], Xs),
    ?assertEqual(
        [{1, 1}, {2, 2}, {3, 3}, {5, 5}, {6, 6}, {8, 8}],
        lists:sort(dict:to_list(Dict))
    ).

%%--------------------------------------------------------------------
%% Reference runtime access
%%--------------------------------------------------------------------

%% Encodes one struct through the official runtime (binary or compact
%% protocol) into a fresh membuffer. The encoded bytes stay inside the
%% transport — the official API offers no extraction — so the encode
%% numbers measure the write cost only, identically for both protocols.
-spec official_write(tuple(), atom(), binary | compact) -> ok.
official_write(Value, Name, ProtocolName) ->
    {ok, Transport} = thrift_membuffer_transport:new(),
    {ok, Protocol0} = protocol_module(ProtocolName, Transport),
    {Protocol1, ok} = thrift_protocol:write(Protocol0, {{struct, {thrift_test_types, Name}}, Value}),
    {_Protocol2, ok} = thrift_protocol:flush_transport(Protocol1),
    ok.

-spec protocol_module(binary | compact, term()) -> {ok, term()}.
protocol_module(binary, Transport) ->
    thrift_binary_protocol:new(Transport);
protocol_module(compact, Transport) ->
    thrift_compact_protocol:new(Transport).

%% Decodes one struct from `Wire` through the official runtime.
-spec official_decode(binary(), binary | compact, atom()) ->
    {term(), {ok, tuple()} | {error, term()}}.
official_decode(Wire, ProtocolName, Name) ->
    {ok, Transport} = thrift_membuffer_transport:new(Wire),
    {ok, Protocol} = protocol_module(ProtocolName, Transport),
    thrift_protocol:read(Protocol, {struct, {thrift_test_types, Name}}).

%%--------------------------------------------------------------------
%% Measurement (erlperf, continuous mode)
%%--------------------------------------------------------------------

-spec bench_options() -> map().
bench_options() ->
    #{
        warmup => env_int("BENCH_WARMUP", 1),
        sample_duration => env_int("BENCH_SAMPLE_MS", 500),
        %% erlperf's stddev report divides by samples - 1
        samples => max(2, env_int("BENCH_SAMPLES", 3)),
        report => full
    }.

-spec env_int(string(), non_neg_integer()) -> non_neg_integer().
env_int(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        Raw ->
            case string:to_integer(Raw) of
                {N, []} when N >= 0 ->
                    N;
                _ ->
                    erlang:error({bad_env, Name, Raw})
            end
    end.

-spec erlbench(fun(() -> term())) -> throughput().
erlbench(Fun) ->
    #{result := #{average := Average, stddev := StdDev}} = erlperf:run(Fun, bench_options()),
    #{average => Average, stddev => StdDev}.

-spec format_report(binary(), [{binary | compact, non_neg_integer()}], [row()]) -> string().
format_report(Name, WireSizes, Rows) ->
    Sizes = [
        io_lib:format("~ts ~p B", [Proto, Size])
     || {Proto, Size} <- WireSizes
    ],
    Header =
        io_lib:format("thrift_bench[~ts: ~ts]", [Name, lists:join(", ", Sizes)]),
    Lines = [row_line(Row) || Row <- Rows],
    lists:flatten([Header, $\n, lists:join($\n, Lines)]).

-type row() :: {binary(), {measured, throughput()}, {measured, throughput()}}.

-spec row_line(row()) -> string().
row_line({Label, Ours, Reference}) ->
    lists:flatten([
        "  ",
        string:pad(Label, 15, trailing),
        "ours ",
        pad_side(Ours),
        "   reference ",
        pad_side(Reference),
        "   ",
        speedup_note(Ours, Reference)
    ]).

%% A literal percent sign in a format string needs no escaping (Erlang
%% has no %% sequence); widths go through string:pad because ~-Nts
%% truncates instead of widening.

-spec pad_side({measured, throughput()}) -> string().
pad_side({measured, #{average := Average, stddev := StdDev}}) ->
    string:pad(
        lists:flatten(io_lib:format("~ts ±~.1f%", [format_qps(Average), 100 * StdDev / Average])),
        18,
        trailing
    ).

-spec speedup_note({measured, throughput()}, {measured, throughput()}) -> string().
speedup_note({measured, #{average := Ours}}, {measured, #{average := Reference}}) ->
    io_lib:format("speedup ~5.2fx", [Ours / Reference]).

-spec format_qps(float()) -> string().
format_qps(Qps) when Qps >= 1000000 ->
    io_lib:format("~.2f M/s", [Qps / 1000000]);
format_qps(Qps) when Qps >= 1000 ->
    io_lib:format("~.1f K/s", [Qps / 1000]);
format_qps(Qps) ->
    io_lib:format("~b /s", [round(Qps)]).

%%--------------------------------------------------------------------
%% Setup helpers (shared shape with thrift_golden_SUITE)
%%--------------------------------------------------------------------

-spec setup() -> ok.
setup() ->
    %% Same setup as thrift_golden_SUITE: the committed officially
    %% generated code lives with the vendored official runtime, our side
    %% is generated in memory from the same fixture (which lives in the
    %% golden suite's data dir — one fixture, one source of truth) under
    %% the renamed `goldentest` module prefix so both can coexist in the
    %% test VM.
    {ok, _} = application:ensure_all_started(erlperf),
    GenDir = filename:join(code:lib_dir(thrift), "include/golden/gen-erl"),
    ok = compile_official_generated(GenDir),
    AppDir = code:lib_dir(thrift_generator),
    DataDir = filename:join(AppDir, "test/thrift_golden_SUITE_data"),
    ok = load_our_thrift_test_modules(DataDir).

%% Compiles the committed officially generated sources in memory and
%% loads them.
-spec compile_official_generated(file:filename_all()) -> ok.
compile_official_generated(GenDir) ->
    Files = filelib:wildcard(filename:join(GenDir, "*.erl")),
    ?assertNotEqual([], Files),
    lists:foreach(
        fun(File) ->
            case compile:file(File, [binary, {i, GenDir}, report_errors, return_errors]) of
                {ok, Module, Beam} ->
                    {module, Module} = code:load_binary(Module, File, Beam);
                {error, Errors, _Warnings} ->
                    erlang:error({official_compile_failed, File, Errors})
            end
        end,
        Files
    ),
    ok.

%% Generates and loads OUR modules for the fixture the official gen-erl
%% was compiled from, renamed as a whole (module and the
%% namespace-derived identifier prefix) to `goldentest` so the two
%% generations coexist in the test VM.
-spec load_our_thrift_test_modules(file:filename_all()) -> ok.
load_our_thrift_test_modules(DataDir) ->
    ThriftFile = filename:join(DataDir, "ThriftTest.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(ThriftFile),
    {ok, Model0} = thrift_generator_semantic:analyze(Loaded),
    Model = Model0#tg_model{
        modules = [
            Mod#tg_module{name = <<"goldentest">>, prefix = <<"goldentest">>}
         || Mod <- Model0#tg_model.modules
        ]
    },
    Beams = thrift_generator_emitter:compile_sources(Model),
    lists:foreach(
        fun
            ({ok, Name, Beam}) ->
                {module, Name} = code:load_binary(Name, atom_to_list(Name) ++ ".erl", Beam);
            ({error, Reason}) ->
                erlang:error({our_compile_failed, Reason})
        end,
        Beams
    ),
    ok.
