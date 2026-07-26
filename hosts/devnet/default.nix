# devnet — private ETC chain from block 0 (current ETC rules, custom chainId), on a single
# multi-instance box: a core-geth miner sealing from block 0 (internal CPU etchash), followed
# by getc/Nethermind/Besu, each isolated in its own network namespace and peered over a
# WireGuard overlay mesh simulating one-client-per-machine (modules/devnet/netns-mesh.nix)
# + an eth-netstats dashboard showing all four. Parametrized by `devnetTarget` (specialArgs
# from flake.nix's mkDevnet), mirroring hosts/replay.
#
# Genesis parity: core-geth's genesis (assets/devnet/genesis-classic-from-0.json) and Nethermind's
# chainspec (assets/devnet/nethermind-classic-from-0.json) are two encodings of the SAME chain —
# identical genesis hash + networkId + fork schedule (all ECIP forks at block 0). Both are derived
# from the classic preset with every fork rebased to 0; chainId/networkId are NOT part of the
# genesis header, so they are reparametrized here without changing the genesis hash.
#
# Ephemeral-first (like hosts/replay): secrets are staged as plain files under
# /var/lib/devnet-secrets via nixos-anywhere --extra-files, not sops.
{
  pkgs,
  lib,
  devnetTarget,
  ...
}:
let
  secretsDir = "/var/lib/devnet-secrets";

  # ── netns-simulated WireGuard mesh ───────────────────────────────────────────────────
  # Every client runs in its own network namespace (ns-<name>) with its own WireGuard
  # overlay IP (10.99.0.0/24) via modules/devnet/netns-mesh.nix, so the miner can be a
  # uniform devp2p bootnode over DISCOVERY and the mesh is a REAL (bridged) tunnel instead
  # of four wg interfaces collapsing to loopback in one namespace — see netns-mesh.nix's
  # header for the full rationale. `underlayIp` (paired with the shared wgPort) is the
  # only environment-specific-at-migration field per node; see netns-mesh.nix's header and
  # mesh.nix (the multi-machine module this replaces on a single box) for that story.
  #
  # ── OPERATOR RUNBOOK — run once, before the first deploy ────────────────────────────
  #   1. Generate the 4 keypairs:
  #        for n in miner nethermind getc besu; do
  #          wg genkey | tee /tmp/wg-$n.key | wg pubkey > /tmp/wg-$n.pub
  #        done
  #   2. Put each /tmp/wg-<name>.pub into the config's `meshPublicKeys` (in the mkDevnet call —
  #      devnet01 in flake.nix, or a downstream reproducer's own flake). Public keys, safe to commit.
  #   3. Stage the 4 PRIVATE keys as plain files via nixos-anywhere --extra-files, same
  #      pattern as the existing devnet-secrets (nodekey, coinbase_key, ethstats_secret):
  #        /var/lib/devnet-secrets/wg-miner.key
  #        /var/lib/devnet-secrets/wg-nethermind.key
  #        /var/lib/devnet-secrets/wg-getc.key
  #        /var/lib/devnet-secrets/wg-besu.key
  #   4. Delete /tmp/wg-*.key once staged — do NOT commit private keys to this repo.
  netnsMeshNodes = [
    {
      name = "miner";
      overlayIp = "10.99.0.11";
      underlayIp = "172.30.0.11";
      publicKey = devnetTarget.meshPublicKeys.miner;
      privateKeyFile = "${secretsDir}/wg-miner.key";
    }
    {
      name = "nethermind";
      overlayIp = "10.99.0.12";
      underlayIp = "172.30.0.12";
      publicKey = devnetTarget.meshPublicKeys.nethermind;
      privateKeyFile = "${secretsDir}/wg-nethermind.key";
    }
    {
      name = "getc";
      overlayIp = "10.99.0.13";
      underlayIp = "172.30.0.13";
      publicKey = devnetTarget.meshPublicKeys.getc;
      privateKeyFile = "${secretsDir}/wg-getc.key";
    }
    {
      name = "besu";
      overlayIp = "10.99.0.14";
      underlayIp = "172.30.0.14";
      publicKey = devnetTarget.meshPublicKeys.besu;
      privateKeyFile = "${secretsDir}/wg-besu.key";
    }
  ];

  # Every client service depends on its own ns-<name>'s WireGuard oneshot (netns-mesh.nix) so it
  # starts inside a fully-wired namespace, never the root one — see the systemd.services.* block
  # near the end of this file.
  netnsWgUnit = name: "netns-mesh-wg-${name}.service";
  netnsPath = name: "/run/netns/ns-${name}";

  gethGenesis =
    let
      base = builtins.fromJSON (builtins.readFile ../../assets/devnet/genesis-classic-from-0.json);
    in
    pkgs.writeText "devnet-${devnetTarget.networkName}-genesis.json" (
      builtins.toJSON (
        base
        // {
          config = base.config // {
            inherit (devnetTarget) chainId networkId;
          };
        }
      )
    );

  nmChainspec =
    let
      base = builtins.fromJSON (builtins.readFile ../../assets/devnet/nethermind-classic-from-0.json);
      idHex = "0x${lib.toHexString devnetTarget.chainId}";
    in
    pkgs.writeText "devnet-${devnetTarget.networkName}-chainspec.json" (
      builtins.toJSON (
        base
        // {
          params = base.params // {
            chainId = idHex;
            networkID = idHex;
          };
        }
      )
    );

  besuGenesis =
    let
      base = builtins.fromJSON (builtins.readFile ../../assets/devnet/besu-classic-from-0.json);
    in
    pkgs.writeText "devnet-${devnetTarget.networkName}-besu-genesis.json" (
      builtins.toJSON (
        base
        // {
          config = base.config // {
            inherit (devnetTarget) chainId;
          };
        }
      )
    );

  # getc (go-ethereum-classic) uses the STANDARD geth genesis schema (homesteadBlock, …) + ETC keys
  # (ecip1017/1041/1099Block, spiralBlock) — NOT core-geth's multi-geth format. londonBlock is
  # deliberately omitted: at block 0 it would stamp a baseFeePerGas (EIP-1559) into the header,
  # diverging from the miner's genesis hash and rules (ETC has no 1559).
  getcGenesis =
    let
      base = builtins.fromJSON (builtins.readFile ../../assets/devnet/getc-genesis-from-0.json);
    in
    pkgs.writeText "devnet-${devnetTarget.networkName}-getc-genesis.json" (
      builtins.toJSON (
        base
        // {
          config = base.config // {
            inherit (devnetTarget) chainId;
          };
        }
      )
    );

  getcPkg = pkgs.callPackage ../../pkgs/getc-bin.nix {
    version = "1.17.4-etc.1";
    # Republished 2026-07-25 with per-feature gating (not chainId-gated), so getc follows the
    # devnet's ETC consensus on a custom chainId — like core-geth.
    gitCommit = "8c438c8f";
    hash = "sha256-rTtv04Eu58rph9XtBjdtnwNoIdSgyouBAO69PM5Edu8=";
  };
in
{
  imports = [
    ./disko.nix
    ./hardware.nix
    ../../modules/base.nix
    ../../modules/observability.nix # node_exporter :9100
    ../../modules/devnet/netns-mesh.nix
    ../../modules/devnet/spamoor.nix
    ../../modules/clients/core-geth.nix
    ../../modules/clients/nethermind.nix
    ../../modules/clients/besu.nix
    ../../modules/monitoring/eth-netstats.nix
  ];

  networking.hostName = devnetTarget.networkName;
  networking.useDHCP = lib.mkForce false;
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  etc.devnetNetnsMesh.nodes = netnsMeshNodes;
  # wgPort/prefixes/bridgeName/bridgeIp stay at netns-mesh.nix's defaults (51820, /24, br-devnet,
  # 172.30.0.1) — nothing here needs to reach outside this box, so no firewall change either.

  # core-geth miner — seals from block 0 (internal CPU etchash), the devnet's bootnode. Runs
  # inside ns-miner (netns-mesh.nix): NetworkNamespacePath below, wired in the
  # systemd.services.* block near the end of this file. Discovery is ON (was --nodiscover): it
  # advertises its mesh overlay IP (10.99.0.11) via --nat extip so followers can find it by
  # discovery instead of static-peering hacks (see netns-mesh.nix for why loopback specifically
  # doesn't work for this).
  etc.coreGeth.instances.miner = {
    package = pkgs.callPackage ../../pkgs/core-geth-bin.nix {
      version = "1.12.22";
      hash = "sha256-4SKjRwGGydMqTeHsfURNNpLf1FFnMql/gHgfysSAqT4=";
    };
    customGenesis = gethGenesis;
    inherit (devnetTarget) networkId;
    syncmode = "full";
    cache = 1024;
    discovery = true; # it's the bootnode — no bootnodes of its own
    netrestrict = "10.99.0.0/24"; # mesh overlay only
    maxpeers = 25;
    openFirewall = false;
    port = 30303; # module default — safe now that every client has its own netns
    nodekeyFile = "${secretsDir}/nodekey"; # stable enode (matches devnetTarget.minerEnode)
    # No --authrpc.port override: each client is isolated in its own netns now, so the module
    # default (8551) no longer collides with getc's (also isolated, also default).
    extraArgs = [
      "--nat"
      "extip:10.99.0.11" # advertise the mesh overlay IP (loopback is filtered from discovery)
    ];
    http = {
      enable = true;
      addr = "127.0.0.1";
      port = 8545;
      api = [
        "eth"
        "net"
        "web3"
        "admin"
        "miner"
      ];
    };
    mining = {
      enable = true;
      etherbaseKeyFile = "${secretsDir}/coinbase_key";
      threads = 1; # internal CPU etchash sealing
      extraData = "${devnetTarget.networkName}/cg";
    };
    ethstats = {
      enable = true;
      # → the hashrate proxy below (injects the miner's real rate). Both the proxy and this
      # instance run inside ns-miner, so 127.0.0.1 here is ns-miner's OWN loopback — unaffected.
      server = "127.0.0.1:3999";
      name = "cg-${devnetTarget.networkName}-miner";
      secretFile = "${secretsDir}/ethstats_secret";
    };
  };

  # getc follower — go-ethereum-classic (reuses the coreGeth module), getc-format genesis (same
  # hash G), non-mining. Finds the miner by discovery (--bootnodes) over the mesh overlay IP —
  # modern getc/geth has no static-nodes flag, and dialing the miner over 127.0.0.1 doesn't work
  # (loopback is filtered out of the discovery table), which is what the mesh solves.
  etc.coreGeth.instances.getc = {
    package = getcPkg;
    customGenesis = getcGenesis; # getc-format genesis (still hashes to G)
    inherit (devnetTarget) networkId;
    syncmode = "full";
    cache = 1024;
    logFormat = "json";
    metrics.expensive = false; # getc 1.17.4 removed --metrics.expensive
    # port/metrics.port stay distinct from the miner's (not netns-driven — both run isolated in
    # their own netns — but modules/clients/core-geth.nix asserts p2p/metrics ports are unique
    # ACROSS its instances on one host, since it has no notion of netns; miner+getc share that
    # module, so these two stay off its defaults while every OTHER port here is a default.
    metrics.port = 6061;
    discovery = true;
    bootnodes = [ devnetTarget.minerEnode ]; # miner's enode, now @ its mesh overlay IP
    netrestrict = "10.99.0.0/24"; # mesh overlay only
    maxpeers = 25;
    openFirewall = false;
    port = 30305;
    # No --authrpc.port override: isolated in its own netns now, so the module default (8551)
    # no longer collides with the miner's (also isolated, also default).
    extraArgs = [
      "--nat"
      "extip:10.99.0.13" # advertise the mesh overlay IP
    ];
    http = {
      enable = true;
      addr = "127.0.0.1";
      port = 8545; # module default — safe now that every client has its own netns
      api = [
        "eth"
        "net"
        "web3"
        "admin"
      ];
    };
    ethstats = {
      enable = true;
      server = "172.30.0.1:3000"; # netstats runs in the HOST (root) ns, reachable via the bridge IP
      name = "getc-${devnetTarget.networkName}-follower";
      secretFile = "${secretsDir}/ethstats_secret";
    };
  };

  # Nethermind follower — same chain (custom chainspec), non-mining. Runs inside ns-nethermind
  # (netns-mesh.nix). Finds the miner by discovery (--Discovery.Bootnodes) over the mesh overlay
  # IP, and advertises + binds its own P2P listener on its overlay IP via
  # Network.ExternalIp/LocalIp (Nethermind docs: "in private network setups, LocalIp,
  # ExternalIp ... should have the same value"). p2pPort/jsonRpc.port/metrics.exposePort are the
  # module defaults — safe now that every client has its own netns (this module's own
  # cross-instance port-uniqueness assertions are trivially satisfied: it has a single instance).
  etc.nethermind.instances.follower = {
    package = pkgs.callPackage ../../pkgs/nethermind-etc-bin.nix {
      version = "1.39.1.1";
      hash = "sha256-rKCe2CS0f0VzjguIRJkH6Fa6Oih3tpdzD3pWJa7uK3Y=";
    };
    network = "classic"; # base .cfg (Etchash engine/plugin wiring); chainspec overridden below
    customChainspec = nmChainspec;
    inherit (devnetTarget) genesisHash; # boot gate: mismatch → refuses to start
    discovery = true;
    discoveryDns = ""; # blank the classic ENR-tree (no public peers)
    bootnodes = [ devnetTarget.minerEnode ]; # miner's enode, now @ its mesh overlay IP
    openFirewall = false;
    p2pPort = 30303;
    maxPeers = 25;
    extraArgs = [
      "--Network.ExternalIp"
      "10.99.0.12"
      "--Network.LocalIp"
      "10.99.0.12"
    ];
    jsonRpc = {
      enable = true;
      port = 8545;
      modules = [
        "Eth"
        "Net"
        "Web3"
        "Admin"
      ];
    };
    metrics.exposePort = 9545;
    ethstats = {
      enable = true;
      scheme = "ws";
      server = "172.30.0.1:3000"; # netstats runs in the HOST (root) ns, reachable via the bridge IP
      name = "nm-${devnetTarget.networkName}-follower";
      secretFile = "${secretsDir}/ethstats_secret";
    };
  };

  # Besu follower — uses besu-legacy (Besu 25.11.0, the last upstream with NATIVE ETC: forks are
  # read from the genesis and not gated on chainId, unlike the besu-etc plugin which hard-gates ETC
  # on chainId 61/63). Same chain via a Besu-format genesis; non-mining. Runs inside ns-besu
  # (netns-mesh.nix). Finds the miner by discovery (bootnodes) over the mesh overlay IP; p2pHost
  # both binds and advertises its own overlay IP (Besu, unlike geth, has no separate
  # advertise-only flag). p2pPort/rpc.http.port/metrics.port are the module defaults — safe now
  # that every client has its own netns (this module's own cross-instance port-uniqueness
  # assertions are trivially satisfied: it has a single instance).
  etc.besu.instances.follower = {
    package = pkgs.callPackage ../../pkgs/besu-legacy.nix {
      version = "25.11.0";
      hash = "sha256-04Uzu0wC3RNj3fSFUroqyqv57H2v3iCDk7Q62/63CUY=";
    };
    genesisFile = besuGenesis;
    inherit (devnetTarget) networkId;
    syncMode = "FULL";
    discovery = true;
    bootnodes = [ devnetTarget.minerEnode ]; # miner's enode, now @ its mesh overlay IP
    p2pHost = "10.99.0.14";
    p2pPort = 30303;
    openFirewall = false;
    rpc.http = {
      enable = true;
      port = 8545;
      api = [
        "ETH"
        "NET"
        "WEB3"
        "ADMIN"
      ];
    };
    metrics.port = 9545;
    ethstats = {
      enable = true;
      scheme = "ws";
      server = "172.30.0.1:3000"; # netstats runs in the HOST (root) ns, reachable via the bridge IP
      name = "besu-legacy-${devnetTarget.networkName}-follower";
      secretFile = "${secretsDir}/ethstats_secret";
    };
  };

  # netstats dashboard for the devnet — runs in the HOST (root) namespace, unaffected by the
  # per-client netns split, and reachable both from any client's netns via the bridge IP
  # (172.30.0.1:3000, see each ethstats.server above) and publicly via the VM IP:3000.
  etc.ethNetstats.instances.devnet = {
    port = 3000;
    wsSecretFile = "${secretsDir}/ethstats_secret";
  };

  # core-geth reports hashrate 0 to netstats (its miner is beacon-wrapped), so route --ethstats
  # through this proxy, which polls the real internal rate via ethash_getHashrate over the geth IPC
  # and injects it. Declared by hand (not core-geth's ethstats.hashrateProxy) so `upstream` is plain
  # ws to netstats instead of the module's wss default. Runs inside ns-miner (systemd.services.*
  # below) so it shares a namespace with core-geth-miner: the miner's ethstats points at this
  # proxy's ns-miner loopback (127.0.0.1:3999, see the miner instance above), and this proxy
  # reaches netstats over the bridge IP.
  etc.ethstatsHashrateProxy.instances.miner = {
    listenPort = 3999;
    upstream = "ws://172.30.0.1:3000/api";
    ipcPath = "/var/lib/core-geth/miner/geth.ipc";
    user = "geth"; # to reach the geth IPC socket
  };

  # Transaction spammer + web dashboard — the tool the current Ethereum devnets use
  # (ethpandaops/spamoor). Runs inside ns-miner (systemd.services.* below) against the miner's own
  # RPC (127.0.0.1:8545) so fuzzed txs land straight in the sealing txpool; the faucet is the
  # miner's coinbase key (rewards accrue from block 0, so Restart=always is the whole "wait for
  # funds" story). A consensus divergence (a client recomputing a different stateRoot) shows up as
  # a head-hash split in netstats — the live chain is the differential oracle, no checker needed.
  #
  # The startup file mirrors spamoor's built-in "Fuzzing" group (evm-fuzz + tx-fuzz +
  # tx-fuzz-invalid under a shared 10 tx/slot budget), re-tuned for this pre-London ETC chain: the
  # tx-fuzz member is pinned to legacy/type-1 (its default `all` includes EIP-1559/blob/7702 this
  # chain rejects); evm-fuzz emits legacy via pkgs/spamoor-evm-fuzz-legacy.patch; funding is legacy
  # via pkgs/spamoor-legacy-funding.patch + --without-batcher. --without-default-spammers
  # (pkgs/spamoor-without-default-spammers.patch) keeps the dashboard to just this group instead of
  # the 25 built-in, mostly-1559 templates. The web UI binds 0.0.0.0:8080 inside ns-miner;
  # spamoor-webui-forward (below) republishes it on the host IP.
  etc.spamoor.instances.devnet = {
    rpcHosts = [ "http://127.0.0.1:8545" ]; # ns-miner's own loopback → the miner's RPC
    privkeyFile = "${secretsDir}/coinbase_key"; # same key the miner mines to
    port = 8080;
    user = "geth"; # reads coinbase_key (owned/readable by the miner's user)
    extraArgs = [ "--without-default-spammers" ]; # only run this group, no built-in templates
    startupSpammerFile = pkgs.writeText "spamoor-${devnetTarget.networkName}-startup.yaml" ''
      # Mirrors spamoor's built-in "Fuzzing" group (daemon/default-spammers/03-fuzzing.yaml),
      # re-tuned for this pre-London ETC chain. The ONLY change from upstream is the tx-fuzz
      # member's tx_types (all -> legacy,accesslist); the small wallet pools (4/4/1) and shared
      # 10 tx/slot budget are the upstream group's own curation — the small pools also sidestep the
      # slow-accrual funding gate (the auto-sized standalone defaults want ~1000 ETH → ~40 min).
      - scenario: group
        name: ${devnetTarget.networkName}-fuzzing
        description: EVM-execution + transaction-layer + invalid-tx fuzzing for the ${devnetTarget.networkName} devnet, sharing a 10 tx/slot budget to surface consensus and validation bugs.
        start: true
        group_config:
          throughput_mode: shared
          total_throughput: 10
          total_count: 0
          total_max_pending: 0
      - scenario: evm-fuzz
        name: EVM Execution Fuzzing
        description: Deploys contracts with randomly generated, stack-aware bytecode exercising opcodes and precompiles.
        group: ${devnetTarget.networkName}-fuzzing
        group_config:
          weight: 2
          enabled: true
          sort_order: 0
        config:
          seed: evmfuzz-700001
          refill_amount: 5000000000000000000
          refill_balance: 1000000000000000000
          refill_interval: 600
          total_count: 0
          throughput: 4
          max_pending: 20
          max_wallets: 4
          rebroadcast: 1
          base_fee: 20
          tip_fee: 2
          gas_limit: 1000000
          max_code_size: 512
          min_code_size: 100
          fuzz_mode: all
      - scenario: tx-fuzz
        name: Transaction Layer Fuzzing
        description: Sends well-formed legacy + EIP-2930 access-list transactions with randomized calldata, access lists and targets.
        group: ${devnetTarget.networkName}-fuzzing
        group_config:
          weight: 2
          enabled: true
          sort_order: 1
        config:
          seed: txfuzz-700002
          refill_amount: 5000000000000000000
          refill_balance: 1000000000000000000
          refill_interval: 600
          total_count: 0
          throughput: 4
          max_pending: 20
          max_wallets: 4
          rebroadcast: 1
          base_fee: 20
          tip_fee: 2
          gas_limit: 500000
          tx_types: legacy,accesslist
          max_call_data: 1024
          max_access_list: 5
      - scenario: tx-fuzz-invalid
        name: Invalid Transaction Fuzzing
        description: Fires deliberately-invalid transactions (bad chainid/nonce/gas, malformed RLP, …) fire-and-forget; a node accepting one is a potential validation gap.
        group: ${devnetTarget.networkName}-fuzzing
        group_config:
          weight: 1
          enabled: true
          sort_order: 2
        config:
          seed: txfuzzinvalid-700003
          refill_amount: 50000000000000000
          refill_balance: 10000000000000000
          refill_interval: 600
          total_count: 0
          throughput: 2
          max_pending: 20
          max_wallets: 1
          categories: all
    '';
  };

  # ── netns wiring ──────────────────────────────────────────────────────────────────────
  # None of the four client modules (or ethstats-hashrate-proxy) expose a NetworkNamespacePath
  # option, so it's set here instead, per-service. Each Requires+After its ns-<name>'s WireGuard
  # oneshot (netns-mesh-wg-<name>.service, from netns-mesh.nix, which itself Requires+After
  # netns-mesh-setup-<name>.service, which Requires+After netns-mesh-bridge.service) — that chain
  # is what actually guarantees "netns/bridge/veth/wg fully up before any client starts", even
  # though the ordering is declared from the client side rather than via `before` on the mesh
  # oneshots (systemd's dependency graph is symmetric either way).
  systemd.services.core-geth-miner = {
    after = [ (netnsWgUnit "miner") ];
    requires = [ (netnsWgUnit "miner") ];
    serviceConfig.NetworkNamespacePath = netnsPath "miner";
  };
  systemd.services.core-geth-getc = {
    after = [ (netnsWgUnit "getc") ];
    requires = [ (netnsWgUnit "getc") ];
    serviceConfig.NetworkNamespacePath = netnsPath "getc";
  };
  systemd.services.nethermind-follower = {
    after = [ (netnsWgUnit "nethermind") ];
    requires = [ (netnsWgUnit "nethermind") ];
    serviceConfig.NetworkNamespacePath = netnsPath "nethermind";
  };
  systemd.services.besu-follower = {
    after = [ (netnsWgUnit "besu") ];
    requires = [ (netnsWgUnit "besu") ];
    serviceConfig.NetworkNamespacePath = netnsPath "besu";
  };
  # Shares ns-miner with core-geth-miner: it polls the miner's geth IPC (unaffected by netns —
  # a unix socket, filesystem-only) and needs to reach netstats over the bridge IP from INSIDE
  # ns-miner, since the miner's own --ethstats points at this proxy's ns-miner loopback.
  systemd.services.ethstats-hashrate-proxy-miner = {
    after = [ (netnsWgUnit "miner") ];
    requires = [ (netnsWgUnit "miner") ];
    serviceConfig.NetworkNamespacePath = netnsPath "miner";
  };
  # spamoor shares ns-miner with core-geth-miner so it reaches the miner's RPC over 127.0.0.1.
  # Requires the wg oneshot (that's what creates the namespace); only `after` core-geth-miner —
  # it self-heals via Restart=always if the miner isn't sealing yet, so no hard `requires` on it.
  systemd.services.spamoor-devnet = {
    after = [
      (netnsWgUnit "miner")
      "core-geth-miner.service"
    ];
    requires = [ (netnsWgUnit "miner") ];
    serviceConfig.NetworkNamespacePath = netnsPath "miner";
  };
  # spamoor's dashboard binds 0.0.0.0:8080 INSIDE ns-miner, so from the host (root ns) it's only
  # reachable at the miner's bridge underlay IP (172.30.0.11:8080). Republish it on the host's
  # public interface (0.0.0.0:8080, firewall-opened below) with a plain TCP forwarder — the same
  # "reachable by VM IP" access netstats gets on :3000. Needs only the veth/bridge up
  # (netns-mesh-setup-miner), not spamoor itself; socat retries the backend via Restart.
  systemd.services.spamoor-webui-forward = {
    description = "republish spamoor's ns-miner web UI (172.30.0.11:8080) on the host";
    wantedBy = [ "multi-user.target" ];
    after = [
      "netns-mesh-setup-miner.service"
      "spamoor-devnet.service"
    ];
    requires = [ "netns-mesh-setup-miner.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:8080,fork,reuseaddr TCP:172.30.0.11:8080";
      Restart = "always";
      RestartSec = "10s";
      DynamicUser = true;
    };
  };

  # OOM headroom (on top of base.nix's 1 GB): core-geth full DAG + .NET Nethermind + node netstats.
  swapDevices = [
    {
      device = "/var/swapfile-devnet";
      size = 4096;
    }
  ];

  networking.firewall.allowedTCPPorts = [
    22
    3000 # netstats dashboard, reachable by IP (RPC/metrics stay on loopback)
    8080 # spamoor dashboard, republished from ns-miner by spamoor-webui-forward
  ];
}
