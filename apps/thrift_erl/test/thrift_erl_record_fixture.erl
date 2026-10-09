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

%% Struct-descriptor fixture for the representation engine tests: the
%% same surface a generated `<mod>_types` module exposes, covering every
%% `record_fields/1` mode (record, map with atom or binary keys, and the
%% wire passthrough for modules without an entry).

-module(thrift_erl_record_fixture).

-export([struct_info/1, record_fields/1]).

-spec struct_info(binary()) -> thrift_erl_binary:struct_desc() | error.
struct_info(<<"Point">>) ->
    {struct, [
        {1, default, {base, i32}, <<"x">>, undefined},
        {2, default, {base, i32}, <<"y">>, undefined}
    ]};
struct_info(<<"Wrap">>) ->
    {struct, [
        {1, default, {struct, {ref, ?MODULE, <<"Point">>}}, <<"p">>, undefined}
    ]};
struct_info(<<"Bag">>) ->
    {struct, [
        {1, default, {struct, {ref, ?MODULE, <<"Point">>}}, <<"p">>, undefined}
    ]};
struct_info(<<"Loose">>) ->
    {struct, [
        {1, default, {base, string}, <<"s">>, undefined}
    ]};
struct_info(<<"BinKeys">>) ->
    {struct, [
        {1, default, {base, string}, <<"s">>, undefined}
    ]};
struct_info(<<"SetBag">>) ->
    {struct, [
        {1, default, {set, {base, i32}, list}, <<"plain">>, undefined},
        {2, default, {set, {base, i32}, ordset}, <<"ords">>, undefined},
        {3, default, {set, {base, string}, sets}, <<"tags">>, undefined},
        {4, default, {set, {set, {base, i32}, ordset}, sets}, <<"nested">>, undefined}
    ]};
struct_info(_) ->
    error.

%% point/wrap: record mode; bag/loose: map mode with atom keys; binkeys:
%% map mode with binary keys; anything else is the wire passthrough.

-spec record_fields(binary()) -> {atom(), [atom()]} | {map, atom | binary} | none.
record_fields(<<"Point">>) ->
    {point, [x, y]};
record_fields(<<"Wrap">>) ->
    {wrap, [p]};
record_fields(<<"Bag">>) ->
    {map, atom};
record_fields(<<"Loose">>) ->
    {map, atom};
record_fields(<<"BinKeys">>) ->
    {map, binary};
record_fields(<<"SetBag">>) ->
    {setbag, [plain, ords, tags, nested]};
record_fields(_) ->
    none.
