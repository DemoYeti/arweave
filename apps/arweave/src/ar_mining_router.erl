-module(ar_mining_router).

-behaviour(gen_server).

-export([start_link/0, prepare_solution/1, route_solution/1, route_h1/2, route_h2/1]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_mining.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-record(state, {
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the gen_server.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
	
prepare_solution(Candidate) ->
	%% A pool client does not validate VDF before sharing a solution.
	{ok, Config} = application:get_env(arweave, config),
	ar_mining_server:prepare_solution(Candidate, Config#config.is_pool_client).

route_solution(Solution) ->
	{ok, Config} = application:get_env(arweave, config),
	route_solution(Config#config.cm_exit_peer, Config#config.is_pool_client, Solution).

route_h1(Candidate, DiffPair) ->
	{ok, Config} = application:get_env(arweave, config),
	case Config#config.coordinated_mining of
		false ->
			ok;
		true ->
			ar_coordination:computed_h1(Candidate, DiffPair)
	end.

route_h2(#mining_candidate{ cm_lead_peer = not_set } = Candidate) ->
	prepare_solution(Candidate);
route_h2(Candidate) ->
	ar_coordination:computed_h2_for_peer(Candidate).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	{ok, #state{}}.

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_info(Message, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {message, Message}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

route_solution(not_set, true, Solution) ->
	%% When posting a partial solution the pool client will skip many of the validation steps
	%% that are normally performed before sharing a solution.
	ar_pool:post_partial_solution(Solution);
route_solution(not_set, _IsPoolClient, Solution) ->
	ar_mining_server:validate_solution(Solution);
route_solution(ExitPeer, true, Solution) ->
	case ar_http_iface_client:post_partial_solution(ExitPeer, Solution) of
		{ok, _} ->
			ok;
		{error, Reason} ->
			?LOG_WARNING([{event, found_partial_solution_but_failed_to_reach_exit_node},
					{reason, io_lib:format("~p", [Reason])}]),
			ar:console("We found a partial solution but failed to reach the exit node, "
					"error: ~p.", [io_lib:format("~p", [Reason])])
	end;
route_solution(ExitPeer, _IsPoolClient, Solution) ->
	case ar_http_iface_client:cm_publish_send(ExitPeer, Solution) of
		{ok, _} ->
			ok;
		{error, Reason} ->
			?LOG_WARNING([{event, solution_rejected},
					{reason, failed_to_reach_exit_node},
					{message, io_lib:format("~p", [Reason])}]),
			ar:console("We found a solution but failed to reach the exit node, "
					"error: ~p.", [io_lib:format("~p", [Reason])]),
			ar_mining_stats:solution(rejected)
	end.
