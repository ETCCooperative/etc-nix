# etc-nix

Reusable Nix builds of the Ethereum Classic clients (core-geth, getc, Nethermind, Besu) plus two
experiment factories:

- **`lib.mkReplay`** — a consensus-replay machine: feed a client an Era1 archive and re-execute the
  chain, checking it against the canonical state.
- **`lib.mkDevnet`** — a private ETC chain **from block 0** (current ETC consensus rules on a custom
  chain id): a core-geth miner + getc/Nethermind/Besu followers in a WireGuard/netns mesh, an
  eth-netstats dashboard, and the spamoor "Fuzzing" group cross-checking the clients on real state
  transitions.

## Use it

```
nix flake init -t github:ETCCooperative/etc-nix#replay   # or #devnet
```

The template pins this flake and calls the factory with your own client ref / chain params /
archive endpoint. Run parameters (block ranges, credentials, keys) stay runtime (`--extra-files`),
never a commit. See `nixosConfigurations.example-{replay,devnet}` for a worked call.

## Outputs

- `lib.{mkReplay,mkDevnet}`
- `nixosModules.{coreGeth,nethermind,besu,consensusReplay,devnetMesh,devnetNetnsMesh,spamoor,ethNetstats,ethstatsHashrateProxy}`
- `packages` / `overlays.default` — the pinned reference client builds
- `templates.{replay,devnet}`, `apps.replay`
