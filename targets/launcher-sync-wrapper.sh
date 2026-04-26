#!/usr/bin/env bash
set -euo pipefail

# launcher-sync-wrapper.sh — Coordinate readiness sync for two pre-launched benchmark targets.
#
# This wrapper does NOT start target processes. Targets must be launched externally.
# It manages readiness probe, output-dir setup, and measurement window coordination.
#
# Usage:
#   targets/launcher-sync-wrapper.sh \
#     --target-a-id  <id>   \
#     --target-a-port <port> \
#     --target-b-id  <id>   \
#     --target-b-port <port> \
#     --output-dir   <path>  \
#     [--health-path /health] \
#     [--sync-timeout-seconds 30]
#
# Output files in --output-dir:
#   measurement-start-timestamp.txt
#   target-a-ready-timestamp.txt
#   target-b-ready-timestamp.txt
#   sync-log.txt
#
# Exit code: 0 when both targets respond 200 OK; 1 on timeout or error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TARGET_A_ID=""
TARGET_A_PORT=""
TARGET_B_ID=""
TARGET_B_PORT=""
OUTPUT_DIR=""
HEALTH_PATH="${HEALTH_PATH:-/health}"
SYNC_TIMEOUT_SECONDS="${SYNC_TIMEOUT_SECONDS:-30}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-a-id)           TARGET_A_ID="$2";           shift 2 ;;
    --target-a-port)         TARGET_A_PORT="$2";         shift 2 ;;
    --target-b-id)           TARGET_B_ID="$2";           shift 2 ;;
    --target-b-port)         TARGET_B_PORT="$2";         shift 2 ;;
    --output-dir)            OUTPUT_DIR="$2";            shift 2 ;;
    --health-path)           HEALTH_PATH="$2";           shift 2 ;;
    --sync-timeout-seconds)  SYNC_TIMEOUT_SECONDS="$2";  shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
missing=()
[[ -z "$TARGET_A_ID"   ]] && missing+=("--target-a-id")
[[ -z "$TARGET_A_PORT" ]] && missing+=("--target-a-port")
[[ -z "$TARGET_B_ID"   ]] && missing+=("--target-b-id")
[[ -z "$TARGET_B_PORT" ]] && missing+=("--target-b-port")
[[ -z "$OUTPUT_DIR"    ]] && missing+=("--output-dir")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Required arguments missing: ${missing[*]}" >&2
  exit 1
fi

if ! [[ "$TARGET_A_PORT" =~ ^[0-9]+$ && "$TARGET_A_PORT" -ge 1 && "$TARGET_A_PORT" -le 65535 ]]; then
  echo "ERROR: --target-a-port must be a valid port number (got: $TARGET_A_PORT)" >&2
  exit 1
fi
if ! [[ "$TARGET_B_PORT" =~ ^[0-9]+$ && "$TARGET_B_PORT" -ge 1 && "$TARGET_B_PORT" -le 65535 ]]; then
  echo "ERROR: --target-b-port must be a valid port number (got: $TARGET_B_PORT)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Output directory setup
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"

SYNC_LOG="${OUTPUT_DIR}/sync-log.txt"
MEASUREMENT_START_FILE="${OUTPUT_DIR}/measurement-start-timestamp.txt"
TARGET_A_READY_FILE="${OUTPUT_DIR}/target-a-ready-timestamp.txt"
TARGET_B_READY_FILE="${OUTPUT_DIR}/target-b-ready-timestamp.txt"

ts_now() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

log_sync() {
  local msg="$1"
  local ts
  ts="$(ts_now)"
  echo "[${ts}] ${msg}" | tee -a "$SYNC_LOG"
}

echo "" > "$SYNC_LOG"
log_sync "launcher-sync-wrapper started"
log_sync "target-a: id=${TARGET_A_ID} port=${TARGET_A_PORT}"
log_sync "target-b: id=${TARGET_B_ID} port=${TARGET_B_PORT}"
log_sync "health-path: ${HEALTH_PATH}"
log_sync "sync-timeout-seconds: ${SYNC_TIMEOUT_SECONDS}"

# Write measurement start timestamp before health probing
MEASURE_START="$(ts_now)"
echo "$MEASURE_START" > "$MEASUREMENT_START_FILE"
log_sync "measurement-start-timestamp written: ${MEASURE_START}"

# ---------------------------------------------------------------------------
# Health probe helper
# ---------------------------------------------------------------------------
probe_http() {
  local port="$1"
  local path="$2"
  # Use curl if available; fall back to wget; return HTTP status code
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -w "%{http_code}" \
      --max-time 2 \
      "http://localhost:${port}${path}" 2>/dev/null || echo "000"
  elif command -v wget >/dev/null 2>&1; then
    local code
    code="$(wget -q -S --spider "http://localhost:${port}${path}" 2>&1 | grep 'HTTP/' | awk '{print $2}' | tail -1)"
    echo "${code:-000}"
  else
    echo "ERROR: Neither curl nor wget available for health probe." >&2
    exit 1
  fi
}

wait_for_ready() {
  local target_id="$1"
  local port="$2"
  local ready_file="$3"
  local deadline=$(( $(date +%s) + SYNC_TIMEOUT_SECONDS ))
  local attempts=0

  log_sync "Waiting for ${target_id} on port ${port}${HEALTH_PATH} ..."
  while true; do
    local now
    now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      log_sync "TIMEOUT: ${target_id} did not become ready within ${SYNC_TIMEOUT_SECONDS}s"
      echo -e "${RED}ERROR${NC}: Sync timeout — ${target_id} not ready after ${SYNC_TIMEOUT_SECONDS}s" >&2
      exit 1
    fi

    local http_status
    http_status="$(probe_http "$port" "$HEALTH_PATH")"
    attempts=$((attempts + 1))

    if [[ "$http_status" == "200" ]]; then
      local ready_ts
      ready_ts="$(ts_now)"
      echo "$ready_ts" > "$ready_file"
      log_sync "${target_id} READY after ${attempts} attempt(s) — ts=${ready_ts}"
      echo -e "${GREEN}✓${NC} ${target_id} ready (HTTP 200) after ${attempts} attempt(s)"
      return 0
    fi

    log_sync "${target_id} not ready (HTTP ${http_status}) — retrying in 1s"
    sleep 1
  done
}

# ---------------------------------------------------------------------------
# Health checks — target-a first, then target-b
# ---------------------------------------------------------------------------
wait_for_ready "$TARGET_A_ID" "$TARGET_A_PORT" "$TARGET_A_READY_FILE"
wait_for_ready "$TARGET_B_ID" "$TARGET_B_PORT" "$TARGET_B_READY_FILE"

log_sync "Both targets ready — measurement window may begin"
echo -e "${GREEN}✓${NC} Both targets ready. Measurement window may begin."
echo -e "  Output dir: ${OUTPUT_DIR}"
echo -e "  Sync log:   ${SYNC_LOG}"
