#!/usr/bin/env bash
# REVERSE NORMALIZATION — robustness test for the §8 flagship claim.
#
# §8 equalizes both arms on FETCH-ALL and reports exeris leading heavy by +5-7%. The obvious reader
# objection is "you normalized to the setting that favours exeris". This runs both arms on the OPPOSITE
# fetch mode and asks one question: DOES THE RANKING DEPEND ON WHICH MODE YOU EQUALIZE TO?
#
# This is a ROBUSTNESS TEST, not an alternative primary normalization. Fetch-all remains the setting
# appropriate to the workload (the 10x10x10 aggregate is serialized whole -> every row is wanted;
# adaptive fetch exists for streaming large sets consumed incrementally).
#
# DESIGN TRAP AVOIDED: pgjdbc's adaptiveFetch only applies when the fetch size is > 0 -- it tunes a
# cursor's fetch size, and defaultRowFetchSize=0 means "unnamed portal, no cursor" (see the rationale
# comment in run-entity-read-by-id.sh). Flipping adaptiveFetch=true while leaving defaultRowFetchSize=0
# would be a NO-OP producing an identical query wire, i.e. a vacuous "no difference" result. The reverse
# arm therefore uses defaultRowFetchSize=100 + adaptiveFetch=true (cursor mode, adaptively sized).
# The value 100 is a free parameter, but it is IDENTICAL on both arms, so the ranking comparison is valid
# whatever it is.
#
# The fetch-all control is re-measured IN THIS SAME SESSION rather than reused from an earlier campaign:
# the counterbalanced cell showed ~1-2% session-to-session offsets, which is the same order as the effect
# being tested. Arm order is REVERSED between the two configs so any within-pair order effect partly
# cancels when the two GAPS are compared.
set -uo pipefail
cd /home/bench/exeris-benchmarks
CONTRACT=fixed_contract_runtime_h1_constrained_aggregate_1024m_4vcpu_v1   # HEAVY, 1024m budget

FETCH_ALL='preferQueryMode=extended&prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false'
ADAPTIVE='preferQueryMode=extended&prepareThreshold=1&defaultRowFetchSize=100&adaptiveFetch=true'

run() {
  local STACK=$1 LABEL=$2 PARAMS=$3 EXTRA=$4
  echo "############ $STACK [$LABEL] $(date -u +%H:%M:%S)UTC ############"
  echo "    params: ${PARAMS}"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -f /home/bench/rn-${LABEL}.log
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
  BENCH_PGJDBC_FAIR_PARAMS="$PARAMS" \
    nohup env JDK_JAVA_OPTIONS="${EXTRA}" bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id runtime-constrained-1024m-4vcpu-v1 --contract-id "$CONTRACT" \
      --profiles-json runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json \
      --scenario-json scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir /tmp/rn-${LABEL}-run </dev/null > /home/bench/rn-${LABEL}.log 2>&1 &
  wait $! 2>/dev/null
  # fail closed: prove the params actually reached the target
  local applied
  applied=$(grep -oE "pgjdbc fairness params \(identical on both arms\): .*" /home/bench/rn-${LABEL}.log | head -1 | sed 's/.*: //')
  if [ "$applied" != "$PARAMS" ]; then
    echo "    !! PARAM MISMATCH — requested [$PARAMS] but target got [$applied]"
  else
    echo "    verified applied: $applied"
  fi
  local f RPS CPS
  f=$(find /tmp/rn-${LABEL}-run -name resource-metrics.json | head -1)
  RPS=$(find /tmp/rn-${LABEL}-run -name result.json | head -1 | xargs -r jq -r '.metrics.throughput_rps//0')
  CPS=$(jq -r '.cpu_time_seconds' "$f" 2>/dev/null)
  echo "$RPS" > /tmp/rn-${LABEL}.rps
  awk -v r="$RPS" -v c="$CPS" -v l="$LABEL" 'BEGIN{ if(r>0) printf "[%s] rps=%.0f  cpu_time_s=%.1f  CPU/req=%.1fus\n", l,r,c,c/(r*300)*1e6 }'
}

# fetch-all control (arm order: exeris, qtuned)
run community     fa-exeris "$FETCH_ALL" "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run quarkus-tuned fa-qtuned "$FETCH_ALL" ""
# reverse normalization (arm order DELIBERATELY REVERSED: qtuned, exeris)
run quarkus-tuned ad-qtuned "$ADAPTIVE"  ""
run community     ad-exeris "$ADAPTIVE"  "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"

echo "===== REVERSE NORMALIZATION DONE $(date -u +%H:%M:%S)UTC ====="
FAE=$(cat /tmp/rn-fa-exeris.rps 2>/dev/null); FAQ=$(cat /tmp/rn-fa-qtuned.rps 2>/dev/null)
ADE=$(cat /tmp/rn-ad-exeris.rps 2>/dev/null); ADQ=$(cat /tmp/rn-ad-qtuned.rps 2>/dev/null)
awk -v fae="$FAE" -v faq="$FAQ" -v ade="$ADE" -v adq="$ADQ" 'BEGIN{
  printf "  FETCH-ALL  exeris=%.0f  qtuned=%.0f  gap=%+.1f%%\n", fae, faq, (fae-faq)/faq*100
  printf "  ADAPTIVE   exeris=%.0f  qtuned=%.0f  gap=%+.1f%%\n", ade, adq, (ade-adq)/adq*100
  print  "  READ: gap keeps its SIGN under both -> §8 conclusion is independent of normalization direction."
  print  "        gap FLIPS sign -> §8 must be restated as \"ranking depends on which fetch mode you equalize to\"."
}'
