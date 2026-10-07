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

-module(thrift_erl_socket).

-moduledoc """
Socket plumbing shared by the client and the server connection.

Two framing modes, mirroring the classic Thrift transports:

- `framed` — every message is prefixed with its big-endian i32 length;
  a `max_frame_size` guards against hostile sizes.
- `buffered` — raw byte stream; messages are parsed incrementally by
  retrying `thrift_erl_binary:decode_message/1` whenever new bytes
  arrive and it answers `more`.

All functions are plain helpers over `gen_tcp`; each takes the socket
and a per-call timeout.
""".

-export([
    send/2,
    recv_message/5,
    read_frame/2,
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
%% Reads
%%--------------------------------------------------------------------

-doc """
Reads one complete message.

In `framed` mode reads the length prefix (checked against
`MaxFrameSize`), then the frame. In `buffered` mode keeps reading
whatever is available until the envelope and its payload struct parse
completely; `InitialBuffer` carries leftover bytes of the next message
from a previous read.

The timeout applies to every individual socket read.
""".
-spec recv_message(
    socket(),
    transport(),
    Timeout :: non_neg_integer() | infinity,
    MaxFrameSize :: pos_integer(),
    InitialBuffer :: binary()
) ->
    {ok, Message :: binary(), Leftover :: binary()}
    | {error, closed | timeout | frame_too_large | bad_frame | term()}.
recv_message(Socket, framed, Timeout, MaxFrameSize, _InitialBuffer) ->
    case recv_exact(Socket, 4, Timeout, []) of
        {ok, <<Size:32/big-unsigned>>} when Size =< MaxFrameSize ->
            case recv_exact(Socket, Size, Timeout, []) of
                {ok, Frame} -> {ok, Frame, <<>>};
                Error -> Error
            end;
        {ok, _} ->
            {error, frame_too_large};
        Error ->
            Error
    end;
recv_message(Socket, buffered, Timeout, _MaxFrameSize, InitialBuffer) ->
    recv_buffered(Socket, InitialBuffer, Timeout).

-doc "Reads a framed transport frame header (4-byte size prefix).".
-spec read_frame(socket(), Timeout :: non_neg_integer() | infinity) ->
    {ok, binary()} | {error, closed | timeout | term()}.
read_frame(Socket, Timeout) ->
    recv_exact(Socket, 4, Timeout, []).

-spec recv_exact(socket(), non_neg_integer(), Timeout :: non_neg_integer() | infinity, [binary()]) ->
    {ok, binary()} | {error, closed | timeout | term()}.
recv_exact(_Socket, 0, _Timeout, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
recv_exact(Socket, N, Timeout, Acc) ->
    case gen_tcp:recv(Socket, N, Timeout) of
        {ok, Data} ->
            recv_exact(Socket, N - byte_size(Data), Timeout, [Data | Acc]);
        Error ->
            Error
    end.

-spec recv_buffered(socket(), binary(), Timeout :: non_neg_integer() | infinity) ->
    {ok, binary(), binary()} | {error, closed | timeout | bad_frame | term()}.
recv_buffered(Socket, Buffer, Timeout) ->
    case message_complete(Buffer) of
        complete ->
            split_complete(Buffer);
        incomplete ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, Data} ->
                    recv_buffered(Socket, <<Buffer/binary, Data/binary>>, Timeout);
                Error ->
                    Error
            end;
        invalid ->
            %% Bytes that cannot form a valid envelope or payload:
            %% the stream is unrecoverable.
            {error, bad_frame}
    end.

%% Splits a complete buffered message into the message bytes and the
%% leftover that belongs to the next one, by skipping the payload
%% struct with an empty descriptor (every field unknown, skipped by
%% wire type).

-spec split_complete(binary()) -> {ok, binary(), binary()}.
split_complete(Buffer) ->
    {ok, _Type, _Name, _SeqId, Tail} = thrift_erl_binary:decode_message(Buffer),
    {ok, _Skipped, Leftover} = thrift_erl_binary:decode({struct, {struct, []}}, Tail),
    Consumed = byte_size(Buffer) - byte_size(Leftover),
    {ok, binary:part(Buffer, 0, Consumed), Leftover}.

%% A message is complete when its envelope parses and the payload
%% struct can be consumed to its stop byte. Decoding a descriptor with
%% no fields makes every wire field unknown, so the codec skips each by
%% wire type — exactly the completeness probe we need.

-spec message_complete(binary()) -> complete | incomplete | invalid.
message_complete(<<>>) ->
    incomplete;
message_complete(Buffer) ->
    case thrift_erl_binary:decode_message(Buffer) of
        {ok, _Type, _Name, _SeqId, Tail} ->
            case thrift_erl_binary:decode({struct, {struct, []}}, Tail) of
                {ok, _Skipped, _Rest} -> complete;
                more -> incomplete;
                {error, _} -> invalid
            end;
        more ->
            incomplete;
        {error, _} ->
            invalid
    end.

%%--------------------------------------------------------------------
%% Listening
%%--------------------------------------------------------------------

-doc """
Listens with the standard socket options for the binary protocol
(binary, passive, raw) plus `backlog` from `Opts`.
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
