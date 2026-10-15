#!/usr/bin/env bash
# run-diagnostics.sh — diagnostic trials for the cells the I/O-bound campaign could not explain.
#
# Not a campaign: every trial here carries a recorder, so none of its latencies is a result. Each
# trial runs a latency probe (latency_probe.py) whose timeline locates the slow windows, plus one
# recorder, and analyze_diag.py cuts the recording to those windows:
#
#   light  probe + GC/safepoint logs                       (the least perturbed timeline)
#   sched  light + scheduler trace of every CPU, 20 s from 20 s into the window
#   wall   light + async-profiler wall clock, JFR output
#   jfr    light + JFR, virtual-thread pinning from 1 ms
#   ctl    light + backend trace (pool connections, mock threads), mock idle timeout at its default
#   idle   ctl with the mock's idle timeout raised to 600 s
#
# Cells, I/O-bound regime (30 ms backend, 5,000 connections, pool 2,048), at the campaign's rates,
# written arm:rate[:pollerMode] (pollerMode 3 unless given):
#   D      43300 (70 %)  bimodal across JVMs, worst arm at that rate
#   C_iso  52600 (85 %)  floating carriers, worst cell of the campaign
#   A_iso  52600 (85 %)  floating carriers, stock scheduler
#
# A second block runs POLLER_KINDS (default `light`) only, POLLER_REPS fresh JVMs per cell, to test one
# explanation for D at 70 %: with jdk.pollerMode=3 each read sub-poller is a virtual thread bound
# to one carrier, queued behind everything else on that carrier's FIFO, and a late sub-poller
# delays every backend socket it watches. pollerMode=1 moves the read pollers to platform threads
# on the auxiliary CPUs. If the bimodality goes with it, the sub-poller is the cause.
#
# Run as root from a text console, inside tmux, with the graphical session stopped, as for
# run-sequence.sh:
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s diag
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo scripts/loom-carrier-scheduler/run-diagnostics.sh
#   sudo systemctl isolate graphical.target
#
# Environment (defaults in brackets):
#   KERNEL_COMMIT [bc26f9a0e8fc]   REPS [3] per (cell, kind)   SYS_CPUS [0,6]   BOOST [off]
#   CELLS ["D:43300 C_iso:52600 A_iso:52600"]   KINDS ["light sched wall jfr"]
#   POLLER_CELLS ["D:43300:1 D:43300:3"]   POLLER_REPS [6]   POLLER_KINDS [light]
#
# The backend test: D at 70 % stalls once at a fixed point ~52 s into the window, while the mock's
# CPU jumps to its limit and the server's carriers and reactors rise with it. `ctl` records what
# changes in that second: the server's connections on both sides by TCP state, the mock's threads
# and its CPU profile. `idle` repeats it with the mock's idle timeout raised from 30 s to 600 s,
# which removes the stall if it is backend connections expiring together:
#
#   sudo REPS=0 POLLER_CELLS="D:43300:3 A_iso:43300:3" POLLER_KINDS="ctl idle" POLLER_REPS=6 \
#     scripts/loom-carrier-scheduler/run-diagnostics.sh
#
# On any exit the shield is reverted and perf_event_paranoid and /sys/kernel/tracing restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"

KERNEL_COMMIT="${KERNEL_COMMIT:-bc26f9a0e8fc}"
REPS="${REPS:-3}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"
CELLS="${CELLS:-D:43300 C_iso:52600 A_iso:52600}"
KINDS="${KINDS:-light sched wall jfr}"
POLLER_CELLS="${POLLER_CELLS:-D:43300:1 D:43300:3}"
POLLER_REPS="${POLLER_REPS:-6}"
POLLER_KINDS="${POLLER_KINDS:-light}"
PROBE_RATE=200

IO_ARGS=(--backend jdk --warmup-mode open --warmup 30 --duration 60 --think-ms 30
         --connections 5000 --pool 2048 --max-connections 16384)

die() { echo "run-diagnostics: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

kind_args() {
  local base=(--latency-probe "$PROBE_RATE" --gc-log)
  case "$1" in
    light) echo "${base[*]}" ;;
    sched) echo "${base[*]} --perf-sched --perf-sched-delay 20 --perf-sched-seconds 20" ;;
    wall)  echo "${base[*]} --profile wall" ;;
    jfr)   echo "${base[*]} --jfr" ;;
    ctl)   echo "${base[*]} --backend-trace" ;;
    idle)  echo "${base[*]} --backend-trace --mock-idle-timeout 600000" ;;
    *) die "unknown kind $1" ;;
  esac
}

# --- inner: the trial loop, run as the benchmark user inside the shield -----------------------------
if [[ "${1:-}" == "--inner" ]]; then
  OUT_ROOT="$2"
  mkdir -p "$OUT_ROOT"
  sha="$(git -C "$BENCH_ROOT" rev-parse HEAD)"
  # Already built by the outer step; build-kernel.sh returns the cached directory.
  KDIR="$("$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT" | tail -1)"
  [[ -f "$KDIR/kernel-cp.txt" ]] || die "kernel build not found at $KDIR"
  cp "$KDIR/kernel-identity.json" "$OUT_ROOT/kernel-identity.json"
  seed="$(date +%s)"
  {
    echo "seed=$seed harness=$sha"
    echo "block 1: cells=$CELLS kinds=$KINDS reps=$REPS"
    echo "block 2: cells=$POLLER_CELLS kinds=$POLLER_KINDS reps=$POLLER_REPS"
  } >"$OUT_ROOT/plan.txt"
  : >"$OUT_ROOT/order.txt"
  plan() {  # <reps> <cells> <kinds>
    local r cell kind arm rate pm
    for r in $(seq 1 "$1"); do
      for cell in $2; do
        IFS=: read -r arm rate pm <<<"$cell"
        for kind in $3; do echo "r$r $arm $rate ${pm:-3} $kind"; done
      done | shuf --random-source=<(yes "$seed$r$2")
    done
  }
  plan "$REPS" "$CELLS" "$KINDS" >>"$OUT_ROOT/order.txt"
  plan "$POLLER_REPS" "$POLLER_CELLS" "$POLLER_KINDS" | sed 's/^r/q/' >>"$OUT_ROOT/order.txt"
  n=0; total="$(wc -l <"$OUT_ROOT/order.txt")"
  while read -r rep arm rate pm kind; do
    n=$((n + 1))
    dir="$OUT_ROOT/$rep-$arm-$rate-p$pm-$kind"
    log "[$n/$total] $arm $rate pollerMode=$pm $kind"
    # shellcheck disable=SC2046
    "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KDIR" --arm "$arm" --rate "$rate" --poller-mode "$pm" "${IO_ARGS[@]}" \
      $(kind_args "$kind") --out "$dir" >"$dir.log" 2>&1 || log "  trial failed, see $dir.log"
    [[ -f "$dir/diag.txt" ]] && head -2 "$dir/diag.txt" | sed 's/^/  /'
  done <"$OUT_ROOT/order.txt"
  python3 "$SCRIPT_DIR/summarize_diag.py" "$OUT_ROOT" || log "summary failed"
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

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
PREV_TRACING_MODE="$(stat -c %a /sys/kernel/tracing)"
restore() {
  local rc=$?
  log "restoring host"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  [[ "${PREV_TRACING_MODE: -1}" == "0" ]] && chmod -R o-rx /sys/kernel/tracing 2>/dev/null || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT

sysctl -q kernel.perf_event_paranoid=-1
# The scheduler trace reads tracepoint formats from tracefs as the benchmark user.
chmod -R o+rx /sys/kernel/tracing 2>/dev/null || true
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"
"$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT"

HSHA="$(git -C "$BENCH_ROOT" rev-parse --short=12 HEAD)"
OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler-diag/$(date -u +%Y%m%dT%H%M%SZ)-h$HSHA"

log "diagnostics into $OUT_ROOT"
"$SHIELD" run -- env KERNEL_COMMIT="$KERNEL_COMMIT" CELLS="$CELLS" KINDS="$KINDS" REPS="$REPS" \
  POLLER_CELLS="$POLLER_CELLS" POLLER_REPS="$POLLER_REPS" POLLER_KINDS="$POLLER_KINDS" \
  "$SCRIPT_DIR/run-diagnostics.sh" --inner "$OUT_ROOT"
log "summary: $OUT_ROOT/summary.md"
