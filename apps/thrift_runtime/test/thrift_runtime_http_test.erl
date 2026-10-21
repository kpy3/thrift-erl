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

%% Unit tests for the HTTP framing: request and response round-trips
%% with known bytes, case-insensitive headers, keep-alive leftovers,
%% `more` on every truncation, and the error cases the connection maps
%% to status codes.

-module(thrift_runtime_http_test).

-include_lib("stdlib/include/assert.hrl").

-export([
    request_roundtrip_test/0,
    response_roundtrip_test/0,
    truncation_test/0,
    keep_alive_test/0,
    request_errors_test/0,
    response_errors_test/0
]).

%%--------------------------------------------------------------------
%% Requests: known bytes, header case, body round-trip

request_roundtrip_test() ->
    ?assertEqual(
        <<
            "POST /thrift/test HTTP/1.1\r\n"
            "Host: 127.0.0.1:9090\r\n"
            "Content-Type: application/x-thrift\r\n"
            "Content-Length: 5\r\n\r\n"
            "hello"
        >>,
        iolist_to_binary(thrift_runtime_http:request(<<"127.0.0.1:9090">>, <<"/thrift/test">>, [], <<"hello">>))
    ),
    {ok, Request, <<>>} = extract_request(thrift_runtime_http:request(<<"h:1">>, <<"/">>, [], <<"body">>)),
    ?assertEqual(<<"POST">>, maps:get(method, Request)),
    ?assertEqual(<<"/">>, maps:get(path, Request)),
    ?assertEqual(<<"body">>, maps:get(body, Request)),
    Headers = maps:get(headers, Request),
    ?assertEqual(<<"h:1">>, proplists:get_value(<<"host">>, Headers)),
    ?assertEqual(
        <<"application/x-thrift">>, proplists:get_value(<<"content-type">>, Headers)
    ),
    %% extra headers ride between the built-ins
    {ok, WithExtra, <<>>} =
        extract_request(thrift_runtime_http:request(<<"h">>, <<"/">>, [{<<"X-Trace">>, <<"abc">>}], <<>>)),
    ?assertEqual(<<"abc">>, proplists:get_value(<<"x-trace">>, maps:get(headers, WithExtra))),
    %% header names parse case-insensitively, values keep their case
    Mixed = <<"POST / HTTP/1.1\r\nCoNtEnT-lEnGtH: 4\r\n\r\nBODY">>,
    {ok, MixedReq, <<>>} = extract_request(Mixed),
    ?assertEqual(<<"BODY">>, maps:get(body, MixedReq)),
    %% HTTP/1.0 requests work too
    {ok, _, <<>>} = extract_request(<<"POST / HTTP/1.0\r\nContent-Length: 0\r\n\r\n">>),
    ok.

%%--------------------------------------------------------------------
%% Responses: known bytes, status codes

response_roundtrip_test() ->
    ?assertEqual(
        <<
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/x-thrift\r\n"
            "Content-Length: 2\r\n\r\n"
            "ok"
        >>,
        iolist_to_binary(thrift_runtime_http:response(200, [], <<"ok">>))
    ),
    {ok, {200, Headers, <<"ok">>}, <<>>} =
        extract_response(thrift_runtime_http:response(200, [], <<"ok">>)),
    ?assertEqual(
        <<"application/x-thrift">>, proplists:get_value(<<"content-type">>, Headers)
    ),
    %% other status codes round-trip
    {ok, {405, _, <<>>}, <<>>} = extract_response(thrift_runtime_http:response(405, [], <<>>)),
    ok.

%%--------------------------------------------------------------------
%% Every truncation of a valid exchange is `more`, never garbage

truncation_test() ->
    Request = iolist_to_binary(thrift_runtime_http:request(<<"h">>, <<"/">>, [], <<"0123456789">>)),
    RequestPrefixes = [binary:part(Request, 0, N) || N <- lists:seq(1, byte_size(Request) - 1)],
    ?assert(
        lists:all(fun(P) -> more =:= thrift_runtime_http:extract_request(P, 100) end, RequestPrefixes)
    ),
    Response = iolist_to_binary(thrift_runtime_http:response(200, [], <<"0123456789">>)),
    ResponsePrefixes = [binary:part(Response, 0, N) || N <- lists:seq(1, byte_size(Response) - 1)],
    ?assert(
        lists:all(fun(P) -> more =:= thrift_runtime_http:extract_response(P, 100) end, ResponsePrefixes)
    ),
    ok.

%%--------------------------------------------------------------------
%% Keep-alive: the leftover carries the next exchange whole

keep_alive_test() ->
    First = iolist_to_binary(thrift_runtime_http:request(<<"h">>, <<"/a">>, [], <<"one">>)),
    Second = iolist_to_binary(thrift_runtime_http:response(200, [], <<"two">>)),
    {ok, Req, Rest} = extract_request(<<First/binary, Second/binary>>),
    ?assertEqual(<<"one">>, maps:get(body, Req)),
    {ok, {200, _, <<"two">>}, <<>>} = extract_response(Rest),
    ok.

%%--------------------------------------------------------------------
%% Request errors: the connection answers 400, not_post gets 405

request_errors_test() ->
    %% non-POST methods are refused (before any body expectations)
    ?assertEqual({error, not_post}, thrift_runtime_http:extract_request(<<"GET /x HTTP/1.1\r\n">>, 100)),
    %% a missing Content-Length cannot frame a body
    ?assertEqual(
        {error, no_content_length},
        thrift_runtime_http:extract_request(<<"POST / HTTP/1.1\r\nHost: h\r\n\r\n">>, 100)
    ),
    %% a non-numeric or negative length is a bad request
    ?assertEqual(
        {error, bad_request},
        thrift_runtime_http:extract_request(<<"POST / HTTP/1.1\r\nContent-Length: x\r\n\r\n">>, 100)
    ),
    ?assertEqual(
        {error, bad_request},
        thrift_runtime_http:extract_request(<<"POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n">>, 100)
    ),
    %% a header line without a colon
    ?assertEqual(
        {error, bad_request},
        thrift_runtime_http:extract_request(<<"POST / HTTP/1.1\r\nnocolon\r\n\r\n">>, 100)
    ),
    %% a bad version
    ?assertEqual(
        {error, bad_request}, thrift_runtime_http:extract_request(<<"POST / HTTP/2\r\n\r\n">>, 100)
    ),
    %% a body beyond the limit is refused without waiting for it
    Big = <<"POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort">>,
    ?assertEqual({error, body_too_large}, thrift_runtime_http:extract_request(Big, 50)),
    %% an endless header block hits the 16 KiB cap
    Junk = binary:copy(<<"X-Junk: y\r\n">>, 2000),
    ?assertEqual(
        {error, headers_too_large}, thrift_runtime_http:extract_request(<<"POST / HTTP/1.1\r\n", Junk/binary>>, 100)
    ),
    ok.

%%--------------------------------------------------------------------
%% Response errors

response_errors_test() ->
    ?assertEqual(
        {error, bad_response}, thrift_runtime_http:extract_response(<<"HTTP/2 200 OK\r\n\r\n">>, 100)
    ),
    ?assertEqual(
        {error, no_content_length},
        thrift_runtime_http:extract_response(<<"HTTP/1.1 200 OK\r\n\r\n">>, 100)
    ),
    ?assertEqual(
        {error, body_too_large},
        thrift_runtime_http:extract_response(<<"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nxx">>, 5)
    ),
    ok.

%%--------------------------------------------------------------------
%% Helpers

-spec extract_request(iodata()) ->
    {ok, thrift_runtime_http:request(), binary()} | more | {error, term()}.
extract_request(Bin) ->
    thrift_runtime_http:extract_request(iolist_to_binary(Bin), 100).

-spec extract_response(iodata()) ->
    {ok, thrift_runtime_http:response(), binary()} | more | {error, term()}.
extract_response(Bin) ->
    thrift_runtime_http:extract_response(iolist_to_binary(Bin), 100).
