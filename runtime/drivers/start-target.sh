#!/usr/bin/env bash
# runtime/drivers/start-target.sh — Start the benchmark target application.
# Usage:
#   ./runtime/drivers/start-target.sh <target>
#   target: community | enterprise | spring-runtime
#
# The script sources a target-specific env file from targets/<target>/
# and starts the application via:
#   - Docker Compose (public/local)
#   - direct JVM invocation (public/local)
#   - external/private executor hook (enterprise private wiring)
set -euo pipefail

TARGET="${1:?Usage: start-target.sh <community|enterprise|spring-runtime>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
ENV_DIR="$SCRIPT_DIR/env"

TARGET_ENV="$ENV_DIR/${TARGET}.env"
if [[ ! -f "$TARGET_ENV" ]]; then
  echo "ERROR: Target env not found: $TARGET_ENV" >&2
  echo "       Create it from $ENV_DIR/template.env" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$TARGET_ENV"
# Expected variables from .env file:
#   START_MODE:   docker | jar | external
#   COMPOSE_FILE: path to docker-compose.yml (if START_MODE=docker)
#   JAR_PATH:     path to runnable jar          (if START_MODE=jar)
#   JVM_FLAGS:    extra JVM flags
#   EXTERNAL_START_CMD: shell command used when START_MODE=external
#   HEALTH_URL:   URL to poll for readiness
#   HEALTH_TIMEOUT_SECONDS

echo "=== Starting target: $TARGET ==="
echo "  MODE: ${START_MODE:-docker}"

case "${START_MODE:-docker}" in
  docker)
    COMPOSE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose/${TARGET}.yml}"
    echo "  Compose: $COMPOSE"
    docker compose -f "$COMPOSE" up -d
    ;;
  jar)
    echo "  JAR: $JAR_PATH"
    # shellcheck disable=SC2086
    java ${JVM_FLAGS:-} -jar "$JAR_PATH" &
    echo "$!" > /tmp/exeris-bench-target.pid
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
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"
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
