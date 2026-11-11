#!/usr/bin/env bash
# A/B the Qwen3.8 Flash Next serve across two TensorFold builds on this N1X.
#
#   bench/run-ab.sh 1.2.3  tensorfold/zig-out/native/bin/tensorfold-native.exe
#   bench/run-ab.sh 1.2.6  tensorfold/zig-out-v126/native/bin/tensorfold-native.exe
#
# One run = serve on $PORT with the serve-qwen38.bat settings, bench cold prefill +
# 1/8-stream decode, kill the server, wait for the framebuffer to come back.
#
# Traps this script exists to avoid (all hit once):
#  - MSYS passes `//F` to taskkill literally, so `taskkill //F //IM ...` silently fails
#    and a stale 80 GiB server answers /health for the next build's bench. Kill through
#    PowerShell and then prove the port is free before starting anything.
#  - native exes (tensorfold-native, python) cannot read /c/... paths: use C:/...
set -u

LABEL=${1:?label}
EXE=${2:?exe}
ROOT=C:/Projects/tensorfold-win-arm64
PORT=${PORT:-8084}
PARALLEL=${PARALLEL:-2}
CONTEXT=${CONTEXT:-262144}
PROMPT_CACHE_GIB=${PROMPT_CACHE_GIB:-4}
MODEL="$ROOT/models/Qwen3.8-Flash-Next-FP4-Local"
LOG="$ROOT/logs/serve-$LABEL.log"
OUT="$ROOT/bench/results/results-$LABEL.json"

cd "$ROOT" || exit 1

kill_server() {
  powershell -NoProfile -Command "Stop-Process -Name tensorfold-native -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    tasklist | grep -qi tensorfold-native || return 0
    sleep 1
  done
  echo "  WARNING: a tensorfold-native process survived Stop-Process"
}

wait_vram_free() {
  # the process is gone before the driver releases the framebuffer; give it room
  for _ in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
    [ -n "${used:-}" ] && [ "$used" -lt 4000 ] && { echo "  framebuffer back to ${used} MiB"; return 0; }
    sleep 2
  done
  echo "  WARNING: framebuffer still busy: ${used:-?} MiB"
  return 1
}

port_free() {
  ! netstat -ano | grep -q ":$PORT .*LISTENING"
}

kill_server
wait_vram_free || { echo "  refusing to bench against a stale server"; exit 1; }
port_free || { echo "  refusing: port $PORT is already listening"; exit 1; }

echo "=== $LABEL: $EXE"
: > "$LOG"
TENSORFOLD_MEMORY_RESERVE_GIB=4 TF_FLASHNEXT_DRAFTS=6 TF_FLASHNEXT_GATHER_READ=pread \
TENSORFOLD_NO_UPDATE_CHECK=1 \
"$EXE" serve "$MODEL" \
  --name Qwen3.8-Flash-Next --host 127.0.0.1 --port "$PORT" \
  --parallel "$PARALLEL" --context "$CONTEXT" --prompt-cache-gib "$PROMPT_CACHE_GIB" \
  >> "$LOG" 2>&1 &
SERVE_PID=$!

start=$(date +%s)
python "$ROOT/bench/bench-flashnext.py" --label "$LABEL" \
  --stream-tokens "${STREAM_TOKENS:-128}" \
  --base-url "http://127.0.0.1:$PORT/v1" --out "$OUT"
rc=$?
echo "=== $LABEL: bench rc=$rc after $(( $(date +%s) - start ))s"

nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | sed 's/^/  resident MiB: /'
grep -m1 -E '^tensorfold-native [0-9]' "$LOG" | sed 's/^/  engine: /'
kill_server
echo "  server stopped"
exit $rc
