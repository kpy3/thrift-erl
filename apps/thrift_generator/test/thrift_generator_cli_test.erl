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

-module(thrift_generator_cli_test).

-moduledoc "Unit tests for the CLI error formatting (`main/1' itself halts\n"
"the emulator; argument parsing rides on the stdlib `argparse' module).".

-include_lib("stdlib/include/assert.hrl").

-export([
    format_error_test/0,
    format_error_list_test/0
]).

%% Lexer/parser errors format through the originating module's own
%% formatter, with the file and line prefixed.

format_error_test() ->
    ?assertEqual(
        "p.thrift:966: illegal characters \"#\"",
        lists:flatten(
            thrift_generator_cli:format_error({parse, "p.thrift", {966, thrift_lexer, {illegal, "#"}}})
        )
    ),
    ?assertEqual(
        "include cycle involving p.thrift",
        lists:flatten(thrift_generator_cli:format_error({cycle, "p.thrift"}))
    ),
    ?assertEqual(
        "module m declared twice: a.thrift and b.thrift",
        lists:flatten(
            thrift_generator_cli:format_error({duplicate_module, <<"m">>, "a.thrift", "b.thrift"})
        )
    ),
    ?assertEqual(
        "cannot write p.erl: eacces",
        lists:flatten(thrift_generator_cli:format_error({write_error, "p.erl", eacces}))
    ),
    ok.

%% Semantic errors arrive as a list of {File, Line, Message} — one
%% rendered line each, joined with newlines in order.

format_error_list_test() ->
    ?assertEqual(
        "a.thrift:3: bad thing\nb.thrift:7: worse thing",
        lists:flatten(
            thrift_generator_cli:format_error([
                {"a.thrift", 3, "bad thing"},
                {"b.thrift", 7, "worse thing"}
            ])
        )
    ),
    ok.
