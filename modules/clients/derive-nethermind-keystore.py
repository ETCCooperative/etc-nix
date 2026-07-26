"""Package a hex private-key file into a Nethermind-compatible Web3 Secret Storage
keystore file (V3, scrypt/aes-128-ctr — the same standard geth uses), plus a
throwaway password, both regenerated at every service start.

This exists because, unlike core-geth/besu, Nethermind's remote-sealer Address is
NOT just the configured KeyStore.BlockAuthorAccount string: it comes from an
ACTUAL private key loaded and unlocked through the keystore. If that lookup fails
(no keystore entry, wrong/missing password), Nethermind.Wallet.NodeKeyManager
.LoadSignerKey() silently falls back to the node's own enode key instead of
throwing — so the box would mine with the wrong beneficiary with no crash and only
an Error-level log line. See NodeKeyManager.cs LoadSignerKey/LoadKeyForAccount.

Regenerating the keystore + password from the sops-provisioned raw key on every
start keeps that key the single source of truth (mirrors derive-etherbase.py's
address derivation) while still satisfying what Nethermind actually requires.

Usage: derive-nethermind-keystore.py <raw-keyfile> <keystore-dir> <password-file>
Writes <keystore-dir>/UTC--nethermind-mining--<address> (fixed name, so re-runs
overwrite it instead of accumulating stale copies encrypted under a forgotten
password) and <password-file>. Prints the checksummed address to stdout.
"""

import json
import os
import secrets
import sys

os.environ.setdefault("ETH_HASH_BACKEND", "pycryptodome")

from eth_keyfile import create_keyfile_json  # noqa: E402
from eth_keys import keys  # noqa: E402

keyfile, keystore_dir, password_file = sys.argv[1:4]

raw = open(keyfile).read().strip()
if raw[:2] in ("0x", "0X"):
    raw = raw[2:]
key_bytes = bytes.fromhex(raw)
address = keys.PrivateKey(key_bytes).public_key.to_checksum_address()

password = secrets.token_hex(32)
keystore_json = create_keyfile_json(key_bytes, password.encode(), kdf="scrypt")

os.makedirs(keystore_dir, exist_ok=True)
keystore_path = os.path.join(keystore_dir, f"UTC--nethermind-mining--{address[2:].lower()}")
with open(keystore_path, "w") as f:
    json.dump(keystore_json, f)
os.chmod(keystore_path, 0o600)

with open(password_file, "w") as f:
    f.write(password)
os.chmod(password_file, 0o600)

print(address)
