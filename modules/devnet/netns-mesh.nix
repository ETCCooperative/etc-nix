# Single-box simulation of a multi-machine WireGuard mesh: one network namespace per client,
# so each looks like its own machine (own routing table, own 127.0.0.1, own devp2p listener)
# instead of sharing the root namespace. See hosts/devnet/default.nix for why the ROOT-namespace
# mesh (modules/devnet/mesh.nix) doesn't give a stable peer graph on one host: four WireGuard
# interfaces on the SAME 10.99.0.0/24 in ONE namespace collapse peer dials to local delivery and
# make the kernel pick an ambiguous source IP (a client's admin_peers ends up seeing its OWN
# overlay address), so devp2p connections that bind/advertise a specific IP (Nethermind
# Network.LocalIp, Besu p2pHost) never complete a real tunnel.
#
# Topology per node (all raw ip/wg via systemd oneshots — there is no NixOS-native "wireguard
# inside a netns" primitive):
#
#   host (root ns)                      ns-<name>
#   ┌───────────────┐   veth pair    ┌────────────────────────────┐
#   │ br-devnet      │──veth-<name>──┤ eth0  <underlayIp>/24       │
#   │ <bridgeIp>/24  │               │ wg0   <overlayIp>/24 ───────┼─ peered to every OTHER
#   └───────────────┘                │       ListenPort <wgPort>   │  node's <underlayIp>:<wgPort>
#                                     └────────────────────────────┘
#
# br-devnet is a plain Linux bridge: every node's host-side veth end is a switch port on it, so
# underlay traffic between two nodes (including the WireGuard handshake/data UDP) is switched by
# the kernel bridge between two DIFFERENT namespaces — never collapsed to loopback. Each wg0
# lives inside its own namespace with its own connected route for the whole overlay /24 (from the
# /24 assigned to it), so peer traffic routes over wg0 without any extra `ip route` bookkeeping.
#
# `underlayIp:wgPort` (the WireGuard Endpoint) is the only thing that stops applying once nodes
# are on separate machines — see the header of mesh.nix for the multi-machine migration story:
# delete this module's usage (the systemd oneshots below + the host's NetworkNamespacePath
# overrides), import mesh.nix instead, and reuse the SAME overlayIp/publicKey/privateKeyFile per
# node — only `endpoint` (loopback/underlay → each machine's public IP) changes.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.devnetNetnsMesh;

  nodeOpts = {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Node name. Namespace is ns-<name>, veth is veth-<name>.";
      };
      overlayIp = lib.mkOption {
        type = lib.types.str;
        example = "10.99.0.11";
        description = "This node's address on the WireGuard overlay (wg0, inside ns-<name>), no prefix.";
      };
      underlayIp = lib.mkOption {
        type = lib.types.str;
        example = "172.30.0.11";
        description = ''
          This node's address on the host-bridge underlay (eth0, inside ns-<name>), no prefix.
          Paired with wgPort, this is what every OTHER node dials as this node's WireGuard
          Endpoint — the only field that becomes environment-specific after a multi-machine
          migration (see the module header).
        '';
      };
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "This node's WireGuard public key (`wg pubkey` output). Safe to commit.";
      };
      privateKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          File with this node's WireGuard private key. Staged out-of-band (e.g. nixos-anywhere
          --extra-files). Never generated or committed by this module.
        '';
      };
    };
  };

  ipBin = "${pkgs.iproute2}/bin/ip";
  wgBin = "${pkgs.wireguard-tools}/bin/wg";

  # Runs once: the shared L2 switch every node's veth pair attaches to. Idempotent (guards every
  # step) because it's a oneshot with RemainAfterExit — a unit-file change re-runs ExecStart
  # against whatever the box already has from a previous boot/switch.
  bridgeSetupScript = pkgs.writeShellScript "netns-mesh-bridge-setup" ''
    set -euo pipefail
    ${ipBin} link show ${cfg.bridgeName} >/dev/null 2>&1 || ${ipBin} link add ${cfg.bridgeName} type bridge
    ${ipBin} addr show dev ${cfg.bridgeName} | grep -q ' ${cfg.bridgeIp}/' || ${ipBin} addr add ${cfg.bridgeIp}/${toString cfg.underlayPrefixLength} dev ${cfg.bridgeName}
    ${ipBin} link set ${cfg.bridgeName} up
  '';

  # Per node: the namespace + its veth leg onto the bridge + a default route back to the bridge
  # (used for anything outside the overlay/underlay /24s, e.g. reaching netstats on bridgeIp).
  nodeSetupScript =
    node:
    pkgs.writeShellScript "netns-mesh-setup-${node.name}" ''
      set -euo pipefail
      ns=ns-${node.name}
      # Short names: Linux caps interface names at 15 chars, and "veth-nethermind-ns" (18) is over.
      hostVeth=vh-${node.name}
      nsVeth=vn-${node.name}

      # Check the netns file directly: `ip netns list` prints "ns-x (id: N)", so `grep -qx ns-x`
      # would miss it and re-run `netns add` (which then errors "File exists").
      test -e /var/run/netns/"$ns" || ${ipBin} netns add "$ns"

      # Idempotent on the netns's OWN state (eth0 present), so a rebuild that renames the host
      # veth doesn't try to re-create over an already-wired namespace and fail half-way.
      if ! ${ipBin} -n "$ns" link show eth0 >/dev/null 2>&1; then
        ${ipBin} link add "$hostVeth" type veth peer name "$nsVeth"
        ${ipBin} link set "$hostVeth" master ${cfg.bridgeName}
        ${ipBin} link set "$hostVeth" up
        ${ipBin} link set "$nsVeth" netns "$ns"
        ${ipBin} -n "$ns" link set "$nsVeth" name eth0
        ${ipBin} -n "$ns" addr add ${node.underlayIp}/${toString cfg.underlayPrefixLength} dev eth0
        ${ipBin} -n "$ns" link set lo up
        ${ipBin} -n "$ns" link set eth0 up
        ${ipBin} -n "$ns" route add default via ${cfg.bridgeIp}
      fi
    '';

  # Per node: wg0 INSIDE the namespace, full-mesh peered to every OTHER node over the underlay
  # (Endpoint = that peer's underlayIp:wgPort). All nodes may share one wgPort — each has its own
  # namespace, so there's no port collision to avoid (unlike modules/devnet/mesh.nix, which needs
  # a distinct listenPort per node because every wg-<name> interface lives in the SAME namespace).
  nodeWgScript =
    node:
    let
      peers = lib.filter (peer: peer.name != node.name) cfg.nodes;
      peerLines = lib.concatMapStrings (peer: ''
        ${ipBin} netns exec "$ns" ${wgBin} set wg0 peer ${lib.escapeShellArg peer.publicKey} allowed-ips ${peer.overlayIp}/32 endpoint ${peer.underlayIp}:${toString cfg.wgPort} persistent-keepalive ${toString cfg.persistentKeepalive}
      '') peers;
    in
    pkgs.writeShellScript "netns-mesh-wg-${node.name}" ''
      set -euo pipefail
      ns=ns-${node.name}

      ${ipBin} netns exec "$ns" ${ipBin} link show wg0 >/dev/null 2>&1 || ${ipBin} netns exec "$ns" ${ipBin} link add wg0 type wireguard
      ${ipBin} netns exec "$ns" ${wgBin} set wg0 listen-port ${toString cfg.wgPort} private-key ${lib.escapeShellArg (toString node.privateKeyFile)}
      ${ipBin} -n "$ns" addr replace ${node.overlayIp}/${toString cfg.overlayPrefixLength} dev wg0
      ${ipBin} -n "$ns" link set wg0 up
      ${peerLines}
    '';

  nodeSetupUnit = node: {
    name = "netns-mesh-setup-${node.name}";
    value = {
      description = "devnet netns mesh: ns-${node.name} + veth-${node.name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "netns-mesh-bridge.service" ];
      requires = [ "netns-mesh-bridge.service" ];
      path = [
        pkgs.iproute2
        pkgs.gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = nodeSetupScript node;
      };
    };
  };

  nodeWgUnit = node: {
    name = "netns-mesh-wg-${node.name}";
    value = {
      description = "devnet netns mesh: wg0 inside ns-${node.name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "netns-mesh-setup-${node.name}.service" ];
      requires = [ "netns-mesh-setup-${node.name}.service" ];
      path = [
        pkgs.iproute2
        pkgs.wireguard-tools
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = nodeWgScript node;
      };
    };
  };
in
{
  options.etc.devnetNetnsMesh = {
    nodes = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule nodeOpts);
      default = [ ];
      description = "Nodes to simulate as their own machine. Empty (default) → nothing created.";
    };
    wgPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = "UDP port every node's wg0 listens on inside its own namespace.";
    };
    overlayPrefixLength = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 24;
      description = "CIDR prefix applied to every node's overlayIp on wg0.";
    };
    underlayPrefixLength = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 24;
      description = "CIDR prefix applied to every node's underlayIp on eth0, and to the bridge's own address.";
    };
    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "br-devnet";
      description = "Host-side Linux bridge every node's veth pair attaches to.";
    };
    bridgeIp = lib.mkOption {
      type = lib.types.str;
      default = "172.30.0.1";
      description = ''
        The bridge's own address, in the root namespace. Every node's default route, and the
        address host-side services (e.g. netstats) are reachable at from inside any node's
        namespace.
      '';
    };
    persistentKeepalive = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "PersistentKeepalive (seconds) on every peer.";
    };
  };

  config = lib.mkIf (cfg.nodes != [ ]) {
    systemd.services = {
      netns-mesh-bridge = {
        description = "devnet netns mesh: host bridge ${cfg.bridgeName}";
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.iproute2
          pkgs.gnugrep
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = bridgeSetupScript;
        };
      };
    }
    // lib.listToAttrs (map nodeSetupUnit cfg.nodes)
    // lib.listToAttrs (map nodeWgUnit cfg.nodes);
  };
}
