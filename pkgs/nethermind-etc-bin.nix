# nethermind-etc = Nethermind with the Ethereum Classic plugin, shipped
# as a prebuilt linux-x64 self-contained .NET bundle (like pkgs/besu-etc-bin.nix / core-geth-bin
# — a released binary, not built from source). Matches the version the Ansible nodes run
# (1.37.2.0) so the reused chain DB on the data volume stays compatible.
#
# The apphost (`nethermind` / `Nethermind.Runner`, same ELF) is a .NET single-file
# bundle ("singlefilehost"): the runtime + managed DLLs + native libs are embedded and
# self-extracted at RUNTIME to $DOTNET_BUNDLE_EXTRACT_BASE_DIR — so there are no .so
# files in the tree, and autoPatchelf only patches the apphost ELF (which links the
# usual libc/libstdc++/libgcc/... satisfied by stdenv.cc.cc.lib). The extracted native
# libs (System.Native, OpenSSL, ICU, …) resolve THEIR deps via LD_LIBRARY_PATH set on
# the wrapper. DOTNET_BUNDLE_EXTRACT_BASE_DIR must be writable — the systemd unit points
# it at a cache dir; a bare `nethermind --version` uses the default (~/.net) fine.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  makeWrapper,
  zlib,
  openssl,
  icu,
  snappy,
  version,
  url ? "https://github.com/ETCCooperative/nethermind-etc-plugin/releases/download/v${version}/nethermind-etc-v${version}-linux-x64.zip",
  hash,
  # Wire the shipped NLog-json.config (JSON-per-line error log → events.jsonl) into
  # NLog.config, so etc.sentryReporter (file_jsonl) has a source. Mirrors the
  # Ansible role's opt-in `<include>` when nethermind_json_logs_enabled.
  enableJsonErrorLog ? false,
}:
stdenv.mkDerivation {
  pname = "nethermind-etc";
  inherit version;

  src = fetchurl { inherit url hash; };

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

  # The single-file bundle references native libs it self-extracts at runtime; those are
  # not ELF-visible here, so don't fail the build on them — LD_LIBRARY_PATH covers them.
  autoPatchelfIgnoreMissingDeps = true;

  unpackPhase = ''
    runHook preUnpack
    mkdir -p nethermind
    unzip -q $src -d nethermind
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/nethermind $out/bin
    cp -r nethermind/. $out/nethermind/
    chmod +x $out/nethermind/nethermind $out/nethermind/Nethermind.Runner

    ${lib.optionalString enableJsonErrorLog ''
      # NLog resolves <include> relative to NLog.config's own directory ($out/nethermind),
      # where NLog-json.config also lives → the JSON error target is picked up.
      substituteInPlace $out/nethermind/NLog.config \
        --replace-fail '</nlog>' '  <include file="NLog-json.config" />
      </nlog>'
    ''}

    # Wrap the launcher: native libs the bundle extracts at runtime find their deps via
    # LD_LIBRARY_PATH. The apphost resolves configs/chainspecs/plugins relative to its
    # own directory ($out/nethermind), so no --chdir is needed.
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

  meta = {
    description = "Nethermind Ethereum Classic client (self-contained build)";
    homepage = "https://github.com/ETCCooperative/nethermind-etc-plugin";
    license = lib.licenses.lgpl3Plus; # Nethermind is LGPL-3.0-only
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "nethermind";
    platforms = [ "x86_64-linux" ];
  };
}
