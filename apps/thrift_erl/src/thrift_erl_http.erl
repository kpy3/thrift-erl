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

-module(thrift_erl_http).

-moduledoc """
The bytes-level HTTP/1.1 subset the `http' transport needs.

A Thrift message rides as an HTTP request/response body: the client
wraps one encoded message in a POST per call, the server answers one
response per request, and the connection stays open for the next
exchange (HTTP/1.1 keep-alive). Only the pieces this codebase speaks
are implemented — `Content-Length' framing; no chunked transfer, no
header continuations, no trailer sections.

The parse side follows the streaming contract of the protocol codecs:
`more` while the bytes are a valid prefix, a tagged error once they
cannot become a valid exchange. Header names are compared
case-insensitively (stored lowercase); a header block is capped at
16 KiB, the body at the caller's size limit (`max_frame_size` plays
that role on both ends).
""".

-export([
    extract_request/2,
    request/4,
    extract_response/2,
    response/3
]).

-export_type([headers/0, request/0, response/0]).

-define(MAX_HEADER_SIZE, (16 * 1024)).
-define(CONTENT_TYPE, <<"application/x-thrift">>).

-type headers() :: [{binary(), binary()}].

-type request() :: #{
    method := binary(),
    path := binary(),
    headers := headers(),
    body := binary()
}.

-type response() :: {StatusCode :: 100..599, headers(), Body :: binary()}.

-doc """
Builds the client's POST for one message body.

`Host` is the `Host:' header value; `ExtraHeaders` land after the
built-in `Content-Type'.
""".
-spec request(binary(), binary(), headers(), iodata()) -> iodata().
request(Host, Path, ExtraHeaders, Body) ->
    head(<<"POST ">>, Path, <<" HTTP/1.1\r\n">>, ExtraHeaders, Body, [<<"Host: ">>, Host, <<"\r\n">>]).

-doc """
Builds a server response with the given status code.

`Content-Type' is `application/x-thrift'; `ExtraHeaders` land between
it and the built-in `Content-Length'.
""".
-spec response(100..599, headers(), iodata()) -> iodata().
response(Code, ExtraHeaders, Body) ->
    Status = [integer_to_binary(Code), <<" ">>, reason(Code), <<"\r\n">>],
    head(<<"HTTP/1.1 ">>, Status, <<>>, ExtraHeaders, Body, []).

-spec head(binary(), iodata(), iodata(), headers(), iodata(), iodata()) -> iodata().
head(Prefix, Target, LineEnd, ExtraHeaders, Body, ExtraBuiltIn) ->
    [
        Prefix,
        Target,
        LineEnd,
        ExtraBuiltIn,
        <<"Content-Type: ">>,
        ?CONTENT_TYPE,
        <<"\r\n">>,
        [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- ExtraHeaders],
        <<"Content-Length: ">>,
        integer_to_binary(iolist_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ].

-doc """
Splits one HTTP request off the front of `Buffer`.

Answers the parsed request with the bytes after it. Anything but POST
answers `{error, not_post}` — the HTTP server replies 405 to that; a
body longer than `MaxBodySize` is refused without waiting for it.
""".
-spec extract_request(binary(), MaxBodySize :: pos_integer()) ->
    {ok, request(), Leftover :: binary()} | more | {error, term()}.
extract_request(Buffer, MaxBody) ->
    %% The method is known from the first line: a non-POST is refused
    %% right away, without waiting for a body that will not come.
    case binary:split(Buffer, <<"\r\n">>) of
        [RequestLine, Rest] ->
            case request_line(RequestLine) of
                {ok, <<"POST">>, Path} ->
                    request_from_head(Path, Rest, Buffer, MaxBody);
                {ok, _OtherMethod, _Path} ->
                    {error, not_post};
                {error, _} = Error ->
                    Error
            end;
        [_] ->
            header_block_outcome(Buffer)
    end.

-spec request_from_head(binary(), binary(), binary(), pos_integer()) ->
    {ok, request(), binary()} | more | {error, term()}.
request_from_head(Path, Rest, Buffer, MaxBody) ->
    case read_head(Rest) of
        {ok, HeaderLines, AfterHead} ->
            case headers(HeaderLines) of
                {ok, ParsedHeaders} ->
                    body_from_headers(ParsedHeaders, AfterHead, MaxBody, fun(Body) ->
                        #{method => <<"POST">>, path => Path, headers => ParsedHeaders, body => Body}
                    end);
                {error, _} = Error ->
                    Error
            end;
        more ->
            header_block_outcome(Buffer)
    end.

-doc """
Splits one HTTP response off the front of `Buffer`.

Answers `{StatusCode, Headers, Body}' with the bytes after it.
""".
-spec extract_response(binary(), MaxBodySize :: pos_integer()) ->
    {ok, response(), Leftover :: binary()} | more | {error, term()}.
extract_response(Buffer, MaxBody) ->
    case binary:split(Buffer, <<"\r\n">>) of
        [StatusLine, Rest] ->
            response_from_head(StatusLine, Rest, Buffer, MaxBody);
        [_] ->
            header_block_outcome(Buffer)
    end.

-spec response_from_head(binary(), binary(), binary(), pos_integer()) ->
    {ok, response(), binary()} | more | {error, term()}.
response_from_head(StatusLine, Rest, Buffer, MaxBody) ->
    case status_line(StatusLine) of
        {ok, Code} ->
            response_from_status(Code, Rest, Buffer, MaxBody);
        {error, _} = Error ->
            Error
    end.

-spec response_from_status(100..599, binary(), binary(), pos_integer()) ->
    {ok, response(), binary()} | more | {error, term()}.
response_from_status(Code, Rest, Buffer, MaxBody) ->
    case read_head(Rest) of
        {ok, HeaderLines, AfterHead} ->
            case headers(HeaderLines) of
                {ok, ParsedHeaders} ->
                    body_from_headers(ParsedHeaders, AfterHead, MaxBody, fun(Body) ->
                        {Code, ParsedHeaders, Body}
                    end);
                {error, _} = Error ->
                    Error
            end;
        more ->
            header_block_outcome(Buffer)
    end.

%% The head (request/status line plus header lines up to the empty
%% line) is a list of complete lines; `more' while the empty line has
%% not arrived.

-spec read_head(binary()) -> {ok, [binary()], binary()} | more.
read_head(Bin) ->
    case binary:split(Bin, <<"\r\n">>) of
        [<<>>, Rest] ->
            {ok, [], Rest};
        [Line, Rest] ->
            case read_head(Rest) of
                {ok, Lines, Rest1} -> {ok, [Line | Lines], Rest1};
                more -> more
            end;
        [_] ->
            more
    end.

%% A head that is still incomplete is `more' until the 16 KiB cap says
%% no bytes could ever make it valid.

-spec header_block_outcome(binary()) -> more | {error, headers_too_large}.
header_block_outcome(Buffer) ->
    case byte_size(Buffer) >= ?MAX_HEADER_SIZE of
        true -> {error, headers_too_large};
        false -> more
    end.

-spec request_line(binary()) -> {ok, binary(), binary()} | {error, bad_request}.
request_line(Line) ->
    case binary:split(Line, <<" ">>) of
        [Method, Rest] ->
            case binary:split(Rest, <<" ">>) of
                [Path, Version] when Version =:= <<"HTTP/1.1">>; Version =:= <<"HTTP/1.0">> ->
                    {ok, Method, Path};
                _ ->
                    {error, bad_request}
            end;
        _ ->
            {error, bad_request}
    end.

-spec status_line(binary()) -> {ok, 100..599} | {error, bad_response}.
status_line(Line) ->
    case binary:split(Line, <<" ">>) of
        [Version, Rest] when Version =:= <<"HTTP/1.1">>; Version =:= <<"HTTP/1.0">> ->
            case binary:split(Rest, <<" ">>) of
                [CodeBin, _Reason] when byte_size(CodeBin) =:= 3 ->
                    try
                        {ok, binary_to_integer(CodeBin)}
                    catch
                        _:_ -> {error, bad_response}
                    end;
                _ ->
                    {error, bad_response}
            end;
        _ ->
            {error, bad_response}
    end.

-spec headers([binary()]) -> {ok, headers()} | {error, bad_request}.
headers(Lines) ->
    headers(Lines, []).

-spec headers([binary()], headers()) -> {ok, headers()} | {error, bad_request}.
headers([], Acc) ->
    {ok, lists:reverse(Acc)};
headers([Line | Rest], Acc) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            headers(Rest, [{lower(string:trim(Name)), string:trim(Value)} | Acc]);
        _ ->
            {error, bad_request}
    end.

%% The body carries `Content-Length' bytes after the head; the wrap
%% builds the caller's result from it.

-spec body_from_headers(headers(), binary(), pos_integer(), fun((binary()) -> term())) ->
    {ok, term(), binary()} | more | {error, term()}.
body_from_headers(Headers, Rest, MaxBody, Wrap) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Value} ->
            case parse_length(Value) of
                {ok, Length} ->
                    take_body(Length, Rest, MaxBody, Wrap);
                error ->
                    {error, bad_request}
            end;
        false ->
            {error, no_content_length}
    end.

-spec take_body(non_neg_integer(), binary(), pos_integer(), fun((binary()) -> term())) ->
    {ok, term(), binary()} | more | {error, term()}.
take_body(Length, Rest, MaxBody, Wrap) when Length =< MaxBody ->
    case Rest of
        <<Body:Length/binary, Leftover/binary>> ->
            {ok, Wrap(Body), Leftover};
        _ ->
            more
    end;
take_body(_Length, _Rest, _MaxBody, _Wrap) ->
    {error, body_too_large}.

-spec parse_length(binary()) -> {ok, non_neg_integer()} | error.
parse_length(Value) ->
    try
        Length = binary_to_integer(Value),
        case Length >= 0 of
            true -> {ok, Length};
            false -> error
        end
    catch
        _:_ -> error
    end.

-spec reason(100..599) -> binary().
reason(200) -> <<"OK">>;
reason(400) -> <<"Bad Request">>;
reason(405) -> <<"Method Not Allowed">>;
reason(500) -> <<"Internal Server Error">>;
reason(_) -> <<>>.

%% Handwritten on purpose: header names are ASCII, and string:lowercase/1 rejects bytes outside valid UTF-8.
-spec lower(binary()) -> binary().
lower(Bin) ->
    <<
        <<
            (if
                C >= $A andalso C =< $Z -> C + 32;
                true -> C
            end)
        >>
     || <<C>> <= Bin
    >>.
