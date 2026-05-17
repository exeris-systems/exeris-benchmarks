#!/usr/bin/env bash
# destructive.sh — shared helpers for destructive / fuzz / chaos campaigns.
#
# All functions are side-effect-free except where documented. Source this file
# into a campaign script; assume readiness.sh has already been sourced if you
# need bench_health_http_code.
#
# Reusable helpers:
#   destructive_capture_rss <pid>
#       echoes "<rss_bytes> <vsz_bytes>" on stdout, or "unobtained unobtained"
#       if the PID is unknown / /proc entry is gone / ps output is empty.
#       Callers MUST distinguish "unobtained" from numeric 0 — emitting a
#       literal 0 here would silently classify a no-signal run as "stable".
#   destructive_jcmd_native_heap_committed <pid>
#       echoes committed-native-heap-bytes from `jcmd <pid> VM.native_memory summary`
#       requires NMT to be enabled on the target; echoes "" if unavailable
#   destructive_start_jfr <pid> <output_file> [name]
#       starts a JFR profile recording; returns 0 on success
#   destructive_stop_jfr <pid> [name]
#       stops the recording started with destructive_start_jfr
#   destructive_liveness_probe <base_url> <path> <expected_status> <max_response_ms>
#       sends one curl GET to the target; sets DESTR_PROBE_* env vars
#   destructive_emit_findings_json <output_path> <jq-filter>
#       writes a destructive-findings.json sidecar from jq filter input

set -u

DESTR_PROBE_STATUS=""
DESTR_PROBE_DURATION_MS=""
DESTR_PROBE_ALIVE=""

destructive_capture_rss() {
  local pid="${1:-}"
  if [[ -z "$pid" || "$pid" == "0" || ! -d "/proc/$pid" ]]; then
    echo "unobtained unobtained"
    return 1
  fi
  local rss_kb vsz_kb
  read -r rss_kb vsz_kb < <(ps -o rss=,vsz= -p "$pid" 2>/dev/null | tr -s ' ' || true)
  if [[ -z "${rss_kb:-}" || -z "${vsz_kb:-}" ]]; then
    echo "unobtained unobtained"
    return 1
  fi
  printf '%d %d\n' "$((rss_kb * 1024))" "$((vsz_kb * 1024))"
}

destructive_jcmd_native_heap_committed() {
  local pid="${1:-}"
  if [[ -z "$pid" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  local nmt_out
  nmt_out="$(jcmd "$pid" VM.native_memory summary scale=KB 2>/dev/null || true)"
  if [[ -z "$nmt_out" || "$nmt_out" == *"Native memory tracking is not enabled"* ]]; then
    return 1
  fi
  local committed_kb
  committed_kb="$(printf '%s' "$nmt_out" | awk '
    /Total:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /committed=/) {
          gsub(/[^0-9]/, "", $i)
          print $i
          exit
        }
      }
    }')"
  if [[ -z "$committed_kb" || ! "$committed_kb" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%d\n' "$((committed_kb * 1024))"
}

destructive_start_jfr() {
  local pid="${1:-}"
  local output="${2:-}"
  local name="${3:-destructive}"
  if [[ -z "$pid" || -z "$output" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  jcmd "$pid" JFR.start name="$name" settings=profile filename="$output" dumponexit=true \
    >/dev/null 2>&1
}

destructive_stop_jfr() {
  local pid="${1:-}"
  local name="${2:-destructive}"
  if [[ -z "$pid" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  jcmd "$pid" JFR.stop name="$name" >/dev/null 2>&1
}

destructive_force_gc() {
  local pid="${1:-}"
  if [[ -z "$pid" ]] || ! command -v jcmd >/dev/null 2>&1; then
    return 1
  fi
  jcmd "$pid" GC.run >/dev/null 2>&1 || true
  sleep 1
  jcmd "$pid" GC.run >/dev/null 2>&1 || true
}

destructive_liveness_probe() {
  local base_url="${1:?destructive_liveness_probe: base_url required}"
  local path="${2:-/health}"
  local expected_status="${3:-200}"
  local max_response_ms="${4:-1000}"
  local url="${base_url%/}${path}"

  DESTR_PROBE_STATUS=""
  DESTR_PROBE_DURATION_MS=""
  DESTR_PROBE_ALIVE="false"

  local start_ms end_ms code
  start_ms="$(date -u +%s%3N)"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo '000')"
  end_ms="$(date -u +%s%3N)"

  DESTR_PROBE_STATUS="$code"
  DESTR_PROBE_DURATION_MS="$((end_ms - start_ms))"

  if [[ "$code" == "$expected_status" ]] \
     && (( DESTR_PROBE_DURATION_MS <= max_response_ms )); then
    DESTR_PROBE_ALIVE="true"
    return 0
  fi
  return 1
}

# Compute degradation_class from collected signals.
# Usage:
#   destructive_classify <crash_count> <oom_count> <hang_count> \
#                        <rss_delta_bytes> <rss_growth_pct_max> <rss_before_bytes> \
#                        <probe_alive>
# Echoes one of: graceful-shed | timeout-flood | crash | oom | leak-suspected | stable
destructive_classify() {
  local crash="${1:-0}"
  local oom="${2:-0}"
  local hang="${3:-0}"
  local rss_delta="${4:-0}"
  local rss_growth_pct_max="${5:-5}"
  local rss_before="${6:-1}"
  local probe_alive="${7:-true}"

  if (( oom > 0 )); then
    echo "oom"; return 0
  fi
  if (( crash > 0 )); then
    echo "crash"; return 0
  fi
  if [[ "$probe_alive" != "true" ]]; then
    echo "timeout-flood"; return 0
  fi
  if (( hang > 0 )); then
    echo "graceful-shed"; return 0
  fi
  if (( rss_before > 0 )); then
    local growth_pct=$((rss_delta * 100 / rss_before))
    if (( growth_pct > rss_growth_pct_max )); then
      echo "leak-suspected"; return 0
    fi
  fi
  echo "stable"
}
