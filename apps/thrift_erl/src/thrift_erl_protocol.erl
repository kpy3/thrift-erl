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

`thrift_erl_binary` implements this behaviour. Any other module passed
as a `thrift_erl:protocol()` — to the facade, the client or the server
— must export every callback with these exact shapes.
""".

-export_type([protocol/0]).

%% Named protocols known to `thrift_erl:protocol_module/1`; a custom
%% implementation is passed as a module name instead.
-type protocol() :: binary | compact.

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
