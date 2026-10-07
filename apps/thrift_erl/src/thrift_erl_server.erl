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

-module(thrift_erl_server).

-moduledoc """
Supervision root of a Thrift server: one acceptor, restartable.

`start_link(Opts)` takes the same map as `thrift_erl_acceptor` (plus an
optional `name`); the acceptor is a permanent child, so a crashing
listener comes back. All configuration is given here at creation time.

Example:

```
{ok, Server} = thrift_erl_server:start_link(#{port => 0, handler => my_handler, service => my_service}),
{ok, Port} = thrift_erl_server:port(Server).
```
""".

-behaviour(supervisor).

-export([start_link/1, stop/1, port/1]).

-export([init/1]).

-export_type([options/0]).

-type options() :: thrift_erl_acceptor:options().
-doc "Starts the server supervision tree.".
-spec start_link(options()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) ->
    Name = maps:get(name, Opts, ?MODULE),
    supervisor:start_link({local, Name}, ?MODULE, Opts).

-doc "Stops the server: the acceptor and, through it, all connections.".
-spec stop(pid() | atom()) -> ok.
stop(Server) ->
    supervisor:stop(Server).

-doc "Returns the bound port (useful with `port = 0`).".
-spec port(pid() | atom()) -> {ok, inet:port_number()}.
port(Server) ->
    Acceptor = whereis_acceptor(Server),
    thrift_erl_acceptor:port(Acceptor).

-doc false.
-spec init(options()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Opts) ->
    Children = [
        #{
            id => acceptor,
            start => {thrift_erl_acceptor, start_link, [maps:remove(name, Opts)]},
            restart => permanent,
            shutdown => 5000,
            type => worker
        }
    ],
    {ok, {#{strategy => one_for_all, intensity => 5, period => 10}, Children}}.

-spec whereis_acceptor(pid() | atom()) -> pid().
whereis_acceptor(Server) ->
    [Acceptor] = [
        Pid
     || {_, Pid, worker, [thrift_erl_acceptor]} <- supervisor:which_children(Server)
    ],
    Acceptor.
