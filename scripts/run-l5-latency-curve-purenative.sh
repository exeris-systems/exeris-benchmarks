#!/usr/bin/env bash
#
# run-l5-latency-curve-purenative.sh — open-loop wrk2 service-time curves for the Spring
# series: the ORM axis under a matched offered rate, and the L5 tail question.
#
# WHY OPEN LOOP AT ALL
#
# Every latency number in this series so far came from wrk at saturation. With 128 connections
# in flight a closed-loop driver reports queue occupancy, not service time — the artifacts stamp
# driver.mode=closed and latency_percentile_eligibility.publishable=false saying exactly that.
# So the repo currently has no service-time evidence for any Spring arm, and CLAIMS L5 closes
# with "Next step unchanged: open-loop wrk2 below saturation."
#
# THE LADDER IS A PROPERTY OF THE PAIR, NOT OF THE CAMPAIGN
#
# A rung is only meaningful below BOTH arms' saturation, so the ceiling is set by the slower arm
# — and that differs per pair by more than an order of magnitude on heavy. Driving every pair
# from one global ladder (the shape this script had on its first draft) only looked correct
# because its two original pairs happened to saturate within 0.1 % of each other. Each pair now
# carries its own ladders and gets its own invocation of the curve driver.
#
# Closed-loop saturation, arm means over the committed 2026-08 campaigns (min in brackets):
#
#     arm                            light rps           heavy rps
#     exeris-community               74 269              13 107
#     quarkus-tuned                  55 490 [53 967]     12 862
#     spring-on-exeris-pure-native   55 434 [54 651]     12 645
#     spring-jdbc                    32 190 [31 631]     12 664
#     spring-hibernate               27 571 [27 108]      3 681 [3 628]
#
# PHASE 1 — spring-hibernate x spring-jdbc, THE ORM AXIS. Report-critical.
#
# The 2026-08-10 campaign measured this pair closed-loop and got x3.95 cpu/req on heavy — but
# with spring-jdbc saturating the DB cpuset at 97.4 % while spring-hibernate left it at 26.4 %,
# so its heavy throughput ratio reads the Postgres ceiling for one arm only and cannot be
# quoted. Open loop removes that asymmetry outright: at a matched offered rate below both arms
# both do IDENTICAL work per second, so they present identical load to Postgres, and what
# remains between them is service time and cpu/req at equal work. This is the first fair heavy
# comparison this pair can produce, which is why heavy is included here and was excluded from
# phase 2.
#
# Ladders bound by spring-hibernate, the slower arm on both contracts:
#   light  4k..24k  against its 27 108 worst-observed  (top rung ~89 %)
#   heavy  600..3400 against its 3 628                 (top rung ~94 %)
#
# PHASE 2 — exeris-community x spring-on-exeris-pure-native, THE L5 TAIL.
#
# L5: pure-native has the second-best median and the worst p99 of the four ladder arms on light,
# and its own text localises the excess to "where Spring AND native persistence are both in the
# path". Both arms here are kernel-native persistence over the same kernel issuing byte-identical
# SQL; community is what removes the Spring half while holding persistence fixed. If the tail
# follows Spring it shows here; if it collapses as offered load drops away from the knee it was
# queueing all along. Light only — L5's excess is absent on heavy (+0.17 ms against +5.04 ms on
# light), so heavy rungs would pay to measure a contract where the effect does not occur.
#
# DROPPED: quarkus-tuned x pure-native. It was in the first draft as an open-loop reproduction of
# Run B (2026-08-08, 2.81x the comparator's tail). Quarkus is a reference point in a Spring-series
# report, it already carries wrk2 data from the 2026-07-22 curve, and it brings the Jackson-2 vs
# Jackson-3 confound with it. Phase 2 is the pair that LOCALISES L5; reproduction is a nice-to-have
# that the diagnostic does not depend on. Stated so the omission is a decision on the record and
# not an oversight: no open-loop reproduction of Run B exists after this campaign.
#
# ISO-HEAP 1280 MB ON EVERY ARM, INCLUDING EXERIS
#
# BENCH_EXERIS_HEAP_MB defaults to 256 in run-full-triad-ab-ba.sh. Left alone, phase 2 would put
# exeris-community on a 5x smaller heap than its partner and reintroduce the budget-vs-matched
# heap difference the 2026-07-21 report spent a section separating. The ladder that produced L5
# ran iso-heap 1280 (verified: heap_committed_kb = 1310720 for exeris-community in
# 20260806T183034Z-spring-ladder-n3), so these leaves match it or they are not comparable with
# the data they exist to explain.
#
# USAGE
#   ./scripts/run-l5-latency-curve-purenative.sh              # both phases
#   L5_PHASES=orm  ./scripts/run-l5-latency-curve-purenative.sh
#   L5_PHASES=tail ./scripts/run-l5-latency-curve-purenative.sh
#
# Cost: phase 1 = 2 directions x (6 light + 6 heavy) = 24 leaves; phase 2 = 2 x 6 = 12 leaves.
# 60 s warmup + 120 s measurement per arm, ~4 h for both.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

CURVE_DRIVER="${REPO_ROOT}/scripts/run-entity-read-by-id-latency-curve-triad.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PHASES="${L5_PHASES:-orm tail}"

# ---------------------------------------------------------------------------
# Database — the 2026-07-24 pgjdbc fetch equalisation. Dropping these reintroduces the
# confound that inverted the aggregate verdict in the 2026-07-21 triad.
# ---------------------------------------------------------------------------
export EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended'
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

# ---------------------------------------------------------------------------
# Fairness profile — identical to the n3 campaigns so these leaves sit alongside them
# ---------------------------------------------------------------------------
export BENCH_TOTAL_MEMORY_MB=2048
export BENCH_EXERIS_HEAP_MB=1280
export BENCH_SPRING_HEAP_MB=1280
export BENCH_QUARKUS_HEAP_MB=1280

export BENCH_SERVER_CPU_AFFINITY=0-1,8-9
export BENCH_LOADGEN_CPU_AFFINITY=2-3,10-11
export BENCH_DB_CPUSET=4-7,12-15
export BENCH_DB_TUNED=1
export DB_HOST_NETWORK=1

# ---------------------------------------------------------------------------
# Preflight. Boot-verify is a hard entry condition in this repo — jar inspection is not
# evidence. Seconds against a 4-hour campaign.
# ---------------------------------------------------------------------------
command -v wrk2 >/dev/null 2>&1 || { echo "ABORT: wrk2 not in PATH — the open-loop driver is the entire point" >&2; exit 1; }

if ! PGPASSWORD="$EXERIS_DB_PASSWORD" psql -h localhost -U "$EXERIS_DB_USERNAME" -d benchmark_db -c 'select 1' >/dev/null 2>&1; then
  echo "ABORT: benchmark_db not reachable as $EXERIS_DB_USERNAME" >&2
  exit 1
fi
echo "[preflight] benchmark_db reachable as $EXERIS_DB_USERNAME"

# ---------------------------------------------------------------------------
# run_phase <name> <pairs> <light-rungs> <heavy-rungs>
#
# An EMPTY rung string means "skip that endpoint" — the curve driver distinguishes empty from
# unset for exactly this (it used to collapse them, silently running the default ladder).
# ---------------------------------------------------------------------------
run_phase() {
  local name="$1" pairs="$2" light="$3" heavy="$4"
  local root="results/raw/entity-read-by-id/${STAMP}-l5-curve-${name}"

  echo ""
  echo "############################################################"
  echo "[l5-curve] PHASE ${name}"
  echo "[l5-curve]   pairs : ${pairs}"
  echo "[l5-curve]   light : ${light:-<skipped>}"
  echo "[l5-curve]   heavy : ${heavy:-<skipped>}"
  echo "[l5-curve]   root  : ${root}"
  echo "############################################################"

  LATENCY_TRIAD_PAIRS="$pairs" \
  LATENCY_LIGHT_RUNGS="$light" \
  LATENCY_HEAVY_RUNGS="$heavy" \
  LATENCY_CURVE_ROOT="$root" \
    bash "$CURVE_DRIVER"
  echo "[l5-curve] phase ${name} exited rc=$?"
}

for phase in $PHASES; do
  case "$phase" in
    orm)
      run_phase orm \
        "1-hibernate-vs-jdbc:spring-hibernate:spring-jdbc:1:9001:9008" \
        "4000 8000 12000 16000 20000 24000" \
        "600 1200 1800 2400 3000 3400"
      ;;
    tail)
      run_phase tail \
        "1-community-vs-purenative:exeris-community:spring-on-exeris-pure-native:1:9000:9006" \
        "10000 20000 30000 40000 45000 50000" \
        ""
      ;;
    *)
      echo "ABORT: unknown phase '$phase' (want: orm, tail)" >&2; exit 1 ;;
  esac
done

echo ""
echo "============================================================"
echo "[l5-curve] ALL PHASES COMPLETE (stamp ${STAMP})"
echo "============================================================"
