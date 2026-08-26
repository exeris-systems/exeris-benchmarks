#!/usr/bin/env bash
# run-destructive-slowloris.sh — drive a Slowloris attack and emit conforming artifacts.
#
# Target MUST be launched externally before this script runs.
#
# Usage:
#   ./scripts/run-destructive-slowloris.sh \
#       --base-url http://127.0.0.1:8080 \
#       --target-repo <repo-id> \
#       --target-commit <sha> \
#       --target-mode pure|compat|native|jdbc-bridge|baseline-db \
#       --target-tier community|enterprise \
#       [--target-pid <pid>] \
#       [--connections 1000] \
#       [--header-delay 10] \
#       [--duration 120] \
#       [--cooldown 30] \
#       [--health-path /health] \
#       [--output <dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tools/bench/lib/destructive.sh
source "$ROOT/tools/bench/lib/destructive.sh"
# shellcheck source=tools/bench/lib/identity.sh
source "$ROOT/tools/bench/lib/identity.sh"
# shellcheck source=tools/bench/lib/readiness.sh
source "$ROOT/tools/bench/lib/readiness.sh"

BASE_URL=""
TARGET_PID=""
TARGET_REPO=""
TARGET_COMMIT="${BENCH_TARGET_COMMIT:-}"
TARGET_MODE=""
TARGET_TIER=""
CONNECTIONS=1000
HEADER_DELAY=10
DURATION=120
COOLDOWN=30
HEALTH_PATH="/health"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)        BASE_URL="$2";        shift 2 ;;
    --target-pid)      TARGET_PID="$2";      shift 2 ;;
    --target-repo)     TARGET_REPO="$2";     shift 2 ;;
    --target-commit)   TARGET_COMMIT="$2";   shift 2 ;;
    --harness-sha)     BENCH_HARNESS_SHA="$2"; export BENCH_HARNESS_SHA; shift 2 ;;
    --target-mode)     TARGET_MODE="$2";     shift 2 ;;
    --target-tier)     TARGET_TIER="$2";     shift 2 ;;
    --connections)     CONNECTIONS="$2";     shift 2 ;;
    --header-delay)    HEADER_DELAY="$2";    shift 2 ;;
    --duration)        DURATION="$2";        shift 2 ;;
    --cooldown)        COOLDOWN="$2";        shift 2 ;;
    --health-path)     HEALTH_PATH="$2";     shift 2 ;;
    --output)          OUTPUT_DIR="$2";      shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BASE_URL" ]] && { echo "ERROR: --base-url required" >&2; exit 1; }
# Mandatory target metadata — see run-destructive-radamsa.sh for rationale.
[[ -z "$TARGET_REPO" ]] && { echo "ERROR: --target-repo required (reproducibility metadata)" >&2; exit 1; }
[[ -z "$TARGET_MODE" ]] && { echo "ERROR: --target-mode required (pure|compat|...)" >&2; exit 1; }
[[ -z "$TARGET_TIER" ]] && { echo "ERROR: --target-tier required (community|enterprise)" >&2; exit 1; }
case "$TARGET_MODE" in
  pure|compat|native|jdbc-bridge|baseline-db) ;;
  *) echo "ERROR: --target-mode must be one of pure|compat|native|jdbc-bridge|baseline-db (got: '$TARGET_MODE')" >&2; exit 1 ;;
esac
case "$TARGET_TIER" in
  community|enterprise) ;;
  *) echo "ERROR: --target-tier must be community or enterprise (got: '$TARGET_TIER')" >&2; exit 1 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
# Two repositories, two identities, and neither may be silently absent. commit_sha sits next to
# repo: $target_repo, so it must be the TARGET's commit -- but this line filled it with the
# HARNESS revision, and fell back to the literal "nogit" whenever git failed. It always failed on
# the perf-box, whose copy of this repo is an rsync target rather than a checkout, so every real
# run would have recorded a result that satisfies the schema while carrying no traceable
# revision at all. Same defect as scripts/run-fuzz-campaign.sh had; a shared helper in
# tools/bench/lib/ is the obvious follow-up once these land.
HARNESS_SHA="$(bench_harness_sha "$ROOT")" || exit 1
TARGET_COMMIT="$(bench_require_target_sha "$TARGET_COMMIT" --target-commit)" || exit 1
GIT_SHA7="$HARNESS_SHA"
RUN_ID="destructive-slowloris-h1-${TIMESTAMP}-${GIT_SHA7}"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT/results/raw/destructive-slowloris-h1-${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"

# Auto-detect PID from listening port if not provided — resource sampling
# is best-effort but a known PID makes it meaningful.
if [[ -z "$TARGET_PID" ]]; then
  PORT="$(bench_extract_port_from_url "$BASE_URL")"
  TARGET_PID="$(bench_detect_pid_for_port "$PORT" 2>/dev/null || true)"
fi

# Pre-attack sampling
read -r RSS_BEFORE VSZ_BEFORE < <(destructive_capture_rss "${TARGET_PID:-0}")
echo "pre-attack RSS=${RSS_BEFORE} VSZ=${VSZ_BEFORE} pid=${TARGET_PID:-unknown}"

# Optional JFR
JFR_OUT=""
if [[ -n "${TARGET_PID:-}" ]]; then
  JFR_OUT="$OUTPUT_DIR/destructive-slowloris.jfr"
  if destructive_start_jfr "$TARGET_PID" "$JFR_OUT" destructive-slowloris; then
    echo "JFR recording started: $JFR_OUT"
  else
    JFR_OUT=""
  fi
fi

ATTACKER_OUT="$OUTPUT_DIR/slowloris-stdout.json"
echo "=== Slowloris attack: $CONNECTIONS conns, ${HEADER_DELAY}s delay, ${DURATION}s ==="
set +e
python3 "$ROOT/runtime/drivers/slowloris.py" \
    --base-url "$BASE_URL" \
    --connections "$CONNECTIONS" \
    --header-delay-seconds "$HEADER_DELAY" \
    --attack-duration-seconds "$DURATION" \
    > "$ATTACKER_OUT" 2> "$OUTPUT_DIR/slowloris-stderr.txt"
ATTACKER_RC=$?
set -e

echo "=== Cooldown ${COOLDOWN}s ==="
sleep "$COOLDOWN"
destructive_force_gc "${TARGET_PID:-0}" || true

read -r RSS_AFTER VSZ_AFTER < <(destructive_capture_rss "${TARGET_PID:-0}")
echo "post-attack RSS=${RSS_AFTER} VSZ=${VSZ_AFTER}"

if [[ -n "$JFR_OUT" ]]; then
  destructive_stop_jfr "$TARGET_PID" destructive-slowloris || true
fi

echo "=== Liveness probe: GET ${BASE_URL%/}${HEALTH_PATH} ==="
if destructive_liveness_probe "$BASE_URL" "$HEALTH_PATH" 200 1000; then
  echo "  ALIVE: status=$DESTR_PROBE_STATUS duration_ms=$DESTR_PROBE_DURATION_MS"
else
  echo "  DEAD : status=$DESTR_PROBE_STATUS duration_ms=$DESTR_PROBE_DURATION_MS" >&2
fi

if [[ "$RSS_BEFORE" == "unobtained" || "$RSS_AFTER" == "unobtained" ]]; then
  RSS_OBTAINED=false
  RSS_DELTA="unobtained"
else
  RSS_OBTAINED=true
  RSS_DELTA=$(( RSS_AFTER - RSS_BEFORE ))
fi
ATTACKER_JSON="$(cat "$ATTACKER_OUT")"
ITERATIONS_TOTAL=$(echo "$ATTACKER_JSON" | jq -r '.iterations_total // 0')
CONNECTIONS_DROPPED=$(echo "$ATTACKER_JSON" | jq -r '.connections_dropped // 0')

if [[ "$RSS_OBTAINED" == "true" ]]; then
  DEGRADATION="$(destructive_classify 0 0 "$CONNECTIONS_DROPPED" \
      "$RSS_DELTA" 5 "$RSS_BEFORE" "$DESTR_PROBE_ALIVE")"
else
  # RSS unobtained — skip leak-suspected pathway, don't let the classifier
  # interpret a missing measurement as "stable".
  DEGRADATION="$(destructive_classify 0 0 "$CONNECTIONS_DROPPED" \
      0 5 0 "$DESTR_PROBE_ALIVE")"
fi

RESULT_FILE="$OUTPUT_DIR/result.json"
FINDINGS_FILE="$OUTPUT_DIR/destructive-findings.json"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sha "$TARGET_COMMIT" \
  --arg harness_sha "$HARNESS_SHA" \
  --arg target_repo "$TARGET_REPO" \
  --arg target_mode "$TARGET_MODE" \
  --arg target_tier "$TARGET_TIER" \
  --argjson duration "$DURATION" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  --argjson crash "$CONNECTIONS_DROPPED" \
  '{
    schema_version: "1",
    run_id: $run_id,
    timestamp: $ts,
    scenario: "destructive-slowloris-h1",
    tool: "slowloris",
    env_ref: "",
    transport_mode: "loopback-h1",
    target: {
      repo: $target_repo,
      commit_sha: $sha,
      mode: $target_mode,
      tier: $target_tier,
      protocol: "h1"
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
      total_errors: $crash
    }
  }' > "$RESULT_FILE"

jq -n \
  --arg run_id "$RUN_ID" \
  --argjson duration_seconds "$DURATION" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  --argjson connections_dropped "$CONNECTIONS_DROPPED" \
  --arg rss_before "$RSS_BEFORE" \
  --arg rss_after "$RSS_AFTER" \
  --arg rss_delta "$RSS_DELTA" \
  --arg vsz_before "$VSZ_BEFORE" \
  --arg vsz_after "$VSZ_AFTER" \
  --arg probe_status "$DESTR_PROBE_STATUS" \
  --argjson probe_duration_ms "$DESTR_PROBE_DURATION_MS" \
  --arg probe_alive "$DESTR_PROBE_ALIVE" \
  --arg degradation "$DEGRADATION" \
  --arg jfr_path "${JFR_OUT:-}" \
  '{
    schema_version: "1",
    run_id: $run_id,
    scenario: "destructive-slowloris-h1",
    campaign_kind: "slowloris",
    duration_seconds: $duration_seconds,
    claim_scope: "exploratory",
    comparison_axis: "standalone",
    findings: {
      iterations_total: $iterations,
      crash_count: 0,
      oom_count: 0,
      hang_count: $connections_dropped,
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
      rss_bytes_before: ($rss_before | tonumber? // null),
      rss_bytes_after:  ($rss_after  | tonumber? // null),
      rss_bytes_delta:  ($rss_delta  | tonumber? // null),
      vsz_bytes_before: ($vsz_before | tonumber? // null),
      vsz_bytes_after:  ($vsz_after  | tonumber? // null),
      vsz_bytes_delta:  (
        if ($vsz_before | test("^[0-9]+$")) and ($vsz_after | test("^[0-9]+$"))
        then (($vsz_after | tonumber) - ($vsz_before | tonumber))
        else null
        end
      ),
      native_heap_committed_bytes_delta: null,
      jfr_recording_path: (if $jfr_path == "" then null else $jfr_path end)
    },
    degradation_class: $degradation,
    tolerance: {
      rss_growth_pct_max: 5,
      max_hang_count: 0
    },
    publication_mode: "internal-only"
  }' > "$FINDINGS_FILE"

echo ""
echo "=== Summary ==="
echo "  class      : $DEGRADATION"
echo "  liveness   : $DESTR_PROBE_ALIVE ($DESTR_PROBE_STATUS, ${DESTR_PROBE_DURATION_MS}ms)"
if [[ "$RSS_OBTAINED" == "true" ]]; then
  echo "  RSS delta  : $RSS_DELTA bytes"
else
  echo "  RSS delta  : unobtained (no PID for sampling)"
fi
echo ""
echo "Artifacts:"
echo "  $RESULT_FILE"
echo "  $FINDINGS_FILE"
[[ -n "$JFR_OUT" ]] && echo "  $JFR_OUT (raw JFR — internal-only)"
