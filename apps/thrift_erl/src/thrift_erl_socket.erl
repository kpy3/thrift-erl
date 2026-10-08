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

Two framing modes, mirroring the classic Thrift transports:

- `framed` — every message is prefixed with its big-endian i32 length;
  a `max_frame_size` guards against hostile sizes.
- `buffered` — raw byte stream; message boundaries come from the
  protocol itself: `extract_message/4` probes the envelope and payload
  struct with the protocol module's decode functions, which answer
  `more` while the input is a truncated but valid encoding.

Socket reads happen in the owning processes via `{active, N}` delivery
— this module only provides the pure frame splitter over accumulated
buffers plus send/listen/accept helpers.
""".

-export([
    send/2,
    extract_message/4,
    listen/1,
    accept/1
]).

-export_type([transport/0, socket/0]).

-type transport() :: buffered | framed.
-type socket() :: gen_tcp:socket().

%%--------------------------------------------------------------------
%% Writes
%%--------------------------------------------------------------------

-doc "Sends iodata over the socket.".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send(Socket, Data) ->
    gen_tcp:send(Socket, Data).

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
extract_message(Buffer, buffered, ProtocolMod, _MaxFrameSize) ->
    case ProtocolMod:decode_message(Buffer) of
        {ok, _Type, _Name, _SeqId, Tail} ->
            %% Decoding a descriptor with no fields makes every wire
            %% field unknown, so the codec skips each by wire type —
            %% exactly the completeness probe we need.
            case ProtocolMod:decode({struct, {struct, []}}, Tail) of
                {ok, _Skipped, Leftover} ->
                    Consumed = byte_size(Buffer) - byte_size(Leftover),
                    {ok, binary:part(Buffer, 0, Consumed), Leftover};
                more ->
                    more;
                {error, Reason} ->
                    {error, {bad_frame, Reason}}
            end;
        more ->
            more;
        {error, Reason} ->
            {error, {bad_frame, Reason}}
    end.

%%--------------------------------------------------------------------
%% Listening
%%--------------------------------------------------------------------

-doc """
Listens with the standard socket options (binary, passive, raw) plus
`backlog` from `Opts`.

The listen socket stays passive; accepted connections switch
themselves to `{active, N}` delivery after taking ownership.
""".
-spec listen(map()) -> {ok, socket()} | {error, term()}.
listen(#{port := Port} = Opts) ->
    Backlog = maps:get(backlog, Opts, 1024),
    gen_tcp:listen(Port, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, Backlog}
    ]).

-doc "Accepts one connection.".
-spec accept(socket()) -> {ok, socket()} | {error, term()}.
accept(ListenSocket) ->
    gen_tcp:accept(ListenSocket, infinity).
