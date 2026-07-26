# eth-netstats — the ethstats dashboard SERVER (not the agent). Old Node app
# (2016, declares node 0.12; ran on node v12 on the former eth_stats box).
#
# ⚠️ The most fragile package in the repo. Caveats to validate in the builder:
#  - The repo does NOT commit package-lock (it was untracked on the box) → we vendor it.
#  - `geoip-lite` downloads MaxMind data in postinstall (network) → `--ignore-scripts`
#    (the geo features end up degraded; acceptable for the dashboard).
#  - The upstream repo ships no pre-built dist/ (the grunt output); we compile it in a
#    preInstall grunt phase (grunt is a regular dep, already in node_modules) — see there.
#  - Modern geth agents report block.number as a hex string, which crashes this 2016
#    app on a cold start — patched in postPatch below (this was long misattributed to
#    the Node version; it is not — see the comment there).
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  nodejs_20, # build (npm) and runtime — see postInstall
  rev ? "f556b55aa848e165a80175fb4af42290275048a1", # ethereum/eth-netstats fork (the classic one)
  hash ? "sha256-44JkZRWhKPJ64wrqvWxNhVEm2S/aQms/ydb1EibSSzc=",
  npmDepsHash ? "sha256-Z24+5cHBfz/63QvZa3PqaAh45LWVm+NQM8h/0wGT6F4=",
}:
buildNpmPackage {
  pname = "eth-netstats";
  version = "0.0.9-unstable-${builtins.substring 0 7 rev}";

  # Build and run on Node 20. An earlier theory blamed Node's V8 for an "invalid table
  # size" OOM under the agent reconnect storm and pinned the runtime to Node 12; that was
  # a misdiagnosis — the app crashes on Node 12 just the same. The real cause is hex-string
  # block numbers (see postPatch); with that fixed, Node 20 is stable. There are no native
  # modules (--ignore-scripts), so this single node handles both build and runtime.
  nodejs = nodejs_20;
  inherit npmDepsHash;

  src = fetchFromGitHub {
    owner = "ethereum";
    repo = "eth-netstats";
    inherit rev hash;
  };

  postPatch = ''
    # The lock is versioned in this dir (captured from the box, untracked over there).
    cp ${./package-lock.json} package-lock.json

    # Modern geth/ethstats agents report block.number as a hex string ("0x17b5f66").
    # History.getHistoryRequestRange() computes `best + 1` on the max block height; with a
    # hex-string height that string-CONCATENATES ("0x17b5f66" + 1 → "0x17b5f661"), which
    # _.range() then coerces to a ~400-million number and tries to allocate as an array →
    # V8 "FATAL ERROR: invalid table size". It only fires on a cold start (history below
    # MAX_HISTORY, so requiresUpdate() is true and history gets requested); the former
    # eth_stats box survived for years only because it was never restarted — its in-memory
    # history stayed full/"warm", so getHistoryRequestRange was never reached. Coercing the
    # heights to numbers keeps the arithmetic numeric and the range bounded to MAX_HISTORY.
    substituteInPlace lib/history.js \
      --replace-fail "var blocks = _.pluck( this._items, 'height' );" \
                     "var blocks = _.map( _.pluck( this._items, 'height' ), Number );"
  '';

  # Skip lifecycle scripts (geoip-lite postinstall downloads data over the network).
  npmFlags = [ "--ignore-scripts" ];

  # No npm "build" script exists; the dashboard frontend is compiled by grunt. grunt and
  # its plugins are regular dependencies (already in node_modules), so grunt's CLI is
  # invoked programmatically below — grunt-cli (which only ships the `grunt` binary) is
  # not needed. The `all` task builds dist/ + dist-lite/ (concat/uglify/cssmin/jade) and
  # is fully offline: the front-end libs are vendored upstream in src/js/lib.
  dontNpmBuild = true;

  # Compile dist/ + dist-lite/ before the install phase copies the tree to $out. Without
  # them the page still renders (from the jade view) but the node grid and charts 404 on
  # the missing /js/netstats.min.js + /css/netstats.min.css bundles.
  preInstall = ''
    node -e 'process.argv = [ process.argv[0], "grunt", "all" ]; require("grunt").cli()'
  '';

  nativeBuildInputs = [ makeWrapper ];

  # Bin that starts the server. WITHOUT --chdir: the app writes propagation-data.txt
  # in its CWD; if the CWD were the store (read-only) it would crash with EROFS. The
  # systemd module sets WorkingDirectory+StateDirectory to a writable dir. www is
  # invoked by absolute path → the require() calls still resolve from the store.
  postInstall = ''
    # The install phase (npm pack) honours the upstream .gitignore, which excludes dist/,
    # so copy the grunt output (built in preInstall) into the store package explicitly.
    cp -r dist dist-lite $out/lib/node_modules/eth-netstats/

    makeWrapper ${nodejs_20}/bin/node $out/bin/eth-netstats \
      --add-flags "$out/lib/node_modules/eth-netstats/bin/www"
  '';

  meta = {
    description = "Ethereum Network Intelligence dashboard (ethstats server)";
    homepage = "https://github.com/ethereum/eth-netstats";
    license = lib.licenses.lgpl3Only;
    mainProgram = "eth-netstats";
    platforms = lib.platforms.linux;
  };
}
