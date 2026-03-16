#!/usr/bin/env bash
# run-h2load.sh — Run h2load HTTP/2 load benchmark against a target.
# Usage:
#   ./scripts/run-h2load.sh <target-profile-dir> <scenario-dir> [EXTRA_H2LOAD_ARGS...]
#
# Examples:
#   ./scripts/run-h2load.sh targets/exeris-kernel/community scenarios/plaintext
#   ./scripts/run-h2load.sh targets/exeris-kernel/enterprise scenarios/json-1kb -m 20
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

TARGET_DIR="${1:?Usage: run-h2load.sh <target-dir> <scenario-dir>}"
SCENARIO_DIR="${2:?Usage: run-h2load.sh <target-dir> <scenario-dir>}"
shift 2

TARGET_DIR="$ROOT/$TARGET_DIR"
SCENARIO_DIR="$ROOT/$SCENARIO_DIR"

TARGET_CONFIG="$TARGET_DIR/h2load-target.env"
if [[ ! -f "$TARGET_CONFIG" ]]; then
  echo "ERROR: Target config not found: $TARGET_CONFIG" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$TARGET_CONFIG"
# Expected: H2LOAD_BASE_URL, H2LOAD_PATH

SCENARIO_CONFIG="$SCENARIO_DIR/h2load.env"
[[ -f "$SCENARIO_CONFIG" ]] && source "$SCENARIO_CONFIG"

CLIENTS="${H2LOAD_CLIENTS:-100}"
STREAMS="${H2LOAD_MAX_STREAMS:-10}"
TOTAL_REQUESTS="${H2LOAD_TOTAL_REQUESTS:-1000000}"
URL="${H2LOAD_BASE_URL}${H2LOAD_PATH:-/}"
DATA_FILE="${H2LOAD_DATA_FILE:-}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$ROOT/results/raw"
mkdir -p "$RESULTS_DIR"
RESULT_OUT="$RESULTS_DIR/h2load-${TIMESTAMP}.txt"

echo "=== h2load benchmark ==="
echo "  URL    : $URL"
echo "  Clients: $CLIENTS"
echo "  Streams: $STREAMS"
echo "  Total  : $TOTAL_REQUESTS requests"
[[ -n "$DATA_FILE" ]] && echo "  Data   : $DATA_FILE"
echo ""

echo "--- Warmup (10000 requests) ---"
h2load -n 10000 -c "$CLIENTS" -m "$STREAMS" \
  ${DATA_FILE:+-d "$DATA_FILE"} \
  "$URL" > /dev/null

echo "--- Measurement ---"
h2load -n "$TOTAL_REQUESTS" -c "$CLIENTS" -m "$STREAMS" \
  ${DATA_FILE:+-d "$DATA_FILE"} \
  "$@" \
  "$URL" | tee "$RESULT_OUT"

echo ""
echo "Result written to: $RESULT_OUT"
