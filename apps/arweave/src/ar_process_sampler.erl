-module(ar_process_sampler).
-behaviour(gen_server).

-include_lib("arweave/include/ar.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SAMPLE_PROCESSES_INTERVAL, 1000).
-define(SAMPLE_SCHEDULERS_INTERVAL, 30000).
-define(SAMPLE_SCHEDULERS_DURATION, 5000).

-record(state, {
	scheduler_samples = undefined
}).

%% API
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server callbacks
init([]) ->
	timer:send_interval(?SAMPLE_PROCESSES_INTERVAL, sample_processes),
	ar_util:cast_after(?SAMPLE_SCHEDULERS_INTERVAL, ?MODULE, sample_schedulers),
	{ok, #state{}}.

handle_call(_Request, _From, State) ->
	{reply, ok, State}.

handle_cast(sample_schedulers, State) ->
	State2 = sample_schedulers(State),
	{noreply, State2};
	
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(sample_processes, State) ->
	Processes = erlang:processes(),
	ProcessData = lists:filtermap(fun(Pid) -> process_function(Pid) end, Processes),

	{ProcessMemory, ProcessMsgQueueLen} =
		lists:foldl(fun(
				{Status, ProcessName, FunctionName, Memory, MsgQueueLen},
				{MemoryAcc, MsgQueueLenAcc}
			) ->
				case Status of
					running ->
						prometheus_counter:inc(process_functions, [FunctionName]);
					_ ->
						ok
				end,

				%% Sum the memory and message queue length for each process. This is a compromise
				%% for handling unregistered processes. It has the effect of summing the memory
				%% and message queue length across all unregistered processes running off the
				%% same function. In general this is what we want (e.g. for the io threads within
				%% ar_mining_io and the hashing threads within ar_mining_hashing, we wand to
				%% see if, in aggregate, their memory or message queue length has spiked).
				MemoryTotal = maps:get(ProcessName, MemoryAcc, 0),
				MsgQueueLenTotal = maps:get(ProcessName, MsgQueueLenAcc, 0),
				{
					maps:put(ProcessName, MemoryTotal + Memory, MemoryAcc),
					maps:put(ProcessName, MsgQueueLenTotal + MsgQueueLen, MsgQueueLenAcc)
				}
		end, 
		{#{}, #{}},
		ProcessData),

	%% Clear out the process_info metric so that we don't persist data about processes that
	%% have exited. We have to deregister and re-register the metric because we don't track
	%% all the label values used.
	prometheus_gauge:deregister(process_info),
	prometheus_gauge:new([{name, process_info},
		{labels, [process, type]},
		{help, "Sampling info about active processes. Only set when debug=true."}]),

	maps:foreach(fun(ProcessName, Memory) ->
		prometheus_gauge:set(process_info, [ProcessName, memory], Memory)
	end, ProcessMemory),

	maps:foreach(fun(ProcessName, MsgQueueLen) ->
		prometheus_gauge:set(process_info, [ProcessName, message_queue], MsgQueueLen)
	end, ProcessMsgQueueLen),

	prometheus_gauge:set(process_info, [system, memory], erlang:memory(system)),
	{noreply, State};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%% Internal functions
sample_schedulers(#state{ scheduler_samples = undefined } = State) ->
	%% Start sampling
	erlang:system_flag(scheduler_wall_time,true),
	Samples = scheduler:sample_all(),
	%% Every ?SAMPLE_SCHEDULERS_INTERVAL ms, we'll sample the schedulers for 
	%% ?SAMPLE_SCHEDULERS_DURATION ms.
	ar_util:cast_after(?SAMPLE_SCHEDULERS_INTERVAL, ?MODULE, sample_schedulers),
	ar_util:cast_after(?SAMPLE_SCHEDULERS_DURATION, ?MODULE, sample_schedulers),
	State#state{ scheduler_samples = Samples };
sample_schedulers(#state{ scheduler_samples = Samples1 } = State) ->
	%% Finish sampling
	Samples2 = scheduler:sample_all(),
	Util = scheduler:utilization(Samples1, Samples2),
	erlang:system_flag(scheduler_wall_time,false),
	average_utilization(Util),
	State#state{ scheduler_samples = undefined }.

average_utilization(Util) ->
	Averages = lists:foldl(
		fun
		({Type, Value, _}, Acc) ->
			maps:put(Type, {Value, 1}, Acc);
		({Type, _, Value, _}, Acc) ->
			case (Type == io andalso Value > 0) orelse (Type /= io) of
				true ->
					{Sum, Count} = maps:get(Type, Acc, {0, 0}),
					maps:put(Type, {Sum+Value, Count+1}, Acc);
				false ->
					Acc
			end
		end,
		#{},
		Util),
	?LOG_DEBUG([{event, scheduler_utilization}, {util, Util}]),
	maps:foreach(
		fun(Type, {Sum, Count}) ->
			?LOG_DEBUG([{event, scheduler_utilization}, {Type, Sum / Count}]),
			prometheus_gauge:set(scheduler_utilization, [Type], Sum / Count)
		end,
		Averages).
	
process_function(Pid) ->
	case process_info(Pid, [current_function, current_stacktrace, registered_name,
		status, memory, message_queue_len]) of
	[{current_function, {?MODULE, process_function, _A}}, _, _, _, _, _] ->
		false;
	[{current_function, {erlang, process_info, _A}}, _, _, _, _, _] ->
		false;
	[{current_function, CurrentFunction}, {current_stacktrace, Stack},
			{registered_name, Name}, {status, Status},
			{memory, Memory}, {message_queue_len, MsgQueueLen}] ->
		ProcessName = process_name(Name, Stack),
		FunctionName = function_name(ProcessName, CurrentFunction),
		{true, {Status, ProcessName, FunctionName, Memory, MsgQueueLen}};
	_ ->
		false
	end.

%% @doc Anonymous processes don't have a registered name. So we'll name them after their
%% module, function and arity.
process_name([], []) ->
	"unknown";
process_name([], Stack) ->
	InitialCall = lists:last(Stack),
	M = element(1, InitialCall),
	F = element(2, InitialCall),
	A = element(3, InitialCall),
	atom_to_list(M) ++ ":" ++ atom_to_list(F) ++ "/" ++ integer_to_list(A);
process_name(Name, _Stack) ->
	atom_to_list(Name).

function_name(ProcessName, {M, F, A}) ->
	ProcessName ++ "~" ++ atom_to_list(M) ++ ":" ++ atom_to_list(F) ++ "/" ++ integer_to_list(A).
