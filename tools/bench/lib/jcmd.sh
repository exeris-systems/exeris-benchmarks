#!/usr/bin/env bash
set -u

bench_capture_jcmd_diagnostics() {
  local pid="$1"
  local logs_dir="$2"
  local target_id="$3"
  local jcmd_available=false
  local pid_json="null"
  local vm_flags_status="skipped"
  local vm_command_line_status="skipped"
  local nmt_summary_status="skipped"
  local capture_utc

  mkdir -p "$logs_dir"
  capture_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if command -v jcmd >/dev/null 2>&1; then
    jcmd_available=true
  fi

  if [[ "$jcmd_available" == true && -n "$pid" && "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]]; then
    pid_json="$pid"

    if jcmd "$pid" VM.flags > "$logs_dir/jcmd-vm.flags.txt" 2>&1; then
      vm_flags_status="captured"
    else
      vm_flags_status="failed"
    fi

    if jcmd "$pid" VM.command_line > "$logs_dir/jcmd-vm.command_line.txt" 2>&1; then
      vm_command_line_status="captured"
    else
      vm_command_line_status="failed"
    fi

    if jcmd "$pid" VM.native_memory summary scale=KB > "$logs_dir/jcmd-nmt-summary.txt" 2>&1; then
      nmt_summary_status="captured"
    else
      nmt_summary_status="failed"
    fi
  fi

  jq -n \
    --arg     target_id              "$target_id" \
    --argjson pid                    "$pid_json" \
    --arg     capture_utc            "$capture_utc" \
    --argjson jcmd_available         "$jcmd_available" \
    --arg     vm_flags_status        "$vm_flags_status" \
    --arg     vm_command_line_status "$vm_command_line_status" \
    --arg     nmt_summary_status     "$nmt_summary_status" \
    '{
      target_id:              $target_id,
      pid:                    $pid,
      capture_utc:            $capture_utc,
      jcmd_available:         $jcmd_available,
      vm_flags_status:        $vm_flags_status,
      vm_command_line_status: $vm_command_line_status,
      nmt_summary_status:     $nmt_summary_status
    }' \
    > "$logs_dir/jcmd-diagnostics.json" || true
}
