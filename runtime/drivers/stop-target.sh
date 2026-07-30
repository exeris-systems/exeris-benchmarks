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
        echo "CONFIG_ERROR: Resolved compose file does not exist: $COMPOSE" >&2
        exit 64
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
      echo "CONFIG_ERROR: EXTERNAL_STOP_CMD is required for START_MODE=external" >&2
      exit 64
    else
      echo "Running external stop command"
      bash -lc "$EXTERNAL_STOP_CMD"
    fi
    ;;
  *)
    echo "Nothing to stop for START_MODE: ${START_MODE}"
    ;;
esac

# --- Post-stop verification -------------------------------------------------
#
# EXTERNAL_STOP_CMD kills the PID recorded by `echo $!` at start, swallows the
# result with `|| true`, and removes the pid file. When `$!` captured a wrapper
# or a since-dead retry rather than the JVM (observed: the recorded pid was
# dead while the real JVM was still serving), the stop is a silent no-op and
# the target keeps running. A leaked JVM then co-resides with every subsequent
# rep — memory pressure and CPU contention that silently contaminates the
# results rather than failing them. So do not trust the stop command: verify
# the target's declared port is actually released, escalate if not, and fail
# closed if it survives.
#
# The port comes from the target's OWN env file (HEALTH_URL), not from the
# asset matrix, so a stale matrix entry cannot misdirect the check. Override
# with BENCH_STOP_VERIFY_URL when the runner reassigned the port.
_stop_verify_url="${BENCH_STOP_VERIFY_URL:-${HEALTH_URL:-}}"
_stop_verify_port=""
if [[ "$_stop_verify_url" =~ :([0-9]+)(/|$) ]]; then
  _stop_verify_port="${BASH_REMATCH[1]}"
fi

_port_holder_pid() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnp 2>/dev/null | grep ":${port} " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

if [[ "$START_MODE" == "external" || "$START_MODE" == "jar" ]] && [[ -n "$_stop_verify_port" ]]; then
  for _ in $(seq 1 10); do
    [[ -z "$(_port_holder_pid "$_stop_verify_port")" ]] && break
    sleep 1
  done

  _leaked_pid="$(_port_holder_pid "$_stop_verify_port")"
  if [[ -n "$_leaked_pid" ]]; then
    echo "WARN: port ${_stop_verify_port} still held by pid ${_leaked_pid} after the stop command; the recorded pid did not match the live process. Escalating." >&2
    kill "$_leaked_pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
      [[ -z "$(_port_holder_pid "$_stop_verify_port")" ]] && break
      sleep 1
    done
    _leaked_pid="$(_port_holder_pid "$_stop_verify_port")"
    if [[ -n "$_leaked_pid" ]]; then
      echo "WARN: pid ${_leaked_pid} ignored SIGTERM on port ${_stop_verify_port}; sending SIGKILL." >&2
      kill -9 "$_leaked_pid" 2>/dev/null || true
      sleep 3
    fi
  fi

  _leaked_pid="$(_port_holder_pid "$_stop_verify_port")"
  if [[ -n "$_leaked_pid" ]]; then
    echo "ERROR: target port ${_stop_verify_port} is STILL held by pid ${_leaked_pid} after SIGTERM and SIGKILL." >&2
    echo "ERROR: refusing to report a clean stop — a surviving target JVM co-resides with every subsequent run and contaminates its resource and latency measurements." >&2
    exit 65
  fi
fi

echo "Target stopped."
