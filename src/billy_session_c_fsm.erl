-module(billy_session_c_fsm).

-behaviour(gen_fsm).

%% API
-export([
	start_link/2
]).

%% gen_fsm callbacks
-export([
	init/1,
	handle_event/3,
	handle_sync_event/4,
	handle_info/3,
	terminate/3,
	code_change/4,

	st_negotiating/2,
	st_negotiating/3,

	st_unbound/2,
	st_unbound/3,

	st_binding/2,
	st_binding/3,

	st_bound/2,
	st_bound/3,

	st_required_unbind/2,
	st_required_unbind/3,

	st_unbinding/2,
	st_unbinding/3
]).

-include("billy_session_c.hrl").
-include_lib("billy_common/include/billy_session_piqi.hrl").
-include_lib("billy_common/include/gen_fsm_spec.hrl").

-define(ARGS, billy_session_c_args).

-define(dispatch_event(Event, SArgs, Sess, PDU) ,
	Fun = SArgs#?ARGS.Event,
	Fun(Sess, PDU)
).

-record(state, {
	session_id :: binary(),
	sock,
	args :: #billy_session_c_args{},
	unbound_request,
	bound_request,
	tcp_bytes_part :: binary()
}).

%% ===================================================================
%% API
%% ===================================================================

start_link(Sock, Args = #?ARGS{}) ->
	gen_fsm:start_link(?MODULE, {Sock, Args}, []).

%% ===================================================================
%% gen_fsm callbacks
%% ===================================================================

init({Sock, Args}) ->
	gproc:add_local_name({?MODULE, Sock}),
	io:format("FSM_C:init ~p~n", [self()]),

	{ok, st_negotiating, #state{
		sock = Sock,
		args = Args,
		unbound_request = undefined,
		tcp_bytes_part = <<>>
	}}.

handle_event(Event, _StateName, StateData) ->
	{stop, {bad_arg, Event}, StateData}.

handle_sync_event(wait_till_st_bound, From, StateName, StateData) ->
	% io:format("wait_till_st_bound, StateName: ~p~n", [StateName]),
	case StateName of
		st_bound ->
			{reply, {ok, bound}, StateName, StateData};
		_Any ->
			{next_state, StateName, StateData#state{bound_request = From}}
	end;
handle_sync_event(wait_till_st_unbound, From, StateName, StateData) ->
	% io:format("wait_till_st_unbound, StateName: ~p~n", [StateName]),
	case StateName of
		st_unbound ->
			{reply, {ok, unbound}, StateName, StateData};
		_Any ->
			{next_state, StateName, StateData#state{unbound_request = From}}
	end;
handle_sync_event(Event, _From, _StateName, StateData) ->
	{stop, {bad_arg, Event}, bad_arg, StateData}.

handle_info({tcp, _, TcpData}, StateName, StateData = #state{
	sock = Sock, tcp_bytes_part = BytesPart
}) ->
	try
		% io:format("Data for parsing: ~p~n", [list_to_binary([BytesPart, TcpData])]),
		{ok, NewBytesPart} = parse_tcp_data(list_to_binary([BytesPart, TcpData])),
		% io:format("NewBytesPart: ~p~n", [NewBytesPart]),
		inet:setopts(Sock, [{active, once}]),
		{next_state, StateName, StateData#state{tcp_bytes_part = NewBytesPart}}
	catch
		EType:Error ->
			io:format("Error parsing data: ~p:~p~n", [EType, Error]),
			Bye = #billy_session_bye{
				state_name = StateName,
				reason = internal_error,
				reason_long = list_to_binary(io_lib:format("~p : ~p", [EType, Error]))
			},
			send_pdu(Sock, bye, Bye),
			{stop, normal, StateData}
	end;

handle_info({tcp_closed, _}, _StateName, StateData = #state{
	sock = _Sock
}) ->
	{stop, lost_connection, StateData};

handle_info(Info, _StateName, StateData) ->
	{stop, {bad_arg, Info}, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.

terminate(_Reason, _StateName, _StateData) ->
	ok.

%% ===================================================================
%% State NEGOTIATING
%% ===================================================================

st_negotiating({in_pdu, Hello = #billy_session_hello{
	session_id = SessionID
}}, StateData = #state{args = Args, unbound_request = Caller}) ->
	?dispatch_event(cb_on_hello, Args, self(), Hello) ,
	case Caller of
		undefined ->
			ok;
		From ->
			gen_fsm:reply(From, {ok, unbound})
	end,
	{next_state, st_unbound, StateData#state{
		session_id = SessionID
	}};

% got unexpected PDU: saying #bye{reason = protocol_error}
st_negotiating({in_pdu, _WrongPDU}, StateData = #state{sock = Sock}) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, bye, Bye),
	{stop, protocol_error, StateData};

st_negotiating(Event, StateData) ->
	{stop, {bad_arg, Event}, StateData}.

st_negotiating(Event, _From, StateData) ->
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.

%% ===================================================================
%% State UNBOUND
%% ===================================================================

% API asked to send #bind_request
st_unbound({control, bind, BindProps}, StateData = #state{sock = Sock}) ->
	ClientID = proplists:get_value(client_id, BindProps),
	ClientPw = proplists:get_value(client_pw, BindProps),
	BindReq = #billy_session_bind_request{
		client_id = ClientID,
		client_pw = ClientPw
	},
	send_pdu(Sock, bind_request, BindReq),
	{next_state, st_binding, StateData};

% API asked to say #bye
st_unbound({control, bye}, StateData = #state{
	sock = Sock
}) ->
	Bye = #billy_session_bye{
		state_name = st_unbound,
		reason = normal
	},
	send_pdu(Sock, bye, Bye),
	{stop, normal, StateData};

% got unexpected PDU: saying #bye{reason = protocol_error}
st_unbound({in_pdu, _WrongPDU}, StateData = #state{sock = Sock}) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, bye, Bye),
	{stop, protocol_error, StateData};

st_unbound(Event, StateData) ->
	{stop, {bad_arg, Event}, StateData}.

st_unbound(Event, _From, StateData) ->
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.

%% ===================================================================
%% State BINDING
%% ===================================================================

st_binding({in_pdu, BindResponse = #billy_session_bind_response{
	result = accept
}}, StateData = #state{args = Args, bound_request = Caller}) ->
	% io:format("in_pdu, BindResponse", []),
	?dispatch_event(cb_on_bind_accept, Args, self(), BindResponse),
	case Caller of
		undefined ->
			ok;
		From ->
			gen_fsm:reply(From, {ok, bound})
	end,
	{next_state, st_bound, StateData};

st_binding({in_pdu, BindResponse = #billy_session_bind_response{
	result = {reject, _}
}}, StateData = #state{args = Args}) ->
	?dispatch_event(cb_on_bind_reject, Args, self(), BindResponse),
	{next_state, st_unbound, StateData};

% got unexpected PDU: saying #bye{reason = protocol_error}
st_binding({in_pdu, _WrongPDU}, StateData = #state{sock = Sock}) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, bye, Bye),
	{stop, protocol_error, StateData};

st_binding(Event, StateData) ->
	{stop, {bad_arg, Event}, StateData}.

st_binding(Event, _From, StateData) ->
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.

%% ===================================================================
%% State BOUND
%% ===================================================================

st_bound({control, data_pdu, DataPDUBin}, StateData = #state{sock = Sock}) ->
	DataPDU = #billy_session_data_pdu{
		data_pdu = DataPDUBin
	},
	send_pdu(Sock, data_pdu, DataPDU),
	{next_state, st_bound, StateData};

st_bound({in_pdu, DataPDU = #billy_session_data_pdu{}},  StateData = #state{args = Args}) ->
	?dispatch_event(cb_on_data_pdu, Args, self(), DataPDU),
	{next_state, st_bound, StateData};

st_bound({control, unbind, UnbindProps}, StateData = #state{sock = Sock}) ->
	UnbindRequest = #billy_session_unbind_request{
		reason = proplists:get_value(reason, UnbindProps)
	},
	send_pdu(Sock, unbind_request, UnbindRequest),
	{next_state, st_unbinding, StateData};

st_bound({in_pdu, RequireUnbind = #billy_session_require_unbind{}}, StateData = #state{
	args = Args
}) ->
	?dispatch_event(cb_on_required_unbind, Args, self(), RequireUnbind),
	{next_state, st_required_unbind, StateData};

% got unexpected PDU: saying #bye{reason = protocol_error}
st_bound({in_pdu, _WrongPDU}, StateData = #state{sock = Sock}) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, bye, Bye),
	{stop, protocol_error, StateData};

st_bound(Event, StateData) ->
	{stop, {bad_arg, Event}, StateData}.

st_bound(Event, _From, StateData) ->
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.

%% ===================================================================
%% State REQUIRED_UNBIND
%% ===================================================================

% got unexpected PDU: saying #bye{reason = protocol_error}
st_required_unbind({in_pdu, _WrongPDU}, StateData = #state{sock = Sock}) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, bye, Bye),
	{stop, protocol_error, StateData};

st_required_unbind(Event, StateData) ->
	{stop, {bad_arg, Event}, StateData}.

st_required_unbind(Event, _From, StateData) ->
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.

%% ===================================================================
%% State UNBINDING
%% ===================================================================

st_unbinding({in_pdu, UnbindResponse = #billy_session_unbind_response{}}, StateData = #state{
	args = Args
}) ->
	?dispatch_event(cb_on_unbound, Args, self(), UnbindResponse),
	{next_state, st_unbound, StateData};

% got unexpected PDU: saying #bye{reason = protocol_error}
st_unbinding({in_pdu, _WrongPDU}, StateData = #state{sock = Sock}) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, bye, Bye),
	{stop, protocol_error, StateData};

st_unbinding(Event, StateData) ->
	{stop, {bad_arg, Event}, StateData}.

st_unbinding(Event, _From, StateData) ->
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.

%% ===================================================================
%% Internal
%% ===================================================================

send_pdu(Sock, Msg, Data) ->
	PDU = {Msg, Data},
	send_pdu(Sock, PDU).

send_pdu(Sock, PDU) ->
	% io:format("Sending PDU:~p into ~p~n", [PDU, Sock]),
	PDUBin = billy_session_piqi:gen_pdu(PDU),
	Size = size(list_to_binary(PDUBin)),
	BinSize = <<Size:16/little>>,
	% io:format("BinSize: ~p~n", [BinSize]),
	Bin = list_to_binary([BinSize, PDUBin]),
	% io:format("Sending BIN: ~p~n", [Bin]),
	gen_tcp:send(Sock, Bin),
	inet:setopts(Sock, [{active, once}]).

parse_tcp_data(Bytes) when size(Bytes) =< 2 ->
	{ok, Bytes};
parse_tcp_data(<<BinSize:2/binary, BytesSoFar/binary>>) ->
	Size = binary:decode_unsigned(BinSize, little),
	BytesSoFarSize = size(BytesSoFar),
	if
		BytesSoFarSize >= Size ->
			<<PDUBin:Size/binary, PDUBinSoFar/binary>> = BytesSoFar,
			{_PDUType, PDU} = billy_session_piqi:parse_pdu(PDUBin),
			%io:format("Got ~p on ~p~n", [PDU, Sock]),
			gen_fsm:send_event(self(), {in_pdu, PDU}),
			parse_tcp_data(PDUBinSoFar);
		true ->
			{ok, list_to_binary([BinSize, BytesSoFar])}
	end.
