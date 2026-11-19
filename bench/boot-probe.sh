#!/usr/bin/env bash
# Boot-admission probe: does the engine accept PARALLEL full CONTEXT windows with
# the given KV dtype? The memory check is at startup, so a refusal exits the
# process early; a true ready is the engine's own 'serving' log line (/v1/models
# answers before the load finishes). Short deadline -- this is not a bench.
set -u
LABEL=${1:?label}
EXE=${2:?exe}
ROOT=C:/Projects/tensorfold-win-arm64
PORT=${PORT:-8084}
PARALLEL=${PARALLEL:-3}
CONTEXT=${CONTEXT:-262144}
KV=${KV_CACHE:-bf16}
MODEL="$ROOT/models/Qwen3.8-Flash-Next-FP4-Local"
LOG="$ROOT/logs/boot-$LABEL.log"
cd "$ROOT" || exit 1

powershell -NoProfile -Command "Stop-Process -Name tensorfold-native -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
for _ in $(seq 1 30); do tasklist | grep -qi tensorfold-native || break; sleep 1; done
for _ in $(seq 1 60); do
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
  [ -n "${used:-}" ] && [ "$used" -lt 4000 ] && break
  sleep 2
done

echo "=== boot-probe $LABEL: kv=$KV parallel=$PARALLEL context=$CONTEXT"
: > "$LOG"
TENSORFOLD_MEMORY_RESERVE_GIB=4 TF_FLASHNEXT_DRAFTS=6 TF_FLASHNEXT_GATHER_READ=pread \
TENSORFOLD_NO_UPDATE_CHECK=1 \
"$EXE" serve "$MODEL" --name boot-probe --host 127.0.0.1 --port "$PORT" \
  --parallel "$PARALLEL" --context "$CONTEXT" --prompt-cache-gib 4 --kv-cache "$KV" \
  >> "$LOG" 2>&1 &

ready=0
for i in $(seq 1 90); do
  sleep 2
  grep -q 'serving boot-probe' "$LOG" && { ready=1; break; }
  tasklist | grep -qi tensorfold-native || break
done
echo "=== $LABEL: ready=$ready after ~$((i * 2))s"
echo "--- log tail ---"
tail -8 "$LOG"
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | sed 's/^/resident MiB: /'
powershell -NoProfile -Command "Stop-Process -Name tensorfold-native -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
for _ in $(seq 1 30); do tasklist | grep -qi tensorfold-native || break; sleep 1; done
[ "$ready" = 1 ] && exit 0 || exit 2
