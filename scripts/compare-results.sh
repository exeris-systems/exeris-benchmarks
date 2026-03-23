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

# --- Comparison eligibility pre-check ---
# Reads claim_scope and execution_class from each result JSON.
# Fails fast unless claim_scope is exactly comparison_eligible.
check_eligible() {
  local file="$1"
  local label="$2"
  local scope exec_class final_reason
  scope="$(jq -er '.claim_scope' "$file" 2>/dev/null)" || {
    echo "ERROR: Contract drift in $label: missing required field .claim_scope for comparison eligibility" >&2
    echo "ACTION: populate canonical classification fields (claim_scope, execution_class, final_reason) before comparing." >&2
    exit 1
  }
  exec_class="$(jq -er '.execution_class' "$file" 2>/dev/null)" || {
    echo "ERROR: Contract drift in $label: missing required field .execution_class for comparison eligibility" >&2
    exit 1
  }
  final_reason="$(jq -er '.final_reason' "$file" 2>/dev/null)" || {
    echo "ERROR: Contract drift in $label: missing required field .final_reason for comparison eligibility" >&2
    exit 1
  }

  if [[ "$final_reason" != "ok" ]]; then
    echo "EXCLUDED: comparative sections disabled for $label" >&2
    echo "EXCLUSION_REASON: final_reason_not_ok" >&2
    echo "OBSERVED: claim_scope=${scope}, execution_class=${exec_class}, final_reason=${final_reason}" >&2
    echo "ACTION: Only final_reason=ok is eligible for comparison." >&2
    exit 1
  fi

  if [[ "$scope" != "comparison_eligible" ]]; then
    echo "EXCLUDED: comparative sections disabled for $label" >&2
    echo "EXCLUSION_REASON: claim_scope_not_comparison_eligible" >&2
    echo "OBSERVED: claim_scope=${scope}, execution_class=${exec_class}, final_reason=${final_reason}" >&2
    echo "ACTION: Only claim_scope=comparison_eligible is allowed for comparisons. Produce a complete guard/regression run with final_reason=ok, then rerun compare-results.sh." >&2
    exit 1
  fi
}

metric_present() {
  local file="$1"
  local key="$2"
  jq -e --arg k "$key" '.metrics | type == "object" and has($k)' "$file" >/dev/null 2>&1
}

metric_value() {
  local file="$1"
  local key="$2"
  local label="$3"
  jq -er --arg k "$key" '.metrics[$k] | select(type == "number")' "$file" 2>/dev/null || {
    echo "ERROR: Contract drift in $label: .metrics.$key is missing or non-numeric" >&2
    exit 1
  }
}

compare_metric_pair_if_present() {
  local label="$1"
  local key="$2"
  local warn="$3"
  local block="$4"
  local direction="$5"

  local base_has=0
  local cur_has=0
  metric_present "$BASELINE" "$key" && base_has=1
  metric_present "$CURRENT" "$key" && cur_has=1

  if [[ "$base_has" -ne "$cur_has" ]]; then
    echo "ERROR: Contract drift: metric presence mismatch for '$key' (baseline=$base_has, current=$cur_has)" >&2
    echo "ACTION: ensure both artifacts expose the same canonical metrics before comparison." >&2
    exit 1
  fi

  if [[ "$base_has" -eq 1 ]]; then
    local base_val cur_val
    base_val="$(metric_value "$BASELINE" "$key" "baseline ($BASELINE)")"
    cur_val="$(metric_value "$CURRENT" "$key" "current ($CURRENT)")"
    compare_metric "$label" "$base_val" "$cur_val" "$warn" "$block" "$direction"
  fi
}

check_eligible "$BASELINE" "baseline ($BASELINE)"
check_eligible "$CURRENT"  "current ($CURRENT)"

# --- Regression thresholds (aligns with docs/regression-policy.md) ---
WARN_THROUGHPUT_PCT=-5
BLOCK_THROUGHPUT_PCT=-10
WARN_LATENCY_MEAN_PCT=5
BLOCK_LATENCY_MEAN_PCT=10
WARN_LATENCY_P99_PCT=10
BLOCK_LATENCY_P99_PCT=20
WARN_LATENCY_P999_PCT=15
BLOCK_LATENCY_P999_PCT=30

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

compare_metric_pair_if_present "Throughput (req/s)" "throughput_rps" "$WARN_THROUGHPUT_PCT" "$BLOCK_THROUGHPUT_PCT" higher_is_better
compare_metric_pair_if_present "Latency mean (µs)" "latency_mean_us" "$WARN_LATENCY_MEAN_PCT" "$BLOCK_LATENCY_MEAN_PCT" lower_is_better
compare_metric_pair_if_present "Latency p99 (µs)" "latency_p99_us" "$WARN_LATENCY_P99_PCT" "$BLOCK_LATENCY_P99_PCT" lower_is_better
compare_metric_pair_if_present "Latency p999 (µs)" "latency_p999_us" "$WARN_LATENCY_P999_PCT" "$BLOCK_LATENCY_P999_PCT" lower_is_better

BASE_ALLOC_PRESENT=0
CUR_ALLOC_PRESENT=0
metric_present "$BASELINE" "jmh_alloc_rate_norm_bytes" && BASE_ALLOC_PRESENT=1
metric_present "$CURRENT" "jmh_alloc_rate_norm_bytes" && CUR_ALLOC_PRESENT=1
if [[ "$BASE_ALLOC_PRESENT" -ne "$CUR_ALLOC_PRESENT" ]]; then
  echo "ERROR: Contract drift: metric presence mismatch for 'jmh_alloc_rate_norm_bytes' (baseline=$BASE_ALLOC_PRESENT, current=$CUR_ALLOC_PRESENT)" >&2
  exit 1
fi

if [[ "$BASE_ALLOC_PRESENT" -eq 1 ]]; then
  BASE_ALLOC="$(metric_value "$BASELINE" "jmh_alloc_rate_norm_bytes" "baseline ($BASELINE)")"
  CUR_ALLOC="$(metric_value "$CURRENT" "jmh_alloc_rate_norm_bytes" "current ($CURRENT)")"
  [[ "$BASE_ALLOC" == "0" && "$CUR_ALLOC" != "0" ]] && {
  echo "| zero-alloc path | 0 B/op | ${CUR_ALLOC} B/op | N/A | ✗ BLOCKING REGRESSION (zero-alloc violation) |"
  REGRESSION=1
}
fi

echo ""
if [[ "$REGRESSION" -eq 1 ]]; then
  echo "**RESULT: REGRESSION DETECTED** — see docs/regression-policy.md"
  exit 1
else
  echo "**RESULT: OK** — no blocking regressions detected"
fi
