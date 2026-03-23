#!/usr/bin/env bash
# runtime/drivers/start-target.sh — Start the benchmark target application.
# Usage:
#   ./runtime/drivers/start-target.sh <target_id_or_legacy>
#
# The script resolves a deterministic runtime target contract and sources
# the target-specific env file when present.
# and starts the application via:
#   - Docker Compose (public/local)
#   - direct JVM invocation (public/local)
#   - external/private executor hook (enterprise private wiring)
set -euo pipefail

TARGET_INPUT="${1:?Usage: start-target.sh <target_id_or_legacy>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

compose_cmd() {
  if docker compose version > /dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose > /dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "ERROR: Docker Compose is unavailable. Install 'docker compose' plugin or 'docker-compose' binary." >&2
    return 127
  fi
}

# shellcheck source=/dev/null
source "$SCRIPT_DIR/target-contract-registry.sh"

resolve_target_contract "$TARGET_INPUT" || { rc=$?; exit "$rc"; }
assert_target_contract_complete || { rc=$?; exit "$rc"; }

TARGET="$TARGET_CONTRACT_TARGET_ID"
TARGET_ENV="$TARGET_CONTRACT_ENV_FILE"

if [[ -n "$TARGET_ENV" && -f "$TARGET_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$TARGET_ENV"
fi

if [[ -n "${START_MODE:-}" && "$START_MODE" != "$TARGET_CONTRACT_LAUNCHER_MODE" ]]; then
  echo "CONFIG_ERROR: START_MODE mismatch for target_id '${TARGET}': env START_MODE='${START_MODE}' contract launcher_mode='${TARGET_CONTRACT_LAUNCHER_MODE}'" >&2
  exit 64
fi

START_MODE="${START_MODE:-$TARGET_CONTRACT_LAUNCHER_MODE}"

# Expected variables from .env file:
#   START_MODE:   docker | jar | external
#   COMPOSE_FILE: path to docker-compose.yml (if START_MODE=docker)
#   JAR_PATH:     path to runnable jar          (if START_MODE=jar)
#   JVM_FLAGS:    extra JVM flags
#   EXTERNAL_START_CMD: shell command used when START_MODE=external
#   HEALTH_URL:   URL to poll for readiness
#   HEALTH_TIMEOUT_SECONDS

echo "=== Starting target: $TARGET ==="
echo "  MODE: ${START_MODE}"

TARGET_LOG_DIR="${TARGET_LOG_DIR:-/tmp/exeris-bench-logs}"
mkdir -p "$TARGET_LOG_DIR"
RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

case "${START_MODE}" in
  docker)
    COMPOSE="${COMPOSE_FILE:-$TARGET_CONTRACT_COMPOSE_FILE}"
    if [[ -z "$COMPOSE" ]]; then
      echo "CONFIG_ERROR: target_id '${TARGET}' resolved to docker launcher but compose_file is empty" >&2
      exit 64
    fi
    echo "  Compose: $COMPOSE"
    compose_cmd -f "$COMPOSE" up -d
    ;;
  jar)
    JAR_PATH="${JAR_PATH:-$TARGET_CONTRACT_JAR_PATH}"
    if [[ -z "$JAR_PATH" ]]; then
      echo "CONFIG_ERROR: target_id '${TARGET}' resolved to jar launcher but jar_path is empty" >&2
      exit 64
    fi
    echo "  JAR: $JAR_PATH"
    # JFR ring-buffer NOTE: dumponexit=true retains only the last 256m of events.
    # Early-phase GC events may be evicted. For early-phase analysis, use maxchunksize=64m.
    # See docs/methodology.md: "JFR ring-buffer early-phase loss"
    # GC log path uses /tmp (local fs) to avoid I/O overhead on network-backed CI filesystems.
    # shellcheck disable=SC2086
    java ${JVM_FLAGS:-} \
      "-Xlog:gc*,safepoint:file=${TARGET_LOG_DIR}/gc-${RUN_TIMESTAMP}.log:time,uptime,level,tags" \
      "-Xlog:safepoint:file=${TARGET_LOG_DIR}/safepoint-${RUN_TIMESTAMP}.log:time,uptime,level,tags" \
      "-XX:StartFlightRecording=filename=${TARGET_LOG_DIR}/jfr-${RUN_TIMESTAMP}.jfr,settings=profile,duration=0,maxsize=256m,dumponexit=true" \
      -jar "$JAR_PATH" &
    echo "$!" > /tmp/exeris-bench-target.pid
    echo "[launcher] GC logs: $TARGET_LOG_DIR/gc-${RUN_TIMESTAMP}.log"
    ;;
  external)
    if [[ -z "${EXTERNAL_START_CMD:-}" ]]; then
      echo "ERROR: START_MODE=external requires EXTERNAL_START_CMD" >&2
      exit 1
    fi
    echo "  External runner command: $EXTERNAL_START_CMD"
    bash -lc "$EXTERNAL_START_CMD"
    ;;
  *)
    echo "ERROR: Unknown START_MODE: $START_MODE" >&2
    exit 1
    ;;
esac

# Wait for readiness
HEALTH_URL="${HEALTH_URL:-$TARGET_CONTRACT_HEALTH_URL}"
TIMEOUT="${HEALTH_TIMEOUT_SECONDS:-60}"
echo "  Waiting for readiness: $HEALTH_URL (timeout: ${TIMEOUT}s)"

for i in $(seq 1 "$TIMEOUT"); do
  if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
    echo "  Target ready after ${i}s"
    exit 0
  fi
  sleep 1
done

echo "ERROR: Target did not become ready within ${TIMEOUT}s" >&2
exit 1
