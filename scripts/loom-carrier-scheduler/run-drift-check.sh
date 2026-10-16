#!/usr/bin/env bash
# run-drift-check.sh — separate the two recorded changes between the CPU-bound campaigns.
#
# The floating arms' CPU-bound tails are higher on harness 8b915264 than on 84685a1c at the same
# rates, and two recorded changes lie between them: the benchmark app's backend pool (a
# LinkedBlockingDeque before e33e9595, a fair Semaphore over a ConcurrentLinkedDeque since) and
# the trial's descriptor limits (systemd's unit default, soft 1024 / hard 524288, before c6979e96;
# 1048576 since). This runs A_iso at one rate in all four combinations, and D in the current one
# as a control: a cause that moves A_iso's tail and leaves D's alone is what the stacking mechanism
# predicts.
#
# Cells (CPU-bound regime: 1 ms backend, 100 connections, pollerMode 3, open-loop warmup 30 s):
#   A_iso  pool {old, new} x limits {old, new}     D  pool new, limits new
# REPS fresh JVMs per cell, the cells of each repetition in a recorded shuffled order. Trials carry
# no recorder; their latencies are results about these cells, not about the ladder campaigns.
#
# Run as root from a text console, inside tmux, with the graphical session stopped:
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s drift
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo scripts/loom-carrier-scheduler/run-drift-check.sh
#   sudo systemctl isolate graphical.target
#
# Environment (defaults in brackets):
#   KERNEL_COMMIT [bc26f9a0e8fc]   RATE [52200]   REPS [5]   SYS_CPUS [0,6]   BOOST [off]
#   OLD_APP_COMMIT [84685a1c]      OLD_NOFILE [1024:524288]
#
# On any exit the shield is reverted and perf_event_paranoid restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"

KERNEL_COMMIT="${KERNEL_COMMIT:-bc26f9a0e8fc}"
RATE="${RATE:-52200}"
REPS="${REPS:-5}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"
OLD_APP_COMMIT="${OLD_APP_COMMIT:-84685a1c}"
OLD_NOFILE="${OLD_NOFILE:-1024:524288}"
CELLS="A_iso:old:old A_iso:old:new A_iso:new:old A_iso:new:new D:new:new"

CPU_ARGS=(--backend jdk --poller-mode 3 --warmup-mode open --warmup 30)

die() { echo "run-drift-check: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

# --- inner: the trial loop, run as the benchmark user inside the shield -----------------------------
if [[ "${1:-}" == "--inner" ]]; then
  OUT_ROOT="$2"
  mkdir -p "$OUT_ROOT"
  KDIR="$("$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT" | tail -1)"
  [[ -f "$KDIR/kernel-cp.txt" ]] || die "kernel build not found at $KDIR"
  cp "$KDIR/kernel-identity.json" "$OUT_ROOT/kernel-identity.json"
  OLD_APP="$OUT_ROOT/app-$OLD_APP_COMMIT"
  mkdir -p "$OLD_APP"
  git -C "$BENCH_ROOT" archive "$OLD_APP_COMMIT" targets/exeris-loom-scheduler-app | tar -x -C "$OLD_APP"
  OLD_APP="$OLD_APP/targets/exeris-loom-scheduler-app"
  seed="$(date +%s)"
  {
    echo "seed=$seed harness=$(git -C "$BENCH_ROOT" rev-parse HEAD) rate=$RATE reps=$REPS"
    echo "pool old = app at $OLD_APP_COMMIT; pool new = this checkout's app"
    echo "limits old = $OLD_NOFILE; limits new = the shield's, raised to the hard limit"
  } >"$OUT_ROOT/plan.txt"
  : >"$OUT_ROOT/order.txt"
  for r in $(seq 1 "$REPS"); do
    for c in $CELLS; do echo "r$r $c"; done | shuf --random-source=<(yes "$seed$r") >>"$OUT_ROOT/order.txt"
  done
  n=0; total="$(wc -l <"$OUT_ROOT/order.txt")"
  while read -r rep cell; do
    n=$((n + 1))
    IFS=: read -r arm pool limits <<<"$cell"
    dir="$OUT_ROOT/$rep-$arm-pool$pool-fd$limits"
    extra=()
    [[ "$pool" == "old" ]] && extra+=(--app-src "$OLD_APP")
    [[ "$limits" == "old" ]] && extra+=(--nofile "$OLD_NOFILE")
    log "[$n/$total] $arm pool=$pool limits=$limits"
    "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KDIR" --arm "$arm" --rate "$RATE" "${CPU_ARGS[@]}" \
      "${extra[@]}" --out "$dir" >"$dir.log" 2>&1 || log "  trial failed, see $dir.log"
  done <"$OUT_ROOT/order.txt"
  python3 "$SCRIPT_DIR/summarize_drift.py" "$OUT_ROOT" || log "summary failed"
  exit 0
fi

# --- outer: host preparation, as root ----------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
[[ -n "${TMUX:-}${STY:-}" ]] || log "warning: not inside tmux or screen; a dropped console ends the run"
git -C "$BENCH_ROOT" cat-file -e "$OLD_APP_COMMIT^{commit}" || die "commit $OLD_APP_COMMIT not found"

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
restore() {
  local rc=$?
  log "restoring host"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT

# perf stat gives each trial its CPUs utilised, one of the quantities the campaigns compare.
sysctl -q kernel.perf_event_paranoid=-1
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"
"$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT"

HSHA="$(git -C "$BENCH_ROOT" rev-parse --short=12 HEAD)"
OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler-drift/$(date -u +%Y%m%dT%H%M%SZ)-h$HSHA"

log "drift check into $OUT_ROOT"
"$SHIELD" run -- env KERNEL_COMMIT="$KERNEL_COMMIT" RATE="$RATE" REPS="$REPS" \
  OLD_APP_COMMIT="$OLD_APP_COMMIT" OLD_NOFILE="$OLD_NOFILE" \
  "$SCRIPT_DIR/run-drift-check.sh" --inner "$OUT_ROOT"
log "summary: $OUT_ROOT/summary.md"
