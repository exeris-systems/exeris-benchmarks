#!/usr/bin/env bash
# Analyze the 3-way kernel profile. Per stack (community|qtuned|qhib): kernel/user split from the
# async-profiler collapsed file (Probe 2), syscalls/request (Probe 1), serializer+db shares, top
# frames, and the system-wide non-idle view (Probe 3 -> softirq/TCP).
set -uo pipefail

for L in community qtuned qhib; do
  COLL=/tmp/prof-${L}.collapsed
  echo "================= STACK: $L ================="
  if [ ! -s "$COLL" ]; then echo "  (no collapsed file — stack likely failed)"; continue; fi
  RPS=$(cat /tmp/prof-${L}.rps 2>/dev/null || echo 0)

  # --- kernel% / user% by LEAF frame (on-CPU location at sample time) ---
  awk '{cnt=$NF; line=$0; sub(/ [0-9]+$/,"",line); n=split(line,a,";"); leaf=a[n];
        tot+=cnt; if (leaf ~ /_\[k\]$/) k+=cnt}
       END{printf "  samples=%d  kernel(leaf)=%d (%.1f%%)  user=%.1f%%\n", tot,k,100*k/tot,100*(tot-k)/tot}' "$COLL"

  # --- serializer (jackson, inclusive) + db-client (inclusive) shares of total CPU ---
  awk '{cnt=$NF; tot+=cnt;
        if (tolower($0) ~ /jackson/) j+=cnt;
        if ($0 ~ /postgresql|pgjdbc|PgResultSet|PGStream|VisibleBuffered|ByteConverter|pgclient|[Vv]ertx.*[Pp]g|hibernate|Hibernate|Agroal/) d+=cnt}
       END{printf "  serializer(jackson,incl)=%.1f%%   db-client(incl)=%.1f%%\n", 100*j/tot, 100*d/tot}' "$COLL"

  # --- syscalls / request (Probe 1, root) ---
  SYS=$(grep raw_syscalls /tmp/prof-${L}.syscalls.txt 2>/dev/null | grep -oE '[0-9][0-9,]*' | head -1 | tr -d ',')
  if [ -n "${SYS:-}" ] && awk -v r="$RPS" 'BEGIN{exit !(r>0)}'; then
    awk -v s="$SYS" -v r="$RPS" 'BEGIN{printf "  syscalls_30s=%s  rps=%.0f  => syscalls/req = %.2f\n", s, r, s/(r*30)}'
  else
    echo "  syscalls_30s=${SYS:-n/a}  rps=$RPS  => syscalls/req = n/a"
  fi

  echo "  -- top KERNEL leaf frames --"
  awk '{cnt=$NF; line=$0; sub(/ [0-9]+$/,"",line); n=split(line,a,";"); leaf=a[n];
        if (leaf ~ /_\[k\]$/) print cnt,leaf}' "$COLL" \
    | awk '{s[$2]+=$1} END{for(f in s) print s[f],f}' | sort -rn | head -8 | sed 's/^/     /'
  echo "  -- top USER leaf frames --"
  awk '{cnt=$NF; line=$0; sub(/ [0-9]+$/,"",line); n=split(line,a,";"); leaf=a[n];
        if (leaf !~ /_\[k\]$/) print cnt,leaf}' "$COLL" \
    | awk '{s[$2]+=$1} END{for(f in s) print s[f],f}' | sort -rn | head -8 | sed 's/^/     /'

  echo "  -- system-wide (Probe 3) top non-idle functions on cpuset --"
  perf report --stdio -i /tmp/perf-sys-${L}.data 2>/dev/null \
    | grep -vE "swapper|do_idle|cpuidle|secondary_startup|native_safe_halt|^#|^\s*$" \
    | head -12 | sed 's/^/     /'
  echo
done
