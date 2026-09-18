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

# Prints the pid holding <port>, or nothing. MUST always succeed: this script
# runs under `set -euo pipefail`, and the happy path (port free) makes grep
# exit 1, which pipefail propagates — a bare `pid="$(_port_holder_pid ...)"`
# assignment would then abort the script on the SUCCESS path, before
# "Target stopped." is ever printed and before any verification runs.
_port_holder_pid() {
  local port="$1" out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltnp 2>/dev/null | grep ":${port} " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)"
  fi
  printf '%s' "$out"
  return 0
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

# --- Post-stop verification, second leg: the PROCESS, not just the port ------
#
# The port check above is necessary and not sufficient. Observed 2026-08-21: an
# exeris-community target answered SIGTERM by closing its listener and then did
# NOT exit. `ss` saw the port free, the sweep above passed, "Target stopped."
# was printed -- and the JVM stayed alive for the next three rungs of the
# ladder, idle but resident, holding its minimum JDBC pool open. Port released
# is not process gone, and every consequence the sweep above exists to prevent
# (co-resident memory, CPU contention, and here ~16 Postgres backends charged
# to whichever arm ran next) happened anyway under a clean report.
#
# The signature comes from the arm's OWN EXTERNAL_START_CMD, so it cannot match
# another arm: each target names a distinct jar or main class. `pgrep -f`
# matches any process whose command line contains the pattern INCLUDING this
# script and its ancestors, which carry EXTERNAL_START_CMD in their environment
# -- hence the comm=java filter and the explicit self/parent exclusion. That
# self-match has produced a false "still running" reading in this repo before.
_target_signature() {
  local cmd="${EXTERNAL_START_CMD:-}" sig=""
  sig="$(printf '%s' "$cmd" | grep -oE -- '-jar +[^ ]+' | head -1 | awk '{print $2}' || true)"
  # `-jar` also occurs in prose inside these env files (one arm's comment block
  # yielded the literal token "ADDED"), and a bogus signature is worse than none:
  # it turns the sweep into a pgrep for an arbitrary string. Require a real jar.
  if [[ "$sig" != *.jar ]]; then sig=""; fi
  if [[ -z "$sig" ]]; then
    sig="$(printf '%s' "$cmd" | grep -oE 'eu\.exeris[A-Za-z0-9_.]*' | head -1 || true)"
  fi
  printf '%s' "$sig"
  return 0
}

_survivors() {
  local sig="$1" out="" p
  if [[ -z "$sig" ]]; then printf ''; return 0; fi
  for p in $(pgrep -f -- "$sig" 2>/dev/null || true); do
    if [[ "$p" == "$$" || "$p" == "$PPID" ]]; then continue; fi
    if [[ "$(ps -p "$p" -o comm= 2>/dev/null)" != "java" ]]; then continue; fi
    out="${out}${p} "
  done
  printf '%s' "$out"
  return 0
}

if [[ "$START_MODE" == "external" || "$START_MODE" == "jar" ]]; then
  _sig="$(_target_signature)"
  if [[ -n "$_sig" ]]; then
    _surv="$(_survivors "$_sig")"
    if [[ -n "$_surv" ]]; then
      echo "WARN: target process(es) ${_surv}still alive after the stop command despite the port being released; escalating." >&2
      for _p in $_surv; do kill "$_p" 2>/dev/null || true; done
      for _ in $(seq 1 10); do
        if [[ -z "$(_survivors "$_sig")" ]]; then break; fi
        sleep 1
      done
      _surv="$(_survivors "$_sig")"
      if [[ -n "$_surv" ]]; then
        echo "WARN: ${_surv}ignored SIGTERM; sending SIGKILL." >&2
        for _p in $_surv; do kill -9 "$_p" 2>/dev/null || true; done
        sleep 2
      fi
    fi
    _surv="$(_survivors "$_sig")"
    if [[ -n "$_surv" ]]; then
      echo "ERROR: target process(es) ${_surv}survived SIGTERM and SIGKILL." >&2
      echo "ERROR: refusing to report a clean stop -- a surviving target JVM co-resides with every subsequent run and contaminates its resource and latency measurements even when it no longer serves." >&2
      exit 65
    fi
  fi
fi

echo "Target stopped."
