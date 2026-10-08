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

-module(thrift_erl_protocol).

-moduledoc """
Wire protocol behaviour: value and message codecs as pure functions.

A protocol module encodes and decodes values described by the same
type descriptors the generated introspection functions return
(`struct_info/1`, `enum_info/1`, `function_info/2`). Decoding consumes
a binary and returns the remaining bytes, so callers can stream;
`more` marks a truncated but otherwise valid input.

`thrift_erl_binary` and `thrift_erl_compact` implement this behaviour.
Any other module passed as a `thrift_erl:protocol()` — to the facade,
the client or the server — must export every callback with these exact
shapes.

The module also hosts the constants both implementations share: the
`TMessageType` ids of the message envelope and the `TApplicationException`
descriptor with its code-to-name table.
""".

-export([
    message_type_id/1,
    application_exception_desc/0,
    application_exception_name/1
]).

-export_type([protocol/0]).

%% Named protocols known to `thrift_erl:protocol_module/1`; a custom
%% implementation is passed as a module name instead.
-type protocol() :: binary | compact | json.

-doc "Encodes `Value` as `Type`, or fails with a tagged error.".
-callback encode(thrift_erl_binary:type_desc(), term()) -> {ok, iodata()} | {error, term()}.

-doc """
Decodes one value of `Type` from the front of `Binary`; the rest comes
back, `more` marks a valid but truncated input.
""".
-callback decode(thrift_erl_binary:type_desc(), binary()) ->
    thrift_erl_binary:decode_result(term()).

-doc "Wraps an already-encoded payload into a message envelope.".
-callback encode_message(
    thrift_erl_binary:message_type(),
    Name :: binary(),
    SeqId :: non_neg_integer(),
    Payload :: iodata()
) -> iodata().

-doc """
Decodes a message envelope from the front of `Binary`; `more` marks a
truncated one.
""".
-callback decode_message(binary()) ->
    {ok, thrift_erl_binary:message_type(), binary(), non_neg_integer(), binary()}
    | more
    | {error, term()}.

-doc "Encodes a `TApplicationException` payload.".
-callback encode_application_exception(Message :: binary(), Code :: non_neg_integer()) ->
    {ok, iodata()} | {error, term()}.

-doc "Decodes a `TApplicationException` payload.".
-callback decode_application_exception(binary()) ->
    thrift_erl_binary:decode_result(thrift_erl_binary:application_exception()).

%% TMessageType ids shared by the binary envelope and the compact
%% envelope (they travel in different bit layouts, the numbers are the
%% same).
%%
%% The mapping is total over message_type(): an unknown value cannot
%% reach it — callers take message_type() from their own types.

-spec message_type_id(thrift_erl_binary:message_type()) -> non_neg_integer().
message_type_id(call) -> 1;
message_type_id(reply) -> 2;
message_type_id(exception) -> 3;
message_type_id(oneway) -> 4.

-spec application_exception_desc() -> thrift_erl_binary:struct_desc().
application_exception_desc() ->
    {exception, [
        {1, default, {base, string}, <<"message">>, undefined},
        {2, default, {base, i32}, <<"code">>, undefined}
    ]}.

-spec application_exception_name(non_neg_integer()) -> binary().
application_exception_name(0) -> <<"UNKNOWN">>;
application_exception_name(1) -> <<"UNKNOWN_METHOD">>;
application_exception_name(2) -> <<"INVALID_MESSAGE_TYPE">>;
application_exception_name(3) -> <<"WRONG_METHOD_NAME">>;
application_exception_name(4) -> <<"BAD_SEQUENCE_ID">>;
application_exception_name(5) -> <<"MISSING_RESULT">>;
application_exception_name(6) -> <<"INTERNAL_ERROR">>;
application_exception_name(7) -> <<"PROTOCOL_ERROR">>;
application_exception_name(_) -> <<"UNKNOWN">>.
