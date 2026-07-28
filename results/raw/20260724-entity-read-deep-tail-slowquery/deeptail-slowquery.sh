#!/usr/bin/env bash
# ITEM 3 — log_min_duration_statement=20ms on the deep tail.
# Discriminator: are deep-tail events (p99.9+) DB-side or runtime-side? Every statement slower than
# 20 ms is logged by PostgreSQL; the app-side CO-free percentiles come from the same window. If the
# app sees 20 ms+ tail events while PG logs ~none, the deep tail is NOT the database.
#
# Scope + revert: uses ALTER DATABASE (per-database, NOT a global/system setting), applied before the
# target starts (it only affects NEW connections) and RESET in a trap on every exit path. PG runs in
# the exeris-benchmark-db container, so slow-statement lines land in `docker logs`.
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1
PSQL="docker exec -i exeris-benchmark-db psql -U benchmark -d benchmark_db -X -q"
THRESHOLD_MS="${THRESHOLD_MS:-20}"

revert() { echo "[revert] ALTER DATABASE benchmark_db RESET log_min_duration_statement"; echo "ALTER DATABASE benchmark_db RESET log_min_duration_statement;" | $PSQL 2>&1 | sed 's/^/    /'; }
trap revert EXIT INT TERM

echo "=== enabling slow-statement logging (per-database, revertible) ==="
echo "ALTER DATABASE benchmark_db SET log_min_duration_statement = ${THRESHOLD_MS};" | $PSQL 2>&1 | sed 's/^/    /'
echo "SELECT name, setting FROM pg_settings WHERE name='log_min_duration_statement';" | $PSQL 2>&1 | sed 's/^/    /'

run() {
  local STACK=$1 LABEL=$2 RATE=$3 EXTRA=$4
  echo "############ $STACK open-loop -R ${RATE} ($LABEL) $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /home/bench/dt-${LABEL}.log
  local T0; T0=$(date -u +%Y-%m-%dT%H:%M:%S)
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
  WRK2_TARGET_RPS="$RATE" WRK2_SKIP_DISCOVERY=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA}" bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 --driver wrk2 \
      --output-dir /tmp/dt-${LABEL}-run </dev/null > /home/bench/dt-${LABEL}.log 2>&1 &
  wait $! 2>/dev/null
  local rj wl
  rj=$(find /tmp/dt-${LABEL}-run -name result.json | head -1)
  echo "[$LABEL] attained_rps=$(jq -r '.metrics.throughput_rps // 0' "$rj" 2>/dev/null)"
  wl=$(find /tmp/dt-${LABEL}-run -name "*wrk2*.log" 2>/dev/null | head -1)
  echo "[$LABEL] app-side CO-free percentiles:"
  awk '/Latency Distribution \(HdrHistogram/{f=1} f&&/^ *[0-9]+\.[0-9]+%/{print} /^#\[Mean/{f=0}' "$wl" 2>/dev/null \
    | grep -E '50\.000|99\.000|99\.900|99\.990|99\.999|100\.000' | sed 's/^/      /'
  echo "[$LABEL] PG statements slower than ${THRESHOLD_MS}ms during the run:"
  docker logs exeris-benchmark-db --since "${T0}Z" 2>&1 | grep -c "duration:" | sed 's/^/      slow_statement_lines=/'
  docker logs exeris-benchmark-db --since "${T0}Z" 2>&1 | grep "duration:" | grep -oE "duration: [0-9.]+ ms" \
    | awk '{print $2}' | sort -n | awk '{a[NR]=$1} END{if(NR>0) printf "      slowest=%.1fms  median=%.1fms  n=%d\n", a[NR], a[int(NR/2)+1], NR; else print "      (none - deep tail is NOT database-side)"}'
  docker logs exeris-benchmark-db --since "${T0}Z" 2>&1 | grep "duration:" | tail -3 | cut -c1-180 | sed 's/^/      /'
}

run community     exerisDT 48000 "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run quarkus-tuned qtunedDT 30000 ""
echo "===== DEEP TAIL SLOW-QUERY DONE $(date -u +%H:%M:%S)UTC ====="
