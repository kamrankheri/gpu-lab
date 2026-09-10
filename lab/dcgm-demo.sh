#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dcgm-demo.sh - run the GPU workload and DCGM sampling at the same time.
#
#   ./dcgm-demo.sh [seconds_per_phase]     default 90
#
# Uses native dcgmi, which the Deep Learning AMI already ships. No container,
# no SYS_ADMIN, no port mapping.
#
# Fields sampled:
#   203    DCGM_FI_DEV_GPU_UTIL       what every dashboard shows
#   1001   GRACT   graphics/compute engine active
#   1002   SMACT   fraction of SMs with work
#   1003   SMOCC   warp occupancy
#   1004   TENSO   tensor pipe active   <- the one that matters
#   1005   DRAMA   memory bandwidth active
#
# Verify the IDs on your build:  dcgmi dmon -l
# ---------------------------------------------------------------------------
set -uo pipefail

SECONDS_PER_PHASE="${1:-90}"
FIELDS="${FIELDS:-203,1001,1002,1003,1004,1005}"
LOG="${LOG:-$HOME/dcgm-log.txt}"

command -v dcgmi >/dev/null || { echo "dcgmi not found"; exit 1; }
[ -f gpu-workload.py ] || { echo "gpu-workload.py not in $(pwd)"; exit 1; }

echo "sampling fields $FIELDS -> $LOG"
echo

# -d is the delay between samples in milliseconds.
dcgmi dmon -e "$FIELDS" -d 1000 > "$LOG" 2>&1 &
DMON=$!
# Kill the sampler even if the workload crashes or you ctrl-C.
trap 'kill $DMON 2>/dev/null' EXIT INT TERM

sleep 3
echo "--- baseline: 15s idle ---"
sleep 15

python3 gpu-workload.py --phase both --seconds "$SECONDS_PER_PHASE"

sleep 5
kill $DMON 2>/dev/null
wait $DMON 2>/dev/null

echo
echo "==========================================================="
echo "  sampled $(grep -c '^GPU' "$LOG" 2>/dev/null) rows -> $LOG"
echo "==========================================================="
echo
echo "First 5 idle samples:"
grep '^GPU' "$LOG" | head -5
echo
echo "Peak per column across the whole run:"
grep '^GPU' "$LOG" | awk '
  { for (i = 3; i <= NF; i++) if ($i + 0 > max[i]) max[i] = $i + 0 }
  END { printf "  "; for (i = 3; i <= NF; i++) printf "%10.3f", max[i]; printf "\n" }'
echo
echo "Read the full log with:  less $LOG"
echo "Phase 1 (trivial) and phase 2 (tensor) are separated by a 30s idle gap."