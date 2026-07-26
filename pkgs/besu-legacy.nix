# besu-legacy = Hyperledger Besu 25.x — the LAST upstream Besu that shipped native ETC
# support (classic/mordor built in). Upstream dropped native ETC afterward, which is why
# the ETC client now lives as the diega/besu-etc-plugin fork — built from source by
# pkgs/besu-etc.nix (replicates the plugin's release job) or fetched via pkgs/besu-etc-bin.nix
# (the CI release). This packages that frozen pre-divergence upstream release; keep it for
# hosts still on the old client (e.g. besu-mordor-release-mining).
#
# Parameterized like pkgs/core-geth-bin.nix — override `version`/`hash` for a specific
# release, and `jdk` for the JVM. Besu bundles/targets a specific OpenJDK per release (the
# release string is e.g. `openjdk-java-21`); pin the matching JDK here so the client runs
# on the JVM it was validated against. 25.11.0 → Java 21.
#
# Packaging mirrors nixpkgs' besu: unpack the generic distribution and wrap the gradle
# launcher with JAVA_HOME + jemalloc on LD_LIBRARY_PATH (Besu extracts its bundled JNI
# natives — rocksdb/secp256k1/netty — at runtime and links against these).
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  jemalloc,
  jdk21_headless,
  jdk ? jdk21_headless,
  version,
  hash,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "besu-legacy";
  inherit version;

  src = fetchurl {
    url = "https://github.com/hyperledger/besu/releases/download/${finalAttrs.version}/besu-${finalAttrs.version}.tar.gz";
    inherit hash;
  };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ jemalloc ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r bin lib $out/
    wrapProgram $out/bin/besu \
      --set JAVA_HOME ${jdk} \
      --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ jemalloc ]}
    runHook postInstall
  '';

  meta = {
    description = "Hyperledger Besu Ethereum client (ETC classic/mordor capable)";
    homepage = "https://www.hyperledger.org/projects/besu";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
    mainProgram = "besu";
    platforms = lib.platforms.linux;
  };
})
