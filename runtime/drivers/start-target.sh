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
  allexport_was_set=0
  [[ $- == *a* ]] && allexport_was_set=1
  set -a
  # shellcheck source=/dev/null
  source "$TARGET_ENV"
  if [[ "$allexport_was_set" -eq 0 ]]; then
    set +a
  fi
fi

ENV_HEALTH_URL="${HEALTH_URL:-}"
HEALTH_URL="$TARGET_CONTRACT_HEALTH_URL"
export HEALTH_URL

if [[ -n "$ENV_HEALTH_URL" && "$ENV_HEALTH_URL" != "$TARGET_CONTRACT_HEALTH_URL" ]]; then
  echo "  NOTE: ignoring env HEALTH_URL='${ENV_HEALTH_URL}' and using resolved contract '${TARGET_CONTRACT_HEALTH_URL}'"
fi

# Auto-provision smoke TLS cert/key for HTTPS targets when cert path is not configured.
# Mirrors the cert setup used in scripts/run-primary-tls-matrix.sh and run-e2e-shop-order-saga-baseline.sh.
if [[ "${HEALTH_URL:-}" == https://* && -z "${EXERIS_TRANSPORT_CERT_PATH:-}" ]]; then
  _smoke_cert="/tmp/exeris-bench-certs/smoke-cert.pem"
  _smoke_key="/tmp/exeris-bench-certs/smoke-key.pem"
  _certs_lib="${SCRIPT_DIR}/../../tools/bench/lib/certs.sh"
  if [[ -f "$_certs_lib" ]] && command -v openssl >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_certs_lib"
    if ensure_smoke_cert_key "$_smoke_cert" "$_smoke_key"; then
      export EXERIS_TRANSPORT_CERT_PATH="$_smoke_cert"
      export EXERIS_TRANSPORT_KEY_PATH="$_smoke_key"
      echo "  [TLS] Auto-provisioned smoke cert: ${_smoke_cert}"
    else
      echo "WARNING: Failed to provision smoke TLS cert; HTTPS target may not start." >&2
    fi
  else
    echo "WARNING: HEALTH_URL is HTTPS but EXERIS_TRANSPORT_CERT_PATH is empty and openssl/certs.sh is unavailable." >&2
  fi
  unset _smoke_cert _smoke_key _certs_lib
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
    compose_cmd --file "$COMPOSE" up -d
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
    _tgt_stdout_log="${TARGET_LOG_DIR}/target-stdout-${RUN_TIMESTAMP}.log"
    
    # Java 26 module system compatibility for Neo4j driver + Eclipse Collections
    # ServiceLoader requires access to jdk.internal.module for proper service discovery.
    # See: https://github.com/neo4j-java/neo4j-java-driver/issues (Java 26 compatibility)
    _module_opens="--add-opens java.base/jdk.internal.module=ALL-UNNAMED"
    
    # shellcheck disable=SC2086
    java ${JVM_FLAGS:-} \
      "${_module_opens}" \
      "-Xlog:gc*,safepoint:file=${TARGET_LOG_DIR}/gc-${RUN_TIMESTAMP}.log:time,uptime,level,tags" \
      "-Xlog:safepoint:file=${TARGET_LOG_DIR}/safepoint-${RUN_TIMESTAMP}.log:time,uptime,level,tags" \
      "-XX:StartFlightRecording=filename=${TARGET_LOG_DIR}/jfr-${RUN_TIMESTAMP}.jfr,settings=profile,duration=0,maxsize=256m,dumponexit=true" \
      -jar "$JAR_PATH" > "$_tgt_stdout_log" 2>&1 &
    echo "$!" > /tmp/exeris-bench-target.pid
    printf '%s\n' "$_tgt_stdout_log" > /tmp/exeris-bench-target.log.path
    echo "[launcher] GC logs: $TARGET_LOG_DIR/gc-${RUN_TIMESTAMP}.log"
    echo "[launcher] stdout log: $_tgt_stdout_log"
    ;;
  external)
    if [[ -z "${EXTERNAL_START_CMD:-}" ]]; then
      echo "ERROR: START_MODE=external requires EXTERNAL_START_CMD" >&2
      exit 1
    fi
    if [[ -n "${EXTERNAL_STOP_CMD:-}" ]]; then
      echo "  Attempting best-effort stale external cleanup"
      bash -lc "cd '$ROOT' && $EXTERNAL_STOP_CMD" || true
    fi
    echo "  External runner command: $EXTERNAL_START_CMD"
    # Java 26 module system compatibility for Neo4j driver + Eclipse Collections
    # Add --add-opens flag to EXERIS_JAVA_OPTS so it's used by EXTERNAL_START_CMD
    export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS:-} --add-opens java.base/jdk.internal.module=ALL-UNNAMED"
    bash -lc "cd '$ROOT' && $EXTERNAL_START_CMD"
    ;;
  *)
    echo "ERROR: Unknown START_MODE: $START_MODE" >&2
    exit 1
    ;;
esac

# Wait for readiness
TIMEOUT="${HEALTH_TIMEOUT_SECONDS:-60}"
echo "  Waiting for readiness: $HEALTH_URL (timeout: ${TIMEOUT}s)"

deadline=$(( $(date +%s) + TIMEOUT ))
last_dot=0
while true; do
  now=$(date +%s)
  if curl -sfk --connect-timeout 3 --max-time 8 "$HEALTH_URL" > /dev/null 2>&1; then
    elapsed=$(( now - (deadline - TIMEOUT) ))
    echo "  Target ready after ${elapsed}s"
    exit 0
  fi
  if (( now >= deadline )); then
    break
  fi
  if (( now - last_dot >= 10 )); then
    remaining=$(( deadline - now ))
    printf '  Still waiting... (%ds remaining)\n' "$remaining"
    last_dot=$now
  fi
  sleep 1
done

echo "ERROR: Target did not become ready within ${TIMEOUT}s" >&2
exit 1
