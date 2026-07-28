#!/usr/bin/env bash
# FUTEX / syscall-mix probe (ROOT side): perf trace -s needs the raw_syscalls tracepoints, whose
# tracefs files are root-only (bench has no passwordless sudo). Read-only measurement.
set -uo pipefail
probe() {
  local LABEL="$1"
  local READY=/tmp/fx-${LABEL}.ready
  echo "[$LABEL] waiting for bench marker..."
  local i; for i in $(seq 1 300); do [ -f "$READY" ] && break; sleep 5; done
  [ -f "$READY" ] || { echo "[$LABEL] TIMEOUT"; return 1; }
  local JP; JP=$(cat /tmp/fx-${LABEL}.javapid 2>/dev/null)
  [ -n "$JP" ] || { echo "[$LABEL] no pid"; return 1; }
  echo "[$LABEL] perf trace -s -p $JP (20s) $(date -u +%H:%M:%S)UTC"
  perf trace -s -p "$JP" -- sleep 20 > /tmp/fx-${LABEL}.trace 2>&1
  echo "[$LABEL] ===== SYSCALL SUMMARY ====="
  # perf trace -s prints: syscall calls errors total(msec) min avg max stddev
  sed -n '/syscall/,$p' /tmp/fx-${LABEL}.trace | head -25
  rm -f "$READY"; touch /tmp/fx-${LABEL}.done
}
probe exeris
probe qtuned
probe qhib
echo "===== FUTEX ROOT PROBES DONE $(date -u +%H:%M:%S)UTC ====="
