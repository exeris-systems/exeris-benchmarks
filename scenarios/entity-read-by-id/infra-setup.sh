#!/usr/bin/env bash
# scenarios/entity-read-by-id/infra-setup.sh
# Scenario infrastructure hook called by run-comparative.sh Stage 3.
# Starts the benchmark PostgreSQL container, applies seed, verifies.
# Idempotent: safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

COMPOSE_FILE="${REPO_ROOT}/runtime/compose/entity-read-by-id-db.yml"
SEED_APPLY_SCRIPT="${REPO_ROOT}/runtime/db/seed/seed-apply.sh"
VERIFY_SCRIPT="${REPO_ROOT}/scenarios/entity-read-by-id/seed/verify-seed.sh"
CAPTURE_DB_DIAGNOSTICS_SCRIPT="${REPO_ROOT}/scenarios/entity-read-by-id/capture-db-diagnostics.sh"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-benchmark_db}"
PGUSER="${PGUSER:-benchmark}"
PGPASSWORD="${PGPASSWORD:-benchmark}"
SEED_APPLY_RETRIES="${SEED_APPLY_RETRIES:-6}"
SEED_RETRY_SLEEP_SECONDS="${SEED_RETRY_SLEEP_SECONDS:-3}"
EXPECTED_PG_MAX_CONNECTIONS="${EXPECTED_PG_MAX_CONNECTIONS:-300}"
EXPECTED_PG_SHARED_BUFFERS="${EXPECTED_PG_SHARED_BUFFERS:-256MB}"
EXPECTED_PG_WORK_MEM="${EXPECTED_PG_WORK_MEM:-8MB}"
export PGPASSWORD

DB_CONTAINER_NAME="exeris-benchmark-db"

managed_container_exists() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps -a \
    --filter "name=^/${DB_CONTAINER_NAME}$" \
    --format '{{.Names}}' | grep -qx "$DB_CONTAINER_NAME"
}

managed_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps \
    --filter "name=^/${DB_CONTAINER_NAME}$" \
    --filter "status=running" \
    --format '{{.Names}}' | grep -qx "$DB_CONTAINER_NAME"
}

use_managed_container_db() {
  managed_container_running
}

run_managed_psql() {
  docker exec -i "$DB_CONTAINER_NAME" \
    env PGPASSWORD="$PGPASSWORD" \
    psql -U "$PGUSER" -d "$PGDATABASE" "$@"
}

run_host_psql() {
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

run_managed_seed_sql() {
  DB_CONTAINER_NAME="$DB_CONTAINER_NAME" \
  PGUSER="$PGUSER" PGDATABASE="$PGDATABASE" PGPASSWORD="$PGPASSWORD" \
  bash "$SEED_APPLY_SCRIPT"
}

run_host_seed_sql() {
  PGHOST="$PGHOST" PGPORT="$PGPORT" PGUSER="$PGUSER" \
  PGDATABASE="$PGDATABASE" PGPASSWORD="$PGPASSWORD" \
  bash "$SEED_APPLY_SCRIPT"
}

terminate_managed_db_client_backends() {
  # Best-effort cleanup of all non-self sessions for the benchmark DB in managed PostgreSQL.
  # Use container superuser context so this works even when benchmark user cannot terminate peers.
  if ! managed_container_running; then
    echo "  [infra] Managed DB container is not running; skipping backend termination." >&2
    return 0
  fi

  echo "  [infra] Terminating managed DB client backends for database '${PGDATABASE}'..." >&2
  if ! docker exec -u postgres -i "$DB_CONTAINER_NAME" \
    psql -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${PGDATABASE}' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1; then
    echo "  [infra] Backend termination attempt failed (best-effort)." >&2
  fi
}

is_connection_slot_exhaustion_error() {
  local err_output="$1"
  grep -Eqi "too many clients already|remaining connection slots are reserved|connection slots" <<<"$err_output"
}

restart_managed_container_for_slot_recovery() {
  # Best-effort restart path for persistent connection-slot exhaustion in managed DB mode.
  if ! managed_container_running; then
    echo "  [infra] Managed DB container is not running; skipping restart-based slot recovery." >&2
    return 1
  fi

  echo "  [infra] Restarting managed DB container for slot recovery..." >&2
  if [[ "$COMPOSE_AVAILABLE" -eq 1 ]]; then
    if ! $DOCKER_COMPOSE -f "$COMPOSE_FILE" restart benchmark-db >/dev/null 2>&1; then
      echo "  [infra] Compose restart failed during slot recovery (best-effort)." >&2
      return 1
    fi
  else
    if ! docker restart "$DB_CONTAINER_NAME" >/dev/null 2>&1; then
      echo "  [infra] Docker restart failed during slot recovery (best-effort)." >&2
      return 1
    fi
  fi

  if wait_for_db_ready 30; then
    echo "  [infra] Managed DB ready after slot-recovery restart." >&2
    return 0
  fi

  echo "  [infra] Managed DB did not become ready within 30s after slot-recovery restart (best-effort)." >&2
  return 1
}

container_health_status() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$DB_CONTAINER_NAME" 2>/dev/null || echo "unknown"
}

container_running_status() {
  docker inspect -f '{{.State.Status}}' "$DB_CONTAINER_NAME" 2>/dev/null || echo "unknown"
}

wait_for_db_ready() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if use_managed_container_db; then
      if docker exec "$DB_CONTAINER_NAME" \
        env PGPASSWORD="$PGPASSWORD" \
        pg_isready -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; then
        return 0
      fi
    elif command -v psql >/dev/null 2>&1; then
      if run_host_psql -c "SELECT 1" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 2
  done

  return 1
}

start_or_create_managed_container() {
  if [[ "$COMPOSE_AVAILABLE" -eq 1 ]]; then
    echo "  [infra] Starting benchmark DB..."
    $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "WARNING: Docker CLI not found; using existing PostgreSQL endpoint at ${PGHOST}:${PGPORT}." >&2
    echo "  [infra] Skipping benchmark DB startup (compose unavailable)."
    return 0
  fi

  if managed_container_running; then
    echo "  [infra] Benchmark DB container already running (${DB_CONTAINER_NAME})."
  elif managed_container_exists; then
    echo "  [infra] Starting existing benchmark DB container (${DB_CONTAINER_NAME})..."
    docker start "$DB_CONTAINER_NAME" >/dev/null
  else
    echo "  [infra] Creating benchmark DB container (${DB_CONTAINER_NAME})..."
    docker run -d \
      --name "$DB_CONTAINER_NAME" \
      -e POSTGRES_DB=benchmark_db \
      -e POSTGRES_USER=benchmark \
      -e POSTGRES_PASSWORD=benchmark \
      -p 5432:5432 \
      -v "${REPO_ROOT}/runtime/compose/entity-read-by-id-init.sql:/docker-entrypoint-initdb.d/01-pg-stat-statements-init.sql" \
      postgres:16.2 \
      -c "max_connections=${EXPECTED_PG_MAX_CONNECTIONS}" \
      -c "shared_buffers=${EXPECTED_PG_SHARED_BUFFERS}" \
      -c "work_mem=${EXPECTED_PG_WORK_MEM}" \
      -c "shared_preload_libraries=pg_stat_statements" >/dev/null
  fi
}

heal_managed_container_once() {
  local state health

  if ! managed_container_exists; then
    echo "  [infra] Managed DB container ${DB_CONTAINER_NAME} is missing; recreating once..."
    start_or_create_managed_container
    return 0
  fi

  state="$(container_running_status)"
  health="$(container_health_status)"
  echo "  [infra] Managed DB container not ready after initial wait; state=${state} health=${health}. Attempting one recovery..."

  if [[ "$COMPOSE_AVAILABLE" -eq 1 ]]; then
    if ! $DOCKER_COMPOSE -f "$COMPOSE_FILE" restart benchmark-db >/dev/null 2>&1; then
      echo "  [infra] Compose restart failed; forcing one container recreate..."
      $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d --force-recreate benchmark-db >/dev/null
    fi
    return 0
  fi

  if managed_container_running; then
    if ! docker restart "$DB_CONTAINER_NAME" >/dev/null; then
      echo "  [infra] Docker restart failed; recreating managed DB container once..."
      docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
      start_or_create_managed_container
    fi
  else
    echo "  [infra] Managed DB container is not running; recreating once..."
    docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
    start_or_create_managed_container
  fi
}

# Detect docker compose invocation style
if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
  COMPOSE_AVAILABLE=1
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
  COMPOSE_AVAILABLE=1
else
  DOCKER_COMPOSE=""
  COMPOSE_AVAILABLE=0
  echo "WARNING: Neither 'docker compose' plugin nor 'docker-compose' found; using existing PostgreSQL endpoint at ${PGHOST}:${PGPORT}." >&2
fi

# Helper: use managed container first when it is running; otherwise fall back to host psql.
run_psql() {
  if use_managed_container_db; then
    run_managed_psql "$@"
  elif command -v psql >/dev/null 2>&1; then
    run_host_psql "$@"
  else
    echo "ERROR: Could not run psql: managed container is not running and host psql is unavailable." >&2
    exit 1
  fi
}

read_pg_runtime_settings() {
  local max_connections shared_buffers work_mem

  max_connections="$(run_psql -Atqc "SHOW max_connections;")"
  shared_buffers="$(run_psql -Atqc "SHOW shared_buffers;")"
  work_mem="$(run_psql -Atqc "SHOW work_mem;")"

  printf '%s|%s|%s\n' "$max_connections" "$shared_buffers" "$work_mem"
}

normalize_pg_memory_to_bytes() {
  local setting_value="$1"
  run_psql -Atqc "SELECT pg_size_bytes('${setting_value}')::bigint;"
}

reconcile_managed_db_settings_once() {
  if [[ "$COMPOSE_AVAILABLE" -eq 1 ]]; then
    echo "  [infra] Recreating managed benchmark DB once to enforce launch flags..."
    $DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d --force-recreate benchmark-db >/dev/null
    return 0
  fi

  echo "  [infra] Recreating managed benchmark DB container once to enforce launch flags..."
  docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
  start_or_create_managed_container
}

assert_expected_pg_runtime_settings() {
  local settings_line actual_max actual_shared actual_work actual_spl=""
  local actual_shared_bytes actual_work_bytes expected_shared_bytes expected_work_bytes
  local mismatch=0

  settings_line="$(read_pg_runtime_settings)"
  IFS='|' read -r actual_max actual_shared actual_work <<<"$settings_line"

  actual_shared_bytes="$(normalize_pg_memory_to_bytes "$actual_shared")"
  actual_work_bytes="$(normalize_pg_memory_to_bytes "$actual_work")"
  expected_shared_bytes="$(normalize_pg_memory_to_bytes "$EXPECTED_PG_SHARED_BUFFERS")"
  expected_work_bytes="$(normalize_pg_memory_to_bytes "$EXPECTED_PG_WORK_MEM")"

  if [[ "$actual_max" != "$EXPECTED_PG_MAX_CONNECTIONS" ]]; then
    mismatch=1
  fi
  if [[ "$actual_shared_bytes" != "$expected_shared_bytes" ]]; then
    mismatch=1
  fi
  if [[ "$actual_work_bytes" != "$expected_work_bytes" ]]; then
    mismatch=1
  fi

  if use_managed_container_db; then
    actual_spl="$(run_psql -Atqc "SHOW shared_preload_libraries;" 2>/dev/null || echo "")"
    if ! echo "$actual_spl" | grep -q 'pg_stat_statements'; then
      echo "  [infra] shared_preload_libraries does not include pg_stat_statements (actual: '${actual_spl}'); will reconcile." >&2
      mismatch=1
    fi
  fi

  if [[ "$mismatch" -eq 0 ]]; then
    echo "  [infra] PostgreSQL runtime settings verified (max_connections=${actual_max}, shared_buffers=${actual_shared}, work_mem=${actual_work})."
    return 0
  fi

  if use_managed_container_db; then
    echo "  [infra] PostgreSQL settings mismatch detected in managed DB mode; attempting one reconcile..."
    reconcile_managed_db_settings_once
    echo "  [infra] Waiting for DB readiness after reconcile..."
    if ! wait_for_db_ready 60; then
      echo "ERROR: Managed DB was not ready after settings reconcile attempt." >&2
      exit 1
    fi

    settings_line="$(read_pg_runtime_settings)"
    IFS='|' read -r actual_max actual_shared actual_work <<<"$settings_line"
    actual_shared_bytes="$(normalize_pg_memory_to_bytes "$actual_shared")"
    actual_work_bytes="$(normalize_pg_memory_to_bytes "$actual_work")"

    mismatch=0
    if [[ "$actual_max" != "$EXPECTED_PG_MAX_CONNECTIONS" ]]; then
      mismatch=1
    fi
    if [[ "$actual_shared_bytes" != "$expected_shared_bytes" ]]; then
      mismatch=1
    fi
    if [[ "$actual_work_bytes" != "$expected_work_bytes" ]]; then
      mismatch=1
    fi
    actual_spl="$(run_psql -Atqc "SHOW shared_preload_libraries;" 2>/dev/null || echo "")"
    if ! echo "$actual_spl" | grep -q 'pg_stat_statements'; then
      mismatch=1
    fi

    if [[ "$mismatch" -eq 0 ]]; then
      echo "  [infra] PostgreSQL runtime settings verified after reconcile (max_connections=${actual_max}, shared_buffers=${actual_shared}, work_mem=${actual_work})."
      return 0
    fi

    echo "ERROR: PostgreSQL runtime settings mismatch after one reconcile attempt. Expected: max_connections=${EXPECTED_PG_MAX_CONNECTIONS}, shared_buffers=${EXPECTED_PG_SHARED_BUFFERS}, work_mem=${EXPECTED_PG_WORK_MEM}, shared_preload_libraries contains pg_stat_statements. Actual: max_connections=${actual_max}, shared_buffers=${actual_shared}, work_mem=${actual_work}, shared_preload_libraries='${actual_spl}'." >&2
    exit 1
  fi

  echo "ERROR: PostgreSQL runtime settings mismatch on host DB endpoint ${PGHOST}:${PGPORT}. Expected: max_connections=${EXPECTED_PG_MAX_CONNECTIONS}, shared_buffers=${EXPECTED_PG_SHARED_BUFFERS}, work_mem=${EXPECTED_PG_WORK_MEM}. Actual: max_connections=${actual_max}, shared_buffers=${actual_shared}, work_mem=${actual_work}. Refusing to continue with non-equivalent DB config." >&2
  exit 1
}

apply_seed_sql_with_retry() {
  local attempt=1
  local err_file err_output

  while (( attempt <= SEED_APPLY_RETRIES )); do
    err_file="$(mktemp)"

    if use_managed_container_db; then
      if run_managed_seed_sql 2>"$err_file"; then
        rm -f "$err_file"
        return 0
      fi
    elif command -v psql >/dev/null 2>&1; then
      if run_host_seed_sql 2>"$err_file"; then
        rm -f "$err_file"
        return 0
      fi
    else
      rm -f "$err_file"
      echo "ERROR: Could not apply seed SQL: managed container is not running and host psql is unavailable." >&2
      return 1
    fi

    err_output="$(cat "$err_file")"
    rm -f "$err_file"

    if is_connection_slot_exhaustion_error "$err_output"; then
      echo "  [infra] Seed apply attempt ${attempt}/${SEED_APPLY_RETRIES} failed: PostgreSQL connection slots exhausted. Retrying..." >&2
      if use_managed_container_db; then
        terminate_managed_db_client_backends
        if (( attempt >= 2 )); then
          restart_managed_container_for_slot_recovery || true
        fi
      fi
      sleep "$SEED_RETRY_SLEEP_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi

    echo "$err_output" >&2
    return 1
  done

  echo "ERROR: Seed SQL apply failed after ${SEED_APPLY_RETRIES} attempts due to PostgreSQL connection-slot exhaustion." >&2
  return 1
}

# 1. Start DB container (idempotent)
start_or_create_managed_container

# 2. Wait for DB readiness (up to 60s)
echo "  [infra] Waiting for DB readiness..."
ready=0
if wait_for_db_ready 60; then
  ready=1
elif use_managed_container_db; then
  heal_managed_container_once
  if wait_for_db_ready 60; then
    ready=1
  fi
fi

if [[ "$ready" -ne 1 ]]; then
  if use_managed_container_db; then
    echo "ERROR: Managed DB container ${DB_CONTAINER_NAME} was still not ready after initial wait and one recovery attempt." >&2
  else
    echo "ERROR: DB not ready after 60s using PostgreSQL endpoint ${PGHOST}:${PGPORT}." >&2
  fi
  exit 1
fi
echo "  [infra] DB ready."

# 3. Verify required PostgreSQL runtime settings before seed apply.
assert_expected_pg_runtime_settings

# 4. Apply seed SQL (idempotent via ON CONFLICT UPDATE)
echo "  [infra] Applying seed SQL (idempotent)..."
apply_seed_sql_with_retry

# 5. Verify seed
echo "  [infra] Verifying seed..."
PGPASSWORD="$PGPASSWORD" bash "$VERIFY_SCRIPT"

echo "  [infra] Capturing PostgreSQL diagnostics..."
PGHOST="$PGHOST" \
PGPORT="$PGPORT" \
PGDATABASE="$PGDATABASE" \
PGUSER="$PGUSER" \
PGPASSWORD="$PGPASSWORD" \
BENCH_SCENARIO_DIAGNOSTICS_DIR="${BENCH_SCENARIO_DIAGNOSTICS_DIR:-}" \
BENCH_CAPTURE_DB_EXPLAIN="${BENCH_CAPTURE_DB_EXPLAIN:-0}" \
bash "$CAPTURE_DB_DIAGNOSTICS_SCRIPT"