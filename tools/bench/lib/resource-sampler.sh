#!/usr/bin/env bash
set -u

BENCH_RESOURCE_SAMPLER_PID="${BENCH_RESOURCE_SAMPLER_PID:-}"

bench_start_resource_sampler() {
  local pid="$1"
  local csv_file="$2"
  local page_size

  BENCH_RESOURCE_SAMPLER_PID=""

  if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
    return 0
  fi

  page_size="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
  printf 'epoch_ms,utime_ticks,stime_ticks,rss_kb,vmsize_kb,threads,vmhwm_kb,smaps_rss_kb,cgroup_mem_kb\n' > "$csv_file"

  (
    while [[ -d "/proc/$pid" ]]; do
      local stat_line rest epoch_ms
      local utime_ticks stime_ticks threads vmsize_bytes rss_pages rss_kb vmsize_kb
      local -a stat_fields

      stat_line="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
      if [[ -z "$stat_line" ]]; then
        sleep 1
        continue
      fi

      rest="${stat_line#*) }"
      read -r -a stat_fields <<< "$rest"
      if (( ${#stat_fields[@]} < 22 )); then
        sleep 1
        continue
      fi

      epoch_ms="$(date +%s%3N)"
      utime_ticks="${stat_fields[11]}"
      stime_ticks="${stat_fields[12]}"
      threads="${stat_fields[17]}"
      vmsize_bytes="${stat_fields[20]}"
      rss_pages="${stat_fields[21]}"
      rss_kb="$(( rss_pages * page_size / 1024 ))"
      vmsize_kb="$(( vmsize_bytes / 1024 ))"

      local vmhwm_kb="0"
      vmhwm_kb="$(awk '/^VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"

      local smaps_rss_kb="0"
      smaps_rss_kb="$(awk '/^Rss:/{sum+=$2} END{print sum+0}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo 0)"

      local cgroup_mem_kb="0"
      local _cgmem=""
      _cgmem="$(grep '^0::' /proc/"$pid"/cgroup 2>/dev/null | cut -d: -f3 | xargs -I{} cat /sys/fs/cgroup{}/memory.current 2>/dev/null || true)"
      if [[ "$_cgmem" =~ ^[0-9]+$ ]]; then
        cgroup_mem_kb="$(( _cgmem / 1024 ))"
      fi

      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$epoch_ms" "$utime_ticks" "$stime_ticks" "$rss_kb" "$vmsize_kb" "$threads" "$vmhwm_kb" "$smaps_rss_kb" "$cgroup_mem_kb" >> "$csv_file"
      sleep 1
    done
  ) &

  BENCH_RESOURCE_SAMPLER_PID="$!"
}

bench_stop_resource_sampler() {
  if [[ -n "$BENCH_RESOURCE_SAMPLER_PID" ]]; then
    kill "$BENCH_RESOURCE_SAMPLER_PID" >/dev/null 2>&1 || true
    wait "$BENCH_RESOURCE_SAMPLER_PID" 2>/dev/null || true
    BENCH_RESOURCE_SAMPLER_PID=""
  fi
}

bench_summarize_resource_samples() {
  local csv_file="$1"
  local json_file="$2"
  local ticks_per_second
  local host_logical_cpus

  ticks_per_second="$(getconf CLK_TCK 2>/dev/null || echo 100)"
  host_logical_cpus="$(nproc 2>/dev/null || echo 1)"

  local awk_stats
  awk_stats="$(
    LC_ALL=C awk -F',' -v tps="$ticks_per_second" '
    NR==1 { next }
    NF < 6 { next }
    {
      epoch  = $1 + 0
      total  = $2 + $3
      rss    = $4 + 0
      vm     = $5 + 0
      thr    = $6 + 0
      hwm    = (NF >= 7) ? $7 + 0 : 0
      smaps  = (NF >= 8) ? $8 + 0 : 0
      cgmem  = (NF >= 9) ? $9 + 0 : 0

      if (count == 0) {
        first_epoch = epoch
        first_cpu   = total
        rss_min=rss; vm_min=vm; thr_min=thr
        hwm_min=hwm; smaps_min=smaps; cgmem_min=cgmem
      }
      count++
      last_epoch = epoch
      last_cpu   = total

      rss_sum+=rss; if(rss>rss_max) rss_max=rss; if(rss<rss_min) rss_min=rss
      vm_sum+=vm;   if(vm>vm_max)   vm_max=vm;   if(vm<vm_min)   vm_min=vm
      thr_sum+=thr; if(thr>thr_max) thr_max=thr; if(thr<thr_min) thr_min=thr
      hwm_sum+=hwm;   if(hwm>hwm_max)     hwm_max=hwm;     if(hwm<hwm_min)     hwm_min=hwm
      smaps_sum+=smaps; if(smaps>smaps_max) smaps_max=smaps; if(smaps<smaps_min) smaps_min=smaps
      cgmem_sum+=cgmem; if(cgmem>cgmem_max) cgmem_max=cgmem; if(cgmem<cgmem_min) cgmem_min=cgmem
    }
    END {
      if (count == 0) {
        print "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
      } else {
        cpu_delta  = last_cpu - first_cpu
        if (cpu_delta < 0) cpu_delta = 0
        cpu_secs   = (tps > 0) ? cpu_delta / tps : 0
        elapsed_ms = last_epoch - first_epoch
        elapsed_s  = (elapsed_ms > 0) ? elapsed_ms / 1000.0 : 0
        printf "%d %.6f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.6f\n",
          count,
          cpu_secs,
          rss_min, int(rss_sum/count), rss_max,
          vm_min,  int(vm_sum/count),  vm_max,
          thr_min, int(thr_sum/count), thr_max,
          hwm_min, int(hwm_sum/count), hwm_max,
          smaps_min, int(smaps_sum/count), smaps_max,
          cgmem_min, int(cgmem_sum/count), cgmem_max,
          first_cpu, last_cpu,
          cpu_delta,
          elapsed_s
      }
    }' "$csv_file" 2>/dev/null
  )" || awk_stats="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"

  local sample_count cpu_time_seconds
  local rss_min rss_avg rss_max vm_min vm_avg vm_max
  local thr_min thr_avg thr_max hwm_min hwm_avg hwm_max
  local smaps_min smaps_avg smaps_max cgmem_min cgmem_avg cgmem_max
  local first_cpu last_cpu cpu_delta elapsed_s
  read -r sample_count cpu_time_seconds \
    rss_min rss_avg rss_max \
    vm_min  vm_avg  vm_max \
    thr_min thr_avg thr_max \
    hwm_min hwm_avg hwm_max \
    smaps_min smaps_avg smaps_max \
    cgmem_min cgmem_avg cgmem_max \
    first_cpu last_cpu cpu_delta elapsed_s \
    <<< "$awk_stats"

  local cpu_util_pct_one_core="0"
  local avg_cores_used="0"
  local cpu_util_pct_host_total="0"
  if LC_ALL=C awk -v cs="$cpu_time_seconds" -v es="$elapsed_s" \
       'BEGIN { exit (es > 0.001 && cs > 0) ? 0 : 1 }' 2>/dev/null; then
    cpu_util_pct_one_core="$(LC_ALL=C awk -v cs="$cpu_time_seconds" -v es="$elapsed_s" \
      'BEGIN { printf "%.4f", (cs / es) * 100 }')"
    avg_cores_used="$(LC_ALL=C awk -v cs="$cpu_time_seconds" -v es="$elapsed_s" \
      'BEGIN { printf "%.4f", cs / es }')"
    cpu_util_pct_host_total="$(LC_ALL=C awk -v ac="$avg_cores_used" -v cpus="$host_logical_cpus" \
      'BEGIN { printf "%.4f", (cpus > 0) ? (ac / cpus) * 100 : 0 }')"
  fi

  jq -n \
    --argjson sample_count                    "${sample_count:-0}" \
    --arg     cpu_time_seconds                "${cpu_time_seconds:-0}" \
    --argjson host_logical_cpus               "${host_logical_cpus:-1}" \
    --arg     cpu_util_percent_of_one_core    "${cpu_util_pct_one_core:-0}" \
    --arg     avg_cores_used                  "${avg_cores_used:-0}" \
    --arg     cpu_util_percent_of_host_total  "${cpu_util_pct_host_total:-0}" \
    --argjson rss_kb_min                      "${rss_min:-0}" \
    --argjson rss_kb_avg                      "${rss_avg:-0}" \
    --argjson peak_rss_kb                     "${rss_max:-0}" \
    --argjson vmsize_kb_min                   "${vm_min:-0}" \
    --argjson vmsize_kb_avg                   "${vm_avg:-0}" \
    --argjson peak_vmsize_kb                  "${vm_max:-0}" \
    --argjson threads_min                     "${thr_min:-0}" \
    --argjson threads_avg                     "${thr_avg:-0}" \
    --argjson peak_threads                    "${thr_max:-0}" \
    --argjson vmhwm_kb_max                    "${hwm_max:-0}" \
    --argjson smaps_rss_kb_avg                "${smaps_avg:-0}" \
    --argjson smaps_rss_kb_max                "${smaps_max:-0}" \
    --argjson cgroup_memory_current_kb_avg    "${cgmem_avg:-0}" \
    --argjson cgroup_memory_current_kb_max    "${cgmem_max:-0}" \
    '{
      sample_count:                     $sample_count,
      cpu_time_seconds:                 ($cpu_time_seconds | tonumber),
      host_logical_cpus:                $host_logical_cpus,
      cpu_util_percent_of_one_core:     ($cpu_util_percent_of_one_core | tonumber),
      avg_cores_used:                   ($avg_cores_used | tonumber),
      cpu_util_percent_of_host_total:   ($cpu_util_percent_of_host_total | tonumber),
      rss_kb_min:                       $rss_kb_min,
      rss_kb_avg:                       $rss_kb_avg,
      peak_rss_kb:                      $peak_rss_kb,
      vmsize_kb_min:                    $vmsize_kb_min,
      vmsize_kb_avg:                    $vmsize_kb_avg,
      peak_vmsize_kb:                   $peak_vmsize_kb,
      threads_min:                      $threads_min,
      threads_avg:                      $threads_avg,
      peak_threads:                     $peak_threads,
      vmhwm_kb_max:                     $vmhwm_kb_max,
      smaps_rss_kb_avg:                 $smaps_rss_kb_avg,
      smaps_rss_kb_max:                 $smaps_rss_kb_max,
      cgroup_memory_current_kb_avg:     $cgroup_memory_current_kb_avg,
      cgroup_memory_current_kb_max:     $cgroup_memory_current_kb_max
    }' > "$json_file"
}

bench_augment_resource_metrics_with_jvm_breakdown() {
  local pid="$1"
  local json_file="$2"
  local heap_info="" nmt_summary=""
  local heap_used_kb="" heap_committed_kb="" heap_reserved_kb=""
  local nmt_total_reserved_kb="" nmt_total_committed_kb=""
  local nmt_java_heap_reserved_kb="" nmt_java_heap_committed_kb=""
  local tmp_json

  if [[ -z "$pid" || ! -f "$json_file" ]]; then
    return 0
  fi
  if ! command -v jcmd >/dev/null 2>&1; then
    return 0
  fi

  heap_info="$(jcmd "$pid" GC.heap_info 2>/dev/null || true)"
  nmt_summary="$(jcmd "$pid" VM.native_memory summary scale=KB 2>/dev/null || true)"

  if [[ -n "$heap_info" ]]; then
    heap_used_kb="$(printf '%s\n' "$heap_info" | \
      sed -nE 's/.*used[ =]*([0-9]+)K.*/\1/p' | head -n 1)"
    heap_committed_kb="$(printf '%s\n' "$heap_info" | \
      sed -nE 's/.*committed[ =]*([0-9]+)K.*/\1/p' | head -n 1)"
    heap_reserved_kb="$(printf '%s\n' "$heap_info" | \
      sed -nE 's/.*reserved[ =]*([0-9]+)K.*/\1/p' | head -n 1)"
  fi

  if [[ -n "$nmt_summary" ]]; then
    nmt_total_reserved_kb="$(printf '%s\n' "$nmt_summary" | \
      sed -nE 's/^[[:space:]]*Total:[[:space:]]*reserved=([0-9]+)KB, committed=([0-9]+)KB.*/\1/p' | head -n 1)"
    nmt_total_committed_kb="$(printf '%s\n' "$nmt_summary" | \
      sed -nE 's/^[[:space:]]*Total:[[:space:]]*reserved=([0-9]+)KB, committed=([0-9]+)KB.*/\2/p' | head -n 1)"
    nmt_java_heap_reserved_kb="$(printf '%s\n' "$nmt_summary" | \
      sed -nE 's/^[[:space:]]*-?[[:space:]]*Java Heap[[:space:]]*\(reserved=([0-9]+)KB, committed=([0-9]+)KB\).*/\1/p' | head -n 1)"
    nmt_java_heap_committed_kb="$(printf '%s\n' "$nmt_summary" | \
      sed -nE 's/^[[:space:]]*-?[[:space:]]*Java Heap[[:space:]]*\(reserved=([0-9]+)KB, committed=([0-9]+)KB\).*/\2/p' | head -n 1)"
  fi

  local offheap_kb_estimate="" nmt_enabled="false"

  if [[ -n "$nmt_total_committed_kb" && -n "$nmt_java_heap_committed_kb" ]]; then
    offheap_kb_estimate=$(( nmt_total_committed_kb - nmt_java_heap_committed_kb )) || offheap_kb_estimate=""
    nmt_enabled="true"
  fi

  tmp_json="$(mktemp)"
  jq \
    --arg pid                        "$pid" \
    --arg heap_used_kb               "$heap_used_kb" \
    --arg heap_committed_kb          "$heap_committed_kb" \
    --arg heap_reserved_kb           "$heap_reserved_kb" \
    --arg nmt_total_reserved_kb      "$nmt_total_reserved_kb" \
    --arg nmt_total_committed_kb     "$nmt_total_committed_kb" \
    --arg nmt_java_heap_reserved_kb  "$nmt_java_heap_reserved_kb" \
    --arg nmt_java_heap_committed_kb "$nmt_java_heap_committed_kb" \
    --arg offheap_kb_estimate        "$offheap_kb_estimate" \
    --arg nmt_enabled                "$nmt_enabled" \
    '.jvm = (
      (.jvm // {})
      + {pid: ($pid | tonumber)}
      + (if $heap_used_kb             != "" then {heap_used_kb:             ($heap_used_kb             | tonumber)} else {} end)
      + (if $heap_committed_kb        != "" then {heap_committed_kb:        ($heap_committed_kb        | tonumber)} else {} end)
      + (if $heap_reserved_kb         != "" then {heap_reserved_kb:         ($heap_reserved_kb         | tonumber)} else {} end)
      + (if $nmt_total_reserved_kb    != "" then {nmt_total_reserved_kb:    ($nmt_total_reserved_kb    | tonumber)} else {} end)
      + (if $nmt_total_committed_kb   != "" then {nmt_total_committed_kb:   ($nmt_total_committed_kb   | tonumber)} else {} end)
      + (if $nmt_java_heap_reserved_kb  != "" then {nmt_java_heap_reserved_kb:  ($nmt_java_heap_reserved_kb  | tonumber)} else {} end)
      + (if $nmt_java_heap_committed_kb != "" then {nmt_java_heap_committed_kb: ($nmt_java_heap_committed_kb | tonumber)} else {} end)
      + (if $offheap_kb_estimate      != "" then {offheap_kb_estimate: ($offheap_kb_estimate | tonumber), offheap_estimate_source: "nmt_minus_java_heap"} else {} end)
      + {nmt_enabled: ($nmt_enabled == "true")}
    )' "$json_file" > "$tmp_json"
  mv "$tmp_json" "$json_file"
}
