# Hyperledger Besu nodes — multi-instance NixOS module (mirrors modules/clients/core-geth.nix).
# Translation of roles/besu + plays/besu (config.toml template).
#
# Multi-instance: each entry in `etc.besu.instances.<name>` is an independent
# besu-<name> systemd service (its own config.toml + datadir + ports). This is what lets
# one box run e.g. a classic and a mordor node at once, or a release node next to a canary.
#
# Secrets (ethstats key, miner coinbase) are NOT baked into the store: the static bits go
# into a generated config.toml, and the ethstats URL (with the sops key) + the miner
# coinbase (derived at start from the sops coinbase key, like the coreGeth module) are
# added as CLI flags at runtime by the start wrapper.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.besu;
  # Captured here because instanceOpts shadows the outer `config` with the submodule's.
  inherit (config.networking) hostName;

  # Same address-from-key derivation the coreGeth mining option uses (single source of
  # truth: --miner-coinbase always matches the sops coinbase key, no hardcoded address).
  deriveEtherbase = pkgs.writeShellScript "derive-etherbase" ''
    exec ${
      pkgs.python3.withPackages (
        ps: with ps; [
          eth-keys
          eth-hash
          pycryptodome
          pydantic
        ]
      )
    }/bin/python3 ${./derive-etherbase.py} "$@"
  '';

  tomlList = xs: "[" + lib.concatMapStringsSep "," (x: ''"${x}"'') xs + "]";

  instanceOpts =
    {
      name,
      config,
      ...
    }:
    {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.callPackage ../../pkgs/besu-legacy.nix {
            version = "25.11.0";
            hash = "sha256-04Uzu0wC3RNj3fSFUroqyqv57H2v3iCDk7Q62/63CUY=";
          };
          defaultText = lib.literalExpression "pkgs.callPackage ../../pkgs/besu-legacy.nix { version = …; hash = …; }";
          description = ''
            Besu derivation to run. Defaults to the legacy last-upstream-with-ETC client
            (pkgs/besu-legacy.nix). For the current ETC-plugin client: build from source
            with pkgs/besu-etc.nix, or fetch a CI release with pkgs/besu-etc-bin.nix.
          '';
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "besu";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "besu";
        };
        dataDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/besu/${name}";
          defaultText = lib.literalExpression ''"/var/lib/besu/<name>"'';
          description = "Besu data-path. Point at a reused chain to preserve it.";
        };
        nodePrivateKeyFile = lib.mkOption {
          type = lib.types.str;
          default = "${config.dataDir}/key";
          defaultText = lib.literalExpression ''"''${dataDir}/key"'';
          description = "node-private-key-file — the enode identity. Preserve across migrations.";
        };

        network = lib.mkOption {
          type = lib.types.str;
          default = "classic";
          description = ''
            Besu network (classic/mordor are built-in ETC networks). Ignored when genesisFile is
            set (a private chain selected by genesis-file + network-id instead).
          '';
        };

        genesisFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            genesis-file for a PRIVATE chain: written to config.toml with network-id INSTEAD of
            the built-in `network`. null → the public ETC network selected by `network`.
          '';
        };
        networkId = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "network-id (--network-id). Required when genesisFile is set.";
        };
        discovery = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "discovery-enabled. false → isolated devnet (no discovery).";
        };
        discoveryDns = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "discovery-dns-url override (e.g. \"\" to disable the ENR-tree).";
        };
        bootnodes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "bootnodes enode URLs (discovery bootstrap).";
        };
        staticNodes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "enode://<id>@127.0.0.1:30303" ];
          description = "static-nodes-file enodes: always-connect direct peers (reliable localhost peering).";
        };
        syncMode = lib.mkOption {
          type = lib.types.enum [
            "FULL"
            "SNAP"
            "FAST"
            "CHECKPOINT"
          ];
          default = "SNAP";
        };
        dataStorageFormat = lib.mkOption {
          type = lib.types.enum [
            "FOREST"
            "BONSAI"
          ];
          default = "FOREST";
        };
        minGasPrice = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 1000;
        };
        hostAllowlist = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "*" ];
        };
        ethCapabilityMax = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "Xeth-capability-max (experimental eth wire cap); null → omit.";
        };

        p2pHost = lib.mkOption {
          type = lib.types.str;
          description = "Advertised p2p host (the node's public IP).";
        };
        p2pPort = lib.mkOption {
          type = lib.types.port;
          default = 30303;
          description = "p2p port. Different per instance if they share a machine.";
        };
        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open the p2p port in the firewall.";
        };

        rpc.http = {
          enable = lib.mkEnableOption "the HTTP-JSON-RPC server";
          host = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8545;
            description = "rpc-http-port. Different per instance if they share a machine.";
          };
          api = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "NET"
              "ETH"
              "WEB3"
            ];
          };
          corsOrigins = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "all" ];
          };
        };

        mining = {
          enable = lib.mkEnableOption "PoW mining (miner-enabled)";
          coinbaseKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              File with the coinbase private key (sops). --miner-coinbase is derived from it
              at service start — single source of truth, no hardcoded address.
            '';
          };
        };

        metrics = {
          enable = (lib.mkEnableOption "the Prometheus metrics endpoint") // {
            default = true;
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Metrics bind address (localhost by default → not exposed).";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 9545;
            description = "metrics-port. Different per instance if they share a machine.";
          };
        };

        txPoolPriceBump = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 10;
        };

        enableJsonErrorLog = lib.mkEnableOption "the log4j2 JSON error log (ERROR+ → events.jsonl) for etc.sentryReporter (file_jsonl, clientKind = besu)";

        ethstats = {
          enable = lib.mkEnableOption "reporting to ethstats";
          scheme = lib.mkOption {
            type = lib.types.str;
            default = "wss";
          };
          server = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "${hostName}-${name}";
            defaultText = lib.literalExpression ''"<hostName>-<name>"'';
          };
          secretFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "File with the ethstats key (sops). Read at runtime.";
          };
        };
      };
    };

  inherit (cfg) instances;
  instanceList = lib.attrValues instances;

  mkStaticNodesFile =
    name: icfg: pkgs.writeText "besu-${name}-static-nodes.json" (builtins.toJSON icfg.staticNodes);

  mkConfigFile =
    name: icfg:
    pkgs.writeText "besu-${name}-config.toml" ''
      data-path="${icfg.dataDir}"
      data-storage-format="${icfg.dataStorageFormat}"
      node-private-key-file="${icfg.nodePrivateKeyFile}"
      ${
        if icfg.genesisFile != null then
          ''genesis-file="${icfg.genesisFile}"'' + "\nnetwork-id=${toString icfg.networkId}"
        else
          ''network="${icfg.network}"''
      }
      min-gas-price=${toString icfg.minGasPrice}
      sync-mode="${icfg.syncMode}"
      host-allowlist=${tomlList icfg.hostAllowlist}
      engine-jwt-disabled=false
      ${lib.optionalString (!icfg.discovery) "discovery-enabled=false"}
      ${lib.optionalString (icfg.discoveryDns != null) ''discovery-dns-url="${icfg.discoveryDns}"''}
      ${lib.optionalString (icfg.bootnodes != [ ]) "bootnodes=${tomlList icfg.bootnodes}"}
      ${lib.optionalString (
        icfg.staticNodes != [ ]
      ) ''static-nodes-file="${mkStaticNodesFile name icfg}"''}
      ${lib.optionalString icfg.mining.enable "miner-enabled=true"}
      ${lib.optionalString icfg.rpc.http.enable ''
        rpc-http-enabled=true
        rpc-http-host="${icfg.rpc.http.host}"
        rpc-http-port=${toString icfg.rpc.http.port}
        rpc-http-api=${tomlList icfg.rpc.http.api}
        rpc-http-cors-origins=${tomlList icfg.rpc.http.corsOrigins}
      ''}
      p2p-host="${icfg.p2pHost}"
      p2p-port=${toString icfg.p2pPort}
      tx-pool-price-bump=${toString icfg.txPoolPriceBump}
      ${lib.optionalString icfg.metrics.enable ''
        metrics-enabled=true
        metrics-host="${icfg.metrics.host}"
        metrics-port=${toString icfg.metrics.port}
      ''}
      ${lib.optionalString (
        icfg.ethCapabilityMax != null
      ) "Xeth-capability-max=${toString icfg.ethCapabilityMax}"}
    '';

  mkStartScript =
    name: icfg:
    pkgs.writeShellScript "besu-${name}-start" ''
      ${lib.optionalString (icfg.mining.enable && icfg.mining.coinbaseKeyFile != null) ''
        # Derive the miner coinbase from the sops key (single source of truth).
        COINBASE="$(${deriveEtherbase} ${toString icfg.mining.coinbaseKeyFile})"
      ''}
      exec ${lib.getExe icfg.package} --config-file=${mkConfigFile name icfg} \
        ${
          lib.optionalString (
            icfg.mining.enable && icfg.mining.coinbaseKeyFile != null
          ) ''--miner-coinbase="$COINBASE" ''
        } \
        ${lib.optionalString icfg.ethstats.enable ''--ethstats="${icfg.ethstats.scheme}://${icfg.ethstats.name}:$(cat ${toString icfg.ethstats.secretFile})@${icfg.ethstats.server}"''}
    '';

  mkService = name: icfg: {
    description = "Hyperledger Besu [${name}] (${icfg.network})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # The Besu launcher (gradle app script) shells out to awk/sed/grep/coreutils (e.g. to
    # detect the Java version) — provide them, else it dies with "awk: command not found".
    path = [
      pkgs.gawk
      pkgs.gnused
      pkgs.gnugrep
      pkgs.coreutils
    ];
    environment = {
      HOME = icfg.dataDir;
    }
    // lib.optionalAttrs icfg.enableJsonErrorLog {
      # Swap Besu's log4j2 config for ours: same console output (journal) + an ERROR+ JSON file
      # (events.jsonl) that etc.sentryReporter tails. The file lands under LogsDirectory.
      LOG4J_CONFIGURATION_FILE = "${./besu-log4j2.xml}";
      BESU_JSON_LOG = "/var/log/besu-${name}/events.jsonl";
    };
    serviceConfig = {
      User = icfg.user;
      Group = icfg.group;
      ExecStart = mkStartScript name icfg;
      Restart = "on-failure";
      RestartSec = "10s";
      # Besu catches SIGTERM (exit 143) and flushes RocksDB; give it room.
      SuccessExitStatus = 143;
      TimeoutStopSec = "5min";
      LimitNOFILE = 65536;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ icfg.dataDir ];
      # /var/log/besu-<name> for the JSON error log (writable under ProtectSystem=strict).
      LogsDirectory = lib.mkIf icfg.enableJsonErrorLog "besu-${name}";
    };
  };

  # To check port uniqueness across instances that share a machine.
  p2pPorts = map (i: i.p2pPort) instanceList;
  metricsPorts = map (i: i.metrics.port) (lib.filter (i: i.metrics.enable) instanceList);
  rpcPorts = map (i: i.rpc.http.port) (lib.filter (i: i.rpc.http.enable) instanceList);
  usedUsers = lib.unique (map (i: i.user) instanceList);
  usedGroups = lib.unique (map (i: i.group) instanceList);
in
{
  options.etc.besu.instances = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule instanceOpts);
    default = { };
    description = "Hyperledger Besu node instances to run on this host.";
  };

  config = lib.mkIf (instances != { }) {
    assertions = [
      {
        assertion = lib.length p2pPorts == lib.length (lib.unique p2pPorts);
        message = "etc.besu: there are instances with the same p2pPort on the same machine.";
      }
      {
        assertion = lib.length metricsPorts == lib.length (lib.unique metricsPorts);
        message = "etc.besu: there are instances with the same metrics.port on the same machine.";
      }
      {
        assertion = lib.length rpcPorts == lib.length (lib.unique rpcPorts);
        message = "etc.besu: there are instances with the same rpc.http.port on the same machine.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: icfg: [
        {
          assertion = icfg.mining.enable -> icfg.mining.coinbaseKeyFile != null;
          message = "etc.besu.instances.${name}: mining.enable requires mining.coinbaseKeyFile (sops).";
        }
        {
          assertion = icfg.ethstats.enable -> icfg.ethstats.secretFile != null;
          message = "etc.besu.instances.${name}: ethstats.enable requires ethstats.secretFile (sops).";
        }
        {
          assertion = (icfg.genesisFile != null) -> (icfg.networkId != null);
          message = "etc.besu.instances.${name}: genesisFile requires networkId.";
        }
      ]) instances
    );

    users.users = lib.genAttrs usedUsers (user: {
      isSystemUser = true;
      group = user;
      home = "/var/lib/besu";
      createHome = false;
      description = "Hyperledger Besu nodes";
    });
    users.groups = lib.genAttrs usedGroups (_group: { });

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _name: icfg: "d ${icfg.dataDir} 0750 ${icfg.user} ${icfg.group} - -"
    ) instances;

    networking.firewall.allowedTCPPorts = lib.concatMap (
      i: lib.optional i.openFirewall i.p2pPort
    ) instanceList;
    networking.firewall.allowedUDPPorts = lib.concatMap (
      i: lib.optional i.openFirewall i.p2pPort
    ) instanceList;

    systemd.services = lib.mapAttrs' (
      name: icfg: lib.nameValuePair "besu-${name}" (mkService name icfg)
    ) instances;
  };
}
