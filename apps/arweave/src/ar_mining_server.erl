%%% @doc The 2.6 mining server.
-module(ar_mining_server).

-behaviour(gen_server).

-export([start_link/0, start_mining/1, set_difficulty/1, set_merkle_rebase_threshold/1, 
		prepare_solution/2, validate_solution/1,
		compute_h2_for_peer/1, load_poa/2, get_recall_bytes/4, active_sessions/0,
		encode_sessions/1, add_pool_job/6, is_one_chunk_solution/1]).
-export([pause/0]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_data_discovery.hrl").
-include_lib("arweave/include/ar_mining.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-record(state, {
	paused 						= true,
	workers						= #{},
	active_sessions				= sets:new(),
	seeds						= #{},
	diff_pair					= not_set,
	chunk_cache_limit 			= 0,
	gc_frequency_ms				= undefined,
	gc_process_ref				= undefined,
	merkle_rebase_threshold		= infinity
}).

-define(FETCH_POA_FROM_PEERS_TIMEOUT_MS, 10000).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the gen_server.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Start mining.
start_mining(Args) ->
	gen_server:cast(?MODULE, {start_mining, Args}).

%% @doc Compute H2 for a remote peer (used in coordinated mining).
compute_h2_for_peer(Candidate) ->
	gen_server:cast(?MODULE, {compute_h2_for_peer, Candidate}).

%% @doc Set the new mining difficulty. We do not recalculate it inside the mining
%% server because we want to completely detach the mining server from the block
%% ordering. The previous block is chosen only after the mining solution is found (if
%% we choose it in advance we may miss a better option arriving in the process).
%% Also, a mining session may (in practice, almost always will) span several blocks.
set_difficulty(DiffPair) ->
	gen_server:cast(?MODULE, {set_difficulty, DiffPair}).

set_merkle_rebase_threshold(Threshold) ->
	gen_server:cast(?MODULE, {set_merkle_rebase_threshold, Threshold}).

%% @doc Add a pool job to the mining queue.
add_pool_job(SessionKey, StepNumber, Output, PartitionUpperBound, Seed, PartialDiff) ->
	Args = {SessionKey, StepNumber, Output, PartitionUpperBound, Seed, PartialDiff},
	gen_server:cast(?MODULE, {add_pool_job, Args}).

active_sessions() ->
	gen_server:call(?MODULE, active_sessions).

encode_sessions(Sessions) ->
	lists:map(fun(SessionKey) ->
		ar_nonce_limiter:encode_session_key(SessionKey)
	end, sets:to_list(Sessions)).

is_one_chunk_solution(Solution) ->
	Solution#mining_solution.recall_byte2 == undefined.

prepare_solution(Candidate, SkipVDF) ->
	gen_server:cast(?MODULE, {prepare_solution, Candidate, SkipVDF}).

validate_solution(Solution) ->
	gen_server:cast(?MODULE, {validate_solution, Solution}).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	%% Trap exit to avoid corrupting any open files on quit.
	process_flag(trap_exit, true),
	ok = ar_events:subscribe(nonce_limiter),
	ar_chunk_storage:open_files("default"),

	Workers = lists:foldl(
		fun({Partition, _}, Acc) ->
			maps:put(Partition, ar_mining_worker:name(Partition), Acc)
		end,
		#{},
		ar_mining_io:get_partitions(infinity)
	),

	{ok, #state{
		workers = Workers
	}}.

handle_call(active_sessions, _From, State) ->
	{reply, State#state.active_sessions, State};

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_cast(pause, State) ->
	ar:console("Pausing mining.~n"),
	?LOG_INFO([{event, pause_mining}]),
	ar_mining_stats:mining_paused(),
	%% Setting paused to true allows all pending tasks to complete, but prevents new output to be 
	%% distributed. Setting diff to infinity ensures that no solutions are found.
	State2 = set_difficulty({infinity, infinity}, State),
	{noreply, State2#state{ paused = true }};

handle_cast({start_mining, Args}, State) ->
	{DiffPair, RebaseThreshold} = Args,
	ar:console("Starting mining.~n"),
	?LOG_INFO([{event, start_mining}, {difficulty, DiffPair},
			{rebase_threshold, RebaseThreshold}]),
	ar_mining_stats:start_performance_reports(),

	maps:foreach(
		fun(_Partition, Worker) ->
			ar_mining_worker:reset(Worker, DiffPair)
		end,
		State#state.workers
	),

	{noreply, State#state{ 
		paused = false,
		active_sessions	= sets:new(),
		diff_pair = DiffPair,
		merkle_rebase_threshold = RebaseThreshold }};

handle_cast({set_difficulty, DiffPair}, State) ->
	State2 = set_difficulty(DiffPair, State),
	{noreply, State2};

handle_cast({set_merkle_rebase_threshold, Threshold}, State) ->
	{noreply, State#state{ merkle_rebase_threshold = Threshold }};

handle_cast({add_pool_job, Args}, State) ->
	{SessionKey, StepNumber, Output, PartitionUpperBound, Seed, PartialDiff} = Args,
	State2 = set_seed(SessionKey, Seed, State),
	handle_computed_output(
		SessionKey, StepNumber, Output, PartitionUpperBound, PartialDiff, State2);

handle_cast({compute_h2_for_peer, Candidate}, State) ->
	#mining_candidate{ partition_number2 = Partition2 } = Candidate,
	case get_worker(Partition2, State) of
		not_found ->
			ok;
		Worker ->
			ar_mining_worker:add_task(Worker, compute_h2_for_peer, Candidate)
	end,
	{noreply, State};

handle_cast({manual_garbage_collect, Ref}, #state{ gc_process_ref = Ref } = State) ->
	%% Reading recall ranges from disk causes a large amount of binary data to be allocated and
	%% references to that data is spread among all the different mining processes. Because of this
	%% it can take the default garbage collection to clean up all references and deallocate the
	%% memory - which in turn can cause memory to be exhausted.
	%% 
	%% To address this the mining server will force a garbage collection on all mining processes
	%% every time we process a few VDF steps. The exact number of VDF steps is determined by
	%% the chunk cache size limit in order to roughly align garbage collection with when we
	%% expect all references to a recall range's chunks to be evicted from the cache.
	?LOG_DEBUG([{event, mining_debug_garbage_collect_start}]),
	ar_mining_io:garbage_collect(),
	ar_mining_hash:garbage_collect(),
	erlang:garbage_collect(self(), [{async, erlang:monotonic_time()}]),
	maps:foreach(
		fun(_Partition, Worker) ->
			ar_mining_worker:garbage_collect(Worker)
		end,
		State#state.workers
	),
	ar_coordination:garbage_collect(),
	ar_util:cast_after(State#state.gc_frequency_ms, ?MODULE, {manual_garbage_collect, Ref}),
	{noreply, State};
handle_cast({manual_garbage_collect, _}, State) ->
	%% Does not originate from the running instance of the server; happens in tests.
	{noreply, State};

handle_cast({prepare_solution, Candidate, SkipVDF}, State) ->
	#mining_candidate{
		mining_address = MiningAddress, next_seed = NextSeed, 
		next_vdf_difficulty = NextVDFDifficulty, nonce = Nonce,
		nonce_limiter_output = NonceLimiterOutput, partition_number = PartitionNumber,
		partition_upper_bound = PartitionUpperBound, poa2 = PoA2, preimage = Preimage,
		seed = Seed, start_interval_number = StartIntervalNumber, step_number = StepNumber
	} = Candidate,
	
	Solution = #mining_solution{
		mining_address = MiningAddress,
		next_seed = NextSeed,
		next_vdf_difficulty = NextVDFDifficulty,
		nonce = Nonce,
		nonce_limiter_output = NonceLimiterOutput,
		partition_number = PartitionNumber,
		partition_upper_bound = PartitionUpperBound,
		poa2 = PoA2,
		preimage = Preimage,
		seed = Seed,
		start_interval_number = StartIntervalNumber,
		step_number = StepNumber
	},
	
	Solution2 = case SkipVDF of
		true ->
			prepare_solution_proofs(Candidate, Solution);
		false ->
			prepare_solution_last_step_checkpoints(Candidate, Solution)
	end,
	case Solution2 of
		error -> ok;
		_ -> ar_mining_router:route_solution(Solution2)
	end,
	{noreply, State};

handle_cast({validate_solution, Solution}, State) ->
	#state{ diff_pair = DiffPair } = State,
	case validate_solution(Solution, DiffPair) of
		error ->
			ar_mining_router:reject_solution(Solution, failed_to_validate_solution, []);
		{false, Reason} ->
			ar_mining_router:reject_solution(Solution, Reason, []);
		{true, PoACache, PoA2Cache} ->
			ar_events:send(miner, {found_solution, miner, Solution, PoACache, PoA2Cache})
	end,
	{noreply, State};

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_info({event, nonce_limiter, {computed_output, _Args}}, #state{ paused = true } = State) ->
	{noreply, State};
handle_info({event, nonce_limiter, {computed_output, Args}}, State) ->
	case ar_pool:is_client() of
		true ->
			%% Ignore VDF events because we are receiving jobs from the pool.
			{noreply, State};
		false ->
			{SessionKey, StepNumber, Output, PartitionUpperBound} = Args,
			handle_computed_output(
				SessionKey, StepNumber, Output, PartitionUpperBound, not_set, State)
	end;

handle_info({event, nonce_limiter, Message}, State) ->
	?LOG_DEBUG([{event, mining_debug_skipping_nonce_limiter}, {message, Message}]),
	{noreply, State};

handle_info({garbage_collect, StartTime, GCResult}, State) ->
	EndTime = erlang:monotonic_time(),
	ElapsedTime = erlang:convert_time_unit(EndTime-StartTime, native, millisecond),
	case GCResult == false orelse ElapsedTime > ?GC_LOG_THRESHOLD of
		true ->
			?LOG_DEBUG([
				{event, mining_debug_garbage_collect}, {process, ar_mining_server}, {pid, self()},
				{gc_time, ElapsedTime}, {gc_result, GCResult}]);
		false ->
			ok
	end,
	{noreply, State};

handle_info({fetched_last_moment_proof, _}, State) ->
    %% This is a no-op to handle "slow" response from peers that were queried by `fetch_poa_from_peers`
    %% Only the first peer to respond with a PoA will be handled, all other responses will fall through to here
    %% an be ignored.
	{noreply, State};

handle_info(Message, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {message, Message}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

get_worker(Partition, State) ->
	maps:get(Partition, State#state.workers, not_found).

set_difficulty(DiffPair, State) ->
	maps:foreach(
		fun(_Partition, Worker) ->
			ar_mining_worker:set_difficulty(Worker, DiffPair)
		end,
		State#state.workers
	),
	State#state{ diff_pair = DiffPair }.

maybe_update_sessions(SessionKey, State) ->
	CurrentActiveSessions = State#state.active_sessions,
	case sets:is_element(SessionKey, CurrentActiveSessions) of
		true ->
			State;
		false ->
			NewActiveSessions = build_active_session_set(SessionKey, CurrentActiveSessions),
			case sets:to_list(sets:subtract(NewActiveSessions, CurrentActiveSessions)) of
				[] ->
					State;
				_ ->
					update_sessions(NewActiveSessions, CurrentActiveSessions, State)
			end
	end.

build_active_session_set(SessionKey, CurrentActiveSessions) ->
	CandidateSessions = [SessionKey | sets:to_list(CurrentActiveSessions)],
	SortedSessions = lists:sort(
		fun({_, StartIntervalA, _}, {_, StartIntervalB, _}) ->
			StartIntervalA > StartIntervalB
		end, CandidateSessions),
	build_active_session_set(SortedSessions).

build_active_session_set([A, B | _]) ->
	sets:from_list([A, B]);
build_active_session_set([A]) ->
	sets:from_list([A]);
build_active_session_set([]) ->
	sets:new().

update_sessions(NewActiveSessions, CurrentActiveSessions, State) ->
	AddedSessions = sets:to_list(sets:subtract(NewActiveSessions, CurrentActiveSessions)),
	RemovedSessions = sets:to_list(sets:subtract(CurrentActiveSessions, NewActiveSessions)),

	maps:foreach(
		fun(_Partition, Worker) ->
			ar_mining_worker:set_sessions(Worker, NewActiveSessions)
		end,
		State#state.workers
	),

	State2 = add_sessions(AddedSessions, State),
	State3 = remove_sessions(RemovedSessions, State2),

	State3#state{ active_sessions = NewActiveSessions }.

add_sessions([], State) ->
	State;
add_sessions([SessionKey | AddedSessions], State) ->
	{NextSeed, StartIntervalNumber, NextVDFDifficulty} = SessionKey,
	ar:console("Starting new mining session: "
		"next entropy nonce: ~s, interval number: ~B, next vdf difficulty: ~B.~n",
		[ar_util:safe_encode(NextSeed), StartIntervalNumber, NextVDFDifficulty]),
	?LOG_INFO([{event, new_mining_session}, 
		{session_key, ar_nonce_limiter:encode_session_key(SessionKey)}]),
	add_sessions(AddedSessions, add_seed(SessionKey, State)).

remove_sessions([], State) ->
	State;
remove_sessions([SessionKey | RemovedSessions], State) ->
	remove_sessions(RemovedSessions, remove_seed(SessionKey, State)).

get_seed(SessionKey, State) ->
	maps:get(SessionKey, State#state.seeds, not_found).

set_seed(SessionKey, Seed, State) ->
	State#state{ seeds = maps:put(SessionKey, Seed, State#state.seeds) }.

remove_seed(SessionKey, State) ->
	State#state{ seeds = maps:remove(SessionKey, State#state.seeds) }.

add_seed(SessionKey, State) ->
	case get_seed(SessionKey, State) of
		not_found ->
			Session = ar_nonce_limiter:get_session(SessionKey),
			case Session of
				not_found ->
					?LOG_ERROR([{event, mining_session_not_found},
						{session_key, ar_nonce_limiter:encode_session_key(SessionKey)}]),
					State;
				_ ->
					set_seed(SessionKey, Session#vdf_session.seed, State)
			end;
		_ ->
			State
	end.

update_cache_limits(State) ->
	NumActivePartitions = length(ar_mining_io:get_partitions()),
	update_cache_limits(NumActivePartitions, State).

update_cache_limits(0, State) ->
	State;
update_cache_limits(NumActivePartitions, State) ->
	%% This allows the cache to store enough chunks for 4 concurrent VDF steps per partition.
	IdealStepsPerPartition = 4,
	IdealRangesPerStep = 2,
	ChunksPerRange = ?RECALL_RANGE_SIZE div ?DATA_CHUNK_SIZE,
	IdealCacheLimit = ar_util:ceil_int(
		IdealStepsPerPartition * IdealRangesPerStep * ChunksPerRange * NumActivePartitions, 100),

	{ok, Config} = application:get_env(arweave, config),
	OverallCacheLimit = case Config#config.mining_server_chunk_cache_size_limit of
		undefined ->
			IdealCacheLimit;
		N ->
			N
	end,

	%% We shard the chunk cache across every active worker. Only workers that mine a partition
	%% included in the current weave are active.
	NewCacheLimit = max(1, OverallCacheLimit div NumActivePartitions),

	case NewCacheLimit == State#state.chunk_cache_limit of
		true ->
			State;
		false ->
			%% Allow enough compute_h0 tasks to be queued to completely refill the chunk cache.
			VDFQueueLimit = NewCacheLimit div (2 * ChunksPerRange),
			maps:foreach(
				fun(_Partition, Worker) ->
					ar_mining_worker:set_cache_limits(Worker, NewCacheLimit, VDFQueueLimit)
				end,
				State#state.workers
			),

			ar:console(
				"~nSetting the mining chunk cache size limit to ~B chunks "
				"(~B chunks per partition).~n", [OverallCacheLimit, NewCacheLimit]),
			?LOG_INFO([{event, update_mining_cache_limits},
				{limit, OverallCacheLimit}, {per_partition, NewCacheLimit},
				{vdf_queue_limit, VDFQueueLimit}]),
			case OverallCacheLimit < IdealCacheLimit of
				true ->
					ar:console("~nChunk cache size limit is below minimum limit of ~p. "
						"Mining performance may be impacted.~n"
						"Consider changing the 'mining_server_chunk_cache_size_limit' option.",
						[IdealCacheLimit]);
				false -> ok
			end,
			GarbageCollectionFrequency = 4 * VDFQueueLimit * 1000,
			GCRef =
				case State#state.gc_frequency_ms == undefined of
					true ->
						%% This is the first time setting the garbage collection frequency,
						%% so kick off the periodic call.
						Ref = make_ref(),
						ar_util:cast_after(GarbageCollectionFrequency, ?MODULE,
								{manual_garbage_collect, Ref}),
						Ref;
					false ->
						State#state.gc_process_ref
				end,
			State#state{
				chunk_cache_limit = NewCacheLimit,
				gc_frequency_ms = GarbageCollectionFrequency,
				gc_process_ref = GCRef
			}
	end.

distribute_output(Candidate, State) ->
	distribute_output(ar_mining_io:get_partitions(), Candidate, State).

distribute_output([], _Candidate, _State) ->
	ok;
distribute_output([{Partition, MiningAddress} | Partitions], Candidate, State) ->
	case get_worker(Partition, State) of
		not_found ->
			?LOG_ERROR([{event, worker_not_found}, {partition, Partition}]),
			ok;
		Worker ->
			ar_mining_worker:add_task(
				Worker, compute_h0,
				Candidate#mining_candidate{
					partition_number = Partition,
					mining_address = MiningAddress
				})
	end,
	distribute_output(Partitions, Candidate, State).

get_recall_bytes(H0, PartitionNumber, Nonce, PartitionUpperBound) ->
	{RecallRange1Start, RecallRange2Start} = ar_block:get_recall_range(H0,
			PartitionNumber, PartitionUpperBound),
	RelativeOffset = Nonce * (?DATA_CHUNK_SIZE),
	{RecallRange1Start + RelativeOffset, RecallRange2Start + RelativeOffset}.

prepare_solution_last_step_checkpoints(Candidate, Solution) ->
	#mining_candidate{
		next_seed = NextSeed, next_vdf_difficulty = NextVDFDifficulty, 
		start_interval_number = StartIntervalNumber, step_number = StepNumber } = Candidate,
	LastStepCheckpoints = ar_nonce_limiter:get_step_checkpoints(
			StepNumber, NextSeed, StartIntervalNumber, NextVDFDifficulty),
	LastStepCheckpoints2 =
		case LastStepCheckpoints of
			not_found ->
				?LOG_WARNING([{event,
						found_solution_but_failed_to_find_last_step_checkpoints}]),
				[];
			_ ->
				LastStepCheckpoints
		end,
	prepare_solution_steps(Candidate, Solution#mining_solution{
			last_step_checkpoints = LastStepCheckpoints2 }).

prepare_solution_steps(Candidate, Solution) ->
	#mining_candidate{ step_number = StepNumber } = Candidate,
	[{_, TipNonceLimiterInfo}] = ets:lookup(node_state, nonce_limiter_info),
	#nonce_limiter_info{ global_step_number = PrevStepNumber, next_seed = PrevNextSeed,
			next_vdf_difficulty = PrevNextVDFDifficulty } = TipNonceLimiterInfo,
	case StepNumber > PrevStepNumber of
		true ->
			Steps = ar_nonce_limiter:get_steps(
					PrevStepNumber, StepNumber, PrevNextSeed, PrevNextVDFDifficulty),
			case Steps of
				not_found ->
					ar_mining_router:reject_solution(Solution, failed_to_find_checkpoints,
						[{prev_next_seed, ar_util:safe_encode(PrevNextSeed)},
						 {prev_step_number, PrevStepNumber}]),
					error;
				_ ->
					prepare_solution_proofs(Candidate,
							Solution#mining_solution{ steps = Steps })
			end;
		false ->
			ar_mining_router:reject_solution(Solution, stale_step_number,
						[{prev_next_seed, ar_util:safe_encode(PrevNextSeed)},
						 {prev_step_number, PrevStepNumber}]),
			error
	end.

prepare_solution_proofs(Candidate, Solution) ->
	#mining_candidate{
		h0 = H0, h1 = H1, h2 = H2, nonce = Nonce, partition_number = PartitionNumber,
		partition_upper_bound = PartitionUpperBound } = Candidate,
	#mining_solution{ poa1 = PoA1, poa2 = PoA2 } = Solution,
	{RecallByte1, RecallByte2} = get_recall_bytes(H0, PartitionNumber, Nonce,
			PartitionUpperBound),
	case { H1, H2 } of
		{not_set, not_set} ->
			ar_mining_router:reject_solution(Solution, h1_h2_not_set, []),
			error;
		{H1, not_set} ->
			prepare_solution_poa1(Candidate, Solution#mining_solution{
				solution_hash = H1, recall_byte1 = RecallByte1,
				poa1 = may_be_empty_poa(PoA1), poa2 = #poa{} });
		{_, H2} ->
			prepare_solution_poa2(Candidate, Solution#mining_solution{
				solution_hash = H2, recall_byte1 = RecallByte1, recall_byte2 = RecallByte2,
				poa1 = may_be_empty_poa(PoA1), poa2 = may_be_empty_poa(PoA2) })
	end.

prepare_solution_poa1(Candidate,
		#mining_solution{ poa1 = #poa{ chunk = <<>> } } = Solution) ->
	#mining_solution{ recall_byte1 = RecallByte1 } = Solution,
	case load_poa(RecallByte1, Candidate) of
		not_found ->
			ar_mining_router:reject_solution(Solution, failed_to_read_chunk_proofs, []),
			error;
		PoA -> Solution#mining_solution{ poa1 = PoA }
	end.
prepare_solution_poa2(Candidate,
		#mining_solution{ poa2 = #poa{ chunk = <<>> } } = Solution) ->
	#mining_solution{ recall_byte2 = RecallByte2 } = Solution,
	case load_poa(RecallByte2, Candidate) of
		not_found ->
			ar_mining_router:reject_solution(Solution, failed_to_read_chunk_proofs, []),
			error;
		PoA -> Solution#mining_solution{ poa2 = PoA }
	end;
prepare_solution_poa2(Candidate,
		#mining_solution{ poa1 = #poa{ chunk = <<>> } } = Solution) ->
	prepare_solution_poa1(Candidate, Solution).

may_be_empty_poa(not_set) ->
	#poa{};
may_be_empty_poa(#poa{} = PoA) ->
	PoA.

fetch_poa_from_peers(RecallByte) ->
	Peers = ar_data_discovery:get_bucket_peers(RecallByte div ?NETWORK_DATA_BUCKET_SIZE),
	From = self(),
	lists:foreach(
		fun(Peer) ->
			spawn(
				fun() ->
					?LOG_INFO([{event, last_moment_proof_search},
							{peer, ar_util:format_peer(Peer)}, {recall_byte, RecallByte}]),
					case fetch_poa_from_peer(Peer, RecallByte) of
						not_found ->
							ok;
						PoA ->
							From ! {fetched_last_moment_proof, PoA}
					end
				end)
		end,
		Peers
	),
	receive
         %% The first spawned process to fetch a PoA from a peer will trigger this `receive` and allow
         %% `fetch_poa_from_peers` to exit. All other processes that complete later will trigger the
         %% `handle_info({fetched_last_moment_proof, _}, State) ->` above (which is a no-op)
		{fetched_last_moment_proof, PoA} ->
			PoA
		after ?FETCH_POA_FROM_PEERS_TIMEOUT_MS ->
			not_found
	end.

fetch_poa_from_peer(Peer, RecallByte) ->
	case ar_http_iface_client:get_chunk_binary(Peer, RecallByte + 1, any) of
		{ok, #{ data_path := DataPath, tx_path := TXPath }, _, _} ->
			#poa{ data_path = DataPath, tx_path = TXPath };
		_ ->
			not_found
	end.

handle_computed_output(SessionKey, StepNumber, Output, PartitionUpperBound,
		PartialDiff, State) ->
	true = is_integer(StepNumber),
	ar_mining_stats:vdf_computed(),

	State2 = case ar_mining_io:set_largest_seen_upper_bound(PartitionUpperBound) of
		true ->
			%% If the largest seen upper bound changed, a new partition may have been added
			%% to the mining set, so we may need to update the chunk cache size limit.
			update_cache_limits(State);
		false ->
			State
	end,

	State3 = maybe_update_sessions(SessionKey, State2),

	case sets:is_element(SessionKey, State3#state.active_sessions) of
		false ->
			?LOG_DEBUG([{event, mining_debug_skipping_vdf_output}, {reason, stale_session},
				{step_number, StepNumber},
				{session_key, ar_nonce_limiter:encode_session_key(SessionKey)},
				{active_sessions, encode_sessions(State#state.active_sessions)}]);
		true ->
			{NextSeed, StartIntervalNumber, NextVDFDifficulty} = SessionKey,
			Candidate = #mining_candidate{
				session_key = SessionKey,
				seed = get_seed(SessionKey, State3),
				next_seed = NextSeed,
				next_vdf_difficulty = NextVDFDifficulty,
				start_interval_number = StartIntervalNumber,
				step_number = StepNumber,
				nonce_limiter_output = Output,
				partition_upper_bound = PartitionUpperBound,
				diff_pair = PartialDiff
			},
			distribute_output(Candidate, State3),
			?LOG_DEBUG([{event, mining_debug_processing_vdf_output},
				{step_number, StepNumber}, {output, ar_util:safe_encode(Output)},
				{start_interval_number, StartIntervalNumber},
				{session_key, ar_nonce_limiter:encode_session_key(SessionKey)}])
	end,
	{noreply, State3}.

load_poa(RecallByte, Candidate) ->
	#mining_candidate{ chunk1 = Chunk1, chunk2 = Chunk2, 
			h1 = H1, h2 = H2, mining_address = MiningAddress } = Candidate,
	Chunk = case {H1, H2} of
		{H1, not_set} -> Chunk1;
		{_, H2} -> Chunk2
	end,

	case read_poa(RecallByte, Chunk, MiningAddress) of
		{ok, PoA} ->
			PoA;
		_ ->
			Modules = ar_storage_module:get_all(RecallByte + 1),
			ModuleIDs = [ar_storage_module:id(Module) || Module <- Modules],
			?LOG_ERROR([{event, failed_to_find_poa_proofs_locally},
					{tags, [solution_proofs]},
					{recall_byte, RecallByte},
					{modules_covering_recall_byte, ModuleIDs}]),
			ar:console("WARNING: we have found a solution but did not "
					"find the PoA proofs locally - searching the peers...~n"),
			case fetch_poa_from_peers(RecallByte) of
				not_found ->
					not_found;
				PoA ->
					PoA#poa{ chunk = Chunk }
			end
	end.

read_poa(RecallByte, Chunk, MiningAddress) ->
	PoAReply = read_poa(RecallByte, MiningAddress),
	case {Chunk, PoAReply} of
		{not_set, _} ->
			PoAReply;
		{Chunk, {ok, #poa{ chunk = Chunk }}} ->
			PoAReply;
		{_Chunk, {ok, #poa{}}} ->
			{error, chunk_mismatch};
		{_, Error} ->
			Error
	end.

read_poa(RecallByte, MiningAddress) ->
	Options = #{ pack => true, packing => {spora_2_6, MiningAddress},
			is_miner_request => true },
	case ar_data_sync:get_chunk(RecallByte + 1, Options) of
		{ok, #{ chunk := Chunk, tx_path := TXPath, data_path := DataPath }} ->
			{ok, #poa{ option = 1, chunk = Chunk, tx_path = TXPath, data_path = DataPath }};
		Error ->
			Error
	end.

validate_solution(Solution, DiffPair) ->
	#mining_solution{
		mining_address = MiningAddress,
		nonce = Nonce, nonce_limiter_output = NonceLimiterOutput,
		partition_number = PartitionNumber, partition_upper_bound = PartitionUpperBound,
		poa1 = PoA1, recall_byte1 = RecallByte1, seed = Seed,
		solution_hash = SolutionHash } = Solution,
	H0 = ar_block:compute_h0(NonceLimiterOutput, PartitionNumber, Seed, MiningAddress),
	{H1, _Preimage1} = ar_block:compute_h1(H0, Nonce, PoA1#poa.chunk),
	{RecallRange1Start, RecallRange2Start} = ar_block:get_recall_range(H0,
			PartitionNumber, PartitionUpperBound),
	%% Assert recall_byte1 is computed correctly.
	RecallByte1 = RecallRange1Start + Nonce * ?DATA_CHUNK_SIZE,
	{BlockStart1, BlockEnd1, TXRoot1} = ar_block_index:get_block_bounds(RecallByte1),
	BlockSize1 = BlockEnd1 - BlockStart1,
	case ar_poa:validate({BlockStart1, RecallByte1, TXRoot1, BlockSize1, PoA1,
			{spora_2_6, MiningAddress}, not_set}) of
		{true, ChunkID} ->
			PoACache = {{BlockStart1, RecallByte1, TXRoot1, BlockSize1,
					{spora_2_6, MiningAddress}}, ChunkID},
			case ar_node_utils:h1_passes_diff_check(H1, DiffPair) of
				true ->
					%% validates solution_hash
					SolutionHash = H1,
					{true, PoACache, undefined};
				false ->
					case is_one_chunk_solution(Solution) of
						true ->
							%% This can happen if the difficulty has increased between the
							%% time the H1 solution was found and now. In this case,
							%% there is no H2 solution, so we flag the solution invalid.
							{false, h1_diff_check};
						false ->
							#mining_solution{
								recall_byte2 = RecallByte2, poa2 = PoA2 } = Solution,
							{H2, _Preimage2} = ar_block:compute_h2(H1, PoA2#poa.chunk, H0),
							case ar_node_utils:h2_passes_diff_check(H2, DiffPair) of
								false ->
									{false, h2_diff_check};
								true ->
									
									%% validates solution_hash
									SolutionHash = H2,
									%% validates recall_byte2
									RecallByte2 = RecallRange2Start + Nonce * ?DATA_CHUNK_SIZE,
									{BlockStart2, BlockEnd2, TXRoot2} =
											ar_block_index:get_block_bounds(RecallByte2),
									BlockSize2 = BlockEnd2 - BlockStart2,
									case ar_poa:validate({BlockStart2, RecallByte2, TXRoot2,
											BlockSize2, PoA2,
											{spora_2_6, MiningAddress}, not_set}) of
										{true, Chunk2ID} ->
											PoA2Cache = {{BlockStart2, RecallByte2, TXRoot2,
													BlockSize2, {spora_2_6, MiningAddress}},
													Chunk2ID},
											{true, PoACache, PoA2Cache};
										error ->
											error;
										false ->
											{false, poa2}
									end
							end
					end
			end;
		error ->
			error;
		false ->
			{false, poa1}
	end.

%%%===================================================================
%%% Public Test interface.
%%%===================================================================

%% @doc Pause the mining server. Only used in tests.
pause() ->
	gen_server:cast(?MODULE, pause).
