# ETC devnet from block 0

Spin up your own private Ethereum Classic chain from block 0 — current ETC consensus rules, a
custom chain id, four clients (core-geth miner + getc / Nethermind / besu-legacy followers) in a WireGuard
mesh, an eth-netstats dashboard, and the spamoor fuzzing group (evm-fuzz + tx-fuzz +
tx-fuzz-invalid) so the clients are cross-checked on real state transitions. Reproduced from your
own flake, without touching the [`etc-nix`](https://github.com/ETCCooperative/etc-nix) repo.

```
nix flake init -t github:ETCCooperative/etc-nix#devnet
```

## 1. Generate the keys (once)

Everything below is a *public* value you paste into `flake.nix`, plus a *private* half you stage
onto the box. Nothing secret is committed.

```sh
mkdir -p secrets/var/lib/devnet-secrets && cd secrets/var/lib/devnet-secrets

# 4 WireGuard keypairs (one per client). Keep the .key files; paste the .pub into flake.nix.
for n in miner nethermind getc besu; do
  wg genkey | tee wg-$n.key | wg pubkey > wg-$n.pub
done

# The miner's devp2p node key + the coinbase key + the shared ethstats secret.
openssl rand -hex 32 > nodekey
openssl rand -hex 32 > coinbase_key
openssl rand -hex 16 > ethstats_secret
chmod 0644 *   # readable by the services; the box is ephemeral
cd -
```

Derive the **miner enode** from the node key (its uncompressed secp256k1 pubkey, minus the `0x04`
prefix, at the miner's mesh overlay IP):

```sh
nix-shell -p "python3.withPackages (ps: [ ps.coincurve ])" --run '
python3 - <<PY
import coincurve
sk = bytes.fromhex(open("secrets/var/lib/devnet-secrets/nodekey").read().strip())
pub = coincurve.PublicKey.from_secret(sk).format(compressed=False)[1:].hex()
print("enode://" + pub + "@10.99.0.11:30303")
PY'
```

## 2. Fill in `flake.nix`

- `minerEnode` ← the `enode://…` printed above
- `meshPublicKeys.{miner,nethermind,getc,besu}` ← the contents of each `wg-<name>.pub`
- `networkName`, `chainId` ← your choice (`genesisHash` stays as-is unless you edit the genesis assets)

## 3. Deploy

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#my-devnet --extra-files ./secrets --build-on-remote root@<box-ip>
```

An 8-vCPU / 16 GB box is comfortable (4 clients + DAG + JVM). The four clients seal/follow from
block 0; give it a couple of minutes for the etchash DAG.

## 4. Look at it

- **netstats**: `http://<box-ip>:3000` — the four clients advancing in lockstep
- **spamoor**: `http://<box-ip>:8080` — the fuzzing group; a consensus divergence shows up as a
  head-hash split in netstats (the live chain is the differential oracle)

## Notes

- The genesis is deliberately **pre-London** (no EIP-1559 / BASEFEE), matching ETC. The spamoor
  fuzzers are adapted to legacy/type-1 txs for exactly this reason.
- To iterate a *new* consensus, point the client packages at a ref that implements it and activate
  the fork in the genesis assets — the modules don't change. (A first-class client-source override
  is a planned tool-repo change.)
- `private` keys never leave `./secrets`; delete it once the box is up.
