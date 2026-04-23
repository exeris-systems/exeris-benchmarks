#!/usr/bin/env bash
# runtime/drivers/stop-target.sh — Stop the benchmark target application.
# Usage:
#   ./runtime/drivers/stop-target.sh [target_id_or_legacy]
set -euo pipefail

TARGET_INPUT="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

TARGET=""
if [[ -n "$TARGET_INPUT" ]]; then
  resolve_target_contract "$TARGET_INPUT" || { rc=$?; exit "$rc"; }
  assert_target_contract_complete || { rc=$?; exit "$rc"; }
  TARGET="$TARGET_CONTRACT_TARGET_ID"

  if [[ -n "$TARGET_CONTRACT_ENV_FILE" && -f "$TARGET_CONTRACT_ENV_FILE" ]]; then
    allexport_was_set=0
    [[ $- == *a* ]] && allexport_was_set=1
    set -a
    # shellcheck source=/dev/null
    source "$TARGET_CONTRACT_ENV_FILE"
    if [[ "$allexport_was_set" -eq 0 ]]; then
      set +a
    fi
  fi

  if [[ -n "${START_MODE:-}" && "$START_MODE" != "$TARGET_CONTRACT_LAUNCHER_MODE" ]]; then
    echo "CONFIG_ERROR: START_MODE mismatch for target_id '${TARGET}': env START_MODE='${START_MODE}' contract launcher_mode='${TARGET_CONTRACT_LAUNCHER_MODE}'" >&2
    exit 64
  fi

  START_MODE="${START_MODE:-$TARGET_CONTRACT_LAUNCHER_MODE}"
else
  START_MODE="${START_MODE:-docker}"
fi

echo "=== Stopping target: ${TARGET:-all} ==="

case "${START_MODE}" in
  docker)
    if [[ -n "$TARGET" ]]; then
      COMPOSE="${COMPOSE_FILE:-$TARGET_CONTRACT_COMPOSE_FILE}"
      if [[ -z "$COMPOSE" ]]; then
        echo "CONFIG_ERROR: target_id '${TARGET}' resolved to docker launcher but compose_file is empty" >&2
        exit 64
      fi
      if [[ -f "$COMPOSE" ]]; then
        compose_cmd --file "$COMPOSE" down --remove-orphans
      else
        echo "WARN: Resolved compose file does not exist: $COMPOSE"
      fi
    else
      # Stop all known compose stacks
      for f in "$SCRIPT_DIR"/docker-compose/*.yml; do
        [[ -e "$f" ]] || continue
        compose_cmd --file "$f" down --remove-orphans 2>/dev/null || true
      done
    fi
    ;;
  jar)
    PID_FILE="/tmp/exeris-bench-target.pid"
    if [[ -f "$PID_FILE" ]]; then
      PID="$(cat "$PID_FILE")"
      kill "$PID" 2>/dev/null && echo "Stopped PID $PID" || echo "PID $PID not running"
      rm -f "$PID_FILE"
    fi
    ;;
  external)
    if [[ -z "${EXTERNAL_STOP_CMD:-}" ]]; then
      echo "No EXTERNAL_STOP_CMD configured for START_MODE=external"
    else
      echo "Running external stop command"
      bash -lc "$EXTERNAL_STOP_CMD"
    fi
    ;;
  *)
    echo "Nothing to stop for START_MODE: ${START_MODE}"
    ;;
esac

echo "Target stopped."
