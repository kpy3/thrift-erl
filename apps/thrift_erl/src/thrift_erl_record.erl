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
Representation engine: converts struct values between the wire
representation (maps keyed by binary field names) and the in-process
representations — driven purely by type descriptors.

A struct descriptor's `{ref, Module, Name}` target declares its
representation through `Module:record_fields(Name)`:

- `{Tag, [FieldAtoms]}` — tuple records; `Tag` and the field atoms are
  the definitions generated into `<mod>_types.erl`;
- `{map, KeyType}` — maps with `KeyType` (`atom` | `binary`) keys, the
  `erl.struct_type = "map"` representation;
- `none`, or no `record_fields` export at all — hand-written
  descriptors: values pass through unchanged, assumed already wire.

Input values are auto-detected in `to_wire/2`: a native record (EEP-79,
OTP 29+, see `thrift_erl_native`), a tuple record, a plain map with
atom keys (the generated record field atoms), a plain map with binary
keys (already the wire shape) or an Elixir-style tagged map
(`#{__struct__ => Tag, ...}`) all normalize to the wire map.
`from_wire/2` produces the struct's default representation;
`from_wire/3` produces the requested one (see `thrift_erl:repr/0`).

Field atoms are only ever taken from generated definitions or minted
from IDL-controlled field names — never from wire data.
""".

-export([
    args_to_wire/2,
    args_from_wire/2,
    result_to_wire/3,
    call_result_from_wire/3,
    to_wire/2,
    from_wire/2,
    from_wire/3,
    repr_mode/1
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

%% How a struct-ref descriptor target represents its values.
-type mode() :: {record, atom(), [atom()]} | {map, atom() | binary()} | wire.

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
%% Representation introspection
%%--------------------------------------------------------------------

-doc """
The representation of a struct descriptor's values: `record` for
tuple records, `{map, KeyType}` for map-representation structs,
`wire` when values pass through unchanged (inline descriptors and
hand-written modules without `record_fields/1`).
""".
-spec repr_mode(type_desc()) -> record | {map, atom | binary} | wire.
repr_mode({struct, {ref, Module, Name}}) ->
    case struct_mode(Module, Name) of
        {record, _, _} -> record;
        {map, KeyType} -> {map, KeyType};
        wire -> wire
    end;
repr_mode(_) ->
    wire.

%%--------------------------------------------------------------------
%% Core value conversion
%%--------------------------------------------------------------------

%% The wire representation is authoritative: maps keyed by binary
%% field names, nested struct values in the same shape.

-doc """
Converts any representation (record, atom- or binary-keyed map,
struct-map) to the wire representation.
""".
-spec to_wire(type_desc(), term()) -> term().
to_wire({struct, {ref, Module, Name}}, Value) ->
    case thrift_erl_native:is_native(Value) of
        true ->
            native_to_wire(Module, Name, Value);
        false ->
            case struct_mode(Module, Name) of
                {record, Tag, FieldAtoms} -> record_to_wire(Module, Name, Tag, FieldAtoms, Value);
                {map, KeyType} -> map_mode_to_wire(Module, Name, KeyType, Value);
                wire -> Value
            end
    end;
to_wire({struct, {_Kind, _Fields}}, Value) ->
    %% Inline descriptors carry no identity: the value is already in
    %% whatever representation the caller holds.
    Value;
to_wire({list, Elem}, Values) when is_list(Values) ->
    [to_wire(Elem, V) || V <- Values];
%% The wire shape of a set is the element list for every erl.set
%% implementation: plain lists and ordsets are lists already, a `sets`
%% v2 collection folds through sets:to_list.
to_wire({set, Elem}, Values) when is_list(Values) ->
    [to_wire(Elem, V) || V <- Values];
to_wire({set, Elem, list}, Values) when is_list(Values) ->
    [to_wire(Elem, V) || V <- Values];
to_wire({set, Elem, ordset}, Values) when is_list(Values) ->
    [to_wire(Elem, V) || V <- Values];
%% No is_map guard: sets v2 is a map internally, and guarding narrows
%% the argument to map(), which dialyzer rejects against the opaque
%% sets:set(_) parameter of sets:to_list/1.
to_wire({set, Elem, sets}, Values) ->
    [to_wire(Elem, V) || V <- sets:to_list(Values)];
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

-doc "Converts a wire value to the struct's default representation.".
-spec from_wire(type_desc(), term()) -> term().
from_wire(Desc, Value) ->
    from_wire(Desc, Value, record).

-doc "Converts a wire value to the given representation.".
-spec from_wire(type_desc(), term(), thrift_erl:repr()) -> term().
%% Native records keep the representation uniform all the way down: a
%% wire-passthrough target has no identity to stamp, so its value stays
%% the wire map.
from_wire({struct, {ref, Module, Name}}, Value, native) when is_map(Value) ->
    case struct_mode(Module, Name) of
        wire ->
            Value;
        _Mode ->
            FieldValues = [
                {
                    field_atom(NameBin),
                    case Value of
                        #{NameBin := FieldValue} -> from_wire(Type, FieldValue, native);
                        _ -> undefined
                    end
                }
             || {_, _, Type, NameBin, _} <- struct_fields(Module, Name)
            ],
            thrift_erl_native:create(Module, record_tag(Name), FieldValues)
    end;
from_wire({struct, {ref, Module, Name}}, Value, Repr) when is_map(Value) ->
    case struct_mode(Module, Name) of
        {record, Tag, _FieldAtoms} ->
            case Repr of
                record -> struct_from_wire(Tag, struct_fields(Module, Name), Value);
                map -> wire_to_atom_map(struct_fields(Module, Name), Value);
                struct -> wire_to_struct_map(Tag, struct_fields(Module, Name), Value)
            end;
        {map, KeyType} ->
            case Repr of
                record -> map_mode_from_wire(struct_fields(Module, Name), KeyType, Value);
                map -> wire_to_atom_map(struct_fields(Module, Name), Value);
                struct -> wire_to_struct_map(record_tag(Name), struct_fields(Module, Name), Value)
            end;
        wire ->
            Value
    end;
from_wire({struct, {_Kind, _Fields}}, Value, _Repr) ->
    Value;
from_wire({list, Elem}, Values, Repr) when is_list(Values) ->
    [from_wire(Elem, V, Repr) || V <- Values];
from_wire({set, Elem}, Values, Repr) when is_list(Values) ->
    [from_wire(Elem, V, Repr) || V <- Values];
from_wire({set, Elem, list}, Values, Repr) when is_list(Values) ->
    [from_wire(Elem, V, Repr) || V <- Values];
from_wire({set, Elem, ordset}, Values, Repr) when is_list(Values) ->
    ordsets:from_list([from_wire(Elem, V, Repr) || V <- Values]);
from_wire({set, Elem, sets}, Values, Repr) when is_list(Values) ->
    sets:from_list([from_wire(Elem, V, Repr) || V <- Values]);
from_wire({map, KeyType, ValType}, Map, Repr) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{from_wire(KeyType, K, Repr) => from_wire(ValType, V, Repr)}
        end,
        #{},
        Map
    );
from_wire(_Type, Value, _Repr) ->
    Value.

%%--------------------------------------------------------------------
%% Struct mode resolution
%%--------------------------------------------------------------------

-spec struct_mode(module(), binary()) -> mode().
struct_mode(Module, Name) ->
    try Module:record_fields(Name) of
        {Tag, Fields} when is_atom(Tag), is_list(Fields) -> {record, Tag, Fields};
        {map, KeyType} when KeyType =:= atom; KeyType =:= binary -> {map, KeyType};
        none -> wire
    catch
        %% Hand-written descriptor targets may not export record_fields
        %% at all; their values are assumed already wire.
        error:undef -> wire
    end.

-spec struct_fields(module(), binary()) -> [field_desc()].
struct_fields(Module, Name) ->
    {_, Fields} = Module:struct_info(Name),
    Fields.

%%--------------------------------------------------------------------
%% record mode: record | map | struct-map -> wire
%%--------------------------------------------------------------------

-spec record_to_wire(module(), binary(), atom(), [atom()], term()) -> map().
record_to_wire(Module, Name, Tag, _FieldAtoms, Value) when
    is_tuple(Value), element(1, Value) =:= Tag
->
    struct_to_wire(struct_fields(Module, Name), Value);
record_to_wire(Module, Name, _Tag, FieldAtoms, Value) when is_map(Value) ->
    %% Atom keys come from the generated record definition, binary keys
    %% are already wire; the __struct__ tag is identity metadata.
    FieldsZip = lists:zip(struct_fields(Module, Name), FieldAtoms),
    declared_to_wire(FieldsZip, maps:remove('__struct__', Value)).

-spec struct_to_wire([field_desc()], tuple()) -> map().
struct_to_wire(Fields, Record) ->
    Values = tl(tuple_to_list(Record)),
    #{
        NameBin => to_wire(Type, V)
     || {V, {_, _, Type, NameBin, _}} <- lists:zip(Values, Fields), V =/= undefined
    }.

%% A native record encodes through its declaration, not its fields'
%% positions: the identity (module and lowercased struct name) must match
%% the descriptor, declared fields are taken when defined, `undefined`
%% is skipped exactly as for tuple records, and fields the descriptor
%% does not declare (a newer definition than the descriptor) are ignored.

-spec native_to_wire(module(), binary(), term()) -> map().
native_to_wire(Module, Name, Record) ->
    {RecordModule, RecordName, FieldMap} = thrift_erl_native:fields(Record),
    case RecordModule =:= Module andalso RecordName =:= record_tag(Name) of
        true ->
            maps:from_list([
                {NameBin, to_wire(Type, V)}
             || {_, _, Type, NameBin, _} <- struct_fields(Module, Name),
                {ok, V} <- [native_lookup(field_atom(NameBin), FieldMap)]
            ]);
        false ->
            erlang:error({badrecord, Record})
    end.

-spec native_lookup(atom(), #{atom() => term()}) -> {ok, term()} | none.
native_lookup(Atom, FieldMap) ->
    case FieldMap of
        #{Atom := undefined} -> none;
        #{Atom := V} -> {ok, V};
        _ -> none
    end.

%% Walks the declared fields, accepting either the binary field name or
%% its generated field atom as the input key.

-spec declared_to_wire([{field_desc(), atom()}], map()) -> map().
declared_to_wire(FieldsZip, Map) ->
    maps:from_list([
        {NameBin, to_wire(Type, V)}
     || {{_, _, Type, NameBin, _}, Atom} <- FieldsZip,
        {ok, V} <- [lookup_field(NameBin, Atom, Map)]
    ]).

-spec lookup_field(binary(), atom(), map()) -> {ok, term()} | none.
lookup_field(NameBin, Atom, Map) ->
    case Map of
        #{NameBin := V} ->
            {ok, V};
        _ when Atom =/= undefined ->
            case Map of
                #{Atom := V} -> {ok, V};
                _ -> none
            end;
        _ ->
            none
    end.

%%--------------------------------------------------------------------
%% map mode: atom- or binary-keyed map -> wire
%%--------------------------------------------------------------------

-spec map_mode_to_wire(module(), binary(), atom() | binary(), term()) -> map().
map_mode_to_wire(Module, Name, KeyType, Value) when is_map(Value) ->
    Fields = struct_fields(Module, Name),
    FieldsZip =
        case KeyType of
            atom ->
                [{Field, field_atom(NameBin)} || Field = {_, _, _, NameBin, _} <- Fields];
            binary ->
                [{Field, undefined} || Field <- Fields]
        end,
    %% lookup_field accepts binary keys first, so a {map, atom} struct
    %% fed its own wire shape round-trips instead of dropping fields.
    declared_to_wire(FieldsZip, Value).

%%--------------------------------------------------------------------
%% wire -> record | map | struct
%%--------------------------------------------------------------------

-spec struct_from_wire(atom(), [field_desc()], map()) -> tuple().
struct_from_wire(Tag, Fields, Map) ->
    Values = [
        case Map of
            #{NameBin := V} -> from_wire(Type, V, record);
            _ -> undefined
        end
     || {_, _, Type, NameBin, _} <- Fields
    ],
    list_to_tuple([Tag | Values]).

%% Every representation is uniform all the way down: `map` produces
%% atom-keyed plain maps for nested structs, `struct` propagates the
%% `__struct__` tag through nesting, `record` produces records for every
%% record-mode struct on the path.

-spec wire_to_atom_map([field_desc()], map()) -> map().
wire_to_atom_map(Fields, Map) ->
    wire_to_fields(Fields, Map, map).

-spec wire_to_struct_map(atom(), [field_desc()], map()) -> map().
wire_to_struct_map(Tag, Fields, Map) ->
    maps:put('__struct__', Tag, wire_to_fields(Fields, Map, struct)).

-spec wire_to_fields([field_desc()], map(), thrift_erl:repr()) -> map().
wire_to_fields(Fields, Map, Repr) ->
    maps:from_list([
        {field_atom(NameBin), from_wire(Type, V, Repr)}
     || {_, _, Type, NameBin, _} <- Fields,
        maps:is_key(NameBin, Map),
        V <- [maps:get(NameBin, Map)]
    ]).

-spec map_mode_from_wire([field_desc()], atom() | binary(), map()) -> map().
map_mode_from_wire(Fields, atom, Map) ->
    wire_to_fields(Fields, Map, record);
map_mode_from_wire(Fields, binary, Map) ->
    maps:from_list([
        {NameBin, from_wire(Type, V, record)}
     || {_, _, Type, NameBin, _} <- Fields,
        maps:is_key(NameBin, Map),
        V <- [maps:get(NameBin, Map)]
    ]).

%%--------------------------------------------------------------------
%% Name helpers
%%--------------------------------------------------------------------

-spec field_atom(binary()) -> atom().
field_atom(NameBin) ->
    binary_to_atom(NameBin, utf8).

-spec record_tag(binary()) -> atom().
record_tag(NameBin) ->
    binary_to_atom(string:lowercase(NameBin), utf8).
