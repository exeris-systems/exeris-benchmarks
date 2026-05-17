#!/usr/bin/env bash
# run-fuzz-campaign.sh — drive a Jazzer fuzz campaign and emit conforming artifacts.
#
# Usage:
#   ./scripts/run-fuzz-campaign.sh <scenario-dir> [--duration <jazzer-duration>]
#                                                 [--output <dir>]
#
# Emits to <output>/ (default: results/raw/<scenario-id>-<timestamp>/):
#   - result.json                  — benchmark-result.schema.json conforming
#   - destructive-findings.json    — destructive-findings.schema.json conforming
#   - surefire-output.txt          — raw Surefire stdout (debug aid)
#   - crash-* / hang-*             — if Jazzer found anything (NEVER publish)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCENARIO_DIR="${1:?Usage: run-fuzz-campaign.sh <scenario-dir> [--duration <d>] [--output <dir>]}"
shift

DURATION="${FUZZ_DURATION:-60s}"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --output)   OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$SCENARIO_DIR" ]]; then
  echo "ERROR: scenario dir not found: $SCENARIO_DIR" >&2; exit 1
fi
SCENARIO_JSON="$SCENARIO_DIR/scenario.json"
if [[ ! -f "$SCENARIO_JSON" ]]; then
  echo "ERROR: scenario.json missing in $SCENARIO_DIR" >&2; exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v mvn >/dev/null 2>&1 || { echo "ERROR: mvn required" >&2; exit 1; }

SCENARIO_ID="$(jq -r '.scenario_id' "$SCENARIO_JSON")"
TEST_CLASS_FQN="$(jq -r '.fuzz.test_class' "$SCENARIO_JSON")"
TEST_CLASS_SHORT="${TEST_CLASS_FQN##*.}"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
GIT_SHA7="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo 'nogit')"
RUN_ID="${SCENARIO_ID}-${TIMESTAMP}-${GIT_SHA7}"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT/results/raw/${SCENARIO_ID}-${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"

SUREFIRE_OUT="$OUTPUT_DIR/surefire-output.txt"
JAZZER_WORK="$OUTPUT_DIR/jazzer-work"
mkdir -p "$JAZZER_WORK"

echo "=== Jazzer fuzz campaign ==="
echo "  scenario   : $SCENARIO_ID"
echo "  test class : $TEST_CLASS_FQN"
echo "  duration   : $DURATION"
echo "  output     : $OUTPUT_DIR"
echo ""

START_EPOCH_MS="$(date -u +%s%3N)"

set +e
(
  cd "$ROOT/micro/fuzz"
  mvn -s "$ROOT/.github/maven-settings-gpr.xml" \
      -B test \
      -Dtest="$TEST_CLASS_SHORT" \
      -Djazzer.duration="$DURATION"
) > "$SUREFIRE_OUT" 2>&1
SUREFIRE_RC=$?
set -e

END_EPOCH_MS="$(date -u +%s%3N)"
DURATION_SEC=$(( (END_EPOCH_MS - START_EPOCH_MS) / 1000 ))

# Jazzer emits crash-* / hang-* in CWD. Move them next to the campaign output
# so they're easy to attach as --destructive-artifact paths.
shopt -s nullglob
for f in "$ROOT/micro/fuzz"/crash-* "$ROOT/micro/fuzz"/hang-*; do
  mv "$f" "$JAZZER_WORK/"
done
shopt -u nullglob

# All numeric counters below are fed to jq --argjson, which aborts on an empty
# string. Apply ${VAR:-0} + regex sanitization so a missing/unreadable
# $SUREFIRE_OUT never causes the whole run to crash at the reporting step.
CRASH_COUNT=$(find "$JAZZER_WORK" -maxdepth 1 -name 'crash-*' 2>/dev/null | wc -l | tr -d ' ')
HANG_COUNT=$(find "$JAZZER_WORK" -maxdepth 1 -name 'hang-*' 2>/dev/null | wc -l | tr -d ' ')
OOM_COUNT=$(grep -c 'OutOfMemoryError' "$SUREFIRE_OUT" 2>/dev/null || echo 0)
[[ "$CRASH_COUNT" =~ ^[0-9]+$ ]] || CRASH_COUNT=0
[[ "$HANG_COUNT"  =~ ^[0-9]+$ ]] || HANG_COUNT=0
[[ "$OOM_COUNT"   =~ ^[0-9]+$ ]] || OOM_COUNT=0

if (( CRASH_COUNT > 0 )); then
  DEGRADATION="crash"
elif (( OOM_COUNT > 0 )); then
  DEGRADATION="oom"
elif (( HANG_COUNT > 0 )); then
  DEGRADATION="graceful-shed"
else
  DEGRADATION="stable"
fi

# Iterations are not reliably extractable from Surefire; Jazzer's libFuzzer
# output goes to a separate log stream. Best-effort grep — empty/non-numeric
# tail must become a literal 0 or jq --argjson aborts.
ITERATIONS_TOTAL=$(grep -oE '#[0-9]+\b' "$SUREFIRE_OUT" 2>/dev/null \
  | tr -d '#' | sort -n | tail -1 || true)
[[ "$ITERATIONS_TOTAL" =~ ^[0-9]+$ ]] || ITERATIONS_TOTAL=0

JAZZER_VERSION="$(cd "$ROOT/micro/fuzz" && mvn -s "$ROOT/.github/maven-settings-gpr.xml" \
  -B help:evaluate -Dexpression=jazzer.version -q -DforceStdout 2>/dev/null || echo "unknown")"
KERNEL_VERSION="$(cd "$ROOT/micro/fuzz" && mvn -s "$ROOT/.github/maven-settings-gpr.xml" \
  -B help:evaluate -Dexpression=exeris.kernel.version -q -DforceStdout 2>/dev/null || echo "unknown")"

SEED_CORPUS_DIR="$ROOT/micro/fuzz/src/test/resources/eu/exeris/benchmarks/micro/fuzz/$TEST_CLASS_SHORT"
SEED_SHA="unknown"
if [[ -d "$SEED_CORPUS_DIR" ]]; then
  SEED_SHA="$(find "$SEED_CORPUS_DIR" -type f -print0 | sort -z \
    | xargs -0 cat | sha256sum | awk '{print $1}')"
fi

RESULT_FILE="$OUTPUT_DIR/result.json"
FINDINGS_FILE="$OUTPUT_DIR/destructive-findings.json"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg scenario "$SCENARIO_ID" \
  --arg sha "$GIT_SHA7" \
  --arg duration "$DURATION" \
  --arg surefire_rc "$SUREFIRE_RC" \
  --argjson crash "$CRASH_COUNT" \
  --argjson hang "$HANG_COUNT" \
  --argjson oom "$OOM_COUNT" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  '{
    schema_version: "1",
    run_id: $run_id,
    timestamp: $ts,
    scenario: $scenario,
    tool: "jazzer",
    env_ref: "",
    target: {
      repo: "exeris-kernel",
      commit_sha: $sha,
      mode: "pure",
      tier: "community",
      protocol: "h1"
    },
    comparison_axis: "standalone",
    execution_class: "exploratory",
    claim_scope: "exploratory",
    final_reason: (if ($surefire_rc | tonumber) == 0 then "ok" else "benchmark_exit_nonzero" end),
    runner_status: (if ($surefire_rc | tonumber) == 0 and $crash == 0 then "success" else "failed" end),
    reproducibility_status: "complete",
    run_config: {
      duration_seconds: ($duration | rtrimstr("s") | tonumber? // 0)
    },
    metrics: {
      total_requests: $iterations,
      total_errors: ($crash + $oom + $hang)
    }
  }' > "$RESULT_FILE"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg scenario "$SCENARIO_ID" \
  --argjson duration_seconds "$DURATION_SEC" \
  --argjson iterations "$ITERATIONS_TOTAL" \
  --argjson crash "$CRASH_COUNT" \
  --argjson oom "$OOM_COUNT" \
  --argjson hang "$HANG_COUNT" \
  --arg degradation "$DEGRADATION" \
  --arg jazzer_v "$JAZZER_VERSION" \
  --arg kernel_v "$KERNEL_VERSION" \
  --arg seed_sha "$SEED_SHA" \
  '{
    schema_version: "1",
    run_id: $run_id,
    scenario: $scenario,
    campaign_kind: "jazzer-parser",
    duration_seconds: $duration_seconds,
    claim_scope: "exploratory",
    comparison_axis: "standalone",
    findings: {
      iterations_total: $iterations,
      crash_count: $crash,
      oom_count: $oom,
      hang_count: $hang,
      unique_crash_signatures: $crash,
      mean_time_to_crash_us: null,
      leak_count_delta: 0
    },
    degradation_class: $degradation,
    tool_versions: {
      jazzer: $jazzer_v,
      "exeris-kernel": $kernel_v
    },
    seeds: {
      jazzer_seed_corpus_sha256: $seed_sha
    },
    tolerance: {
      max_unexpected_crashes: 0,
      max_hang_count: 0
    },
    publication_mode: "internal-only"
  }' > "$FINDINGS_FILE"

echo ""
echo "=== Summary ==="
echo "  iterations : $ITERATIONS_TOTAL"
echo "  crashes    : $CRASH_COUNT"
echo "  hangs      : $HANG_COUNT"
echo "  OOM        : $OOM_COUNT"
echo "  class      : $DEGRADATION"
echo ""
echo "Artifacts:"
echo "  $RESULT_FILE"
echo "  $FINDINGS_FILE"
echo "  $SUREFIRE_OUT"
if (( CRASH_COUNT > 0 || HANG_COUNT > 0 )); then
  echo ""
  echo "FINDINGS in $JAZZER_WORK — pass via --destructive-artifact to publish-report.sh,"
  echo "and ONLY in --publication-mode internal-only."
fi

exit "$SUREFIRE_RC"
