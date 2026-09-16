#!/usr/bin/env bash
# Runs the registered protocol in h100/PROTOCOL.md.
# Requires dcgmi, vllm, python (venv active), curl, timeout, nvidia-smi.
set -euo pipefail

FIELDS="203,1001,1002,1003,1004,1005,155"   # GPUTL GRACT SMACT SMOCC TENSO DRAMA POWER
ENTITY="0"
REPEATS="${REPEATS:-2}"
SERVE_MODEL="${SERVE_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
TRAIN_MODEL="${TRAIN_MODEL:-Qwen/Qwen2.5-0.5B}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HOME/telemetry-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
MANIFEST="$OUT/manifest.tsv"
printf 'scenario\tstart_utc\tend_utc\tseconds\n' > "$MANIFEST"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# record NAME SECONDS [COMMAND...]: sample for exactly SECONDS while an optional command runs
record() {
  local name="$1" secs="$2"; shift 2
  local start; start="$(stamp)"
  dcgmi dmon -i "$ENTITY" -e "$FIELDS" -d 1000 -c "$secs" > "$OUT/$name.dcgm" &
  local mon=$!
  if [ "$#" -gt 0 ]; then
    timeout "$secs" "$@" > "$OUT/$name.stdout" 2>&1 || true
  fi
  wait "$mon"
  printf '%s\t%s\t%s\t%s\n' "$name" "$start" "$(stamp)" "$secs" >> "$MANIFEST"
}

# record_train NAME MODE SECONDS: sampling starts when train.py takes its first step
record_train() {
  local name="$1" mode="$2" secs="$3"
  local ready="$OUT/$name.ready"
  rm -f "$ready"
  python "$HERE/train.py" --mode "$mode" --seconds "$secs" --model "$TRAIN_MODEL" \
    --ready-file "$ready" > "$OUT/$name.stdout" 2>&1 &
  local job=$!
  while [ ! -f "$ready" ]; do
    if ! kill -0 "$job" 2>/dev/null; then
      echo "train.py exited before its first step, see $OUT/$name.stdout" >&2
      exit 1
    fi
    sleep 1
  done
  record "$name" "$secs"
  wait "$job"
}

gpu_busy() {
  [ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader)" ]
}

# Environment record
nvidia-smi -q > "$OUT/env-nvidia-smi.txt"
dcgmi discovery -l > "$OUT/env-dcgm-discovery.txt"
dcgmi profile -l -i 0 > "$OUT/env-dcgm-profile.txt"
dpkg -l | grep -i datacenter-gpu-manager > "$OUT/env-dcgm-pkg.txt" || true
pip freeze > "$OUT/env-pip-freeze.txt"
uname -a > "$OUT/env-uname.txt"
cp "$HERE/run-scenarios.sh" "$HERE/train.py" "$HERE/summarize.py" "$OUT/"

if ! grep -q 1002 "$OUT/env-dcgm-profile.txt" || ! grep -q 1004 "$OUT/env-dcgm-profile.txt"; then
  echo "GPU does not expose SMACT and TENSO; stopping" >&2
  exit 1
fi

record baseline_empty 120

PROF="$(ls /usr/bin/dcgmproftester* 2>/dev/null | head -n1 || true)"
if [ -n "$PROF" ]; then
  record control_proftester_tenso 60 "$PROF" --gpuIds 0 --fieldId 1004 --duration 45 --no-dcgm-validation
else
  echo "dcgmproftester not found; control skipped" >> "$OUT/DEVIATIONS.txt"
fi

vllm serve "$SERVE_MODEL" --port 8000 --max-model-len 4096 > "$OUT/vllm-server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
for _ in $(seq 1 900); do
  curl -sf http://127.0.0.1:8000/v1/models > /dev/null && break
  kill -0 "$SERVER" 2>/dev/null || { echo "vllm serve exited, see $OUT/vllm-server.log" >&2; exit 1; }
  sleep 1
done
curl -sf http://127.0.0.1:8000/v1/models > /dev/null || { echo "vllm serve not ready after 900 s" >&2; exit 1; }

BENCH=(vllm bench serve --model "$SERVE_MODEL" --port 8000 --dataset-name random
       --random-input-len 512 --random-output-len 256 --ignore-eos --seed 42)

for r in $(seq 1 "$REPEATS"); do
  record "r${r}_vllm_idle_loaded" 300
  record "r${r}_vllm_rate_0.2"  600 "${BENCH[@]}" --request-rate 0.2 --max-concurrency 256 --num-prompts 150
  record "r${r}_vllm_rate_2"    600 "${BENCH[@]}" --request-rate 2   --max-concurrency 256 --num-prompts 1250
  record "r${r}_vllm_saturated" 600 "${BENCH[@]}" --request-rate inf --max-concurrency 64  --num-prompts 40000
done

kill "$SERVER" 2>/dev/null || true
wait "$SERVER" 2>/dev/null || true
trap - EXIT

# vLLM holds most of the GPU memory; training must not start until it is released
for _ in $(seq 1 120); do
  gpu_busy || break
  sleep 1
done
if gpu_busy; then
  echo "GPU still has compute processes 120 s after stopping vLLM:" >&2
  nvidia-smi --query-compute-apps=pid,process_name --format=csv >&2
  exit 1
fi

for r in $(seq 1 "$REPEATS"); do
  record_train "r${r}_train_untuned" untuned 600
  record_train "r${r}_train_tuned"   tuned   600
done

record baseline_empty_end 120

python "$HERE/summarize.py" "$OUT" | tee "$OUT/summary.md"
echo "Run complete: $OUT"
