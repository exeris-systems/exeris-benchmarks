#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
USER_REPOSITORY_FILE="$REPO_ROOT/targets/exeris-community-app/src/main/java/eu/exeris/benchmarks/targets/exeriscommunity/infrastructure/persistence/UserRepository.java"
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

# The GET /api/v1/users aggregate (UserRepository#findTopUsersWithDetails) is composed of
# three constituent SQL statements. READ_TOP_USERS_SQL is a single-line String constant;
# READ_FRIENDS_SQL and READ_INTERESTS_SQL are Java text blocks ("""..."""). The previous
# extractor assumed a single multiline READ_TOP_USERS_JSON_SQL constant that no longer
# exists — see the aggregate constants and their kind (single-line vs text block) below.
AGGREGATE_SQL_CONSTANTS=(
  "READ_TOP_USERS_SQL:single"
  "READ_FRIENDS_SQL:multi"
  "READ_INTERESTS_SQL:multi"
)

# Extract a single-line `private static final String NAME = "...";` literal (unquoted body).
extract_single_line_sql_constant() {
  awk -v name="$1" '
    $0 ~ ("private static final String " name "[ \t]*=") {
      line = $0
      sub(/^[^"]*"/, "", line)   # strip up to and including the opening quote
      sub(/"[^"]*$/, "", line)   # strip the closing quote and trailing ";"
      print line
      exit
    }
  ' "$USER_REPOSITORY_FILE"
}

# Extract the body of a `private static final String NAME = """ ... """;` text block.
extract_multiline_sql_constant() {
  awk -v name="$1" '
    $0 ~ ("private static final String " name "[ \t]*=[ \t]*\"\"\"") { capture=1; next }
    capture && /"""/ { exit }
    capture { print }
  ' "$USER_REPOSITORY_FILE"
}

extract_aggregate_sql_constant() {
  local constant_name="$1" kind="$2"
  if [[ ! -f "$USER_REPOSITORY_FILE" ]]; then
    warn "Could not find UserRepository source at $USER_REPOSITORY_FILE"
    return 1
  fi
  case "$kind" in
    single) extract_single_line_sql_constant "$constant_name" ;;
    multi)  extract_multiline_sql_constant "$constant_name" ;;
    *) warn "Unknown SQL constant kind '$kind' for ${constant_name}"; return 1 ;;
  esac
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
  local settings_file version_file explain_file metadata_file pg_stat_statements_pre

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
aggregate_method=findTopUsersWithDetails
query_constants=READ_TOP_USERS_SQL,READ_FRIENDS_SQL,READ_INTERESTS_SQL
query_constant=READ_TOP_USERS_SQL
limits.users=10
limits.friends=10
limits.interests=10
capture_control=BENCH_CAPTURE_DB_EXPLAIN
pg_stat_statements_enabled=true
pg_stat_statements_max=10000
note=EXPLAIN targets the three named constants. The multi-user aggregate additionally issues inline row_number() windowed variants (queryFriendsForUsers/queryInterestsForUsers); pg_stat_statements measurement-delta captures the statements that actually executed.
EOF

  if [[ "$BENCH_CAPTURE_DB_EXPLAIN" == "1" ]]; then
    local entry constant_name kind constant_sql constant_sql_for_explain per_query_explain
    for entry in "${AGGREGATE_SQL_CONSTANTS[@]}"; do
      constant_name="${entry%%:*}"
      kind="${entry##*:}"

      if ! constant_sql="$(extract_aggregate_sql_constant "$constant_name" "$kind")"; then
        warn "Skipping EXPLAIN for ${constant_name} because SQL extraction failed"
        continue
      fi

      if [[ -z "${constant_sql//[[:space:]]/}" ]]; then
        warn "Skipping EXPLAIN for ${constant_name} because extracted SQL is empty"
        continue
      fi

      # Each '?' is a positional bind. Substitute a literal 10 (valid as both a user id and
      # a LIMIT, incl. inside CAST(? AS BIGINT)) so EXPLAIN (ANALYZE) can execute it.
      constant_sql_for_explain="$(printf '%s\n' "$constant_sql" | sed 's/?/10/g')"

      per_query_explain="$BENCH_SCENARIO_DIAGNOSTICS_DIR/users-endpoint-explain-analyze-buffers.${constant_name}.json"
      if ! run_psql -t -A > "$per_query_explain" <<SQL
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
$constant_sql_for_explain
;
SQL
      then
        warn "Failed to capture EXPLAIN diagnostics for ${constant_name}"
      fi

      # Backward-compat: keep the primary top-users plan at the legacy filename too.
      if [[ "$constant_name" == "READ_TOP_USERS_SQL" && -f "$per_query_explain" ]]; then
        cp -f "$per_query_explain" "$explain_file" 2>/dev/null || true
      fi
    done
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