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

-module(thrift_bench_regression).

-moduledoc """
Paired historical benchmark for generated codecs. `generate` runs in each
checkout and writes generated beams; `compare` proves wire and round-trip
equality, then alternates baseline/current measurements. Both sides use the
same function atoms in distinct modules. Same-module and cross-module direct
rows isolate emitted code and form the regression gate; public rows expose
dispatch costs for diagnosis. Public rows have distinct top-level module/cache
keys, so they are unsuitable for a 1% hard gate. Direct targets are external
funs created before timing, not dynamic module lookups on every iteration.

The reported ratio is current throughput divided by baseline throughput.
Environment knobs: `THRIFT_BENCH_ROUNDS` (31), `THRIFT_BENCH_SAMPLE_MS`
(250), `THRIFT_BENCH_THRESHOLD` (0.99), `THRIFT_BENCH_PROTOCOL` and
`THRIFT_BENCH_ENTRY` optionally select one protocol and `public`/`direct`.
Use `scripts/bench-regression`, which supplies generation and cleanup.
""".

-export([main/1, median/1, evaluate/2]).
-export([repeat/3, encode/1, decode/1, call/1]).
-export_type([sample/0, evaluation/0]).

-type protocol_name() :: binary | compact | json.
-type entry() :: public | direct.
-type operation() :: encode | decode.
-type sample() :: {BaseUs :: pos_integer(), HeadUs :: pos_integer(), Iterations :: pos_integer()}.
-type evaluation() :: #{
    ratio := float(),
    ci_low := float(),
    ci_high := float(),
    pass := boolean(),
    inconclusive := boolean()
}.
-type benchmark_spec() :: #{
    id := binary(),
    struct := binary(),
    value := map(),
    base_prefix := binary(),
    base_module := module(),
    head_prefix := binary(),
    head_module := module()
}.
-type case_spec() :: #{
    key := {binary(), protocol_name(), entry(), operation()},
    base := {atom(), term()},
    head := {atom(), term()},
    n := non_neg_integer()
}.

-spec main([string()]) -> no_return().
main(Args) ->
    try run(Args) of
        ok ->
            erlang:halt(0);
        {error, Reason} ->
            io:format("benchmark failed: ~p~n", [Reason]),
            erlang:halt(1)
    catch
        Class:Reason:Stack ->
            io:format("benchmark failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
            erlang:halt(1)
    end.

run(["generate"]) ->
    generate();
run(["compare"]) ->
    compare();
run(Args) ->
    {error, {unknown_command, Args}}.

%% Generation runs with the checkout's own generator and the current
%% benchmark module on the code path. Record name/prefix positions and the
%% model's final modules field are shared by v0.8.0 and HEAD.
generate() ->
    Base = required_env_bin("THRIFT_BENCH_BASE"),
    Suffix = required_env_bin("THRIFT_BENCH_SUFFIX"),
    Out = required_env("THRIFT_BENCH_OUT"),
    Idl = required_env("THRIFT_BENCH_IDL"),
    {ok, Loaded} = thrift_generator_loader:load(Idl),
    {ok, Model0} = thrift_generator_semantic:analyze(Loaded),
    Model = rename_model(Model0, Base, Suffix),
    Results = thrift_generator_emitter:compile_sources(Model),
    ok = filelib:ensure_dir(filename:join(Out, "beams")),
    lists:foreach(
        fun({ok, Name, Beam}) ->
            ok = file:write_file(filename:join(Out, atom_to_list(Name) ++ ".beam"), Beam)
        end,
        Results
    ),
    io:format("generated ~p modules for ~ts~n", [length(Results), Base]),
    ok.

rename_model(Model0, Base, Suffix) ->
    Modules = element(tuple_size(Model0), Model0),
    Renamed = [rename_module(M, Base, Suffix, length(Modules)) || M <- Modules],
    setelement(tuple_size(Model0), Model0, Renamed).

rename_module(Module0, Base, Suffix, Count) ->
    Name = element(2, Module0),
    NewName =
        case Count of
            1 -> <<Base/binary, Suffix/binary>>;
            _ -> <<Base/binary, "_", (thrift_generator_emitter:sanitize(Name))/binary, Suffix/binary>>
        end,
    NewPrefix =
        case Count of
            1 -> Base;
            _ -> Name
        end,
    setelement(2, setelement(3, Module0, NewPrefix), NewName).

compare() ->
    BaseBeams = read_generated(required_env("THRIFT_BENCH_BASE_BEAMS")),
    HeadBeams = read_generated(required_env("THRIFT_BENCH_HEAD_BEAMS")),
    ok = load_version(BaseBeams),
    ok = load_version(HeadBeams),
    Specs = benchmark_specs(),
    ok = lists:foreach(fun check_spec/1, Specs),
    Rounds = max(3, env_int("THRIFT_BENCH_ROUNDS", 31)),
    SampleMs = max(1, env_int("THRIFT_BENCH_SAMPLE_MS", 250)),
    Threshold = env_float("THRIFT_BENCH_THRESHOLD", 0.99),
    Cases = [calibrate(C, SampleMs) || C <- cases(Specs)],
    io:format("paired benchmark: ~p cells, ~p rounds, target ~p ms/side~n", [length(Cases), Rounds, SampleMs]),
    Results = lists:foldl(
        fun(Round, Acc) ->
            Ordered =
                case Round rem 2 of
                    0 -> lists:reverse(Cases);
                    _ -> Cases
                end,
            Acc1 = lists:foldl(fun(C, A) -> measure(C, Round, A) end, Acc, Ordered),
            io:format("round ~p done~n", [Round]),
            Acc1
        end,
        #{},
        lists:seq(1, Rounds)
    ),
    Evaluations = [report(C, maps:get(case_key(C), Results), Threshold) || C <- Cases],
    Regressions = length([E || E = #{pass := false, inconclusive := false, gate := true} <- Evaluations]),
    Inconclusive = length([E || E = #{inconclusive := true, gate := true} <- Evaluations]),
    io:format(
        "threshold ~.2f: ~p confirmed regressions, ~p inconclusive, ~p cells~n",
        [Threshold, Regressions, Inconclusive, length(Cases)]
    ),
    case Regressions + Inconclusive of
        0 -> ok;
        _ -> {error, {performance_gate, Regressions, Inconclusive}}
    end.

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

benchmark_specs() ->
    Standard = [
        #{
            id => Name,
            struct => Name,
            value => Value,
            base_prefix => <<"goldentest">>,
            base_module => goldentest080a_types,
            head_prefix => <<"goldentest">>,
            head_module => goldentesthead_types
        }
     || {Name, Value} <- standard_values()
    ],
    Cross = #{
        id => <<"CrossModule">>,
        struct => <<"Outer">>,
        value => cross_value(),
        base_prefix => <<"multiroot">>,
        base_module => bench_multiroot080a_types,
        head_prefix => <<"multiroot">>,
        head_module => bench_multiroothead_types
    },
    Standard ++ [Cross].

standard_values() ->
    X = xtruct_value(<<"hello thrift">>, -1, 123456, 123456789012),
    X2 = #{<<"byte_thing">> => 5, <<"struct_thing">> => X, <<"i32_thing">> => 77},
    Ins = #{
        <<"userMap">> => #{'ONE' => 1, 'TWO' => 2, 'THREE' => 3, 'FIVE' => 5, 'SIX' => 6, 'EIGHT' => 8},
        <<"xtructs">> => [xtruct_value(<<"x">>, K rem 128, K, K * 1000) || K <- lists:seq(1, 100)]
    },
    [{<<"Xtruct">>, X}, {<<"Xtruct2">>, X2}, {<<"Insanity">>, Ins}].

xtruct_value(String, Byte, I32, I64) ->
    #{
        <<"string_thing">> => String,
        <<"byte_thing">> => Byte,
        <<"i32_thing">> => I32,
        <<"i64_thing">> => I64
    }.

cross_value() ->
    #{
        <<"items">> => [
            #{<<"text">> => <<"x">>, <<"number">> => K}
         || K <- lists:seq(1, 100)
        ]
    }.

check_spec(Spec) ->
    lists:foreach(
        fun(Protocol) -> check_protocol(Protocol, Spec) end,
        [binary, compact, json]
    ),
    ok.

check_protocol(Protocol, Spec) ->
    Runtime = protocol_module(Protocol),
    Name = maps:get(struct, Spec),
    Value = maps:get(value, Spec),
    BaseModule = maps:get(base_module, Spec),
    HeadModule = maps:get(head_module, Spec),
    BaseDesc = {struct, {ref, BaseModule, Name}},
    HeadDesc = {struct, {ref, HeadModule, Name}},
    {ok, BaseIo} = Runtime:encode(BaseDesc, Value),
    BaseWire = iolist_to_binary(BaseIo),
    {ok, BaseDecoded, <<>>} = Runtime:decode(BaseDesc, BaseWire),
    BaseEncode = function_ref(BaseModule, function_name(Protocol, encode, maps:get(base_prefix, Spec), Name)),
    BaseDecode = function_ref(BaseModule, function_name(Protocol, decode, maps:get(base_prefix, Spec), Name)),
    HeadEncode = function_ref(HeadModule, function_name(Protocol, encode, maps:get(head_prefix, Spec), Name)),
    HeadDecode = function_ref(HeadModule, function_name(Protocol, decode, maps:get(head_prefix, Spec), Name)),
    {ok, BaseDirect} = call({BaseEncode, Value}),
    {ok, BaseDirectDecoded, <<>>} = call({BaseDecode, BaseWire}),
    {ok, HeadIo} = Runtime:encode(HeadDesc, Value),
    HeadWire = iolist_to_binary(HeadIo),
    {ok, HeadDecoded, <<>>} = Runtime:decode(HeadDesc, HeadWire),
    {ok, HeadDirect} = call({HeadEncode, Value}),
    {ok, HeadDirectDecoded, <<>>} = call({HeadDecode, HeadWire}),
    true = BaseWire =:= HeadWire,
    true = BaseDecoded =:= Value,
    true = HeadDecoded =:= Value,
    true = iolist_to_binary(BaseDirect) =:= BaseWire,
    true = iolist_to_binary(HeadDirect) =:= HeadWire,
    true = BaseDirectDecoded =:= Value,
    true = HeadDirectDecoded =:= Value,
    ok.

cases(Specs) ->
    [
        make_case(Spec, Protocol, Entry, Op)
     || Spec <- Specs,
        Protocol <- [binary, compact, json],
        Entry <- [public, direct],
        selected(Protocol, Entry),
        Op <- [encode, decode]
    ].

selected(Protocol, Entry) ->
    selected_env("THRIFT_BENCH_PROTOCOL", atom_to_binary(Protocol, utf8)) andalso
        selected_env("THRIFT_BENCH_ENTRY", atom_to_binary(Entry, utf8)).

selected_env(Name, Value) ->
    case os:getenv(Name) of
        false -> true;
        Raw -> list_to_binary(Raw) =:= Value
    end.

-spec make_case(benchmark_spec(), protocol_name(), entry(), operation()) -> case_spec().
make_case(Spec, Protocol, Entry, Op) ->
    Value = maps:get(value, Spec),
    Name = maps:get(struct, Spec),
    Arg =
        case Op of
            encode ->
                Value;
            decode ->
                Runtime = protocol_module(Protocol),
                {ok, Io} = Runtime:encode({struct, {ref, maps:get(head_module, Spec), Name}}, Value),
                iolist_to_binary(Io)
        end,
    Base = args(Spec, Protocol, Entry, Op, base, Arg),
    Head = args(Spec, Protocol, Entry, Op, head, Arg),
    #{key => {maps:get(id, Spec), Protocol, Entry, Op}, base => Base, head => Head, n => 0}.

args(Spec, Protocol, public, Op, Side, Arg) ->
    Module = maps:get(side_field(Side, module), Spec),
    {Op, {protocol_module(Protocol), Module, maps:get(struct, Spec), Arg}};
args(Spec, Protocol, direct, Op, Side, Arg) ->
    Module = maps:get(side_field(Side, module), Spec),
    Prefix = maps:get(side_field(Side, prefix), Spec),
    Function = function_name(Protocol, Op, Prefix, maps:get(struct, Spec)),
    {call, {function_ref(Module, Function), Arg}}.

side_field(base, module) -> base_module;
side_field(head, module) -> head_module;
side_field(base, prefix) -> base_prefix;
side_field(head, prefix) -> head_prefix.

function_name(Protocol, Op, Prefix, Name) ->
    Suffix =
        case Protocol of
            binary -> <<"_wire">>;
            compact -> <<"_compact">>;
            json -> <<"_json">>
        end,
    OpBin = atom_to_binary(Op, utf8),
    Snake = thrift_generator_names:snake(Name),
    binary_to_atom(
        <<OpBin/binary, "_", Prefix/binary, "_", Snake/binary, Suffix/binary>>,
        utf8
    ).

protocol_module(binary) -> thrift_runtime_binary;
protocol_module(compact) -> thrift_runtime_compact;
protocol_module(json) -> thrift_runtime_json.

repeat(_Function, _Arg, 0) ->
    ok;
repeat(Function, Arg, N) ->
    _ = erlang:apply(?MODULE, Function, [Arg]),
    repeat(Function, Arg, N - 1).

encode({Protocol, Module, Name, Value}) -> Protocol:encode({struct, {ref, Module, Name}}, Value).
decode({Protocol, Module, Name, Wire}) -> Protocol:decode({struct, {ref, Module, Name}}, Wire).
call({Function, Arg}) when is_function(Function, 1) -> Function(Arg).

function_ref(Module, Function) -> erlang:make_fun(Module, Function, 1).

-spec case_key(case_spec()) -> {binary(), protocol_name(), entry(), operation()}.
case_key(C) -> maps:get(key, C).

calibrate(C, SampleMs) ->
    {Id, _Protocol, _Entry, Op} = case_key(C),
    CalN =
        case {Id, Op} of
            {<<"Insanity">>, decode} -> 500;
            {<<"Insanity">>, encode} -> 500;
            {<<"CrossModule">>, decode} -> 100;
            {<<"CrossModule">>, encode} -> 500;
            _ -> 2000
        end,
    {Function, Arg} = maps:get(head, C),
    {Time, ok} = timer:tc(?MODULE, repeat, [Function, Arg, CalN]),
    N = max(20, min(2000000, round(CalN * SampleMs * 1000 / max(Time, 1)))),
    C#{n => N}.

measure(C, Round, Acc) ->
    N = maps:get(n, C),
    {BaseFunction, BaseArg} = maps:get(base, C),
    {HeadFunction, HeadArg} = maps:get(head, C),
    {BaseTime, HeadTime} =
        case Round rem 2 of
            0 ->
                {Head0, ok} = timer:tc(?MODULE, repeat, [HeadFunction, HeadArg, N]),
                {Base0, ok} = timer:tc(?MODULE, repeat, [BaseFunction, BaseArg, N]),
                {Base0, Head0};
            _ ->
                {Base0, ok} = timer:tc(?MODULE, repeat, [BaseFunction, BaseArg, N]),
                {Head0, ok} = timer:tc(?MODULE, repeat, [HeadFunction, HeadArg, N]),
                {Base0, Head0}
        end,
    maps:update_with(case_key(C), fun(L) -> [{BaseTime, HeadTime, N} | L] end, [{BaseTime, HeadTime, N}], Acc).

report(C, Samples0, Threshold) ->
    {Id, Protocol, Entry, Op} = case_key(C),
    Samples = lists:reverse(Samples0),
    Evaluation = evaluate(Samples, Threshold),
    BaseQps = median([N * 1000000 / BaseTime || {BaseTime, _HeadTime, N} <- Samples]),
    HeadQps = median([N * 1000000 / HeadTime || {_BaseTime, HeadTime, N} <- Samples]),
    #{
        ratio := Ratio,
        ci_low := CiLow,
        ci_high := CiHigh,
        pass := Pass,
        inconclusive := Inconclusive
    } = Evaluation,
    Gate = Entry =:= direct,
    io:format(
        "~ts ~p ~p ~p base=~.1f head=~.1f ratio=~.4f ci95=[~.4f,~.4f] delta=~.2f% pass=~p inc=~p gate=~p~n",
        [
            Id,
            Protocol,
            Entry,
            Op,
            BaseQps,
            HeadQps,
            Ratio,
            CiLow,
            CiHigh,
            100 * (Ratio - 1),
            Pass,
            Inconclusive,
            Gate
        ]
    ),
    Evaluation#{gate => Gate}.

-doc "Returns the median of a non-empty list.".
-spec median([number()]) -> number().
median(Values) when Values =/= [] ->
    Sorted = lists:sort(Values),
    N = length(Sorted),
    case N rem 2 of
        1 -> lists:nth((N + 1) div 2, Sorted);
        0 -> (lists:nth(N div 2, Sorted) + lists:nth(N div 2 + 1, Sorted)) / 2
    end.

-doc "Evaluates paired base/current timings as a current/baseline throughput ratio.".
-spec evaluate([sample()], float()) -> evaluation().
evaluate(Samples, Threshold) when Samples =/= [] ->
    Ratios = [BaseUs / HeadUs || {BaseUs, HeadUs, _Iterations} <- Samples],
    Ratio = median(Ratios),
    {CiLow, CiHigh} = bootstrap_ci(Ratios),
    Pass = Ratio >= Threshold andalso CiLow >= Threshold,
    Inconclusive = not Pass andalso CiHigh >= Threshold,
    #{
        ratio => Ratio,
        ci_low => CiLow,
        ci_high => CiHigh,
        pass => Pass,
        inconclusive => Inconclusive
    }.

bootstrap_ci(Ratios) ->
    rand:seed(exsplus, {11, 22, 33}),
    Tuple = list_to_tuple(Ratios),
    N = tuple_size(Tuple),
    Replicates = [
        median([element(rand:uniform(N), Tuple) || _ <- lists:seq(1, N)])
     || _ <- lists:seq(1, 2000)
    ],
    Sorted = lists:sort(Replicates),
    {lists:nth(50, Sorted), lists:nth(1950, Sorted)}.

required_env_bin(Name) -> list_to_binary(required_env(Name)).

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
