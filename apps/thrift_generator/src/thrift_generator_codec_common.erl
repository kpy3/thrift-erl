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

-export([enum_registry/1, type_name/2]).

-export_type([wire_type/0, enum_desc/0, registry/0]).

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
