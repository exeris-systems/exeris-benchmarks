#!/usr/bin/env bash
# Host-housekeeping CPU census — the confound the pinning plan CANNOT remove on this box.
#
# The pin sets give every measured container its own physical cores, but dockerd, containerd and
# journald are root-owned and run with affinity 0-15 (verified 2026-08-20: `taskset -pc <dockerd>`
# reports 0-15, and setting it fails with EPERM — this account has no passwordless sudo, and the
# kernel cmdline carries no isolcpus). So system housekeeping floats across every pin set,
# including the ones holding Postgres and the payment gateway.
#
# WHY IT MATTERS RATHER THAN BEING BACKGROUND NOISE: housekeeping load is NOT constant across
# arms. Arms with more processes and more log volume generate more daemon work, which correlates
# with the arm in exactly the same direction as the contamination the repin is meant to remove.
# That gives the gateway-spread control a THIRD outcome beyond the two it was designed to
# separate: the spread can survive the repin because housekeeping is unpinned, and be misread as
# "the arms really do offer different load". A false negative on the question that already cost
# one campaign.
#
# Since the affinity cannot be set from this account, the next best thing is to MEASURE the term
# and bound it. If daemon CPU per arm is small against the spread being investigated, the
# confound is bounded and can be declared. If it is comparable, the repin control cannot conclude
# and the fix needs root (systemd CPUAffinity, or isolcpus/nohz_full on the measured sets).
#
#   tools/saga/host-housekeeping.sh [out.csv] [interval_s]
set -uo pipefail
OUT="${1:-host-housekeeping.csv}"
INTERVAL="${2:-60}"
CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
echo "ts_utc,proc,pid,cpu_seconds,affinity" > "$OUT"
while true; do
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for name in dockerd containerd systemd-journald rsyslogd; do
    for pid in $(pgrep -x "$name" 2>/dev/null); do
      st="$(cat "/proc/$pid/stat" 2>/dev/null)" || continue
      # utime and stime are fields 14 and 15 after the comm field, which may contain spaces.
      rest="${st#*) }"
      set -- $rest
      utime="${12}"; stime="${13}"
      cpus="$(( (utime + stime) ))"
      aff="$(taskset -pc "$pid" 2>/dev/null | sed 's/.*: //')"
      echo "${TS},${name},${pid},$(awk -v c="$cpus" -v k="$CLK" 'BEGIN{printf "%.2f", c/k}'),${aff:-unknown}" >> "$OUT"
    done
  done
  sleep "$INTERVAL"
done
