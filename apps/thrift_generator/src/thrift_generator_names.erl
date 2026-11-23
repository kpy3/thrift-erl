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

-module(thrift_generator_names).

-moduledoc """
Identifier derivation shared by the semantic checks and the emitters.

IDL names surface in generated Erlang unchanged where the wire sees
them (struct_info keys, enum atoms, field-name binaries); every
*derived* identifier — record tags, type aliases, helper function
names, constant macros — goes through `snake/1`, so an IDL
`InvoiceBankAccount` becomes the readable `invoice_bank_account`
instead of the lowercased mush `invoicebankaccount`.

The module-level names live here too: `sanitize/1` and
`types_module_atom/1` derive the generated module names, `typed_prefix/2`
joins the namespace prefix with a definition name, and `current_prefix/1`
reads the prefix of the module under generation.
""".

-export([snake/1, sanitize/1, types_module_atom/1, typed_prefix/2, current_prefix/1]).

-include("thrift_generator_model.hrl").

-doc "Lowers a CamelCase/Snake/mixed identifier to snake_case.".
-spec snake(binary()) -> binary().
snake(Name) ->
    snake(unicode:characters_to_list(Name), <<>>, none).

-spec snake(string(), binary(), none | char()) -> binary().
snake([], Acc, _Prev) ->
    Acc;
snake([C | Rest], Acc, Prev) when C >= $A, C =< $Z ->
    Boundary =
        case Prev of
            none ->
                false;
            P when (P >= $a andalso P =< $z) orelse (P >= $0 andalso P =< $9) ->
                %% lower->Upper / digit->Upper starts a new word
                true;
            P when P >= $A, P =< $Z ->
                %% Upper->Upper starts a word only when the run ends
                %% here (CountryIDRef -> country_id_ref)
                case Rest of
                    [N | _] when N >= $a, N =< $z -> true;
                    _ -> false
                end;
            _ ->
                false
        end,
    Acc1 =
        case Boundary of
            true -> <<Acc/binary, "_">>;
            false -> Acc
        end,
    snake(Rest, <<Acc1/binary, (C + 32)>>, C);
snake([C | Rest], Acc, _Prev) ->
    snake(Rest, <<Acc/binary, C>>, C).

-doc "The module key with dots replaced by underscores (an atom-safe module name).".
-spec sanitize(binary()) -> binary().
sanitize(Name) ->
    binary:replace(Name, <<".">>, <<"_">>, [global]).

-doc "The generated types module atom of a module key (`demo.widgets` -> `demo_widgets_types`).".
-spec types_module_atom(binary()) -> module().
types_module_atom(Name) ->
    binary_to_atom(<<(sanitize(Name))/binary, "_types">>, utf8).

-doc """
The module's namespace-derived identifier prefix: prepended (with a
separating underscore) to every record tag, type alias, derived
function name and constant macro of that module; empty without a
declared erl/wildcard namespace.
""".
-spec typed_prefix(binary(), binary()) -> binary().
typed_prefix(<<>>, Name) ->
    Name;
typed_prefix(Prefix, Name) ->
    <<Prefix/binary, "_", Name/binary>>.

-doc "Returns the namespace prefix of the module being generated.".
-spec current_prefix(#ectx{}) -> binary().
current_prefix(Ctx) ->
    (maps:get(Ctx#ectx.current, Ctx#ectx.modules))#tg_module.prefix.
