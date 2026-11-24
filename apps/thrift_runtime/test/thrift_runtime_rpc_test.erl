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

%% The RPC conversion boundary (`thrift_runtime_rpc`): call arguments and
%% whole call results between the handler representation and the wire
%% representation, over the canonical descriptor types. The representation
%% engine itself (`thrift_runtime_record`) stays the conversion backend.

-module(thrift_runtime_rpc_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    args_conversion_test/0,
    void_result_test/0,
    value_result_test/0,
    exception_conversion_test/0
]).

-define(FIXTURE, thrift_runtime_record_fixture).

%% Call arguments convert in both directions, structurally: the record
%% `{point, 1, 2}' is the wire map `#{<<"x">> => 1, <<"y">> => 2}' nested
%% inside the params struct's single field.

args_conversion_test() ->
    Point = {struct, {ref, ?FIXTURE, <<"Point">>}},
    Params = {struct, {struct, [{1, default, Point, <<"p">>, undefined}]}},
    ?assertEqual(
        [#{<<"x">> => 1, <<"y">> => 2}],
        thrift_runtime_rpc:args_to_wire(Params, [{point, 1, 2}])
    ),
    ?assertEqual(
        [{point, 1, 2}],
        thrift_runtime_rpc:args_from_wire(Params, [#{<<"x">> => 1, <<"y">> => 2}])
    ),
    ok.

%% A `void' function: `ok' from the handler stays `ok', and the wire-level
%% `{ok, undefined}' of a void reply normalizes to the bare atom; any other
%% bare `ok' passes through unchanged.

void_result_test() ->
    ?assertEqual(ok, thrift_runtime_rpc:result_to_wire(undefined, [], ok)),
    ?assertEqual(ok, thrift_runtime_rpc:call_result_from_wire(undefined, [], {ok, undefined})),
    ?assertEqual(ok, thrift_runtime_rpc:call_result_from_wire(undefined, [], ok)),
    %% a non-void handler answering the historical void shape is not
    %% translated either — it passes through to the strict result check
    ?assertEqual(
        {ok, undefined},
        thrift_runtime_rpc:result_to_wire(undefined, [], {ok, undefined})
    ),
    ok.

%% A non-void function: `{ok, Value}' converts through the reply type in
%% both directions.

value_result_test() ->
    ReplyType = {base, i32},
    ?assertEqual({ok, 5}, thrift_runtime_rpc:result_to_wire(ReplyType, [], {ok, 5})),
    ?assertEqual({ok, 5}, thrift_runtime_rpc:call_result_from_wire(ReplyType, [], {ok, 5})),
    ok.

%% Declared exceptions: the explicit wire name converts the value through
%% the exception's struct type in both directions; a tag-identified value
%% (record tag) resolves to its struct's wire name; a map-representation
%% exception carries no identity — it stays untranslated instead of being
%% inferred.

exception_conversion_test() ->
    Point = {struct, {ref, ?FIXTURE, <<"Point">>}},
    WirePoint = #{<<"x">> => 1, <<"y">> => 2},
    Exceptions = [{1, default, Point, <<"p">>, undefined}],
    %% explicit name: record -> wire and wire -> record
    ?assertEqual(
        {error, {exception, <<"Point">>, WirePoint}},
        thrift_runtime_rpc:result_to_wire(undefined, Exceptions, {error, {exception, <<"Point">>, {point, 1, 2}}})
    ),
    ?assertEqual(
        {error, {exception, {point, 1, 2}}},
        thrift_runtime_rpc:call_result_from_wire(undefined, Exceptions, {error, {exception, <<"Point">>, WirePoint}})
    ),
    %% the value's record tag alone identifies the exception: the name is
    %% resolved against the declared exceptions
    ?assertEqual(
        {error, {exception, <<"Point">>, WirePoint}},
        thrift_runtime_rpc:result_to_wire(undefined, Exceptions, {error, {exception, {point, 1, 2}}})
    ),
    %% a map-mode exception has no representation identity: the tag-less
    %% form is not translated and not guessed
    Bag = {struct, {ref, ?FIXTURE, <<"Bag">>}},
    BagExceptions = [{1, default, Bag, <<"b">>, undefined}],
    BagValue = #{<<"p">> => WirePoint},
    ?assertEqual(
        {error, {exception, BagValue}},
        thrift_runtime_rpc:result_to_wire(undefined, BagExceptions, {error, {exception, BagValue}})
    ),
    %% an unknown wire name on the way in drops the name, keeping the value
    ?assertEqual(
        {error, {exception, WirePoint}},
        thrift_runtime_rpc:call_result_from_wire(undefined, Exceptions, {error, {exception, <<"Nope">>, WirePoint}})
    ),
    ok.
