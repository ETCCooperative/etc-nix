{
  description = "etc-nix — reusable ETC client builds + replay/devnet experiment tooling (agnostic)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    # mkReplay/mkDevnet stage secrets via sops-nix on the target; disko partitions it.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
      treefmt-nix,
      ...
    }@inputs:
    let
      devSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs devSystems (s: f nixpkgs.legacyPackages.${s});

      # Client REFERENCE builds the tool ships (explicit versions; the builders have no default).
      # A consumer that wants a different ref calls pkgs/<client>.nix with it (via lib.mkReplay /
      # the templates) or overrides these.
      clientPkgs = pkgs: {
        core-geth-bin = pkgs.callPackage ./pkgs/core-geth-bin.nix {
          version = "1.12.22";
          hash = "sha256-4SKjRwGGydMqTeHsfURNNpLf1FFnMql/gHgfysSAqT4=";
        };
        getc-bin = pkgs.callPackage ./pkgs/getc-bin.nix {
          version = "1.17.4-etc.1";
          gitCommit = "8c438c8f";
          hash = "sha256-rTtv04Eu58rph9XtBjdtnwNoIdSgyouBAO69PM5Edu8=";
        };
        nethermind-etc-bin = pkgs.callPackage ./pkgs/nethermind-etc-bin.nix {
          version = "1.38.1.1";
          hash = "sha256-9HEDH0zrojxSkXXW6VztarMPESlvNbXcypKwoabNZc4=";
        };
        besu-etc-bin = pkgs.callPackage ./pkgs/besu-etc-bin.nix {
          tag = "26.6.1-etc";
          hash = "sha256-DvLCSqVZrR+nz6+OyUkheyIOSELywztnUvcCrATqA4w=";
        };
        besu-legacy = pkgs.callPackage ./pkgs/besu-legacy.nix {
          version = "25.11.0";
          hash = "sha256-04Uzu0wC3RNj3fSFUroqyqv57H2v3iCDk7Q62/63CUY=";
        };
        etc-getwork-miner = pkgs.callPackage ./pkgs/etc-getwork-miner { };
      };

      # The agnostic factories. No archive/telemetry baked in here — the caller passes `endpoint`
      # (its own S3/R2) and, optionally, `influxUrl`.
      mkReplay =
        {
          client,
          network,
          packagePath,
          packageArgs ? { },
          endpoint,
          eraBucket ? null,
          influxUrl ? "",
          sshKeys ? [ ], # authorized keys for the box's admin account (base.nix); consumer-supplied
        }:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit inputs sshKeys;
            replayTarget = {
              inherit
                client
                network
                packagePath
                packageArgs
                endpoint
                eraBucket
                influxUrl
                ;
            };
          };
          modules = [
            sops-nix.nixosModules.sops
            inputs.disko.nixosModules.disko
            ./hosts/replay
          ];
        };

      mkDevnet =
        {
          networkName,
          chainId,
          networkId ? chainId,
          genesisHash,
          minerEnode,
          meshPublicKeys,
          sshKeys ? [ ], # authorized keys for the box's admin account (base.nix); consumer-supplied
        }:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit inputs sshKeys;
            devnetTarget = {
              inherit
                networkName
                chainId
                networkId
                genesisHash
                minerEnode
                meshPublicKeys
                ;
            };
          };
          modules = [
            sops-nix.nixosModules.sops
            inputs.disko.nixosModules.disko
            ./hosts/devnet
          ];
        };

      treefmtFor =
        pkgs:
        treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
          programs.statix.enable = true;
          programs.deadnix.enable = true;
        };
    in
    {
      # ── the tool's public API ──────────────────────────────────────────────────────────
      lib = { inherit mkReplay mkDevnet; };

      nixosModules = {
        coreGeth = ./modules/clients/core-geth.nix;
        nethermind = ./modules/clients/nethermind.nix;
        besu = ./modules/clients/besu.nix;
        consensusReplay = ./modules/validation/consensus-replay.nix;
        devnetMesh = ./modules/devnet/mesh.nix;
        devnetNetnsMesh = ./modules/devnet/netns-mesh.nix;
        spamoor = ./modules/devnet/spamoor.nix;
        ethNetstats = ./modules/monitoring/eth-netstats.nix;
        ethstatsHashrateProxy = ./modules/monitoring/ethstats-hashrate-proxy.nix;
      };

      # Example instances — how a consumer calls the factories, and a build smoke-test for CI.
      nixosConfigurations.example-replay = mkReplay {
        client = "core-geth";
        network = "classic";
        packagePath = ./pkgs/core-geth-bin.nix;
        packageArgs = {
          version = "1.12.22";
          hash = "sha256-4SKjRwGGydMqTeHsfURNNpLf1FFnMql/gHgfysSAqT4=";
        };
        endpoint = "https://s3.example.org";
      };
      nixosConfigurations.example-devnet = mkDevnet {
        networkName = "example";
        chainId = 133761;
        genesisHash = "0x12cc331b39571efd31c02c73e2eda6a5fb691aedbb68120ef8b1629b93024cd9";
        minerEnode = "enode://0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000@10.99.0.11:30303";
        meshPublicKeys = {
          miner = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          nethermind = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          getc = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          besu = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      };

      packages = forAllSystems clientPkgs;
      overlays.default = final: _prev: clientPkgs final;

      templates.replay = {
        path = ./templates/replay;
        description = "ETC consensus-replay experiment";
      };
      templates.devnet = {
        path = ./templates/devnet;
        description = "ETC devnet from block 0";
      };
      templates.default = self.templates.replay;

      formatter = forAllSystems (pkgs: (treefmtFor pkgs).config.build.wrapper);
      checks = forAllSystems (pkgs: {
        formatting = (treefmtFor pkgs).config.build.check self;
      });
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nixfmt-rfc-style
            pkgs.statix
            pkgs.deadnix
          ];
        };
      });
    };
}
