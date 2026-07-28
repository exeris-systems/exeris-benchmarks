#!/usr/bin/env bash
# FUTEX / syscall-mix probe (bench side) — mechanism behind §4's "cheaper syscalls, not fewer".
# §4 established exeris does the MOST syscalls/req (37.4 vs 36.0 vs 25.7) yet spends the LEAST
# kernel-CPU/req (~82 vs 99 vs 87us). That is a per-syscall COST statement; this probe shows the MIX
# and the per-syscall time that produce it — in particular how much is futex (thread coordination /
# lock contention), the classic expensive-syscall culprit.
#
# perf trace needs the raw_syscalls tracepoints, which are root-only on this box, so the target runs
# as bench here and the root side (futex-root.sh) attaches via a /tmp marker — same split as the
# earlier kernel-profile run.
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_aggregate_1024m_4vcpu_v1   # HEAVY: the §4 workload

run() {
  local STACK=$1 LABEL=$2 EXTRA=$3
  echo "############ $STACK ($LABEL) $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /tmp/fx-${LABEL}.ready /tmp/fx-${LABEL}.javapid /tmp/fx-${LABEL}.rps /home/bench/fx-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA}" bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/fx-${LABEL}-run </dev/null > /home/bench/fx-${LABEL}.log 2>&1 &
  local R=$! i JP=""
  for i in $(seq 1 70); do
    JP=$(pgrep -x java | head -1)
    if [ -n "$JP" ] && grep -q "Measuring" /home/bench/fx-${LABEL}.log 2>/dev/null; then break; fi
    sleep 10
  done
  if [ -z "$JP" ]; then echo "[$LABEL] ERROR: no target pid"; kill "$R" 2>/dev/null; return 1; fi
  sleep 15
  echo "$JP" > /tmp/fx-${LABEL}.javapid
  touch /tmp/fx-${LABEL}.ready
  echo "[$LABEL] target pid $JP measuring; root prober attaching (perf trace -s, 20s)"
  # wait for the root side to finish its 20s window before letting the leg end
  for i in $(seq 1 24); do [ -f /tmp/fx-${LABEL}.done ] && break; sleep 5; done
  wait "$R" 2>/dev/null
  local RPS
  RPS=$(find /tmp/fx-${LABEL}-run -name result.json | head -1 | xargs -r jq -r '.metrics.throughput_rps//0')
  echo "$RPS" > /tmp/fx-${LABEL}.rps
  echo "[$LABEL] rps=$RPS (NOTE: perf trace runs for 20s of the 300s window; its overhead depresses this slightly)"
}

run community     exeris "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run quarkus-tuned qtuned ""
run quarkus       qhib   ""
echo "===== FUTEX BENCH SIDE DONE $(date -u +%H:%M:%S)UTC ====="
