# etc.spamoor — run ethpandaops/spamoor's daemon (transaction spammer + web dashboard)
# against a devnet RPC, so the clients agree on real STATE TRANSITIONS rather than just empty
# blocks. This is the transaction spammer the current Ethereum devnets use; nothing here is
# bespoke. spamoor funds its own child wallets from a root key and runs configurable scenarios;
# on the devnet we point it at the miner and auto-start its built-in `tx-fuzz` scenario
# restricted to legacy/type-1 txs (see the host's startup-spammer file).
#
# Consensus check comes for free: the stateRoot is in the block header, so a client that
# recomputes a different root rejects the block and forks — a divergence shows up as a
# head-hash split across the clients in netstats. No differential checker to maintain.
#
# Pre-London note: --withoutBatcher is on by default because batch funding goes through a
# batcher CONTRACT deployed with an EIP-1559 tx, which this no-base-fee chain rejects. With it
# off, funding uses the direct-EOA path, which pkgs/spamoor-legacy-funding.patch makes legacy.
#
# The root key is passed to spamoor on argv (--privkey has no file/env input), so it is visible
# in the running process's /proc/<pid>/cmdline. It is NEVER written to the Nix store or the unit
# file (the wrapper reads it at runtime). Acceptable for an ephemeral devnet whose coinbase
# controls only play-money; do not reuse this module for a key with real value as-is.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.spamoor;

  mkService =
    name: icfg:
    let
      dbPath = "/var/lib/spamoor-${name}/spamoor.db";
      startScript = pkgs.writeShellScript "spamoor-${name}-start" ''
        set -euo pipefail
        args=(
          --port ${toString icfg.port}
          --db ${lib.escapeShellArg dbPath}
          --slot-duration ${lib.escapeShellArg icfg.slotDuration}
          --startup-delay ${toString icfg.startupDelay}
        )
        ${lib.concatMapStringsSep "\n" (h: "args+=( --rpchost ${lib.escapeShellArg h} )") icfg.rpcHosts}
        ${lib.optionalString icfg.withoutBatcher "args+=( --without-batcher )"}
        ${lib.optionalString (
          icfg.startupSpammerFile != null
        ) "args+=( --startup-spammer ${lib.escapeShellArg (toString icfg.startupSpammerFile)} )"}
        ${lib.optionalString (icfg.extraArgs != [ ]) "args+=( ${lib.escapeShellArgs icfg.extraArgs} )"}
        args+=( --privkey "$(cat ${lib.escapeShellArg (toString icfg.privkeyFile)})" )
        exec ${lib.getExe icfg.package} "''${args[@]}"
      '';
    in
    lib.nameValuePair "spamoor-${name}" {
      description = "spamoor transaction spammer + web UI for ${name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = startScript;
        # The coinbase has no balance at first boot, and the RPC may not be up yet; keep
        # retrying until both are, which is when spamoor can fund its wallets and start.
        Restart = "always";
        RestartSec = "15s";
        StateDirectory = "spamoor-${name}";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictSUIDSGID = true;
      }
      // (if icfg.user != null then { User = icfg.user; } else { DynamicUser = true; })
      // lib.optionalAttrs (icfg.group != null) { Group = icfg.group; };
    };
in
{
  options.etc.spamoor.instances = lib.mkOption {
    default = { };
    description = "spamoor daemon instances (one web UI + spammer per RPC target).";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.callPackage ../../pkgs/spamoor.nix { };
            defaultText = lib.literalExpression "pkgs.callPackage ../../pkgs/spamoor.nix { }";
            description = "spamoor derivation providing the spamoor-daemon binary.";
          };
          rpcHosts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            example = [ "http://127.0.0.1:8545" ];
            description = "RPC endpoints to send transactions to (spamoor spreads load across them).";
          };
          privkeyFile = lib.mkOption {
            type = lib.types.path;
            description = ''
              File with the root/faucet private key (hex, 0x-optional) spamoor funds its child
              wallets from. On the devnet this is the miner's coinbase key. The service user must
              be able to read it (see user).
            '';
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8080;
            description = "Port the web dashboard listens on (bound on 0.0.0.0 in the service's netns).";
          };
          withoutBatcher = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Pass --without-batcher. Required on a pre-London chain: batch funding deploys a
              batcher contract with an EIP-1559 tx, which a no-base-fee chain rejects. With it on,
              funding uses the direct-EOA path (made legacy by pkgs/spamoor-legacy-funding.patch).
            '';
          };
          slotDuration = lib.mkOption {
            type = lib.types.str;
            default = "12s";
            description = "--slot-duration for rate limiting (roughly the chain's block time).";
          };
          startupDelay = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 30;
            description = "--startup-delay: seconds before auto-starting spammers (allows cancellation).";
          };
          startupSpammerFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "YAML file of startup spammers (--startup-spammer). null → none auto-start.";
          };
          user = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Run as this user (e.g. geth, to read privkeyFile). null → DynamicUser.";
          };
          group = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Extra args appended to spamoor-daemon.";
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg.instances != { }) {
    systemd.services = lib.mapAttrs' mkService cfg.instances;
  };
}
