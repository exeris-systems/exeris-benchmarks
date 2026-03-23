#!/usr/bin/env bash
# Helper functions for JMH benchmark execution and result processing
set -u

# json_row_count(json_file) — count number of benchmark results in JMH JSON output
json_row_count() {
  local json_file="$1"

  if [[ ! -s "$json_file" ]]; then
    echo 0
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    jq 'length' "$json_file" 2>/dev/null || echo 0
    return
  fi

  # Best-effort fallback when jq is unavailable.
  grep -c '"benchmark"' "$json_file" 2>/dev/null || echo 0
}

# estimate_failed_cases(bench_rc, completed_cases, log_file) — estimate number of failed benchmark cases
estimate_failed_cases() {
  local bench_rc="$1"
  local completed_cases="$2"
  local log_file="$3"

  if [[ "$bench_rc" -eq 0 ]]; then
    echo 0
    return
  fi

  if [[ -f "$log_file" ]]; then
    local log_failed
    log_failed="$(grep -Eic 'Benchmark.*(failed|error)|<failure>|Exception in thread' "$log_file" 2>/dev/null || true)"
    if [[ "$log_failed" -gt 0 ]]; then
      echo "$log_failed"
      return
    fi
  fi

  if [[ "$completed_cases" -gt 0 ]]; then
    echo 1
    return
  fi

  echo 1
}

# write_cmd_artifacts(cmd_file, jvm_args_file, cmd_array_args...) — write command and extracted JVM args to files
redact_cmd_arg_for_artifacts() {
  local arg="$1"
  printf '%s' "$arg" | sed -E \
    -e 's/(-Dexeris\.tls\.enterprise\.[^=[:space:]]*=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/eu\.exeris\.kernel\.enterprise\.[A-Za-z0-9_$.]+/eu.exeris.kernel.enterprise.[REDACTED]/g'
}

write_cmd_artifacts() {
  local cmd_file="$1"
  local jvm_args_file="$2"
  shift 2
  local cmd=( "$@" )
  local redacted_cmd=()
  local java_idx=-1
  local i

  for arg in "${cmd[@]}"; do
    redacted_cmd+=("$(redact_cmd_arg_for_artifacts "$arg")")
  done

  printf '%q ' "${redacted_cmd[@]}" > "$cmd_file"
  echo >> "$cmd_file"

  : > "$jvm_args_file"

  for ((i = 0; i < ${#cmd[@]}; i++)); do
    if [[ "${cmd[$i]}" == "java" ]]; then
      java_idx=$i
      break
    fi
  done

  if [[ $java_idx -lt 0 ]]; then
    return
  fi

  for ((i = java_idx + 1; i < ${#cmd[@]}; i++)); do
    if [[ "${cmd[$i]}" == "-cp" || "${cmd[$i]}" == "-classpath" ]]; then
      break
    fi
    printf '%s\n' "$(redact_cmd_arg_for_artifacts "${cmd[$i]}")" >> "$jvm_args_file"
  done
}

# count_log_failures(log_file) — count failure/error patterns in benchmark log
count_log_failures() {
  local log_file="$1"
  
  if [[ ! -f "$log_file" ]]; then
    echo 0
    return
  fi

  grep -Eic 'Benchmark.*(failed|error)|<failure>|Exception in thread' "$log_file" 2>/dev/null || echo 0
}
