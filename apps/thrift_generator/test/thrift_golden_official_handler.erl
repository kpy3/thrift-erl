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

-module(thrift_golden_official_handler).

-moduledoc """
Handler for the golden-interop suite, in the OFFICIAL Apache Thrift
Erlang runtime's representation: `handle_function/2` tuples, `dict()` for
maps, officially generated exception records. Serves OUR generated client
through the vendored official server (see `thrift_golden_SUITE`).
""".

-include("priv/golden/gen-erl/thrift_test_types.hrl").

-export([handle_function/2, notify_oneway/1]).

-doc false.
-spec notify_oneway(integer()) -> ok.
notify_oneway(Secs) ->
    case whereis(thrift_golden_oneway_sink) of
        undefined ->
            ok;
        Pid ->
            Pid ! {fired, Secs},
            ok
    end.

%% The official processor convention: arguments arrive as the bare
%% tuple of values `{Arg1, ...}`; the handler answers `{reply, Value}`
%% or `ok` for void/oneway, and throws the generated exception record
%% for declared exceptions.

-doc false.
-spec handle_function(atom(), tuple()) -> {reply, term()} | ok.
handle_function(testVoid, _Args) ->
    ok;
handle_function(testString, {Thing}) ->
    {reply, Thing};
handle_function(testBool, {Thing}) ->
    {reply, Thing};
handle_function(testByte, {Thing}) ->
    {reply, Thing};
handle_function(testI32, {Thing}) ->
    {reply, Thing};
handle_function(testI64, {Thing}) ->
    {reply, Thing};
handle_function(testDouble, {Thing}) ->
    {reply, Thing};
handle_function(testBinary, {Thing}) ->
    {reply, Thing};
handle_function(testStruct, {Thing}) ->
    {reply, Thing};
handle_function(testNest, {Thing}) ->
    {reply, Thing};
handle_function(testMap, {Thing}) ->
    {reply, Thing};
%% The official runtime reads sets as `sets` collections and requires
%% one to write them back, so the value echoes untouched.
handle_function(testSet, {Thing}) ->
    {reply, Thing};
handle_function(testList, {Thing}) ->
    {reply, Thing};
handle_function(testEnum, {Thing}) ->
    {reply, Thing};
handle_function(testTypedef, {Thing}) ->
    {reply, Thing};
handle_function(testMapMap, {Hi}) ->
    {reply, map_map(Hi)};
handle_function(testException, {<<"Xception">>}) ->
    erlang:throw(#'thrift.test.Xception'{errorCode = 1001, message = <<"Xception">>});
handle_function(testException, _Args) ->
    ok;
handle_function(testMultiException, {<<"Xception">>, _}) ->
    erlang:throw(#'thrift.test.Xception'{errorCode = 1001, message = <<"This is not Xception2">>});
handle_function(testMultiException, {<<"Xception2">>, Arg1}) ->
    erlang:throw(#'thrift.test.Xception2'{
        errorCode = 2002,
        struct_thing = #'thrift.test.Xtruct'{string_thing = Arg1}
    });
handle_function(testMultiException, {_, Arg1}) ->
    {reply, #'thrift.test.Xtruct'{string_thing = Arg1}};
handle_function(testOneway, {Secs}) ->
    notify_oneway(Secs),
    ok.

%% Canonical ThriftTest semantics: keys -4 and 4; inner keys are their
%% own values (-4..-1 for -4, 1..4 for 4). The official representation
%% uses `dict()` at every map level.

map_map(_Hi) ->
    dict:from_list([
        {I, dict:from_list([{J, J} || J <- inner_keys(I)])}
     || I <- [-4, 4]
    ]).

inner_keys(I) when I < 0 -> lists:seq(I, -1);
inner_keys(I) -> lists:seq(1, I).
