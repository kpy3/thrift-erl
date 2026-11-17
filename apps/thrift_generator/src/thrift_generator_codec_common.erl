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

-moduledoc "Protocol-independent wire types and helper naming for codec emitters.".

-export([
    enum_registry/1,
    type_name/2,
    typed_prefix/2,
    current_prefix/1,
    codec_pair/3,
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

-doc "Returns the export entries of one protocol's specialized codecs.".
-spec export_entries(wire | compact | json, #tg_module{}, #ectx{}) -> [{atom(), arity()}].
export_entries(Protocol, Mod, Ctx) ->
    [{protocol_index(Protocol), 1}] ++
        lists:append([
            [{Encode, 1}, {Decode, 1}] ++
                case Protocol of
                    json -> [{atom_concat(Decode, <<"_body">>), 1}];
                    _ -> []
                end
         || {Encode, Decode} <- [codec_pair(Protocol, S, Ctx) || S <- Mod#tg_module.structs]
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
    thrift_generator_emitter_syntax:doc_form(undefined, codec_index_doc(Protocol)) ++
        [codec_index_spec(Protocol, Index), {function, ?ANNO, Index, 1, Clauses}].

-spec protocol_index(wire | compact | json) -> atom().
protocol_index(wire) -> binary_codec;
protocol_index(compact) -> compact_codec;
protocol_index(json) -> json_codec.

-spec index_decode_name(wire | compact | json, atom()) -> atom().
index_decode_name(json, Decode) -> atom_concat(Decode, <<"_body">>);
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

-spec codec_index_doc(wire | compact | json) -> binary().
codec_index_doc(wire) ->
    <<
        "The binary-protocol wire codecs of this module's structs, by wire"
        " struct name: `{ok, {Encode, Decode}}` where `Encode/1` takes the"
        " wire map to `{ok, iodata()} | {error, _}` and `Decode/1` takes a"
        " binary to `{ok, WireMap, Rest} | more | {error, _}` -- the same"
        " contracts as `thrift_runtime_binary:encode/2` and `decode/2`."
        " Unknown names answer `error`; `thrift_runtime_binary` probes this"
        " export to dispatch named-struct references to the specialized"
        " code."
    >>;
codec_index_doc(compact) ->
    <<
        "The compact-protocol wire codecs of this module's structs, by wire"
        " struct name: `{ok, {Encode, Decode}}` where `Encode/1` takes the"
        " wire map to `{ok, iodata()} | {error, _}` and `Decode/1` takes a"
        " binary to `{ok, WireMap, Rest} | more | {error, _}` -- the same"
        " contracts as `thrift_runtime_compact:encode/2` and `decode/2`."
        " Unknown names answer `error`; `thrift_runtime_compact` probes this"
        " export to dispatch named-struct references to the specialized"
        " code."
    >>;
codec_index_doc(json) ->
    <<
        "The specialized JSON codec pair by wire struct name:"
        " `error` for names this module does not define. The decode"
        " side is the non-folding struct body: folding the envelope's"
        " closing `]` is the caller's (the runtime's top-level entry"
        " points') job."
    >>.
