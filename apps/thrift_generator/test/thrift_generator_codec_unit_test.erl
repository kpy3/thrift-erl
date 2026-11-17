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

-module(thrift_generator_codec_unit_test).

-moduledoc "Unit tests for protocol-independent codec emitter helpers.".

-include_lib("stdlib/include/assert.hrl").

-export([
    colliding_enum_descriptors_test/0,
    equal_enum_descriptors_share_name_test/0
]).

colliding_enum_descriptors_test() ->
    {D1, D2} = find_enum_collision(0, #{}),
    Registry = thrift_generator_codec_common:enum_registry([{enum, D1}, {enum, D2}]),
    ?assertEqual(2, map_size(Registry)),
    ?assertNotEqual(
        thrift_generator_codec_common:type_name({enum, D1}, Registry),
        thrift_generator_codec_common:type_name({enum, D2}, Registry)
    ),
    ok.

equal_enum_descriptors_share_name_test() ->
    Desc = [{1, 'ONE'}],
    Registry = thrift_generator_codec_common:enum_registry([{enum, Desc}, {enum, Desc}]),
    ?assertEqual(1, map_size(Registry)),
    ?assertEqual(<<"enum1">>, thrift_generator_codec_common:type_name({enum, Desc}, Registry)),
    ok.

find_enum_collision(N, _Seen) when N >= 200000 ->
    erlang:error(no_enum_descriptor_collision);
find_enum_collision(N, Seen) ->
    Desc = [{N, 'A'}],
    Hash = erlang:phash2(Desc),
    case Seen of
        #{Hash := Other} ->
            {Other, Desc};
        _ ->
            find_enum_collision(N + 1, Seen#{Hash => Desc})
    end.
