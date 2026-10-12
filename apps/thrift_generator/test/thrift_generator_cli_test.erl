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
    format_error_list_test/0,
    format_error_stale_test/0,
    diagnostic_excerpt_test/0,
    diagnostic_compact_fallback_test/0,
    diagnostic_join_test/0
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

%% The check gate's drift report: one indented path per line, so the
%% rebar3 plugin (which renders through this formatter) shows exactly
%% which artifacts to refresh.

format_error_stale_test() ->
    ?assertEqual(
        "generated sources are out of date (run the generator to refresh):\n"
        "  src/a_types.erl\n"
        "  src/a_types.hrl\n",
        lists:flatten(
            thrift_generator_cli:format_error({stale, ["src/a_types.erl", "src/a_types.hrl"]})
        )
    ),
    ok.

%% Located errors render as rebar3/elp-style excerpt blocks: the
%% offending line under a gutter, the marker under the construct's
%% first non-blank column. The block is asserted byte-exact — the box
%% glyphs ride in a `/utf8` binary literal, and a truncated literal
%% must not sneak back in.

diagnostic_excerpt_test() ->
    Source = <<"namespace erl d\n\nstruct P {\n  1: i64 x,\n  1: i64 y\n}\n">>,
    Rendered = thrift_generator_diagnostic:format(
        {parse, <<"p.thrift">>, {5, thrift_lexer, {illegal, "@"}}},
        fun(_Path) -> {ok, Source} end
    ),
    ?assertEqual(
        %% string literals, not a binary literal: the glyphs are
        %% codepoints here, and /utf8 segments do not concatenate
        unicode:characters_to_binary([
            "  ┌─ p.thrift:5:\n",
            "  │\n",
            "5 │   1: i64 y\n",
            "  │   ╰── illegal characters \"@\""
        ]),
        unicode:characters_to_binary(Rendered)
    ),
    ok.

%% Unreadable sources fall back to the compact path:line: message.

diagnostic_compact_fallback_test() ->
    Rendered = thrift_generator_diagnostic:format(
        {parse, <<"gone.thrift">>, {5, thrift_lexer, {illegal, "@"}}},
        fun(_Path) -> {error, enoent} end
    ),
    ?assertEqual(
        <<"gone.thrift:5: illegal characters \"@\"">>,
        unicode:characters_to_binary(Rendered)
    ),
    ok.

%% Compact entries join as one continuous report (the historical
%% single-newline shape); once an excerpt block is in the mix the
%% entries separate with a blank line.

diagnostic_join_test() ->
    Compact = thrift_generator_diagnostic:format(
        [{"a.thrift", 3, <<"bad">>}, {"b.thrift", 7, <<"worse">>}],
        fun(_Path) -> {error, enoent} end
    ),
    ?assertEqual(<<"a.thrift:3: bad\nb.thrift:7: worse">>, unicode:characters_to_binary(Compact)),
    Mixed = thrift_generator_diagnostic:format(
        [{"a.thrift", 3, <<"bad">>}, {"b.thrift", 7, <<"worse">>}],
        fun
            ("a.thrift") -> {ok, <<"x\ny\nbad line\n">>};
            (_Other) -> {error, enoent}
        end
    ),
    ?assertMatch(
        {_, _},
        binary:match(unicode:characters_to_binary(Mixed), <<"\n\nb.thrift:7: worse">>)
    ),
    ok.
