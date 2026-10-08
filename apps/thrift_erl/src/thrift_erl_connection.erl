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
delivery mode: incoming bytes arrive as `tcp` messages, complete
messages are split off the buffer by `thrift_erl_socket:extract_message/4`
and dispatched; the socket re-arms itself on `tcp_passive`. A peer
closing the connection is seen as `tcp_closed` even while idle.

Timeouts: one timer guards the stream between messages (idle with an
empty buffer, or a partial message mid-parse) — when it fires the
connection stops. Handler crashes are contained per call and answered
with `TApplicationException` (INTERNAL_ERROR); anything that breaks
the stream (bad frame, socket error, timeout) closes the connection.

Configuration comes in at creation time as a map — never from the
application environment:

- `handler` (required) — module implementing the service;
- `service` (required) — module implementing `thrift_erl_service`;
- `socket` (required) — the accepted socket;
- `transport` — `framed` (default) or `buffered`;
- `protocol` — `binary` (default), or any `thrift_erl_protocol`
  implementation module (see `thrift_erl:protocol_module/1`);
- `max_frame_size` — framed mode guard, default 64 MiB;
- `timeout` — maximum silence between messages, default 5000 ms;
- `active_n` — `{active, N}` batch size, default 100.
""".

-behaviour(gen_server).

-export([start_link/1, start/1, stop/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0]).

-include_lib("kernel/include/logger.hrl").

-type options() :: #{
    socket := gen_tcp:socket(),
    handler := module(),
    service := module(),
    transport => thrift_erl_socket:transport(),
    protocol => binary | compact | module(),
    max_frame_size => pos_integer(),
    timeout => pos_integer(),
    active_n => pos_integer(),
    %% when true, handler arguments and results are records; `types`
    %% names the generated types module providing record_fields/1
    record_api => boolean(),
    types => module()
}.

-record(state, {
    socket :: gen_tcp:socket(),
    handler :: module(),
    service :: module(),
    service_info :: thrift_erl_service:service_info(),
    protocol :: module(),
    transport :: thrift_erl_socket:transport(),
    max_frame_size :: pos_integer(),
    timeout :: pos_integer() | infinity,
    active_n :: pos_integer(),
    record_api :: module() | undefined,
    idle_timer :: undefined | reference(),
    buffer = <<>> :: binary()
}).

-define(DEFAULT_MAX_FRAME_SIZE, 64 * 1024 * 1024).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_ACTIVE_N, 100).

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
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    case thrift_erl:protocol_module(maps:get(protocol, Opts, binary)) of
        {ok, Protocol} ->
            Socket = maps:get(socket, Opts),
            ActiveN = maps:get(active_n, Opts, ?DEFAULT_ACTIVE_N),
            %% The socket arrives owned by the acceptor and still
            %% passive; it takes over ownership (the acceptor calls
            %% controlling_process) and only then arms active delivery
            %% — see the 'go' handler.
            State0 =
                #state{
                    socket = Socket,
                    handler = maps:get(handler, Opts),
                    service = maps:get(service, Opts),
                    service_info = (maps:get(service, Opts)):service_info(),
                    protocol = Protocol,
                    transport = maps:get(transport, Opts, framed),
                    max_frame_size = maps:get(max_frame_size, Opts, ?DEFAULT_MAX_FRAME_SIZE),
                    timeout = Timeout,
                    active_n = ActiveN,
                    record_api =
                        case maps:get(record_api, Opts, false) of
                            true -> maps:get(types, Opts);
                            false -> undefined
                        end
                },
            {ok, State0};
        {error, Reason} ->
            {stop, {protocol, Reason}}
    end.

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
    ok = arm_active(Socket, ActiveN),
    {noreply, arm_idle_timer(State)};
handle_info({tcp, Socket, Data}, #state{socket = Socket} = State) ->
    State1 = cancel_idle_timer(State),
    handle_stream(State1#state{buffer = <<(State#state.buffer)/binary, Data/binary>>});
handle_info({tcp_passive, Socket}, #state{socket = Socket} = State) ->
    ok = arm_active(Socket, State#state.active_n),
    {noreply, State};
handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};
handle_info({tcp_error, _Socket, Reason}, State) ->
    {stop, {error, Reason}, State};
handle_info({timeout, Timer, idle}, #state{idle_timer = Timer} = State) ->
    %% Same consequence for an idle peer and a stalled partial message:
    %% the stream is no longer trusted.
    {stop, {error, timeout}, State#state{idle_timer = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{socket = Socket}) ->
    gen_tcp:close(Socket),
    ok.

%%--------------------------------------------------------------------
%% Stream processing
%%--------------------------------------------------------------------

%% Extracts and dispatches every complete message in the buffer, then
%% re-arms the silence timer.

-spec handle_stream(#state{}) -> {noreply, #state{}} | {stop, normal | {error, term()}, #state{}}.
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
            handle_oneway_message(Name, Tail, State);
        {ok, _Type, Name, _SeqId, _Tail} ->
            ?LOG_WARNING(#{domain => [thrift], msg => "unexpected message type", name => Name}),
            reply_application_exception(
                Name, 0, <<"invalid message type">>, 2, State
            );
        {error, Reason} ->
            ?LOG_WARNING(#{domain => [thrift], msg => "bad message", reason => Reason}),
            State
    end.

-spec handle_call_message(binary(), non_neg_integer(), binary(), #state{}) -> #state{}.
handle_call_message(Name, SeqId, Tail, #state{} = State) ->
    case State#state.service_info of
        #{Name := Info} ->
            dispatch(Name, SeqId, Tail, Info, State);
        _ ->
            reply_application_exception(
                Name, SeqId, <<"unknown function">>, 1, State
            )
    end.

-spec dispatch(binary(), non_neg_integer(), binary(), thrift_erl_service:function_info(), #state{}) ->
    #state{}.
dispatch(Name, SeqId, Tail, Info, #state{} = State) ->
    case decode_params(Tail, Info, State) of
        {ok, Args} ->
            Args1 = args_for_handler(Args, Info, State),
            try apply(State#state.handler, function_name(Name), Args1) of
                Result ->
                    case wire_result(Result, Info, State) of
                        {ok, Reply} ->
                            encode_reply(Name, SeqId, Reply, Info, State);
                        {error, {exception, ExceptionName, ExceptionValue}} ->
                            encode_exception_reply(
                                Name, SeqId, ExceptionName, ExceptionValue, Info, State
                            );
                        Other ->
                            ?LOG_WARNING(#{
                                domain => [thrift],
                                msg => "handler returned an unsupported result",
                                name => Name,
                                result => Other
                            }),
                            reply_application_exception(Name, SeqId, <<"internal error">>, 6, State)
                    end
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_WARNING(#{
                        domain => [thrift],
                        msg => "handler crashed",
                        name => Name,
                        class => Class,
                        reason => Reason,
                        stack => Stacktrace
                    }),
                    reply_application_exception(Name, SeqId, <<"internal error">>, 6, State)
            end;
        {error, Reason} ->
            ?LOG_WARNING(#{
                domain => [thrift],
                msg => "params decoding failed",
                name => Name,
                reason => Reason
            }),
            reply_application_exception(Name, SeqId, <<"protocol error">>, 7, State)
    end.

-spec handle_oneway_message(binary(), binary(), #state{}) -> #state{}.
handle_oneway_message(Name, Tail, #state{} = State) ->
    case State#state.service_info of
        #{Name := Info} ->
            case decode_params(Tail, Info, State) of
                {ok, Args} ->
                    Args1 = args_for_handler(Args, Info, State),
                    try apply(State#state.handler, function_name(Name), Args1) of
                        _ -> ok
                    catch
                        Class:Reason:Stacktrace ->
                            ?LOG_WARNING(#{
                                domain => [thrift],
                                msg => "oneway handler crashed",
                                name => Name,
                                class => Class,
                                reason => Reason,
                                stack => Stacktrace
                            }),
                            ok
                    end,
                    State;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        domain => [thrift],
                        msg => "oneway params decoding failed",
                        name => Name,
                        reason => Reason
                    }),
                    State
            end;
        _ ->
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
            %% Encoding the one-field reply struct produces exactly the
            %% old hand-assembled bytes (field header, value, stop)
            %% without the connection knowing protocol wire details.
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
    Bytes =
        case State#state.transport of
            framed -> [<<(iolist_size(Message)):32/big-unsigned>>, Message];
            buffered -> Message
        end,
    case thrift_erl_socket:send(State#state.socket, Bytes) of
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
%% mid-message: the receive-timeout semantics of the old passive loop.

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

-spec arm_active(gen_tcp:socket(), pos_integer()) -> ok.
arm_active(Socket, ActiveN) ->
    ok = inet:setopts(Socket, [{active, ActiveN}]),
    ok.
