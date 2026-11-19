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

-module(thrift_bench_rpc).

-moduledoc """
Paired loopback RPC benchmark: historical versus HEAD generated service
code, both running on the current runtime in one VM over a real
client/server loopback. The measured delta is the generated-code side of
the RPC path — params/result encoding and decoding — with framing,
transport and runtime held constant. Runtime-side historical drift is
covered by the codec-level gate of `thrift_bench_regression', not here.

Both sides stay loaded simultaneously (the driver script generates with
distinct module prefixes); each round alternates the side measured first.
The reported ratio is HEAD throughput divided by baseline throughput,
evaluated by `thrift_bench_regression:evaluate/2'. Every cell gates at
`THRIFT_BENCH_THRESHOLD': the RPC specialization series is accepted only
when the loopback cells pass.

Environment knobs: `THRIFT_BENCH_BASE_BEAMS` and `THRIFT_BENCH_HEAD_BEAMS`
(directories of generated beams, required), `THRIFT_BENCH_ROUNDS` (31),
`THRIFT_BENCH_SAMPLE_MS` (250), `THRIFT_BENCH_THRESHOLD` (0.99) and
`THRIFT_BENCH_FUNCTION` to select one function. Use `scripts/bench-rpc`,
which supplies generation and cleanup.
""".

-export([main/1, rpc_repeat/1]).

-export_type([rpc_case/0]).

-type rpc_case() :: #{
    id := binary(),
    name := binary(),
    args := [term()],
    n := non_neg_integer()
}.
-type side() :: #{server := pid(), client := pid()}.

-spec main([string()]) -> no_return().
main(Args) ->
    try run(Args) of
        ok ->
            erlang:halt(0);
        {error, Reason} ->
            io:format("rpc benchmark failed: ~p~n", [Reason]),
            erlang:halt(1)
    catch
        Class:Reason:Stack ->
            io:format("rpc benchmark failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
            erlang:halt(1)
    end.

run(["compare"]) ->
    compare();
run(Args) ->
    {error, {unknown_command, Args}}.

compare() ->
    BaseBeams = read_generated(required_env("THRIFT_BENCH_BASE_BEAMS")),
    HeadBeams = read_generated(required_env("THRIFT_BENCH_HEAD_BEAMS")),
    ok = load_version(BaseBeams),
    ok = load_version(HeadBeams),
    Rounds = max(3, env_int("THRIFT_BENCH_ROUNDS", 31)),
    SampleMs = max(1, env_int("THRIFT_BENCH_SAMPLE_MS", 250)),
    Threshold = env_float("THRIFT_BENCH_THRESHOLD", 0.99),
    Base = start_side(goldentest080a_thrift_test_server, thrift_bench_rpc_base),
    Head = start_side(goldentesthead_thrift_test_server, thrift_bench_rpc_head),
    Cases0 = [C || C <- cases(), selected(C)],
    ok = lists:foreach(
        fun(C) ->
            check_case(C, Base),
            check_case(C, Head)
        end,
        Cases0
    ),
    Cases = [calibrate(C, SampleMs, Head) || C <- Cases0],
    io:format("paired rpc benchmark: ~p cells, ~p rounds, target ~p ms/side~n", [length(Cases), Rounds, SampleMs]),
    Results = lists:foldl(
        fun(Round, Acc) ->
            Ordered =
                case Round rem 2 of
                    0 -> lists:reverse(Cases);
                    _ -> Cases
                end,
            Acc1 = lists:foldl(fun(C, A) -> measure(C, Round, Base, Head, A) end, Acc, Ordered),
            io:format("round ~p done~n", [Round]),
            Acc1
        end,
        #{},
        lists:seq(1, Rounds)
    ),
    Evaluations = [report(C, maps:get(maps:get(id, C), Results), Threshold) || C <- Cases],
    Regressions = length([E || E = #{pass := false, inconclusive := false} <- Evaluations]),
    Inconclusive = length([E || E = #{inconclusive := true} <- Evaluations]),
    io:format(
        "threshold ~.2f: ~p confirmed regressions, ~p inconclusive, ~p cells~n",
        [Threshold, Regressions, Inconclusive, length(Cases)]
    ),
    case Regressions + Inconclusive of
        0 -> ok;
        _ -> {error, {performance_gate, Regressions, Inconclusive}}
    end.

-spec cases() -> [rpc_case()].
cases() ->
    [
        #{id => <<"testVoid">>, name => <<"testVoid">>, args => [], n => 0},
        #{id => <<"testString">>, name => <<"testString">>, args => [<<"hello thrift rpc benchmark">>], n => 0},
        #{id => <<"testStruct">>, name => <<"testStruct">>, args => [xtruct_value()], n => 0},
        #{id => <<"testList">>, name => <<"testList">>, args => [lists:seq(1, 100)], n => 0}
    ].

xtruct_value() ->
    #{
        <<"string_thing">> => <<"hello thrift">>,
        <<"byte_thing">> => -1,
        <<"i32_thing">> => 123456,
        <<"i64_thing">> => 123456789012
    }.

selected(C) ->
    case os:getenv("THRIFT_BENCH_FUNCTION") of
        false -> true;
        Raw -> maps:get(id, C) =:= list_to_binary(Raw)
    end.

-spec start_side(module(), atom()) -> side().
start_side(ServerMod, Name) ->
    {ok, Server} = thrift_runtime_server:start_link(#{
        port => 0,
        handler => thrift_bench_rpc_handler,
        service => ServerMod,
        %% Both servers live in one VM; the default registration name
        %% would collide.
        name => Name
    }),
    {ok, Port} = thrift_runtime_server:port(Server),
    {ok, Client} = thrift_runtime_client:start_link(#{
        host => "127.0.0.1",
        port => Port,
        service => ServerMod
    }),
    #{server => Server, client => Client}.

%% One real call per side before any timing: proves the echo round trip
%% and warms the codec caches the measured path depends on.

-spec check_case(rpc_case(), side()) -> ok.
check_case(#{name := Name, args := Args}, #{client := Client}) ->
    Expected =
        case Args of
            [] -> undefined;
            [Arg] -> Arg
        end,
    {ok, Expected} = thrift_runtime_client:call(Client, Name, Args, 30000),
    ok.

-spec calibrate(rpc_case(), pos_integer(), side()) -> rpc_case().
calibrate(C, SampleMs, #{client := Client}) ->
    CalN = 100,
    {Time, ok} = timer:tc(?MODULE, rpc_repeat, [{Client, C, CalN}]),
    N = max(20, min(2000000, round(CalN * SampleMs * 1000 / max(Time, 1)))),
    C#{n => N}.

-spec rpc_repeat({pid(), rpc_case(), non_neg_integer()}) -> ok.
rpc_repeat({_Client, _C, 0}) ->
    ok;
rpc_repeat({Client, #{name := Name, args := Args} = C, N}) ->
    _ = thrift_runtime_client:call(Client, Name, Args, 30000),
    rpc_repeat({Client, C, N - 1}).

-spec measure(rpc_case(), pos_integer(), side(), side(), map()) -> map().
measure(#{n := N} = C, Round, #{client := BaseClient}, #{client := HeadClient}, Acc) ->
    {BaseTime, HeadTime} =
        case Round rem 2 of
            0 ->
                {Head0, ok} = timer:tc(?MODULE, rpc_repeat, [{HeadClient, C, N}]),
                {Base0, ok} = timer:tc(?MODULE, rpc_repeat, [{BaseClient, C, N}]),
                {Base0, Head0};
            _ ->
                {Base0, ok} = timer:tc(?MODULE, rpc_repeat, [{BaseClient, C, N}]),
                {Head0, ok} = timer:tc(?MODULE, rpc_repeat, [{HeadClient, C, N}]),
                {Base0, Head0}
        end,
    maps:update_with(maps:get(id, C), fun(L) -> [{BaseTime, HeadTime, N} | L] end, [{BaseTime, HeadTime, N}], Acc).

report(C, Samples0, Threshold) ->
    Id = maps:get(id, C),
    Samples = lists:reverse(Samples0),
    Evaluation = thrift_bench_regression:evaluate(Samples, Threshold),
    BaseQps = thrift_bench_regression:median([N * 1000000 / BaseTime || {BaseTime, _HeadTime, N} <- Samples]),
    HeadQps = thrift_bench_regression:median([N * 1000000 / HeadTime || {_BaseTime, HeadTime, N} <- Samples]),
    #{
        ratio := Ratio,
        ci_low := CiLow,
        ci_high := CiHigh,
        pass := Pass,
        inconclusive := Inconclusive
    } = Evaluation,
    io:format(
        "~ts rpc base=~.1f head=~.1f ratio=~.4f ci95=[~.4f,~.4f] delta=~.2f% pass=~p inc=~p~n",
        [Id, BaseQps, HeadQps, Ratio, CiLow, CiHigh, 100 * (Ratio - 1), Pass, Inconclusive]
    ),
    Evaluation.

read_generated(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    lists:sort([
        {Module, Beam, Path}
     || File <- Files,
        filename:extension(File) =:= ".beam",
        Path <- [filename:join(Dir, File)],
        {ok, Beam} <- [file:read_file(Path)],
        Module <- [list_to_atom(filename:rootname(File))]
    ]).

load_version(Beams) ->
    lists:foreach(
        fun({Module, Beam, Path}) ->
            _ = code:purge(Module),
            {module, Module} = code:load_binary(Module, Path, Beam)
        end,
        Beams
    ),
    ok.

required_env(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({missing_env, Name});
        Value -> Value
    end.

env_int(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        Raw ->
            case string:to_integer(Raw) of
                {N, []} when N >= 0 -> N;
                _ -> erlang:error({bad_env, Name, Raw})
            end
    end.

env_float(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        Raw ->
            try list_to_float(Raw) of
                Value -> Value
            catch
                error:badarg -> erlang:error({bad_env, Name, Raw})
            end
    end.
