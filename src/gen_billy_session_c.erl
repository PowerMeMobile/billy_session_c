-module(gen_billy_session_c).

-behaviour(gen_server).

%% API
-export([
	start_link/3,
	reply_bind/2,
	reply_unbind/2,
	reply_bye/2,
	reply_data_pdu/2
]).

%% gen_server callbacks
-export([
	init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3
]).

-export([
	behaviour_info/1
]).

-spec behaviour_info(callbacks) -> [{atom(), arity()}];
					(any()) -> undefined.
behaviour_info(callbacks) ->
	[
		{init, 1},
		{handle_call, 4},
		{handle_cast, 3},
		{terminate, 3},

		{handle_hello, 3},
		{handle_bind_accept, 3},
		{handle_bind_reject, 3},
		{handle_require_unbind, 3},
		{handle_unbind_response, 3},
		{handle_bye, 3},
		{handle_data_pdu, 3}
	];
behaviour_info(_) ->
	undefined.

-include("billy_session_c.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").
-include_lib("billy_common/include/logging.hrl").

-record(state, {
	ref :: reference(),
	mod :: term(),
	mod_state :: any(),
	fsm :: pid()
}).

%% ===================================================================
%% API
%% ===================================================================

start_link(Socket, Mod, ModArgs) ->
	gen_server:start_link(?MODULE, [Socket, Mod, ModArgs], []).

reply_bye(FSM, Props) ->
	gen_fsm:send_event(FSM, {control, bye, Props}).

reply_bind(FSM, Props) ->
	gen_fsm:send_event(FSM, {control, bind, Props}).

reply_unbind(FSM, Props) ->
	gen_fsm:send_event(FSM, {control, unbind, Props}).

reply_data_pdu(FSM, Props) ->
	gen_fsm:send_event(FSM, {control, data_pdu, Props}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([Socket, Mod, ModArgs]) ->
	Gen = self(),
	Ref = make_ref(),

	{ok, FSM} = billy_session_c_fsm:start(Socket, #billy_session_c_args{
		cb_on_hello = fun(_Pid, PDU) -> gen_server:cast(Gen, {Ref, on_hello, PDU}) end,
		cb_on_bind_accept = fun(_Pid, PDU) -> gen_server:cast(Gen, {Ref, on_bind_accept, PDU}) end,
		cb_on_bind_reject = fun(_Pid, PDU) -> gen_server:cast(Gen, {Ref, on_bind_reject, PDU}) end,
		cb_on_required_unbind = fun(_Pid, PDU) -> gen_server:cast(Gen, {Ref, on_require_unbind, PDU}) end,
		cb_on_unbound = fun(_Pid, PDU) -> gen_server:cast(Gen, {Ref, on_unbound, PDU}) end,
		cb_on_bye = fun(_Pid, PDU) -> gen_server:cast(Gen, {Ref, on_bye, PDU}) end,
		cb_on_data_pdu = fun(_Pid, PDU) -> gen_server:cast(Gen, {Ref, on_data_pdu, PDU}) end
	}),
	erlang:monitor(process, FSM),

	{ok, ModState} = Mod:init(ModArgs),

	{ok, #state{
		ref = Ref,

		mod = Mod,
		mod_state = ModState,

		fsm = FSM
	}}.

handle_call(get_fsm, _From, State = #state{fsm = FSM}) ->
	{reply, {ok, FSM}, State};

handle_call(Request, From, State = #state{mod = Mod, fsm = FSM, mod_state = ModState}) ->
	case Mod:handle_call(Request, From, FSM, ModState) of
		{reply, Reply, NewMState} ->
			{reply, Reply, State#state{mod_state = NewMState}};
		{reply, Reply, NewMState, Timeout} ->
			{reply, Reply, State#state{mod_state = NewMState}, Timeout};
		{noreply, NewMState} ->
			{noreply, State#state{mod_state = NewMState}};
		{noreply, NewMState, Timeout} ->
			{noreply, State#state{mod_state = NewMState}, Timeout};
		{stop, Reason, Reply, NewMState} ->
			{stop, Reason, Reply, State#state{mod_state = NewMState}};
		{stop, Reason, NewMState} ->
			{stop, Reason, State#state{mod_state = NewMState}}
	end.

handle_cast({control, bind_request, _Props}, State = #state{fsm = _FSM}) ->
	{noreply, State};

handle_cast({Ref, on_hello, InPDU}, State = #state{ref = Ref, fsm = FSM, mod = Mod, mod_state = ModState}) ->
	et:trace_me(85, server, client, hello, InPDU),
	{noreply, NModState} = Mod:handle_hello(InPDU, FSM, ModState),
	{noreply, State#state{
		mod_state = NModState
	}};

handle_cast({Ref, on_bind_accept, InPDU}, State = #state{ref = Ref, fsm = FSM, mod = Mod, mod_state = ModState}) ->
	et:trace_me(85, server, client, bind_accept, InPDU),
	{noreply, NModState} = Mod:handle_bind_accept(InPDU, FSM, ModState),
	{noreply, State#state{
		mod_state = NModState
	}};

handle_cast({Ref, on_bind_reject, InPDU}, State = #state{ref = Ref, fsm = FSM, mod = Mod, mod_state = ModState}) ->
	et:trace_me(85, server, client, bind_reject, InPDU),
	{noreply, NModState} = Mod:handle_bind_reject(InPDU, FSM, ModState),
	{noreply, State#state{
		mod_state = NModState
	}};

handle_cast({Ref, on_require_unbind, InPDU}, State = #state{ref = Ref, fsm = FSM, mod = Mod, mod_state = ModState}) ->
	et:trace_me(85, server, client, require_unbind, InPDU),
	{noreply, NModState} = Mod:handle_require_unbind(InPDU, FSM, ModState),
	{noreply, State#state{
		mod_state = NModState
	}};

handle_cast({Ref, on_unbound, InPDU}, State = #state{ref = Ref, fsm = FSM, mod = Mod, mod_state = ModState}) ->
	et:trace_me(85, server, client, unbound, InPDU),
	{noreply, NModState} = Mod:handle_unbind_response(InPDU, FSM, ModState),
	{noreply, State#state{
		mod_state = NModState
	}};

handle_cast({Ref, on_bye, InPDU}, State = #state{ref = Ref, fsm = FSM, mod = Mod, mod_state = ModState}) ->
	et:trace_me(85, server, client, bye, InPDU),
	{noreply, NModState} = Mod:handle_bye(InPDU, FSM, ModState),
	{noreply, State#state{
		mod_state = NModState
	}};

handle_cast({Ref, on_data_pdu, InPDU}, State = #state{ref = Ref, fsm = FSM, mod = Mod, mod_state = ModState}) ->
	et:trace_me(85, server, client, data_pdu, InPDU),
	{noreply, NModState} = Mod:handle_data_pdu(InPDU, FSM, ModState),
	{noreply, State#state{
		mod_state = NModState
	}};

handle_cast(Request, State = #state{fsm = FSM, mod_state = ModState, mod = Mod}) ->
	case Mod:handle_cast(Request, FSM, ModState) of
		{noreply, NewMState} ->
			{noreply, State#state{mod_state = NewMState}};
		{noreply, NewMState, Timeout} ->
			{noreply, State#state{mod_state = NewMState}, Timeout};
		{stop, Reason, NewMState} ->
			{stop, Reason, State#state{mod_state = NewMState}}
	end.

handle_info({'DOWN', _MonitorRef, process, _FSM, Reason}, State = #state{}) ->
	{stop, Reason, State};

handle_info(Message, State = #state{}) ->
	{stop, {bad_arg, Message}, State}.

terminate(Reason, #state{fsm = FSM, mod_state = ModState, mod = Mod}) ->
	ok = Mod:terminate(Reason, FSM, ModState).

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
