#!/usr/bin/env bash
# STEP 2 — the REAL tail: open-loop wrk2 (fixed -R, CO-free percentiles = true service time).
# Closed-loop max (148ms) is coordinated-omission-inflated; this measures actual service-time p99.9/p99.99.
# Fair 3-way at a common sub-saturation 30k (below qhib's ~44k ceiling), + exeris at 48k (near its ~57k
# saturation, where the closed-loop tail lived). Attained rps must ~= offered, else the rung is not CO-free.
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1

run() {
  local STACK=$1 LABEL=$2 RATE=$3 EXTRA=$4
  echo "############ $STACK ($LABEL) open-loop wrk2 -R ${RATE} $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /home/bench/ol-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
  WRK2_TARGET_RPS="$RATE" WRK2_SKIP_DISCOVERY=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA}" bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --driver wrk2 \
      --output-dir /tmp/ol-${LABEL}-run </dev/null > /home/bench/ol-${LABEL}.log 2>&1 &
  wait $! 2>/dev/null
  local rj wl
  rj=$(find /tmp/ol-${LABEL}-run -name result.json | head -1)
  echo "[$LABEL] offered=${RATE}  attained_rps=$(jq -r '.metrics.throughput_rps // .throughput_rps // "?"' "$rj" 2>/dev/null)  (attained must ~= offered for CO-free validity)"
  echo "[$LABEL] CO-free service-time percentiles:"
  jq -r '(.metrics.latency_percentiles // .latency_percentiles // [])[] | "    \(.percentile)\t\(.latency_us/1000) ms"' "$rj" 2>/dev/null | head -12
  wl=$(find /tmp/ol-${LABEL}-run -name "*wrk2*.log" 2>/dev/null | head -1)
  [ -n "$wl" ] && { echo "[$LABEL] wrk2 raw dist:"; grep -iE "^ *(50|75|90|99|99.9|99.99|99.999)\.?[0-9]*%|Requests/sec|Latency|rate" "$wl" 2>/dev/null | head -12 | sed 's/^/      /'; }
  echo "[$LABEL] max GC pause during run (context): $(grep -E 'Pause' /home/bench/ol-${LABEL}.log 2>/dev/null | grep -oE '[0-9]+\.[0-9]+ms' | sed 's/ms//' | sort -n | tail -1)ms"
}

run community     c30  30000 "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run quarkus-tuned qt30 30000 ""
run quarkus       qh30 30000 ""
run community     c48  48000 "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
echo "===== OPEN-LOOP TAIL DONE $(date -u +%H:%M:%S)UTC ====="
