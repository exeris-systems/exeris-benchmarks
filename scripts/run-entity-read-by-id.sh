#!/usr/bin/env bash
set -euo pipefail

# Usage: run-entity-read-by-id.sh [--contract fixed_contract_v1] [--claim-scope exploratory|comparison-eligible] [--profile <hw-profile>] [--output-dir <path>] [--threads <int>] [--connections <int>] [--duration <N>s] [--warmup <N>s]
#
# Orchestrates the entity-read-by-id E2E benchmark run:
#   1. Validate claim-scope
#   2. Start DB (Docker Compose)
#   3. Apply seed (psql entities.sql)
#   4. Verify seed (verify-seed.sh) — abort on failure
#   5. Capture env
#   6. Warmup (60s, discarded)
#   7. Measure (duration per claim-scope)
#   8. Write result artifact with transport_mode, seed_ref, claim_scope
#   9. Schema-validate result artifact

CLAIM_SCOPE="${CLAIM_SCOPE:-exploratory}"
PROFILE="${PROFILE:-dev-laptop}"
OUTPUT_DIR="${OUTPUT_DIR:-results/raw/entity-read-by-id/$(date +%Y%m%d-%H%M%S)}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-32}"
WARMUP="${WARMUP:-60s}"
DURATION_OVERRIDE=""
CONTRACT_NAME=""
BASE_URL="http://localhost:8080"
SCENARIO_DIR="scenarios/entity-read-by-id"
DB_COMPOSE_FILE="runtime/compose/entity-read-by-id-db.yml"
TARGET_MAIN_CLASS="eu.exeris.kernel.benchmark.target.app.BenchmarkTargetMain"
TARGET_CLASSES_DIR="targets/exeris-benchmark-app/target/classes"
DB_PORT="${DB_PORT:-5432}"
TARGET_APP_LOG=""
TARGET_APP_PID=""
TARGET_APP_STARTED=0
COMPOSE_BIN=""
DB_LAUNCH_MODE=""
DB_CONTAINER_NAME="exeris-benchmark-db"
DB_MANAGED=0

CONTRACT_FIXED_THREADS=4
CONTRACT_FIXED_CONNECTIONS=32
CONTRACT_FIXED_WARMUP_SECONDS=60
CONTRACT_FIXED_DURATION_SECONDS=60
CONTRACT_FIXED_PROFILE="perf-box-amd64"
CONTRACT_FIXED_CLAIM_SCOPE="comparison-eligible"

require_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    echo "ERROR: $name must be a positive integer (got: $value)"
    exit 1
  fi
}

require_duration_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+s$ ]]; then
    echo "ERROR: $name must match <N>s (got: $value)"
    exit 1
  fi
}

to_us() {
  local token="$1"
  if [[ -z "$token" ]]; then
    echo ""
    return 0
  fi

  if [[ "$token" =~ ^([0-9]*\.?[0-9]+)(us|ms|s)$ ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    LC_ALL=C awk -v v="$value" -v u="$unit" 'BEGIN {
      if (u == "us") {
        printf "%.6f", v
      } else if (u == "ms") {
        printf "%.6f", v * 1000
      } else if (u == "s") {
        printf "%.6f", v * 1000000
      }
    }'
    return 0
  fi

  echo ""
}

assert_contract_match() {
  local flag_name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: --contract $CONTRACT_NAME requires $flag_name=$expected (got: $actual)"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT_NAME="$2"; shift 2 ;;
    --claim-scope) CLAIM_SCOPE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --duration) DURATION_OVERRIDE="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

require_positive_int "--threads" "$THREADS"
require_positive_int "--connections" "$CONNECTIONS"
require_duration_seconds "--warmup" "$WARMUP"
if [[ -n "$DURATION_OVERRIDE" ]]; then
  require_duration_seconds "--duration" "$DURATION_OVERRIDE"
fi

if [[ -n "$CONTRACT_NAME" ]]; then
  if [[ "$CONTRACT_NAME" != "fixed_contract_v1" ]]; then
    echo "ERROR: Unsupported contract '$CONTRACT_NAME'. Supported: fixed_contract_v1"
    exit 1
  fi

  if [[ -n "$DURATION_OVERRIDE" ]]; then
    echo "ERROR: --duration override is not allowed with --contract $CONTRACT_NAME"
    exit 1
  fi

  assert_contract_match "--threads" "$THREADS" "$CONTRACT_FIXED_THREADS"
  assert_contract_match "--connections" "$CONNECTIONS" "$CONTRACT_FIXED_CONNECTIONS"
  assert_contract_match "--warmup" "$WARMUP" "${CONTRACT_FIXED_WARMUP_SECONDS}s"
  assert_contract_match "--claim-scope" "$CLAIM_SCOPE" "$CONTRACT_FIXED_CLAIM_SCOPE"
  assert_contract_match "--profile" "$PROFILE" "$CONTRACT_FIXED_PROFILE"
fi

# claim_scope enforcement
case "$CLAIM_SCOPE" in
  exploratory)
    DURATION=30s
    ;;
  comparison-eligible)
    DURATION=60s
    if [[ "$PROFILE" != "perf-box-amd64" ]]; then
      echo "ERROR: comparison-eligible requires --profile perf-box-amd64 (got: $PROFILE)"
      exit 1
    fi
    ;;
  p99-stable)
    echo "ERROR: p99-stable requires wrk2 (CO-free). wrk is INELIGIBLE. Use run-wrk2.sh."
    exit 1
    ;;
  *)
    echo "ERROR: Unknown claim-scope: $CLAIM_SCOPE. Valid: exploratory, comparison-eligible, p99-stable"
    exit 1
    ;;
esac

if [[ -n "$DURATION_OVERRIDE" ]]; then
  if [[ "$CLAIM_SCOPE" != "exploratory" ]]; then
    echo "ERROR: --duration override is only allowed with --claim-scope exploratory"
    exit 1
  fi
  DURATION="$DURATION_OVERRIDE"
fi

if [[ -n "$CONTRACT_NAME" ]]; then
  assert_contract_match "duration" "$DURATION" "${CONTRACT_FIXED_DURATION_SECONDS}s"
fi

DURATION_SECONDS="${DURATION%s}"
WARMUP_SECONDS="${WARMUP%s}"

mkdir -p "$OUTPUT_DIR"
TARGET_APP_LOG="$OUTPUT_DIR/target-app.log"

resolve_db_launcher() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN="docker compose"
    DB_LAUNCH_MODE="compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_BIN="docker-compose"
    DB_LAUNCH_MODE="compose"
  elif command -v docker >/dev/null 2>&1; then
    DB_LAUNCH_MODE="docker-run"
  else
    echo "ERROR: Neither compose nor docker runtime is available"
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

start_db() {
  if db_accepting_connections; then
    echo "[step 2/9] Reusing already-running local benchmark DB on localhost:$DB_PORT"
    DB_LAUNCH_MODE="external"
    DB_MANAGED=0
    return 0
  fi

  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db up -d
    DB_MANAGED=1
  else
    if [[ "$DB_PORT" == "5432" ]] && port_reachable 5432; then
      DB_PORT=55432
      echo "[step 2/9] WARN: localhost:5432 is occupied by a different service; using localhost:$DB_PORT"
    fi
    echo "[step 2/9] WARN: Compose not available; using docker-run fallback for DB"
    docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$DB_CONTAINER_NAME" \
      -e POSTGRES_DB=benchmark_db \
      -e POSTGRES_USER=benchmark \
      -e POSTGRES_PASSWORD=benchmark \
      -p "$DB_PORT":5432 \
      --health-cmd 'pg_isready -U benchmark -d benchmark_db' \
      --health-interval 5s \
      --health-timeout 5s \
      --health-retries 10 \
      --tmpfs /var/lib/postgresql/data \
      postgres:16.2 >/dev/null
    DB_MANAGED=1
  fi
}

db_accepting_connections() {
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD=benchmark psql -h localhost -p "$DB_PORT" -U benchmark -d benchmark_db -c 'SELECT 1' >/dev/null 2>&1
    return $?
  fi

  if [[ "$DB_LAUNCH_MODE" == "docker-run" ]] && docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    docker exec -e PGPASSWORD=benchmark "$DB_CONTAINER_NAME" psql -U benchmark -d benchmark_db -c 'SELECT 1' >/dev/null 2>&1
    return $?
  fi

  return 1
}

apply_seed_sql() {
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD=benchmark psql -h localhost -p "$DB_PORT" -U benchmark -d benchmark_db -f "$SCENARIO_DIR/seed/entities.sql"
    return 0
  fi

  if [[ "$DB_LAUNCH_MODE" == "docker-run" ]] && docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    docker exec -i -e PGPASSWORD=benchmark "$DB_CONTAINER_NAME" psql -U benchmark -d benchmark_db < "$SCENARIO_DIR/seed/entities.sql"
    return 0
  fi

  echo "ERROR: psql is required when benchmark DB is not managed by docker-run"
  return 1
}

query_seed_count() {
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD=benchmark psql -h localhost -p "$DB_PORT" -U benchmark -d benchmark_db -t -A -c "SELECT COUNT(*) FROM entities"
    return 0
  fi

  if [[ "$DB_LAUNCH_MODE" == "docker-run" ]] && docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    docker exec -e PGPASSWORD=benchmark "$DB_CONTAINER_NAME" psql -U benchmark -d benchmark_db -t -A -c "SELECT COUNT(*) FROM entities"
    return 0
  fi

  echo "ERROR: psql is required to verify seed count when DB is external"
  return 1
}

verify_seed_fallback() {
  local manifest="$SCENARIO_DIR/seed/seed-manifest.json"
  local seed_file="$SCENARIO_DIR/seed/entities.sql"
  local expected_count expected_sha256 actual_sha256 actual_count

  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed"
    return 1
  fi

  expected_count=$(jq -r '.entity_count' "$manifest")
  expected_sha256=$(jq -r '.seed_file_sha256' "$manifest")
  actual_sha256=$(sha256sum "$seed_file" | awk '{print $1}')

  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "SEED FILE HASH MISMATCH: expected $expected_sha256 got $actual_sha256"
    return 1
  fi

  actual_count=$(query_seed_count)
  if ! [[ "$actual_count" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not query entity count. Output: $actual_count"
    return 1
  fi

  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "SEED ROW COUNT MISMATCH: expected $expected_count, got $actual_count"
    return 1
  fi

  echo "SEED VERIFIED: $actual_count rows, hash OK, migration V1 (fallback)"
  return 0
}

is_db_healthy() {
  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db ps | grep -q "healthy"
  elif [[ "$DB_LAUNCH_MODE" == "external" ]]; then
    db_accepting_connections
  else
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER_NAME" 2>/dev/null || true)" == "healthy" ]]
  fi
}

stop_db() {
  if [[ "$DB_MANAGED" -ne 1 ]]; then
    return 0
  fi

  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db down --remove-orphans >/dev/null 2>&1 || true
  else
    docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

target_reachable() {
  if curl -sf "$BASE_URL/health" >/dev/null 2>&1; then
    return 0
  fi
  if curl -sf "$BASE_URL/health/ready" >/dev/null 2>&1; then
    return 0
  fi
  if (echo > /dev/tcp/127.0.0.1/8080) >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

port_reachable() {
  local port="$1"
  if (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wait_for_target() {
  local timeout=60
  for _ in $(seq 1 "$timeout"); do
    if target_reachable; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  local exit_code=$?
  if [[ "$TARGET_APP_STARTED" -eq 1 ]] && [[ -n "$TARGET_APP_PID" ]] && kill -0 "$TARGET_APP_PID" >/dev/null 2>&1; then
    echo "[cleanup] Stopping benchmark target app (pid=$TARGET_APP_PID)..."
    kill "$TARGET_APP_PID" >/dev/null 2>&1 || true
    wait "$TARGET_APP_PID" 2>/dev/null || true
  fi
  echo "[cleanup] Stopping benchmark DB..."
  stop_db
  trap - EXIT
  exit "$exit_code"
}

resolve_db_launcher
trap cleanup EXIT

echo "[entity-read-by-id] claim_scope=$CLAIM_SCOPE profile=$PROFILE duration=$DURATION warmup=$WARMUP threads=$THREADS connections=$CONNECTIONS output=$OUTPUT_DIR"

# Step 2: Start DB
echo "[step 2/9] Starting benchmark DB..."
start_db
echo "[step 2/9] Waiting for DB to be healthy..."
for i in $(seq 1 30); do
  if is_db_healthy; then
    break
  fi
  sleep 2
done

if ! is_db_healthy; then
  echo "ERROR: benchmark DB failed to become healthy"
  exit 1
fi

# Step 3: Apply seed
echo "[step 3/9] Applying seed..."
apply_seed_sql

# Step 4: Verify seed — abort on failure
echo "[step 4/9] Verifying seed..."
if command -v psql >/dev/null 2>&1; then
  PGPASSWORD=benchmark PGPORT="$DB_PORT" bash "$SCENARIO_DIR/seed/verify-seed.sh"
else
  verify_seed_fallback
fi

# Step 5: Capture env
echo "[step 5/9] Capturing environment..."
./scripts/capture-env.sh --profile "$PROFILE" --tool wrk > "$OUTPUT_DIR/env.json"

# Step 6: Warmup
echo "[step 6/9] Ensuring benchmark target app is available..."
if ! target_reachable; then
  if [[ "$OUTPUT_DIR" == /* ]]; then
    TARGET_CP_FILE="$OUTPUT_DIR/target-app.classpath"
  else
    TARGET_CP_FILE="$PWD/$OUTPUT_DIR/target-app.classpath"
  fi

  echo "[step 6/9] Building benchmark target app..."
  mvn -f targets/exeris-benchmark-app/pom.xml -DskipTests compile

  echo "[step 6/9] Resolving benchmark target classpath..."
  mvn -f targets/exeris-benchmark-app/pom.xml -DskipTests dependency:build-classpath \
    -Dmdep.outputFile="$TARGET_CP_FILE"

  if [[ ! -f "$TARGET_CP_FILE" ]]; then
    echo "ERROR: Failed to build benchmark target classpath"
    exit 1
  fi

  TARGET_APP_CLASSPATH=$(<"$TARGET_CP_FILE")
  if [[ -z "$TARGET_APP_CLASSPATH" ]]; then
    echo "ERROR: Benchmark target classpath is empty"
    exit 1
  fi

  COMMUNITY_JAR=$(ls -1 "$HOME"/.m2/repository/eu/exeris/exeris-kernel-community/*/exeris-kernel-community-*.jar 2>/dev/null | sort | tail -n 1 || true)
  if [[ -z "$COMMUNITY_JAR" ]]; then
    echo "ERROR: exeris-kernel-community jar not found in ~/.m2. Build/install it before running this scenario."
    exit 1
  fi

  echo "[step 6/9] Starting benchmark target app..."
  java --enable-preview -cp "$TARGET_CLASSES_DIR:$TARGET_APP_CLASSPATH:$COMMUNITY_JAR" \
    -Dexeris.http.port=8080 \
    -Dexeris.launcher.subsystems=http,persistence \
    -Dexeris.tls.community.cryptoProviderClass=eu.exeris.kernel.community.crypto.CommunityKernelCryptoProvider \
    -Dexeris.tls.community.memoryProviderClass=eu.exeris.kernel.community.memory.CommunityMemoryProvider \
    -Dbenchmark.target.basePath=/api/v1 \
    -Dexeris.persistence.jdbcUrl=jdbc:postgresql://localhost:$DB_PORT/benchmark_db \
    -Dexeris.persistence.username=benchmark \
    -Dexeris.persistence.password=benchmark \
    "$TARGET_MAIN_CLASS" > "$TARGET_APP_LOG" 2>&1 &
  TARGET_APP_PID=$!
  TARGET_APP_STARTED=1
fi

echo "[step 6/9] Waiting for target readiness (<=60s)..."
if ! wait_for_target; then
  echo "ERROR: benchmark target app failed readiness check within 60s"
  if [[ -f "$TARGET_APP_LOG" ]]; then
    echo "---- target-app.log (tail) ----"
    tail -n 60 "$TARGET_APP_LOG" || true
    echo "---- end target-app.log ----"
  fi
  exit 1
fi

PREFLIGHT_BODY_FILE="$OUTPUT_DIR/preflight-entity-read-by-id.json"
PREFLIGHT_STATUS=$(curl -sS -o "$PREFLIGHT_BODY_FILE" -w "%{http_code}" "$BASE_URL/api/v1/entities/1" || true)
echo "[step 6/9] Endpoint preflight status: $PREFLIGHT_STATUS"
if [[ "$PREFLIGHT_STATUS" != "200" ]]; then
  echo "ERROR: endpoint preflight failed for $BASE_URL/api/v1/entities/1 (status=$PREFLIGHT_STATUS)"
  echo "ERROR: preflight response body saved at $PREFLIGHT_BODY_FILE"
  exit 1
fi

echo "[step 6/9] Warmup ($WARMUP)..."
wrk -t "$THREADS" -c "$CONNECTIONS" -d "$WARMUP" --script "$SCENARIO_DIR/wrk.lua" "$BASE_URL/api/v1/entities/1" > /dev/null || true

# Step 7: Measure
echo "[step 7/9] Measuring ($DURATION)..."
WRK_OUT=$(wrk -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" --script "$SCENARIO_DIR/wrk.lua" --latency "$BASE_URL/api/v1/entities/1" 2>&1)
echo "$WRK_OUT"

THROUGHPUT_RPS=$(awk '/Requests\/sec:/ {print $2; exit}' <<<"$WRK_OUT")
LATENCY_STATS_LINE=$(printf '%s\n' "$WRK_OUT" | awk '/Thread Stats/{in_stats=1;next} in_stats && /^[[:space:]]*Latency[[:space:]]/ {print; exit}')
LATENCY_MEAN_US=$(to_us "$(awk '{print $2}' <<<"$LATENCY_STATS_LINE")")
LATENCY_STDEV_US=$(to_us "$(awk '{print $3}' <<<"$LATENCY_STATS_LINE")")
LATENCY_MAX_US=$(to_us "$(awk '{print $4}' <<<"$LATENCY_STATS_LINE")")
LATENCY_P50_US=$(to_us "$(awk '$1 == "50%" {print $2; exit}' <<<"$WRK_OUT")")
LATENCY_P75_US=$(to_us "$(awk '$1 == "75%" {print $2; exit}' <<<"$WRK_OUT")")
LATENCY_P90_US=$(to_us "$(awk '$1 == "90%" {print $2; exit}' <<<"$WRK_OUT")")
LATENCY_P99_US=$(to_us "$(awk '$1 == "99%" {print $2; exit}' <<<"$WRK_OUT")")
TOTAL_REQUESTS=$(awk '/requests in/ {gsub(/,/, "", $1); print $1; exit}' <<<"$WRK_OUT")
NON2XX_ERRORS=$(awk '/Non-2xx or 3xx responses:/ {print $5; exit}' <<<"$WRK_OUT")
SOCKET_ERRORS=$(awk -F'[:, ]+' '/Socket errors:/ {print ($4 + $6 + $8 + $10); exit}' <<<"$WRK_OUT")

if [[ -z "$NON2XX_ERRORS" ]]; then
  NON2XX_ERRORS=0
fi
if [[ -z "$SOCKET_ERRORS" ]]; then
  SOCKET_ERRORS=0
fi

TOTAL_ERRORS=$((NON2XX_ERRORS + SOCKET_ERRORS))
ERROR_RATE_PCT=$(LC_ALL=C awk -v errors="$TOTAL_ERRORS" -v total="${TOTAL_REQUESTS:-0}" 'BEGIN {
  if (total > 0) {
    printf "%.6f", (errors * 100.0) / total
  } else {
    printf "0.000000"
  }
}')

RUN_CONFIG_JSON=$(jq -n \
  --argjson duration_seconds "$DURATION_SECONDS" \
  --argjson warmup_seconds "$WARMUP_SECONDS" \
  --argjson threads "$THREADS" \
  --argjson connections "$CONNECTIONS" \
  '{
    duration_seconds: $duration_seconds,
    warmup_seconds: $warmup_seconds,
    threads: $threads,
    connections: $connections
  }')

METRICS_JSON=$(jq -n \
  --arg throughput_rps "$THROUGHPUT_RPS" \
  --arg latency_mean_us "$LATENCY_MEAN_US" \
  --arg latency_stdev_us "$LATENCY_STDEV_US" \
  --arg latency_max_us "$LATENCY_MAX_US" \
  --arg latency_p50_us "$LATENCY_P50_US" \
  --arg latency_p75_us "$LATENCY_P75_US" \
  --arg latency_p90_us "$LATENCY_P90_US" \
  --arg latency_p99_us "$LATENCY_P99_US" \
  --arg total_requests "$TOTAL_REQUESTS" \
  --arg total_errors "$TOTAL_ERRORS" \
  --arg error_rate_pct "$ERROR_RATE_PCT" \
  '
  def num_or_null($v):
    if ($v == null) then null
    else (($v|tostring|gsub(",";".")|gsub("^[[:space:]]+|[[:space:]]+$";"")) as $t
      | if $t=="" then null else (($t|tonumber?) // null) end)
    end;

  {
    throughput_rps: num_or_null($throughput_rps),
    latency_mean_us: num_or_null($latency_mean_us),
    latency_stdev_us: num_or_null($latency_stdev_us),
    latency_max_us: num_or_null($latency_max_us),
    latency_p50_us: num_or_null($latency_p50_us),
    latency_p75_us: num_or_null($latency_p75_us),
    latency_p90_us: num_or_null($latency_p90_us),
    latency_p99_us: num_or_null($latency_p99_us),
    total_requests: num_or_null($total_requests),
    total_errors: num_or_null($total_errors),
    error_rate_pct: num_or_null($error_rate_pct)
  }')

# Step 8: Write result artifact
echo "[step 8/9] Writing result artifact..."
RESULT_FILE="$OUTPUT_DIR/result.json"
COMMIT_SHA=$(git -C . rev-parse HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_ID="entity-read-by-id-$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Map claim_scope to schema enum value
case "$CLAIM_SCOPE" in
  exploratory)          RESULT_CLAIM_SCOPE="exploratory" ;;
  comparison-eligible)  RESULT_CLAIM_SCOPE="comparison_eligible" ;;
  *)                    RESULT_CLAIM_SCOPE="descriptive_only" ;;
esac

# Map execution_class for reproducibility axis labels.
case "$CLAIM_SCOPE" in
  comparison-eligible) EXECUTION_CLASS="guard" ;;
  exploratory)         EXECUTION_CLASS="exploratory" ;;
  *)                   EXECUTION_CLASS="exploratory" ;;
esac

cat > "$RESULT_FILE" <<EOF
{
  "schema_version": "1",
  "run_id": "$RUN_ID",
  "timestamp": "$TIMESTAMP",
  "scenario": "entity-read-by-id",
  "tool": "wrk",
  "env_ref": "$OUTPUT_DIR/env.json",
  "claim_scope": "$RESULT_CLAIM_SCOPE",
  "transport_mode": "loopback-h1",
  "co_risk": true,
  "target": {
    "name": "exeris-benchmark-app",
    "tier": "community",
    "mode": "baseline-db",
    "commit_sha": "$COMMIT_SHA"
  },
  "seed_ref": {
    "manifest_version": "1",
    "scenario_id": "entity-read-by-id",
    "schema_migration_version": "V1",
    "entity_count": 1000,
    "verified": true
  },
  "cross_tier_status": "deferred",
  "cross_tier_guard_ref": "scenarios/entity-read-by-id/scenario.json#cross_tier_equivalence_constraints",
  "run_config": $RUN_CONFIG_JSON,
  "metrics": $METRICS_JSON,
  "raw_output": $(echo "$WRK_OUT" | jq -Rs .)
}
EOF

REPRO_FILE="$OUTPUT_DIR/reproducibility-metadata.json"
STEADY_STATE_FILE="$OUTPUT_DIR/steady-state-evidence.json"
WRK_VERSION_LINE="$(wrk --version 2>&1 | head -1 || true)"
if [[ -z "$WRK_VERSION_LINE" ]]; then
  WRK_VERSION_LINE="unknown"
fi

if [[ -f "$OUTPUT_DIR/env.json" ]]; then
  JDK_VENDOR="$(jq -r '.jdk.vendor // "unknown"' "$OUTPUT_DIR/env.json")"
  JDK_VERSION="$(jq -r '.jdk.version // "unknown"' "$OUTPUT_DIR/env.json")"
  HARDWARE_PROFILE_REF="$(jq -r '.hardware_profile // "unknown"' "$OUTPUT_DIR/env.json")"
  JVM_FLAGS_JSON="$(jq -c '.jvm_flags // []' "$OUTPUT_DIR/env.json")"
else
  JDK_VENDOR="unknown"
  JDK_VERSION="unknown"
  HARDWARE_PROFILE_REF="$PROFILE"
  JVM_FLAGS_JSON="[]"
fi

jq -n \
  --arg timestamp "$TIMESTAMP" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg scenario_id "entity-read-by-id" \
  --arg scenario_classification "runtime-baseline-db-read-path" \
  --arg contract "${CONTRACT_NAME:-none}" \
  --arg jdk_vendor "$JDK_VENDOR" \
  --arg jdk_version "$JDK_VERSION" \
  --arg hardware_profile_ref "$HARDWARE_PROFILE_REF" \
  --arg tool "wrk" \
  --arg tool_version "$WRK_VERSION_LINE" \
  --arg tier "community" \
  --arg protocol_mode "h1" \
  --arg benchmark_family "runtime-wrk" \
  --arg transport_mode "loopback-h1" \
  --arg execution_class "$EXECUTION_CLASS" \
  --arg comparison_axis "within-tier" \
  --arg claim_scope "$RESULT_CLAIM_SCOPE" \
  --arg mode "baseline-db" \
  --arg seed_manifest_ref "$SCENARIO_DIR/seed/seed-manifest.json" \
  --arg seed_manifest_version "1" \
  --argjson jvm_flags "$JVM_FLAGS_JSON" \
  --argjson threads "$THREADS" \
  --argjson connections "$CONNECTIONS" \
  --argjson warmup_seconds "$WARMUP_SECONDS" \
  --argjson duration_seconds "$DURATION_SECONDS" \
  '{
    timestamp: $timestamp,
    benchmark_commit_sha: $commit_sha,
    target_commit_sha: $commit_sha,
    scenario_id: $scenario_id,
    scenario_classification: $scenario_classification,
    contract: $contract,
    jdk: {
      vendor: $jdk_vendor,
      version: $jdk_version
    },
    jvm_flags: $jvm_flags,
    hardware_profile_ref: $hardware_profile_ref,
    tool: {
      name: $tool,
      version: $tool_version
    },
    axis_labels: {
      tier: $tier,
      protocol_mode: $protocol_mode,
      benchmark_family: $benchmark_family,
      transport_mode: $transport_mode,
      execution_class: $execution_class,
      comparison_axis: $comparison_axis,
      claim_scope: $claim_scope
    },
    mode: $mode,
    run_config: {
      threads: $threads,
      connections: $connections,
      warmup_seconds: $warmup_seconds,
      duration_seconds: $duration_seconds
    },
    seed_manifest_refs: {
      manifest_ref: $seed_manifest_ref,
      manifest_version: $seed_manifest_version
    }
  }' > "$REPRO_FILE"

jq -n \
  --arg throughput_rps "${THROUGHPUT_RPS:-}" \
  --arg latency_mean_us "${LATENCY_MEAN_US:-}" \
  --arg latency_p99_us "${LATENCY_P99_US:-}" \
  --arg duration_seconds "$DURATION_SECONDS" \
  --arg warmup_seconds "$WARMUP_SECONDS" \
  --arg note "Window-level evidence derived from measured run window only; warmup is excluded from metric aggregation." \
  '
  def num_or_null($v):
    if ($v == null) then null
    else (($v|tostring|gsub(",";".")|gsub("^[[:space:]]+|[[:space:]]+$";"")) as $t
      | if $t=="" then null else (($t|tonumber?) // null) end)
    end;

  {
    throughput_rps: num_or_null($throughput_rps),
    latency_mean_us: num_or_null($latency_mean_us),
    latency_p99_us: num_or_null($latency_p99_us),
    duration_seconds: num_or_null($duration_seconds),
    warmup_seconds: num_or_null($warmup_seconds),
    note: $note
  }' > "$STEADY_STATE_FILE"

echo "[step 9/9] Validating result artifact against schema..."
if command -v check-jsonschema &>/dev/null; then
  check-jsonschema --schemafile schemas/benchmark-result.schema.json "$RESULT_FILE" \
    && echo "[step 9/9] Schema validation PASSED" \
    || { echo "ERROR: result artifact failed schema validation — see above"; exit 1; }
elif command -v ajv &>/dev/null; then
  ajv validate -s schemas/benchmark-result.schema.json -d "$RESULT_FILE" \
    && echo "[step 9/9] Schema validation PASSED" \
    || { echo "ERROR: result artifact failed schema validation"; exit 1; }
else
  echo "WARN: No schema validator found (check-jsonschema or ajv). Install one for schema validation."
  echo "WARN: Skipping schema validation — result artifact may not conform to schema."
fi

echo "Done. claim_scope=$CLAIM_SCOPE -> $RESULT_CLAIM_SCOPE | results in $OUTPUT_DIR"
echo "Done. claim_scope=$CLAIM_SCOPE -- results in $OUTPUT_DIR"
