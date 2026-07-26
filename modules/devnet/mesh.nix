# Reusable WireGuard overlay mesh for a devnet. Gives every node its own non-loopback IP
# so a single miner can act as a uniform devp2p bootnode over DISCOVERY for all followers.
#
# Why this exists (see hosts/devnet/default.nix for the full writeup): go-ethereum-family
# clients (core-geth 1.12 + getc 1.17) filter LOOPBACK (127.0.0.1) out of their discovery
# table, so a miner-as-bootnode over 127.0.0.1 silently never gets found. Give every client
# a real (non-loopback) overlay address instead and --bootnodes works uniformly everywhere.
#
# Reusable: parametrized by `etc.devnetMesh.nodes`, a list of
#   { name; overlayIp; publicKey; privateKeyFile; listenPort; endpoint; }
# One `networking.wireguard.interfaces.wg-<name>` is created per node, full-mesh peered to
# every OTHER node in the list (AllowedIPs = that peer's overlay /32, Endpoint = that peer's
# `endpoint`).
#
# `endpoint` is the ONLY environment-specific field — everything else (overlayIp, publicKey,
# privateKeyFile, listenPort, and the peer wiring below) is identical whether the nodes are
# instances on one box or spread across a fleet:
#   - single box (today):        endpoint = "127.0.0.1:<that node's own listenPort>"
#   - one-client-per-machine:    endpoint = "<that node's public IP>:<its listenPort>"
# Migrating a node off the shared box later is a one-field edit (its `endpoint`, on every
# OTHER node's peer list) — nothing about the interface, keys, or overlay addressing changes.
#
# Caveat: this only wires the mesh IPs and WireGuard peering. It does NOT rebind any ETC
# client's devp2p listener — core-geth/getc have no bind-IP flag and always listen on
# 0.0.0.0:<p2pPort>, so p2p ports must stay distinct per client (30303..30306) even though
# every client now has its own overlay IP. The overlay IP is what each client's discovery
# ADVERTISES (and what --netrestrict filters peers on), not necessarily what its p2p socket
# binds to.
{
  config,
  lib,
  ...
}:
let
  cfg = config.etc.devnetMesh;

  nodeOpts = {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Node name. The WireGuard interface is named wg-<name>.";
      };
      overlayIp = lib.mkOption {
        type = lib.types.str;
        example = "10.99.0.11";
        description = "This node's address on the mesh overlay (no prefix — see prefixLength).";
      };
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "This node's WireGuard public key (`wg pubkey` output). Safe to commit.";
      };
      privateKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          File with this node's WireGuard private key. Staged out-of-band (e.g. nixos-anywhere
          --extra-files), same pattern as the other /var/lib/devnet-secrets/* secrets. Never
          generated or committed by this module.
        '';
      };
      listenPort = lib.mkOption {
        type = lib.types.port;
        description = "UDP port this node's WireGuard interface listens on.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        example = "127.0.0.1:51821";
        description = ''
          How OTHER nodes dial this node's WireGuard listener ("<host>:<port>"). THE ONLY
          environment-specific field of a node entry — see the module header.
        '';
      };
    };
  };
in
{
  options.etc.devnetMesh = {
    nodes = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule nodeOpts);
      default = [ ];
      description = "Nodes in the WireGuard overlay mesh. Empty (default) → no interfaces created.";
    };
    prefixLength = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 24;
      description = "CIDR prefix length applied to every node's overlayIp (e.g. 24 for a 10.99.0.0/24 mesh).";
    };
    persistentKeepalive = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = ''
        PersistentKeepalive (seconds) on every peer. Mostly a no-op on a single box (peers
        dial 127.0.0.1), but keeps NAT/conntrack state alive once endpoints are real public
        IPs after a multi-machine migration — left on uniformly so that migration needs no
        extra change here.
      '';
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open every node's listenPort (UDP) in the firewall. false is correct for a single-box
        devnet (endpoints are 127.0.0.1 — nothing needs to reach the port from outside). Flip
        to true when migrating to one-client-per-machine, where each node's listenPort must be
        reachable from the other machines.
      '';
    };
  };

  config = lib.mkIf (cfg.nodes != [ ]) {
    networking.wireguard.interfaces = lib.listToAttrs (
      map (node: {
        name = "wg-${node.name}";
        value = {
          ips = [ "${node.overlayIp}/${toString cfg.prefixLength}" ];
          inherit (node) listenPort;
          inherit (node) privateKeyFile;
          peers = map (peer: {
            inherit (peer) publicKey;
            allowedIPs = [ "${peer.overlayIp}/32" ];
            inherit (peer) endpoint;
            inherit (cfg) persistentKeepalive;
          }) (lib.filter (peer: peer.name != node.name) cfg.nodes);
        };
      }) cfg.nodes
    );

    networking.firewall.allowedUDPPorts = lib.optionals cfg.openFirewall (
      map (node: node.listenPort) cfg.nodes
    );
  };
}
