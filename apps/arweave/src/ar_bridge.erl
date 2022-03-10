%% This Source Code Form is subject to the terms of the GNU General
%% Public License, v. 2.0. If a copy of the GPLv2 was not distributed
%% with this file, You can obtain one at
%% https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html

%%% @doc The module gossips blocks to peers.
-module(ar_bridge).

-behaviour(gen_server).

-export([start_link/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").

-record(state, {
	block_propagation_queue = gb_sets:new(),
	workers
}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Name, Workers) ->
	gen_server:start_link({local, Name}, ?MODULE, Workers, []).

%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%					   {ok, State, Timeout} |
%%					   ignore |
%%					   {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Workers) ->
	process_flag(trap_exit, true),
	ar_events:subscribe(block),
	WorkerMap = lists:foldl(fun(W, Acc) -> maps:put(W, free, Acc) end, #{}, Workers),
	State = #state{ workers = WorkerMap },
	{ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%									 {reply, Reply, State} |
%%									 {reply, Reply, State, Timeout} |
%%									 {noreply, State} |
%%									 {noreply, State, Timeout} |
%%									 {stop, Reason, Reply, State} |
%%									 {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(Request, _From, State) ->
	?LOG_WARNING("unhandled call: ~p", [Request]),
	{reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%									{noreply, State, Timeout} |
%%									{stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_cast({may_be_send_block, W}, State) ->
	#state{ workers = Workers, block_propagation_queue = Q } = State,
	case dequeue(Q) of
		empty ->
			{noreply, State};
		{{_Priority, Peer, B, BDS}, Q2} ->
			case maps:get(W, Workers) of
				free ->
					gen_server:cast(W, {send_block, Peer, B, BDS, self()}),
					{noreply, State#state{ block_propagation_queue = Q2,
							workers = maps:put(W, busy, Workers) }};
				busy ->
					{noreply, State}
			end
	end;

handle_cast(Msg, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {message, Msg}]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%									 {noreply, State, Timeout} |
%%									 {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({event, block, {new, _Block, ar_poller}}, State) ->
	%% ar_poller often fetches blocks when the network already knows about them
	%% so do not gossip.
	{noreply, State};

handle_info({event, block, {new, B, _Source}}, State) ->
	#state{ block_propagation_queue = Q, workers = Workers } = State,
	case ar_block_cache:get(block_cache, B#block.previous_block) of
		not_found ->
			%% The cache should have been just pruned and this block is old.
			{noreply, State};
		_ ->
			{ok, Config} = application:get_env(arweave, config),
			TrustedPeers = ar_peers:get_trusted_peers(),
			SpecialPeers = Config#config.block_gossip_peers,
			Peers = ((SpecialPeers ++ ar_peers:get_peers()) -- TrustedPeers)
					++ TrustedPeers,
			BDS = ar_block:generate_block_data_segment(B),
			Q2 = enqueue_block(Peers, B, BDS, Q),
			[gen_server:cast(?MODULE, {may_be_send_block, W}) || W <- maps:keys(Workers)],
			{noreply, State#state{ block_propagation_queue = Q2 }}
	end;

handle_info({event, block, {mined, _Block, _TXs, _CurrentBH}}, State) ->
	%% This event is handled by ar_node_worker. Ignore it.
	{noreply, State};

handle_info({worker_sent_block, W},
		#state{ workers = Workers, block_propagation_queue = Q } = State) ->
	case dequeue(Q) of
		empty ->
			{noreply, State#state{ workers = maps:put(W, free, Workers) }};
		{{_Priority, Peer, B, BDS}, Q2} ->
			gen_server:cast(W, {send_block, Peer, B, BDS, self()}),
			{noreply, State#state{ block_propagation_queue = Q2,
					workers = maps:put(W, busy, Workers) }}
	end;

handle_info(Info, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {info, Info}]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
	?LOG_INFO([{event, ar_bridge_terminated}, {module, ?MODULE}]),
	ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

enqueue_block(Peers, B, BDS, Q) ->
	enqueue_block(Peers, B, BDS, Q, 0).

enqueue_block([], _B, _BDS, Q, _N) ->
	Q;
enqueue_block([Peer | Peers], B, BDS, Q, N) ->
	Priority = {N, B#block.height},
	enqueue_block(Peers, B, BDS, gb_sets:add_element({Priority, Peer, B, BDS}, Q)).

dequeue(Q) ->
	case gb_sets:is_empty(Q) of
		true ->
			empty;
		false ->
			gb_sets:take_smallest(Q)
	end.
