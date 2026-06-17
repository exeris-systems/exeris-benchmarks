#!/usr/bin/env bash
# run-k6.sh — Run a k6 scenario.
# Usage:
#   ./scripts/run-k6.sh <scenario-dir> [K6_ARGS...]
#
# Examples:
#   ./scripts/run-k6.sh scenarios/json-1kb
#   ./scripts/run-k6.sh scenarios/backpressure --vus 200 --duration 60s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
source "$ROOT/tools/bench/lib/k6.sh"

SCENARIO_DIR="${1:?Usage: run-k6.sh <scenario-dir> [k6 args]}"
shift

SCENARIO_DIR="$ROOT/$SCENARIO_DIR"
K6_SCRIPT="$SCENARIO_DIR/k6.js"

if [[ ! -f "$K6_SCRIPT" ]]; then
  echo "ERROR: k6 script not found: $K6_SCRIPT" >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$ROOT/results/raw"
mkdir -p "$RESULTS_DIR"
RESULT_JSON="$RESULTS_DIR/k6-${TIMESTAMP}.json"
# Persist the k6 console output as a first-class artifact alongside the JSON
# streams (the JSON is the data; the console log is the ground truth for what
# k6 reported — thresholds/checks/protocol — kept for honest reproducibility).
# pipefail (set above) preserves k6's exit status through the tee.
K6_CONSOLE_LOG="$RESULTS_DIR/k6-console-${TIMESTAMP}.log"

echo "=== k6 scenario ==="
echo "  Script : $K6_SCRIPT"
echo "  Output : $RESULT_JSON"
echo "  Console: $K6_CONSOLE_LOG"
echo ""

bench_k6_assert_arrival_rate_executor "$K6_SCRIPT" || exit 1

k6 run \
  --out json="$RESULT_JSON" \
  --summary-export="$RESULTS_DIR/k6-summary-${TIMESTAMP}.json" \
  "$@" \
  "$K6_SCRIPT" 2>&1 | tee "$K6_CONSOLE_LOG"

if [[ -f "$RESULT_JSON" ]]; then
  if ! jq -e '.metrics.http_req_duration.values["p(99)"]' "$RESULT_JSON" >/dev/null 2>&1; then
    echo "WARN: p(99) not found in k6 output — check that enough samples were collected." >&2
  fi
fi

echo ""
echo "Result written to: $RESULT_JSON"
echo "Console log      : $K6_CONSOLE_LOG"
