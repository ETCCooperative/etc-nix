# era-to-rlp — convert an Era1 archive to a concatenated block-RLP stream for `geth`/`getc`/`besu`
# block import (which re-executes each block). Used by the consensus-replay machines. See
# era_to_rlp.py for the mechanism.
{
  python3,
  writeShellApplication,
}:
let
  py = python3.withPackages (ps: [ ps.python-snappy ]);
in
writeShellApplication {
  name = "era-to-rlp";
  runtimeInputs = [ py ];
  text = ''exec python3 ${./era_to_rlp.py} "$@"'';
}
