#!/usr/bin/env bash
# Per-index scan census, sampled on a wall clock so index USE can be attributed to arms.
#
# WHY THIS IS SEPARATE FROM schema-fairness.sh. That script answers "which indexes does this
# database never read", globally and cumulatively. It cannot answer the question CONTRACT-v2 §2
# actually asks, which is per arm. idx_orders_saga has 1 436 417 scans and idx_orders_status
# 209 427 — but if the first is read only by the Axon arms (the column is named saga_id) and the
# second only by exeris, then neither is a shared index and neither is dead: both are
# SINGLE-ARM indexes on a shared domain table, which is precisely the defect class §2 forbids
# and precisely what a global counter cannot show.
#
# And once that is known, "droppable" stops being the right category. Dropping a single-arm
# index penalises that arm; keeping it taxes every arm. Neither option is neutral, so the
# decision has to be made on per-arm evidence rather than derived from a global counter.
#
# DELTAS, NOT pg_stat_reset(). idx_scan is cumulative, so a delta across an arm's window is that
# arm's index use — no mutation, safe to run beside a live campaign, and it does not destroy the
# cumulative history the schema census reads. Attribute by matching sample timestamps against
# the arm windows in the campaign's status.csv, exactly as tools/saga/pg-table-census.sh does.
#
#   tools/saga/pg-index-census.sh [out.csv] [interval_s] [container]
set -uo pipefail
OUT="${1:-pg-index-census.csv}"
INTERVAL="${2:-60}"
CONTAINER="${3:-exeris-e2e-saga-postgres}"
echo "ts_utc,relname,indexrelname,idx_scan,idx_tup_read,idx_tup_fetch" > "$OUT"
while true; do
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker exec "$CONTAINER" psql -U postgres -tAF, -c \
    "select relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch from pg_stat_user_indexes order by relname, indexrelname;" 2>/dev/null \
    | sed "s/^/${TS},/" >> "$OUT"
  sleep "$INTERVAL"
done
