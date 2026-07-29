#!/usr/bin/env bash
# 3-way MATCHED-HEAP FOOTPRINT DECOMPOSITION — bench side.
#
# QUESTION (triad report §5, the one open question that section declares):
#   At a matched 256 MB heap Exeris still holds the lowest RSS (~1.2x vs quarkus-tuned,
#   ~1.5-1.65x vs hibernate). WHERE does that advantage live — in fewer RESIDENT HEAP
#   pages (a smaller live set), or in a smaller NON-HEAP footprint?
#   §5 states a falsifiable hypothesis: it is the heap. If so, the result CONTRADICTS
#   the "off-heap design => smaller non-heap" reading. Measure it, do not assert it.
#
# WHY A NEW RUN (existing artifacts cannot answer it):
#   - The 2026-07-24 matched-heap profiles carry NO NMT at all: the constrained path
#     skipped jcmd wholesale ("would spike memory past MemoryMax and OOM the run").
#   - No campaign anywhere captured smaps PER REGION — only smaps_rollup, a SUM.
#   §5's claim that both were "already enabled" does not hold; this run enables them.
#
# DELIBERATE DIFFERENCES FROM THE 2026-07-24 PROFILE RUNS:
#   1. NO async-profiler agent. §5 itself notes the agent inflates absolute RSS — which
#      is precisely the quantity under test. Those runs could state ratios only; this
#      one is built to state levels too.
#   2. -XX:NativeMemoryTracking=detail on EVERY arm. `summary` has no virtual memory
#      map, hence no heap address range, hence no attribution. detail costs native
#      memory; it is applied equally to all arms and its self-cost is read back from
#      NMT's own "tracking overhead" line by the extractor.
# Everything else (profile, scenario, contracts, pins, GC, heap, pool) is held identical
# to the 2026-07-24 runs so the numbers sit alongside the ones §5 already quotes.
#
# TRACK: exploratory / descriptive. This is NOT a gated comparative campaign — no
# stage7 gate artifacts, no AB/BA order control, n=1 per cell. Footprint per arm is a
# measured fact; treat cross-arm deltas as directional.

# REPEATS: the whole 6-cell matrix is re-run end to end, not each cell three times in a
# row. That is the sweep report's "interleaved repeats" design — it controls TIME DRIFT
# (cache/thermal/background state moving over hours). It does NOT control ARM ORDER:
# within every repeat the order is community -> qtuned -> qhib, so an order effect stays
# confounded exactly as it is in the 2026-07-22 sweep. Do not describe n=3 here as
# order-controlled; the AB/BA machinery lives in the gated comparative path, not this one.
set -uo pipefail
cd /home/bench/exeris-benchmarks || exit 1

REPEAT="${1:?Usage: $0 <repeat-index>   (e.g. 1, 2, 3)}"
[[ "$REPEAT" =~ ^[0-9]+$ ]] || { echo "repeat index must be numeric, got: $REPEAT" >&2; exit 1; }

PROFILE_ID=runtime-constrained-1024m-4vcpu-v1
PROFILES_JSON=runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json
SCENARIO_JSON=scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json
CONTRACT_LIGHT=fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1
CONTRACT_HEAVY=fixed_contract_runtime_h1_constrained_aggregate_1024m_4vcpu_v1

RUN_ROOT=/tmp/foot3way/r${REPEAT}
LOG_ROOT=/home/bench/foot3way-logs/r${REPEAT}
mkdir -p "$RUN_ROOT" "$LOG_ROOT"
echo "===== REPEAT r${REPEAT} — run root $RUN_ROOT — $(date -u +%Y-%m-%dT%H:%M:%S)Z ====="

run_stack() {
  local STACK="$1" LABEL="$2" CONTRACT="$3" EXTRA="$4"
  local LOG="$LOG_ROOT/${LABEL}.log"
  local OUT="$RUN_ROOT/${LABEL}-run"

  echo "############ $LABEL  stack=$STACK  $(date -u +%H:%M:%S)UTC ############"
  if pgrep -x java >/dev/null 2>&1; then pkill -x java; sleep 3; fi
  rm -rf "$OUT"; rm -f "$LOG"

  # NMT detail is what makes the heap ADDRESS RANGE visible; without it the snapshot
  # captures smaps but cannot attribute it. Same level on every arm — see header.
  BENCHMARK_SKIP_TARGET_BUILD=1 \
  BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=32 BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=32 \
  BENCHMARK_ALLOW_EXTERNAL_DB=1 \
    nohup env JDK_JAVA_OPTIONS="${EXTRA} -XX:NativeMemoryTracking=detail" \
    bash scripts/run-entity-read-by-id-constrained.sh \
      --execution-profile-id "$PROFILE_ID" \
      --contract-id "$CONTRACT" \
      --profiles-json "$PROFILES_JSON" \
      --scenario-json "$SCENARIO_JSON" \
      --target-runtime "$STACK" --target-build jvm --jvm-gc parallel \
      --jvm-xms-mb 256 --jvm-xmx-mb 256 \
      --cpu-affinity 0-1,8-9 --client-cpu-affinity 2-3,10-11 \
      --output-dir "$OUT" </dev/null > "$LOG" 2>&1 &
  local RUNNER=$!
  echo "[$LABEL] runner PID $RUNNER"
  wait "$RUNNER" 2>/dev/null
  local RC=$?

  local RES SMAPS NMT RPS
  RES=$(find "$OUT" -name result.json 2>/dev/null | head -1)
  SMAPS=$(find "$OUT" -name 'footprint-smaps-*.txt.gz' 2>/dev/null | head -1)
  NMT=$(find "$OUT" -name 'footprint-nmt-detail-*.txt' 2>/dev/null | head -1)
  RPS=$( [ -n "$RES" ] && jq -r '.metrics.throughput_rps // 0' "$RES" 2>/dev/null || echo 0 )

  echo "[$LABEL] rc=$RC rps=$RPS"
  echo "[$LABEL] smaps=${SMAPS:-MISSING} nmt=${NMT:-MISSING}"
  # Fail loudly per cell rather than discovering an empty dataset at analysis time.
  [ -n "$SMAPS" ] || echo "[$LABEL] WARN: no smaps snapshot — footprint decomposition impossible for this cell"
  [ -n "$NMT" ]   || echo "[$LABEL] WARN: no NMT detail — check NativeMemoryTracking + constrained-scope escape"
}

echo "===== LIGHT (single-read) ====="
run_stack community     light-community "$CONTRACT_LIGHT" "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run_stack quarkus-tuned light-qtuned    "$CONTRACT_LIGHT" ""
run_stack quarkus       light-qhib      "$CONTRACT_LIGHT" ""

echo "===== HEAVY (10x10x10 aggregate) ====="
run_stack community     heavy-community "$CONTRACT_HEAVY" "-Dexeris.persistence.admission.queueDepthAllowanceRatio=32"
run_stack quarkus-tuned heavy-qtuned    "$CONTRACT_HEAVY" ""
run_stack quarkus       heavy-qhib      "$CONTRACT_HEAVY" ""

echo "===== ALL 6 CELLS DONE r${REPEAT} $(date -u +%H:%M:%S)UTC ====="
echo "Next: bash results/raw/20260729-entity-read-by-id-3way-footprint-decomposition/foot-3way-analyze.sh"
