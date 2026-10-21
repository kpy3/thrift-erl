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

-module(thrift_runtime_native).

-moduledoc """
EEP-79 native records for the representation axis (`thrift_runtime:repr()`
value `native`).

Native records exist from OTP 29 on, while this runtime keeps
`minimum_otp_vsn` on 28, so every reference to the `records` module and
to the `is_record/1` BIF lives behind a `-if(?OTP_RELEASE >= 29)`
conditional: older releases compile the stub branch, where `is_native/1`
answers `false` and the conversions raise `native_records_unsupported`.
The facade turns the gate into `{error, {unsupported_repr, native}}`
before any conversion runs.

The runtime never compiles record definitions: values are minted with
`records:create/4` from the wire field map (all declared fields present,
missing wire fields as `undefined`), stamped with the descriptor's
module and the lowercased struct name — the same tag a tuple record of
that struct carries. Values are created exported, since they are handed
out of the module that decoded them.
""".

-export([supported/0, is_native/1, create/3, fields/1]).

-export_type([native_record/0]).

%% Derived from the running release rather than a literal, so dialyzer
%% sees a plain boolean() and keeps the OTP-28 arms of the facade's
%% `supported()` cases alive on an OTP-29 build.

-doc "Answers whether this OTP carries native records (EEP-79, OTP 29+).".
-spec supported() -> boolean().
supported() ->
    list_to_integer(erlang:system_info(otp_release)) >= 29.

%% The spec-level shape of a native record. `record()' is predefined
%% from OTP 29 on; elvis, which parses the raw source without running
%% the preprocessor, would see both branches and flag an unresolvable
%% `record/0' in the exported specs on an OTP-28 toolchain — hence the
%% exported alias instead of the bare builtin.

-if(?OTP_RELEASE >= 29).

-opaque native_record() :: record().

-doc "Answers whether Term is a native record of any definition.".
-spec is_native(term()) -> boolean().
is_native(Term) ->
    is_record(Term).

-doc """
Creates an exported native record `Module:Name` with the given
`{FieldAtom, Value}` pairs (every declared field, in declaration order).
""".
-spec create(module(), atom(), [{atom(), term()}]) -> native_record().
create(Module, Name, FieldValues) ->
    records:create(Module, Name, FieldValues, #{is_exported => true}).

-doc """
The identity and content of a native record: its module, its name and
the `FieldAtom => Value` map over all its fields.
""".
-spec fields(native_record()) -> {module(), atom(), #{atom() => term()}}.
fields(Record) ->
    Names = records:get_field_names(Record),
    FieldMap = maps:from_list([{Name, records:get(Name, Record)} || Name <- Names]),
    {records:get_module(Record), records:get_name(Record), FieldMap}.

-else.

-opaque native_record() :: term().

-doc "Always false: native records need OTP 29.".
-spec is_native(term()) -> boolean().
%% `supported()', not a literal `false': on an OTP-28 toolchain dialyzer
%% folds a literal into a `false' return type, kills every caller's
%% `true' arm as unmatched and the native wire paths as never-called.
%% `supported()' stays an unfoldable boolean() here and answers false at
%% runtime on this release anyway.
is_native(_Term) ->
    supported().

-doc "Raises: native records cannot be created before OTP 29.".
-spec create(module(), atom(), [{atom(), term()}]) -> no_return().
create(_Module, _Name, _FieldValues) ->
    erlang:error(native_records_unsupported).

-doc "Raises: no native record can exist before OTP 29.".
-spec fields(native_record()) -> no_return().
fields(_Record) ->
    erlang:error(native_records_unsupported).

-endif.
