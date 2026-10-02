#!/usr/bin/env bash
# host-shield.sh — keep everything except the benchmark off the benchmark CPUs, and put it back.
#
# The shield is a cgroup cpuset, not isolcpus. isolcpus also turns off load balancing on the
# isolated CPUs, so two carriers sharing a two-CPU mask would no longer be moved between those CPUs
# by the kernel scheduler — the placement behaviour the floating arms exist to measure.
#
# Usage (as root, from a text console with the graphical session stopped):
#   sudo scripts/loom-carrier-scheduler/host-shield.sh apply  [--sys-cpus 0,6] [--boost off|on|keep]
#   sudo scripts/loom-carrier-scheduler/host-shield.sh run    -- <command> [args...]
#   sudo scripts/loom-carrier-scheduler/host-shield.sh revert
#        scripts/loom-carrier-scheduler/host-shield.sh status
#
#   apply   confines system.slice, user.slice and init.scope to --sys-cpus, moves every movable IRQ
#           there, sets the cpufreq governor to performance and boost as requested. Runtime only:
#           nothing survives a reboot. The previous state is saved for revert.
#   run     runs <command> as the invoking user in bench.slice, which may use every CPU, with that
#           user's login environment and the current directory.
#   revert  restores the saved slice masks, IRQ affinities, governors and boost.
#   status  prints the current state; needs no privileges.
#
# To stop and restore the graphical session around a campaign:
#   sudo systemctl isolate multi-user.target     # then log in on a text console (Ctrl+Alt+F3)
#   sudo systemctl isolate graphical.target
set -euo pipefail
export LC_ALL=C

STATE_DIR=/run/loom-carrier-scheduler
STATE="$STATE_DIR/shield.state"
SLICES=(system.slice user.slice init.scope)
SYS_CPUS="0,6"
BOOST="keep"

die() { echo "host-shield: $*" >&2; exit 2; }
need_root() { [[ $EUID -eq 0 ]] || die "$1 needs root (sudo)"; }
all_cpus() { echo "0-$(( $(nproc --all) - 1 ))"; }

status() {
  echo "systemd: default=$(systemctl get-default)  graphical.target=$(systemctl is-active graphical.target 2>/dev/null || true)"
  for s in "${SLICES[@]}" bench.slice; do
    printf '%-14s AllowedCPUs=%s\n' "$s" "$(systemctl show "$s" -p AllowedCPUs --value 2>/dev/null)"
  done
  echo "isolated: $(cat /sys/devices/system/cpu/isolated 2>/dev/null)"
  echo "boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a)"
  echo "governors: $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | xargs)"
  local total=0 off=0 f
  for f in /proc/irq/[0-9]*/smp_affinity_list; do
    total=$((total + 1))
    [[ "$(cat "$f")" == "$SYS_CPUS" ]] && off=$((off + 1))
  done
  echo "irqs: $off of $total have affinity $SYS_CPUS"
  echo "irqbalance: $(systemctl is-active irqbalance 2>/dev/null || true)"
}

apply() {
  need_root apply
  [[ -e "$STATE" ]] && die "a shield is already applied ($STATE); revert it first"
  mkdir -p "$STATE_DIR"
  {
    for s in "${SLICES[@]}"; do echo "slice $s $(systemctl show "$s" -p AllowedCPUs --value)"; done
    echo "boost $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a)"
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "gov $g $(cat "$g")"; done
    for f in /proc/irq/[0-9]*/smp_affinity_list; do echo "irq $f $(cat "$f")"; done
  } >"$STATE"

  if systemctl is-active --quiet irqbalance; then
    echo "stopping irqbalance for the session"; systemctl stop irqbalance
    echo "irqbalance active" >>"$STATE"
  fi
  for s in "${SLICES[@]}"; do systemctl set-property --runtime "$s" AllowedCPUs="$SYS_CPUS"; done

  local moved=0 refused=0 f
  for f in /proc/irq/[0-9]*/smp_affinity_list; do
    if echo "$SYS_CPUS" >"$f" 2>/dev/null; then moved=$((moved + 1)); else refused=$((refused + 1)); fi
  done
  echo "irqs moved to $SYS_CPUS: $moved; refused (per-CPU or managed): $refused"

  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance >"$g" 2>/dev/null || true; done
  case "$BOOST" in
    off) echo 0 >/sys/devices/system/cpu/cpufreq/boost ;;
    on)  echo 1 >/sys/devices/system/cpu/cpufreq/boost ;;
    keep) ;;
    *) die "--boost must be off, on or keep" ;;
  esac
  status
}

revert() {
  need_root revert
  [[ -f "$STATE" ]] || die "no saved state at $STATE"
  local kind a b
  while read -r kind a b; do
    case "$kind" in
      slice) systemctl set-property --runtime "$a" AllowedCPUs="${b:-}" ;;
      boost) [[ "$a" != "n/a" ]] && echo "$a" >/sys/devices/system/cpu/cpufreq/boost ;;
      gov)   echo "$b" >"$a" 2>/dev/null || true ;;
      irq)   echo "$b" >"$a" 2>/dev/null || true ;;
      irqbalance) systemctl start irqbalance ;;
    esac
  done <"$STATE"
  rm -f "$STATE"
  status
}

run() {
  need_root run
  local user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != "root" ]] || die "run must be invoked through sudo by the benchmark user"
  [[ $# -gt 0 ]] || die "run needs a command after --"
  local cmd
  printf -v cmd '%q ' "$@"
  exec systemd-run --quiet --pty --collect --slice=bench.slice -p AllowedCPUs="$(all_cpus)" \
    --uid="$user" --working-directory="$PWD" -- /bin/bash -lc "$cmd"
}

ACTION="${1:-status}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sys-cpus) SYS_CPUS="$2"; shift 2 ;;
    --boost) BOOST="$2"; shift 2 ;;
    --) shift; break ;;
    *) [[ "$ACTION" == "run" ]] && break; die "unknown option $1" ;;
  esac
done

case "$ACTION" in
  apply) apply ;;
  revert) revert ;;
  status) status ;;
  run) run "$@" ;;
  *) die "action must be apply, run, revert or status" ;;
esac
