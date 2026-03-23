#!/usr/bin/env bash
set -euo pipefail

# compute-fairness-index.sh — Compute the fairness index between two benchmark result.json files.
#
# Usage:
#   tools/compute-fairness-index.sh \
#     --result-a <path-to-result-a.json> \
#     --result-b <path-to-result-b.json> \
#     --output   <path-to-fairness-index.json>
#
# Output: fairness-index.json conforming to schemas/fairness-index.schema.json
# Exit code: 0 on success, 1 on validation failure or missing inputs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RESULT_A=""
RESULT_B=""
OUTPUT=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-a) RESULT_A="$2"; shift 2 ;;
    --result-b) RESULT_B="$2"; shift 2 ;;
    --output)   OUTPUT="$2";   shift 2 ;;
    *) echo -e "${RED}ERROR${NC}: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$RESULT_A" || -z "$RESULT_B" || -z "$OUTPUT" ]]; then
  echo "ERROR: --result-a, --result-b, and --output are all required." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for cmd in jq awk date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Input file validation
# ---------------------------------------------------------------------------
for f in "$RESULT_A" "$RESULT_B"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Result file not found: $f" >&2
    exit 1
  fi
  if ! jq empty "$f" 2>/dev/null; then
    echo "ERROR: Result file is not valid JSON: $f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Extract target IDs (best-effort; fall back to filename)
# ---------------------------------------------------------------------------
TARGET_A_ID="$(jq -r '.target.repo // .run_id // "unknown-a"' "$RESULT_A")"
TARGET_B_ID="$(jq -r '.target.repo // .run_id // "unknown-b"' "$RESULT_B")"

# Use run_id as target label if target.repo is absent or generic
if jq -e '.run_id' "$RESULT_A" >/dev/null 2>&1; then
  TARGET_A_ID="$(jq -r '.run_id' "$RESULT_A")"
fi
if jq -e '.run_id' "$RESULT_B" >/dev/null 2>&1; then
  TARGET_B_ID="$(jq -r '.run_id' "$RESULT_B")"
fi

# ---------------------------------------------------------------------------
# Helper: extract a numeric metric, error if missing
# ---------------------------------------------------------------------------
extract_metric() {
  local file="$1"
  local field="$2"
  local value
  value="$(jq -r ".metrics.${field} // empty" "$file")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "ERROR: Required metric field '.metrics.${field}' is absent or null in: $file" >&2
    exit 1
  fi
  echo "$value"
}

# ---------------------------------------------------------------------------
# Extract required metrics
# ---------------------------------------------------------------------------
ERROR_A="$(extract_metric "$RESULT_A" "error_rate_pct")"
ERROR_B="$(extract_metric "$RESULT_B" "error_rate_pct")"

RPS_A="$(extract_metric "$RESULT_A" "throughput_rps")"
RPS_B="$(extract_metric "$RESULT_B" "throughput_rps")"

P50_A="$(extract_metric "$RESULT_A" "latency_p50_us")"
P50_B="$(extract_metric "$RESULT_B" "latency_p50_us")"

P95_A="$(extract_metric "$RESULT_A" "latency_p95_us")"
P95_B="$(extract_metric "$RESULT_B" "latency_p95_us")"

P99_A="$(extract_metric "$RESULT_A" "latency_p99_us")"
P99_B="$(extract_metric "$RESULT_B" "latency_p99_us")"

# Optional percentiles — default to 0 when absent (will not make symmetry worse than present data)
P75_A="$(jq -r '.metrics.latency_p75_us // 0' "$RESULT_A")"
P75_B="$(jq -r '.metrics.latency_p75_us // 0' "$RESULT_B")"
P90_A="$(jq -r '.metrics.latency_p90_us // 0' "$RESULT_A")"
P90_B="$(jq -r '.metrics.latency_p90_us // 0' "$RESULT_B")"

# ---------------------------------------------------------------------------
# ALGORITHM — all floating-point math via awk to avoid Python dependency
# ---------------------------------------------------------------------------

# ---- Gate 1: error_symmetry (weight 0.3) -----------------------------------
# - Both < 0.5  → 1.0
# - Either > 1.0 → 0.0
# - Otherwise: max(0.0, 1.0 - abs(a - b) / 0.02)
ERROR_SYMMETRY="$(awk -v a="$ERROR_A" -v b="$ERROR_B" 'BEGIN {
  if (a < 0.5 && b < 0.5) { printf "%.4f", 1.0; exit }
  if (a > 1.0 || b > 1.0) { printf "%.4f", 0.0; exit }
  diff = a - b; if (diff < 0) diff = -diff
  val = 1.0 - diff / 0.02
  if (val < 0.0) val = 0.0
  if (val > 1.0) val = 1.0
  printf "%.4f", val
}')"

# ---- Gate 2: latency_symmetry (weight 0.4) ---------------------------------
# Percentile pairs: p50, p75, p90, p95, p99
# max_norm_diff = max over pairs of abs(a - b) / max(a, b)
# < 0.10 → 1.0 ; > 0.50 → 0.0 ; else 1.0 - (diff / 0.50)
LATENCY_SYMMETRY="$(awk \
  -v p50a="$P50_A" -v p50b="$P50_B" \
  -v p75a="$P75_A" -v p75b="$P75_B" \
  -v p90a="$P90_A" -v p90b="$P90_B" \
  -v p95a="$P95_A" -v p95b="$P95_B" \
  -v p99a="$P99_A" -v p99b="$P99_B" \
'BEGIN {
  # Compute normalised diff for a single pair; skip if both zero
  function norm_diff(a, b,    mx, diff) {
    mx = a > b ? a : b
    if (mx == 0) return 0
    diff = a - b; if (diff < 0) diff = -diff
    return diff / mx
  }
  max_nd = 0
  nd = norm_diff(p50a, p50b); if (nd > max_nd) max_nd = nd
  # Only include p75/p90 if non-zero (optional fields)
  if (p75a > 0 || p75b > 0) { nd = norm_diff(p75a, p75b); if (nd > max_nd) max_nd = nd }
  if (p90a > 0 || p90b > 0) { nd = norm_diff(p90a, p90b); if (nd > max_nd) max_nd = nd }
  nd = norm_diff(p95a, p95b); if (nd > max_nd) max_nd = nd
  nd = norm_diff(p99a, p99b); if (nd > max_nd) max_nd = nd

  if (max_nd < 0.10) { printf "%.4f", 1.0; exit }
  if (max_nd > 0.50) { printf "%.4f", 0.0; exit }
  val = 1.0 - (max_nd / 0.50)
  if (val < 0.0) val = 0.0
  if (val > 1.0) val = 1.0
  printf "%.4f", val
}')"

# ---- Gate 3: throughput_confidence (weight 0.2) ----------------------------
# ratio = min(a,b) / max(a,b)
# > 0.9 → 1.0 ; < 0.7 → 0.5 ; else 0.5 + (ratio - 0.7) / 0.4
THROUGHPUT_CONFIDENCE="$(awk -v a="$RPS_A" -v b="$RPS_B" 'BEGIN {
  mx = a > b ? a : b
  mn = a < b ? a : b
  if (mx == 0) { printf "%.4f", 0.5; exit }
  ratio = mn / mx
  if (ratio > 0.9) { printf "%.4f", 1.0; exit }
  if (ratio < 0.7) { printf "%.4f", 0.5; exit }
  val = 0.5 + (ratio - 0.7) / 0.4
  if (val > 1.0) val = 1.0
  printf "%.4f", val
}')"

# ---- Composite score -------------------------------------------------------
# 0.3 * error + 0.4 * latency + 0.2 * throughput  (weights sum to 0.9 by design)
COMPOSITE="$(awk \
  -v es="$ERROR_SYMMETRY" \
  -v ls="$LATENCY_SYMMETRY" \
  -v tc="$THROUGHPUT_CONFIDENCE" \
'BEGIN {
  val = 0.3 * es + 0.4 * ls + 0.2 * tc
  printf "%.4f", val
}')"

# ---- Interpretation --------------------------------------------------------
INTERPRETATION="$(awk -v c="$COMPOSITE" 'BEGIN {
  if (c >= 0.85) { print "highly_fair";        exit }
  if (c >= 0.70) { print "fairly_comparable";  exit }
  if (c >= 0.50) { print "moderate_asymmetry"; exit }
  print "unsuitable"
}')"

# ---------------------------------------------------------------------------
# Build output JSON via jq (never string-concatenate JSON)
# ---------------------------------------------------------------------------
COMPUTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$OUTPUT")"

jq -n \
  --argjson error_symmetry       "$ERROR_SYMMETRY" \
  --argjson latency_symmetry     "$LATENCY_SYMMETRY" \
  --argjson throughput_confidence "$THROUGHPUT_CONFIDENCE" \
  --argjson composite_score      "$COMPOSITE" \
  --arg     interpretation       "$INTERPRETATION" \
  --arg     computed_at          "$COMPUTED_AT" \
  --arg     target_a             "$TARGET_A_ID" \
  --arg     target_b             "$TARGET_B_ID" \
'{
  error_symmetry:        $error_symmetry,
  latency_symmetry:      $latency_symmetry,
  throughput_confidence: $throughput_confidence,
  composite_score:       $composite_score,
  interpretation:        $interpretation,
  computed_at:           $computed_at,
  targets:               [$target_a, $target_b],
  asymmetry_notes:       []
}' > "$OUTPUT"

echo -e "${GREEN}✓${NC} Fairness index written to: $OUTPUT"
echo -e "  composite_score:  ${COMPOSITE}  (${INTERPRETATION})"
echo -e "  error_symmetry:   ${ERROR_SYMMETRY}"
echo -e "  latency_symmetry: ${LATENCY_SYMMETRY}"
echo -e "  throughput_conf:  ${THROUGHPUT_CONFIDENCE}"
