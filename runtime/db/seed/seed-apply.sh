#!/usr/bin/env bash
# seed-apply.sh — Apply versioned migrations for exeris-community-app in order.
# Idempotent: safe to re-run against existing DB (all migrations use CREATE TABLE IF NOT EXISTS).
# Usage:
#   PGPASSWORD=benchmark bash runtime/db/seed/seed-apply.sh
#   DB_CONTAINER_NAME=mycontainer bash runtime/db/seed/seed-apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-benchmark_db}"
PGUSER="${PGUSER:-benchmark}"
export PGPASSWORD="${PGPASSWORD:-benchmark}"
DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-}"

MIGRATIONS=(
  "${SCRIPT_DIR}/v0_clean.sql"
  "${SCRIPT_DIR}/v1_core.sql"
  "${SCRIPT_DIR}/v2_shop.sql"
  "${SCRIPT_DIR}/v3_outbox_axon.sql"
)

run_sql_file() {
  local file="$1"
  if [[ -n "$DB_CONTAINER_NAME" ]] && docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    docker exec -i -e PGPASSWORD="$PGPASSWORD" "$DB_CONTAINER_NAME" \
      psql -U "$PGUSER" -d "$PGDATABASE" < "$file"
  elif command -v psql >/dev/null 2>&1; then
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -f "$file"
  else
    echo "ERROR: psql not available and DB_CONTAINER_NAME not running." >&2
    return 1
  fi
}

for migration in "${MIGRATIONS[@]}"; do
  if [[ ! -f "$migration" ]]; then
    echo "ERROR: Migration file not found: $migration" >&2
    exit 1
  fi
  echo "[seed-apply] Applying $(basename "$migration")..."
  run_sql_file "$migration"
  echo "[seed-apply] $(basename "$migration") — done."
done

echo "[seed-apply] All migrations applied."
