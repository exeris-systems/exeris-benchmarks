#!/usr/bin/env bash
# 3-way kernel profile (ROOT side, read-only measurement): Probe 1 = syscalls/request.
# raw_syscalls:sys_enter is a tracepoint whose /sys/kernel/tracing files are root-only, so this
# probe must run as root even with perf_event_paranoid=-1. It only READS a counter (perf stat) —
# it changes no setting. Waits for the bench side to publish a per-stack ready+pid marker, then
# counts syscalls on the target PID for 30s.
set -uo pipefail

probe() {
  local LABEL="$1"
  local READY=/tmp/prof-${LABEL}.ready
  echo "[$LABEL] waiting for bench ready marker..."
  local i
  for i in $(seq 1 300); do [ -f "$READY" ] && break; sleep 5; done
  if [ ! -f "$READY" ]; then echo "[$LABEL] PROBE1 TIMEOUT (no ready marker)"; return 1; fi
  local JP
  JP=$(cat /tmp/prof-${LABEL}.javapid 2>/dev/null)
  if [ -z "$JP" ]; then echo "[$LABEL] PROBE1 no pid"; return 1; fi
  echo "[$LABEL] PROBE1: perf stat -e raw_syscalls:sys_enter -p $JP (30s) $(date -u +%H:%M:%S)UTC"
  perf stat -e raw_syscalls:sys_enter -p "$JP" -- sleep 30 2>/tmp/prof-${LABEL}.syscalls.txt
  grep -iE "sys_enter|seconds time elapsed" /tmp/prof-${LABEL}.syscalls.txt
  rm -f "$READY"    # consume, so a stale marker never re-triggers
}

probe community
probe qtuned
probe qhib
echo "===== ROOT SYSCALL PROBES DONE $(date -u +%H:%M:%S)UTC ====="
for L in community qtuned qhib; do
  echo "--- $L ---"; grep -iE "sys_enter|elapsed" /tmp/prof-${L}.syscalls.txt 2>/dev/null | head -3
done
