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

%% Handler for the map-mode fixture (`MapSvc`): the loopback case runs
%% the generated stack where structs declared with
%% `erl.struct_type = "map"` travel as maps. Atom-key maps come with the
%% default key type, binary-key maps with
%% `erl.struct_type.map.key_type = "binary"`; the record-mode parent
%% keeps its record shape with map-mode children inside.

-module(thrift_generator_mapmode_handler).

-export([reflect/1, wrap/1, area/2]).
-export_type([point/0]).

-record(mapmode_nest, {p, b}).
-record(mapmode_oops, {why}).

-type point() :: #{x => integer(), y => integer()}.

-spec reflect(point()) -> {ok, point()}.
reflect(#{x := X, y := Y}) ->
    {ok, #{x => Y, y => X}}.

-spec wrap(point()) -> {ok, #mapmode_nest{}}.
wrap(P) ->
    {ok, #mapmode_nest{p = P, b = #{<<"x">> => maps:get(x, P) + 100}}}.

-spec area(integer(), integer()) ->
    {ok, integer()}
    | {error, {exception, binary(), #mapmode_oops{}}}.
area(W, _H) when W < 0 ->
    {error, {exception, <<"Oops">>, #mapmode_oops{why = <<"negative width">>}}};
area(W, H) ->
    {ok, W * H}.
