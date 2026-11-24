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

-module(thrift_runtime_rpc).

-moduledoc """
RPC conversion boundary: call arguments and whole call results between
the handler representation and the wire representation.

The conversion itself is the representation engine's job
(`thrift_runtime_record:to_wire/2` and `from_wire/2`, driven purely by
the canonical type descriptors of `thrift_runtime_protocol`); this
module owns the RPC-shaped seams over it:

- `args_to_wire/2` and `args_from_wire/2` convert a call's positional
  argument list against the function's params struct descriptor;
- `result_to_wire/3` converts a handler result — the strict `ok` /
  `{ok, Value}` success contract or a declared exception — to what the
  result codec encodes;
- `call_result_from_wire/3` converts what `thrift_runtime_client:call/4`
  returned — including the wire-level `{error, {exception, Name, Map}}` —
  to the caller-facing shape.

Declared exceptions are identified by their struct name (the IDL-level
identity); a handler may signal one by that explicit name or by the
value's representation tag (record tag, `__struct__` map or sum-union
field atom). Map-representation exceptions are plain maps and carry no
identity — handlers signal them through the explicit-name form.
""".

-export([
    args_to_wire/2,
    args_from_wire/2,
    result_to_wire/3,
    call_result_from_wire/3
]).

%%--------------------------------------------------------------------
%% Argument lists (client → wire, wire → server handler)
%%--------------------------------------------------------------------

-doc "Converts call arguments to wire representation, in order.".
-spec args_to_wire({struct, thrift_runtime_protocol:struct_desc()}, [term()]) -> [term()].
args_to_wire({struct, {_Kind, Fields}}, Args) ->
    Types = [T || {_, _, T, _, _} <- Fields],
    [thrift_runtime_record:to_wire(T, V) || {T, V} <- lists:zip(Types, Args)].

-doc "Converts wire call arguments to the handler representation.".
-spec args_from_wire({struct, thrift_runtime_protocol:struct_desc()}, [term()]) -> [term()].
args_from_wire({struct, {_Kind, Fields}}, Args) ->
    Types = [T || {_, _, T, _, _} <- Fields],
    [thrift_runtime_record:from_wire(T, V) || {T, V} <- lists:zip(Types, Args)].

%%--------------------------------------------------------------------
%% Whole call results
%%--------------------------------------------------------------------

-doc """
Converts a handler result to wire representation.

`Result` is `ok` — the success answer of a `void` function — or
`{ok, Value}` — the reply of a non-void function, converted through
`ReplyType`; declared exceptions answer `{error, {exception, Value}}` —
the declared exception identified by its representation tag — or
`{error, {exception, Name, Value}}` with an explicit wire name (the
form hand-written descriptors and map-representation exceptions need);
anything else passes through, and the runtime rejects it as an
unsupported result.
""".
-spec result_to_wire(thrift_runtime_protocol:type_desc() | undefined, [thrift_runtime_protocol:field_desc()], term()) ->
    term().
result_to_wire(undefined, _Exceptions, ok = Result) ->
    Result;
result_to_wire(ReplyType, _Exceptions, {ok, Value}) when ReplyType =/= undefined ->
    {ok, thrift_runtime_record:to_wire(ReplyType, Value)};
result_to_wire(_ReplyType, Exceptions, {error, {exception, Value}} = Result) ->
    case exception_name(Value, Exceptions) of
        {ok, Name} -> result_to_wire(undefined, Exceptions, {error, {exception, Name, Value}});
        error -> Result
    end;
result_to_wire(_ReplyType, Exceptions, {error, {exception, Name, Value}}) ->
    case exception_type(Name, Exceptions) of
        {ok, Type} -> {error, {exception, Name, thrift_runtime_record:to_wire(Type, Value)}};
        error -> {error, {exception, Name, Value}}
    end;
result_to_wire(_ReplyType, _Exceptions, Result) ->
    Result.

-doc """
Converts a call result to the handler representation.

`CallResult` is what `thrift_runtime_client:call/4` returned. A `void`
function (`ReplyType => undefined`) answers the bare atom `ok`, and so
does `{ok, undefined}` for compatibility with callers still matching
the old shape; any other bare `ok` passes through unchanged. Declared
exceptions answer `{error, {exception, Value}}`: the value's
representation — record tag, `__struct__` map or native record —
identifies the exception.
""".
-spec call_result_from_wire(
    thrift_runtime_protocol:type_desc() | undefined,
    [thrift_runtime_protocol:field_desc()],
    thrift_runtime_client:call_result()
) ->
    term().
call_result_from_wire(undefined, _Exceptions, {ok, undefined}) ->
    ok;
call_result_from_wire(_ReplyType, _Exceptions, {ok, undefined} = Result) ->
    Result;
call_result_from_wire(ReplyType, _Exceptions, {ok, Value}) when ReplyType =/= undefined ->
    {ok, thrift_runtime_record:from_wire(ReplyType, Value)};
call_result_from_wire(_ReplyType, Exceptions, {error, {exception, Name, Value}}) ->
    case exception_type(Name, Exceptions) of
        {ok, Type} -> {error, {exception, thrift_runtime_record:from_wire(Type, Value)}};
        error -> {error, {exception, Value}}
    end;
call_result_from_wire(_ReplyType, _Exceptions, Result) ->
    Result.

%%--------------------------------------------------------------------
%% Exception identity
%%--------------------------------------------------------------------
%%
%% Exceptions are identified by their struct name (the IDL-level
%% identity); the throw-field name is the fallback for descriptors
%% without a struct ref.

-spec exception_type(binary(), [thrift_runtime_protocol:field_desc()]) ->
    {ok, thrift_runtime_protocol:type_desc()} | error.
exception_type(Name, Exceptions) ->
    Pred = fun
        ({_, _, {struct, {ref, _, StructName}}, _, _}) -> StructName =:= Name;
        ({_, _, _, FieldName, _}) -> FieldName =:= Name
    end,
    case lists:search(Pred, Exceptions) of
        {value, {_, _, Type, _, _}} -> {ok, Type};
        false -> error
    end.

%% The name of the declared exception a handler value belongs to: the
%% value's representation tag (record tag, `__struct__` atom, sum-union
%% field atom) is matched against every declared exception. Map-mode
%% exceptions are plain maps and carry no identity — handlers signal
%% them through the explicit-name form.

-spec exception_name(term(), [thrift_runtime_protocol:field_desc()]) -> {ok, binary()} | error.
exception_name(Value, Exceptions) ->
    Pred = fun({_, _, Type, _FieldName, _}) -> value_matches_repr(Value, Type) end,
    case lists:search(Pred, Exceptions) of
        {value, {_, _, {struct, {ref, _, StructName}}, _, _}} -> {ok, StructName};
        {value, {_, _, _, FieldName, _}} -> {ok, FieldName};
        false -> error
    end.

-spec value_matches_repr(term(), thrift_runtime_protocol:type_desc()) -> boolean().
value_matches_repr(Value, {struct, {ref, Mod, Name}}) ->
    Tag =
        case Value of
            #{'__struct__' := T} when is_atom(T) -> T;
            _ -> tuple_tag(Value)
        end,
    case struct_mode(Mod, Name) of
        {record, Declared, _} -> Tag =:= Declared;
        {map, _} -> false;
        {native, Declared} -> Tag =:= Declared;
        {sum, FieldAtoms} -> is_atom(Tag) andalso lists:member(Tag, FieldAtoms);
        _ -> false
    end;
value_matches_repr(_, _) ->
    false.

-spec tuple_tag(term()) -> atom() | undefined.
tuple_tag(Value) when is_tuple(Value), tuple_size(Value) >= 1, is_atom(element(1, Value)) ->
    element(1, Value);
tuple_tag(_) ->
    undefined.

%% How a struct-ref descriptor target represents its values: the same
%% resolution the representation engine applies through the generated
%% `record_fields/1` contract, narrowed to the modes an exception value
%% can be identified by.

-type mode() ::
    {record, atom(), [atom()]}
    | {map, atom() | binary()}
    | {sum, [atom()]}
    | {native, atom()}
    | wire.

-spec struct_mode(module(), binary()) -> mode().
struct_mode(Module, Name) ->
    try Module:record_fields(Name) of
        {sum, Fields} when is_list(Fields) -> {sum, Fields};
        {Tag, Fields} when is_atom(Tag), is_list(Fields) -> {record, Tag, Fields};
        {map, KeyType} when KeyType =:= atom; KeyType =:= binary -> {map, KeyType};
        {native, Tag} when is_atom(Tag) -> {native, Tag};
        none -> wire
    catch
        %% Hand-written descriptor targets may not export record_fields
        %% at all; their values are assumed already wire.
        error:undef -> wire
    end.
