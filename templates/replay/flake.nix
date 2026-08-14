{
  description = "ETC consensus-replay experiment — re-execute a chain with your own client build";

  inputs = {
    # The reusable tool. Pin a tag/commit for a reproducible experiment.
    etc-nix.url = "github:ETCCooperative/etc-nix";
    # Reuse the tool's pinned nixpkgs so your run is bit-for-bit comparable.
    nixpkgs.follows = "etc-nix/nixpkgs";
    # Only needed to build core-geth FROM SOURCE: it pulls in fjl/memsize, which reaches
    # runtime.stopTheWorld through //go:linkname — something the Go linker has rejected
    # since 1.23, and the tool's nixpkgs packages nothing older. Drop this input if you
    # point packagePath at a *-bin.nix builder, or at getc (which has no such dependency).
    nixpkgs-go121.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs =
    { etc-nix, nixpkgs-go121, ... }:
    {
      # Deploy (builds on the box, so it works from macOS too):
      #   nix run github:nix-community/nixos-anywhere -- \
      #     --flake .#my-replay --extra-files ./secrets --build-on-remote root@<ip>
      #
      # Run PARAMETERS live at RUNTIME, never in this flake: stage them under
      # ./secrets/var/lib/replay-secrets/ and --extra-files copies them onto the box —
      #   r2_access_key_id, r2_secret_access_key   (read the archive)
      #   self-destruct                            (executable: your provider's teardown; else poweroff)
      #   from_epoch, to_epoch                     (optional: a shorter range)
      #   run_id, influx_token, …                  (optional: telemetry/fleet)
      # The ONLY thing this flake pins is WHICH client build to re-execute with.
      nixosConfigurations.my-replay = etc-nix.lib.mkReplay {
        client = "core-geth"; # core-geth | getc | nethermind | besu
        network = "classic"; # classic | mordor

        # YOUR archive (Cloudflare R2 / any S3). The read creds go in at runtime (see above); this
        # is just the non-secret endpoint + bucket (required — the factory has no default).
        endpoint = "https://<your-account-id>.r2.cloudflarestorage.com";
        eraBucket = "classic-era1"; # your bucket of Era1 files; null keeps the "<network>-era1" default
        influxUrl = ""; # "" = no progress metric; set your own InfluxDB v2 URL to enable it
        sshKeys = [ "ssh-ed25519 AAAA... you@host" ]; # your keys for the box's admin login

        # Build the client from source at YOUR ref. core-geth and getc share this arg shape.
        # For nethermind/besu, point packagePath at their builder and use their args instead
        # (pluginRev/version for nethermind-etc; pluginRev/besuVersion for besu-etc — see README).
        packagePath = "${etc-nix}/pkgs/core-geth.nix";
        packageArgs = {
          # Required for the from-source Go builders — see the nixpkgs-go121 input above.
          buildGoModule = nixpkgs-go121.legacyPackages.x86_64-linux.buildGo121Module;
          version = "my-branch"; # informational; also the default rev (v${version}) when rev unset
          rev = "0000000000000000000000000000000000000000";
          # srcHash:    nix run nixpkgs#nix-prefetch-github -- <owner> core-geth --rev <rev>
          # vendorHash: leave as-is, `nix build .#nixosConfigurations.my-replay.config.system.build.toplevel`,
          #             then paste the hash the build error reports.
          srcHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      };
    };
}
