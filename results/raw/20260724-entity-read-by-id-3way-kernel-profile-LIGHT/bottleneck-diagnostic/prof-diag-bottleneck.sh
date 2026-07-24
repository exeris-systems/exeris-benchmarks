#!/usr/bin/env bash
# Bottleneck diagnostic: is the LIGHT throughput target-bound, loadgen-bound, or DB-bound? And how much
# of the profiled CPU/req was async-profiler overhead? Runs each stack CLEAN (no agent, no perf record)
# with mpstat -P ALL across all 16 CPUs during measurement, then groups busy% by cpuset:
#   target = 0,1,8,9 (phys cores 0,1) | loadgen = 2,3,10,11 (phys 2,3) | db/free = 4-7,12-15 (postgres).
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1

grp() {  # $1=label $2=name $3=comma-cpu-list
  awk -v cpus=",$3," -v name="$2" '
    /^Average:/ && $2 ~ /^[0-9]+$/ { if (index(cpus, ","$2",")>0){ bsum+=100-$NF; sys+=$5; soft+=$8; usr+=$3; n++ } }
    END{ if(n>0) printf "    %-9s cpus=%d  busy=%.1f%%  cores=%.2f  (%%usr=%.1f %%sys=%.1f %%soft=%.1f)\n", name, n, bsum/n, bsum/100, usr/n, sys/n, soft/n }' \
    /tmp/diag-${1}.mpstat.txt
}

run() {
  local STACK=$1 LABEL=$2 EXTRA=$3
  echo "############ $STACK ($LABEL) $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /tmp/diag-${LABEL}.mpstat.txt /tmp/diag-${LABEL}.rps /home/bench/diag-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA}" bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/diag-${LABEL}-run </dev/null > /home/bench/diag-${LABEL}.log 2>&1 &
  local R=$! i
  for i in $(seq 1 70); do grep -q "Measuring" /home/bench/diag-${LABEL}.log 2>/dev/null && break; sleep 10; done
  sleep 15
  echo "[$LABEL] mpstat -P ALL 30s (steady state)..."
  LC_ALL=C mpstat -P ALL 30 1 > /tmp/diag-${LABEL}.mpstat.txt 2>&1
  wait "$R" 2>/dev/null
  local f RPS CPS
  f=$(find /tmp/diag-${LABEL}-run -name resource-metrics.json | head -1)
  RPS=$(find /tmp/diag-${LABEL}-run -name result.json | head -1 | xargs -r jq -r '.metrics.throughput_rps//0')
  CPS=$(jq -r '.cpu_time_seconds' "$f" 2>/dev/null)
  echo "$RPS" > /tmp/diag-${LABEL}.rps
  awk -v r="$RPS" -v c="$CPS" 'BEGIN{ if(r>0) printf "[%s] CLEAN rps=%.0f  cpu_time_s=%.1f  CPU/req=%.1fus\n","'"$LABEL"'",r,c,c/(r*300)*1e6 }'
  grp "$LABEL" target  "0,1,8,9"
  grp "$LABEL" loadgen "2,3,10,11"
  grp "$LABEL" db_free "4,5,6,7,12,13,14,15"
}

run community     communityD "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run quarkus-tuned qtunedD    ""
run quarkus       qhibD      ""
echo "===== BOTTLENECK DIAG DONE $(date -u +%H:%M:%S)UTC ====="
echo "(compare CLEAN CPU/req here vs profiled 57/69/77us -> async-profiler overhead; compare busy per cpuset -> limiter)"
