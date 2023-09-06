-module(ar_nonce_limiter).

-behaviour(gen_server).

-export([start_link/0, is_ahead_on_the_timeline/2, get_current_step_number/0,
		get_current_step_number/1, get_seed_data/2, get_step_checkpoints/3,
		get_steps/3, validate_last_step_checkpoints/3, request_validation/3,
		get_or_init_nonce_limiter_info/1, get_or_init_nonce_limiter_info/2,
		apply_external_update/2, get_session/1, 
		compute/3, resolve_remote_server_raw_peers/0,
		get_entropy_reset_point/2, maybe_add_entropy/4, mix_seed/2]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_vdf.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_pricing.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {
	current_session_key,
	sessions = gb_sets:new(),
	session_by_key = #{}, % {NextSeed, StartIntervalNumber} => #vdf_session
	worker,
	worker_monitor_ref,
	autocompute = true,
	computing = false,
	last_external_update = {not_set, 0},
	emit_initialized_event = true
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Return true if the first solution is above the second one according
%% to the protocol ordering.
is_ahead_on_the_timeline(NonceLimiterInfo1, NonceLimiterInfo2) ->
	#nonce_limiter_info{ global_step_number = N1 } = NonceLimiterInfo1,
	#nonce_limiter_info{ global_step_number = N2 } = NonceLimiterInfo2,
	N1 > N2.

%% @doc Return the latest known step number.
get_current_step_number() ->
	gen_server:call(?MODULE, get_current_step_number, infinity).

%% @doc Return the latest known step number in the session of the given (previous) block.
%% Return not_found if the session is not found.
get_current_step_number(B) ->
	#block{ nonce_limiter_info = #nonce_limiter_info{ next_seed = NextSeed,
			global_step_number = StepNumber } } = B,
	SessionKey = {NextSeed, StepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},
	gen_server:call(?MODULE, {get_current_step_number, SessionKey}, infinity).

%% @doc Return {Seed, NextSeed, PartitionUpperBound, NextPartitionUpperBound, VDFDifficulty}
%% for the block mined at StepNumber considering its previous block PrevB.
%% The previous block's independent hash, weave size, and VDF difficulty
%% become the new NextSeed, NextPartitionUpperBound, and NextVDFDifficulty
%% accordingly when we cross the next reset line.
%% Note: next_vdf_difficulty is not part of the seed data as it is computed using the
%% block_time_history - which is a heavier operation handled separate from the (quick) seed data
%% retrieval
get_seed_data(StepNumber, PrevB) ->
	NonceLimiterInfo = PrevB#block.nonce_limiter_info,
	#nonce_limiter_info{
		global_step_number = PrevStepNumber,
		seed = Seed, next_seed = NextSeed,
		partition_upper_bound = PartitionUpperBound,
		next_partition_upper_bound = NextPartitionUpperBound,
		%% VDF difficulty in use at the previous block
		vdf_difficulty = VDFDifficulty, 
		%% Next VDF difficulty scheduled at the previous block
		next_vdf_difficulty = PrevNextVDFDifficulty 
	} = NonceLimiterInfo,
	true = StepNumber > PrevStepNumber,
	case get_entropy_reset_point(PrevStepNumber, StepNumber) of
		none ->
			%% Entropy reset line was not crossed between previous and current block
			{ Seed, NextSeed, PartitionUpperBound, NextPartitionUpperBound, VDFDifficulty };
		_ ->
			%% Entropy reset line was crossed between previous and current block
			{
				NextSeed, PrevB#block.indep_hash,
				NextPartitionUpperBound, PrevB#block.weave_size,
				%% The next VDF difficulty that was scheduled at the previous block
				%% (PrevNextVDFDifficulty) was applied when we crossed the entropy reset line and
				%% is now the current VDF difficulty.
				PrevNextVDFDifficulty
			}
	end.

%% @doc Return the cached checkpoints for the given step. Return not_found if
%% none found.
get_step_checkpoints(StepNumber, NextSeed, StartIntervalNumber) ->
	SessionKey = {NextSeed, StartIntervalNumber},
	get_step_checkpoints(StepNumber, SessionKey).
get_step_checkpoints(StepNumber, SessionKey) ->
	gen_server:call(?MODULE, {get_step_checkpoints, StepNumber, SessionKey}, infinity).

%% @doc Return the steps of the given interval. The steps are chosen
%% according to the protocol. Return not_found if the corresponding hash chain is not
%% computed yet.
get_steps(StartStepNumber, EndStepNumber, NextSeed)
		when EndStepNumber > StartStepNumber ->
	SessionKey = {NextSeed, StartStepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},
	gen_server:call(?MODULE, {get_steps, StartStepNumber, EndStepNumber, SessionKey},
			infinity).

%% @doc Quickly validate the checkpoints of the latest step.
validate_last_step_checkpoints(#block{ nonce_limiter_info = #nonce_limiter_info{
		global_step_number = StepNumber } },
		#block{ nonce_limiter_info = #nonce_limiter_info{
				global_step_number = StepNumber } }, _PrevOutput) ->
	false;
validate_last_step_checkpoints(#block{
		nonce_limiter_info = #nonce_limiter_info{ output = Output,
				global_step_number = StepNumber, seed = Seed,
				vdf_difficulty = VDFDifficulty,
				last_step_checkpoints = [Output | _] = LastStepCheckpoints } }, PrevB,
				PrevOutput)
		when length(LastStepCheckpoints) == ?VDF_CHECKPOINT_COUNT_IN_STEP ->
	PrevInfo = get_or_init_nonce_limiter_info(PrevB),
	#nonce_limiter_info{ next_seed = PrevNextSeed,
			global_step_number = PrevBStepNumber } = PrevInfo,
	SessionKey = {PrevNextSeed, PrevBStepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},
	case get_step_checkpoints(StepNumber, SessionKey) of
		LastStepCheckpoints ->
			{true, cache_match};
		not_found ->
			PrevOutput2 = ar_nonce_limiter:maybe_add_entropy(
				PrevOutput, PrevBStepNumber, StepNumber, Seed),
			PrevStepNumber = StepNumber - 1,
			{ok, Config} = application:get_env(arweave, config),
			ThreadCount = Config#config.max_nonce_limiter_last_step_validation_thread_count,
			case verify_no_reset(PrevStepNumber, PrevOutput2, 1,
					lists:reverse(LastStepCheckpoints), ThreadCount, VDFDifficulty) of
				{true, _Steps} ->
					true;
				false ->
					false
			end;
		_ ->
			{false, cache_mismatch}
	end;
validate_last_step_checkpoints(_B, _PrevB, _PrevOutput) ->
	false.

%% @doc Determine whether StepNumber has passed the entropy reset line. If it has return the
%% reset line, otherwise return none.
get_entropy_reset_point(PrevStepNumber, StepNumber) ->
	ResetLine = (PrevStepNumber div ?NONCE_LIMITER_RESET_FREQUENCY + 1)
			* ?NONCE_LIMITER_RESET_FREQUENCY,
	case ResetLine > StepNumber of
		true ->
			none;
		false ->
			ResetLine
	end.

%% @doc Conditionally add entropy to PrevOutput if the configured number of steps have
%% passed. See ?NONCE_LIMITER_RESET_FREQUENCY for more details.
maybe_add_entropy(PrevOutput, PrevStepNumber, StepNumber, Seed) ->
	case get_entropy_reset_point(PrevStepNumber, StepNumber) of
		StepNumber ->
			mix_seed(PrevOutput, Seed);
		_ ->
			PrevOutput
	end.

%% @doc Add entropy to an earlier VDF output to mitigate the impact of a miner with a
%% fast VDF compute. See ?NONCE_LIMITER_RESET_FREQUENCY for more details.
mix_seed(PrevOutput, Seed) ->
	SeedH = crypto:hash(sha256, Seed),
	mix_seed2(PrevOutput, SeedH).

mix_seed2(PrevOutput, SeedH) ->
	crypto:hash(sha256, << PrevOutput/binary, SeedH/binary >>).

%% @doc Validate the nonce limiter chain between two blocks in the background.
%% Assume the seeds are correct and the first block is above the second one
%% according to the protocol.
%% Emit {nonce_limiter, {invalid, H, ErrorCode}} or {nonce_limiter, {valid, H}}.
request_validation(H, #nonce_limiter_info{ global_step_number = N },
		#nonce_limiter_info{ global_step_number = N }) ->
	spawn(fun() -> ar_events:send(nonce_limiter, {invalid, H, 1}) end);
request_validation(H, #nonce_limiter_info{ output = Output,
		steps = [Output | _] = StepsToValidate } = Info, PrevInfo) ->
	#nonce_limiter_info{ output = PrevOutput, next_seed = PrevNextSeed,
			global_step_number = PrevStepNumber } = PrevInfo,
	#nonce_limiter_info{ output = Output, seed = Seed, next_seed = NextSeed,
			vdf_difficulty = VDFDifficulty, next_vdf_difficulty = NextVDFDifficulty,
			partition_upper_bound = UpperBound,
			next_partition_upper_bound = NextUpperBound, global_step_number = StepNumber,
			steps = StepsToValidate } = Info,
	EntropyResetPoint = get_entropy_reset_point(PrevStepNumber, StepNumber),
	SessionKey = {PrevNextSeed, PrevStepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},
	%% The steps that fall at the intersection of the PrevStepNumber to StepNumber range
	%% and the SessionKey session.
	SessionSteps = gen_server:call(?MODULE, {get_session_steps, PrevStepNumber, StepNumber,
			SessionKey}, infinity),
	NextSessionKey = {NextSeed, StepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},

	?LOG_INFO([{event, vdf_validation_start}, {block, ar_util:encode(H)},
			{session_key, ar_util:encode(PrevNextSeed)},
			{next_session_key, ar_util:encode(NextSeed)},
			{start_step_number, PrevStepNumber}, {step_number, StepNumber},
			{step_count, StepNumber - PrevStepNumber}, {steps, length(StepsToValidate)},
			{session_steps, length(SessionSteps)},
			{pid, self()}]),

	%% We need to validate all the steps from PrevStepNumber to StepNumber:
	%% PrevStepNumber <--------------------------------------------> StepNumber
	%%     PrevOutput x
	%%                                      |----------------------| StepsToValidate
	%%                |-----------------------------------| SessionSteps
	%%                      StartStepNumber x 
	%%                          StartOutput x
	%%                                      |-------------| ComputedSteps
	%%                                      --------------> NumAlreadyComputed
	%%                                   StartStepNumber2 x
	%%                                       StartOutput2 x
	%%                                                    |--------| RemainingStepsToValidate
	%%
	{StartStepNumber, StartOutput, ComputedSteps} =
		skip_already_computed_steps(PrevStepNumber, StepNumber, PrevOutput,
			StepsToValidate, SessionSteps),
	case exclude_computed_steps_from_steps_to_validate(
			lists:reverse(StepsToValidate), ComputedSteps) of
		invalid ->
			ErrorID = dump_error({PrevStepNumber, StepNumber, StepsToValidate, SessionSteps}),
			?LOG_WARNING([{event, nonce_limiter_validation_failed},
					{step, exclude_computed_steps_from_steps_to_validate},
					{error_dump, ErrorID}]),
			spawn(fun() -> ar_events:send(nonce_limiter, {invalid, H, 2}) end);

		{[], NumAlreadyComputed} when StartStepNumber + NumAlreadyComputed == StepNumber ->
			%% We've already computed up to StepNumber, so we can use the checkpoints from the
			%% current session
			LastStepCheckpoints = get_step_checkpoints(StepNumber, SessionKey),
			Args = {StepNumber, SessionKey, NextSessionKey, Seed, UpperBound, NextUpperBound,
					VDFDifficulty, NextVDFDifficulty, SessionSteps, LastStepCheckpoints},
			gen_server:cast(?MODULE, {validated_steps, Args}),
			spawn(fun() -> ar_events:send(nonce_limiter, {valid, H}) end);

		{_, NumAlreadyComputed} when StartStepNumber + NumAlreadyComputed >= StepNumber ->
			ErrorID = dump_error({PrevStepNumber, StepNumber, StepsToValidate, SessionSteps,
					StartStepNumber, NumAlreadyComputed}),
			?LOG_WARNING([{event, nonce_limiter_validation_failed},
					{step, exclude_computed_steps_from_steps_to_validate_shift},
					{start_step_number, StartStepNumber}, {shift2, NumAlreadyComputed},
					{error_dump, ErrorID}]),
			spawn(fun() -> ar_events:send(nonce_limiter, {invalid, H, 2}) end);
		{RemainingStepsToValidate, NumAlreadyComputed}
		  		when StartStepNumber + NumAlreadyComputed < StepNumber ->
			case ar_config:use_remote_vdf_server() of
				true ->
					%% Wait for our VDF server(s) to validate the reamining steps.
					spawn(fun() ->
						timer:sleep(1000),
						request_validation(H, Info, PrevInfo) end);
				false ->
					%% Validate the remaining steps.
					StartOutput2 = case NumAlreadyComputed of
							0 -> StartOutput;
							_ -> lists:nth(NumAlreadyComputed, ComputedSteps)
					end,
					spawn(fun() ->
						StartStepNumber2 = StartStepNumber + NumAlreadyComputed,
						{ok, Config} = application:get_env(arweave, config),
						ThreadCount = Config#config.max_nonce_limiter_validation_thread_count,
						Result =
							case is_integer(EntropyResetPoint) andalso
									EntropyResetPoint > StartStepNumber2 of
								true ->
									catch verify(StartStepNumber2, StartOutput2,
											?VDF_CHECKPOINT_COUNT_IN_STEP,
											RemainingStepsToValidate, EntropyResetPoint,
											crypto:hash(sha256, Seed), ThreadCount,
											VDFDifficulty, NextVDFDifficulty);
								_ ->
									catch verify_no_reset(StartStepNumber2, StartOutput2,
											?VDF_CHECKPOINT_COUNT_IN_STEP,
											RemainingStepsToValidate, ThreadCount,
											VDFDifficulty)
							end,
						case Result of
							{'EXIT', Exc} ->
								ErrorID = dump_error(
									{StartStepNumber2, StartOutput2,
									?VDF_CHECKPOINT_COUNT_IN_STEP,
									RemainingStepsToValidate,
									EntropyResetPoint, crypto:hash(sha256, Seed),
									ThreadCount, VDFDifficulty}),
								?LOG_ERROR([{event, nonce_limiter_validation_failed},
										{block, ar_util:encode(H)},
										{start_step_number, StartStepNumber2},
										{error_id, ErrorID},
										{prev_output, ar_util:encode(StartOutput2)},
										{exception, io_lib:format("~p", [Exc])}]),
								ar_events:send(nonce_limiter, {validation_error, H});
							false ->
								ar_events:send(nonce_limiter, {invalid, H, 3});
							{true, ValidatedSteps} ->
								AllValidatedSteps = ValidatedSteps ++ SessionSteps,
								%% The last_step_checkpoints in Info were validated as part
								%% of an earlier call to
								%% ar_block_pre_validator:pre_validate_nonce_limiter, so
								%% we can trust them here.
								LastStepCheckpoints = get_last_step_checkpoints(Info),
								Args = {StepNumber, SessionKey, NextSessionKey,
										Seed, UpperBound, NextUpperBound,
										VDFDifficulty, NextVDFDifficulty,
										AllValidatedSteps, LastStepCheckpoints},
								gen_server:cast(?MODULE, {validated_steps, Args}),
								ar_events:send(nonce_limiter, {valid, H})
						end
					end)
			end;
		Data ->
			ErrorID = dump_error(Data),
			ar_events:send(nonce_limiter, {validation_error, H}),
			?LOG_ERROR([{event, unexpected_error_during_nonce_limiter_validation},
					{error_id, ErrorID}])
	end;
request_validation(H, _Info, _PrevInfo) ->
	spawn(fun() -> ar_events:send(nonce_limiter, {invalid, H, 4}) end).

get_last_step_checkpoints(Info) ->
	Info#nonce_limiter_info.last_step_checkpoints.

get_or_init_nonce_limiter_info(#block{ height = Height, indep_hash = H } = B) ->
	case Height >= ar_fork:height_2_6() of
		true ->
			B#block.nonce_limiter_info;
		false ->
			{Seed, PartitionUpperBound} =
					ar_node:get_recent_partition_upper_bound_by_prev_h(H),
			get_or_init_nonce_limiter_info(B, Seed, PartitionUpperBound)
	end.

get_or_init_nonce_limiter_info(#block{ height = Height } = B, RecentBI) ->
	case Height >= ar_fork:height_2_6() of
		true ->
			B#block.nonce_limiter_info;
		false ->
			{Seed, PartitionUpperBound, _TXRoot}
					= lists:last(lists:sublist(RecentBI, ?SEARCH_SPACE_UPPER_BOUND_DEPTH)),
			get_or_init_nonce_limiter_info(B, Seed, PartitionUpperBound)
	end.

%% @doc Apply the nonce limiter update provided by the configured trusted peer.
apply_external_update(Update, Peer) ->
	gen_server:call(?MODULE, {apply_external_update, Update, Peer}, infinity).

%% @doc Return the nonce limiter session with the given key.
get_session(SessionKey) ->
	gen_server:call(?MODULE, {get_session, SessionKey}, infinity).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	ok = ar_events:subscribe(node_state),
	State =
		case ar_node:is_joined() of
			true ->
				Blocks = get_blocks(),
				handle_initialized(Blocks, #state{});
			_ ->
				#state{}
		end,
	State2 =
		case ar_config:use_remote_vdf_server() of
			false ->
				State;
			true ->
				resolve_remote_server_raw_peers(),
				gen_server:cast(?MODULE, check_external_vdf_server_input),
				State#state{ autocompute = false }
		end,
	{ok, start_worker(State2)}.

resolve_remote_server_raw_peers() ->
	{ok, Config} = application:get_env(arweave, config),
	resolve_remote_server_raw_peers(Config#config.nonce_limiter_server_trusted_peers),
	timer:apply_after(10000, ?MODULE, resolve_remote_server_raw_peers, []).

resolve_remote_server_raw_peers([]) ->
	ok;
resolve_remote_server_raw_peers([RawPeer | RawPeers]) ->
	case ar_peers:resolve_and_cache_peer(RawPeer, vdf_server_peer) of
		{ok, _Peer} ->
			resolve_remote_server_raw_peers(RawPeers);
		{error, Reason} ->
			?LOG_WARNING([{event, failed_to_resolve_vdf_server_peer},
					{reason, io_lib:format("~p", [Reason])}]),
			resolve_remote_server_raw_peers(RawPeers)
	end.

get_blocks() ->
	B = ar_node:get_current_block(),
	[B | get_blocks(B#block.previous_block, 1)].

get_blocks(_H, N) when N >= ?STORE_BLOCKS_BEHIND_CURRENT ->
	[];
get_blocks(H, N) ->
	#block{} = B = ar_block_cache:get(block_cache, H),
	[B | get_blocks(B#block.previous_block, N + 1)].

handle_call(get_current_step_number, _From,
		#state{ current_session_key = undefined } = State) ->
	{reply, 0, State};
handle_call(get_current_step_number, _From, State) ->
	#state{ current_session_key = Key, session_by_key = SessionByKey } = State,
	Session = maps:get(Key, SessionByKey),
	{reply, Session#vdf_session.step_number, State};

handle_call({get_current_step_number, SessionKey}, _From, State) ->
	#state{ session_by_key = SessionByKey } = State,
	case maps:get(SessionKey, SessionByKey, not_found) of
		not_found ->
			{reply, not_found, State};
		#vdf_session{ step_number = StepNumber } ->
			{reply, StepNumber, State}
	end;

handle_call({get_step_checkpoints, StepNumber, SessionKey}, _From, State) ->
	#state{ session_by_key = SessionByKey } = State,
	case maps:get(SessionKey, SessionByKey, not_found) of
		not_found ->
			{reply, not_found, State};
		Session ->
			Map = Session#vdf_session.step_checkpoints_map,
			{reply, maps:get(StepNumber, Map, not_found), State}
	end;

handle_call({get_steps, StartStepNumber, EndStepNumber, SessionKey}, _From, State) ->
	case get_steps(StartStepNumber, EndStepNumber, SessionKey, State) of
		not_found ->
			{reply, not_found, State};
		Steps ->
			TakeN = min(?NONCE_LIMITER_MAX_CHECKPOINTS_COUNT, EndStepNumber - StartStepNumber),
			{reply, lists:sublist(Steps, TakeN), State}
	end;

handle_call({get_session_steps, StartStepNumber, EndStepNumber, SessionKey}, _From, State) ->
	{reply, get_session_steps(StartStepNumber, EndStepNumber, SessionKey, State), State};

handle_call(get_steps, _From, #state{ current_session_key = undefined } = State) ->
	{reply, [], State};
handle_call(get_steps, _From, State) ->
	#state{ current_session_key = SessionKey, session_by_key = SessionByKey } = State,
	#vdf_session{ step_number = StepNumber } = maps:get(SessionKey, SessionByKey),
	{reply, get_steps(1, StepNumber, SessionKey, State), State};

handle_call({apply_external_update, Update, Peer}, _From, State) ->
	#state{ last_external_update = {Peer2, Time} } = State,
	Now = os:system_time(millisecond),
	case Peer /= Peer2 andalso Now - Time < 1000 of
		true ->
			{reply, #nonce_limiter_update_response{ postpone = 5 }, State};
		false ->
			State2 = State#state{ last_external_update = {Peer, Now} },
			apply_external_update2(Update, State2)
	end;

handle_call({get_session, SessionKey}, _From, State) ->
	#state{ session_by_key = SessionByKey } = State,
	{reply, maps:get(SessionKey, SessionByKey, not_found), State};

handle_call(Request, _From, State) ->
	?LOG_WARNING("event: unhandled_call, request: ~p", [Request]),
	{reply, ok, State}.

handle_cast(check_external_vdf_server_input,
		#state{ last_external_update = {_, 0} } = State) ->
	ar_util:cast_after(1000, ?MODULE, check_external_vdf_server_input),
	{noreply, State};
handle_cast(check_external_vdf_server_input,
		#state{ last_external_update = {_, Time} } = State) ->
	Now = os:system_time(millisecond),
	case Now - Time > 2000 of
		true ->
			?LOG_WARNING([{event, no_message_from_any_vdf_servers},
					{last_message_seconds_ago, (Now - Time) div 1000}]),
			ar_util:cast_after(30000, ?MODULE, check_external_vdf_server_input);
		false ->
			ar_util:cast_after(1000, ?MODULE, check_external_vdf_server_input)
	end,
	{noreply, State};

handle_cast(initialized, State) ->
	gen_server:cast(?MODULE, schedule_step),
	case State#state.emit_initialized_event of
		true ->
			ar_events:send(nonce_limiter, initialized);
		false ->
			ok
	end,
	{noreply, State};

handle_cast({initialize, [PrevB, B | Blocks]}, State) ->
	apply_chain(B#block.nonce_limiter_info, PrevB#block.nonce_limiter_info),
	gen_server:cast(?MODULE, {apply_tip, B, PrevB}),
	gen_server:cast(?MODULE, {initialize, [B | Blocks]}),
	{noreply, State};
handle_cast({initialize, _}, State) ->
	gen_server:cast(?MODULE, initialized),
	{noreply, State};

handle_cast({apply_tip, B, PrevB}, State) ->
	{noreply, apply_tip2(B, PrevB, State)};

handle_cast({validated_steps, Args}, State) ->
	{StepNumber, SessionKey, NextSessionKey, Seed, UpperBound, NextUpperBound,
			VDFDifficulty, NextVDFDifficulty, Steps, LastStepCheckpoints} = Args,
	#state{ session_by_key = SessionByKey, sessions = Sessions,
			current_session_key = CurrentSessionKey } = State,
	case maps:get(SessionKey, SessionByKey, not_found) of
		not_found ->
			%% The corresponding fork origin should have just dropped below the
			%% checkpoint height.
			?LOG_WARNING([{event, session_not_found_for_validated_steps},
					{next_seed, ar_util:encode(element(1, SessionKey))},
					{interval, element(2, SessionKey)}]),
			{noreply, State};
		#vdf_session{ step_number = CurrentStepNumber, steps = CurrentSteps,
				step_checkpoints_map = Map } = Session ->
			Session2 =
				case CurrentStepNumber < StepNumber of
					true ->
						%% Update the current Session with all the newly validated steps and
						%% as well as the checkpoints associated with step StepNumber.
						%% This branch occurs when a block is received that is ahead of us
						%% in the VDF chain.
						Steps2 = lists:sublist(Steps, StepNumber - CurrentStepNumber)
								++ CurrentSteps,
						Map2 = maps:put(StepNumber, LastStepCheckpoints, Map),
						Session#vdf_session{
							step_number = StepNumber, steps = Steps2,
							step_checkpoints_map = Map2 };
					false ->
						Session
				end,
			SessionByKey2 = maps:put(SessionKey, Session2, SessionByKey),
			may_be_set_vdf_step_metric(SessionKey, CurrentSessionKey,
					Session2#vdf_session.step_number),
			Steps3 = Session2#vdf_session.steps,
			StepNumber2 = Session2#vdf_session.step_number,
			Session3 =
				case maps:get(NextSessionKey, SessionByKey2, not_found) of
					not_found ->
						{_, Interval} = NextSessionKey,
						SessionStart = Interval * ?NONCE_LIMITER_RESET_FREQUENCY,
						SessionEnd = (Interval + 1) * ?NONCE_LIMITER_RESET_FREQUENCY - 1,
						Steps4 =
							case StepNumber2 > SessionEnd of
								true ->
									lists:nthtail(StepNumber2 - SessionEnd, Steps3);
								false ->
									Steps3
							end,
						StepNumber3 = min(StepNumber2, SessionEnd),
						Steps5 = lists:sublist(Steps4, StepNumber3 - SessionStart + 1),
						#vdf_session{ step_number = StepNumber3, seed = Seed,
							step_checkpoints_map = #{}, steps = Steps5,
							upper_bound = UpperBound, next_upper_bound = NextUpperBound,
							prev_session_key = SessionKey,
							vdf_difficulty = VDFDifficulty,
							next_vdf_difficulty = NextVDFDifficulty };
					Session4 ->
						Session4
				end,
			SessionByKey3 = maps:put(NextSessionKey, Session3, SessionByKey2),
			may_be_set_vdf_step_metric(NextSessionKey, CurrentSessionKey,
					Session3#vdf_session.step_number),
			Sessions2 = gb_sets:add_element({element(2, NextSessionKey),
					element(1, NextSessionKey)}, Sessions),
			{noreply, State#state{ session_by_key = SessionByKey3, sessions = Sessions2 }}
	end;

handle_cast(schedule_step, #state{ autocompute = false } = State) ->
	{noreply, State#state{ computing = false }};
handle_cast(schedule_step, State) ->
	{noreply, schedule_step(State#state{ computing = true })};

handle_cast(compute_step, State) ->
	{noreply, schedule_step(State)};

handle_cast(reset_and_pause, State) ->
	{noreply, State#state{ autocompute = false, computing = false,
			current_session_key = undefined, sessions = gb_sets:new(), session_by_key = #{} }};

handle_cast(turn_off_initialized_event, State) ->
	{noreply, State#state{ emit_initialized_event = false }};

handle_cast(Cast, State) ->
	?LOG_WARNING("event: unhandled_cast, cast: ~p", [Cast]),
	{noreply, State}.

handle_info({event, node_state, {initializing, Blocks}}, State) ->
	{noreply, handle_initialized(lists:sublist(Blocks, ?STORE_BLOCKS_BEHIND_CURRENT), State)};

handle_info({event, node_state, {validated_pre_fork_2_6_block, B}}, State) ->
	#state{ sessions = Sessions } = State,
	case gb_sets:is_empty(Sessions) of
		true ->
			{noreply, apply_base_block(B, State)};
		false ->
			%% The fork block is seeded from the STORE_BLOCKS_BEHIND_CURRENT's past block
			%% and we do not reorg past that point so even if there are competing
			%% pre-fork 2.6 blocks, they have the same {NextSeed, IntervalNumber} key.
			{noreply, State}
	end;

handle_info({event, node_state, {new_tip, B, PrevB}}, State) ->
	{noreply, apply_tip(B, PrevB, State)};

handle_info({event, node_state, {checkpoint_block, B}}, State) ->
	case B#block.height < ar_fork:height_2_6() of
		true ->
			{noreply, State};
		false ->
			#state{ sessions = Sessions, session_by_key = SessionByKey,
					current_session_key = CurrentSessionKey } = State,
			StepNumber = (B#block.nonce_limiter_info)#nonce_limiter_info.global_step_number,
			BaseInterval = StepNumber div ?NONCE_LIMITER_RESET_FREQUENCY,
			{Sessions2, SessionByKey2} = prune_old_sessions(Sessions, SessionByKey,
					BaseInterval),
			true = maps:is_key(CurrentSessionKey, SessionByKey2),
			{noreply, State#state{ sessions = Sessions2, session_by_key = SessionByKey2 }}
	end;

handle_info({event, node_state, _}, State) ->
	{noreply, State};

handle_info({'DOWN', Ref, process, _, Reason}, #state{ worker_monitor_ref = Ref } = State) ->
	?LOG_WARNING([{event, nonce_limiter_worker_down},
			{reason, io_lib:format("~p", [Reason])}]),
	{noreply, start_worker(State)};

handle_info({computed, Args}, State) ->
	#state{ session_by_key = SessionByKey, current_session_key = CurrentSessionKey } = State,
	{StepNumber, PrevOutput, Output, UpperBound, Checkpoints} = Args,
	Session = maps:get(CurrentSessionKey, SessionByKey),
	#vdf_session{ steps = [SessionOutput | _] = Steps,
			step_checkpoints_map = Map, prev_session_key = PrevSessionKey } = Session,
	{NextSeed, IntervalNumber} = CurrentSessionKey,
	IntervalStart = IntervalNumber * ?NONCE_LIMITER_RESET_FREQUENCY,
	SessionOutput2 = ar_nonce_limiter:maybe_add_entropy(
			SessionOutput, IntervalStart, StepNumber, NextSeed),
	gen_server:cast(?MODULE, schedule_step),
	case PrevOutput == SessionOutput2 of
		false ->
			?LOG_INFO([{event, computed_for_outdated_key}]),
			{noreply, State};
		true ->
			Map2 = maps:put(StepNumber, Checkpoints, Map),
			Session2 = Session#vdf_session{ step_number = StepNumber,
					step_checkpoints_map = Map2, steps = [Output | Steps] },
			SessionByKey2 = maps:put(CurrentSessionKey, Session2, SessionByKey),
			PrevSession = maps:get(PrevSessionKey, SessionByKey, undefined),
			ar_events:send(nonce_limiter, {computed_output, {CurrentSessionKey, Session2,
					PrevSessionKey, PrevSession, Output, UpperBound}}),
			may_be_set_vdf_step_metric(CurrentSessionKey, CurrentSessionKey, StepNumber),
			{noreply, State#state{ session_by_key = SessionByKey2 }}
	end;

handle_info(Message, State) ->
	?LOG_WARNING("event: unhandled_info, message: ~p", [Message]),
	{noreply, State}.

terminate(_Reason, #state{ worker = W }) ->
	W ! stop,
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

dump_error(Data) ->
	{ok, Config} = application:get_env(arweave, config),
	ErrorID = binary_to_list(ar_util:encode(crypto:strong_rand_bytes(8))),
	ErrorDumpFile = filename:join(Config#config.data_dir, "error_dump_" ++ ErrorID),
	file:write_file(ErrorDumpFile, term_to_binary(Data)),
	ErrorID.

%% @doc
%% PrevStepNumber <------------------------------------------------------> StepNumber
%%     PrevOutput x
%%                                                |----------------------| StepsToValidate
%%                |-------------------------------| NumStepsBefore
%%                |---------------------------------------------| SessionSteps
%%
skip_already_computed_steps(PrevStepNumber, StepNumber, PrevOutput, StepsToValidate,
		SessionSteps) ->
	ComputedSteps = lists:reverse(SessionSteps),
	%% Number of steps in the PrevStepNumber to StepNumber range that fall before the
	%% beginning of the StepsToValidate list. To avoid computing these steps we will look for
	%% them in the current VDF session (i.e. in the SessionSteps list)
	NumStepsBefore = StepNumber - PrevStepNumber - length(StepsToValidate),
	case NumStepsBefore > 0 andalso length(ComputedSteps) >= NumStepsBefore of
		false ->
			{PrevStepNumber, PrevOutput, ComputedSteps};
		true ->
			{
				PrevStepNumber + NumStepsBefore,
				lists:nth(NumStepsBefore, ComputedSteps),
				lists:nthtail(NumStepsBefore, ComputedSteps)
			}
	end.

exclude_computed_steps_from_steps_to_validate(StepsToValidate, ComputedSteps) ->
	exclude_computed_steps_from_steps_to_validate(StepsToValidate, ComputedSteps, 1, 0).

exclude_computed_steps_from_steps_to_validate(StepsToValidate, [], _I, NumAlreadyComputed) ->
	{StepsToValidate, NumAlreadyComputed};
exclude_computed_steps_from_steps_to_validate(StepsToValidate, [_Step | ComputedSteps], I,
		NumAlreadyComputed) when I /= 1 ->
	exclude_computed_steps_from_steps_to_validate(StepsToValidate, ComputedSteps, I + 1,
			NumAlreadyComputed);
exclude_computed_steps_from_steps_to_validate([Step], [Step | _ComputedSteps], _I,
			NumAlreadyComputed) ->
	{[], NumAlreadyComputed + 1};
exclude_computed_steps_from_steps_to_validate([Step | StepsToValidate], [Step | ComputedSteps],
		_I, NumAlreadyComputed) ->
	exclude_computed_steps_from_steps_to_validate(StepsToValidate, ComputedSteps, 1,
		NumAlreadyComputed + 1);
exclude_computed_steps_from_steps_to_validate(_StepsToValidate, _ComputedSteps, _I,
		_NumAlreadyComputed) ->
	invalid.

handle_initialized([B | Blocks], State) ->
	Blocks2 = take_blocks_after_fork([B | Blocks]),
	handle_initialized2(lists:reverse(Blocks2), State).

take_blocks_after_fork([#block{ height = Height } = B | Blocks]) ->
	case Height + 1 >= ar_fork:height_2_6() of
		true ->
			[B | take_blocks_after_fork(Blocks)];
		false ->
			[]
	end;
take_blocks_after_fork([]) ->
	[].

handle_initialized2([B | Blocks], State) ->
	State2 = apply_base_block(B, State),
	gen_server:cast(?MODULE, {initialize, [B | Blocks]}),
	State2.

apply_base_block(B, State) ->
	#nonce_limiter_info{ seed = Seed, next_seed = NextSeed, output = Output,
			partition_upper_bound = UpperBound,
			next_partition_upper_bound = NextUpperBound,
			global_step_number = StepNumber,
			last_step_checkpoints = LastStepCheckpoints,
			vdf_difficulty = VDFDifficulty,
			next_vdf_difficulty = NextVDFDifficulty } = B#block.nonce_limiter_info,
	Session = #vdf_session{ step_number = StepNumber,
			step_checkpoints_map = #{ StepNumber => LastStepCheckpoints },
			steps = [Output], upper_bound = UpperBound, next_upper_bound = NextUpperBound,
			seed = Seed, vdf_difficulty = VDFDifficulty,
			next_vdf_difficulty = NextVDFDifficulty },
	SessionKey = {NextSeed, StepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},
	Sessions = gb_sets:from_list([{StepNumber div ?NONCE_LIMITER_RESET_FREQUENCY, NextSeed}]),
	SessionByKey = #{ SessionKey => Session },
	State#state{ current_session_key = SessionKey, sessions = Sessions,
			session_by_key = SessionByKey }.

apply_chain(#nonce_limiter_info{ global_step_number = StepNumber },
		#nonce_limiter_info{ global_step_number = PrevStepNumber })
		when StepNumber - PrevStepNumber > ?NONCE_LIMITER_MAX_CHECKPOINTS_COUNT ->
	ar:console("Cannot do a trusted join - there are not enough checkpoints"
			" to apply quickly; step number: ~B, previous step number: ~B.",
			[StepNumber, PrevStepNumber]),
	timer:sleep(1000),
	erlang:halt();
%% @doc Apply the pre-validated / trusted nonce_limiter_info. Since the info is trusted
%% we don't validate it here.
apply_chain(Info, PrevInfo) ->
	#nonce_limiter_info{ next_seed = PrevNextSeed,
			global_step_number = PrevStepNumber } = PrevInfo,
	#nonce_limiter_info{ output = Output, seed = Seed, next_seed = NextSeed,
			vdf_difficulty = VDFDifficulty,
			next_vdf_difficulty = NextVDFDifficulty,
			partition_upper_bound = UpperBound,
			next_partition_upper_bound = NextUpperBound, global_step_number = StepNumber,
			steps = Steps, last_step_checkpoints = LastStepCheckpoints } = Info,
	Count = StepNumber - PrevStepNumber,
	Output = hd(Steps),
	Count = length(Steps),
	SessionKey = {PrevNextSeed, PrevStepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},
	NextSessionKey = {NextSeed, StepNumber div ?NONCE_LIMITER_RESET_FREQUENCY},
	Args = {StepNumber, SessionKey, NextSessionKey, Seed, UpperBound, NextUpperBound,
			VDFDifficulty, NextVDFDifficulty, Steps, LastStepCheckpoints},
	gen_server:cast(?MODULE, {validated_steps, Args}).

apply_tip(#block{ height = Height } = B, PrevB, #state{ sessions = Sessions } = State) ->
	case Height + 1 < ar_fork:height_2_6() of
		true ->
			State;
		false ->
			State2 =
				case State#state.computing of
					false ->
						gen_server:cast(?MODULE, schedule_step),
						State#state{ computing = true };
					true ->
						State
				end,
			case gb_sets:is_empty(Sessions) of
				true ->
					true = (Height + 1) == ar_fork:height_2_6(),
					State3 = apply_base_block(B, State2),
					State3;
				false ->
					apply_tip2(B, PrevB, State2)
			end
	end.

apply_tip2(B, PrevB, State) ->
	#state{ session_by_key = SessionByKey, sessions = Sessions } = State,
	#nonce_limiter_info{ next_seed = NextSeed, seed = Seed,
			partition_upper_bound = UpperBound,
			next_partition_upper_bound = NextUpperBound, global_step_number = StepNumber,
			last_step_checkpoints = LastStepCheckpoints,
			vdf_difficulty = VDFDifficulty,
			next_vdf_difficulty = NextVDFDifficulty } = B#block.nonce_limiter_info,
	#nonce_limiter_info{ next_seed = PrevNextSeed,
			global_step_number = PrevStepNumber } = PrevB#block.nonce_limiter_info,
	Interval = StepNumber div ?NONCE_LIMITER_RESET_FREQUENCY,
	SessionKey = {NextSeed, Interval},
	PrevInterval = PrevStepNumber div ?NONCE_LIMITER_RESET_FREQUENCY,
	PrevSessionKey = {PrevNextSeed, PrevInterval},
	PrevSession = maps:get(PrevSessionKey, SessionByKey),
	ExistingSession = maps:is_key(SessionKey, SessionByKey),
	Session2 =
		case maps:get(SessionKey, SessionByKey, not_found) of
			not_found ->
				#vdf_session{ steps = Steps, step_number = StepNumber2 } = PrevSession,
				SessionStart = Interval * ?NONCE_LIMITER_RESET_FREQUENCY,
				SessionEnd = (Interval + 1) * ?NONCE_LIMITER_RESET_FREQUENCY - 1,
				Steps2 =
					case StepNumber2 > SessionEnd of
						true ->
							lists:nthtail(StepNumber2 - SessionEnd, Steps);
						false ->
							Steps
					end,
				StepNumber3 = min(StepNumber2, SessionEnd),
				Steps3 = lists:sublist(Steps2, StepNumber3 - SessionStart + 1),
				#vdf_session{ step_number = StepNumber3, seed = Seed,
						step_checkpoints_map = #{ StepNumber => LastStepCheckpoints },
						steps = Steps3, upper_bound = UpperBound,
						next_upper_bound = NextUpperBound, prev_session_key = PrevSessionKey,
						vdf_difficulty = VDFDifficulty,
						next_vdf_difficulty = NextVDFDifficulty };
			Session ->
				Session
		end,
	may_be_set_vdf_step_metric(SessionKey, SessionKey, Session2#vdf_session.step_number),
	case ExistingSession of
		true ->
			State#state{ current_session_key = SessionKey };
		false ->
			SessionByKey2 = maps:put(SessionKey, Session2, SessionByKey),
			Sessions2 = gb_sets:add_element({element(2, SessionKey), element(1, SessionKey)},
					Sessions),
			State#state{ current_session_key = SessionKey, sessions = Sessions2,
					session_by_key = SessionByKey2 }
	end.

prune_old_sessions(Sessions, SessionByKey, BaseInterval) ->
	{{Interval, NextSeed}, Sessions2} = gb_sets:take_smallest(Sessions),
	case BaseInterval > Interval + 10 of
		true ->
			SessionByKey2 = maps:remove({NextSeed, Interval}, SessionByKey),
			prune_old_sessions(Sessions2, SessionByKey2, BaseInterval);
		false ->
			{Sessions, SessionByKey}
	end.

start_worker(State) ->
	Worker = spawn(fun() -> process_flag(priority, high), worker() end),
	Ref = monitor(process, Worker),
	State#state{ worker = Worker, worker_monitor_ref = Ref }.

compute(StepNumber, PrevOutput, VDFDifficulty) ->
	{ok, Output, Checkpoints} = ar_vdf:compute2(StepNumber, PrevOutput, VDFDifficulty),
	debug_double_check(
		"compute",
		{ok, Output, Checkpoints},
		fun ar_vdf:debug_sha2/3,
		[StepNumber, PrevOutput, VDFDifficulty]).

verify(StartStepNumber, PrevOutput, NumCheckpointsBetweenHashes, Hashes, ResetStepNumber,
		ResetSeed, ThreadCount, VDFDifficulty, NextVDFDifficulty) ->
	{Result1, PrevOutput2, ValidatedSteps1} =
		case lists:sublist(Hashes, ResetStepNumber - StartStepNumber - 1) of
			[] ->
				{true, mix_seed2(PrevOutput, ResetSeed), []};
			Hashes1 ->
				case verify_no_reset(StartStepNumber, PrevOutput,
						NumCheckpointsBetweenHashes, Hashes1, ThreadCount, VDFDifficulty) of
					{true, ValidatedSteps} ->
						{true, mix_seed2(hd(ValidatedSteps), ResetSeed), ValidatedSteps};
					false ->
						{false, undefined, undefined}
				end
		end,
	case Result1 of
		false ->
			false;
		true ->
			Hashes2 = lists:nthtail(ResetStepNumber - StartStepNumber - 1, Hashes),
			case verify_no_reset(ResetStepNumber - 1, PrevOutput2, NumCheckpointsBetweenHashes,
					Hashes2, ThreadCount, NextVDFDifficulty) of
				{true, ValidatedSteps2} ->
					{true, ValidatedSteps2 ++ ValidatedSteps1};
				false ->
					false
			end
	end.

verify_no_reset(StartStepNumber, PrevOutput, NumCheckpointsBetweenHashes, Hashes, ThreadCount,
		VDFDifficulty) ->
	Garbage = crypto:strong_rand_bytes(32),
	Result = ar_vdf:verify2(StartStepNumber, PrevOutput, NumCheckpointsBetweenHashes, Hashes,
			0, Garbage, ThreadCount, VDFDifficulty),
	debug_double_check(
		"verify_no_reset",
		Result,
		fun ar_vdf:debug_sha_verify_no_reset/6,
		[StartStepNumber, PrevOutput, NumCheckpointsBetweenHashes, Hashes, ThreadCount,
				VDFDifficulty]).

worker() ->
	receive
		{compute, {StepNumber, PrevOutput, UpperBound, VDFDifficulty}, From} ->
			{ok, Output, Checkpoints} = prometheus_histogram:observe_duration(
					vdf_step_time_milliseconds, [], fun() -> compute(StepNumber, PrevOutput,
							VDFDifficulty) end),
			From ! {computed, {StepNumber, PrevOutput, Output, UpperBound, Checkpoints}},
			worker();
		stop ->
			ok
	end.

%% @doc Get all the steps that fall between StartStepNumber and EndStepNumber, traversing
%% multiple sessions if needed.
get_steps(StartStepNumber, EndStepNumber, SessionKey, State) ->
	#state{ session_by_key = SessionByKey } = State,
	case maps:get(SessionKey, SessionByKey, not_found) of
		#vdf_session{ step_number = StepNumber, steps = SessionSteps,
				prev_session_key = PrevSessionKey }
				when StepNumber >= EndStepNumber ->
			%% Get the steps within the current session that fall within the StartStepNumber
			%% and EndStepNumber range.
			Steps = lists:nthtail(StepNumber - EndStepNumber, SessionSteps),
			TotalCount = EndStepNumber - StartStepNumber,
			Count = length(Steps),
			%% If we haven't found all the steps, recurse into the previous session.
			case TotalCount > Count of
				true ->
					case get_steps(StartStepNumber, EndStepNumber - Count,
							PrevSessionKey, State) of
						not_found ->
							not_found;
						PrevSteps ->
							Steps ++ PrevSteps
					end;
				false ->
					lists:sublist(Steps, TotalCount)
			end;
		_ ->
			not_found
	end.

%% @doc Get all the steps in the current session that fall between
%% StartStepNumber and EndStepNumber
get_session_steps(StartStepNumber, EndStepNumber, SessionKey, State) ->
	#state{ session_by_key = SessionByKey } = State,
	case maps:get(SessionKey, SessionByKey, not_found) of
		#vdf_session{ step_number = StepNumber, steps = SessionSteps }
				when StepNumber > StartStepNumber ->
			End = min(StepNumber, EndStepNumber),
			Steps = lists:nthtail(StepNumber - End, SessionSteps),
			lists:sublist(Steps, End - StartStepNumber);
		_ ->
			[]
	end.

schedule_step(State) ->
	#state{ current_session_key = {NextSeed, IntervalNumber} = Key,
			session_by_key = SessionByKey, worker = Worker } = State,
	#vdf_session{ step_number = PrevStepNumber, steps = Steps, upper_bound = UpperBound,
			next_upper_bound = NextUpperBound,
			vdf_difficulty = VDFDifficulty,
			next_vdf_difficulty = NextVDFDifficulty } = maps:get(Key, SessionByKey),
	PrevOutput = hd(Steps),
	StepNumber = PrevStepNumber + 1,
	IntervalStart = IntervalNumber * ?NONCE_LIMITER_RESET_FREQUENCY,
	PrevOutput2 = ar_nonce_limiter:maybe_add_entropy(
		PrevOutput, IntervalStart, StepNumber, NextSeed),
	{UpperBound2, VDFDifficulty2} =
		case get_entropy_reset_point(IntervalStart, StepNumber) of
			none ->
				{UpperBound, VDFDifficulty};
			_ ->
				?LOG_DEBUG([{event, entropy_reset_point_found}, {step_number, StepNumber},
					{interval_start, IntervalStart}, {vdf_difficulty, VDFDifficulty},
					{next_vdf_difficulty, NextVDFDifficulty}]),
				{NextUpperBound, NextVDFDifficulty}
		end,
	Worker ! {compute, {StepNumber, PrevOutput2, UpperBound2, VDFDifficulty2}, self()},
	State.

get_or_init_nonce_limiter_info(#block{ height = Height } = B, Seed, PartitionUpperBound) ->
	NextSeed = B#block.indep_hash,
	NextPartitionUpperBound = B#block.weave_size,
	case Height + 1 == ar_fork:height_2_6() of
		true ->
			Output = crypto:hash(sha256, Seed),
			#nonce_limiter_info{ output = Output, seed = Seed, next_seed = NextSeed,
					partition_upper_bound = PartitionUpperBound,
					next_partition_upper_bound = NextPartitionUpperBound };
		false ->
			undefined
	end.

apply_external_update2(Update, State) ->
	#state{ session_by_key = SessionByKey, current_session_key = CurrentSessionKey,
			sessions = Sessions } = State,
	#nonce_limiter_update{ session_key = SessionKey,
			session = #vdf_session{ upper_bound = UpperBound,
					prev_session_key = PrevSessionKey,
					step_number = StepNumber } = Session,
			checkpoints = Checkpoints, is_partial = IsPartial } = Update,
	{SessionSeed, SessionInterval} = SessionKey,
	case maps:get(SessionKey, SessionByKey, not_found) of
		not_found ->
			case IsPartial of
				true ->
					%% Inform the peer we have not initialized the corresponding session yet.
					?LOG_DEBUG([{event, apply_external_vdf},
						{result, session_not_found},
						{is_partial, IsPartial},
						{session_seed, ar_util:encode(SessionSeed)},
						{session_interval, SessionInterval},
						{server_step_number, StepNumber}]),
					{reply, #nonce_limiter_update_response{ session_found = false }, State};
				false ->
					Sessions2 = gb_sets:add_element({SessionInterval, SessionSeed}, Sessions),
					%% Handle the case where The VDF server has processed a block and re-allocated
					%% steps across sessions. Between blocks The VDF server (and all nodes that 
					%% compute their own VDF) will add all computed steps to the same session -
					%% *even if* the new steps have crossed the entropy reset line and therefore 
					%% could be added to a new session. Once a block is processed the server will
					%% open a new session and re-allocate all the steps past the entropy reset line
					%% to that new session. When the VDF client sees the new session it will request
					%% the full session to be resent - which will contain steps it has already seen
					%% and cached under the previous session key.
					%% 
					%% Note: This overlap in session caching is intentional. The intention is to
					%% quickly access the steps when validating B1 -> reset line -> B2 given the
					%% current fork of B1 -> B2' -> reset line -> B3 i.e. we can query all steps by
					%% B1.next_seed even though on our fork the reset line determined a different
					%% next_seed for the latest session.
					%%
					%% To avoid processing those steps twice, the client grabs PrevSessions's most
					%% recently processed step and ignores it and any lower steps found in Session.
					PrevStepNumber = case maps:get(PrevSessionKey, SessionByKey, undefined) of
						undefined -> 0;
						PrevSession -> PrevSession#vdf_session.step_number
					end,
					SessionByKey2 = apply_external_update3(CurrentSessionKey, SessionKey,
						PrevSessionKey, Session, SessionByKey, StepNumber - PrevStepNumber,
						UpperBound),
					{reply, ok,
						State#state{ session_by_key = SessionByKey2, sessions = Sessions2 }}
			end;
		#vdf_session{ step_number = CurrentStepNumber, steps = CurrentSteps,
				step_checkpoints_map = Map } = CurrentSession ->
			case CurrentStepNumber + 1 == StepNumber of
				true ->
					Map2 = maps:put(StepNumber, Checkpoints, Map),
					[Output | _] = Session#vdf_session.steps,
					CurrentSession2 = CurrentSession#vdf_session{ step_number = StepNumber,
							step_checkpoints_map = Map2,
							steps = [Output | CurrentSteps] },
					SessionByKey2 = apply_external_update3(
							CurrentSessionKey, SessionKey, PrevSessionKey,
							CurrentSession2, SessionByKey, 1, UpperBound),
					{reply, ok, State#state{ session_by_key = SessionByKey2 }};
				false ->
					case CurrentStepNumber >= StepNumber of
						true ->
							%% Inform the peer we are ahead.
							?LOG_DEBUG([{event, apply_external_vdf},
								{result, ahead_of_server},
								{session_seed, ar_util:encode(SessionSeed)},
								{session_interval, SessionInterval},
								{client_step_number, CurrentStepNumber},
								{server_step_number, StepNumber}]),
							{reply, #nonce_limiter_update_response{
											step_number = CurrentStepNumber }, State};
						false ->
							case IsPartial of
								true ->
									%% Inform the peer we miss some steps.
									?LOG_DEBUG([{event, apply_external_vdf},
										{result, missing_steps},
										{is_partial, IsPartial},
										{session_seed, ar_util:encode(SessionSeed)},
										{session_interval, SessionInterval},
										{client_step_number, CurrentStepNumber},
										{server_step_number, StepNumber}]),
									{reply, #nonce_limiter_update_response{
											step_number = CurrentStepNumber }, State};
								false ->
									%% Handle the case where the VDF client has dropped of the
									%% network briefly and the VDF server has advanced several
									%% steps within the same session. In this case the client has
									%% noticed the gap and requested the  full VDF session be sent -
									%% which may contain previously processed steps in a addition to
									%% the missing ones.
									%% 
									%% To avoid processing those steps twice, the client grabs
									%% CurrentStepNumber (our most recently processed step number)
									%% and ignores it and any lower steps found in Session.
									SessionByKey2 = apply_external_update3(
										CurrentSessionKey, SessionKey, PrevSessionKey,
										Session, SessionByKey, StepNumber - CurrentStepNumber,
										UpperBound),
									{reply, ok, State#state{ session_by_key = SessionByKey2 }}
							end
					end
			end
	end.

%% @doc Final step of applying a VDF update pushed by a VDF server
%% @param CurrentSessionKey Session key of the session currently tracked by ar_nonce_limiter state
%% @param SessionKey Session key of the session pushed by the VDF server
%% @param PrevSessionKey Session key of the session before the session pushed by the VDF server
%% @param Session Session to apply (either the session pushed by the VDF server or the one tracked
%%                by ar_nonce_limiter state)
%% @param SessionByKey Session map maintained by ar_nonce_limiter state
%% @param NumSteps Number of Session steps to apply. Steps are sorted in descending order.
%% @param UpperBound Upper bound of the session pushed by the VDF server
%%
%% Note: an important job of this function is to ensure that VDF steps are only processed once.
%% We truncate Session.steps such the previously procesed steps are not sent to
%% trigger_computed_outputs.
apply_external_update3(
	CurrentSessionKey, SessionKey, PrevSessionKey, Session, SessionByKey, NumSteps, UpperBound) ->
	SessionByKey2 = maps:put(SessionKey, Session, SessionByKey),
	StepNumber = Session#vdf_session.step_number,
	may_be_set_vdf_step_metric(SessionKey, CurrentSessionKey, StepNumber),
	PrevSession = maps:get(PrevSessionKey, SessionByKey, undefined),
	Steps = lists:sublist(Session#vdf_session.steps, NumSteps),
	trigger_computed_outputs(SessionKey, Session, PrevSessionKey, PrevSession, UpperBound, Steps),
	SessionByKey2.

may_be_set_vdf_step_metric(SessionKey, CurrentSessionKey, StepNumber) ->
	case SessionKey == CurrentSessionKey of
		true ->
			prometheus_gauge:set(vdf_step, StepNumber);
		false ->
			ok
	end.


trigger_computed_outputs(_SessionKey, _Session, _PrevSessionKey, _PrevSession,
		_UpperBound, []) ->
	ok;
trigger_computed_outputs(SessionKey, Session, PrevSessionKey, PrevSession, UpperBound,
		[Step | Steps]) ->
	ar_events:send(nonce_limiter, {computed_output, {SessionKey, Session, PrevSessionKey,
			PrevSession, Step, UpperBound}}),
	#vdf_session{ step_number = StepNumber, steps = [_ | PrevSteps] } = Session,
	Session2 = Session#vdf_session{ step_number = StepNumber - 1, steps = PrevSteps },
	trigger_computed_outputs(SessionKey, Session2, PrevSessionKey, PrevSession, UpperBound,
			Steps).

debug_double_check(Label, Result, Func, Args) ->
	{ok, Config} = application:get_env(arweave, config),
	case lists:member(double_check_nonce_limiter, Config#config.enable) of
		false ->
			Result;
		true ->
			Check = apply(Func, Args),
			case Result == Check of
				true ->
					Result;
				false ->
					ID = ar_util:encode(crypto:strong_rand_bytes(16)),
					file:write_file(Label ++ "_" ++ binary_to_list(ID),
							term_to_binary(Args)),
					Event = "nonce_limiter_" ++ Label ++ "_mismatch",
					?LOG_ERROR([{event, list_to_atom(Event)}, {report_id, ID}]),
					Result
			end
	end.

%%%===================================================================
%%% Tests.
%%%===================================================================

%% @doc Reset the state and stop computing steps automatically. Used in tests.
reset_and_pause() ->
	gen_server:cast(?MODULE, reset_and_pause).

%% @doc Do not emit the initialized event. Used in tests.
turn_off_initialized_event() ->
	gen_server:cast(?MODULE, turn_off_initialized_event).

%% @doc Get all steps starting from the latest on the current tip. Used in tests.
get_steps() ->
	gen_server:call(?MODULE, get_steps).

%% @doc Compute a single step. Used in tests.
step() ->
	Self = self(),
	spawn(
		fun() ->
			ok = ar_events:subscribe(nonce_limiter),
			gen_server:cast(?MODULE, compute_step),
			receive
				{event, nonce_limiter, {computed_output, _}} ->
					Self ! done
			end
		end
	),
	receive
		done ->
			ok
	end.

exclude_computed_steps_from_steps_to_validate_test() ->
	C1 = crypto:strong_rand_bytes(32),
	C2 = crypto:strong_rand_bytes(32),
	C3 = crypto:strong_rand_bytes(32),
	C4 = crypto:strong_rand_bytes(32),
	C5 = crypto:strong_rand_bytes(32),
	Cases = [
		{{[], []}, {[], 0}, "Case 1"},
		{{[C1], []}, {[C1], 0}, "Case 2"},
		{{[C1], [C1]}, {[], 1}, "Case 3"},
		{{[C1, C2], []}, {[C1, C2], 0}, "Case 4"},
		{{[C1, C2], [C2]}, invalid, "Case 5"},
		{{[C1, C2], [C1]}, {[C2], 1}, "Case 6"},
		{{[C1, C2], [C2, C1]}, invalid, "Case 7"},
		{{[C1, C2], [C1, C2]}, {[], 2}, "Case 8"},
		{{[C1, C2], [C1, C2, C3, C4, C5]}, {[], 2}, "Case 9"}
	],
	test_exclude_computed_steps_from_steps_to_validate(Cases).

test_exclude_computed_steps_from_steps_to_validate([Case | Cases]) ->
	{Input, Expected, Title} = Case,
	{StepsToValidate, ComputedSteps} = Input,
	Got = exclude_computed_steps_from_steps_to_validate(StepsToValidate, ComputedSteps),
	?assertEqual(Expected, Got, Title),
	test_exclude_computed_steps_from_steps_to_validate(Cases);
test_exclude_computed_steps_from_steps_to_validate([]) ->
	ok.

get_entropy_reset_point_test() ->
	ResetFreq = ?NONCE_LIMITER_RESET_FREQUENCY,
	?assertEqual(none, get_entropy_reset_point(1, ResetFreq - 1)),
	?assertEqual(ResetFreq, get_entropy_reset_point(1, ResetFreq)),
	?assertEqual(none, get_entropy_reset_point(ResetFreq, ResetFreq + 1)),
	?assertEqual(2 * ResetFreq, get_entropy_reset_point(ResetFreq, ResetFreq * 2)),
	?assertEqual(ResetFreq * 3, get_entropy_reset_point(ResetFreq * 3 - 1, ResetFreq * 3 + 2)),
	?assertEqual(ResetFreq * 4, get_entropy_reset_point(ResetFreq * 3, ResetFreq * 4 + 1)).

applies_validated_steps_test_() ->
	{timeout, 60, fun test_applies_validated_steps/0}.

test_applies_validated_steps() ->
	reset_and_pause(),
	Seed = crypto:strong_rand_bytes(32),
	NextSeed = crypto:strong_rand_bytes(32),
	NextSeed2 = crypto:strong_rand_bytes(32),
	InitialOutput = crypto:strong_rand_bytes(32),
	B1 = test_block(1, InitialOutput, Seed, NextSeed, [], []),
	turn_off_initialized_event(),
	ar_events:send(node_state, {initializing, [B1]}),
	true = ar_util:do_until(fun() -> get_current_step_number() == 1 end, 100, 1000),
	{ok, Output2, _} = compute(2, InitialOutput, ?VDF_DIFFICULTY),
	B2 = test_block(2, Output2, Seed, NextSeed, [], [Output2]),
	ok = ar_events:subscribe(nonce_limiter),
	assert_validate(B2, B1, valid),
	assert_validate(B2, B1, valid),
	assert_validate(B2#block{ nonce_limiter_info = #nonce_limiter_info{} }, B1, {invalid, 1}),
	N2 = B2#block.nonce_limiter_info,
	assert_validate(B2#block{ nonce_limiter_info = N2#nonce_limiter_info{ steps = [] } },
			B1, {invalid, 4}),
	assert_validate(B2#block{
			nonce_limiter_info = N2#nonce_limiter_info{ steps = [Output2, Output2] } },
			B1, {invalid, 2}),
	assert_step_number(2),
	[step() || _ <- lists:seq(1, 3)],
	assert_step_number(5),
	ar_events:send(node_state, {new_tip, B2, B1}),
	assert_step_number(5),
	{ok, Output3, _} = compute(3, Output2, ?VDF_DIFFICULTY),
	{ok, Output4, _} = compute(4, Output3, ?VDF_DIFFICULTY),
	B3 = test_block(4, Output4, Seed, NextSeed, [], [Output4, Output3]),
	assert_validate(B3, B2, valid),
	assert_validate(B3, B1, valid),
	{ok, Output5, _} = compute(5, mix_seed(Output4, NextSeed), ?VDF_DIFFICULTY),
	B4 = test_block(5, Output5, NextSeed, NextSeed2, [], [Output5]),
	[step() || _ <- lists:seq(1, 6)],
	assert_step_number(11),
	assert_validate(B4, B3, valid),
	ar_events:send(node_state, {new_tip, B4, B3}),
	assert_step_number(9),
	assert_validate(B4, B4, {invalid, 1}),
	% 5, 6, 7, 8, 9, 10
	B5 = test_block(10, <<>>, NextSeed, NextSeed2, [], [<<>>]),
	assert_validate(B5, B4, {invalid, 3}),
	B6 = test_block(10, <<>>, NextSeed, NextSeed2, [],
			% Steps 10, 9, 8, 7, 6.
			[<<>> | lists:sublist(get_steps(), 4)]),
	assert_validate(B6, B4, {invalid, 3}),
	Invalid = crypto:strong_rand_bytes(32),
	B7 = test_block(10, Invalid, NextSeed, NextSeed2, [],
			% Steps 10, 9, 8, 7, 6.
			[Invalid | lists:sublist(get_steps(), 4)]),
	assert_validate(B7, B4, {invalid, 3}),
	{ok, Output6, _} = compute(6, Output5, ?VDF_DIFFICULTY),
	{ok, Output7, _} = compute(7, Output6, ?VDF_DIFFICULTY),
	{ok, Output8, _} = compute(8, Output7, ?VDF_DIFFICULTY),
	B8 = test_block(8, Output8, NextSeed, NextSeed2, [], [Output8, Output7, Output6]),
	assert_validate(B8, B4, valid).

reorg_after_join_test_() ->
	{timeout, 120, fun test_reorg_after_join/0}.

test_reorg_after_join() ->
	[B0] = ar_weave:init(),
	ar_test_node:start(B0),
	ar_test_node:slave_start(B0),
	ar_test_node:connect_to_slave(),
	ar_node:mine(),
	ar_test_node:assert_slave_wait_until_height(1),
	ar_test_node:join_on_slave(),
	ar_test_node:slave_start(B0),
	ar_test_node:slave_mine(),
	ar_test_node:assert_slave_wait_until_height(1),
	ar_test_node:slave_mine(),
	ar_test_node:wait_until_height(2).

reorg_after_join2_test_() ->
	{timeout, 120, fun test_reorg_after_join2/0}.

test_reorg_after_join2() ->
	[B0] = ar_weave:init(),
	ar_test_node:start(B0),
	ar_test_node:slave_start(B0),
	ar_test_node:connect_to_slave(),
	ar_node:mine(),
	ar_test_node:assert_slave_wait_until_height(1),
	ar_test_node:join_on_slave(),
	ar_node:mine(),
	ar_test_node:wait_until_height(2),
	ar_test_node:disconnect_from_slave(),
	ar_test_node:slave_start(B0),
	ar_test_node:slave_mine(),
	ar_test_node:assert_slave_wait_until_height(1),
	ar_test_node:slave_mine(),
	ar_test_node:assert_slave_wait_until_height(2),
	ar_test_node:connect_to_slave(),
	ar_test_node:slave_mine(),
	ar_test_node:wait_until_height(3).

assert_validate(B, PrevB, ExpectedResult) ->
	request_validation(B#block.indep_hash, B#block.nonce_limiter_info,
			PrevB#block.nonce_limiter_info),
	BH = B#block.indep_hash,
	receive
		{event, nonce_limiter, {valid, BH}} ->
			case ExpectedResult of
				valid ->
					ok;
				_ ->
					?assert(false, iolist_to_binary(io_lib:format("Unexpected "
							"validation success. Expected: ~p.", [ExpectedResult])))
			end;
		{event, nonce_limiter, {invalid, BH, Code}} ->
			case ExpectedResult of
				{invalid, Code} ->
					ok;
				_ ->
					?assert(false, iolist_to_binary(io_lib:format("Unexpected "
							"validation failure: ~p. Expected: ~p.",
							[Code, ExpectedResult])))
			end
	after 2000 ->
		?assert(false, "Validation timeout.")
	end.

assert_step_number(N) ->
	timer:sleep(200),
	?assert(ar_util:do_until(fun() -> get_current_step_number() == N end, 100, 1000)).

test_block(StepNumber, Output, Seed, NextSeed, LastStepCheckpoints, Steps) ->
	#block{ indep_hash = crypto:strong_rand_bytes(32),
			nonce_limiter_info = #nonce_limiter_info{ output = Output,
					global_step_number = StepNumber, seed = Seed, next_seed = NextSeed,
					last_step_checkpoints = LastStepCheckpoints, steps = Steps } }.
