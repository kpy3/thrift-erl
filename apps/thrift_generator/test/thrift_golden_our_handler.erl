%% Copyright 2025 Sergei Yelin
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

-module(thrift_golden_our_handler).

-moduledoc """
Handler for the golden-interop suite, in OUR representation: records and
atoms as produced by the generated `ThriftTest_handler` behaviour. Serves
the officially generated client through our runtime (see
`thrift_golden_SUITE`).
""".

-include("thrift_golden_records.hrl").

-export([
    testVoid/0,
    testString/1,
    testBool/1,
    testByte/1,
    testI32/1,
    testI64/1,
    testDouble/1,
    testBinary/1,
    testStruct/1,
    testNest/1,
    testMap/1,
    testSet/1,
    testList/1,
    testEnum/1,
    testTypedef/1,
    testMapMap/1,
    testException/1,
    testMultiException/2,
    testOneway/1
]).

-doc false.
testVoid() ->
    {ok, undefined}.

-doc false.
testString(Thing) ->
    {ok, Thing}.

-doc false.
testBool(Thing) ->
    {ok, Thing}.

-doc false.
testByte(Thing) ->
    {ok, Thing}.

-doc false.
testI32(Thing) ->
    {ok, Thing}.

-doc false.
testI64(Thing) ->
    {ok, Thing}.

-doc false.
testDouble(Thing) ->
    {ok, Thing}.

-doc false.
testBinary(Thing) ->
    {ok, Thing}.

-doc false.
testStruct(#xtruct{} = Thing) ->
    {ok, Thing}.

-doc false.
testNest(#xtruct2{} = Thing) ->
    {ok, Thing}.

-doc false.
testMap(Thing) ->
    {ok, Thing}.

-doc false.
testSet(Thing) ->
    {ok, Thing}.

-doc false.
testList(Thing) ->
    {ok, Thing}.

-doc false.
testEnum(Thing) ->
    {ok, Thing}.

-doc false.
testTypedef(Thing) ->
    {ok, Thing}.

-doc false.
%% Canonical ThriftTest semantics: keys -4 and 4; inner keys are their
%% own values (-4..-1 for -4, 1..4 for 4), plain maps on our side.
testMapMap(_Hi) ->
    {ok, #{
        -4 => #{J => J || J <- lists:seq(-4, -1)},
        4 => #{J => J || J <- lists:seq(1, 4)}
    }}.

-doc false.
testException(<<"Xception">>) ->
    {error, {exception, <<"Xception">>, #xception{errorCode = 1001, message = <<"Xception">>}}};
testException(_) ->
    {ok, undefined}.

-doc false.
testMultiException(<<"Xception">>, _) ->
    {error, {exception, <<"Xception">>, #xception{errorCode = 1001, message = <<"This is not Xception2">>}}};
testMultiException(<<"Xception2">>, Arg1) ->
    {error, {exception, <<"Xception2">>, #xception2{errorCode = 2002, struct_thing = #xtruct{string_thing = Arg1}}}};
testMultiException(_, Arg1) ->
    {ok, #xtruct{string_thing = Arg1}}.

-doc false.
testOneway(Secs) ->
    thrift_golden_official_handler:notify_oneway(Secs),
    {ok, undefined}.
