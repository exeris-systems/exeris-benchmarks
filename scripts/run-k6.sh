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

echo "=== k6 scenario ==="
echo "  Script : $K6_SCRIPT"
echo "  Output : $RESULT_JSON"
echo ""

k6 run \
  --out json="$RESULT_JSON" \
  "$@" \
  "$K6_SCRIPT"

echo ""
echo "Result written to: $RESULT_JSON"
