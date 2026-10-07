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

-module(rebar3_thrift).

-moduledoc """
rebar3 provider that runs the thrift_generator over IDL files declared
in the consumer's `rebar.config`:

```erlang
{thrift, [
    {files, ["src/my_api.thrift"]},  %% required, one or more IDL files
    {out_dir, "src"}                 %% optional, default "src"
]}
```

`rebar3 thrift` regenerates the Erlang sources for every file. To run
it before every compilation, hook it in the consumer's `rebar.config`:

```erlang
{provider_hooks, [{pre, [{compile, {default, thrift}}]}]}.
```
""".

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, thrift).
-define(DEPS, [app_discovery]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider =
        providers:create([
            {name, ?PROVIDER},
            {module, ?MODULE},
            {bare, true},
            {deps, ?DEPS},
            {example, "rebar3 thrift"},
            {opts, []},
            {short_desc, "Generate Erlang code from Thrift IDL files"},
            {desc,
                "Runs thrift_generator over the IDL files listed in "
                "the {thrift, [...]} section of rebar.config."}
        ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, {string(), term()}}.
do(State) ->
    Opts = rebar_state:get(State, thrift, []),
    Files = proplists:get_value(files, Opts, []),
    OutDir = proplists:get_value(out_dir, Opts, "src"),
    case Files of
        [] ->
            rebar_api:warn("~ts is configured but no thrift files are listed", [?PROVIDER]),
            {ok, State};
        _ ->
            try
                lists:foreach(fun(File) -> generate(File, OutDir) end, Files),
                {ok, State}
            catch
                throw:{thrift_error, Reason} -> {error, {?PROVIDER, Reason}}
            end
    end.

-spec generate(file:filename_all(), file:filename_all()) -> ok.
generate(File, OutDir) ->
    case thrift_generator:generate(File, OutDir, #{}) of
        {ok, Generated} ->
            rebar_api:info("~ts: generated ~b module(s) in ~ts", [
                File, length(Generated), OutDir
            ]),
            ok;
        {error, Reason} ->
            rebar_api:debug("~ts: generation failed", [File]),
            throw({thrift_error, Reason})
    end.

-spec format_error({thrift, term()}) -> string().
format_error({?PROVIDER, Reason}) ->
    %% Renders through the CLI's formatter so the console shows the
    %% same diagnostics the standalone tool prints.
    unicode:characters_to_list(
        lists:flatten(thrift_generator_cli:format_error(Reason))
    );
format_error(Reason) ->
    io_lib:format("~0p", [Reason]).
