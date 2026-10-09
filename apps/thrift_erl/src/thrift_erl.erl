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

-module(thrift_erl).

-moduledoc """
High-level facade over the runtime codecs: two independent axes.

The **protocol** axis picks the wire format; the default is the Thrift
binary protocol, `compact` and `json` are the built-in Apache
protocols, and any module implementing `thrift_erl_protocol` plugs in
without code changes here. The **representation** axis picks the in-process shape
of struct values:

- `record` — tuple records as declared by generated `<mod>_types.erl`
  (the default for record-mode structs);
- `map` — plain maps with atom keys matching the IDL field names;
- `struct` — `#{__struct__ => Tag, Field => Value, ...}`, the
  Elixir-style tagged map that survives round-trips without the record
  definitions in scope;
- `native` — EEP-79 native records (OTP 29+): values minted by
  `thrift_erl_native` from the descriptor, fields readable through the
  `records` module without any compiled definitions. Releases older
  than 29 answer `{error, {unsupported_repr, native}}` from `decode`
  and `convert`.

`encode/2,3` accepts any representation on input and auto-detects it;
`decode/3,4` produces the requested one. `convert/3` reshapes typed
values without touching bytes: pass the tag index emitted by the
generator (the `TagIndex/0` export of generated types modules) and any
record or struct-map value.

All functions are pure; the network API lives in `thrift_erl_client`
and `thrift_erl_server`.
""".

-export([
    encode/2,
    encode/3,
    decode/3,
    decode/4,
    convert/3,
    protocol_module/1
]).

-export_type([repr/0, protocol/0, tag_index/0]).

%% Struct representations. `record` requires the generated record
%% definitions in scope; `map` and `struct` work without them; `native`
%% (EEP-79) exists on OTP 29+ only.
-type repr() :: record | map | struct | native.

%% Wire protocols: named ones known here, or any module implementing
%% `thrift_erl_protocol`.
-type protocol() :: thrift_erl_protocol:protocol() | module().

%% Tag index emitted by the generator into `<mod>_types.erl`:
%% record tag or `__struct__` key -> struct descriptor.
-type tag_index() :: #{atom() => thrift_erl_protocol:type_desc()}.

%% The thrift_erl_protocol callback set a custom protocol module must
%% export.
-define(PROTOCOL_CALLBACKS, [
    {encode, 2},
    {decode, 2},
    {encode_message, 4},
    {decode_message, 1},
    {encode_application_exception, 2},
    {decode_application_exception, 1}
]).

-doc "Encodes a value in any representation with the binary protocol.".
-spec encode(thrift_erl_binary:type_desc(), term()) -> {ok, binary()} | {error, term()}.
encode(Desc, Value) ->
    encode(Desc, Value, binary).

-doc "Encodes a value in any representation with the given protocol.".
-spec encode(thrift_erl_binary:type_desc(), term(), protocol()) -> {ok, binary()} | {error, term()}.
encode(Desc, Value, Protocol) ->
    case protocol_module(Protocol) of
        {ok, Mod} ->
            case Mod:encode(Desc, thrift_erl_record:to_wire(Desc, Value)) of
                {ok, IoData} -> {ok, iolist_to_binary(IoData)};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Decodes the whole binary into a record with the binary protocol.

Unlike the streaming `thrift_erl_binary:decode/2`, this is strict: a
truncated input fails with `{error, truncated}`, trailing bytes with
`{error, trailing}`. The `record` representation of a
map-representation struct is its atom-keyed map.
""".
-spec decode(thrift_erl_binary:type_desc(), binary(), repr()) -> {ok, term()} | {error, term()}.
decode(Desc, Binary, Repr) ->
    decode(Desc, Binary, Repr, binary).

-doc "Decodes the whole binary into the given representation and protocol.".
-spec decode(thrift_erl_binary:type_desc(), binary(), repr(), protocol()) ->
    {ok, term()} | {error, term()}.
decode(Desc, Binary, Repr, Protocol) ->
    case repr_supported(Repr) of
        true ->
            case protocol_module(Protocol) of
                {ok, Mod} ->
                    case Mod:decode(Desc, Binary) of
                        {ok, Value, <<>>} ->
                            {ok, thrift_erl_record:from_wire(Desc, Value, Repr)};
                        {ok, _Value, _Rest} ->
                            {error, trailing};
                        more ->
                            {error, truncated};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            {error, {unsupported_repr, native}}
    end.

%% The one representation with an OTP floor: native records need the
%% `records` module (OTP 29), everything else is release-independent.

-spec repr_supported(repr()) -> boolean().
repr_supported(native) ->
    thrift_erl_native:supported();
repr_supported(_Repr) ->
    true.

-doc """
Reshapes a typed value (record or struct-map, nested structures
included) into `Repr`, without encoding bytes.

`Value` carries its own identity — a record tag or the `__struct__`
key — which is looked up in `TagIndex` (the `TagIndex/0` export of
generated types modules). Unknown tags and values without identity
crash: this function is for values the caller knows to be service
structs. The `record` representation of a map-representation struct
answers `{error, {no_record, Tag}}` — there is no record to produce.
""".
-spec convert(tag_index(), term(), repr()) -> {ok, term()} | {error, term()}.
convert(TagIndex, Value, Repr) when is_map(TagIndex) ->
    Tag = value_tag(Value),
    %% Misuse (an unknown tag or a value without identity) is a
    %% programming error, not a data condition: crash.
    #{Tag := Desc} = TagIndex,
    Wire = thrift_erl_record:to_wire(Desc, Value),
    case Repr of
        record ->
            case thrift_erl_record:repr_mode(Desc) of
                record -> {ok, thrift_erl_record:from_wire(Desc, Wire, record)};
                _ -> {error, {no_record, Tag}}
            end;
        map ->
            {ok, thrift_erl_record:from_wire(Desc, Wire, map)};
        struct ->
            {ok, thrift_erl_record:from_wire(Desc, Wire, struct)};
        native ->
            case thrift_erl_native:supported() of
                true -> {ok, thrift_erl_record:from_wire(Desc, Wire, native)};
                false -> {error, {unsupported_repr, native}}
            end
    end.

-doc """
Resolves a protocol axis value to its implementation module.

`binary`, `compact` and `json` are the built-in protocols; a module
name is
accepted after verifying it exports every `thrift_erl_protocol`
callback.
""".
-spec protocol_module(protocol()) -> {ok, module()} | {error, term()}.
protocol_module(binary) ->
    {ok, thrift_erl_binary};
protocol_module(compact) ->
    {ok, thrift_erl_compact};
protocol_module(json) ->
    {ok, thrift_erl_json};
protocol_module(Mod) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} ->
            Exported = Mod:module_info(exports),
            case [CB || CB <- ?PROTOCOL_CALLBACKS, not lists:member(CB, Exported)] of
                [] ->
                    {ok, Mod};
                Missing ->
                    {error, {bad_protocol, Mod, Missing}}
            end;
        {error, What} ->
            {error, {bad_protocol, Mod, What}}
    end;
protocol_module(Other) ->
    {error, {bad_protocol, Other}}.

%% The identity of a typed struct value: the record tag of a tuple, or
%% the __struct__ key of an Elixir-style map.

-spec value_tag(term()) -> atom().
value_tag(Value) when is_tuple(Value), is_atom(element(1, Value)) ->
    element(1, Value);
value_tag(#{'__struct__' := Tag}) when is_atom(Tag) ->
    Tag.
