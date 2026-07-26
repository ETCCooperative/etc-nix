# Nethermind (ETC) nodes — multi-instance NixOS module (mirrors modules/clients/core-geth.nix).
# Translation of roles/nethermind + the nethermind.service template.
#
# Multi-instance: each entry in `etc.nethermind.instances.<name>` is an independent
# nethermind-<name> systemd service. This is what lets one box run e.g. a classic and a
# mordor node at once (different ports), or a release node next to a canary build.
#
# Nethermind is configured entirely by CLI flags (no config file): --config <network>
# selects the built-in ETC network (classic/mordor), the rest are --Section.Key flags
# mirroring the Ansible ExecStart. The ethstats key is NOT baked into the store — it is
# read from its sops file at runtime by the start wrapper.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.nethermind;

  # Packages the sops coinbase private key into a Nethermind keystore file (see
  # mining.coinbaseKeyFile) at every service start — Nethermind needs the account
  # actually unlocked, not just its address (derive-nethermind-keystore.py).
  deriveNethermindKeystore = pkgs.writeShellScript "derive-nethermind-keystore" ''
    exec ${
      pkgs.python3.withPackages (
        ps: with ps; [
          eth-keys
          eth-hash
          eth-keyfile
          pycryptodome
          pydantic # eth-utils (pulled by eth-keyfile) imports it but nixpkgs doesn't propagate it here
        ]
      )
    }/bin/python3 ${./derive-nethermind-keystore.py} "$@"
  '';

  instanceOpts =
    { name, ... }:
    {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.callPackage ../../pkgs/nethermind-etc-bin.nix {
            version = "1.37.2.0";
            hash = "sha256-Upy3xcE/0UKlqnP2nJEWTAogQoSDwToGOzcAfT7xtYI=";
          };
          defaultText = lib.literalExpression "pkgs.callPackage ../../pkgs/nethermind-etc-bin.nix { version = …; hash = …; }";
          description = "Nethermind derivation to run (override version via callPackage).";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "nethermind";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "nethermind";
        };
        dataDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/nethermind/${name}";
          defaultText = lib.literalExpression ''"/var/lib/nethermind/<name>"'';
          description = "--datadir. Point at a reused chain volume to preserve it (the DB lives in the nethermind_db subdir, the enode identity in keystore/node.key.plain).";
        };

        network = lib.mkOption {
          type = lib.types.str;
          default = "classic";
          description = ''
            --config value: built-in network (classic/mordor). Kept even for a private
            chain (it selects the base .cfg wiring the Etchash engine/plugin); customChainspec
            then overrides its chainspec via --Init.ChainSpecPath.
          '';
        };

        customChainspec = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            --Init.ChainSpecPath: custom Parity/Nethermind chainspec (private chain). `network`
            still selects the base .cfg (engine/plugin wiring); this overrides its chainspec.
          '';
        };
        genesisHash = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            --Init.GenesisHash: expected genesis hash. Nethermind refuses to boot on mismatch,
            so pinning it to the peer client's genesis hash makes booting itself the parity gate.
          '';
        };
        discovery = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "devp2p discovery. false → --Init.DiscoveryEnabled false (localhost-only devnet).";
        };
        discoveryDns = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "";
          description = ''--Network.DiscoveryDns override; "" disables the ENR-tree so no public peers are pulled in.'';
        };
        staticPeers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "enode://<id>@127.0.0.1:30303" ];
          description = "--Network.StaticPeers: enode URLs to always connect to.";
        };
        onlyStaticPeers = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "--Network.OnlyStaticPeers: dial only the staticPeers list.";
        };
        bootnodes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "--Discovery.Bootnodes: enode URLs to bootstrap discovery.";
        };

        maxPeers = lib.mkOption {
          type = lib.types.ints.positive;
          default = 50;
          description = "--Network.MaxActivePeers.";
        };
        p2pPort = lib.mkOption {
          type = lib.types.port;
          default = 30303;
          description = "--Network.P2PPort and --Network.DiscoveryPort. Different per instance if they share a machine.";
        };
        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open the p2p port (TCP+UDP) in the firewall.";
        };

        jsonRpc = {
          enable = (lib.mkEnableOption "the JSON-RPC server") // {
            default = true;
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8545;
            description = "--JsonRpc.Port. Different per instance if they share a machine.";
          };
          modules = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "Eth"
              "Net"
              "Web3"
              "TxPool"
            ];
            description = "--JsonRpc.EnabledModules.";
          };
        };

        metrics = {
          enable = (lib.mkEnableOption "the Prometheus metrics endpoint (/metrics)") // {
            default = true;
          };
          exposePort = lib.mkOption {
            type = lib.types.port;
            default = 9545;
            description = "--Metrics.ExposePort (Prometheus pull endpoint). Different per instance if they share a machine.";
          };
        };

        pruning = {
          mode = lib.mkOption {
            type = lib.types.str;
            default = "Hybrid";
          };
          cacheMb = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 1024;
          };
          dirtyCacheMb = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 512;
          };
          fullTrigger = lib.mkOption {
            type = lib.types.str;
            default = "StateDbSize";
          };
          fullThresholdMb = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 80000;
          };
        };

        ethstats = {
          enable = lib.mkEnableOption "reporting to ethstats";
          scheme = lib.mkOption {
            type = lib.types.str;
            default = "wss";
          };
          server = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "ethstats host; the /api path and scheme are added → \${scheme}://\${server}/api.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "${config.networking.hostName}-${name}";
            defaultText = lib.literalExpression ''"<hostName>-<name>"'';
          };
          secretFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "File with the ethstats key (sops). Read at runtime, not baked into the store.";
          };
          contact = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
          hashrateProxy = lib.mkEnableOption "the ethstats hashrate proxy (Nethermind hardcodes hashrate 0 in its EthStats frame, so an external getwork miner never shows up without it)";
          hashrateProxyPort = lib.mkOption {
            type = lib.types.port;
            default = 3999;
            description = "Local port the proxy listens on; --EthStats.Server is pointed here (plain ws).";
          };
          hashrateUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "http://127.0.0.1:8555/";
            description = "The getwork miner's -hashrate-addr endpoint the proxy polls (required when hashrateProxy is set).";
          };
        };

        mining = {
          enable = lib.mkEnableOption "PoW mining (remote getwork sealing via the EthereumClassic plugin)";
          coinbaseKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              File with the coinbase private key (hex, sops-provisioned) — same
              convention as the coreGeth/besu mining options. Unlike those clients,
              Nethermind's remote sealer needs the account actually unlocked, not just
              its address (see derive-nethermind-keystore.py): at every service start
              the key is repackaged into a keystore file under dataDir/keystore and
              unlocked with a throwaway password generated the same run, and
              KeyStore.BlockAuthorAccount is set to its address — single source of
              truth, nothing besides this raw key needs provisioning.
            '';
          };
          mode = lib.mkOption {
            type = lib.types.enum [
              "Remote"
              "Local"
              "Manual"
            ];
            default = "Remote";
            description = ''
              --EtcMining.Mode. Remote continuously serves eth_getWork/eth_submitWork to
              an external miner (etc.getworkMiner); Local CPU-mines continuously;
              Manual only produces on evm_mine.
            '';
          };
          extraData = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              --Blocks.ExtraData: block tag identifying the sealing client. Max 32 UTF-8
              bytes — unlike geth, Nethermind throws and exits on an over-length value
              instead of silently truncating it. null → omit (client default).
            '';
          };
          workRefreshSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
            description = "--EtcMining.WorkRefreshSeconds: how often Remote/Local rebuild the block template.";
          };
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra CLI flags appended verbatim.";
        };
      };
    };

  inherit (cfg) instances;
  instanceList = lib.attrValues instances;

  mkStartScript =
    name: icfg:
    let
      # Empty for non-mining instances → their start command stays byte-identical (no
      # rebuild). Packages the sops coinbase key into a keystore Nethermind can actually
      # unlock (see mining.coinbaseKeyFile) and captures the derived address. The
      # password lives under $RUNTIME_DIRECTORY (systemd, from serviceConfig
      # .RuntimeDirectory below) so it never touches the persistent datadir.
      coinbaseSetup = lib.optionalString (icfg.mining.enable && icfg.mining.coinbaseKeyFile != null) ''
        set -e
        mkdir -p ${icfg.dataDir}/keystore
        COINBASE_ADDRESS="$(${deriveNethermindKeystore} ${toString icfg.mining.coinbaseKeyFile} ${icfg.dataDir}/keystore "$RUNTIME_DIRECTORY/coinbase.pass")"
      '';

      # Appended RAW (not escaped) at the very end of the command, like coreGeth's
      # miningFlags — empty and flush against extraArgs when disabled, so non-mining
      # instances render the exact same command as before (no rebuild).
      miningFlags = lib.optionalString icfg.mining.enable (
        " --Mining.Enabled true"
        + " --EtcMining.Mode ${icfg.mining.mode}"
        + " --EtcMining.WorkRefreshSeconds ${toString icfg.mining.workRefreshSeconds}"
        + " --KeyStore.BlockAuthorAccount \"$COINBASE_ADDRESS\""
        + " --KeyStore.UnlockAccounts \"$COINBASE_ADDRESS\""
        + " --KeyStore.PasswordFiles \"$RUNTIME_DIRECTORY/coinbase.pass\""
        + lib.optionalString (
          icfg.mining.extraData != null
        ) " --Blocks.ExtraData \"${icfg.mining.extraData}\""
      );

      # Custom-chain / peering flags, appended RAW after extraArgs like miningFlags — empty
      # (and flush) for every non-devnet instance, so their command stays byte-identical.
      devnetFlags =
        lib.optionalString (
          icfg.customChainspec != null
        ) " --Init.ChainSpecPath ${toString icfg.customChainspec}"
        + lib.optionalString (icfg.genesisHash != null) " --Init.GenesisHash ${icfg.genesisHash}"
        + lib.optionalString (!icfg.discovery) " --Init.DiscoveryEnabled false"
        + lib.optionalString (icfg.discoveryDns != null) " --Network.DiscoveryDns \"${icfg.discoveryDns}\""
        + lib.optionalString (
          icfg.staticPeers != [ ]
        ) " --Network.StaticPeers \"${lib.concatStringsSep "," icfg.staticPeers}\""
        + lib.optionalString icfg.onlyStaticPeers " --Network.OnlyStaticPeers true"
        + lib.optionalString (
          icfg.bootnodes != [ ]
        ) " --Discovery.Bootnodes \"${lib.concatStringsSep "," icfg.bootnodes}\"";
    in
    pkgs.writeShellScript "nethermind-${name}-start" ''
      ${coinbaseSetup}exec ${lib.getExe icfg.package} \
        --config ${icfg.network} \
        --datadir ${icfg.dataDir} \
        --Init.LogDirectory /var/log/nethermind-${name} \
        --Network.P2PPort ${toString icfg.p2pPort} \
        --Network.DiscoveryPort ${toString icfg.p2pPort} \
        --Network.MaxActivePeers ${toString icfg.maxPeers} \
        ${lib.optionalString icfg.jsonRpc.enable ''
          --JsonRpc.Enabled true \
                --JsonRpc.Host ${icfg.jsonRpc.host} \
                --JsonRpc.Port ${toString icfg.jsonRpc.port} \
                --JsonRpc.EnabledModules ${lib.concatStringsSep "," icfg.jsonRpc.modules} \
        ''} \
        ${lib.optionalString icfg.metrics.enable ''
          --Metrics.Enabled true \
                --Metrics.ExposePort ${toString icfg.metrics.exposePort} \
        ''} \
        --Pruning.Mode ${icfg.pruning.mode} \
        --Pruning.CacheMb ${toString icfg.pruning.cacheMb} \
        --Pruning.DirtyCacheMb ${toString icfg.pruning.dirtyCacheMb} \
        --Pruning.FullPruningTrigger ${icfg.pruning.fullTrigger} \
        --Pruning.FullPruningThresholdMb ${toString icfg.pruning.fullThresholdMb} \
        ${lib.optionalString icfg.ethstats.enable ''
          --EthStats.Enabled true \
                --EthStats.Name "${icfg.ethstats.name}" \
                --EthStats.Secret "$(cat ${toString icfg.ethstats.secretFile})" \
                --EthStats.Server "${
                  if icfg.ethstats.hashrateProxy then
                    "ws://127.0.0.1:${toString icfg.ethstats.hashrateProxyPort}/api"
                  else
                    "${icfg.ethstats.scheme}://${icfg.ethstats.server}/api"
                }" \
                --EthStats.Contact "${icfg.ethstats.contact}" \
        ''} \
        ${lib.escapeShellArgs icfg.extraArgs}${devnetFlags}${miningFlags}
    '';

  mkService = name: icfg: {
    description = "Nethermind [${name}] (${icfg.network})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      HOME = icfg.dataDir;
      # The self-contained .NET single-file bundle extracts its embedded native libs here
      # at startup → must be writable (CacheDirectory provides it), and per-instance so
      # two instances on one box don't clash.
      DOTNET_BUNDLE_EXTRACT_BASE_DIR = "/var/cache/nethermind-${name}";
    };
    serviceConfig = {
      User = icfg.user;
      Group = icfg.group;
      # Nethermind resolves configs/chainspecs/plugins relative to the apphost dir.
      WorkingDirectory = "${icfg.package}/nethermind";
      ExecStart = mkStartScript name icfg;
      Restart = "on-failure";
      RestartSec = "10s";
      # Nethermind flushes RocksDB on SIGTERM ("All DBs closed" / "Nethermind is shut down")
      # — give it room, and treat its graceful-shutdown exit code (130, plus 0 and the 143
      # SIGTERM code) as success so a clean stop doesn't trip a restart.
      TimeoutStopSec = "5min";
      SuccessExitStatus = [
        0
        130
        143
      ];
      LimitNOFILE = 1000000;
      LogsDirectory = "nethermind-${name}"; # /var/log/nethermind-<name> (--Init.LogDirectory)
      CacheDirectory = "nethermind-${name}"; # /var/cache/nethermind-<name> (bundle extract dir)
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ icfg.dataDir ];
    }
    // lib.optionalAttrs icfg.mining.enable {
      # /run/nethermind-<name>, 0700 (icfg.user-owned) → the throwaway coinbase-unlock
      # password (see mkStartScript's coinbaseSetup) never lands in the persistent datadir.
      RuntimeDirectory = "nethermind-${name}";
      RuntimeDirectoryMode = "0700";
    };
  };

  # To check port uniqueness across instances that share a machine.
  p2pPorts = map (i: i.p2pPort) instanceList;
  metricsPorts = map (i: i.metrics.exposePort) (lib.filter (i: i.metrics.enable) instanceList);
  rpcPorts = map (i: i.jsonRpc.port) (lib.filter (i: i.jsonRpc.enable) instanceList);
  usedUsers = lib.unique (map (i: i.user) instanceList);
  usedGroups = lib.unique (map (i: i.group) instanceList);
in
{
  imports = [ ../monitoring/ethstats-hashrate-proxy.nix ];

  options.etc.nethermind.instances = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule instanceOpts);
    default = { };
    description = "Nethermind node instances to run on this host.";
  };

  config = lib.mkIf (instances != { }) {
    assertions = [
      {
        assertion = lib.length p2pPorts == lib.length (lib.unique p2pPorts);
        message = "etc.nethermind: there are instances with the same p2pPort on the same machine.";
      }
      {
        assertion = lib.length metricsPorts == lib.length (lib.unique metricsPorts);
        message = "etc.nethermind: there are instances with the same metrics.exposePort on the same machine.";
      }
      {
        assertion = lib.length rpcPorts == lib.length (lib.unique rpcPorts);
        message = "etc.nethermind: there are instances with the same jsonRpc.port on the same machine.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: icfg: [
        {
          assertion = icfg.ethstats.enable -> icfg.ethstats.secretFile != null;
          message = "etc.nethermind.instances.${name}: ethstats.enable requires ethstats.secretFile (sops).";
        }
        {
          assertion = icfg.mining.enable -> icfg.mining.coinbaseKeyFile != null;
          message = "etc.nethermind.instances.${name}: mining.enable requires mining.coinbaseKeyFile (sops).";
        }
        {
          assertion = icfg.mining.enable -> lib.elem "Eth" icfg.jsonRpc.modules;
          message = "etc.nethermind.instances.${name}: mining.enable requires 'Eth' in jsonRpc.modules (eth_getWork/eth_submitWork are registered under it).";
        }
        {
          # Nethermind throws and EXITS on over-length Blocks.ExtraData (unlike geth,
          # which silently truncates it to empty) — guard it at build time.
          assertion = icfg.mining.extraData == null || lib.stringLength icfg.mining.extraData <= 32;
          message = "etc.nethermind.instances.${name}: mining.extraData exceeds 32 bytes (Nethermind refuses to start).";
        }
        {
          assertion =
            icfg.ethstats.hashrateProxy
            -> (icfg.mining.enable && icfg.ethstats.enable && icfg.ethstats.hashrateUrl != null);
          message = "etc.nethermind.instances.${name}: ethstats.hashrateProxy requires mining.enable + ethstats.enable + ethstats.hashrateUrl.";
        }
      ]) instances
    );

    users.users = lib.genAttrs usedUsers (user: {
      isSystemUser = true;
      group = user;
      home = "/var/lib/nethermind";
      createHome = false;
      description = "Nethermind nodes";
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

    # Spin up a hashrate proxy only for instances that opt in (mining + ethstats nodes).
    etc.ethstatsHashrateProxy.instances = lib.mapAttrs (_n: icfg: {
      listenPort = icfg.ethstats.hashrateProxyPort;
      upstream = "${icfg.ethstats.scheme}://${icfg.ethstats.server}/api";
      inherit (icfg.ethstats) hashrateUrl;
    }) (lib.filterAttrs (_: icfg: icfg.ethstats.hashrateProxy) instances);

    systemd.services = lib.mapAttrs' (
      name: icfg: lib.nameValuePair "nethermind-${name}" (mkService name icfg)
    ) instances;
  };
}
