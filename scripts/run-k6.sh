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

# CO Guard: k6 closed-loop executors (shared-iterations, ramping-vus) produce
# Coordinated Omission-contaminated p99 latency. Hard-fail unless arrival-rate
# executor is declared. Bypass with CO_GUARD_BYPASS=true (no latency claims allowed).
if ! grep -qE '"(constant|ramping)-arrival-rate"' "$K6_SCRIPT" 2>/dev/null \
   && ! grep -qE "executor:[[:space:]]*'(constant|ramping)-arrival-rate'" "$K6_SCRIPT" 2>/dev/null; then
  echo "ERROR: k6 scenario does not declare a constant-arrival-rate or ramping-arrival-rate executor." >&2
  echo "  Closed-loop executors (shared-iterations, ramping-vus) produce CO-contaminated p99 latency." >&2
  echo "  Update $K6_SCRIPT to use: executor: 'constant-arrival-rate'" >&2
  echo "  See docs/methodology.md for guidance." >&2
  echo "  To run throughput-only probes (no latency claims), set CO_GUARD_BYPASS=true" >&2
  if [[ "${CO_GUARD_BYPASS:-false}" != "true" ]]; then
    exit 1
  fi
  echo "WARN: CO_GUARD_BYPASS=true — latency results will be CO-contaminated. Do not publish p99." >&2
fi

k6 run \
  --out json="$RESULT_JSON" \
  --summary-export="$RESULTS_DIR/k6-summary-${TIMESTAMP}.json" \
  "$@" \
  "$K6_SCRIPT"

if [[ -f "$RESULT_JSON" ]]; then
  if ! jq -e '.metrics.http_req_duration.values["p(99)"]' "$RESULT_JSON" >/dev/null 2>&1; then
    echo "WARN: p(99) not found in k6 output — check that enough samples were collected." >&2
  fi
fi

echo ""
echo "Result written to: $RESULT_JSON"
