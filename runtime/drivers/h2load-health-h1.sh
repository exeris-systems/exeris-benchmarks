#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
N="${N:-10000}"
C="${C:-100}"
T="${T:-4}"

fail() {
  echo "[h2load-health] ERROR: $*" >&2
  exit 1
}

command -v h2load >/dev/null 2>&1 || fail "Missing required command: h2load"

TARGET="http://${HOST}:${PORT}/health"

echo "[h2load-health] target=${TARGET} n=${N} c=${C} t=${T}"
exec h2load --h1 -H "Connection: close" -n "$N" -c "$C" -t "$T" "$TARGET"
