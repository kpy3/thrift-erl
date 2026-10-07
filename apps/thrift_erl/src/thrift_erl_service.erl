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

-module(thrift_erl_service).

-moduledoc """
Behaviour of a service description module.

The generated `<service>_server` module (or a hand-written one) exports
`service_info/0`, giving the runtime everything it needs to frame
calls: parameter descriptors for decoding, the reply type for encoding
and the declared exceptions.

Handler functions are called as `Handler:Function(Args...)` with
arguments in declaration order. They answer:

- `{ok, Value}` — the reply value (`undefined` for `void` functions);
- `{error, {exception, Name, Map}}` — a declared exception, encoded
  under its throw-field id by name;
- anything else that raises — the runtime answers with
  `TApplicationException` (INTERNAL_ERROR).
""".

-export_type([function_info/0, service_info/0, handler_result/0]).

-type function_info() :: #{
    %% function name as written in the IDL
    name := binary(),
    oneway := boolean(),
    %% params as a full struct type descriptor (ids are the argument ids)
    params := thrift_erl_binary:type_desc(),
    %% reply type descriptor, `void` maps to `undefined`
    reply => thrift_erl_binary:type_desc() | undefined,
    %% declared exceptions as throw-field descriptors
    exceptions => [thrift_erl_binary:field_desc()]
}.

-type service_info() :: #{binary() := function_info()}.

-type handler_result() ::
    {ok, term()}
    | {error, {exception, Name :: binary(), thrift_erl_binary:struct_value()}}.

-doc """
The single callback of the behaviour: returns the service descriptor.
""".
-callback service_info() -> service_info().
