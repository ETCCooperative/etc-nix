# Deploying a node: what bites

Traps hit while putting a client from this flake on a real machine, observed on throwaway
VMs running core-geth on mordor.

**A first activation cannot decrypt sops secrets.** A host decrypts with an age key derived
from its ssh host key, and that key does not exist until the install has created it:

```
Cannot read ssh key '/etc/ssh/ssh_host_ed25519_key': no such file or directory
sops-install-secrets: failed to decrypt '…': Error getting data key: 0 successful groups required, got 0
Activation script snippet 'setupSecrets' failed (1)
```

The install still completes and the box boots — the client even starts, if it needs no secret
to run — but `/run/secrets` is absent. Enroll the key
(`ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` → `.sops.yaml` → `sops updatekeys`) and
switch again; that second switch is what delivers the secrets. To keep the first activation
clean instead, install a variant of the host with
`sops.secrets = lib.mkForce { }` (and the client instances too, if they consume a secret),
then switch to the real one.

**DHCP is not a safe default.** Several providers hand networking to the guest through a
config drive or metadata service, and a box left on DHCP installs perfectly and never comes
back — with no console, an opaque way to lose an afternoon. `modules/base.nix` defaults to
DHCP; `hosts/replay` and `hosts/devnet` turn it off:

```nix
networking.useDHCP = false;
services.cloud-init = {
  enable = true;
  network.enable = true;
};
```

**`nixos-rebuild` has no `--ssh-option`.** Pass ssh flags through `NIX_SSHOPTS`.

**A non-zero `switch-to-configuration` does not mean the switch failed.** It exits non-zero if
*any* unit on the box is in a failed state, and on stock cloud images `cloud-final.service`
often is. Check `/run/current-system` before believing it.

**A source-built client is not too big for the installer.** core-geth compiled from source
inside the kexec installer on an 8 GB VM without trouble, so that is not a reason to reach for
a stripped first install.
