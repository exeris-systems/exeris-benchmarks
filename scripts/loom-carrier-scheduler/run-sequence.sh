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
#   REPS [10]                     repetitions per (arm, rate) cell in the cpu and io campaigns
#   SLO_REPS [5]                  repetitions per cell in the cpu-slo and io-slo campaigns
#   SAT_REPS [3]                  saturation repetitions per arm
#   SYS_CPUS [0,6]                CPUs left to everything outside the benchmark
#   BOOST [off]                   cpufreq boost during the run: off, on or keep
#   CAMPAIGNS [cpu io]            which campaigns to run, in order: cpu, io, cpu-slo, io-slo
#
# cpu and io are the three-arm ladders at 50-90 % of A_iso's saturation. cpu-slo and io-slo are the
# capacity ladders: all four arms, 70-100 % in steps of 5 %, against a p99 objective fixed here
# before the run (slo_ladder.py applies it):
#
#   sudo CAMPAIGNS="cpu-slo io-slo" scripts/loom-carrier-scheduler/run-sequence.sh
#
# On any exit — success, failure or Ctrl+C — the shield is reverted and perf_event_paranoid restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"

KERNEL_COMMIT="${KERNEL_COMMIT:-bc26f9a0e8fc}"
REPS="${REPS:-10}"
SLO_REPS="${SLO_REPS:-5}"
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
        --saturation-reps "$SAT_REPS" --warmup-mode open --warmup 30)

# CPU-bound: 1 ms backend think time, 100 connections, 2 carriers.
CPU_ARGS=(--fractions "0.5 0.7 0.85 0.9")
CPU_LOAD=()

# I/O-bound: 30 ms think time. 5,000 connections keep the closed-loop ceiling (5,000 / 31 ms)
# above the CPU ceiling, so saturation measures the server, not the connection count. The backend
# pool is sized to the in-flight requests the ladder can reach (rate x ~32 ms, ~1,650 at the top
# rung) rather than to the connection count: a pool as large as the connection count lets the
# server hold thousands of idle backend sockets, and with it the p99 at half load rises from
# ~37 ms to ~200 ms in every arm. 2,048 slots still allow ~66,000 req/s at 31 ms, above the CPU
# ceiling, so saturation stays a measure of the server.
IO_ARGS=(--fractions "0.5 0.7 0.85")
IO_LOAD=(--think-ms 30 --connections 5000 --pool 2048 --max-connections 16384 --duration 60)

# Capacity ladders. The objectives: CPU-bound p99 <= 5 ms, about twice the p99 every arm reaches
# at 50-70 % of saturation; I/O-bound p99 <= 65 ms, twice the 32.5 ms a request costs with nothing
# queued (30 ms backend think time plus the round trips). B_pin is the stock pool with its workers
# pinned, the cell that separates pinning from the scheduling algorithm.
SLO_ARMS="A_iso B_pin C_iso D"
SLO_FRACTIONS="0.7 0.75 0.8 0.85 0.9 0.95 1.0"
CPU_SLO_ARGS=(--arms "$SLO_ARMS" --fractions "$SLO_FRACTIONS" --reps "$SLO_REPS" --slo-p99-ms 5)
IO_SLO_ARGS=(--arms "$SLO_ARMS" --fractions "$SLO_FRACTIONS" --reps "$SLO_REPS" --slo-p99-ms 65)

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
restore() {
  local rc=$?
  log "restoring host"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT

log "kernel $KERNEL_COMMIT, reps $REPS (slo $SLO_REPS), campaigns: $CAMPAIGNS"
sysctl -q kernel.perf_event_paranoid=-1
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"

# Build once, as the benchmark user, so the campaigns' first trial does not include a build.
"$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT"

declare -A RESULT
for c in $CAMPAIGNS; do
  case "$c" in
    cpu)     args=("${COMMON[@]}" --reps "$REPS" "${CPU_ARGS[@]}" "${CPU_LOAD[@]}") ;;
    io)      args=("${COMMON[@]}" --reps "$REPS" "${IO_ARGS[@]}" "${IO_LOAD[@]}") ;;
    cpu-slo) args=("${COMMON[@]}" "${CPU_SLO_ARGS[@]}" "${CPU_LOAD[@]}") ;;
    io-slo)  args=("${COMMON[@]}" "${IO_SLO_ARGS[@]}" "${IO_LOAD[@]}") ;;
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
