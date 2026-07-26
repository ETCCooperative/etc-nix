# ETC consensus-replay experiment

Reproduce an Ethereum Classic chain re-execution with the client build of *your* choice,
without touching the [`etc-nix`](https://github.com/ETCCooperative/etc-nix) tool repo.
This flake pins that repo as an input and calls its `lib.mkReplay` factory; your experiment
lives here, in your flake.

```
nix flake init -t github:ETCCooperative/etc-nix#replay
```

## What goes where

- **This flake** pins one thing: *which client build* to re-execute with (`client`, `network`,
  and the client `packageArgs` — a version/ref + hashes). Change the ref → re-deploy. No commit
  to the tool repo, ever.
- **Runtime parameters** never live here. Stage them as plain files under
  `./secrets/var/lib/replay-secrets/` and `nixos-anywhere --extra-files ./secrets` copies them
  onto the box on install:
  - `r2_access_key_id`, `r2_secret_access_key` — read the Era1 archive
  - `self-destruct` — an executable (your cloud provider's teardown) run when the box finishes, so it
    deletes itself instead of billing idle; omit it and the box just powers off
  - `from_epoch` / `to_epoch` — optional, for a shorter run
  - `run_id`, `influx_token`, `fleet_size`, … — optional telemetry / fleet coordination

## Deploy

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#my-replay --extra-files ./secrets --build-on-remote root@<box-ip>

# watch it re-execute:
ssh root@<box-ip> journalctl -fu consensus-replay
```

`--build-on-remote` builds the system on the (x86_64-linux) box, so this works from macOS too.

## Getting the hashes

```sh
# srcHash
nix run nixpkgs#nix-prefetch-github -- <owner> core-geth --rev <rev>
# vendorHash: leave the placeholder, build, and paste the hash from the error:
nix build .#nixosConfigurations.my-replay.config.system.build.toplevel
```

## Other clients

`packagePath` + `packageArgs` select the client builder from the tool repo's `pkgs/`:

| client | `packagePath` | key `packageArgs` |
|---|---|---|
| core-geth | `${etc-nix}/pkgs/core-geth.nix` | `version, rev, srcHash, vendorHash` |
| getc | `${etc-nix}/pkgs/getc.nix` | `version, rev, srcHash, vendorHash` |
| nethermind | `${etc-nix}/pkgs/nethermind-etc.nix` | `pluginRev, version, …` |
| besu | `${etc-nix}/pkgs/besu-etc.nix` | `pluginRev, besuVersion, …` |

To replay a **fork** rather than a ref of the canonical client repo, override the client's
source — the `-bin.nix` variants take a published release, the from-source variants take
`owner`/`rev`. (First-class `--override-input` for client sources is a planned tool-repo change.)
