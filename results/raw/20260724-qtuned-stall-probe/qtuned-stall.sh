#!/usr/bin/env bash
# quarkus-tuned ~1s stall — settle ALL THREE variants in one run per heap.
#
# Variants:
#   (1) GC pause                -> -Xlog:gc
#   (2) non-GC safepoint stall  -> -Xlog:safepoint
#   (3) blocking wait (Agroal pool acquisition / socket) -> JFR
# JFR at DEFAULT settings thresholds ThreadPark / JavaMonitorWait / SocketRead|Write at ~20ms and
# always records GC pauses, so a ~1s event cannot hide; overhead ~1%. Agroal pool acquisition parks,
# so a pool wait surfaces as jdk.ThreadPark / jdk.JavaMonitorWait. Pool DEBUG logging was rejected:
# at 30k rps it would flood and perturb the very stall being measured.
#
# Already excluded before this run: hard pool TIMEOUT (both prior qtuned runs had 0 errors; a timeout
# throws and fails the request). So the ~1s is a WAIT, not a timeout.
#
# quarkus-tuned is Agroal + pgjdbc (pure JDBC, no ORM), quarkus.vertx.event-loops-pool-size=1.
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1
JFR_BIN=/opt/jdk26/bin/jfr

# top durations for a JFR event type, normalized to ms
top_durations() {
  local f="$1" ev="$2" n="${3:-6}"
  "$JFR_BIN" print --events "$ev" "$f" 2>/dev/null \
    | grep -E "^\s*duration\s*=" \
    | awk '{v=$3; u=$4;
            if(u=="s") v*=1000; else if(u=="us") v/=1000; else if(u=="ns") v/=1000000;
            print v}' \
    | sort -rn | head -"$n" | awk -v ev="$ev" '{printf "      %-22s %.1f ms\n", (NR==1?ev":":""), $1}'
}

run() {
  local HEAP=$1 LABEL=$2
  echo "############ quarkus-tuned heap=${HEAP}m open-loop -R 30000 ($LABEL) $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /tmp/qs-${LABEL}.gc.log /tmp/qs-${LABEL}.jfr /home/bench/qs-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
  WRK2_TARGET_RPS=30000 WRK2_SKIP_DISCOVERY=1 \
    nohup env JDK_JAVA_OPTIONS="-Xlog:gc,safepoint:file=/tmp/qs-${LABEL}.gc.log:time,uptimemillis,level,tags -XX:StartFlightRecording=settings=default,filename=/tmp/qs-${LABEL}.jfr,dumponexit=true" \
    bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime quarkus-tuned --target-build jvm --jvm-gc parallel \
      --jvm-xms-mb "$HEAP" --jvm-xmx-mb "$HEAP" \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 --driver wrk2 \
      --output-dir /tmp/qs-${LABEL}-run </dev/null > /home/bench/qs-${LABEL}.log 2>&1 &
  wait $! 2>/dev/null

  local rj wl
  rj=$(find /tmp/qs-${LABEL}-run -name result.json | head -1)
  wl=$(find /tmp/qs-${LABEL}-run -name "*wrk2*.log" 2>/dev/null | head -1)
  echo "[$LABEL] attained_rps=$(jq -r '.metrics.throughput_rps // 0' "$rj" 2>/dev/null)  errors=$(jq -r '.metrics.total_errors // 0' "$rj" 2>/dev/null)"
  echo "[$LABEL] app-side CO-free percentiles (does the ~1s stall reproduce at this heap?):"
  awk '/Latency Distribution \(HdrHistogram/{f=1} f&&/^ *[0-9]+\.[0-9]+%/{print} /^#\[Mean/{f=0}' "$wl" 2>/dev/null \
    | grep -E '50\.000|99\.000|99\.900|99\.990|99\.999|100\.000' | sed 's/^/      /'

  echo "[$LABEL] VARIANT 1 - GC pauses:"
  grep -E "Pause" /tmp/qs-${LABEL}.gc.log 2>/dev/null | grep -oE "[0-9]+\.[0-9]+ms" | sed 's/ms//' | sort -n > /tmp/qs-${LABEL}.pauses
  awk 'END{if(NR>0) printf "      count=%d  MAX=%.2f ms\n", NR, $0; else print "      (no pause lines)"}' /tmp/qs-${LABEL}.pauses
  echo "      5 longest: $(tail -5 /tmp/qs-${LABEL}.pauses | tr '\n' ' ')"
  echo "      Full GCs: $(grep -c 'Pause Full' /tmp/qs-${LABEL}.gc.log 2>/dev/null)"

  echo "[$LABEL] VARIANT 2 - safepoint stalls (max total stop):"
  grep -oE "Total: [0-9]+ ns" /tmp/qs-${LABEL}.gc.log 2>/dev/null | awk '{print $2/1000000}' | sort -rn | head -3 \
    | awk '{printf "      %.2f ms\n", $1}'

  echo "[$LABEL] VARIANT 3 - blocking waits (JFR, threshold ~20ms):"
  if [ -s /tmp/qs-${LABEL}.jfr ]; then
    "$JFR_BIN" summary /tmp/qs-${LABEL}.jfr 2>/dev/null \
      | grep -iE "ThreadPark|JavaMonitorWait|JavaMonitorEnter|SocketRead|SocketWrite|GCPhasePause|ThreadSleep" | sed 's/^/      /'
    for ev in jdk.ThreadPark jdk.JavaMonitorWait jdk.JavaMonitorEnter jdk.SocketRead jdk.SocketWrite; do
      top_durations /tmp/qs-${LABEL}.jfr "$ev" 4
    done
  else
    echo "      (no JFR produced)"
  fi
}

run 256 h256
run 768 h768
echo "===== QTUNED STALL PROBE DONE $(date -u +%H:%M:%S)UTC ====="
echo "READ: ~1s in GC pauses -> heap-driven. ~1s only in ThreadPark/MonitorWait -> pool/lock wait."
echo "      ~1s in SocketRead -> downstream/network wait. Nothing ~1s anywhere -> not a single stall event."
