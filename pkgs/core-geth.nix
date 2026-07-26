# core-geth (etclabscore/core-geth) compiled from source — the ETC Go client.
#
# BUILD mode: mirror of roles/coregeth/tasks/custom-build.yml. Useful for running
# a branch/PR/commit that does NOT yet have a release (testing a change live).
# To run an already-published release/pre-release without compiling, use
# pkgs/core-geth-bin.nix.
#
# Parameterized: callPackage can override version/rev/hashes to point at another
# commit, e.g.
#   pkgs.callPackage ./pkgs/core-geth.nix {
#     version = "my-branch"; rev = "abc1234"; srcHash = "..."; vendorHash = "...";
#   }
#
# Bumping: change version/rev and refresh the two hashes:
#   1. srcHash    → `nix run nixpkgs#nix-prefetch-github -- etclabscore core-geth --rev <rev>`
#   2. vendorHash → leave lib.fakeHash, `nix build .#core-geth`, paste the hash from the error.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  version,
  rev ? "v${version}",
  srcHash,
  vendorHash,
}:
buildGoModule {
  pname = "core-geth";
  inherit version vendorHash;

  src = fetchFromGitHub {
    owner = "etclabscore";
    repo = "core-geth";
    inherit rev;
    hash = srcHash;
  };

  # Only the `geth` binary. The rest of cmd/* (clef, faucet, devp2p, abigen…) is
  # not used on these nodes; building them only adds time and closure size.
  subPackages = [ "cmd/geth" ];

  # core-geth keeps the upstream module path (github.com/ethereum/go-ethereum),
  # so the commit is injected into `geth version` via this symbol.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/ethereum/go-ethereum/internal/version.gitCommit=${rev}"
  ];

  # The tree's consensus suites are long and require network access; the binary doesn't need them.
  doCheck = false;

  meta = {
    description = "Ethereum Classic Go client (etclabscore/core-geth), build from source";
    homepage = "https://github.com/etclabscore/core-geth";
    license = lib.licenses.gpl3Plus;
    mainProgram = "geth";
    platforms = lib.platforms.linux;
  };
}
