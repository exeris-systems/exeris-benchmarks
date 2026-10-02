#!/usr/bin/env bash
# run-campaign.sh — a loom-carrier-scheduler campaign: saturation probe, then a fixed-rate ladder.
#
# 1. Build the kernel at one commit (build-kernel.sh); every trial records that identity.
# 2. Saturation: each arm closed-loop (wrk), --saturation-reps fresh JVMs, arm order shuffled per
#    repetition. The ladder base is the median saturation of the A_iso arm over its valid trials.
# 3. Ladder: every arm at every rate (--fractions x base), --reps fresh JVMs per cell, the full
#    (arm, rate) order shuffled per repetition with a recorded seed.
# 4. summarize.py writes summary.md / summary.json from the trial.json files.
#
# Usage:
#   scripts/loom-carrier-scheduler/run-campaign.sh --kernel-commit <rev> --backend jdk|kernel [options]
#
# Options:
#   --arms "A_iso C_iso D"   --reps 5   --saturation-reps 3   --fractions "0.5 0.7 0.85"
#   --rates "<r1> <r2> ..."  fixed ladder instead of fractions (skips the saturation step)
#   --seed <int>             shuffle seed (default: from the clock, recorded)
#   --kernel-repo <path>     --out-root <dir>  (default results/raw/loom-carrier-scheduler)
#   any other option is passed to every run-trial.sh call (layout, think time, poller mode, ...)
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL_COMMIT="" KERNEL_REPO="" BACKEND="" ARMS="A_iso C_iso D" REPS=5 SAT_REPS=3
FRACTIONS="0.5 0.7 0.85" RATES="" SEED="$(date +%s)" OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler"
TRIAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel-commit) KERNEL_COMMIT="$2"; shift 2 ;;  --kernel-repo) KERNEL_REPO="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;              --arms) ARMS="$2"; shift 2 ;;
    --reps) REPS="$2"; shift 2 ;;                    --saturation-reps) SAT_REPS="$2"; shift 2 ;;
    --fractions) FRACTIONS="$2"; shift 2 ;;          --rates) RATES="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;                    --out-root) OUT_ROOT="$2"; shift 2 ;;
    *) TRIAL_ARGS+=("$1" "$2"); shift 2 ;;
  esac
done
[[ -n "$KERNEL_COMMIT" ]] || { echo "--kernel-commit is required" >&2; exit 2; }
[[ "$BACKEND" =~ ^(jdk|kernel)$ ]] || { echo "--backend must be jdk or kernel" >&2; exit 2; }

KERNEL_DIR="$("$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT" ${KERNEL_REPO:+"$KERNEL_REPO"})"
SHA12="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["kernel_commit"][:12])' "$KERNEL_DIR/kernel-identity.json")"
CAMPAIGN="$OUT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$BACKEND-k$SHA12"
mkdir -p "$CAMPAIGN"
ORDER="$CAMPAIGN/order.txt"
: >"$ORDER"

shuffle() {  # <salt> < lines  — deterministic for (seed, salt)
  python3 -c 'import random,sys; r=random.Random(f"{sys.argv[1]}-{sys.argv[2]}"); l=sys.stdin.read().split(); r.shuffle(l); print("\n".join(l))' "$SEED" "$1"
}

trial() {  # <name> <arm> <rate>
  echo "$1" >>"$ORDER"
  "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KERNEL_DIR" --arm "$2" --backend "$BACKEND" --rate "$3" \
    --out "$CAMPAIGN/$1" "${TRIAL_ARGS[@]}" || echo "{\"trial\": \"$1\", \"harness_error\": true}" >>"$CAMPAIGN/harness-errors.jsonl"
}

if [[ -z "$RATES" ]]; then
  for rep in $(seq 1 "$SAT_REPS"); do
    for arm in $(printf '%s\n' $ARMS | shuffle "sat-$rep"); do
      trial "sat-r$rep-$arm" "$arm" max
    done
  done
  BASE="$(python3 - "$CAMPAIGN" <<'EOF'
import json, statistics, sys
from pathlib import Path
vals = []
for p in Path(sys.argv[1]).glob("sat-*-A_iso/trial.json"):
    t = json.loads(p.read_text())
    if t["valid"] and t["load"]["requests_per_sec"]:
        vals.append(t["load"]["requests_per_sec"])
print(int(statistics.median(vals)) if vals else 0)
EOF
)"
  [[ "$BASE" -gt 0 ]] || { echo "no valid A_iso saturation trial; ladder cannot be set" >&2; exit 1; }
  RATES="$(for f in $FRACTIONS; do python3 -c "import sys;print(int(round(float(sys.argv[1])*int(sys.argv[2]),-2)))" "$f" "$BASE"; done | xargs)"
else
  BASE=""
fi

cat >"$CAMPAIGN/campaign.json" <<EOF
{
  "schema": "loom-carrier-scheduler-campaign/1",
  "kernel_commit_requested": "$KERNEL_COMMIT",
  "backend": "$BACKEND",
  "arms": "$(echo $ARMS)",
  "reps": $REPS,
  "saturation_reps": $SAT_REPS,
  "ladder_base_a_iso_rps": ${BASE:-null},
  "fractions": "$( [[ -n "$BASE" ]] && echo "$FRACTIONS" )",
  "rates": "$RATES",
  "seed": "$SEED",
  "trial_args": "$(printf '%s ' "${TRIAL_ARGS[@]:-}")"
}
EOF

for rep in $(seq 1 "$REPS"); do
  cells=()
  for arm in $ARMS; do for rate in $RATES; do cells+=("$arm@$rate"); done; done
  for cell in $(printf '%s\n' "${cells[@]}" | shuffle "ladder-$rep"); do
    trial "r$rep-${cell%@*}-${cell#*@}" "${cell%@*}" "${cell#*@}"
  done
done

python3 "$SCRIPT_DIR/summarize.py" "$CAMPAIGN"
echo "$CAMPAIGN"
