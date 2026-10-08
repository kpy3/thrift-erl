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

-module(thrift_erl_client).

-moduledoc """
One connection to a Thrift server, as a gen_server.

A deliberately simple client: no automatic reconnection. Any failure —
connect error, socket close, per-call timeout — fails the affected
calls and stops the process, so a supervisor or a pool (poolboy,
pooler, a custom supervisor) sees the death immediately and replaces
the worker. That makes this process safe to use as a pool worker
without extra keep-alive logic.

`call/4` sends a CALL envelope with the function's parameter struct,
then waits for exactly one REPLY. The reply payload is decoded per the
service description: field 0 is the success value, a declared exception
field turns into `{error, {exception, Name, Map}}`, and a
`TApplicationException` into `{error, {application_exception, ...}}`.
`oneway/4` answers as soon as the message is on the wire.

The socket runs in `{active, N}` delivery mode, so a dead peer is
noticed even while the connection is idle. Calls are serialized per
connection (one outstanding request at a time); concurrent callers
queue inside the client and are served in order, matching the classic
Thrift client model.

The generated typed client modules call into this; the same map drives
both:

- `host`, `port` (required);
- `service` — module implementing `thrift_erl_service` (required);
- `transport` — `framed` (default) or `buffered`;
- `protocol` — `binary` (default), or any `thrift_erl_protocol`
  implementation module (see `thrift_erl:protocol_module/1`);
- `timeout` — connect, TLS handshake and per-call timeout, default
  5000 ms;
- `max_frame_size` — framed guard, default 64 MiB;
- `ssl_opts` — a list of `ssl:tls_client_option()`; presence switches
  the connection to TLS (verify the server with `verify_peer` plus
  `cacerts`).
""".

-behaviour(gen_server).

-export([start/1, start_link/1, stop/1, call/4, oneway/4]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0, call_result/0]).

-type options() :: #{
    host := inet:socket_address() | inet:hostname(),
    port := inet:port_number(),
    service := module(),
    transport => thrift_erl_socket:transport(),
    protocol => binary | compact | module(),
    timeout => pos_integer(),
    max_frame_size => pos_integer(),
    ssl_opts => [ssl:tls_client_option()]
}.

-type call_result() ::
    {ok, term()}
    | {error, {exception, binary(), thrift_erl_binary:struct_value()}}
    | {error, {application_exception, binary(), non_neg_integer(), binary()}}
    | {error, term()}.

%% A caller waiting for its request to be sent. Calls additionally
%% wait for the reply once on the wire; oneway requests complete on
%% send.

-record(request, {
    kind :: call | oneway,
    from :: gen_server:from(),
    function :: binary(),
    args :: [term()],
    timeout :: pos_integer() | infinity
}).

%% The request currently on the wire.

-record(pending, {
    from :: gen_server:from(),
    function :: binary(),
    seqid :: non_neg_integer(),
    info :: thrift_erl_service:function_info(),
    timer :: undefined | reference()
}).

-record(state, {
    socket :: thrift_erl_socket:socket(),
    service :: module(),
    service_info :: thrift_erl_service:service_info(),
    protocol :: module(),
    transport :: thrift_erl_socket:transport(),
    timeout :: pos_integer(),
    max_frame_size :: pos_integer(),
    active_n :: pos_integer(),
    seqid = 0 :: non_neg_integer(),
    buffer = <<>> :: binary(),
    pending :: undefined | #pending{},
    queue = [] :: [#request{}]
}).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_MAX_FRAME_SIZE, 64 * 1024 * 1024).
-define(DEFAULT_ACTIVE_N, 100).

-doc """
Connects to the server and links the client to the caller; fails if
the connection cannot be made.
""".
-spec start_link(options()) -> gen_server:start_ret().
start_link(Opts) ->
    %% A failed connect answers {error, Reason} from init and then the
    %% child exits with the same reason; trapping around the start
    %% shields the (non-trapping) caller from that exit race, so it
    %% sees the {error, Reason} answer only.
    process_flag(trap_exit, true),
    Result = gen_server:start_link(?MODULE, Opts, []),
    process_flag(trap_exit, false),
    case Result of
        {ok, Pid} ->
            receive
                {'EXIT', Pid, Reason} -> {error, Reason}
            after 0 ->
                Result
            end;
        {error, _Reason} = Error ->
            receive
                {'EXIT', _Pid, _} -> ok
            after 0 ->
                ok
            end,
            Error
    end.

-doc """
Connects to the server without linking — for owners that monitor
instead, such as pool workers started by a pool library.
""".
-spec start(options()) -> gen_server:start_ret().
start(Opts) ->
    gen_server:start(?MODULE, Opts, []).

-doc "Closes the connection; outstanding calls fail with `{error, closed}`.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-doc """
Calls `Function` with `Args` (declaration order, wire representation)
and waits for a reply.

For `void` functions the success value is `undefined`. Concurrent
callers queue in order; only the head request is on the wire.
""".
-spec call(pid(), binary(), [term()], pos_integer() | infinity) -> call_result().
call(Pid, Function, Args, Timeout) ->
    gen_server:call(Pid, {call, Function, Args, Timeout}, infinity).

-doc "Sends a one-way call; the server never answers.".
-spec oneway(pid(), binary(), [term()], pos_integer() | infinity) -> ok | {error, term()}.
oneway(Pid, Function, Args, Timeout) ->
    gen_server:call(Pid, {oneway, Function, Args, Timeout}, infinity).

%% gen_server callbacks

-doc false.
-spec init(options()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Connect =
        thrift_erl_socket:connect(
            maps:get(host, Opts), maps:get(port, Opts), maps:get(ssl_opts, Opts, undefined), Timeout
        ),
    case {Connect, thrift_erl:protocol_module(maps:get(protocol, Opts, binary))} of
        {{ok, Socket}, {ok, Protocol}} ->
            ActiveN = ?DEFAULT_ACTIVE_N,
            ok = thrift_erl_socket:set_active(Socket, ActiveN),
            Service = maps:get(service, Opts),
            {ok, #state{
                socket = Socket,
                service = Service,
                service_info = Service:service_info(),
                protocol = Protocol,
                transport = maps:get(transport, Opts, framed),
                timeout = Timeout,
                max_frame_size = maps:get(max_frame_size, Opts, ?DEFAULT_MAX_FRAME_SIZE),
                active_n = ActiveN
            }};
        {{error, Reason}, _} ->
            {stop, Reason};
        {_, {error, Reason}} ->
            {stop, {protocol, Reason}}
    end.

-doc false.
-spec handle_call(term(), gen_server:from(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
handle_call({Kind, Function, Args, Timeout}, From, #state{} = State) ->
    Request =
        #request{kind = Kind, from = From, function = Function, args = Args, timeout = Timeout},
    try_dispatch(State#state{queue = State#state.queue ++ [Request]});
handle_call(_Request, From, State) ->
    gen_server:reply(From, {error, unsupported}),
    {noreply, State}.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
handle_info({tcp, Socket, Data}, #state{socket = {tcp, Socket}} = State) ->
    handle_stream(State#state{buffer = <<(State#state.buffer)/binary, Data/binary>>});
handle_info({ssl, Socket, Data}, #state{socket = {ssl, Socket}} = State) ->
    handle_stream(State#state{buffer = <<(State#state.buffer)/binary, Data/binary>>});
handle_info({tcp_passive, Socket}, #state{socket = {tcp, Socket}, active_n = ActiveN} = State) ->
    ok = thrift_erl_socket:set_active({tcp, Socket}, ActiveN),
    {noreply, State};
handle_info({ssl_passive, Socket}, #state{socket = {ssl, Socket}, active_n = ActiveN} = State) ->
    ok = thrift_erl_socket:set_active({ssl, Socket}, ActiveN),
    {noreply, State};
handle_info({tcp_closed, _Socket}, State) ->
    abort(closed, State);
handle_info({tcp_error, _Socket, Reason}, State) ->
    abort(Reason, State);
handle_info(ssl_closed, State) ->
    abort(closed, State);
handle_info({ssl_error, _Socket, Reason}, State) ->
    abort(Reason, State);
%% The reply can never be trusted to stay in sync after a timeout:
%% fail the call and drop the connection.
handle_info(
    {timeout, Timer, call_timer},
    #state{
        pending = #pending{timer = Timer, from = From}
    } = State
) ->
    gen_server:reply(From, {error, timeout}),
    fail_queue(closed, State#state{pending = undefined});
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{socket = Socket} = State) ->
    case State#state.pending of
        #pending{from = From} -> gen_server:reply(From, {error, closed});
        undefined -> ok
    end,
    fail_queue(closed, State),
    thrift_erl_socket:close(Socket),
    ok.

%%--------------------------------------------------------------------
%% Send path
%%--------------------------------------------------------------------

%% Starts the head queued request while no other one is on the wire.

-spec try_dispatch(#state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
try_dispatch(#state{pending = undefined, queue = []} = State) ->
    {noreply, State};
try_dispatch(#state{pending = undefined, queue = [Request | Rest]} = State0) ->
    SeqId = State0#state.seqid + 1,
    case prepare(Request, SeqId, State0) of
        {reply, Reply} ->
            gen_server:reply(Request#request.from, Reply),
            try_dispatch(State0#state{queue = Rest});
        {ok, Message} ->
            dispatch_request(Request, Message, SeqId, State0#state{queue = Rest})
    end;
try_dispatch(State) ->
    {noreply, State}.

-spec dispatch_request(#request{}, iodata(), non_neg_integer(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
dispatch_request(#request{kind = oneway, from = From}, Message, SeqId, State) ->
    case send_message(Message, State) of
        #state{} = Sent ->
            %% Answered as soon as the bytes are out; no reply follows.
            gen_server:reply(From, ok),
            try_dispatch(Sent#state{seqid = SeqId});
        Stop ->
            Stop
    end;
dispatch_request(Request, Message, SeqId, State) ->
    Pending =
        #pending{
            from = Request#request.from,
            function = Request#request.function,
            seqid = SeqId,
            info = request_info(Request, State),
            timer = arm_call_timer(Request)
        },
    case send_message(Message, State#state{seqid = SeqId, pending = Pending}) of
        #state{} = Sent -> {noreply, Sent};
        Stop -> Stop
    end.

%% Builds the full message bytes for the request, or a local reply
%% (unknown function, bad arity, encode failure — the connection stays
%% usable in every one of these cases).

-spec prepare(#request{}, non_neg_integer(), #state{}) -> {ok, iodata()} | {reply, term()}.
prepare(Request, SeqId, #state{} = State) ->
    case State#state.service_info of
        #{Request#request.function := Info} ->
            prepare_args(Request, SeqId, Info, State);
        _ ->
            {reply, {error, unknown_function}}
    end.

-spec prepare_args(#request{}, non_neg_integer(), thrift_erl_service:function_info(), #state{}) ->
    {ok, iodata()} | {reply, term()}.
prepare_args(Request, SeqId, #{params := ParamsDesc}, #state{} = State) ->
    Names = [Name || {_, _, _, Name, _} <- thrift_erl_binary:struct_fields(ParamsDesc)],
    Args = Request#request.args,
    case length(Args) =:= length(Names) of
        true ->
            Values = lists:zip(Names, Args),
            case (State#state.protocol):encode(ParamsDesc, maps:from_list(Values)) of
                {ok, Payload} ->
                    Type =
                        case Request#request.kind of
                            call -> call;
                            oneway -> oneway
                        end,
                    Message = (State#state.protocol):encode_message(
                        Type, Request#request.function, SeqId, Payload
                    ),
                    {ok, Message};
                {error, Reason} ->
                    {reply, {error, Reason}}
            end;
        false ->
            {reply, {error, {bad_arity, Request#request.function, length(Names), length(Args)}}}
    end.

-spec request_info(#request{}, #state{}) -> thrift_erl_service:function_info().
request_info(Request, #state{} = State) ->
    #{Request#request.function := Info} = State#state.service_info,
    Info.

-spec arm_call_timer(#request{}) -> undefined | reference().
arm_call_timer(#request{timeout = infinity}) ->
    undefined;
arm_call_timer(#request{timeout = Timeout, kind = call}) ->
    erlang:start_timer(Timeout, self(), call_timer).

-spec send_message(iodata(), #state{}) -> #state{} | {stop, normal, #state{}}.
send_message(Message, #state{} = State) ->
    Bytes =
        case State#state.transport of
            framed -> [<<(iolist_size(Message)):32/big-unsigned>>, Message];
            buffered -> Message
        end,
    case thrift_erl_socket:send(State#state.socket, Bytes) of
        ok ->
            State;
        {error, Reason} ->
            %% A failed send means the request never went out: fail the
            %% pending call and drop the connection.
            abort(Reason, State)
    end.

%%--------------------------------------------------------------------
%% Receive path
%%--------------------------------------------------------------------

-spec handle_stream(#state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
handle_stream(#state{buffer = Buffer} = State) ->
    case
        thrift_erl_socket:extract_message(
            Buffer, State#state.transport, State#state.protocol, State#state.max_frame_size
        )
    of
        {ok, Message, Leftover} ->
            case handle_message(Message, State#state{buffer = Leftover}) of
                {ok, State1} ->
                    try_dispatch(State1);
                Stop ->
                    Stop
            end;
        more ->
            {noreply, State};
        {error, Reason} ->
            abort(Reason, State)
    end.

%% Consumes one complete message against the pending request. An
%% incoming message with no pending call means the stream desynced.

-spec handle_message(binary(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.
handle_message(_Message, #state{pending = undefined} = State) ->
    {stop, {error, unexpected_message}, State};
handle_message(Message, #state{pending = Pending} = State) ->
    case
        decode_reply(
            Pending#pending.function, Pending#pending.seqid, Pending#pending.info, Message, State
        )
    of
        {ok, CallResult} ->
            cancel_call_timer(Pending#pending.timer),
            gen_server:reply(Pending#pending.from, CallResult),
            {ok, State#state{pending = undefined}};
        {error, Reason} ->
            cancel_call_timer(Pending#pending.timer),
            gen_server:reply(Pending#pending.from, {error, Reason}),
            fail_queue(closed, State#state{pending = undefined})
    end.

%% A complete reply — value, declared exception or
%% TApplicationException — comes back as {ok, CallResult}; anything
%% else breaks the stream.

-spec decode_reply(
    binary(), non_neg_integer(), thrift_erl_service:function_info(), binary(), #state{}
) -> {ok, call_result()} | {error, term()}.
decode_reply(Function, SeqId, Info, Message, #state{} = State) ->
    case (State#state.protocol):decode_message(Message) of
        {ok, reply, Function, SeqId, Tail} ->
            decode_result(Info, Tail, State);
        {ok, exception, _Name, _SeqId, Tail} ->
            case (State#state.protocol):decode_application_exception(Tail) of
                {ok, #{message := Msg, code := Code, name := Name}, _} ->
                    {ok, {error, {application_exception, Msg, Code, Name}}};
                Other ->
                    {error, {application_exception_decode, Other}}
            end;
        {ok, _OtherType, Name, OtherSeqId, _Tail} ->
            {error, {unexpected_reply, Name, OtherSeqId}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Field 0 is success; any declared exception field that appears wins.

-spec decode_result(thrift_erl_service:function_info(), binary(), #state{}) ->
    {ok, call_result()} | {error, term()}.
decode_result(Info, Tail, #state{} = State) ->
    Exceptions = maps:get(exceptions, Info, []),
    ResultDesc = result_desc(Info),
    case (State#state.protocol):decode(ResultDesc, Tail) of
        {ok, Values, _Rest} ->
            case exception_field(Values, Exceptions) of
                {ok, Name, Value} ->
                    {ok, {error, {exception, Name, Value}}};
                none when map_size(Values) =:= 0 ->
                    {ok, {ok, undefined}};
                none ->
                    {ok, {ok, maps:get(<<"success">>, Values)}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% The reply payload descriptor: success field 0 plus every declared
%% exception under its throw-field id. Exception values decode as maps
%% (the generic struct representation).

-spec result_desc(thrift_erl_service:function_info()) -> thrift_erl_binary:type_desc().
result_desc(#{reply := ReplyType} = Info) when ReplyType =/= undefined ->
    {struct, {struct, [{0, default, ReplyType, <<"success">>, undefined} | exception_fields(Info)]}};
result_desc(#{} = Info) ->
    {struct, {struct, exception_fields(Info)}}.

-spec exception_fields(thrift_erl_service:function_info()) -> [thrift_erl_binary:field_desc()].
exception_fields(Info) ->
    maps:get(exceptions, Info, []).

-spec exception_field(map(), [thrift_erl_binary:field_desc()]) ->
    {ok, binary(), thrift_erl_binary:struct_value()} | none.
exception_field(Values, Exceptions) ->
    Found = [
        {exception_name(FieldDesc), Value}
     || FieldDesc = {_, _, {struct, _}, _, _} <- Exceptions,
        Value <- [maps:get(element(4, FieldDesc), Values, none)],
        Value =/= none
    ],
    case Found of
        [{Name, Value} | _] -> {ok, Name, Value};
        [] -> none
    end.

-spec exception_name(thrift_erl_binary:field_desc()) -> binary().
exception_name({_, _, {struct, {ref, _, StructName}}, _, _}) -> StructName;
exception_name({_, _, _, FieldName, _}) -> FieldName.

%%--------------------------------------------------------------------
%% Failure path
%%--------------------------------------------------------------------

%% The stream is broken: the pending call already got its own failure
%% reason; everyone still queued gets closed.

-spec fail_queue(term(), #state{}) -> {stop, normal, #state{}}.
fail_queue(Reason, #state{} = State) ->
    lists:foreach(
        fun(#request{from = From}) -> gen_server:reply(From, {error, Reason}) end,
        State#state.queue
    ),
    {stop, normal, State#state{queue = []}}.

-spec abort(term(), #state{}) -> {stop, normal, #state{}}.
abort(Reason, #state{pending = #pending{from = From, timer = Timer}} = State) ->
    cancel_call_timer(Timer),
    gen_server:reply(From, {error, Reason}),
    fail_queue(closed, State#state{pending = undefined});
abort(_Reason, #state{pending = undefined} = State) ->
    fail_queue(closed, State).

-spec cancel_call_timer(undefined | reference()) -> ok.
cancel_call_timer(undefined) ->
    ok;
cancel_call_timer(Timer) ->
    erlang:cancel_timer(Timer),
    %% The timeout message may already sit in the queue; it must not
    %% hit a stale pending slot.
    receive
        {timeout, Timer, call_timer} -> ok
    after 0 ->
        ok
    end.
