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

-module(thrift_erl_protocol).

-moduledoc """
Wire protocol behaviour: value and message codecs as pure functions.

A protocol module encodes and decodes values described by the same
type descriptors the generated introspection functions return
(`struct_info/1`, `enum_info/1`, `function_info/2`). Decoding consumes
a binary and returns the remaining bytes, so callers can stream;
`more` marks a truncated but otherwise valid input.

`thrift_erl_binary` and `thrift_erl_compact` implement this behaviour.
Any other module passed as a `thrift_erl:protocol()` — to the facade,
the client or the server — must export every callback with these exact
shapes.

The module also hosts what the implementations share:

- the descriptor **type vocabulary** (`type_desc()`, `field_desc()`,
  `message_type()`, ...): the behaviour owns the contract, so the
  callbacks are typed through it; `thrift_erl_binary` re-exports the
  names for the existing call sites;
- the `TMessageType` ids of the message envelope and the
  `TApplicationException` descriptor with its code-to-name table, plus
  the shared encode/decode of that exception payload;
- cold-path helpers the three implementations would otherwise carry
  three copies of: enum member conversion, required-field bookkeeping,
  the message-type table, struct resolution through `struct_info/1`
  with the schema cache, and the per-process memo over inline
  descriptors.

Hot-path pieces stay in the implementations on purpose: the per-type
codecs, the skip functions, varint/zigzag and the per-field/per-scalar
helpers work on wire shapes only they understand.
""".

-export([
    message_type_id/1,
    application_exception_desc/0,
    application_exception_name/1,
    encode_application_exception/3,
    decode_application_exception/2,
    message_type/1,
    enum_to_int/2,
    enum_from_int/2,
    all_present/2,
    struct_fields/1,
    resolve_struct/4,
    memo_compiled/5
]).

-export_type([
    protocol/0,
    base_type/0,
    type_desc/0,
    field_desc/0,
    struct_desc/0,
    enum_desc/0,
    struct_value/0,
    message_type/0,
    application_exception/0,
    decode_result/1
]).

%% Named protocols known to `thrift_erl:protocol_module/1`; a custom
%% implementation is passed as a module name instead.
-type protocol() :: binary | compact | json.

-doc "Encodes `Value` as `Type`, or fails with a tagged error.".
-callback encode(type_desc(), term()) -> {ok, iodata()} | {error, term()}.

-doc """
Decodes one value of `Type` from the front of `Binary`; the rest comes
back, `more` marks a valid but truncated input.
""".
-callback decode(type_desc(), binary()) ->
    decode_result(term()).

-doc "Wraps an already-encoded payload into a message envelope.".
-callback encode_message(
    message_type(),
    Name :: binary(),
    SeqId :: non_neg_integer(),
    Payload :: iodata()
) -> iodata().

-doc """
Decodes a message envelope from the front of `Binary`; `more` marks a
truncated one.
""".
-callback decode_message(binary()) ->
    {ok, message_type(), binary(), non_neg_integer(), binary()}
    | more
    | {error, term()}.

-doc "Encodes a `TApplicationException` payload.".
-callback encode_application_exception(Message :: binary(), Code :: non_neg_integer()) ->
    {ok, iodata()} | {error, term()}.

-doc "Decodes a `TApplicationException` payload.".
-callback decode_application_exception(binary()) ->
    decode_result(application_exception()).

%% TMessageType ids shared by the binary envelope and the compact
%% envelope (they travel in different bit layouts, the numbers are the
%% same).
%%
%% The mapping is total over message_type(): an unknown value cannot
%% reach it — callers take message_type() from their own types.

-spec message_type_id(message_type()) -> non_neg_integer().
message_type_id(call) -> 1;
message_type_id(reply) -> 2;
message_type_id(exception) -> 3;
message_type_id(oneway) -> 4.

-spec application_exception_desc() -> struct_desc().
application_exception_desc() ->
    {exception, [
        {1, default, {base, string}, <<"message">>, undefined},
        {2, default, {base, i32}, <<"code">>, undefined}
    ]}.

-spec application_exception_name(non_neg_integer()) -> binary().
application_exception_name(0) -> <<"UNKNOWN">>;
application_exception_name(1) -> <<"UNKNOWN_METHOD">>;
application_exception_name(2) -> <<"INVALID_MESSAGE_TYPE">>;
application_exception_name(3) -> <<"WRONG_METHOD_NAME">>;
application_exception_name(4) -> <<"BAD_SEQUENCE_ID">>;
application_exception_name(5) -> <<"MISSING_RESULT">>;
application_exception_name(6) -> <<"INTERNAL_ERROR">>;
application_exception_name(7) -> <<"PROTOCOL_ERROR">>;
application_exception_name(_) -> <<"UNKNOWN">>.

%%--------------------------------------------------------------------
%% Descriptor vocabulary
%%--------------------------------------------------------------------
%%
%% The contract the behaviour and every generated introspection surface
%% speak. `thrift_erl_binary` re-exports these names for the existing
%% call sites; the compiled descriptors (`c_type()`, `k_type()`,
%% `j_type()`) stay inside their implementations — no other module may
%% depend on them.

-type base_type() :: bool | i8 | i16 | i32 | i64 | double | string | binary | uuid.

-type requiredness() :: required | optional | default.

-type enum_desc() :: [{integer(), atom()}].

%% A struct descriptor is either the full `{Kind, Fields}` tuple or a
%% `{ref, Module, Name}` resolved through `Module:struct_info/1` — the
%% indirection keeps recursive descriptors finite.

-type struct_desc() :: {struct | union | exception, [field_desc()]} | {ref, module(), binary()}.

-type field_desc() :: {
    Id :: integer(),
    requiredness(),
    type_desc(),
    Name :: binary(),
    Default :: term()
}.

-type type_desc() ::
    {base, base_type()}
    | {enum, enum_desc()}
    | {list, type_desc()}
    | {set, type_desc()}
    | {set, type_desc(), set_impl()}
    | {map, type_desc(), type_desc()}
    | {struct, struct_desc()}.

%% The in-process representation a decoded set is built into. `list`
%% keeps the wire list as is; `sets`/`ordset` name the stdlib collection
%% the representation layer (`thrift_erl_record`) builds from it. This
%% vocabulary is wire-shaped: codecs encode and decode lists regardless;
%% the third element only has to be tolerated so generated descriptors
%% pass through.

-type set_impl() :: list | sets | ordset.

%% Generic struct representation: binary field names to values.

-type struct_value() :: #{binary() := term()}.

-type message_type() :: call | reply | exception | oneway.

-type application_exception() :: #{
    message := binary(),
    code := non_neg_integer(),
    name := binary()
}.

-type decode_result(Value) ::
    {ok, Value, binary()}
    | more
    | {error, term()}.

%%--------------------------------------------------------------------
%% Shared implementations
%%--------------------------------------------------------------------
%%
%% Cold-path code the three built-in protocols would otherwise carry as
%% verbatim copies. Parameterized by the implementing module so every
%% protocol keeps its own wire codec, schema cache identity and process
%% dictionary entry.

%% TMessageType table: the numbers are the same in every envelope (the
%% bit layouts differ). Total over message_type() — an unknown value
%% cannot reach it.

-spec message_type(non_neg_integer()) -> {ok, message_type()} | error.
message_type(1) -> {ok, call};
message_type(2) -> {ok, reply};
message_type(3) -> {ok, exception};
message_type(4) -> {ok, oneway};
message_type(_) -> error.

%% Enum member conversion: atoms map through the declared table,
%% integers pass through on the way out.

-spec enum_to_int(enum_desc(), atom() | integer()) -> {ok, integer()} | error.
enum_to_int(Desc, V) when is_atom(V) ->
    case lists:keyfind(V, 2, Desc) of
        {Int, V} -> {ok, Int};
        false -> error
    end;
enum_to_int(_Desc, V) when is_integer(V) ->
    {ok, V}.

-spec enum_from_int(enum_desc(), integer()) -> {ok, atom()} | error.
enum_from_int(Desc, Int) ->
    case lists:keyfind(Int, 1, Desc) of
        {Int, Atom} -> {ok, Atom};
        false -> error
    end.

%% Required-field bookkeeping over the wire-named struct map: every
%% name still in `Required` must be present.

-spec all_present([binary()], struct_value()) -> boolean().
all_present([], _Map) ->
    true;
all_present([Name | Rest], Map) ->
    case Map of
        #{Name := _} -> all_present(Rest, Map);
        #{} -> false
    end.

%% The fields of a struct descriptor, resolving a ref through the
%% descriptor module's `struct_info/1`.

-spec struct_fields(type_desc()) -> [field_desc()].
struct_fields({struct, {ref, Module, Name}}) ->
    {_, Fields} = Module:struct_info(Name),
    Fields;
struct_fields({struct, {_Kind, Fields}}) ->
    Fields.

%% The shared shape of the application-exception callbacks: the payload
%% is the ordinary struct `application_exception_desc/0` describes, so
%% both directions reduce to the module's own value codec.

-spec encode_application_exception(module(), binary(), non_neg_integer()) ->
    {ok, iodata()} | {error, term()}.
encode_application_exception(Mod, Message, Code) ->
    Mod:encode(
        {struct, application_exception_desc()},
        #{<<"message">> => Message, <<"code">> => Code}
    ).

-spec decode_application_exception(module(), binary()) ->
    decode_result(application_exception()).
decode_application_exception(Mod, Bin) ->
    case Mod:decode({struct, application_exception_desc()}, Bin) of
        {ok, #{<<"message">> := Message} = Map, Rest} ->
            {ok, application_exception(Message, Map), Rest};
        {ok, Map, Rest} ->
            {ok, application_exception(<<>>, Map), Rest};
        Other ->
            Other
    end.

-spec application_exception(binary(), struct_value()) -> application_exception().
application_exception(Message, Map) ->
    Code = maps:get(<<"code">>, Map, 0),
    #{
        message => Message,
        code => Code,
        name => application_exception_name(Code)
    }.

%% Struct resolution through `Module:struct_info/1` with the schema
%% cache: one `persistent_term` entry per protocol module and struct
%% (the compiled shapes are protocol-specific, so the keys must not
%% collide). `Compile` builds the protocol's own compiled schema.

-spec resolve_struct(
    module(),
    module(),
    binary(),
    fun((struct | union | exception, [field_desc()]) -> Compiled)
) ->
    {ok, Compiled} | error.
resolve_struct(Mod, Module, Name, Compile) ->
    Key = {Mod, schema, Module, Name},
    case persistent_term:get(Key, error) of
        error ->
            case Module:struct_info(Name) of
                {Kind, Fields} when is_atom(Kind), is_list(Fields) ->
                    Compiled = Compile(Kind, Fields),
                    persistent_term:put(Key, Compiled),
                    {ok, Compiled};
                error ->
                    error
            end;
        Compiled ->
            {ok, Compiled}
    end.

%% The per-process memo over inline `{Kind, Fields}` descriptors
%% (params structs of `function_info/2` are literals, so a hit is
%% pointer equality): a miss compiles into a capped list. `Mod`
%% namespaces the process-dictionary entry per protocol; `Key` is the
%% memo entry key (the protocol's own descriptor shape).

-define(MEMO_LIMIT, 8).

-spec memo_compiled(
    module(),
    term(),
    struct | union | exception,
    [field_desc()],
    fun((struct | union | exception, [field_desc()]) -> Compiled)
) ->
    Compiled.
memo_compiled(Mod, Key, Kind, Fields, Compile) ->
    DictKey = {Mod, compiled_structs},
    case erlang:get(DictKey) of
        undefined ->
            Compiled = Compile(Kind, Fields),
            erlang:put(DictKey, [{Key, Compiled}]),
            Compiled;
        Entries when is_list(Entries) ->
            case lists:keyfind(Key, 1, Entries) of
                {_Key, Compiled} ->
                    Compiled;
                false ->
                    Compiled = Compile(Kind, Fields),
                    erlang:put(DictKey, lists:sublist([{Key, Compiled} | Entries], ?MEMO_LIMIT)),
                    Compiled
            end;
        _ ->
            Compiled = Compile(Kind, Fields),
            erlang:put(DictKey, [{Key, Compiled}]),
            Compiled
    end.
