#!/usr/bin/env bash
# run-v2-equivalence.sh — is arm D the same arm in two kernel builds?
#
# Scheduler v2 changes the kernel build that D and D2 run from. Before D2 is compared with anything
# measured on the earlier build, D from the new build is run against D from the earlier one at a
# fixed rate in both regimes, in one boot and one host state. The comparison is held to B_float's
# reproduction rule (stats.reproduction_check): accepted when the new build's p99 does not separate
# from the earlier build's (exact two-sided Mann-Whitney p >= 0.05) and its median lies inside the
# earlier build's range. If it is not accepted, the new build's D is the control and no earlier
# campaign is compared with D2.
#
# Cells: D x {earlier, new build} x {cpu, io regime}, REPS fresh JVMs each, the cells of each
# repetition in a recorded shuffled order. Trial directories are r<n>-D-k<sha12>-<regime>; the order
# file names each trial's kernel so that summarize_equivalence.py can check what ran.
#
# Run as root from a text console, inside tmux, with the graphical session stopped, on a boot in
# which the Docker daemon has not run (connection tracking not loaded):
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s v2
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo KERNEL_NEW=<rev> scripts/loom-carrier-scheduler/run-v2-equivalence.sh
#
# Environment (defaults in brackets):
#   KERNEL_NEW (required)   KERNEL_OLD [bc26f9a0e8fc]   KERNEL_REPO [build-kernel.sh's default]
#   REPS [5]   SYS_CPUS [0,6]   BOOST [off]
#   EQUIV_RATE_CPU [63400]   EQUIV_RATE_IO [52800]   and the regimes' options (v2-regimes.sh)
#
# On any exit the shield is reverted and perf_event_paranoid restored.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIELD="$SCRIPT_DIR/host-shield.sh"
# shellcheck source=v2-regimes.sh
source "$SCRIPT_DIR/v2-regimes.sh"

KERNEL_OLD="${KERNEL_OLD:-bc26f9a0e8fc}"
KERNEL_NEW="${KERNEL_NEW:-}"
KERNEL_REPO="${KERNEL_REPO:-}"
REPS="${REPS:-5}"
SYS_CPUS="${SYS_CPUS:-0,6}"
BOOST="${BOOST:-off}"

die() { echo "run-v2-equivalence: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

[[ -n "$KERNEL_NEW" ]] || die "KERNEL_NEW (the v2 build's commit) is required"
[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
grep -q '^nf_conntrack ' /proc/modules \
  && die "nf_conntrack is loaded (the Docker daemon loads it and it stays until reboot); reboot without starting Docker"
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

sysctl -q kernel.perf_event_paranoid=-1
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"
# The shield runs commands on a pseudo-terminal, so captured output ends its lines with CR.
build() { "$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$1" ${KERNEL_REPO:+"$KERNEL_REPO"} | tr -d '\r' | tail -1; }
KDIR_OLD="$(build "$KERNEL_OLD")"; KDIR_NEW="$(build "$KERNEL_NEW")"
for d in "$KDIR_OLD" "$KDIR_NEW"; do [[ -f "$d/kernel-cp.txt" ]] || die "kernel build not found at $d"; done
sha12() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["kernel_commit"][:12])' "$1/kernel-identity.json"; }
SHA_OLD="$(sha12 "$KDIR_OLD")"; SHA_NEW="$(sha12 "$KDIR_NEW")"
[[ "$SHA_OLD" != "$SHA_NEW" ]] || die "KERNEL_OLD and KERNEL_NEW are the same commit ($SHA_OLD)"

HSHA="$(git -C "$BENCH_ROOT" rev-parse --short=12 HEAD)"
OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler-v2-equivalence/$(date -u +%Y%m%dT%H%M%SZ)-h$HSHA"
mkdir -p "$OUT_ROOT"
seed="$(date +%s)"
{
  echo "seed=$seed harness=$(git -C "$BENCH_ROOT" rev-parse HEAD) reps=$REPS"
  echo "kernel_old=$SHA_OLD kernel_new=$SHA_NEW"
  echo "rate_cpu=$EQUIV_RATE_CPU rate_io=$EQUIV_RATE_IO"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)"
  echo "cpu_load_args=$CPU_LOAD_ARGS"
  echo "io_load_args=$IO_LOAD_ARGS"
} >"$OUT_ROOT/plan.txt"
: >"$OUT_ROOT/order.txt"
for r in $(seq 1 "$REPS"); do
  for k in "$SHA_OLD" "$SHA_NEW"; do for g in cpu io; do echo "r$r k$k $g"; done; done \
    | python3 -c 'import random,sys; r=random.Random(sys.argv[1]); l=sys.stdin.read().splitlines(); r.shuffle(l); print("\n".join(l))' "$seed-$r" \
    >>"$OUT_ROOT/order.txt"
done
chown -R "$SUDO_USER": "$OUT_ROOT"

log "equivalence check into $OUT_ROOT"
# The order is read up front: the shield's pseudo-terminal would consume a loop's standard input.
mapfile -t ORDER <"$OUT_ROOT/order.txt"
n=0; total="${#ORDER[@]}"
for line in "${ORDER[@]}"; do
  n=$((n + 1))
  read -r rep ktag regime <<<"$line"
  kdir="$KDIR_NEW"; [[ "$ktag" == "k$SHA_OLD" ]] && kdir="$KDIR_OLD"
  rate="$(regime_value "$regime" EQUIV_RATE_CPU EQUIV_RATE_IO)"
  regime_load_args "$regime"
  dir="$OUT_ROOT/$rep-D-$ktag-$regime"
  log "[$n/$total] D $ktag $regime at $rate req/s"
  "$SHIELD" run -- "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$kdir" --arm D --backend jdk --rate "$rate" \
    "${COMMON_TRIAL_ARGS[@]}" "${REGIME_ARGS[@]}" --out "$dir" >"$dir.log" 2>&1 \
    || log "  trial failed, see $dir.log"
done
chown -R "$SUDO_USER": "$OUT_ROOT"
sudo -u "$SUDO_USER" python3 "$SCRIPT_DIR/summarize_equivalence.py" "$OUT_ROOT" || log "summary failed"
log "summary: $OUT_ROOT/summary.md"
