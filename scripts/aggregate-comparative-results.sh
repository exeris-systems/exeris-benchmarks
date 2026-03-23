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

# ---------------------------------------------------------------------------
# Discover comparative-result.json files
# ---------------------------------------------------------------------------
# Expand glob relative to REPO_ROOT if not absolute
if [[ "$INPUT_PATTERN" != /* ]]; then
  INPUT_PATTERN="${REPO_ROOT}/${INPUT_PATTERN}"
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
  # Emit one compact JSON object per line
  jq -c '{
    run_file:         input_filename,
    comparative_id:   .comparative_id,
    timestamp_utc:    .timestamp_utc,
    scenario_id:      .scenario_id,
    contract_id:      .contract_id,
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
  }' --rawfile /dev/null "$f" "$f" 2>/dev/null >> "$SCRATCH" || true
done

VALID_RUNS="$(wc -l < "$SCRATCH" | tr -d ' ')"

if [[ "$VALID_RUNS" -lt 2 ]]; then
  echo "ERROR: After JSON validation, only ${VALID_RUNS} valid result(s) remain (minimum 2 required)." >&2
  exit 1
fi

echo "  Valid runs processed: ${VALID_RUNS}"

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

gate_pass_rate_maturity="$(compute_gate_pass_rate "maturity")"
gate_pass_rate_equivalence="$(compute_gate_pass_rate "equivalence")"
gate_pass_rate_endpoint="$(compute_gate_pass_rate "endpoint")"
gate_pass_rate_payload="$(compute_gate_pass_rate "payload")"
gate_pass_rate_fairness="$(compute_gate_pass_rate "fairness")"
gate_pass_rate_error="$(compute_gate_pass_rate "error")"
gate_pass_rate_measurement="$(compute_gate_pass_rate "measurement")"
gate_pass_rate_metadata="$(compute_gate_pass_rate "metadata")"

# Derive target IDs from first run
TARGET_A_ID="$(jq -r '.target_a.target_id' "$SCRATCH" | head -1)"
TARGET_B_ID="$(jq -r '.target_b.target_id' "$SCRATCH" | head -1)"
CAMPAIGN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Write campaign-summary.json
# ---------------------------------------------------------------------------
SUMMARY_OUT="${OUTPUT_DIR}/campaign-summary.json"

jq -n \
  --arg scenario_id          "$SCENARIO_ID" \
  --arg campaign_timestamp   "$CAMPAIGN_TS" \
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
  --argjson gpr_maturity     "$gate_pass_rate_maturity" \
  --argjson gpr_equivalence  "$gate_pass_rate_equivalence" \
  --argjson gpr_endpoint     "$gate_pass_rate_endpoint" \
  --argjson gpr_payload      "$gate_pass_rate_payload" \
  --argjson gpr_fairness     "$gate_pass_rate_fairness" \
  --argjson gpr_error        "$gate_pass_rate_error" \
  --argjson gpr_measurement  "$gate_pass_rate_measurement" \
  --argjson gpr_metadata     "$gate_pass_rate_metadata" \
'{
  scenario_id:          $scenario_id,
  campaign_timestamp:   $campaign_timestamp,
  total_runs:           $total_runs,
  axis_labels: {
    benchmark_family: "runtime-wrk",
    protocol_mode:    "h1",
    transport_mode:   "loopback-h1",
    tier:             "community"
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
    maturity:    $gpr_maturity,
    equivalence: $gpr_equivalence,
    endpoint:    $gpr_endpoint,
    payload:     $gpr_payload,
    fairness:    $gpr_fairness,
    error:       $gpr_error,
    measurement: $gpr_measurement,
    metadata:    $gpr_metadata
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
    echo "> Axis labels: tier=community | protocol_mode=h1 | transport_mode=loopback-h1 | benchmark_family=runtime-wrk"
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
