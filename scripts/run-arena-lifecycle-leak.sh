#!/usr/bin/env bash
# run-arena-lifecycle-leak.sh — sustained radamsa load + RSS/NMT/leak-count delta.
#
# Long-running variant of run-destructive-radamsa.sh focused on memory
# accounting rather than crash detection. Default duration: 10 minutes
# (sufficient for slow leaks to materialize on most pool-backed targets).
#
# Usage:
#   ./scripts/run-arena-lifecycle-leak.sh \
#       --base-url http://127.0.0.1:8080 \
#       --target-pid <pid> \
#       --target-repo <repo-id> \
#       --target-mode pure|compat|native|jdbc-bridge|baseline-db \
#       --target-tier community|enterprise \
#       --radamsa-seed <seed> \
#       [--duration 600] [--cooldown 60] \
#       [--memory-stats-endpoint /debug/exeris-memory-stats] \
#       [--output <dir>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tools/bench/lib/destructive.sh
source "$ROOT/tools/bench/lib/destructive.sh"
# shellcheck source=tools/bench/lib/readiness.sh
source "$ROOT/tools/bench/lib/readiness.sh"
# shellcheck source=tools/bench/lib/identity.sh
source "$ROOT/tools/bench/lib/identity.sh"

BASE_URL=""
TARGET_PID=""
TARGET_REPO=""
TARGET_MODE=""
TARGET_TIER=""
TARGET_COMMIT="${BENCH_TARGET_COMMIT:-}"
RADAMSA_SEED=""
DURATION=600
COOLDOWN=60
RPS=500
# See scripts/run-destructive-radamsa.sh for the sizing arithmetic. This scenario needs it most:
# 500 rps x 600 s = 300 000 iterations, which the pre-2026-08-26 single-threaded driver would have
# taken ~24 h to deliver at its achieved 3.4 rps. The scenario was blocked on the driver, not the
# target, and had never run.
WORKERS=256
SOCKET_TIMEOUT=2.0
MUTANT_CHUNK_SIZE=2048
HEALTH_PATH="/health"
MEMSTATS_ENDPOINT=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)              BASE_URL="$2";          shift 2 ;;
    --target-pid)            TARGET_PID="$2";        shift 2 ;;
    --target-repo)           TARGET_REPO="$2";       shift 2 ;;
    --target-mode)           TARGET_MODE="$2";       shift 2 ;;
    --target-tier)           TARGET_TIER="$2";       shift 2 ;;
    --target-commit)         TARGET_COMMIT="$2";     shift 2 ;;
    --harness-sha)           BENCH_HARNESS_SHA="$2"; export BENCH_HARNESS_SHA; shift 2 ;;
    --workers)               WORKERS="$2";           shift 2 ;;
    --socket-timeout)        SOCKET_TIMEOUT="$2";    shift 2 ;;
    --mutant-chunk-size)     MUTANT_CHUNK_SIZE="$2"; shift 2 ;;
    --radamsa-seed)          RADAMSA_SEED="$2";      shift 2 ;;
    --duration)              DURATION="$2";          shift 2 ;;
    --cooldown)              COOLDOWN="$2";          shift 2 ;;
    --rps)                   RPS="$2";               shift 2 ;;
    --health-path)           HEALTH_PATH="$2";       shift 2 ;;
    --memory-stats-endpoint) MEMSTATS_ENDPOINT="$2"; shift 2 ;;
    --output)                OUTPUT_DIR="$2";        shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BASE_URL"     ]] && { echo "ERROR: --base-url required" >&2; exit 1; }
[[ -z "$TARGET_PID"   ]] && { echo "ERROR: --target-pid required for RSS/NMT sampling" >&2; exit 1; }
[[ -z "$RADAMSA_SEED" ]] && { echo "ERROR: --radamsa-seed required" >&2; exit 1; }
# Mandatory target metadata — see run-destructive-radamsa.sh for rationale.
[[ -z "$TARGET_REPO" ]] && { echo "ERROR: --target-repo required (reproducibility metadata)" >&2; exit 1; }
[[ -z "$TARGET_MODE" ]] && { echo "ERROR: --target-mode required (pure|compat|...)" >&2; exit 1; }
[[ -z "$TARGET_TIER" ]] && { echo "ERROR: --target-tier required (community|enterprise)" >&2; exit 1; }
TARGET_COMMIT="$(bench_require_target_sha "$TARGET_COMMIT" --target-commit)" || exit 1
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
RADAMSA_BIN="$(bench_require_radamsa)" || exit 1
export RADAMSA_BIN

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
# Was: git rev-parse ... || echo 'nogit' -- the last of the four copies of that line. It filled
# commit_sha (which sits next to repo: $target_repo, so it reads as the TARGET's revision) with
# the HARNESS's, and fell back to a literal that satisfies the schema while carrying no traceable
# revision. On the perf box, whose copy of this repo is an rsync destination rather than a
# checkout, the fallback fired on every run. Both identities are now mandatory and separate.
HARNESS_SHA="$(bench_harness_sha "$ROOT")" || exit 1
RUN_ID="$(bench_run_id arena-lifecycle-leak "$TIMESTAMP" "$HARNESS_SHA")"
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$ROOT/results/raw/arena-lifecycle-leak-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

probe_memstats() {
  local label="$1"
  if [[ -z "$MEMSTATS_ENDPOINT" ]]; then
    echo "null"
    return
  fi
  local url="${BASE_URL%/}${MEMSTATS_ENDPOINT}"
  local out
  out="$(curl -sS --max-time 5 "$url" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    echo "null"
    return
  fi
  echo "$out" > "$OUTPUT_DIR/memstats-${label}.json"
  jq -r '.leakCount // 0' "$OUTPUT_DIR/memstats-${label}.json" 2>/dev/null || echo "null"
}

echo "=== Pre-attack sampling ==="
# `read` swallows the return code of `destructive_capture_rss` — intentional.
# A failed sample emits the "unobtained" sentinel rather than aborting under
# `set -e`; the sentinel is detected below and turned into JSON null.
read -r RSS_BEFORE VSZ_BEFORE < <(destructive_capture_rss "$TARGET_PID")
NHC_BEFORE="$(destructive_jcmd_native_heap_committed "$TARGET_PID" || echo '')"
LEAKCOUNT_BEFORE="$(probe_memstats before)"
echo "  RSS=${RSS_BEFORE} VSZ=${VSZ_BEFORE} native_heap_committed=${NHC_BEFORE:-N/A} leakCount=${LEAKCOUNT_BEFORE}"

JFR_OUT="$OUTPUT_DIR/arena-lifecycle.jfr"
destructive_start_jfr "$TARGET_PID" "$JFR_OUT" arena-lifecycle || JFR_OUT=""

echo "=== Sustained radamsa H1 load: ${RPS} rps × ${DURATION}s, ${WORKERS} workers ==="
ATTACKER_OUT="$OUTPUT_DIR/radamsa-stdout.json"
set +e
python3 "$ROOT/runtime/drivers/radamsa-h1-attacker.py" \
    --base-url "$BASE_URL" \
    --rps "$RPS" \
    --attack-duration-seconds "$DURATION" \
    --radamsa-seed "$RADAMSA_SEED" \
    --workers "$WORKERS" \
    --socket-timeout-seconds "$SOCKET_TIMEOUT" \
    --mutant-chunk-size "$MUTANT_CHUNK_SIZE" \
    > "$ATTACKER_OUT" 2> "$OUTPUT_DIR/radamsa-stderr.txt"
set -e

echo "=== Cooldown ${COOLDOWN}s ==="
sleep "$COOLDOWN"
destructive_force_gc "$TARGET_PID"

read -r RSS_AFTER VSZ_AFTER < <(destructive_capture_rss "$TARGET_PID")
NHC_AFTER="$(destructive_jcmd_native_heap_committed "$TARGET_PID" || echo '')"
LEAKCOUNT_AFTER="$(probe_memstats after)"
[[ -n "$JFR_OUT" ]] && destructive_stop_jfr "$TARGET_PID" arena-lifecycle || true

destructive_liveness_probe "$BASE_URL" "$HEALTH_PATH" 200 1000 || true

ITERATIONS_TOTAL=$(jq -r '.iterations_total // 0' "$ATTACKER_OUT")
if [[ "$RSS_BEFORE" == "unobtained" || "$RSS_AFTER" == "unobtained" ]]; then
  RSS_OBTAINED=false
  RSS_DELTA="unobtained"
else
  RSS_OBTAINED=true
  RSS_DELTA=$(( RSS_AFTER - RSS_BEFORE ))
fi
NHC_DELTA="null"
if [[ -n "$NHC_BEFORE" && -n "$NHC_AFTER" ]]; then
  NHC_DELTA=$(( NHC_AFTER - NHC_BEFORE ))
fi
LEAK_DELTA=0
if [[ "$LEAKCOUNT_BEFORE" != "null" && "$LEAKCOUNT_AFTER" != "null" ]]; then
  LEAK_DELTA=$(( LEAKCOUNT_AFTER - LEAKCOUNT_BEFORE ))
fi

if (( LEAK_DELTA > 0 )); then
  DEGRADATION="leak-suspected"
elif [[ "$RSS_OBTAINED" == "true" ]]; then
  DEGRADATION="$(destructive_classify 0 0 0 "$RSS_DELTA" 5 \
      "$RSS_BEFORE" "$DESTR_PROBE_ALIVE")"
else
  # RSS unobtained — skip leak-suspected pathway so a missing measurement
  # is not silently rewritten as "stable".
  DEGRADATION="$(destructive_classify 0 0 0 0 5 0 "$DESTR_PROBE_ALIVE")"
fi

RESULT_FILE="$OUTPUT_DIR/result.json"
FINDINGS_FILE="$OUTPUT_DIR/destructive-findings.json"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sha "$TARGET_COMMIT" \
  --arg target_repo "$TARGET_REPO" \
  --arg target_mode "$TARGET_MODE" \
  --arg target_tier "$TARGET_TIER" \
  --argjson duration "$DURATION" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  '{
    schema_version: "1",
    run_id: $run_id,
    timestamp: $ts,
    scenario: "arena-lifecycle-leak",
    tool: "radamsa",
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
    run_config: { duration_seconds: $duration },
    metrics: { total_requests: $iterations, total_errors: 0 }
  }' > "$RESULT_FILE"

# leak delta and NHC delta are emitted with jq's null-safety
jq -n \
  --arg run_id "$RUN_ID" \
  --argjson duration_seconds "$DURATION" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  --arg rss_before "$RSS_BEFORE" \
  --arg rss_after "$RSS_AFTER" \
  --arg rss_delta "$RSS_DELTA" \
  --arg vsz_before "$VSZ_BEFORE" \
  --arg vsz_after "$VSZ_AFTER" \
  --arg nhc_delta "$NHC_DELTA" \
  --argjson leak_delta "$LEAK_DELTA" \
  --arg probe_status "$DESTR_PROBE_STATUS" \
  --argjson probe_duration_ms "$DESTR_PROBE_DURATION_MS" \
  --arg probe_alive "$DESTR_PROBE_ALIVE" \
  --arg degradation "$DEGRADATION" \
  --arg jfr_path "${JFR_OUT:-}" \
  --arg radamsa_seed "$RADAMSA_SEED" \
  '{
    schema_version: "1",
    run_id: $run_id,
    scenario: "arena-lifecycle-leak",
    campaign_kind: "arena-lifecycle",
    duration_seconds: $duration_seconds,
    claim_scope: "exploratory",
    comparison_axis: "standalone",
    findings: {
      iterations_total: $iterations,
      crash_count: 0,
      oom_count: 0,
      hang_count: 0,
      unique_crash_signatures: 0,
      mean_time_to_crash_us: null,
      leak_count_delta: $leak_delta
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
      native_heap_committed_bytes_delta: ($nhc_delta | tonumber? // null),
      jfr_recording_path: (if $jfr_path == "" then null else $jfr_path end)
    },
    degradation_class: $degradation,
    tolerance: {
      rss_growth_pct_max: 5,
      native_heap_committed_growth_pct_max: 10
    },
    seeds: { radamsa_seed: $radamsa_seed },
    publication_mode: "internal-only"
  }' > "$FINDINGS_FILE"

echo ""
echo "=== Summary ==="
echo "  class       : $DEGRADATION"
if [[ "$RSS_OBTAINED" == "true" ]]; then
  echo "  RSS delta   : $RSS_DELTA bytes (before=$RSS_BEFORE after=$RSS_AFTER)"
else
  echo "  RSS delta   : unobtained (ps -p $TARGET_PID returned no data)"
fi
echo "  NHC delta   : $NHC_DELTA bytes"
echo "  leak delta  : $LEAK_DELTA"
echo "  liveness    : $DESTR_PROBE_ALIVE ($DESTR_PROBE_STATUS, ${DESTR_PROBE_DURATION_MS}ms)"
echo ""
echo "Artifacts: $RESULT_FILE, $FINDINGS_FILE"
[[ -n "$JFR_OUT" ]] && echo "JFR (internal-only): $JFR_OUT"
