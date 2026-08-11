#!/usr/bin/env bash
#
# run-l5-latency-curve-purenative.sh — the open-loop measurement CLAIMS.md L5 has been
# asking for since it was opened.
#
# WHAT L5 IS AND WHY wrk IS THE WRONG INSTRUMENT FOR IT
#
# L5: spring-on-exeris-pure-native has the second-best median and the WORST p99 of all four
# ladder arms on the light contract, and Run B (2026-08-08, host-net, quarkus-tuned as the
# comparator) made it worse — 2.81x the comparator's tail on an arm with the BETTER median.
#
# Every one of those numbers came from wrk at saturation. A closed-loop driver with 128
# connections in flight reports queue occupancy, not service time: the artifacts stamp
# driver.mode=closed and latency_percentile_eligibility.publishable=false with exactly that
# note, and L5's own text closes with "Next step unchanged: open-loop wrk2 below saturation.
# These p99 are still queue tails (p50 agrees with Little's law within a few percent in all
# eight cells)."
#
# So L5 currently has no service-time evidence at all. This campaign supplies it. If the tail
# is a real per-request property it persists at every sub-saturation rung; if it is queueing
# it collapses as offered load drops away from the knee. Either outcome closes the question,
# which is why it is worth 3 hours.
#
# THE TWO PAIRS ANSWER DIFFERENT HALVES
#
#   1-community-vs-purenative    exeris-community x spring-on-exeris-pure-native
#       LOCALISATION. Both arms are kernel-native persistence over the same kernel line and
#       issue byte-identical SQL; what differs is that one carries a Spring ApplicationContext
#       and reaches its repositories through exeris-spring-runtime-web, and the other routes
#       the kernel HttpRouter into hand-written handlers. L5 says the excess appears only where
#       Spring AND native persistence are both present — community is the arm that removes
#       exactly the Spring half while holding persistence fixed. If the tail follows Spring,
#       it shows here.
#
#   2-quarkustuned-vs-purenative  quarkus-tuned x spring-on-exeris-pure-native
#       REPRODUCTION. This is Run B's pair, re-run open-loop. It also happens to be the best-
#       matched pair in the manifest for a rate ladder: measured light-contract saturation is
#       55 490 rps (quarkus-tuned) against 55 434 (pure-native), a 0.1 % difference, so a
#       single ladder sits at the same fraction of both arms' capacity. Carries the standing
#       Jackson-2-vs-Jackson-3 confound (see the pair's axis_note) — which is a confound for a
#       THROUGHPUT claim and is not what this campaign quotes.
#
# RUNGS ARE DERIVED, NOT CHOSEN
#
# Light-contract closed-loop saturation, arm means over every committed 2026-08 campaign:
#
#     exeris-community              74 269 rps  (n=12)
#     quarkus-tuned                 55 490      (n=6,  min 53 967)
#     spring-on-exeris-pure-native  55 434      (n=24, min 54 651)
#
# The binding constraint is the slower arm of each pair, ~54 000 rps at its worst observed.
# The ladder tops out at 50 000 = ~93 % of that, deliberately inside the knee: a rung that
# cannot be sustained is not waste, it brackets saturation from above, and the harness flags
# it automatically via rate_attainment_pct and
# latency_percentile_eligibility.publishable=false. Rungs below it are comfortably open-loop.
#
# ISO-HEAP AT 1280 MB ON ALL THREE ARMS, INCLUDING EXERIS
#
# BENCH_EXERIS_HEAP_MB defaults to 256 in run-full-triad-ab-ba.sh. Left alone it would put
# exeris-community on a 5x smaller heap than its partner and reintroduce the budget-vs-matched
# heap difference that the 2026-07-21 report spent a whole section separating. The ladder that
# produced L5's numbers ran iso-heap 1280 (verified: heap_committed_kb = 1310720 for
# exeris-community in 20260806T183034Z-spring-ladder-n3), so this campaign matches it or its
# results are not comparable with the data it exists to explain.
#
# LIGHT ONLY, ON PURPOSE
#
# L5's excess is absent on heavy (+0.17 ms pure-native vs community, against +5.04 ms on
# light) — regime-dependent, not scale-dependent. Heavy rungs would double the cost to measure
# a contract where the effect does not occur. LATENCY_HEAVY_RUNGS is set empty; the curve
# driver skips the heavy loop.
#
# USAGE
#   ./scripts/run-l5-latency-curve-purenative.sh
#   LATENCY_LIGHT_RUNGS="20000 40000" ./scripts/run-l5-latency-curve-purenative.sh   # short probe
#
# Cost: 2 pairs x ab/ba x 6 rungs = 24 leaves, 60 s warmup + 120 s measurement per arm, ~3 h.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Pairs and ladder
# ---------------------------------------------------------------------------
export LATENCY_TRIAD_PAIRS="${LATENCY_TRIAD_PAIRS:-1-community-vs-purenative:exeris-community:spring-on-exeris-pure-native:1:9000:9006;2-quarkustuned-vs-purenative:quarkus-tuned:spring-on-exeris-pure-native:2:9003:9006}"

export LATENCY_HEAVY_RUNGS="${LATENCY_HEAVY_RUNGS:-}"
export LATENCY_LIGHT_RUNGS="${LATENCY_LIGHT_RUNGS:-10000 20000 30000 40000 45000 50000}"

# Defaults in the curve driver already point at the wrk2 CO-free family; restated so a reader
# of this file can see which contract the numbers will carry.
export LATENCY_LIGHT_CONTRACT="${LATENCY_LIGHT_CONTRACT:-fixed_contract_p99_stable_h1_wrk2_single_read_v1}"

export LATENCY_CURVE_ROOT="${LATENCY_CURVE_ROOT:-results/raw/entity-read-by-id/$(date -u +%Y%m%dT%H%M%SZ)-l5-latency-curve-purenative}"

# ---------------------------------------------------------------------------
# Database — same normalised pgjdbc configuration every 2026-08 campaign used.
# The fetch settings are the 2026-07-24 equalisation (defaultRowFetchSize=0,
# adaptiveFetch=false); dropping them would reintroduce the confound that inverted the
# aggregate verdict in the 2026-07-21 triad.
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
# Preflight. Boot-verify is a hard entry condition — jar inspection is not evidence, and
# four defects in this repo's history died at startup rather than at build. Costs seconds
# against a 3-hour campaign.
# ---------------------------------------------------------------------------
command -v wrk2 >/dev/null 2>&1 || { echo "ABORT: wrk2 not in PATH — the whole point of this campaign is the open-loop driver" >&2; exit 1; }

if ! PGPASSWORD="$EXERIS_DB_PASSWORD" psql -h localhost -U "$EXERIS_DB_USERNAME" -d benchmark_db -c 'select 1' >/dev/null 2>&1; then
  echo "ABORT: benchmark_db not reachable as $EXERIS_DB_USERNAME" >&2
  exit 1
fi
echo "[preflight] benchmark_db reachable as $EXERIS_DB_USERNAME"

echo "[l5-curve] pairs : $LATENCY_TRIAD_PAIRS"
echo "[l5-curve] rungs : ${LATENCY_LIGHT_RUNGS} rps (light only, contract $LATENCY_LIGHT_CONTRACT)"
echo "[l5-curve] heap  : iso 1280 MB on exeris/spring/quarkus, total budget ${BENCH_TOTAL_MEMORY_MB} MB"
echo "[l5-curve] root  : $LATENCY_CURVE_ROOT"

exec bash "${REPO_ROOT}/scripts/run-entity-read-by-id-latency-curve-triad.sh"
