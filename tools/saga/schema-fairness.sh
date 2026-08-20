#!/usr/bin/env bash
# Schema-level fairness census for the shared domain tables.
#
# WHY THIS EXISTS SEPARATELY FROM pg-table-census.sh. CONTRACT-v2 §2 says domain persistence
# MUST be identical across stacks — "same writes, same datastore, same schema". The tuple
# census covers the writes. Nothing covered the schema, and the schema is where a single arm
# can impose cost on every other arm without writing a single extra row.
#
# Found by reading, then confirmed by this query on 2026-08-20 — which is the wrong order and
# the reason this script exists:
#
#   index              idx_scan      verdict
#   orders_pkey      19 406 608      essential
#   idx_orders_saga   1 436 417      used
#   idx_orders_status   209 427      used
#   idx_orders_lra            1      maintained by every arm, read by one
#   idx_orders_user           0      maintained by every arm, read by none
#
# Two of the five indexes on `orders` are never read, and `orders` takes 15 270 345 updates
# with ZERO of them HOT (idx_orders_status indexes `status`, and transitioning `status` is the
# saga's whole job, so HOT is disqualified unconditionally). Every one of those updates
# therefore rewrites all five index entries plus their WAL — 40 % of that maintenance for
# indexes nobody reads.
#
# A never-scanned index is NOT automatically droppable, and conflating the two would break
# the scenario. A UNIQUE or PRIMARY KEY index reports idx_scan = 0 while still doing real work
# on every insert: it enforces the constraint. users_email_key and user_principals_user_id_key
# are exactly this, and dropping them would change scenario semantics - the k6 username
# collision that produced 409 on exeris and 200/201 elsewhere depends on that uniqueness. So
# the census reports 'droppable' only for indexes never scanned AND neither unique nor primary.
# Everything else is declared, not removed.
#
# DIRECTION OF THE BIAS: because §2 makes the `orders` update count identical across arms, the
# tax is levied evenly. It inflates every arm's absolute Postgres cost and does NOT tilt the
# ranking. Declare it; do not treat it as a comparative finding.
#
# WHAT TO DO WITH THE OUTPUT: a never-scanned index is pure cost, and dropping it is cheaper
# and less invasive than a fillfactor change — it removes work rather than relaying pages, so
# it does not put a schema fence under existing numbers the way a page-layout change does.
#
#   tools/saga/schema-fairness.sh [out.json] [container]
set -uo pipefail
OUT="${1:-schema-fairness.json}"
CONTAINER="${2:-exeris-e2e-saga-postgres}"
SQL="
select json_build_object(
  'captured_at_utc', to_char(now() at time zone 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
  'indexes', (
    select json_agg(json_build_object(
      'table', s2.relname, 'index', s2.indexrelname, 'idx_scan', s2.idx_scan,
      'idx_tup_read', s2.idx_tup_read, 'size_bytes', pg_relation_size(s2.indexrelid),
      'is_unique', i.indisunique, 'is_primary', i.indisprimary,
      'droppable', (s2.idx_scan = 0 and not i.indisunique and not i.indisprimary),
      'never_scanned', (s2.idx_scan = 0)) order by s2.relname, s2.idx_scan desc)
    from pg_stat_user_indexes s2 join pg_index i on i.indexrelid = s2.indexrelid),
  'tables', (
    select json_agg(json_build_object(
      'table', c.relname, 'reloptions', c.reloptions,
      'n_tup_upd', s.n_tup_upd, 'n_tup_hot_upd', s.n_tup_hot_upd,
      'hot_pct', case when s.n_tup_upd > 0
                      then round(100.0 * s.n_tup_hot_upd / s.n_tup_upd, 2) else null end,
      'autovacuum_count', s.autovacuum_count) order by s.n_tup_upd desc nulls last)
    from pg_class c join pg_stat_user_tables s on s.relid = c.oid
    where c.relkind = 'r')
);"
docker exec "$CONTAINER" psql -U postgres -tAc "$SQL" > "$OUT" 2>/dev/null
if [ -s "$OUT" ]; then
  python3 -c "
import json,sys
d=json.load(open('$OUT'))
idx=d.get('indexes') or []
drop=[i for i in idx if i.get('droppable')]
keep=[i for i in idx if i['never_scanned'] and not i.get('droppable')]
print('schema census written to $OUT')
print('DROPPABLE - never scanned, not unique, not primary => pure maintenance cost: %d' % len(drop))
for i in drop: print('  %-24s %-34s %9d bytes' % (i['table'], i['index'], i['size_bytes']))
print('NOT droppable - never scanned but enforcing uniqueness/PK on insert: %d' % len(keep))
for i in keep: print('  %-24s %-34s %9d bytes' % (i['table'], i['index'], i['size_bytes']))
cold=[t for t in (d.get('tables') or []) if t.get('hot_pct') is not None and t['hot_pct'] < 50 and (t['n_tup_upd'] or 0) > 1000]
print('tables with < 50%% HOT updates (over 1000 updates):')
for t in cold: print('  %-24s upd=%-12d hot=%.1f%% reloptions=%s' % (t['table'], t['n_tup_upd'], t['hot_pct'], t['reloptions']))
" 2>/dev/null || cat "$OUT"
else
  echo "ERROR: schema census produced no output (is $CONTAINER running?)" >&2; exit 1
fi
