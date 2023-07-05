%%% @doc Tracks the availability and performance of the network peers.
-module(ar_peers).

-behaviour(gen_server).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_peers.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([start_link/0, get_peers/0, get_peer_performances/1, get_trusted_peers/0, is_public_peer/1,
    get_peer_release/1, stats/0, discover_peers/0, rank_peers/1, resolve_and_cache_peer/2,
    rate_response/4, rate_fetched_data/2, gossiped_data/3, gossiped_data/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% The frequency in milliseconds of ranking the known peers.
-ifdef(DEBUG).
-define(RANK_PEERS_FREQUENCY_MS, 2 * 1000).
-else.
-define(RANK_PEERS_FREQUENCY_MS, 2 * 60 * 1000).
-endif.

%% The frequency in milliseconds of asking some peers for their peers.
-ifdef(DEBUG).
-define(GET_MORE_PEERS_FREQUENCY_MS, 5000).
-else.
-define(GET_MORE_PEERS_FREQUENCY_MS, 240 * 1000).
-endif.

%% Peers to never add to the peer list.
-define(PEER_PERMANENT_BLACKLIST, []).

%% The maximum number of peers to return from get_peers/0.
-define(MAX_PEERS, 1000).

%% The number of failed requests in a row we tolerate before dropping the peer.
-define(TOLERATE_FAILURE_COUNT, 20).
-define(MINIMUM_SUCCESS, 0.5).
-define(THROUGHPUT_ALPHA, 0.1).
-define(SUCCESS_ALPHA, 0.01).

-define(RATE_SUCCESS, 1).
-define(RATE_ERROR, 0).
-define(RATE_PENALTY, -1).

%% We only do scoring of this many TCP ports per IP address. When there are not enough slots,
%% we remove the peer from the first slot.
-define(DEFAULT_PEER_PORT_MAP,
    {empty_slot, empty_slot, empty_slot, empty_slot, empty_slot, empty_slot, empty_slot, empty_slot,
        empty_slot, empty_slot}
).

-record(state, {}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_peers() ->
    case catch ets:lookup(?MODULE, peers) of
        {'EXIT', _} ->
            [];
        [] ->
            [];
        [{_, Peers}] ->
            Peers
    end.

get_peer_performances(Peers) ->
    [get_or_init_performance(Peer) || Peer <- Peers].

-if(?NETWORK_NAME == "arweave.N.1").
get_trusted_peers() ->
    {ok, Config} = application:get_env(arweave, config),
    case Config#config.peers of
        [] ->
            ArweavePeers = ["sfo-1.na-west-1.arweave.net", "ams-1.eu-central-1.arweave.net",
                			"fra-1.eu-central-2.arweave.net", "blr-1.ap-central-1.arweave.net",
                			"sgp-1.ap-central-2.arweave.net"
            ],
            resolve_peers(ArweavePeers);
        Peers ->
            Peers
    end.
-else.
get_trusted_peers() ->
    {ok, Config} = application:get_env(arweave, config),
    Config#config.peers.
-endif.

resolve_peers([]) ->
    [];
resolve_peers([RawPeer | Peers]) ->
    case ar_util:safe_parse_peer(RawPeer) of
        {ok, Peer} ->
            [Peer | resolve_peers(Peers)];
        {error, invalid} ->
            ?LOG_WARNING([
                {event, failed_to_resolve_trusted_peer},
                {peer, RawPeer}
            ]),
            resolve_peers(Peers)
    end.

%% @doc Return true if the given peer has a public IPv4 address.
%% https://en.wikipedia.org/wiki/Reserved_IP_addresses.
is_public_peer({Oct1, Oct2, Oct3, Oct4, _Port}) ->
    is_public_peer({Oct1, Oct2, Oct3, Oct4});
is_public_peer({0, _, _, _}) ->
    false;
is_public_peer({10, _, _, _}) ->
    false;
is_public_peer({127, _, _, _}) ->
    false;
is_public_peer({100, Oct2, _, _}) when Oct2 >= 64 andalso Oct2 =< 127 ->
    false;
is_public_peer({169, 254, _, _}) ->
    false;
is_public_peer({172, Oct2, _, _}) when Oct2 >= 16 andalso Oct2 =< 31 ->
    false;
is_public_peer({192, 0, 0, _}) ->
    false;
is_public_peer({192, 0, 2, _}) ->
    false;
is_public_peer({192, 88, 99, _}) ->
    false;
is_public_peer({192, 168, _, _}) ->
    false;
is_public_peer({198, 18, _, _}) ->
    false;
is_public_peer({198, 19, _, _}) ->
    false;
is_public_peer({198, 51, 100, _}) ->
    false;
is_public_peer({203, 0, 113, _}) ->
    false;
is_public_peer({Oct1, _, _, _}) when Oct1 >= 224 ->
    false;
is_public_peer(_) ->
    true.

%% @doc Return the release nubmer reported by the peer.
%% Return -1 if the release is not known.
get_peer_release(Peer) ->
    case catch ets:lookup(?MODULE, {peer, Peer}) of
        [{_, #performance{release = Release}}] ->
            Release;
        _ ->
            -1
    end.

rate_response({_Host, _Port}, _, _, _) ->
    %% Only track requests for IP-based peers as the rest of the stack assumes an IP-based peer.
    ok;
rate_response(Peer, PathLabel, get, Response) ->
    gen_server:cast(
        ?MODULE, {rate_response, Peer, PathLabel, get, ar_metrics:get_status_class(Response)}
    );
rate_response(_Peer, _PathLabel, _Method, _Response) ->
    ok.

rate_fetched_data(_Peer, {ok, _}) ->
    %% The fetched data is valid so the rating was already captured as part of
    %% the start/end request pair. Nothing more to do.
    ok;
rate_fetched_data(Peer, {error, _}) ->
    %% The fetched data is invalid, so we need to reverse the rating that was applied
    %% in end_request, and then apply a penalty
    gen_server:cast(?MODULE, {invalid_fetched_data, Peer});
rate_fetched_data(Peer, invalid) ->
    %% The fetched data is invalid, so we need to reverse the rating that was applied
    %% in end_request, and then apply a penalty
    gen_server:cast(?MODULE, {invalid_fetched_data, Peer}).

gossiped_data(Peer, Data) ->
    gossiped_data(Peer, Data, ok).

gossiped_data(Peer, Data, ok) ->
    gen_server:cast(?MODULE, {
        gossiped_data, Peer, Data
    });
gossiped_data(_Peer, _Data, _ValidationStatus) ->
    %% Ignore skipped or invalid blocks for now (consistent with old behavior, but may need to
    %% be revisited)
    ok.

%% @doc Print statistics about the current peers.
stats() ->
    Connected = get_peers(),
    io:format("Connected peers, in preference order:~n"),
    stats(Connected),
    io:format("Other known peers:~n"),
    All = ets:foldl(
        fun
            ({{peer, Peer}, _}, Acc) -> [Peer | Acc];
            (_, Acc) -> Acc
        end,
        [],
        ?MODULE
    ),
    stats(All -- Connected).
stats(Peers) ->
    lists:foreach(
        fun(Peer) -> format_stats(Peer, get_or_init_performance(Peer)) end,
        Peers
    ).

discover_peers() ->
    case ets:lookup(?MODULE, peers) of
        [] ->
            ok;
        [{_, []}] ->
            ok;
        [{_, Peers}] ->
            Peer = ar_util:pick_random(Peers),
            discover_peers(get_peer_peers(Peer))
    end.

%% @doc Resolve the domain name of the given peer (if the given peer is an IP address)
%% and cache it. Return {ok, Peer} | {error, Reason}.
resolve_and_cache_peer(RawPeer, Type) ->
    case ar_util:safe_parse_peer(RawPeer) of
        {ok, Peer} ->
            case ets:lookup(?MODULE, {raw_peer, RawPeer}) of
                [] ->
                    ets:insert(?MODULE, {{raw_peer, RawPeer}, Peer}),
                    ets:insert(?MODULE, {{Type, Peer}, RawPeer});
                [{_, Peer}] ->
                    ok;
                [{_, PreviousPeer}] ->
                    %% This peer is configured with a domain name rather than IP address,
                    %% and the IP underlying the domain name has changed.
                    ets:delete(?MODULE, {Type, PreviousPeer}),
                    ets:insert(?MODULE, {{raw_peer, RawPeer}, Peer}),
                    ets:insert(?MODULE, {{Type, Peer}, RawPeer})
            end,
            {ok, Peer};
        Error ->
            Error
    end.

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    [ok, ok] = ar_events:subscribe([peer, block]),
    load_peers(),
    gen_server:cast(?MODULE, rank_peers),
    gen_server:cast(?MODULE, ping_peers),
    timer:apply_interval(?GET_MORE_PEERS_FREQUENCY_MS, ?MODULE, discover_peers, []),
    {ok, #state{}}.

handle_call(Request, _From, State) ->
    ?LOG_WARNING("event: unhandled_call, request: ~p", [Request]),
    {reply, ok, State}.

handle_cast({add_peer, Peer, Release}, State) ->
    may_be_rotate_peer_ports(Peer),
    case ets:lookup(?MODULE, {peer, Peer}) of
        [{_, #performance{release = Release}}] ->
            ok;
        [{_, Performance}] ->
            set_performance(Peer, Performance#performance{release = Release});
        [] ->
            set_performance(Peer, #performance{release = Release})
    end,
    {noreply, State};
handle_cast(rank_peers, State) ->
    Total = get_total_rating(),
    Peers =
        ets:foldl(
            fun
                ({{peer, Peer}, Performance}, Acc) ->
                    %% Bigger score increases the chances to end up on the top
                    %% of the peer list, but at the same time the ranking is
                    %% probabilistic to always give everyone a chance to improve
                    %% in the competition (i.e., reduce the advantage gained by
                    %% being the first to earn a reputation).
                    Score =
                        rand:uniform() * Performance#performance.rating /
                            (Total + 0.0001),
                    [{Peer, Score} | Acc];
                (_, Acc) ->
                    Acc
            end,
            [],
            ?MODULE
        ),
    prometheus_gauge:set(arweave_peer_count, length(Peers)),
    ets:insert(?MODULE, {peers, lists:sublist(rank_peers(Peers), ?MAX_PEERS)}),
    ar_util:cast_after(?RANK_PEERS_FREQUENCY_MS, ?MODULE, rank_peers),
    stats(),
    {noreply, State};
handle_cast(ping_peers, State) ->
    [{peers, Peers}] = ets:lookup(?MODULE, peers),
    ping_peers(lists:sublist(Peers, 100)),
    {noreply, State};
handle_cast({rate_response, Peer, PathLabel, get, Status}, State) ->
    case Status of
        "success" ->
            update_rating(Peer, ?RATE_SUCCESS);
        "redirection" ->
            %% don't update rating
            ok;
        "client-error" ->
            %% don't update rating
            ok;
        _ ->
            update_rating(Peer, ?RATE_ERROR)
    end,
    ?LOG_DEBUG([
        {event, update_rating},
        {update_type, response},
        {path, PathLabel},
        {status, Status},
        {peer, ar_util:format_peer(Peer)}
    ]),
    {noreply, State};
handle_cast({invalid_fetched_data, Peer}, State) ->
    ?LOG_DEBUG([
        {event, update_rating},
        {update_type, invalid_fetched_data},
        {peer, ar_util:format_peer(Peer)}
    ]),
    %% log 2 failures - first is to reverse the success that was previously recorded by end_request
    %% (since end_request only considers whether or not the HTTP request was successful and does not
    %% consider the validity of the data it may be overly permissive), and the second is to
    %% penalize the peer for serving invalid data.
    %% Note: this is an approximation as due to the nature of the EMA this won't exactly reverse
    %% the prior success.
    update_rating(Peer, false),
    update_rating(Peer, false),
    {noreply, State};
handle_cast({gossiped_data, Peer, Data}, State) ->
    case check_external_peer(Peer) of
        ok ->
            ?LOG_DEBUG([
                {event, update_rating},
                {update_type, gossiped_data},
                {peer, ar_util:format_peer(Peer)}
            ]),
            update_rating(Peer, true);
        _ ->
            ok
    end,

    {noreply, State};
handle_cast(Cast, State) ->
    ?LOG_WARNING("event: unhandled_cast, cast: ~p", [Cast]),
    {noreply, State}.

handle_info({event, peer, {made_request, Peer, Release}}, State) ->
    may_be_rotate_peer_ports(Peer),
    case ets:lookup(?MODULE, {peer, Peer}) of
        [{_, #performance{release = Release}}] ->
            ok;
        [{_, Performance}] ->
            set_performance(Peer, Performance#performance{release = Release});
        [] ->
            case check_external_peer(Peer) of
                ok ->
                    set_performance(Peer, #performance{release = Release});
                _ ->
                    ok
            end
    end,
    {noreply, State};
handle_info({event, peer, {fetched_tx, Peer, TimeDelta, Size}}, State) ->
    % ?LOG_DEBUG([{event, update_rating}, {type, fetched_tx}, {peer, ar_util:format_peer(Peer)}, {time_delta, TimeDelta}, {size, Size}]),
    % update_rating(Peer, TimeDelta, Size),
    {noreply, State};
handle_info({event, peer, {fetched_block, Peer, TimeDelta, Size}}, State) ->
    % ?LOG_DEBUG([{event, update_rating}, {type, fetched_tx}, {peer, ar_util:format_peer(Peer)}, {time_delta, TimeDelta}, {size, Size}]),
    % update_rating(Peer, TimeDelta, Size),
    {noreply, State};
handle_info({event, peer, {bad_response, {Peer, _Type, _Reason}}}, State) ->
    issue_warning(Peer),
    {noreply, State};
handle_info({event, peer, {banned, BannedPeer}}, State) ->
    remove_peer(BannedPeer),
    {noreply, State};
handle_info({event, block, {rejected, failed_to_fetch_first_chunk, _H, Peer}}, State) ->
    issue_warning(Peer),
    {noreply, State};
handle_info({event, block, {rejected, failed_to_fetch_second_chunk, _H, Peer}}, State) ->
    issue_warning(Peer),
    {noreply, State};
handle_info({event, block, {rejected, failed_to_fetch_chunk, _H, Peer}}, State) ->
    issue_warning(Peer),
    {noreply, State};
handle_info({event, block, _}, State) ->
    {noreply, State};
handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};
handle_info(Message, State) ->
    ?LOG_WARNING("event: unhandled_info, message: ~p", [Message]),
    {noreply, State}.

terminate(_Reason, _State) ->
    store_peers().

%%%===================================================================
%%% Private functions.
%%%===================================================================
get_peer_peers(Peer) ->
    case ar_http_iface_client:get_peers(Peer) of
        unavailable -> [];
        Peers -> Peers
    end.

get_or_init_performance(Peer) ->
    get_or_init_performance(Peer, overall).
get_or_init_performance(Peer, Metric) ->
    case ets:lookup(?MODULE, {peer, Peer, Metric}) of
        [] ->
            #performance{};
        [{_, Performance}] ->
            Performance
    end.

set_performance(Peer, Performance) ->
    set_performance(Peer, overall, Performance).
set_performance(Peer, Metric, Performance) ->
    ets:insert(?MODULE, [{{peer, Peer, Metric}, Performance}]).

get_total_rating() ->
    get_total_rating(overall).
get_total_rating(Metric) ->
    case ets:lookup(?MODULE, {rating_total, Metric}) of
        [] ->
            0;
        [{_, Total}] ->
            Total
    end.

set_total_rating(Total) ->
    set_total_rating(overall, Total).
set_total_rating(Metric, Total) ->
    ets:insert(?MODULE, {{rating_total, Metric}, Total}).

discover_peers([]) ->
    ok;
discover_peers([Peer | Peers]) ->
    case ets:member(?MODULE, {peer, Peer}) of
        true ->
            ok;
        false ->
            IsPublic = is_public_peer(Peer),
            IsBanned = ar_blacklist_middleware:is_peer_banned(Peer) == banned,
            IsBlacklisted = lists:member(Peer, ?PEER_PERMANENT_BLACKLIST),
            case IsPublic andalso not IsBanned andalso not IsBlacklisted of
                false ->
                    ok;
                true ->
                    case ar_http_iface_client:get_info(Peer, release) of
                        {<<"release">>, Release} when is_integer(Release) ->
                            gen_server:cast(?MODULE, {add_peer, Peer, Release});
                        _ ->
                            ok
                    end
            end
    end,
    discover_peers(Peers).

format_stats(Peer, Perf) ->
    KB = Perf#performance.bytes / 1024,
    io:format(
        "\t~s ~.2f kB/s (~.2f kB, ~B latency, ~.2f success, ~p transfers)~n",
        [
            string:pad(ar_util:format_peer(Peer), 21, trailing, $\s),
            float(Perf#performance.rating),
            KB,
            trunc(Perf#performance.latency),
            Perf#performance.success,
            Perf#performance.transfers
        ]
    ).

read_peer_records() ->
	PeerRecords = case ar_storage:read_term(peers) of
        not_found ->
            ok;
        {ok, {_TotalRating, Records}} ->
			%% Legacy format included the TotalRating, but since we always recalculate it when
			%% loading the peers, we've dropped it from the saved format.
			Records;
		{ok, Records} ->
			Records
	end,

	%% We only want to return records for available peers. However, PeerRecords may contain
	%% multiple records for the same peer (one for each tracked metric) and we don't want to
	%% ping each peer multiple times. So:
	%% 1. Get a set of UniquePeers from PeerRecords
	%% 2. Ping those peers to get a set of VaidPeers
	%% 3. Filter PeerRecords to only include records for ValidPeers
	UniquePeers = sets:from_list([ element(1, Record) || Record <- PeerRecords ]),

	ValidPeers = sets:filter(
		fun(Peer) ->
			case ar_http_iface_client:get_info(Peer, name) of
				info_unavailable ->
					?LOG_DEBUG([{event, peer_unavailable}, {peer, ar_util:format_peer(Peer)}]),
					false;
				<<?NETWORK_NAME>> ->
					true;
				Network ->
					?LOG_DEBUG([
						{event, peer_from_the_wrong_network},
						{peer, ar_util:format_peer(Peer)},
						{network, Network}
					]),
					false
			end
		end,
		UniquePeers
	),

	ValidPeerRecords = lists:filter(
		fun(PeerRecord) ->	
			sets:is_element(element(1, PeerRecord), ValidPeers)
		end,
		PeerRecords
	),
	ValidPeerRecords.
	
load_peers() ->
	?LOG_INFO([{event, polling_saved_peers}]),
	ar:console("Polling saved peers...~n"),
	PeerRecords = read_peer_records(),
	load_peers(PeerRecords),
	load_totals(),
	?LOG_INFO([{event, polled_saved_peers}]),
	ar:console("Polled saved peers.~n").

load_peers(PeerRecords) when length(PeerRecords) < 20 ->
    ar_util:pmap(fun load_peer/1, PeerRecords);
load_peers(PeerRecords) ->
    {PeerRecords2, PeerRecords3} = lists:split(20, PeerRecords),
    ar_util:pmap(fun load_peer/1, PeerRecords2),
    load_peers(PeerRecords3).

load_peer({Peer, Performance}) ->
	load_peer({Peer, overall, Performance});
load_peer({Peer, Metric, Performance}) ->
	may_be_rotate_peer_ports(Peer),
	case Performance of
		{performance, Bytes, Latency, Transfers, _Failures, Rating} ->
			%% For compatibility with a few nodes already storing the records
			%% without the release field.
			set_performance(Peer, Metric, #performance{
				bytes = Bytes,
				latency = Latency,
				transfers = Transfers,
				rating = Rating
			});
		{performance, Bytes, Latency, Transfers, _Failures, Rating, Release} ->
			%% For compatibility with nodes storing records from before the introduction of
			%% the version field
			set_performance(Peer, Metric, #performance{
				release = Release,
				bytes = Bytes,
				latency = Latency,
				transfers = Transfers,
				rating = Rating
			});
		{performance, 3, _Release, _Bytes, _Latency, _Transfers, _Success, _Rating} ->
			%% Going forward whenever we change the #performance record we should increment the
			%% version field so we can match on it when doing a load. Here we're handling the
			%% version 3 format.
			set_performance(Peer, Metric, Performance)
	end.

load_totals() ->
	Totals = ets:foldl(
		fun
			({{peer, Metric, _Peer}, Performance}, Acc) ->
				Total = maps:get(Metric, Acc, 0),
				maps:put(Metric, Total + Performance#performance.rating, Acc);
			(_, Acc) ->
				Acc
		end,
		#{},
		?MODULE
	),

	lists:foreach(
		fun(Metric) ->
			Total = maps:get(Metric, Totals, 0),
			set_total_rating(Metric, Total)
		end,
		?AVAILABLE_METRICS
	).

may_be_rotate_peer_ports(Peer) ->
    {IP, Port} = get_ip_port(Peer),
    case ets:lookup(?MODULE, {peer_ip, IP}) of
        [] ->
            ets:insert(
                ?MODULE, {{peer_ip, IP}, {erlang:setelement(1, ?DEFAULT_PEER_PORT_MAP, Port), 1}}
            );
        [{_, {PortMap, Position}}] ->
            case is_in_port_map(Port, PortMap) of
                {true, _} ->
                    ok;
                false ->
                    MaxSize = erlang:size(?DEFAULT_PEER_PORT_MAP),
                    case Position < MaxSize of
                        true ->
                            ets:insert(
                                ?MODULE,
                                {{peer_ip, IP}, {
                                    erlang:setelement(Position + 1, PortMap, Port), Position + 1
                                }}
                            );
                        false ->
                            RemovedPeer = construct_peer(IP, element(1, PortMap)),
                            PortMap2 = shift_port_map_left(PortMap),
                            PortMap3 = erlang:setelement(MaxSize, PortMap2, Port),
                            ets:insert(?MODULE, {{peer_ip, IP}, {PortMap3, MaxSize}}),
                            remove_peer(RemovedPeer)
                    end
            end
    end.

get_ip_port({A, B, C, D, Port}) ->
    {{A, B, C, D}, Port}.

construct_peer({A, B, C, D}, Port) ->
    {A, B, C, D, Port}.

is_in_port_map(Port, PortMap) ->
    is_in_port_map(Port, PortMap, erlang:size(PortMap), 1).

is_in_port_map(_Port, _PortMap, Max, N) when N > Max ->
    false;
is_in_port_map(Port, PortMap, Max, N) ->
    case element(N, PortMap) == Port of
        true ->
            {true, N};
        false ->
            is_in_port_map(Port, PortMap, Max, N + 1)
    end.

shift_port_map_left(PortMap) ->
    shift_port_map_left(PortMap, erlang:size(PortMap), 1).

shift_port_map_left(PortMap, Max, N) when N == Max ->
    erlang:setelement(N, PortMap, empty_slot);
shift_port_map_left(PortMap, Max, N) ->
    PortMap2 = erlang:setelement(N, PortMap, element(N + 1, PortMap)),
    shift_port_map_left(PortMap2, Max, N + 1).

ping_peers(Peers) when length(Peers) < 100 ->
    ar_util:pmap(fun ar_http_iface_client:add_peer/1, Peers);
ping_peers(Peers) ->
    {Send, Rest} = lists:split(100, Peers),
    ar_util:pmap(fun ar_http_iface_client:add_peer/1, Send),
    ping_peers(Rest).

-ifdef(DEBUG).
%% Do not filter out loopback IP addresses with custom port in the debug mode
%% to allow multiple local VMs to peer with each other.
is_loopback_ip({127, _, _, _, Port}) ->
    {ok, Config} = application:get_env(arweave, config),
    Port == Config#config.port;
is_loopback_ip({_, _, _, _, _}) ->
    false.
-else.
%% @doc Is the IP address in question a loopback ('us') address?
is_loopback_ip({A, B, C, D, _Port}) -> is_loopback_ip({A, B, C, D});
is_loopback_ip({127, _, _, _}) -> true;
is_loopback_ip({0, _, _, _}) -> true;
is_loopback_ip({169, 254, _, _}) -> true;
is_loopback_ip({255, 255, 255, 255}) -> true;
is_loopback_ip({_, _, _, _}) -> false.
-endif.

%% @doc Return a ranked list of peers.
rank_peers(ScoredPeers) ->
    SortedReversed = lists:reverse(
        lists:sort(fun({_, S1}, {_, S2}) -> S1 >= S2 end, ScoredPeers)
    ),
    GroupedBySubnet =
        lists:foldl(
            fun({{A, B, _C, _D, _Port}, _Score} = Peer, Acc) ->
                maps:update_with({A, B}, fun(L) -> [Peer | L] end, [Peer], Acc)
            end,
            #{},
            SortedReversed
        ),
    ScoredSubnetPeers =
        maps:fold(
            fun(_Subnet, SubnetPeers, Acc) ->
                element(
                    2,
                    lists:foldl(
                        fun({Peer, Score}, {N, Acc2}) ->
                            %% At first we take the best peer from every subnet,
                            %% then take the second best from every subnet, etc.
                            {N + 1, [{Peer, {-N, Score}} | Acc2]}
                        end,
                        {0, Acc},
                        SubnetPeers
                    )
                )
            end,
            [],
            GroupedBySubnet
        ),
    [
        Peer
     || {Peer, _} <- lists:sort(
            fun({_, S1}, {_, S2}) -> S1 >= S2 end,
            ScoredSubnetPeers
        )
    ].

check_external_peer(Peer) ->
    IsLoopbackIP = is_loopback_ip(Peer),
    IsBlacklisted = lists:member(Peer, ?PEER_PERMANENT_BLACKLIST),
    IsBanned = ar_blacklist_middleware:is_peer_banned(Peer) == banned,
    case {IsLoopbackIP, IsBlacklisted, IsBanned} of
        {true, _, _} ->
            reject;
        {_, true, _} ->
            reject;
        {_, _, true} ->
            reject;
        _ ->
            ok
    end.

update_rating(Peer, IsSuccess) ->
    update_rating(Peer, [], IsSuccess).
update_rating(Peer, AdditionalMetrics, IsSuccess) ->
    Performance = get_or_init_performance(Peer),
    %% Pass in the current latency and bytes values in order to hold them constant.
    %% Only the success average should be updated.
    update_rating(
        Peer,
        AdditionalMetrics,
        Performance#performance.latency,
        Performance#performance.bytes,
        IsSuccess
    ).

update_rating(Peer, LatencyMicroseconds, Size, IsSuccess) ->
    update_rating(Peer, [], LatencyMicroseconds, Size, IsSuccess).
update_rating(Peer, AdditionalMetrics, LatencyMicroseconds, Size, IsSuccess) ->
    %% Update the 'overall' metric plus any additional metrics specified.
    lists:foreach(
        fun(Metric) ->
            update_performance(Peer, Metric, LatencyMicroseconds, Size, IsSuccess)
        end,
        [overall | AdditionalMetrics]
    ).

update_performance(Peer, Metric, LatencyMicroseconds, Size, IsSuccess) ->
    %% only update available metrics
    true = lists:member(Metric, ?AVAILABLE_METRICS),
    Performance = get_or_init_performance(Peer, Metric),
    Total = get_total_rating(Metric),
    #performance{
        bytes = Bytes,
        latency = Latency,
        success = Success,
        rating = Rating,
        transfers = N
    } = Performance,
    Bytes2 = calculate_ema(Bytes, Size, ?THROUGHPUT_ALPHA),
    Latency2 = calculate_ema(Latency, LatencyMicroseconds / 1000, ?THROUGHPUT_ALPHA),
    Success2 = calculate_ema(Success, ar_util:bool_to_int(IsSuccess), ?SUCCESS_ALPHA),
    Rating2 = (Bytes2 / Latency2) * Success2,
    Performance2 = Performance#performance{
        bytes = Bytes2,
        latency = Latency2,
        success = Success2,
        rating = Rating2,
        transfers = N + 1
    },
    Total2 = Total - Rating + Rating2,
    may_be_rotate_peer_ports(Peer),
    set_performance(Peer, Metric, Performance2),
    set_total_rating(Metric, Total2).

calculate_ema(OldEMA, Value, Alpha) ->
    Alpha * Value + (1 - Alpha) * OldEMA.

remove_peer(RemovedPeer) ->
    ?LOG_DEBUG([
        {event, remove_peer},
        {peer, ar_util:format_peer(RemovedPeer)}
    ]),
    lists:foreach(
        fun(Metric) ->
            Performance = get_or_init_performance(RemovedPeer, Metric),
            Total = get_total_rating(Metric),
            set_total_rating(Metric, Total - Performance#performance.rating),
            ets:delete(?MODULE, {peer, RemovedPeer, Metric})
        end,
        ?AVAILABLE_METRICS
    ),
    remove_peer_port(RemovedPeer).

remove_peer_port(Peer) ->
    {IP, Port} = get_ip_port(Peer),
    case ets:lookup(?MODULE, {peer_ip, IP}) of
        [] ->
            ok;
        [{_, {PortMap, Position}}] ->
            case is_in_port_map(Port, PortMap) of
                false ->
                    ok;
                {true, N} ->
                    PortMap2 = erlang:setelement(N, PortMap, empty_slot),
                    case is_port_map_empty(PortMap2) of
                        true ->
                            ets:delete(?MODULE, {peer_ip, IP});
                        false ->
                            ets:insert(?MODULE, {{peer_ip, IP}, {PortMap2, Position}})
                    end
            end
    end.

is_port_map_empty(PortMap) ->
    is_port_map_empty(PortMap, erlang:size(PortMap), 1).

is_port_map_empty(_PortMap, Max, N) when N > Max ->
    true;
is_port_map_empty(PortMap, Max, N) ->
    case element(N, PortMap) of
        empty_slot ->
            is_port_map_empty(PortMap, Max, N + 1);
        _ ->
            false
    end.

store_peers() ->
    Records =
		ets:foldl(
			fun
				({{peer, Peer, Metric}, Performance}, Acc) ->
					[{Peer, Metric, Performance} | Acc];
				(_, Acc) ->
					Acc
			end,
			[],
			?MODULE
		),
    case Records of
        [] ->
            ok;
        _ ->     
            ar_storage:write_term(peers, Records)
    end.

issue_warning(Peer) ->
    Performance = get_or_init_performance(Peer),
    Success = calculate_ema(Performance#performance.success, 0, ?SUCCESS_ALPHA),
    case Success < ?MINIMUM_SUCCESS of
        true ->
            remove_peer(Peer);
        false ->
            Performance2 = Performance#performance{success = Success},
            may_be_rotate_peer_ports(Peer),
            set_performance(Peer, Performance2)
    end.

%%%===================================================================
%%% Tests.
%%%===================================================================

rotate_peer_ports_test() ->
    Peer = {2, 2, 2, 2, 1},
    may_be_rotate_peer_ports(Peer),
    [{_, {PortMap, 1}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(1, element(1, PortMap)),
    remove_peer(Peer),
    ?assertEqual([], ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}})),
    may_be_rotate_peer_ports(Peer),
    Peer2 = {2, 2, 2, 2, 2},
    may_be_rotate_peer_ports(Peer2),
    [{_, {PortMap2, 2}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(1, element(1, PortMap2)),
    ?assertEqual(2, element(2, PortMap2)),
    remove_peer(Peer),
    [{_, {PortMap3, 2}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(empty_slot, element(1, PortMap3)),
    ?assertEqual(2, element(2, PortMap3)),
    Peer3 = {2, 2, 2, 2, 3},
    Peer4 = {2, 2, 2, 2, 4},
    Peer5 = {2, 2, 2, 2, 5},
    Peer6 = {2, 2, 2, 2, 6},
    Peer7 = {2, 2, 2, 2, 7},
    Peer8 = {2, 2, 2, 2, 8},
    Peer9 = {2, 2, 2, 2, 9},
    Peer10 = {2, 2, 2, 2, 10},
    Peer11 = {2, 2, 2, 2, 11},
    may_be_rotate_peer_ports(Peer3),
    may_be_rotate_peer_ports(Peer4),
    may_be_rotate_peer_ports(Peer5),
    may_be_rotate_peer_ports(Peer6),
    may_be_rotate_peer_ports(Peer7),
    may_be_rotate_peer_ports(Peer8),
    may_be_rotate_peer_ports(Peer9),
    may_be_rotate_peer_ports(Peer10),
    [{_, {PortMap4, 10}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(empty_slot, element(1, PortMap4)),
    ?assertEqual(2, element(2, PortMap4)),
    ?assertEqual(10, element(10, PortMap4)),
    may_be_rotate_peer_ports(Peer8),
    may_be_rotate_peer_ports(Peer9),
    may_be_rotate_peer_ports(Peer10),
    [{_, {PortMap5, 10}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(empty_slot, element(1, PortMap5)),
    ?assertEqual(2, element(2, PortMap5)),
    ?assertEqual(3, element(3, PortMap5)),
    ?assertEqual(9, element(9, PortMap5)),
    ?assertEqual(10, element(10, PortMap5)),
    may_be_rotate_peer_ports(Peer11),
    [{_, {PortMap6, 10}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(element(2, PortMap5), element(1, PortMap6)),
    ?assertEqual(3, element(2, PortMap6)),
    ?assertEqual(4, element(3, PortMap6)),
    ?assertEqual(5, element(4, PortMap6)),
    ?assertEqual(11, element(10, PortMap6)),
    may_be_rotate_peer_ports(Peer11),
    [{_, {PortMap7, 10}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(element(2, PortMap5), element(1, PortMap7)),
    ?assertEqual(3, element(2, PortMap7)),
    ?assertEqual(4, element(3, PortMap7)),
    ?assertEqual(5, element(4, PortMap7)),
    ?assertEqual(11, element(10, PortMap7)),
    remove_peer(Peer4),
    [{_, {PortMap8, 10}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(empty_slot, element(3, PortMap8)),
    ?assertEqual(3, element(2, PortMap8)),
    ?assertEqual(5, element(4, PortMap8)),
    remove_peer(Peer2),
    remove_peer(Peer3),
    remove_peer(Peer5),
    remove_peer(Peer6),
    remove_peer(Peer7),
    remove_peer(Peer8),
    remove_peer(Peer9),
    remove_peer(Peer10),
    [{_, {PortMap9, 10}}] = ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}}),
    ?assertEqual(11, element(10, PortMap9)),
    remove_peer(Peer11),
    ?assertEqual([], ets:lookup(?MODULE, {peer_ip, {2, 2, 2, 2}})).
