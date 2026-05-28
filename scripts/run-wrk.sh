#!/usr/bin/env bash
# run-wrk.sh — Run wrk HTTP/1.1 load benchmark against a target.
# Usage:
#   ./scripts/run-wrk.sh <target-profile-dir> <scenario-dir> [EXTRA_WRK_ARGS...]
#
# Examples:
#   ./scripts/run-wrk.sh targets/exeris-kernel/community scenarios/plaintext
#   ./scripts/run-wrk.sh targets/exeris-kernel/community scenarios/json-1kb -t 8 -c 200
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

TARGET_DIR="${1:?Usage: run-wrk.sh <target-dir> <scenario-dir>}"
SCENARIO_DIR="${2:?Usage: run-wrk.sh <target-dir> <scenario-dir>}"
shift 2

TARGET_DIR="$ROOT/$TARGET_DIR"
SCENARIO_DIR="$ROOT/$SCENARIO_DIR"

# Load target config (optional when a base URL is supplied via the environment,
# e.g. WRK_BASE_URL_OVERRIDE from run-guided.sh for local/WAN dispatch).
TARGET_CONFIG="$TARGET_DIR/wrk-target.env"
if [[ -f "$TARGET_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$TARGET_CONFIG"
elif [[ -z "${WRK_BASE_URL_OVERRIDE:-}${WRK_BASE_URL:-}" ]]; then
  echo "ERROR: Target config not found: $TARGET_CONFIG (and no WRK_BASE_URL/WRK_BASE_URL_OVERRIDE set)" >&2
  exit 1
fi
# Expected variables: WRK_BASE_URL, WRK_PATH

SCENARIO_CONFIG="$SCENARIO_DIR/wrk.env"
if [[ -f "$SCENARIO_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$SCENARIO_CONFIG"
fi

# Overrides win over both target and scenario config (guided local/WAN dispatch).
WRK_BASE_URL="${WRK_BASE_URL_OVERRIDE:-${WRK_BASE_URL:-}}"
WRK_PATH="${WRK_PATH_OVERRIDE:-${WRK_PATH:-/}}"
if [[ -z "${WRK_BASE_URL:-}" ]]; then
  echo "ERROR: WRK_BASE_URL is empty (set it in $TARGET_CONFIG or via WRK_BASE_URL_OVERRIDE)" >&2
  exit 1
fi

# WRK_LUA_SCRIPT may be set by scenario config
LUA_SCRIPT="${WRK_LUA_SCRIPT:-}"

THREADS="${WRK_THREADS_OVERRIDE:-${WRK_THREADS:-4}}"
CONNECTIONS="${WRK_CONNECTIONS_OVERRIDE:-${WRK_CONNECTIONS:-100}}"
DURATION="${WRK_DURATION_OVERRIDE:-${WRK_DURATION:-30s}}"
URL="${WRK_BASE_URL}${WRK_PATH:-/}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$ROOT/results/raw"
mkdir -p "$RESULTS_DIR"
RESULT_OUT="$RESULTS_DIR/wrk-${TIMESTAMP}.txt"

echo "=== wrk benchmark ==="
echo "  URL        : $URL"
echo "  Threads    : $THREADS"
echo "  Connections: $CONNECTIONS"
echo "  Duration   : $DURATION"
[[ -n "$LUA_SCRIPT" ]] && echo "  Lua script : $LUA_SCRIPT"
echo ""

echo "--- Warmup (60s) ---"
wrk -t "$THREADS" -c "$CONNECTIONS" -d 60s ${LUA_SCRIPT:+--script "$LUA_SCRIPT"} "$URL" > /dev/null

echo "--- Measurement ---"
# ============================================================
# CO WARNING: wrk uses a closed-loop executor. Latency results
# (p50/p99/max printed below) are subject to Coordinated Omission
# and UNDERESTIMATE tail latency under real arrival-rate pressure.
# Use run-wrk2.sh for any p99/p99.9 latency claims.
# This script is for throughput / saturation probes ONLY.
# ============================================================
wrk -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" --latency \
  ${LUA_SCRIPT:+--script "$LUA_SCRIPT"} \
  "$@" \
  "$URL" | tee "$RESULT_OUT"

echo ""
echo "Result written to: $RESULT_OUT"
echo "NOTE: co_risk=true — latency from wrk is CO-contaminated. For p99 claims use run-wrk2.sh."
