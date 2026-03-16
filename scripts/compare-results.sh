#!/usr/bin/env bash
# compare-results.sh — Compare a current result JSON against a baseline JSON.
# Outputs a Markdown summary table and exits non-zero if any blocking regression
# is detected (per docs/regression-policy.md).
#
# Usage:
#   ./scripts/compare-results.sh <baseline.json> <current.json>
#
# Both files must conform to schemas/benchmark-result.schema.json.
set -euo pipefail

BASELINE="${1:?Usage: compare-results.sh <baseline.json> <current.json>}"
CURRENT="${2:?Usage: compare-results.sh <baseline.json> <current.json>}"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

# --- Regression thresholds (aligns with docs/regression-policy.md) ---
WARN_THROUGHPUT_PCT=-5
BLOCK_THROUGHPUT_PCT=-10
WARN_LATENCY_MEAN_PCT=5
BLOCK_LATENCY_MEAN_PCT=10
WARN_LATENCY_P99_PCT=10
BLOCK_LATENCY_P99_PCT=20

pct_change() {
  local base="$1"
  local cur="$2"
  # Returns (cur - base) / base * 100
  echo "$(python3 -c "b=float('$base'); c=float('$cur'); print(0 if b==0 else round((c-b)/b*100,2))")"
}

echo "## Exeris Benchmark Comparison"
echo ""
echo "| Metric | Baseline | Current | Delta | Status |"
echo "|---|---|---|---|---|"

REGRESSION=0

compare_metric() {
  local label="$1"
  local base_val="$2"
  local cur_val="$3"
  local warn_threshold="$4"   # positive = "higher is worse"
  local block_threshold="$5"
  local direction="$6"        # "lower_is_better" or "higher_is_better"

  local delta
  delta="$(pct_change "$base_val" "$cur_val")"

  local status="✓"
  local effective_delta="$delta"

  if [[ "$direction" == "higher_is_better" ]]; then
    # throughput: negative delta is bad
    effective_delta="$(python3 -c "print(-1 * float('$delta'))")"
    if python3 -c "import sys; sys.exit(0 if float('$effective_delta') >= float('$block_threshold'.replace('-','')) else 1)" 2>/dev/null; then
      status="✗ BLOCKING REGRESSION"
      REGRESSION=1
    elif python3 -c "import sys; sys.exit(0 if float('$effective_delta') >= float('$warn_threshold'.replace('-','')) else 1)" 2>/dev/null; then
      status="⚠ WARNING"
    fi
  else
    # latency: positive delta is bad
    if python3 -c "import sys; sys.exit(0 if float('$delta') >= float('$block_threshold') else 1)" 2>/dev/null; then
      status="✗ BLOCKING REGRESSION"
      REGRESSION=1
    elif python3 -c "import sys; sys.exit(0 if float('$delta') >= float('$warn_threshold') else 1)" 2>/dev/null; then
      status="⚠ WARNING"
    fi
  fi

  printf "| %-35s | %12s | %12s | %+.2f%% | %s |\n" \
    "$label" "$base_val" "$cur_val" "$delta" "$status"
}

# Extract metrics
BASE_RPS="$(jq -r '.metrics.throughput_rps // "N/A"' "$BASELINE")"
CUR_RPS="$(jq -r '.metrics.throughput_rps // "N/A"' "$CURRENT")"
BASE_LAT_MEAN="$(jq -r '.metrics.latency_mean_us // "N/A"' "$BASELINE")"
CUR_LAT_MEAN="$(jq -r '.metrics.latency_mean_us // "N/A"' "$CURRENT")"
BASE_LAT_P99="$(jq -r '.metrics.latency_p99_us // "N/A"' "$BASELINE")"
CUR_LAT_P99="$(jq -r '.metrics.latency_p99_us // "N/A"' "$CURRENT")"
BASE_LAT_P999="$(jq -r '.metrics.latency_p999_us // "N/A"' "$BASELINE")"
CUR_LAT_P999="$(jq -r '.metrics.latency_p999_us // "N/A"' "$CURRENT")"
BASE_ALLOC="$(jq -r '.metrics.jmh_alloc_rate_norm_bytes // "N/A"' "$BASELINE")"
CUR_ALLOC="$(jq -r '.metrics.jmh_alloc_rate_norm_bytes // "N/A"' "$CURRENT")"

[[ "$BASE_RPS" != "N/A" ]]       && compare_metric "Throughput (req/s)"   "$BASE_RPS"       "$CUR_RPS"       5  10  higher_is_better
[[ "$BASE_LAT_MEAN" != "N/A" ]]  && compare_metric "Latency mean (µs)"    "$BASE_LAT_MEAN"  "$CUR_LAT_MEAN"  5  10  lower_is_better
[[ "$BASE_LAT_P99" != "N/A" ]]   && compare_metric "Latency p99 (µs)"     "$BASE_LAT_P99"   "$CUR_LAT_P99"   10 20  lower_is_better
[[ "$BASE_LAT_P999" != "N/A" ]]  && compare_metric "Latency p999 (µs)"    "$BASE_LAT_P999"  "$CUR_LAT_P999"  15 30  lower_is_better
[[ "$BASE_ALLOC" != "N/A" && "$BASE_ALLOC" == "0" && "$CUR_ALLOC" != "0" && "$CUR_ALLOC" != "N/A" ]] && {
  echo "| zero-alloc path | 0 B/op | ${CUR_ALLOC} B/op | N/A | ✗ BLOCKING REGRESSION (zero-alloc violation) |"
  REGRESSION=1
}

echo ""
if [[ "$REGRESSION" -eq 1 ]]; then
  echo "**RESULT: REGRESSION DETECTED** — see docs/regression-policy.md"
  exit 1
else
  echo "**RESULT: OK** — no blocking regressions detected"
fi
