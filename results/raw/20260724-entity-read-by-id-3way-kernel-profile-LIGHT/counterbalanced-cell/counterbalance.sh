#!/usr/bin/env bash
# COUNTERBALANCED CELL — quarkus first. Every prior 3-way ran community -> qtuned -> qhib, so target
# order is confounded with target identity (DB page-cache warmth, PG stats, thermal drift within the
# ~21 min sequence). This runs the REVERSE order (qhib -> qtuned -> community), identical in every
# other respect to prof-diag-bottleneck.sh (clean, no profiler, mpstat -P ALL), so the forward/reverse
# delta gives the DIRECTION and MAGNITUDE of the order confound.
# Compare against: results/raw/.../-LIGHT/bottleneck-diagnostic/ (forward order, same config).
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1

grp() {
  awk -v cpus=",$3," -v name="$2" '
    /^Average:/ && $2 ~ /^[0-9]+$/ { if (index(cpus, ","$2",")>0){ bsum+=100-$NF; sys+=$5; soft+=$8; usr+=$3; n++ } }
    END{ if(n>0) printf "    %-9s cpus=%d  busy=%.1f%%  cores=%.2f  (%%usr=%.1f %%sys=%.1f %%soft=%.1f)\n", name, n, bsum/n, bsum/100, usr/n, sys/n, soft/n }' \
    /tmp/cb-${1}.mpstat.txt
}

run() {
  local STACK=$1 LABEL=$2 EXTRA=$3 SLOT=$4
  echo "############ SLOT ${SLOT}: $STACK ($LABEL) $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /tmp/cb-${LABEL}.mpstat.txt /home/bench/cb-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA}" bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/cb-${LABEL}-run </dev/null > /home/bench/cb-${LABEL}.log 2>&1 &
  local R=$! i
  for i in $(seq 1 70); do grep -q "Measuring" /home/bench/cb-${LABEL}.log 2>/dev/null && break; sleep 10; done
  sleep 15
  LC_ALL=C mpstat -P ALL 30 1 > /tmp/cb-${LABEL}.mpstat.txt 2>&1
  wait "$R" 2>/dev/null
  local f RPS CPS
  f=$(find /tmp/cb-${LABEL}-run -name resource-metrics.json | head -1)
  RPS=$(find /tmp/cb-${LABEL}-run -name result.json | head -1 | xargs -r jq -r '.metrics.throughput_rps//0')
  CPS=$(jq -r '.cpu_time_seconds' "$f" 2>/dev/null)
  awk -v r="$RPS" -v c="$CPS" -v l="$LABEL" 'BEGIN{ if(r>0) printf "[%s] rps=%.0f  cpu_time_s=%.1f  CPU/req=%.1fus  RSS_avg=%s\n", l,r,c,c/(r*300)*1e6, "'"$(jq -r '.rss_kb_avg' "$f" 2>/dev/null)"'" }'
  grp "$LABEL" target  "0,1,8,9"
  grp "$LABEL" loadgen "2,3,10,11"
  grp "$LABEL" db_free "4,5,6,7,12,13,14,15"
}

# REVERSE of the forward cell (which was community, qtuned, qhib)
run quarkus       qhibCB   ""                                                              1
run quarkus-tuned qtunedCB ""                                                              2
run community     commCB   "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"    3
echo "===== COUNTERBALANCED CELL DONE $(date -u +%H:%M:%S)UTC ====="
echo "FORWARD (community,qtuned,qhib): rps 57830/48492/44334  CPU/req 52.8/66.9/74.6us"
echo "Compare per-stack: if the forward-vs-reverse delta is within run-to-run noise, order is not a confound."
