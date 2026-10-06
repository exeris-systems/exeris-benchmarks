#!/usr/bin/env bash
# run-sequence.sh — the full shielded run: host preparation, every campaign, host restoration.
#
# Run as root from a text console, inside tmux, with the graphical session already stopped:
#
#   sudo systemctl isolate multi-user.target        # from the desktop; then Ctrl+Alt+F3, log in
#   tmux new -s bench
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo scripts/loom-carrier-scheduler/run-sequence.sh
#   ...                                             # afterwards:
#   sudo systemctl isolate graphical.target
#
# The script does not stop or start the graphical session itself: isolating a target from inside
# the session that runs the script can take that session down with it.
#
# Environment (defaults in brackets):
#   KERNEL_COMMIT [bc26f9a0e8fc]  kernel under test; a commit, so every campaign measures one build
#   REPS [10]                     repetitions per (arm, rate) cell
#   SAT_REPS [3]                  saturation repetitions per arm
#   SYS_CPUS [0,6]                CPUs left to everything outside the benchmark
#   BOOST [off]                   cpufreq boost during the run: off, on or keep
#   CAMPAIGNS [cpu io]            which campaigns to run, in order
#
# On any exit — success, failure or Ctrl+C — the shield is reverted and perf_event_paranoid restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"

KERNEL_COMMIT="${KERNEL_COMMIT:-bc26f9a0e8fc}"
REPS="${REPS:-10}"
SAT_REPS="${SAT_REPS:-3}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"
CAMPAIGNS="${CAMPAIGNS:-cpu io}"

die() { echo "run-sequence: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
[[ -n "${TMUX:-}${STY:-}" ]] || log "warning: not inside tmux or screen; a dropped console ends the run"

# Common to both regimes: same arms, same CPU layout, same kernel build, open-loop warmup.
COMMON=(--kernel-commit "$KERNEL_COMMIT" --backend jdk --poller-mode 3
        --reps "$REPS" --saturation-reps "$SAT_REPS" --warmup-mode open --warmup 30)

# CPU-bound: 1 ms backend think time, 100 connections, 2 carriers.
CPU_ARGS=(--fractions "0.5 0.7 0.85 0.9")

# I/O-bound: 30 ms think time. 5,000 connections keep the closed-loop ceiling (5,000 / 31 ms)
# above the CPU ceiling, so saturation measures the server, not the connection count; the pool
# matches the connection count and the kernel limits are raised above both.
IO_ARGS=(--fractions "0.5 0.7 0.85" --think-ms 30 --connections 5000 --pool 5000
         --max-connections 16384 --duration 60)

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
restore() {
  local rc=$?
  log "restoring host"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT

log "kernel $KERNEL_COMMIT, reps $REPS, campaigns: $CAMPAIGNS"
sysctl -q kernel.perf_event_paranoid=-1
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"

# Build once, as the benchmark user, so the campaigns' first trial does not include a build.
"$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT"

declare -A RESULT
for c in $CAMPAIGNS; do
  case "$c" in
    cpu) args=("${COMMON[@]}" "${CPU_ARGS[@]}") ;;
    io)  args=("${COMMON[@]}" "${IO_ARGS[@]}") ;;
    *) log "unknown campaign '$c', skipped"; RESULT[$c]="skipped"; continue ;;
  esac
  log "campaign $c: run-campaign.sh ${args[*]}"
  if "$SHIELD" run -- "$SCRIPT_DIR/run-campaign.sh" "${args[@]}"; then
    RESULT[$c]="ok"
  else
    RESULT[$c]="failed ($?)"
  fi
  log "campaign $c: ${RESULT[$c]}"
done

log "summary:"
for c in $CAMPAIGNS; do echo "  $c: ${RESULT[$c]:-not run}"; done
echo "  results: $BENCH_ROOT/results/raw/loom-carrier-scheduler/ (newest directories)"
