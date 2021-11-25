{ config, lib, pkgs, ... }:

let
  inherit (lib) literalExpression mkEnableOption mkIf mkOption types;
  cfg = config.services.arweave;
  defaultUser = "arweave";
in
{
  options.services.arweave = {

    enable = mkEnableOption ''
      Enable arweave node as systemd service
    '';

    peer = mkOption {
      type = types.nonEmptyListOf types.str;
      default = [ ];
      example = [ "http://domain-or-ip.com:1984" ];
      description = ''
        List of primary node peers
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.arweave;
      defaultText = literalExpression "pkgs.arweave";
      example = literalExpression "pkgs.arweave";
      description = ''
        The Arweave expression to use
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/arweave-data";
      description = ''
        Data directory path for arweave node.
      '';
    };

    metricsDir = mkOption {
      type = types.path;
      default = "/var/lib/arweave/metrics";
      description = ''
        Directory path for node metric outputs
      '';
    };

    debug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug logging.";
    };

    user = mkOption {
      type = types.str;
      default = defaultUser;
      description = "Run Arweave Node under this user.";
    };

    group = mkOption {
      type = types.str;
      default = "users";
      description = "Run Arweave Node under this group.";
    };

    transactionBlacklists = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/user/arweave/blacklist.txt" ];
      description = ''
        List of paths to textfiles containing blacklisted txids
      '';
    };

    transactionWhitelists = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/user/arweave/whitelist.txt" ];
      description = ''
        List of paths to textfiles containing whitelisted txids
      '';
    };

    maxDiskPoolDataRootBufferMb = mkOption {
      type = types.int;
      default = 500;
      description = "Max disk-pool buffer size in mb.";
    };

    maxMiners = mkOption {
      type = types.int;
      default = 0;
      description = "Max amount of miners to spawn, 0 means no mining will be performed.";
    };

    featuresDisable = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "packing" ];
      description = ''
        List of features to disable.
      '';
    };

    headerSyncJobs = mkOption {
      type = types.int;
      default = 10;
      description = "The pace for which to sync up with historical headers.";
    };

    syncJobs = mkOption {
      type = types.int;
      default = 100;
      description = "The pace for which to sync up with historical data.";
    };

    maxParallelGetChunkRequests = mkOption {
      type = types.int;
      default = 100;
      description = "As semaphore, the max amount of parallel get chunk requests to perform.";
    };

    maxParallelGetAndPackChunkRequests = mkOption {
      type = types.int;
      default = 10;
      description = "As semaphore, the max amount of parallel get chunk and pack requests to perform.";
    };

    maxParallelGetTxDataRequests = mkOption {
      type = types.int;
      default = 10;
      description = "As semaphore, the max amount of parallel get transaction data requests to perform.";
    };

    maxParallelPostChunkRequests = mkOption {
      type = types.int;
      default = 100;
      description = "As semaphore, the max amount of parallel post chunk requests to perform.";
    };

    maxParallelBlockIndexRequests = mkOption {
      type = types.int;
      default = 2;
      description = "As semaphore, the max amount of parallel block index requests to perform.";
    };

    maxParallelWalletListRequests = mkOption {
      type = types.int;
      default = 2;
      description = "As semaphore, the max amount of parallel block index requests to perform.";
    };

    maxParallelGetSyncRecord = mkOption {
      type = types.int;
      default = 2;
      description = "As semaphore, the max amount of parallel get sync record requests to perform.";
    };

  };

  config = mkIf cfg.enable (
    let configFile =
          pkgs.writeText "config.json" (builtins.toJSON {
            data_dir = cfg.dataDir;
            metrics_dir = cfg.metricsDir;
            transaction_blacklists = cfg.transactionBlacklists;
            transaction_whitelists = cfg.transactionWhitelists;
            max_disk_pool_data_root_buffer_mb = cfg.maxDiskPoolDataRootBufferMb;
            max_miners = cfg.maxMiners;
            disable = cfg.featuresDisable;
            header_sync_jobs = cfg.headerSyncJobs;
            sync_jobs = cfg.syncJobs;
            debug = cfg.debug;
            semaphores = {
              get_chunk = cfg.maxParallelGetChunkRequests;
              get_and_pack_chunk = cfg.maxParallelGetAndPackChunkRequests;
              get_tx_data = cfg.maxParallelGetTxDataRequests;
              post_chunk = cfg.maxParallelPostChunkRequests;
              get_block_index = cfg.maxParallelBlockIndexRequests;
              get_wallet_list = cfg.maxParallelWalletListRequests;
              get_sync_record = cfg.maxParallelGetSyncRecord;
              arql = 10;
              gateway_arql = 10;
            };
          });
    in {
      systemd.services.arweave = {
        description = "Arweave Node Service";
        after = [ "network.target" ];
        environment = {};
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = "${cfg.package}";
          Type = "forking";
          ExecStartPre = "${pkgs.bash}/bin/bash -c '(${pkgs.procps}/bin/pkill epmd || true) && (${pkgs.procps}/bin/pkill screen || true) && sleep 5 || true'";
          ExecStart = "${pkgs.screen}/bin/screen -dmS arweave ${cfg.package}/bin/start-nix config_file ${configFile} ${builtins.concatStringsSep " " (builtins.concatMap (p: ["peer" p]) cfg.peer)}";
          ExecStop = "${cfg.package}/bin/stop-nix && sleep 5 || true";
        };
      };
    });
}
