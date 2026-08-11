#!/usr/bin/env bash
#
# run-security-confound-n3.sh — put a number on the last unbounded confound in the Spring ladder.
#
# WHAT IS UNBOUNDED
#
# The hosting rung — spring-hibernate -> spring-on-exeris-pure, 121.52 us/req, x1.127 (CLAIMS L3,
# report §6) — crosses a boundary that is not only hosting. The Tomcat arm carries
# spring-boot-starter-security and runs a servlet SecurityFilterChain that reaches an authorization
# decision on every request even when the match is permitAll; the Exeris arm carries no Spring
# Security at all. The repo's fairness rules forbid borrowing the Exeris-side bound (+0.14 %),
# because a FilterChainProxy dispatch with SecurityContextHolder lifecycle and AuthorizationManager
# evaluation is a different and heavier mechanism.
#
# It lands on the smallest effect in the report, which is what makes it matter: a chain costing
# 10 / 20 / 30 us per request would be 8.2 / 16.5 / 24.7 % of the ENTIRE hosting gain.
#
# READ LIGHT. HEAVY CANNOT ANSWER THIS — THAT IS ARITHMETIC, NOT PREFERENCE.
#
# Against the +/-2.80 % cpu/req error budget:
#
#   contract   baseline    10 us     20 us     30 us
#   heavy      1077.4 us   0.93 %    1.86 %    2.78 %   <- all at or BELOW the noise floor
#   light       146.7 us   6.82 %   13.63 %   20.45 %   <- resolvable
#
# So the measurement is the LIGHT contract. Heavy still runs, but as a TEST OF TRANSFERABILITY: a
# per-request filter chain should cost roughly constant absolute microseconds whatever the
# contract, and heavy can falsify that even where it cannot measure it. A heavy null result is the
# expected outcome and means nothing on its own — do not report it as "no effect on heavy".
#
# ONE JAR, ONE VARIABLE
#
# Both arms launch targets/spring-benchmark-app/target/spring-benchmark-app-1.0.0-SNAPSHOT.jar with
# identical artifact_sha256. Classpath, loaded classes and metaspace are held constant, so RSS stays
# comparable; only the filter chain moves. Building a second module without the starter would have
# changed all of those at once. Same design as comp-native vs pure-native: one POM, one property.
#
# TWO THINGS THAT WENT WRONG IN CONSTRUCTION, BOTH CAUGHT BY BOOT-VERIFY
#
# 1. Gating the whole SecurityConfig class removed its JwtEncoder bean, which AuthTokenService
#    requires, and the app refused to start. Only the chain is now gated
#    (SecurityFilterChainConfig); the JWT key material stays unconditional and costs nothing per
#    request.
# 2. The first auto-configuration exclusion list used Boot-3 package names. In Boot 4 security
#    auto-config moved to spring-boot-security / spring-boot-security-oauth2-resource-server under
#    org.springframework.boot.security.autoconfigure.*. The Boot-3 names matched nothing SILENTLY:
#    the arm booted clean, logged no error, and served 401 from the default chain — measuring the
#    exact opposite of what was asked while looking healthy. Only an unauthenticated curl caught it.
#
# Hence the preflight below does not merely check for 200. It proves the chain is ABSENT rather than
# permissive, by hitting a path the stock config marks authenticated(): stock answers 401 (the chain
# evaluated and denied), nosec must answer 404/405 (the request reached Spring MVC directly).
#
# Cost: 1 pair x 1 run x 2 directions x 3 repeats x 2 contracts = 12 leaves, ~8 h.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

export BENCH_TRIAD_PAIRS="${BENCH_TRIAD_PAIRS:-1-sec-vs-nosec:spring-hibernate:spring-hibernate-nosec:1:9001:9009}"

export EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended'
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

export BENCH_RUNS_PER_PAIR=1
export BENCH_TOTAL_MEMORY_MB=2048
export BENCH_SPRING_HEAP_MB=1280
export BENCH_SERVER_CPU_AFFINITY=0-1,8-9
export BENCH_LOADGEN_CPU_AFFINITY=2-3,10-11
export BENCH_DB_CPUSET=4-7,12-15
export BENCH_DB_TUNED=1
export DB_HOST_NETWORK=1
export WARMUP_SECONDS=300
export MEASUREMENT_SECONDS=900

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
ROOT="results/raw/entity-read-by-id/${CAMPAIGN_TS}-security-confound-n3"
mkdir -p "$ROOT"

declare -A CONTRACT=(
  [light]=fixed_contract_cross_runtime_h1_single_read_v1
  [heavy]=fixed_contract_cross_runtime_h1_v2
)

if command -v psql >/dev/null 2>&1; then
  PGPASSWORD="$EXERIS_DB_PASSWORD" psql -h localhost -U "$EXERIS_DB_USERNAME" -d benchmark_db -c 'select 1' >/dev/null 2>&1 \
    || { echo "PREFLIGHT FAILED: benchmark_db unreachable as ${EXERIS_DB_USERNAME}" >&2; exit 1; }
  echo "[preflight] benchmark_db reachable as ${EXERIS_DB_USERNAME}"
fi

# ---------------------------------------------------------------------------
# Preflight: prove the chain is absent on nosec and present on stock.
# ---------------------------------------------------------------------------
echo "[preflight] boot-verifying spring-hibernate (9001) and spring-hibernate-nosec (9009)"
for spec in "spring-hibernate:9001:401" "spring-hibernate-nosec:9009:absent"; do
  tid="${spec%%:*}"; rest="${spec#*:}"; port="${rest%%:*}"; expect="${rest##*:}"
  ./runtime/drivers/stop-target.sh "$tid" >/dev/null 2>&1 || true
  if ! ./runtime/drivers/start-target.sh "$tid" >/tmp/preflight-${tid}.log 2>&1; then
    echo "PREFLIGHT FAILED: ${tid} did not become ready. See /tmp/preflight-${tid}.log" >&2
    exit 1
  fi
  heavy_code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/api/v1/users")"
  light_code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/api/v1/user?id=1")"
  if [[ "$heavy_code" != "200" || "$light_code" != "200" ]]; then
    echo "PREFLIGHT FAILED: ${tid} heavy=${heavy_code} light=${light_code} (expected 200/200)." >&2
    echo "A 401 here means the filter chain is active on an arm that should not have one; note the" >&2
    echo "unauthorized /error forward makes every failure look like an auth problem, so read the" >&2
    echo "app log for the underlying exception before believing the status code." >&2
    exit 1
  fi

  # The decisive check. /api/v1/orders is anyRequest().authenticated() in the stock config.
  guarded="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/api/v1/orders")"
  if [[ "$expect" == "401" && "$guarded" != "401" ]]; then
    echo "PREFLIGHT FAILED: ${tid} answered ${guarded} on a guarded path, expected 401." >&2
    echo "The stock arm MUST still run its filter chain — otherwise the pair measures nothing." >&2
    exit 1
  fi
  if [[ "$expect" == "absent" && "$guarded" == "401" ]]; then
    echo "PREFLIGHT FAILED: ${tid} answered 401 on a guarded path — a filter chain is STILL ACTIVE." >&2
    echo "This is the failure mode that looks healthy: 200 on permitAll paths while a default" >&2
    echo "chain runs underneath. Check that the Boot 4 auto-configuration exclusions in" >&2
    echo "runtime/drivers/env/spring-hibernate-nosec.env still match the classes on the classpath:" >&2
    echo "  unzip -l targets/spring-benchmark-app/target/*.jar | grep spring-boot-security" >&2
    exit 1
  fi
  echo "[preflight] ${tid}: heavy=200 light=200 guarded=${guarded} (expected ${expect})"
done
for tid in spring-hibernate spring-hibernate-nosec; do
  ./runtime/drivers/stop-target.sh "$tid" >/dev/null 2>&1 || true
done
sleep 2

cat > "${ROOT}/campaign-manifest.json" <<JSON
{
  "campaign": "entity-read-by-id-security-confound-n3",
  "campaign_ts": "${CAMPAIGN_TS}",
  "commit_sha": "${BENCH_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}",
  "repeats": "01,02,03",
  "contracts": "light,heavy",
  "contract_order_note": "Light runs FIRST because it is the measurement; heavy is a transferability test only.",
  "repeat_loop_position": "outer",
  "runs_per_pair": ${BENCH_RUNS_PER_PAIR},
  "expected_leaves": 12,
  "triad_pairs": "${BENCH_TRIAD_PAIRS}",
  "benchmark_family": "runtime",
  "axis_under_test": "servlet-security-filter-chain",
  "axis_under_test_note": "One jar, identical artifact_sha256 on both arms, separated by benchmark.security.filter-chain.enabled plus seven Boot 4 security auto-configuration exclusions. Bounds the unmeasured security term inside the 121.52 us/req hosting rung of CLAIMS L3.",
  "READ_LIGHT_NOT_HEAVY": "Against the +/-2.80 % cpu/req budget a 10-30 us chain is 0.93-2.78 % of heavy's 1077 us baseline (at or below the noise floor) and 6.8-20.5 % of light's 147 us. Heavy is a transferability test; a heavy null result means nothing on its own.",
  "iso_heap_mb": ${BENCH_SPRING_HEAP_MB},
  "server_cpu_affinity": "${BENCH_SERVER_CPU_AFFINITY}",
  "loadgen_cpu_affinity": "${BENCH_LOADGEN_CPU_AFFINITY}",
  "db_cpuset": "${BENCH_DB_CPUSET}",
  "backend_network_mode": "host",

  "AXIS_FENCES": "The nosec arm is not a shippable configuration and is not a comparator for anything except its own stock twin.",
  "fence_not_the_exeris_mechanism": "This bounds the cost of THIS app's permitAll chain on Tomcat. It is not a general figure for Spring Security, and the Exeris arm's ExerisSecurityContextFilter is a different mechanism measured separately (+0.14 %).",
  "fence_jwt_beans_remain": "Only the SecurityFilterChain is gated. RSAKey/JwtEncoder/JwtDecoder stay in both arms — AuthTokenService needs JwtEncoder and gating the whole config broke startup. They cost nothing on the request path, and keeping them means the arms differ by the chain alone rather than by a bean graph.",
  "fence_boot4_package_move": "The exclusion list is Boot-4 specific. Boot-3 package names match nothing SILENTLY and yield a default chain serving 401 while the app looks healthy; re-derive the names from the jar if Boot is upgraded.",

  "db_client": {
    "fetch_mode": "equalized",
    "jdbc_url": "${EXERIS_DB_JDBC_URL}",
    "username": "${EXERIS_DB_USERNAME}"
  }
}
JSON

first_iteration=1
for repeat in 01 02 03; do
  for kind in light heavy; do
    out="${ROOT}/repeat${repeat}/${kind}"
    mkdir -p "$out"
    echo "=============================================================="
    echo "repeat${repeat} / ${kind} / contract=${CONTRACT[$kind]}"
    echo "started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=============================================================="
    BENCH_CAMPAIGN_OUTPUT_DIR_OVERRIDE="$out" \
    BENCH_CONTRACT_ID="${CONTRACT[$kind]}" \
      ./scripts/run-full-triad-ab-ba.sh 2>&1 | tee "${out}/campaign.log"

    if [[ "$first_iteration" == "1" ]]; then
      produced=$(find "$out" -name claim-status.json 2>/dev/null | wc -l)
      eligible=$(find "$out" -name claim-status.json -exec jq -r '.claim_status // empty' {} \; 2>/dev/null | grep -c '^comparison_eligible$' || true)
      if [[ "$produced" -eq 0 ]]; then
        echo "ABORT: first iteration produced no comparative leaves (0 claim-status.json)." >&2
        exit 1
      fi
      if [[ "$eligible" -eq 0 ]]; then
        echo "ABORT: ${produced} leaf/leaves, NONE comparison_eligible. Both arms are mode=pure so" >&2
        echo "every leaf should clear G3; zero eligible means a common failure." >&2
        exit 1
      fi
      echo "[fail-fast] first iteration: ${produced} leaf/leaves, ${eligible} comparison_eligible — continuing"
      first_iteration=0
    fi
  done
done

echo "=============================================================="
echo "SECURITY CONFOUND CAMPAIGN COMPLETE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "root: ${ROOT}"
echo "Read the LIGHT contract for the answer; heavy is the transferability test."
echo "=============================================================="
