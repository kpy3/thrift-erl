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
    used_helpers/2
]).

-export_type([wire_type/0, enum_desc/0, registry/0]).

-include("thrift_generator_model.hrl").

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
