#!/usr/bin/env bash
# run-destructive-radamsa.sh — drive a radamsa-mutated HTTP attack.
#
# Target MUST be launched externally before this script runs.
# `radamsa` MUST be on PATH.
#
# Usage:
#   ./scripts/run-destructive-radamsa.sh \
#       --base-url http://127.0.0.1:8080 \
#       --protocol h1|h2 \
#       --radamsa-seed <seed> \
#       [--target-pid <pid>] \
#       [--rps 500] [--duration 120] [--cooldown 30] \
#       [--health-path /health] [--output <dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tools/bench/lib/destructive.sh
source "$ROOT/tools/bench/lib/destructive.sh"
# shellcheck source=tools/bench/lib/readiness.sh
source "$ROOT/tools/bench/lib/readiness.sh"

BASE_URL=""
PROTOCOL=""
RADAMSA_SEED=""
TARGET_PID=""
RPS=500
DURATION=120
COOLDOWN=30
HEALTH_PATH="/health"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)      BASE_URL="$2";      shift 2 ;;
    --protocol)      PROTOCOL="$2";      shift 2 ;;
    --radamsa-seed)  RADAMSA_SEED="$2";  shift 2 ;;
    --target-pid)    TARGET_PID="$2";    shift 2 ;;
    --rps)           RPS="$2";           shift 2 ;;
    --duration)      DURATION="$2";      shift 2 ;;
    --cooldown)      COOLDOWN="$2";      shift 2 ;;
    --health-path)   HEALTH_PATH="$2";   shift 2 ;;
    --output)        OUTPUT_DIR="$2";    shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BASE_URL" ]] && { echo "ERROR: --base-url required" >&2; exit 1; }
[[ -z "$RADAMSA_SEED" ]] && { echo "ERROR: --radamsa-seed required (campaign reproducibility)" >&2; exit 1; }
case "$PROTOCOL" in
  h1|h2) ;;
  *) echo "ERROR: --protocol must be h1 or h2 (got: '$PROTOCOL')" >&2; exit 1 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }
command -v radamsa >/dev/null 2>&1 || { echo "ERROR: radamsa not in PATH" >&2; exit 1; }

SCENARIO_ID="destructive-radamsa-${PROTOCOL}"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
GIT_SHA7="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo 'nogit')"
RUN_ID="${SCENARIO_ID}-${TIMESTAMP}-${GIT_SHA7}"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT/results/raw/${SCENARIO_ID}-${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"

if [[ -z "$TARGET_PID" ]]; then
  PORT="$(bench_extract_port_from_url "$BASE_URL")"
  TARGET_PID="$(bench_detect_pid_for_port "$PORT" 2>/dev/null || true)"
fi

read -r RSS_BEFORE VSZ_BEFORE < <(destructive_capture_rss "${TARGET_PID:-0}")

JFR_OUT=""
if [[ -n "${TARGET_PID:-}" ]]; then
  JFR_OUT="$OUTPUT_DIR/destructive-radamsa.jfr"
  if destructive_start_jfr "$TARGET_PID" "$JFR_OUT" destructive-radamsa; then
    echo "JFR recording started: $JFR_OUT"
  else
    JFR_OUT=""
  fi
fi

ATTACKER_PY="$ROOT/runtime/drivers/radamsa-${PROTOCOL}-attacker.py"
ATTACKER_OUT="$OUTPUT_DIR/radamsa-stdout.json"

echo "=== Radamsa $PROTOCOL attack: ${RPS} rps × ${DURATION}s, seed=${RADAMSA_SEED} ==="
set +e
python3 "$ATTACKER_PY" \
    --base-url "$BASE_URL" \
    --rps "$RPS" \
    --attack-duration-seconds "$DURATION" \
    --radamsa-seed "$RADAMSA_SEED" \
    > "$ATTACKER_OUT" 2> "$OUTPUT_DIR/radamsa-stderr.txt"
ATTACKER_RC=$?
set -e

echo "=== Cooldown ${COOLDOWN}s ==="
sleep "$COOLDOWN"
destructive_force_gc "${TARGET_PID:-0}" || true

read -r RSS_AFTER VSZ_AFTER < <(destructive_capture_rss "${TARGET_PID:-0}")
[[ -n "$JFR_OUT" ]] && destructive_stop_jfr "$TARGET_PID" destructive-radamsa || true

echo "=== Liveness probe: GET ${BASE_URL%/}${HEALTH_PATH} ==="
destructive_liveness_probe "$BASE_URL" "$HEALTH_PATH" 200 1000 || true
echo "  status=$DESTR_PROBE_STATUS duration_ms=$DESTR_PROBE_DURATION_MS alive=$DESTR_PROBE_ALIVE"

ITERATIONS_TOTAL=$(jq -r '.iterations_total // 0' "$ATTACKER_OUT")
CRASH_COUNT=$(jq -r '.crash_count // 0' "$ATTACKER_OUT")
HANG_COUNT=$(jq -r '.hang_count // 0' "$ATTACKER_OUT")
FIVE_XX_COUNT=$(jq -r '.five_xx_count // 0' "$ATTACKER_OUT")
RSS_DELTA=$(( RSS_AFTER - RSS_BEFORE ))

DEGRADATION="$(destructive_classify "$CRASH_COUNT" 0 "$HANG_COUNT" \
    "$RSS_DELTA" 5 "${RSS_BEFORE:-1}" "$DESTR_PROBE_ALIVE")"

TRANSPORT_MODE="loopback-${PROTOCOL}"
RESULT_FILE="$OUTPUT_DIR/result.json"
FINDINGS_FILE="$OUTPUT_DIR/destructive-findings.json"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg scenario "$SCENARIO_ID" \
  --arg sha "$GIT_SHA7" \
  --arg transport_mode "$TRANSPORT_MODE" \
  --arg protocol "$PROTOCOL" \
  --argjson duration "$DURATION" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  --argjson errors "$((CRASH_COUNT + HANG_COUNT + FIVE_XX_COUNT))" \
  '{
    schema_version: "1",
    run_id: $run_id,
    timestamp: $ts,
    scenario: $scenario,
    tool: "radamsa",
    env_ref: "",
    transport_mode: $transport_mode,
    target: {
      repo: "exeris-community-app",
      commit_sha: $sha,
      mode: "pure",
      tier: "community",
      protocol: $protocol
    },
    comparison_axis: "standalone",
    execution_class: "exploratory",
    claim_scope: "exploratory",
    final_reason: "ok",
    runner_status: "success",
    reproducibility_status: "complete",
    run_config: {
      duration_seconds: $duration
    },
    metrics: {
      total_requests: $iterations,
      total_errors: $errors
    }
  }' > "$RESULT_FILE"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg scenario "$SCENARIO_ID" \
  --argjson duration_seconds "$DURATION" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  --argjson crash "$CRASH_COUNT" \
  --argjson hang "$HANG_COUNT" \
  --argjson five_xx "$FIVE_XX_COUNT" \
  --argjson rss_before "$RSS_BEFORE" \
  --argjson rss_after "$RSS_AFTER" \
  --argjson rss_delta "$RSS_DELTA" \
  --argjson vsz_before "$VSZ_BEFORE" \
  --argjson vsz_after "$VSZ_AFTER" \
  --arg probe_status "$DESTR_PROBE_STATUS" \
  --argjson probe_duration_ms "$DESTR_PROBE_DURATION_MS" \
  --arg probe_alive "$DESTR_PROBE_ALIVE" \
  --arg degradation "$DEGRADATION" \
  --arg jfr_path "${JFR_OUT:-}" \
  --arg radamsa_seed "$RADAMSA_SEED" \
  --arg scenario "$SCENARIO_ID" \
  '{
    schema_version: "1",
    run_id: $run_id,
    scenario: $scenario,
    campaign_kind: "radamsa",
    duration_seconds: $duration_seconds,
    claim_scope: "exploratory",
    comparison_axis: "standalone",
    findings: {
      iterations_total: $iterations,
      crash_count: $crash,
      oom_count: 0,
      hang_count: $hang,
      unique_crash_signatures: 0,
      mean_time_to_crash_us: null,
      leak_count_delta: 0
    },
    liveness_probe: {
      method: "GET",
      path: "/health",
      status_code: ($probe_status | tonumber? // 0),
      duration_ms: $probe_duration_ms,
      expected_status: 200,
      expected_max_response_ms: 1000,
      asserted_alive: ($probe_alive == "true")
    },
    resource_delta: {
      rss_bytes_before: $rss_before,
      rss_bytes_after: $rss_after,
      rss_bytes_delta: $rss_delta,
      vsz_bytes_before: $vsz_before,
      vsz_bytes_after: $vsz_after,
      vsz_bytes_delta: ($vsz_after - $vsz_before),
      native_heap_committed_bytes_delta: null,
      jfr_recording_path: (if $jfr_path == "" then null else $jfr_path end)
    },
    degradation_class: $degradation,
    tolerance: {
      rss_growth_pct_max: 5,
      max_unexpected_crashes: 0
    },
    seeds: { radamsa_seed: $radamsa_seed },
    publication_mode: "internal-only"
  }' > "$FINDINGS_FILE"

echo ""
echo "=== Summary ==="
echo "  class      : $DEGRADATION"
echo "  iterations : $ITERATIONS_TOTAL"
echo "  crashes    : $CRASH_COUNT"
echo "  hangs      : $HANG_COUNT"
echo "  5xx        : $FIVE_XX_COUNT"
echo "  RSS delta  : $RSS_DELTA bytes"
echo "  liveness   : $DESTR_PROBE_ALIVE ($DESTR_PROBE_STATUS, ${DESTR_PROBE_DURATION_MS}ms)"
echo ""
echo "Artifacts:"
echo "  $RESULT_FILE"
echo "  $FINDINGS_FILE"
