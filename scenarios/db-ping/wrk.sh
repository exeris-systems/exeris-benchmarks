#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-18080}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-20s}"
TIMEOUT="${TIMEOUT:-2s}"

fail() {
  echo "[wrk-db-ping] ERROR: $*" >&2
  exit 1
}

command -v wrk >/dev/null 2>&1 || fail "Missing required command: wrk"

TARGET="http://${HOST}:${PORT}/db/ping"

echo "[wrk-db-ping] target=${TARGET} threads=${THREADS} connections=${CONNECTIONS} duration=${DURATION}"
exec wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --timeout "$TIMEOUT" "$TARGET"
