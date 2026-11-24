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

-module(thrift_runtime_record).

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
- `{sum, [FieldAtoms]}` — sum unions (`erl.union_type = "sum"`):
  `{FieldAtom, Value}` tagged tuples, exactly one variant by
  construction;
- `none`, or no `record_fields` export at all — hand-written
  descriptors: values pass through unchanged, assumed already wire.

Input values are auto-detected in `to_wire/2`: a native record (EEP-79,
OTP 29+, see `thrift_runtime_native`), a tuple record, a plain map with
atom keys (the generated record field atoms), a plain map with binary
keys (already the wire shape) or an Elixir-style tagged map
(`#{__struct__ => Tag, ...}`) all normalize to the wire map.
`from_wire/2` produces the struct's default representation;
`from_wire/3` produces the requested one (see `t:thrift_runtime:repr/0`).

Field atoms are only ever taken from generated definitions or minted
from IDL-controlled field names — never from wire data.

Generated `<mod>_types_repr' modules carry direct per-struct converters
registered in their `repr_index/1': tuple-record `to_wire/2' and
`from_wire/3' probe that index once per struct and then call the cached
functions with their literal field atoms, skipping the descriptor walk.
Map-shaped `to_wire/2' keeps the descriptor's maps:from_list path, which
is faster than the generated per-field map_put chain. Structs without a
converter (sum unions, map-mode and native-mode structs, hand-written
modules) have no repr module and keep the descriptor engine below.

A struct value that matches no representation (neither the declared
record tag nor a map) raises `value_does_not_match_type`; the facade
turns it into the tagged `{error, {value_does_not_match_type, Value}}`
the codecs answer with.
""".

-export([
    to_wire/2,
    from_wire/2,
    from_wire/3,
    repr_mode/1,
    record_tag/1,
    unknown_fields/2
]).

%% How a struct-ref descriptor target represents its values.
-type mode() ::
    {record, atom(), [atom()]}
    | {map, atom() | binary()}
    | {sum, [atom()]}
    | {native, atom()}
    | wire.

%%--------------------------------------------------------------------
%% Representation introspection
%%--------------------------------------------------------------------

-doc """
The representation of a struct descriptor's values: `record` for
tuple records, `{map, KeyType}` for map-representation structs, `sum`
for tagged-tuple unions, `{native, Tag}` for native-record structs,
`wire` when values pass through unchanged (inline descriptors and
hand-written modules without `record_fields/1`).
""".
-spec repr_mode(thrift_runtime_protocol:type_desc()) -> record | {map, atom | binary} | {native, atom} | sum | wire.
repr_mode({struct, {ref, Module, Name}}) ->
    case struct_mode(Module, Name) of
        {record, _, _} -> record;
        {map, KeyType} -> {map, KeyType};
        {sum, _} -> sum;
        {native, Tag} -> {native, Tag};
        wire -> wire
    end;
repr_mode(_) ->
    wire.

%% The keys of a map/struct-map input that match no declared field: the
%% `strict` encode option turns these into `{error, {unknown_fields,
%% Keys}}` instead of the default silent drop. `none` marks inputs with
%% nothing to check — non-maps, inline descriptors and wire-passthrough
%% targets have no declared field set to compare against.

-spec unknown_fields(thrift_runtime_protocol:type_desc(), term()) -> [atom() | binary()] | none.
unknown_fields({struct, {ref, Module, Name}}, Value) when is_map(Value) ->
    case struct_mode(Module, Name) of
        {record, Tag, FieldAtoms} ->
            dropped_keys(
                maps:remove('__struct__', Value),
                Tag,
                FieldAtoms ++ [NameBin || {_, _, _, NameBin, _} <- struct_fields(Module, Name)]
            );
        {map, KeyType} ->
            Fields = struct_fields(Module, Name),
            dropped_keys(
                Value,
                none,
                [NameBin || {_, _, _, NameBin, _} <- Fields] ++
                    [field_atom(NameBin) || {_, _, _, NameBin, _} <- Fields, KeyType =:= atom]
            );
        {native, _Tag} ->
            Fields = struct_fields(Module, Name),
            dropped_keys(
                maps:remove('__struct__', Value),
                none,
                [NameBin || {_, _, _, NameBin, _} <- Fields] ++
                    [field_atom(NameBin) || {_, _, _, NameBin, _} <- Fields]
            );
        wire ->
            none;
        _Mode ->
            none
    end;
unknown_fields(_Desc, _Value) ->
    none.

%% The input keys that match neither the binary field names nor the
%% field atoms; `Key` (a record tag) is identity metadata, not a field.

-spec dropped_keys(map(), atom() | none, [atom() | binary()]) -> [atom() | binary()].
dropped_keys(Map, Key, Declared) ->
    maps:keys(
        maps:without([Key | Declared], Map)
    ).

%%--------------------------------------------------------------------
%% Core value conversion
%%--------------------------------------------------------------------

%% The wire representation is authoritative: maps keyed by binary
%% field names, nested struct values in the same shape.

-doc """
Converts any representation (record, atom- or binary-keyed map,
struct-map) to the wire representation.
""".
-spec to_wire(thrift_runtime_protocol:type_desc(), term()) -> term().
to_wire({struct, {ref, Module, Name}}, Value) ->
    case thrift_runtime_native:is_native(Value) of
        true ->
            native_to_wire(Module, Name, Value);
        false ->
            to_wire_ref(Module, Name, Value)
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

%% The generated-converter arm of to_wire/2 (kept shallow for elvis).
%% Map-shaped inputs keep the descriptor's maps:from_list construction:
%% the generated per-field map_put chain is slower on this path.

-spec to_wire_ref(module(), binary(), term()) -> term().
to_wire_ref(Module, Name, Value) when is_map(Value) ->
    to_wire_descriptor(Module, Name, Value);
to_wire_ref(Module, Name, Value) ->
    case repr_funs(Module, Name) of
        {ReprModule, ToWire, _} ->
            try
                ReprModule:ToWire(Value)
            catch
                error:undef:Stack ->
                    repr_undef(Module, Name, ReprModule, ToWire, 1, Stack, fun() ->
                        to_wire({struct, {ref, Module, Name}}, Value)
                    end)
            end;
        false ->
            to_wire_descriptor(Module, Name, Value);
        cold ->
            case repr_probe(Module, Name) of
                {_ReprModule, _ToWire, _FromWire} ->
                    to_wire({struct, {ref, Module, Name}}, Value);
                false ->
                    to_wire_descriptor(Module, Name, Value)
            end
    end.

-doc "Converts a wire value to the struct's default representation.".
-spec from_wire(thrift_runtime_protocol:type_desc(), term()) -> term().
from_wire(Desc, Value) ->
    from_wire(Desc, Value, record).

-doc "Converts a wire value to the given representation.".
-spec from_wire(thrift_runtime_protocol:type_desc(), term(), thrift_runtime:repr()) -> term().
%% The generated `repr_index' converters own the {ref, _Module, _Name}
%% map-input path when present; every other target keeps the descriptor
%% engine below.
from_wire({struct, {ref, Module, Name}}, Value, Repr) when is_map(Value) ->
    case repr_funs(Module, Name) of
        {ReprModule, _, FromWire} ->
            try
                ReprModule:FromWire(Repr, Value)
            catch
                error:undef:Stack ->
                    repr_undef(Module, Name, ReprModule, FromWire, 2, Stack, fun() ->
                        from_wire({struct, {ref, Module, Name}}, Value, Repr)
                    end)
            end;
        false ->
            from_wire_descriptor(Module, Name, Value, Repr);
        cold ->
            case repr_probe(Module, Name) of
                {_ReprModule, _ToWire, _FromWire} ->
                    from_wire({struct, {ref, Module, Name}}, Value, Repr);
                false ->
                    from_wire_descriptor(Module, Name, Value, Repr)
            end
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

%% The descriptor-driven from_wire for targets without a generated
%% converter: hand-written modules, sum unions, map-mode and native-mode
%% structs. Semantics must stay identical to the generated converters.

%% Native records keep the representation uniform all the way down: a
%% wire-passthrough target has no identity to stamp, so its value stays
%% the wire map.
-spec from_wire_descriptor(module(), binary(), map(), thrift_runtime:repr()) -> term().
from_wire_descriptor(Module, Name, Value, native) ->
    case struct_mode(Module, Name) of
        wire ->
            Value;
        {sum, _FieldAtoms} ->
            sum_from_wire(struct_fields(Module, Name), Value, native);
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
            thrift_runtime_native:create(Module, native_tag(Module, Name), FieldValues)
    end;
from_wire_descriptor(Module, Name, Value, Repr) ->
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
        {sum, _FieldAtoms} ->
            sum_from_wire(struct_fields(Module, Name), Value, Repr);
        {native, Tag} ->
            case Repr of
                %% No tuple record exists for a native-mode struct: the
                %% `record' axis answers its atom-keyed map (the facade
                %% reports {error, {no_record, _}} before reaching here).
                record -> map_mode_from_wire(struct_fields(Module, Name), atom, Value);
                map -> wire_to_atom_map(struct_fields(Module, Name), Value);
                struct -> wire_to_struct_map(Tag, struct_fields(Module, Name), Value)
            end;
        wire ->
            Value
    end.

%% The descriptor-driven to_wire for targets without a generated
%% converter (see from_wire_descriptor/4).

-spec to_wire_descriptor(module(), binary(), term()) -> term().
to_wire_descriptor(Module, Name, Value) ->
    case struct_mode(Module, Name) of
        {record, Tag, FieldAtoms} -> record_to_wire(Module, Name, Tag, FieldAtoms, Value);
        {map, KeyType} -> map_mode_to_wire(Module, Name, KeyType, Value);
        {sum, _FieldAtoms} -> sum_to_wire(struct_fields(Module, Name), Value);
        {native, _Tag} -> native_map_to_wire(Module, Name, Value);
        wire -> Value
    end.

%%--------------------------------------------------------------------
%% Generated converter dispatch
%%--------------------------------------------------------------------

%% The same dispatch contract the codec indexes use
%% (thrift_runtime_protocol): the hot path reads this module's own
%% persistent_term key, the cold probe asks the generated
%% `<types>_repr' module's `repr_index/1' once per struct name and
%% caches the verdict — the `{ReprModule, ToWire, FromWire}' triple for
%% record-mode structs, `false' for everything without a converter
%% (hand-written modules, sum unions, map-mode and native-mode structs).
%% A reload that drops a converter surfaces as undef on the call:
%% repr_stale/2 drops the entry and the caller re-enters, landing on the
%% descriptor path.

-spec repr_funs(module(), binary()) -> {module(), atom(), atom()} | false | cold.
repr_funs(Module, Name) ->
    case persistent_term:get({?MODULE, repr_mfa, Module}, probe) of
        #{Name := Entry} -> Entry;
        _ -> cold
    end.

-spec repr_probe(module(), binary()) -> {module(), atom(), atom()} | false.
repr_probe(Module, Name) ->
    ReprModule = repr_module(Module),
    Entry =
        case code:ensure_loaded(ReprModule) of
            {module, ReprModule} ->
                case erlang:function_exported(ReprModule, repr_index, 1) of
                    true ->
                        case ReprModule:repr_index(Name) of
                            {ok, {ToWire, FromWire}} when is_atom(ToWire), is_atom(FromWire) ->
                                {ReprModule, ToWire, FromWire};
                            error ->
                                false
                        end;
                    false ->
                        false
                end;
            {error, _} ->
                false
        end,
    repr_cache(Module, Name, Entry),
    Entry.

%% The repr module of a types module: `<mod>_types_repr'. The name is
%% derived from an already-loaded generated module, so the atom is
%% IDL-controlled, never wire data. A cached `false' verdict is not
%% invalidated when a repr module appears later — same documented
%% no-hot-swap trade-off as the codec dispatch.

-spec repr_module(module()) -> module().
repr_module(Module) ->
    binary_to_atom(<<(atom_to_binary(Module, utf8))/binary, "_repr">>, utf8).

%% Merges one probed name into the per-module map; last write wins, so
%% a racing writer can drop this entry — that only costs a re-probe.

-spec repr_cache(module(), binary(), {module(), atom(), atom()} | false) -> ok.
repr_cache(Module, Name, Entry) ->
    Key = {?MODULE, repr_mfa, Module},
    case persistent_term:get(Key, probe) of
        Cached when is_map(Cached) ->
            persistent_term:put(Key, Cached#{Name => Entry});
        _ ->
            persistent_term:put(Key, #{Name => Entry})
    end.

-spec repr_stale(module(), binary()) -> ok.
repr_stale(Module, Name) ->
    Key = {?MODULE, repr_mfa, Module},
    case persistent_term:get(Key, probe) of
        Cached when is_map(Cached) ->
            persistent_term:put(Key, maps:remove(Name, Cached));
        _ ->
            ok
    end.

%% An undef on a cached converter call means either a genuinely missing
%% function inside it (re-raise — the converter is broken, not stale) or
%% a reload that dropped it (invalidate and re-enter on the descriptor
%% path).

-spec repr_undef(module(), binary(), module(), atom(), arity(), erlang:stacktrace(), fun(() -> term())) ->
    term().
repr_undef(Module, Name, ReprModule, Fun, Arity, Stack, Retry) ->
    case erlang:function_exported(ReprModule, Fun, Arity) of
        true ->
            erlang:raise(error, undef, Stack);
        false ->
            repr_stale(Module, Name),
            Retry()
    end.

%%--------------------------------------------------------------------
%% Struct mode resolution
%%--------------------------------------------------------------------

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

-spec struct_fields(module(), binary()) -> [thrift_runtime_protocol:field_desc()].
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
    declared_to_wire(FieldsZip, maps:remove('__struct__', Value));
record_to_wire(_Module, _Name, _Tag, _FieldAtoms, Value) ->
    erlang:error({value_does_not_match_type, Value}).

-spec struct_to_wire([thrift_runtime_protocol:field_desc()], tuple()) -> map().
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
%%
%% Preprocessor-split like `thrift_runtime_native' itself: on a pre-29
%% toolchain dialyzer types `fields/1' as no_return() and would kill this
%% body down to its spec, so the stub keeps the raise contract and says
%% so in its spec — no native value can ever reach it there anyway.

-if(?OTP_RELEASE >= 29).

-spec native_to_wire(module(), binary(), term()) -> map().
native_to_wire(Module, Name, Record) ->
    {RecordModule, RecordName, FieldMap} = thrift_runtime_native:fields(Record),
    case RecordModule =:= Module andalso RecordName =:= native_tag(Module, Name) of
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

-else.

-spec native_to_wire(module(), binary(), term()) -> no_return().
native_to_wire(_Module, _Name, _Record) ->
    erlang:error(native_records_unsupported).

-endif.

%% A native-mode struct declares no tuple record, so the map input is
%% the only non-native shape: field atoms and wire names both normalize
%% (the `__struct__' key is identity metadata, same as record mode).

-spec native_map_to_wire(module(), binary(), term()) -> map().
native_map_to_wire(Module, Name, Value) when is_map(Value) ->
    Fields = struct_fields(Module, Name),
    declared_to_wire(
        [{Field, field_atom(NameBin)} || Field = {_, _, _, NameBin, _} <- Fields],
        maps:remove('__struct__', Value)
    );
native_map_to_wire(_Module, _Name, Value) ->
    erlang:error({value_does_not_match_type, Value}).

%% Walks the declared fields, accepting either the binary field name or
%% its generated field atom as the input key.

-spec declared_to_wire([{thrift_runtime_protocol:field_desc(), atom()}], map()) -> map().
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
    declared_to_wire(FieldsZip, Value);
map_mode_to_wire(_Module, _Name, _KeyType, Value) ->
    erlang:error({value_does_not_match_type, Value}).

%%--------------------------------------------------------------------
%% sum unions: {FieldAtom, Value} -> wire, wire -> {FieldAtom, Value}
%%--------------------------------------------------------------------

%% The tagged tuple IS the whole invariant: the input is a two-tuple
%% whose tag names a declared field, so a union value can never be
%% empty or carry two variants. The wire form is the same single-field
%% struct map every representation shares.

-spec sum_to_wire([thrift_runtime_protocol:field_desc()], term()) -> map().
sum_to_wire(Fields, {Tag, Value}) when is_atom(Tag) ->
    sum_field(Fields, Tag, Value);
sum_to_wire(_Fields, Value) ->
    erlang:error({value_does_not_match_type, Value}).

-spec sum_field([thrift_runtime_protocol:field_desc()], atom(), term()) -> map().
sum_field([], Tag, _Value) ->
    erlang:error({value_does_not_match_type, Tag});
sum_field([{_, _, Type, NameBin, _} | RestFields], Tag, Value) ->
    case field_atom(NameBin) =:= Tag of
        true -> #{NameBin => to_wire(Type, Value)};
        false -> sum_field(RestFields, Tag, Value)
    end.

%% The wire of a sum union must carry exactly one declared field: zero
%% or several, or a key matching nothing, is a malformed union — the
%% representation cannot express it, so it is a hard error (the facade
%% turns it into `{error, {invalid_union, Map}}').

-spec sum_from_wire([thrift_runtime_protocol:field_desc()], map(), thrift_runtime:repr()) -> {atom(), term()}.
sum_from_wire(Fields, WireMap, Repr) when map_size(WireMap) =:= 1 ->
    [NameBin] = maps:keys(WireMap),
    case lists:keyfind(NameBin, 4, Fields) of
        {_, _, Type, NameBin, _} ->
            {field_atom(NameBin), from_wire(Type, maps:get(NameBin, WireMap), Repr)};
        false ->
            erlang:error({invalid_union, WireMap})
    end;
sum_from_wire(_Fields, WireMap, _Repr) ->
    erlang:error({invalid_union, WireMap}).

%%--------------------------------------------------------------------
%% wire -> record | map | struct
%%--------------------------------------------------------------------

-spec struct_from_wire(atom(), [thrift_runtime_protocol:field_desc()], map()) -> tuple().
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

-spec wire_to_atom_map([thrift_runtime_protocol:field_desc()], map()) -> map().
wire_to_atom_map(Fields, Map) ->
    wire_to_fields(Fields, Map, map).

-spec wire_to_struct_map(atom(), [thrift_runtime_protocol:field_desc()], map()) -> map().
wire_to_struct_map(Tag, Fields, Map) ->
    maps:put('__struct__', Tag, wire_to_fields(Fields, Map, struct)).

-spec wire_to_fields([thrift_runtime_protocol:field_desc()], map(), thrift_runtime:repr()) -> map().
wire_to_fields(Fields, Map, Repr) ->
    maps:from_list([
        {field_atom(NameBin), from_wire(Type, V, Repr)}
     || {_, _, Type, NameBin, _} <- Fields,
        maps:is_key(NameBin, Map),
        V <- [maps:get(NameBin, Map)]
    ]).

-spec map_mode_from_wire([thrift_runtime_protocol:field_desc()], atom() | binary(), map()) -> map().
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

-doc """
The fallback identity tag for a struct whose definition declares no
record tag of its own: the snake-cased wire name (`__struct__` tags
of map-mode structs, hand-written descriptor targets).
""".
-spec record_tag(binary()) -> atom().
record_tag(NameBin) ->
    binary_to_atom(thrift_runtime_names:snake(NameBin), utf8).

%% The tag a minted native record carries: the declared (prefixed)
%% record tag when the target generates one — so a native value and the
%% tuple record of the same struct share one identity — the fallback
%% tag otherwise.

-spec native_tag(module(), binary()) -> atom().
native_tag(Module, Name) ->
    case struct_mode(Module, Name) of
        {record, Tag, _FieldAtoms} -> Tag;
        _ -> record_tag(Name)
    end.
