-ifndef(billy_session_c_hrl).
-define(billy_session_c_hrl, included).

-type session_cb() :: fun((pid(), any()) -> ok).

-record(billy_session_c_args, {
	cb_on_hello :: session_cb(),
	cb_on_bind_accept :: session_cb(),
	cb_on_bind_reject :: session_cb(),
	cb_on_required_unbind :: session_cb(),
	cb_on_unbound :: session_cb(),
	cb_on_bye :: session_cb(),
	cb_on_data_pdu :: session_cb()
}).

-endif. % billy_session_c_hrl
