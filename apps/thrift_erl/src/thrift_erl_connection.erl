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

-module(thrift_erl_connection).

-moduledoc """
One server-side connection: read message, dispatch, answer, repeat.

Runs as a gen_server owning the accepted socket in `{active, N}`
delivery mode: incoming bytes arrive as `tcp`/`ssl` messages, complete
messages are split off the buffer by `thrift_erl_socket:extract_message/4`
and dispatched; the socket re-arms itself on `tcp_passive`/`ssl_passive`.
A peer closing the connection is seen as `tcp_closed`/`ssl_closed`
even while idle.

Timeouts: one timer guards the stream between messages (idle with an
empty buffer, or a partial message mid-parse) — when it fires the
connection stops. Handler crashes are contained per call and answered
with `TApplicationException` (INTERNAL_ERROR); anything that breaks
the stream (bad frame, socket error, timeout) closes the connection.

Configuration comes in at creation time as a map — never from the
application environment:

- `socket` (required) — the accepted, already handshaken socket;
- `transport` — `framed` (default), `buffered`, or `http`: a Thrift
  message rides as the body of one HTTP/1.1 POST, answered by one
  response per request over a keep-alive connection. Even a oneway
  gets an (empty) response — HTTP is request/response. `max_frame_size`
  bounds the request body; a request that cannot be parsed is answered
  400 (405 for a non-POST method) before the connection closes, a
  complete request with a bad Thrift payload inside gets 400 and the
  connection continues.
- `protocol` — `binary` (default), or any `thrift_erl_protocol`
  implementation module (see `thrift_erl:protocol_module/1`);
- `max_frame_size` — framed mode guard, default 64 MiB;
- `timeout` / `idle_timeout` — maximum silence between messages,
  default 5000 ms (`idle_timeout` overrides the umbrella);
- `active_n` — `{active, N}` batch size, default 100;
- `record_api` — when true, handler arguments and results are records;
  `types` names the generated types module providing `record_fields/1`.

Exactly one service mode is required:

- `handler` + `service` — single-service mode: `service` implements
  `thrift_erl_service`, `handler` implements it;
- `services` — multiplexed mode: a map from the service name (binary,
  as it appears in the `Service:function` message-name prefix) to
  `#{handler := module(), service := module()}`. Incoming message names
  are routed strictly by that prefix; replies are sent back with the
  plain function name, matching the Apache multiplexed protocol.
""".

-behaviour(gen_server).

-export([start_link/1, start/1, stop/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0]).

-include_lib("kernel/include/logger.hrl").

-type service_entry() :: #{handler := module(), service := module()}.

-type options() :: #{
    socket := thrift_erl_socket:socket(),
    transport => thrift_erl_socket:transport(),
    protocol => binary | compact | module(),
    max_frame_size => pos_integer(),
    %% the umbrella; `idle_timeout` names it specifically
    timeout => pos_integer() | infinity,
    idle_timeout => pos_integer() | infinity,
    active_n => pos_integer(),
    %% when true, handler arguments and results are records; `types`
    %% names the generated types module providing record_fields/1
    record_api => boolean(),
    types => module(),
    handler => module(),
    service => module(),
    services => #{binary() => service_entry()},
    %% the observability handler; see `thrift_erl_events'
    on_event => thrift_erl_events:handler()
}.

%% Handler + descriptor per dispatch key: `<<>>' in single-service
%% mode, the service name in multiplexed mode.

-record(state, {
    socket :: thrift_erl_socket:socket(),
    services :: #{binary() => {module(), thrift_erl_service:service_info()}},
    protocol :: module(),
    transport :: thrift_erl_socket:transport(),
    max_frame_size :: pos_integer(),
    timeout :: pos_integer() | infinity,
    active_n :: pos_integer(),
    record_api :: module() | undefined,
    idle_timer :: undefined | reference(),
    handler :: thrift_erl_events:handler(),
    buffer = <<>> :: binary()
}).

-doc "Starts a linked connection process for an accepted socket.".
-spec start_link(options()) -> gen_server:start_ret().
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-doc """
Starts an unlinked connection process.

The acceptor uses this plus a monitor, so a crashing connection does
not affect the listener.
""".
-spec start(options()) -> gen_server:start_ret().
start(Opts) ->
    gen_server:start(?MODULE, Opts, []).

-doc "Stops the connection (closes the socket).".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%% gen_server callbacks

-doc false.
-spec init(options()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    Timeout = thrift_erl_options:idle_timeout(Opts),
    case {thrift_erl_options:protocol_module(Opts), services(Opts), thrift_erl_options:on_event(Opts)} of
        {{ok, Protocol}, {ok, Services}, {ok, Handler}} ->
            Socket = maps:get(socket, Opts),
            ActiveN = thrift_erl_options:active_n(Opts),
            %% The socket arrives owned by the acceptor and still
            %% passive; it takes over ownership (the acceptor calls
            %% controlling_process) and only then arms active delivery
            %% — see the 'go' handler.
            State0 =
                #state{
                    socket = Socket,
                    services = Services,
                    protocol = Protocol,
                    transport = thrift_erl_options:transport(Opts),
                    max_frame_size = thrift_erl_options:max_frame_size(Opts),
                    timeout = Timeout,
                    active_n = ActiveN,
                    record_api =
                        case maps:get(record_api, Opts, false) of
                            true -> maps:get(types, Opts);
                            false -> undefined
                        end,
                    handler = Handler
                },
            thrift_erl_events:emit(Handler, connection_open, #{peer => peer(Socket)}),
            {ok, State0};
        {{error, Reason}, _, _} ->
            {stop, {protocol, Reason}};
        {_, {error, Reason}, _} ->
            {stop, Reason};
        {_, _, {error, Reason}} ->
            {stop, Reason}
    end.

%% The remote endpoint for the `connection_open' event; a socket whose
%% peer is already gone reports `undefined' rather than failing init.

-spec peer(thrift_erl_socket:socket()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(Socket) ->
    case thrift_erl_socket:peername(Socket) of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    end.

%% Resolves the service-mode options into the dispatch table. A
%% malformed entry (non-binary name, missing modules, unloaded
%% descriptors) stops the connection at init instead of failing later
%% per message.

-spec services(options()) ->
    {ok, #{binary() => {module(), thrift_erl_service:service_info()}}} | {error, term()}.
services(#{services := Map}) when is_map(Map) ->
    try
        {ok, maps:fold(fun service_entry/3, #{}, Map)}
    catch
        error:Reason -> {error, {services, Reason}}
    end;
services(#{handler := Handler, service := Service}) ->
    {ok, #{<<>> => {Handler, Service:service_info()}}};
services(_Opts) ->
    {error, missing_service}.

-spec service_entry(binary(), service_entry(), #{binary() => {module(), term()}}) ->
    #{binary() => {module(), term()}}.
service_entry(Name, #{handler := Handler, service := Service}, Acc) when is_binary(Name) ->
    Acc#{Name => {Handler, Service:service_info()}};
service_entry(Name, _Entry, _Acc) ->
    erlang:error({bad_service_entry, Name}).

-doc false.
-spec handle_call(term(), {pid(), reference()}, #state{}) -> {reply, term(), #state{}}.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, normal | {error, term()}, #state{}}.
%% The acceptor has handed the socket over (controlling_process) and
%% signals the connection to start reading. Data sent before this is
%% buffered by the passive socket, nothing is lost.

handle_info(go, #state{socket = Socket, active_n = ActiveN} = State) ->
    ok = thrift_erl_socket:set_active(Socket, ActiveN),
    {noreply, arm_idle_timer(State)};
%% The acceptor drains: whatever is being processed right now finishes
%% first (this message is only reached when the loop comes back), then
%% the connection exits and closes the socket. Requests the peer sends
%% after the drain began go with it.
handle_info(drain, State) ->
    {stop, normal, State};
handle_info({tcp, Socket, Data}, #state{socket = {tcp, Socket}} = State) ->
    State1 = cancel_idle_timer(State),
    handle_stream(State1#state{buffer = <<(State#state.buffer)/binary, Data/binary>>});
handle_info({ssl, Socket, Data}, #state{socket = {ssl, Socket}} = State) ->
    State1 = cancel_idle_timer(State),
    handle_stream(State1#state{buffer = <<(State#state.buffer)/binary, Data/binary>>});
handle_info({tcp_passive, Socket}, #state{socket = {tcp, Socket}, active_n = ActiveN} = State) ->
    ok = thrift_erl_socket:set_active({tcp, Socket}, ActiveN),
    {noreply, State};
handle_info({ssl_passive, Socket}, #state{socket = {ssl, Socket}, active_n = ActiveN} = State) ->
    ok = thrift_erl_socket:set_active({ssl, Socket}, ActiveN),
    {noreply, State};
handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};
handle_info({tcp_error, _Socket, Reason}, State) ->
    {stop, {error, Reason}, State};
handle_info({ssl_closed, _Socket}, State) ->
    {stop, normal, State};
handle_info({ssl_error, _Socket, Reason}, State) ->
    {stop, {error, Reason}, State};
handle_info({timeout, Timer, idle}, #state{idle_timer = Timer} = State) ->
    %% Same consequence for an idle peer and a stalled partial message:
    %% the stream is no longer trusted.
    {stop, {error, timeout}, State#state{idle_timer = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> ok.
terminate(Reason, #state{socket = Socket, handler = Handler}) ->
    thrift_erl_events:emit(Handler, connection_closed, #{reason => Reason}),
    thrift_erl_socket:close(Socket),
    ok.

%%--------------------------------------------------------------------
%% Stream processing
%%--------------------------------------------------------------------

%% Extracts and dispatches every complete message in the buffer, then
%% re-arms the silence timer.

-spec handle_stream(#state{}) -> {noreply, #state{}} | {stop, normal | {error, term()}, #state{}}.
%% The HTTP direction parses whole requests (the body is the Thrift
%% message); a request that cannot be parsed gets a status code before
%% the connection closes.

handle_stream(#state{buffer = Buffer, transport = http, max_frame_size = Max} = State) ->
    case thrift_erl_http:extract_request(Buffer, Max) of
        {ok, #{body := Message}, Leftover} ->
            handle_stream(process_message(Message, State#state{buffer = Leftover}));
        more ->
            {noreply, arm_idle_timer(State)};
        {error, Reason} ->
            respond_http_error(Reason, State),
            ?LOG_WARNING(#{domain => [thrift], msg => "bad stream", reason => Reason}),
            {stop, {error, Reason}, State}
    end;
handle_stream(#state{buffer = Buffer} = State) ->
    case
        thrift_erl_socket:extract_message(
            Buffer, State#state.transport, State#state.protocol, State#state.max_frame_size
        )
    of
        {ok, Message, Leftover} ->
            handle_stream(
                process_message(Message, State#state{buffer = Leftover})
            );
        more ->
            {noreply, arm_idle_timer(State)};
        {error, Reason} ->
            ?LOG_WARNING(#{domain => [thrift], msg => "bad stream", reason => Reason}),
            {stop, {error, Reason}, State}
    end.

%%--------------------------------------------------------------------
%% Dispatch
%%--------------------------------------------------------------------

-spec process_message(binary(), #state{}) -> #state{}.
process_message(Message, #state{} = State) ->
    case (State#state.protocol):decode_message(Message) of
        {ok, call, Name, SeqId, Tail} ->
            handle_call_message(Name, SeqId, Tail, State);
        {ok, oneway, Name, _SeqId, Tail} ->
            handle_oneway_message(Name, Tail, acknowledge_oneway(State));
        {ok, _Type, Name, _SeqId, _Tail} ->
            ?LOG_WARNING(#{domain => [thrift], msg => "unexpected message type", name => Name}),
            reply_application_exception(
                Name, 0, <<"invalid message type">>, 2, State
            );
        {error, Reason} ->
            ?LOG_WARNING(#{domain => [thrift], msg => "bad message", reason => Reason}),
            case State#state.transport of
                %% HTTP framing still holds: answer and keep the
                %% connection for the next request.
                http -> send_http(400, <<>>, State);
                _ -> State
            end
    end.

-spec handle_call_message(binary(), non_neg_integer(), binary(), #state{}) -> #state{}.
handle_call_message(Name, SeqId, Tail, #state{} = State) ->
    case resolve(Name, State) of
        {ok, Function, Handler, Info} ->
            dispatch(Function, Handler, SeqId, Tail, Info, State);
        error ->
            reply_application_exception(
                Name, SeqId, <<"unknown function">>, 1, State
            )
    end.

%% Splits the wire message name into a service prefix and the function,
%% then finds both in the dispatch table. A multiplexed server requires
%% the prefix to name one of its services. In single-service mode the
%% one service answers plain names — and keeps answering names that
%% carry any `Service:' prefix, so an Apache-style multiplexed client
%% pointed at a non-multiplexed service still finds its functions.

-spec resolve(binary(), #state{}) ->
    {ok, binary(), module(), thrift_erl_service:function_info()} | error.
resolve(WireName, #state{services = Services}) ->
    case binary:split(WireName, <<":">>) of
        [Function] ->
            lookup(<<>>, Function, Services);
        [_Service, Function] when is_map_key(<<>>, Services) ->
            lookup(<<>>, Function, Services);
        [Service, Function] ->
            lookup(Service, Function, Services)
    end.

-spec lookup(binary(), binary(), #{binary() => {module(), thrift_erl_service:service_info()}}) ->
    {ok, binary(), module(), thrift_erl_service:function_info()} | error.
lookup(Service, Function, Services) ->
    case Services of
        #{Service := {Handler, Info}} ->
            case Info of
                %% Narrow to the one function's descriptor: the dispatch
                %% and decode paths work on function_info, not the map.
                #{Function := FunctionInfo} ->
                    {ok, Function, Handler, FunctionInfo};
                _ ->
                    error
            end;
        _ ->
            error
    end.

-spec dispatch(
    binary(), module(), non_neg_integer(), binary(), thrift_erl_service:function_info(), #state{}
) ->
    #state{}.
dispatch(Function, Handler, SeqId, Tail, Info, #state{} = State) ->
    case decode_params(Tail, Info, State) of
        {ok, Args} ->
            Args1 = args_for_handler(Args, Info, State),
            try apply(Handler, function_name(Function), Args1) of
                Result ->
                    case wire_result(Result, Info, State) of
                        {ok, Reply} ->
                            encode_reply(Function, SeqId, Reply, Info, State);
                        {error, {exception, ExceptionName, ExceptionValue}} ->
                            encode_exception_reply(
                                Function, SeqId, ExceptionName, ExceptionValue, Info, State
                            );
                        Other ->
                            ?LOG_WARNING(#{
                                domain => [thrift],
                                msg => "handler returned an unsupported result",
                                name => Function,
                                result => Other
                            }),
                            emit_handler_error(State, Function, {bad_result, Other}),
                            reply_application_exception(
                                Function, SeqId, <<"internal error">>, 6, State
                            )
                    end
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_WARNING(#{
                        domain => [thrift],
                        msg => "handler crashed",
                        name => Function,
                        class => Class,
                        reason => Reason,
                        stack => Stacktrace
                    }),
                    emit_handler_error(State, Function, Reason),
                    reply_application_exception(Function, SeqId, <<"internal error">>, 6, State)
            end;
        {error, Reason} ->
            ?LOG_WARNING(#{
                domain => [thrift],
                msg => "params decoding failed",
                name => Function,
                reason => Reason
            }),
            reply_application_exception(Function, SeqId, <<"protocol error">>, 7, State)
    end.

%% A handler crash or an unsupported handler result. Declared
%% exceptions and protocol errors are answers, not handler errors.

-spec emit_handler_error(#state{}, binary(), term()) -> ok.
emit_handler_error(#state{handler = Handler}, Function, Reason) ->
    thrift_erl_events:emit(Handler, handler_error, #{function => Function, reason => Reason}).

-spec handle_oneway_message(binary(), binary(), #state{}) -> #state{}.
handle_oneway_message(Name, Tail, #state{} = State) ->
    case resolve(Name, State) of
        {ok, Function, Handler, Info} ->
            case decode_params(Tail, Info, State) of
                {ok, Args} ->
                    Args1 = args_for_handler(Args, Info, State),
                    try apply(Handler, function_name(Function), Args1) of
                        _ -> ok
                    catch
                        Class:Reason:Stacktrace ->
                            ?LOG_WARNING(#{
                                domain => [thrift],
                                msg => "oneway handler crashed",
                                name => Function,
                                class => Class,
                                reason => Reason,
                                stack => Stacktrace
                            }),
                            emit_handler_error(State, Function, Reason),
                            ok
                    end,
                    State;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        domain => [thrift],
                        msg => "oneway params decoding failed",
                        name => Function,
                        reason => Reason
                    }),
                    State
            end;
        error ->
            ?LOG_WARNING(#{domain => [thrift], msg => "unknown oneway function", name => Name}),
            State
    end.

-spec decode_params(binary(), thrift_erl_service:function_info(), #state{}) ->
    {ok, [term()]} | {error, term()}.
decode_params(Tail, #{params := ParamsDesc}, #state{} = State) ->
    case (State#state.protocol):decode(ParamsDesc, Tail) of
        {ok, Values, _Rest} ->
            {ok, [
                maps:get(Name, Values, undefined)
             || {_, _, _, Name, _} <- thrift_erl_binary:struct_fields(ParamsDesc)
            ]};
        {error, Reason} ->
            {error, Reason}
    end.

%% Record-API bridging: when enabled, handler arguments arrive as
%% records and results (including declared exception values) go back
%% as records; the wire side stays maps.

-spec args_for_handler([term()], thrift_erl_service:function_info(), #state{}) -> [term()].
args_for_handler(Args, _Info, #state{record_api = undefined}) ->
    Args;
args_for_handler(Args, #{params := ParamsDesc}, #state{}) ->
    thrift_erl_record:args_from_wire(ParamsDesc, Args).

-spec wire_result(term(), thrift_erl_service:function_info(), #state{}) -> term().
wire_result(Result, _Info, #state{record_api = undefined}) ->
    Result;
wire_result(Result, Info, #state{}) ->
    thrift_erl_record:result_to_wire(
        maps:get(reply, Info, undefined), maps:get(exceptions, Info, []), Result
    ).

%% Builds the REPLY payload: field 0 carries the return value when the
%% function is non-void; declared exceptions were already encoded by
%% their own path.

-spec encode_reply(
    binary(), non_neg_integer(), term(), thrift_erl_service:function_info(), #state{}
) -> #state{}.
encode_reply(Name, SeqId, Reply, #{reply := ReplyType} = _Info, #state{} = State) ->
    case
        (State#state.protocol):encode(
            {struct, {struct, [{0, default, ReplyType, <<"success">>, undefined}]}},
            #{<<"success">> => Reply}
        )
    of
        {ok, Payload} ->
            send_message(reply, Name, SeqId, Payload, State);
        {error, Reason} ->
            ?LOG_WARNING(#{
                domain => [thrift],
                msg => "reply encoding failed",
                name => Name,
                reason => Reason
            }),
            reply_application_exception(Name, SeqId, <<"internal error">>, 6, State)
    end;
encode_reply(Name, SeqId, _Reply, #{}, #state{} = State) ->
    %% void function: empty struct payload.
    {ok, Payload} = (State#state.protocol):encode({struct, {struct, []}}, #{}),
    send_message(reply, Name, SeqId, Payload, State).

-spec encode_exception_reply(
    binary(),
    non_neg_integer(),
    binary(),
    thrift_erl_binary:struct_value(),
    thrift_erl_service:function_info(),
    #state{}
) -> #state{}.
encode_exception_reply(Name, SeqId, ExceptionName, ExceptionValue, Info, #state{} = State) ->
    Exceptions = maps:get(exceptions, Info, []),
    %% Handlers name exceptions by their struct name (the IDL-level
    %% identity); the throw-field name is only a wire detail, accepted
    %% as a fallback for descriptors without a struct ref.
    Pred = fun
        ({_, _, {struct, {ref, _, StructName}}, _, _}) ->
            StructName =:= ExceptionName;
        ({_, _, {struct, {struct, _}}, FieldName, _}) ->
            FieldName =:= ExceptionName;
        (_) ->
            false
    end,
    case lists:search(Pred, Exceptions) of
        {value, {_, _, _, FieldName, _} = Field} ->
            %% Encoding the one-field reply struct produces the same
            %% bytes (field header, value, stop) without the connection
            %% knowing protocol wire details.
            PayloadDesc = {struct, {struct, [Field]}},
            case (State#state.protocol):encode(PayloadDesc, #{FieldName => ExceptionValue}) of
                {ok, Payload} ->
                    send_message(reply, Name, SeqId, Payload, State);
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        domain => [thrift],
                        msg => "exception encoding failed",
                        name => Name,
                        exception => ExceptionName,
                        reason => Reason
                    }),
                    reply_application_exception(Name, SeqId, <<"internal error">>, 6, State)
            end;
        false ->
            ?LOG_WARNING(#{
                domain => [thrift],
                msg => "undeclared exception thrown",
                name => Name,
                exception => ExceptionName
            }),
            reply_application_exception(Name, SeqId, <<"internal error">>, 6, State)
    end.

-spec reply_application_exception(
    binary(), non_neg_integer(), binary(), non_neg_integer(), #state{}
) -> #state{}.
reply_application_exception(Name, SeqId, Message, Code, #state{} = State) ->
    case (State#state.protocol):encode_application_exception(Message, Code) of
        {ok, Payload} ->
            send_message(exception, Name, SeqId, Payload, State);
        {error, _} ->
            State
    end.

-spec send_message(
    thrift_erl_binary:message_type(), binary(), non_neg_integer(), iodata(), #state{}
) -> #state{}.
send_message(Type, Name, SeqId, Payload, #state{} = State) ->
    Message = (State#state.protocol):encode_message(Type, Name, SeqId, Payload),
    Bytes = thrift_erl_transport:server_frame(State#state.transport, Message),
    case thrift_erl_socket:send(State#state.socket, Bytes) of
        ok ->
            State;
        {error, Reason} ->
            ?LOG_WARNING(#{domain => [thrift], msg => "send failed", reason => Reason}),
            State
    end.

%% HTTP is request/response even where Thrift is not: oneways and
%% undecodable messages still owe the client a response.

-spec acknowledge_oneway(#state{}) -> #state{}.
acknowledge_oneway(#state{transport = http} = State) ->
    send_http(200, <<>>, State);
acknowledge_oneway(State) ->
    State.

-spec respond_http_error(term(), #state{}) -> ok.
respond_http_error(not_post, #state{} = State) ->
    _ = send_http(405, <<>>, State),
    ok;
respond_http_error(_, #state{} = State) ->
    _ = send_http(400, <<>>, State),
    ok.

-spec send_http(200 | 400 | 405, iodata(), #state{}) -> #state{}.
send_http(Code, Body, #state{} = State) ->
    case thrift_erl_socket:send(State#state.socket, thrift_erl_http:response(Code, [], Body)) of
        ok ->
            State;
        {error, Reason} ->
            ?LOG_WARNING(#{domain => [thrift], msg => "send failed", reason => Reason}),
            State
    end.

-spec function_name(binary()) -> atom().
%% Handler modules are compiled and loaded before traffic arrives, so
%% every real function name already exists as an atom; refusing to mint
%% new ones keeps hostile message names from growing the atom table.
%% The badarg for unknown names is caught by the dispatch try/catch.
function_name(Name) ->
    binary_to_existing_atom(Name, utf8).

%%--------------------------------------------------------------------
%% Timers and active mode
%%--------------------------------------------------------------------

%% One timer guards the stream whether it is idle (empty buffer) or
%% mid-message.

-spec arm_idle_timer(#state{}) -> #state{}.
arm_idle_timer(#state{timeout = infinity} = State) ->
    State;
arm_idle_timer(#state{idle_timer = undefined} = State) ->
    State#state{idle_timer = erlang:start_timer(State#state.timeout, self(), idle)};
arm_idle_timer(State) ->
    State.

-spec cancel_idle_timer(#state{}) -> #state{}.
cancel_idle_timer(#state{idle_timer = undefined} = State) ->
    State;
cancel_idle_timer(#state{idle_timer = Timer} = State) ->
    erlang:cancel_timer(Timer),
    drain_timer(Timer),
    State#state{idle_timer = undefined}.

%% The timeout message may already sit in the queue when data arrives;
%% it must not kill a healthy connection.

-spec drain_timer(reference()) -> ok.
drain_timer(Timer) ->
    receive
        {timeout, Timer, idle} -> ok
    after 0 ->
        ok
    end.
