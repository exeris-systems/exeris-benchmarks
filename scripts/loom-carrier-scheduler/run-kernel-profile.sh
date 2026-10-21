#!/usr/bin/env bash
# run-kernel-profile.sh — where the carriers' kernel time goes, on this host in its current state.
#
# The floating arms' CPU-bound tail and the carriers' kernel time are higher on a host that has run
# for most of a day than on a freshly booted one, with the app's backend pool and the descriptor
# limit ruled out. This run is meant to be taken twice — within minutes of a boot, and again after
# a day of the host's ordinary use — and the two compared with kernel_profile.py compare:
#
#   clean    A_iso at RATE, no recorder: the tail and carrier CPU of the state, comparable with the
#            campaigns' cells (52,200 req/s is the CPU-bound campaigns' 70 % rung)
#   profiled A_iso at RATE with perf record -g on the carrier CPUs: the kernel symbols the extra
#            time is spent in
#   control  D at RATE with the same recorder: pinned carriers in the same state
#
# Every trial also records the host's boot, uptime and, at both ends of its window, the tracked
# connections, dying memory cgroups, unreclaimable slab and TCP socket counts.
#
# Run as root from a text console, inside tmux, with the graphical session stopped:
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s kprof
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo scripts/loom-carrier-scheduler/run-kernel-profile.sh
#   sudo systemctl isolate graphical.target
#
# Then, with two runs:
#   scripts/loom-carrier-scheduler/kernel_profile.py compare <fresh-run-dir> <long-uptime-run-dir>
#
# Environment (defaults in brackets):
#   KERNEL_COMMIT [bc26f9a0e8fc]   RATE [52200]   REPS [3]   SYS_CPUS [0,6]   BOOST [off]
#
# On any exit the shield is reverted and perf_event_paranoid and kptr_restrict restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"

KERNEL_COMMIT="${KERNEL_COMMIT:-bc26f9a0e8fc}"
RATE="${RATE:-52200}"
REPS="${REPS:-3}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"
CELLS="A_iso:clean A_iso:profiled D:profiled"

CPU_ARGS=(--backend jdk --poller-mode 3 --warmup-mode open --warmup 30)

die() { echo "run-kernel-profile: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

# --- inner: the trial loop, run as the benchmark user inside the shield -----------------------------
if [[ "${1:-}" == "--inner" ]]; then
  OUT_ROOT="$2"
  mkdir -p "$OUT_ROOT"
  KDIR="$("$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT" | tail -1)"
  [[ -f "$KDIR/kernel-cp.txt" ]] || die "kernel build not found at $KDIR"
  cp "$KDIR/kernel-identity.json" "$OUT_ROOT/kernel-identity.json"
  seed="$(date +%s)"
  {
    echo "seed=$seed harness=$(git -C "$BENCH_ROOT" rev-parse HEAD) rate=$RATE reps=$REPS"
    echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)"
  } >"$OUT_ROOT/plan.txt"
  : >"$OUT_ROOT/order.txt"
  for r in $(seq 1 "$REPS"); do
    for c in $CELLS; do echo "r$r $c"; done \
      | python3 -c 'import random,sys; r=random.Random(sys.argv[1]); l=sys.stdin.read().splitlines(); r.shuffle(l); print("\n".join(l))' "$seed-$r" \
      >>"$OUT_ROOT/order.txt"
  done
  n=0; total="$(wc -l <"$OUT_ROOT/order.txt")"
  while read -r rep cell; do
    n=$((n + 1))
    IFS=: read -r arm kind <<<"$cell"
    dir="$OUT_ROOT/$rep-$arm-$kind"
    extra=()
    [[ "$kind" == "profiled" ]] && extra+=(--perf-record)
    log "[$n/$total] $arm $kind"
    "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KDIR" --arm "$arm" --rate "$RATE" "${CPU_ARGS[@]}" \
      "${extra[@]}" --out "$dir" >"$dir.log" 2>&1 || log "  trial failed, see $dir.log"
  done <"$OUT_ROOT/order.txt"
  python3 "$SCRIPT_DIR/kernel_profile.py" summary "$OUT_ROOT" || log "summary failed"
  exit 0
fi

# --- outer: host preparation, as root ----------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
[[ -n "${TMUX:-}${STY:-}" ]] || log "warning: not inside tmux or screen; a dropped console ends the run"
command -v perf >/dev/null || die "perf not found"
log "host up $(awk '{printf "%.1f", $1 / 3600}' /proc/uptime) h (this run's state is the point; no warning applies)"

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
PREV_KPTR="$(cat /proc/sys/kernel/kptr_restrict)"
restore() {
  local rc=$?
  log "restoring host"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  sysctl -q kernel.kptr_restrict="$PREV_KPTR" || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT

sysctl -q kernel.perf_event_paranoid=-1
# Kernel symbols resolve for the benchmark user only with kernel pointers unrestricted.
sysctl -q kernel.kptr_restrict=0
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"
"$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT"

HSHA="$(git -C "$BENCH_ROOT" rev-parse --short=12 HEAD)"
OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler-kprof/$(date -u +%Y%m%dT%H%M%SZ)-h$HSHA"

log "kernel profile into $OUT_ROOT"
"$SHIELD" run -- env KERNEL_COMMIT="$KERNEL_COMMIT" RATE="$RATE" REPS="$REPS" \
  "$SCRIPT_DIR/run-kernel-profile.sh" --inner "$OUT_ROOT"
log "summary: $OUT_ROOT/summary.md"
