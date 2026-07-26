# devnet — private ETC chain from block 0 (tool)

Modules for a self-contained ETC devnet: the peering mesh (`mesh.nix` for multi-machine,
`netns-mesh.nix` to simulate it on one box) and the spamoor fuzzing daemon (`spamoor.nix`). Four
clients seal/follow from block 0 (current ETC rules, custom chain id) and are cross-checked on real
state transitions. The bundled example is `nixosConfigurations.example-devnet` (assembled by
`flake.nix`'s `mkDevnet` from `hosts/devnet` + the genesis in `assets/devnet`).

## Reproduce it yourself

```sh
nix flake init -t github:ETCCooperative/etc-nix#devnet
```

That gives a consumer flake that pins this repo and calls `lib.mkDevnet` with **your** chain id +
**your** generated mesh keys, then deploys with nixos-anywhere. Full walkthrough (key generation,
deploy, the netstats + spamoor dashboards): [`templates/devnet/README.md`](../../templates/devnet/README.md).
