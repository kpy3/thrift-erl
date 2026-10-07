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

-module(thrift_perf_SUITE).

-moduledoc """
Codec-level performance comparison of the two protocol implementations
in the repository, measured with erlperf and driven from the same
ThriftTest fixture as the golden interop suite:

- **ours** — `thrift_erl_binary` over the introspection descriptors of
  the in-memory generated `goldentest_types` module;
- **reference** — the vendored Apache Thrift 0.25.0 Erlang runtime
  (`thrift_binary_protocol` over `thrift_membuffer_transport`) with the
  committed officially generated `thrift_test_types`.

Each case first proves the codecs agree: our bytes must decode back
through the official reader into the expected record (byte-level
exchange in the opposite direction is covered by the golden suite's
socket scenarios). Only then are encode and decode benchmarked
separately, in erlperf continuous mode: one discarded warmup sample
followed by three 500 ms samples, concurrency 1; the reported number is
erlperf's average iterations per second with the sample stddev.

Throughput numbers are reported into the log and never asserted, so
the suite stays green on any hardware (it simply runs for about half a
minute). Reference numbers include a fresh membuffer transport and
protocol per operation — that API has no way to decode a bare binary,
so the construction is part of its codec cost.
""".

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").
-include("priv/golden/gen-erl/thrift_test_types.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    xtruct/1,
    xtruct2/1,
    insanity/1
]).

-type case_spec() :: #{
    name := binary(),
    official_name := atom(),
    our_value := thrift_erl_binary:struct_value(),
    official_value := tuple(),
    official_check := fun((tuple()) -> ok)
}.
%% The throughput report erlperf returns in `full' mode, narrowed to
%% the fields this suite consumes.
-type throughput() :: #{average := float(), stddev := float()}.

all() ->
    [xtruct, xtruct2, insanity].

init_per_suite(Config) ->
    %% Same setup as thrift_golden_SUITE: the committed officially
    %% generated code lives under priv/, our side is generated in
    %% memory from the same fixture (which lives in the golden suite's
    %% data dir — one fixture, one source of truth) under the renamed
    %% `goldentest` module prefix so both can coexist in the test VM.
    {ok, _} = application:ensure_all_started(erlperf),
    AppDir = code:lib_dir(thrift_generator),
    GenDir = filename:join(AppDir, "priv/golden/gen-erl"),
    ok = compile_official_generated(GenDir),
    DataDir = filename:join(AppDir, "test/thrift_golden_SUITE_data"),
    ok = load_our_thrift_test_modules(DataDir),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

%% Flat struct of primitives — the codec floor.
xtruct(_Config) ->
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
xtruct2(_Config) ->
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
insanity(_Config) ->
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
    Wire = iolist_to_binary(Encoded),

    %% Correctness before timing: our roundtrip is exact, and the
    %% official reader must accept our bytes.
    {ok, OurDecoded, <<>>} = thrift_erl_binary:decode(Desc, Wire),
    ?assertEqual(OurValue, OurDecoded),
    {_, {ok, OfficialDecoded}} = official_decode(Wire, OfficialName),
    Check(OfficialDecoded),

    OursEncode = erlbench(fun() -> {ok, _} = thrift_erl_binary:encode(Desc, OurValue) end),
    OursDecode = erlbench(fun() -> {ok, _, <<>>} = thrift_erl_binary:decode(Desc, Wire) end),
    ReferenceEncode = erlbench(fun() -> official_encode(OfficialValue, OfficialName) end),
    ReferenceDecode = erlbench(fun() -> {_, {ok, _}} = official_decode(Wire, OfficialName) end),

    Rows = [
        {encode, OursEncode, ReferenceEncode},
        {decode, OursDecode, ReferenceDecode}
    ],
    ct:pal("~ts", [format_report(Name, byte_size(Wire), Rows)]),
    ct:comment("speedup vs reference: encode ~.2fx, decode ~.2fx", [
        speedup(ReferenceEncode, OursEncode),
        speedup(ReferenceDecode, OursDecode)
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

%% Encodes one struct through the official runtime into a fresh
%% membuffer. The encoded bytes stay inside the transport — the official
%% API offers no extraction — so this measures the write cost only.
-spec official_encode(tuple(), atom()) -> ok.
official_encode(Value, Name) ->
    {ok, Transport} = thrift_membuffer_transport:new(),
    {ok, Protocol0} = thrift_binary_protocol:new(Transport),
    {Protocol1, ok} = thrift_protocol:write(Protocol0, {{struct, {thrift_test_types, Name}}, Value}),
    {_Protocol2, ok} = thrift_protocol:flush_transport(Protocol1),
    ok.

%% Decodes one struct from `Wire` through the official runtime.
-spec official_decode(binary(), atom()) -> {term(), {ok, tuple()} | {error, term()}}.
official_decode(Wire, Name) ->
    {ok, Transport} = thrift_membuffer_transport:new(Wire),
    {ok, Protocol} = thrift_binary_protocol:new(Transport),
    thrift_protocol:read(Protocol, {struct, {thrift_test_types, Name}}).

%%--------------------------------------------------------------------
%% Measurement (erlperf, continuous mode)
%%--------------------------------------------------------------------

-define(BENCH_OPTIONS, #{
    warmup => 1,
    sample_duration => 500,
    samples => 3,
    report => full
}).

-spec erlbench(fun(() -> term())) -> throughput().
erlbench(Fun) ->
    #{result := #{average := Average, stddev := StdDev}} = erlperf:run(Fun, ?BENCH_OPTIONS),
    #{average => Average, stddev => StdDev}.

%% Throughput ratio: how many times more operations per second ours
%% completes than the reference.
-spec speedup(throughput(), throughput()) -> float().
speedup(#{average := Ours}, #{average := Reference}) ->
    Ours / Reference.

-spec format_report(binary(), non_neg_integer(), [{atom(), throughput(), throughput()}]) -> string().
format_report(Name, WireBytes, Rows) ->
    Header = io_lib:format("thrift_perf[~ts: ~p bytes on the wire]", [Name, WireBytes]),
    Lines = [
        io_lib:format(
            "  ~-6ts ours ~-11ts ±~.1f%%   reference ~-11ts ±~.1f%%   speedup ~5.2fx",
            [
                Mode,
                format_qps(OursAverage),
                100 * OursStdDev / OursAverage,
                format_qps(ReferenceAverage),
                100 * ReferenceStdDev / ReferenceAverage,
                OursAverage / ReferenceAverage
            ]
        )
     || {Mode, #{average := OursAverage, stddev := OursStdDev}, #{
            average := ReferenceAverage, stddev := ReferenceStdDev
        }} <-
            Rows
    ],
    lists:flatten([Header, $\n, lists:join($\n, Lines)]).

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
%% was compiled from, under the renamed `goldentest' prefix.
-spec load_our_thrift_test_modules(file:filename_all()) -> ok.
load_our_thrift_test_modules(DataDir) ->
    ThriftFile = filename:join(DataDir, "ThriftTest.thrift"),
    {ok, Loaded} = thrift_generator_loader:load(ThriftFile),
    {ok, Model0} = thrift_generator_semantic:analyze(Loaded),
    Model = Model0#tg_model{
        modules = [Mod#tg_module{name = <<"goldentest">>} || Mod <- Model0#tg_model.modules]
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
