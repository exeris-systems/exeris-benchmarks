#!/usr/bin/env bash
set -euo pipefail

# aggregate-comparative-results.sh — Aggregate multiple comparative runs into a campaign summary.
#
# Usage:
#   scripts/aggregate-comparative-results.sh \
#     --input-pattern "results/raw/entity-read-by-id/*-comparative-*" \
#     --scenario-id   entity-read-by-id                                \
#     --output-dir    results/reports/entity-read-by-id/campaign-YYYYMMDD \
#     [--generate-report]
#
# Output files:
#   campaign-summary.json
#   campaign-status.csv
#   campaign-report.md  (with --generate-report)
#
# Minimum 2 runs required; exits 1 if fewer than 2 comparative-result.json found.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INPUT_PATTERN=""
SCENARIO_ID=""
OUTPUT_DIR=""
GENERATE_REPORT=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-pattern)  INPUT_PATTERN="$2";  shift 2 ;;
    --scenario-id)    SCENARIO_ID="$2";    shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
    --generate-report) GENERATE_REPORT=1;  shift 1 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$INPUT_PATTERN" || -z "$SCENARIO_ID" || -z "$OUTPUT_DIR" ]]; then
  echo "ERROR: --input-pattern, --scenario-id, and --output-dir are all required." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for cmd in jq awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

aggregate_constrained_contract_id() {
  local contract_id="${1:-}"
  [[ -n "$contract_id" && ( "$contract_id" == fixed_contract_runtime_h1_constrained* || "$contract_id" == *_constrained_* ) ]]
}

aggregate_constrained_execution_profile_id() {
  local execution_profile_id="${1:-}"
  [[ -n "$execution_profile_id" && "$execution_profile_id" == runtime-constrained-* ]]
}

aggregate_constrained_track_id() {
  local track_id="${1:-}"
  [[ -n "$track_id" && "$track_id" == track-c* ]]
}

aggregate_constrained_path() {
  local path_value="${1:-}"
  [[ -n "$path_value" && ( "$path_value" == */results/constrained/* || "$path_value" == results/constrained/* ) ]]
}

aggregate_result_constrained_reason() {
  local file="$1"
  local contract_id=""
  local track_id=""
  local execution_profile_id=""
  local top_level_track_id=""

  contract_id="$(jq -r '.contract_id // empty' "$file" 2>/dev/null || true)"
  if aggregate_constrained_contract_id "$contract_id"; then
    echo "contract_id=${contract_id} file=${file}"
    return 0
  fi

  track_id="$(jq -r '.run_config.track_id // empty' "$file" 2>/dev/null || true)"
  if aggregate_constrained_track_id "$track_id"; then
    echo "run_config.track_id=${track_id} file=${file}"
    return 0
  fi

  top_level_track_id="$(jq -r '.track_id // empty' "$file" 2>/dev/null || true)"
  if aggregate_constrained_track_id "$top_level_track_id"; then
    echo "track_id=${top_level_track_id} file=${file}"
    return 0
  fi

  execution_profile_id="$(jq -r '.run_config.execution_profile_id // empty' "$file" 2>/dev/null || true)"
  if aggregate_constrained_execution_profile_id "$execution_profile_id"; then
    echo "run_config.execution_profile_id=${execution_profile_id} file=${file}"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Discover comparative-result.json files
# ---------------------------------------------------------------------------
# Expand glob relative to REPO_ROOT if not absolute
if [[ "$INPUT_PATTERN" != /* ]]; then
  INPUT_PATTERN="${REPO_ROOT}/${INPUT_PATTERN}"
fi

if aggregate_constrained_path "$INPUT_PATTERN"; then
  echo "ERROR: constrained execution profiles are exploratory only and must not flow through aggregate-comparative-results.sh (input_pattern=${INPUT_PATTERN})" >&2
  exit 1
fi

declare -a RESULT_FILES=()
# Use eval-safe glob expansion via find + pattern matching
while IFS= read -r -d '' f; do
  RESULT_FILES+=("$f")
done < <(find ${INPUT_PATTERN} -maxdepth 1 -name "comparative-result.json" -print0 2>/dev/null || true)

# Fallback: try glob directly
if [[ ${#RESULT_FILES[@]} -eq 0 ]]; then
  for dir in ${INPUT_PATTERN}; do
    f="${dir}/comparative-result.json"
    [[ -f "$f" ]] && RESULT_FILES+=("$f")
  done
fi

TOTAL_RUNS="${#RESULT_FILES[@]}"

for f in "${RESULT_FILES[@]}"; do
  if aggregate_constrained_path "$f"; then
    echo "ERROR: constrained execution profiles are exploratory only and must not flow through aggregate-comparative-results.sh (result_path=${f})" >&2
    exit 1
  fi
done

if [[ "$TOTAL_RUNS" -lt 2 ]]; then
  echo "ERROR: Minimum 2 comparative-result.json files required; found ${TOTAL_RUNS} matching '${INPUT_PATTERN}'." >&2
  exit 1
fi

echo -e "${GREEN}Found ${TOTAL_RUNS} comparative result files.${NC}"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Extract per-run data into a temp JSONL scratch file
# ---------------------------------------------------------------------------
SCRATCH="$(mktemp /tmp/comparative-campaign-XXXXXX.jsonl)"
cleanup() { rm -f "$SCRATCH"; }
trap cleanup EXIT

for f in "${RESULT_FILES[@]}"; do
  if ! jq empty "$f" 2>/dev/null; then
    echo -e "${YELLOW}WARN${NC}: Skipping invalid JSON: $f" >&2
    continue
  fi
  if constrained_reason="$(aggregate_result_constrained_reason "$f")"; then
    echo "ERROR: constrained execution profiles are exploratory only and must not flow through aggregate-comparative-results.sh (${constrained_reason})" >&2
    exit 1
  fi
  # Emit one compact JSON object per line
  jq -c '{
    run_file:         input_filename,
    comparative_id:   .comparative_id,
    timestamp_utc:    .timestamp_utc,
    scenario_id:      .scenario_id,
    contract_id:      .contract_id,
    workload_profile_key: (.workload_profile_key // .pair_fingerprint.workload_profile_key // ""),
    pair_fingerprint: (.pair_fingerprint // {}),
    measurement_seconds: .measurement_seconds,
    warmup_seconds:   .warmup_seconds,
    target_a: (.targets[0] | {
      target_id:      .target_id,
      tier:           .tier,
      protocol_mode:  .protocol_mode,
      transport_mode: .transport_mode,
      throughput_rps: .metrics.throughput_rps,
      latency_p95_us: .metrics.latency_p95_us,
      latency_p99_us: .metrics.latency_p99_us,
      error_rate_pct: .metrics.error_rate_pct
    }),
    target_b: (.targets[1] | {
      target_id:      .target_id,
      tier:           .tier,
      protocol_mode:  .protocol_mode,
      transport_mode: .transport_mode,
      throughput_rps: .metrics.throughput_rps,
      latency_p95_us: .metrics.latency_p95_us,
      latency_p99_us: .metrics.latency_p99_us,
      error_rate_pct: .metrics.error_rate_pct
    }),
    fairness_composite: .fairness_index.composite_score,
    fairness_interp:    .fairness_index.interpretation,
    gate_status:        .gate_status
  }' "$f" >> "$SCRATCH"
done

VALID_RUNS="$(wc -l < "$SCRATCH" | tr -d ' ')"

if [[ "$VALID_RUNS" -lt 2 ]]; then
  echo "ERROR: After JSON validation, only ${VALID_RUNS} valid result(s) remain (minimum 2 required)." >&2
  exit 1
fi

echo "  Valid runs processed: ${VALID_RUNS}"

# Fail-closed: all comparative inputs in one aggregation must share a single
# canonical pair fingerprint for scenario/contract/targets/tier/protocol/transport/workload.
FINGERPRINTS_JSON="$(jq -s '
  map({
    scenario_id: .scenario_id,
    contract_id: .contract_id,
    canonical_unordered_targets: [(.target_a.target_id // ""), (.target_b.target_id // "")] | sort,
    tier: (
      [(.target_a.tier // ""), (.target_b.tier // "")] | unique |
      if length == 1 then .[0] else "__mixed__" end
    ),
    protocol_mode: (
      [(.target_a.protocol_mode // ""), (.target_b.protocol_mode // "")] | unique |
      if length == 1 then .[0] else "__mixed__" end
    ),
    transport_mode: (
      [(.target_a.transport_mode // ""), (.target_b.transport_mode // "")] | unique |
      if length == 1 then .[0] else "__mixed__" end
    ),
    workload_profile_key: (.workload_profile_key // "")
  })
' "$SCRATCH")"

if ! jq -e '
  all(.[];
    (.scenario_id | type == "string" and length > 0) and
    (.contract_id | type == "string" and length > 0) and
    (.canonical_unordered_targets | type == "array" and length == 2 and all(.[]; type == "string" and length > 0)) and
    (.tier | type == "string" and length > 0 and . != "__mixed__") and
    (.protocol_mode | type == "string" and length > 0 and . != "__mixed__") and
    (.transport_mode | type == "string" and length > 0 and . != "__mixed__") and
    (.workload_profile_key | type == "string" and length > 0)
  )
' <<<"$FINGERPRINTS_JSON" >/dev/null 2>&1; then
  echo "ERROR: Pair fingerprint validation failed: required fingerprint fields are missing/empty or mixed in inputs." >&2
  exit 1
fi

UNIQUE_FINGERPRINT_COUNT="$(jq -c 'unique | length' <<<"$FINGERPRINTS_JSON")"
if [[ "$UNIQUE_FINGERPRINT_COUNT" != "1" ]]; then
  echo "ERROR: Mixed pair fingerprints detected in aggregation input (unique_fingerprints=${UNIQUE_FINGERPRINT_COUNT})." >&2
  jq -c 'unique' <<<"$FINGERPRINTS_JSON" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Compute statistics using jq + awk
# ---------------------------------------------------------------------------

# Helper: compute min, max, mean, median, CV for an array of numbers
# median = sort + take midpoint (integer index)
stats_for_jq_array() {
  local array_json="$1"
  awk -v arr="$array_json" 'BEGIN {
    # Parse JSON array manually for portability
    gsub(/[\[\]]/, "", arr)
    n = split(arr, a, /,[ \t]*/)
    if (n == 0) {
      print "{\"min\":0,\"max\":0,\"mean\":0,\"median\":0,\"cv\":0,\"count\":0}"
      exit
    }
    # Sort (bubble sort for small n)
    for (i = 1; i <= n; i++) { a[i] = a[i] + 0 }
    for (i = 1; i < n; i++) for (j = i+1; j <= n; j++) if (a[j] < a[i]) { t=a[i]; a[i]=a[j]; a[j]=t }
    mn = a[1]; mx = a[n]
    sum = 0; for (i = 1; i <= n; i++) sum += a[i]
    mean = sum / n
    # Median
    if (n % 2 == 1) median = a[int(n/2)+1]
    else median = (a[n/2] + a[n/2+1]) / 2
    # Standard deviation
    sv = 0; for (i = 1; i <= n; i++) sv += (a[i] - mean)^2
    stdev = (n > 1) ? sqrt(sv / (n-1)) : 0
    cv = (mean > 0) ? stdev / mean : 0
    printf "{\"min\":%.4f,\"max\":%.4f,\"mean\":%.4f,\"median\":%.4f,\"cv\":%.4f,\"count\":%d}", mn, mx, mean, median, cv, n
  }'
}

# Collect metric arrays from scratch file using jq
rps_a_arr="$(jq -s '[.[].target_a.throughput_rps | numbers]' "$SCRATCH")"
p95_a_arr="$(jq -s '[.[].target_a.latency_p95_us | numbers]' "$SCRATCH")"
p99_a_arr="$(jq -s '[.[].target_a.latency_p99_us | numbers]' "$SCRATCH")"
err_a_arr="$(jq -s '[.[].target_a.error_rate_pct | numbers]' "$SCRATCH")"

rps_b_arr="$(jq -s '[.[].target_b.throughput_rps | numbers]' "$SCRATCH")"
p95_b_arr="$(jq -s '[.[].target_b.latency_p95_us | numbers]' "$SCRATCH")"
p99_b_arr="$(jq -s '[.[].target_b.latency_p99_us | numbers]' "$SCRATCH")"
err_b_arr="$(jq -s '[.[].target_b.error_rate_pct | numbers]' "$SCRATCH")"

fairness_arr="$(jq -s '[.[].fairness_composite | numbers]' "$SCRATCH")"

# Compute stats
stats_rps_a="$(stats_for_jq_array "$rps_a_arr")"
stats_p95_a="$(stats_for_jq_array "$p95_a_arr")"
stats_p99_a="$(stats_for_jq_array "$p99_a_arr")"
stats_err_a="$(stats_for_jq_array "$err_a_arr")"

stats_rps_b="$(stats_for_jq_array "$rps_b_arr")"
stats_p95_b="$(stats_for_jq_array "$p95_b_arr")"
stats_p99_b="$(stats_for_jq_array "$p99_b_arr")"
stats_err_b="$(stats_for_jq_array "$err_b_arr")"

stats_fairness="$(stats_for_jq_array "$fairness_arr")"

# Compute gate pass rates per gate
compute_gate_pass_rate() {
  local gate="$1"
  jq -rs --arg gate "$gate" '
    [(.[].gate_status[$gate].pass_fail == "PASS") | if . then 1 else 0 end] |
    add as $passes |
    length as $total |
    if $total == 0 then 0 else ($passes / $total) end
  ' "$SCRATCH"
}

gate_pass_rate_track_isolation="$(compute_gate_pass_rate "track_isolation")"
gate_pass_rate_eligibility="$(compute_gate_pass_rate "eligibility")"
gate_pass_rate_equivalence="$(compute_gate_pass_rate "equivalence")"
gate_pass_rate_ab_ba="$(compute_gate_pass_rate "ab_ba")"
gate_pass_rate_drift="$(compute_gate_pass_rate "drift")"
gate_pass_rate_metadata="$(compute_gate_pass_rate "metadata")"
gate_pass_rate_pin_verification="$(compute_gate_pass_rate "pin_verification")"
gate_pass_rate_schema="$(compute_gate_pass_rate "schema")"
gate_pass_rate_quarantine="$(compute_gate_pass_rate "quarantine")"
gate_pass_rate_reporting_guard="$(compute_gate_pass_rate "reporting_guard")"

# Derive target IDs from first run
TARGET_A_ID="$(jq -r '.target_a.target_id' "$SCRATCH" | head -1)"
TARGET_B_ID="$(jq -r '.target_b.target_id' "$SCRATCH" | head -1)"
CAMPAIGN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Derive axis labels from the first run rather than hardcoding them. The pair-fingerprint
# validation above fails closed unless every run in this aggregation shares one
# protocol_mode / transport_mode / tier (G3 isolation), so the first run's values are
# authoritative for the whole campaign and can never be an h1/h2 blend. benchmark_family
# is left constant: this aggregator only ever consumes wrk comparative runs.
CAMPAIGN_PROTOCOL_MODE="$(jq -r '.target_a.protocol_mode' "$SCRATCH" | head -1)"
CAMPAIGN_TRANSPORT_MODE="$(jq -r '.target_a.transport_mode' "$SCRATCH" | head -1)"
CAMPAIGN_TIER="$(jq -r '.target_a.tier' "$SCRATCH" | head -1)"

# ---------------------------------------------------------------------------
# Write campaign-summary.json
# ---------------------------------------------------------------------------
SUMMARY_OUT="${OUTPUT_DIR}/campaign-summary.json"

jq -n \
  --arg scenario_id          "$SCENARIO_ID" \
  --arg campaign_timestamp   "$CAMPAIGN_TS" \
  --arg protocol_mode        "$CAMPAIGN_PROTOCOL_MODE" \
  --arg transport_mode       "$CAMPAIGN_TRANSPORT_MODE" \
  --arg tier                 "$CAMPAIGN_TIER" \
  --argjson total_runs       "$VALID_RUNS" \
  --arg target_a_id          "$TARGET_A_ID" \
  --arg target_b_id          "$TARGET_B_ID" \
  --argjson stats_rps_a      "$stats_rps_a" \
  --argjson stats_p95_a      "$stats_p95_a" \
  --argjson stats_p99_a      "$stats_p99_a" \
  --argjson stats_err_a      "$stats_err_a" \
  --argjson stats_rps_b      "$stats_rps_b" \
  --argjson stats_p95_b      "$stats_p95_b" \
  --argjson stats_p99_b      "$stats_p99_b" \
  --argjson stats_err_b      "$stats_err_b" \
  --argjson stats_fairness   "$stats_fairness" \
  --argjson gpr_track_isolation "$gate_pass_rate_track_isolation" \
  --argjson gpr_eligibility  "$gate_pass_rate_eligibility" \
  --argjson gpr_equivalence  "$gate_pass_rate_equivalence" \
  --argjson gpr_ab_ba        "$gate_pass_rate_ab_ba" \
  --argjson gpr_drift        "$gate_pass_rate_drift" \
  --argjson gpr_metadata     "$gate_pass_rate_metadata" \
  --argjson gpr_pin_verification "$gate_pass_rate_pin_verification" \
  --argjson gpr_schema       "$gate_pass_rate_schema" \
  --argjson gpr_quarantine   "$gate_pass_rate_quarantine" \
  --argjson gpr_reporting_guard "$gate_pass_rate_reporting_guard" \
'{
  scenario_id:          $scenario_id,
  campaign_timestamp:   $campaign_timestamp,
  total_runs:           $total_runs,
  axis_labels: {
    benchmark_family: "runtime-wrk",
    protocol_mode:    $protocol_mode,
    transport_mode:   $transport_mode,
    tier:             $tier
  },
  targets: {
    target_a: {
      target_id:           $target_a_id,
      throughput_rps:      $stats_rps_a,
      latency_p95_us:      $stats_p95_a,
      latency_p99_us:      $stats_p99_a,
      error_rate_pct:      $stats_err_a
    },
    target_b: {
      target_id:           $target_b_id,
      throughput_rps:      $stats_rps_b,
      latency_p95_us:      $stats_p95_b,
      latency_p99_us:      $stats_p99_b,
      error_rate_pct:      $stats_err_b
    }
  },
  fairness: {
    composite_score:          $stats_fairness,
    campaign_fairness_mean:   $stats_fairness.mean
  },
  gate_pass_rates: {
    track_isolation: $gpr_track_isolation,
    eligibility:     $gpr_eligibility,
    equivalence:     $gpr_equivalence,
    ab_ba:           $gpr_ab_ba,
    drift:           $gpr_drift,
    metadata:        $gpr_metadata,
    pin_verification:$gpr_pin_verification,
    schema:          $gpr_schema,
    quarantine:      $gpr_quarantine,
    reporting_guard: $gpr_reporting_guard
  }
}' > "$SUMMARY_OUT"

echo -e "${GREEN}✓${NC} campaign-summary.json written: ${SUMMARY_OUT}"

# ---------------------------------------------------------------------------
# Write campaign-status.csv
# ---------------------------------------------------------------------------
STATUS_CSV="${OUTPUT_DIR}/campaign-status.csv"
{
  echo "run_index,comparative_id,timestamp_utc,gate_pass_count,gate_warn_count,gate_fail_count,fairness_composite,interpretation"
  idx=0
  while IFS= read -r line; do
    idx=$(( idx + 1 ))
    cid="$(echo "$line" | jq -r '.comparative_id')"
    ts="$(echo "$line" | jq -r '.timestamp_utc')"
    fc="$(echo "$line" | jq -r '.fairness_composite')"
    fi_interp="$(echo "$line" | jq -r '.fairness_interp')"
    gate_pass_count="$(echo "$line" | jq -r '[.gate_status[] | select(.pass_fail == "PASS")] | length')"
    gate_warn_count="$(echo "$line" | jq -r '[.gate_status[] | select(.pass_fail == "WARN")] | length')"
    gate_fail_count="$(echo "$line" | jq -r '[.gate_status[] | select(.pass_fail == "FAIL")] | length')"
    echo "${idx},${cid},${ts},${gate_pass_count},${gate_warn_count},${gate_fail_count},${fc},${fi_interp}"
  done < "$SCRATCH"
} > "$STATUS_CSV"

echo -e "${GREEN}✓${NC} campaign-status.csv written: ${STATUS_CSV}"

# ---------------------------------------------------------------------------
# Campaign report (--generate-report)
# ---------------------------------------------------------------------------
if [[ "$GENERATE_REPORT" -eq 1 ]]; then
  REPORT_MD="${OUTPUT_DIR}/campaign-report.md"
  FAIRNESS_MEAN="$(jq -r '.fairness.campaign_fairness_mean' "$SUMMARY_OUT")"

  {
    echo "# Comparative Campaign Report"
    echo ""
    echo "| Field              | Value                            |"
    echo "|--------------------|----------------------------------|"
    echo "| scenario_id        | ${SCENARIO_ID}                   |"
    echo "| total_runs         | ${VALID_RUNS}                    |"
    echo "| campaign_timestamp | ${CAMPAIGN_TS}                   |"
    echo "| target_a           | ${TARGET_A_ID}                   |"
    echo "| target_b           | ${TARGET_B_ID}                   |"
    echo "| campaign_fairness_mean | ${FAIRNESS_MEAN}             |"
    echo ""
    echo "## Throughput (req/s)"
    echo ""
    echo "| Stat   | ${TARGET_A_ID} | ${TARGET_B_ID} |"
    echo "|--------|---------|---------|"
    jq -r --argjson a "$stats_rps_a" --argjson b "$stats_rps_b" -n '
      "| min    | \($a.min)    | \($b.min)    |",
      "| max    | \($a.max)    | \($b.max)    |",
      "| mean   | \($a.mean)   | \($b.mean)   |",
      "| median | \($a.median) | \($b.median) |",
      "| cv     | \($a.cv)     | \($b.cv)     |"
    '
    echo ""
    echo "## Latency p95 (us)"
    echo ""
    echo "| Stat   | ${TARGET_A_ID} | ${TARGET_B_ID} |"
    echo "|--------|---------|---------|"
    jq -r --argjson a "$stats_p95_a" --argjson b "$stats_p95_b" -n '
      "| min    | \($a.min)    | \($b.min)    |",
      "| max    | \($a.max)    | \($b.max)    |",
      "| mean   | \($a.mean)   | \($b.mean)   |",
      "| median | \($a.median) | \($b.median) |",
      "| cv     | \($a.cv)     | \($b.cv)     |"
    '
    echo ""
    echo "## Latency p99 (us)"
    echo ""
    echo "| Stat   | ${TARGET_A_ID} | ${TARGET_B_ID} |"
    echo "|--------|---------|---------|"
    jq -r --argjson a "$stats_p99_a" --argjson b "$stats_p99_b" -n '
      "| min    | \($a.min)    | \($b.min)    |",
      "| max    | \($a.max)    | \($b.max)    |",
      "| mean   | \($a.mean)   | \($b.mean)   |",
      "| median | \($a.median) | \($b.median) |",
      "| cv     | \($a.cv)     | \($b.cv)     |"
    '
    echo ""
    echo "## Gate Pass Rates"
    echo ""
    echo "| Gate        | Pass Rate |"
    echo "|-------------|-----------|"
    jq -r '.gate_pass_rates | to_entries[] | "| \(.key)        | \(.value) |"' "$SUMMARY_OUT"
    echo ""
    echo "> Axis labels: tier=${CAMPAIGN_TIER} | protocol_mode=${CAMPAIGN_PROTOCOL_MODE} | transport_mode=${CAMPAIGN_TRANSPORT_MODE} | benchmark_family=runtime-wrk"
    echo ""
    echo "_Generated by aggregate-comparative-results.sh — Phase 6.3_"
  } > "$REPORT_MD"

  echo -e "${GREEN}✓${NC} campaign-report.md written: ${REPORT_MD}"
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  CAMPAIGN AGGREGATION COMPLETE${NC}"
echo -e "${GREEN}  total_runs     : ${VALID_RUNS}${NC}"
echo -e "${GREEN}  output_dir     : ${OUTPUT_DIR}${NC}"
echo -e "${GREEN}============================================================${NC}"
