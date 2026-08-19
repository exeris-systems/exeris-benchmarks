#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCENARIO_JSON="$REPO_ROOT/scenarios/e2e-shop-order-saga/scenario.json"
cd "$REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: run-e2e-shop-order-saga-campaign.sh [options]

Options:
  --targets <list>              Comma-separated target app labels (required)
  --graph-track <name>          Graph track: neo4j|pgq_pure|age_compat (default: neo4j)
  --fault-mode <mode>           Fault-class label per CONTRACT-v2 s4: terminal|transient (default: terminal)
  --repeats <n>                 Repetitions per target (default: 3)
  --profile <name>              Hardware profile label (default: perf-box-amd64)
  --output-dir <path>           Campaign output directory
  --contract-id <id>            Override contract id; default: auto-derived per target from scenario.json graph_track
  --jfr-max-size-mb <n>         JFR max file size per run in MB (default: 256)
  --db-pool-max <n>             DB connection pool max size (default: 32)
  --skip-seed-verify            Skip seed verification in baseline runs (default: disabled)
  --cgroup-memory-limit-mb <n>  OS-level memory limit per target process (cgroup v2, MB). Empty = disabled.
  --cgroup-cpu-quota-pct <n>    OS-level CPU quota per target process (cgroup v2, %). Empty = disabled.
  -h, --help                    Show this help
EOF
}

# --- Defaults ---
CAMPAIGN_TARGETS=""
GRAPH_TRACK="neo4j"
FAULT_MODE="terminal"
REPEATS=3
PROFILE="perf-box-amd64"
OUTPUT_DIR=""
CONTRACT_ID="exeris_community_h1_v2"
_CONTRACT_ID_EXPLICIT="false"
JFR_MAX_SIZE_MB=256
BENCH_DB_POOL_MAX="${BENCH_DB_POOL_MAX:-32}"
BENCH_SERVER_CPU_AFFINITY="${BENCH_SERVER_CPU_AFFINITY:-}"
BENCH_CGROUP_MEMORY_LIMIT_MB="${BENCH_CGROUP_MEMORY_LIMIT_MB:-}"
BENCH_CGROUP_CPU_QUOTA_PCT="${BENCH_CGROUP_CPU_QUOTA_PCT:-}"
SKIP_SEED_VERIFY="false"

# --- Argparse ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)
      CAMPAIGN_TARGETS="$2"
      shift 2
      ;;
    --graph-track)
      GRAPH_TRACK="$2"
      shift 2
      ;;
    --fault-mode)
      FAULT_MODE="$2"
      shift 2
      ;;
    --repeats)
      REPEATS="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --contract-id)
      CONTRACT_ID="$2"
      _CONTRACT_ID_EXPLICIT="true"
      shift 2
      ;;
    --jfr-max-size-mb)
      JFR_MAX_SIZE_MB="$2"
      shift 2
      ;;
    --db-pool-max)
      BENCH_DB_POOL_MAX="$2"
      shift 2
      ;;
    --skip-seed-verify)
      SKIP_SEED_VERIFY="true"
      shift
      ;;
    --cgroup-memory-limit-mb)   BENCH_CGROUP_MEMORY_LIMIT_MB="$2";           shift 2 ;;
    --cgroup-cpu-quota-pct)     BENCH_CGROUP_CPU_QUOTA_PCT="$2";             shift 2 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# --- Validation ---
if [[ -z "$CAMPAIGN_TARGETS" ]]; then
  echo "ERROR: --targets is required" >&2
  usage >&2
  exit 1
fi

if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || [[ "$REPEATS" -le 0 ]]; then
  echo "ERROR: --repeats must be a positive integer (got: $REPEATS)" >&2
  exit 1
fi

case "$FAULT_MODE" in
  terminal|transient) ;;
  *)
    echo "ERROR: --fault-mode must be 'terminal' or 'transient' (got: $FAULT_MODE)" >&2
    exit 1
    ;;
esac

CAMPAIGN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$REPO_ROOT/results/raw/e2e-shop-order-saga/${CAMPAIGN_TS}-campaign"
fi

mkdir -p "$OUTPUT_DIR"
STATUS_CSV="$OUTPUT_DIR/status.csv"
CAMPAIGN_MANIFEST_JSON="$OUTPUT_DIR/campaign-manifest.json"

apply_resource_profile() {
  local profile_path="$OUTPUT_DIR/resource-profile.json"
  local generated_at_utc
  generated_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  export EXERIS_DB_POOL_MAX_SIZE="$BENCH_DB_POOL_MAX"
  # CONTRACT-v2 §4 parking workload. Exported here so EVERY rep of EVERY arm runs the
  # same shape: the baseline fails closed (exit 74) if the running gateway's delay or
  # fault mode disagrees with what the run declares, so a campaign that forgot to pass
  # these would stop rather than quietly measure shape A0 again.
  # CPU pinning, disjoint by construction on this 8-physical-core box (CPU n and n+8 are
  # SMT siblings of core n, so each set is whole physical cores):
  #   target   cores 0-3  -> 0-3,8-11
  #   loadgen  cores 4-5  -> 4,5,12,13
  #   backends cores 6-7  -> 6,7,14,15
  # Overridable, but never silently absent: the baseline fails closed if taskset is
  # missing or a container cannot be pinned.
  export BENCH_TARGET_CPUS="${BENCH_TARGET_CPUS:-0-3,8-11}"
  export BENCH_LOADGEN_CPUS="${BENCH_LOADGEN_CPUS:-4,5,12,13}"
  export BENCH_BACKEND_CPUS="${BENCH_BACKEND_CPUS:-6,7,14,15}"
  export BENCH_PAYMENT_PARKING="${BENCH_PAYMENT_PARKING:-1}"
  # 100 ms, matching the compose default and the "100 ms for perf runs" convention in the
  # compose file. It was 1 ms, which is a declaration the running gateway never matched -
  # the baseline's fail-closed check refused every arm before k6 started. A 1 ms callback
  # would also collapse the parked population the shape exists to create: parked concurrency
  # is arrival rate x delay, so 1 ms means ~0.05 parked sagas at 50/s instead of ~5.
  export PAYMENT_STUB_DELAY_MS="${PAYMENT_STUB_DELAY_MS:-100}"
  export BENCH_SERVER_CPU_AFFINITY
  export BENCH_CGROUP_MEMORY_LIMIT_MB
  export BENCH_CGROUP_CPU_QUOTA_PCT

  local _cg_mem_json="${BENCH_CGROUP_MEMORY_LIMIT_MB:-null}"
  local _cg_cpu_json="${BENCH_CGROUP_CPU_QUOTA_PCT:-null}"

  cat > "$profile_path" <<EOF
{
  "db_pool_max":             ${BENCH_DB_POOL_MAX},
  "server_cpu_affinity":     "${BENCH_SERVER_CPU_AFFINITY:-}",
  "cgroup_memory_limit_mb":  ${_cg_mem_json},
  "cgroup_cpu_quota_pct":    ${_cg_cpu_json},
  "jfr_max_size_mb":         ${JFR_MAX_SIZE_MB},
  "generated_at_utc":        "${generated_at_utc}"
}
EOF
  echo "Resource profile written to ${profile_path}"
}

# Derive the fixed-contract id for a target, or FAIL CLOSED.
#
# The campaign always passes --contract-id down to the baseline, which makes the
# baseline treat the id as operator-supplied (_CONTRACT_ID_EXPLICIT=true) and
# skip its own "no contract id given" abort. A fallback here would therefore
# launder a guessed id past that check and stamp it onto every artifact of the
# run (contract_id + protocol axis). A target label with no matching
# fixed_contracts row for this graph track is an operator error, not a default:
# abort before any target is started.
_derive_contract_id() {
  local target_app="$1"
  if [[ "${_CONTRACT_ID_EXPLICIT}" == "true" ]]; then
    echo "$CONTRACT_ID"
    return 0
  fi
  local contract_id
  contract_id="$(jq -r \
    --arg gt "$GRAPH_TRACK" \
    --arg ta "$target_app" \
    '((.graph_tracks[$gt].required_contracts // []) as $cids |
      $cids[] as $cid |
      if .fixed_contracts[$cid].target_app == $ta then $cid else empty end),
     (.locality_research.contracts // {} | to_entries[] |
      select(.value.target_app == $ta) | .key)' \
    "$SCENARIO_JSON" 2>/dev/null | head -1)"
  if [[ -z "$contract_id" ]]; then
    # Second chance: the baseline-only namespace. These contracts are runnable
    # but deliberately kept out of fixed_contracts / graph_tracks so no
    # comparative tooling can pick them up (restate today). Driving one is
    # allowed; it is recorded as baseline_only so nothing downstream mistakes
    # the run for a comparison-eligible arm.
    contract_id="$(jq -r --arg ta "$target_app" \
      '(.baseline_only_contracts // {}) | to_entries[]
       | select(.value | type == "object")
       | select(.value.target_app == $ta) | .key' \
      "$SCENARIO_JSON" 2>/dev/null | head -1)"
    if [[ -n "$contract_id" ]]; then
      BASELINE_ONLY_TARGET["$target_app"]="true"
      echo "$contract_id"
      return 0
    fi
  fi
  if [[ -z "$contract_id" ]]; then
    {
      echo "ERROR: no fixed contract for target_app='${target_app}' on graph_track='${GRAPH_TRACK}' in ${SCENARIO_JSON#$REPO_ROOT/}."
      echo "ERROR: refusing to fall back to '${CONTRACT_ID}' — the campaign passes --contract-id explicitly, so a guessed id"
      echo "ERROR: bypasses the baseline's own fail-closed check and mislabels the run's contract_id and protocol axis."
      echo "ERROR: known target_app values for graph_track='${GRAPH_TRACK}':"
      jq -r --arg gt "$GRAPH_TRACK" \
        '(.graph_tracks[$gt].required_contracts // [])[] as $cid
         | "ERROR:   \(.fixed_contracts[$cid].target_app // "?")  ->  \($cid)"' \
        "$SCENARIO_JSON" 2>/dev/null || true
      echo "ERROR: baseline-only target_app values:"
      jq -r '(.baseline_only_contracts // {}) | to_entries[]
             | select(.value | type == "object")
             | "ERROR:   \(.value.target_app // "?")  ->  \(.key)  (baseline_only)"' \
        "$SCENARIO_JSON" 2>/dev/null || true
      echo "ERROR: for anything else, pass --contract-id explicitly."
    } >&2
    return 1
  fi
  echo "$contract_id"
}

# Resolve every contract id up front so an unknown target aborts the campaign
# before any target process, database seed, or measurement window is spent.
declare -A RESOLVED_CONTRACT_ID=()
declare -A BASELINE_ONLY_TARGET=()
resolve_all_contract_ids() {
  local target_app cid
  for target_app in "$@"; do
    # _derive_contract_id runs in a subshell for its stdout, so the
    # BASELINE_ONLY_TARGET write inside it does not propagate; re-derive the
    # flag here from the resolved id.
    if ! cid="$(_derive_contract_id "$target_app")"; then
      echo "ERROR: campaign aborted during contract-id preflight (target_app='${target_app}')." >&2
      exit 1
    fi
    RESOLVED_CONTRACT_ID["$target_app"]="$cid"
    if jq -e --arg cid "$cid" '(.baseline_only_contracts // {}) | has($cid)' \
         "$SCENARIO_JSON" >/dev/null 2>&1; then
      BASELINE_ONLY_TARGET["$target_app"]="true"
      echo "  contract-id preflight: ${target_app} -> ${cid}  [BASELINE-ONLY: descriptive single-stack run; NOT comparison-eligible]"
    else
      BASELINE_ONLY_TARGET["$target_app"]="false"
      echo "  contract-id preflight: ${target_app} -> ${cid}"
    fi
  done
}

run_target_rep() {
  local target_app="$1"
  local rep="$2"
  local run_dir="$3"
  mkdir -p "$run_dir"

  local -a args=(
    --target-app          "$target_app"
    --contract-id         "${RESOLVED_CONTRACT_ID[$target_app]}"
    --graph-track         "$GRAPH_TRACK"
    --fault-mode          "$FAULT_MODE"
    --profile             "$PROFILE"
    --output-dir          "$run_dir"
    --force-restart-target
    --jfr-max-size-mb     "$JFR_MAX_SIZE_MB"
  )

  if [[ "$SKIP_SEED_VERIFY" == "true" ]]; then
    args+=(--skip-seed-verify)
  fi

  [[ -n "${BENCH_CGROUP_MEMORY_LIMIT_MB:-}" ]] && args+=(--cgroup-memory-limit-mb "$BENCH_CGROUP_MEMORY_LIMIT_MB")
  [[ -n "${BENCH_CGROUP_CPU_QUOTA_PCT:-}"    ]] && args+=(--cgroup-cpu-quota-pct   "$BENCH_CGROUP_CPU_QUOTA_PCT")

  local rc=0
  "$SCRIPT_DIR/run-e2e-shop-order-saga-baseline.sh" "${args[@]}" || rc=$?
  return "$rc"
}

write_campaign_manifest() {
  local generated_at_utc
  generated_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit_sha
  commit_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"

  local _cg_mem_json="${BENCH_CGROUP_MEMORY_LIMIT_MB:-null}"
  local _cg_cpu_json="${BENCH_CGROUP_CPU_QUOTA_PCT:-null}"
  local _seed_verify_skipped_json="false"
  if [[ "$SKIP_SEED_VERIFY" == "true" ]]; then
    _seed_verify_skipped_json="true"
  fi
  local _contract_id_mode
  [[ "${_CONTRACT_ID_EXPLICIT}" == "true" ]] \
    && _contract_id_mode="cli-override" \
    || _contract_id_mode="auto-derived-per-target"

  cat > "$CAMPAIGN_MANIFEST_JSON" <<EOF
{
  "schema_version":         "1",
  "scenario_id":            "e2e-shop-order-saga",
  "campaign_ts":            "${CAMPAIGN_TS}",
  "generated_at_utc":       "${generated_at_utc}",
  "commit_sha":             "${commit_sha}",
  "targets":                "${CAMPAIGN_TARGETS}",
  "graph_track":            "${GRAPH_TRACK}",
  "fault_mode":             "${FAULT_MODE}",
  "repeats":                ${REPEATS},
  "hardware_profile":       "${PROFILE}",
  "contract_id_mode":       "${_contract_id_mode}",
  "contract_id_fallback":   "${CONTRACT_ID}",
  "jfr_max_size_mb":        ${JFR_MAX_SIZE_MB},
  "db_pool_max":            ${BENCH_DB_POOL_MAX},
  "seed_verification_skipped": ${_seed_verify_skipped_json},
  "server_cpu_affinity":    "${BENCH_SERVER_CPU_AFFINITY:-}",
  "cgroup_memory_limit_mb": ${_cg_mem_json},
  "cgroup_cpu_quota_pct":   ${_cg_cpu_json},
  "output_dir":             "${OUTPUT_DIR}",
  "status_csv":             "${STATUS_CSV}"
}
EOF
  echo "Campaign manifest: ${CAMPAIGN_MANIFEST_JSON}"
}

# Campaign-level rollup of the per-rep CONTRACT-v2 s4.1 correctness gate.
#
# This is NOT the comparative strict gate (stage7-gate-report.csv /
# claim-status.json / rejection-codes.json): it says only that every rep's
# compensation COUNT matched the exact expected integer. It is O2-at-count-
# granularity, per CONTRACT-v2-IMPLEMENTATION.md s7 — no LIFO order, no O1
# duplicate-execution, no O3 orphaned-effect evidence. Comparative eligibility
# is decided by a separate promotion step, not here.
write_campaign_gate_summary() {
  local summary_json="$OUTPUT_DIR/campaign-gate-summary.json"
  local generated_at_utc
  generated_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -n \
    --argjson reps "[${gate_rows}]" \
    --arg scenario_id  "e2e-shop-order-saga" \
    --arg campaign_ts  "$CAMPAIGN_TS" \
    --arg fault_mode   "$FAULT_MODE" \
    --arg graph_track  "$GRAPH_TRACK" \
    --arg generated_at_utc "$generated_at_utc" \
    '($reps | map(.correctness_gate)) as $verdicts
     | {
         schema_version: "1",
         gate_id:   "contract_v2_s4_1_exact_compensation_campaign_rollup",
         gate_name: "every rep: observed_compensations == expected_declines",
         contract_ref: "scenarios/e2e-shop-order-saga/CONTRACT-v2.md#4.1",
         scope_note: "Count-granularity O2 rollup only. NOT a comparative strict-gate verdict and NOT evidence of O1/O3 or LIFO ordering; see CONTRACT-v2-IMPLEMENTATION.md s7.",
         scenario_id: $scenario_id,
         campaign_ts: $campaign_ts,
         fault_mode:  $fault_mode,
         graph_track: $graph_track,
         reps_total:  ($reps | length),
         baseline_only_targets: ($reps | map(select(.baseline_only)) | map(.target_app) | unique),
         comparison_eligible_targets_note: "Presence here means only that a target has a fixed_contracts row for this graph track. Comparative eligibility additionally requires the strict-gate artifacts, which this campaign does NOT emit.",
         verdict_counts: ($verdicts | group_by(.) | map({key: .[0], value: length}) | from_entries),
         durability_tiers: ($reps | map(.durability_tier) | unique),
         # CONTRACT-v2 s8 forbids cross-TIER comparison, so uniformity is judged
         # on the tier class (the leading T<n> token), not on the full label.
         # The stacks legitimately carry different suffixes for the same tier
         # ("T2-fsync-node-durable" for restate-server vs
         # "T2-fsync-node-durable-postgres" for the Postgres-backed stacks);
         # comparing raw strings would raise a s8 alarm on every mixed campaign
         # and train readers to ignore it. Full labels stay above.
         durability_tier_classes: ($reps | map(.durability_tier | capture("^(?<t>T[0-9]+)").t? // .) | unique),
         durability_tier_uniform:
           (($reps | map(.durability_tier | capture("^(?<t>T[0-9]+)").t? // .) | unique | length) <= 1),
         durability_labels_uniform: (($reps | map(.durability_tier) | unique | length) <= 1),
         campaign_gate_status:
           (if ($reps | length) == 0 then "error"
            elif ($verdicts | all(. == "pass")) then "pass"
            elif ($verdicts | any(. == "fail")) then "fail"
            else "not_evaluated" end),
         reps: $reps,
         generated_at_utc: $generated_at_utc
       }' > "$summary_json"

  local _campaign_gate
  _campaign_gate="$(jq -r '.campaign_gate_status' "$summary_json")"
  echo "Campaign correctness-gate rollup: ${_campaign_gate} (${summary_json})"
  if [[ "$_campaign_gate" != "pass" ]]; then
    echo "WARN: not every rep passed the CONTRACT-v2 s4.1 gate; no s4.1 correctness claim may cite this campaign." >&2
  fi
  if [[ "$(jq -r '.durability_tier_uniform' "$summary_json")" != "true" ]]; then
    echo "WARN: durability TIERS differ across reps ($(jq -rc '.durability_tier_classes' "$summary_json")); CONTRACT-v2 s8 forbids cross-tier comparison." >&2
  elif [[ "$(jq -r '.durability_labels_uniform' "$summary_json")" != "true" ]]; then
    echo "Note: same durability tier, differing labels across reps ($(jq -rc '.durability_tiers' "$summary_json")) — no s8 violation; declare the per-stack label in reports."
  fi
}

# --- Main ---
echo "Campaign config: targets=${CAMPAIGN_TARGETS} repeats=${REPEATS} graph_track=${GRAPH_TRACK} fault_mode=${FAULT_MODE} profile=${PROFILE}"
[[ -n "${BENCH_CGROUP_MEMORY_LIMIT_MB:-}" ]] && echo "  cgroup_memory_limit_mb=${BENCH_CGROUP_MEMORY_LIMIT_MB}"
[[ -n "${BENCH_CGROUP_CPU_QUOTA_PCT:-}"    ]] && echo "  cgroup_cpu_quota_pct=${BENCH_CGROUP_CPU_QUOTA_PCT}"

IFS=',' read -ra TARGET_LIST <<< "$CAMPAIGN_TARGETS"
resolve_all_contract_ids "${TARGET_LIST[@]}"

apply_resource_profile

echo "rep,target_app,contract_id,baseline_only,graph_track,run_dir,runner_status,k6_exit_code,baseline_exit_code,result_json_present,fault_mode,durability_tier,correctness_gate" > "$STATUS_CSV"

any_fail=0
gate_rows=""

for target_app in "${TARGET_LIST[@]}"; do
  for rep in $(seq 1 "$REPEATS"); do
    run_label="${target_app}-rep-${rep}"
    run_dir="$OUTPUT_DIR/$run_label"
    echo "--- Campaign rep ${rep}/${REPEATS}: target=${target_app} ---"

    rc=0
    run_target_rep "$target_app" "$rep" "$run_dir" || rc=$?

    result_json_present="false"
    runner_status="failed"
    k6_exit_code="$rc"

    if [[ -f "$run_dir/result.json" ]] && jq -e . "$run_dir/result.json" >/dev/null 2>&1; then
      result_json_present="true"
      runner_status="$(jq -r '.runner_status // "unknown"' "$run_dir/result.json")"
      k6_exit_code="$(jq -r '.k6_exit_code // '"$rc" "$run_dir/result.json")"
    fi

    # CONTRACT-v2 s4.1 correctness-gate verdict per rep (pass|fail|skipped|error|absent)
    # and the s8 durability-tier label the baseline stamped for this run.
    correctness_gate="absent"
    durability_tier="unknown"
    if [[ -f "$run_dir/correctness-gate.json" ]]; then
      correctness_gate="$(jq -r '.status // "unknown"' "$run_dir/correctness-gate.json" 2>/dev/null || echo "unknown")"
      durability_tier="$(jq -r '.durability_tier // "unknown"' "$run_dir/correctness-gate.json" 2>/dev/null || echo "unknown")"
    fi

    if [[ "$rc" -ne 0 ]]; then
      any_fail=1
    fi

    echo "${rep},${target_app},${RESOLVED_CONTRACT_ID[$target_app]},${BASELINE_ONLY_TARGET[$target_app]},${GRAPH_TRACK},${run_dir},${runner_status},${k6_exit_code},${rc},${result_json_present},${FAULT_MODE},${durability_tier},${correctness_gate}" >> "$STATUS_CSV"
    gate_rows+="${gate_rows:+,}$(jq -nc \
      --arg t "$target_app" --arg c "${RESOLVED_CONTRACT_ID[$target_app]}" \
      --arg g "$correctness_gate" --arg d "$durability_tier" \
      --arg s "$runner_status" --argjson r "$rep" --argjson x "$rc" \
      --argjson b "${BASELINE_ONLY_TARGET[$target_app]}" \
      '{rep:$r, target_app:$t, contract_id:$c, baseline_only:$b, runner_status:$s,
        baseline_exit_code:$x, durability_tier:$d, correctness_gate:$g}')"
  done
done

write_campaign_manifest
write_campaign_gate_summary

overall_status="pass"
if [[ "$any_fail" -ne 0 ]]; then
  overall_status="fail"
fi

echo "Campaign complete. Status: ${overall_status}"
echo "Manifest: ${CAMPAIGN_MANIFEST_JSON}"
echo "Status CSV: ${STATUS_CSV}"
echo "Gate rollup: ${OUTPUT_DIR}/campaign-gate-summary.json"

if [[ "$any_fail" -ne 0 ]]; then
  exit 1
fi
