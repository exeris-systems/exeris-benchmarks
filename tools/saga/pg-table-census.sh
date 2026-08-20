#!/usr/bin/env bash
# Per-table write census for the saga scenario, sampled on a wall clock.
#
# WHY: CONTRACT-v2 §2 requires "Domain persistence performed by steps MUST be identical
# across stacks (same writes, same datastore, same schema)". Nothing in the harness ever
# checked that. The 2026-08-20 shape-B campaign showed Postgres CPU per arm spanning
# 167 s (restate) to 905 s (spring-axon-embedded) against a component that is supposed to
# be doing the same work, and no artifact could say whether the difference was the engines'
# own persistence or an inequality in the domain writes.
#
# HOW: pg_stat_user_tables counters are cumulative and survive a container restart, so a
# delta across an arm's run window is exactly that arm's writes. Read-only - this samples
# a catalog view and mutates nothing, so it is safe to run alongside a live campaign.
#
# Attribution: match sample timestamps against the arm windows in the campaign's status.csv
# / per-rep run-metadata.json. The stack restart between reps does NOT reset these counters,
# which is what makes windowing work.
#
#   tools/saga/pg-table-census.sh [out.csv] [interval_s] [container]
set -uo pipefail
OUT="${1:-pg-table-census.csv}"
INTERVAL="${2:-60}"
CONTAINER="${3:-exeris-e2e-saga-postgres}"
echo "ts_utc,relname,n_tup_ins,n_tup_upd,n_tup_del,seq_scan,idx_scan" > "$OUT"
while true; do
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker exec "$CONTAINER" psql -U postgres -tAF, -c \
    "select relname, n_tup_ins, n_tup_upd, n_tup_del, coalesce(seq_scan,0), coalesce(idx_scan,0) from pg_stat_user_tables order by relname;" 2>/dev/null \
    | sed "s/^/${TS},/" >> "$OUT"
  sleep "$INTERVAL"
done
