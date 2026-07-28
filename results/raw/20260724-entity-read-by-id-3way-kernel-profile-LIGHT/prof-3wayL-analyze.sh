#!/usr/bin/env bash
# Analyze the LIGHT 3-way profile. Adds the mpstat cpuset %sys+%soft reconciliation (Probe 4) so the
# per-PID kernel% (process CPU-time denominator) and the sar-style %sys+%soft (cpuset wall-clock
# denominator, matches report §2) sit side by side.
set -uo pipefail

for L in communityL qtunedL qhibL; do
  COLL=/tmp/profL-${L}.collapsed
  echo "================= LIGHT STACK: $L ================="
  if [ ! -s "$COLL" ]; then echo "  (no collapsed file — stack likely failed)"; continue; fi
  RPS=$(cat /tmp/profL-${L}.rps 2>/dev/null || echo 0)

  awk '{cnt=$NF; line=$0; sub(/ [0-9]+$/,"",line); n=split(line,a,";"); leaf=a[n];
        tot+=cnt; if (leaf ~ /_\[k\]$/) k+=cnt}
       END{printf "  samples=%d  kernel(leaf,per-PID)=%d (%.1f%%)  user=%.1f%%\n", tot,k,100*k/tot,100*(tot-k)/tot}' "$COLL"

  awk '{cnt=$NF; tot+=cnt;
        if (tolower($0) ~ /jackson/) j+=cnt;
        if ($0 ~ /postgresql|pgjdbc|PgResultSet|PGStream|VisibleBuffered|ByteConverter|pgclient|[Vv]ertx.*[Pp]g|hibernate|Hibernate|Agroal/) d+=cnt}
       END{printf "  serializer(jackson,incl)=%.1f%%   db-client(incl)=%.1f%%\n", 100*j/tot, 100*d/tot}' "$COLL"

  SYS=$(grep raw_syscalls /tmp/profL-${L}.syscalls.txt 2>/dev/null | grep -oE '[0-9][0-9,]*' | head -1 | tr -d ',')
  if [ -n "${SYS:-}" ] && awk -v r="$RPS" 'BEGIN{exit !(r>0)}'; then
    awk -v s="$SYS" -v r="$RPS" 'BEGIN{printf "  syscalls_30s=%s  rps=%.0f  => syscalls/req = %.2f\n", s, r, s/(r*30)}'
  else echo "  syscalls_30s=${SYS:-n/a}  rps=$RPS => syscalls/req = n/a"; fi

  # Probe 4: mpstat cpuset %usr/%sys/%soft (sar denominator — matches report §2)
  if [ -s /tmp/profL-${L}.mpstat.txt ]; then
    awk '/^Average:/ && $2 ~ /^(0|1|8|9)$/ {usr+=$3; sys+=$5; soft+=$8; idle+=$NF; n++}
         END{if(n>0) printf "  mpstat cpuset(4cpu avg): %%usr=%.1f %%sys=%.1f %%soft=%.1f  =>  %%sys+%%soft=%.1f  (%%busy=%.1f)\n", usr/n, sys/n, soft/n, (sys+soft)/n, 100-idle/n}' /tmp/profL-${L}.mpstat.txt
  fi

  echo "  -- top KERNEL leaf frames --"
  awk '{cnt=$NF; line=$0; sub(/ [0-9]+$/,"",line); n=split(line,a,";"); leaf=a[n];
        if (leaf ~ /_\[k\]$/) print cnt,leaf}' "$COLL" \
    | awk '{s[$2]+=$1} END{for(f in s) print s[f],f}' | sort -rn | head -8 | sed 's/^/     /'
  echo "  -- softirq/net_rx inline? (system-wide, by command) --"
  perf report --stdio -g none --sort comm -i /tmp/perf-sysL-${L}.data 2>/dev/null | grep -viE '^#|^\s*$|swapper' | head -6 | sed 's/^/     /'
  perf report --stdio -g none -i /tmp/perf-sysL-${L}.data 2>/dev/null | grep -iE 'ksoftirq|__do_softirq|net_rx_action|__napi_poll' | head -4 | sed 's/^/     /'
  echo
done
