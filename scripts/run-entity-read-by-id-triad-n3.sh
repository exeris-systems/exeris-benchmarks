#!/usr/bin/env bash
set -euo pipefail

# run-entity-read-by-id-triad-n3.sh
#
# Campaign C1 of docs/campaign-plan-2026-08-triad-n3-and-protocol-axis.md:
# the n=3 firming run of the 2026-07-21 comparison_eligible triad.
#
# WHY THIS WRAPPER EXISTS — it is not just "BENCH_RUNS_PER_PAIR=3".
#
#   1. Repeat-as-OUTER-loop. run-full-triad-ab-ba.sh iterates run_num *inside*
#      run_pair_block, so BENCH_RUNS_PER_PAIR=3 would run a pair's three repeats
#      back-to-back and control nothing but within-pair jitter. The 2026-07-22 sweep
#      made repeat the outer loop precisely so each (pair, arm) sample is spread across
#      the campaign. This wrapper therefore invokes the campaign once per repeat with
#      BENCH_RUNS_PER_PAIR=1 and pins each into its own output root.
#
#   2. track_id disambiguation. With run_num pinned to 1, every invocation would mint the
#      same track-<order>-01 id. BENCH_REPEAT_ID (added to the runner for this campaign)
#      folds the repeat into the id, so repeats stay distinguishable — track_id is an
#      isolation boundary and silently-pooled repeats are exactly what it exists to stop.
#
#   3. Cold-cache warm-through (triad Limitations, correction #7): each pair block
#      re-provisions Postgres, so the ~8% cold-buffer-cache penalty lands entirely on
#      whichever arm is measured first. BENCH_PAIR_WARM_THROUGH_SECONDS drives a discarded
#      pass against BOTH arms before leaf 1.
#
#   4. JFR disk containment WITHOUT weakening a correction. The campaign generates
#      ~110-145 GB of complete JFR recordings. Lowering BENCH_JFR_MAX_SIZE_MB would
#      reintroduce triad bug 4 (size rotation retains only a tail); enabling JFR on one
#      repeat only would make the repeats different-config and the medians meaningless.
#      So JFR config stays IDENTICAL across all leaves and the raw artifact is pruned
#      after per-leaf metric extraction, retaining raw only for a declared subset.
#
# Usage:
#   scripts/run-entity-read-by-id-triad-n3.sh [options]
#
#   --repeats   01,02,03     which repeats to run (default all three; use to resume)
#   --contracts light,heavy  which contracts to run (default both)
#   --output-root PATH       campaign root (default results/raw/entity-read-by-id/<ts>-triad-n3)
#   --retain-jfr 01          comma-separated repeats whose raw .jfr is kept (default 01)
#   --keep-all-jfr           retain every raw .jfr (needs ~145 GB free)
#   --min-free-gb N          preflight free-space floor (default 120)
#   --dry-run                print the schedule and preflight only; measure nothing
#
# Targets must be buildable by the campaign's own prebuild step; Postgres is provisioned
# per pair block by the scenario infra script. Run this from the repo root on the perf box.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCENARIO_ID="entity-read-by-id"
SCENARIO_JSON="scenarios/${SCENARIO_ID}/scenario.json"
TRIAD_RUNNER="./scripts/run-full-triad-ab-ba.sh"

REPEATS="01,02,03"
CONTRACTS="light,heavy"
RETAIN_JFR_REPEATS="01"
KEEP_ALL_JFR=0
MIN_FREE_GB=120
DRY_RUN=0
CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT=""

# Contract ids — the two fixed contracts the 2026-07-21 report measured (300s warmup /
# 900s measurement, "_v2"-class windows). Both are protocol-pinned h1.
CONTRACT_ID_light="fixed_contract_cross_runtime_h1_single_read_v1"
CONTRACT_ID_heavy="fixed_contract_cross_runtime_h1_v2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeats)       REPEATS="$2"; shift 2 ;;
    --contracts)     CONTRACTS="$2"; shift 2 ;;
    --output-root)   OUTPUT_ROOT="$2"; shift 2 ;;
    --retain-jfr)    RETAIN_JFR_REPEATS="$2"; shift 2 ;;
    --keep-all-jfr)  KEEP_ALL_JFR=1; shift ;;
    --min-free-gb)   MIN_FREE_GB="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '1,50p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option '$1' (see --help)" >&2; exit 64 ;;
  esac
done

OUTPUT_ROOT="${OUTPUT_ROOT:-results/raw/${SCENARIO_ID}/${CAMPAIGN_TS}-triad-n3}"

# ---------------------------------------------------------------------------
# Campaign configuration — inherited VERBATIM from the 2026-07-21 triad.
# Changing any of these breaks continuity with the report this campaign firms up,
# which is the entire point of the run. See the runbook §3.2.
# ---------------------------------------------------------------------------
export HARDWARE_PROFILE="perf-box-amd64"
export BENCH_DB_TUNED="${BENCH_DB_TUNED:-1}"
export BENCH_SERVER_CPU_AFFINITY="${BENCH_SERVER_CPU_AFFINITY:-0-1,8-9}"
export BENCH_LOADGEN_CPU_AFFINITY="${BENCH_LOADGEN_CPU_AFFINITY:-2-3,10-11}"
export BENCH_TOTAL_MEMORY_MB="${BENCH_TOTAL_MEMORY_MB:-2048}"
export BENCH_EXERIS_HEAP_MB="${BENCH_EXERIS_HEAP_MB:-256}"
export BENCH_QUARKUS_HEAP_MB="${BENCH_QUARKUS_HEAP_MB:-1280}"
export BENCH_DB_POOL_MIN_SIZE="${BENCH_DB_POOL_MIN_SIZE:-16}"
export BENCH_DB_POOL_MAX_SIZE="${BENCH_DB_POOL_MAX_SIZE:-256}"
export BENCH_ENABLE_NATIVE_MEMORY_TRACKING="${BENCH_ENABLE_NATIVE_MEMORY_TRACKING:-1}"
export BENCH_NATIVE_MEMORY_TRACKING_LEVEL="${BENCH_NATIVE_MEMORY_TRACKING_LEVEL:-summary}"
export BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS="${BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS:-1}"
# Non-rotating JFR ceiling — keeps triad bug 4 fixed. Identical on every leaf.
export BENCH_JFR_SETTINGS="${BENCH_JFR_SETTINGS:-profile}"
export BENCH_JFR_MAX_SIZE_MB="${BENCH_JFR_MAX_SIZE_MB:-6144}"
# Correction #7 — discarded pre-leaf pass against both arms.
export BENCH_PAIR_WARM_THROUGH_SECONDS="${BENCH_PAIR_WARM_THROUGH_SECONDS:-60}"
# The quarkus-focused triad measured by the 2026-07-21 report.
export BENCH_TRIAD_PAIRS="${BENCH_TRIAD_PAIRS:-1-exeris-vs-quarkus-tuned:exeris-community:quarkus-tuned:1:9000:9003;2-exeris-vs-quarkus-hibernate:exeris-community:quarkus-hibernate:2:9000:9002;3-quarkus-hibernate-vs-tuned:quarkus-hibernate:quarkus-tuned:3:9002:9003}"

# ---------------------------------------------------------------------------
# DB CLIENT CONFIGURATION — the caller's job, and historically the caller's bug.
#
# run-full-triad-ab-ba.sh exports NO database credentials, and the per-target env files
# (runtime/drivers/env/*.env) fall back to a legacy postgres/postgres/…/postgres default
# that does not exist in the benchmark database (role "benchmark", db "benchmark_db").
# Every campaign therefore has to set these itself — which is exactly triad bug 5: "The
# configuration lives in whichever caller launched the campaign, so each caller had to be
# fixed separately (9f2b182 for the sweep/matrix path, d1032c8 for the promotion path,
# five lines, months apart, same root cause)." This is the third caller; it is fixed here
# explicitly rather than inherited from whatever happens to be in the operator's shell.
#
# BENCH_DB_FETCH_MODE selects the pgjdbc fetch configuration, which is NOT cosmetic: on the
# heavy aggregate it inverts the ranking (report conclusion 2 vs its "does not support"
# counterpart). The light single-read is fetch-insensitive.
#   equalized — the §8 promotion URL; the report's "fair, DB-normalized comparison"
#   default   — prepareThreshold only; each arm on the driver's own fetch behavior
BENCH_DB_FETCH_MODE="${BENCH_DB_FETCH_MODE:-equalized}"
case "$BENCH_DB_FETCH_MODE" in
  equalized) _DB_QUERY_PARAMS="prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended" ;;
  default)   _DB_QUERY_PARAMS="prepareThreshold=1" ;;
  *) echo "ERROR: BENCH_DB_FETCH_MODE must be 'equalized' or 'default' (got '${BENCH_DB_FETCH_MODE}')" >&2; exit 64 ;;
esac
export EXERIS_DB_JDBC_URL="${EXERIS_DB_JDBC_URL:-jdbc:postgresql://localhost:5432/benchmark_db?${_DB_QUERY_PARAMS}}"
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

# Reproducibility metadata requires the commit the measured code came from. The perf box
# runs an rsync MIRROR, not a git checkout, so `git rev-parse` there yields nothing and the
# manifest would silently record "unknown" — defeating the point of committing before the
# sync. The syncing side therefore passes the SHA in explicitly.
CAMPAIGN_COMMIT_SHA="${BENCH_CAMPAIGN_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"

log()  { echo -e "\033[0;36m[triad-n3]\033[0m $*"; }
warn() { echo -e "\033[1;33m[triad-n3] WARN\033[0m $*" >&2; }
fail() { echo -e "\033[0;31m[triad-n3] ERROR\033[0m $*" >&2; exit 1; }

contract_id_for() {
  case "$1" in
    light) echo "$CONTRACT_ID_light" ;;
    heavy) echo "$CONTRACT_ID_heavy" ;;
    *) fail "unknown contract alias '$1' (expected light|heavy)" ;;
  esac
}

contract_field() {
  jq -r --arg c "$1" --arg f "$2" '.fixed_contracts[$c][$f] // empty' "$SCENARIO_JSON"
}

# ---------------------------------------------------------------------------
# Preflight — fail fast. A 30h campaign must not die on hour 12 for a missing tool.
# ---------------------------------------------------------------------------
preflight() {
  log "Preflight"

  [[ -x "$TRIAD_RUNNER" ]] || fail "$TRIAD_RUNNER not found or not executable"
  [[ -f "$SCENARIO_JSON" ]] || fail "$SCENARIO_JSON not found"

  local tool
  for tool in jq wrk java; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool '$tool' not on PATH"
  done
  command -v jfr >/dev/null 2>&1 || warn "'jfr' not on PATH — JFR metric extraction will be skipped and raw .jfr cannot be pruned safely"

  # The runner reads BENCH_REPEAT_ID / BENCH_PAIR_WARM_THROUGH_SECONDS; without them this
  # wrapper silently degrades to indistinguishable track ids and an uncontrolled cold cache.
  grep -q 'BENCH_REPEAT_ID' "$TRIAD_RUNNER" \
    || fail "$TRIAD_RUNNER lacks BENCH_REPEAT_ID support — repeats would share a track_id. Apply the runner patch that ships with this wrapper."
  grep -q 'pair_db_warm_through' "$TRIAD_RUNNER" \
    || fail "$TRIAD_RUNNER lacks the pair warm-through hook — correction #7 would be uncontrolled."

  local c cid w d
  for c in ${CONTRACTS//,/ }; do
    cid="$(contract_id_for "$c")"
    [[ -n "$(contract_field "$cid" endpoint)" ]] || fail "contract '$cid' not found in $SCENARIO_JSON"
    w="$(contract_field "$cid" warmup_seconds)"
    d="$(contract_field "$cid" duration_seconds)"
    [[ -n "$w" && -n "$d" ]] || fail "contract '$cid' is missing warmup_seconds/duration_seconds"
    log "  contract ${c}: ${cid} — ${w}s warmup / ${d}s measurement, endpoint $(contract_field "$cid" endpoint)"
  done

  local free_gb
  free_gb="$(df -BG --output=avail . | tail -1 | tr -dc '0-9')"
  log "  free disk: ${free_gb} GB (floor ${MIN_FREE_GB} GB)"
  if (( free_gb < MIN_FREE_GB )); then
    fail "only ${free_gb} GB free; campaign needs ~${MIN_FREE_GB} GB (see runbook §3.5). Free space, mount a larger volume, or lower --min-free-gb deliberately."
  fi

  if [[ "$BENCH_DB_TUNED" != "1" ]]; then
    warn "BENCH_DB_TUNED != 1 — Postgres will NOT be host-networked/cpuset-isolated; this diverges from the 2026-07-21 setup"
  fi

  if [[ "$CAMPAIGN_COMMIT_SHA" == "unknown" ]]; then
    fail "commit SHA unresolved — this host is not a git checkout and BENCH_CAMPAIGN_COMMIT_SHA was not passed. Reproducibility metadata would be incomplete; pass the SHA of the synced code."
  fi
  log "  commit: ${CAMPAIGN_COMMIT_SHA}"

  # The DB-config fingerprint gate (triad bug 5, 518b23c) is the correction this campaign
  # is meant to be the first to run under. A mirror that predates it would produce results
  # indistinguishable from the ungated ones — fail rather than measure for 30h without it.
  if ! grep -q 'DB_CONFIG_ASYMMETRIC' scripts/run-comparative.sh 2>/dev/null; then
    fail "scripts/run-comparative.sh predates the DB-config fairness gate (518b23c). Sync the current code before running."
  fi
  log "  DB-config fairness gate: present"

  # Catch the bug-5 shape before it costs a measurement window: an unset credential makes
  # the target env files fall back to the legacy postgres/postgres default, and the app
  # dies at pool init with 'role "postgres" does not exist' AFTER the harness has already
  # provisioned and seeded the database.
  local u="${EXERIS_DB_USERNAME:-}" url="${EXERIS_DB_JDBC_URL:-}"
  [[ -n "$u" && -n "$url" && -n "${EXERIS_DB_PASSWORD:-}" ]] \
    || fail "DB credentials incomplete — targets would fall back to the legacy postgres/postgres default and fail at pool init."
  if [[ "$u" == "postgres" || "$url" == *"/postgres?"* ]]; then
    warn "DB client points at role/db 'postgres' — the benchmark database uses role 'benchmark' / db 'benchmark_db'. This is the bug-5 default; verify deliberately."
  fi
  log "  DB fetch mode: ${BENCH_DB_FETCH_MODE}"
  log "  DB client: ${u}@${url}"

  log "Preflight OK"
}

# ---------------------------------------------------------------------------
# JFR containment: extract derived metrics for every leaf, then prune raw recordings
# for repeats outside the retention set. JFR *configuration* is untouched — every leaf
# records identically, so the repeats stay same-config and the medians stay meaningful.
# ---------------------------------------------------------------------------
prune_jfr_for_repeat() {
  local repeat="$1" repeat_dir="$2"

  if (( KEEP_ALL_JFR )); then
    log "  JFR: --keep-all-jfr set; retaining every raw recording under ${repeat_dir}"
    return 0
  fi

  local retain=0
  case ",${RETAIN_JFR_REPEATS}," in *",${repeat},"*) retain=1 ;; esac

  local extractor="tools/extract-jfr-metrics.sh"
  local jfr_file metrics_json extracted=0 pruned=0 failed=0

  while IFS= read -r -d '' jfr_file; do
    metrics_json="${jfr_file%.jfr}-jfr-metrics.json"
    if [[ -x "$extractor" ]] && command -v jfr >/dev/null 2>&1; then
      if "$extractor" "$jfr_file" "$metrics_json" >/dev/null 2>&1; then
        extracted=$((extracted + 1))
      else
        failed=$((failed + 1))
        warn "JFR extraction failed for ${jfr_file} — raw recording RETAINED"
        continue
      fi
    else
      failed=$((failed + 1))
      warn "no usable JFR extractor — raw recording RETAINED: ${jfr_file}"
      continue
    fi

    if (( retain == 0 )); then
      rm -f "$jfr_file"
      pruned=$((pruned + 1))
    fi
  done < <(find "$repeat_dir" -type f -name '*.jfr' -print0 2>/dev/null)

  log "  JFR repeat ${repeat}: extracted=${extracted} pruned=${pruned} retained_on_error=${failed} (retention set: ${RETAIN_JFR_REPEATS})"
}

# ---------------------------------------------------------------------------
# One campaign invocation = one (repeat, contract) leaf-set.
# ---------------------------------------------------------------------------
run_leafset() {
  local repeat="$1" contract_alias="$2"
  local cid warmup duration outdir
  cid="$(contract_id_for "$contract_alias")"
  warmup="$(contract_field "$cid" warmup_seconds)"
  duration="$(contract_field "$cid" duration_seconds)"
  outdir="${OUTPUT_ROOT}/repeat${repeat}/${contract_alias}"

  log "=== repeat ${repeat} · contract ${contract_alias} (${cid}) → ${outdir}"

  if (( DRY_RUN )); then
    log "    [dry-run] would run 3 pairs x {ab,ba} at ${warmup}s/${duration}s, track suffix r${repeat}"
    return 0
  fi

  mkdir -p "$outdir"

  # WARMUP_SECONDS / MEASUREMENT_SECONDS must equal the contract's own values —
  # run-comparative.sh treats them as immutable contract knobs and fails closed on
  # mismatch, so passing them explicitly is belt-and-braces, not a config choice.
  set +e
  BENCH_RUNS_PER_PAIR=1 \
  BENCH_REPEAT_ID="$repeat" \
  BENCH_CONTRACT_ID="$cid" \
  WARMUP_SECONDS="$warmup" \
  MEASUREMENT_SECONDS="$duration" \
  BENCH_CAMPAIGN_OUTPUT_DIR_OVERRIDE="$outdir" \
    "$TRIAD_RUNNER" 2>&1 | tee -a "${outdir}/campaign.log"
  local status="${PIPESTATUS[0]:-1}"
  set -e

  if (( status != 0 )); then
    warn "repeat ${repeat} / ${contract_alias} exited ${status} — continuing; inspect ${outdir}/campaign.log"
    echo "repeat=${repeat} contract=${contract_alias} status=${status}" >> "${OUTPUT_ROOT}/FAILURES.txt"
  fi
  return 0
}

# ---------------------------------------------------------------------------
main() {
  preflight

  mkdir -p "$OUTPUT_ROOT"
  log "Campaign root: ${OUTPUT_ROOT}"
  log "Schedule: repeats [${REPEATS}] x contracts [${CONTRACTS}], repeat is the OUTER loop"
  log "Estimated wall clock: ~$(( $(tr -cd ',' <<<"$REPEATS" | wc -c) + 1 )) repeats x $(( $(tr -cd ',' <<<"$CONTRACTS" | wc -c) + 1 )) contracts x 3 pairs x 2 orders x ~45 min/leaf"

  # Campaign-level provenance so the report never has to reconstruct how this ran.
  jq -n \
    --arg ts "$CAMPAIGN_TS" --arg repeats "$REPEATS" --arg contracts "$CONTRACTS" \
    --arg retain "$RETAIN_JFR_REPEATS" --arg pairs "$BENCH_TRIAD_PAIRS" \
    --arg warm "$BENCH_PAIR_WARM_THROUGH_SECONDS" --arg profile "$HARDWARE_PROFILE" \
    --arg sha "$CAMPAIGN_COMMIT_SHA" \
    --arg fetchmode "$BENCH_DB_FETCH_MODE" --arg dburl "$EXERIS_DB_JDBC_URL" \
    --arg dbuser "$EXERIS_DB_USERNAME" \
    '{campaign: "entity-read-by-id-triad-n3", campaign_ts: $ts, commit_sha: $sha,
      hardware_profile: $profile, repeats: $repeats, contracts: $contracts,
      repeat_loop_position: "outer",
      jfr_raw_retention_repeats: $retain,
      jfr_config: "identical on every leaf (settings=profile, non-rotating ceiling)",
      pair_warm_through_seconds: $warm, triad_pairs: $pairs,
      db_client: { fetch_mode: $fetchmode, jdbc_url: $dburl, username: $dbuser,
                   note: "Set explicitly by this caller. run-full-triad-ab-ba.sh exports no DB credentials and the target env files default to a legacy postgres/postgres that does not exist in this database — triad bug 5. fetch_mode inverts the heavy-contract ranking and is therefore a first-class axis label, not a detail." },
      corrections_applied: ["#5 db-config fingerprint gate (inherited)",
                            "#5b db client pinned by the caller + recorded",
                            "#6 n=3", "#7 pair warm-through", "#8 repeat-as-outer-loop"]}' \
    > "${OUTPUT_ROOT}/campaign-manifest.json"

  local repeat contract
  for repeat in ${REPEATS//,/ }; do
    for contract in ${CONTRACTS//,/ }; do
      run_leafset "$repeat" "$contract"
    done
    (( DRY_RUN )) || prune_jfr_for_repeat "$repeat" "${OUTPUT_ROOT}/repeat${repeat}"
  done

  log "Campaign complete: ${OUTPUT_ROOT}"
  if [[ -f "${OUTPUT_ROOT}/FAILURES.txt" ]]; then
    warn "some leaf-sets reported failures:"
    cat "${OUTPUT_ROOT}/FAILURES.txt" >&2
  fi
  log "Next: verify per-leaf acceptance checks (runbook §3.6) before any aggregation."
}

main "$@"
