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

-module(thrift_generator_emitter_service).

-moduledoc """
The per-service trio of generated modules: `<prefix>_<svc>_handler.erl`
(the `-callback` behaviour), `<prefix>_<svc>_server.erl` (the
start/stop/port entry points) and `<prefix>_<svc>_client.erl` (one
typed wrapper per IDL function). The name carries the file's
identifier prefix and the snake-cased service name — `Ping` in
`namespace erl ping.api` becomes `ping_api_ping_client` — so
same-named services of different IDL files cannot collide, exactly
like the record tags.

Split out of the core emitter: everything here is about services, while
the core builds the types module and its codecs. The type mapping for
callback specs and the record/naming helpers stay in the core emitter;
the shared form-building vocabulary lives in
`thrift_generator_emitter_syntax`.
""".

-export([service_sources/3]).

-include("thrift_generator.hrl").
-include("thrift_generator_model.hrl").

%% The client's default per-call timeout mirrors the runtime's
%% `thrift_erl_options:connect_timeout` default.
-define(DEFAULT_TIMEOUT, 5000).

%%--------------------------------------------------------------------
%% Service modules
%%--------------------------------------------------------------------

-spec service_sources(#tg_service{}, #tg_module{}, #ectx{}) ->
    [{module(), erl_syntax:forms(), undefined}].
service_sources(Svc, Mod, Ctx) ->
    TypesMod = maps:get(Mod#tg_module.name, Ctx#ectx.type_modules),
    HandlerMod = service_module(Mod, Svc#tg_service.name, handler),
    ServerMod = service_module(Mod, Svc#tg_service.name, server),
    ClientMod = service_module(Mod, Svc#tg_service.name, client),
    [
        {HandlerMod, handler_forms(Svc, Mod, HandlerMod, Ctx), undefined},
        {ServerMod, server_forms(Svc, Mod, TypesMod, ServerMod), undefined},
        {ClientMod, client_forms(Svc, Mod, TypesMod, ServerMod, ClientMod), undefined}
    ].

%% The prefix always exists for loaded files (namespace value or the
%% normalized file base name — the loader guarantees that); hand-built
%% models may carry an empty prefix, the module base name steps in.

-spec service_module(#tg_module{}, binary(), handler | server | client) -> module().
service_module(Mod, Name, Kind) ->
    Prefix =
        case Mod#tg_module.prefix of
            <<>> -> Mod#tg_module.name;
            P -> P
        end,
    Base =
        <<Prefix/binary, "_", (thrift_generator_names:snake(thrift_generator_emitter:sanitize(Name)))/binary>>,
    binary_to_atom(<<Base/binary, (kind_suffix(Kind))/binary>>, utf8).

%% The service's IDL doc comment appended to a generated module doc.

-spec service_doc_suffix(#tg_service{}) -> binary().
service_doc_suffix(Svc) ->
    case Svc#tg_service.doc of
        undefined ->
            <<>>;
        Doc ->
            <<"\n\n", Doc/binary>>
    end.

%% The boundary sentence of the client/handler module docs, worded per
%% the representations the service actually passes: every struct carries
%% its resolved `erl.struct_type' (the `--repr' option injects the
%% choice before the emit), sum unions are tagged tuples whatever the
%% axis says. Services over no structs at all carry no sentence.

-spec repr_text(#tg_service{}, #tg_module{}, string()) -> binary().
repr_text(Svc, Mod, Template) ->
    case repr_names(Svc, Mod) of
        [] ->
            <<>>;
        Reprs ->
            unicode:characters_to_binary(io_lib:format(Template, [repr_noun(Reprs)]))
    end.

%% The distinct representations of the module's structs reachable from
%% the service's parameter, reply and throws types.

-spec repr_names(#tg_service{}, #tg_module{}) -> [record | map | native | sum].
repr_names(Svc, Mod) ->
    ByName = #{S#tg_struct.name => S || S <- Mod#tg_module.structs},
    lists:usort([
        case thrift_generator_emitter:sum_mode(S) of
            true ->
                sum;
            false ->
                thrift_generator_emitter:struct_type(S)
        end
     || Name <- service_struct_names(Svc, Mod),
        S <- [maps:get(Name, ByName)]
    ]).

%% One distinct representation reads concrete; a mix reads neutral.

-spec repr_noun([record | map | native | sum]) -> binary().
repr_noun([record]) ->
    <<"records">>;
repr_noun([map]) ->
    <<"maps">>;
repr_noun([native]) ->
    <<"native records">>;
repr_noun([sum]) ->
    <<"tagged tuples">>;
repr_noun(_) ->
    <<"the representation declared for each struct">>.

-spec kind_suffix(handler | server | client) -> binary().
kind_suffix(handler) ->
    <<"_handler">>;
kind_suffix(server) ->
    <<"_server">>;
kind_suffix(client) ->
    <<"_client">>.

-spec handler_forms(#tg_service{}, #tg_module{}, module(), #ectx{}) -> erl_syntax:forms().
handler_forms(Svc, Mod, HandlerMod, Ctx) ->
    Doc =
        unicode:characters_to_binary([
            io_lib:format(
                "Handler behaviour for the ~ts service. Implement every"
                " callback and pass the module as `handler` when starting"
                " the server.~ts",
                [Svc#tg_service.name, repr_text(Svc, Mod, " Struct arguments arrive as ~ts.")]
            ),
            service_doc_suffix(Svc)
        ]),
    %% Callback specs mention record types for struct-typed params, so
    %% the handler declares the records of every struct the service's
    %% signatures can reach (transitively through struct fields) — and
    %% only those, so generated handlers compile warning-free even when
    %% the IDL declares many unused structs.
    Needed = service_struct_names(Svc, Mod),
    %% Handler specs and record fields name types from the defining
    %% types module — the handler declares no local types itself.
    Ctx1 = Ctx#ectx{qualify = true},
    Records = lists:append([
        thrift_generator_emitter:record_form(S, Mod#tg_module.prefix, Ctx1)
     || S <- Mod#tg_module.structs,
        thrift_generator_emitter:has_record(S),
        lists:member(S#tg_struct.name, Needed)
    ]),
    Callbacks = lists:append([callback_form(F, Ctx1) || F <- Svc#tg_service.functions]),
    thrift_generator_emitter_syntax:header(HandlerMod, Mod#tg_module.path) ++
        thrift_generator_emitter_syntax:moduledoc_form(Doc) ++
        [
            %% Only parameter types reach the -callback specs (the reply
            %% is hidden behind thrift_erl_service:handler_result(),
            %% declared exceptions never appear there), so records
            %% reachable only through replies or throws are unused as
            %% far as the compiler can see.
            thrift_generator_emitter_syntax:nowarn_unused_record_form()
        ] ++
        Records ++
        Callbacks.

%% Names of the module's struct-mode definitions reachable from the
%% service's parameter, reply and throws types.
-spec service_struct_names(#tg_service{}, #tg_module{}) -> [binary()].
service_struct_names(Svc, Mod) ->
    ByName = #{S#tg_struct.name => S || S <- Mod#tg_module.structs},
    Seeds =
        lists:usort([
            Name
         || F <- Svc#tg_service.functions,
            T <- function_types(F),
            Name <- ref_names(T),
            is_map_key(Name, ByName)
        ]),
    expand_structs(Seeds, ByName, #{}).

-spec function_types(#tg_function{}) -> [thrift_type()].
function_types(F) ->
    [T || P <- F#tg_function.params, T <- [P#tg_field.type]] ++
        case F#tg_function.return_type of
            void -> [];
            T -> [T]
        end ++
        [P#tg_field.type || P <- F#tg_function.throws].

-spec ref_names(thrift_type()) -> [binary()].
ref_names({ref, Name, _}) ->
    [Name];
ref_names({list, T, _}) ->
    ref_names(T);
ref_names({set, T, _}) ->
    ref_names(T);
ref_names({map, K, V, _}) ->
    ref_names(K) ++ ref_names(V);
ref_names(_) ->
    [].

-spec expand_structs([binary()], #{binary() => #tg_struct{}}, #{binary() => true}) -> [binary()].
expand_structs([], _ByName, Seen) ->
    maps:keys(Seen);
%% refs name enums and other-module definitions just as freely: only
%% this module's structs are collected
expand_structs([Name | Rest], ByName, Seen) when not is_map_key(Name, ByName) ->
    expand_structs(Rest, ByName, Seen);
expand_structs([Name | Rest], ByName, Seen) ->
    case is_map_key(Name, Seen) of
        true ->
            expand_structs(Rest, ByName, Seen);
        false ->
            FieldRefs = [
                ref_names(F#tg_field.type)
             || {_, S} <- maps:to_list(ByName),
                S#tg_struct.name =:= Name,
                F <- S#tg_struct.fields
            ],
            expand_structs(lists:append(FieldRefs) ++ Rest, ByName, Seen#{Name => true})
    end.

-spec callback_form(#tg_function{}, #ectx{}) -> erl_syntax:forms().
callback_form(F, Ctx) ->
    ParamTypes = [thrift_generator_emitter:erlang_type(Field#tg_field.type, Ctx) || Field <- F#tg_function.params],
    RetType = thrift_generator_emitter_syntax:remote_type(thrift_erl_service, handler_result),
    FunType = thrift_generator_emitter_syntax:fun_type(ParamTypes, RetType),
    thrift_generator_emitter_syntax:doc_form(F#tg_function.doc, callback_doc(F)) ++
        callback_attribute(F#tg_function.name, length(ParamTypes), FunType).

-spec callback_doc(#tg_function{}) -> binary().
callback_doc(F) ->
    Name = F#tg_function.name,
    case F#tg_function.oneway of
        true ->
            unicode:characters_to_binary(
                io_lib:format(
                    "Handler callback for the oneway ~ts: called as"
                    " `Handler:~ts(Args...)` in declaration order; the"
                    " answer is discarded.",
                    [Name, Name]
                )
            );
        false ->
            unicode:characters_to_binary(
                io_lib:format(
                    "Handler callback for ~ts: called as"
                    " `Handler:~ts(Args...)` in declaration order; answers"
                    " a `thrift_erl_service:handler_result()`.",
                    [Name, Name]
                )
            )
    end.

%% -callback Name/Arity :: FunType — the payload mixes a tree with a
%% name/arity pair, so it is assembled by hand rather than abstracted.

-spec callback_attribute(binary(), arity(), erl_syntax:syntaxTree()) -> erl_syntax:forms().
callback_attribute(Name, Arity, FunType) ->
    [{attribute, erl_anno:new(0), callback, {{thrift_generator_emitter_syntax:function_atom(Name), Arity}, [FunType]}}].

-spec server_forms(#tg_service{}, #tg_module{}, module(), module()) -> erl_syntax:forms().
server_forms(Svc, Mod, TypesMod, ServerMod) ->
    Doc =
        unicode:characters_to_binary([
            io_lib:format(
                "Server entry points for the ~ts service. `start_link/1`"
                " takes the same options map as `thrift_erl_server`"
                " (minus `service`).",
                [Svc#tg_service.name]
            ),
            service_doc_suffix(Svc)
        ]),
    V = thrift_generator_emitter_syntax:var_fun(),
    MapUpdate =
        erl_syntax:map_expr(
            V("Opts"),
            [
                %% The plain atom, not ?MODULE: `revert_forms' does not
                %% expand macros.
                thrift_generator_emitter_syntax:map_field(service, thrift_generator_emitter_syntax:abstract(ServerMod)),
                thrift_generator_emitter_syntax:map_field(record_api, thrift_generator_emitter_syntax:abstract(true)),
                thrift_generator_emitter_syntax:map_field(types, thrift_generator_emitter_syntax:abstract(TypesMod))
            ]
        ),
    thrift_generator_emitter_syntax:header(ServerMod, Mod#tg_module.path) ++
        thrift_generator_emitter_syntax:moduledoc_form(Doc) ++
        [thrift_generator_emitter_syntax:attribute(behaviour, thrift_erl_service)] ++
        [
            thrift_generator_emitter_syntax:export_form([{service_info, 0}, {start_link, 1}, {stop, 1}, {port, 1}])
        ] ++
        %% The runtime serves one service: pick it out of the types
        %% module's per-file map.
        thrift_generator_emitter_syntax:fn_form(service_info, [
            erl_syntax:clause([], none, [
                erl_syntax:application(erl_syntax:atom(maps), erl_syntax:atom(get), [
                    thrift_generator_emitter_syntax:abstract(Svc#tg_service.name),
                    thrift_generator_emitter_syntax:application(TypesMod, service_info, [])
                ])
            ])
        ]) ++
        thrift_generator_emitter_syntax:doc_form(
            undefined,
            <<
                "Starts the server supervisor with the given options (the"
                " same map as `thrift_erl_server`, minus `service`)."
            >>
        ) ++
        thrift_generator_emitter_syntax:fn_form(start_link, [
            erl_syntax:clause(
                [V("Opts")], none, [
                    thrift_generator_emitter_syntax:application(thrift_erl_server, start_link, [MapUpdate])
                ]
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(undefined, <<"Stops the server and every connection it accepted.">>) ++
        thrift_generator_emitter_syntax:fn_form(stop, [
            erl_syntax:clause(
                [V("Pid")], none, [thrift_generator_emitter_syntax:application(thrift_erl_server, stop, [V("Pid")])]
            )
        ]) ++
        thrift_generator_emitter_syntax:doc_form(undefined, <<"The port the server listens on.">>) ++
        thrift_generator_emitter_syntax:fn_form(port, [
            erl_syntax:clause(
                [V("Pid")], none, [thrift_generator_emitter_syntax:application(thrift_erl_server, port, [V("Pid")])]
            )
        ]).

-spec client_forms(#tg_service{}, #tg_module{}, module(), module(), module()) -> erl_syntax:forms().
client_forms(Svc, Mod, TypesMod, ServerMod, ClientMod) ->
    Doc =
        unicode:characters_to_binary([
            io_lib:format(
                "Typed client for the ~ts service. `start_link/1` takes the"
                " same options map as `thrift_erl_client` (minus `service`).~ts",
                [
                    Svc#tg_service.name,
                    repr_text(Svc, Mod, " Struct arguments and results are converted to ~ts at the boundary.")
                ]
            ),
            service_doc_suffix(Svc)
        ]),
    ClientFns = [client_fn(F, TypesMod) || F <- Svc#tg_service.functions],
    thrift_generator_emitter_syntax:header(ClientMod, Mod#tg_module.path) ++
        thrift_generator_emitter_syntax:moduledoc_form(Doc) ++
        [
            thrift_generator_emitter_syntax:export_form(
                lists:append([Exports || {Exports, _} <- ClientFns]) ++ [{start_link, 1}, {stop, 1}]
            )
        ] ++
        lists:append([Forms || {_, Forms} <- ClientFns]) ++
        start_link_form(ServerMod) ++
        stop_form().

%% One wrapper pair per function: `Name/N` applies the default timeout,
%% `Name/(N+1)` the call itself. Non-oneway replies come back through
%% `thrift_erl_record:call_result_from_wire`, so records surface here.

-spec client_fn(#tg_function{}, module()) ->
    {[erl_syntax:forms()], [erl_syntax:forms()]}.
client_fn(F, TypesMod) ->
    Name = thrift_generator_emitter_syntax:function_atom(F#tg_function.name),
    NParams = length(F#tg_function.params),
    ShortArgs = [erl_syntax:variable("Client")] ++ param_vars(NParams),
    LongArgs = ShortArgs ++ [erl_syntax:variable("Timeout")],
    ShortCall = erl_syntax:application(
        erl_syntax:atom(Name), ShortArgs ++ [thrift_generator_emitter_syntax:abstract(?DEFAULT_TIMEOUT)]
    ),
    WireArgs =
        erl_syntax:application(
            erl_syntax:atom(thrift_erl_record),
            erl_syntax:atom(args_to_wire),
            [
                thrift_generator_emitter_syntax:application(TypesMod, function_info, [
                    thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                    thrift_generator_emitter_syntax:abstract(params)
                ]),
                erl_syntax:list(param_vars(NParams))
            ]
        ),
    WireName = thrift_generator_emitter_syntax:abstract(F#tg_function.name),
    LongBody =
        case F#tg_function.oneway of
            true ->
                [client_bridge_call(oneway, WireName, WireArgs)];
            false ->
                RawCall = client_bridge_call(call, WireName, WireArgs),
                [
                    erl_syntax:application(
                        erl_syntax:atom(thrift_erl_record),
                        erl_syntax:atom(call_result_from_wire),
                        [
                            thrift_generator_emitter_syntax:application(TypesMod, function_info, [
                                thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                                thrift_generator_emitter_syntax:abstract(reply)
                            ]),
                            thrift_generator_emitter_syntax:application(TypesMod, function_info, [
                                thrift_generator_emitter_syntax:abstract(F#tg_function.name),
                                thrift_generator_emitter_syntax:abstract(exceptions)
                            ]),
                            RawCall
                        ]
                    )
                ]
        end,
    ShortClause = erl_syntax:clause(ShortArgs, none, [ShortCall]),
    LongClause = erl_syntax:clause(LongArgs, none, LongBody),
    Exports = [{Name, NParams + 1}, {Name, NParams + 2}],
    Forms =
        thrift_generator_emitter_syntax:doc_form(F#tg_function.doc, short_client_doc(F)) ++
            spec_form(F, NParams + 1, oneway_ret(F)) ++
            thrift_generator_emitter_syntax:fn_form(Name, [ShortClause]) ++
            thrift_generator_emitter_syntax:doc_form(F#tg_function.doc, long_client_doc(F)) ++
            spec_form(F, NParams + 2, call_ret()) ++
            thrift_generator_emitter_syntax:fn_form(Name, [LongClause]),
    {Exports, Forms}.

%% The long-form wrapper delegates to `thrift_erl_client` either the
%% oneway or the request/response call; both take the same shape.

-spec client_bridge_call(oneway | call, erl_syntax:syntaxTree(), erl_syntax:syntaxTree()) ->
    erl_syntax:syntaxTree().
client_bridge_call(Method, FunName, WireArgs) ->
    erl_syntax:application(
        erl_syntax:atom(thrift_erl_client),
        erl_syntax:atom(Method),
        [
            erl_syntax:variable("Client"),
            FunName,
            WireArgs,
            erl_syntax:variable("Timeout")
        ]
    ).

%% Built-in client method docs; the IDL doc comment of the function
%% (when present) is prepended by doc_form/2.

-spec short_client_doc(#tg_function{}) -> binary().
short_client_doc(F) ->
    Name = F#tg_function.name,
    case F#tg_function.oneway of
        true ->
            unicode:characters_to_binary(
                io_lib:format(
                    "Sends the oneway ~ts; answers `ok` once the bytes are"
                    " on the wire.",
                    [Name]
                )
            );
        false ->
            unicode:characters_to_binary(
                io_lib:format(
                    "Calls ~ts and waits for the reply with the default"
                    " 5000 ms timeout.",
                    [Name]
                )
            )
    end.

-spec long_client_doc(#tg_function{}) -> binary().
long_client_doc(F) ->
    Name = F#tg_function.name,
    case F#tg_function.oneway of
        true ->
            unicode:characters_to_binary(
                io_lib:format("Sends the oneway ~ts, giving up after `Timeout` ms.", [Name])
            );
        false ->
            unicode:characters_to_binary(
                io_lib:format(
                    "Calls ~ts and waits for the reply, failing after"
                    " `Timeout` ms.",
                    [Name]
                )
            )
    end.

-spec param_vars(pos_integer()) -> [erl_syntax:syntaxTree()].
param_vars(N) ->
    [erl_syntax:variable("P" ++ integer_to_list(I)) || I <- lists:seq(1, N)].

-spec spec_form(#tg_function{}, arity(), erl_syntax:syntaxTree()) -> erl_syntax:forms().
spec_form(F, Arity, RetType) ->
    ArgTypes =
        [thrift_generator_emitter_syntax:raw_type(pid)] ++
            lists:duplicate(Arity - 1, thrift_generator_emitter_syntax:raw_type(term)),
    FunType = thrift_generator_emitter_syntax:fun_type(ArgTypes, RetType),
    [
        {attribute, erl_anno:new(0), spec,
            {{thrift_generator_emitter_syntax:function_atom(F#tg_function.name), Arity}, [FunType]}}
    ].

-spec call_ret() -> erl_syntax:syntaxTree().
call_ret() ->
    thrift_generator_emitter_syntax:remote_type(thrift_erl_client, call_result).

%% `ok | {error, term()}` for oneway, `thrift_erl_client:call_result()`
%% for regular calls.

-spec oneway_ret(#tg_function{}) -> erl_syntax:syntaxTree().
oneway_ret(F) ->
    case F#tg_function.oneway of
        true ->
            Anno = erl_anno:new(0),
            thrift_generator_emitter_syntax:ok_error_type(
                Anno, thrift_generator_emitter_syntax:term_type(), thrift_generator_emitter_syntax:error_term_type(Anno)
            );
        false ->
            call_ret()
    end.

-spec start_link_form(module()) -> erl_syntax:forms().
start_link_form(ServerMod) ->
    MapUpdate =
        erl_syntax:map_expr(
            erl_syntax:variable("Opts"),
            [thrift_generator_emitter_syntax:map_field(service, thrift_generator_emitter_syntax:abstract(ServerMod))]
        ),
    thrift_generator_emitter_syntax:doc_form(
        undefined,
        <<
            "Connects to the server and links the client to the caller;"
            " the options map is `thrift_erl_client`'s, minus `service`."
        >>
    ) ++
        thrift_generator_emitter_syntax:fn_form(start_link, [
            erl_syntax:clause(
                [erl_syntax:variable("Opts")],
                none,
                [
                    erl_syntax:application(
                        erl_syntax:atom(thrift_erl_client),
                        erl_syntax:atom(start_link),
                        [MapUpdate]
                    )
                ]
            )
        ]).

-spec stop_form() -> erl_syntax:forms().
stop_form() ->
    thrift_generator_emitter_syntax:doc_form(
        undefined,
        <<
            "Closes the connection; outstanding calls answer"
            " `{error, closed}`."
        >>
    ) ++
        thrift_generator_emitter_syntax:fn_form(stop, [
            erl_syntax:clause(
                [erl_syntax:variable("Pid")],
                none,
                [
                    erl_syntax:application(
                        erl_syntax:atom(thrift_erl_client),
                        erl_syntax:atom(stop),
                        [erl_syntax:variable("Pid")]
                    )
                ]
            )
        ]).
