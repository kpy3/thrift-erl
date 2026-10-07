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

%% Loopback coverage of the runtime: a real server on an ephemeral
%% port, a real client over TCP, both transports (framed and buffered),
%% every reply shape (value, void, declared exception, application
%% exception) and one-way delivery.

-module(thrift_erl_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    framed_calls/1,
    buffered_calls/1,
    declared_exception/1,
    application_exception/1,
    oneway_delivery/1,
    many_sequential_calls/1,
    unknown_function_is_local_error/1
]).

all() ->
    [
        framed_calls,
        buffered_calls,
        declared_exception,
        application_exception,
        oneway_delivery,
        many_sequential_calls,
        unknown_function_is_local_error
    ].

-define(SERVICE, thrift_erl_test_service).
-define(HANDLER, thrift_erl_test_handler).

%%--------------------------------------------------------------------

framed_calls(_Config) ->
    with_server(#{transport => framed}, fun(Client) ->
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ?assertEqual({ok, <<"hello">>}, call(Client, <<"echo">>, [<<"hello">>])),
        ?assertEqual({ok, 3}, call(Client, <<"size">>, [[<<"a">>, <<"b">>, <<"c">>]])),
        ?assertEqual({ok, undefined}, call(Client, <<"ping">>, [])),
        ?assertEqual(
            {ok, #{<<"x">> => 2, <<"y">> => 1}}, call(Client, <<"deep">>, [#{<<"x">> => 1, <<"y">> => 2}])
        )
    end).

buffered_calls(_Config) ->
    with_server(#{transport => buffered}, fun(Client) ->
        ?assertEqual({ok, 5}, call(Client, <<"add">>, [2, 3])),
        ?assertEqual(
            {ok, #{<<"x">> => 9, <<"y">> => 8}}, call(Client, <<"deep">>, [#{<<"x">> => 8, <<"y">> => 9}])
        )
    end).

declared_exception(_Config) ->
    with_server(#{}, fun(Client) ->
        ?assertEqual(
            {error, {exception, <<"boom">>, #{<<"message">> => <<"as declared">>}}},
            call(Client, <<"boom">>, [])
        ),
        %% The connection stays usable after an exception reply.
        ?assertEqual({ok, 1}, call(Client, <<"add">>, [1, 0]))
    end).

application_exception(_Config) ->
    with_server(#{}, fun(Client) ->
        ?assertMatch(
            {error, {application_exception, <<"internal error">>, 6, <<"INTERNAL_ERROR">>}},
            call(Client, <<"boomInternal">>, [])
        )
    end).

oneway_delivery(_Config) ->
    with_server(#{}, fun(Client) ->
        true = register(thrift_erl_test_sink, self()),
        try
            ok = thrift_erl_client:oneway(Client, <<"notify">>, [<<"fire">>], 5000),
            receive
                {notified, <<"fire">>} ->
                    ok
            after 2000 ->
                erlang:error(oneway_not_delivered)
            end
        after
            unregister(thrift_erl_test_sink)
        end
    end).

many_sequential_calls(_Config) ->
    with_server(#{}, fun(Client) ->
        Results = [call(Client, <<"add">>, [N, N]) || N <- lists:seq(1, 50)],
        ?assertEqual([{ok, N * 2} || N <- lists:seq(1, 50)], Results)
    end).

unknown_function_is_local_error(_Config) ->
    with_server(#{}, fun(Client) ->
        ?assertEqual({error, unknown_function}, call(Client, <<"nope">>, []))
    end).

%%--------------------------------------------------------------------
%% Helpers

call(Client, Function, Args) ->
    thrift_erl_client:call(Client, Function, Args, 5000).

-spec with_server(map(), fun((pid()) -> term())) -> term().
with_server(Overrides, Test) ->
    Base = #{
        port => 0,
        handler => ?HANDLER,
        service => ?SERVICE
    },
    ServerOpts = maps:merge(Base, Overrides),
    {ok, Server} = thrift_erl_server:start_link(ServerOpts),
    try
        {ok, Port} = thrift_erl_server:port(Server),
        ClientOpts = maps:merge(Base#{host => "127.0.0.1", port => Port}, Overrides),
        {ok, Client} = thrift_erl_client:start_link(ClientOpts),
        try
            Test(Client)
        after
            thrift_erl_client:stop(Client)
        end
    after
        thrift_erl_server:stop(Server)
    end.
