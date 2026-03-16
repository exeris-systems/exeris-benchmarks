#!/usr/bin/env bash
# run-community-e2e.sh — Community runtime probe runner.
#
# Uses canonical assets from this repository:
#   runtime/drivers/community-stack-launcher.sh
#   scenarios/health-probe/k6.js
#   runtime/drivers/h2load-health-h1.sh
# and stores outputs in results/raw.
#
# Usage:
#   ./scripts/run-community-e2e.sh --protocol h1 --probe k6
#   ./scripts/run-community-e2e.sh --protocol h2 --probe k6
#   ./scripts/run-community-e2e.sh --protocol h1 --probe h2load
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$ROOT/runtime/drivers/community-stack-launcher.sh"
K6_SCENARIO="$ROOT/scenarios/health-probe/k6.js"
H2LOAD_SCENARIO="$ROOT/runtime/drivers/h2load-health-h1.sh"

if [[ ! -f "$LAUNCHER" ]]; then
  echo "ERROR: launcher not found: $LAUNCHER" >&2
  exit 1
fi
if [[ ! -f "$K6_SCENARIO" ]]; then
  echo "ERROR: k6 scenario not found: $K6_SCENARIO" >&2
  exit 1
fi
if [[ ! -f "$H2LOAD_SCENARIO" ]]; then
  echo "ERROR: h2load scenario not found: $H2LOAD_SCENARIO" >&2
  exit 1
fi

PROTOCOL="h1"
PROBE="k6"
PORT="18080"
DURATION="30s"
VUS="50"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol) PROTOCOL="$2"; shift 2 ;;
    --probe)    PROBE="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --vus)      VUS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$PROTOCOL" != "h1" && "$PROTOCOL" != "h2" ]]; then
  echo "ERROR: --protocol must be h1 or h2" >&2
  exit 2
fi
if [[ "$PROBE" != "k6" && "$PROBE" != "h2load" ]]; then
  echo "ERROR: --probe must be k6 or h2load" >&2
  exit 2
fi

LAUNCHER_MODE="http"
BASE_URL="http://127.0.0.1:${PORT}"
if [[ "$PROTOCOL" == "h2" ]]; then
  LAUNCHER_MODE="h2"
fi

RESULTS_DIR="$ROOT/results/raw"
mkdir -p "$RESULTS_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
PREFIX="community-${PROTOCOL}-health-probe-${PROBE}-${TS}"

APP_LOG="$RESULTS_DIR/${PREFIX}-app.log"
PROBE_LOG="$RESULTS_DIR/${PREFIX}-probe.log"

cleanup() {
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[1/3] Starting Community launcher (mode=${LAUNCHER_MODE}, port=${PORT})"
bash "$LAUNCHER" --mode "$LAUNCHER_MODE" --port "$PORT" >"$APP_LOG" 2>&1 &
APP_PID=$!

for _ in $(seq 1 60); do
  if curl -sf "$BASE_URL/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -sf "$BASE_URL/health" >/dev/null 2>&1; then
  echo "ERROR: app did not become healthy on $BASE_URL/health" >&2
  exit 1
fi

echo "[2/3] Running probe (${PROBE})"
if [[ "$PROBE" == "k6" ]]; then
  if ! command -v k6 >/dev/null 2>&1; then
    echo "ERROR: k6 not installed" >&2
    exit 1
  fi
  BASE_URL="$BASE_URL" VUS="$VUS" DURATION="$DURATION" \
    k6 run "$K6_SCENARIO" | tee "$PROBE_LOG"
else
  PORT="$PORT" N="10000" C="100" T="4" \
    bash "$H2LOAD_SCENARIO" | tee "$PROBE_LOG"
fi

echo "[3/3] Completed"
echo "App log:   $APP_LOG"
echo "Probe log: $PROBE_LOG"
echo "Metadata to use during normalization: tier=community protocol=${PROTOCOL} comparison_axis=within-tier"
