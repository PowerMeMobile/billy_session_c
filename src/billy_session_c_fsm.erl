-module(billy_session_c_fsm).


-behaviour(gen_fsm).
-export([
	start_link/2
]).

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

-include_lib("billy_common/include/billy_session_piqi.hrl").
-include("billy_session_c.hrl").
-define(ARGS, billy_session_c_args).

-define(dispatch_event(Event, SArgs, Sess, PDU) ,
		Fun = SArgs#?ARGS.Event,
		Fun(Sess, PDU)
).

-record(state, {
	session_id :: binary(),
	sock,
	args :: #billy_session_c_args{}
}).

start_link(Sock, Args = #?ARGS{}) ->
	gen_fsm:start_link(?MODULE, {Sock, Args}, []).

init({Sock, Args}) ->
	gproc:add_local_name({?MODULE, Sock}),
	io:format("FSM_C:init ~p~n", [self()]),
	{ok, st_negotiating, #state{
		sock = Sock,
		args = Args
	}}.

handle_event(Event, _StateName, StateData) ->
	% {next_state, StateName, StateData}.
	{stop, {bad_arg, Event}, StateData}.

handle_sync_event(Event, _From, _StateName, StateData) ->
	% {reply, {error, bad_arg}, StateName, StateData}.
	{stop, {bad_arg, Event}, bad_arg, StateData}.

handle_info({tcp, _, TcpData}, StateName, StateData = #state{
	sock = Sock
}) ->
	try 
		io:format("Trying to parse ~p~n", [TcpData]),
		{_PDUType, PDU} = billy_session_piqi:parse_pdu(TcpData),
		io:format("Got ~p on ~p~n", [PDU, Sock]),
		gen_fsm:send_event(self(), {in_pdu, PDU}),

		{next_state, StateName, StateData}
	catch
		EType:Error ->
			io:format("Error parsing data: ~p:~p~n", [EType, Error]),
			Bye = #billy_session_bye{
				
			},
			send_pdu(Sock, {bye, Bye}),
			{stop, normal, StateData}
	end;

handle_info({tcp_closed, _}, _StateName, StateData = #state{
	sock = _Sock
}) ->
	{stop, lost_connection, StateData};

handle_info(Info, _StateName, StateData) ->
	%{next_state, StateName, StateData}.
	{stop, {bad_arg, Info}, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.

terminate(_Reason, _StateName, _StateData) ->
	ok.


% % % State NEGOTIATING % % %

st_negotiating({in_pdu, Hello = #billy_session_hello{
	session_id = SessionID
} }, StateData = #state{ args = Args }) ->
	?dispatch_event(cb_on_hello, Args, self(), Hello) ,

	{next_state, st_unbound, StateData#state{
		session_id = SessionID
	}};

% got unexpected PDU: saying #bye{ reason = protocol_error }
st_negotiating({in_pdu, _WrongPDU}, StateData = #state{ sock = Sock }) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, {bye, Bye}),
	{stop, protocol_error, StateData};

st_negotiating(Event, StateData) ->
	%{next_state, st_free, StateData}.
	{stop, {bad_arg, Event}, StateData}.

st_negotiating(Event, _From, StateData) ->
	%{reply, {error, bad_arg}, StateName, StateData}.
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.



% % % State UNBOUND % % %

% API asked to send #bind_request
st_unbound({control, bind, BindProps}, StateData = #state{ sock = Sock }) ->
	ClientID = proplists:get_value(client_id, BindProps),
	ClientPw = proplists:get_value(client_pw, BindProps),
	BindReq = #billy_session_bind_request{
		client_id = ClientID,
		client_pw = ClientPw
	},
	send_pdu(Sock, {bind_request, BindReq}),
	{next_state, st_binding, StateData};

% API asked to say #bye
st_unbound({control, bye}, StateData = #state{
	sock = Sock
}) ->
	Bye = #billy_session_bye{
		state_name = st_unbound,
		reason = normal
	},
	send_pdu(Sock, {bye, Bye}),
	{stop, normal, StateData};

% got unexpected PDU: saying #bye{ reason = protocol_error }
st_unbound({in_pdu, _WrongPDU}, StateData = #state{ sock = Sock }) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, {bye, Bye}),
	{stop, protocol_error, StateData};

st_unbound(Event, StateData) ->
	%{next_state, st_free, StateData}.
	{stop, {bad_arg, Event}, StateData}.

st_unbound(Event, _From, StateData) ->
	%{reply, {error, bad_arg}, StateName, StateData}.
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.


% % % State BINDING % % %

st_binding({in_pdu, BindResponse = #billy_session_bind_response{ 
	result = accept 
}}, StateData = #state{ args = Args }) ->
	?dispatch_event(cb_on_bind_accept, Args, self(), BindResponse),
	{next_state, st_bound, StateData};

st_binding({in_pdu, BindResponse = #billy_session_bind_response{
	result = {reject, _}
}}, StateData = #state{ args = Args }) ->
	?dispatch_event(cb_on_bind_reject, Args, self(), BindResponse),
	{next_state, st_unbound, StateData};


% got unexpected PDU: saying #bye{ reason = protocol_error }
st_binding({in_pdu, _WrongPDU}, StateData = #state{ sock = Sock }) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, {bye, Bye}),
	{stop, protocol_error, StateData};

st_binding(Event, StateData) ->
	%{next_state, st_free, StateData}.
	{stop, {bad_arg, Event}, StateData}.

st_binding(Event, _From, StateData) ->
	%{reply, {error, bad_arg}, StateName, StateData}.
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.



% % % State BOUND % % %

st_bound({control, unbind, UnbindProps}, StateData = #state{ sock = Sock } ) ->
	UnbindRequest = #billy_session_unbind_request{
		reason = proplists:get_value(reason, UnbindProps)
	},
	send_pdu(Sock, {unbind_request, UnbindRequest}),
	{next_state, st_unbinding, StateData};

st_bound({in_pdu, RequireUnbind = #billy_session_require_unbind{
} }, StateData = #state{ args = Args }) ->
	?dispatch_event(cb_on_required_unbind, Args, self(), RequireUnbind),
	{next_state, st_required_unbind, StateData};

% got unexpected PDU: saying #bye{ reason = protocol_error }
st_bound({in_pdu, _WrongPDU}, StateData = #state{ sock = Sock }) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, {bye, Bye}),
	{stop, protocol_error, StateData};

st_bound(Event, StateData) ->
	%{next_state, st_free, StateData}.
	{stop, {bad_arg, Event}, StateData}.

st_bound(Event, _From, StateData) ->
	%{reply, {error, bad_arg}, StateName, StateData}.
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.



% % % State REQUIRED_UNBIND % % %

% got unexpected PDU: saying #bye{ reason = protocol_error }
st_required_unbind({in_pdu, _WrongPDU}, StateData = #state{ sock = Sock }) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, {bye, Bye}),
	{stop, protocol_error, StateData};

st_required_unbind(Event, StateData) ->
	%{next_state, st_free, StateData}.
	{stop, {bad_arg, Event}, StateData}.

st_required_unbind(Event, _From, StateData) ->
	%{reply, {error, bad_arg}, StateName, StateData}.
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.

% % % State UNBINDING % % %

st_unbinding({in_pdu, UnbindResponse = #billy_session_unbind_response{
} }, StateData = #state{ args = Args }) ->
	?dispatch_event(cb_on_unbound, Args, self(), UnbindResponse),
	{next_state, st_unbound, StateData};

% got unexpected PDU: saying #bye{ reason = protocol_error }
st_unbinding({in_pdu, _WrongPDU}, StateData = #state{ sock = Sock }) ->
	Bye = #billy_session_bye{
		state_name = st_negotiating,
		reason = protocol_error
	},
	send_pdu(Sock, {bye, Bye}),
	{stop, protocol_error, StateData};

st_unbinding(Event, StateData) ->
	%{next_state, st_free, StateData}.
	{stop, {bad_arg, Event}, StateData}.

st_unbinding(Event, _From, StateData) ->
	%{reply, {error, bad_arg}, StateName, StateData}.
	{stop, {bad_arg, Event}, {error, bad_arg}, StateData}.



%%% Internal

send_pdu(Sock, PDU) ->
	io:format("Sending PDU:~p into ~p~n", [PDU, Sock]),
	PDUBin = billy_session_piqi:gen_pdu(PDU),
	io:format("Sending BIN:~p into ~p~n", [list_to_binary(lists:flatten(PDUBin)), Sock]),
	gen_tcp:send(Sock, PDUBin),
	inet:setopts(Sock, [{active, once}]).



