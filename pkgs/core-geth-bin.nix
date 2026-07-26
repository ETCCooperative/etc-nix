# core-geth from an already-released binary (does NOT compile) — mirror of
# roles/coregeth/tasks/download-release.yml.
#
# BIN mode: downloads the release/pre-release artifact and patches it for NixOS.
# Useful for running the latest stable release or testing a pre-release without
# compiling. To test a branch/PR without a release, use pkgs/core-geth.nix (build).
#
# Parameterized to point at any release (including forks/pre-releases):
#   pkgs.callPackage ./pkgs/core-geth-bin.nix {
#     version = "1.12.22";
#     # default url = official etclabscore/core-geth release (zip).
#     hash = "sha256-...";  # `nix store prefetch-file <url>` to obtain it.
#   }
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  zlib,
  version,
  url ? "https://github.com/etclabscore/core-geth/releases/download/v${version}/core-geth-linux-v${version}.zip",
  hash,
}:
stdenv.mkDerivation {
  pname = "core-geth-bin";
  inherit version;

  src = fetchurl { inherit url hash; };

  nativeBuildInputs = [
    unzip
    autoPatchelfHook # rewrites the release binary's interpreter/rpath for NixOS
  ];
  # In case the binary uses CGO (libstdc++/zlib); if it were 100% static, this is a no-op.
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
  ];

  # The official core-geth zip ships `geth` at the root (no subdir).
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 geth $out/bin/geth
    runHook postInstall
  '';

  meta = {
    description = "Ethereum Classic Go client (etclabscore/core-geth), release binary";
    homepage = "https://github.com/etclabscore/core-geth";
    license = lib.licenses.gpl3Plus;
    mainProgram = "geth";
    platforms = lib.platforms.linux;
  };
}
