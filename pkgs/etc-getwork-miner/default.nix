# etc-getwork-miner — CPU etchash miner that drives a node over the historical getwork
# protocol (eth_getWork / eth_submitWork). Written for the cross-client consensus test: it
# exists to exercise that RPC path on every client, not to compete for hashrate.
#
# Why not ethminer: upstream is archived (last release 0.18.0, Jul 2019) and predates
# ECIP-1099, which halved the DAG epoch length. It derives the epoch from the seed hash
# instead of reading the block number getWork returns, so on mordor it sizes the DAG for the
# wrong epoch and every nonce it finds is invalid. No maintained CPU etchash miner exists.
#
# DAG caveat: go-etchash writes to <home>/.etchash and resolves <home> via user.Current(),
# which WINS OVER $HOME — the dir cannot be redirected by setting the environment. The
# service user's actual home must therefore be a persistent path, or the ~1-3 GB DAG is
# regenerated on every restart. See modules/mining/getwork-miner.nix.
{
  lib,
  buildGoModule,
  vendorHash ? "sha256-YVJAdD8TQAoB8y0W3uRMnaH3Aznd1F2ui6H0rNLdzHE=",
}:
buildGoModule {
  pname = "etc-getwork-miner";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  inherit vendorHash;

  # Same as go-orphan-tracker/gethexporter: go-ethereum/crypto/secp256k1 is cgo with its C
  # sources in a subdir that has no .go files, so `go mod vendor` drops them. proxyVendor
  # keeps the module cache instead.
  proxyVendor = true;

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "CPU etchash miner speaking the getwork protocol (eth_getWork/eth_submitWork)";
    mainProgram = "etc-getwork-miner";
    platforms = lib.platforms.linux;
  };
}
