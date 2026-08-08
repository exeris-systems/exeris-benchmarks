#!/usr/bin/env bash
# pure-native vs quarkus-tuned, n=3 — driver for run-full-triad-ab-ba.sh.
#
# ONE pair, both contracts, both directions, three repeats:
#   spring-on-exeris-pure-native   Exeris native web + kernel TransactionalExecutor + SQL
#   quarkus-tuned                  Quarkus, ORM removed, hand-written SQL
#
# 1 pair x 1 run x 2 directions x 3 repeats x 2 contracts = 12 leaves (~40 min each, ~8 h).
#
# WHY THIS PAIR
# Both arms have had the ORM removed and issue hand-written SQL, so the ORM layer — which
# dominated and therefore masked every other difference in the earlier hosting triad — is out
# of the request on both sides. What remains is runtime against runtime.
#
# WHAT THIS PAIR IS NOT
# It is not a clean single-variable measurement, and nothing derived from it may be reported as
# one. Every fence below sits inside this pair simultaneously. They are listed in the manifest
# and repeated in the report, not resolved here — collapsing them would be the apples-to-oranges
# comparison this repo exists to refuse.
#
# Repeat is the OUTER loop, exactly as in the ladder: every repeat is a complete balanced
# dataset, so stopping early costs precision rather than the experiment. Never reorder.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
ROOT="results/raw/entity-read-by-id/${CAMPAIGN_TS}-purenative-vs-quarkustuned-n3"
mkdir -p "$ROOT"
cp -- "$0" "$ROOT/driver.sh"

# Single pair. Ports from runtime/drivers/target-asset-matrix.json: pure-native 9006,
# quarkus-tuned 9003. Both directions come from the runner, not from a second entry here.
export BENCH_TRIAD_PAIRS="${BENCH_TRIAD_PAIRS:-1-purenative-vs-quarkustuned:spring-on-exeris-pure-native:quarkus-tuned:1:9006:9003}"

# ---------------------------------------------------------------------------
# DB client — PINNED BY THIS CALLER, same rationale as the ladder driver: the runner exports
# no DB credentials and the target env files fall back to a legacy postgres/postgres that does
# not exist here. Omitting these does NOT fail fast — every target starts, never becomes ready,
# and the runner logs a skip. A first attempt at the ladder burned 7.5 h producing empty leaves.
#
# The query parameters are the fetch-mode normalisation and a first-class axis label:
# fetch_mode inverts the heavy-contract ranking, so an un-normalised URL can reverse the result.
export EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended'
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

# Repetition is the outer repeat loop below, not the runner's default of 20 runs per pair.
# Left unset this campaign would be 20x longer and nothing would fail to warn you.
export BENCH_RUNS_PER_PAIR=1

export BENCH_TOTAL_MEMORY_MB=2048

# ISO-HEAP ACROSS A CROSS-STACK PAIR. pure-native reads SPRING_JAVA_OPTS; quarkus-tuned reads
# QUARKUS_JAVA_OPTS, composed by the runner from BENCH_QUARKUS_HEAP_MB. Both are set to the
# same value explicitly rather than relying on the runner's defaults matching, because footprint
# is a reported axis on this pair and a heap mismatch would surface as an RSS "finding".
# This is the defect class tools/preflight-ladder-arms.sh check 5 exists to catch.
export BENCH_SPRING_HEAP_MB=1280
export BENCH_QUARKUS_HEAP_MB=${BENCH_SPRING_HEAP_MB}

# Core partition on the 16-thread box: 0-1,8-9 server | 2-3,10-11 loadgen | 4-7,12-15 database.
# Disjoint, and identical to the ladder.
export BENCH_SERVER_CPU_AFFINITY=0-1,8-9
export BENCH_LOADGEN_CPU_AFFINITY=2-3,10-11
export BENCH_DB_CPUSET=4-7,12-15

# ---------------------------------------------------------------------------
# HOST-NETWORKED DB. Required, not preferred: docs/methodology.md states host mode is
# "opt-in but REQUIRED for cross-stack claims", and this pair is the most cross-stack pair
# in the repo (Exeris kernel transport vs Netty/Vert.x). A bridged DB puts a NAT hop between
# each target JVM and Postgres, and the hop is charged per round-trip — so it taxes the
# chattier stack harder and can be mistaken for a runtime difference.
#
# BOTH variables are needed and they do DIFFERENT things. Setting either alone is a defect:
#
#   BENCH_DB_TUNED=1   CHANGES REALITY. infra-setup.sh layers entity-read-by-id-db.tuned.yml,
#                      which sets network_mode: host on the DB container. This is the only
#                      switch in the entity-read-by-id path that actually moves the DB off
#                      the bridge — DB_HOST_NETWORK is NOT read by infra-setup.sh at all.
#                      The override also re-states cpuset 4-7,12-15 (equal to BENCH_DB_CPUSET
#                      above, keep them in step) and leaves shared_buffers/work_mem at the
#                      base values, so PG configuration is unchanged.
#
#   DB_HOST_NETWORK=1  CHANGES THE LABEL. run-comparative.sh drives an externally-launched DB
#                      and therefore cannot detect the mode; it records what the operator
#                      declares. Setting this alone would stamp backend_network_mode="host"
#                      on an artifact whose DB is still bridged — a fairness claim that is
#                      simply false. Setting only the other leaves a true host-net run
#                      labelled "bridge" and emits the harness's cross-stack warning.
export BENCH_DB_TUNED=1
export DB_HOST_NETWORK=1

export BENCH_DB_POOL_MIN_SIZE=16
export BENCH_DB_POOL_MAX_SIZE=256
export BENCH_ENABLE_NATIVE_MEMORY_TRACKING=1
export BENCH_NATIVE_MEMORY_TRACKING_LEVEL=summary

# Campaign-level JFR/safepoint logs off, as in the ladder: that block keys filenames to target
# FAMILIES, and per-leaf recordings from run-comparative.sh are the authoritative artefacts.
export BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS=0

export WARMUP_SECONDS=300
export MEASUREMENT_SECONDS=900

declare -A CONTRACT=(
  [heavy]=fixed_contract_cross_runtime_h1_v2
  [light]=fixed_contract_cross_runtime_h1_single_read_v1
)

if command -v psql >/dev/null 2>&1; then
  if ! PGPASSWORD="$EXERIS_DB_PASSWORD" psql -h localhost -U "$EXERIS_DB_USERNAME" \
        -d benchmark_db -tAc 'select 1' >/dev/null 2>&1; then
    echo "PREFLIGHT FAILED: cannot connect to benchmark_db as ${EXERIS_DB_USERNAME}." >&2
    echo "The campaign would start, every target would fail JDBC metadata, and every" >&2
    echo "leaf would be skipped without an error status. Refusing to start." >&2
    exit 1
  fi
  echo "[preflight] benchmark_db reachable as ${EXERIS_DB_USERNAME}"
else
  echo "[preflight] psql absent — DB connectivity not verified up front" >&2
fi

cat > "${ROOT}/campaign-manifest.json" <<JSON
{
  "campaign": "entity-read-by-id-purenative-vs-quarkustuned-n3",
  "campaign_ts": "${CAMPAIGN_TS}",
  "commit_sha": "${BENCH_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}",
  "commit_sha_note": "The perf box holds an rsynced tree, NOT a git checkout, so \`git rev-parse\` there returns nothing. Pass BENCH_COMMIT_SHA from the machine that holds the checkout. If this reads \"unknown\", the run cannot be tied to a source revision and must not be used for a baseline.",
  "repeats": "01,02,03",
  "contracts": "heavy,light",
  "repeat_loop_position": "outer",
  "runs_per_pair": ${BENCH_RUNS_PER_PAIR},
  "expected_leaves": 12,
  "expected_leaves_note": "pairs x runs x directions x repeats x contracts = 1x1x2x3x2 = 12.",
  "triad_pairs": "${BENCH_TRIAD_PAIRS}",
  "iso_heap_mb": ${BENCH_SPRING_HEAP_MB},
  "iso_heap_note": "pure-native reads SPRING_JAVA_OPTS, quarkus-tuned reads QUARKUS_JAVA_OPTS composed from BENCH_QUARKUS_HEAP_MB. Both pinned to the same value explicitly. Footprint is a reported axis on this cross-stack pair, so an unmatched heap would surface as an RSS finding rather than as a misconfiguration.",
  "server_cpu_affinity": "${BENCH_SERVER_CPU_AFFINITY}",
  "loadgen_cpu_affinity": "${BENCH_LOADGEN_CPU_AFFINITY}",
  "db_cpuset": "${BENCH_DB_CPUSET}",
  "backend_network_mode": "host",
  "backend_network_mode_note": "DB on HOST networking (BENCH_DB_TUNED=1 layers the tuned override's network_mode: host; DB_HOST_NETWORK=1 makes run-comparative.sh record it). Required by docs/methodology.md for any cross-stack claim: a bridged DB charges a NAT hop per round-trip and so taxes the chattier stack asymmetrically. FENCE: the 2026-08-06 spring ladder ran BRIDGED (backend_network_mode=bridge in all 48 leaves) — absolute levels from that campaign and this one are NOT mixable, and the ladder's own cross-stack pairs (1 and 4) carry the bridge tax unquantified. PG settings are unchanged between the two (max_connections=300, shared_buffers=256MB, work_mem=8MB) and the cpuset is the same 4-7,12-15, so networking is the single environmental difference.",
  "runtime_web_build": "$(ls -t "${HOME}/.m2/repository/eu/exeris/exeris-spring-runtime-web/0.5.0-SNAPSHOT/"*.jar 2>/dev/null | head -1 | xargs -r basename)",
  "runtime_build_provenance_note": "The perf box resolves eu.exeris SNAPSHOTs from GitHub Packages; latest published as of 2026-08-08 is 0.5.0-20260805.182020-29, which is what this campaign's pure-native arm carries. A NEWER unpublished build exists in the author's local ~/.m2 (untimestamped, no GHP metadata, i.e. mvn-installed from a source checkout) and behaves differently — it serves ResponseEntity under Spring 7 where -29 throws IncompatibleClassChangeError. Any comparison against a locally-built arm crosses that boundary. This campaign is entirely on the published -29.",

  "AXIS_FENCES": "This pair is NOT single-variable. All of the following are simultaneously true and none may be dropped from a claim derived here.",

  "fence_serialisation": "DOMINANT. pure-native is on Jackson 3 (tools.jackson, 3.1.4 via Boot 4.1.0); quarkus-tuned is on Jackson 2 (com.fasterxml). This is a MAJOR-version difference sitting in the response path of every request. Prior profiling attributed roughly a fifth of Exeris on-CPU time in this scenario to Jackson 3 MethodHandle checkCustomized. Expect it to be the largest single contributor to any gap measured here, and do not attribute the gap to transport or runtime without separating it.",
  "fence_payload_key_order": "Heavy responses from the two arms are the same 9105 bytes but are NOT byte-identical: quarkus-tuned emits keys alphabetically, pure-native in declaration order. They are equal under \`jq -S\`. Left un-normalised deliberately — overriding a framework's default key ordering for cosmetic parity would itself be a change to what is measured. Recorded because it is direct evidence the two serialisers are configured differently, which is the point of fence_serialisation.",
  "fence_pool": "Connection pools differ by implementation: pure-native uses HikariCP, quarkus-tuned uses Agroal. Min/max are matched (16/256) but the implementations are not.",
  "fence_transport": "pure-native runs the Exeris NativeTcpCarrier in mode=auto, which resolves to posix-hybrid (NIO epoll + FFM syscalls) — NOT io_uring. Verify against the carrier banner in the target log before labelling this run's transport. quarkus-tuned runs Netty/Vert.x.",
  "fence_jdbc_logging": "pgjdbc routes through JUL on the Exeris arm; this has previously shown up in on-CPU profiles and is not present in the same form on the Quarkus side.",
  "fence_db_ceiling": "MEASURED, not hypothetical. In the 2026-08-06 ladder, pure-native drove the pinned DB cpuset to 99.80 % mean utilisation on the HEAVY contract (n=12, range 99.78-99.83, %steal 0.00). At that level the heavy throughput of this arm is bounded by Postgres, not by the runtime, and a heavy throughput RATIO between these two arms may be measuring how close each gets to the same wall rather than how fast each is. Use cpu/req as the heavy comparator; treat heavy rps ratios as bounds. On LIGHT the same arm sat at 87.36 % — near saturation but not at it, leaving roughly an eighth of the DB in reserve. Read light as own-CPU-bound with the DB close behind, not as DB-free.",
  "fence_auth": "Neither arm runs Spring Security: pure-native has no Spring Security on the classpath at all, and quarkus-tuned is unauthenticated. This pair is therefore FREE of the per-request security asymmetry that applies to pairs involving spring-hibernate or the compat arm. Do not borrow bounds in either direction.",

  "db_client": {
    "fetch_mode": "equalized",
    "jdbc_url": "${EXERIS_DB_JDBC_URL}",
    "username": "${EXERIS_DB_USERNAME}",
    "note": "Pinned by this caller. The runner exports no DB credentials and the target env files default to a nonexistent postgres/postgres."
  }
}
JSON

first_iteration=1
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

    # Fail fast on the first iteration. The runner treats an unready target as a skipped step
    # and keeps going, so a misconfiguration otherwise yields a "COMPLETE" campaign with
    # nothing in it. Bound that loss to one iteration instead of all six.
    if [[ "$first_iteration" == "1" ]]; then
      produced=$(find "$out" -name claim-status.json 2>/dev/null | wc -l)
      eligible=$(find "$out" -name claim-status.json -exec jq -r '.claim_status // empty' {} \; 2>/dev/null | grep -c '^comparison_eligible$' || true)

      if [[ "$produced" -eq 0 ]]; then
        echo "ABORT: first iteration produced no comparative leaves (0 claim-status.json)." >&2
        echo "Not continuing — the remaining five iterations would fail identically." >&2
        exit 1
      fi

      # Both arms are mode=pure (target-asset-matrix.json), so G3 equivalence_strict passes and
      # ALL leaves should be eligible. Counting files alone is not enough — the ladder's first
      # version of this check passed an iteration in which every leaf was non_eligible.
      if [[ "$eligible" -eq 0 ]]; then
        echo "ABORT: first iteration produced ${produced} leaf/leaves but NONE comparison_eligible." >&2
        echo "Both arms are mode=pure, so every leaf should clear G3. Zero eligible means the" >&2
        echo "failure is common to all of them and the remaining iterations would repeat it." >&2
        find "$out" -name claim-status.json -exec sh -c \
          'echo "  $(jq -r "(.pair_id // \"?\") + \" -> \" + (.claim_status // \"?\") + \" \" + ((.rejection_codes // []) | join(\",\"))" "$1")"' _ {} \; >&2
        exit 1
      fi

      if [[ "$eligible" -lt "$produced" ]]; then
        echo "[fail-fast] WARNING: ${eligible}/${produced} leaves comparison_eligible — expected all." >&2
        find "$out" -name claim-status.json -exec sh -c \
          'jq -e ".claim_status == \"comparison_eligible\"" "$1" >/dev/null 2>&1 || echo "  $(jq -r "(.pair_id // \"?\") + \" -> \" + (.claim_status // \"?\") + \" \" + ((.rejection_codes // []) | join(\",\"))" "$1")"' _ {} \; >&2
      fi

      echo "[fail-fast] first iteration: ${produced} leaf/leaves, ${eligible} comparison_eligible — continuing"
      first_iteration=0
    fi
  done
done

echo "=============================================================="
echo "PURE-NATIVE vs QUARKUS-TUNED CAMPAIGN COMPLETE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "root: ${ROOT}"
echo "=============================================================="
