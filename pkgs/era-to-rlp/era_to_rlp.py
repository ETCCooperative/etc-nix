#!/usr/bin/env python3
# Convert an Era1 archive to a concatenated block-RLP stream — the format that `geth import`,
# `getc import` and `besu blocks import --format=RLP` all consume, re-executing (and thus
# re-validating) every block. Self-contained: parses the e2store, snappy-decompresses each block's
# header+body, and splices them into canonical block RLP = list([header, txs, uncles]) with zero
# dependency on any client. Used by the consensus-replay machines to feed eras one at a time.
#
# Usage: era_to_rlp.py <input.era1> <output.rlp>
import struct
import sys

import snappy

TYPE_HEADER = 0x03
TYPE_BODY = 0x04


def entries(buf):
    off = 0
    while off < len(buf):
        typ, ln = struct.unpack_from("<HI", buf, off)  # 2B type, 4B length (LE); 2B reserved
        yield typ, buf[off + 8 : off + 8 + ln]
        off += 8 + ln


def list_payload(b):
    # return the payload bytes of an RLP list (everything after its length prefix)
    p = b[0]
    if 0xC0 <= p <= 0xF7:
        return b[1 : 1 + (p - 0xC0)]
    if p >= 0xF8:
        nl = p - 0xF7
        n = int.from_bytes(b[1 : 1 + nl], "big")
        return b[1 + nl : 1 + nl + n]
    raise ValueError("not an RLP list")


def encode_list(payload):
    n = len(payload)
    if n < 56:
        return bytes([0xC0 + n]) + payload
    lb = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0xF7 + len(lb)]) + lb + payload


def convert(era_path, out):
    buf = open(era_path, "rb").read()
    header_rlp = None
    count = 0
    for typ, data in entries(buf):
        if typ == TYPE_HEADER:
            header_rlp = snappy.StreamDecompressor().decompress(data)  # complete RLP item
        elif typ == TYPE_BODY:
            body_rlp = snappy.StreamDecompressor().decompress(data)  # rlp([txs, uncles])
            # block = list([header, txs, uncles]); body already holds [txs, uncles]
            out.write(encode_list(header_rlp + list_payload(body_rlp)))
            count += 1
    return count


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: era_to_rlp.py <input.era1> <output.rlp>")
    with open(sys.argv[2], "wb") as fh:
        n = convert(sys.argv[1], fh)
    print(f"era_to_rlp: wrote {n} block RLPs to {sys.argv[2]}")
