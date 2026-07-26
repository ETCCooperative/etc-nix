# Transparent ethstats websocket proxy that fixes the hashrate a mining node reports to netstats.
# The node connects here instead of the real netstats server; every `stats` frame gets its
# hashrate/mining rewritten with a value polled from one of two sources (whichever env is set):
#
#   IPC_PATH      poll ethash_getHashrate over the node's geth IPC — for INTERNAL core-geth
#                 mining. eth_hashrate / Miner().Hashrate() returns 0 because the miner is wrapped
#                 in a beacon.Beacon that fails the consensus.PoW type assertion, but the ethash
#                 namespace still reports the real internal rate over IPC.
#   HASHRATE_URL  poll the etc-getwork-miner's -hashrate-addr http endpoint ({"hashrate": N}) — for
#                 EXTERNAL getwork mining, where the node itself reports 0 for a remote sealer and
#                 Nethermind hardcodes 0.
#
# Auth is untouched: the node's `hello` (with the secret) is forwarded as-is.
# Env: LISTEN_HOST, LISTEN_PORT, UPSTREAM (full ws/wss URL incl. /api), IPC_PATH | HASHRATE_URL, POLL_SECONDS.
import asyncio
import json
import logging
import os
import urllib.request

import websockets

LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "3999"))
UPSTREAM = os.environ["UPSTREAM"]
IPC_PATH = os.environ.get("IPC_PATH") or None
HASHRATE_URL = os.environ.get("HASHRATE_URL") or None
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "5"))

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("hashrate-proxy")
# the node probes wss:// first (TLS bytes hit this plain-ws listener) then falls back to ws://; that
# failed handshake is expected — mute the library's noisy tracebacks, we log what matters below.
logging.getLogger("websockets").setLevel(logging.CRITICAL)

hashrate = 0


def _to_int(v):
    if isinstance(v, str):
        return int(v, 16) if v.lower().startswith("0x") else int(v)
    return int(v)


async def read_ipc():
    req = b'{"jsonrpc":"2.0","id":1,"method":"ethash_getHashrate","params":[]}\n'
    reader, writer = await asyncio.open_unix_connection(IPC_PATH)
    try:
        writer.write(req)
        await writer.drain()
        data = await asyncio.wait_for(reader.readline(), timeout=5)
    finally:
        writer.close()
    return _to_int(json.loads(data).get("result"))


async def read_http():
    loop = asyncio.get_event_loop()

    def fetch():
        with urllib.request.urlopen(HASHRATE_URL, timeout=5) as r:
            return json.loads(r.read().decode())

    return _to_int((await loop.run_in_executor(None, fetch)).get("hashrate"))


async def poll_hashrate():
    global hashrate
    read = read_ipc if IPC_PATH else read_http
    source = IPC_PATH or HASHRATE_URL
    while True:
        try:
            result = await read()
            if result != hashrate:
                hashrate = result
                log.info("hashrate now %d H/s", hashrate)
        except Exception as e:
            log.warning("hashrate poll from %s failed: %s", source, e)
        await asyncio.sleep(POLL_SECONDS)


async def pipe(src, dst, rewrite):
    async for msg in src:
        if rewrite and isinstance(msg, str):
            try:
                obj = json.loads(msg)
                emit = obj.get("emit")
                if isinstance(emit, list) and len(emit) >= 2 and emit[0] == "stats":
                    stats = emit[1].get("stats")
                    if isinstance(stats, dict):
                        stats["hashrate"] = hashrate
                        stats["mining"] = True
                        msg = json.dumps(obj)
            except Exception:
                pass
        await dst.send(msg)


async def handler(node, *_):
    log.info("node connected; dialing %s", UPSTREAM)
    try:
        async with websockets.connect(UPSTREAM, origin="http://localhost") as upstream:
            tasks = [
                asyncio.create_task(pipe(node, upstream, True)),
                asyncio.create_task(pipe(upstream, node, False)),
            ]
            _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
    except Exception as e:
        log.warning("bridge closed: %s", e)
    finally:
        log.info("node disconnected")


async def main():
    log.info("listening on %s:%d, upstream %s, source %s", LISTEN_HOST, LISTEN_PORT, UPSTREAM, IPC_PATH or HASHRATE_URL)
    asyncio.create_task(poll_hashrate())
    async with websockets.serve(handler, LISTEN_HOST, LISTEN_PORT):
        await asyncio.Future()


asyncio.run(main())
