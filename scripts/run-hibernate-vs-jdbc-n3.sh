#!/usr/bin/env bash
# spring-hibernate vs spring-jdbc, n=3 — driver for run-full-triad-ab-ba.sh.
#
# ONE pair, both contracts, both directions, three repeats:
#   spring-hibernate   Tomcat + Spring MVC + Hibernate ORM (spring-data-jpa)
#   spring-jdbc        Tomcat + Spring MVC + plain JdbcTemplate, hand-written SQL
#                       matching pure-native's shapes exactly (see UserRepository.java)
#
# 1 pair x 1 run x 2 directions x 3 repeats x 2 contracts = 12 leaves (~40 min each, ~8 h).
#
# WHY THIS PAIR
# Every prior Hibernate-removal measurement in this repo happened on the Exeris side at the
# same time the web layer moved off Tomcat (docs/CLAIMS.md L3), so the ORM's cost was measured
# on the Exeris-hosted arm and APPLIED to Tomcat by assumption. This pair measures the ORM axis
# directly, with the web layer held fixed: same Tomcat, same Spring MVC, same Boot 4.1.0, same
# SecurityConfig (spring-jdbc's is a byte-for-byte copy), same Jackson, same default HikariCP.
# The only planned difference is Hibernate's presence and the SQL it generates versus the
# hand-written statements in spring-benchmark-app-jdbc/UserRepository.java, matched shape-for-
# shape to pure-native and quarkus-tuned's queries (same projections, same windowed friends/
# interests query, same three-queries-per-heavy-request structure).
#
# WHAT THIS PAIR IS NOT
# Not verified byte-identical dependency trees (unlike purenative-vs-compnative's same-POM
# guarantee) — spring-jdbc drops spring-boot-starter-data-jpa and its transitive Hibernate/
# ORM tree; both still carry spring-boot-starter-data-neo4j for the e2e-shop-order-saga graph
# path (unused by this read-only scenario on either arm). Boot-verified live on 2026-08-10:
# both heavy and light contracts return 200 with real data on spring-jdbc after fixing a
# Neo4j/JDBC PlatformTransactionManager collision (see JdbcTransactionConfig.java) that JPA's
# own transaction-manager auto-configuration had been silently resolving on the hibernate arm.
#
# Repeat is the OUTER loop, exactly as in the ladder and the other n=3 drivers: every repeat is
# a complete balanced dataset, so stopping early costs precision rather than the experiment.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
ROOT="results/raw/entity-read-by-id/${CAMPAIGN_TS}-hibernate-vs-jdbc-n3"
mkdir -p "$ROOT"
cp -- "$0" "$ROOT/driver.sh"

# Single pair. Ports from runtime/drivers/target-asset-matrix.json: spring-hibernate 9001,
# spring-jdbc 9008. Both directions come from the runner, not from a second entry here.
export BENCH_TRIAD_PAIRS="${BENCH_TRIAD_PAIRS:-1-hibernate-vs-jdbc:spring-hibernate:spring-jdbc:1:9001:9008}"

# DB client — PINNED BY THIS CALLER. The runner exports no DB credentials and the target env
# files fall back to a legacy postgres/postgres that does not exist here. Omitting these does
# NOT fail fast: every target starts, never becomes ready, and the runner logs a skip.
export EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended'
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

# Repetition is the outer repeat loop below, not the runner's default of 20 runs per pair.
export BENCH_RUNS_PER_PAIR=1

export BENCH_TOTAL_MEMORY_MB=2048

# ISO-HEAP. Both arms are Spring-family and read SPRING_JAVA_OPTS (spring-runtime.env and
# spring-jdbc.env both compose it the same way), so this is structural, not matched by luck.
# Set explicitly anyway: footprint is a reported axis and Hibernate's metadata/session caches
# make it the more likely of the two arms to actually need the room.
export BENCH_SPRING_HEAP_MB=1280

# Core partition on the 16-thread box: 0-1,8-9 server | 2-3,10-11 loadgen | 4-7,12-15 database.
# Disjoint, and identical to the ladder and both other n=3 drivers.
export BENCH_SERVER_CPU_AFFINITY=0-1,8-9
export BENCH_LOADGEN_CPU_AFFINITY=2-3,10-11
export BENCH_DB_CPUSET=4-7,12-15

# HOST-NETWORKED DB, carried over from run A/B — the DB is already in that state on this box.
# Not required for a same-stack pair (both arms are Tomcat behind the same NAT hop, so a bridge
# tax would fall on them symmetrically), but switching back to bridge mid-series would be an
# unforced environment change and buys nothing here.
export BENCH_DB_TUNED=1
export DB_HOST_NETWORK=1

export BENCH_DB_POOL_MIN_SIZE=16
export BENCH_DB_POOL_MAX_SIZE=256
export BENCH_ENABLE_NATIVE_MEMORY_TRACKING=1
export BENCH_NATIVE_MEMORY_TRACKING_LEVEL=summary
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

# Boot-verify both arms end-to-end before committing eight hours to leaves that would silently
# skip. Mirrors the manual checks done ad hoc on 2026-08-10 (see docs/CLAIMS.md and the
# JdbcTransactionConfig.java commit) so a future re-run of this driver gets the same guarantee
# without repeating them by hand.
echo "[preflight] boot-verifying spring-hibernate (9001) and spring-jdbc (9008)"
for spec in "spring-hibernate:9001" "spring-jdbc:9008"; do
  tid="${spec%%:*}"; port="${spec##*:}"
  ./runtime/drivers/stop-target.sh "$tid" >/dev/null 2>&1 || true
  sleep 1
  if ! ./runtime/drivers/start-target.sh "$tid" >/tmp/preflight-${tid}.log 2>&1; then
    echo "PREFLIGHT FAILED: ${tid} did not become ready. See /tmp/preflight-${tid}.log" >&2
    exit 1
  fi
  heavy_code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/api/v1/users")"
  light_code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/api/v1/user?id=1")"
  if [[ "$heavy_code" != "200" || "$light_code" != "200" ]]; then
    echo "PREFLIGHT FAILED: ${tid} heavy=${heavy_code} light=${light_code} (expected 200/200)." >&2
    echo "A 401 here is very likely the /error-forward trap documented in SecurityConfig —" >&2
    echo "check the target log for the REAL exception before assuming it is auth." >&2
    ./runtime/drivers/stop-target.sh "$tid" >/dev/null 2>&1 || true
    exit 1
  fi
  echo "[preflight] ${tid}: heavy=200 light=200"
  ./runtime/drivers/stop-target.sh "$tid" >/dev/null 2>&1 || true
  sleep 1
done

cat > "${ROOT}/campaign-manifest.json" <<JSON
{
  "campaign": "entity-read-by-id-hibernate-vs-jdbc-n3",
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
  "benchmark_family": "runtime",
  "axis_under_test": "orm-presence",
  "axis_under_test_note": "Isolates docs/CLAIMS.md L3's load-bearing premise — that Hibernate costs the same under Tomcat as under Exeris — by measuring the ORM axis directly on Tomcat, without also moving the web layer. Both arms: Tomcat, Spring MVC, Boot 4.1.0, same SecurityConfig (spring-jdbc's is a copy), same default Jackson, same default HikariCP. spring-jdbc's SQL is hand-matched shape-for-shape to pure-native/quarkus-tuned (see targets/spring-benchmark-app-jdbc UserRepository.java javadoc).",
  "iso_heap_mb": ${BENCH_SPRING_HEAP_MB},
  "server_cpu_affinity": "${BENCH_SERVER_CPU_AFFINITY}",
  "loadgen_cpu_affinity": "${BENCH_LOADGEN_CPU_AFFINITY}",
  "db_cpuset": "${BENCH_DB_CPUSET}",
  "backend_network_mode": "host",
  "backend_network_mode_note": "Host networking, carried over from run A/B. Not required here — both arms are Tomcat behind the same NAT hop, so a bridge tax would fall symmetrically and could not manufacture an ORM-vs-no-ORM difference. Kept host because the DB is already in that state and switching back mid-series would be an unforced change. FENCE: absolute levels do not cross to the 2026-08-06 ladder, which ran bridged.",

  "AXIS_FENCES": "This pair is not verified byte-identical dependency trees (unlike purenative-vs-compnative's same-POM guarantee). The following are known or suspected differences and none may be dropped from a claim derived here.",
  "fence_dependency_tree": "spring-jdbc drops spring-boot-starter-data-jpa and its transitive Hibernate/ORM tree relative to spring-hibernate; not diffed BOOT-INF/lib to confirm everything else is identical the way purenative-vs-compnative was.",
  "fence_transaction_manager": "spring-hibernate resolves @Transactional via Spring Data JPA's JpaTransactionManager; spring-jdbc now resolves it via an explicit @Primary DataSourceTransactionManager (JdbcTransactionConfig.java, added 2026-08-10 to fix a collision with the auto-configured Neo4jTransactionManager both arms carry for the unused e2e-shop-order-saga graph path). Different transaction-manager implementations, not just different persistence.",
  "fence_boot_verify_gap": "Boot-verified live on 2026-08-10 (both contracts 200 with real data on both arms) but not campaign-run before this driver's first execution — read the first-iteration fail-fast output before trusting downstream leaves.",

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
      # ALL leaves should be eligible.
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
echo "HIBERNATE vs JDBC CAMPAIGN COMPLETE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "root: ${ROOT}"
echo "=============================================================="
