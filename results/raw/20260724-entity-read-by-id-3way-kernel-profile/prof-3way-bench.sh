#!/usr/bin/env bash
# 3-way kernel profile (bench side): community | quarkus-tuned | quarkus(hibernate).
# Per stack: launch target via constrained runner + async-profiler agent (Probe 2 -> collapsed),
# then system-wide cpu-clock perf on the target cpuset (Probe 3). Writes a per-stack ready/pid
# marker so the ROOT prober (prof-3way-root.sh) can run Probe 1 (raw_syscalls) in parallel.
set -uo pipefail
cd /home/bench/exeris-benchmarks
AP=/home/bench/async-profiler/lib/libasyncProfiler.so

run_stack() {
  local STACK="$1" LABEL="$2" EXTRA="$3"
  echo "############ STACK=$STACK LABEL=$LABEL $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  local COLL=/tmp/prof-${LABEL}.collapsed
  rm -f "$COLL" /tmp/prof-${LABEL}.javapid /tmp/prof-${LABEL}.ready \
        /tmp/perf-sys-${LABEL}.data /tmp/prof-${LABEL}.rps /home/bench/prof-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA} -agentpath:${AP}=start,event=cpu,collapsed,file=${COLL}" \
    bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 \
      --contract-id fixed_contract_runtime_h1_constrained_aggregate_1024m_4vcpu_v1 \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "${STACK}" --target-build jvm --jvm-gc parallel \
      --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/prof-${LABEL}-run </dev/null > /home/bench/prof-${LABEL}.log 2>&1 &
  local RUNNER=$!
  echo "[$LABEL] runner PID $RUNNER; waiting for measurement phase..."
  local JP="" i
  for i in $(seq 1 70); do
    JP=$(pgrep -x java | head -1)
    if [ -n "$JP" ] && grep -q "Measuring" /home/bench/prof-${LABEL}.log 2>/dev/null; then
      echo "[$LABEL] target PID $JP measuring (~$((i*10))s)"; break; fi
    sleep 10
  done
  if [ -z "$JP" ]; then echo "[$LABEL] ERROR: no target java PID (see prof-${LABEL}.log)"; kill "$RUNNER" 2>/dev/null; return 1; fi
  sleep 15   # settle into steady state
  echo "$JP" > /tmp/prof-${LABEL}.javapid
  touch /tmp/prof-${LABEL}.ready    # <-- signal root prober to start Probe 1 on this PID
  echo "[$LABEL] PROBE3: system-wide perf cpu-clock on cpuset 0-1,8-9 (30s)..."
  perf record -a -C 0-1,8-9 -g -e cpu-clock -F 999 -o /tmp/perf-sys-${LABEL}.data -- sleep 30 2>/dev/null \
    && echo "[$LABEL] perf-sys captured"
  echo "[$LABEL] waiting for runner to finish (async-profiler dumps at teardown)..."
  wait "$RUNNER" 2>/dev/null
  local RPS
  RPS=$(find /tmp/prof-${LABEL}-run -name result.json 2>/dev/null | head -1 | xargs -r jq -r ".metrics.throughput_rps // 0")
  echo "$RPS" > /tmp/prof-${LABEL}.rps
  echo "[$LABEL] DONE rps=$RPS collapsed=$(wc -l < "$COLL" 2>/dev/null || echo 0) stacks"
}

run_stack community     community "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run_stack quarkus-tuned qtuned    ""
run_stack quarkus       qhib      ""
echo "===== ALL 3 STACKS DONE $(date -u +%H:%M:%S)UTC ====="
for L in community qtuned qhib; do
  echo "$L rps=$(cat /tmp/prof-${L}.rps 2>/dev/null) collapsed=$(wc -l < /tmp/prof-${L}.collapsed 2>/dev/null || echo 0)"
done
