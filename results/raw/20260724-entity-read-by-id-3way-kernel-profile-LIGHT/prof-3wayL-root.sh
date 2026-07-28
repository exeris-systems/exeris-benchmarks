#!/usr/bin/env bash
# LIGHT 3-way, ROOT side: Probe 1 = syscalls/request (raw_syscalls tracepoint is root-only).
set -uo pipefail
probe() {
  local LABEL="$1"
  local READY=/tmp/profL-${LABEL}.ready
  echo "[$LABEL] waiting for bench ready marker..."
  local i
  for i in $(seq 1 300); do [ -f "$READY" ] && break; sleep 5; done
  if [ ! -f "$READY" ]; then echo "[$LABEL] PROBE1 TIMEOUT"; return 1; fi
  local JP; JP=$(cat /tmp/profL-${LABEL}.javapid 2>/dev/null)
  if [ -z "$JP" ]; then echo "[$LABEL] PROBE1 no pid"; return 1; fi
  echo "[$LABEL] PROBE1: perf stat -e raw_syscalls:sys_enter -p $JP (30s) $(date -u +%H:%M:%S)UTC"
  perf stat -e raw_syscalls:sys_enter -p "$JP" -- sleep 30 2>/tmp/profL-${LABEL}.syscalls.txt
  grep -iE "sys_enter|seconds time elapsed" /tmp/profL-${LABEL}.syscalls.txt
  rm -f "$READY"
}
probe communityL
probe qtunedL
probe qhibL
echo "===== ROOT LIGHT SYSCALL PROBES DONE $(date -u +%H:%M:%S)UTC ====="
