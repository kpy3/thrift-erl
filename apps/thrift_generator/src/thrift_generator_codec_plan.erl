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

-module(thrift_generator_codec_plan).

-moduledoc """
The single codec emission plan of a types module.

Built once per types module in thrift_generator_emitter:types_forms/2
and consumed by every specialized-codec backend (binary, compact, JSON)
and by the emitter itself (export entries, codec indexes, RPC
service-info hooks). Centralizing the inventory means the backends
share one synthetic-RPC construction, one per-field wire-type list,
one inline-enum registry, one container inventory and one codec-name
table instead of recomputing them per protocol. Declared structs
always precede the synthetic RPC structs; JSON derives its container
inventory from the shared wire types with its unsupported-map cutoff
instead of using the shared `containers' field.
""".

-export([
    build/2,
    codec_pair/3,
    struct_call/6
]).

-include("thrift_generator_model.hrl").

-doc "Builds the codec emission plan of one types module.".
-spec build(#tg_module{}, #ectx{}) -> #tg_codec_plan{}.
build(Mod, Ctx) ->
    Declared = [codec_struct(S, Ctx) || S <- Mod#tg_module.structs],
    RpcStructs = thrift_generator_codec_common:service_structs(Mod),
    Rpc = [codec_struct(S, Ctx) || S <- RpcStructs],
    WireTypes = lists:append([CS#tg_codec_struct.field_types || CS <- Declared ++ Rpc]),
    Enums = thrift_generator_codec_common:enum_registry(WireTypes),
    Containers = lists:usort(
        lists:append([thrift_generator_codec_common:containers(T) || T <- WireTypes])
    ),
    CodecNames = maps:from_list([
        {Protocol, codec_names(Protocol, Mod#tg_module.structs ++ RpcStructs, Ctx)}
     || Protocol <- [wire, compact, json]
    ]),
    #tg_codec_plan{
        module = Mod,
        ctx = Ctx,
        declared = Declared,
        rpc = Rpc,
        wire_types = WireTypes,
        enums = Enums,
        containers = Containers,
        codec_names = CodecNames
    }.

-spec codec_struct(#tg_struct{}, #ectx{}) -> #tg_codec_struct{}.
codec_struct(S, Ctx) ->
    #tg_codec_struct{
        struct = S,
        field_types = [thrift_generator_ir:type_desc(F#tg_field.type, Ctx) || F <- S#tg_struct.fields]
    }.

-spec codec_names(wire | compact | json, [#tg_struct{}], #ectx{}) -> #{binary() => {atom(), atom()}}.
codec_names(Protocol, Structs, Ctx) ->
    maps:from_list([
        {S#tg_struct.name, thrift_generator_codec_common:codec_pair(Protocol, S, Ctx)}
     || S <- Structs
    ]).

-doc "Returns the generated encode/decode function names of one wire struct name.".
-spec codec_pair(wire | compact | json, binary(), #tg_codec_plan{}) -> {atom(), atom()}.
codec_pair(Protocol, Name, Plan) when is_binary(Name) ->
    maps:get(Name, maps:get(Protocol, Plan#tg_codec_plan.codec_names)).

-doc """
The nested-struct codec call of one protocol. A same-module reference
becomes a direct call to the local specialized codec (its name comes
from the plan's codec table); a cross-module reference calls the target
types module directly with its own namespace prefix. JSON decode
selects the `_body' companion — the envelope's `]`-fold belongs to the
top level only. A case body, not a guard: rebuilding the current
module's atom from the binary key is not guard-legal.
""".
-spec struct_call(
    wire | compact | json, encode | decode, module(), binary(), thrift_generator_codec_ast:ast(), #tg_codec_plan{}
) ->
    thrift_generator_codec_ast:ast().
struct_call(Protocol, Op, TypesMod, Name, Arg, Plan) ->
    Ctx = Plan#tg_codec_plan.ctx,
    Local = TypesMod =:= thrift_generator_names:types_module_atom(Ctx#ectx.current),
    Pair =
        case Local of
            true ->
                maps:get(Name, maps:get(Protocol, Plan#tg_codec_plan.codec_names));
            false ->
                thrift_generator_codec_common:ref_codec_pair(Protocol, TypesMod, Name, Ctx)
        end,
    Fun = select_fun(Protocol, Op, Pair),
    case Local of
        true ->
            thrift_generator_codec_ast:call_local(Fun, [Arg]);
        false ->
            thrift_generator_codec_ast:remote(TypesMod, Fun, [Arg])
    end.

-spec select_fun(wire | compact | json, encode | decode, {atom(), atom()}) -> atom().
select_fun(Protocol, Op, {Encode, Decode}) ->
    Fun =
        case Op of
            encode -> Encode;
            decode -> Decode
        end,
    case Protocol =:= json andalso Op =:= decode of
        true -> thrift_generator_codec_common:decode_body_name(Fun);
        false -> Fun
    end.
