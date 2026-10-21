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

-module(thrift_runtime_transport).

-moduledoc """
Send-side framing shared by the connection and the client.

Both endpoints used to carry the same `case Transport of` shape on
every send; this module is the one copy. It is deliberately thin — the
receive side goes through `thrift_runtime_socket:extract_message/4` (and
`thrift_runtime_http` for HTTP), and the process skeletons around both
directions stay in their gen_servers because their error policies
genuinely differ.
""".

-export([server_frame/2, client_frame/4]).

-doc """
Frames an encoded message for the server-to-client direction.

`framed` prefixes a big-endian i32 length, `buffered` sends the message
as is, and `http` answers one request with one 200 response whose body
carries the message — HTTP is request/response even for oneways.
""".
-spec server_frame(thrift_runtime_socket:transport(), iodata()) -> iodata().
server_frame(framed, Message) ->
    [<<(iolist_size(Message)):32/big-unsigned>>, Message];
server_frame(buffered, Message) ->
    Message;
server_frame(http, Message) ->
    thrift_runtime_http:response(200, [], Message).

-doc """
Frames an encoded message for the client-to-server direction.

`Host` and `Path` are the HTTP request-line ingredients; other
transports ignore them.
""".
-spec client_frame(
    thrift_runtime_socket:transport(),
    iodata(),
    Host :: binary(),
    Path :: binary()
) ->
    iodata().
client_frame(framed, Message, _Host, _Path) ->
    [<<(iolist_size(Message)):32/big-unsigned>>, Message];
client_frame(buffered, Message, _Host, _Path) ->
    Message;
client_frame(http, Message, Host, Path) ->
    thrift_runtime_http:request(Host, Path, [], Message).
