#!/usr/bin/env bash
# verify-seed.sh — Verify entity-read-by-id seed state before a benchmark run.
# Checks: seed file hash, row count in DB.
# Usage: PGPASSWORD=benchmark bash scenarios/entity-read-by-id/seed/verify-seed.sh
set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-benchmark_db}"
PGUSER="${PGUSER:-benchmark}"
PGPASSWORD="${PGPASSWORD:-benchmark}"
export PGPASSWORD

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$REPO_ROOT/scenarios/entity-read-by-id/seed/seed-manifest.json"
SEED_FILE="$REPO_ROOT/scenarios/entity-read-by-id/seed/entities.sql"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

EXPECTED_COUNT=$(jq -r '.entity_count' "$MANIFEST")
EXPECTED_SHA256=$(jq -r '.seed_file_sha256' "$MANIFEST")

ACTUAL_SHA256=$(sha256sum "$SEED_FILE" | awk '{print $1}')

if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "SEED FILE HASH MISMATCH: expected $EXPECTED_SHA256 got $ACTUAL_SHA256" >&2
  exit 1
fi

ACTUAL_COUNT=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -A -c "SELECT COUNT(*) FROM entities" 2>&1)

if ! [[ "$ACTUAL_COUNT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Could not query entity count. psql output: $ACTUAL_COUNT" >&2
  exit 1
fi

if [[ "$ACTUAL_COUNT" != "$EXPECTED_COUNT" ]]; then
  echo "SEED ROW COUNT MISMATCH: expected $EXPECTED_COUNT, got $ACTUAL_COUNT" >&2
  exit 1
fi

echo "SEED VERIFIED: $ACTUAL_COUNT rows, hash OK, migration V1"
exit 0
