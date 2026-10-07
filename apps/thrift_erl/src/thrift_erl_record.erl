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

-module(thrift_erl_record).

-moduledoc """
Conversion between wire values (maps) and records, driven purely by
type descriptors.

The generic codec speaks maps. Generated types modules additionally
export `record_fields/1`, returning `{RecordTag, [FieldAtoms]}` for
structs represented as records and `none` for the map representation.
This module walks a descriptor and converts struct values both ways,
recursing through containers — so the generated client wrappers and
server connection can hand users records while the wire stays maps.

Handlers and callers never call this directly; it is the glue between
the generated boundary code and the codec.
""".

-export([
    args_to_wire/2,
    args_from_wire/2,
    result_to_wire/3,
    call_result_from_wire/3,
    to_wire/2,
    from_wire/2
]).

-export_type([
    type_desc/0,
    field_desc/0,
    struct_desc/0,
    call_result/0,
    exception_field/0
]).

-type type_desc() :: thrift_erl_binary:type_desc().
-type field_desc() :: thrift_erl_binary:field_desc().
-type struct_desc() :: thrift_erl_binary:struct_desc().
-type call_result() :: thrift_erl_client:call_result().
-type exception_field() :: field_desc().

%%--------------------------------------------------------------------
%% Argument lists (client → wire, wire → server handler)
%%--------------------------------------------------------------------

-doc "Converts call arguments to wire representation, in order.".
-spec args_to_wire({struct, struct_desc()}, [term()]) -> [term()].
args_to_wire({struct, {_Kind, Fields}}, Args) ->
    Types = [T || {_, _, T, _, _} <- Fields],
    [to_wire(T, V) || {T, V} <- lists:zip(Types, Args)].

-doc "Converts wire call arguments to the handler representation.".
-spec args_from_wire({struct, struct_desc()}, [term()]) -> [term()].
args_from_wire({struct, {_Kind, Fields}}, Args) ->
    Types = [T || {_, _, T, _, _} <- Fields],
    [from_wire(T, V) || {T, V} <- lists:zip(Types, Args)].

%%--------------------------------------------------------------------
%% Whole call results
%%--------------------------------------------------------------------

-doc """
Converts a handler result to wire representation.

`Result` is `{ok, Value}`, `{error, {exception, Name, Value}}` or
anything else (passed through) — the shapes the connection handles.
""".
-spec result_to_wire(type_desc() | undefined, [exception_field()], term()) -> term().
result_to_wire(_ReplyType, _Exceptions, {ok, undefined} = Result) ->
    Result;
result_to_wire(ReplyType, _Exceptions, {ok, Value}) when ReplyType =/= undefined ->
    {ok, to_wire(ReplyType, Value)};
result_to_wire(_ReplyType, Exceptions, {error, {exception, Name, Value}}) ->
    case exception_type(Name, Exceptions) of
        {ok, Type} -> {error, {exception, Name, to_wire(Type, Value)}};
        error -> {error, {exception, Name, Value}}
    end;
result_to_wire(_ReplyType, _Exceptions, Result) ->
    Result.

-doc """
Converts a call result to the handler (record) representation.

`CallResult` is what `thrift_erl_client:call/4` returned.
""".
-spec call_result_from_wire(type_desc() | undefined, [exception_field()], call_result()) ->
    call_result().
call_result_from_wire(_ReplyType, _Exceptions, {ok, undefined} = Result) ->
    Result;
call_result_from_wire(ReplyType, _Exceptions, {ok, Value}) when ReplyType =/= undefined ->
    {ok, from_wire(ReplyType, Value)};
call_result_from_wire(_ReplyType, Exceptions, {error, {exception, Name, Value}}) ->
    case exception_type(Name, Exceptions) of
        {ok, Type} -> {error, {exception, Name, from_wire(Type, Value)}};
        error -> {error, {exception, Name, Value}}
    end;
call_result_from_wire(_ReplyType, _Exceptions, Result) ->
    Result.

%% Exceptions are identified by their struct name (the IDL-level
%% identity); the throw-field name is the fallback for descriptors
%% without a struct ref.
-spec exception_type(binary(), [exception_field()]) -> {ok, type_desc()} | error.
exception_type(Name, Exceptions) ->
    Pred = fun
        ({_, _, {struct, {ref, _, StructName}}, _, _}) -> StructName =:= Name;
        ({_, _, _, FieldName, _}) -> FieldName =:= Name
    end,
    case lists:search(Pred, Exceptions) of
        {value, {_, _, Type, _, _}} -> {ok, Type};
        false -> error
    end.

%%--------------------------------------------------------------------
%% Core value conversion
%%--------------------------------------------------------------------

%% The wire representation is authoritative. A struct is a record when
%% its types module exports record_fields for it; otherwise the wire map
%% passes through unchanged (the map representation).

-doc "Converts a record-representation value to the wire representation.".
-spec to_wire(type_desc(), term()) -> term().
to_wire({struct, {ref, Module, Name}}, Value) ->
    case Module:record_fields(Name) of
        none ->
            Value;
        {_Tag, _Fields} ->
            {_, Fields} = Module:struct_info(Name),
            struct_to_wire(Fields, Value)
    end;
to_wire({struct, {_Kind, _Fields}}, Value) ->
    %% Inline descriptors carry no identity: the value is already in
    %% whatever representation the caller holds.
    Value;
to_wire({list, Elem}, Values) when is_list(Values) ->
    [to_wire(Elem, V) || V <- Values];
to_wire({set, Elem}, Values) when is_list(Values) ->
    [to_wire(Elem, V) || V <- Values];
to_wire({map, KeyType, ValType}, Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{to_wire(KeyType, K) => to_wire(ValType, V)}
        end,
        #{},
        Map
    );
to_wire(_Type, Value) ->
    Value.

-doc "Converts a wire value to the record representation.".
-spec from_wire(type_desc(), term()) -> term().
from_wire({struct, {ref, Module, Name}}, Value) when is_map(Value) ->
    case Module:record_fields(Name) of
        none ->
            Value;
        {Tag, _Fields} ->
            {_, Fields} = Module:struct_info(Name),
            struct_from_wire(Tag, Fields, Value)
    end;
from_wire({struct, {_Kind, _Fields}}, Value) ->
    Value;
from_wire({list, Elem}, Values) when is_list(Values) ->
    [from_wire(Elem, V) || V <- Values];
from_wire({set, Elem}, Values) when is_list(Values) ->
    [from_wire(Elem, V) || V <- Values];
from_wire({map, KeyType, ValType}, Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{from_wire(KeyType, K) => from_wire(ValType, V)}
        end,
        #{},
        Map
    );
from_wire(_Type, Value) ->
    Value.

%%--------------------------------------------------------------------
%% Struct-level conversion
%%--------------------------------------------------------------------

-spec struct_to_wire([field_desc()], tuple()) -> map().
struct_to_wire(Fields, Record) ->
    Values = tl(tuple_to_list(Record)),
    #{
        Name => to_wire(Type, V)
     || {V, {_, _, Type, Name, _}} <- lists:zip(Values, Fields), V =/= undefined
    }.

-spec struct_from_wire(atom(), [field_desc()], map()) -> tuple().
struct_from_wire(Tag, Fields, Map) ->
    Values = [
        case Map of
            #{Name := V} -> from_wire(Type, V);
            _ -> undefined
        end
     || {_, _, Type, Name, _} <- Fields
    ],
    list_to_tuple([Tag | Values]).
