#!/usr/bin/env bash
# pure-native vs comp-native, n=3 — driver for run-full-triad-ab-ba.sh.
#
# THE ONLY SINGLE-VARIABLE MEASUREMENT OF THE PURE-vs-COMPAT WEB AXIS IN THIS REPO.
#   spring-on-exeris-pure-native   exeris.runtime.web.mode absent  (pure: @ExerisRoute)
#   spring-on-exeris-comp-native   exeris.runtime.web.mode=compatibility (@RestController)
#
# Both targets build from the SAME POM — the two jars' BOOT-INF/lib listings diff empty —
# and differ by exactly one property. Persistence, kernel, Boot, Jackson, pool and heap are
# identical by construction, not by matching. 1 pair x 1 run x 2 directions x 3 repeats
# x 2 contracts = 12 leaves (~40 min each, ~8 h).
#
# ============================================================================
# THIS CAMPAIGN IS EXPECTED TO PRODUCE non_eligible LEAVES. THAT IS CORRECT.
# ============================================================================
# Strict gate G3 (equivalence_strict) rejects a pair whose arms differ in mode — here
# pure vs compat — with rejection code EQUIVALENCE_MISMATCH. Pure-vs-Compat is a MANDATORY
# SEPARATION AXIS (CLAUDE.md), so a gate that refuses to call this a cross-target
# comparative claim is the gate working, not failing. What this campaign produces is a
# compat-family OVERHEAD measurement, which CLAUDE.md places in compat/: "pure-mode vs
# compatibility-mode overhead measurements; results from the two modes must be stored
# separately and labeled". Raw artefacts land under results/raw/ as usual (that is where
# unmodified tool output belongs); the derived overhead report belongs in compat/.
#
# The fail-fast block below is therefore INVERTED relative to the ladder and run-B drivers.
# Those assert that every leaf is comparison_eligible and abort on zero. Copying that logic
# here would abort this campaign after its first iteration, every time, by design. Instead
# this driver asserts that leaves are produced AND that the reason they are non_eligible is
# the expected one — an unexpected rejection code is what should stop the run.
#
# WHICH CONTRACT ANSWERS THE QUESTION: light.
# The two arms differ only in HTTP dispatch. On heavy, pure-native drove the pinned DB to
# 99.80 % and sat 26.7 % idle (ladder, n=12) — a dispatch-layer difference is invisible
# underneath that wall, and the earlier measurement of this axis showed exactly that shape
# (+2.3 % heavy vs +7.7 % light). Heavy is run anyway, because "the axis vanishes when the
# DB saturates" is itself a result worth having measured rather than asserted, and because
# the caller asked for both contracts. Read light as the answer and heavy as the control.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
ROOT="results/raw/entity-read-by-id/${CAMPAIGN_TS}-purenative-vs-compnative-n3"
mkdir -p "$ROOT"
cp -- "$0" "$ROOT/driver.sh"

# Ports from runtime/drivers/target-asset-matrix.json: pure-native 9006, comp-native 9007
# (disjoint precisely so these two can co-reside).
export BENCH_TRIAD_PAIRS="${BENCH_TRIAD_PAIRS:-1-purenative-vs-compnative:spring-on-exeris-pure-native:spring-on-exeris-comp-native:1:9006:9007}"

# DB client pinned by this caller — the runner exports no credentials and the target env
# files fall back to a legacy postgres/postgres that does not exist here. Omitting these
# does not fail fast: every target starts, never becomes ready, and the runner logs a skip.
# The query parameters are the fetch-mode normalisation, a first-class axis label.
export EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended'
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

# Repetition is the outer repeat loop below, not the runner's default of 20 runs per pair.
export BENCH_RUNS_PER_PAIR=1

export BENCH_TOTAL_MEMORY_MB=2048
# BOTH arms are Spring-family and read SPRING_JAVA_OPTS, so iso-heap here is structural
# rather than matched. Set explicitly anyway: footprint is a reported axis and the runner's
# per-family defaults are not all equal (BENCH_EXERIS_HEAP_MB defaults to 256).
export BENCH_SPRING_HEAP_MB=1280

export BENCH_SERVER_CPU_AFFINITY=0-1,8-9
export BENCH_LOADGEN_CPU_AFFINITY=2-3,10-11
export BENCH_DB_CPUSET=4-7,12-15

# HOST-NETWORKED DB, carried over from run B. Not strictly required here — both arms are the
# same stack issuing identical SQL, so a bridge tax would fall on them symmetrically and
# could not manufacture a compat-vs-pure difference. Kept host for three reasons: the DB is
# already in that state after run B (switching back means recreating the container mid-
# series), host removes a confound rather than adding one, and it keeps this campaign
# comparable to run B rather than to the bridged ladder.
# BENCH_DB_TUNED=1 changes reality (layers network_mode: host); DB_HOST_NETWORK=1 changes
# the recorded label. Both are required — see run-purenative-vs-quarkustuned-n3.sh.
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
    exit 1
  fi
  echo "[preflight] benchmark_db reachable as ${EXERIS_DB_USERNAME}"
else
  echo "[preflight] psql absent — DB connectivity not verified up front" >&2
fi

cat > "${ROOT}/campaign-manifest.json" <<JSON
{
  "campaign": "entity-read-by-id-purenative-vs-compnative-n3",
  "campaign_ts": "${CAMPAIGN_TS}",
  "commit_sha": "${BENCH_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}",
  "repeats": "01,02,03",
  "contracts": "heavy,light",
  "repeat_loop_position": "outer",
  "runs_per_pair": ${BENCH_RUNS_PER_PAIR},
  "expected_leaves": 12,
  "triad_pairs": "${BENCH_TRIAD_PAIRS}",
  "benchmark_family": "compat",
  "expected_claim_status": "non_eligible",
  "expected_rejection_code": "EQUIVALENCE_MISMATCH",
  "expected_claim_status_note": "BY DESIGN, not a failure. G3 equivalence_strict rejects a pair whose arms differ in mode (pure vs compat). Pure-vs-Compat is a mandatory separation axis, so the gate refusing to license a cross-target comparative claim is correct behaviour. This is a compat-family overhead measurement per CLAUDE.md; the derived report belongs in compat/, stored and labelled separately from pure-mode results. A leaf that is non_eligible for a DIFFERENT reason is a real failure and this driver aborts on it.",
  "single_variable_note": "spring-on-exeris-pure-native and spring-on-exeris-comp-native build from the same POM; the two jars' BOOT-INF/lib listings diff empty (verified on the perf box 2026-08-08). They differ by exactly one property, exeris.runtime.web.mode=compatibility. Persistence, kernel, Boot, Jackson, pool and heap are identical by construction.",
  "iso_heap_mb": ${BENCH_SPRING_HEAP_MB},
  "server_cpu_affinity": "${BENCH_SERVER_CPU_AFFINITY}",
  "loadgen_cpu_affinity": "${BENCH_LOADGEN_CPU_AFFINITY}",
  "db_cpuset": "${BENCH_DB_CPUSET}",
  "backend_network_mode": "host",
  "backend_network_mode_note": "Host networking, carried over from run B. Not required here — both arms are the same stack issuing identical SQL, so a bridge tax would fall symmetrically and could not manufacture a pure-vs-compat difference. Kept host because the DB is already in that state, it removes a confound, and it keeps this campaign comparable to run B rather than to the bridged ladder. FENCE: absolute levels do not cross to the 2026-08-06 ladder, which ran bridged.",
  "runtime_web_build": "$(ls -t "${HOME}/.m2/repository/eu/exeris/exeris-spring-runtime-web/0.5.0-SNAPSHOT/"*.jar 2>/dev/null | head -1 | xargs -r basename)",
  "runtime_build_note": "REQUIRES a published snapshot carrying exeris-spring-runtime PR #61 (merged 2026-08-08T07:57Z, commit c1650cb1, ADR-067 binary neutrality across the Spring Boot matrix). Before that fix the compat ResponseEntity return-value handler bound putAll(Map) — valid on Spring Framework 6 where HttpHeaders implemented MultiValueMap, an IncompatibleClassChangeError on Spring Framework 7 where it does not — so every ResponseEntity return value died and the light contract returned no response at all. The same PR fixed a second, latent instance of the same class in ExerisNativeWebRequest.getHeaderValues (HttpHeaders.get binds to get(Object) on SF6, get(String) on SF7 -> NoSuchMethodError); this benchmark never triggered it because the controller takes no @RequestHeader parameter. Both arms MUST be rebuilt from the SAME snapshot: they are only single-variable if their dependency sets are identical.",
  "cross_campaign_fence": "Rebuilding onto the post-#61 snapshot means this campaign's pure-native arm carries a DIFFERENT runtime build from both the 2026-08-06 ladder (snapshot -29, bridged DB) and run B (snapshot -29, host-net DB). Absolute levels do not cross those boundaries.",
  "free_control_note": "The two changed classes are compat-mode only, so pure mode should not load them and pure-native's behaviour should be unaffected by the rebuild. That is an EXPECTATION, not a measurement — but it is directly checkable and costs nothing: run B and this campaign both measure spring-on-exeris-pure-native under identical conditions (host-net DB, same pins, same heap, same contracts), differing only in the runtime snapshot. Agreement between the two pure-native arms is an external check on ADR-067's binary-neutrality claim; disagreement means the rebuild moved pure mode and this campaign's fences need widening.",
  "informative_contract": "light",
  "informative_contract_note": "The arms differ only in HTTP dispatch. On heavy, pure-native drove the pinned DB to 99.80 % mean utilisation with 26.7 % of its own CPU pin idle (ladder n=12), so a dispatch-layer difference is masked by the database ceiling; the earlier measurement of this axis showed +2.3 % heavy against +7.7 % light. Read light as the result and heavy as the control that demonstrates the masking.",
  "db_client": {
    "fetch_mode": "equalized",
    "jdbc_url": "${EXERIS_DB_JDBC_URL}",
    "username": "${EXERIS_DB_USERNAME}"
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

    # INVERTED fail-fast. See the header: non_eligible is the expected outcome, so the
    # ladder's "abort if zero eligible" would kill this campaign on its first iteration.
    # What must hold instead: leaves exist, and every non-eligible one carries the EXPECTED
    # rejection code. Anything else is a real failure worth stopping for.
    if [[ "$first_iteration" == "1" ]]; then
      produced=$(find "$out" -name claim-status.json 2>/dev/null | wc -l)
      if [[ "$produced" -eq 0 ]]; then
        echo "ABORT: first iteration produced no comparative leaves (0 claim-status.json)." >&2
        echo "The runner treats an unready target as a skipped step, so a misconfiguration" >&2
        echo "yields a COMPLETE campaign with nothing in it. Not continuing." >&2
        exit 1
      fi

      unexpected=0
      while IFS= read -r cs; do
        status=$(jq -r '.claim_status // "?"' "$cs")
        codes=$(jq -r '(.rejection_codes // []) | join(",")' "$cs")
        if [[ "$status" == "comparison_eligible" ]]; then
          # Not fatal, but it means G3 did NOT see a mode difference — which would mean the
          # two arms are not actually in different web modes, i.e. the axis under test is
          # not present. Loud, because it invalidates the whole campaign silently.
          echo "[fail-fast] WARNING: leaf is comparison_eligible — expected non_eligible." >&2
          echo "[fail-fast] G3 saw no mode difference. Verify exeris.runtime.web.mode is" >&2
          echo "[fail-fast] actually set on comp-native; if it is not, this campaign is" >&2
          echo "[fail-fast] measuring pure against pure. Leaf: ${cs}" >&2
          unexpected=$((unexpected + 1))
        elif [[ "$codes" != *"EQUIVALENCE_MISMATCH"* ]]; then
          echo "[fail-fast] UNEXPECTED rejection: ${codes} (leaf ${cs})" >&2
          unexpected=$((unexpected + 1))
        fi
      done < <(find "$out" -name claim-status.json | sort)

      if [[ "$unexpected" -gt 0 ]]; then
        echo "ABORT: ${unexpected}/${produced} leaf/leaves did not match the expected" >&2
        echo "non_eligible + EQUIVALENCE_MISMATCH outcome. The remaining five iterations" >&2
        echo "would repeat whatever this is." >&2
        exit 1
      fi

      echo "[fail-fast] first iteration: ${produced} leaf/leaves, all non_eligible with the"
      echo "[fail-fast] expected EQUIVALENCE_MISMATCH — this is the designed outcome. Continuing."
      first_iteration=0
    fi
  done
done

echo "=============================================================="
echo "PURE-NATIVE vs COMP-NATIVE CAMPAIGN COMPLETE  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "root: ${ROOT}"
echo "Store the derived overhead report under compat/, labelled separately from pure-mode results."
echo "=============================================================="
