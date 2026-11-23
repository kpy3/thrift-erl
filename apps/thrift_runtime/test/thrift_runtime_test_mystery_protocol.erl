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

%% A `thrift_runtime_protocol' test double: behaves exactly like the
%% binary protocol, except that every decoded struct map gains one
%% unknown key. The generic engine and the generated codecs skip unknown
%% wire ids, so a real payload can never produce a decoded result map
%% without the `success' entry; a custom protocol module — a supported
%% client option — can, which is the shape the badkey regression case
%% pins.

-module(thrift_runtime_test_mystery_protocol).

-behaviour(thrift_runtime_protocol).

-export([encode/2, decode/2, encode_message/4, decode_message/1]).
-export([encode_application_exception/2, decode_application_exception/1]).

-spec encode(thrift_runtime_binary:type_desc(), term()) -> {ok, iodata()} | {error, term()}.
encode(Desc, Value) ->
    thrift_runtime_binary:encode(Desc, Value).

-spec decode(thrift_runtime_binary:type_desc(), binary()) ->
    {ok, term(), binary()} | more | {error, term()}.
decode(Desc, Binary) ->
    case thrift_runtime_binary:decode(Desc, Binary) of
        {ok, Values, Rest} when is_map(Values) ->
            {ok, maps:put(<<"mystery">>, 1, Values), Rest};
        Other ->
            Other
    end.

-spec encode_message(term(), binary(), non_neg_integer(), iodata()) -> iodata().
encode_message(Type, Name, SeqId, Payload) ->
    thrift_runtime_binary:encode_message(Type, Name, SeqId, Payload).

-spec decode_message(binary()) ->
    {ok, term(), binary(), non_neg_integer(), binary()} | more | {error, term()}.
decode_message(Binary) ->
    thrift_runtime_binary:decode_message(Binary).

-spec encode_application_exception(binary(), non_neg_integer()) -> {ok, iodata()} | {error, term()}.
encode_application_exception(Message, Code) ->
    thrift_runtime_binary:encode_application_exception(Message, Code).

-spec decode_application_exception(binary()) ->
    {ok, map(), binary()} | more | {error, term()}.
decode_application_exception(Binary) ->
    thrift_runtime_binary:decode_application_exception(Binary).
