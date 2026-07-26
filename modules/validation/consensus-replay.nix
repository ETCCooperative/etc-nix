# Consensus replay — an ephemeral machine's whole purpose. Re-executes every block in a network's
# Era1 archive (pulled from R2 one era at a time) to re-validate consensus with a chosen client
# binary, then powers off. See replay.sh for the mechanism.
#
# Reuses the existing client packages (binary OR built-from-ref) — the host passes `package`.
# Credentials are read from plain files (staged at machine creation via nixos-anywhere --extra-files), NOT
# sops: an ephemeral machine's age key doesn't exist when the secret would be encrypted.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.etc.consensusReplay;
  eraToRlp = pkgs.callPackage ../../pkgs/era-to-rlp { };
  defaultBin = {
    core-geth = "geth";
    getc = "geth";
    besu = "besu";
    nethermind = "nethermind";
  };
in
{
  options.etc.consensusReplay = {
    enable = lib.mkEnableOption "consensus replay (Era1 re-execution) one-shot";

    client = lib.mkOption {
      type = lib.types.enum [
        "core-geth"
        "getc"
        "besu"
        "nethermind"
      ];
      description = "Client whose binary re-executes the blocks.";
    };
    network = lib.mkOption {
      type = lib.types.enum [
        "classic"
        "mordor"
      ];
    };
    package = lib.mkOption {
      type = lib.types.package;
      description = "Client package (any existing pkgs/ variant: binary or built-from-ref).";
    };
    binaryName = lib.mkOption {
      type = lib.types.str;
      default = defaultBin.${cfg.client};
      defaultText = lib.literalExpression "geth|besu|nethermind by client";
      description = "Executable name inside `package`.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/replay";
      description = "Replay DB (holds the re-executed state as it grows across eras).";
    };
    workDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/replay/work";
      description = "Scratch for the one era (+ its rlp) being processed.";
    };
    cache = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2048;
    };
    fromEpoch = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = "First epoch to re-execute (default 0).";
    };
    toEpoch = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = "Last epoch (default: highest in the bucket).";
    };

    era = {
      bucket = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.network}-era1";
        defaultText = lib.literalExpression ''"<network>-era1"'';
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        example = "https://<account-id>.r2.cloudflarestorage.com";
        description = "R2 S3 endpoint (not secret).";
      };
      accessKeyIdFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/replay-secrets/r2_access_key_id";
        description = "File with the R2 read access key id (staged via --extra-files).";
      };
      secretAccessKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/replay-secrets/r2_secret_access_key";
      };
    };

    bugsink.dsnFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File with the Bugsink DSN for the failure verdict (optional).";
    };

    influx = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "InfluxDB v2 base URL for the progress metric (empty = disabled).";
      };
      org = lib.mkOption {
        type = lib.types.str;
        default = "geths";
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        default = "gethmetrics";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/replay-secrets/influx_token";
        description = "File with the InfluxDB write token (staged via --extra-files).";
      };
    };
    release = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Client version/ref recorded in the verdict.";
    };

    powerOffOnDone = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Power off when the replay finishes (ephemeral machine).";
    };
    startOnBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the replay automatically at boot.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.consensus-replay = {
      description = "Consensus replay: re-execute ${cfg.network} Era1 with ${cfg.client}";
      wantedBy = lib.mkIf cfg.startOnBoot [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        cfg.package
        eraToRlp
        pkgs.rclone
        pkgs.curl # verdict → Bugsink; the staged self-destruct hook may also use it
        pkgs.coreutils
        pkgs.gawk # besu's launcher shells out to awk (Java-version detection)
        pkgs.gnused
        pkgs.gnugrep
        config.systemd.package # systemctl poweroff
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root"; # needs poweroff; the client just re-executes into a throwaway datadir
        TimeoutStartSec = "infinity";
        Environment = [
          "CLIENT=${cfg.client}"
          "NETWORK=${cfg.network}"
          "CLIENT_BIN=${cfg.package}/bin/${cfg.binaryName}"
          "ERA2RLP=${eraToRlp}/bin/era-to-rlp"
          "DATADIR=${cfg.dataDir}"
          "WORKDIR=${cfg.workDir}"
          "CACHE=${toString cfg.cache}"
          "ERA_BUCKET=${cfg.era.bucket}"
          "R2_KEY_ID_FILE=${cfg.era.accessKeyIdFile}"
          "R2_SECRET_FILE=${cfg.era.secretAccessKeyFile}"
          "RCLONE_CONFIG=/dev/null"
          "RCLONE_CONFIG_R2_TYPE=s3"
          "RCLONE_CONFIG_R2_PROVIDER=Cloudflare"
          "RCLONE_CONFIG_R2_ENDPOINT=${cfg.era.endpoint}"
          "RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true"
          "INFLUX_URL=${cfg.influx.url}"
          "INFLUX_ORG=${cfg.influx.org}"
          "INFLUX_BUCKET=${cfg.influx.bucket}"
          "INFLUX_TOKEN_FILE=${cfg.influx.tokenFile}"
          "POWEROFF=${lib.boolToString cfg.powerOffOnDone}"
          "RELEASE=${cfg.release}"
        ]
        ++ lib.optional (cfg.bugsink.dsnFile != null) "BUGSINK_DSN_FILE=${cfg.bugsink.dsnFile}"
        ++ lib.optional (cfg.fromEpoch != null) "FROM_EPOCH=${toString cfg.fromEpoch}"
        ++ lib.optional (cfg.toEpoch != null) "TO_EPOCH=${toString cfg.toEpoch}"
        # glibc hoards the arena memory rocksdb frees between blocks during nethermind's offline Era
        # import, OOM-killing the process at the 2016 DoS blocks (~2.43M). jemalloc's background_thread
        # returns freed pages to the OS on a ~1s decay, holding peak RSS ~10.6 GB where glibc reaches
        # >14 GB → OOM. replay.sh applies these to the nethermind binary ONLY; rclone/bash keep glibc.
        ++ lib.optionals (cfg.client == "nethermind") [
          "NM_LD_PRELOAD=${pkgs.jemalloc}/lib/libjemalloc.so.2"
          "NM_MALLOC_CONF=background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:1000"
        ];
        ExecStart = "${pkgs.bash}/bin/bash ${./replay.sh}";
      };
    };
  };
}
