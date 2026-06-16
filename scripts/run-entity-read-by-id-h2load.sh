#!/usr/bin/env bash
set -euo pipefail

# run-entity-read-by-id-h2load.sh
# Orchestrates the entity-read-by-id benchmark via h2load.
#
# Usage:
#   scripts/run-entity-read-by-id-h2load.sh [options]
#
#   --axis h1|h2c                H1 (--h1 flag, loopback-h1) or H2c prior-knowledge (loopback-h2c) [default: h1]
#   --claim-scope exploratory    exploratory only for this driver [default: exploratory]
#   --profile dev-laptop|perf-box-amd64   hardware profile [default: dev-laptop]
#   --output-dir PATH            [default: results/raw/entity-read-by-id/<timestamp>-h2load]
#   --threads INT                h2load -t [default: 4]
#   --connections INT            h2load -c [default: 128]
#   --max-concurrent-streams INT h2load -m [default: 1 for h1, 10 for h2c]
#   --warmup-seconds INT         warmup duration [default: 60]
#   --duration-seconds INT       measurement duration [default: 120]
#   --target-runtime community|spring|quarkus  [default: community]
#   --target-build jvm|native    [default: jvm]
#
# Steps:
#   1. Validate args
#   2. Start DB (Docker Compose)
#   3. Apply seed
#   4. Verify seed
#   5. Capture env
#   6. Start target app + readiness check
#   7. Warmup (h2load, discarded)
#   8. Measure (h2load)
#   9. Write result + reproducibility artifacts
#  10. Schema-validate result

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
READINESS_LIB="${REPO_ROOT}/tools/bench/lib/readiness.sh"
if [[ ! -f "$READINESS_LIB" ]]; then
  echo "ERROR: readiness library not found: $READINESS_LIB"
  exit 1
fi
# shellcheck source=/dev/null
source "$READINESS_LIB"

AXIS="${AXIS:-h1}"
CLAIM_SCOPE="exploratory"
RESULT_CLAIM_SCOPE="exploratory"
EXECUTION_CLASS="exploratory"
PROFILE="${PROFILE:-dev-laptop}"
OUTPUT_DIR="${OUTPUT_DIR:-results/raw/entity-read-by-id/$(date +%Y%m%d-%H%M%S)-h2load}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
MAX_CONCURRENT_STREAMS=""
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
DURATION_SECONDS="${DURATION_SECONDS:-120}"
TARGET_RUNTIME="${TARGET_RUNTIME:-community}"
TARGET_BUILD="${TARGET_BUILD:-jvm}"
SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-0}"
ALLOW_EXTERNAL_DB="${BENCHMARK_ALLOW_EXTERNAL_DB:-0}"
ALLOW_EXTERNAL_TARGET="${BENCHMARK_ALLOW_EXTERNAL_TARGET:-0}"
EXERIS_DB_POOL_MIN_SIZE="${EXERIS_DB_POOL_MIN_SIZE:-16}"
EXERIS_DB_POOL_MAX_SIZE="${EXERIS_DB_POOL_MAX_SIZE:-256}"
ENTITY_READ_PREFLIGHT_TIMEOUT="${ENTITY_READ_PREFLIGHT_TIMEOUT:-60}"
TARGET_PORT="${BENCHMARK_TARGET_PORT:-8080}"

BASE_URL="${BASE_URL:-http://localhost:${TARGET_PORT}}"
SCENARIO_DIR="scenarios/entity-read-by-id"
DB_COMPOSE_FILE="runtime/compose/entity-read-by-id-db.yml"
DB_INIT_SQL_FILE="${REPO_ROOT}/runtime/compose/entity-read-by-id-init.sql"
DB_PORT="${DB_PORT:-5432}"
DB_CONTAINER_NAME="exeris-benchmark-db"
DB_MANAGED=0
DB_LAUNCH_MODE=""
COMPOSE_BIN=""

TARGET_MODULE_POM_COMMUNITY="targets/exeris-community-app/pom.xml"
TARGET_JAR_GLOB_COMMUNITY="targets/exeris-community-app/target/exeris-community-app-*.jar"
TARGET_NATIVE_BIN_GLOB_COMMUNITY="targets/exeris-community-app/target/exeris-community-app"
TARGET_APP_NAME_COMMUNITY="exeris-community-app"
TARGET_MODULE_POM_SPRING="targets/spring-benchmark-app/pom.xml"
TARGET_JAR_GLOB_SPRING="targets/spring-benchmark-app/target/spring-benchmark-app-*.jar"
TARGET_NATIVE_BIN_GLOB_SPRING="targets/spring-benchmark-app/target/spring-benchmark-app"
TARGET_APP_NAME_SPRING="spring-benchmark-app"
TARGET_MODULE_POM_QUARKUS="targets/quarkus-benchmark-app/pom.xml"
TARGET_JAR_GLOB_QUARKUS="targets/quarkus-benchmark-app/target/quarkus-benchmark-app-*-runner.jar"
TARGET_NATIVE_BIN_GLOB_QUARKUS="targets/quarkus-benchmark-app/target/quarkus-benchmark-app-*-runner"
TARGET_APP_NAME_QUARKUS="quarkus-benchmark-app"

TARGET_MODULE_POM="$TARGET_MODULE_POM_COMMUNITY"
TARGET_JAR_GLOB="$TARGET_JAR_GLOB_COMMUNITY"
TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_COMMUNITY"
TARGET_APP_NAME="$TARGET_APP_NAME_COMMUNITY"
TARGET_RUNTIME_EFFECTIVE="community"
TARGET_APP_LOG=""
TARGET_APP_PID=""
TARGET_APP_STARTED=0
TARGET_PID_FILE=""

require_positive_int() {
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    echo "ERROR: $name must be a positive integer (got: $value)" >&2
    exit 1
  fi
}

usage() {
  sed -n '3,22p' "$0" | sed 's/^# //' | sed 's/^#//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --axis)              AXIS="$2";                      shift 2 ;;
    --claim-scope)       CLAIM_SCOPE="$2";               shift 2 ;;
    --profile)           PROFILE="$2";                   shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";                shift 2 ;;
    --threads)           THREADS="$2";                   shift 2 ;;
    --connections)       CONNECTIONS="$2";               shift 2 ;;
    --max-concurrent-streams) MAX_CONCURRENT_STREAMS="$2"; shift 2 ;;
    --warmup-seconds)    WARMUP_SECONDS="$2";            shift 2 ;;
    --duration-seconds)  DURATION_SECONDS="$2";          shift 2 ;;
    --target-runtime)    TARGET_RUNTIME="$2";            shift 2 ;;
    --target-build)      TARGET_BUILD="$2";              shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Validate axis
case "$AXIS" in
  h1|h2c) ;;
  *)
    echo "ERROR: --axis must be h1 or h2c (got: $AXIS)" >&2
    exit 1
    ;;
esac

# Set default max-concurrent-streams per axis
if [[ -z "$MAX_CONCURRENT_STREAMS" ]]; then
  if [[ "$AXIS" == "h1" ]]; then
    MAX_CONCURRENT_STREAMS=1
  else
    MAX_CONCURRENT_STREAMS=10
  fi
fi

# Derive transport_mode and contract
if [[ "$AXIS" == "h1" ]]; then
  TRANSPORT_MODE="loopback-h1"
  CONTRACT_ID="fixed_contract_h1_h2load_exploratory_v1"
  BENCHMARK_FAMILY="runtime-h2load"
  H2LOAD_AXIS_FLAG="--h1"
else
  TRANSPORT_MODE="loopback-h2c"
  CONTRACT_ID="fixed_contract_h2c_h2load_exploratory_v1"
  BENCHMARK_FAMILY="runtime-h2load"
  H2LOAD_AXIS_FLAG=""
fi

# claim-scope: only exploratory supported
if [[ "$CLAIM_SCOPE" != "exploratory" ]]; then
  echo "ERROR: h2load runner only supports --claim-scope exploratory (got: $CLAIM_SCOPE)" >&2
  echo "       H1 and H2c results have different multiplexing semantics and are not" >&2
  echo "       comparison-eligible with wrk H1 results without explicit caveats." >&2
  exit 1
fi

# Validate target-runtime
case "$TARGET_RUNTIME" in
  community)
    TARGET_MODULE_POM="$TARGET_MODULE_POM_COMMUNITY"
    TARGET_JAR_GLOB="$TARGET_JAR_GLOB_COMMUNITY"
    TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_COMMUNITY"
    TARGET_APP_NAME="$TARGET_APP_NAME_COMMUNITY"
    TARGET_RUNTIME_EFFECTIVE="community"
    ;;
  spring)
    TARGET_MODULE_POM="$TARGET_MODULE_POM_SPRING"
    TARGET_JAR_GLOB="$TARGET_JAR_GLOB_SPRING"
    TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_SPRING"
    TARGET_APP_NAME="$TARGET_APP_NAME_SPRING"
    TARGET_RUNTIME_EFFECTIVE="spring"
    ;;
  quarkus)
    TARGET_MODULE_POM="$TARGET_MODULE_POM_QUARKUS"
    TARGET_JAR_GLOB="$TARGET_JAR_GLOB_QUARKUS"
    TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_QUARKUS"
    TARGET_APP_NAME="$TARGET_APP_NAME_QUARKUS"
    TARGET_RUNTIME_EFFECTIVE="quarkus"
    ;;
  spring-runtime-on-exeris)
    # targets/exeris-spring-runtime-app-comp (Spring MVC on exeris-spring-runtime,
    # Compat Mode) serves HTTP/1.1 only (asset-matrix protocol_mode=h1). Driving it
    # with the h2load (HTTP/2) path would be a protocol-mismatched, apples-to-oranges
    # run — rejected per the mandatory H1-vs-H2 separation axis.
    echo "ERROR: --target-runtime spring-runtime-on-exeris is HTTP/1.1-only and is not eligible for the h2load (HTTP/2) entity-read path. Use scripts/run-entity-read-by-id.sh (wrk/H1) instead." >&2
    exit 1
    ;;
  *)
    echo "ERROR: --target-runtime must be community|spring|quarkus (got: $TARGET_RUNTIME)" >&2
    exit 1
    ;;
esac

case "$TARGET_BUILD" in
  jvm|native) ;;
  *)
    echo "ERROR: --target-build must be jvm or native (got: $TARGET_BUILD)" >&2
    exit 1
    ;;
esac

if [[ "$SKIP_TARGET_BUILD" != "0" && "$SKIP_TARGET_BUILD" != "1" ]]; then
  echo "ERROR: BENCHMARK_SKIP_TARGET_BUILD must be 0 or 1 (got: $SKIP_TARGET_BUILD)" >&2
  exit 1
fi

if [[ "$ALLOW_EXTERNAL_TARGET" != "0" && "$ALLOW_EXTERNAL_TARGET" != "1" ]]; then
  echo "ERROR: BENCHMARK_ALLOW_EXTERNAL_TARGET must be 0 or 1 (got: $ALLOW_EXTERNAL_TARGET)" >&2
  exit 1
fi

require_positive_int "BENCHMARK_TARGET_PORT" "$TARGET_PORT"

require_positive_int "--threads" "$THREADS"
require_positive_int "--connections" "$CONNECTIONS"
require_positive_int "--max-concurrent-streams" "$MAX_CONCURRENT_STREAMS"
require_positive_int "--warmup-seconds" "$WARMUP_SECONDS"
require_positive_int "--duration-seconds" "$DURATION_SECONDS"

if ! command -v h2load >/dev/null 2>&1; then
  echo "ERROR: h2load is required but not found in PATH" >&2
  exit 1
fi

TARGET_PID_FILE="/tmp/${TARGET_APP_NAME}-benchmark.pid"
mkdir -p "$OUTPUT_DIR"
TARGET_APP_LOG="$OUTPUT_DIR/target-app.log"

# ── DB helpers (mirrored from run-entity-read-by-id.sh) ──────────────────────

resolve_db_launcher() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN="docker compose"
    DB_LAUNCH_MODE="compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_BIN="docker-compose"
    DB_LAUNCH_MODE="compose"
  elif command -v docker >/dev/null 2>&1; then
    DB_LAUNCH_MODE="docker-run"
  else
    echo "ERROR: docker is required to launch the benchmark DB" >&2
    exit 1
  fi
}

compose_db() {
  if [[ "$COMPOSE_BIN" == "docker compose" ]]; then
    docker compose -f "$DB_COMPOSE_FILE" "$@"
  else
    docker-compose -f "$DB_COMPOSE_FILE" "$@"
  fi
}

port_reachable() {
  local port="$1"
  (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1
}

db_accepting_connections() {
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD=benchmark psql -h localhost -p "$DB_PORT" -U benchmark -d benchmark_db -c 'SELECT 1' >/dev/null 2>&1
    return $?
  fi
  if docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    docker exec -e PGPASSWORD=benchmark "$DB_CONTAINER_NAME" psql -U benchmark -d benchmark_db -c 'SELECT 1' >/dev/null 2>&1
    return $?
  fi
  return 1
}

start_db() {
  if db_accepting_connections; then
    if [[ "$ALLOW_EXTERNAL_DB" == "1" ]]; then
      echo "[step 2] Reusing already-running DB on localhost:$DB_PORT"
      DB_LAUNCH_MODE="external"
      DB_MANAGED=0
      return 0
    fi
    echo "[step 2] WARN: External DB on localhost:$DB_PORT detected; launching managed for reproducibility"
  fi

  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    if [[ "$DB_PORT" == "5432" ]] && port_reachable 5432 && [[ "$ALLOW_EXTERNAL_DB" != "1" ]]; then
      DB_LAUNCH_MODE="docker-run"
      echo "[step 2] WARN: localhost:5432 occupied; switching to docker-run fallback"
    fi
  fi

  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db up -d
    DB_MANAGED=1
  else
    if [[ "$DB_PORT" == "5432" ]] && port_reachable 5432; then
      DB_PORT=55432
      echo "[step 2] WARN: using fallback port $DB_PORT"
    fi
    docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$DB_CONTAINER_NAME" \
      -e POSTGRES_DB=benchmark_db \
      -e POSTGRES_USER=benchmark \
      -e POSTGRES_PASSWORD=benchmark \
      -p "$DB_PORT":5432 \
      --mount "type=bind,source=$DB_INIT_SQL_FILE,target=/docker-entrypoint-initdb.d/01-pg-stat-statements-init.sql,readonly" \
      --health-cmd 'pg_isready -U benchmark -d benchmark_db' \
      --health-interval 5s --health-timeout 5s --health-retries 10 \
      --tmpfs /var/lib/postgresql/data \
      postgres:16.2 \
      postgres -c max_connections=300 -c shared_buffers=256MB -c work_mem=8MB \
               -c shared_preload_libraries=pg_stat_statements >/dev/null
    DB_MANAGED=1
  fi
}

is_db_healthy() {
  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db ps | grep -q "healthy"
  elif [[ "$DB_LAUNCH_MODE" == "external" ]]; then
    db_accepting_connections || port_reachable "$DB_PORT"
  else
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER_NAME" 2>/dev/null || true)" == "healthy" ]]
  fi
}

stop_db() {
  if [[ "$DB_MANAGED" -ne 1 ]]; then return 0; fi
  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db down --remove-orphans >/dev/null 2>&1 || true
  else
    docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

apply_seed_sql() {
  local seed_apply_script="${REPO_ROOT}/runtime/db/seed/seed-apply.sh"
  if [[ -x "$seed_apply_script" ]]; then
    PGHOST=localhost PGPORT="$DB_PORT" PGDATABASE=benchmark_db PGUSER=benchmark PGPASSWORD=benchmark \
      DB_CONTAINER_NAME="$DB_CONTAINER_NAME" \
      bash "$seed_apply_script"
    return
  fi
  # fallback: direct psql
  local seed_file="${REPO_ROOT}/scenarios/entity-read-by-id/seed/entities.sql"
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD=benchmark psql -h localhost -p "$DB_PORT" -U benchmark -d benchmark_db -f "$seed_file"
  else
    docker exec -i -e PGPASSWORD=benchmark "$DB_CONTAINER_NAME" \
      psql -U benchmark -d benchmark_db -f /dev/stdin < "$seed_file"
  fi
}

# ── Target helpers ────────────────────────────────────────────────────────────

target_reachable() {
  curl -sf "$BASE_URL/health" >/dev/null 2>&1 || \
  curl -sf "$BASE_URL/health/ready" >/dev/null 2>&1 || \
  bench_port_reachable "$TARGET_PORT"
}

wait_for_target() {
  local i
  for i in $(seq 1 60); do
    if target_reachable; then return 0; fi
    sleep 1
  done
  return 1
}

resolve_target_artifact() {
  TARGET_APP_JAR=""
  TARGET_APP_BIN=""
  if [[ "$TARGET_BUILD" == "jvm" ]]; then
    TARGET_APP_JAR=$(ls -1 $TARGET_JAR_GLOB 2>/dev/null | grep -Ev '(\.original$|-sources\.jar$|-javadoc\.jar$)' | sort | tail -n 1 || true)
    [[ -n "$TARGET_APP_JAR" ]]
    return $?
  fi
  TARGET_APP_BIN=$(ls -1 $TARGET_NATIVE_BIN_GLOB 2>/dev/null | while IFS= read -r c; do
    [[ -f "$c" && -x "$c" ]] && echo "$c"
  done | sort | tail -n 1 || true)
  [[ -n "$TARGET_APP_BIN" ]]
}

stop_stale_local_target_if_any() {
  [[ ! -f "$TARGET_PID_FILE" ]] && return 0
  local stale_pid
  stale_pid="$(cat "$TARGET_PID_FILE" 2>/dev/null || true)"
  [[ -z "$stale_pid" ]] && { rm -f "$TARGET_PID_FILE"; return 0; }
  if kill -0 "$stale_pid" >/dev/null 2>&1; then
    echo "[step 6] Stopping stale benchmark target (pid=$stale_pid)"
    kill "$stale_pid" >/dev/null 2>&1 || true
    wait "$stale_pid" 2>/dev/null || true
  fi
  rm -f "$TARGET_PID_FILE"
}

cleanup() {
  local exit_code=$?
  if [[ "$TARGET_APP_STARTED" -eq 1 ]] && [[ -n "$TARGET_APP_PID" ]] && kill -0 "$TARGET_APP_PID" >/dev/null 2>&1; then
    echo "[cleanup] Stopping benchmark target app (pid=$TARGET_APP_PID)..."
    kill "$TARGET_APP_PID" >/dev/null 2>&1 || true
    wait "$TARGET_APP_PID" 2>/dev/null || true
  fi
  rm -f "$TARGET_PID_FILE"
  echo "[cleanup] Stopping benchmark DB..."
  stop_db
  trap - EXIT
  exit "$exit_code"
}

# ── Main ──────────────────────────────────────────────────────────────────────

resolve_db_launcher
trap cleanup EXIT

echo "[entity-read-by-id-h2load] axis=$AXIS transport_mode=$TRANSPORT_MODE claim_scope=$CLAIM_SCOPE profile=$PROFILE"
echo "[entity-read-by-id-h2load] connections=$CONNECTIONS threads=$THREADS max_concurrent_streams=$MAX_CONCURRENT_STREAMS warmup=${WARMUP_SECONDS}s duration=${DURATION_SECONDS}s"
echo "[entity-read-by-id-h2load] target_runtime=$TARGET_RUNTIME_EFFECTIVE target_build=$TARGET_BUILD output=$OUTPUT_DIR"

# Step 2: DB
echo "[step 2] Starting benchmark DB..."
start_db
echo "[step 2] Waiting for DB to be healthy..."
for i in $(seq 1 30); do
  if is_db_healthy; then break; fi
  sleep 2
done
if ! is_db_healthy; then
  echo "ERROR: benchmark DB failed to become healthy" >&2
  exit 1
fi

# Step 3: Seed
echo "[step 3] Applying seed..."
apply_seed_sql

# Step 4: Verify seed
echo "[step 4] Verifying seed..."
if command -v psql >/dev/null 2>&1; then
  PGPASSWORD=benchmark PGPORT="$DB_PORT" bash "${REPO_ROOT}/scenarios/entity-read-by-id/seed/verify-seed.sh"
else
  echo "[step 4] psql not available; skipping file-hash verify, relying on managed-container fallback in verify-seed.sh"
  PGPASSWORD=benchmark PGPORT="$DB_PORT" bash "${REPO_ROOT}/scenarios/entity-read-by-id/seed/verify-seed.sh"
fi

# Step 5: Capture env
echo "[step 5] Capturing environment..."
"${REPO_ROOT}/scripts/capture-env.sh" --profile "$PROFILE" --tool h2load > "$OUTPUT_DIR/env.json" || true

# Step 6: Start target
echo "[step 6] Ensuring benchmark target app..."
if [[ "$ALLOW_EXTERNAL_TARGET" != "1" ]]; then
  stop_stale_local_target_if_any
  if bench_port_reachable "$TARGET_PORT"; then
    requested_target_port="$TARGET_PORT"
    TARGET_PORT="$(bench_find_available_local_port "$TARGET_PORT")"
    BASE_URL="http://localhost:${TARGET_PORT}"
    echo "[step 6] WARN: localhost:$requested_target_port is occupied and external target reuse is disabled; using managed target on localhost:$TARGET_PORT"
  fi
fi

if target_reachable; then
  if [[ "$ALLOW_EXTERNAL_TARGET" != "1" ]]; then
    echo "ERROR: benchmark target already reachable at $BASE_URL and BENCHMARK_ALLOW_EXTERNAL_TARGET is not 1" >&2
    exit 1
  fi
  echo "[step 6] WARN: Reusing externally managed target at $BASE_URL (BENCHMARK_ALLOW_EXTERNAL_TARGET=1)"
fi

if ! target_reachable; then
  artifact_found=0
  if resolve_target_artifact; then artifact_found=1; fi

  if [[ "$SKIP_TARGET_BUILD" == "1" ]]; then
    if [[ "$artifact_found" -ne 1 ]]; then
      echo "ERROR: BENCHMARK_SKIP_TARGET_BUILD=1 but no prebuilt artifact found (glob: $TARGET_JAR_GLOB)" >&2
      exit 1
    fi
    echo "[step 6] Using prebuilt artifact (BENCHMARK_SKIP_TARGET_BUILD=1): ${TARGET_APP_JAR:-$TARGET_APP_BIN}"
  else
    echo "[step 6] Building benchmark target app..."
    if [[ "$TARGET_BUILD" == "jvm" ]]; then
      mvn -f "$TARGET_MODULE_POM" -DskipTests package
    else
      case "$TARGET_RUNTIME_EFFECTIVE" in
        community|spring) mvn -f "$TARGET_MODULE_POM" -Pnative -DskipTests native:compile ;;
        quarkus)          mvn -f "$TARGET_MODULE_POM" -Pnative -Dquarkus.native.enabled=true -DskipTests package ;;
        *)                echo "ERROR: unsupported runtime for native build: $TARGET_RUNTIME_EFFECTIVE" >&2; exit 1 ;;
      esac
    fi
    if ! resolve_target_artifact; then
      echo "ERROR: target artifact not found after build" >&2
      exit 1
    fi
  fi

  echo "[step 6] Starting benchmark target app..."
  TARGET_CMD=(env \
    EXERIS_PORT="$TARGET_PORT" \
    EXERIS_DB_JDBC_URL="jdbc:postgresql://localhost:$DB_PORT/benchmark_db" \
    EXERIS_DB_USERNAME=benchmark \
    EXERIS_DB_PASSWORD=benchmark \
    EXERIS_DB_POOL_MIN_SIZE="$EXERIS_DB_POOL_MIN_SIZE" \
    EXERIS_DB_POOL_MAX_SIZE="$EXERIS_DB_POOL_MAX_SIZE" \
    SPRING_DATASOURCE_URL="jdbc:postgresql://localhost:$DB_PORT/benchmark_db" \
    SPRING_DATASOURCE_USERNAME=benchmark \
    SPRING_DATASOURCE_PASSWORD=benchmark \
    SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE="$EXERIS_DB_POOL_MIN_SIZE" \
    SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE="$EXERIS_DB_POOL_MAX_SIZE" \
    QUARKUS_DATASOURCE_JDBC_MIN_SIZE="$EXERIS_DB_POOL_MIN_SIZE" \
    QUARKUS_DATASOURCE_JDBC_MAX_SIZE="$EXERIS_DB_POOL_MAX_SIZE")

  if [[ "$TARGET_BUILD" == "jvm" ]]; then
    TARGET_CMD+=(java)
    if [[ "$TARGET_RUNTIME_EFFECTIVE" == "community" ]]; then
      TARGET_CMD+=(--add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --enable-native-access=ALL-UNNAMED)
      TARGET_CMD+=(--enable-preview)
      TARGET_CMD+=(-Dexeris.backend.mode=default-vt)
    fi
    TARGET_CMD+=(-jar "$TARGET_APP_JAR")
  else
    TARGET_CMD+=("$TARGET_APP_BIN")
  fi

  "${TARGET_CMD[@]}" > "$TARGET_APP_LOG" 2>&1 &
  TARGET_APP_PID=$!
  echo "$TARGET_APP_PID" > "$TARGET_PID_FILE"
  TARGET_APP_STARTED=1
fi

echo "[step 6] Waiting for target readiness (<=60s)..."
if ! wait_for_target; then
  echo "ERROR: benchmark target failed readiness check within 60s" >&2
  if [[ -f "$TARGET_APP_LOG" ]]; then
    echo "---- target-app.log (tail) ----"
    tail -n 40 "$TARGET_APP_LOG" || true
    echo "---- end target-app.log ----"
  fi
  exit 1
fi

PREFLIGHT_BODY_FILE="$OUTPUT_DIR/preflight-users-aggregate.json"
if ! bench_run_endpoint_preflight "$BASE_URL/api/v1/users" "$PREFLIGHT_BODY_FILE" "$ENTITY_READ_PREFLIGHT_TIMEOUT"; then
  echo "ERROR: endpoint preflight failed for $BASE_URL/api/v1/users (status=$BENCH_PREFLIGHT_HTTP_CODE)" >&2
  exit 1
fi
echo "[step 6] Endpoint preflight OK (HTTP $BENCH_PREFLIGHT_HTTP_CODE)"

# Build h2load command arrays
H2LOAD_BASE_ARGS=(-c "$CONNECTIONS" -t "$THREADS" -m "$MAX_CONCURRENT_STREAMS")
if [[ -n "$H2LOAD_AXIS_FLAG" ]]; then
  H2LOAD_BASE_ARGS+=("$H2LOAD_AXIS_FLAG")
fi
TARGET_URL="${BASE_URL}/api/v1/users"

# Step 7: Warmup
echo "[step 7] Warmup (${WARMUP_SECONDS}s, output discarded)..."
h2load "${H2LOAD_BASE_ARGS[@]}" -D "$WARMUP_SECONDS" "$TARGET_URL" > /dev/null 2>&1 || true

# Step 8: Measure
echo "[step 8] Measuring (${DURATION_SECONDS}s)..."
H2LOAD_OUT_FILE="$OUTPUT_DIR/h2load-raw.txt"
h2load "${H2LOAD_BASE_ARGS[@]}" -D "$DURATION_SECONDS" "$TARGET_URL" 2>&1 | tee "$H2LOAD_OUT_FILE"
H2LOAD_OUT="$(<"$H2LOAD_OUT_FILE")"

# Parse h2load output
# finished in Xs, N req/s, X MB/s
THROUGHPUT_RPS=$(awk '/finished in/ { for(i=1;i<=NF;i++) if ($i ~ /req\/s,?$/) { gsub(/,/,"",$i); print $(i-1); exit } }' <<<"$H2LOAD_OUT")
# requests: N total, ... N succeeded, N failed, N errored
TOTAL_REQUESTS=$(awk '/^requests:/ { for(i=1;i<=NF;i++) if ($i=="total,") { gsub(/,/,"",$(i-1)); print $(i-1); exit } }' <<<"$H2LOAD_OUT")
SUCCEEDED=$(awk '/^requests:/ { for(i=1;i<=NF;i++) if ($i=="succeeded,") { gsub(/,/,"",$(i-1)); print $(i-1); exit } }' <<<"$H2LOAD_OUT")
FAILED=$(awk '/^requests:/ { for(i=1;i<=NF;i++) if ($i=="failed,") { gsub(/,/,"",$(i-1)); print $(i-1); exit } }' <<<"$H2LOAD_OUT")
ERRORED=$(awk '/^requests:/ { for(i=1;i<=NF;i++) if ($i=="errored,") { gsub(/,/,"",$(i-1)); print $(i-1); exit } }' <<<"$H2LOAD_OUT")
# time for request:   Xus  Xms  Xus  Xus  XX.XX%
#                     min  max  mean sd   +/-sd
LAT_LINE=$(awk '/^time for request:/' <<<"$H2LOAD_OUT")
LATENCY_MIN_US=""
LATENCY_MAX_US=""
LATENCY_MEAN_US=""
LATENCY_STDEV_US=""
if [[ -n "$LAT_LINE" ]]; then
  to_us_h2load() {
    local v="$1"
    if [[ "$v" =~ ^([0-9.]+)s$ ]];  then echo "$(LC_ALL=C awk -v x="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f", x*1000000}')"; return; fi
    if [[ "$v" =~ ^([0-9.]+)ms$ ]]; then echo "$(LC_ALL=C awk -v x="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f", x*1000}')";    return; fi
    if [[ "$v" =~ ^([0-9.]+)us$ ]]; then echo "$(LC_ALL=C awk -v x="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f", x}')";          return; fi
    echo ""
  }
  LATENCY_MIN_US=$(to_us_h2load "$(awk '{print $4}' <<<"$LAT_LINE")")
  LATENCY_MAX_US=$(to_us_h2load "$(awk '{print $5}' <<<"$LAT_LINE")")
  LATENCY_MEAN_US=$(to_us_h2load "$(awk '{print $6}' <<<"$LAT_LINE")")
  LATENCY_STDEV_US=$(to_us_h2load "$(awk '{print $7}' <<<"$LAT_LINE")")
fi

TOTAL_ERRORS=$(( ${FAILED:-0} + ${ERRORED:-0} ))
ERROR_RATE_PCT=$(LC_ALL=C awk -v e="$TOTAL_ERRORS" -v t="${TOTAL_REQUESTS:-0}" \
  'BEGIN { if (t>0) { printf "%.6f", (e*100.0)/t } else { print "0.000000" } }')

# Step 9: Write artifacts
echo "[step 9] Writing result artifact..."
RESULT_FILE="$OUTPUT_DIR/result.json"
REPRO_FILE="$OUTPUT_DIR/reproducibility-metadata.json"
COMMIT_SHA=$(git -C . rev-parse HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_ID="entity-read-by-id-h2load-$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

H2LOAD_VERSION_LINE="$(h2load --version 2>&1 | head -1 || echo "unknown")"

jq -n \
  --arg schema_version "1" \
  --arg run_id "$RUN_ID" \
  --arg timestamp "$TIMESTAMP" \
  --arg scenario "entity-read-by-id" \
  --arg tool "h2load" \
  --arg tool_version "$H2LOAD_VERSION_LINE" \
  --arg axis "$AXIS" \
  --arg transport_mode "$TRANSPORT_MODE" \
  --arg benchmark_family "$BENCHMARK_FAMILY" \
  --arg contract_id "$CONTRACT_ID" \
  --arg claim_scope "$RESULT_CLAIM_SCOPE" \
  --arg execution_class "$EXECUTION_CLASS" \
  --arg comparison_axis "within-tier" \
  --arg comparison_policy_note "H2c and H1 results are not comparable. Do not compare to wrk H1 results without explicit caveats." \
  --arg target_app_name "$TARGET_APP_NAME" \
  --arg target_runtime "$TARGET_RUNTIME_EFFECTIVE" \
  --arg target_build "$TARGET_BUILD" \
  --arg commit_sha "$COMMIT_SHA" \
  --argjson threads "$THREADS" \
  --argjson connections "$CONNECTIONS" \
  --argjson max_concurrent_streams "$MAX_CONCURRENT_STREAMS" \
  --argjson warmup_seconds "$WARMUP_SECONDS" \
  --argjson duration_seconds "$DURATION_SECONDS" \
  --arg throughput_rps "${THROUGHPUT_RPS:-}" \
  --arg total_requests "${TOTAL_REQUESTS:-}" \
  --arg succeeded "${SUCCEEDED:-}" \
  --arg total_errors "$TOTAL_ERRORS" \
  --arg error_rate_pct "$ERROR_RATE_PCT" \
  --arg latency_min_us "${LATENCY_MIN_US:-}" \
  --arg latency_max_us "${LATENCY_MAX_US:-}" \
  --arg latency_mean_us "${LATENCY_MEAN_US:-}" \
  --arg latency_stdev_us "${LATENCY_STDEV_US:-}" \
  --arg raw_output_file "$H2LOAD_OUT_FILE" \
  '
  def num_or_null($v):
    if ($v == "" or $v == null) then null
    else (($v | tonumber?) // null)
    end;
  {
    schema_version: $schema_version,
    run_id: $run_id,
    timestamp: $timestamp,
    scenario: $scenario,
    tool: $tool,
    tool_version: $tool_version,
    axis: $axis,
    transport_mode: $transport_mode,
    benchmark_family: $benchmark_family,
    contract_id: $contract_id,
    claim_scope: $claim_scope,
    execution_class: $execution_class,
    comparison_axis: $comparison_axis,
    comparison_policy_note: $comparison_policy_note,
    target: {
      app_name: $target_app_name,
      runtime: $target_runtime,
      build: $target_build,
      commit_sha: $commit_sha
    },
    run_config: {
      threads: $threads,
      connections: $connections,
      max_concurrent_streams: $max_concurrent_streams,
      warmup_seconds: $warmup_seconds,
      duration_seconds: $duration_seconds
    },
    metrics: {
      throughput_rps:   num_or_null($throughput_rps),
      total_requests:   num_or_null($total_requests),
      succeeded:        num_or_null($succeeded),
      total_errors:     num_or_null($total_errors),
      error_rate_pct:   num_or_null($error_rate_pct),
      latency_min_us:   num_or_null($latency_min_us),
      latency_max_us:   num_or_null($latency_max_us),
      latency_mean_us:  num_or_null($latency_mean_us),
      latency_stdev_us: num_or_null($latency_stdev_us),
      latency_percentiles_note: "h2load does not emit percentile latencies (p50/p99). Use wrk2 for p99_stable measurements."
    },
    raw_output_file: $raw_output_file,
    seed_ref: {
      manifest_version: "1",
      scenario_id: "entity-read-by-id",
      schema_migration_version: "V1",
      entity_count: 1000,
      verified: true
    }
  }' > "$RESULT_FILE"

# Reproducibility metadata
if [[ -s "$OUTPUT_DIR/env.json" ]] && jq -e . "$OUTPUT_DIR/env.json" >/dev/null 2>&1; then
  JDK_VENDOR="$(jq -r '.jdk.vendor // "unknown"' "$OUTPUT_DIR/env.json")"
  JDK_VERSION="$(jq -r '.jdk.version // "unknown"' "$OUTPUT_DIR/env.json")"
  HARDWARE_PROFILE_REF="$(jq -r '.hardware_profile // "unknown"' "$OUTPUT_DIR/env.json")"
  JVM_FLAGS_JSON="$(jq -c '.jvm_flags // []' "$OUTPUT_DIR/env.json")"
else
  JDK_VENDOR="unknown"; JDK_VERSION="unknown"; HARDWARE_PROFILE_REF="$PROFILE"; JVM_FLAGS_JSON="[]"
fi

jq -n \
  --arg timestamp "$TIMESTAMP" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg scenario_id "entity-read-by-id" \
  --arg contract_id "$CONTRACT_ID" \
  --arg jdk_vendor "$JDK_VENDOR" \
  --arg jdk_version "$JDK_VERSION" \
  --arg hardware_profile_ref "$HARDWARE_PROFILE_REF" \
  --arg tool "h2load" \
  --arg tool_version "$H2LOAD_VERSION_LINE" \
  --arg tier "community" \
  --arg protocol_mode "$AXIS" \
  --arg benchmark_family "$BENCHMARK_FAMILY" \
  --arg transport_mode "$TRANSPORT_MODE" \
  --arg execution_class "$EXECUTION_CLASS" \
  --arg comparison_axis "within-tier" \
  --arg claim_scope "$RESULT_CLAIM_SCOPE" \
  --argjson jvm_flags "$JVM_FLAGS_JSON" \
  --argjson threads "$THREADS" \
  --argjson connections "$CONNECTIONS" \
  --argjson max_concurrent_streams "$MAX_CONCURRENT_STREAMS" \
  --argjson warmup_seconds "$WARMUP_SECONDS" \
  --argjson duration_seconds "$DURATION_SECONDS" \
  '{
    timestamp: $timestamp,
    benchmark_commit_sha: $commit_sha,
    scenario_id: $scenario_id,
    contract_id: $contract_id,
    jdk: { vendor: $jdk_vendor, version: $jdk_version },
    jvm_flags: $jvm_flags,
    hardware_profile_ref: $hardware_profile_ref,
    tool: { name: $tool, version: $tool_version },
    axis_labels: {
      tier: $tier,
      protocol_mode: $protocol_mode,
      benchmark_family: $benchmark_family,
      transport_mode: $transport_mode,
      execution_class: $execution_class,
      comparison_axis: $comparison_axis,
      claim_scope: $claim_scope
    },
    run_config: {
      threads: $threads,
      connections: $connections,
      max_concurrent_streams: $max_concurrent_streams,
      warmup_seconds: $warmup_seconds,
      duration_seconds: $duration_seconds
    },
    seed_manifest_refs: {
      manifest_ref: "scenarios/entity-read-by-id/seed/seed-manifest.json",
      manifest_version: "1"
    }
  }' > "$REPRO_FILE"

echo "[step 10] Result artifact: $RESULT_FILE"
echo "[step 10] Reproducibility: $REPRO_FILE"
echo "[step 10] Raw h2load output: $H2LOAD_OUT_FILE"
echo ""
echo "output_dir=$OUTPUT_DIR"
echo "throughput_rps=${THROUGHPUT_RPS:-unknown} total_requests=${TOTAL_REQUESTS:-unknown} total_errors=${TOTAL_ERRORS}"
echo "axis=$AXIS transport_mode=$TRANSPORT_MODE"
