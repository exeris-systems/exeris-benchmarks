#!/usr/bin/env bash
# run-v2-sequence.sh — one boot's share of the scheduler-v2 measurement: the equivalence check, then
# one regime's campaign (capacity ladder to 130 %, closed-loop cells) with arms A_iso, B_pin, D, D2.
#
# The two regimes run in separate boots. Connection tracking and the other state a boot accumulates
# move the floating arms' tail, so a regime's arms must share one boot and a boot serves one regime;
# the script records every boot it served in a ledger and refuses a second regime in the same boot.
# It also refuses to start when connection tracking is loaded, since every trial would fail the
# host_untracked evidence gate.
#
# Run as root from a text console, inside tmux, with the graphical session stopped, on a boot in
# which the Docker daemon has not run:
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s v2
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo KERNEL_NEW=<rev> REGIME=cpu scripts/loom-carrier-scheduler/run-v2-sequence.sh    # boot 1
#   ...reboot...
#   sudo KERNEL_NEW=<rev> REGIME=io EQUIVALENCE=no scripts/loom-carrier-scheduler/run-v2-sequence.sh   # boot 2
#
# Environment (defaults in brackets):
#   KERNEL_NEW (required)   REGIME (required: cpu or io)   KERNEL_OLD [bc26f9a0e8fc]   KERNEL_REPO
#   EQUIVALENCE [yes]       run run-v2-equivalence.sh (both regimes) before the campaign; once per
#                           boot, and the campaign needs the property file arms/D2.properties
#   ARMS ["A_iso B_pin D D2"]   REPS [5]   SAT_REPS [3]   CLOSED_REPS [7]   CLOSED_CELLS ["1x 4x"]
#   FRACTIONS [0.5, then 0.7 to 1.3 in steps of 0.05, of A_iso's saturation]
#   CLOSED_CONNECTIONS, CLOSED_MAX_CONNECTIONS, CLOSED_POOL   per-cell overrides ("-" = unchanged)
#   CPU_LOAD_ARGS, IO_LOAD_ARGS   the regimes' run-trial.sh options (v2-regimes.sh); set them to the
#                           registered configuration after the pilot
#   SLO_CPU_MS [5]   SLO_IO_MS [80]   SYS_CPUS [0,6]   BOOST [off]
#
# On any exit the shield is reverted and perf_event_paranoid restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"
# shellcheck source=v2-regimes.sh
source "$SCRIPT_DIR/v2-regimes.sh"

KERNEL_NEW="${KERNEL_NEW:-}"
KERNEL_OLD="${KERNEL_OLD:-bc26f9a0e8fc}"
KERNEL_REPO="${KERNEL_REPO:-}"
REGIME="${REGIME:-}"
EQUIVALENCE="${EQUIVALENCE:-yes}"
ARMS="${ARMS:-A_iso B_pin D D2}"
REPS="${REPS:-5}"
SAT_REPS="${SAT_REPS:-3}"
CLOSED_REPS="${CLOSED_REPS:-7}"
CLOSED_CELLS="${CLOSED_CELLS:-1x 4x}"
CLOSED_CONNECTIONS="${CLOSED_CONNECTIONS:-}"
CLOSED_MAX_CONNECTIONS="${CLOSED_MAX_CONNECTIONS:-}"
CLOSED_POOL="${CLOSED_POOL:-}"
FRACTIONS="${FRACTIONS:-0.5 0.7 0.75 0.8 0.85 0.9 0.95 1.0 1.05 1.1 1.15 1.2 1.25 1.3}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"
LEDGER="$BENCH_ROOT/results/raw/loom-carrier-scheduler-v2/boots.txt"

die() { echo "run-v2-sequence: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

[[ -n "$KERNEL_NEW" ]] || die "KERNEL_NEW (the v2 build's commit) is required"
[[ "$REGIME" =~ ^(cpu|io)$ ]] || die "REGIME must be cpu or io"
[[ "$EQUIVALENCE" =~ ^(yes|no)$ ]] || die "EQUIVALENCE must be yes or no"
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
grep -q '^nf_conntrack ' /proc/modules \
  && die "nf_conntrack is loaded (the Docker daemon loads it and it stays until reboot); reboot without starting Docker"
[[ -f "$SCRIPT_DIR/arms/D2.properties" ]] || die "arms/D2.properties is not written; D2's property set is frozen after the pilot"
[[ -n "${TMUX:-}${STY:-}" ]] || log "warning: not inside tmux or screen; a dropped console ends the run"

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"
mkdir -p "$(dirname "$LEDGER")"; touch "$LEDGER"
if grep -q "^$BOOT_ID cpu\$\|^$BOOT_ID io\$" "$LEDGER"; then
  die "boot $BOOT_ID has already served a regime; regimes run in separate boots (see $LEDGER)"
fi
if [[ "$EQUIVALENCE" == yes ]] && grep -q "^$BOOT_ID equivalence\$" "$LEDGER"; then
  die "boot $BOOT_ID has already run the equivalence check (see $LEDGER)"
fi
# Claimed before anything runs: a run that stops half way has still used the boot's state.
[[ "$EQUIVALENCE" == yes ]] && echo "$BOOT_ID equivalence" >>"$LEDGER"
echo "$BOOT_ID $REGIME" >>"$LEDGER"
chown "$SUDO_USER": "$LEDGER" "$(dirname "$LEDGER")"
log "boot $BOOT_ID, regime $REGIME, kernel $KERNEL_NEW (earlier build $KERNEL_OLD), arms: $ARMS"

if [[ "$EQUIVALENCE" == yes ]]; then
  log "equivalence check"
  KERNEL_NEW="$KERNEL_NEW" KERNEL_OLD="$KERNEL_OLD" KERNEL_REPO="$KERNEL_REPO" "$SCRIPT_DIR/run-v2-equivalence.sh"
fi

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

regime_load_args "$REGIME"
SLO="$(regime_value "$REGIME" SLO_CPU_MS SLO_IO_MS)"
ARGS=(--kernel-commit "$KERNEL_NEW" ${KERNEL_REPO:+--kernel-repo "$KERNEL_REPO"}
      "${COMMON_TRIAL_ARGS[@]}" --backend jdk
      --arms "$ARMS" --reps "$REPS" --saturation-reps "$SAT_REPS" --fractions "$FRACTIONS"
      --closed-cells "$CLOSED_CELLS" --closed-reps "$CLOSED_REPS"
      --slo-p99-ms "$SLO" --out-root "$BENCH_ROOT/results/raw/loom-carrier-scheduler-v2/$REGIME")
[[ -n "$CLOSED_CONNECTIONS" ]] && ARGS+=(--closed-connections "$CLOSED_CONNECTIONS")
[[ -n "$CLOSED_MAX_CONNECTIONS" ]] && ARGS+=(--closed-max-connections "$CLOSED_MAX_CONNECTIONS")
[[ -n "$CLOSED_POOL" ]] && ARGS+=(--closed-pool "$CLOSED_POOL")
ARGS+=("${REGIME_ARGS[@]}")

log "campaign $REGIME: run-campaign.sh ${ARGS[*]}"
mkdir -p "$BENCH_ROOT/results/raw/loom-carrier-scheduler-v2/$REGIME"
chown -R "$SUDO_USER": "$BENCH_ROOT/results/raw/loom-carrier-scheduler-v2"
CAMPAIGN="$("$SHIELD" run -- "$SCRIPT_DIR/run-campaign.sh" "${ARGS[@]}" | tr -d '\r' | tee /dev/stderr | tail -1)"
[[ -f "$CAMPAIGN/campaign.json" ]] || die "no campaign directory reported (got '$CAMPAIGN')"
sudo -u "$SUDO_USER" python3 "$SCRIPT_DIR/throughput_v2.py" "$CAMPAIGN" || log "throughput summary failed"
log "campaign $REGIME: $CAMPAIGN"
