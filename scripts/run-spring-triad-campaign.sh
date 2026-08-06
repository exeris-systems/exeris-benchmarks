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

# ---------------------------------------------------------------------------
# DB client — PINNED BY THIS CALLER. Not optional, and not a detail.
#
# run-full-triad-ab-ba.sh exports no DB credentials, run-comparative.sh only
# READS ${EXERIS_DB_JDBC_URL:-}, and the target env files fall back to a legacy
# postgres/postgres that does not exist in this database. Omitting these three
# exports does NOT fail fast: every target starts, fails to obtain JDBC
# metadata, never becomes ready, and the runner logs "Skipping run NN ... due to
# target readiness failure" and moves on. A first attempt at this campaign
# burned 7.5 h and produced 36 empty leaves that way. The C1 triad recorded the
# same trap as "triad bug 5".
#
# The query parameters are the fetch-mode normalisation. They are a first-class
# axis label: fetch_mode inverts the heavy-contract ranking, so an un-normalised
# URL does not merely add noise, it can reverse the result.
export EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended'
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

# All three arms consume $SPRING_JAVA_OPTS (see runtime/drivers/env/spring-runtime*.env),
# so one heap setting gives iso-heap across the whole triad by construction.
# ONE run per pair per direction. run-full-triad-ab-ba.sh defaults
# BENCH_RUNS_PER_PAIR to 20, which is not the repetition axis this campaign uses:
# repetition comes from the OUTER repeat loop below (repeat01..03), exactly as the
# C1 triad did — its committed tree contains run01 and nothing else.
#
# Leaving it unset multiplies the campaign by 20: 3 pairs x 20 runs x 2 directions
# = 120 leaves per iteration instead of 6, and 720 instead of 36 across the whole
# campaign — roughly twelve days instead of about thirty hours. That is what
# TOTAL_STEPS=120 in the runner is reporting, and it is easy to miss because
# nothing fails; the campaign simply runs for far too long.
export BENCH_RUNS_PER_PAIR=1

export BENCH_TOTAL_MEMORY_MB=2048
export BENCH_SPRING_HEAP_MB=1280

# CPU isolation onto disjoint sets, identical to the C1 triad. Not optional:
# unpinned, the load generator and the target under test share all 16 threads
# (observed load average 42), which risks measuring the generator instead of the
# server and compresses the differences this triad exists to resolve. Leaving it
# unset would also make these numbers incomparable with C1, which pinned.
#
# NOTE the interaction with pool sizing: the kernel derives a default max pool
# from Runtime.availableProcessors(), which under this pinning is 4. Before the
# spring-runtime max-pool fix that produced a derived max of 8, below the
# min of 16 below, and every Exeris-hosted arm failed to boot. Verified fixed on
# runtime-web snapshot 0.5.0-20260805.065719-25: boots and serves 200 under
# exactly this pinning with min=16.
export BENCH_SERVER_CPU_AFFINITY=0-1,8-9
export BENCH_LOADGEN_CPU_AFFINITY=2-3,10-11
# Completes the core partition on the 16-thread box: 0-1,8-9 server | 2-3,10-11 loadgen |
# 4-7,12-15 database, no overlap. Consumed twice — docker compose pins the container with it,
# and resolve_db_cpuset() reads it as its highest-priority probe, so the DB-CPU sampler watches
# exactly the cores the DB was confined to.
#
# FENCE. Every campaign before 2026-08-06 ran with Postgres UNPINNED across all 16 threads
# (verified: postmaster Cpus_allowed_list=0-15 while the target was pinned to 0-1,8-9), so the
# DB contended for the measured arm's own cores and DB CPU was unattributable. Absolute levels
# from pinned and unpinned runs are not mixable. Confining PG to 4 physical cores may also lower
# the DB ceiling — say so with any heavy-contract number, since heavy is DB-bound.
export BENCH_DB_CPUSET=4-7,12-15

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

# Preflight: prove the pinned credentials actually open this database before
# committing hours to the run. Cheap, and it is the exact failure that produced
# an empty campaign.
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

# Record what this caller pinned, alongside the results rather than in shell history.
cat > "${ROOT}/campaign-manifest.json" <<JSON
{
  "campaign": "entity-read-by-id-spring-triad-n3",
  "campaign_ts": "${CAMPAIGN_TS}",
  "commit_sha": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
  "repeats": "01,02,03",
  "contracts": "heavy,light",
  "repeat_loop_position": "outer",
  "runs_per_pair": ${BENCH_RUNS_PER_PAIR},
  "runs_per_pair_note": "1, not the runner's default of 20 — repetition is the outer repeat loop, matching C1. Expected leaf count = pairs x runs x directions x repeats x contracts = 3x1x2x3x2 = 36.",
  "triad_pairs": "${BENCH_TRIAD_PAIRS}",
  "iso_heap_mb": ${BENCH_SPRING_HEAP_MB},
  "iso_heap_note": "All three arms read SPRING_JAVA_OPTS, so one setting binds the whole triad by construction.",
  "server_cpu_affinity": "${BENCH_SERVER_CPU_AFFINITY}",
  "loadgen_cpu_affinity": "${BENCH_LOADGEN_CPU_AFFINITY}",
  "db_cpuset": "${BENCH_DB_CPUSET}",
  "db_cpuset_note": "Disjoint from the server and loadgen pins. FENCE: campaigns before 2026-08-06 ran Postgres unpinned on all 16 threads, contending with the measured arm; absolute levels do not cross that boundary.",
  "runtime_web_build": "$(ls -t "${HOME}/.m2/repository/eu/exeris/exeris-spring-runtime-web/0.5.0-SNAPSHOT/"*.jar 2>/dev/null | head -1 | xargs -r basename)",
  "runtime_build_note": "The Exeris-hosted arms' behaviour depends on this build, not only on this repo. It carries the pure-mode query-strip fix (#50) that makes the light contract routable at all, and the max-pool fix without which no Exeris arm boots under 4-CPU pinning. Record it: a light-contract result from a pre-#50 build fails as a 404 that is indistinguishable from 'no such row'.",
  "auth_axis": "Measured traffic is unauthenticated. The compat security filter's per-request cost was bounded at +0.14% against 1.48% run-to-run spread (tools/measure-auth-filter-confound.sh, 2026-08-05), so it does not materially flatter the pure arm. The Tomcat arm's servlet SecurityFilterChain is a heavier, UNMEASURED mechanism — do not borrow that bound for pairs involving spring-hibernate.",
  "campaign_level_jfr": "disabled — three 'spring' arms share SPRING_JAVA_OPTS and would collide on one diagnostics filename; per-leaf recordings come from run-comparative.sh via jcmd JFR.start",
  "db_client": {
    "fetch_mode": "equalized",
    "jdbc_url": "${EXERIS_DB_JDBC_URL}",
    "username": "${EXERIS_DB_USERNAME}",
    "note": "Pinned by this caller. The runner exports no DB credentials and the target env files default to a nonexistent postgres/postgres — triad bug 5."
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

    # Fail fast. The runner treats a target that never becomes ready as a skipped
    # step and keeps going, so a misconfiguration yields a "COMPLETE" campaign
    # with nothing in it. Bound that loss to one iteration instead of all six.
    if [[ "$first_iteration" == "1" ]]; then
      produced=$(find "$out" -name claim-status.json 2>/dev/null | wc -l)
      eligible=$(find "$out" -name claim-status.json -exec jq -r '.claim_status // empty' {} \; 2>/dev/null | grep -c '^comparison_eligible$' || true)

      if [[ "$produced" -eq 0 ]]; then
        echo "ABORT: first iteration produced no comparative leaves (0 claim-status.json)." >&2
        echo "Not continuing — the remaining five iterations would fail identically." >&2
        echo "Check ${out}/campaign.log and the target logs under /tmp." >&2
        exit 1
      fi

      # Counting files is not enough. The first version of this check passed an
      # iteration in which every leaf was non_eligible, because it only asked
      # whether claim-status.json existed. Two of this triad's three pairs are
      # cross-mode and are EXPECTED to come back non_eligible (see claim_track
      # in the pair manifest — they feed compat/, not the comparative track), so
      # the right assertion is that the ELIGIBLE pair still produced an eligible
      # leaf. Zero eligible leaves in a full iteration means the one pair that
      # should pass did not, and the remaining five iterations would repeat it.
      if [[ "$eligible" -eq 0 ]]; then
        echo "ABORT: first iteration produced ${produced} leaf/leaves but NONE comparison_eligible." >&2
        echo "Expected at least one from the within-mode pair (2-tomcat-vs-pure)." >&2
        echo "The cross-mode pairs 1 and 3 are expected non_eligible; this is about the third." >&2
        find "$out" -name claim-status.json -exec sh -c \
          'echo "  $(jq -r "(.pair_id // \"?\") + \" -> \" + (.claim_status // \"?\") + \" \" + ((.rejection_codes // []) | join(\",\"))" "$1")"' _ {} \; >&2
        exit 1
      fi

      echo "[fail-fast] first iteration: ${produced} leaf/leaves, ${eligible} comparison_eligible — continuing"
      echo "[fail-fast] cross-mode pairs reporting non_eligible is expected; they route to compat/"
      first_iteration=0
    fi
  done
done

echo "=============================================================="
echo "SPRING TRIAD CAMPAIGN COMPLETE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "root: ${ROOT}"
echo "=============================================================="
