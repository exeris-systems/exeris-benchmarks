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
# n_tup_hot_upd is captured because it turned out to matter more than the update count. On
# the 2026-08-20 database, `orders` shows 15 270 345 updates and ZERO HOT updates - 0.0 % -
# while Axon's `token_entry` shows 93 654 342 of 93 664 288 HOT, 100.0 %. Every `orders`
# update therefore rewrites all five of its index entries (orders_pkey, idx_orders_user,
# idx_orders_status, idx_orders_saga, idx_orders_lra) plus the WAL for them. The cause is
# structural, not incidental: idx_orders_status indexes `status`, and a saga's whole job is
# to transition `status`, so every transition touches an indexed column and is disqualified
# from HOT unconditionally. `orders` also carries no fillfactor setting, so there is no free
# space on the page for a HOT chain even when no indexed column moves.
#
# Note also idx_orders_lra: it exists for one arm (quarkus + MicroProfile LRA) and every arm
# pays to maintain it on every non-HOT update of the shared domain table.
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
echo "ts_utc,relname,n_tup_ins,n_tup_upd,n_tup_hot_upd,n_tup_del,n_live_tup,n_dead_tup,autovacuum_count,seq_scan,idx_scan" > "$OUT"
while true; do
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker exec "$CONTAINER" psql -U postgres -tAF, -c \
    "select relname, n_tup_ins, n_tup_upd, n_tup_hot_upd, n_tup_del, n_live_tup, n_dead_tup, autovacuum_count, coalesce(seq_scan,0), coalesce(idx_scan,0) from pg_stat_user_tables order by relname;" 2>/dev/null \
    | sed "s/^/${TS},/" >> "$OUT"
  sleep "$INTERVAL"
done
