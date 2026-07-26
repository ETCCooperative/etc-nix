{
  description = "ETC devnet from block 0 — your own private ETC chain + cross-client differential fuzzing";

  inputs = {
    # The reusable tool. Pin a tag/commit for a reproducible devnet.
    etc-nix.url = "github:ETCCooperative/etc-nix";
    nixpkgs.follows = "etc-nix/nixpkgs";
  };

  outputs =
    { etc-nix, ... }:
    {
      # Deploy (builds on the box, so it works from macOS too):
      #   nix run github:nix-community/nixos-anywhere -- \
      #     --flake .#my-devnet --extra-files ./secrets --build-on-remote root@<ip>
      # Generate the keys and stage the private halves under ./secrets FIRST — see README.md.
      nixosConfigurations.my-devnet = etc-nix.lib.mkDevnet {
        networkName = "my-devnet";
        chainId = 133761; # pick one that is NOT a well-known chain id

        # The from-block-0 ETC genesis hash. It is chainId-INDEPENDENT (chainId is not in the
        # header), so keep this value even if you change chainId above — it only changes if you
        # edit the committed genesis assets (e.g. a non-empty alloc or different rules).
        genesisHash = "0x12cc331b39571efd31c02c73e2eda6a5fb691aedbb68120ef8b1629b93024cd9";

        # Derived from YOUR generated keys (see README). The private halves are staged at runtime;
        # only these public values live here.
        minerEnode = "enode://REPLACE_128_HEX_MINER_NODEKEY_PUBKEY@10.99.0.11:30303";
        meshPublicKeys = {
          miner = "REPLACE_WG_PUBKEY_miner";
          nethermind = "REPLACE_WG_PUBKEY_nethermind";
          getc = "REPLACE_WG_PUBKEY_getc";
          besu = "REPLACE_WG_PUBKEY_besu";
        };
        sshKeys = [ "ssh-ed25519 AAAA... you@host" ]; # your keys for the boxes' admin login
      };
    };
}
