# nethermind-etc = Nethermind + the ETC plugin, built FROM SOURCE by replicating the
# nethermind-etc-plugin release job. This is the counterpart of
# pkgs/nethermind-etc-bin.nix (which fetches the CI-published *combined* bundle): here the
# plugin is compiled locally and layered onto a fetched base Nethermind release, so you can
# test an unreleased plugin branch (or a patched base) without waiting for CI.
#
# Shape (mirrors the release workflow's build → create-bundles jobs):
#   1. plugin  — `dotnet publish` of src/Nethermind.EthereumClassic → Nethermind.EthereumClassic.dll.
#                Compiles against Nethermind.ReferenceAssemblies (NuGet), NOT Nethermind source.
#   2. base    — a published Nethermind release zip (fetch-release). Default is upstream
#                NethermindEth/nethermind; for a patched base point baseRepo/baseTag at the
#                diega/nethermind_etc fork's release (also published) — same fetch, different
#                repo/tag/hash. A from-source base build is not needed for Nethermind.
#   3. combine — drop the plugin dll into <base>/plugins, add chainspecs/ + configs/ from the
#                plugin tree, then autoPatchelf + wrap the apphost exactly like nethermind-etc-bin.
#
# Bumping:
#   - plugin: set pluginRev/version + pluginHash; regenerate nugetDeps with
#       `nix build .#nethermind-etc.plugin.fetch-deps && ./result nethermind-etc-deps.json` (or
#       the fetch-deps script path the build prints).
#   - base:   set baseRepo/baseVersion/baseCommit/baseArch + baseHash (nix store prefetch-file <url>).
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  buildDotnetModule,
  dotnet-sdk_10,
  autoPatchelfHook,
  makeWrapper,
  unzip,
  zlib,
  openssl,
  icu,
  snappy,

  # --- plugin (always compiled) ---
  pluginOwner ? "ETCCooperative",
  pluginRepo ? "nethermind-etc-plugin",
  pluginRev,
  version,
  pluginHash,
  nugetDeps ? ./nethermind-etc-deps.json,

  # --- base client (fetch-release; override repo/tag/hash for the patched fork) ---
  baseRepo ? "NethermindEth/nethermind",
  baseVersion ? "1.38.1",
  baseCommit ? "9c365772",
  baseArch ? "linux-x64",
  baseTag ? baseVersion,
  baseUrl ? "https://github.com/${baseRepo}/releases/download/${baseTag}/nethermind-${baseVersion}-${baseCommit}-${baseArch}.zip",
  baseHash ? "sha256-4/+VA32IImq0lJ3rqkFxGzuy7TDIQNuC9YJMvYHZtHM=",

  # Wire the shipped NLog-json.config (JSON-per-line error log → events.jsonl) into
  # NLog.config so etc.sentryReporter (file_jsonl) has a source (mirrors -bin).
  enableJsonErrorLog ? false,
}:
let
  pluginSrc = fetchFromGitHub {
    owner = pluginOwner;
    repo = pluginRepo;
    rev = pluginRev;
    hash = pluginHash;
  };

  # The plugin is a single library project → Nethermind.EthereumClassic.dll. buildDotnetModule
  # handles restore/build/publish + the NuGet dep FOD; it is not an executable, so no wrapper.
  plugin = buildDotnetModule {
    pname = "nethermind-etc-plugin";
    inherit version;
    src = pluginSrc;
    projectFile = "src/Nethermind.EthereumClassic/Nethermind.EthereumClassic.csproj";
    inherit nugetDeps;
    dotnet-sdk = dotnet-sdk_10;
    dotnet-runtime = dotnet-sdk_10;
    executables = [ ];
  };

  base = fetchurl {
    url = baseUrl;
    hash = baseHash;
  };
in
stdenv.mkDerivation {
  pname = "nethermind-etc";
  inherit version;

  # No single `src`: the base zip and the plugin come in via the unpack/install phases.
  dontUnpack = true;

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
    openssl
    icu
    snappy
  ];

  # The apphost self-extracts native libs it references at runtime; not ELF-visible here.
  autoPatchelfIgnoreMissingDeps = true;

  installPhase = ''
    runHook preInstall
    mkdir -p nethermind
    unzip -q ${base} -d nethermind

    # Integrate the plugin exactly like the release job's create-bundles step.
    cp ${plugin}/lib/nethermind-etc-plugin/Nethermind.EthereumClassic.dll nethermind/plugins/
    mkdir -p nethermind/chainspecs
    cp ${pluginSrc}/chainspecs/*.json nethermind/chainspecs/
    cp ${pluginSrc}/configs/*.cfg nethermind/configs/

    ${lib.optionalString enableJsonErrorLog ''
      substituteInPlace nethermind/NLog.config \
        --replace-fail '</nlog>' '  <include file="NLog-json.config" />
      </nlog>'
    ''}

    mkdir -p $out/nethermind $out/bin
    cp -r nethermind/. $out/nethermind/
    chmod +x $out/nethermind/nethermind $out/nethermind/Nethermind.Runner

    makeWrapper $out/nethermind/nethermind $out/bin/nethermind \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          stdenv.cc.cc.lib
          openssl
          icu
          zlib
          snappy
        ]
      }
    runHook postInstall
  '';

  passthru = { inherit plugin base; };

  meta = {
    description = "Nethermind Ethereum Classic client (plugin built from source + fetched base release)";
    homepage = "https://github.com/ETCCooperative/nethermind-etc-plugin";
    license = lib.licenses.lgpl3Plus;
    mainProgram = "nethermind";
    platforms = [ "x86_64-linux" ];
  };
}
