# Deploying a node: what bites

Traps hit while putting a client from this flake on a real machine, observed on throwaway
VMs running core-geth on mordor. Each one is filed under what you actually see, because the
cause is not guessable from the symptom.

| what you see | section |
|---|---|
| The install "fails" on the first switch; `/run/secrets` is empty | [First activation](#the-install-fails-on-the-first-switch-and-runsecrets-is-empty) |
| The install reports success and the machine never comes back | [Networking](#the-install-succeeds-and-the-machine-never-comes-back) |
| `nixos-rebuild: unrecognized option '--ssh-option'` | [SSH flags](#nixos-rebuild-rejects---ssh-option) |
| A deploy exits non-zero but the machine looks fine | [Exit status](#a-deploy-exits-non-zero-but-the-machine-looks-fine) |
| You are about to avoid a source build to keep the installer small | [Installer size](#you-are-about-to-avoid-a-source-build-to-keep-the-installer-small) |

## The install "fails" on the first switch and `/run/secrets` is empty

```
Cannot read ssh key '/etc/ssh/ssh_host_ed25519_key': no such file or directory
sops-install-secrets: failed to decrypt '…': Error getting data key: 0 successful groups required, got 0
Activation script snippet 'setupSecrets' failed (1)
```

A host decrypts with an age key derived from its ssh host key, and that key does not exist
until the install has created it. Nothing is broken: the install completes and the box boots,
and the client even starts if it needs no secret to run — but `/run/secrets` is absent, so
anything that reads a secret is running without it.

Enroll the key and switch again; that second switch is what delivers the secrets:

```
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub   # → .sops.yaml → sops updatekeys
```

To keep the first activation clean instead, install a variant of the host with
`sops.secrets = lib.mkForce { }` (and the client instances too, if they consume a secret),
then switch to the real one.

## The install succeeds and the machine never comes back

No console, no error, nothing to grep — the deploy reports success and the address stops
answering. The box is up and has no route.

Several providers hand networking to the guest through a config drive or metadata service
rather than DHCP, so a machine left on DHCP has no address after the reboot.
`modules/base.nix` defaults to `useDHCP = true`, which is a plain-KVM default and not a
promise about your provider. `hosts/replay` and `hosts/devnet` turn it off and let cloud-init
read the metadata:

```nix
networking.useDHCP = false;
services.cloud-init = {
  enable = true;
  network.enable = true;
};
```

Check this **before** the first install, not after: recovering means console access or
rebuilding the box.

## `nixos-rebuild` rejects `--ssh-option`

It has no such flag. Pass ssh flags through the `NIX_SSHOPTS` environment variable instead.

## A deploy exits non-zero but the machine looks fine

`switch-to-configuration` exits non-zero if *any* unit on the box is in a failed state, not
only if the switch failed. On stock cloud images `cloud-final.service` often is. Check what
the machine actually runs before believing the status:

```
readlink -f /run/current-system
```

The inverse also bites, and it is on you rather than on the tool: a deploy wrapped in a
pipeline or followed by another command reports *that* command's status. `nixos-rebuild … |
tail` exits 0 whatever the deploy did. Capture the status of the deploy itself, or check
`/run/current-system` either way.

## You are about to avoid a source build to keep the installer small

Do not bother. core-geth compiled from source inside the kexec installer on an 8 GB VM
without trouble, so installer size is not a reason to reach for a stripped first install or a
prebuilt binary. Pick `-bin.nix` because you want a published release, not out of this fear.
