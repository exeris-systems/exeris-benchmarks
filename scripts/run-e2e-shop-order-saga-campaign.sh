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
CONTRACT_ID="exeris_community_h2c_v1"
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
    echo "[WARN] _derive_contract_id: no contract for target_app='$target_app' graph_track='$GRAPH_TRACK'; using fallback '$CONTRACT_ID'" >&2
    echo "$CONTRACT_ID"
  else
    echo "$contract_id"
  fi
}

run_target_rep() {
  local target_app="$1"
  local rep="$2"
  local run_dir="$3"
  mkdir -p "$run_dir"

  local -a args=(
    --target-app          "$target_app"
    --contract-id         "$(_derive_contract_id "$target_app")"
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

# --- Main ---
apply_resource_profile

echo "rep,target_app,run_dir,runner_status,k6_exit_code,result_json_present,fault_mode,correctness_gate" > "$STATUS_CSV"

any_fail=0

echo "Campaign config: targets=${CAMPAIGN_TARGETS} repeats=${REPEATS} graph_track=${GRAPH_TRACK} fault_mode=${FAULT_MODE} profile=${PROFILE}"
[[ -n "${BENCH_CGROUP_MEMORY_LIMIT_MB:-}" ]] && echo "  cgroup_memory_limit_mb=${BENCH_CGROUP_MEMORY_LIMIT_MB}"
[[ -n "${BENCH_CGROUP_CPU_QUOTA_PCT:-}"    ]] && echo "  cgroup_cpu_quota_pct=${BENCH_CGROUP_CPU_QUOTA_PCT}"

IFS=',' read -ra TARGET_LIST <<< "$CAMPAIGN_TARGETS"
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

    # CONTRACT-v2 s4.1 correctness-gate verdict per rep (pass|fail|skipped|error|absent).
    correctness_gate="absent"
    if [[ -f "$run_dir/correctness-gate.json" ]]; then
      correctness_gate="$(jq -r '.status // "unknown"' "$run_dir/correctness-gate.json" 2>/dev/null || echo "unknown")"
    fi

    if [[ "$rc" -ne 0 ]]; then
      any_fail=1
    fi

    echo "${rep},${target_app},${run_dir},${runner_status},${k6_exit_code},${result_json_present},${FAULT_MODE},${correctness_gate}" >> "$STATUS_CSV"
  done
done

write_campaign_manifest

overall_status="pass"
if [[ "$any_fail" -ne 0 ]]; then
  overall_status="fail"
fi

echo "Campaign complete. Status: ${overall_status}"
echo "Manifest: ${CAMPAIGN_MANIFEST_JSON}"
echo "Status CSV: ${STATUS_CSV}"

if [[ "$any_fail" -ne 0 ]]; then
  exit 1
fi
