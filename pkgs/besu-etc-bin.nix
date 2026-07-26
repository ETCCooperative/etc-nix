# besu-etc = Hyperledger Besu (fork diega/besu) + the ETC plugin, shipped as the prebuilt
# distribution the diega/besu-etc-plugin CI publishes (like pkgs/nethermind-etc-bin.nix —
# a released bundle, not built from source). Use this for the "test-besu" / release Besu
# node running an ETC plugin build. For the frozen last-upstream-with-ETC client, use
# pkgs/besu-legacy.nix; to build the ETC-plugin client from source, use pkgs/besu-etc.nix.
#
# The release workflow runs `gradlew installDist` on the Besu fork and drops the built
# besu-etc-plugin jar into `besu/plugins/`, then tars the result → the archive is a FULL
# Besu distribution (bin/ + lib/ + plugins/) rooted at `besu/`. Packaging therefore mirrors
# pkgs/besu-legacy.nix (unpack, keep bin/lib/plugins, wrap the launcher with JAVA_HOME + jemalloc
# on LD_LIBRARY_PATH — Besu extracts bundled JNI natives at runtime and links against these).
#
# Release naming (see diega/besu-etc-plugin .github/workflows/release.yml). The combined
# bundle asset is `besu-etc-<artifact>.tar.gz`, published on both diega/besu and
# diega/besu-etc-plugin:
#   - stable:       tag == artifact, e.g. "26.6.1-etc"
#   - pre-release:  tag == artifact, e.g. "26.7.0-etc-SNAPSHOT"
#   - experimental: artifact = "<tag>-<shortSHA>"
# so override `tag` and (for experimental builds) `artifact`. Get the hash with
# `nix store prefetch-file <url>`.
#
# JDK note: the 26.x-etc bundle is built with Java 25 (bytecode target 25) → it runs on
# JDK 25, so jdk25_headless is the default. besu-legacy (25.11) stays on JDK 21. If a future
# release changes its target JVM, pass `jdk = pkgs.<matching-jdk>`.
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  jemalloc,
  jdk25_headless,
  # NB: named runtimeJdk, NOT jdk — callPackage would auto-fill a `jdk` arg from pkgs.jdk (the
  # default JDK, currently 21), silently overriding the default and running Besu on the wrong JVM.
  runtimeJdk ? jdk25_headless,
  tag,
  artifact ? tag,
  url ? "https://github.com/diega/besu-etc-plugin/releases/download/${tag}/besu-etc-${artifact}.tar.gz",
  hash,
}:
stdenv.mkDerivation {
  pname = "besu-etc";
  version = artifact;

  src = fetchurl { inherit url hash; };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ jemalloc ];

  # The archive is rooted at `besu/` (bin/ lib/ plugins/).
  sourceRoot = "besu";

  installPhase = ''
    runHook preInstall
    # Drop macOS AppleDouble sidecars (._foo.jar) the tarball may carry, so Besu doesn't try
    # to load ._besu-etc-plugin.jar as a plugin.
    find . -name '._*' -delete
    mkdir -p $out
    cp -r bin lib plugins $out/
    wrapProgram $out/bin/besu \
      --set JAVA_HOME ${runtimeJdk} \
      --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ jemalloc ]}
    runHook postInstall
  '';

  meta = {
    description = "Hyperledger Besu with the ETC plugin (diega/besu-etc-plugin distribution)";
    homepage = "https://github.com/diega/besu-etc-plugin";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
    mainProgram = "besu";
    platforms = lib.platforms.linux;
  };
}
