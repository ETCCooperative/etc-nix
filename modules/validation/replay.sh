#!/usr/bin/env bash
# Consensus replay for one (client, network): re-execute every block in the Era1 archive to
# re-validate consensus. Config comes from the environment (consensus-replay.nix). Verdict → Bugsink
# (failure) + logs; then poweroff (ephemeral machine).
#
# EVERY client runs as a SINGLE process for the whole archive, so each opens its state DB exactly
# once and keeps its cache warm. This is a fairness requirement, not an optimisation: the DB re-open
# cost scales with state size, so a per-era restart penalises whichever client's DB grows fastest
# (see stream_import). core-geth/getc stream block RLP era-by-era through a FIFO (only one era on disk);
# besu needs that RLP as a FILE instead — its reader is unsound on a pipe (see besu_import) — so it is
# materialised before the timed window; nethermind re-executes Era1 natively via Era.ImportDirectory
# (Sync.FastSync=false + fresh DB) and needs its eras resident, so it pre-fetches them, also up front.
set -euo pipefail
shopt -s nullglob

STEP=8192
log() { echo "[replay:$CLIENT:$NETWORK] $*"; }

# rclone `r2` remote via env (read-only creds from sops); nothing secret on argv/config.
RCLONE_CONFIG_R2_ACCESS_KEY_ID="$(<"$R2_KEY_ID_FILE")"
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$(<"$R2_SECRET_FILE")"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
R2="r2:$ERA_BUCKET/"

SELF_DESTRUCT_HOOK="$(dirname "$R2_KEY_ID_FILE")/self-destruct"

# InfluxDB progress metric: push the re-executed head block over time, tagged by client/network, so a
# Grafana panel can plot block-vs-time per environment and compare speeds. Best-effort; a failed push
# never affects the replay. Enabled only when INFLUX_URL + a token are provided.
[[ -n "${INFLUX_URL:-}" && -s "${INFLUX_TOKEN_FILE:-/nonexistent}" ]] && INFLUX_TOKEN=$(<"$INFLUX_TOKEN_FILE")
push_progress() {
  [[ -n "${INFLUX_TOKEN:-}" ]] || return 0
  curl -sf -m 10 -XPOST "$INFLUX_URL/api/v2/write?org=${INFLUX_ORG:-geths}&bucket=${INFLUX_BUCKET:-gethmetrics}&precision=s" \
    -H "Authorization: Token $INFLUX_TOKEN" -H "Content-Type: text/plain" \
    --data-binary "replay,client=$CLIENT,network=$NETWORK block=${1}i" >/dev/null 2>&1 || true
}

# Tee the client's import output to the journal AND push its block progress to InfluxDB. Each client
# logs progress every ~1-2.5k blocks (geth 2500, besu 1000, nethermind ~700-2600) — pumping one point
# per such line gives fine, per-few-thousand-block granularity without touching the client.
report_blocks() {
  local line blk
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$CLIENT" in
    core-geth | getc) [[ "$line" =~ number=([0-9,]+) ]] && blk=${BASH_REMATCH[1]//,/} || blk="" ;;
    besu) [[ "$line" =~ Import\ at\ block\ ([0-9]+) ]] && blk=${BASH_REMATCH[1]} || blk="" ;;
    nethermind) [[ "$line" =~ Processed[[:space:]]+[0-9]+\.\.\.+[[:space:]]*([0-9]+) ]] && blk=${BASH_REMATCH[1]} || blk="" ;;
    *) blk="" ;;
    esac
    [[ -n "$blk" ]] && push_progress "$blk"
  done
  # Always succeed: this is the last stage of a `set -o pipefail` pipeline, and a `while read` returns
  # its last iteration's status — a non-matching final line (client shutdown noise) would otherwise
  # fabricate a pipeline failure. A real import failure still propagates via the client's own exit
  # code (pipefail carries the non-zero from the left of the pipe).
  return 0
}

# nethermind's Era importer re-executes the batch's eras but, unlike geth/besu's `import`, does NOT
# exit when done — it keeps running (idle offline, or p2p full-sync PAST the batch if peers are
# reachable, defeating the archive re-execution). So run it OFFLINE (no discovery/peers → it
# re-executes ONLY the batch's archive eras, never syncs from peers) and stop it GRACEFULLY once the
# batch is done: SIGTERM lets it flush RocksDB, and DATADIR carries the head into the next invocation.
#
# Completion is judged on the EXECUTED head reaching to_blk, NOT on the "Finished history import" log.
# Those are two different frontiers: ImportBlock only SUGGESTS blocks onto the processing queue, and
# "Finished" is logged the instant the last block is suggested — the executor (whose "Processed …"
# lines we read) still trails it by the queue depth (up to Era.ImportBlocksBufferSize=4096). Killing on
# "Finished" leaves that queued tail unexecuted, and — worse — any run that re-executes through to_blk
# WITHOUT emitting that exact line (the marker's block number differs, or nethermind dies right after)
# is misread as a failure. So on "Finished" we don't kill: we arm a short drain window and let the
# executor catch up, stopping as soon as the executed head reaches to_blk (or the window elapses). Both
# "Processed a…b" (multi-block) and "Processed n |" (single-block) advance the executed head; the old
# regex matched only the first, understating the head near the tip. Args: <from-block> <to-block>.
# Returns 0 iff the executed head reached to_blk (or nethermind logged the range imported); non-zero
# only if it died before completing — a real consensus/import failure.
nm_run_batch() {
  local from_blk="$1" to_blk="$2" line nm_pid rc=0 finished=0 last_exec=0 drain_deadline=0 r fifo
  fifo=$(mktemp -u)
  mkfifo "$fifo"
  # LD_PRELOAD jemalloc (path + tuning injected by consensus-replay.nix for nethermind only): glibc
  # never returns the arena memory rocksdb frees between blocks to the OS, OOM-killing the offline Era
  # import at the 2016 DoS blocks. The prefix scopes the swap to the client binary — the process
  # substitution below keeps the default allocator. Empty when the vars are unset (a no-op).
  LD_PRELOAD="${NM_LD_PRELOAD:-}" MALLOC_CONF="${NM_MALLOC_CONF:-}" \
    "$CLIENT_BIN" -c "$NETWORK" --data-dir "$DATADIR" --Sync.FastSync false \
    --EtcValidation.ForceSealCheck true \
    --Init.DiscoveryEnabled false --Init.PeerManagerEnabled false --Network.OnlyStaticPeers true \
    --Era.NetworkName "$NETWORK" --Era.ImportDirectory "$WORKDIR" \
    --Era.From "$from_blk" --Era.To "$to_blk" \
    > >(sed -u 's/\x1b\[[0-9;]*m//g' >"$fifo") 2>&1 &
  nm_pid=$!
  exec 4<"$fifo" # hold the read end open across iterations so `read -t` timeouts aren't seen as EOF
  while :; do
    if IFS= read -r -t 2 line <&4; then
      printf '%s\n' "$line" # tee to the journal
      if [[ "$line" =~ Processed[[:space:]]+[0-9]+\.\.\.+[[:space:]]*([0-9]+) ]]; then
        last_exec=${BASH_REMATCH[1]}
        push_progress "$last_exec"
      elif [[ "$line" =~ Processed[[:space:]]+([0-9]+)[[:space:]] ]]; then
        last_exec=${BASH_REMATCH[1]}
        push_progress "$last_exec"
      fi
      if ((finished == 0)) && [[ "$line" == *"Finished history import from $from_blk to $to_blk"* ]]; then
        finished=1
        drain_deadline=$(($(date +%s) + ${NM_DRAIN_SECS:-30}))
        log "batch $from_blk..$to_blk imported (suggested) — draining executor to $to_blk"
      fi
    else
      r=$?
      # `read` returns >128 on the 2 s timeout (loop again to re-check the stop conditions) and ≤128 on
      # EOF — the writer closed because nethermind exited, so stop reading and collect its status.
      ((r > 128)) || break
    fi
    # Stop once the executor has re-executed through to_blk, or the post-"Finished" drain window is up.
    if ((last_exec >= to_blk)) || { ((finished)) && (($(date +%s) >= drain_deadline)); }; then
      log "batch $from_blk..$to_blk re-executed to $last_exec — stopping nethermind gracefully"
      kill -TERM "$nm_pid" 2>/dev/null || true
      break
    fi
  done
  exec 4<&-
  wait "$nm_pid" || rc=$? # SIGTERM → 143 (expected); a pre-completion non-zero is a real failure
  rm -f "$fifo"
  # Complete if the executed head reached the target, or nethermind logged the range imported — the
  # queued tail past the executed head is ≤64 blocks it won't persist anyway (the reorg boundary).
  { ((last_exec >= to_blk)) || ((finished)); } && return 0
  return "$rc"
}

# Send the verdict to Bugsink (Sentry store API). The machine self-destructs, so this durable
# record is the only trace of the result. level OK → info, FAIL → error.
report_verdict() {
  local verdict="$1" detail="$2" lvl="info"
  [[ "$verdict" == FAIL ]] && lvl="error"
  log "VERDICT=$verdict client=$CLIENT network=$NETWORK $detail"
  # Durable record to R2 (same bucket) — the machine's logs die with it.
  local rf=/tmp/replay-result.json
  printf '{"client":"%s","network":"%s","verdict":"%s","release":"%s","detail":"%s"}\n' \
    "$CLIENT" "$NETWORK" "$verdict" "${RELEASE:-unknown}" "$detail" >"$rf"
  rclone copyto "$rf" "${R2}replay-results/$CLIENT-$NETWORK.json" 2>/dev/null || log "result upload to R2 failed"
  [[ -n "${BUGSINK_DSN_FILE:-}" && -s "$BUGSINK_DSN_FILE" ]] || return 0
  local dsn key host proj body
  dsn=$(<"$BUGSINK_DSN_FILE")
  key=${dsn#*//}
  key=${key%%@*}
  host=${dsn#*@}
  host=${host%%/*}
  proj=${dsn##*/}
  body=$(printf '{"message":"replay %s: %s/%s %s","level":"%s","release":"%s","tags":{"client":"%s","network":"%s"}}' \
    "$verdict" "$CLIENT" "$NETWORK" "$detail" "$lvl" "${RELEASE:-unknown}" "$CLIENT" "$NETWORK")
  curl -sf -m 20 -X POST "https://$host/api/$proj/store/" \
    -H "Content-Type: application/json" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=$key" \
    -d "$body" >/dev/null 2>&1 || log "bugsink send failed"
}
report_failure() { report_verdict FAIL "epoch=$1 block=$(($1 * STEP)) detail='$2'"; }

# On failure the machine self-destructs and its journal goes with it, leaving only the one-line verdict
# in R2 — too little to diagnose anything (this is exactly how a real nethermind import exception, whose
# text was only in the journal, became unrecoverable). Preserve the tail of the unit's journal to R2
# next to the verdict so a post-mortem has the actual client output. Best-effort; never blocks teardown.
upload_journal_tail() {
  local lf=/tmp/replay-journal.log
  journalctl -u "${REPLAY_UNIT:-consensus-replay}" --no-pager -o cat 2>/dev/null |
    tail -n "${JOURNAL_TAIL_LINES:-500}" >"$lf" 2>/dev/null || return 0
  [[ -s "$lf" ]] || return 0
  rclone copyto "$lf" "${R2}replay-results/$CLIENT-$NETWORK.log" 2>/dev/null || log "journal upload to R2 failed"
}

# Tear the machine down. An ephemeral deployment stages a self-destruct hook — an executable that
# deletes the instance via its provider's API (a powered-off cloud VM may still bill until it is
# destroyed). The hook is provider-specific and lives with whoever provisions the machine, not in
# this tool; if none was staged, or it fails, fall back to powering off.
finish() {
  local rc="$1"
  ((rc != 0)) && upload_journal_tail # keep the failing run's client output before the box disappears
  if [[ -x "$SELF_DESTRUCT_HOOK" ]]; then
    log "running self-destruct hook"
    "$SELF_DESTRUCT_HOOK" >/dev/null 2>&1 || log "self-destruct hook failed; powering off instead"
    sleep 20 # give teardown a moment; if the box is still alive, fall through to poweroff
  fi
  if [[ "${POWEROFF:-true}" == true ]]; then
    log "powering off"
    systemctl poweroff || true
  fi
  exit "$rc"
}

# Highest epoch available in the bucket.
highest=$(rclone lsf "$R2" --include "$NETWORK-*.era1" 2>/dev/null |
  sed -E "s/^$NETWORK-0*([0-9]+)-.*/\1/" | sort -n | tail -1 || true)
[[ "$highest" =~ ^[0-9]+$ ]] || {
  log "no eras found in $R2"
  finish 1
}
# Optional bounds staged at spin time (bounded runs without rebuilding the config).
secrets_dir=$(dirname "$R2_KEY_ID_FILE")
[[ -z "${TO_EPOCH:-}" && -s "$secrets_dir/to_epoch" ]] && TO_EPOCH=$(<"$secrets_dir/to_epoch")
[[ -z "${FROM_EPOCH:-}" && -s "$secrets_dir/from_epoch" ]] && FROM_EPOCH=$(<"$secrets_dir/from_epoch")

to=$highest
[[ -n "${TO_EPOCH:-}" && "$TO_EPOCH" -lt "$to" ]] && to=$TO_EPOCH
from=${FROM_EPOCH:-0}
log "re-executing epochs $from..$to (blocks $((from * STEP))..$(((to + 1) * STEP - 1)))"

install -d -m 0755 "$DATADIR" "$WORKDIR"

fetch_era() {
  local epoch="$1" pfx
  pfx="$NETWORK-$(printf '%05d' "$epoch")-"
  local f=("$WORKDIR/$pfx"*.era1)
  # Only reach for R2 if we don't already have it: nethermind pre-fetches its whole batch in bulk and
  # then walks the same epochs again, and an rclone process per epoch costs more than the transfer.
  ((${#f[@]})) || {
    rclone copy "$R2" "$WORKDIR" --include "$pfx*.era1" --transfers 4 2>/dev/null
    f=("$WORKDIR/$pfx"*.era1)
  }
  ((${#f[@]})) || return 1
  printf '%s\n' "${f[0]}"
}

BESU_RLP="$WORKDIR/blocks.rlp"
case "$CLIENT" in
core-geth | getc) fetch_era "$from" >/dev/null 2>&1 || true ;;
besu)
  # Materialise the whole archive's block RLP as ONE file (besu cannot read a pipe — see besu_import).
  # Done here, BEFORE the coordinated-start barrier, so the conversion never lands inside the measured
  # window. Disk holds the growing RLP plus one era and one part at a time, never the era1 archive.
  : >"$BESU_RLP"
  _pf=""
  for ((_x = from; _x <= to; _x++)); do
    [[ -n "$_pf" ]] && wait "$_pf" 2>/dev/null || true
    _pf=""
    _era=$(fetch_era "$_x") || {
      report_failure "$_x" "era file missing in R2"
      finish 1
    }
    ((_x < to)) && {
      fetch_era $((_x + 1)) >/dev/null 2>&1 &
      _pf=$!
    }
    "$ERA2RLP" "$_era" "$WORKDIR/part.rlp" >/dev/null || {
      report_failure "$_x" "era→rlp conversion failed"
      finish 1
    }
    cat "$WORKDIR/part.rlp" >>"$BESU_RLP"
    rm -f "$_era" "$WORKDIR/part.rlp"
    ((_x % 200 == 0)) && log "epoch $_x/$to converted to RLP"
  done
  log "block RLP materialised: $(du -h "$BESU_RLP" | cut -f1)"
  ;;
nethermind)
  # Era.ImportDirectory needs its batch resident, and the batch now defaults to the whole archive, so
  # pre-fetch it all here — BEFORE the coordinated-start barrier, i.e. outside the measured window.
  rclone copyto "${R2}checksums.txt" "$WORKDIR/checksums-full.txt" 2>/dev/null || true
  _b=$((from + ${NM_BATCH:-$((to - from + 1))} - 1))
  ((_b > to)) && _b=$to
  if ((from == 0 && _b >= to)); then
    # Whole archive (the default): one bulk transfer. Spawning rclone once per epoch would cost hours
    # of process startup alone — enough to blow the coordinated-start barrier.
    rclone copy "$R2" "$WORKDIR" --include "$NETWORK-*.era1" --transfers 8 2>/dev/null || true
  else
    for ((_x = from; _x <= _b; _x++)); do fetch_era "$_x" >/dev/null 2>&1 || true; done
  fi
  ;;
esac

[[ -s "$secrets_dir/run_id" ]] && RUN_ID=$(<"$secrets_dir/run_id")
[[ -s "$secrets_dir/fleet_size" ]] && FLEET_SIZE=$(<"$secrets_dir/fleet_size")
[[ -s "$secrets_dir/influx_read_token" ]] && INFLUX_READ_TOKEN=$(<"$secrets_dir/influx_read_token")
if [[ -n "${RUN_ID:-}" && -n "${FLEET_SIZE:-}" && -n "${INFLUX_TOKEN:-}" && -n "${INFLUX_READ_TOKEN:-}" && -n "${INFLUX_URL:-}" ]]; then
  _dl=$(($(date +%s) + ${SYNC_MAX_WAIT:-1200}))
  while :; do
    curl -sf -m 10 -XPOST "$INFLUX_URL/api/v2/write?org=${INFLUX_ORG:-geths}&bucket=${INFLUX_BUCKET:-gethmetrics}&precision=s" \
      -H "Authorization: Token $INFLUX_TOKEN" -H "Content-Type: text/plain" \
      --data-binary "replay_ready,run=$RUN_ID,client=$CLIENT,network=$NETWORK ready=1i" >/dev/null 2>&1 || true
    _n=$(curl -sf -m 12 "$INFLUX_URL/api/v2/query?org=${INFLUX_ORG:-geths}" \
      -H "Authorization: Token $INFLUX_READ_TOKEN" -H "Content-Type: application/vnd.flux" -H "Accept: application/csv" \
      --data "from(bucket:\"${INFLUX_BUCKET:-gethmetrics}\")|>range(start:-30m)|>filter(fn:(r)=>r._measurement==\"replay_ready\" and r.run==\"$RUN_ID\" and r.network==\"$NETWORK\")|>group(columns:[\"client\"])|>last()|>group()|>count()" 2>/dev/null | tr -d '\r' | grep -oE ',[0-9]+$' | tr -d ',' | head -1)
    _n=${_n:-0}
    log "coordinated start: $_n/$FLEET_SIZE ready"
    ((_n >= FLEET_SIZE)) && break
    (($(date +%s) >= _dl)) && { log "coordinated start: timeout, proceeding with $_n/$FLEET_SIZE"; break; }
    sleep 4
  done
fi

# Stream every era's block RLP through a FIFO into ONE long-lived `geth import` (InsertChain). geth's
# rlp.Stream sits on a bufio.Reader, which LOOPS on a short read, so a named pipe is a valid input and
# era boundaries are invisible to it. besu cannot do this — see besu_import.
#
# Why one process and not one per era (the previous shape): every invocation re-opens the chaindata
# and starts with a COLD block cache. That cost scales with DB size, so it silently penalised clients
# whose state grows fastest — measured on core-geth/classic: 87 s just to open a 127 GB DB, ~3038
# times, leaving only ~20% of wall-clock doing actual re-execution (3% cache hit rate, 38% I/O
# stall). It also made the benchmark unfair: nethermind ran one process per BATCH of eras, so it paid
# that cost 64× less often. Now every client opens its DB exactly once and keeps its cache warm.
#
# Disk is unchanged: exactly one era on disk at a time (the converter feeds the pipe as the client
# drains it, so conversion is pipelined with execution rather than added to it).
stream_import() {
  local fifo="$WORKDIR/stream.rlp" cpid rc=0 e era
  rm -f "$fifo"
  mkfifo "$fifo"
  "$CLIENT_BIN" "--$NETWORK" --datadir "$DATADIR" --cache "${CACHE:-2048}" import "$fifo" \
    > >(sed -u 's/\x1b\[[0-9;]*m//g' | report_blocks) 2>&1 &
  cpid=$! # the client itself (process substitution does not shadow $!) → its real exit status
  # Hold the write end open for the whole run: the converter closing its own fd after era N would
  # otherwise be the last writer, and the client would see EOF and stop after the first era.
  exec 3>"$fifo"
  local prefetch=""
  for ((e = from; e <= to; e++)); do
    # This era was already being fetched while the client chewed on the previous one; the download is
    # long finished, but wait for it anyway — rclone must not still be writing the file we hand over.
    [[ -n "$prefetch" ]] && wait "$prefetch" 2>/dev/null || true
    prefetch=""
    era=$(fetch_era "$e") || {
      exec 3>&-
      wait "$cpid" || true
      report_failure "$e" "era file missing in R2"
      finish 1
    }
    # Fetch the NEXT era in the background. Serialising it cost ~2 s per era against ~47 s of
    # re-execution — ~3% of the measured window, paid only by the clients that stream (the ones that
    # pre-fetch their archive pay it outside the window). Bandwidth was never the constraint: R2
    # delivers ~6.5 MB/s while the client consumes ~0.4 MB/s of era, so overlapping erases it.
    ((e < to)) && {
      fetch_era $((e + 1)) >/dev/null 2>&1 &
      prefetch=$!
    }
    if ! "$ERA2RLP" "$era" /dev/fd/3 >/dev/null; then
      # EPIPE here means the client already exited — i.e. a block failed to re-execute.
      exec 3>&-
      rc=0
      wait "$cpid" || rc=$?
      report_failure "$e" "block re-execution failed (client exited early, rc=$rc)"
      finish 1
    fi
    rm -f "$era"
    ((e % 100 == 0)) && log "epoch $e/$to streamed"
  done
  exec 3>&- # last writer closed → EOF → the client drains the tail and exits
  wait "$cpid" || rc=$?
  rm -f "$fifo"
  return "$rc"
}

# besu gets a FILE, not a pipe, and this is not a preference — its reader is only correct on files.
# RawBlockIterator.fillReadBuffer() calls fileChannel.read() ONCE and never compares what came back
# against the block length it then parses:
#
#     private void fillReadBuffer() { fileChannel.read(readBuffer); }   // one read, no loop
#     final int length = RLP.calculateSize(...);                        // from the block's prefix
#     if (length > readBuffer.capacity()) { grow to 2*length; fillReadBuffer(); }
#     ... then parse `length` bytes, assuming they arrived ...
#
# On a regular file that assumption holds: a read returns everything asked for, short of EOF. On a pipe
# it does not — POSIX lets read() return fewer bytes at ANY size, whenever the writer happens to be
# behind. besu then parses past the valid data into the ByteBuffer's zero-filled tail and dies with
# `MalformedRLPInputException: Invalid scalar, has leading zeros bytes` — it is literally reading the
# zeros. Reproduced to the byte on classic: block #447,533 is 145,690 B, two 64 KiB pipe reads deliver
# 131,072 B, and besu failed at byte ~144,975 — inside that block, in the zeros.
#
# No pipe size fixes this. A bigger pipe makes the short read less likely, never impossible: the
# guarantee would rest on the writer always being ahead, which is a timing property, not an invariant.
# The archive's block RLP is therefore materialised on disk first (see the besu prep below) and handed
# over as a file. Costs ~36 GB for classic; buys a channel on which besu's own assumption is true.
besu_import() {
  local cpid rc=0
  "$CLIENT_BIN" --network="$NETWORK" --data-path="$DATADIR" blocks import --format=RLP --from="$BESU_RLP" \
    > >(sed -u 's/\x1b\[[0-9;]*m//g' | report_blocks) 2>&1 &
  cpid=$!
  wait "$cpid" || rc=$?
  return "$rc"
}

case "$CLIENT" in
core-geth | getc)
  if ! stream_import; then
    report_failure "$to" "block re-execution failed (import returned non-zero)"
    finish 1
  fi
  ;;
besu)
  if ! besu_import; then
    report_failure "$to" "block re-execution failed (import returned non-zero)"
    finish 1
  fi
  ;;
nethermind)
  # nethermind re-executes Era1 natively (FastSync=false + fresh DB → SuggestAndProcessBlock), one
  # batch of eras per invocation via nm_run_batch (offline + graceful stop — see there; resumes from
  # head across batches). NetworkName must match the <network>-*.era1 filenames. EraStore requires
  # core-geth's own checksums.txt (published to R2 by the export): download it once, then feed each
  # batch its slice (nethermind indexes by epoch).
  [[ -s "$WORKDIR/checksums-full.txt" ]] || rclone copyto "${R2}checksums.txt" "$WORKDIR/checksums-full.txt" 2>/dev/null || {
    report_failure "$from" "no checksums.txt in R2 — export must publish core-geth's"
    finish 1
  }
  # One invocation for the whole archive by default, so nethermind opens its DB exactly once — the
  # same rule the RLP clients now follow in stream_import (a per-batch restart used to give
  # nethermind a 64× advantage in DB re-opens over them). NM_BATCH still splits the run when disk is
  # the binding constraint: the eras of a batch must all be resident (Era.ImportDirectory).
  batch=${NM_BATCH:-$((to - from + 1))}
  ((batch < 2)) && batch=2 # need ≥2 eras/batch so the 1-era overlap (below) still advances
  e=$from
  while :; do
    bend=$((e + batch - 1))
    ((bend > to)) && bend=$to
    for ((x = e; x <= bend; x++)); do
      fetch_era "$x" >/dev/null || {
        report_failure "$x" "era file missing in R2"
        finish 1
      }
    done
    # this batch's checksums: lines are one-per-epoch from 0, so slice [e..bend] (1-indexed).
    sed -n "$((e + 1)),$((bend + 1))p" "$WORKDIR/checksums-full.txt" >"$WORKDIR/checksums.txt"
    if ! nm_run_batch $((e * STEP)) $(((bend + 1) * STEP - 1)); then
      report_failure "$e" "nethermind era import failed"
      finish 1
    fi
    log "epochs $e..$bend re-executed OK"
    ((bend >= to)) && break
    # nethermind persists ~Pruning.PruningBoundary (64) blocks BEHIND the processed head, so on stop
    # the on-disk head sits a few dozen blocks inside era `bend`. Keep era `bend` (delete only
    # e..bend-1) and start the next batch AT it (--Era.From = bend*STEP): nethermind resumes from its
    # persisted head, re-imports that sub-era gap from the kept file, and continues — no hole. Deleting
    # e..bend-1 is required for correctness, not just disk: nethermind's Era importer HANGS if the
    # directory holds eras below --Era.From. Costs one extra era on disk + re-executing <8192 blocks/batch.
    for ((x = e; x < bend; x++)); do rm -f "$WORKDIR/$NETWORK-$(printf '%05d' "$x")-"*.era1; done
    e=$bend
  done
  rm -f "$WORKDIR"/*.era1
  ;;
*)
  log "unknown client $CLIENT"
  finish 1
  ;;
esac

report_verdict OK "epochs $from..$to re-executed"
finish 0
