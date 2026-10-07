%% Copyright 2025 Sergei Yelin
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

`call/4` sends a CALL envelope with the function's parameter struct,
then blocks on exactly one REPLY. The reply payload is decoded per the
service description: field 0 is the success value, a declared exception
field turns into `{error, {exception, Name, Map}}`, and a
`TApplicationException` into `{error, {application_exception, ...}}`.
`oneway/4` sends and answers immediately.

The generated typed client modules call into this; the same map drives
both:

- `host`, `port` (required);
- `service` — module implementing `thrift_erl_service` (required);
- `transport` — `framed` (default) or `buffered`;
- `timeout` — connect and per-call timeout, default 5000 ms;
- `max_frame_size` — framed guard, default 64 MiB.

Calls are serialized per connection (one outstanding call at a time),
matching the classic Thrift client model.
""".

-behaviour(gen_server).

-export([start_link/1, stop/1, call/4, oneway/4]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([options/0, call_result/0]).

-include_lib("kernel/include/logger.hrl").

-type options() :: #{
    host := inet:socket_address() | inet:hostname(),
    port := inet:port_number(),
    service := module(),
    transport => thrift_erl_socket:transport(),
    timeout => pos_integer(),
    max_frame_size => pos_integer()
}.

-type call_result() ::
    {ok, term()}
    | {error, {exception, binary(), thrift_erl_binary:struct_value()}}
    | {error, {application_exception, binary(), non_neg_integer(), binary()}}
    | {error, term()}.

-record(state, {
    socket :: gen_tcp:socket(),
    service :: module(),
    service_info :: thrift_erl_service:service_info(),
    transport :: thrift_erl_socket:transport(),
    timeout :: pos_integer(),
    max_frame_size :: pos_integer(),
    seqid = 0 :: non_neg_integer(),
    buffer = <<>> :: binary()
}).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_MAX_FRAME_SIZE, 64 * 1024 * 1024).

-doc "Connects to the server; fails if the connection cannot be made.".
-spec start_link(options()) -> gen_server:start_ret().
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-doc "Closes the connection.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-doc """
Calls `Function` with `Args` (declaration order) and waits for a reply.

For `void` functions the success value is `undefined`.
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
    case
        gen_tcp:connect(
            maps:get(host, Opts),
            maps:get(port, Opts),
            [
                binary, {packet, raw}, {active, false}, {nodelay, true}
            ],
            Timeout
        )
    of
        {ok, Socket} ->
            Service = maps:get(service, Opts),
            {ok, #state{
                socket = Socket,
                service = Service,
                service_info = Service:service_info(),
                transport = maps:get(transport, Opts, framed),
                timeout = Timeout,
                max_frame_size = maps:get(max_frame_size, Opts, ?DEFAULT_MAX_FRAME_SIZE)
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
-spec handle_call(term(), {pid(), reference()}, #state{}) ->
    {reply, term(), #state{}} | {stop, term(), #state{}}.
handle_call({call, Function, Args, Timeout}, _From, #state{} = State) ->
    case maps:find(Function, State#state.service_info) of
        error ->
            {reply, {error, unknown_function}, State};
        {ok, Info} ->
            SeqId = State#state.seqid + 1,
            case send_call(call, Function, SeqId, Info, Args, State) of
                ok ->
                    case recv_reply(Function, SeqId, Info, Timeout, State) of
                        {ok, CallResult, Leftover} ->
                            {reply, CallResult, State#state{seqid = SeqId, buffer = Leftover}};
                        {error, Reason} ->
                            %% The stream state is unknown after a read
                            %% failure; stop the connection and hand the
                            %% error to the caller.
                            State1 = State#state{seqid = SeqId},
                            {stop, normal, {error, Reason}, State1}
                    end;
                {error, Reason} ->
                    {reply, {error, Reason}, State#state{seqid = SeqId}}
            end
    end;
handle_call({oneway, Function, Args, _Timeout}, _From, #state{} = State) ->
    case maps:find(Function, State#state.service_info) of
        error ->
            {reply, {error, unknown_function}, State};
        {ok, Info} ->
            SeqId = State#state.seqid + 1,
            Result = send_call(oneway, Function, SeqId, Info, Args, State),
            {reply, Result, State#state{seqid = SeqId}}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{socket = Socket}) ->
    gen_tcp:close(Socket),
    ok.

%%--------------------------------------------------------------------
%% Call path
%%--------------------------------------------------------------------

-spec send_call(
    thrift_erl_binary:message_type(),
    binary(),
    non_neg_integer(),
    thrift_erl_service:function_info(),
    [term()],
    #state{}
) -> ok | {error, term()}.
send_call(Type, Function, SeqId, #{params := ParamsDesc}, Args, #state{} = State) ->
    Names = [Name || {_, _, _, Name, _} <- thrift_erl_binary:struct_fields(ParamsDesc)],
    case length(Args) =:= length(Names) of
        true ->
            Values = lists:zip(Names, Args),
            case thrift_erl_binary:encode(ParamsDesc, maps:from_list(Values)) of
                {ok, Payload} ->
                    Message = thrift_erl_binary:encode_message(Type, Function, SeqId, Payload),
                    send_message(Message, State);
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            {error, {bad_arity, Function, length(Names), length(Args)}}
    end.

-spec send_message(iodata(), #state{}) -> ok | {error, term()}.
send_message(Message, #state{} = State) ->
    Bytes =
        case State#state.transport of
            framed -> [<<(iolist_size(Message)):32/big-unsigned>>, Message];
            buffered -> Message
        end,
    thrift_erl_socket:send(State#state.socket, Bytes).

-spec recv_reply(
    binary(), non_neg_integer(), thrift_erl_service:function_info(), pos_integer() | infinity, #state{}
) ->
    {ok, call_result(), binary()} | {error, term()}.
recv_reply(Function, SeqId, Info, Timeout, #state{} = State) ->
    case
        thrift_erl_socket:recv_message(
            State#state.socket,
            State#state.transport,
            Timeout,
            State#state.max_frame_size,
            State#state.buffer
        )
    of
        {ok, Message, Leftover} ->
            decode_reply(Function, SeqId, Info, Message, Leftover);
        {error, Reason} ->
            {error, Reason}
    end.

%% Transport-level failures come back as plain `{error, _}`; a complete
%% reply — value, declared exception or TApplicationException — is a
%% successful read and comes back as `{ok, CallResult, Leftover}`.

-spec decode_reply(
    binary(), non_neg_integer(), thrift_erl_service:function_info(), binary(), binary()
) ->
    {ok, call_result(), binary()} | {error, term()}.
decode_reply(Function, SeqId, Info, Message, Leftover) ->
    case thrift_erl_binary:decode_message(Message) of
        {ok, reply, Function, SeqId, Tail} ->
            decode_result(Info, Tail, Leftover);
        {ok, exception, _Name, _SeqId, Tail} ->
            case thrift_erl_binary:decode_application_exception(Tail) of
                {ok, #{message := Msg, code := Code, name := Name}, _} ->
                    {ok, {error, {application_exception, Msg, Code, Name}}, Leftover};
                Other ->
                    {error, {application_exception_decode, Other}}
            end;
        {ok, _OtherType, Name, OtherSeqId, _Tail} ->
            {error, {unexpected_reply, Name, OtherSeqId}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Field 0 is success; any declared exception field that appears wins.

-spec decode_result(thrift_erl_service:function_info(), binary(), binary()) ->
    {ok, call_result(), binary()} | {error, term()}.
decode_result(Info, Tail, Leftover) ->
    Exceptions = maps:get(exceptions, Info, []),
    ResultDesc = result_desc(Info),
    case thrift_erl_binary:decode(ResultDesc, Tail) of
        {ok, Values, _Rest} ->
            case exception_field(Values, Exceptions) of
                {ok, Name, Value} ->
                    {ok, {error, {exception, Name, Value}}, Leftover};
                none when map_size(Values) =:= 0 ->
                    {ok, {ok, undefined}, Leftover};
                none ->
                    {ok, {ok, maps:get(<<"success">>, Values)}, Leftover}
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

%% Exceptions are identified by their struct name (the IDL-level
%% identity); the throw-field name is the fallback for descriptors
%% without a struct ref.
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
