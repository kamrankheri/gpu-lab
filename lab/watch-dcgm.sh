#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# watch-dcgm.sh - poll dcgm-exporter and show the metrics that actually matter
# for GPU waste detection, side by side.
#
#   ./watch-dcgm.sh            poll every 2s
#   ./watch-dcgm.sh 5          poll every 5s
#   ./watch-dcgm.sh 2 log.csv  also append to a CSV
#
# Run this in one SSH session while gpu-workload.py runs in another.
# ---------------------------------------------------------------------------
set -uo pipefail

INTERVAL="${1:-2}"
CSVOUT="${2:-}"
ENDPOINT="${ENDPOINT:-localhost:9400/metrics}"

# The first is what every dashboard shows. The rest are what tell the truth.
#   GPU_UTIL            was any kernel resident during the sample window
#   SM_ACTIVE           fraction of SMs with work
#   SM_OCCUPANCY        warp occupancy of those SMs
#   PIPE_TENSOR_ACTIVE  tensor cores doing work. Zero here on a "busy" GPU is
#                       the finding you get paid for
#   FB_USED             framebuffer memory in MiB
FIELDS=(
  DCGM_FI_DEV_GPU_UTIL
  DCGM_FI_PROF_SM_ACTIVE
  DCGM_FI_PROF_SM_OCCUPANCY
  DCGM_FI_PROF_PIPE_TENSOR_ACTIVE
  DCGM_FI_DEV_FB_USED
)

scrape() { curl -s --max-time 3 "$ENDPOINT"; }

value_of() {
  # metric lines look like: NAME{labels...} VALUE
  echo "$1" | awk -v m="^$2\\{" '$0 ~ m {print $NF; exit}'
}

RAW=$(scrape)
if [ -z "$RAW" ]; then
  echo "no response from $ENDPOINT"
  echo "is the exporter running?  docker ps"
  exit 1
fi

echo
echo "available DCGM_FI_PROF_* fields in this exporter build:"
PROF=$(echo "$RAW" | grep -o '^DCGM_FI_PROF_[A-Z_]*' | sort -u)
if [ -z "$PROF" ]; then
  echo "  NONE. The profiling fields are not in the default counter set."
  echo "  Restart the exporter with a counters file that includes them:"
  echo "    docker rm -f dcgm"
  echo "    docker run -d --rm --gpus all --name dcgm -p 9400:9400 \\"
  echo "      nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04 \\"
  echo "      -f /etc/dcgm-exporter/dcp-metrics-included.csv"
  echo "  If that path is wrong, list what ships in the image:"
  echo "    docker run --rm --entrypoint ls \\"
  echo "      nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04 /etc/dcgm-exporter"
else
  echo "$PROF" | sed 's/^/  /'
fi
echo

if [ -n "$CSVOUT" ] && [ ! -f "$CSVOUT" ]; then
  printf 'timestamp,%s\n' "$(IFS=,; echo "${FIELDS[*]}")" > "$CSVOUT"
fi

printf '%-9s' "time"
for f in "${FIELDS[@]}"; do printf '%14s' "${f#DCGM_FI_}"; done
printf '\n'
printf '%s\n' "$(printf '%0.s-' {1..79})"

while true; do
  RAW=$(scrape)
  [ -z "$RAW" ] && { echo "scrape failed"; sleep "$INTERVAL"; continue; }

  TS=$(date +%H:%M:%S)
  printf '%-9s' "$TS"
  ROW=""
  for f in "${FIELDS[@]}"; do
    v=$(value_of "$RAW" "$f")
    [ -z "$v" ] && v="-"
    printf '%14s' "$v"
    ROW="${ROW},${v}"
  done
  printf '\n'
  [ -n "$CSVOUT" ] && printf '%s%s\n' "$TS" "$ROW" >> "$CSVOUT"
  sleep "$INTERVAL"
done
