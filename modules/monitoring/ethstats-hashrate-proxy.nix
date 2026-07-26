# etc.ethstatsHashrateProxy — per-node transparent ethstats proxy that fixes the hashrate a
# mining node reports to netstats (clients report 0: core-geth's Miner().Hashrate() is 0 because the
# miner is beacon-wrapped; Nethermind hardcodes 0). The node's --ethstats is pointed at this proxy,
# which rewrites each `stats` frame with a real rate polled from ONE of two sources (see the .py):
#   - ipcPath:     ethash_getHashrate over the node's geth IPC (INTERNAL core-geth mining)
#   - hashrateUrl: the etc-getwork-miner's -hashrate-addr endpoint (EXTERNAL getwork mining)
# Usually driven by a client module's ethstats.hashrateProxy flag rather than declared by hand.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.ethstatsHashrateProxy;
  pyenv = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  mkService =
    name: icfg:
    lib.nameValuePair "ethstats-hashrate-proxy-${name}" {
      description = "ethstats hashrate proxy for ${name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        LISTEN_HOST = icfg.listenHost;
        LISTEN_PORT = toString icfg.listenPort;
        UPSTREAM = icfg.upstream;
        POLL_SECONDS = toString icfg.pollSeconds;
      }
      // lib.optionalAttrs (icfg.ipcPath != null) { IPC_PATH = icfg.ipcPath; }
      // lib.optionalAttrs (icfg.hashrateUrl != null) { HASHRATE_URL = icfg.hashrateUrl; };
      serviceConfig = {
        ExecStart = "${pyenv}/bin/python3 ${./ethstats-hashrate-proxy.py}";
        Restart = "always";
        RestartSec = "10s";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictSUIDSGID = true;
      }
      // (if icfg.user != null then { User = icfg.user; } else { DynamicUser = true; })
      // lib.optionalAttrs (icfg.group != null) { Group = icfg.group; }
      # connect() to the node's IPC socket needs write access to its directory.
      // lib.optionalAttrs (icfg.ipcPath != null) { ReadWritePaths = [ (builtins.dirOf icfg.ipcPath) ]; };
    };
in
{
  options.etc.ethstatsHashrateProxy.instances = lib.mkOption {
    default = { };
    description = "ethstats hashrate proxy instances (one per mining node).";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          listenHost = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
          };
          listenPort = lib.mkOption {
            type = lib.types.port;
            description = "Local port the node's --ethstats points at.";
          };
          upstream = lib.mkOption {
            type = lib.types.str;
            example = "wss://netstats.example.org/api";
            description = "Full websocket URL of the real netstats server (incl. /api).";
          };
          hashrateUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "http://127.0.0.1:8555/";
            description = ''
              EXTERNAL-getwork source: the etc-getwork-miner -hashrate-addr endpoint to poll.
              Mutually exclusive with ipcPath.
            '';
          };
          ipcPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/var/lib/core-geth/miner/geth.ipc";
            description = ''
              INTERNAL-mining source: the geth IPC socket to poll ethash_getHashrate from. The
              service must run as a user that can reach the socket (see user). Mutually exclusive
              with hashrateUrl.
            '';
          };
          pollSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 5;
          };
          user = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Run as this user (e.g. geth, to reach ipcPath's socket). null → DynamicUser.";
          };
          group = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg.instances != { }) {
    assertions = lib.mapAttrsToList (name: icfg: {
      assertion = (icfg.ipcPath != null) != (icfg.hashrateUrl != null);
      message = "etc.ethstatsHashrateProxy.instances.${name}: set exactly one of ipcPath (internal mining) or hashrateUrl (external getwork miner).";
    }) cfg.instances;
    systemd.services = lib.mapAttrs' mkService cfg.instances;
  };
}
