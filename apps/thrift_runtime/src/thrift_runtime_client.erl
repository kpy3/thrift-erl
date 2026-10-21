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

-module(thrift_runtime_client).

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
field turns into the wire-level `{error, {exception, Name, Map}}`
(generated clients convert it to `{error, {exception, Value}}` in the
value's representation), and a
`TApplicationException` into `{error, {application_exception, ...}}`.
`oneway/4` answers as soon as the message is on the wire.

The socket runs in `{active, N}` delivery mode, so a dead peer is
noticed even while the connection is idle. Calls are serialized per
connection (one outstanding request at a time); concurrent callers
queue inside the client and are served in order, matching the classic
Thrift client model.

Pool owners read the per-worker counters with `get_stats/1`
(`#{calls_ok, calls_failed}`; `get_and_reset_stats/1` zeroes them) —
the same accounting the `thrift_runtime_reconnecting_client` wrapper
reports, minus the connection axis a single-connection client does not
have.

The generated typed client modules call into this; the same map drives
both:

- `host`, `port` (required);
- `service` — module implementing `thrift_runtime_service` (required);
- `transport` — `framed` (default), `buffered`, or `http`: each call
  POSTs one Thrift message to `http_path` (default `"/"`) over a
  keep-alive connection and waits for the response whose body is the
  reply. A oneway waits for the (empty) response too — HTTP is
  request/response. `max_frame_size` bounds the response body; a
  non-200 status fails the call with `{error, {http_status, Code}}`;
- `protocol` — `binary` (default), or any `thrift_runtime_protocol`
  implementation module (see `thrift_runtime:protocol_module/1`);
- `timeout` / `connect_timeout` — the connect and TLS handshake wait,
  default 5000 ms (`connect_timeout` overrides the umbrella; per-call
  timeouts ride the `call/4` argument);
- `max_frame_size` — framed guard and HTTP body bound, default 64 MiB;
- `ssl_opts` — a list of `ssl:tls_client_option()`; presence switches
  the connection to TLS (verify the server with `verify_peer` plus
  `cacerts`);
- `multiplex` — the service name of a multiplexed server: outgoing
  message names are prefixed `<<"Service:function">>` (the reply keeps
  the plain function name, so nothing else changes). Only the name on
  the wire is touched; pass the same plain function names to
  `call/4`/`oneway/4`;
- `on_event` — an observability callback (`undefined` by default): a
  1-arity fun or `{M, F, A}` receiving one event map per caller-facing
  answer — `call_ok` / `call_error`, the same accounting
  `get_stats/1` reports; see `thrift_runtime_events`.
""".

-behaviour(gen_server).

-export([start/1, start_link/1, stop/1, call/4, oneway/4, get_stats/1, get_and_reset_stats/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0, call_result/0, stats/0]).

-type options() :: #{
    host := inet:socket_address() | inet:hostname(),
    port := inet:port_number(),
    service := module(),
    transport => thrift_runtime_socket:transport(),
    protocol => binary | compact | module(),
    timeout => pos_integer(),
    max_frame_size => pos_integer(),
    http_path => binary(),
    ssl_opts => [ssl:tls_client_option()],
    multiplex => binary(),
    %% the `{active, N}` delivery batch size, default 100
    active_n => pos_integer(),
    %% how many calls may wait while another is on the wire; `infinity`
    %% (the default) keeps the classic unbounded queue
    max_queue_depth => pos_integer() | infinity,
    %% the observability handler; see `thrift_runtime_events'
    on_event => thrift_runtime_events:handler()
}.

-type call_result() ::
    {ok, term()}
    %% wire level: the exception carries its name; after
    %% `thrift_runtime_record:call_result_from_wire/3' the value alone
    %% remains — its representation identifies the exception.
    | {error, {exception, binary(), thrift_runtime_binary:struct_value()}}
    | {error, {exception, thrift_runtime_binary:struct_value()}}
    | {error, {application_exception, binary(), non_neg_integer(), binary()}}
    | {error, term()}.

-type stats() :: #{
    calls_ok := non_neg_integer(),
    calls_failed := non_neg_integer()
}.

%% A caller waiting for its request to be sent. Calls additionally
%% wait for the reply once on the wire; oneway requests complete on
%% send.

-record(request, {
    kind :: call | oneway,
    from :: gen_server:from(),
    function :: binary(),
    args :: [term()],
    %% the deadline covers the queue wait and the wire round-trip: the
    %% timer is armed at enqueue time, not when the request reaches the
    %% wire, so a call stuck behind a slow head still times out on time
    timeout :: pos_integer() | infinity,
    timer :: undefined | reference(),
    %% when the call was accepted: the event duration covers the same
    %% span as the deadline (queue wait plus the wire round-trip)
    started :: integer()
}).

%% The request currently on the wire.

-record(pending, {
    from :: gen_server:from(),
    function :: binary(),
    seqid :: non_neg_integer(),
    info :: thrift_runtime_service:function_info(),
    %% an HTTP oneway waits for the (empty) response and answers ok
    %% without any Thrift decoding
    oneway = false :: boolean(),
    timer :: undefined | reference(),
    started :: integer()
}).

-record(state, {
    socket :: thrift_runtime_socket:socket(),
    service_info :: thrift_runtime_service:service_info(),
    protocol :: module(),
    transport :: thrift_runtime_socket:transport(),
    multiplex :: undefined | binary(),
    max_frame_size :: pos_integer(),
    http_path :: binary(),
    host_value :: binary(),
    active_n :: pos_integer(),
    seqid = 0 :: non_neg_integer(),
    buffer = <<>> :: binary(),
    pending :: undefined | #pending{},
    queue = queue:new() :: queue:queue(#request{}),
    max_queue_depth :: pos_integer() | infinity,
    %% caller-facing outcomes: every `{ok, _}' / `ok' answer counts ok,
    %% every `{error, _}' failed (a declared exception included, same
    %% accounting as `thrift_runtime_reconnecting_client')
    calls_ok = 0 :: non_neg_integer(),
    calls_failed = 0 :: non_neg_integer(),
    handler :: thrift_runtime_events:handler()
}).

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

-doc """
Health-check counters for pool owners, same accounting as
`thrift_runtime_reconnecting_client` (minus the connection axis, which a
single-connection client does not have): `#{calls_ok := N,
calls_failed := N}`. A declared exception is a completed round-trip
but still counts failed, matching the `{error, _}` the caller sees.
""".
-spec get_stats(pid()) -> stats().
get_stats(Pid) ->
    gen_server:call(Pid, get_stats).

-doc """
Returns the same map as `get_stats/1` and zeroes the counters.
""".
-spec get_and_reset_stats(pid()) -> stats().
get_and_reset_stats(Pid) ->
    gen_server:call(Pid, get_and_reset_stats).

%% gen_server callbacks

-doc false.
-spec init(options()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    case thrift_runtime_options:on_event(Opts) of
        {ok, Handler} -> init(Opts, Handler);
        {error, Reason} -> {stop, Reason}
    end.

-spec init(options(), thrift_runtime_events:handler()) -> {ok, #state{}} | {stop, term()}.
init(Opts, Handler) ->
    Timeout = thrift_runtime_options:connect_timeout(Opts),
    Connect =
        thrift_runtime_socket:connect(
            maps:get(host, Opts), maps:get(port, Opts), maps:get(ssl_opts, Opts, undefined), Timeout
        ),
    case {Connect, thrift_runtime_options:protocol_module(Opts)} of
        {{ok, Socket}, {ok, Protocol}} ->
            ActiveN = thrift_runtime_options:active_n(Opts),
            ok = thrift_runtime_socket:set_active(Socket, ActiveN),
            Service = maps:get(service, Opts),
            {ok, #state{
                socket = Socket,
                service_info = Service:service_info(),
                protocol = Protocol,
                transport = thrift_runtime_options:transport(Opts),
                multiplex = maps:get(multiplex, Opts, undefined),
                max_frame_size = thrift_runtime_options:max_frame_size(Opts),
                http_path = thrift_runtime_options:http_path(Opts),
                host_value = host_value(maps:get(host, Opts), maps:get(port, Opts)),
                active_n = ActiveN,
                max_queue_depth = maps:get(max_queue_depth, Opts, infinity),
                handler = Handler
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
    case queue:len(State#state.queue) < State#state.max_queue_depth of
        true ->
            Request = arm_request(#request{
                kind = Kind,
                from = From,
                function = Function,
                args = Args,
                timeout = Timeout,
                started = erlang:monotonic_time(microsecond)
            }),
            try_dispatch(State#state{queue = queue:in(Request, State#state.queue)});
        false ->
            State1 = State#state{calls_failed = State#state.calls_failed + 1},
            emit_outcome(
                State1#state.handler, error, {error, queue_full}, Function, false, erlang:monotonic_time(microsecond)
            ),
            {reply, {error, queue_full}, State1}
    end;
handle_call(get_stats, _From, State) ->
    {reply, stats(State), State};
handle_call(get_and_reset_stats, _From, State) ->
    {reply, stats(State), State#state{calls_ok = 0, calls_failed = 0}};
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
    ok = thrift_runtime_socket:set_active({tcp, Socket}, ActiveN),
    {noreply, State};
handle_info({ssl_passive, Socket}, #state{socket = {ssl, Socket}, active_n = ActiveN} = State) ->
    ok = thrift_runtime_socket:set_active({ssl, Socket}, ActiveN),
    {noreply, State};
handle_info({tcp_closed, _Socket}, State) ->
    abort(closed, State);
handle_info({tcp_error, _Socket, Reason}, State) ->
    abort(Reason, State);
handle_info({ssl_closed, _Socket}, State) ->
    abort(closed, State);
handle_info({ssl_error, _Socket, Reason}, State) ->
    abort(Reason, State);
%% The reply can never be trusted to stay in sync after a timeout:
%% fail the call and drop the connection.
handle_info({timeout, Timer, call_timer}, #state{pending = undefined} = State) ->
    queue_timer_fired(Timer, State);
handle_info(
    {timeout, Timer, call_timer},
    #state{
        pending = Pending = #pending{timer = Timer, from = From}
    } = State
) ->
    fail_queue(closed, answer(From, {error, timeout}, Pending, State#state{pending = undefined}));
handle_info({timeout, Timer, call_timer}, State) ->
    %% a queued request's deadline while another call is on the wire
    queue_timer_fired(Timer, State);
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{socket = Socket} = State) ->
    State1 =
        case State#state.pending of
            Pending = #pending{from = From} ->
                answer(From, {error, closed}, Pending, State#state{pending = undefined});
            undefined ->
                State
        end,
    fail_queue(closed, State1),
    thrift_runtime_socket:close(Socket),
    ok.

%%--------------------------------------------------------------------
%% Send path
%%--------------------------------------------------------------------

%% Starts the head queued request while no other one is on the wire.

-spec try_dispatch(#state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
try_dispatch(#state{pending = undefined, queue = Queue} = State) ->
    case queue:out(Queue) of
        {empty, _} ->
            {noreply, State};
        {{value, Request}, Rest} ->
            SeqId = State#state.seqid + 1,
            case prepare(Request, SeqId, State) of
                {reply, Reply} ->
                    cancel_call_timer(Request#request.timer),
                    try_dispatch(answer(Request#request.from, Reply, Request, State#state{queue = Rest}));
                {ok, Message} ->
                    dispatch_request(Request, Message, SeqId, State#state{queue = Rest})
            end
    end;
try_dispatch(State) ->
    {noreply, State}.

-spec dispatch_request(#request{}, iodata(), non_neg_integer(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
dispatch_request(
    #request{kind = oneway, from = From} = Request, Message, SeqId, #state{transport = http} = State
) ->
    %% HTTP is request/response: the server answers even a oneway, and
    %% the next exchange rides behind that response, so it must be
    %% consumed before anything else goes out.
    Pending =
        #pending{
            from = From,
            function = Request#request.function,
            seqid = SeqId,
            info = request_info(Request, State),
            oneway = true,
            timer = Request#request.timer,
            started = Request#request.started
        },
    case send_message(Message, State#state{seqid = SeqId, pending = Pending}) of
        #state{} = Sent -> {noreply, Sent};
        Stop -> Stop
    end;
dispatch_request(#request{kind = oneway, from = From} = Request, Message, SeqId, State) ->
    case send_message(Message, State) of
        #state{} = Sent ->
            %% Answered as soon as the bytes are out; no reply follows.
            try_dispatch(answer(From, ok, Request, Sent#state{seqid = SeqId}));
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
            timer = Request#request.timer,
            started = Request#request.started
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

-spec prepare_args(#request{}, non_neg_integer(), thrift_runtime_service:function_info(), #state{}) ->
    {ok, iodata()} | {reply, term()}.
prepare_args(Request, SeqId, #{params := ParamsDesc}, #state{} = State) ->
    Names = [Name || {_, _, _, Name, _} <- thrift_runtime_binary:struct_fields(ParamsDesc)],
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
                        Type, wire_name(Request#request.function, State), SeqId, Payload
                    ),
                    {ok, Message};
                {error, Reason} ->
                    {reply, {error, Reason}}
            end;
        false ->
            {reply, {error, {bad_arity, Request#request.function, length(Names), length(Args)}}}
    end.

-spec request_info(#request{}, #state{}) -> thrift_runtime_service:function_info().
request_info(Request, #state{} = State) ->
    #{Request#request.function := Info} = State#state.service_info,
    Info.

%% The name that goes on the wire: plain, or `Service:function' for a
%% multiplexed server. Replies keep the plain name (the Apache
%% multiplexed protocol prefixes writes only), so the receive path
%% needs no changes.

-spec wire_name(binary(), #state{}) -> binary().
wire_name(Function, #state{multiplex = undefined}) ->
    Function;
wire_name(Function, #state{multiplex = Service}) ->
    <<Service/binary, ":", Function/binary>>.

%% The per-call deadline starts when the call is accepted, not when it
%% reaches the wire: a request queued behind a slow head keeps its own
%% deadline. The timer reference travels with the request; on dispatch
%% it moves into the pending slot, on a queue timeout the request is
%% answered from its queue position.

-spec arm_request(#request{}) -> #request{}.
arm_request(#request{timeout = infinity} = Request) ->
    Request#request{timer = undefined};
arm_request(#request{timeout = Timeout} = Request) ->
    Request#request{timer = erlang:start_timer(Timeout, self(), call_timer)}.

%% A queued request's deadline fired: answer it from its queue position
%% and keep the rest of the queue flowing.

-spec queue_timer_fired(reference(), #state{}) -> {noreply, #state{}}.
queue_timer_fired(Timer, #state{queue = Queue} = State) ->
    case queue:out(Queue) of
        {{value, Request = #request{timer = Timer, from = From}}, Rest} ->
            %% head of the queue: nothing is on the wire, the next
            %% request may go out right away
            try_dispatch(answer(From, {error, timeout}, Request, State#state{queue = Rest}));
        _ ->
            case queue_take_timer(Timer, Queue) of
                {ok, Request, Queue1} ->
                    {noreply, answer(Request#request.from, {error, timeout}, Request, State#state{queue = Queue1})};
                error ->
                    %% the timer was cancelled after all; the request is
                    %% on the wire (its pending slot handles it) or gone
                    {noreply, State}
            end
    end.

-spec queue_take_timer(reference(), queue:queue(#request{})) ->
    {ok, #request{}, queue:queue(#request{})} | error.
queue_take_timer(Timer, Queue) ->
    case lists:splitwith(fun(#request{timer = T}) -> T =/= Timer end, queue:to_list(Queue)) of
        {Prefix, [Request | Suffix]} ->
            {ok, Request, queue:from_list(Prefix ++ Suffix)};
        {_, []} ->
            error
    end.

-spec send_message(iodata(), #state{}) -> #state{} | {stop, normal, #state{}}.
send_message(Message, #state{} = State) ->
    Bytes = thrift_runtime_transport:client_frame(
        State#state.transport, Message, State#state.host_value, State#state.http_path
    ),
    case thrift_runtime_socket:send(State#state.socket, Bytes) of
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

%% The HTTP direction parses whole responses; the body is the Thrift
%% reply, a non-200 status fails the call.

handle_stream(#state{buffer = Buffer, transport = http, max_frame_size = Max} = State) ->
    case thrift_runtime_http:extract_response(Buffer, Max) of
        {ok, {200, _Headers, Message}, Leftover} ->
            case handle_message(Message, State#state{buffer = Leftover}) of
                {ok, State1} ->
                    try_dispatch(State1);
                Stop ->
                    Stop
            end;
        {ok, {Code, _Headers, _Body}, _Leftover} ->
            abort({http_status, Code}, State);
        more ->
            {noreply, State};
        {error, Reason} ->
            abort(Reason, State)
    end;
handle_stream(#state{buffer = Buffer} = State) ->
    case
        thrift_runtime_socket:extract_message(
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
handle_message(
    _Body, #state{pending = Pending = #pending{oneway = true, from = From, timer = Timer}} = State
) ->
    %% The HTTP response that carries a oneway: no Thrift payload in
    %% it, the call is done.
    cancel_call_timer(Timer),
    {ok, answer(From, ok, Pending, State#state{pending = undefined})};
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
            {ok, answer(Pending#pending.from, CallResult, Pending, State#state{pending = undefined})};
        {error, Reason} ->
            cancel_call_timer(Pending#pending.timer),
            fail_queue(
                closed,
                answer(Pending#pending.from, {error, Reason}, Pending, State#state{pending = undefined})
            )
    end.

%% A complete reply — value, declared exception or
%% TApplicationException — comes back as {ok, CallResult}; anything
%% else breaks the stream.

-spec decode_reply(
    binary(), non_neg_integer(), thrift_runtime_service:function_info(), binary(), #state{}
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

-spec decode_result(thrift_runtime_service:function_info(), binary(), #state{}) ->
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

-spec result_desc(thrift_runtime_service:function_info()) -> thrift_runtime_binary:type_desc().
result_desc(#{reply := ReplyType} = Info) when ReplyType =/= undefined ->
    {struct, {struct, [{0, default, ReplyType, <<"success">>, undefined} | exception_fields(Info)]}};
result_desc(#{} = Info) ->
    {struct, {struct, exception_fields(Info)}}.

-spec exception_fields(thrift_runtime_service:function_info()) -> [thrift_runtime_binary:field_desc()].
exception_fields(Info) ->
    maps:get(exceptions, Info, []).

-spec exception_field(map(), [thrift_runtime_binary:field_desc()]) ->
    {ok, binary(), thrift_runtime_binary:struct_value()} | none.
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

-spec exception_name(thrift_runtime_binary:field_desc()) -> binary().
exception_name({_, _, {struct, {ref, _, StructName}}, _, _}) -> StructName;
exception_name({_, _, _, FieldName, _}) -> FieldName.

%%--------------------------------------------------------------------
%% Failure path
%%--------------------------------------------------------------------

%% The stream is broken: the pending call already got its own failure
%% reason; everyone still queued gets closed.

-spec fail_queue(term(), #state{}) -> {stop, normal, #state{}}.
fail_queue(Reason, #state{queue = Queue} = State) ->
    State1 = lists:foldl(
        fun(#request{from = From, timer = Timer} = Request, St) ->
            cancel_call_timer(Timer),
            answer(From, {error, Reason}, Request, St)
        end,
        State#state{queue = queue:new()},
        queue:to_list(Queue)
    ),
    %% The process stops right away, so the counters are bookkeeping for
    %% get_stats calls that raced the failure.
    {stop, normal, State1}.

-spec abort(term(), #state{}) -> {stop, normal, #state{}}.
abort(Reason, #state{pending = Pending = #pending{from = From, timer = Timer}} = State) ->
    cancel_call_timer(Timer),
    fail_queue(closed, answer(From, {error, Reason}, Pending, State#state{pending = undefined}));
abort(_Reason, #state{pending = undefined} = State) ->
    fail_queue(closed, State).

%% Every caller-facing answer funnels through here so the stats stay
%% honest and one event goes out per answer, whatever path produced it.

-spec answer(gen_server:from(), term(), #pending{} | #request{}, #state{}) -> #state{}.
answer(From, Result, #pending{function = Function, oneway = Oneway, started = Started}, State) ->
    answer(From, Result, Function, Oneway, Started, State);
answer(From, Result, #request{function = Function, kind = Kind, started = Started}, State) ->
    answer(From, Result, Function, Kind =:= oneway, Started, State).

-spec answer(gen_server:from(), term(), binary(), boolean(), integer(), #state{}) -> #state{}.
answer(From, Result, Function, Oneway, Started, #state{handler = Handler} = State) ->
    gen_server:reply(From, Result),
    Outcome =
        case Result of
            {ok, _} -> ok;
            ok -> ok;
            _ -> error
        end,
    State1 =
        case Outcome of
            ok -> State#state{calls_ok = State#state.calls_ok + 1};
            error -> State#state{calls_failed = State#state.calls_failed + 1}
        end,
    case Handler of
        undefined -> ok;
        _ -> emit_outcome(Handler, Outcome, Result, Function, Oneway, Started)
    end,
    State1.

%% The event map is only built when a handler is set — the default
%% (`undefined') path costs one pattern match per answer.

-spec emit_outcome(
    thrift_runtime_events:handler(), ok | error, term(), binary(), boolean(), integer()
) -> ok.
emit_outcome(Handler, ok, _Result, Function, Oneway, Started) ->
    thrift_runtime_events:emit(Handler, call_ok, #{
        function => Function, duration_us => elapsed_us(Started), oneway => Oneway
    });
emit_outcome(Handler, error, Result, Function, Oneway, Started) ->
    thrift_runtime_events:emit(Handler, call_error, #{
        function => Function,
        reason => error_reason(Result),
        duration_us => elapsed_us(Started),
        oneway => Oneway
    }).

%% The event carries the inner reason — what the caller received
%% inside `{error, _}' — so event counts line up with the answer
%% shapes.

-spec error_reason(term()) -> term().
error_reason({error, Reason}) ->
    Reason;
error_reason(Reason) ->
    Reason.

-spec elapsed_us(integer()) -> non_neg_integer().
elapsed_us(Started) ->
    erlang:max(0, erlang:monotonic_time(microsecond) - Started).

-spec stats(#state{}) -> stats().
stats(#state{calls_ok = Ok, calls_failed = Failed}) ->
    #{calls_ok => Ok, calls_failed => Failed}.

%% The `Host:' header value from the connect options; cosmetic to this
%% runtime's server but honest on the wire.

-spec host_value(inet:socket_address() | inet:hostname(), inet:port_number()) -> binary().
host_value(Host, Port) ->
    <<(render_host(Host))/binary, ":", (integer_to_binary(Port))/binary>>.

-spec render_host(inet:socket_address() | inet:hostname()) -> binary().
render_host(Host) when is_tuple(Host) ->
    list_to_binary(inet:ntoa(Host));
render_host(Host) when is_atom(Host) ->
    atom_to_binary(Host, utf8);
render_host(Host) when is_binary(Host) ->
    Host;
render_host(Host) when is_list(Host) ->
    unicode:characters_to_binary(Host).

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
