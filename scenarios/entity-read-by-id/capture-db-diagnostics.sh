#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
USER_REPOSITORY_FILE="$REPO_ROOT/targets/exeris-community-app/src/main/java/eu/exeris/benchmarks/targets/exeriscommunity/UserRepository.java"
DB_CONTAINER_NAME="exeris-benchmark-db"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-benchmark_db}"
PGUSER="${PGUSER:-benchmark}"
PGPASSWORD="${PGPASSWORD:-benchmark}"
BENCH_SCENARIO_DIAGNOSTICS_DIR="${BENCH_SCENARIO_DIAGNOSTICS_DIR:-}"
BENCH_CAPTURE_DB_EXPLAIN="${BENCH_CAPTURE_DB_EXPLAIN:-0}"
BENCH_DB_DIAGNOSTICS_PHASE="${BENCH_DB_DIAGNOSTICS_PHASE:-pre-benchmark}"
export PGPASSWORD

if [[ -z "$BENCH_SCENARIO_DIAGNOSTICS_DIR" ]]; then
  exit 0
fi

warn() {
  echo "WARNING: $*" >&2
}

managed_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps \
    --filter "name=^/${DB_CONTAINER_NAME}$" \
    --filter "status=running" \
    --format '{{.Names}}' | grep -qx "$DB_CONTAINER_NAME"
}

run_psql() {
  if managed_container_running; then
    docker exec -i "$DB_CONTAINER_NAME" \
      env PGPASSWORD="$PGPASSWORD" \
      psql -X -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDATABASE" "$@"
    return $?
  fi

  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD="$PGPASSWORD" psql -X -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
    return $?
  fi

  warn "Could not capture DB diagnostics: managed container is not running and host psql is unavailable"
  return 1
}

read_top_users_sql() {
  if [[ ! -f "$USER_REPOSITORY_FILE" ]]; then
    warn "Could not find UserRepository source at $USER_REPOSITORY_FILE"
    return 1
  fi

  awk '
    /private static final String READ_TOP_USERS_JSON_SQL = """/ { capture=1; next }
    capture && /""";/ { capture=0; exit }
    capture { print }
  ' "$USER_REPOSITORY_FILE"
}

# Enable pg_stat_statements extension if not already enabled
enable_pg_stat_statements() {
  run_psql -t -A -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" >/dev/null 2>&1 || {
    run_psql -t -A -c "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements';" >/dev/null 2>&1 || {
      warn "pg_stat_statements extension could not be enabled (may require superuser)"
      return 0
    }
  }
  return 0
}

mkdir -p "$BENCH_SCENARIO_DIAGNOSTICS_DIR"

capture_pre_benchmark_diagnostics() {
  local settings_file version_file explain_file metadata_file pg_stat_statements_pre top_users_sql top_users_sql_for_explain

  settings_file="$BENCH_SCENARIO_DIAGNOSTICS_DIR/postgres-settings.tsv"
  version_file="$BENCH_SCENARIO_DIAGNOSTICS_DIR/postgres-version.txt"
  explain_file="$BENCH_SCENARIO_DIAGNOSTICS_DIR/users-endpoint-explain-analyze-buffers.json"
  metadata_file="$BENCH_SCENARIO_DIAGNOSTICS_DIR/users-endpoint-query-metadata.txt"
  pg_stat_statements_pre="$BENCH_SCENARIO_DIAGNOSTICS_DIR/pg_stat_statements-pre-benchmark.json"

  printf 'name\tsetting\tunit\tsource\n' > "$settings_file"
  if ! run_psql -t -A -F $'\t' -c "
    SELECT name, setting, COALESCE(unit, ''), source
    FROM pg_settings
    WHERE name IN ('max_connections', 'shared_buffers', 'work_mem')
    ORDER BY CASE name
      WHEN 'max_connections' THEN 1
      WHEN 'shared_buffers' THEN 2
      WHEN 'work_mem' THEN 3
      ELSE 100
    END
  " >> "$settings_file"; then
    warn "Failed to capture postgres settings snapshot"
  fi

  if ! run_psql -t -A -c "SELECT version();" > "$version_file"; then
    warn "Failed to capture postgres version snapshot"
  fi

  if source "$SCRIPT_DIR/pg_stat_statements-wrapper.sh"; then
    enable_pg_stat_statements || true
    pg_stat_statements_reset || true
    pg_stat_statements_snapshot "$pg_stat_statements_pre" "pre-benchmark" || true
  else
    warn "Failed to source pg_stat_statements wrapper for pre-benchmark snapshot"
  fi

  cat > "$metadata_file" <<'EOF'
endpoint=/api/v1/users
query_constant=READ_TOP_USERS_JSON_SQL
limits.users=10
limits.friends=10
limits.interests=10
capture_control=BENCH_CAPTURE_DB_EXPLAIN
pg_stat_statements_enabled=true
pg_stat_statements_max=10000
EOF

  if [[ "$BENCH_CAPTURE_DB_EXPLAIN" == "1" ]]; then
    if ! top_users_sql="$(read_top_users_sql)"; then
      warn "Skipping EXPLAIN capture because SQL extraction failed"
      return 0
    fi

    if [[ -z "$top_users_sql" ]]; then
      warn "Skipping EXPLAIN capture because extracted SQL is empty"
      return 0
    fi

    top_users_sql_for_explain="$(printf '%s\n' "$top_users_sql" | perl -pe 'BEGIN { $count = 0 } s/\?/(++$count <= 3) ? "10" : "?"/ge')"

    if ! run_psql -t -A > "$explain_file" <<SQL
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
$top_users_sql_for_explain
;
SQL
    then
      warn "Failed to capture EXPLAIN diagnostics"
    fi
  fi
}

capture_post_measurement_pg_stats() {
  local pg_stat_statements_post
  pg_stat_statements_post="$BENCH_SCENARIO_DIAGNOSTICS_DIR/pg_stat_statements-post-measurement.json"

  if source "$SCRIPT_DIR/pg_stat_statements-wrapper.sh"; then
    enable_pg_stat_statements || true
    pg_stat_statements_snapshot "$pg_stat_statements_post" "post-measurement" || true
  else
    warn "Failed to source pg_stat_statements wrapper for post-measurement snapshot"
  fi
}

case "$BENCH_DB_DIAGNOSTICS_PHASE" in
  pre-benchmark)
    capture_pre_benchmark_diagnostics
    ;;
  post-measurement)
    capture_post_measurement_pg_stats
    ;;
  *)
    warn "Unknown BENCH_DB_DIAGNOSTICS_PHASE='$BENCH_DB_DIAGNOSTICS_PHASE'; skipping capture"
    ;;
esac