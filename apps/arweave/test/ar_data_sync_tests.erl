-module(ar_data_sync_tests).

-include_lib("eunit/include/eunit.hrl").

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_data_sync.hrl").

-import(ar_test_node, [start/3, slave_start/3, connect_to_slave/0, rejoin_on_master/0,
		sign_tx/2, sign_v1_tx/2, assert_wait_until_receives_txs/1, post_tx_to_master/1,
		wait_until_height/1, assert_slave_wait_until_height/1, post_and_mine/2,
		get_tx_anchor/1, disconnect_from_slave/0,
		assert_post_tx_to_slave/1, assert_post_tx_to_master/1, slave_mine/0,
		read_block_when_stored/1, get_chunk/1, get_chunk/2, post_chunk/1, post_chunk/2,
		assert_get_tx_data_master/2, assert_get_tx_data_slave/2,
		assert_data_not_found_master/1, assert_data_not_found_slave/1, slave_call/3,
		test_with_mocked_functions/2]).
-import(ar_test_fork, [test_on_fork/3]).

rejects_invalid_chunks_test_() ->
	{timeout, 180, fun test_rejects_invalid_chunks/0}.

test_rejects_invalid_chunks() ->
	{_Master, _, _Wallet} = setup_nodes(),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"chunk_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			chunk => ar_util:encode(crypto:strong_rand_bytes(?DATA_CHUNK_SIZE + 1)),
			data_path => <<>>,
			offset => <<"0">>,
			data_size => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"data_path_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			data_path => ar_util:encode(crypto:strong_rand_bytes(?MAX_PATH_SIZE + 1)),
			chunk => <<>>,
			offset => <<"0">>,
			data_size => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"offset_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			offset => integer_to_binary(trunc(math:pow(2, 256))),
			data_path => <<>>,
			chunk => <<>>,
			data_size => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"data_size_too_big\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			data_size => integer_to_binary(trunc(math:pow(2, 256))),
			data_path => <<>>,
			chunk => <<>>,
			offset => <<"0">>
		}))
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"chunk_proof_ratio_not_attractive\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			chunk => ar_util:encode(<<"a">>),
			data_path => ar_util:encode(<<"bb">>),
			offset => <<"0">>,
			data_size => <<"0">>
		}))
	),
	setup_nodes(),
	Chunk = crypto:strong_rand_bytes(500),
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
		ar_tx:chunks_to_size_tagged_chunks([Chunk])
	),
	{DataRoot, DataTree} = ar_merkle:generate_tree(SizedChunkIDs),
	DataPath = ar_merkle:generate_path(DataRoot, 0, DataTree),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"data_root_not_found\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(#{
			data_root => ar_util:encode(DataRoot),
			chunk => ar_util:encode(Chunk),
			data_path => ar_util:encode(DataPath),
			offset => <<"0">>,
			data_size => <<"500">>
		}))
	),
	?assertMatch(
		{ok, {{<<"413">>, _}, _, <<"Payload too large">>, _, _}},
		post_chunk(<< <<0>> || _ <- lists:seq(1, ?MAX_SERIALIZED_CHUNK_PROOF_SIZE + 1) >>)
	).

does_not_store_small_chunks_after_2_5_test_() ->
	{timeout, 600, fun test_does_not_store_small_chunks_after_2_5/0}.

test_does_not_store_small_chunks_after_2_5() ->
	Size = ?DATA_CHUNK_SIZE,
	Third = Size div 3,
	Splits = [
		{"Even split", Size * 3, Size, Size, Size, Size, Size * 2, Size * 3,
				lists:seq(0, Size - 1, 2048), lists:seq(Size, Size * 2 - 1, 2048),
				lists:seq(Size * 2, Size * 3 + 2048, 2048),
				[{O, first} || O <- lists:seq(1, Size - 1, 2048)]
						++ [{O, second} || O <- lists:seq(Size + 1, 2 * Size, 2048)]
						++ [{O, third} || O <- lists:seq(2 * Size + 1, 3 * Size, 2048)]
						++ [{3 * Size + 1, 404}, {4 * Size, 404}]},
		{"Small last chunk", 2 * Size + Third, Size, Size, Third, Size, 2 * Size,
				2 * Size + Third, lists:seq(3, Size - 1, 2048),
				lists:seq(Size, 2 * Size - 1, 2048),
				lists:seq(2 * Size, 2 * Size + Third, 2048),
				%% The chunk is expected to be returned by any offset of the 256 KiB
				%% bucket where it ends.
				[{O, first} || O <- lists:seq(1, Size - 1, 2048)]
						++ [{O, second} || O <- lists:seq(Size + 1, 2 * Size, 2048)]
						++ [{O, third} || O <- lists:seq(2 * Size + 1, 3 * Size, 2048)]
						++ [{3 * Size + 1, 404}, {4 * Size, 404}]},
		{"Small chunks crossing the bucket", 2 * Size + Third, Size, Third + 1, Size - 1,
				Size, Size + Third + 1, 2 * Size + Third, lists:seq(0, Size - 1, 2048),
				lists:seq(Size, Size + Third, 1024),
				lists:seq(Size + Third + 1, 2 * Size + Third, 2048),
				[{O, first} || O <- lists:seq(1, Size, 2048)]
						++ [{O, second} || O <- lists:seq(Size + 1, 2 * Size, 2048)]
						++ [{O, third} || O <- lists:seq(2 * Size + 1, 3 * Size, 2048)]
						++ [{3 * Size + 1, 404}, {4 * Size, 404}]},
		{"Small chunks in one bucket", 2 * Size, Size, Third, Size - Third, Size, Size + Third,
				2 * Size, lists:seq(0, Size - 1, 2048), lists:seq(Size, Size + Third - 1, 2048),
				lists:seq(Size + Third, 2 * Size, 2048),
				[{O, first} || O <- lists:seq(1, Size - 1, 2048)]
						%% The second and third chunks must not be accepted.
						%% The second chunk does not precede a chunk crossing a bucket border,
						%% the third chunk ends at a multiple of 256 KiB.
						++ [{O, 404} || O <- lists:seq(Size + 1, 2 * Size + 4096, 2048)]},
		{"Small chunk preceding 256 KiB chunk", 2 * Size + Third, Third, Size, Size, Third,
				Size + Third, 2 * Size + Third, lists:seq(0, Third - 1, 2048),
				lists:seq(Third, Third + Size - 1, 2048),
				lists:seq(Third + Size, Third + 2 * Size, 2048),
				%% The first chunk must not be accepted, the first bucket stays empty.
				[{O, 404} || O <- lists:seq(1, Size - 1, 2048)]
						%% The other chunks are rejected too - their start offsets
						%% are not aligned with the buckets.
						++ [{O, 404} || O <- lists:seq(Size + 1, 4 * Size, 2048)]}],
	lists:foreach(
		fun({Title, DataSize, FirstSize, SecondSize, ThirdSize, FirstMerkleOffset,
				SecondMerkleOffset, ThirdMerkleOffset, FirstPublishOffsets, SecondPublishOffsets,
				ThirdPublishOffsets, Expectations}) ->
			?debugFmt("Running [~s]", [Title]),
			{Master, _, Wallet} = setup_nodes(),
			{FirstChunk, SecondChunk, ThirdChunk} = {crypto:strong_rand_bytes(FirstSize),
					crypto:strong_rand_bytes(SecondSize), crypto:strong_rand_bytes(ThirdSize)},
			{FirstChunkID, SecondChunkID, ThirdChunkID} = {ar_tx:generate_chunk_id(FirstChunk),
					ar_tx:generate_chunk_id(SecondChunk), ar_tx:generate_chunk_id(ThirdChunk)},
			{DataRoot, DataTree} = ar_merkle:generate_tree([{FirstChunkID, FirstMerkleOffset},
					{SecondChunkID, SecondMerkleOffset}, {ThirdChunkID, ThirdMerkleOffset}]),
			TX = sign_tx(Wallet, #{ last_tx => get_tx_anchor(master), data_size => DataSize,
					data_root => DataRoot }),
			post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, [TX]),
			lists:foreach(
				fun({Chunk, Offset}) ->
					DataPath = ar_merkle:generate_path(DataRoot, Offset, DataTree),
					Proof = #{ data_root => ar_util:encode(DataRoot),
							data_path => ar_util:encode(DataPath),
							chunk => ar_util:encode(Chunk),
							offset => integer_to_binary(Offset),
							data_size => integer_to_binary(DataSize) },
					%% All chunks are accepted because we do not know their offsets yet -
					%% in theory they may end up below the strict data split threshold.
					?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
							post_chunk(ar_serialize:jsonify(Proof)), Title)
				end,
				[{FirstChunk, O} || O <- FirstPublishOffsets]
						++ [{SecondChunk, O} || O <- SecondPublishOffsets]
						++ [{ThirdChunk, O} || O <- ThirdPublishOffsets]
			),
			%% In practice the chunks are above the strict data split threshold so those
			%% which do not pass strict validation will not be stored.
			timer:sleep(2000),
			GenesisOffset = ?STRICT_DATA_SPLIT_THRESHOLD,
			lists:foreach(
				fun	({Offset, 404}) ->
						?assertMatch({ok, {{<<"404">>, _}, _, _, _, _}},
								get_chunk(GenesisOffset + Offset), Title);
					({Offset, first}) ->
						{ok, {{<<"200">>, _}, _, ProofJSON, _, _}} = get_chunk(
								GenesisOffset + Offset),
						?assertEqual(FirstChunk, ar_util:decode(maps:get(<<"chunk">>,
								jiffy:decode(ProofJSON, [return_maps]))), Title);
					({Offset, second}) ->
						{ok, {{<<"200">>, _}, _, ProofJSON, _, _}} = get_chunk(
								GenesisOffset + Offset),
						?assertEqual(SecondChunk, ar_util:decode(maps:get(<<"chunk">>,
								jiffy:decode(ProofJSON, [return_maps]))), Title);
					({Offset, third}) ->
						{ok, {{<<"200">>, _}, _, ProofJSON, _, _}} = get_chunk(
								GenesisOffset + Offset),
						?assertEqual(ThirdChunk, ar_util:decode(maps:get(<<"chunk">>,
								jiffy:decode(ProofJSON, [return_maps]))), Title)
				end,
				Expectations
			)
		end,
		Splits
	).

rejects_chunks_with_merkle_tree_borders_exceeding_max_chunk_size_test_() ->
	{timeout, 120, fun test_rejects_chunks_with_merkle_tree_borders_exceeding_max_chunk_size/0}.

test_rejects_chunks_with_merkle_tree_borders_exceeding_max_chunk_size() ->
	{Master, _, Wallet} = setup_nodes(),
	BigOutOfBoundsOffsetChunk = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	BigChunkID = ar_tx:generate_chunk_id(BigOutOfBoundsOffsetChunk),
	{BigDataRoot, BigDataTree} = ar_merkle:generate_tree([{BigChunkID, ?DATA_CHUNK_SIZE + 1}]),
	BigTX = sign_tx(Wallet, #{ last_tx => get_tx_anchor(master), data_size => ?DATA_CHUNK_SIZE,
			data_root => BigDataRoot }),
	post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, [BigTX]),
	BigDataPath = ar_merkle:generate_path(BigDataRoot, 0, BigDataTree),
	BigProof = #{ data_root => ar_util:encode(BigDataRoot),
			data_path => ar_util:encode(BigDataPath),
			chunk => ar_util:encode(BigOutOfBoundsOffsetChunk), offset => <<"0">>,
			data_size => integer_to_binary(?DATA_CHUNK_SIZE)},
	?assertMatch({ok, {{<<"400">>, _}, _, <<"{\"error\":\"invalid_proof\"}">>, _, _}},
			post_chunk(ar_serialize:jsonify(BigProof))).

rejects_chunks_exceeding_disk_pool_limit_test_() ->
	test_on_fork(height_2_5, 0, fun test_rejects_chunks_exceeding_disk_pool_limit/0).

test_rejects_chunks_exceeding_disk_pool_limit() ->
	{_Master, _Slave, Wallet} = setup_nodes(),
	Data1 = crypto:strong_rand_bytes(
		(?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB * 1024 * 1024) + 1
	),
	Chunks1 = split(?DATA_CHUNK_SIZE, Data1),
	{DataRoot1, _} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(Chunks1)
		)
	),
	{TX1, Chunks1} = tx(Wallet, {fixed_data, DataRoot1, Chunks1}),
	assert_post_tx_to_master(TX1),
	[{_, FirstProof1} | Proofs1] = build_proofs(TX1, Chunks1, [TX1], 0, 0),
	lists:foreach(
		fun({_, Proof}) ->
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			)
		end,
		Proofs1
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"exceeds_disk_pool_size_limit\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(FirstProof1))
	),
	Data2 = crypto:strong_rand_bytes(
		min(
			?DEFAULT_MAX_DISK_POOL_BUFFER_MB - ?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB,
			?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB - 1
		) * 1024 * 1024
	),
	Chunks2 = split(Data2),
	{DataRoot2, _} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(Chunks2)
		)
	),
	{TX2, Chunks2} = tx(Wallet, {fixed_data, DataRoot2, Chunks2}),
	assert_post_tx_to_master(TX2),
	Proofs2 = build_proofs(TX2, Chunks2, [TX2], 0, 0),
	lists:foreach(
		fun({_, Proof}) ->
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			)
		end,
		Proofs2
	),
	Left =
		?DEFAULT_MAX_DISK_POOL_BUFFER_MB * 1024 * 1024 -
		lists:sum([byte_size(Chunk) || Chunk <- tl(Chunks1)]) -
		byte_size(Data2),
	?assert(Left < ?DEFAULT_MAX_DISK_POOL_DATA_ROOT_BUFFER_MB * 1024 * 1024),
	Data3 = crypto:strong_rand_bytes(Left + 1),
	Chunks3 = split(Data3),
	{DataRoot3, _} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(Chunks3)
		)
	),
	{TX3, Chunks3} = tx(Wallet, {fixed_data, DataRoot3, Chunks3}),
	assert_post_tx_to_master(TX3),
	[{_, FirstProof3} | Proofs3] = build_proofs(TX3, Chunks3, [TX3], 0, 0),
	lists:foreach(
		fun({_, Proof}) ->
			?assertMatch(
				{ok, {{<<"200">>, _}, _, _, _, _}},
				post_chunk(ar_serialize:jsonify(Proof))
			)
		end,
		Proofs3
	),
	?assertMatch(
		{ok, {{<<"400">>, _}, _, <<"{\"error\":\"exceeds_disk_pool_size_limit\"}">>, _, _}},
		post_chunk(ar_serialize:jsonify(FirstProof3))
	),
	slave_mine(),
	true = ar_util:do_until(
		fun() ->
			lists:all(
				fun(Proof) ->
					case post_chunk(ar_serialize:jsonify(Proof)) of
						{ok, {{<<"200">>, _}, _, _, _, _}} ->
							true;
						_ ->
							false
					end
				end,
				[FirstProof1, FirstProof3]
			)
		end,
		500,
		30 * 1000
	).

accepts_chunks_test_() ->
	test_on_fork(height_2_5, 0, fun test_accepts_chunks/0).

test_accepts_chunks() ->
	test_accepts_chunks(original_split).

test_accepts_chunks(Split) ->
	{_Master, _Slave, Wallet} = setup_nodes(),
	{TX, Chunks} = tx(Wallet, {Split, 3}),
	assert_post_tx_to_slave(TX),
	assert_wait_until_receives_txs([TX]),
	[{Offset, FirstProof}, {_, SecondProof}, {_, ThirdProof}] = build_proofs(TX, Chunks,
			[TX], 0, 0),
	EndOffset = Offset + ?STRICT_DATA_SPLIT_THRESHOLD,
	%% Post the third proof to the disk pool.
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(ThirdProof))
	),
	slave_mine(),
	[{BH, _, _} | _] = wait_until_height(1),
	B = read_block_when_stored(BH),
	?assertMatch(
		{ok, {{<<"404">>, _}, _, _, _, _}},
		get_chunk(EndOffset)
	),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		post_chunk(ar_serialize:jsonify(FirstProof))
	),
	%% Expect the chunk to be retrieved by any offset within
	%% (EndOffset - ChunkSize, EndOffset], but not outside of it.
	FirstChunk = ar_util:decode(maps:get(chunk, FirstProof)),
	FirstChunkSize = byte_size(FirstChunk),
	ExpectedProof = #{
		data_path => maps:get(data_path, FirstProof),
		tx_path => maps:get(tx_path, FirstProof),
		chunk => ar_util:encode(FirstChunk)
	},
	wait_until_syncs_chunk(EndOffset, ExpectedProof),
	wait_until_syncs_chunk(EndOffset - rand:uniform(FirstChunkSize - 2), ExpectedProof),
	wait_until_syncs_chunk(EndOffset - FirstChunkSize + 1, ExpectedProof),
	?assertMatch({ok, {{<<"404">>, _}, _, _, _, _}}, get_chunk(0)),
	?assertMatch({ok, {{<<"404">>, _}, _, _, _, _}}, get_chunk(EndOffset + 1)),
	TXSize = byte_size(binary:list_to_bin(Chunks)),
	ExpectedOffsetInfo = ar_serialize:jsonify(#{
		offset => integer_to_binary(TXSize + ?STRICT_DATA_SPLIT_THRESHOLD),
		size => integer_to_binary(TXSize)
	}),
	?assertMatch({ok, {{<<"200">>, _}, _, ExpectedOffsetInfo, _, _}}, get_tx_offset(TX#tx.id)),
	%% Expect no transaction data because the second chunk is not synced yet.
	?assertMatch({ok, {{<<"200">>, _}, _, <<>>, _, _}}, get_tx_data(TX#tx.id)),
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
			post_chunk(ar_serialize:jsonify(SecondProof))),
	ExpectedSecondProof = #{
		data_path => maps:get(data_path, SecondProof),
		tx_path => maps:get(tx_path, SecondProof),
		chunk => maps:get(chunk, SecondProof)
	},
	SecondChunk = ar_util:decode(maps:get(chunk, SecondProof)),
	SecondChunkOffset = ?STRICT_DATA_SPLIT_THRESHOLD + FirstChunkSize + byte_size(SecondChunk),
	wait_until_syncs_chunk(SecondChunkOffset, ExpectedSecondProof),
	true = ar_util:do_until(
		fun() ->
			{ok, {{<<"200">>, _}, _, Data, _, _}} = get_tx_data(TX#tx.id),
			ar_util:encode(binary:list_to_bin(Chunks)) == Data
		end,
		500,
		10 * 1000
	),
	ExpectedThirdProof = #{
		data_path => maps:get(data_path, ThirdProof),
		tx_path => maps:get(tx_path, ThirdProof),
		chunk => maps:get(chunk, ThirdProof)
	},
	wait_until_syncs_chunk(B#block.weave_size, ExpectedThirdProof),
	?assertMatch({ok, {{<<"404">>, _}, _, _, _, _}}, get_chunk(B#block.weave_size + 1)).

syncs_data_test_() ->
	test_on_fork(height_2_5, 0, fun test_syncs_data/0).

test_syncs_data() ->
	{_Master, _Slave, Wallet} = setup_nodes(),
	Records = post_random_blocks(Wallet),
	RecordsWithProofs = lists:flatmap(
			fun({B, TX, Chunks}) -> get_records_with_proofs(B, TX, Chunks) end, Records),
	lists:foreach(
		fun({_, _, _, {_, Proof}}) ->
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					post_chunk(ar_serialize:jsonify(Proof))),
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					post_chunk(ar_serialize:jsonify(Proof)))
		end,
		RecordsWithProofs
	),
	Proofs = [Proof || {_, _, _, Proof} <- RecordsWithProofs],
	wait_until_syncs_chunks(Proofs),
	DiskPoolThreshold = ar_node:get_partition_upper_bound(ar_node:get_block_index()),
	slave_wait_until_syncs_chunks(Proofs, DiskPoolThreshold),
	lists:foreach(
		fun({B, #tx{ id = TXID }, Chunks, {_, Proof}}) ->
			TXSize = byte_size(binary:list_to_bin(Chunks)),
			TXOffset = ar_merkle:extract_note(ar_util:decode(maps:get(tx_path, Proof))),
			AbsoluteTXOffset = B#block.weave_size - B#block.block_size + TXOffset,
			ExpectedOffsetInfo = ar_serialize:jsonify(#{
					offset => integer_to_binary(AbsoluteTXOffset),
					size => integer_to_binary(TXSize) }),
			true = ar_util:do_until(
				fun() ->
					case get_tx_offset_from_slave(TXID) of
						{ok, {{<<"200">>, _}, _, ExpectedOffsetInfo, _, _}} ->
							true;
						_ ->
							false
					end
				end,
				100,
				60 * 1000
			),
			ExpectedData = ar_util:encode(binary:list_to_bin(Chunks)),
			assert_get_tx_data_master(TXID, ExpectedData),
			case AbsoluteTXOffset > DiskPoolThreshold of
				true ->
					ok;
				false ->
					assert_get_tx_data_slave(TXID, ExpectedData)
			end
		end,
		RecordsWithProofs
	).

fork_recovery_test_() ->
	{timeout, 300, fun test_fork_recovery/0}.

test_fork_recovery() ->
	test_fork_recovery(original_split).

test_fork_recovery(Split) ->
	{Master, Slave, Wallet} = setup_nodes(),
	{TX1, Chunks1} = tx(Wallet, {Split, 13}, v2, ?AR(10)),
	?debugFmt("Posting tx to master ~s.~n", [ar_util:encode(TX1#tx.id)]),
	B1 = post_and_mine(#{ miner => {master, Master}, await_on => {slave, Slave} }, [TX1]),
	?debugFmt("Mined block ~s, height ~B.~n", [ar_util:encode(B1#block.indep_hash),
			B1#block.height]),
	Proofs1 = post_proofs_to_master(B1, TX1, Chunks1),
	wait_until_syncs_chunks(Proofs1),
	UpperBound = ar_node:get_partition_upper_bound(ar_node:get_block_index()),
	slave_wait_until_syncs_chunks(Proofs1, UpperBound),
	disconnect_from_slave(),
	{SlaveTX2, SlaveChunks2} = tx(Wallet, {Split, 15}, v2, ?AR(10)),
	{SlaveTX3, SlaveChunks3} = tx(Wallet, {Split, 17}, v2, ?AR(10)),
	?debugFmt("Posting tx to slave ~s.~n", [ar_util:encode(SlaveTX2#tx.id)]),
	?debugFmt("Posting tx to slave ~s.~n", [ar_util:encode(SlaveTX3#tx.id)]),
	SlaveB2 = post_and_mine(#{ miner => {slave, Slave}, await_on => {slave, Slave} },
			[SlaveTX2, SlaveTX3]),
	?debugFmt("Mined block ~s, height ~B.~n", [ar_util:encode(SlaveB2#block.indep_hash),
			SlaveB2#block.height]),
	{MasterTX2, MasterChunks2} = tx(Wallet, {Split, 14}, v2, ?AR(10)),
	?debugFmt("Posting tx to master ~s.~n", [ar_util:encode(MasterTX2#tx.id)]),
	MasterB2 = post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} },
			[MasterTX2]),
	?debugFmt("Mined block ~s, height ~B.~n", [ar_util:encode(MasterB2#block.indep_hash),
			MasterB2#block.height]),
	_SlaveProofs2 = post_proofs_to_slave(SlaveB2, SlaveTX2, SlaveChunks2),
	_SlaveProofs3 = post_proofs_to_slave(SlaveB2, SlaveTX3, SlaveChunks3),
	{SlaveTX4, SlaveChunks4} = tx(Wallet, {Split, 22}, v2, ?AR(10)),
	?debugFmt("Posting tx to slave ~s.~n", [ar_util:encode(SlaveTX4#tx.id)]),
	SlaveB3 = post_and_mine(#{ miner => {slave, Slave}, await_on => {slave, Slave} },
			[SlaveTX4]),
	?debugFmt("Mined block ~s, height ~B.~n", [ar_util:encode(SlaveB3#block.indep_hash),
			SlaveB3#block.height]),
	_SlaveProofs4 = post_proofs_to_slave(SlaveB3, SlaveTX4, SlaveChunks4),
	post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} }, []),
	MasterProofs2 = post_proofs_to_master(MasterB2, MasterTX2, MasterChunks2),
	{MasterTX3, MasterChunks3} = tx(Wallet, {Split, 16}, v2, ?AR(10)),
	?debugFmt("Posting tx to master ~s.~n", [ar_util:encode(MasterTX3#tx.id)]),
	MasterB3 = post_and_mine(#{ miner => {master, Master}, await_on => {master, Master} },
			[MasterTX3]),
	?debugFmt("Mined block ~s, height ~B.~n", [ar_util:encode(MasterB3#block.indep_hash),
			MasterB3#block.height]),
	connect_to_slave(),
	MasterProofs3 = post_proofs_to_master(MasterB3, MasterTX3, MasterChunks3),
	UpperBound2 = ar_node:get_partition_upper_bound(ar_node:get_block_index()),
	slave_wait_until_syncs_chunks(MasterProofs2, UpperBound2),
	slave_wait_until_syncs_chunks(MasterProofs3, UpperBound2),
	slave_wait_until_syncs_chunks(Proofs1),
	%% The slave node will return the orphaned transactions to the mempool
	%% and gossip them.
	?debugFmt("Posting tx to master ~s.~n", [ar_util:encode(SlaveTX2#tx.id)]),
	?debugFmt("Posting tx to master ~s.~n", [ar_util:encode(SlaveTX4#tx.id)]),
	post_tx_to_master(SlaveTX2),
	post_tx_to_master(SlaveTX4),
	assert_wait_until_receives_txs([SlaveTX2, SlaveTX4]),
	MasterB4 = post_and_mine(#{ miner => {master, Master},
			await_on => {master, Master} }, []),
	?debugFmt("Mined block ~s, height ~B.~n", [ar_util:encode(MasterB4#block.indep_hash),
			MasterB4#block.height]),
	Proofs4 = build_proofs(MasterB4, SlaveTX4, SlaveChunks4),
	%% We did not submit proofs for SlaveTX4 to master - they are supposed to be still stored
	%% in the disk pool.
	slave_wait_until_syncs_chunks(Proofs4),
	UpperBound3 = ar_node:get_partition_upper_bound(ar_node:get_block_index()),
	wait_until_syncs_chunks(Proofs4, UpperBound3),
	post_proofs_to_slave(SlaveB2, SlaveTX2, SlaveChunks2).

syncs_after_joining_test_() ->
	test_on_fork(height_2_5, 0, fun test_syncs_after_joining/0).

test_syncs_after_joining() ->
	test_syncs_after_joining(original_split).

test_syncs_after_joining(Split) ->
	{Master, Slave, Wallet} = setup_nodes(),
	{TX1, Chunks1} = tx(Wallet, {Split, 17}, v2, ?AR(1)),
	B1 = post_and_mine(#{ miner => {master, Master}, await_on => {slave, Slave} }, [TX1]),
	Proofs1 = post_proofs_to_master(B1, TX1, Chunks1),
	UpperBound = ar_node:get_partition_upper_bound(ar_node:get_block_index()),
	slave_wait_until_syncs_chunks(Proofs1, UpperBound),
	wait_until_syncs_chunks(Proofs1),
	disconnect_from_slave(),
	{MasterTX2, MasterChunks2} = tx(Wallet, {Split, 13}, v2, ?AR(1)),
	MasterB2 = post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[MasterTX2]
	),
	MasterProofs2 = post_proofs_to_master(MasterB2, MasterTX2, MasterChunks2),
	{MasterTX3, MasterChunks3} = tx(Wallet, {Split, 12}, v2, ?AR(1)),
	MasterB3 = post_and_mine(
		#{ miner => {master, Master}, await_on => {master, Master} },
		[MasterTX3]
	),
	MasterProofs3 = post_proofs_to_master(MasterB3, MasterTX3, MasterChunks3),
	{SlaveTX2, SlaveChunks2} = tx(Wallet, {Split, 20}, v2, ?AR(1)),
	SlaveB2 = post_and_mine(
		#{ miner => {slave, Slave}, await_on => {slave, Slave} },
		[SlaveTX2]
	),
	SlaveProofs2 = post_proofs_to_slave(SlaveB2, SlaveTX2, SlaveChunks2),
	slave_wait_until_syncs_chunks(SlaveProofs2),
	_Slave2 = rejoin_on_master(),
	assert_slave_wait_until_height(3),
	connect_to_slave(),
	UpperBound2 = ar_node:get_partition_upper_bound(ar_node:get_block_index()),
	slave_wait_until_syncs_chunks(MasterProofs2, UpperBound2),
	slave_wait_until_syncs_chunks(MasterProofs3, UpperBound2),
	slave_wait_until_syncs_chunks(Proofs1).

mines_off_only_last_chunks_test_() ->
	test_with_mocked_functions([{ar_fork, height_2_6, fun() -> 0 end}],
			fun test_mines_off_only_last_chunks/0).

test_mines_off_only_last_chunks() ->
	{Master, Slave, Wallet} = setup_nodes(),
	%% Submit only the last chunks (smaller than 256 KiB) of transactions.
	%% Assert the nodes construct correct proofs of access from them.
	lists:foreach(
		fun(Height) ->
			RandomID = crypto:strong_rand_bytes(32),
			Chunk = crypto:strong_rand_bytes(1023),
			ChunkID = ar_tx:generate_chunk_id(Chunk),
			DataSize = ?DATA_CHUNK_SIZE + 1023,
			{DataRoot, DataTree} = ar_merkle:generate_tree([{RandomID, ?DATA_CHUNK_SIZE},
					{ChunkID, DataSize}]),
			TX = sign_tx(Wallet, #{ last_tx => get_tx_anchor(master), data_size => DataSize,
					data_root => DataRoot }),
			post_and_mine(#{ miner => {master, Master}, await_on => {slave, Slave} }, [TX]),
			Offset = ?DATA_CHUNK_SIZE + 1,
			DataPath = ar_merkle:generate_path(DataRoot, Offset, DataTree),
			Proof = #{ data_root => ar_util:encode(DataRoot),
					data_path => ar_util:encode(DataPath), chunk => ar_util:encode(Chunk),
					offset => integer_to_binary(Offset),
					data_size => integer_to_binary(DataSize) },
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					post_chunk(ar_serialize:jsonify(Proof))),
			case Height - ?SEARCH_SPACE_UPPER_BOUND_DEPTH of
				-1 ->
					%% Make sure we waited enough to have the next block use
					%% the new entropy reset source.
					[{_, Info}] = ets:lookup(node_state, nonce_limiter_info),
					PrevStepNumber = Info#nonce_limiter_info.global_step_number,
					true = ar_util:do_until(
						fun() ->
							ar_nonce_limiter:get_current_step_number()
									> PrevStepNumber + ?NONCE_LIMITER_RESET_FREQUENCY
						end,
						200,
						20000
					);
				0 ->
					%% Wait until the new chunks fall below the new upper bound and
					%% remove the original big chunks. The protocol will increase the upper
					%% bound based on the nonce limiter entropy reset, but ar_data_sync waits
					%% for ?SEARCH_SPACE_UPPER_BOUND_DEPTH confirmations before packing the
					%% chunks.
					{ok, Config} = application:get_env(arweave, config),
					lists:foreach(
						fun(O) ->
							[ar_chunk_storage:delete(O, ar_storage_module:id(Module))
									|| Module <- Config#config.storage_modules]
						end,
						lists:seq(?DATA_CHUNK_SIZE, ?STRICT_DATA_SPLIT_THRESHOLD,
								?DATA_CHUNK_SIZE)
					);
				_ ->
					ok
			end
		end,
		lists:seq(1, 6)
	).

mines_off_only_second_last_chunks_test_() ->
	test_with_mocked_functions([{ar_fork, height_2_6, fun() -> 0 end}],
			fun test_mines_off_only_second_last_chunks/0).

test_mines_off_only_second_last_chunks() ->
	{Master, Slave, Wallet} = setup_nodes(),
	%% Submit only the second last chunks (smaller than 256 KiB) of transactions.
	%% Assert the nodes construct correct proofs of access from them.
	lists:foreach(
		fun(Height) ->
			RandomID = crypto:strong_rand_bytes(32),
			Chunk = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE div 2),
			ChunkID = ar_tx:generate_chunk_id(Chunk),
			DataSize = (?DATA_CHUNK_SIZE) div 2 + (?DATA_CHUNK_SIZE) div 2 + 3,
			{DataRoot, DataTree} = ar_merkle:generate_tree([{ChunkID, ?DATA_CHUNK_SIZE div 2},
					{RandomID, DataSize}]),
			TX = sign_tx(Wallet, #{ last_tx => get_tx_anchor(master), data_size => DataSize,
					data_root => DataRoot }),
			post_and_mine(#{ miner => {master, Master}, await_on => {slave, Slave} }, [TX]),
			Offset = 0,
			DataPath = ar_merkle:generate_path(DataRoot, Offset, DataTree),
			Proof = #{ data_root => ar_util:encode(DataRoot),
					data_path => ar_util:encode(DataPath), chunk => ar_util:encode(Chunk),
					offset => integer_to_binary(Offset),
					data_size => integer_to_binary(DataSize) },
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					post_chunk(ar_serialize:jsonify(Proof))),
			case Height - ?SEARCH_SPACE_UPPER_BOUND_DEPTH >= 0 of
				true ->
					%% Wait until the new chunks fall below the new upper bound and
					%% remove the original big chunks. The protocol will increase the upper
					%% bound based on the nonce limiter entropy reset, but ar_data_sync waits
					%% for ?SEARCH_SPACE_UPPER_BOUND_DEPTH confirmations before packing the
					%% chunks.
					{ok, Config} = application:get_env(arweave, config),
					lists:foreach(
						fun(O) ->
							[ar_chunk_storage:delete(O, ar_storage_module:id(Module))
									|| Module <- Config#config.storage_modules]
						end,
						lists:seq(?DATA_CHUNK_SIZE, ?STRICT_DATA_SPLIT_THRESHOLD,
								?DATA_CHUNK_SIZE)
					);
				_ ->
					ok
			end
		end,
		lists:seq(1, 6)
	).

packs_chunks_depending_on_packing_threshold_test_() ->
	test_with_mocked_functions([{ar_fork, height_2_6, fun() -> 0 end},
			{ar_fork, height_2_6_8, fun() -> 0 end},
			{ar_fork, height_2_7, fun() -> 10 end}],
			fun test_packs_chunks_depending_on_packing_threshold/0).

test_packs_chunks_depending_on_packing_threshold() ->
	MasterWallet = ar_wallet:new_keyfile(),
	SlaveWallet = slave_call(ar_wallet, new_keyfile, []),
	MasterAddr = ar_wallet:to_address(MasterWallet),
	SlaveAddr = ar_wallet:to_address(SlaveWallet),
	DataMap =
		lists:foldr(
			fun(Height, Acc) ->
				ChunkCount = 10,
				{DR1, Chunks1} = generate_random_split(ChunkCount),
				{DR2, Chunks2} = generate_random_original_split(ChunkCount),
				{DR3, Chunks3} = generate_random_original_v1_split(),
				maps:put(Height, {{DR1, Chunks1}, {DR2, Chunks2}, {DR3, Chunks3}}, Acc)
			end,
			#{},
			lists:seq(1, 20)
		),
	{Master, Slave, Wallet} = setup_nodes(MasterAddr, SlaveAddr),
	{LegacyProofs, StrictProofs, V1Proofs} = lists:foldl(
		fun(Height, {Acc1, Acc2, Acc3}) ->
			{{DR1, Chunks1}, {DR2, Chunks2}, {DR3, Chunks3}} = maps:get(Height, DataMap),
			{#tx{ id = TXID1 } = TX1, Chunks1} = tx(Wallet, {fixed_data, DR1, Chunks1}),
			{#tx{ id = TXID2 } = TX2, Chunks2} = tx(Wallet, {fixed_data, DR2, Chunks2}),
			{#tx{ id = TXID3 } = TX3, Chunks3} = tx(Wallet, {fixed_data, DR3, Chunks3}, v1),
			{Miner, Receiver} =
				case rand:uniform(2) == 1 of
					true ->
						{{master, Master}, {slave, Slave}};
					false ->
						{{slave, Slave}, {master, Master}}
				end,
			?debugFmt("Mining block ~B, txs: ~s, ~s, ~s; data roots: ~s, ~s, ~s.~n", [Height,
					ar_util:encode(TX1#tx.id), ar_util:encode(TX2#tx.id),
					ar_util:encode(TX3#tx.id), ar_util:encode(TX1#tx.data_root),
					ar_util:encode(TX2#tx.data_root), ar_util:encode(TX3#tx.data_root)]),
			B = post_and_mine(#{ miner => Miner, await_on => Receiver }, [TX1, TX2, TX3]),
			post_proofs_to_master(B, TX1, Chunks1),
			post_proofs_to_slave(B, TX2, Chunks2),
			{maps:put(TXID1, get_records_with_proofs(B, TX1, Chunks1), Acc1),
					maps:put(TXID2, get_records_with_proofs(B, TX2, Chunks2), Acc2),
					maps:put(TXID3, get_records_with_proofs(B, TX3, Chunks3), Acc3)}
		end,
		{#{}, #{}, #{}},
		lists:seq(1, 20)
	),
	%% Mine some empty blocks on top to force all submitted data to fall below
	%% the disk pool threshold so that the non-default storage modules can sync it.
	lists:foreach(
		fun(_) ->
			{Miner, Receiver} =
				case rand:uniform(2) == 1 of
					true ->
						{{master, Master}, {slave, Slave}};
					false ->
						{{slave, Slave}, {master, Master}}
				end,
			post_and_mine(#{ miner => Miner, await_on => Receiver }, [])
		end,
		lists:seq(1, 5)
	),
	BILast = ar_node:get_block_index(),
	LastB = read_block_when_stored(element(1, lists:nth(10, lists:reverse(BILast)))),
	lists:foldl(
		fun(Height, PrevB) ->
			H = element(1, lists:nth(Height + 1, lists:reverse(BILast))),
			B = read_block_when_stored(H),
			PoA = B#block.poa,
			BI = lists:reverse(lists:sublist(lists:reverse(BILast), Height)),
			PrevNonceLimiterInfo = PrevB#block.nonce_limiter_info,
			PrevSeed =
				case B#block.height == ar_fork:height_2_6() of
					true ->
						element(1, lists:nth(?SEARCH_SPACE_UPPER_BOUND_DEPTH, BI));
					false ->
						PrevNonceLimiterInfo#nonce_limiter_info.seed
				end,
			NonceLimiterInfo = B#block.nonce_limiter_info,
			Output = NonceLimiterInfo#nonce_limiter_info.output,
			PartitionUpperBound =
					NonceLimiterInfo#nonce_limiter_info.partition_upper_bound,
			H0 = ar_block:compute_h0(Output, B#block.partition_number, PrevSeed,
					B#block.reward_addr),
			{RecallRange1Start, _} = ar_block:get_recall_range(H0,
					B#block.partition_number, PartitionUpperBound),
			RecallByte = RecallRange1Start + B#block.nonce * ?DATA_CHUNK_SIZE,
			{BlockStart, BlockEnd, TXRoot} = ar_block_index:get_block_bounds(RecallByte),
			?debugFmt("Mined a block. "
					"Computed recall byte: ~B, block's recall byte: ~p. "
					"Height: ~B. Previous block: ~s. "
					"Computed search space upper bound: ~B. "
					"Block start: ~B. Block end: ~B. TX root: ~s.",
					[RecallByte, B#block.recall_byte, Height,
					ar_util:encode(PrevB#block.indep_hash), PartitionUpperBound,
					BlockStart, BlockEnd, ar_util:encode(TXRoot)]),
			?assertEqual(RecallByte, B#block.recall_byte),
			?assertEqual(true, ar_poa:validate({BlockStart, RecallByte, TXRoot,
					BlockEnd - BlockStart, PoA, B#block.strict_data_split_threshold,
					{spora_2_6, B#block.reward_addr},
					B#block.merkle_rebase_support_threshold})),
			B
		end,
		LastB,
		lists:seq(10, 20)
	),
	?debugMsg("Asserting synced data with the strict splits."),
	maps:map(
		fun(TXID, [{_, _, Chunks, _} | _]) ->
			ExpectedData = ar_util:encode(binary:list_to_bin(Chunks)),
			assert_get_tx_data_master(TXID, ExpectedData),
			assert_get_tx_data_slave(TXID, ExpectedData)
		end,
		StrictProofs
	),
	?debugMsg("Asserting synced v1 data."),
	maps:map(
		fun(TXID, [{_, _, Chunks, _} | _]) ->
			ExpectedData = ar_util:encode(binary:list_to_bin(Chunks)),
			assert_get_tx_data_master(TXID, ExpectedData),
			assert_get_tx_data_slave(TXID, ExpectedData)
		end,
		V1Proofs
	),
	?debugMsg("Asserting synced chunks."),
	wait_until_syncs_chunks([P || {_, _, _, P} <- lists:flatten(maps:values(StrictProofs))]),
	wait_until_syncs_chunks([P || {_, _, _, P} <- lists:flatten(maps:values(V1Proofs))]),
	slave_wait_until_syncs_chunks([P || {_, _, _, P} <- lists:flatten(
			maps:values(StrictProofs))]),
	slave_wait_until_syncs_chunks([P || {_, _, _, P} <- lists:flatten(maps:values(V1Proofs))]),
	ChunkSize = ?DATA_CHUNK_SIZE,
	maps:map(
		fun(TXID, [{_B, _TX, Chunks, _} | _] = Proofs) ->
			BigChunks = lists:filter(fun(C) -> byte_size(C) == ChunkSize end, Chunks),
			Length = length(Chunks),
			LastSize = byte_size(lists:last(Chunks)),
			SecondLastSize = byte_size(lists:nth(Length - 1, Chunks)),
			DataPathSize = byte_size(maps:get(data_path, element(2, element(4,
					lists:nth(Length - 1, Proofs))))),
			case length(BigChunks) == Length
					orelse (length(BigChunks) + 1 == Length andalso LastSize < ChunkSize)
					orelse (length(BigChunks) + 2 == Length
							andalso LastSize < ChunkSize
							andalso SecondLastSize < ChunkSize
							andalso SecondLastSize >= DataPathSize
							andalso LastSize + SecondLastSize > ChunkSize) of
				true ->
					?debugMsg("Asserting random split which turned out strict."),
					ExpectedData = ar_util:encode(binary:list_to_bin(Chunks)),
					assert_get_tx_data_master(TXID, ExpectedData),
					assert_get_tx_data_slave(TXID, ExpectedData),
					wait_until_syncs_chunks([P || {_, _, _, P} <- Proofs]),
					slave_wait_until_syncs_chunks([P || {_, _, _, P} <- Proofs]);
				false ->
					?debugFmt("Asserting random split which turned out NOT strict"
							" and was placed above the strict data split threshold, "
							"TXID: ~s.", [ar_util:encode(TXID)]),
					?debugFmt("Chunk sizes: ~p.", [[byte_size(Chunk) || Chunk <- Chunks]]),
					assert_data_not_found_master(TXID),
					assert_data_not_found_slave(TXID)
			end
		end,
		LegacyProofs
	).

get_records_with_proofs(B, TX, Chunks) ->
	[{B, TX, Chunks, Proof} || Proof <- build_proofs(B, TX, Chunks)].

setup_nodes() ->
	Addr = ar_wallet:to_address(ar_wallet:new_keyfile()),
	SlaveAddr = ar_wallet:to_address(slave_call(ar_wallet, new_keyfile, [])),
	setup_nodes(Addr, SlaveAddr).

setup_nodes(MasterAddr, SlaveAddr) ->
	Wallet = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(20000), <<>>}]),
	{ok, Config} = application:get_env(arweave, config),
	{Master, _} = start(B0, MasterAddr, Config),
	{ok, SlaveConfig} = slave_call(application, get_env, [arweave, config]),
	{Slave, _} = slave_start(B0, SlaveAddr, SlaveConfig),
	connect_to_slave(),
	{Master, Slave, Wallet}.

tx(Wallet, SplitType) ->
	tx(Wallet, SplitType, v2, fetch).

v1_tx(Wallet) ->
	tx(Wallet, original_split, v1, fetch).

tx(Wallet, SplitType, Format) ->
	tx(Wallet, SplitType, Format, fetch).

tx(Wallet, SplitType, Format, Reward) ->
	case {SplitType, Format} of
		{{fixed_data, DataRoot, Chunks}, v2} ->
			Data = binary:list_to_bin(Chunks),
			Args = #{ data_size => byte_size(Data), data_root => DataRoot,
					last_tx => get_tx_anchor(master) },
			Args2 = case Reward of fetch -> Args; _ -> Args#{ reward => Reward } end,
			{sign_tx(Wallet, Args2), Chunks};
		{{fixed_data, DataRoot, Chunks}, v1} ->
			Data = binary:list_to_bin(Chunks),
			Args = #{ data_size => byte_size(Data), data_root => DataRoot,
					last_tx => get_tx_anchor(master), data => Data },
			Args2 = case Reward of fetch -> Args; _ -> Args#{ reward => Reward } end,
			{sign_v1_tx(Wallet, Args2), Chunks};
		{original_split, v1} ->
			{_, Chunks} = generate_random_original_v1_split(),
			Data = binary:list_to_bin(Chunks),
			Args = #{ data => Data, last_tx => get_tx_anchor(master) },
			Args2 = case Reward of fetch -> Args; _ -> Args#{ reward => Reward } end,
			{sign_v1_tx(Wallet, Args2), Chunks};
		{original_split, v2} ->
			{DataRoot, Chunks} = generate_random_original_split(),
			Data = binary:list_to_bin(Chunks),
			Args = #{ data_size => byte_size(Data), data_root => DataRoot,
					last_tx => get_tx_anchor(master) },
			Args2 = case Reward of fetch -> Args; _ -> Args#{ reward => Reward } end,
			{sign_tx(Wallet, Args2), Chunks};
		{{custom_split, ChunkNumber}, v2} ->
			{DataRoot, Chunks} = generate_random_split(ChunkNumber),
			Args = #{ data_size => byte_size(binary:list_to_bin(Chunks)),
					last_tx => get_tx_anchor(master), data_root => DataRoot },
			Args2 = case Reward of fetch -> Args; _ -> Args#{ reward => Reward } end,
			TX = sign_tx(Wallet, Args2),
			{TX, Chunks};
		{standard_split, v2} ->
			{DataRoot, Chunks} = generate_random_standard_split(),
			Data = binary:list_to_bin(Chunks),
			Args = #{ data_size => byte_size(Data), data_root => DataRoot,
					last_tx => get_tx_anchor(master) },
			Args2 = case Reward of fetch -> Args; _ -> Args#{ reward => Reward } end,
			TX = sign_tx(Wallet, Args2),
			{TX, Chunks};
		{{original_split, ChunkNumber}, v2} ->
			{DataRoot, Chunks} = generate_random_original_split(ChunkNumber),
			Data = binary:list_to_bin(Chunks),
			Args = #{ data_size => byte_size(Data), data_root => DataRoot,
					last_tx => get_tx_anchor(master) },
			Args2 = case Reward of fetch -> Args; _ -> Args#{ reward => Reward } end,
			TX = sign_tx(Wallet, Args2),
			{TX, Chunks}
	end.

generate_random_split(ChunkCount) ->
	Chunks = lists:foldl(
		fun(_, Chunks) ->
			RandomSize =
				case rand:uniform(3) of
					1 ->
						?DATA_CHUNK_SIZE;
					_ ->
						OneThird = ?DATA_CHUNK_SIZE div 3,
						OneThird + rand:uniform(?DATA_CHUNK_SIZE - OneThird) - 1
				end,
			Chunk = crypto:strong_rand_bytes(RandomSize),
			[Chunk | Chunks]
		end,
		[],
		lists:seq(1, case ChunkCount of random -> rand:uniform(5); _ -> ChunkCount end)),
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(Chunks)),
	{DataRoot, _} = ar_merkle:generate_tree(SizedChunkIDs),
	{DataRoot, Chunks}.

generate_random_original_v1_split() ->
	%% Make sure v1 data does not end with a digit, otherwise it's malleable.
	Data = << (crypto:strong_rand_bytes(rand:uniform(1024 * 1024)))/binary, <<"a">>/binary >>,
	original_split(Data).

generate_random_original_split() ->
	Data = << (crypto:strong_rand_bytes(rand:uniform(1024 * 1024)))/binary >>,
	original_split(Data).

generate_random_standard_split() ->
	Data = crypto:strong_rand_bytes(rand:uniform(3 * ?DATA_CHUNK_SIZE)),
	v2_standard_split(Data).

generate_random_original_split(ChunkCount) ->
	RandomSize = (ChunkCount - 1) * ?DATA_CHUNK_SIZE + rand:uniform(?DATA_CHUNK_SIZE),
	Data = crypto:strong_rand_bytes(RandomSize),
	original_split(Data).

%% @doc Split the way v1 transactions are split.
original_split(Data) ->
	Chunks = ar_tx:chunk_binary(?DATA_CHUNK_SIZE, Data),
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
		ar_tx:chunks_to_size_tagged_chunks(Chunks)
	),
	{DataRoot, _} = ar_merkle:generate_tree(SizedChunkIDs),
	{DataRoot, Chunks}.

%% @doc Split the way v2 transactions are usually split (arweave-js does it
%% this way as of the time this was written).
v2_standard_split(Data) ->
	Chunks = v2_standard_split_get_chunks(Data),
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
		ar_tx:chunks_to_size_tagged_chunks(Chunks)
	),
	{DataRoot, _} = ar_merkle:generate_tree(SizedChunkIDs),
	{DataRoot, Chunks}.

v2_standard_split_get_chunks(Data) ->
	v2_standard_split_get_chunks(Data, [], 32 * 1024).

v2_standard_split_get_chunks(Chunk, Chunks, _MinSize) when byte_size(Chunk) =< 262144 ->
    lists:reverse([Chunk | Chunks]);
v2_standard_split_get_chunks(<< _:262144/binary, LastChunk/binary >> = Rest, Chunks, MinSize)
		when byte_size(LastChunk) < MinSize ->
    FirstSize = round(math:ceil(byte_size(Rest) / 2)),
    << Chunk1:FirstSize/binary, Chunk2/binary >> = Rest,
    lists:reverse([Chunk2, Chunk1 | Chunks]);
v2_standard_split_get_chunks(<< Chunk:262144/binary, Rest/binary >>, Chunks, MinSize) ->
    v2_standard_split_get_chunks(Rest, [Chunk | Chunks], MinSize).

split(Data) ->
	split(?DATA_CHUNK_SIZE, Data).

split(_ChunkSize, Bin) when byte_size(Bin) == 0 ->
	[];
split(ChunkSize, Bin) when byte_size(Bin) < ChunkSize ->
	[Bin];
split(ChunkSize, Bin) ->
	<<ChunkBin:ChunkSize/binary, Rest/binary>> = Bin,
	HalfSize = ChunkSize div 2,
	case byte_size(Rest) < HalfSize of
		true ->
			HalfSize = ChunkSize div 2,
			<<ChunkBin2:HalfSize/binary, Rest2/binary>> = Bin,
			[ChunkBin2, Rest2];
		false ->
			[ChunkBin | split(ChunkSize, Rest)]
	end.

build_proofs(B, TX, Chunks) ->
	build_proofs(TX, Chunks, B#block.txs, B#block.weave_size - B#block.block_size,
			B#block.height).

build_proofs(TX, Chunks, TXs, BlockStartOffset, Height) ->
	SizeTaggedTXs = ar_block:generate_size_tagged_list_from_txs(TXs, Height),
	SizeTaggedDataRoots = [{Root, Offset} || {{_, Root}, Offset} <- SizeTaggedTXs],
	{value, {_, TXOffset}} =
		lists:search(fun({{TXID, _}, _}) -> TXID == TX#tx.id end, SizeTaggedTXs),
	{TXRoot, TXTree} = ar_merkle:generate_tree(SizeTaggedDataRoots),
	TXPath = ar_merkle:generate_path(TXRoot, TXOffset - 1, TXTree),
	SizeTaggedChunks = ar_tx:chunks_to_size_tagged_chunks(Chunks),
	{DataRoot, DataTree} = ar_merkle:generate_tree(
		ar_tx:sized_chunks_to_sized_chunk_ids(SizeTaggedChunks)
	),
	DataSize = byte_size(binary:list_to_bin(Chunks)),
	lists:foldl(
		fun
			({<<>>, _}, Proofs) ->
				Proofs;
			({Chunk, ChunkOffset}, Proofs) ->
				TXStartOffset = TXOffset - DataSize,
				AbsoluteChunkEndOffset = BlockStartOffset + TXStartOffset + ChunkOffset,
				Proof = #{
					tx_path => ar_util:encode(TXPath),
					data_root => ar_util:encode(DataRoot),
					data_path =>
						ar_util:encode(
							ar_merkle:generate_path(DataRoot, ChunkOffset - 1, DataTree)
						),
					chunk => ar_util:encode(Chunk),
					offset => integer_to_binary(ChunkOffset - 1),
					data_size => integer_to_binary(DataSize)
				},
				Proofs ++ [{AbsoluteChunkEndOffset, Proof}]
		end,
		[],
		SizeTaggedChunks
	).

get_tx_offset(TXID) ->
	ar_http:req(#{
		method => get,
		peer => {127, 0, 0, 1, 1984},
		path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/offset"
	}).

get_tx_data(TXID) ->
	ar_http:req(#{
		method => get,
		peer => {127, 0, 0, 1, 1984},
		path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/data"
	}).

get_tx_offset_from_slave(TXID) ->
	ar_http:req(#{
		method => get,
		peer => {127, 0, 0, 1, 1983},
		path => "/tx/" ++ binary_to_list(ar_util:encode(TXID)) ++ "/offset"
	}).

post_random_blocks(Wallet) ->
	post_blocks(Wallet,
		[
			[v1],
			empty,
			[v2, v1, fixed_data, v2_no_data],
			[v2, v2_standard_split, v1, v2],
			empty,
			[v1, v2, v2, empty_tx, v2_standard_split],
			[v2, v2_no_data, v2_no_data, v1, v2_no_data],
			[empty_tx],
			empty,
			[v2_standard_split, v2_no_data, v2, v1, v2],
			empty,
			[fixed_data, fixed_data],
			empty,
			[fixed_data, fixed_data] % same tx_root as in the block before the previous one
		]
	).

post_blocks(Wallet, BlockMap) ->
	FixedChunks = [crypto:strong_rand_bytes(256 * 1024) || _ <- lists:seq(1, 4)],
	SizedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(
			ar_tx:chunks_to_size_tagged_chunks(FixedChunks)),
	{DataRoot, _} = ar_merkle:generate_tree(SizedChunkIDs),
	lists:foldl(
		fun
			({empty, Height}, Acc) ->
				ar_node:mine(),
				assert_slave_wait_until_height(Height),
				Acc;
			({TXMap, _Height}, Acc) ->
				TXsWithChunks = lists:map(
					fun
						(v1) ->
							{v1_tx(Wallet), v1};
						(v2) ->
							{tx(Wallet, original_split), v2};
						(v2_no_data) -> % same as v2 but its data won't be submitted
							{tx(Wallet, {custom_split, random}), v2_no_data};
						(v2_standard_split) ->
							{tx(Wallet, standard_split), v2_standard_split};
						(empty_tx) ->
							{tx(Wallet, {custom_split, 0}), empty_tx};
						(fixed_data) ->
							{tx(Wallet, {fixed_data, DataRoot, FixedChunks}), fixed_data}
					end,
					TXMap
				),
				B = post_and_mine(
					#{ miner => {master, "master"}, await_on => {master, "master"} },
					[TX || {{TX, _}, _} <- TXsWithChunks]
				),
				Acc ++ [{B, TX, C} || {{TX, C}, Type} <- lists:sort(TXsWithChunks),
						Type /= v2_no_data, Type /= empty_tx]
		end,
		[],
		lists:zip(BlockMap, lists:seq(1, length(BlockMap)))
	).

post_proofs_to_master(B, TX, Chunks) ->
	post_proofs(master, B, TX, Chunks).

post_proofs_to_slave(B, TX, Chunks) ->
	post_proofs(slave, B, TX, Chunks).

post_proofs(Peer, B, TX, Chunks) ->
	Proofs = build_proofs(B, TX, Chunks),
	lists:foreach(
		fun({_, Proof}) ->
			{ok, {{<<"200">>, _}, _, _, _, _}} =
				post_chunk(Peer, ar_serialize:jsonify(Proof))
		end,
		Proofs
	),
	Proofs.

wait_until_syncs_chunk(Offset, ExpectedProof) ->
	true = ar_util:do_until(
		fun() ->
			case get_chunk(Offset) of
				{ok, {{<<"200">>, _}, _, ProofJSON, _, _}} ->
					Proof = jiffy:decode(ProofJSON, [return_maps]),
					maps:fold(
						fun	(_Key, _Value, false) ->
								false;
							(Key, Value, true) ->
								maps:get(atom_to_binary(Key), Proof, not_set) == Value
						end,
						true,
						ExpectedProof
					);
				_ ->
					false
			end
		end,
		100,
		5000
	).

wait_until_syncs_chunks(Proofs) ->
	wait_until_syncs_chunks(master, Proofs, infinity).

wait_until_syncs_chunks(Proofs, UpperBound) ->
	wait_until_syncs_chunks(master, Proofs, UpperBound).

slave_wait_until_syncs_chunks(Proofs) ->
	wait_until_syncs_chunks(slave, Proofs, infinity).

slave_wait_until_syncs_chunks(Proofs, UpperBound) ->
	wait_until_syncs_chunks(slave, Proofs, UpperBound).

wait_until_syncs_chunks(Peer, Proofs, UpperBound) ->
	lists:foreach(
		fun({EndOffset, Proof}) ->
			true = ar_util:do_until(
				fun() ->
					case EndOffset > UpperBound of
						true ->
							true;
						false ->
							case get_chunk(Peer, EndOffset) of
								{ok, {{<<"200">>, _}, _, EncodedProof, _, _}} ->
									FetchedProof = ar_serialize:json_map_to_chunk_proof(
										jiffy:decode(EncodedProof, [return_maps])
									),
									ExpectedProof = #{
										chunk => ar_util:decode(maps:get(chunk, Proof)),
										tx_path => ar_util:decode(maps:get(tx_path, Proof)),
										data_path => ar_util:decode(maps:get(data_path, Proof))
									},
									compare_proofs(FetchedProof, ExpectedProof, EndOffset);
								_ ->
									false
							end
					end
				end,
				5 * 1000,
				120 * 1000
			)
		end,
		Proofs
	).

compare_proofs(#{ chunk := C, data_path := D, tx_path := T },
		#{ chunk := C, data_path := D, tx_path := T }, _EndOffset) ->
	true;
compare_proofs(_, _, EndOffset) ->
	?debugFmt("Proof mismatch for ~B.", [EndOffset]),
	false.

enqueue_intervals_test() ->
	test_enqueue_intervals([], 2, [], [], [], "Empty Intervals"),
	Peer1 = {1, 2, 3, 4, 1984},
	Peer2 = {101, 102, 103, 104, 1984},
	Peer3 = {201, 202, 203, 204, 1984},

	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
					{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
					{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
				])}
		],
		5,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer1},
			{7*?DATA_CHUNK_SIZE, 8*?DATA_CHUNK_SIZE, Peer1},
			{8*?DATA_CHUNK_SIZE, 9*?DATA_CHUNK_SIZE, Peer1}
		],
		"Single peer, full intervals, all chunks. Non-overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
					{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
					{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
				])}
		],
		2,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1}
		],
		"Single peer, full intervals, 2 chunks. Non-overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer2, ar_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
			])},
			{Peer3, ar_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		2,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{8*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{5*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer2},
			{7*?DATA_CHUNK_SIZE, 8*?DATA_CHUNK_SIZE, Peer3}
		],
		"Multiple peers, overlapping, full intervals, 2 chunks. Non-overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer2, ar_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
			])},
			{Peer3, ar_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		3,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{8*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{5*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer1},
			{7*?DATA_CHUNK_SIZE, 8*?DATA_CHUNK_SIZE, Peer3}
		],
		"Multiple peers, overlapping, full intervals, 3 chunks. Non-overlapping QIntervals."),
	
	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
					{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
					{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])}
		],
		5,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}, {9*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{7*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer1}
		],
		"Single peer, full intervals, all chunks. Overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer2, ar_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
			])},
			{Peer3, ar_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		2,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}, {9*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{5*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer2}
		],
		"Multiple peers, overlapping, full intervals, 2 chunks. Overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
				{trunc(3.25*?DATA_CHUNK_SIZE), 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, trunc(5.75*?DATA_CHUNK_SIZE)}
			])}
		],
		2,
		[
			{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE},
			{trunc(8.5*?DATA_CHUNK_SIZE), trunc(6.5*?DATA_CHUNK_SIZE)}
		],
		[
			{trunc(3.25*?DATA_CHUNK_SIZE), 2*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, trunc(3.25*?DATA_CHUNK_SIZE), Peer1}
		],
		"Single peer, partial intervals, 2 chunks. Overlapping partial QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, ar_intervals:from_list([
				{trunc(3.25*?DATA_CHUNK_SIZE), 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, trunc(5.75*?DATA_CHUNK_SIZE)}
			])},
			{Peer2, ar_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer3, ar_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		2,
		[
			{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE},
			{trunc(8.5*?DATA_CHUNK_SIZE), trunc(6.5*?DATA_CHUNK_SIZE)}
		],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{8*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, trunc(3.25*?DATA_CHUNK_SIZE), Peer1},
			{trunc(3.25*?DATA_CHUNK_SIZE), 4*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, trunc(6.5*?DATA_CHUNK_SIZE), Peer2}
		],
		"Multiple peers, overlapping, full intervals, 2 chunks. Overlapping QIntervals.").

test_enqueue_intervals(Intervals, ChunksPerPeer, QIntervalsRanges, ExpectedQIntervalRanges, ExpectedChunks, Label) ->
	QIntervals = ar_intervals:from_list(QIntervalsRanges),
	Q = gb_sets:new(),
	{QResult, QIntervalsResult} = ar_data_sync:enqueue_intervals(Intervals, ChunksPerPeer, {Q, QIntervals}),
	ExpectedQIntervals = lists:foldl(fun({End, Start}, Acc) ->
			ar_intervals:add(Acc, End, Start)
		end, QIntervals, ExpectedQIntervalRanges),
	?assertEqual(ar_intervals:to_list(ExpectedQIntervals), ar_intervals:to_list(QIntervalsResult), Label),
	?assertEqual(ExpectedChunks, gb_sets:to_list(QResult), Label).

