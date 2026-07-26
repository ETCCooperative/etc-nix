# getc = go-ethereum-classic (diega/go-ethereum-classic), a geth fork for ETC,
# shipped as a prebuilt linux-amd64 tarball (like pkgs/core-geth-bin.nix — a released
# binary, not built from source). The tarball is flat: a single `geth` ELF at the root.
#
# Parameterizable version/commit/hash for future bumps. NOTE: the release re-uses the
# same tag for rebuilds, so the asset's commit suffix can change under a fixed version;
# pin `gitCommit` + `hash` together. Get the hash with `nix store prefetch-file <url>`.
#
# Do NOT rename `gitCommit` back to `commit`: nixpkgs has a `commit` package, and
# callPackage would inject that derivation instead of this string default, mangling the
# URL into `.../geth-linux-amd64-1.17.3-etc.1-/nix/store/…-commit-4.5.tar.gz`.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
  version,
  # Republished under the same tag (2026-07-04) with a Mordor peering fix — new commit suffix.
  gitCommit,
  url ? "https://github.com/diega/go-ethereum-classic/releases/download/v${version}/geth-linux-amd64-${version}-${gitCommit}.tar.gz",
  hash,
}:
stdenv.mkDerivation {
  pname = "getc";
  inherit version;

  src = fetchurl { inherit url hash; };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
  ];

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 geth $out/bin/geth
    runHook postInstall
  '';

  meta = {
    description = "go-ethereum-classic (getc) — geth fork for ETC (diega/go-ethereum-classic)";
    homepage = "https://github.com/diega/go-ethereum-classic";
    license = lib.licenses.gpl3Plus;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "geth";
    platforms = [ "x86_64-linux" ];
  };
}
