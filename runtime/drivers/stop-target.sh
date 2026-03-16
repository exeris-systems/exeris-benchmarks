#!/usr/bin/env bash
# runtime/drivers/stop-target.sh — Stop the benchmark target application.
# Usage:
#   ./runtime/drivers/stop-target.sh [target]
set -euo pipefail

TARGET="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/env"

if [[ -n "$TARGET" && -f "$ENV_DIR/${TARGET}.env" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_DIR/${TARGET}.env"
fi

echo "=== Stopping target: ${TARGET:-all} ==="

case "${START_MODE:-docker}" in
  docker)
    COMPOSE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose/${TARGET:-community}.yml}"
    if [[ -f "$COMPOSE" ]]; then
      docker compose -f "$COMPOSE" down --remove-orphans
    else
      # Stop all known compose stacks
      for f in "$SCRIPT_DIR"/docker-compose/*.yml; do
        docker compose -f "$f" down --remove-orphans 2>/dev/null || true
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
    echo "Nothing to stop for START_MODE: ${START_MODE:-unknown}"
    ;;
esac

echo "Target stopped."
