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

-module(thrift_erl_names).

-moduledoc """
The runtime's mirror of the generator's identifier derivation: a wire
struct name becomes the snake-cased tag (`InvoiceBankAccount` ->
`invoice_bank_account`) the runtime reaches for when a descriptor
target declares no record tag of its own — map-mode `__struct__` tags
and hand-written descriptor targets.
""".

-export([snake/1]).

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
                true;
            P when P >= $A, P =< $Z ->
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
