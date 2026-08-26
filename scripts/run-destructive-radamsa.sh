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
#       --target-repo <repo-id> \
#       --target-commit <sha> \
#       --target-mode pure|compat|native|jdbc-bridge|baseline-db \
#       --target-tier community|enterprise \
#       [--target-pid <pid>] \
#       [--rps 500] [--duration 120] [--cooldown 30] \
#       [--health-path /health] [--output <dir>]
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
PROTOCOL=""
RADAMSA_SEED=""
TARGET_PID=""
TARGET_REPO=""
TARGET_COMMIT="${BENCH_TARGET_COMMIT:-}"
TARGET_MODE=""
TARGET_TIER=""
RPS=500
DURATION=120
COOLDOWN=30
HEALTH_PATH="/health"
OUTPUT_DIR=""
# Concurrency. The first campaign was single-threaded and every timeout blocked it for the full
# socket deadline: 60 timeouts x 2.0 s consumed the entire 120 s window, so 500 rps was requested
# and 3.4 achieved. Mutant generation was NOT the cause -- radamsa costs 3.1 ms per spawn, 1.1 %
# of that window. Sizing: 500 rps x 14.4 % incomplete mutants x 2.0 s = 144 worker-seconds per
# wall second, so 256 covers the declared profile with headroom. Undersizing is not silent --
# the attacker reports backlog_skips and achieved_rps.
WORKERS=256
SOCKET_TIMEOUT=2.0
# Mutants per radamsa invocation. Batching costs 1.13 ms/mutant against 3.1 ms per spawn; at
# 500 rps the spawn path alone would need 1.55 CPU-seconds per wall second. Part of the
# reproducibility key: (seed, chunk size, index) determines the bytes.
MUTANT_CHUNK_SIZE=2048

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)      BASE_URL="$2";      shift 2 ;;
    --protocol)      PROTOCOL="$2";      shift 2 ;;
    --radamsa-seed)  RADAMSA_SEED="$2";  shift 2 ;;
    --target-pid)    TARGET_PID="$2";    shift 2 ;;
    --target-repo)   TARGET_REPO="$2";   shift 2 ;;
    --target-commit) TARGET_COMMIT="$2"; shift 2 ;;
    --harness-sha)   BENCH_HARNESS_SHA="$2"; export BENCH_HARNESS_SHA; shift 2 ;;
    --target-mode)   TARGET_MODE="$2";   shift 2 ;;
    --target-tier)   TARGET_TIER="$2";   shift 2 ;;
    --rps)           RPS="$2";           shift 2 ;;
    --workers)       WORKERS="$2";       shift 2 ;;
    --socket-timeout) SOCKET_TIMEOUT="$2"; shift 2 ;;
    --mutant-chunk-size) MUTANT_CHUNK_SIZE="$2"; shift 2 ;;
    --duration)      DURATION="$2";      shift 2 ;;
    --cooldown)      COOLDOWN="$2";      shift 2 ;;
    --health-path)   HEALTH_PATH="$2";   shift 2 ;;
    --output)        OUTPUT_DIR="$2";    shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BASE_URL" ]] && { echo "ERROR: --base-url required" >&2; exit 1; }
[[ -z "$RADAMSA_SEED" ]] && { echo "ERROR: --radamsa-seed required (campaign reproducibility)" >&2; exit 1; }
# Target metadata is mandatory: the harness can't introspect which app is behind
# $BASE_URL, and silently labeling the wrong repo/mode/tier in result.json
# breaks reproducibility metadata and cross-stack comparisons.
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
case "$PROTOCOL" in
  h1|h2) ;;
  *) echo "ERROR: --protocol must be h1 or h2 (got: '$PROTOCOL')" >&2; exit 1 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }
RADAMSA_BIN="$(bench_require_radamsa)" || exit 1
export RADAMSA_BIN

SCENARIO_ID="destructive-radamsa-${PROTOCOL}"
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
RUN_ID="${SCENARIO_ID}-${TIMESTAMP}-${GIT_SHA7}"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT/results/raw/${SCENARIO_ID}-${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"

if [[ -z "$TARGET_PID" ]]; then
  PORT="$(bench_extract_port_from_url "$BASE_URL")"
  TARGET_PID="$(bench_detect_pid_for_port "$PORT" 2>/dev/null || true)"
fi

# destructive_capture_rss emits "unobtained unobtained" when no PID is known;
# downstream JSON emission turns that into null so a no-signal run is not
# misread as a stable-with-zero-RSS run.
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

echo "=== Radamsa $PROTOCOL attack: ${RPS} rps × ${DURATION}s, ${WORKERS} workers, seed=${RADAMSA_SEED} ==="
set +e
python3 "$ATTACKER_PY" \
    --base-url "$BASE_URL" \
    --rps "$RPS" \
    --attack-duration-seconds "$DURATION" \
    --radamsa-seed "$RADAMSA_SEED" \
    --workers "$WORKERS" \
    --socket-timeout-seconds "$SOCKET_TIMEOUT" \
    --mutant-chunk-size "$MUTANT_CHUNK_SIZE" \
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

# The attacker writes its summary as JSON on stdout. If it died -- a rejected radamsa seed,
# a missing binary, an unreachable target -- that file is empty, every counter below becomes
# an empty string, and jq --argjson aborts with "invalid JSON text" after leaving two 0-byte
# artifacts behind. Measured on the first real run of this scenario. Check before parsing, and
# emit nothing rather than something unreadable.
if [[ ! -s "$ATTACKER_OUT" ]] || ! jq -e . "$ATTACKER_OUT" >/dev/null 2>&1; then
  echo "" >&2
  echo "ERROR: the attacker produced no usable JSON summary ($ATTACKER_OUT)." >&2
  echo "       The campaign did not complete; NOT writing result.json or the findings sidecar." >&2
  echo "       Attacker stderr:" >&2
  tail -n 20 "$OUTPUT_DIR/radamsa-stderr.txt" >&2 2>/dev/null || true
  rm -f "$OUTPUT_DIR/result.json" "$OUTPUT_DIR/destructive-findings.json"
  exit 1
fi
ITERATIONS_TOTAL=$(jq -r '.iterations_total // 0' "$ATTACKER_OUT")
CRASH_COUNT=$(jq -r '.crash_count // 0' "$ATTACKER_OUT")
HANG_COUNT=$(jq -r '.hang_count // 0' "$ATTACKER_OUT")
FIVE_XX_COUNT=$(jq -r '.five_xx_count // 0' "$ATTACKER_OUT")
# Rejections and plain responses are EXPECTED outcomes, not findings: closing the connection on
# an unparseable request is specified behaviour. They are not in the findings schema (which is
# additionalProperties:false), so they ride in `notes` -- without them a reader cannot tell a
# campaign the target absorbed from one it barely saw.
REJECTED_COUNT=$(jq -r '.rejected_count // 0' "$ATTACKER_OUT")
RESPONSE_COUNT=$(jq -r '.response_count // 0' "$ATTACKER_OUT")
# A read timeout on a mutant that never terminated its request is the target correctly waiting
# for the rest of it -- the ATTACKER gave up first. Measured 2026-08-26: 60 of 410 mutants (14.6 %)
# timed out at a 2 s deadline and every one was charged to hang_count, while the target answered
# /health in 8 ms; independently, 14.4 % of radamsa's mutants from this seed carry no terminated
# request. hang_count now counts only timeouts on COMPLETE requests, where the target owed an
# answer. `incomplete-wait` is disclosed, not hidden -- it is an attack-shape fact worth reading.
INCOMPLETE_WAIT_COUNT=$(jq -r '.incomplete_wait_count // 0' "$ATTACKER_OUT")
# Achieved rate, worker count and pacing pressure: the campaign's declared rps is a REQUEST, and a
# run that could not reach it must say so rather than let the scenario's profile stand in for what
# happened. Concurrency is part of the stimulus, so it travels with the result.
ACHIEVED_RPS=$(jq -r '(.achieved_rps // 0) | . * 10 | round / 10' "$ATTACKER_OUT")
WORKERS_USED=$(jq -r '.workers // 0' "$ATTACKER_OUT")
BACKLOG_SKIPS=$(jq -r '.backlog_skips // 0' "$ATTACKER_OUT")
GENERATOR_FAILURES=$(jq -r '.generator_failures // 0' "$ATTACKER_OUT")
MUTANT_STREAM=$(jq -r '.mutant_stream // "unknown"' "$ATTACKER_OUT")
CAMPAIGN_NOTES="expected outcomes (not findings): ${REJECTED_COUNT} connection-close rejections, ${RESPONSE_COUNT} well-formed responses, ${INCOMPLETE_WAIT_COUNT} incomplete-wait timeouts (mutant never terminated its request; the target was correctly waiting, the attacker gave up at the socket deadline -- whether the target EVER times out an incomplete request is destructive-slowloris-h1's question, not this one). crash_count counts CONNECT failures only (listener gone); a close after connect is the server correctly refusing malformed input. hang_count counts timeouts on COMPLETE requests only. rate: ${ACHIEVED_RPS}/${RPS} rps achieved with ${WORKERS_USED} workers, ${BACKLOG_SKIPS} pacing skips, ${GENERATOR_FAILURES} generator failures. mutant_stream=${MUTANT_STREAM} (streams are not byte-comparable across ids)."

if [[ "$RSS_BEFORE" == "unobtained" || "$RSS_AFTER" == "unobtained" ]]; then
  RSS_OBTAINED=false
  RSS_DELTA="unobtained"
else
  RSS_OBTAINED=true
  RSS_DELTA=$(( RSS_AFTER - RSS_BEFORE ))
fi

if [[ "$RSS_OBTAINED" == "true" ]]; then
  DEGRADATION="$(destructive_classify "$CRASH_COUNT" 0 "$HANG_COUNT" \
      "$RSS_DELTA" 5 "$RSS_BEFORE" "$DESTR_PROBE_ALIVE")"
else
  # RSS path is the only "leak-suspected" signal — skip it when unobtained,
  # so the classifier doesn't conclude "stable" from a missing measurement.
  DEGRADATION="$(destructive_classify "$CRASH_COUNT" 0 "$HANG_COUNT" \
      0 5 0 "$DESTR_PROBE_ALIVE")"
fi

TRANSPORT_MODE="loopback-${PROTOCOL}"
RESULT_FILE="$OUTPUT_DIR/result.json"
FINDINGS_FILE="$OUTPUT_DIR/destructive-findings.json"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg scenario "$SCENARIO_ID" \
  --arg sha "$TARGET_COMMIT" \
  --arg transport_mode "$TRANSPORT_MODE" \
  --arg protocol "$PROTOCOL" \
  --arg target_repo "$TARGET_REPO" \
  --arg target_mode "$TARGET_MODE" \
  --arg target_tier "$TARGET_TIER" \
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
      repo: $target_repo,
      commit_sha: $sha,
      mode: $target_mode,
      tier: $target_tier,
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
  --arg rss_before "$RSS_BEFORE" \
  --arg rss_after "$RSS_AFTER" \
  --arg rss_delta "$RSS_DELTA" \
  --arg vsz_before "$VSZ_BEFORE" \
  --arg vsz_after "$VSZ_AFTER" \
  --arg probe_status "$DESTR_PROBE_STATUS" \
  --argjson probe_duration_ms "$DESTR_PROBE_DURATION_MS" \
  --arg probe_alive "$DESTR_PROBE_ALIVE" \
  --arg degradation "$DEGRADATION" \
  --arg notes "$CAMPAIGN_NOTES" \
  --arg jfr_path "${JFR_OUT:-}" \
  --arg radamsa_seed "$RADAMSA_SEED" \
  --argjson incomplete_wait "$INCOMPLETE_WAIT_COUNT" \
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
      incomplete_wait_count: $incomplete_wait,
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
    notes: $notes,
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
if [[ "$RSS_OBTAINED" == "true" ]]; then
  echo "  RSS delta  : $RSS_DELTA bytes"
else
  echo "  RSS delta  : unobtained (no PID for sampling)"
fi
echo "  liveness   : $DESTR_PROBE_ALIVE ($DESTR_PROBE_STATUS, ${DESTR_PROBE_DURATION_MS}ms)"
echo ""
echo "Artifacts:"
echo "  $RESULT_FILE"
echo "  $FINDINGS_FILE"
