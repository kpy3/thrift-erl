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

-module(thrift_runtime).

-moduledoc """
High-level facade over the runtime codecs: two independent axes.

The **protocol** axis picks the wire format; the default is the Thrift
binary protocol, `compact` and `json` are the built-in Apache
protocols, and any module implementing `thrift_runtime_protocol` plugs in
without code changes here. The **representation** axis picks the in-process shape
of struct values:

- `record` — tuple records as declared by generated `<mod>_types.erl`
  (the default for record-mode structs);
- `map` — plain maps with atom keys matching the IDL field names;
- `struct` — `#{__struct__ => Tag, Field => Value, ...}`, the
  Elixir-style tagged map that survives round-trips without the record
  definitions in scope;
- `native` — EEP-79 native records (OTP 29+): values minted by
  `thrift_runtime_native` from the descriptor, fields readable through the
  `records` module without any compiled definitions. Releases older
  than 29 answer `{error, {unsupported_repr, native}}` from `decode`
  and `convert`.

Sum unions (`erl.union_type = "sum"`) are their own representation:
the value is a `{FieldAtom, Value}` tuple — one variant by
construction — unchanged across all four axes (only the nested
payloads convert). A wire union with zero or several set fields is
malformed and answers `{error, {invalid_union, Map}}`.

`encode/2,3` accepts any representation on input and auto-detects it;
`decode/3` produces the requested one. Both take the axes as an options
map — encode allows exactly `protocol` and `strict` (default `binary`,
`false`), decode allows exactly `protocol` and `repr` with `repr`
required — normalized and validated by
`thrift_runtime_options:codec_options/2`. `convert/3` reshapes typed
values without touching bytes: pass the struct's type descriptor and
any record, map or struct-map value; nested structures convert
recursively. A non-map options argument answers the documented
`{error, {bad_option, {options, Value, [map]}}}` — the transitional
positional protocol/repr forms, the arity-4 variants and the tag-index
convert input are gone.

All functions are pure; the network API lives in `thrift_runtime_client`
and `thrift_runtime_server`.
""".

-export([
    encode/2,
    encode/3,
    decode/3,
    convert/3,
    protocol_module/1,
    repr_supported/1
]).

-export_type([repr/0, protocol/0]).

%% Struct representations. `record` requires the generated record
%% definitions in scope; `map` and `struct` work without them; `native`
%% (EEP-79) exists on OTP 29+ only.
-type repr() :: record | map | struct | native.

%% Wire protocols: named ones known here, or any module implementing
%% `thrift_runtime_protocol`.
-type protocol() :: thrift_runtime_protocol:protocol() | module().

%% The thrift_runtime_protocol callback set a custom protocol module must
%% export. Kept by hand in sync with the -callback attributes of
%% thrift_runtime_protocol — there is no cheap way to derive one list from
%% the other at compile time.
-define(PROTOCOL_CALLBACKS, [
    {encode, 2},
    {decode, 2},
    {encode_message, 4},
    {decode_message, 1},
    {encode_application_exception, 2},
    {decode_application_exception, 1}
]).

-doc "Encodes a value in any representation with the binary protocol.".
-spec encode(thrift_runtime_binary:type_desc(), term()) -> {ok, binary()} | {error, term()}.
encode(Desc, Value) ->
    encode(Desc, Value, #{}).

-doc """
Encodes a value with the options map form of the facade.

The option map normalizes through
`thrift_runtime_options:codec_options/2`: exactly `protocol` and
`strict` are allowed (default `binary`, `false`); unknown keys, a
non-boolean `strict` and a bad protocol answer the documented option
errors without touching the value. `strict => true` checks the
top-level map/struct-map input against the struct's declared fields and
fails with `{error, {unknown_fields, Keys}}` instead of silently
dropping the keys that match nothing (the default). Every other value
shape the codecs reject on their own with `{error,
{value_does_not_match_type, Value}}`.

A non-map options argument is not a positional protocol: it answers
`{error, {bad_option, {options, Options, [map]}}}`.
""".
-spec encode(thrift_runtime_binary:type_desc(), term(), map()) ->
    {ok, binary()} | {error, term()}.
encode(Desc, Value, Options) when is_map(Options) ->
    case thrift_runtime_options:codec_options(Options, encode) of
        {ok, #{protocol := Protocol, strict := Strict}} ->
            encode_opts(Desc, Value, Protocol, #{strict => Strict});
        {error, _} = Error ->
            Error
    end;
encode(_Desc, _Value, Options) ->
    bad_options(Options).

%% The protocol-resolved encode: strict check first, then the wire
%% codec. The one-pass binary fast path retries through the two-pass
%% path on any failure so both answer the identical error for genuinely
%% bad values and the fast path can keep declining shapes it cannot
%% represent (mixed nesting).

-spec encode_opts(thrift_runtime_binary:type_desc(), term(), protocol(), map()) ->
    {ok, binary()} | {error, term()}.
encode_opts(Desc, Value, Protocol, Opts) ->
    case protocol_module(Protocol) of
        {ok, Mod} ->
            case strict_check(Desc, Value, Opts) of
                ok ->
                    case encode_wire(Desc, Value, Mod) of
                        {ok, IoData} -> {ok, iolist_to_binary(IoData)};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec strict_check(thrift_runtime_binary:type_desc(), term(), map()) -> ok | {error, term()}.
strict_check(Desc, Value, Opts) ->
    case maps:get(strict, Opts, false) of
        true ->
            case thrift_runtime_record:unknown_fields(Desc, Value) of
                [] -> ok;
                none -> ok;
                Unknown -> {error, {unknown_fields, Unknown}}
            end;
        false ->
            ok
    end.

%% The record engine raises `value_does_not_match_type` for a value
%% that matches no representation; the facade turns it into the same
%% tagged error the codecs answer with.

-spec encode_wire(thrift_runtime_binary:type_desc(), term(), module()) ->
    {ok, iodata()} | {error, term()}.
encode_wire(Desc, Value, Mod) ->
    case Mod of
        thrift_runtime_binary ->
            case thrift_runtime_binary:encode_repr(Desc, Value) of
                {ok, IoData} ->
                    {ok, IoData};
                %% Any fast-path failure retries the two-pass path:
                %% it answers the identical error for genuinely bad
                %% values and still accepts shapes the one-pass family
                %% cannot represent (mixed nesting).
                _ ->
                    encode_wire_two_pass(Desc, Value, Mod)
            end;
        _ ->
            encode_wire_two_pass(Desc, Value, Mod)
    end.

%% The two-pass baseline: conversion first, then the wire codec.
encode_wire_two_pass(Desc, Value, Mod) ->
    try thrift_runtime_record:to_wire(Desc, Value) of
        Wire ->
            Mod:encode(Desc, Wire)
    catch
        error:{value_does_not_match_type, V} ->
            {error, {value_does_not_match_type, V}}
    end.

-doc """
Decodes the whole binary with the options map form of the facade.

The option map normalizes through
`thrift_runtime_options:codec_options/2`: exactly `protocol` and
`repr` are allowed, `repr` is required (the advanced facade has no
schema module from which to infer one) and the protocol defaults to
binary; the normalized repr feeds the one-pass dispatch.

Unlike the streaming `thrift_runtime_binary:decode/2`, this is strict: a
truncated input fails with `{error, truncated}`, trailing bytes with
`{error, trailing}`. A map-representation or native-representation
struct has no record to produce: `record` fails with
`{error, {no_record, Name}}`.

A non-map options argument is not a positional repr: it answers
`{error, {bad_option, {options, Options, [map]}}}`.
""".
-spec decode(thrift_runtime_binary:type_desc(), binary(), map()) ->
    {ok, term()} | {error, term()}.
decode(Desc, Binary, Options) when is_map(Options) ->
    case thrift_runtime_options:codec_options(Options, decode) of
        {ok, #{protocol := Protocol, repr := Repr}} ->
            case protocol_module(Protocol) of
                {ok, Mod} ->
                    decode_fast(Mod, Desc, Binary, Repr);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
decode(_Desc, _Binary, Options) ->
    bad_options(Options).

%% A non-map options argument is not a positional protocol or repr:
%% the documented bad_option answer both facade directions share.

-spec bad_options(term()) -> {error, {bad_option, {options, term(), [map]}}}.
bad_options(Options) ->
    {error, {bad_option, {options, Options, [map]}}}.

%% The one-pass attempt: binary protocol only; any other protocol (or
%% a miss — hand-written modules, native-mode and sum unions) takes
%% the decode-to-wire + conversion path with identical results.
decode_fast(thrift_runtime_binary, Desc, Binary, Repr) ->
    case thrift_runtime_binary:decode_repr(Desc, Binary, Repr) of
        miss ->
            decode_two_pass(thrift_runtime_binary, Desc, Binary, Repr);
        {ok, Value, <<>>} ->
            {ok, Value};
        {ok, _Value, _Rest} ->
            {error, trailing};
        more ->
            {error, truncated};
        {error, _} = Error ->
            Error
    end;
decode_fast(Mod, Desc, Binary, Repr) ->
    decode_two_pass(Mod, Desc, Binary, Repr).

decode_two_pass(Mod, Desc, Binary, Repr) ->
    case Mod:decode(Desc, Binary) of
        {ok, Value, <<>>} ->
            decode_repr(Desc, Value, Repr);
        {ok, _Value, _Rest} ->
            {error, trailing};
        more ->
            {error, truncated};
        {error, Reason} ->
            {error, Reason}
    end.

%% A map-representation or native-representation struct has no record
%% to produce — `convert/3' answers `{error, {no_record, Tag}}` for the
%% same input, so `decode' does too instead of silently returning an
%% atom-keyed map. A sum union decodes into its tagged tuple under
%% `record'; a malformed union on the wire (zero or several fields) is a
%% data error, not a crash.

-spec decode_repr(thrift_runtime_binary:type_desc(), term(), repr()) -> {ok, term()} | {error, term()}.
decode_repr(Desc, Value, record) ->
    case thrift_runtime_record:repr_mode(Desc) of
        {map, _} ->
            {error, {no_record, struct_tag(Desc)}};
        {native, _} ->
            {error, {no_record, struct_tag(Desc)}};
        _Mode ->
            from_wire_repr(Desc, Value, record)
    end;
decode_repr(Desc, Value, Repr) ->
    from_wire_repr(Desc, Value, Repr).

-spec from_wire_repr(thrift_runtime_binary:type_desc(), term(), repr()) -> {ok, term()} | {error, term()}.
from_wire_repr(Desc, Value, Repr) ->
    try
        {ok, thrift_runtime_record:from_wire(Desc, Value, Repr)}
    catch
        error:{invalid_union, Map} -> {error, {invalid_union, Map}}
    end.

%% The tag a struct value carries for this descriptor: the snake-cased
%% wire name of map-mode structs.

-spec struct_tag({struct, {ref, module(), binary()}}) -> atom().
struct_tag({struct, {ref, _Module, Name}}) ->
    thrift_runtime_record:record_tag(Name).
%% `decode_repr/3` reaches `struct_tag/1` only for map-mode structs, and
%% those are always ref descriptors — an inline descriptor has no
%% representation to mis-decode into.

%% The one representation with an OTP floor plus membership: native
%% records need the `records` module (OTP 29), and a repr outside the
%% axis vocabulary is a caller typo, not a decode condition. Exported
%% for `thrift_runtime_options:codec_options/2`, which validates the
%% decode facade's `repr` option through this same check.

-doc """
Validates a representation axis value.

`record`, `map` and `struct` always exist; `native` additionally needs
the `records` module (OTP 29), and anything else is a `bad_repr` typo.
""".
-spec repr_supported(repr()) -> ok | {error, {unsupported_repr, native} | {bad_repr, repr()}}.
repr_supported(native) ->
    case thrift_runtime_native:supported() of
        true -> ok;
        false -> {error, {unsupported_repr, native}}
    end;
repr_supported(Repr) when Repr =:= record; Repr =:= map; Repr =:= struct ->
    ok;
repr_supported(Repr) ->
    {error, {bad_repr, Repr}}.

-doc """
Reshapes a typed value (record, struct-map or native record, nested
structures included) into `Repr`, without encoding bytes.

`Desc` is the value's type descriptor — a `thrift_runtime_protocol:
type_desc/0` tuple; the value itself needs no identity of its own — a
plain map converts like a struct-map without the `__struct__` key. The
`record` representation of a map-representation or
native-representation struct answers `{error, {no_record, Tag}}` —
there is no record to produce.

A non-descriptor first argument is a programming error, not a data
condition: the call crashes. In particular the removed tag-index map
(the old `TagIndex/0` shape) is not a descriptor and no longer
converts.
""".
-spec convert(thrift_runtime_protocol:type_desc(), term(), repr()) ->
    {ok, term()} | {error, term()}.
convert(Desc, Value, Repr) when is_tuple(Desc) ->
    convert_value(Desc, Value, Repr).

%% The conversion body. The `no_record` error names the value's struct:
%% descriptor callers resolve it from the descriptor lazily (the same
%% rule `decode/3` follows), so a descriptor whose record target never
%% reaches the error — inline and wire-passthrough structs — is never
%% tagged.

-spec convert_value(thrift_runtime_protocol:type_desc(), term(), repr()) ->
    {ok, term()} | {error, term()}.
convert_value(Desc, Value, Repr) ->
    Wire = thrift_runtime_record:to_wire(Desc, Value),
    case Repr of
        record ->
            case thrift_runtime_record:repr_mode(Desc) of
                Record when Record =:= record; Record =:= sum ->
                    from_wire_repr(Desc, Wire, record);
                _ ->
                    {error, {no_record, struct_tag(Desc)}}
            end;
        map ->
            from_wire_repr(Desc, Wire, map);
        struct ->
            from_wire_repr(Desc, Wire, struct);
        native ->
            case thrift_runtime_native:supported() of
                true -> from_wire_repr(Desc, Wire, native);
                false -> {error, {unsupported_repr, native}}
            end
    end.

-doc """
Resolves a protocol axis value to its implementation module.

`binary`, `compact` and `json` are the built-in protocols; a module
name is
accepted after verifying it exports every `thrift_runtime_protocol`
callback.
""".
-spec protocol_module(protocol()) -> {ok, module()} | {error, term()}.
protocol_module(binary) ->
    {ok, thrift_runtime_binary};
protocol_module(compact) ->
    {ok, thrift_runtime_compact};
protocol_module(json) ->
    {ok, thrift_runtime_json};
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
