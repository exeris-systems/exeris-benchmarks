#!/usr/bin/env bash
# run-netfilter-check.sh — does connection tracking on loopback carry the CPU-bound tail?
#
# On a host where connection tracking and iptables' NAT table are loaded (as they are once the
# Docker daemon has started), every loopback packet between the load generator, the server and the
# backend passes the conntrack and NAT hooks, and the carriers' samples show it. This runs, in one
# boot and one host state, the same cells with and without two raw-table rules that exempt
# loopback from tracking:
#
#   tracked   the host as it is
#   notrack   iptables -t raw -I PREROUTING -i lo -j CT --notrack, and the same on OUTPUT -o lo
#
# Cells (CPU-bound regime: 1 ms backend, 100 connections, pollerMode 3, open-loop warmup 30 s):
#   A_iso tracked, A_iso notrack, D tracked, D notrack
# REPS fresh JVMs per cell, the cells of each repetition in a recorded shuffled order; the rules are
# set or removed before each trial and recorded with it. Trials carry no recorder.
#
# Run as root from a text console, inside tmux, with the graphical session stopped, on a host where
# nf_conntrack and iptable_nat are loaded:
#
#   sudo systemctl isolate multi-user.target
#   tmux new -s netfilter
#   cd ~/exeris-systems/exeris-benchmarks/.claude/worktrees/loom-carrier-scheduler
#   sudo scripts/loom-carrier-scheduler/run-netfilter-check.sh
#   sudo systemctl isolate graphical.target
#
# Environment (defaults in brackets):
#   KERNEL_COMMIT [bc26f9a0e8fc]   RATE [52200]   REPS [5]   SYS_CPUS [0,6]   BOOST [off]
#
# On any exit the rules are removed, the shield reverted and perf_event_paranoid restored.
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
CELLS="A_iso:tracked A_iso:notrack D:tracked D:notrack"
TAG="loom-carrier-scheduler-notrack"

CPU_ARGS=(--backend jdk --poller-mode 3 --warmup-mode open --warmup 30)

die() { echo "run-netfilter-check: $*" >&2; exit 2; }
log() { echo "[$(date '+%F %T')] $*"; }

notrack_rules() {  # <-I|-D>
  iptables -t raw "$1" PREROUTING -i lo -m comment --comment "$TAG" -j CT --notrack
  iptables -t raw "$1" OUTPUT -o lo -m comment --comment "$TAG" -j CT --notrack
}
notrack_off() { while iptables -t raw -S | grep -q -- "$TAG"; do notrack_rules -D; done; }
notrack_on() { notrack_off; notrack_rules -I; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || die "run through sudo from the benchmark user's session"
if systemctl is-active --quiet graphical.target; then
  die "graphical.target is active; run 'sudo systemctl isolate multi-user.target' and log in on a text console first"
fi
[[ -n "${TMUX:-}${STY:-}" ]] || log "warning: not inside tmux or screen; a dropped console ends the run"
for m in nf_conntrack iptable_nat iptable_raw; do
  grep -q "^$m " /proc/modules || die "$m is not loaded; this check compares a host where it is (start the Docker daemon first)"
done
log "host up $(awk '{printf "%.1f", $1 / 3600}' /proc/uptime) h"

PREV_PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
restore() {
  local rc=$?
  log "restoring host"
  notrack_off || log "could not remove the $TAG rules; check 'iptables -t raw -S'"
  "$SHIELD" revert || log "shield revert failed; check '$SHIELD status'"
  sysctl -q kernel.perf_event_paranoid="$PREV_PARANOID" || true
  log "done (exit $rc); restore the desktop with: sudo systemctl isolate graphical.target"
}
trap restore EXIT

# perf stat gives each trial its CPUs utilised, one of the quantities the campaigns compare.
sysctl -q kernel.perf_event_paranoid=-1
"$SHIELD" apply --sys-cpus "$SYS_CPUS" --boost "$BOOST"
# The shield runs commands on a pseudo-terminal, so captured output ends its lines with CR.
KDIR="$("$SHIELD" run -- "$SCRIPT_DIR/build-kernel.sh" "$KERNEL_COMMIT" | tr -d '\r' | tail -1)"
[[ -f "$KDIR/kernel-cp.txt" ]] || die "kernel build not found at $KDIR"

HSHA="$(git -C "$BENCH_ROOT" rev-parse --short=12 HEAD)"
OUT_ROOT="$BENCH_ROOT/results/raw/loom-carrier-scheduler-netfilter/$(date -u +%Y%m%dT%H%M%SZ)-h$HSHA"
mkdir -p "$OUT_ROOT"
cp "$KDIR/kernel-identity.json" "$OUT_ROOT/kernel-identity.json"
seed="$(date +%s)"
{
  echo "seed=$seed harness=$(git -C "$BENCH_ROOT" rev-parse HEAD) rate=$RATE reps=$REPS"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)"
  echo "notrack = iptables -t raw -I {PREROUTING -i lo, OUTPUT -o lo} -j CT --notrack"
} >"$OUT_ROOT/plan.txt"
iptables-save >"$OUT_ROOT/iptables-at-start.txt"
: >"$OUT_ROOT/order.txt"
for r in $(seq 1 "$REPS"); do
  for c in $CELLS; do echo "r$r $c"; done \
    | python3 -c 'import random,sys; r=random.Random(sys.argv[1]); l=sys.stdin.read().splitlines(); r.shuffle(l); print("\n".join(l))' "$seed-$r" \
    >>"$OUT_ROOT/order.txt"
done
chown -R "$SUDO_USER": "$OUT_ROOT"

log "netfilter check into $OUT_ROOT"
# The order is read up front: the shield's pseudo-terminal would consume a loop's standard input.
mapfile -t ORDER <"$OUT_ROOT/order.txt"
n=0; total="${#ORDER[@]}"
for line in "${ORDER[@]}"; do
  n=$((n + 1))
  read -r rep cell <<<"$line"
  IFS=: read -r arm track <<<"$cell"
  dir="$OUT_ROOT/$rep-$arm-$track"
  if [[ "$track" == "notrack" ]]; then notrack_on; else notrack_off; fi
  log "[$n/$total] $arm $track"
  "$SHIELD" run -- env LOOPBACK_NOTRACK="$track" "$SCRIPT_DIR/run-trial.sh" --kernel-dir "$KDIR" \
    --arm "$arm" --rate "$RATE" "${CPU_ARGS[@]}" --out "$dir" >"$dir.log" 2>&1 \
    || log "  trial failed, see $dir.log"
  iptables -t raw -S >"$dir.raw-table.txt" 2>&1 || true
done
notrack_off
chown -R "$SUDO_USER": "$OUT_ROOT"
sudo -u "$SUDO_USER" python3 "$SCRIPT_DIR/summarize_netfilter.py" "$OUT_ROOT" || log "summary failed"
log "summary: $OUT_ROOT/summary.md"
