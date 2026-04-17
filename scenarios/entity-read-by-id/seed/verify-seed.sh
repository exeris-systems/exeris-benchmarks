#!/usr/bin/env bash
# verify-seed.sh — Verify entity-read-by-id relational seed state before a benchmark run.
# Checks: optional seed file hash, users/entities row counts, and minimum fan-out for first 10 users.
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

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

EXPECTED_ENTITY_COUNT=$(jq -r '.entity_count' "$MANIFEST")
EXPECTED_USER_COUNT=$(jq -r '.user_count // .entity_count' "$MANIFEST")
EXPECTED_SHA256=$(jq -r '.seed_file_sha256 // ""' "$MANIFEST")
SEED_FILE_REL=$(jq -r '.seed_file // ""' "$MANIFEST")
SEED_FILE="${REPO_ROOT}/${SEED_FILE_REL}"

managed_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps \
    --filter "name=^/exeris-benchmark-db$" \
    --filter "status=running" \
    --format '{{.Names}}' | grep -qx 'exeris-benchmark-db'
}

query_scalar() {
  local sql="$1"
  local output

  if managed_container_running; then
    if ! output=$(docker exec -e PGPASSWORD="$PGPASSWORD" exeris-benchmark-db psql -U "$PGUSER" -d "$PGDATABASE" -t -A -c "$sql" 2>&1); then
      echo "ERROR: Could not query DB via managed container exeris-benchmark-db. output: $output" >&2
      exit 1
    fi
    printf '%s' "$output"
    return 0
  fi

  if command -v psql >/dev/null 2>&1; then
    if ! output=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -A -c "$sql" 2>&1); then
      echo "ERROR: Could not query DB via host psql. psql output: $output" >&2
      exit 1
    fi
    printf '%s' "$output"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Could not query DB: host psql not found and docker is unavailable for fallback." >&2
    exit 1
  fi

  if ! output=$(docker exec -e PGPASSWORD="$PGPASSWORD" exeris-benchmark-db psql -U "$PGUSER" -d "$PGDATABASE" -t -A -c "$sql" 2>&1); then
    echo "ERROR: Could not query DB via docker fallback (container exeris-benchmark-db). output: $output" >&2
    exit 1
  fi

  printf '%s' "$output"
}

if [[ -n "$EXPECTED_SHA256" && "$EXPECTED_SHA256" != "skip" ]]; then
  ACTUAL_SHA256=$(sha256sum "$SEED_FILE" | awk '{print $1}')
  if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "SEED FILE HASH MISMATCH: expected $EXPECTED_SHA256 got $ACTUAL_SHA256" >&2
    exit 1
  fi
else
  echo "SEED FILE HASH CHECK: skipped (manifest seed_file_sha256=$EXPECTED_SHA256)"
fi

ACTUAL_USER_COUNT=$(query_scalar "SELECT COUNT(*) FROM users")
ACTUAL_ENTITY_COUNT=$(query_scalar "SELECT COUNT(*) FROM entities")

if ! [[ "$ACTUAL_USER_COUNT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Could not query user count. psql output: $ACTUAL_USER_COUNT" >&2
  exit 1
fi

if ! [[ "$ACTUAL_ENTITY_COUNT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Could not query entity count. psql output: $ACTUAL_ENTITY_COUNT" >&2
  exit 1
fi

if [[ "$ACTUAL_USER_COUNT" != "$EXPECTED_USER_COUNT" ]]; then
  echo "SEED USER COUNT MISMATCH: expected $EXPECTED_USER_COUNT, got $ACTUAL_USER_COUNT" >&2
  exit 1
fi

if [[ "$ACTUAL_ENTITY_COUNT" != "$EXPECTED_ENTITY_COUNT" ]]; then
  echo "SEED ENTITY COUNT MISMATCH: expected $EXPECTED_ENTITY_COUNT, got $ACTUAL_ENTITY_COUNT" >&2
  exit 1
fi

for user_id in $(seq 1 10); do
  friend_count=$(query_scalar "SELECT COUNT(*) FROM friendships WHERE user_id = $user_id")
  interest_count=$(query_scalar "SELECT COUNT(*) FROM user_interests WHERE user_id = $user_id")

  if ! [[ "$friend_count" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not query friend count for user_id=$user_id. output: $friend_count" >&2
    exit 1
  fi

  if ! [[ "$interest_count" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not query interest count for user_id=$user_id. output: $interest_count" >&2
    exit 1
  fi

  if (( friend_count < 10 )); then
    echo "SEED FRIENDSHIP COUNT MISMATCH: user_id=$user_id expected >=10, got $friend_count" >&2
    exit 1
  fi

  if (( interest_count < 10 )); then
    echo "SEED USER_INTEREST COUNT MISMATCH: user_id=$user_id expected >=10, got $interest_count" >&2
    exit 1
  fi
done

echo "SEED VERIFIED: users=$ACTUAL_USER_COUNT entities=$ACTUAL_ENTITY_COUNT relational fan-out OK, migration V1"
exit 0
