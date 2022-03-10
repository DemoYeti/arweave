-define(THROTTLE_PERIOD, 30000).

-define(BAN_CLEANUP_INTERVAL, 60000).

-define(RPM_BY_PATH(Path), fun() ->
	{ok, Config} = application:get_env(arweave, config),
	?RPM_BY_PATH(Path, Config#config.requests_per_minute_limit)()
end).

-ifdef(DEBUG).
-define(RPM_BY_PATH(Path, DefaultPathLimit), fun() ->
	case Path of
		[<<"chunk">> | _]            -> {chunk,            12000};
		[<<"data_sync_record">> | _] -> {data_sync_record, 10000};
		_ ->                            {default,          DefaultPathLimit}
	end
end).
-else.
-define(RPM_BY_PATH(Path, DefaultPathLimit), fun() ->
	case Path of
		[<<"chunk">> | _]            -> {chunk,            12000}; % ~50 MB/s.
		[<<"data_sync_record">> | _] -> {data_sync_record, 40};
		_ ->                            {default,          DefaultPathLimit}
	end
end).
-endif.
