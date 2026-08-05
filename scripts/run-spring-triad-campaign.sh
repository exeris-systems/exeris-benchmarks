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
  "triad_pairs": "${BENCH_TRIAD_PAIRS}",
  "iso_heap_mb": ${BENCH_SPRING_HEAP_MB},
  "iso_heap_note": "All three arms read SPRING_JAVA_OPTS, so one setting binds the whole triad by construction.",
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
      if [[ "$produced" -eq 0 ]]; then
        echo "ABORT: first iteration produced no comparative leaves (0 claim-status.json)." >&2
        echo "Not continuing — the remaining five iterations would fail identically." >&2
        echo "Check ${out}/campaign.log and the target logs under /tmp." >&2
        exit 1
      fi
      echo "[fail-fast] first iteration produced ${produced} leaf/leaves — continuing"
      first_iteration=0
    fi
  done
done

echo "=============================================================="
echo "SPRING TRIAD CAMPAIGN COMPLETE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "root: ${ROOT}"
echo "=============================================================="
