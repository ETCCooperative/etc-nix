"""Derive the checksummed Ethereum address from a hex private-key file.

Used by the coreGeth mining ExecStartPre so `--miner.etherbase` is always
consistent with the sops-provisioned coinbase key: single source of truth, no
hardcoded address to keep in sync. The key is read from the file path in
argv[1] (never passed on the command line, so it never shows in /proc/*/cmdline).
"""

import os
import sys

os.environ.setdefault("ETH_HASH_BACKEND", "pycryptodome")

from eth_keys import keys  # noqa: E402

raw = open(sys.argv[1]).read().strip()
if raw[:2] in ("0x", "0X"):
    raw = raw[2:]
print(keys.PrivateKey(bytes.fromhex(raw)).public_key.to_checksum_address())
