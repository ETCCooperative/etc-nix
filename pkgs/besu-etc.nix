# besu-etc = Hyperledger Besu (ETC fork) + the ETC plugin, built FROM SOURCE by replicating
# the diega/besu-etc-plugin release. Counterpart of pkgs/besu-etc-bin.nix (which fetches the
# CI-combined bundle): here the plugin jar is compiled locally and swapped into a fetched
# base bundle, so you can test an unreleased plugin branch without waiting for CI.
#
# SELF-CONTAINED — no Besu compiled from source. The fetched bundle already ships every jar
# the plugin needs that isn't on the public Maven repos it queries: the patched Besu modules
# and a couple of besu-pinned deps (tuweni, jackson-databind). We stage those from besu/lib
# into a project-local Maven repo (with minimal POMs — enough metadata for Gradle's
# variant-aware compileClasspath, which a flatDir repo can't satisfy). Everything else
# (auto-service, picocli, guava, slf4j, …) is fetched from the network — pinned by the Gradle
# mitmCache FOD (pkgs/besu-etc-deps.json).
#
# Shape (mirrors the release job, minus the Besu compile):
#   1. base    — fetch besu-etc-<tag>.tar.gz (patched Besu dist + a plugin jar in plugins/).
#   2. stage   — besu/lib jars → besu-local-repo (Maven layout) for the not-on-public deps.
#   3. plugin  — `gradle jar -PbesuVersion=<v> -PbuildVersion=<v> -x test` → besu-etc-plugin.jar.
#   4. combine — replace besu/plugins/besu-etc-plugin-*.jar with the freshly built one, wrap.
#
# Bumping: set pluginRev/besuVersion + pluginHash + bundleHash (nix store prefetch-file <url>),
# check slf4jVersion + the staged versions against the bundle, and regenerate the deps lock on
# a linux builder: `nix build .#besu-etc.mitmCache.updateScript -o upd && ./upd`.
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  gradle_9,
  jdk25_headless,
  jemalloc,
  makeWrapper,
  unzip,

  # --- plugin (compiled) ---
  pluginRev,
  pluginHash,

  # --- base bundle (fetch-release; besuVersion must match the bundle's jars) ---
  besuVersion,
  bundleRepo ? "diega/besu-etc-plugin",
  bundleTag ? besuVersion,
  bundleArtifact ? bundleTag,
  bundleUrl ? "https://github.com/${bundleRepo}/releases/download/${bundleTag}/besu-etc-${bundleArtifact}.tar.gz",
  bundleHash,

  # slf4j-api is declared WITHOUT a version in build.gradle (it normally comes from the Besu
  # BOM); pin it to the version the bundle ships (it's on Maven Central → comes via the FOD).
  slf4jVersion ? "2.0.17",

  # jackson-databind is used by the plugin (ClassicGenesisConfig) but at some tags (incl.
  # 26.6.1-etc) isn't declared in build.gradle — it came transitively from a Besu module whose
  # real POM our minimal POMs don't replicate. We declare jackson explicitly (databind + its
  # core/annotations transitives, which the minimal databind POM doesn't pull) and stage them;
  # pin to the versions the bundle ships (annotations trails databind/core: 2.21 vs 2.21.1).
  jacksonDatabindVersion ? "2.21.1",
  jacksonCoreVersion ? "2.21.1",
  jacksonAnnotationsVersion ? "2.21",

  # Runtime JVM. The 26.x-etc bundle is built with Java 25 (bytecode target 25) → runs on JDK 25.
  # NB: named runtimeJdk, NOT jdk — callPackage would auto-fill a `jdk` arg from pkgs.jdk (the
  # default JDK, currently 21), silently overriding the default and running Besu on the wrong JVM.
  runtimeJdk ? jdk25_headless,
}:
let
  # The plugin targets Java 25 (sourceCompatibility 25), so Gradle itself must run on a JDK 25
  # — else javac rejects `--source 25` ("invalid source release: 25").
  gradle25 = gradle_9.override { java = jdk25_headless; };

  bundle = fetchurl {
    url = bundleUrl;
    hash = bundleHash;
  };

  # Artifacts the plugin compiles against that aren't on the public repos it queries, staged
  # from the bundle's besu/lib jars (as besu/lib/<art>-<ver>.jar):
  #   - the patched Besu modules (org.hyperledger.besu[.internal]:*:${besuVersion}),
  #   - tuweni (io.consensys.tuweni, 2.7.2) — hidden by the consensys repo's tech.pegasys filter,
  #   - jackson-databind (com.fasterxml.jackson.core, 2.21.1) — the besu-pinned version isn't on
  #     Maven Central; the plugin declares it directly (ClassicGenesisConfig parses genesis JSON).
  localArtifacts = [
    {
      art = "besu-plugin-api";
      grp = "org.hyperledger.besu";
      ver = besuVersion;
    }
    {
      art = "besu-evm";
      grp = "org.hyperledger.besu";
      ver = besuVersion;
    }
    {
      art = "besu-datatypes";
      grp = "org.hyperledger.besu";
      ver = besuVersion;
    }
    {
      art = "besu-ethereum-core";
      grp = "org.hyperledger.besu.internal";
      ver = besuVersion;
    }
    {
      art = "besu-ethereum-rlp";
      grp = "org.hyperledger.besu.internal";
      ver = besuVersion;
    }
    {
      art = "besu-ethereum-eth";
      grp = "org.hyperledger.besu.internal";
      ver = besuVersion;
    }
    {
      art = "besu-ethereum-p2p";
      grp = "org.hyperledger.besu.internal";
      ver = besuVersion;
    }
    {
      art = "besu-config";
      grp = "org.hyperledger.besu.internal";
      ver = besuVersion;
    }
    {
      art = "besu-crypto-algorithms";
      grp = "org.hyperledger.besu.internal";
      ver = besuVersion;
    }
    {
      art = "besu-util";
      grp = "org.hyperledger.besu.internal";
      ver = besuVersion;
    }
    {
      art = "tuweni-bytes";
      grp = "io.consensys.tuweni";
      ver = "2.7.2";
    }
    {
      art = "tuweni-units";
      grp = "io.consensys.tuweni";
      ver = "2.7.2";
    }
    {
      art = "jackson-databind";
      grp = "com.fasterxml.jackson.core";
      ver = jacksonDatabindVersion;
    }
    {
      art = "jackson-core";
      grp = "com.fasterxml.jackson.core";
      ver = jacksonCoreVersion;
    }
    {
      art = "jackson-annotations";
      grp = "com.fasterxml.jackson.core";
      ver = jacksonAnnotationsVersion;
    }
  ];

  stageArtifact =
    {
      art,
      grp,
      ver,
    }:
    let
      groupPath = builtins.replaceStrings [ "." ] [ "/" ] grp;
      dir = "besu-local-repo/${groupPath}/${art}/${ver}";
    in
    ''
      mkdir -p ${dir}
      cp bundle/besu/lib/${art}-${ver}.jar ${dir}/${art}-${ver}.jar
      cat > ${dir}/${art}-${ver}.pom <<POM
      <project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>${grp}</groupId><artifactId>${art}</artifactId><version>${ver}</version><packaging>jar</packaging></project>
      POM
    '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "besu-etc";
  version = besuVersion;

  src = fetchFromGitHub {
    owner = "diega";
    repo = "besu-etc-plugin";
    rev = pluginRev;
    hash = pluginHash;
  };

  postPatch = ''
    # slf4j-api is version-less in build.gradle; pin it to the version the bundle ships.
    substituteInPlace build.gradle \
      --replace-fail "'org.slf4j:slf4j-api'" "'org.slf4j:slf4j-api:${slf4jVersion}'"

    # Drop the two Besu test-only deps (besu-testutil + the test-support classifier): they
    # aren't shipped in a runtime dist and aren't on public Maven, and we build `jar` (-x test).
    substituteInPlace build.gradle \
      --replace-fail 'testImplementation "org.hyperledger.besu.internal:besu-testutil:''${besuVersion}"' "" \
      --replace-fail 'testImplementation("org.hyperledger.besu.internal:besu-ethereum-core:''${besuVersion}:test-support")' ""

    # Resolve the staged artifacts from a project-local Maven repo (populated in preBuild).
    # Project-relative so it works both in the mitmCache generation and the real build.
    substituteInPlace build.gradle \
      --replace-fail 'mavenLocal()' 'mavenLocal()
    maven { url = uri("besu-local-repo") }'

    # Declare jackson explicitly (see the jacksonDatabindVersion note). Appended as a separate
    # dependencies block — Gradle merges them, and it's harmless if a newer tag already declares
    # them (duplicate deps are deduplicated).
    printf '\ndependencies {\n  implementation "com.fasterxml.jackson.core:jackson-databind:${jacksonDatabindVersion}"\n  implementation "com.fasterxml.jackson.core:jackson-core:${jacksonCoreVersion}"\n  implementation "com.fasterxml.jackson.core:jackson-annotations:${jacksonAnnotationsVersion}"\n}\n' >> build.gradle
  '';

  nativeBuildInputs = [
    gradle25
    makeWrapper
    unzip
  ];
  buildInputs = [ jemalloc ];

  mitmCache = gradle25.fetchDeps {
    pkg = finalAttrs.finalPackage;
    data = ./besu-etc-deps.json;
  };

  # Extract the base bundle and stage the not-on-public-Maven jars into the local repo. Runs
  # before Gradle in both the mitmCache generation and the real build.
  preBuild = ''
    mkdir -p besu-local-repo bundle
    tar xzf ${bundle} -C bundle
    # The published tarball carries macOS AppleDouble sidecars (._foo.jar); drop them so they
    # don't end up in plugins/ (Besu would try to load ._besu-etc-plugin.jar as a plugin).
    find bundle/besu -name '._*' -delete
    ${lib.concatStringsSep "\n" (map stageArtifact localArtifacts)}
  '';

  gradleFlags = [
    "-PbesuVersion=${besuVersion}"
    "-PbuildVersion=${besuVersion}"
    "-x"
    "test"
  ];
  gradleBuildTask = "jar";

  installPhase = ''
    runHook preInstall
    # Swap the freshly built plugin jar into the base bundle, then package + wrap it.
    rm -f bundle/besu/plugins/besu-etc-plugin-*.jar
    cp build/libs/besu-etc-plugin-*.jar bundle/besu/plugins/

    mkdir -p $out
    cp -r bundle/besu/bin bundle/besu/lib bundle/besu/plugins $out/
    wrapProgram $out/bin/besu \
      --set JAVA_HOME ${runtimeJdk} \
      --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ jemalloc ]}
    runHook postInstall
  '';

  meta = {
    description = "Hyperledger Besu ETC client (plugin built from source + fetched base bundle)";
    homepage = "https://github.com/diega/besu-etc-plugin";
    license = lib.licenses.asl20;
    mainProgram = "besu";
    platforms = [ "x86_64-linux" ];
  };
})
