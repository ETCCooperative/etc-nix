# getc = go-ethereum-classic (diega/go-ethereum-classic) compiled FROM SOURCE — the
# counterpart of pkgs/core-geth.nix for the getc fork. Use this to run a branch/PR/commit
# that does NOT yet have a published release (the "test-getc" node runs whatever ref you
# point it at). To run an already-published release tarball without compiling, use
# pkgs/getc-bin.nix instead.
#
# getc is a straight geth fork: it keeps the upstream Go module path
# (github.com/ethereum/go-ethereum), so the commit is injected into `geth version` via the
# same internal/version.gitCommit symbol core-geth uses. Only the `geth` binary is built.
#
# Parameterized: callPackage can override version/rev/hashes to point at another ref, e.g.
#   pkgs.callPackage ./pkgs/getc.nix {
#     version = "my-branch"; rev = "abc1234"; srcHash = "..."; vendorHash = "...";
#   }
#
# Bumping: change version/rev and refresh the two hashes:
#   1. srcHash    → `nix run nixpkgs#nix-prefetch-github -- diega go-ethereum-classic --rev <rev>`
#   2. vendorHash → leave lib.fakeHash, `nix build .#getc`, paste the hash from the error.
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
  pname = "getc";
  inherit version vendorHash;

  src = fetchFromGitHub {
    owner = "diega";
    repo = "go-ethereum-classic";
    inherit rev;
    hash = srcHash;
  };

  # Only the `geth` binary. The rest of cmd/* (clef, faucet, devp2p, abigen…) is not used
  # on these nodes; building them only adds time and closure size.
  subPackages = [ "cmd/geth" ];

  # getc keeps the upstream module path (github.com/ethereum/go-ethereum), so the commit
  # is injected into `geth version` via this symbol (same as core-geth).
  ldflags = [
    "-s"
    "-w"
    "-X github.com/ethereum/go-ethereum/internal/version.gitCommit=${rev}"
  ];

  # The tree's consensus suites are long and require network access; the binary doesn't need them.
  doCheck = false;

  meta = {
    description = "go-ethereum-classic (getc) — geth fork for ETC (diega/go-ethereum-classic), build from source";
    homepage = "https://github.com/diega/go-ethereum-classic";
    license = lib.licenses.gpl3Plus;
    mainProgram = "geth";
    platforms = lib.platforms.linux;
  };
}
