#!/usr/bin/env bash
set -euo pipefail

# pg_stat_statements-wrapper.sh
# Captures and resets pg_stat_statements diagnostic data
# Usage:
#   source pg_stat_statements-wrapper.sh
#   pg_stat_statements_reset
#   pg_stat_statements_snapshot /path/to/output.json

DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-exeris-benchmark-db}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-benchmark_db}"
PGUSER="${PGUSER:-benchmark}"
PGPASSWORD="${PGPASSWORD:-benchmark}"

_managed_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps \
    --filter "name=^/${DB_CONTAINER_NAME}$" \
    --filter "status=running" \
    --format '{{.Names}}' | grep -qx "$DB_CONTAINER_NAME" || return 1
}

_run_psql() {
  if _managed_container_running; then
    docker exec -i "$DB_CONTAINER_NAME" \
      env PGPASSWORD="$PGPASSWORD" \
      psql -X -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDATABASE" "$@"
    return $?
  fi

  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD="$PGPASSWORD" psql -X -v ON_ERROR_STOP=1 \
      -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
    return $?
  fi

  echo "ERROR: pg_stat_statements_wrapper: psql is unavailable" >&2
  return 1
}

_check_extension_available() {
  _run_psql -t -A -c "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements';" 2>/dev/null | grep -q . || return 1
  local spl
  spl=$(_run_psql -t -A -c "SHOW shared_preload_libraries;" 2>/dev/null || echo "")
  echo "$spl" | grep -q 'pg_stat_statements' || return 1
}

_resolve_timing_column_profile() {
  if _run_psql -t -A -c "SELECT total_exec_time, mean_exec_time, max_exec_time FROM pg_stat_statements LIMIT 1;" >/dev/null 2>&1; then
    echo "exec_time_cols"
    return 0
  fi

  if _run_psql -t -A -c "SELECT total_time, mean_time, max_time FROM pg_stat_statements LIMIT 1;" >/dev/null 2>&1; then
    echo "legacy_time_cols"
    return 0
  fi

  echo "unknown"
  return 1
}

pg_stat_statements_reset() {
  # A reset that lands inside an open measurement window destroys that window's delta: the
  # final snapshot's call counts fall below the baseline's, every queryid fails the
  # `$dcalls > 0` filter, and the delta artifact is emitted as an empty-but-well-formed
  # `queries: []` — valid-looking evidence of nothing. Measured on campaign
  # 20260805T140104Z-spring-triad-n3: resets fired every 5-10 s and 34 of 58 arm-windows
  # came out empty.
  #
  # The guard is an inherited environment flag rather than call-site ordering on purpose:
  # run-comparative.sh nests copies of itself, so any single call site can be re-entered at
  # a depth the ordering does not control. While a window is open no shell caller can reset,
  # whatever invoked it.
  #
  # SCOPE: this covers shell-side callers only. The 5 s reset storm that produced the empty
  # deltas came from the Postgres container's own healthcheck, which never enters this
  # function — that is fixed in runtime/compose/entity-read-by-id-db.yml. Anything resetting
  # from inside the DB, or over a connection this wrapper did not open, is likewise invisible
  # here. Treat the flag as defence in depth, not as the guarantee.
  if [[ "${BENCH_PGSS_RESET_INHIBIT:-0}" == "1" ]]; then
    echo "INFO: pg_stat_statements_reset() suppressed — a measurement window is open (BENCH_PGSS_RESET_INHIBIT=1)" >&2
    return 0
  fi

  if ! _check_extension_available; then
    echo "INFO: pg_stat_statements not available (not in shared_preload_libraries or extension not installed); reset skipped" >&2
    return 0
  fi

  _run_psql -t -A -c "SELECT pg_stat_statements_reset();" >/dev/null 2>&1 || {
    echo "WARNING: pg_stat_statements_reset() failed; continue" >&2
    return 0
  }
  
  return 0
}

pg_stat_statements_snapshot() {
  local output_file="$1"
  local phase="${2:-benchmark}"
  local timestamp
  local server_version_num
  local column_profile
  local total_time_col
  local mean_time_col
  local max_time_col
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if ! _check_extension_available; then
    echo "INFO: pg_stat_statements not available (not in shared_preload_libraries or extension not installed); snapshot skipped" >&2
    cat > "$output_file" <<EOF
{
  "error": "pg_stat_statements extension not loaded",
  "timestamp": "$timestamp",
  "phase": "$phase",
  "server_version_num": "unknown",
  "column_profile": "unavailable",
  "queries": []
}
EOF
    return 0
  fi

  server_version_num="$(_run_psql -t -A -c "SHOW server_version_num;" 2>/dev/null | tr -d '[:space:]' || echo "")"
  if [[ -z "$server_version_num" ]]; then
    server_version_num="unknown"
  fi

  column_profile="$(_resolve_timing_column_profile 2>/dev/null || echo "unknown")"
  case "$column_profile" in
    exec_time_cols)
      total_time_col="total_exec_time"
      mean_time_col="mean_exec_time"
      max_time_col="max_exec_time"
      ;;
    legacy_time_cols)
      total_time_col="total_time"
      mean_time_col="mean_time"
      max_time_col="max_time"
      ;;
    *)
      cat > "$output_file" <<EOF
{
  "error": "failed to resolve pg_stat_statements timing columns",
  "timestamp": "$timestamp",
  "phase": "$phase",
  "server_version_num": "$server_version_num",
  "column_profile": "$column_profile",
  "queries": []
}
EOF
      return 0
      ;;
  esac

  # Emit query rows as server-side JSON. The GET /api/v1/users aggregate query text is
  # multi-line; a line-based capture (-F $'\t' piped through a per-line awk) splits a single
  # pg_stat_statements row across physical lines, corrupting the output (empty
  # calls/total_time_ms on the head line, a bogus "queryid":"FROM (" from continuation lines).
  # json_agg(row_to_json(...)) makes PostgreSQL escape embedded newlines as \n, so the value
  # is valid single-line JSON regardless of query text. queryid stays ::text (preserves int64
  # precision and is used as a jq object key by the comparative delta); calls and the *_time_ms
  # columns stay numeric so downstream delta arithmetic works.
  local queries_json
  queries_json=$(_run_psql -t -A -c \
    "SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.total_time_ms DESC), '[]'::json)::text
     FROM (
       SELECT queryid::text    AS queryid,
              query             AS query,
              calls             AS calls,
              ${total_time_col} AS total_time_ms,
              ${mean_time_col}  AS mean_time_ms,
              ${max_time_col}   AS max_time_ms
       FROM pg_stat_statements
       ORDER BY ${total_time_col} DESC
       LIMIT 20
     ) t;" 2>/dev/null | tr -d '\r\n')

  if [[ -z "$queries_json" ]]; then
    cat > "$output_file" <<EOF
{
  "error": "failed to query pg_stat_statements",
  "timestamp": "$timestamp",
  "phase": "$phase",
  "server_version_num": "$server_version_num",
  "column_profile": "$column_profile",
  "queries": []
}
EOF
    return 0
  fi

  printf '{"timestamp": "%s", "phase": "%s", "server_version_num": "%s", "column_profile": "%s", "queries": %s}\n' \
    "$timestamp" "$phase" "$server_version_num" "$column_profile" "$queries_json" > "$output_file"

  return 0
}

export -f pg_stat_statements_reset pg_stat_statements_snapshot
