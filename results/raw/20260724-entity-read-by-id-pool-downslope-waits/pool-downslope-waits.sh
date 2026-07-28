#!/usr/bin/env bash
# ITEM 2 — remove "inferred" from the pool-curve downslope.
# The aggregate pool curve is an inverted-U peaking at pool 32; WHY it declines past the peak is
# currently inferred. This samples pg_stat_activity at ~10 Hz during the measurement window and
# classifies every client backend by wait_event_type — so the downslope is explained by MEASURED
# waits (Lock / LWLock / Client / IO ...) rather than inference.
#
# Sampler design notes (traps avoided):
#  - pg_stat_activity is CACHED per transaction -> pg_stat_clear_snapshot() before every sample.
#  - one aggregated INSERT per sample (not one row per backend) into an UNLOGGED table, so the
#    sampler adds ~80 rows/s instead of ~1300 rows/s and does not perturb the workload it measures.
#  - single connection for the whole sample window (no per-sample connect cost).
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_aggregate_1024m_4vcpu_v1   # HEAVY: where the pool curve lives
POOLS="${POOLS:-32 64 128}"        # 32 = peak, 64/128 = downslope
SAMPLE_SECONDS="${SAMPLE_SECONDS:-60}"
HZ=10
SAMPLES=$(( SAMPLE_SECONDS * HZ ))
PSQL="docker exec -i exeris-benchmark-db psql -U benchmark -d benchmark_db -X -q"

sampler_sql() {
cat <<SQL
CREATE UNLOGGED TABLE IF NOT EXISTS bench_wait_samples(
  ts timestamptz, state text, wait_event_type text, wait_event text, cnt int);
TRUNCATE bench_wait_samples;
DO \$\$
DECLARE i int;
BEGIN
  FOR i IN 1..${SAMPLES} LOOP
    PERFORM pg_stat_clear_snapshot();
    INSERT INTO bench_wait_samples(ts, state, wait_event_type, wait_event, cnt)
    SELECT clock_timestamp(), state, wait_event_type, wait_event, count(*)
      FROM pg_stat_activity
     WHERE datname = current_database()
       AND pid <> pg_backend_pid()
       AND backend_type = 'client backend'
     GROUP BY state, wait_event_type, wait_event;
    PERFORM pg_sleep(0.1);
  END LOOP;
END \$\$;
SQL
}

report_sql() {
cat <<'SQL'
\echo '--- mean client backends per sample / total samples ---'
SELECT round(sum(cnt)::numeric / NULLIF(count(DISTINCT ts),0), 2) AS mean_backends_per_sample,
       count(DISTINCT ts) AS samples
  FROM bench_wait_samples;
\echo '--- wait_event_type distribution (share of backend-samples) ---'
SELECT coalesce(wait_event_type,'(running/none)') AS wait_type,
       sum(cnt) AS backend_samples,
       round(100.0*sum(cnt)/NULLIF((SELECT sum(cnt) FROM bench_wait_samples),0),2) AS pct
  FROM bench_wait_samples GROUP BY 1 ORDER BY backend_samples DESC;
\echo '--- REQUESTED FILTER: Lock / LWLock / Client detail ---'
SELECT wait_event_type, coalesce(wait_event,'-') AS wait_event,
       sum(cnt) AS backend_samples,
       round(100.0*sum(cnt)/NULLIF((SELECT sum(cnt) FROM bench_wait_samples),0),2) AS pct
  FROM bench_wait_samples
 WHERE wait_event_type IN ('Lock','LWLock','Client')
 GROUP BY 1,2 ORDER BY backend_samples DESC LIMIT 15;
\echo '--- state distribution (active vs idle-in-txn vs idle = pool oversubscription signal) ---'
SELECT coalesce(state,'?') AS state, sum(cnt) AS backend_samples,
       round(100.0*sum(cnt)/NULLIF((SELECT sum(cnt) FROM bench_wait_samples),0),2) AS pct
  FROM bench_wait_samples GROUP BY 1 ORDER BY backend_samples DESC;
SQL
}

run() {
  local STACK=$1 ARM=$2 POOL=$3 EXTRA=$4
  local LABEL="${ARM}-p${POOL}"
  echo "############ $STACK pool=${POOL} ($LABEL) $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /home/bench/pw-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE="$POOL" BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE="$POOL" \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA}" bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/pw-${LABEL}-run </dev/null > /home/bench/pw-${LABEL}.log 2>&1 &
  local R=$! i
  for i in $(seq 1 70); do grep -q "Measuring" /home/bench/pw-${LABEL}.log 2>/dev/null && break; sleep 10; done
  sleep 15
  echo "[$LABEL] sampling pg_stat_activity @${HZ}Hz for ${SAMPLE_SECONDS}s (${SAMPLES} samples)..."
  sampler_sql | $PSQL > /tmp/pw-${LABEL}.sampler.log 2>&1
  echo "[$LABEL] ===== WAIT PROFILE ====="
  report_sql | $PSQL 2>&1 | sed 's/^/    /'
  wait "$R" 2>/dev/null
  local RPS f
  RPS=$(find /tmp/pw-${LABEL}-run -name result.json | head -1 | xargs -r jq -r '.metrics.throughput_rps//0')
  f=$(find /tmp/pw-${LABEL}-run -name resource-metrics.json | head -1)
  echo "[$LABEL] rps=${RPS}  cpu_time_s=$(jq -r '.cpu_time_seconds' "$f" 2>/dev/null)"
}

for p in $POOLS; do run community     exeris "$p" "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"; done
for p in $POOLS; do run quarkus-tuned qtuned "$p" ""; done
echo "===== POOL DOWNSLOPE WAIT PROFILE DONE $(date -u +%H:%M:%S)UTC ====="
