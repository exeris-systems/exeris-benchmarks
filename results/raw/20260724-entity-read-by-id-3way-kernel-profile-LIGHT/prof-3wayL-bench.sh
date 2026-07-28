#!/usr/bin/env bash
# LIGHT (single-read GET /api/v1/user?id=1, 125 B) 3-way kernel profile — bench side.
# Same infra as the heavy run; ONLY the contract-id changes (single_read vs aggregate). Adds Probe 4:
# mpstat %usr/%sys/%soft over the target cpuset, to reconcile against the report's sar denominator
# (§2's +39% kernel-time claim is a LIGHT claim measured as %sys+%soft of the cpuset, not per-PID).
set -uo pipefail
cd /home/bench/exeris-benchmarks
AP=/home/bench/async-profiler/lib/libasyncProfiler.so
CONTRACT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1

run_stack() {
  local STACK="$1" LABEL="$2" EXTRA="$3"
  echo "############ LIGHT STACK=$STACK LABEL=$LABEL $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  local COLL=/tmp/profL-${LABEL}.collapsed
  rm -f "$COLL" /tmp/profL-${LABEL}.javapid /tmp/profL-${LABEL}.ready \
        /tmp/perf-sysL-${LABEL}.data /tmp/profL-${LABEL}.rps /tmp/profL-${LABEL}.mpstat.txt /home/bench/profL-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA} -agentpath:${AP}=start,event=cpu,collapsed,file=${COLL}" \
    bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 \
      --contract-id "${CONTRACT}" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "${STACK}" --target-build jvm --jvm-gc parallel \
      --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/profL-${LABEL}-run </dev/null > /home/bench/profL-${LABEL}.log 2>&1 &
  local RUNNER=$!
  echo "[$LABEL] runner PID $RUNNER; waiting for measurement phase..."
  local JP="" i
  for i in $(seq 1 70); do
    JP=$(pgrep -x java | head -1)
    if [ -n "$JP" ] && grep -q "Measuring" /home/bench/profL-${LABEL}.log 2>/dev/null; then
      echo "[$LABEL] target PID $JP measuring (~$((i*10))s)"; break; fi
    sleep 10
  done
  if [ -z "$JP" ]; then echo "[$LABEL] ERROR: no target java PID"; kill "$RUNNER" 2>/dev/null; return 1; fi
  sleep 15
  echo "$JP" > /tmp/profL-${LABEL}.javapid
  touch /tmp/profL-${LABEL}.ready   # signal root prober (Probe 1)
  echo "[$LABEL] PROBE4: mpstat %usr/%sys/%soft over cpuset 0,1,8,9 (30s) + PROBE3 system-wide perf..."
  LC_ALL=C mpstat -P 0,1,8,9 30 1 > /tmp/profL-${LABEL}.mpstat.txt 2>&1 &
  local MPID=$!
  perf record -a -C 0-1,8-9 -g -e cpu-clock -F 999 -o /tmp/perf-sysL-${LABEL}.data -- sleep 30 2>/dev/null \
    && echo "[$LABEL] perf-sysL captured"
  wait "$MPID" 2>/dev/null; echo "[$LABEL] mpstat captured"
  echo "[$LABEL] waiting for runner to finish..."
  wait "$RUNNER" 2>/dev/null
  local RPS
  RPS=$(find /tmp/profL-${LABEL}-run -name result.json 2>/dev/null | head -1 | xargs -r jq -r ".metrics.throughput_rps // 0")
  echo "$RPS" > /tmp/profL-${LABEL}.rps
  echo "[$LABEL] DONE rps=$RPS collapsed=$(wc -l < "$COLL" 2>/dev/null || echo 0) stacks"
}

run_stack community     communityL "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run_stack quarkus-tuned qtunedL    ""
run_stack quarkus       qhibL      ""
echo "===== ALL 3 LIGHT STACKS DONE $(date -u +%H:%M:%S)UTC ====="
for L in communityL qtunedL qhibL; do
  echo "$L rps=$(cat /tmp/profL-${L}.rps 2>/dev/null) collapsed=$(wc -l < /tmp/profL-${L}.collapsed 2>/dev/null || echo 0)"
done
