#!/usr/bin/env bash
# STEP 1 — classify the exeris LIGHT closed-loop tail: GC or scheduling? + heap counterfactual (256 vs 768).
# -Xlog:gc+pause=info captures every pause with a timestamp. Blunt discriminator: max GC pause vs wrk max
# latency. If a ~100-163ms pause exists -> GC. If max pause < ~20ms -> the 163ms is a non-GC stall
# (scheduling / SMT-sibling / park-unpark) surfacing as coordinated-omission pileup. Closed-loop max is a
# SMOKE ALARM here, not the measurement (Step 2 = open-loop wrk2).
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1

run() {
  local HEAP=$1 LABEL=$2
  echo "############ exeris LIGHT closed-loop heap=${HEAP}m ($LABEL) $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /tmp/gc-${LABEL}.log /home/bench/tail-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="-Dexeris.persistence.admission.queueDepthAllowanceRatio=32 -Xlog:gc,safepoint:file=/tmp/gc-${LABEL}.log:time,uptimemillis,level,tags" \
    bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime community --target-build jvm --jvm-gc parallel \
      --jvm-xms-mb "${HEAP}" --jvm-xmx-mb "${HEAP}" \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/tail-${LABEL}-run </dev/null > /home/bench/tail-${LABEL}.log 2>&1 &
  wait $! 2>/dev/null
  local RPS w
  RPS=$(find /tmp/tail-${LABEL}-run -name result.json | head -1 | xargs -r jq -r '.metrics.throughput_rps//0')
  w=$(find /tmp/tail-${LABEL}-run -name driver-wrk.log | head -1)
  echo "[$LABEL] rps=$RPS  (OOM check: $(grep -ciE 'OutOfMemory|oom|killed' /home/bench/tail-${LABEL}.log 2>/dev/null))"
  echo "[$LABEL] wrk closed-loop latency (--latency, CO-inflated):"
  grep -iE "Thread Stats|Latency |[0-9.]+%|requests in|Socket errors" "$w" 2>/dev/null | sed 's/^/    /'
  echo "[$LABEL] GC pause classification (parallel GC):"
  grep -E "Pause" /tmp/gc-${LABEL}.log 2>/dev/null | grep -oE "[0-9]+\.[0-9]+ms" | sed 's/ms//' | sort -n > /tmp/gc-${LABEL}.pauses
  awk '{a[NR]=$1; s+=$1} END{n=NR; if(n>0){printf "    pauses=%d  total_gc=%.0fms  mean=%.3fms  p99=%.2fms  MAX=%.2fms\n", n,s,s/n,a[int(n*0.99)>0?int(n*0.99):1],a[n]} else print "    (no pause lines)"}' /tmp/gc-${LABEL}.pauses
  echo "    pause histogram (ms buckets):"
  awk '{b=($1<1)?"<1":($1<5)?"1-5":($1<10)?"5-10":($1<20)?"10-20":($1<50)?"20-50":($1<100)?"50-100":">100"; c[b]++} END{split("<1 1-5 5-10 10-20 20-50 50-100 >100",o," "); for(i=1;i<=7;i++) if(c[o[i]]) printf "      %-7s %d\n",o[i],c[o[i]]}' /tmp/gc-${LABEL}.pauses
  echo "    5 longest pauses (ms): $(tail -5 /tmp/gc-${LABEL}.pauses | tr '\n' ' ')"
  echo "    Full GCs: $(grep -c 'Pause Full' /tmp/gc-${LABEL}.log 2>/dev/null)"
  echo "    safepoint stalls (catches NON-GC stops): 2 sample lines + max total-stop:"
  grep -i "safepoint" /tmp/gc-${LABEL}.log 2>/dev/null | grep -iE "stopped|Total:|At safepoint" | tail -2 | sed 's/^/      /'
  grep -oE "Total: [0-9]+ ns|stopped: [0-9.]+ (seconds|ms)|threads were stopped: [0-9.]+" /tmp/gc-${LABEL}.log 2>/dev/null \
    | grep -oE "[0-9.]+ (ns|ms|seconds)?" | awk '{v=$1; u=$2; if(u=="ns")v/=1e6; else if(u=="seconds")v*=1000; if(v>mx)mx=v} END{printf "      max safepoint stop ~= %.2f ms\n", mx}'
}

run 256 h256
run 768 h768
echo "===== TAIL CLASSIFIER DONE $(date -u +%H:%M:%S)UTC ====="
echo "VERDICT RULE: max GC pause ~= wrk Max -> GC-driven. max pause << wrk Max -> non-GC stall (CO pileup)."
