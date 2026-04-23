#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-guided.sh [--profile-out <path>] [--execute] [--no-execute]

Interactive guided launcher:
  - captures benchmark metadata and run intent
  - writes guided-run-profile.json
  - validates profile via runtime/drivers/validate-guided-profile.sh
  - optionally dispatches supported run scripts
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "[guided] $*"
}

warn() {
  echo "WARN: $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR_SCRIPT="${REPO_ROOT}/runtime/drivers/validate-guided-profile.sh"

PROFILE_OUT=""
EXECUTE_MODE="ask"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-out)
      PROFILE_OUT="$2"
      shift 2
      ;;
    --execute)
      EXECUTE_MODE="yes"
      shift
      ;;
    --no-execute)
      EXECUTE_MODE="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ ! -x "$VALIDATOR_SCRIPT" ]]; then
  fail "Validator script not executable: $VALIDATOR_SCRIPT"
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required by run-guided.sh"
fi

choose_option() {
  local prompt="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local value=""

  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    for opt in "${options[@]}"; do
      if [[ "$value" == "$opt" ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    done
    echo "Invalid value '$value'. Allowed: ${options[*]}" >&2
  done
}

prompt_text() {
  local prompt="$1"
  local default="$2"
  local value=""
  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  printf '%s\n' "$value"
}

prompt_positive_int() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 1 ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "Invalid value '$value'. Enter an integer >= 1." >&2
  done
}

tool_version_or_unknown() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%s\n' "unknown"
    return 0
  fi

  local line="unknown"
  case "$tool" in
    jq)
      line="$(jq --version 2>/dev/null | head -n1 || true)"
      ;;
    k6)
      line="$(k6 version 2>/dev/null | head -n1 || true)"
      ;;
    wrk)
      line="$(wrk --version 2>/dev/null | head -n1 || true)"
      ;;
    h2load)
      line="$(h2load --version 2>/dev/null | head -n1 || true)"
      ;;
    docker)
      line="$(docker --version 2>/dev/null | head -n1 || true)"
      ;;
    *)
      line="unknown"
      ;;
  esac

  line="${line//$'\r'/}"
  if [[ -z "$line" ]]; then
    line="unknown"
  fi
  printf '%s\n' "$line"
}

map_entity_runtime() {
  local target="$1"
  case "$target" in
    *spring*) printf '%s\n' "spring" ;;
    *quarkus*) printf '%s\n' "quarkus" ;;
    *locality*) printf '%s\n' "locality" ;;
    *community*|*enterprise*|*exeris*) printf '%s\n' "community" ;;
    *) printf '%s\n' "auto" ;;
  esac
}

map_entity_build() {
  local target="$1"
  case "$target" in
    *native*) printf '%s\n' "native" ;;
    *) printf '%s\n' "jvm" ;;
  esac
}

map_entity_backend_mode() {
  local target="$1"
  case "$target" in
    *locality*) printf '%s\n' "locality-aware" ;;
    *) printf '%s\n' "default-vt" ;;
  esac
}

readarray -t SCENARIO_IDS < <(find "$REPO_ROOT/scenarios" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ "${#SCENARIO_IDS[@]}" -gt 0 ]] || fail "No scenarios found under $REPO_ROOT/scenarios"

echo "Available scenarios:"
printf '  - %s\n' "${SCENARIO_IDS[@]}"

run_type="$(choose_option "run_type" "guard" guard regression exploratory)"
topology_mode="$(choose_option "topology_mode" "localhost" localhost network)"
target_mode="$(choose_option "target_mode" "single" single multi)"

app_endpoint=""
db_endpoint=""
launch_mode=""
runtime_mode=""

if [[ "$topology_mode" == "network" ]]; then
  app_endpoint="$(prompt_text "app_endpoint" "http://127.0.0.1:8080")"
  db_endpoint="$(prompt_text "db_endpoint" "postgresql://benchmark:benchmark@127.0.0.1:5432/benchmark")"
  warn "Network mode selected: ensure targets are launched with scenario-compatible configuration before execution."
else
  launch_mode="$(choose_option "launch_mode" "prebuild" prebuild build docker)"
  runtime_mode="$(choose_option "runtime_mode" "jvm" native jvm)"
fi

scenario_id=""
while true; do
  read -r -p "scenario_id [entity-read-by-id]: " scenario_id
  scenario_id="${scenario_id:-entity-read-by-id}"
  for s in "${SCENARIO_IDS[@]}"; do
    if [[ "$scenario_id" == "$s" ]]; then
      break 2
    fi
  done
  echo "Invalid scenario_id '$scenario_id'. Choose one of listed scenarios." >&2
done

protocol_mode="$(choose_option "protocol_mode" "h1" h1 h2 h3)"
tier="$(choose_option "tier" "community" community enterprise)"
target_classification="$(choose_option "target_classification" "pure" pure compat)"

targets=()
if [[ "$target_mode" == "single" ]]; then
  target_single="$(prompt_text "target_id" "exeris-community-app")"
  [[ -n "$target_single" ]] || fail "target_id cannot be empty"
  targets+=("$target_single")
else
  target_a="$(prompt_text "target_a" "exeris-benchmark-app-community-h1")"
  target_b="$(prompt_text "target_b" "spring-jvm-vt-tuned")"
  [[ -n "$target_a" && -n "$target_b" ]] || fail "target ids cannot be empty"
  targets+=("$target_a" "$target_b")
fi

contract_id="$(prompt_text "contract_id" "fixed_contract_v1")"
warmup_seconds="$(prompt_positive_int "workload.warmup_seconds" "60")"
measurement_seconds="$(prompt_positive_int "workload.measurement_seconds" "120")"
threads="$(prompt_positive_int "workload.threads" "4")"
connections="$(prompt_positive_int "workload.connections" "128")"
hardware_profile="$(prompt_text "hardware_profile" "dev-laptop")"

if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  benchmark_commit_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
else
  benchmark_commit_sha="unknown"
fi

if command -v java >/dev/null 2>&1; then
  jdk_version="$(java -version 2>&1 | head -n1 | sed 's/"//g')"
  [[ -n "$jdk_version" ]] || jdk_version="unknown"
else
  jdk_version="unknown"
fi

jq_version="$(tool_version_or_unknown jq)"
k6_version="$(tool_version_or_unknown k6)"
wrk_version="$(tool_version_or_unknown wrk)"
h2load_version="$(tool_version_or_unknown h2load)"
docker_version="$(tool_version_or_unknown docker)"

read -r -p "jvm_flags (comma-separated, empty for none) []: " jvm_flags_raw
jvm_flags=()
if [[ -n "${jvm_flags_raw//[[:space:]]/}" ]]; then
  IFS=',' read -r -a raw_flags <<< "$jvm_flags_raw"
  for f in "${raw_flags[@]}"; do
    trimmed="$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$trimmed" ]] && jvm_flags+=("$trimmed")
  done
fi

claim_scope="descriptive_only"
if [[ "$run_type" != "exploratory" ]]; then
  claim_scope="$(choose_option "claim_scope" "descriptive_only" descriptive_only comparison_eligible)"
fi

fairness_payload_equivalent="false"
fairness_concurrency_equivalent="false"
fairness_protocol_mode_equivalent="false"
fairness_target_scope_equivalent="false"

if [[ "$claim_scope" == "comparison_eligible" ]]; then
  fairness_attest_payload="$(choose_option "fairness_attest_payload" "yes" yes no)"
  fairness_attest_concurrency="$(choose_option "fairness_attest_concurrency" "yes" yes no)"
  fairness_attest_protocol_mode="$(choose_option "fairness_attest_protocol_mode" "yes" yes no)"
  fairness_attest_target_scope="$(choose_option "fairness_attest_target_scope" "yes" yes no)"

  if [[ "$fairness_attest_payload" == "yes" ]]; then
    fairness_payload_equivalent="true"
  fi
  if [[ "$fairness_attest_concurrency" == "yes" ]]; then
    fairness_concurrency_equivalent="true"
  fi
  if [[ "$fairness_attest_protocol_mode" == "yes" ]]; then
    fairness_protocol_mode_equivalent="true"
  fi
  if [[ "$fairness_attest_target_scope" == "yes" ]]; then
    fairness_target_scope_equivalent="true"
  fi
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$PROFILE_OUT" ]]; then
  PROFILE_OUT="$REPO_ROOT/results/raw/guided/${timestamp}/guided-run-profile.json"
fi
mkdir -p "$(dirname "$PROFILE_OUT")"
profile_dir="$(cd "$(dirname "$PROFILE_OUT")" && pwd)"
output_dir="$profile_dir"

mkdir -p "$output_dir"

targets_json="$(jq -n "\$ARGS.positional" --args "${targets[@]}")"
jvm_flags_json="$(jq -n "\$ARGS.positional" --args "${jvm_flags[@]}")"

jq -n \
  --arg schema_version "1" \
  --arg benchmark_family "runtime" \
  --arg benchmark_commit_sha "$benchmark_commit_sha" \
  --arg jdk_version "$jdk_version" \
  --arg hardware_profile "$hardware_profile" \
  --arg scenario_id "$scenario_id" \
  --arg target_classification "$target_classification" \
  --arg protocol_mode "$protocol_mode" \
  --arg tier "$tier" \
  --arg topology_mode "$topology_mode" \
  --arg run_type "$run_type" \
  --arg target_mode "$target_mode" \
  --arg claim_scope "$claim_scope" \
  --arg app_endpoint "$app_endpoint" \
  --arg db_endpoint "$db_endpoint" \
  --arg launch_mode "$launch_mode" \
  --arg runtime_mode "$runtime_mode" \
  --arg contract_id "$contract_id" \
  --arg output_dir "$output_dir" \
  --arg jq_version "$jq_version" \
  --arg k6_version "$k6_version" \
  --arg wrk_version "$wrk_version" \
  --arg h2load_version "$h2load_version" \
  --arg docker_version "$docker_version" \
  --arg fairness_payload_equivalent "$fairness_payload_equivalent" \
  --arg fairness_concurrency_equivalent "$fairness_concurrency_equivalent" \
  --arg fairness_protocol_mode_equivalent "$fairness_protocol_mode_equivalent" \
  --arg fairness_target_scope_equivalent "$fairness_target_scope_equivalent" \
  --argjson targets "$targets_json" \
  --argjson jvm_flags "$jvm_flags_json" \
  --argjson warmup_seconds "$warmup_seconds" \
  --argjson measurement_seconds "$measurement_seconds" \
  --argjson threads "$threads" \
  --argjson connections "$connections" \
  '
  {
    schema_version: $schema_version,
    benchmark_family: $benchmark_family,
    benchmark_commit_sha: $benchmark_commit_sha,
    jdk_version: $jdk_version,
    tool_versions: {
      jq: $jq_version,
      k6: $k6_version,
      wrk: $wrk_version,
      h2load: $h2load_version,
      docker: $docker_version
    },
    jvm_flags: $jvm_flags,
    hardware_profile: $hardware_profile,
    scenario_id: $scenario_id,
    target_classification: $target_classification,
    protocol_mode: $protocol_mode,
    tier: $tier,
    topology_mode: $topology_mode,
    run_type: $run_type,
    target_mode: $target_mode,
    claim_scope: $claim_scope,
    targets: $targets,
    contract_id: $contract_id,
    output_dir: $output_dir,
    fairness_attestations: {
      payload_equivalent: ($fairness_payload_equivalent == "true"),
      concurrency_equivalent: ($fairness_concurrency_equivalent == "true"),
      protocol_mode_equivalent: ($fairness_protocol_mode_equivalent == "true"),
      target_scope_equivalent: ($fairness_target_scope_equivalent == "true")
    },
    workload: {
      warmup_seconds: $warmup_seconds,
      measurement_seconds: $measurement_seconds,
      threads: $threads,
      connections: $connections
    }
  }
  | if $topology_mode == "network" then . + {app_endpoint: $app_endpoint, db_endpoint: $db_endpoint} else . + {launch_mode: $launch_mode, runtime_mode: $runtime_mode} end
  ' > "$PROFILE_OUT"

info "Profile written: $PROFILE_OUT"
validate_args=(--profile "$PROFILE_OUT" --dispatch-compatible)
if [[ "$claim_scope" == "comparison_eligible" ]]; then
  validate_args+=(--confirm-comparison-eligibility)
fi
"$VALIDATOR_SCRIPT" "${validate_args[@]}"

echo
echo "Guided profile summary:"
echo "  run_type: $run_type"
echo "  topology_mode: $topology_mode"
echo "  target_mode: $target_mode"
echo "  scenario_id: $scenario_id"
echo "  protocol_mode: $protocol_mode"
echo "  tier: $tier"
echo "  target_classification: $target_classification"
echo "  claim_scope: $claim_scope"
echo "  contract_id: $contract_id"
echo "  output_dir: $output_dir"
echo "  targets: ${targets[*]}"
echo "  workload: warmup=$warmup_seconds measurement=$measurement_seconds threads=$threads connections=$connections"

should_execute="no"
if [[ "$EXECUTE_MODE" == "yes" ]]; then
  should_execute="yes"
elif [[ "$EXECUTE_MODE" == "no" ]]; then
  should_execute="no"
else
  read -r -p "Execute now? [y/N]: " run_now
  if [[ "$run_now" == "y" || "$run_now" == "Y" ]]; then
    should_execute="yes"
  fi
fi

if [[ "$should_execute" != "yes" ]]; then
  info "Generate+validate complete (execution skipped)."
  exit 0
fi

if [[ "$target_mode" == "multi" ]]; then
  info "Dispatch: run-comparative.sh"
  "$REPO_ROOT/scripts/run-comparative.sh" \
    --target-a "${targets[0]}" \
    --target-b "${targets[1]}" \
    --scenario-id "$scenario_id" \
    --contract-id "$contract_id" \
    --output-dir "$output_dir" \
    --measurement-seconds "$measurement_seconds" \
    --warmup-seconds "$warmup_seconds" \
    --threads "$threads" \
    --connections "$connections"
  exit $?
fi

if [[ "$scenario_id" == "entity-read-by-id" ]]; then
  mapped_runtime="$(map_entity_runtime "${targets[0]}")"
  mapped_build="$(map_entity_build "${targets[0]}")"
  mapped_backend_mode="$(map_entity_backend_mode "${targets[0]}")"

  if [[ "$claim_scope" == "comparison_eligible" ]]; then
    mapped_claim_scope="comparison-eligible"
  else
    mapped_claim_scope="exploratory"
  fi

  info "Dispatch: run-entity-read-by-id.sh"
  "$REPO_ROOT/scripts/run-entity-read-by-id.sh" \
    --contract "$contract_id" \
    --claim-scope "$mapped_claim_scope" \
    --profile "$hardware_profile" \
    --output-dir "$output_dir" \
    --threads "$threads" \
    --connections "$connections" \
    --warmup "${warmup_seconds}s" \
    --duration "${measurement_seconds}s" \
    --target-runtime "$mapped_runtime" \
    --target-build "$mapped_build" \
    --backend-mode "$mapped_backend_mode"
  exit $?
fi

if [[ "$scenario_id" == "e2e-shop-order-saga" ]]; then
  info "Dispatch: run-e2e-shop-order-saga-baseline.sh"
  cmd=(
    "$REPO_ROOT/scripts/run-e2e-shop-order-saga-baseline.sh"
    --contract-id "$contract_id"
    --output-dir "$output_dir"
    --target-app "${targets[0]}"
    --profile "$hardware_profile"
  )
  if [[ "$topology_mode" == "network" ]]; then
    cmd+=(--base-url "$app_endpoint")
  fi
  "${cmd[@]}"
  exit $?
fi

echo "Dispatch is not implemented for scenario=$scenario_id target_mode=$target_mode"
exit 3
