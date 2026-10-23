#!/usr/bin/env bash
# run-v2-pilot.sh — the scheduler-v2 pilot for one regime. Not evidence.
#
# The pilot decides what the registered measurement will use: the property set frozen as arm D2, and
# the rig configuration under which the carriers, not the mock backend or the pool, reach their
# limit. Every trial is marked "v2 pilot", so the unperturbed gate fails and no trial is evidence,
# whatever the host state; trials also carry the scheduler's counters (arms that run it) and
# per-thread context-switch and futex counts.
#
# Two blocks, REPS fresh JVMs per cell (default 3), all cells of a repetition shuffled with a
# recorded seed:
#
#  variants  D, B_pin and the cumulative property sets arms/pilot/*.properties (arm Dv), each at
#            50 % and 85 % of A_iso's saturation (and 70 % in the I/O-bound regime) and at
#            saturation (closed loop).
#  headroom  B_pin and P0132: rungs of 100-130 % in steps of 5 %, and a sweep of connection count
#            (and, in the I/O-bound regime, backend pool size) at saturation and at 115 %, with the
#            mock's CPU, the carriers' CPU and p50 recorded, so the summary can say which resource
#            saturates first.
#
# Run one regime per boot, as root from a text console, inside tmux, with the graphical session
# stopped:
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s pilot
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo KERNEL_NEW=<rev> REGIME=cpu scripts/loom-carrier-scheduler/run-v2-pilot.sh
#
# Environment (defaults in brackets):
#   KERNEL_NEW (required)   REGIME (required: cpu or io)   KERNEL_REPO   REPS [3]
#   BASE [A_iso's saturation of the capacity ladders in the regime, v2-regimes.sh]
#   VARIANT_ARMS ["D B_pin P0 P01 P013 P0132 P0132-prio P0132-lifo"]; a name that is not D or B_pin
#       is a pilot cell, arms/pilot/<name>.properties
#   FRACTIONS [cpu "0.5 0.85", io "0.5 0.7 0.85"]   RUNGS ["1.00 1.05 ... 1.30"]
#   HEADROOM_ARMS ["B_pin P0132"]
#   CONN_SWEEP [cpu "100 200 400", io "5000 10000"]   POOL_SWEEP [cpu "", io "2048 4096"]
#   CPU_LOAD_ARGS, IO_LOAD_ARGS (v2-regimes.sh)   SYS_CPUS [0,6]   BOOST [off]
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"
# shellcheck source=v2-regimes.sh
source "$SCRIPT_DIR/v2-regimes.sh"

KERNEL_NEW="${KERNEL_NEW:-}"
KERNEL_REPO="${KERNEL_REPO:-}"
REGIME="${REGIME:-}"
REPS="${REPS:-3}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"
VARIANT_ARMS="${VARIANT_ARMS:-D B_pin P0 P01 P013 P0132 P0132-prio P0132-lifo}"
HEADROOM_ARMS="${HEADROOM_ARMS:-B_pin P0132}"
RUNGS="${RUNGS:-1.00 1.05 1.10 1.15 1.20 1.25 1.30}"

die() { echo "run-v2-pilot: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

[[ -n "$KERNEL_NEW" ]] || die "KERNEL_NEW is required"
[[ "$REGIME" =~ ^(cpu|io)$ ]] || die "REGIME must be cpu or io"
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
grep -q '^nf_conntrack ' /proc/modules \
  && log "warning: nf_conntrack is loaded; the pilot is not evidence either way, but its rates are read against a host that may differ from the campaign's"
[[ -n "${TMUX:-}${STY:-}" ]] || log "warning: not inside tmux or screen; a dropped console ends the run"
for v in $VARIANT_ARMS $HEADROOM_ARMS; do
  [[ "$v" == "D" || "$v" == "B_pin" || -f "$SCRIPT_DIR/arms/pilot/$v.properties" ]] \
    || die "no pilot cell $v (arms/pilot/$v.properties)"
done

if [[ "$REGIME" == cpu ]]; then
  FRACTIONS="${FRACTIONS:-0.5 0.85}"; CONN_SWEEP="${CONN_SWEEP:-100 200 400}"; POOL_SWEEP="${POOL_SWEEP-}"
else
  FRACTIONS="${FRACTIONS:-0.5 0.7 0.85}"; CONN_SWEEP="${CONN_SWEEP:-5000 10000}"; POOL_SWEEP="${POOL_SWEEP-2048 4096}"
fi
BASE="${BASE:-$(regime_value "$REGIME" BASE_CPU BASE_IO)}"
regime_load_args "$REGIME"
# The regime's own connection count, pool and kernel connection limit; a sweep value equal to them
# is the baseline cell and is not run twice.
opt_of() {  # <option> <default>
  local i v="$2"
  for ((i = 0; i < ${#REGIME_ARGS[@]}; i++)); do [[ "${REGIME_ARGS[i]}" == "$1" ]] && v="${REGIME_ARGS[i+1]}"; done
  echo "$v"
}
DEF_CONN="$(opt_of --connections 100)"; DEF_POOL="$(opt_of --pool 128)"; DEF_MAXC="$(opt_of --max-connections 4096)"

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
restore() {
  local rc=$?
  log "restoring host"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT
sysctl -q kernel.perf_event_paranoid=-1
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"
KDIR="$("$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_NEW" ${KERNEL_REPO:+"$KERNEL_REPO"} | tr -d '\r' | tail -1)"
[[ -f "$KDIR/kernel-cp.txt" ]] || die "kernel build not found at $KDIR"
SHA12="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["kernel_commit"][:12])' "$KDIR/kernel-identity.json")"

rate_of() {  # <fraction>
  python3 -c "import sys;print(int(round(float(sys.argv[1])*int(sys.argv[2]),-2)))" "$1" "$BASE"
}
OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler-v2-pilot/$(date -u +%Y%m%dT%H%M%SZ)-$REGIME-k$SHA12"
mkdir -p "$OUT_ROOT"
seed="$(date +%s)"

# One cell per line: <block>|<cell>|<rate or max>|<connections>|<pool>, then the repetition.
cells=()
for v in $VARIANT_ARMS; do
  for f in $FRACTIONS; do cells+=("var|$v|$(rate_of "$f")|$DEF_CONN|$DEF_POOL"); done
  cells+=("var|$v|max|$DEF_CONN|$DEF_POOL")
done
for v in $HEADROOM_ARMS; do
  for f in $RUNGS; do cells+=("rung|$v|$(rate_of "$f")|$DEF_CONN|$DEF_POOL"); done
  for c in $CONN_SWEEP; do
    [[ "$c" == "$DEF_CONN" ]] && continue
    cells+=("conn|$v|max|$c|$DEF_POOL" "conn|$v|$(rate_of 1.15)|$c|$DEF_POOL")
  done
  for p in $POOL_SWEEP; do
    [[ "$p" == "$DEF_POOL" ]] && continue
    cells+=("pool|$v|max|$DEF_CONN|$p" "pool|$v|$(rate_of 1.15)|$DEF_CONN|$p")
  done
done
{
  echo "seed=$seed harness=$(git -C "$BENCH_ROOT" rev-parse HEAD) kernel=$SHA12 regime=$REGIME reps=$REPS"
  echo "base_rps=$BASE (A_iso saturation of the capacity ladders; not re-measured here)"
  echo "variant_arms=$VARIANT_ARMS headroom_arms=$HEADROOM_ARMS"
  echo "fractions=$FRACTIONS rungs=$RUNGS conn_sweep=$CONN_SWEEP pool_sweep=$POOL_SWEEP"
  echo "default_connections=$DEF_CONN default_pool=$DEF_POOL regime_args=${REGIME_ARGS[*]}"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)"
} >"$OUT_ROOT/plan.txt"
: >"$OUT_ROOT/order.txt"
for r in $(seq 1 "$REPS"); do
  printf '%s\n' "${cells[@]}" \
    | python3 -c 'import random,sys; r=random.Random(sys.argv[1]); l=sys.stdin.read().split(); r.shuffle(l); print("\n".join(l))' "$seed-$r" \
    | sed "s/^/r$r /" >>"$OUT_ROOT/order.txt"
done
chown -R "$SUDO_USER": "$OUT_ROOT"

log "pilot ($REGIME, ${#cells[@]} cells x $REPS) into $OUT_ROOT"
mapfile -t ORDER <"$OUT_ROOT/order.txt"
n=0; total="${#ORDER[@]}"
for line in "${ORDER[@]}"; do
  n=$((n + 1))
  read -r rep spec <<<"$line"
  IFS='|' read -r block cell rate conn pool <<<"$spec"
  arm_args=(--arm "$cell")
  stats=()
  case "$cell" in
    D) stats=(--stats) ;;
    B_pin) ;;
    *) arm_args=(--arm Dv --variant "$cell"); stats=(--stats) ;;
  esac
  over=()
  if [[ "$conn" != "$DEF_CONN" ]]; then
    over+=(--connections "$conn"); m="$DEF_MAXC"; (( conn + 1024 > m )) && m=$(( conn + 1024 )); over+=(--max-connections "$m")
  fi
  [[ "$pool" != "$DEF_POOL" ]] && over+=(--pool "$pool")
  dir="$OUT_ROOT/$block-$rep-$cell-$rate-c$conn-p$pool"
  log "[$n/$total] $block $cell rate=$rate connections=$conn pool=$pool"
  "$SHIELD" run -- "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KDIR" "${arm_args[@]}" "${stats[@]}" --pilot \
    --backend jdk --rate "$rate" "${COMMON_TRIAL_ARGS[@]}" "${REGIME_ARGS[@]}" "${over[@]}" --out "$dir" >"$dir.log" 2>&1 \
    || log "  trial failed, see $dir.log"
done
chown -R "$SUDO_USER": "$OUT_ROOT"
sudo -u "$SUDO_USER" python3 "$SCRIPT_DIR/summarize_v2_pilot.py" "$OUT_ROOT" || log "summary failed"
log "summary: $OUT_ROOT/summary.md"
