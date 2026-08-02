#!/usr/bin/env bash
# Spring hosting triad, n=3 — driver for run-full-triad-ab-ba.sh.
#
# Three arms of ONE Spring + JPA application, differing only in how requests
# reach it:
#   spring-hibernate       Tomcat + Spring MVC          (never touches Exeris)
#   spring-on-exeris       Exeris compatibility ingress (Spring MVC over the compat dispatcher)
#   spring-on-exeris-pure  Exeris native web layer      (@ExerisRoute, no compat dispatcher)
#
# Pair 3 (compat vs pure) is the cleanest form of the Pure-vs-Compat axis in this
# scenario: transport, kernel and carrier are identical on both sides, so the
# delta attributes to the compat dispatcher rather than to hosting as a whole.
#
# Shape mirrors the C1 triad exactly so the two campaigns stay comparable:
# repeat as the OUTER loop, 3 repeats x {heavy, light} x 3 pairs x {ab, ba} = 36 leaves.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
ROOT="results/raw/entity-read-by-id/${CAMPAIGN_TS}-spring-triad-n3"
mkdir -p "$ROOT"
cp -- "$0" "$ROOT/driver.sh"

export BENCH_TRIAD_PAIRS="1-tomcat-vs-compat:spring-hibernate:spring-on-exeris:1:9001:9004;2-tomcat-vs-pure:spring-hibernate:spring-on-exeris-pure:2:9001:9005;3-compat-vs-pure:spring-on-exeris:spring-on-exeris-pure:3:9004:9005"

# All three arms consume $SPRING_JAVA_OPTS (see runtime/drivers/env/spring-runtime*.env),
# so one heap setting gives iso-heap across the whole triad by construction.
export BENCH_TOTAL_MEMORY_MB=2048
export BENCH_SPRING_HEAP_MB=1280
export BENCH_DB_POOL_MIN_SIZE=16
export BENCH_DB_POOL_MAX_SIZE=256
export BENCH_ENABLE_NATIVE_MEMORY_TRACKING=1
export BENCH_NATIVE_MEMORY_TRACKING_LEVEL=summary

# Campaign-level JFR + safepoint logs are OFF for this campaign, deliberately.
# That block keys its filenames to three fixed target families (exeris/spring/
# quarkus) via three JAVA_OPTS variables. Here all three arms are "spring" and
# share SPRING_JAVA_OPTS, so all three would write to the SAME
# diagnostics/spring-hibernate.jfr and silently overwrite one another.
# Per-leaf recordings are unaffected: run-comparative.sh starts its own via
# `jcmd JFR.start` when no recording is already present, and those are the
# authoritative artefacts anyway. Side benefit: no 60 GB safepoint logs and no
# 6 GB campaign recordings, which is most of what C1's disk went to.
export BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS=0

export WARMUP_SECONDS=300
export MEASUREMENT_SECONDS=900

declare -A CONTRACT=(
  [heavy]=fixed_contract_cross_runtime_h1_v2
  [light]=fixed_contract_cross_runtime_h1_single_read_v1
)

for repeat in 01 02 03; do
  for kind in heavy light; do
    out="${ROOT}/repeat${repeat}/${kind}"
    mkdir -p "$out"
    echo "=============================================================="
    echo "repeat${repeat} / ${kind} / contract=${CONTRACT[$kind]}"
    echo "started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=============================================================="
    BENCH_CAMPAIGN_OUTPUT_DIR_OVERRIDE="$out" \
    BENCH_CONTRACT_ID="${CONTRACT[$kind]}" \
      ./scripts/run-full-triad-ab-ba.sh 2>&1 | tee "${out}/campaign.log"
  done
done

echo "=============================================================="
echo "SPRING TRIAD CAMPAIGN COMPLETE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "root: ${ROOT}"
echo "=============================================================="
