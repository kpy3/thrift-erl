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

%% The one options contract shared by every generator frontend — the
%% library (`generate/1,2', `check/1,2'), the standalone CLI and the
%% rebar3 plugin all validate through normalize/1 and receive the same
%% fully-defaulted map, so no frontend reimplements validation.

-module(thrift_generator_options).

-moduledoc """
Strict normalizer for the generator options map.

`normalize/1` accepts only the known keys — `out_dir`, `repr`,
`union_type`, `set`, `typedef_type` and `enum_case` — fills every
missing key with its default and returns the complete map. Anything
else is an error, reported deterministically (keys are checked in
sorted order, so the reported error is always the first one):

- a non-map argument is `{error, {bad_option, {options, Value, [map]}}}`;
- an unknown key is `{error, {unknown_option, Key}}`;
- a bad value is `{error, {bad_option, {Key, Value, Allowed}}}`.
""".

-export([normalize/1]).

-spec normalize(term()) ->
    {ok, thrift_generator:generate_opts()}
    | {error, {unknown_option, atom()} | {bad_option, {atom(), term(), [atom()]}}}.
normalize(Options) when is_map(Options) ->
    case first_error(lists:sort(maps:keys(Options)), Options) of
        ok -> {ok, maps:merge(defaults(), Options)};
        {error, _} = Error -> Error
    end;
normalize(Options) ->
    {error, {bad_option, {options, Options, [map]}}}.

%% Allowed values and defaults for every key; `out_dir' is the only
%% non-enum key: it takes any valid filename chardata (a flat or deep
%% string list, or a binary).

-spec axes() -> #{atom() => {[atom()], term()}}.
axes() ->
    #{
        out_dir => {[string, binary], "src"},
        repr => {[record, map, native], record},
        union_type => {[record, sum], record},
        set => {[list, sets, ordset], list},
        typedef_type => {[alias, nominal], alias},
        enum_case => {[preserve, lower], preserve}
    }.

-spec defaults() -> thrift_generator:generate_opts().
defaults() ->
    maps:map(fun(_Key, {_Allowed, Default}) -> Default end, axes()).

first_error([Key | Rest], Options) ->
    case error_for(Key, maps:get(Key, Options)) of
        ok -> first_error(Rest, Options);
        {error, _} = Error -> Error
    end;
first_error([], _Options) ->
    ok.

error_for(Key, Value) ->
    case maps:get(Key, axes(), unknown) of
        unknown ->
            {error, {unknown_option, Key}};
        {Allowed, _Default} ->
            case valid_value(Key, Value) of
                true -> ok;
                false -> {error, {bad_option, {Key, Value, Allowed}}}
            end
    end.

-spec valid_value(atom(), term()) -> boolean().
valid_value(out_dir, Value) ->
    is_binary(Value) orelse (is_list(Value) andalso io_lib:deep_char_list(Value));
valid_value(Key, Value) when is_atom(Value) ->
    {Allowed, _Default} = maps:get(Key, axes()),
    lists:member(Value, Allowed);
valid_value(_Key, _Value) ->
    false.
