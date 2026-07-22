#!/usr/bin/env bash
# Recovery-aware aggregator for the entity-read memory-cpu matrix.
# Reads every point-*/arm/repeat-* dir. For rc=0 runs uses result.json; for rc!=0
# runs (128m memory-edge SIGTERM before result.json) RECOVERS rps+total_requests from
# driver-wrk.log and cpu_time+RSS from resource-metrics.json -- validated identical
# to clean runs. Emits normalized-runs.jsonl + median tables (memory curve @4vcpu,
# cpu cut @1GB), per arm, with pg_rss alongside (outside the app budget).
set -uo pipefail
CAMP="${1:?usage: aggregate-matrix.sh <campaign-dir>}"
OUT="$CAMP/normalized-runs.jsonl"
: > "$OUT"

jnum() { local v="$1"; [[ -z "$v" || "$v" == "null" ]] && echo null || echo "$v"; }

for pdir in "$CAMP"/point-*; do
  [[ -d "$pdir" ]] || continue
  bn=$(basename "$pdir")
  mem=$(sed -E 's/point-([0-9]+)m-([0-9]+)vcpu/\1/' <<<"$bn")
  vcpu=$(sed -E 's/point-([0-9]+)m-([0-9]+)vcpu/\2/' <<<"$bn")
  for adir in "$pdir"/*; do
    [[ -d "$adir" ]] || continue
    arm=$(basename "$adir")
    for rdir in "$adir"/repeat-*; do
      [[ -d "$rdir" ]] || continue
      repeat=$(sed 's/repeat-//' <<<"$(basename "$rdir")")
      rps=""; tr=""; src=""
      if [[ -f "$rdir/result.json" ]]; then
        src="clean"
        rps=$(jq -r '.metrics.throughput_rps // empty' "$rdir/result.json" 2>/dev/null)
        tr=$(jq -r '.metrics.total_requests // empty' "$rdir/result.json" 2>/dev/null)
      elif [[ -f "$rdir/driver-wrk.log" ]]; then
        src="recovered"
        rps=$(grep -oE 'Requests/sec:[[:space:]]*[0-9.]+' "$rdir/driver-wrk.log" 2>/dev/null | grep -oE '[0-9.]+$' | tail -1)
        tr=$(grep -oE '[0-9]+ requests in' "$rdir/driver-wrk.log" 2>/dev/null | grep -oE '^[0-9]+' | tail -1)
      else
        src="missing"
      fi
      cpu=$(jq -r '.cpu_time_seconds // empty' "$rdir/resource-metrics.json" 2>/dev/null)
      rss=$(jq -r '.peak_rss_kb // empty' "$rdir/resource-metrics.json" 2>/dev/null)
      smaps=$(jq -r '.smaps_rss_kb_max // empty' "$rdir/resource-metrics.json" 2>/dev/null)
      cores=$(jq -r '.avg_cores_used // empty' "$rdir/resource-metrics.json" 2>/dev/null)
      cgmem=$(jq -r '(.cgroup_effective.memory_peak_bytes // empty) | if .=="" then empty else (./1024|floor) end' "$rdir/constrained-execution-evidence.json" 2>/dev/null)
      # pg_rss is captured by the matrix (docker-stats), stored per-run in runs.jsonl keyed by run_dir.
      pgrss=$(jq -r --arg d "$rdir" 'select(.run_dir==$d)|.pg_rss_kb // empty' "$CAMP/runs.jsonl" 2>/dev/null | head -1)
      jq -cn \
        --argjson mem "$mem" --argjson vcpu "$vcpu" --arg arm "$arm" --argjson repeat "$repeat" \
        --arg src "$src" \
        --argjson rps "$(jnum "$rps")" --argjson tr "$(jnum "$tr")" \
        --argjson cpu "$(jnum "$cpu")" --argjson rss "$(jnum "$rss")" --argjson smaps "$(jnum "$smaps")" \
        --argjson cores "$(jnum "$cores")" --argjson cgmem "$(jnum "$cgmem")" --argjson pgrss "$(jnum "$pgrss")" \
        '{mem_mb:$mem, vcpu:$vcpu, arm:$arm, repeat:$repeat, src:$src, rps:$rps,
          total_requests:$tr, cpu_time_s:$cpu,
          cpu_per_req_ms:(if $cpu!=null and $tr!=null and $tr>0 then ($cpu/$tr*1000) else null end),
          peak_rss_kb:$rss, smaps_rss_kb:$smaps, cgroup_mem_peak_kb:$cgmem,
          avg_cores:$cores, pg_rss_kb:$pgrss}' >> "$OUT"
    done
  done
done

echo "== normalized runs: $(wc -l < "$OUT") =="
echo
echo "## Memory curve (fixed 4 vCPU) — median across repeats"
echo "arm | mem_mb | rps | cpu/req_ms | peak_rss_mb | smaps_rss_mb | avg_cores | pg_rss_mb | n | src"
jq -s -r '
  def med(f): map(f)|map(select(.!=null))|sort|if length==0 then null elif length%2==1 then .[(length/2|floor)] else (.[length/2-1]+.[length/2])/2 end;
  [.[]|select(.vcpu==4)] | group_by([.arm,.mem_mb]) | .[]
  | { arm:.[0].arm, mem:.[0].mem_mb, n:length,
      rps:(med(.rps)), cpr:(med(.cpu_per_req_ms)),
      rss:(med(.peak_rss_kb)), smaps:(med(.smaps_rss_kb)), cores:(med(.avg_cores)),
      pg:(med(.pg_rss_kb)), rec:([.[]|select(.src=="recovered")]|length) }
  | "\(.arm) | \(.mem) | \(if .rps then (.rps|floor) else "-" end) | \(if .cpr then (.cpr*10000|round/10000) else "-" end) | \(if .rss then (.rss/1024|floor) else "-" end) | \(if .smaps then (.smaps/1024|floor) else "-" end) | \(if .cores then (.cores*100|round/100) else "-" end) | \(if .pg then (.pg/1024|floor) else "-" end) | \(.n) | \(if .rec>0 then "\(.rec) recovered" else "clean" end)"
' "$OUT" | sort -t'|' -k1,1 -k2,2n
echo
echo "## CPU cut (fixed 1024 MB) — median across repeats"
echo "arm | vcpu | rps | cpu/req_ms | peak_rss_mb | avg_cores | n | src"
jq -s -r '
  def med(f): map(f)|map(select(.!=null))|sort|if length==0 then null elif length%2==1 then .[(length/2|floor)] else (.[length/2-1]+.[length/2])/2 end;
  [.[]|select(.mem_mb==1024)] | group_by([.arm,.vcpu]) | .[]
  | { arm:.[0].arm, vcpu:.[0].vcpu, n:length,
      rps:(med(.rps)), cpr:(med(.cpu_per_req_ms)), rss:(med(.peak_rss_kb)), cores:(med(.avg_cores)),
      rec:([.[]|select(.src=="recovered")]|length) }
  | "\(.arm) | \(.vcpu) | \(if .rps then (.rps|floor) else "-" end) | \(if .cpr then (.cpr*10000|round/10000) else "-" end) | \(if .rss then (.rss/1024|floor) else "-" end) | \(if .cores then (.cores*100|round/100) else "-" end) | \(.n) | \(if .rec>0 then "\(.rec) recovered" else "clean" end)"
' "$OUT" | sort -t'|' -k1,1 -k2,2n
