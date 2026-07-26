# spamoor (ethpandaops/spamoor) — the transaction spammer the current Ethereum devnets use,
# with a web dashboard (daemon mode). Built FROM SOURCE. Only the daemon binary is built.
#
# Used on hosts/devnet as the load generator + web UI for the from-block-0 ETC devnet. spamoor
# funds its own child wallets from a root key (the miner's coinbase) and runs configurable
# scenarios; we run its built-in `tx-fuzz` scenario restricted to legacy/type-1 txs (its
# --tx-types flag) so the four clients agree on real STATE TRANSITIONS. A consensus bug shows
# up as one client rejecting a block and forking — visible in netstats; the live chain is the
# differential oracle, no bespoke checker.
#
# One adaptation: spamoor funds child wallets with EIP-1559 (type-2) txs, which this pre-London
# ETC chain (no base fee) rejects — blocking every scenario before it starts. See
# pkgs/spamoor-legacy-funding.patch: the two direct-EOA funders build legacy txs instead. The
# batch funder is left 1559 (it funds via a contract that needs a type-2 deploy anyway) and
# avoided at runtime with --without-batcher. Fees come from eth_gasPrice, so no base-fee read.
#
# Bumping: change rev and refresh the two hashes:
#   1. srcHash    → `nix run nixpkgs#nix-prefetch-github -- ethpandaops spamoor --rev <rev>`
#   2. vendorHash → leave lib.fakeHash, build, paste the hash from the error.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  rev ? "d84b7568fac09667e467b5bef576ff210faf7eb7",
  srcHash ? "sha256-0wxfvtDhuhC1KNZZTpGnXupBjfTX62VTELSumsXjEX8=",
  vendorHash ? "sha256-J/8D1WseX8iAdJemkBKN+e0srwX21xxvryPi9us0J54=",
}:
buildGoModule {
  pname = "spamoor";
  version = "0-unstable-2026-07-24";
  inherit vendorHash;

  src = fetchFromGitHub {
    owner = "ethpandaops";
    repo = "spamoor";
    inherit rev;
    hash = srcHash;
  };

  patches = [
    ./spamoor-legacy-funding.patch
    ./spamoor-evm-fuzz-legacy.patch
    ./spamoor-without-default-spammers.patch
  ];

  # Only the daemon (web UI + scenario runner). The `spamoor` CLI and `spamoor-utils` are unused.
  subPackages = [ "cmd/spamoor-daemon" ];

  ldflags = [
    "-s"
    "-w"
  ];

  doCheck = false;

  meta = {
    description = "Ethereum transaction spammer for testnets, with a web dashboard (ethpandaops/spamoor)";
    homepage = "https://github.com/ethpandaops/spamoor";
    license = lib.licenses.gpl3Only;
    mainProgram = "spamoor-daemon";
    platforms = lib.platforms.linux;
  };
}
