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

%% Loopback coverage of the TLS path: a real server on an ephemeral
%% port with ssl_opts, a real client verifying the server (verify_peer
%% against generated cacerts), both transports, plus the mixed-up
%% cases — a plain client against a TLS server and a TLS client
%% against a plain server.
%%
%% Certificates are generated per run with public_key:pkix_test_data/1
%% (8-day validity by construction, so nothing is committed); the SAN
%% dNSName "localhost" makes the hostname check a real check.

-module(thrift_ssl_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    tls_framed_calls/1,
    tls_buffered_calls/1,
    tls_declared_exception/1,
    tls_many_sequential_calls/1,
    tls_peer_close_fails_pending_call/1,
    tls_peer_close_stops_connection/1,
    plain_client_to_tls_server/1,
    tls_client_to_plain_server/1
]).

all() ->
    [
        tls_framed_calls,
        tls_buffered_calls,
        tls_declared_exception,
        tls_many_sequential_calls,
        tls_peer_close_fails_pending_call,
        tls_peer_close_stops_connection,
        plain_client_to_tls_server,
        tls_client_to_plain_server
    ].

init_per_suite(Config) ->
    [{certs, make_certs()} | Config].

end_per_suite(_Config) ->
    ok.

-define(SERVICE, thrift_erl_test_service).
-define(HANDLER, thrift_erl_test_handler).

%%--------------------------------------------------------------------

tls_framed_calls(Config) ->
    with_tls(framed, Config, fun(Client) ->
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ?assertEqual({ok, <<"hello">>}, call(Client, <<"echo">>, [<<"hello">>]))
    end).

tls_buffered_calls(Config) ->
    with_tls(buffered, Config, fun(Client) ->
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ?assertEqual(
            {ok, #{<<"x">> => 9, <<"y">> => 8}}, call(Client, <<"deep">>, [#{<<"x">> => 8, <<"y">> => 9}])
        )
    end).

tls_declared_exception(Config) ->
    with_tls(framed, Config, fun(Client) ->
        ?assertEqual(
            {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}},
            call(Client, <<"boom">>, [])
        ),
        %% The connection stays usable after an exception reply.
        ?assertEqual({ok, 1}, call(Client, <<"add">>, [1, 0]))
    end).

tls_many_sequential_calls(Config) ->
    with_tls(framed, Config, fun(Client) ->
        Results = [call(Client, <<"add">>, [N, N]) || N <- lists:seq(1, 50)],
        ?assertEqual([{ok, N * 2} || N <- lists:seq(1, 50)], Results)
    end).

%% The test plays the server over a raw TLS socket, so the close is
%% deterministic: an orderly ssl:close must reach the client as
%% {ssl_closed, Socket} — the pending call fails with {error, closed},
%% not by its own per-call timeout.

tls_peer_close_fails_pending_call(Config) ->
    #{server_opts := ServerSslOpts, client_opts := ClientSslOpts} = certs(Config),
    {ok, Listen} =
        ssl:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true} | ServerSslOpts]),
    {ok, {_Addr, Port}} = ssl:sockname(Listen),
    Parent = self(),
    Peer =
        spawn(fun() ->
            {ok, S} = ssl:transport_accept(Listen, 5000),
            {ok, Handshaken} = ssl:handshake(S, 5000),
            %% hand the socket over: this helper exits right after
            %% signaling, and the socket would close with it
            ok = ssl:controlling_process(Handshaken, Parent),
            Parent ! {peer, Handshaken}
        end),
    {ok, Client} =
        thrift_erl_client:start_link(#{
            host => "localhost",
            port => Port,
            service => ?SERVICE,
            transport => framed,
            ssl_opts => ClientSslOpts,
            timeout => 5000
        }),
    try
        Sock =
            receive
                {peer, S} -> S
            after 5000 ->
                erlang:error(no_peer)
            end,
        Caller = self(),
        spawn(fun() ->
            Caller ! {res, thrift_erl_client:call(Client, <<"add">>, [2, 3], 4000)}
        end),
        %% the request is on the wire before the peer closes
        {ok, _Request} = ssl:recv(Sock, 0, 2000),
        ok = ssl:close(Sock),
        Result =
            receive
                {res, R} -> R
            after 5000 ->
                erlang:error(pending_not_answered)
            end,
        ?assertEqual({error, closed}, Result)
    after
        stop_client_quietly(Client),
        Peer ! close,
        ssl:close(Listen)
    end.

%% A connection process handed a socket directly: the test plays the
%% peer, so the orderly close is deterministic — the connection must
%% see {ssl_closed, Socket} and stop instead of lingering until the
%% idle timer.

tls_peer_close_stops_connection(Config) ->
    #{server_opts := ServerSslOpts, client_opts := ClientSslOpts} = certs(Config),
    {ok, Listen} =
        ssl:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true} | ServerSslOpts]),
    {ok, {_Addr, Port}} = ssl:sockname(Listen),
    Parent = self(),
    Peer =
        spawn(fun() ->
            {ok, S} = ssl:transport_accept(Listen, 5000),
            {ok, Handshaken} = ssl:handshake(S, 5000),
            %% hand the socket over: this helper exits right after
            %% signaling, and the socket would close with it
            ok = ssl:controlling_process(Handshaken, Parent),
            Parent ! {peer, Handshaken}
        end),
    {ok, TestSock} =
        ssl:connect(
            "localhost", Port, [binary, {packet, raw}, {active, false} | ClientSslOpts], 5000
        ),
    Sock =
        receive
            {peer, S} -> S
        after 5000 ->
            erlang:error(no_peer)
        end,
    {ok, Conn} =
        thrift_erl_connection:start(#{
            socket => {ssl, Sock},
            handler => ?HANDLER,
            service => ?SERVICE,
            timeout => 30000
        }),
    ok = thrift_erl_socket:controlling_process({ssl, Sock}, Conn),
    Conn ! go,
    timer:sleep(50),
    try
        Monitor = monitor(process, Conn),
        ok = ssl:close(TestSock),
        receive
            {'DOWN', Monitor, process, Conn, normal} -> ok
        after 3000 ->
            erlang:error(connection_lingering)
        end
    after
        stop_connection_quietly(Conn),
        Peer ! close,
        ssl:close(Listen)
    end.

%% A plain TCP client reaches a TLS server at the TCP level, but its
%% first bytes are not a TLS handshake: the server drops the
%% connection and stays healthy for real TLS clients.

plain_client_to_tls_server(Config) ->
    #{server_opts := ServerSslOpts, client_opts := ClientSslOpts} = certs(Config),
    ServerOpts =
        #{
            port => 0,
            handler => ?HANDLER,
            service => ?SERVICE,
            transport => framed,
            ssl_opts => ServerSslOpts
        },
    {ok, Server} = thrift_erl_server:start_link(ServerOpts),
    try
        {ok, Port} = thrift_erl_server:port(Server),
        ClientOpts = #{host => "localhost", port => Port, service => ?SERVICE, transport => framed},
        {ok, Client} = thrift_erl_client:start_link(ClientOpts),
        try
            ?assertMatch({error, _}, call(Client, <<"add">>, [2, 3]))
        after
            %% The failed call stops the client (its design); the
            %% teardown races its death on loaded runners.
            stop_client_quietly(Client)
        end,
        %% The server is still there and still speaks TLS.
        {ok, TlsClient} = thrift_erl_client:start_link(
            ClientOpts#{ssl_opts => ClientSslOpts}
        ),
        try
            ?assertEqual({ok, 5}, call(TlsClient, <<"add">>, [2, 3]))
        after
            thrift_erl_client:stop(TlsClient)
        end
    after
        thrift_erl_server:stop(Server)
    end.

%% A TLS client against a plain server fails at the handshake, inside
%% the client start — nothing to stop afterwards.

tls_client_to_plain_server(Config) ->
    #{client_opts := ClientSslOpts} = certs(Config),
    {ok, Server} =
        thrift_erl_server:start_link(#{port => 0, handler => ?HANDLER, service => ?SERVICE}),
    try
        {ok, Port} = thrift_erl_server:port(Server),
        ?assertMatch(
            {error, _},
            thrift_erl_client:start_link(#{
                host => "localhost",
                port => Port,
                service => ?SERVICE,
                ssl_opts => ClientSslOpts
            })
        )
    after
        thrift_erl_server:stop(Server)
    end.

%%--------------------------------------------------------------------
%% Helpers

call(Client, Function, Args) ->
    thrift_erl_client:call(Client, Function, Args, 5000).

%% The client may already have stopped itself (a peer close aborts it);
%% a quiet stop keeps the teardown from failing the case.

stop_client_quietly(Client) ->
    try thrift_erl_client:stop(Client) of
        _ -> ok
    catch
        _:_ -> ok
    end.

stop_connection_quietly(Conn) ->
    try thrift_erl_connection:stop(Conn) of
        _ -> ok
    catch
        _:_ -> ok
    end.

certs(Config) ->
    #{server_cert := ServerCert, server_key := ServerKey, cacerts := CACerts} =
        proplists:get_value(certs, Config),
    #{
        server_opts => [
            {certs_keys, [#{cert => [ServerCert], key => ServerKey}]},
            {verify, verify_none}
        ],
        client_opts => [
            {verify, verify_peer},
            {cacerts, CACerts},
            {server_name_indication, "localhost"}
        ]
    }.

-spec with_tls(framed | buffered, proplists:proplist(), fun((pid()) -> term())) -> term().
with_tls(Transport, Config, Test) ->
    #{server_opts := ServerSslOpts, client_opts := ClientSslOpts} = certs(Config),
    ServerOpts =
        #{
            port => 0,
            handler => ?HANDLER,
            service => ?SERVICE,
            transport => Transport,
            ssl_opts => ServerSslOpts
        },
    {ok, Server} = thrift_erl_server:start_link(ServerOpts),
    try
        {ok, Port} = thrift_erl_server:port(Server),
        {ok, Client} = thrift_erl_client:start_link(#{
            host => "localhost",
            port => Port,
            service => ?SERVICE,
            transport => Transport,
            ssl_opts => ClientSslOpts
        }),
        try
            Test(Client)
        after
            thrift_erl_client:stop(Client)
        end
    after
        thrift_erl_server:stop(Server)
    end.

%% One CA signing one server certificate with SAN localhost; returns
%% DER binaries plus the key record ssl consumes in certs_keys.

make_certs() ->
    %% {digest, sha256}: the pkix_test_data default signature is SHA-1,
    %% which no TLS 1.2/1.3 client offers to accept — the server would
    %% answer the hello with a handshake_failure alert.
    [{cert, ServerCert}, {key, ServerKey}, {cacerts, CACerts}] =
        public_key:pkix_test_data(#{
            root => [{digest, sha256}],
            intermediates => [],
            peer => [
                {key, {rsa, 2048, 65537}},
                {digest, sha256},
                {extensions, [
                    #'Extension'{
                        extnID = ?'id-ce-subjectAltName',
                        critical = false,
                        extnValue = [{dNSName, "localhost"}]
                    }
                ]}
            ]
        }),
    #{server_cert => ServerCert, server_key => ServerKey, cacerts => CACerts}.
