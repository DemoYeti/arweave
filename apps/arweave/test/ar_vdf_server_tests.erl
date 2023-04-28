-module(ar_vdf_server_tests).

-export([init/2]).

-include_lib("eunit/include/eunit.hrl").

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").

-import(ar_test_node, [start/3, slave_start/1, disconnect_from_slave/0,
		sign_tx/3, assert_post_tx_to_master/1, slave_mine/0,
		assert_slave_wait_until_height/1, slave_call/3,
		wait_until_height/1, read_block_when_stored/1,
		create_block/2, sign_block/3, post_block/2]).

init(Req, State) ->
	SplitPath = ar_http_iface_server:split_path(cowboy_req:path(Req)),
	handle(SplitPath, Req, State).

handle([<<"vdf">>], Req, State) ->
	{ok, Body, _} = ar_http_req:body(Req, ?MAX_BODY_SIZE),
	{ok, Update} = ar_serialize:binary_to_nonce_limiter_update(Body),

	{SessionKey, _} = Update#nonce_limiter_update.session_key,
	IsPartial  = Update#nonce_limiter_update.is_partial,
	UpdateOutput = hd(Update#nonce_limiter_update.checkpoints),

	Session = Update#nonce_limiter_update.session,
	StepNumber = Session#vdf_session.step_number,
	SessionOutput = hd(Session#vdf_session.steps),

	?assertNotEqual(Update#nonce_limiter_update.checkpoints, Session#vdf_session.steps),
	%% #nonce_limiter_update.checkpoints should be the checkpoints of the last step so
	%% the head of checkpoints should match the head of the session's steps
	?assertEqual(UpdateOutput, SessionOutput),

	case ets:lookup(?MODULE, SessionKey) of
		[{SessionKey, FirstStepNumber, LatestStepNumber}] ->
			?LOG_ERROR("***VDF FOUND*** ~p / ~p", [ar_util:encode(SessionKey), StepNumber]),
			?assert(not IsPartial orelse StepNumber == LatestStepNumber+1, "Partial VDF update did not increase by 1"),
			ets:insert(?MODULE, {SessionKey, FirstStepNumber, StepNumber}),
			{ok, cowboy_req:reply(200, #{}, <<>>, Req), State};
		_ ->
			case IsPartial of
				true ->
					?LOG_ERROR("***VDF NOT FOUND*** ~p / ~p", [ar_util:encode(SessionKey), StepNumber]),
					Bin = ar_serialize:nonce_limiter_update_response_to_binary(
						#nonce_limiter_update_response{ session_found = false }),
					{ok, cowboy_req:reply(202, #{}, Bin, Req), State};
				false ->
					?LOG_ERROR("***VDF INITIALIZING*** ~p / ~p", [ar_util:encode(SessionKey), StepNumber]),
					ets:insert(?MODULE, {SessionKey, StepNumber, StepNumber}),
					{ok, cowboy_req:reply(200, #{}, <<>>, Req), State}
			end
	end.

vdf_server_test_() ->
	% {timeout, 120, fun test_vdf_server_push_fast_block/0},
	{timeout, 120, fun test_vdf_server_push_slow_block/0}.

%% @doc All vdf_server_test_ tests test a few things
%% 1. VDF server posts regular VDF updates to the client
%% 2. For partial updates (session doesn't change), each step number posted is 1 greater than
%%    the one before
%% 3. When the client responds that it doesn't have the session in a partial update, server
%%    should post the full session
%%
%% test_vdf_server_push_fast_block tests that the VDF server can handle receiving
%% a block that is ahead in the VDF chain: specifically:
%%    When a block comes in that starts a new VDF session, the server should first post the
%%    full previous session which should include all steps up to and including the
%%    global_step_number of the block. The server should not post the new session until it has
%%    computed a step in that session - which means the new session's first step will be 1
%%    greater than the last step of the previous session and also 1 greater than the block's
%%    global_step_number
%%
%% test_vdf_server_push_slow_block tests that the VDF server can handle receiving
%% a block that is behind in the VDF chain: specifically:
%%    
test_vdf_server_push_fast_block() ->
	{_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(10000), <<>>}]),

	%% Let the slave get ahead of master in the VDF chain
	slave_start(B0),
	slave_call(ar_http, block_peer_connections, []),
	timer:sleep(3000),

	{ok, Config} = application:get_env(arweave, config),
	Config2 = Config#config{ nonce_limiter_client_peers = [ "127.0.0.1:1986" ]},
	start(B0, ar_wallet:to_address(ar_wallet:new_keyfile()), Config2),

	%% Setup a server to listen for VDF pushes
	ets:new(?MODULE, [named_table, set, public]),
	Routes = [{"/[...]", ar_vdf_server_tests, []}],
	{ok, _} = cowboy:start_clear(
		ar_vdf_server_test_listener,
		[{port, 1986}],
		#{ env => #{ dispatch => cowboy_router:compile([{'_', Routes}]) } }
	),

	%% Mine a block that will be ahead of master in the VDF chain
	slave_mine(),
	BI = assert_slave_wait_until_height(1),
	B1 = slave_call(ar_storage, read_block, [hd(BI)]),

	%% Post the block to master which will cause it to validate VDF for the block under
	%% the B0 session and then begin using the B1 VDF session going forward
	ok = ar_events:subscribe(block),
	post_block(B1, valid),
	timer:sleep(3000),

	SessionKey0 = B0#block.nonce_limiter_info#nonce_limiter_info.next_seed,
	SessionKey1 = B1#block.nonce_limiter_info#nonce_limiter_info.next_seed,
	StepNumber1 = B1#block.nonce_limiter_info#nonce_limiter_info.global_step_number,

	[{SessionKey0, _, LatestStepNumber0}] = ets:lookup(?MODULE, SessionKey0),
	[{SessionKey1, FirstStepNumber1, _}] = ets:lookup(?MODULE, SessionKey1),
	?assertEqual(2, ets:info(?MODULE, size), "VDF server did not post 2 sessions"),
	?assertEqual(FirstStepNumber1, LatestStepNumber0+1),
	?assertEqual(StepNumber1, LatestStepNumber0,
		"VDF server did not post the full Session0 when starting Session1"),

	cowboy:stop_listener(ar_vdf_server_test_listener),
	application:set_env(arweave, config, Config#config{ nonce_limiter_client_peers = [] }).

test_vdf_server_push_slow_block() ->
	{_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(10000), <<>>}]),

	{ok, Config} = application:get_env(arweave, config),
	Config2 = Config#config{ nonce_limiter_client_peers = [ "127.0.0.1:1986" ]},
	start(B0, ar_wallet:to_address(ar_wallet:new_keyfile()), Config2),
	timer:sleep(3000),

	%% Let the slave get ahead of master in the VDF chain
	slave_start(B0),
	slave_call(ar_http, block_peer_connections, []),

	%% Setup a server to listen for VDF pushes
	ets:new(?MODULE, [named_table, set, public]),
	Routes = [{"/[...]", ar_vdf_server_tests, []}],
	{ok, _} = cowboy:start_clear(
		ar_vdf_server_test_listener,
		[{port, 1986}],
		#{ env => #{ dispatch => cowboy_router:compile([{'_', Routes}]) } }
	),

	%% Mine a block that will be ahead of master in the VDF chain
	slave_mine(),
	BI = assert_slave_wait_until_height(1),
	B1 = slave_call(ar_storage, read_block, [hd(BI)]),

	%% Post the block to master which will cause it to validate VDF for the block under
	%% the B0 session and then begin using the B1 VDF session going forward
	ok = ar_events:subscribe(block),
	post_block(B1, valid),
	timer:sleep(3000),

	SessionKey0 = B0#block.nonce_limiter_info#nonce_limiter_info.next_seed,
	SessionKey1 = B1#block.nonce_limiter_info#nonce_limiter_info.next_seed,
	StepNumber1 = B1#block.nonce_limiter_info#nonce_limiter_info.global_step_number,

	[{SessionKey0, _, LatestStepNumber0}] = ets:lookup(?MODULE, SessionKey0),
	[{SessionKey1, FirstStepNumber1, LatestStepNumber1}] = ets:lookup(?MODULE, SessionKey1),
	?assertEqual(2, ets:info(?MODULE, size), "VDF server did not post 2 sessions"),
	?assert(LatestStepNumber0 > FirstStepNumber1, "Session0 should be ahead of Session1"),
	?assert(LatestStepNumber0 > LatestStepNumber1, "Session0 should be ahead of Session1"),
	%% When a block comes in that opens a new session, the server doesn't push an update
	%% until it's computed once step, which is why the FirstStepNumber is 1 more than
	%% the block's global_step_number. Note: in some cases the preivous session will contain
	%% the block's global_step_number, see test_vdf_server_push_fast_block
	?assertEqual(StepNumber1+1, FirstStepNumber1),

	timer:sleep(3000),
	[{SessionKey0, _, NewLatestStepNumber0}] = ets:lookup(?MODULE, SessionKey0),
	[{SessionKey1, _, NewLatestStepNumber1}] = ets:lookup(?MODULE, SessionKey1),
	?assertEqual(LatestStepNumber0, NewLatestStepNumber0,
		"Session0 should not have progressed"),
	?assert(NewLatestStepNumber1 > LatestStepNumber1, "Session1 should have progressed"),

	cowboy:stop_listener(ar_vdf_server_test_listener),
	application:set_env(arweave, config, Config#config{ nonce_limiter_client_peers = [] }).
