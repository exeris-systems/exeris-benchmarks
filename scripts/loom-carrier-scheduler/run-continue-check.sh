#!/usr/bin/env bash
# run-continue-check.sh — does B_pin's onContinue path move its results?
#
# B_pin (PinnedForkJoinScheduler) lazy-submits a continuation unparked from a virtual thread on one
# of its workers, without signalling an idle worker; the built-in scheduler's onContinue calls
# execute(), which may signal one. This runs B_pin both ways in one boot and one host state:
#
#   lazy     -Dloom.bench.pinned.continue=lazy, the arm the capacity ladders measured
#   execute  -Dloom.bench.pinned.continue=execute, the built-in scheduler's path
#
# Cells: B_pin lazy and execute at 85 % of A_iso's saturation in both regimes (the capacity ladders'
# rates, v2-regimes.sh), REPS fresh JVMs per cell, all cells of a repetition in a recorded shuffled
# order. Trials carry no recorder. The kernel is the capacity ladders' commit, so only the mode differs.
#
# Run as root from a text console, inside tmux, with the graphical session stopped, in a boot in
# which the Docker daemon has not run:
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s continue
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo scripts/loom-carrier-scheduler/run-continue-check.sh
#   sudo systemctl isolate graphical.target
#
# Environment (defaults in brackets):
#   KERNEL_COMMIT [bc26f9a0e8fc]   REPS [5]   SYS_CPUS [0,6]   BOOST [off]
#   EQUIV_RATE_CPU, EQUIV_RATE_IO, CPU_LOAD_ARGS, IO_LOAD_ARGS (v2-regimes.sh)
#
# On any exit the shield is reverted and perf_event_paranoid restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"
# shellcheck source=v2-regimes.sh
source "$SCRIPT_DIR/v2-regimes.sh"

KERNEL_COMMIT="${KERNEL_COMMIT:-bc26f9a0e8fc}"
REPS="${REPS:-5}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"
CELLS="cpu:lazy cpu:execute io:lazy io:execute"

die() { echo "run-continue-check: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
# The result is cited; a trial with connection tracking loaded fails the host_untracked evidence gate.
grep -q '^nf_conntrack ' /proc/modules \
  && die "nf_conntrack is loaded (the Docker daemon loads it and it stays until reboot); start from a boot in which the daemon has not run"
[[ -n "${TMUX:-}${STY:-}" ]] || log "warning: not inside tmux or screen; a dropped console ends the run"

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
restore() {
  local rc=$?
  log "restoring host"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT

# perf stat gives each trial its CPUs utilised and context switches.
sysctl -q kernel.perf_event_paranoid=-1
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"
# The shield runs commands on a pseudo-terminal, so captured output ends its lines with CR.
KDIR="$("$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT" | tr -d '\r' | tail -1)"
[[ -f "$KDIR/kernel-cp.txt" ]] || die "kernel build not found at $KDIR"

HSHA="$(git -C "$BENCH_ROOT" rev-parse --short=12 HEAD)"
OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler-continue/$(date -u +%Y%m%dT%H%M%SZ)-h$HSHA"
mkdir -p "$OUT_ROOT"
cp "$KDIR/kernel-identity.json" "$OUT_ROOT/kernel-identity.json"
seed="$(date +%s)"
{
  echo "seed=$seed harness=$(git -C "$BENCH_ROOT" rev-parse HEAD) reps=$REPS"
  echo "rate_cpu=$EQUIV_RATE_CPU rate_io=$EQUIV_RATE_IO cpu_args=$CPU_LOAD_ARGS io_args=$IO_LOAD_ARGS"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)"
  echo "lazy = -Dloom.bench.pinned.continue=lazy; execute = -Dloom.bench.pinned.continue=execute"
} >"$OUT_ROOT/plan.txt"
: >"$OUT_ROOT/order.txt"
for r in $(seq 1 "$REPS"); do
  for c in $CELLS; do echo "r$r $c"; done \
    | python3 -c 'import random,sys; r=random.Random(sys.argv[1]); l=sys.stdin.read().splitlines(); r.shuffle(l); print("\n".join(l))' "$seed-$r" \
    >>"$OUT_ROOT/order.txt"
done
chown -R "$SUDO_USER": "$OUT_ROOT"

log "continue check into $OUT_ROOT"
# The order is read up front: the shield's pseudo-terminal would consume a loop's standard input.
mapfile -t ORDER <"$OUT_ROOT/order.txt"
n=0; total="${#ORDER[@]}"
for line in "${ORDER[@]}"; do
  n=$((n + 1))
  read -r rep cell <<<"$line"
  IFS=: read -r regime mode <<<"$cell"
  regime_load_args "$regime"
  rate="$(regime_value "$regime" EQUIV_RATE_CPU EQUIV_RATE_IO)"
  dir="$OUT_ROOT/$rep-B_pin-$mode-$regime"
  log "[$n/$total] B_pin $mode $regime rate=$rate"
  "$SHIELD" run -- "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KDIR" --arm B_pin --pinned-continue "$mode" \
    --backend jdk --rate "$rate" "${COMMON_TRIAL_ARGS[@]}" "${REGIME_ARGS[@]}" --out "$dir" >"$dir.log" 2>&1 \
    || log "  trial failed, see $dir.log"
done
chown -R "$SUDO_USER": "$OUT_ROOT"
sudo -u "$SUDO_USER" python3 "$SCRIPT_DIR/summarize_continue.py" "$OUT_ROOT" || log "summary failed"
log "summary: $OUT_ROOT/summary.md"
