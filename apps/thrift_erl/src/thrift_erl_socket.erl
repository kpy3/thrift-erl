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

-module(thrift_erl_socket).

-moduledoc """
Socket plumbing shared by the client and the server connection.

Sockets are tagged — `{tcp, gen_tcp:socket()}` or
`{ssl, ssl:sslsocket()}` — so every helper dispatches on the tag and
the rest of the runtime carries one socket type. Plain TCP is the
default; passing `ssl_opts` (a list of `ssl:tls_server_option()` on
the server, `ssl:tls_client_option()` on the client) switches the
listen/connect path to TLS.

Two framing modes, mirroring the classic Thrift transports:

- `framed` — every message is prefixed with its big-endian i32 length;
  a `max_frame_size` guards against hostile sizes.
- `buffered` — raw byte stream; message boundaries come from the
  protocol itself: `extract_message/4` probes the envelope and payload
  struct with the protocol module's decode functions, which answer
  `more` while the input is a truncated but valid encoding; a
  truncated message that grows past `max_frame_size` is rejected, the
  same bound framed mode applies to the length prefix.
- `http` — each Thrift message rides as the body of one HTTP/1.1
  exchange; `thrift_erl_http` provides the framing (requests on the
  server, responses on the client) with the same `more` semantics, and
  `max_frame_size` bounds the body. The two directions parse
  differently, so the endpoints call it directly instead of going
  through `extract_message/4`.

Socket reads happen in the owning processes via `{active, N}` delivery
— this module only provides the pure frame splitter over accumulated
buffers plus the send/listen/accept/connect helpers.
""".

-export([
    send/2,
    extract_message/4,
    listen/1,
    accept/3,
    connect/4,
    set_active/2,
    controlling_process/2,
    close/1,
    peername/1
]).

-export_type([transport/0, socket/0]).

-type transport() :: buffered | framed | http.
-type socket() :: {tcp, gen_tcp:socket()} | {ssl, ssl:sslsocket()}.

%%--------------------------------------------------------------------
%% Writes
%%--------------------------------------------------------------------

-doc "Sends iodata over the socket.".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send({tcp, Socket}, Data) ->
    gen_tcp:send(Socket, Data);
send({ssl, Socket}, Data) ->
    ssl:send(Socket, Data).

-doc "The remote endpoint of the socket, for the connection events.".
-spec peername(socket()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername({tcp, Socket}) ->
    inet:peername(Socket);
peername({ssl, Socket}) ->
    ssl:peername(Socket).

%%--------------------------------------------------------------------
%% Frame splitting
%%--------------------------------------------------------------------

-doc """
Splits one complete message off the front of `Buffer`.

`more` means the buffer holds a truncated but so-far valid encoding —
wait for more bytes. `framed` counts the length prefix against
`MaxFrameSize`; `buffered` probes completeness with `ProtocolMod`
(the envelope plus a skip-everything payload struct), so any protocol
implementing `thrift_erl_protocol` with streaming-friendly `more`
semantics works.

Errors mean the bytes cannot form a valid message: the stream is
unrecoverable and the owning connection must close.
""".
-spec extract_message(binary(), transport(), module(), MaxFrameSize :: pos_integer()) ->
    {ok, Message :: binary(), Leftover :: binary()} | more | {error, term()}.
extract_message(Buffer, framed, _ProtocolMod, MaxFrameSize) ->
    case Buffer of
        <<Size:32/big-unsigned, Rest/binary>> when Size =< MaxFrameSize ->
            case Rest of
                <<Frame:Size/binary, Leftover/binary>> -> {ok, Frame, Leftover};
                _ -> more
            end;
        <<_Size:32/big-unsigned, _/binary>> ->
            {error, frame_too_large};
        _ ->
            more
    end;
extract_message(Buffer, buffered, ProtocolMod, MaxFrameSize) ->
    case ProtocolMod:decode_message(Buffer) of
        {ok, _Type, _Name, _SeqId, Tail} ->
            %% Decoding a descriptor with no fields makes every wire
            %% field unknown, so the codec skips each by wire type —
            %% exactly the completeness probe we need.
            case ProtocolMod:decode({struct, {struct, []}}, Tail) of
                {ok, _Skipped, Leftover} ->
                    Consumed = byte_size(Buffer) - byte_size(Leftover),
                    case Consumed =< MaxFrameSize of
                        true ->
                            {ok, binary:part(Buffer, 0, Consumed), Leftover};
                        false ->
                            {error, frame_too_large}
                    end;
                more ->
                    more_capped(Buffer, MaxFrameSize);
                {error, Reason} ->
                    {error, {bad_frame, Reason}}
            end;
        more ->
            more_capped(Buffer, MaxFrameSize);
        {error, Reason} ->
            {error, {bad_frame, Reason}}
    end.

%% `more` on an incomplete message: the buffer may only grow up to
%% max_frame_size — the same bound framed mode applies to the length
%% prefix. At this point the buffer holds an incomplete head message
%% (a complete one would have been extracted), so a buffer past the
%% cap means the message itself never fits.

-spec more_capped(binary(), pos_integer()) -> more | {error, frame_too_large}.
more_capped(Buffer, MaxFrameSize) when byte_size(Buffer) > MaxFrameSize ->
    {error, frame_too_large};
more_capped(_Buffer, _MaxFrameSize) ->
    more.

%%--------------------------------------------------------------------
%% Listening and connecting
%%--------------------------------------------------------------------

-doc """
Listens with the standard socket options (binary, passive, raw) plus
`backlog` from `Opts`.

With `ssl_opts` in `Opts` (a list of `ssl:tls_server_option()`) the
listener is TLS. The listen socket stays passive; accepted connections
switch themselves to `{active, N}` delivery after taking ownership.
""".
-spec listen(map()) -> {ok, socket()} | {error, term()}.
listen(#{port := Port} = Opts) ->
    Backlog = maps:get(backlog, Opts, 1024),
    Base = [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, Backlog}
    ],
    case maps:get(ssl_opts, Opts, undefined) of
        undefined ->
            case gen_tcp:listen(Port, Base) of
                {ok, Socket} -> {ok, {tcp, Socket}};
                {error, Reason} -> {error, Reason}
            end;
        SslOpts when is_list(SslOpts) ->
            case ssl:listen(Port, Base ++ SslOpts) of
                {ok, Socket} -> {ok, {ssl, Socket}};
                {error, Reason} -> {error, Reason}
            end
    end.

-doc """
Accepts one connection from the listen socket.

`AcceptTimeout` slices the wait so the caller (the acceptor) stays
responsive between accepts; on TLS the subsequent handshake gets
`HandshakeTimeout` of silence before failing.
""".
-spec accept(socket(), AcceptTimeout :: timeout(), HandshakeTimeout :: timeout()) ->
    {ok, socket()} | {error, term()}.
accept({tcp, ListenSocket}, AcceptTimeout, _HandshakeTimeout) ->
    case gen_tcp:accept(ListenSocket, AcceptTimeout) of
        {ok, Socket} -> {ok, {tcp, Socket}};
        {error, Reason} -> {error, Reason}
    end;
accept({ssl, ListenSocket}, AcceptTimeout, HandshakeTimeout) ->
    case ssl:transport_accept(ListenSocket, AcceptTimeout) of
        {ok, TransportSocket} ->
            case ssl:handshake(TransportSocket, HandshakeTimeout) of
                {ok, SslSocket} ->
                    {ok, {ssl, SslSocket}};
                {error, Reason} ->
                    close({ssl, TransportSocket}),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Connects to `Host:Port`; with `SslOpts` (a list of
`ssl:tls_client_option()`) the connection is TLS, otherwise plain TCP.
""".
-spec connect(
    inet:socket_address() | inet:hostname(),
    inet:port_number(),
    SslOpts :: [term()] | undefined,
    timeout()
) -> {ok, socket()} | {error, term()}.
connect(Host, Port, SslOpts, Timeout) ->
    Base = [binary, {packet, raw}, {active, false}, {nodelay, true}],
    case SslOpts of
        undefined ->
            case gen_tcp:connect(Host, Port, Base, Timeout) of
                {ok, Socket} -> {ok, {tcp, Socket}};
                {error, Reason} -> {error, Reason}
            end;
        Opts when is_list(Opts) ->
            case ssl:connect(Host, Port, Base ++ Opts, Timeout) of
                {ok, Socket} -> {ok, {ssl, Socket}};
                {error, Reason} -> {error, Reason}
            end
    end.

%%--------------------------------------------------------------------
%% Shared dispatchers
%%--------------------------------------------------------------------

-doc """
Arms `{active, N}` delivery on the socket.

The passive->active flow is what the connections re-arm on
`tcp_passive`/`ssl_passive` after each consumed batch.
""".
-spec set_active(socket(), pos_integer()) -> ok.
set_active({tcp, Socket}, N) ->
    ok = inet:setopts(Socket, [{active, N}]);
set_active({ssl, Socket}, N) ->
    ok = ssl:setopts(Socket, [{active, N}]).

-doc "Hands the socket to `Pid`, which becomes its controlling process.".
-spec controlling_process(socket(), pid()) -> ok | {error, term()}.
controlling_process({tcp, Socket}, Pid) ->
    gen_tcp:controlling_process(Socket, Pid);
controlling_process({ssl, Socket}, Pid) ->
    ssl:controlling_process(Socket, Pid).

-doc "Closes the socket.".
-spec close(socket()) -> ok.
close({tcp, Socket}) ->
    gen_tcp:close(Socket),
    ok;
close({ssl, Socket}) ->
    ssl:close(Socket),
    ok.
