# eth-netstats multi-instance — the ethstats dashboard server.
# Replaces the manual `eth-netstats[-mordor].service` units of the former eth_stats.
# Config via env: WS_SECRET (handshake with the agents) + PORT.
# Instances: classic (:3000) and mordor (:3001).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.ethNetstats;
  user = "eth-netstats";

  instanceOpts = _: {
    options = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ../../pkgs/eth-netstats { };
        defaultText = lib.literalExpression "pkgs.callPackage ../../pkgs/eth-netstats { }";
      };
      port = lib.mkOption { type = lib.types.port; };
      wsSecretFile = lib.mkOption {
        type = lib.types.path;
        description = "File with the ethstats WS_SECRET (sops). Readable by the service user.";
      };
      heapSizeMb = lib.mkOption {
        type = lib.types.int;
        default = 2048;
        description = ''
          Node.js old-space heap cap (MB). classic/mainnet handles far more nodes
          and block/tx traffic than mordor and needs a bigger heap (the former
          eth_stats box ran classic with 4096); 2048 there causes GC-thrash + crash.
        '';
      };
    };
  };

  # Reads the secret at runtime (does not end up in the unit) and starts the server.
  mkStart =
    name: i:
    pkgs.writeShellScript "eth-netstats-${name}-start" ''
      export WS_SECRET="$(cat ${i.wsSecretFile})"
      export PORT=${toString i.port}
      export NODE_OPTIONS="--max-old-space-size=${toString i.heapSizeMb}"
      exec ${lib.getExe i.package}
    '';
in
{
  options.etc.ethNetstats.instances = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule instanceOpts);
    default = { };
    description = "eth-netstats server instances (e.g. classic/mordor).";
  };

  config = lib.mkIf (cfg.instances != { }) {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = { };

    systemd.services = lib.mapAttrs' (
      name: i:
      lib.nameValuePair "eth-netstats-${name}" {
        description = "eth-netstats [${name}] (ethstats server)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = mkStart name i;
          User = user;
          Group = user;
          # Writable dir (under ProtectSystem=strict) that is the app's CWD, so
          # it can write propagation-data.txt without hitting the store (EROFS).
          StateDirectory = "eth-netstats-${name}";
          WorkingDirectory = "/var/lib/eth-netstats-${name}";
          Restart = "always";
          RestartSec = "10s";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          RestrictSUIDSGID = true;
        };
      }
    ) cfg.instances;
  };
}
