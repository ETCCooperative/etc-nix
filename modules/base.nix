# Base module shared by ALL hosts (swapfile, users, sysctl, sshd) + bootstrap for a KVM cloud.
{
  lib,
  pkgs,
  modulesPath,
  # Authorized SSH keys for the admin (wheel) account. The consumer passes its own — a standing
  # deployment via its own config, a reproducer via theirs — so the tool ships no operator keys.
  # mkReplay/mkDevnet thread this through; empty (default) = only whoever provisioned the box can
  # reach it (nixos-anywhere's root key).
  sshKeys ? [ ],
  ...
}:
{
  # ── Boot / hardware (cloud VM = KVM/virtio, BIOS/GRUB) ──────────
  # Every host is an identical cloud VM (KVM guest, BIOS/GRUB, virtio), so the
  # QEMU-guest profile + virtio module set live here, not in a per-host
  # hardware-configuration.nix. The boot disk is registered by disko (the host's
  # EF02 partition) — disk topology stays per-host.
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "sd_mod"
    "sr_mod"
  ];

  # ── Network ───────────────────────────────────────────────────────────────────
  # DO provides the public IP via DHCP. The hostname is set per-host.
  networking.useDHCP = lib.mkDefault true;

  # ── Users ────────────────────────────────────────────────────────────────────
  # A single admin (wheel) account; its authorized SSH keys come from the consumer via `sshKeys`
  # (see the module header). No operator identities are baked into the tool.
  users.mutableUsers = false;
  # sshKeys may be empty (the tool ships none) — the provisioner reaches the box via nixos-anywhere's
  # install key. Allow that instead of failing the "you'll be locked out" assertion.
  users.allowNoPasswordLogin = true;
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "systemd-journal"
    ];
    openssh.authorizedKeys.keys = sshKeys;
  };
  security.sudo.wheelNeedsPassword = false;

  # ── SSH ──────────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      # nixos-anywhere connects as root with a key; after bootstrap the
      # operators use their normal accounts (wheel).
      PermitRootLogin = "prohibit-password";
    };
  };

  # ── Swap 1G (swap_file_size: 1G) ─────────────────────────────────────────────
  swapDevices = [
    {
      device = "/var/swapfile";
      size = 1024; # MiB
    }
  ];

  # ── UDP/QUIC tuning (roles/linux/tasks/main.yml) ─────────────────────────────
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 2500000;
    "net.core.wmem_max" = 2500000;
  };

  # ── Base packages (inventory/group_vars/all/apt.yml) ─────────────────────────
  environment.systemPackages = with pkgs; [
    # build-essential ≈ gcc + make + libc headers
    gcc
    gnumake
    bashInteractive
    libyaml
    git
    wget
    unzip
    gzip
    rsync
    htop
    tmux
    tree
    silver-searcher # provides `ag`
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # All cloud VMs are x86_64.
  nixpkgs.hostPlatform = "x86_64-linux";

  time.timeZone = "UTC";
  system.stateVersion = "25.11";
}
