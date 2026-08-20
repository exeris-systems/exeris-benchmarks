#!/usr/bin/env bash
# Foreign work on the measured CPU sets — the confound, measured exactly rather than bounded.
#
# The question is NOT how much CPU dockerd burns in total: a daemon can spend 200 s entirely on
# cores 0-3 and contaminate nothing. What matters is foreign work ON THE MEASURED SETS, and that
# is directly computable from files needing no privilege at all:
#
#   foreign(set) = busy(cores in set, from /proc/stat) - SUM(usage of every cgroup pinned there)
#
# Every container pinned to 6,7,14,15 can only run there, so whatever busy time remains after
# subtracting all of them is foreign by construction. This works BEFORE any repin — it does not
# need one container per set — and it turns "we know an upper bound" into "we know the number".
#
# /proc/stat also splits irq and softirq per core, which tests a second hypothesis for free. If
# the Axon arms show materially more softirq on the backend cores, the channel is packet
# processing rather than SMT interference: their Postgres runs ~3.5x the queries, hence ~3.5x the
# loopback packets, hence more kernel work billed wherever it lands. That was an argument; this
# makes it a reading.
#
# cgroup v2: per-cgroup CPU is total-only (cpu.stat usage_usec), with no per-core breakdown. That
# is sufficient here precisely because the cpuset confines each container to a known set.
#
#   tools/saga/foreign-core-work.sh [out.csv] [interval_s]
set -uo pipefail
OUT="${1:-foreign-core-work.csv}"
INTERVAL="${2:-60}"
CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
echo "ts_utc,kind,name,cores,busy_s,user_s,system_s,irq_s,softirq_s,steal_s,idle_s" > "$OUT"

emit_cores() {   # $1 = ts, $2 = label, $3 = comma list of core ids
  local ts="$1" label="$2" list="$3"
  awk -v ts="$ts" -v label="$label" -v list="$list" -v clk="$CLK" '
    BEGIN { n=split(list, want, ","); for (i=1;i<=n;i++) sel["cpu" want[i]]=1 }
    /^cpu[0-9]/ && ($1 in sel) {
      user+=$2; nice+=$3; sys+=$4; idle+=$5; iow+=$6; irq+=$7; sirq+=$8; steal+=$9
    }
    END {
      busy = user+nice+sys+irq+sirq+steal
      gsub(/,/, "+", list)
      printf "%s,coreset,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n", ts, label, list,
             busy/clk, (user+nice)/clk, sys/clk, irq/clk, sirq/clk, steal/clk, idle/clk
    }' /proc/stat
}

while true; do
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  emit_cores "$TS" target   "0,1,2,3,8,9,10,11"   >> "$OUT"
  emit_cores "$TS" loadgen  "4,5,12,13"           >> "$OUT"
  emit_cores "$TS" backend  "6,7,14,15"           >> "$OUT"
  emit_cores "$TS" all      "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15" >> "$OUT"
  for name in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    id="$(docker inspect "$name" --format '{{.Id}}' 2>/dev/null)" || continue
    scope="/sys/fs/cgroup/system.slice/docker-${id}.scope"
    [ -d "$scope" ] || scope="/sys/fs/cgroup/docker/${id}"
    [ -d "$scope" ] || continue
    u="$(awk '/^usage_usec/{print $2}'  "$scope/cpu.stat" 2>/dev/null)"
    us="$(awk '/^user_usec/{print $2}'   "$scope/cpu.stat" 2>/dev/null)"
    sy="$(awk '/^system_usec/{print $2}' "$scope/cpu.stat" 2>/dev/null)"
    cs="$(tr -d '\n' < "$scope/cpuset.cpus.effective" 2>/dev/null | tr ',' '+')"
    [ -n "$u" ] && printf '%s,cgroup,%s,%s,%.2f,%.2f,%.2f,,,,\n' \
      "$TS" "$name" "${cs:-unknown}" \
      "$(awk -v v="$u"  'BEGIN{printf "%.2f", v/1000000}')" \
      "$(awk -v v="$us" 'BEGIN{printf "%.2f", v/1000000}')" \
      "$(awk -v v="$sy" 'BEGIN{printf "%.2f", v/1000000}')" >> "$OUT"
  done
  sleep "$INTERVAL"
done
