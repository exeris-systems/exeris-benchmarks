#!/usr/bin/env bash
# run-wrk2.sh — Run CO-mitigated latency measurement with wrk2 at fixed arrival rate.
#
# This script performs a three-phase flow:
# 1) Discover approximate saturation using wrk (closed-loop) for 30s.
# 2) Warm up target state for 60s.
# 3) Measure with wrk2 (open-loop, fixed -R) to mitigate Coordinated Omission (CO).
#
# Usage:
#   ./scripts/run-wrk2.sh <target-profile-dir> <scenario-dir> [EXTRA_WRK2_ARGS...]
#
# Examples:
#   ./scripts/run-wrk2.sh targets/exeris-kernel/community scenarios/plaintext
#   WRK2_TARGET_RPS=80000 ./scripts/run-wrk2.sh targets/exeris-kernel/community scenarios/json-1kb
#   WRK2_THREADS=8 WRK2_CONNECTIONS=256 WRK2_DURATION=90s ./scripts/run-wrk2.sh targets/exeris-kernel/community scenarios/keepalive-steady
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

TARGET_DIR="${1:?Usage: run-wrk2.sh <target-dir> <scenario-dir> [EXTRA_WRK2_ARGS...]}"
SCENARIO_DIR="${2:?Usage: run-wrk2.sh <target-dir> <scenario-dir> [EXTRA_WRK2_ARGS...]}"
shift 2

TARGET_DIR="$ROOT/$TARGET_DIR"
SCENARIO_DIR="$ROOT/$SCENARIO_DIR"

if ! command -v wrk2 >/dev/null 2>&1; then
  echo "ERROR: wrk2 binary not found in PATH." >&2
  echo "  Install wrk2 and retry." >&2
  exit 1
fi
if ! command -v wrk >/dev/null 2>&1; then
  echo "ERROR: wrk binary not found in PATH." >&2
  echo "  wrk is required for the saturation discovery and warmup passes." >&2
  exit 1
fi

# Target config is optional when a base URL is supplied via the environment
# (e.g. WRK_BASE_URL_OVERRIDE from run-guided.sh for local/WAN dispatch).
TARGET_CONFIG="$TARGET_DIR/wrk-target.env"
if [[ -f "$TARGET_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$TARGET_CONFIG"
elif [[ -z "${WRK_BASE_URL_OVERRIDE:-}${WRK_BASE_URL:-}" ]]; then
  echo "ERROR: Target config not found: $TARGET_CONFIG (and no WRK_BASE_URL/WRK_BASE_URL_OVERRIDE set)" >&2
  exit 1
fi

SCENARIO_CONFIG="$SCENARIO_DIR/wrk.env"
if [[ -f "$SCENARIO_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$SCENARIO_CONFIG"
fi

# Overrides win over both target and scenario config (guided local/WAN dispatch).
WRK_BASE_URL="${WRK_BASE_URL_OVERRIDE:-${WRK_BASE_URL:-}}"
WRK_PATH="${WRK_PATH_OVERRIDE:-${WRK_PATH:-/}}"
if [[ -z "${WRK_BASE_URL:-}" ]]; then
  echo "ERROR: WRK_BASE_URL is empty (set it in $TARGET_CONFIG or via WRK_BASE_URL_OVERRIDE)" >&2
  exit 1
fi

LUA_SCRIPT="${WRK_LUA_SCRIPT:-}"
THREADS="${WRK2_THREADS_OVERRIDE:-${WRK2_THREADS:-4}}"
CONNECTIONS="${WRK2_CONNECTIONS_OVERRIDE:-${WRK2_CONNECTIONS:-100}}"
DURATION="${WRK2_DURATION_OVERRIDE:-${WRK2_DURATION:-60s}}"
HARDWARE_PROFILE_VALUE="${HARDWARE_PROFILE:-dev-laptop}"
URL="${WRK_BASE_URL}${WRK_PATH:-/}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$ROOT/results/raw"
mkdir -p "$RESULTS_DIR"
RESULT_JSON="$RESULTS_DIR/wrk2-${TIMESTAMP}.json"
RESULT_RAW_FILE="$(mktemp)"
PERCENTILES_FILE="$(mktemp)"
trap 'rm -f "$RESULT_RAW_FILE" "$PERCENTILES_FILE"' EXIT

WRK_BASE_CMD=(wrk -t "$THREADS" -c "$CONNECTIONS")
if [[ -n "$LUA_SCRIPT" ]]; then
  WRK_BASE_CMD+=(--script "$LUA_SCRIPT")
fi

echo "=== wrk2 benchmark (CO-mitigated) ==="
echo "  URL        : $URL"
echo "  Threads    : $THREADS"
echo "  Connections: $CONNECTIONS"
echo "  Duration   : $DURATION"
[[ -n "$LUA_SCRIPT" ]] && echo "  Lua script : $LUA_SCRIPT"
echo ""

echo "--- Saturation discovery (wrk, 30s) ---"
SATURATION_OUTPUT="$("${WRK_BASE_CMD[@]}" -d 30s "$URL" 2>&1)"
printf '%s\n' "$SATURATION_OUTPUT"
SATURATION_RPS="$(printf '%s\n' "$SATURATION_OUTPUT" | awk '/Requests\/sec:/ {print $2; exit}')"
if [[ -z "$SATURATION_RPS" ]]; then
  echo "ERROR: Failed to parse Requests/sec from saturation output." >&2
  exit 1
fi

MEASUREMENT_RPS="$(awk -v sat="$SATURATION_RPS" 'BEGIN { v = int(sat * 0.75); if (v < 1) v = 1; print v }')"
if [[ -n "${WRK2_TARGET_RPS:-}" ]]; then
  MEASUREMENT_RPS="$WRK2_TARGET_RPS"
  if awk -v target="$MEASUREMENT_RPS" -v sat="$SATURATION_RPS" 'BEGIN { exit (target > (0.95 * sat)) ? 0 : 1 }'; then
    echo "WARN: WRK2_TARGET_RPS=$MEASUREMENT_RPS exceeds 95% of observed saturation ($SATURATION_RPS)." >&2
  fi
fi

LOAD_FRACTION="$(awk -v target="$MEASUREMENT_RPS" -v sat="$SATURATION_RPS" 'BEGIN { if (sat <= 0) { print 0; exit } printf "%.6f", (target / sat) }')"
AT_SATURATION="$(awk -v fraction="$LOAD_FRACTION" 'BEGIN { if (fraction >= 0.95) print "true"; else print "false" }')"

echo ""
echo "--- Warmup (60s) ---"
"${WRK_BASE_CMD[@]}" -d 60s "$URL" > /dev/null

echo "--- Measurement (wrk2, fixed rate) ---"
WRK2_CMD=(wrk2 -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" -R "$MEASUREMENT_RPS" --latency)
if [[ -n "$LUA_SCRIPT" ]]; then
  WRK2_CMD+=(--script "$LUA_SCRIPT")
fi
"${WRK2_CMD[@]}" "$@" "$URL" | tee "$RESULT_RAW_FILE"

REQUESTS_PER_SEC="$(awk '/Requests\/sec:/ {print $2; exit}' "$RESULT_RAW_FILE")"
if [[ -z "$REQUESTS_PER_SEC" ]]; then
  echo "ERROR: Failed to parse Requests/sec from wrk2 output." >&2
  exit 1
fi

awk '
  function to_micros(raw, unit, n) {
    n = raw + 0
    if (unit == "us") return int(n + 0.5)
    if (unit == "ms") return int((n * 1000) + 0.5)
    if (unit == "s") return int((n * 1000000) + 0.5)
    return -1
  }
  function map_percentile(p) {
    if (p == "50.000") return "p50"
    if (p == "75.000") return "p75"
    if (p == "90.000") return "p90"
    if (p == "99.000") return "p99"
    if (p == "99.900") return "p99.9"
    if (p == "99.990") return "p99.99"
    if (p == "99.999") return "p99.999"
    return ""
  }
  /^[[:space:]]*[0-9]+\.[0-9]+%[[:space:]]+[0-9]+(\.[0-9]+)?(us|ms|s)[[:space:]]*$/ {
    percentile = $1
    gsub(/%/, "", percentile)
    key = map_percentile(percentile)
    if (key == "") next

    value = $2
    unit = ""
    if (value ~ /us$/) {
      unit = "us"
      sub(/us$/, "", value)
    } else if (value ~ /ms$/) {
      unit = "ms"
      sub(/ms$/, "", value)
    } else if (value ~ /s$/) {
      unit = "s"
      sub(/s$/, "", value)
    } else {
      next
    }

    micros = to_micros(value, unit)
    if (micros >= 0) {
      print key "\t" micros
    }
  }
' "$RESULT_RAW_FILE" > "$PERCENTILES_FILE"

if command -v jq >/dev/null 2>&1; then
  LATENCY_PERCENTILES_JSON="$(jq -Rn '[inputs | split("\t") | {percentile: .[0], latency_us: (.[1] | tonumber)}]' < "$PERCENTILES_FILE")"
  jq -n \
    --arg tool "wrk2" \
    --argjson co_corrected true \
    --argjson r_value "$MEASUREMENT_RPS" \
    --argjson observed_saturation_rps "$SATURATION_RPS" \
    --argjson load_fraction "$LOAD_FRACTION" \
    --argjson at_saturation "$AT_SATURATION" \
    --arg url "$URL" \
    --argjson threads "$THREADS" \
    --argjson connections "$CONNECTIONS" \
    --arg duration "$DURATION" \
    --argjson requests_per_sec "$REQUESTS_PER_SEC" \
    --arg timestamp "$TIMESTAMP" \
    --arg hardware_profile "$HARDWARE_PROFILE_VALUE" \
    --argjson latency_percentiles "$LATENCY_PERCENTILES_JSON" \
    '{
      tool: $tool,
      co_corrected: $co_corrected,
      r_value: $r_value,
      observed_saturation_rps: $observed_saturation_rps,
      load_fraction: $load_fraction,
      at_saturation: $at_saturation,
      url: $url,
      threads: $threads,
      connections: $connections,
      duration: $duration,
      requests_per_sec: $requests_per_sec,
      timestamp: $timestamp,
      hardware_profile: $hardware_profile,
      latency_percentiles: $latency_percentiles
    }' > "$RESULT_JSON"
else
  json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
  }

  latency_json="["
  first=1
  while IFS=$'\t' read -r percentile latency_us; do
    [[ -z "$percentile" ]] && continue
    if [[ $first -eq 0 ]]; then
      latency_json+=","
    fi
    latency_json+="{\"percentile\":\"$(json_escape "$percentile")\",\"latency_us\":${latency_us}}"
    first=0
  done < "$PERCENTILES_FILE"
  latency_json+="]"

  printf '%s\n' "{" > "$RESULT_JSON"
  printf '%s\n' "  \"tool\": \"wrk2\"," >> "$RESULT_JSON"
  printf '%s\n' "  \"co_corrected\": true," >> "$RESULT_JSON"
  printf '%s\n' "  \"r_value\": ${MEASUREMENT_RPS}," >> "$RESULT_JSON"
  printf '%s\n' "  \"observed_saturation_rps\": ${SATURATION_RPS}," >> "$RESULT_JSON"
  printf '%s\n' "  \"load_fraction\": ${LOAD_FRACTION}," >> "$RESULT_JSON"
  printf '%s\n' "  \"at_saturation\": ${AT_SATURATION}," >> "$RESULT_JSON"
  printf '%s\n' "  \"url\": \"$(json_escape "$URL")\"," >> "$RESULT_JSON"
  printf '%s\n' "  \"threads\": ${THREADS}," >> "$RESULT_JSON"
  printf '%s\n' "  \"connections\": ${CONNECTIONS}," >> "$RESULT_JSON"
  printf '%s\n' "  \"duration\": \"$(json_escape "$DURATION")\"," >> "$RESULT_JSON"
  printf '%s\n' "  \"requests_per_sec\": ${REQUESTS_PER_SEC}," >> "$RESULT_JSON"
  printf '%s\n' "  \"timestamp\": \"$(json_escape "$TIMESTAMP")\"," >> "$RESULT_JSON"
  printf '%s\n' "  \"hardware_profile\": \"$(json_escape "$HARDWARE_PROFILE_VALUE")\"," >> "$RESULT_JSON"
  printf '%s\n' "  \"latency_percentiles\": ${latency_json}" >> "$RESULT_JSON"
  printf '%s\n' "}" >> "$RESULT_JSON"
fi

echo ""
echo "Result written to: $RESULT_JSON"
echo "$RESULT_JSON"
