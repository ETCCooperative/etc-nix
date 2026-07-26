# "live" core-geth nodes — translation of roles/coregeth (defaults/main.yml +
# templates/coregeth.service.j2) into a multi-instance NixOS module.
#
# Multi-instance (just as the Ansible role runs N `app_*` of the same client):
# each entry in `etc.coreGeth.instances.<name>` is an independent
# core-geth-<name> systemd service. Cases:
#   - instances.release  → package = core-geth-bin (latest release, reference node)
#   - instances.canary   → package = core-geth (build of a branch/PR to test in live)
#   - instances.mordor   → another network, etc.
# They can coexist on one machine (different ports) or go to separate machines
# to isolate blast-radius (recommended for release vs canary/replay).
#
# Deliberate differences from the Ansible role:
#   - datadir under /var/lib (NixOS convention) instead of /home/geth/datadirs.
#   - syncmode `full` by default (the role used `snap`): this is the node that
#     "did a full sync and keeps moving forward".
#   - the secrets (influx token, ethstats key) are read at runtime from sops,
#     not baked into the unit.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.coreGeth;

  # Derives the miner etherbase ADDRESS from a private-key file at service start
  # (see mining.etherbaseKeyFile). Keeps --miner.etherbase in lockstep with the
  # sops-provisioned coinbase key — single source of truth, no hardcoded address.
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

  instanceOpts =
    { name, ... }:
    {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.callPackage ../../pkgs/core-geth-bin.nix {
            version = "1.12.22";
            hash = "sha256-4SKjRwGGydMqTeHsfURNNpLf1FFnMql/gHgfysSAqT4=";
          };
          defaultText = lib.literalExpression "pkgs.callPackage ../../pkgs/core-geth-bin.nix { version = …; hash = …; }";
          description = ''
            core-geth derivation to run. Defaults to the pinned release binary
            (pkgs/core-geth-bin.nix). For a specific ref built from source:
            pkgs.callPackage ../../pkgs/core-geth.nix { version = …; rev = …; srcHash = …; vendorHash = …; }.
          '';
        };

        network = lib.mkOption {
          type = lib.types.enum [
            "classic"
            "mordor"
          ];
          default = "classic";
          description = ''
            ETC network (--classic / --mordor flag). Ignored when customGenesis is set
            (the chain is then a private one selected by --networkid).
          '';
        };

        customGenesis = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Genesis JSON (core-geth/multi-geth extended format) for a PRIVATE chain. When
            set, the instance runs an idempotent `geth init` against it on first start and
            boots with --networkid <networkId> INSTEAD of --classic/--mordor. null → a
            public ETC network selected by `network` (unchanged behaviour).
          '';
        };
        networkId = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "devp2p/JSON-RPC network id (--networkid). Required when customGenesis is set.";
        };
        discovery = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "devp2p discovery. false → --nodiscover (isolated devnet with no peers to find).";
        };
        bootnodes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "enode://<id>@127.0.0.1:30303" ];
          description = "enode URLs to bootstrap peering (--bootnodes). For localhost peering point at 127.0.0.1:<port>.";
        };
        netrestrict = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "127.0.0.0/8";
          description = "Restrict peering to a CIDR (--netrestrict). Pins a devnet to loopback.";
        };

        syncmode = lib.mkOption {
          type = lib.types.enum [
            "full"
            "snap"
            "light"
          ];
          default = "full";
          description = "Sync mode. The project's live node runs full.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "geth";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "geth";
        };

        datadir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/core-geth/${name}";
          defaultText = lib.literalExpression ''"/var/lib/core-geth/<name>"'';
          description = ''
            Node datadir. To reuse an already-synced DB (migration from
            Ansible), point it at the existing volume's path, e.g.
            "/mnt/volume_sfo2_01/app_benchmark_coregeth_classic_full_sfo2_1".
          '';
        };
        nodekeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            File with the 64-hex devp2p node private key (sops-provisioned) — the
            enode identity. When set, passed as --nodekey so the identity is decoupled
            from the datadir and survives volume loss; null → geth uses
            <datadir>/geth/nodekey (auto-generated on first start). Readable by the
            service user. Preserve across migrations.
          '';
        };

        cache = lib.mkOption {
          type = lib.types.ints.positive;
          default = 4096;
          description = "Cache size in MB (--cache).";
        };
        maxpeers = lib.mkOption {
          type = lib.types.ints.positive;
          default = 50;
        };
        verbosity = lib.mkOption {
          type = lib.types.ints.between 0 5;
          default = 3;
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 30303;
          description = "p2p port (TCP+UDP). Different per instance if they share a machine.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open the p2p port in the firewall.";
        };

        metrics = {
          enable = (lib.mkEnableOption "geth metrics endpoint") // {
            default = true;
          };
          expensive = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Emit --metrics.expensive. Newer geth bases dropped this flag (getc >= 1.17.4
              rejects it and refuses to start); set false on those instances.
            '';
          };
          addr = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Endpoint bind address. Scrapeable by Prometheus at /debug/metrics/prometheus.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 6060;
            description = "Different per instance if they share a machine.";
          };
          influxdb2 = {
            enable = lib.mkEnableOption "pushing metrics to InfluxDB v2";
            endpoint = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            bucket = lib.mkOption {
              type = lib.types.str;
              default = "gethmetrics";
            };
            organization = lib.mkOption {
              type = lib.types.str;
              default = "geths";
            };
            tags = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Full Influx tag string; overrides the built default (chain/host/instance + owner).";
            };
            owner = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Optional `owner` tag folded into the default tags (empty = omitted; the tool ships none).";
            };
            tokenFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "File containing the token (sops). Readable by the service user.";
            };
          };
        };

        ethstats = {
          enable = lib.mkEnableOption "reporting to ethstats";
          server = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "${config.networking.hostName}-${name}";
            defaultText = lib.literalExpression ''"<hostName>-<name>"'';
          };
          secretFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "File containing the ethstats key (sops). Readable by the service user.";
          };
          hashrateProxy = lib.mkEnableOption "the ethstats hashrate proxy (external-getwork nodes otherwise report hashrate 0 — geth sources it from Miner().Hashrate(), which has no local threads)";
          hashrateProxyPort = lib.mkOption {
            type = lib.types.port;
            default = 3999;
            description = "Local port the proxy listens on; geth's --ethstats is pointed here.";
          };
          hashrateUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "http://127.0.0.1:8555/";
            description = "The getwork miner's -hashrate-addr endpoint the proxy polls (required when hashrateProxy is set).";
          };
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra flags for geth (escaped).";
        };

        # GC / RPC. Off by default so nodes that don't set them (bootnodes) render
        # the exact same start command as before.
        gcmode = lib.mkOption {
          type = lib.types.enum [
            "full"
            "archive"
          ];
          default = "full";
          description = "GC mode; `archive` keeps all historical state (RPC archive nodes).";
        };
        txlookuplimit = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.unsigned;
          default = null;
          description = "--txlookuplimit (blocks of tx index kept); 0 = keep all (archive). null → omit.";
        };
        logFormat = lib.mkOption {
          type = lib.types.enum [
            "terminal"
            "json"
          ];
          default = "terminal";
          description = "--log.format; `json` for structured logs (getc → sentry-reporter). terminal → omit (unchanged command).";
        };

        http = {
          enable = lib.mkEnableOption "the HTTP-RPC server (--http)";
          addr = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8545;
          };
          api = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "eth"
              "net"
              "web3"
            ];
          };
          vhosts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "localhost" ];
            description = "Accepted Host headers (--http.vhosts).";
          };
          corsdomain = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "CORS origins (--http.corsdomain); empty → omit.";
          };
        };

        ws = {
          enable = lib.mkEnableOption "the WS-RPC server (--ws)";
          addr = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8546;
          };
          api = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "eth"
              "net"
              "web3"
            ];
          };
        };

        mining = {
          enable = lib.mkEnableOption "PoW mining (--mine)";
          etherbaseKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              File with the coinbase private key (hex, sops-provisioned). The
              etherbase ADDRESS is derived from it at service start so the
              etherbase flag always matches the key — single source of truth,
              no hardcoded address. Readable by the service user.
            '';
          };
          etherbaseFlag = lib.mkOption {
            type = lib.types.str;
            default = "miner.etherbase";
            description = ''
              Flag name that sets the miner coinbase. core-geth uses
              miner.etherbase; getc (≥1.17.4) dropped it and takes
              miner.pending.feeRecipient instead — both write the same
              PendingFeeRecipient, so the derived address flows through either.
            '';
          };
          extraData = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              --miner.extradata: block tag identifying the sealing client. Max 32
              bytes; over-length is SILENTLY discarded to empty by geth, so keep it
              short. null → omit (client stamps its default RLP tag).
            '';
          };
          gaslimit = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "--miner.gaslimit; null → omit.";
          };
          threads = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "--miner.threads; null → omit.";
          };
        };
      };
    };

  inherit (cfg) instances;
  instanceList = lib.attrValues instances;

  tagsFor =
    name: icfg:
    if icfg.metrics.influxdb2.tags != "" then
      icfg.metrics.influxdb2.tags
    else
      "chain=${icfg.network},${
        lib.optionalString (icfg.metrics.influxdb2.owner != "") "owner=${icfg.metrics.influxdb2.owner},"
      }host=${config.networking.hostName},instance=${name}";

  # --gcmode/--txlookuplimit/--http/--ws built as a shell-arg list, appended to
  # extraArgs. Empty for nodes that leave them at the defaults → the start command
  # stays byte-identical to before (existing nodes don't rebuild).
  extraFlags =
    icfg:
    lib.optionals (icfg.nodekeyFile != null) [
      "--nodekey"
      (toString icfg.nodekeyFile)
    ]
    ++ lib.optionals (icfg.gcmode != "full") [
      "--gcmode"
      icfg.gcmode
    ]
    ++ lib.optionals (icfg.txlookuplimit != null) [
      "--txlookuplimit"
      (toString icfg.txlookuplimit)
    ]
    ++ lib.optionals (icfg.logFormat != "terminal") [
      "--log.format"
      icfg.logFormat
    ]
    ++ lib.optionals icfg.http.enable (
      [
        "--http"
        "--http.addr"
        icfg.http.addr
        "--http.port"
        (toString icfg.http.port)
        "--http.api"
        (lib.concatStringsSep "," icfg.http.api)
        "--http.vhosts"
        (lib.concatStringsSep "," icfg.http.vhosts)
      ]
      ++ lib.optionals (icfg.http.corsdomain != [ ]) [
        "--http.corsdomain"
        (lib.concatStringsSep "," icfg.http.corsdomain)
      ]
    )
    ++ lib.optionals icfg.ws.enable [
      "--ws"
      "--ws.addr"
      icfg.ws.addr
      "--ws.port"
      (toString icfg.ws.port)
      "--ws.api"
      (lib.concatStringsSep "," icfg.ws.api)
    ]
    ++ lib.optional (!icfg.discovery) "--nodiscover"
    ++ lib.optionals (icfg.bootnodes != [ ]) [
      "--bootnodes"
      (lib.concatStringsSep "," icfg.bootnodes)
    ]
    ++ lib.optionals (icfg.netrestrict != null) [
      "--netrestrict"
      icfg.netrestrict
    ];

  # Mining flags, appended RAW (not escaped) to the start command because the etherbase
  # flag uses $MINER_ETHERBASE, derived from the key at runtime (see mkStartScript). Leading
  # space, empty when disabled → non-mining nodes render the exact same command as before
  # (no rebuild).
  miningFlags =
    icfg:
    lib.optionalString icfg.mining.enable (
      " --mine --${icfg.mining.etherbaseFlag} \"$MINER_ETHERBASE\""
      + lib.optionalString (
        icfg.mining.gaslimit != null
      ) " --miner.gaslimit ${toString icfg.mining.gaslimit}"
      + lib.optionalString (
        icfg.mining.threads != null
      ) " --miner.threads ${toString icfg.mining.threads}"
      + lib.optionalString (
        icfg.mining.extraData != null
      ) " --miner.extradata \"${icfg.mining.extraData}\""
    );

  # Per-instance start wrapper. The secrets are injected via substitution at
  # runtime (they don't end up in the store or in the unit). Caveat: geth takes
  # token/key as flags → at runtime they are visible in /proc/<pid>/cmdline to
  # anyone who can read it on the machine (same model as the Ansible unit, but
  # without the secret on disk world-readable).
  mkStartScript =
    name: icfg:
    let
      # Empty for non-mining nodes → their start command stays byte-identical (no
      # rebuild). When mining, derives the etherbase from the sops coinbase key first.
      etherbaseSetup = lib.optionalString (icfg.mining.enable && icfg.mining.etherbaseKeyFile != null) ''
        # Derive the miner etherbase from the sops coinbase key (single source of truth).
        MINER_ETHERBASE="$(${deriveEtherbase} ${toString icfg.mining.etherbaseKeyFile})"
      '';

      # One-time genesis init for a private chain (customGenesis). Idempotent: skipped once
      # chaindata exists. Empty for public instances → their start script stays byte-identical.
      initStep = lib.optionalString (icfg.customGenesis != null) ''
        if [ ! -d ${icfg.datadir}/geth/chaindata ]; then
          ${lib.getExe icfg.package} --datadir ${icfg.datadir} init ${toString icfg.customGenesis}
        fi
      '';

      # --classic/--mordor for public nets; --networkid for a private chain. A public
      # instance renders "--classic" exactly as before (byte-identical, no rebuild).
      networkSelector =
        if icfg.customGenesis == null then
          "--${icfg.network}"
        else
          "--networkid ${toString icfg.networkId}";
    in
    pkgs.writeShellScript "core-geth-${name}-start" ''
      ${etherbaseSetup}${initStep}exec ${lib.getExe icfg.package} \
        --datadir ${icfg.datadir} \
        ${networkSelector} \
        --syncmode ${icfg.syncmode} \
        --port ${toString icfg.port} \
        --maxpeers ${toString icfg.maxpeers} \
        --cache ${toString icfg.cache} \
        --verbosity ${toString icfg.verbosity} \
        --ipcpath ${icfg.datadir}/geth.ipc \
        ${lib.optionalString icfg.metrics.enable ''
          --metrics ${lib.optionalString icfg.metrics.expensive "--metrics.expensive"} \
          --metrics.addr ${icfg.metrics.addr} --metrics.port ${toString icfg.metrics.port} \
        ''} \
        ${
          lib.optionalString (icfg.metrics.enable && icfg.metrics.influxdb2.enable) ''
            --metrics.influxdbv2 \
            --metrics.influxdb.endpoint "${icfg.metrics.influxdb2.endpoint}" \
            --metrics.influxdb.bucket "${icfg.metrics.influxdb2.bucket}" \
            --metrics.influxdb.organization "${icfg.metrics.influxdb2.organization}" \
            --metrics.influxdb.tags "${tagsFor name icfg}" \
            --metrics.influxdb.token "$(cat ${toString icfg.metrics.influxdb2.tokenFile})" \
          ''
        } \
        ${lib.optionalString icfg.ethstats.enable ''
          --ethstats "${icfg.ethstats.name}:$(cat ${toString icfg.ethstats.secretFile})@${
            if icfg.ethstats.hashrateProxy then
              "127.0.0.1:${toString icfg.ethstats.hashrateProxyPort}"
            else
              icfg.ethstats.server
          }" \
        ''} \
        ${lib.escapeShellArgs (extraFlags icfg ++ icfg.extraArgs)}${miningFlags icfg}
    '';

  mkService = name: icfg: {
    description = "core-geth [${name}] (${icfg.network}) — ETC live node";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      User = icfg.user;
      Group = icfg.group;
      ExecStart = mkStartScript name icfg;
      Restart = "always";
      RestartSec = "30s";
      # geth catches SIGTERM and flushes; give it room to close the DB cleanly.
      TimeoutStopSec = "5min";
      FinalKillSignal = "SIGABRT";

      # Hardening (it's a network service, so no PrivateNetwork).
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ icfg.datadir ];
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LimitNOFILE = 65536;
    };
  };

  # To check port uniqueness across instances that share a machine.
  p2pPorts = map (i: i.port) instanceList;
  metricsPorts = map (i: i.metrics.port) (lib.filter (i: i.metrics.enable) instanceList);
  usesGethUser = lib.any (i: i.user == "geth") instanceList;
  usesGethGroup = lib.any (i: i.group == "geth") instanceList;
in
{
  imports = [ ../monitoring/ethstats-hashrate-proxy.nix ];

  options.etc.coreGeth.instances = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule instanceOpts);
    default = { };
    description = "core-geth node instances to run on this host.";
  };

  config = lib.mkIf (instances != { }) {
    assertions = [
      {
        assertion = lib.length p2pPorts == lib.length (lib.unique p2pPorts);
        message = "etc.coreGeth: there are instances with the same p2p port on the same machine.";
      }
      {
        assertion = lib.length metricsPorts == lib.length (lib.unique metricsPorts);
        message = "etc.coreGeth: there are instances with the same metrics.port on the same machine.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: icfg: [
        {
          assertion = icfg.metrics.influxdb2.enable -> icfg.metrics.influxdb2.tokenFile != null;
          message = "etc.coreGeth.instances.${name}: influxdb2.enable requires tokenFile (sops).";
        }
        {
          assertion = icfg.ethstats.enable -> icfg.ethstats.secretFile != null;
          message = "etc.coreGeth.instances.${name}: ethstats.enable requires secretFile (sops).";
        }
        {
          assertion = icfg.mining.enable -> icfg.mining.etherbaseKeyFile != null;
          message = "etc.coreGeth.instances.${name}: mining.enable requires etherbaseKeyFile (sops).";
        }
        {
          # geth silently discards over-length extradata to empty rather than erroring,
          # so guard it at build time. 32 bytes = the header field limit.
          assertion = icfg.mining.extraData == null || lib.stringLength icfg.mining.extraData <= 32;
          message = "etc.coreGeth.instances.${name}: mining.extraData exceeds 32 bytes (geth would silently drop it).";
        }
        {
          assertion =
            icfg.ethstats.hashrateProxy
            -> (icfg.mining.enable && icfg.ethstats.enable && icfg.ethstats.hashrateUrl != null);
          message = "etc.coreGeth.instances.${name}: ethstats.hashrateProxy requires mining.enable + ethstats.enable + ethstats.hashrateUrl.";
        }
        {
          assertion = (icfg.customGenesis != null) -> (icfg.networkId != null);
          message = "etc.coreGeth.instances.${name}: customGenesis requires networkId.";
        }
      ]) instances
    );

    users.users = lib.mkIf usesGethUser {
      geth = {
        isSystemUser = true;
        group = "geth";
        home = "/var/lib/core-geth";
        createHome = false;
        description = "core-geth nodes";
      };
    };
    users.groups = lib.mkIf usesGethGroup { geth = { }; };

    # systemd-tmpfiles creates each datadir (and its parents) with the correct ownership.
    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _name: icfg: "d ${icfg.datadir} 0750 ${icfg.user} ${icfg.group} - -"
    ) instances;

    networking.firewall.allowedTCPPorts = lib.concatMap (
      i: lib.optional i.openFirewall i.port
    ) instanceList;
    networking.firewall.allowedUDPPorts = lib.concatMap (
      i: lib.optional i.openFirewall i.port
    ) instanceList;

    # Spin up a hashrate proxy only for instances that opt in (mining + ethstats nodes).
    etc.ethstatsHashrateProxy.instances = lib.mapAttrs (_n: icfg: {
      listenPort = icfg.ethstats.hashrateProxyPort;
      upstream = "wss://${icfg.ethstats.server}/api";
      inherit (icfg.ethstats) hashrateUrl;
    }) (lib.filterAttrs (_: icfg: icfg.ethstats.hashrateProxy) instances);

    systemd.services = lib.mapAttrs' (
      name: icfg: lib.nameValuePair "core-geth-${name}" (mkService name icfg)
    ) instances;
  };
}
