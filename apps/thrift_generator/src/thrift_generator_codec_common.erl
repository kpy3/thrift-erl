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

-module(thrift_generator_codec_common).

-moduledoc """
Protocol-independent wire types and helper naming for codec emitters.

The generated per-protocol codec indexes (`binary_codec/1`,
`compact_codec/1`, `json_codec/1`) answer `{ok, {Encode, Decode}}` by
wire struct name, where `Encode/1` takes the wire map to `{ok,
iodata()} | {error, _}` and `Decode/1` takes a binary to `{ok, WireMap,
Rest} | more | {error, _}` -- the same contracts as the corresponding
`thrift_runtime_*:encode/2` and `decode/2`. Unknown names answer
`error`; the runtime probes these exports to dispatch named-struct
references to the specialized code. The indexes are internal
(`-doc false` in the generated module): the generated facade and the
runtime are their only callers.
""".

-export([
    enum_registry/1,
    type_name/2,
    typed_prefix/2,
    current_prefix/1,
    codec_pair/3,
    ref_codec_pair/4,
    service_structs/1,
    rpc_struct_name/3,
    decode_body_name/1,
    containers/1,
    elem_type/1,
    used_helpers/2,
    export_entries/3,
    codec_index_forms/3
]).

-export_type([wire_type/0, enum_desc/0, registry/0]).

-include("thrift_generator_model.hrl").

-import(thrift_generator_codec_ast, [
    v/1,
    at/1,
    tuple_t/1,
    tuple_t_type/1,
    clause/3,
    name_lit/1,
    t_atom/1,
    t_atom_lit/1,
    t_ok/1,
    t_union/1,
    t_fun/2,
    spec_form/3,
    atom_concat/2
]).

-define(ANNO, erl_anno:new(0)).

-type enum_desc() :: [{integer(), atom()}].
-type registry() :: #{enum_desc() => pos_integer()}.
-type wire_type() ::
    {base, atom()}
    | {enum, enum_desc()}
    | {list, wire_type()}
    | {set, wire_type(), list | sets | ordset}
    | {set, wire_type()}
    | {map, wire_type(), wire_type()}
    | {struct, {ref, module(), binary()}}.

-doc "Numbers distinct inline enum descriptors by first appearance.".
-spec enum_registry([wire_type()]) -> registry().
enum_registry(WireTypes) ->
    enum_registry(WireTypes, #{}).

-spec enum_registry([wire_type()], registry()) -> registry().
enum_registry([], Acc) ->
    Acc;
enum_registry([{enum, Desc} | Rest], Acc) ->
    case Acc of
        #{Desc := _} -> enum_registry(Rest, Acc);
        _ -> enum_registry(Rest, Acc#{Desc => map_size(Acc) + 1})
    end;
enum_registry([T | Rest], Acc) ->
    enum_registry(children(T) ++ Rest, Acc).

-spec children(wire_type()) -> [wire_type()].
children({list, T}) -> [T];
children({set, T, _Impl}) -> [T];
children({map, K, V}) -> [K, V];
children(_) -> [].

-doc "Renders a wire type as a private helper-name fragment.".
-spec type_name(wire_type(), registry()) -> binary().
type_name({base, B}, _Enums) ->
    atom_to_binary(B, utf8);
type_name({enum, Desc}, Enums) ->
    <<"enum", (integer_to_binary(maps:get(Desc, Enums)))/binary>>;
type_name({list, T}, Enums) ->
    <<"list_", (type_name(T, Enums))/binary>>;
type_name({set, T, _Impl}, Enums) ->
    type_name({set, T}, Enums);
type_name({set, T}, Enums) ->
    <<"set_", (type_name(T, Enums))/binary>>;
type_name({map, K, V}, Enums) ->
    <<"map_", (type_name(K, Enums))/binary, "_", (type_name(V, Enums))/binary>>;
type_name({struct, {ref, TypesMod, Local}}, _Enums) ->
    <<(module_tag(TypesMod))/binary, "_", (thrift_generator_names:snake(Local))/binary>>.

-spec module_tag(module()) -> binary().
module_tag(TypesMod) ->
    binary:replace(atom_to_binary(TypesMod, utf8), <<"_types">>, <<>>).

-doc "Joins a namespace prefix and a snake-case definition name.".
-spec typed_prefix(binary(), binary()) -> binary().
typed_prefix(<<>>, Name) ->
    Name;
typed_prefix(Prefix, Name) ->
    <<Prefix/binary, "_", Name/binary>>.

-doc "Returns the namespace prefix of the module being generated.".
-spec current_prefix(#ectx{}) -> binary().
current_prefix(Ctx) ->
    (maps:get(Ctx#ectx.current, Ctx#ectx.modules))#tg_module.prefix.

-doc "Returns the generated encode/decode function names for a struct and protocol.".
-spec codec_pair(wire | compact | json, binary() | #tg_struct{}, #ectx{}) -> {atom(), atom()}.
codec_pair(Protocol, #tg_struct{name = Name}, Ctx) ->
    codec_pair(Protocol, Name, Ctx);
codec_pair(Protocol, Name, Ctx) when is_binary(Name) ->
    Prefix = typed_prefix(current_prefix(Ctx), thrift_generator_names:snake(Name)),
    Suffix = protocol_suffix(Protocol),
    {
        binary_to_atom(<<"encode_", Prefix/binary, Suffix/binary>>, utf8),
        binary_to_atom(<<"decode_", Prefix/binary, Suffix/binary>>, utf8)
    }.

-doc "Returns codec names in a referenced types module, using that module's namespace prefix.".
-spec ref_codec_pair(wire | compact | json, module(), binary(), #ectx{}) -> {atom(), atom()}.
ref_codec_pair(Protocol, TypesMod, Name, Ctx) ->
    [Target] = [Key || {Key, Module} <- maps:to_list(Ctx#ectx.type_modules), Module =:= TypesMod],
    codec_pair(Protocol, Name, Ctx#ectx{current = Target}).

-doc """
Synthetic structs for the RPC params/result codecs of every service
function: the params struct carries the declared arguments, the result
struct carries field 0 `success` (absent for `void`) plus the declared
exceptions. Oneway functions get no result struct. They feed only the
codec emitters — never `struct_info/1` or the codec indexes.
""".
-spec service_structs(#tg_module{}) -> [#tg_struct{}].
service_structs(Mod) ->
    lists:append([
        service_function_structs(Svc#tg_service.name, F)
     || Svc <- Mod#tg_module.services,
        F <- Svc#tg_service.functions
    ]).

-spec service_function_structs(binary(), #tg_function{}) -> [#tg_struct{}].
service_function_structs(SvcName, F) ->
    Params = #tg_struct{
        kind = struct,
        name = rpc_struct_name(SvcName, F#tg_function.name, params),
        fields = F#tg_function.params
    },
    case F#tg_function.oneway of
        true ->
            [Params];
        false ->
            [
                Params,
                #tg_struct{
                    kind = struct,
                    name = rpc_struct_name(SvcName, F#tg_function.name, result),
                    fields = rpc_result_fields(F)
                }
            ]
    end.

-doc """
The synthetic struct name of a function's params or result: service and
function names joined with `$` — impossible in an IDL identifier, so the
name can never collide with a declared struct.
""".
-spec rpc_struct_name(binary(), binary(), params | result) -> binary().
rpc_struct_name(SvcName, FnName, Kind) ->
    <<SvcName/binary, "$", FnName/binary, "$", (atom_to_binary(Kind, utf8))/binary>>.

-spec rpc_result_fields(#tg_function{}) -> [#tg_field{}].
rpc_result_fields(F) ->
    case F#tg_function.return_type of
        void ->
            F#tg_function.throws;
        Type ->
            [
                #tg_field{id = 0, required = default, type = Type, name = <<"success">>, default = undefined}
                | F#tg_function.throws
            ]
    end.

-spec protocol_suffix(wire | compact | json) -> binary().
protocol_suffix(wire) -> <<"_wire">>;
protocol_suffix(compact) -> <<"_compact">>;
protocol_suffix(json) -> <<"_json">>.

-doc "Returns every container node of a wire type, outermost first.".
-spec containers(wire_type()) -> [wire_type()].
containers({list, T}) -> [{list, T} | containers(T)];
containers({set, T, _Impl}) -> [{set, T} | containers(T)];
containers({map, K, V}) -> [{map, K, V} | containers(K) ++ containers(V)];
containers(_) -> [].

-doc "Returns the element type of a list or normalized set.".
-spec elem_type({list, wire_type()} | {set, wire_type()}) -> wire_type().
elem_type({list, T}) -> T;
elem_type({set, T}) -> T.

-doc "Returns local helper calls and their transitive dependencies found in forms.".
-spec used_helpers(erl_syntax:forms(), #{atom() => [atom()]}) -> [atom()].
used_helpers(Forms, Dependencies) ->
    closure(lists:usort(collect_calls(Forms)), Dependencies, #{}).

-spec collect_calls(term()) -> [atom()].
collect_calls({call, _, {atom, _, Name}, Args}) ->
    [Name | collect_calls(Args)];
collect_calls(Term) when is_tuple(Term) ->
    collect_calls(tuple_to_list(Term));
collect_calls(Term) when is_list(Term) ->
    lists:append([collect_calls(Element) || Element <- Term]);
collect_calls(_) ->
    [].

-spec closure([atom()], #{atom() => [atom()]}, #{atom() => true}) -> [atom()].
closure([], _Dependencies, Seen) ->
    maps:keys(Seen);
closure([Name | Rest], Dependencies, Seen) ->
    case Seen of
        #{Name := true} ->
            closure(Rest, Dependencies, Seen);
        _ ->
            Next = maps:get(Name, Dependencies, []),
            closure(Next ++ Rest, Dependencies, Seen#{Name => true})
    end.

-doc """
The JSON decode-body companion of a struct decode name. The codec index
and the emitter must agree on the spelling, so it lives here.
""".
-spec decode_body_name(atom()) -> atom().
decode_body_name(Decode) ->
    atom_concat(Decode, <<"_body">>).

-doc "Returns the export entries of one protocol's specialized codecs, including the RPC params/result pairs.".
-spec export_entries(wire | compact | json, #tg_module{}, #ectx{}) -> [{atom(), arity()}].
export_entries(Protocol, Mod, Ctx) ->
    [{protocol_index(Protocol), 1}] ++
        lists:append([
            [{Encode, 1}, {Decode, 1}] ++
                case Protocol of
                    json -> [{decode_body_name(Decode), 1}];
                    _ -> []
                end
         || {Encode, Decode} <- [
                codec_pair(Protocol, S, Ctx)
             || S <- Mod#tg_module.structs ++ service_structs(Mod)
            ]
        ]).

-doc "Builds the public codec index of one protocol.".
-spec codec_index_forms(wire | compact | json, #tg_module{}, #ectx{}) -> erl_syntax:forms().
codec_index_forms(Protocol, Mod, Ctx) ->
    Clauses =
        [
            clause([name_lit(S#tg_struct.name)], none, [
                tuple_t([
                    at(ok),
                    tuple_t([
                        {'fun', ?ANNO, {function, Encode, 1}},
                        {'fun', ?ANNO, {function, index_decode_name(Protocol, Decode), 1}}
                    ])
                ])
            ])
         || {S, {Encode, Decode}} <- [{S, codec_pair(Protocol, S, Ctx)} || S <- Mod#tg_module.structs]
        ] ++ [clause([v(index_unknown_name(Protocol))], none, [at(error)])],
    Index = protocol_index(Protocol),
    thrift_generator_emitter_syntax:doc_false_form() ++
        [codec_index_spec(Protocol, Index), {function, ?ANNO, Index, 1, Clauses}].

-spec protocol_index(wire | compact | json) -> atom().
protocol_index(wire) -> binary_codec;
protocol_index(compact) -> compact_codec;
protocol_index(json) -> json_codec.

-spec index_decode_name(wire | compact | json, atom()) -> atom().
index_decode_name(json, Decode) -> decode_body_name(Decode);
index_decode_name(_, Decode) -> Decode.

-spec index_unknown_name(wire | compact | json) -> string().
index_unknown_name(json) -> "_Name";
index_unknown_name(_) -> "_".

-spec codec_index_spec(wire | compact | json, atom()) -> tuple().
codec_index_spec(json, Index) ->
    spec_form(Index, 1, [
        t_fun(
            [t_atom(binary)],
            t_union([
                t_ok(
                    tuple_t_type([
                        t_fun([t_atom(term)], t_atom(term)),
                        t_fun([t_atom(term)], t_atom(term))
                    ])
                ),
                t_atom_lit(error)
            ])
        )
    ]);
codec_index_spec(_, Index) ->
    spec_form(Index, 1, [
        t_fun(
            [t_atom(binary)],
            t_union([
                t_ok(tuple_t_type([t_atom('fun'), t_atom('fun')])),
                t_atom_lit(error)
            ])
        )
    ]).
