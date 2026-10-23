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
#   --extra-cells "<arm>:<fraction> ..."   cells run in every repetition beside the ladder, shuffled
#                            with it, at a fraction of the same base (for an arm that does not need
#                            the whole ladder)
#   --slo-p99-ms <ms>        the p99 objective, recorded in campaign.json before the ladder starts;
#                            slo_ladder.py then reports each arm's highest rate inside it
#   --closed-cells "1x 4x"   closed-loop cells (wrk at saturation) beside the ladder, one per entry:
#                            the regime's connection count (the trial arguments' --connections, else
#                            100) times the entry's multiple, run for every arm, --closed-reps fresh
#                            JVMs each (default 7), shuffled with the ladder's cells. Directories
#                            are cl-r<rep>-<arm>-c<connections>.
#   --closed-connections "<c> ..."   --closed-max-connections "<m> ..."   --closed-pool "<p> ..."
#                            per-cell overrides aligned with --closed-cells; "-" keeps the regime's
#                            value. Without them the connection count is the multiple, the kernel's
#                            connection limit is raised to the count plus 1,024 when that exceeds it
#                            (default 4,096), and the pool is the regime's.
#   --kernel-repo <path>     --out-root <dir>  (default results/raw/loom-carrier-scheduler)
#   Arms D2 take their scheduler properties from arms/D2.properties; the campaign refuses to start
#   without the file, and records each file arm's property set and digest in campaign.json.
#   any other option is passed to every run-trial.sh call (layout, think time, poller mode, ...)
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL_COMMIT="" KERNEL_REPO="" BACKEND="" ARMS="A_iso C_iso D" REPS=5 SAT_REPS=3
CLOSED_CELLS="" CLOSED_REPS=7 CLOSED_CONNS="" CLOSED_MAXCONNS="" CLOSED_POOLS=""
FRACTIONS="0.5 0.7 0.85" RATES="" EXTRA_CELLS="" SLO_P99_MS="" SEED="$(date +%s)" OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler"
TRIAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel-commit) KERNEL_COMMIT="$2"; shift 2 ;;  --kernel-repo) KERNEL_REPO="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;              --arms) ARMS="$2"; shift 2 ;;
    --reps) REPS="$2"; shift 2 ;;                    --saturation-reps) SAT_REPS="$2"; shift 2 ;;
    --fractions) FRACTIONS="$2"; shift 2 ;;          --rates) RATES="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;                    --out-root) OUT_ROOT="$2"; shift 2 ;;
    --slo-p99-ms) SLO_P99_MS="$2"; shift 2 ;;      --extra-cells) EXTRA_CELLS="$2"; shift 2 ;;
    --closed-cells) CLOSED_CELLS="$2"; shift 2 ;;    --closed-reps) CLOSED_REPS="$2"; shift 2 ;;
    --closed-connections) CLOSED_CONNS="$2"; shift 2 ;;
    --closed-max-connections) CLOSED_MAXCONNS="$2"; shift 2 ;;
    --closed-pool) CLOSED_POOLS="$2"; shift 2 ;;
    *) TRIAL_ARGS+=("$1" "$2"); shift 2 ;;
  esac
done
[[ -n "$KERNEL_COMMIT" ]] || { echo "--kernel-commit is required" >&2; exit 2; }
[[ "$BACKEND" =~ ^(jdk|kernel)$ ]] || { echo "--backend must be jdk or kernel" >&2; exit 2; }

# Refused before anything is built or run: a file arm without its property file, or a malformed one.
ARM_PROPS_JSON="$(python3 "$SCRIPT_DIR/armcfg.py" campaign-json $ARMS)" || exit 2

# The last value a trial argument was given, or the default.
targ() {  # <option> <default>
  local i v="$2"
  for ((i = 0; i < ${#TRIAL_ARGS[@]}; i += 2)); do [[ "${TRIAL_ARGS[i]}" == "$1" ]] && v="${TRIAL_ARGS[i+1]}"; done
  echo "$v"
}

# Closed-loop cells: connection count, kernel connection limit and pool per entry of --closed-cells.
CL_CONN=() CL_ARGS=()
if [[ -n "$CLOSED_CELLS" ]]; then
  read -r -a _lv <<<"$CLOSED_CELLS"; read -r -a _cc <<<"$CLOSED_CONNS"
  read -r -a _cm <<<"$CLOSED_MAXCONNS"; read -r -a _cp <<<"$CLOSED_POOLS"
  _base="$(targ --connections 100)"; _maxc="$(targ --max-connections 4096)"
  for i in "${!_lv[@]}"; do
    [[ "${_lv[i]}" =~ ^[0-9]+x$ ]] || { echo "--closed-cells entries look like 1x, 4x; got '${_lv[i]}'" >&2; exit 2; }
    c="${_cc[i]:--}"; [[ "$c" == "-" ]] && c=$(( _base * ${_lv[i]%x} ))
    m="${_cm[i]:--}"
    if [[ "$m" == "-" ]]; then m="$_maxc"; (( c + 1024 > m )) && m=$(( c + 1024 )); fi
    a=(--connections "$c" --max-connections "$m"); p="${_cp[i]:--}"; [[ "$p" == "-" ]] || a+=(--pool "$p")
    CL_CONN+=("$c"); CL_ARGS+=("${a[*]}")
  done
fi

KERNEL_DIR="$("$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT" ${KERNEL_REPO:+"$KERNEL_REPO"})"
SHA12="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["kernel_commit"][:12])' "$KERNEL_DIR/kernel-identity.json")"
CAMPAIGN="$OUT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$BACKEND-k$SHA12"
mkdir -p "$CAMPAIGN"
ORDER="$CAMPAIGN/order.txt"
: >"$ORDER"

shuffle() {  # <salt> < lines  — deterministic for (seed, salt)
  python3 -c 'import random,sys; r=random.Random(f"{sys.argv[1]}-{sys.argv[2]}"); l=sys.stdin.read().split(); r.shuffle(l); print("\n".join(l))' "$SEED" "$1"
}

trial() {  # <name> <arm> <rate> [run-trial.sh options that override the campaign's]
  echo "$1" >>"$ORDER"
  "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KERNEL_DIR" --arm "$2" --backend "$BACKEND" --rate "$3" \
    --out "$CAMPAIGN/$1" "${TRIAL_ARGS[@]}" "${@:4}" || echo "{\"trial\": \"$1\", \"harness_error\": true}" >>"$CAMPAIGN/harness-errors.jsonl"
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
  rate_of() { python3 -c "import sys;print(int(round(float(sys.argv[1])*int(sys.argv[2]),-2)))" "$1" "$BASE"; }
  RATES="$(for f in $FRACTIONS; do rate_of "$f"; done | xargs)"
  EXTRA="$(for c in $EXTRA_CELLS; do echo "${c%%:*}@$(rate_of "${c#*:}")"; done | xargs)"
else
  BASE=""
  [[ -z "$EXTRA_CELLS" ]] || { echo "--extra-cells needs the saturation base; drop --rates" >&2; exit 2; }
  EXTRA=""
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
  "extra_cells": "$EXTRA",
  "seed": "$SEED",
  "slo_p99_ms": ${SLO_P99_MS:-null},
  "trial_args": "$(printf '%s ' "${TRIAL_ARGS[@]:-}")",
  "closed_cells": "$CLOSED_CELLS",
  "closed_reps": $( [[ -n "$CLOSED_CELLS" ]] && echo "$CLOSED_REPS" || echo null ),
  "closed_connections": "${CL_CONN[*]:-}",
  "arm_properties": $ARM_PROPS_JSON
}
EOF

TOTAL_REPS=$REPS
[[ -n "$CLOSED_CELLS" ]] && (( CLOSED_REPS > TOTAL_REPS )) && TOTAL_REPS=$CLOSED_REPS
for rep in $(seq 1 "$TOTAL_REPS"); do
  cells=()
  if (( rep <= REPS )); then
    for arm in $ARMS; do for rate in $RATES; do cells+=("$arm@$rate"); done; done
    for cell in $EXTRA; do cells+=("$cell"); done
  fi
  if [[ -n "$CLOSED_CELLS" ]] && (( rep <= CLOSED_REPS )); then
    for arm in $ARMS; do for i in "${!CL_CONN[@]}"; do cells+=("cl:$arm:$i"); done; done
  fi
  for cell in $(printf '%s\n' "${cells[@]}" | shuffle "ladder-$rep"); do
    if [[ "$cell" == cl:* ]]; then
      IFS=: read -r _ arm i <<<"$cell"
      read -r -a _ov <<<"${CL_ARGS[i]}"
      trial "cl-r$rep-$arm-c${CL_CONN[i]}" "$arm" max "${_ov[@]}"
    else
      trial "r$rep-${cell%@*}-${cell#*@}" "${cell%@*}" "${cell#*@}"
    fi
  done
done

python3 "$SCRIPT_DIR/summarize.py" "$CAMPAIGN"
[[ -n "$SLO_P99_MS" ]] && python3 "$SCRIPT_DIR/slo_ladder.py" "$CAMPAIGN"
echo "$CAMPAIGN"
