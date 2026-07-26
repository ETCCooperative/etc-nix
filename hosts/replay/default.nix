# Ephemeral consensus-replay machine. Parametrized by `replayTarget` (passed via specialArgs in
# flake.nix): { client, network, packagePath, packageArgs?, endpoint, eraBucket?, influxUrl }. The
# archive/telemetry come from mkReplay's params (endpoint required, telemetry optional). One config
# serves any client×network combo. Deployed on demand via nixos-anywhere, re-executes the network's
# Era1 archive on boot, reports the verdict, then self-destructs (staged hook) or powers off.
{
  lib,
  pkgs,
  replayTarget,
  ...
}:
{
  imports = [
    ./disko.nix
    ./hardware.nix
    ../../modules/base.nix
    ../../modules/validation/consensus-replay.nix
  ];

  # Release-naming convention <client>-<network>-release-replay. The functional client/network keys
  # (core-geth/classic) still drive the package + module; only the display name is mapped.
  networking.hostName =
    let
      clientAbbrev = {
        "core-geth" = "cg";
        getc = "getc";
        besu = "besu";
        nethermind = "nm";
      };
      netName = {
        classic = "mainnet";
        mordor = "mordor";
      };
    in
    "${clientAbbrev.${replayTarget.client}}-${netName.${replayTarget.network}}-release-replay";
  # DO delivers networking through its config drive / metadata, not DHCP. cloud-init — the standard
  # mechanism the official DO images use — reads it and configures the interface via systemd-networkd,
  # so one config works for any VM without baking a per-VM IP.
  networking.useDHCP = lib.mkForce false;
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  etc.consensusReplay = {
    enable = true;
    inherit (replayTarget) client network;
    # any pkgs/ variant — binary or built-from-ref — chosen by packagePath/packageArgs.
    package = pkgs.callPackage replayTarget.packagePath (replayTarget.packageArgs or { });
    era = {
      inherit (replayTarget) endpoint;
    }
    # null → keep the module's "<network>-era1" default.
    // lib.optionalAttrs (replayTarget.eraBucket or null != null) { bucket = replayTarget.eraBucket; };
    release = replayTarget.release or "";
    # the DSN is staged here if given; the driver skips Bugsink if the file is absent.
    bugsink.dsnFile = "/var/lib/replay-secrets/bugsink_dsn";
    # Progress metric → InfluxDB (block-vs-time per client/network for the Grafana comparison).
    # "" (a downstream reproducer's default) disables it.
    influx.url = replayTarget.influxUrl or "";
  };

  networking.firewall.allowedTCPPorts = [ 22 ]; # ssh for debugging while it runs
}
