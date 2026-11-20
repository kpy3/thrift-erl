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
Paired historical benchmark for generated codecs and representation
conversion. `generate` runs in each checkout and writes generated beams;
`compare` proves wire and round-trip equality, then alternates
baseline/current measurements. Both sides use the same function atoms in
distinct modules. Same-module and cross-module direct rows isolate emitted
code and form the regression gate; public rows expose dispatch costs for
diagnosis. Public rows have distinct top-level module/cache keys, so they
are unsuitable for a 1% hard gate. Direct targets are external funs created
before timing, not dynamic module lookups on every iteration.

Conversion rows (`conversion` entry) measure `thrift_runtime_record`
`to_wire`/`from_wire` on the generated modules of each side: the protocol
slot carries the input shape (`to_wire`) or target representation
(`from_wire`) — `record`, `map`, `struct`, `sum` or `native` (OTP 29+
only). They gate like direct rows.

The reported ratio is current throughput divided by baseline throughput.
Environment knobs: `THRIFT_BENCH_ROUNDS` (31), `THRIFT_BENCH_SAMPLE_MS`
(250), `THRIFT_BENCH_THRESHOLD` (0.99), `THRIFT_BENCH_PROTOCOL` and
`THRIFT_BENCH_ENTRY` optionally select one protocol and
`public`/`direct`/`conversion`; `THRIFT_BENCH_REPR` selects one conversion
representation. Use `scripts/bench-regression`, which supplies generation
and cleanup.
""".

-export([main/1, median/1, evaluate/2, cases/1]).
-export([repeat/3, encode/1, decode/1, call/1, to_wire/1, from_wire/1]).
-export([decode_twopass/1, decode_onepass/1, encode_twopass/1, encode_onepass/1, onepass_cases/1]).
-export_type([sample/0, evaluation/0]).

-type protocol_name() :: binary | compact | json.
-type repr_name() :: record | map | struct | sum | native.
-type entry() :: public | direct | conversion | onepass.
-type operation() :: encode | decode | to_wire | from_wire.
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
    key := {binary(), protocol_name() | repr_name(), entry(), operation()},
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
            id => Id,
            struct => Name,
            value => Value,
            base_prefix => <<"goldentest">>,
            base_module => goldentest080a_types,
            head_prefix => <<"goldentest">>,
            head_module => goldentesthead_types
        }
     || {Id, Name, Value} <- standard_values()
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
    U = #{<<"string_thing">> => <<"union value">>},
    XL = xtruct_value(binary:copy(<<"long string payload ">>, 100), -1, 123456, 123456789012),
    [
        {<<"Xtruct">>, <<"Xtruct">>, X},
        {<<"Xtruct2">>, <<"Xtruct2">>, X2},
        {<<"Insanity">>, <<"Insanity">>, Ins},
        {<<"SomeUnion">>, <<"SomeUnion">>, U},
        {<<"XtructLong">>, <<"Xtruct">>, XL}
    ].

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
    check_conversion(Spec),
    ok.

%% Conversion parity: both sides' modules accept the same input shapes,
%% return the very same wire map back, and agree on the converted values
%% (native values carry their module's identity, so they compare through
%% the to_wire round trip instead of by value).

%% The parity assertions of the sanity gate: written as explicit
%% comparisons rather than pattern matches (elp W0060).

-spec assert_equal(term(), term()) -> ok.
assert_equal(Expected, Got) ->
    case Got =:= Expected of
        true -> ok;
        false -> erlang:error({parity_mismatch, Expected, Got})
    end.

-spec assert_true(boolean()) -> ok.
assert_true(true) -> ok;
assert_true(false) -> erlang:error(parity_check_failed).

check_conversion(Spec) ->
    Name = maps:get(struct, Spec),
    Value = maps:get(value, Spec),
    BaseModule = maps:get(base_module, Spec),
    HeadModule = maps:get(head_module, Spec),
    case repr_mode_of(HeadModule, Name) of
        record ->
            Reprs = [record, map, struct] ++ native_repr(),
            lists:foreach(
                fun(Repr) ->
                    BaseIn = conversion_input(BaseModule, Name, Repr, to_wire, Value),
                    HeadIn = conversion_input(HeadModule, Name, Repr, to_wire, Value),
                    assert_equal(Value, thrift_runtime_record:to_wire({struct, {ref, BaseModule, Name}}, BaseIn)),
                    assert_equal(Value, thrift_runtime_record:to_wire({struct, {ref, HeadModule, Name}}, HeadIn))
                end,
                Reprs
            ),
            lists:foreach(
                fun(Repr) ->
                    BaseOut = thrift_runtime_record:from_wire({struct, {ref, BaseModule, Name}}, Value, Repr),
                    HeadOut = thrift_runtime_record:from_wire({struct, {ref, HeadModule, Name}}, Value, Repr),
                    assert_equal(Value, thrift_runtime_record:to_wire({struct, {ref, BaseModule, Name}}, BaseOut)),
                    assert_equal(Value, thrift_runtime_record:to_wire({struct, {ref, HeadModule, Name}}, HeadOut)),
                    %% Native values carry their module's identity and
                    %% cannot compare by value; everything else must
                    %% agree exactly.
                    assert_true(Repr =:= native orelse BaseOut =:= HeadOut)
                end,
                Reprs
            );
        sum ->
            BaseIn = conversion_input(BaseModule, Name, sum, to_wire, Value),
            HeadIn = conversion_input(HeadModule, Name, sum, to_wire, Value),
            assert_equal(Value, thrift_runtime_record:to_wire({struct, {ref, BaseModule, Name}}, BaseIn)),
            assert_equal(Value, thrift_runtime_record:to_wire({struct, {ref, HeadModule, Name}}, HeadIn)),
            BaseOut = thrift_runtime_record:from_wire({struct, {ref, BaseModule, Name}}, Value, record),
            HeadOut = thrift_runtime_record:from_wire({struct, {ref, HeadModule, Name}}, Value, record),
            assert_equal(BaseOut, HeadOut),
            assert_equal(Value, thrift_runtime_record:to_wire({struct, {ref, BaseModule, Name}}, BaseOut));
        _ ->
            ok
    end.

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
    Codec = [
        make_case(Spec, Protocol, Entry, Op)
     || Spec <- Specs,
        Protocol <- [binary, compact, json],
        Entry <- [public, direct],
        selected(Protocol, Entry),
        Op <- [encode, decode]
    ],
    Codec ++
        lists:append([conversion_cases(Spec) || Spec <- Specs]) ++
        lists:append([onepass_cases(Spec) || Spec <- Specs]).

%% Conversion cells: one per struct x representation x direction the
%% struct's mode supports. The representation sits in the protocol slot
%% of the key; `THRIFT_BENCH_ENTRY=conversion` selects exactly these rows
%% (codec rows ask for `public`/`direct`), `THRIFT_BENCH_REPR` narrows to
%% one representation. Map-mode structs have no fixture here yet.

conversion_cases(Spec) ->
    Name = maps:get(struct, Spec),
    HeadModule = maps:get(head_module, Spec),
    Mode = repr_mode_of(HeadModule, Name),
    Reprs =
        case Mode of
            record -> [record, map, struct] ++ native_repr();
            sum -> [];
            _ -> []
        end,
    ToWire =
        [conversion_case(Spec, Repr, to_wire) || Repr <- Reprs, selected_conversion(Repr)] ++
            case Mode of
                sum ->
                    [
                        conversion_case(Spec, sum, to_wire)
                     || selected_conversion(sum)
                    ];
                _ ->
                    []
            end,
    FromWire =
        [
            conversion_case(Spec, Repr, from_wire)
         || Repr <- Reprs,
            selected_conversion(Repr)
        ] ++
            case Mode of
                sum -> [conversion_case(Spec, record, from_wire) || selected_conversion(record)];
                _ -> []
            end,
    ToWire ++ FromWire.

selected_conversion(Repr) ->
    selected_env("THRIFT_BENCH_ENTRY", <<"conversion">>) andalso
        selected_env("THRIFT_BENCH_REPR", atom_to_binary(Repr, utf8)).

%% One-pass facade cells: `base` is the explicit two-pass baseline
%% (codec decode/encode + thrift_runtime_record conversion) and `head`
%% is the facade fast path, both on the head side's modules — the pair
%% measures the algorithm, not a code generation. Both baseline and
%% head exist from this task on, so the pre-fast-path run reads
%% ratio ~= 1.00.

onepass_cases(Spec) ->
    Name = maps:get(struct, Spec),
    Value = maps:get(value, Spec),
    HeadModule = maps:get(head_module, Spec),
    HeadDesc = {struct, {ref, HeadModule, Name}},
    Reprs = [record, map, struct] ++ native_repr(),
    lists:append([
        begin
            Bin =
                case thrift_runtime_binary:encode(HeadDesc, Value) of
                    {ok, Io} -> iolist_to_binary(Io)
                end,
            EncValue =
                case Repr of
                    struct -> struct_input(HeadModule, Name, Value);
                    _ -> conversion_input(HeadModule, Name, Repr, to_wire, Value)
                end,
            case selected_onepass(Repr) of
                true ->
                    [
                        onepass_case(Spec, Repr, decode, {HeadDesc, Bin, Repr}),
                        onepass_case(Spec, Repr, encode, {HeadDesc, EncValue})
                    ];
                false ->
                    []
            end
        end
     || Repr <- Reprs
    ]).

struct_input(Module, Name, Value) ->
    {Tag, _} = Module:record_fields(Name),
    (conversion_input(Module, Name, map, to_wire, Value))#{'__struct__' => Tag}.

onepass_case(Spec, Repr, Op, HeadArg) ->
    #{
        key => {maps:get(id, Spec), Repr, onepass, Op},
        base => {onepass_base_op(Op), HeadArg},
        head => {onepass_head_op(Op), HeadArg},
        n => 0
    }.

onepass_base_op(decode) -> decode_twopass;
onepass_base_op(encode) -> encode_twopass.

onepass_head_op(decode) -> decode_onepass;
onepass_head_op(encode) -> encode_onepass.

selected_onepass(Repr) ->
    selected_env("THRIFT_BENCH_ENTRY", <<"onepass">>) andalso
        selected_env("THRIFT_BENCH_REPR", atom_to_binary(Repr, utf8)).

decode_twopass({Desc, Bin, Repr}) ->
    {ok, Wire, <<>>} = thrift_runtime_binary:decode(Desc, Bin),
    thrift_runtime_record:from_wire(Desc, Wire, Repr).

decode_onepass({Desc, Bin, Repr}) ->
    {ok, Value} = thrift_runtime:decode(Desc, Bin, Repr),
    Value.

encode_twopass({Desc, Value}) ->
    Wire = thrift_runtime_record:to_wire(Desc, Value),
    {ok, Io} = thrift_runtime_binary:encode(Desc, Wire),
    %% The facade answers {ok, binary()} — flatten on the baseline too,
    %% so both sides measure the same output contract.
    iolist_to_binary(Io).

encode_onepass({Desc, Value}) ->
    {ok, Io} = thrift_runtime:encode(Desc, Value),
    Io.

-spec repr_mode_of(module(), binary()) -> record | {map, atom | binary} | sum | native | wire.
repr_mode_of(Module, Name) ->
    try Module:record_fields(Name) of
        {sum, _} -> sum;
        {map, KeyType} -> {map, KeyType};
        {native, _} -> native;
        {Tag, _} when is_atom(Tag) -> record;
        none -> wire
    catch
        error:undef -> wire
    end.

native_repr() ->
    case thrift_runtime_native:supported() of
        true -> [native];
        false -> []
    end.

conversion_case(Spec, Repr, Op) ->
    Name = maps:get(struct, Spec),
    Value = maps:get(value, Spec),
    BaseModule = maps:get(base_module, Spec),
    HeadModule = maps:get(head_module, Spec),
    #{
        key => {maps:get(id, Spec), Repr, conversion, Op},
        base => {Op, conversion_arg(BaseModule, Name, Repr, Op, Value)},
        head => {Op, conversion_arg(HeadModule, Name, Repr, Op, Value)},
        n => 0
    }.

conversion_arg(Module, Name, Repr, to_wire, Value) ->
    {Module, Name, conversion_input(Module, Name, Repr, to_wire, Value)};
conversion_arg(Module, Name, Repr, from_wire, Value) ->
    {Module, Name, Repr, Value}.

%% Inputs are built from each side's own introspection, so a baseline
%% module generated by v0.8.0 works unchanged. Record tuples and native
%% records carry every declared field, missing ones as `undefined'.

conversion_input(Module, Name, record, to_wire, Value) ->
    {Tag, _FieldAtoms} = Module:record_fields(Name),
    {_Kind, Fields} = Module:struct_info(Name),
    list_to_tuple([Tag | [maps:get(NameBin, Value, undefined) || {_, _, _, NameBin, _} <- Fields]]);
conversion_input(Module, Name, map, to_wire, Value) ->
    atom_map_input(Module, Name, Value);
conversion_input(Module, Name, struct, to_wire, Value) ->
    {Tag, _FieldAtoms} = Module:record_fields(Name),
    (atom_map_input(Module, Name, Value))#{'__struct__' => Tag};
conversion_input(Module, Name, native, to_wire, Value) ->
    {Tag, FieldAtoms} = Module:record_fields(Name),
    {_Kind, Fields} = Module:struct_info(Name),
    thrift_runtime_native:create(Module, Tag, [
        {Atom, maps:get(NameBin, Value, undefined)}
     || {{_, _, _, NameBin, _}, Atom} <- lists:zip(Fields, FieldAtoms)
    ]);
conversion_input(Module, Name, sum, to_wire, Value) ->
    {sum, _FieldAtoms} = Module:record_fields(Name),
    [NameBin] = maps:keys(Value),
    {binary_to_atom(NameBin, utf8), maps:get(NameBin, Value)}.

atom_map_input(Module, Name, Value) ->
    {_Tag, FieldAtoms} = Module:record_fields(Name),
    {_Kind, Fields} = Module:struct_info(Name),
    maps:from_list([
        {Atom, maps:get(NameBin, Value)}
     || {{_, _, _, NameBin, _}, Atom} <- lists:zip(Fields, FieldAtoms),
        maps:is_key(NameBin, Value)
    ]).

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

to_wire({Module, Name, Value}) ->
    thrift_runtime_record:to_wire({struct, {ref, Module, Name}}, Value).
from_wire({Module, Name, Repr, Value}) ->
    thrift_runtime_record:from_wire({struct, {ref, Module, Name}}, Value, Repr).

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
    Gate = Entry =:= direct orelse Entry =:= conversion orelse Entry =:= onepass,
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
