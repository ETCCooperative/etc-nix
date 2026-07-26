# consensus-replay (tool)

Re-execute a network's Era1 archive with a chosen client build and verify it stays in consensus.
`consensus-replay.nix` is the one-shot NixOS module; `replay.sh` is its driver. The bundled example
is `nixosConfigurations.example-replay` (assembled by `flake.nix`'s `mkReplay` from `hosts/replay`).

## Reproduce it yourself

```sh
nix flake init -t github:ETCCooperative/etc-nix#replay
```

That gives a tiny consumer flake that pins this repo and calls `lib.mkReplay` with **your** client
ref + **your** archive (Era1 in any S3/R2). Deploy it with `nixos-anywhere`, staging the run
parameters (block range, creds) under `--extra-files` — never committed. Full walkthrough: [`templates/replay/README.md`](../../templates/replay/README.md).
