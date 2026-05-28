#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-guided.sh [--profile-out <path>] [--execute] [--no-execute]

Interactive guided launcher for local and WAN benchmark runs.

  - menu-driven selection of: connectivity (local / WAN-remote / WAN-impaired),
    scenario, load driver, target app(s), runtime env file, hardware profile,
    protocol/tier/classification, workload and fairness intent
  - captures benchmark metadata and run intent into guided-run-profile.json
  - validates the profile via runtime/drivers/validate-guided-profile.sh
  - optionally dispatches the matching run script:
      * multi-target               -> run-comparative.sh
      * entity-read-by-id (local)  -> run-entity-read-by-id.sh
      * e2e-shop-order-saga        -> run-e2e-shop-order-saga-baseline.sh
      * any scenario + a load      -> run-wrk.sh / run-wrk2.sh / run-k6.sh /
        driver (wrk/wrk2/k6/h2load)   run-h2load.sh (local or WAN endpoint)

Connectivity modes:
  local         loopback, clean path; target launched locally
  wan-remote    target reachable over the network at a remote host:port
  wan-impaired  controlled tc netem impairment (delay/loss/jitter), loopback
                or remote; impairment parameters are captured into the profile
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
TARGET_MATRIX="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"
ENV_DIR="${REPO_ROOT}/runtime/drivers/env"

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

[[ -f "$TARGET_MATRIX" ]] || fail "Target asset matrix not found: $TARGET_MATRIX"

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

choose_option() {
  local prompt="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local value=""

  while true; do
    read -r -p "$prompt [$default]: " value || true
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

# select_kv <prompt> <default-value> <val1> <label1> [<val2> <label2> ...]
# Renders a numbered menu (to stderr) and prints the chosen value (to stdout).
select_kv() {
  local prompt="$1"
  local default="$2"
  shift 2
  local -a vals=()
  local -a labels=()
  while [[ $# -gt 0 ]]; do
    vals+=("$1")
    labels+=("${2:-$1}")
    shift 2
  done

  local n="${#vals[@]}"
  [[ "$n" -ge 1 ]] || fail "select_kv called with no options ($prompt)"

  local i default_idx=1
  for ((i = 0; i < n; i++)); do
    if [[ "${vals[i]}" == "$default" ]]; then
      default_idx=$((i + 1))
    fi
  done

  {
    printf '\n%s\n' "$prompt"
    for ((i = 0; i < n; i++)); do
      printf '  %2d) %s\n' "$((i + 1))" "${labels[i]}"
    done
  } >&2

  local choice
  while true; do
    read -r -p "  -> choose 1-${n} [${default_idx}]: " choice || true
    choice="${choice:-$default_idx}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      printf '%s\n' "${vals[choice - 1]}"
      return 0
    fi
    echo "  invalid selection '$choice' (enter 1-${n})" >&2
  done
}

prompt_text() {
  local prompt="$1"
  local default="$2"
  local value=""
  read -r -p "$prompt [$default]: " value || true
  value="${value:-$default}"
  printf '%s\n' "$value"
}

prompt_positive_int() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 1 ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "Invalid value '$value'. Enter an integer >= 1." >&2
  done
}

prompt_number() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "Invalid number '$value'. Enter a non-negative number." >&2
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
    jq)     line="$(jq --version 2>/dev/null | head -n1 || true)" ;;
    k6)     line="$(k6 version 2>/dev/null | head -n1 || true)" ;;
    wrk)    line="$(wrk --version 2>/dev/null | head -n1 || true)" ;;
    wrk2)   line="$(wrk2 --version 2>/dev/null | head -n1 || true)" ;;
    h2load) line="$(h2load --version 2>/dev/null | head -n1 || true)" ;;
    docker) line="$(docker --version 2>/dev/null | head -n1 || true)" ;;
    tc)     line="$(tc -V 2>/dev/null | head -n1 || true)" ;;
    *)      line="unknown" ;;
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

# Best-effort target directory (used only to locate optional per-target driver
# config; base URL is supplied via *_BASE_URL_OVERRIDE for guided dispatch).
map_target_dir() {
  local tid="$1"
  local dir
  case "$tid" in
    spring*)  dir="targets/spring-benchmark-app" ;;
    quarkus*) dir="targets/quarkus-benchmark-app" ;;
    *)        dir="targets/exeris-community-app" ;;
  esac
  if [[ -d "${REPO_ROOT}/${dir}" ]]; then
    printf '%s\n' "$dir"
  else
    printf '%s\n' "targets"
  fi
}

# scheme://host:port from a target's health_url in the asset matrix.
resolve_local_base_url() {
  local tid="$1" hu
  hu="$(jq -r --arg id "$tid" '.targets[] | select(.target_id == $id) | .health_url // empty' "$TARGET_MATRIX" 2>/dev/null || true)"
  if [[ -n "$hu" ]]; then
    printf '%s\n' "$hu" | sed -E 's#(https?://[^/]+).*#\1#'
  else
    printf '%s\n' "http://localhost:8080"
  fi
}

# ---------------------------------------------------------------------------
# Discovery: scenarios, targets, env files
# ---------------------------------------------------------------------------

readarray -t SCENARIO_IDS < <(find "$REPO_ROOT/scenarios" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ "${#SCENARIO_IDS[@]}" -gt 0 ]] || fail "No scenarios found under $REPO_ROOT/scenarios"

readarray -t TARGET_IDS < <(jq -r '.targets[].target_id' "$TARGET_MATRIX" 2>/dev/null | sort)
[[ "${#TARGET_IDS[@]}" -gt 0 ]] || fail "No targets found in $TARGET_MATRIX"

readarray -t ENV_FILE_NAMES < <(find "$ENV_DIR" -maxdepth 1 -type f -name '*.env' -printf '%f\n' 2>/dev/null | sort || true)

echo "=== Exeris guided benchmark launcher ==="

# ---------------------------------------------------------------------------
# Run intent + connectivity
# ---------------------------------------------------------------------------

run_type="$(select_kv "Run type" "exploratory" \
  guard       "guard       — gating/smoke probe" \
  regression  "regression  — baseline-tracked run" \
  exploratory "exploratory — descriptive investigation")"

connectivity="$(select_kv "Connectivity / topology" "local" \
  local        "local        — loopback, clean path, target launched locally" \
  wan-remote   "wan-remote   — target over the network at a remote host:port" \
  wan-impaired "wan-impaired — tc netem delay/loss/jitter (loopback or remote)")"

# Connectivity -> topology_mode (schema) + impairment intent.
topology_mode="localhost"
impairment_enabled="false"
applied_to=""
imp_profile=""
apply_netem="no"
delay_ms=0
loss_pct=0
jitter_ms=0

app_endpoint=""
db_endpoint=""
health_path=""
launch_mode=""
runtime_mode=""

configure_impairment() {
  imp_profile="$(select_kv "Network impairment profile (tc netem)" "moderate" \
    mild     "mild     — 5ms delay / 0.1% loss / 1ms jitter" \
    moderate "moderate — 20ms delay / 1.0% loss / 5ms jitter" \
    severe   "severe   — 100ms delay / 5.0% loss / 20ms jitter" \
    custom   "custom   — enter values")"
  case "$imp_profile" in
    mild)     delay_ms=5;   loss_pct=0.1; jitter_ms=1 ;;
    moderate) delay_ms=20;  loss_pct=1.0; jitter_ms=5 ;;
    severe)   delay_ms=100; loss_pct=5.0; jitter_ms=20 ;;
    custom)
      delay_ms="$(prompt_positive_int "netem delay_ms" "20")"
      loss_pct="$(prompt_number "netem loss_pct" "1.0")"
      jitter_ms="$(prompt_positive_int "netem jitter_ms" "5")"
      ;;
  esac
  impairment_enabled="true"
}

case "$connectivity" in
  local)
    topology_mode="localhost"
    launch_mode="$(select_kv "Launch mode" "prebuild" \
      prebuild "prebuild — use a pre-built jar/binary" \
      build    "build    — build from source first" \
      docker   "docker   — launch via docker compose")"
    runtime_mode="$(select_kv "Runtime mode" "jvm" \
      jvm    "jvm    — JVM build" \
      native "native — native-image build")"
    ;;
  wan-remote)
    topology_mode="network"
    ;;
  wan-impaired)
    applied_to="$(select_kv "Apply impairment to" "loopback" \
      loopback "loopback — tc netem on lo, target launched locally" \
      remote   "remote   — impairment lives on the path to a remote endpoint")"
    configure_impairment
    if [[ "$applied_to" == "loopback" ]]; then
      topology_mode="localhost"
      launch_mode="$(select_kv "Launch mode" "prebuild" \
        prebuild "prebuild — use a pre-built jar/binary" \
        build    "build    — build from source first" \
        docker   "docker   — launch via docker compose")"
      runtime_mode="$(select_kv "Runtime mode" "jvm" \
        jvm    "jvm    — JVM build" \
        native "native — native-image build")"
      apply_netem="$(choose_option "Apply tc netem to loopback at dispatch (requires root)?" "no" yes no)"
    else
      topology_mode="network"
      warn "Impairment lives on the remote network path; the guided launcher will NOT apply tc netem locally."
    fi
    ;;
esac

if [[ "$topology_mode" == "network" ]]; then
  wan_scheme="$(select_kv "WAN scheme" "http" http "http" https "https")"
  wan_host="$(prompt_text "WAN target host" "10.0.0.10")"
  wan_port="$(prompt_positive_int "WAN target port" "8080")"
  health_path="$(prompt_text "Health path" "/health")"
  app_endpoint="${wan_scheme}://${wan_host}:${wan_port}"
  db_endpoint="$(prompt_text "db_endpoint" "postgresql://benchmark:benchmark@${wan_host}:5432/benchmark")"
  warn "Network mode: ensure the remote target is launched with scenario-compatible configuration before execution."
fi

# ---------------------------------------------------------------------------
# Scenario + driver
# ---------------------------------------------------------------------------

scenario_kv=()
for s in "${SCENARIO_IDS[@]}"; do
  desc="$(jq -r '.description // ""' "$REPO_ROOT/scenarios/$s/scenario.json" 2>/dev/null | tr '\n' ' ' | cut -c1-60)"
  if [[ -n "$desc" ]]; then
    scenario_kv+=("$s" "$s — $desc")
  else
    scenario_kv+=("$s" "$s")
  fi
done
scenario_id="$(select_kv "Scenario" "entity-read-by-id" "${scenario_kv[@]}")"

scenario_json="$REPO_ROOT/scenarios/$scenario_id/scenario.json"

# Drivers declared by the scenario, intersected with supported load drivers.
readarray -t SCEN_DRIVERS < <(jq -r '.driver[]?' "$scenario_json" 2>/dev/null || true)
driver_kv=()
for d in "${SCEN_DRIVERS[@]}"; do
  case "$d" in
    wrk|wrk2|k6|h2load) driver_kv+=("$d" "$d") ;;
  esac
done

driver="none"
if [[ "${#driver_kv[@]}" -gt 0 ]]; then
  driver_kv+=("none" "none — generate profile only (no auto-dispatch)")
  driver="$(select_kv "Load driver (auto-dispatch for non-specialized scenarios)" "${driver_kv[0]}" "${driver_kv[@]}")"
else
  warn "Scenario '$scenario_id' declares no HTTP load driver (uses ${SCEN_DRIVERS[*]:-a specialized harness}); no generic dispatch available."
fi

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

target_kv=()
for t in "${TARGET_IDS[@]}"; do
  meta="$(jq -r --arg id "$t" '.targets[] | select(.target_id == $id) | "\(.tier // "?")/\(.protocol_mode // "?")  \(.health_url // "")"' "$TARGET_MATRIX" 2>/dev/null || true)"
  target_kv+=("$t" "$t   [$meta]")
done

target_mode="$(select_kv "Target mode" "single" \
  single "single — one target" \
  multi  "multi  — two targets (comparative)")"

targets=()
if [[ "$target_mode" == "single" ]]; then
  target_single="$(select_kv "Target app" "${TARGET_IDS[0]}" "${target_kv[@]}")"
  targets+=("$target_single")
else
  target_a="$(select_kv "Target A" "${TARGET_IDS[0]}" "${target_kv[@]}")"
  target_b="$(select_kv "Target B" "${TARGET_IDS[1]:-${TARGET_IDS[0]}}" "${target_kv[@]}")"
  targets+=("$target_a" "$target_b")
fi

# ---------------------------------------------------------------------------
# Classification axes
# ---------------------------------------------------------------------------

protocol_mode="$(select_kv "Protocol mode" "h1" h1 "h1 — HTTP/1.1" h2 "h2 — HTTP/2" h3 "h3 — HTTP/3/QUIC")"
tier="$(select_kv "Tier" "community" community "community" enterprise "enterprise")"
target_classification="$(select_kv "Target classification" "pure" \
  pure   "pure   — pure-mode runtime" \
  compat "compat — compatibility mode")"

# ---------------------------------------------------------------------------
# Env file + workload + reproducibility metadata
# ---------------------------------------------------------------------------

env_file="none"
env_kv=("none" "none — no runtime env file")
for e in "${ENV_FILE_NAMES[@]}"; do
  env_kv+=("$e" "$e")
done
if [[ "${#env_kv[@]}" -gt 2 ]]; then
  env_file="$(select_kv "Runtime env file (runtime/drivers/env/)" "none" "${env_kv[@]}")"
fi

contract_id="$(prompt_text "contract_id" "fixed_contract_v1")"
warmup_seconds="$(prompt_positive_int "workload.warmup_seconds" "60")"
measurement_seconds="$(prompt_positive_int "workload.measurement_seconds" "120")"
threads="$(prompt_positive_int "workload.threads" "4")"
connections="$(prompt_positive_int "workload.connections" "128")"
hardware_profile="$(select_kv "Hardware profile" "dev-laptop" \
  linux-generic    "linux-generic" \
  aarch64-generic  "aarch64-generic" \
  dev-laptop       "dev-laptop" \
  ci-runner        "ci-runner" \
  docker-container "docker-container")"

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

read -r -p "jvm_flags (comma-separated, empty for none) []: " jvm_flags_raw || true
jvm_flags=()
if [[ -n "${jvm_flags_raw//[[:space:]]/}" ]]; then
  IFS=',' read -r -a raw_flags <<< "$jvm_flags_raw"
  for f in "${raw_flags[@]}"; do
    trimmed="$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$trimmed" ]] && jvm_flags+=("$trimmed")
  done
fi

# ---------------------------------------------------------------------------
# Claim scope + fairness attestations
# ---------------------------------------------------------------------------

claim_scope="descriptive_only"
if [[ "$run_type" != "exploratory" ]]; then
  claim_scope="$(select_kv "Claim scope" "descriptive_only" \
    descriptive_only    "descriptive_only    — describe results only" \
    comparison_eligible "comparison_eligible — eligible for cross-target claims")"
fi

fairness_payload_equivalent="false"
fairness_concurrency_equivalent="false"
fairness_protocol_mode_equivalent="false"
fairness_target_scope_equivalent="false"

if [[ "$claim_scope" == "comparison_eligible" ]]; then
  [[ "$(choose_option "fairness_attest_payload" "yes" yes no)" == "yes" ]] && fairness_payload_equivalent="true"
  [[ "$(choose_option "fairness_attest_concurrency" "yes" yes no)" == "yes" ]] && fairness_concurrency_equivalent="true"
  [[ "$(choose_option "fairness_attest_protocol_mode" "yes" yes no)" == "yes" ]] && fairness_protocol_mode_equivalent="true"
  [[ "$(choose_option "fairness_attest_target_scope" "yes" yes no)" == "yes" ]] && fairness_target_scope_equivalent="true"
fi

# ---------------------------------------------------------------------------
# Write profile
# ---------------------------------------------------------------------------

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$PROFILE_OUT" ]]; then
  PROFILE_OUT="$REPO_ROOT/results/raw/guided/${timestamp}/guided-run-profile.json"
fi
mkdir -p "$(dirname "$PROFILE_OUT")"
profile_dir="$(cd "$(dirname "$PROFILE_OUT")" && pwd)"
output_dir="$profile_dir"
mkdir -p "$output_dir"

targets_json="$(jq -n '$ARGS.positional' --args "${targets[@]}")"
if [[ "${#jvm_flags[@]}" -gt 0 ]]; then
  jvm_flags_json="$(jq -n '$ARGS.positional' --args "${jvm_flags[@]}")"
else
  jvm_flags_json="[]"
fi

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
  --arg connectivity "$connectivity" \
  --arg run_type "$run_type" \
  --arg target_mode "$target_mode" \
  --arg claim_scope "$claim_scope" \
  --arg driver "$driver" \
  --arg env_file "$env_file" \
  --arg app_endpoint "$app_endpoint" \
  --arg db_endpoint "$db_endpoint" \
  --arg health_path "$health_path" \
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
  --arg impairment_enabled "$impairment_enabled" \
  --arg apply_netem "$apply_netem" \
  --arg imp_profile "$imp_profile" \
  --arg applied_to "$applied_to" \
  --arg netem_tool "tc netem" \
  --argjson delay_ms "${delay_ms:-0}" \
  --argjson loss_pct "${loss_pct:-0}" \
  --argjson jitter_ms "${jitter_ms:-0}" \
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
    connectivity: $connectivity,
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
  | (if $driver != "none" and $driver != "" then . + {driver: $driver} else . end)
  | (if $env_file != "none" and $env_file != "" then . + {env_file: $env_file} else . end)
  | (if $topology_mode == "network"
       then . + {app_endpoint: $app_endpoint, db_endpoint: $db_endpoint, health_path: $health_path}
       else . + {launch_mode: $launch_mode, runtime_mode: $runtime_mode} end)
  | (if $impairment_enabled == "true"
       then . + {network_impairment: {
                   enabled: true,
                   apply_requested: ($apply_netem == "yes"),
                   applied_to: $applied_to,
                   profile: $imp_profile,
                   tool: $netem_tool,
                   delay_ms: $delay_ms,
                   loss_pct: $loss_pct,
                   jitter_ms: $jitter_ms
                 }}
       else . end)
  ' > "$PROFILE_OUT"

info "Profile written: $PROFILE_OUT"
validate_args=(--profile "$PROFILE_OUT" --dispatch-compatible)
if [[ "$claim_scope" == "comparison_eligible" ]]; then
  validate_args+=(--confirm-comparison-eligibility)
fi
"$VALIDATOR_SCRIPT" "${validate_args[@]}"

echo
echo "Guided profile summary:"
echo "  run_type           : $run_type"
echo "  connectivity       : $connectivity (topology_mode=$topology_mode)"
echo "  scenario_id        : $scenario_id"
echo "  driver             : $driver"
echo "  protocol_mode      : $protocol_mode"
echo "  tier               : $tier"
echo "  target_classification: $target_classification"
echo "  target_mode        : $target_mode"
echo "  targets            : ${targets[*]}"
echo "  env_file           : $env_file"
echo "  hardware_profile   : $hardware_profile"
echo "  claim_scope        : $claim_scope"
echo "  contract_id        : $contract_id"
echo "  output_dir         : $output_dir"
echo "  workload           : warmup=$warmup_seconds measurement=$measurement_seconds threads=$threads connections=$connections"
if [[ "$topology_mode" == "network" ]]; then
  echo "  app_endpoint       : $app_endpoint"
  echo "  db_endpoint        : $db_endpoint"
  echo "  health_path        : $health_path"
fi
if [[ "$impairment_enabled" == "true" ]]; then
  echo "  impairment         : profile=$imp_profile applied_to=$applied_to delay=${delay_ms}ms loss=${loss_pct}% jitter=${jitter_ms}ms apply_requested=$apply_netem"
fi

# ---------------------------------------------------------------------------
# Execution decision
# ---------------------------------------------------------------------------

should_execute="no"
if [[ "$EXECUTE_MODE" == "yes" ]]; then
  should_execute="yes"
elif [[ "$EXECUTE_MODE" == "no" ]]; then
  should_execute="no"
else
  read -r -p "Execute now? [y/N]: " run_now || true
  if [[ "$run_now" == "y" || "$run_now" == "Y" ]]; then
    should_execute="yes"
  fi
fi

if [[ "$should_execute" != "yes" ]]; then
  info "Generate+validate complete (execution skipped)."
  exit 0
fi

# ---------------------------------------------------------------------------
# tc netem application (loopback only, when requested)
# ---------------------------------------------------------------------------

NETEM_APPLIED=0
maybe_apply_netem() {
  [[ "$impairment_enabled" == "true" && "$apply_netem" == "yes" && "$applied_to" == "loopback" ]] || return 0

  if ! command -v tc >/dev/null 2>&1; then
    warn "tc not available; cannot apply netem. Run is invalid for impairment claims; metadata captured only."
    return 0
  fi

  local prefix=""
  [[ "${EUID:-$(id -u)}" -ne 0 ]] && prefix="sudo"

  info "Applying tc netem to loopback: delay=${delay_ms}ms jitter=${jitter_ms}ms loss=${loss_pct}%"
  if $prefix tc qdisc add dev lo root netem delay "${delay_ms}ms" "${jitter_ms}ms" loss "${loss_pct}%"; then
    NETEM_APPLIED=1
    trap 'if [[ "${NETEM_APPLIED:-0}" == "1" ]]; then '"$prefix"' tc qdisc del dev lo root 2>/dev/null || true; fi' EXIT
  else
    warn "Failed to apply tc netem; continuing without impairment (run invalid for impairment claims)."
  fi
}

# ---------------------------------------------------------------------------
# Generic single-target dispatch via the selected load driver
# ---------------------------------------------------------------------------

dispatch_generic_driver() {
  local base_url="$1"
  local target_rel
  target_rel="$(map_target_dir "${targets[0]}")"
  local scenario_rel="scenarios/$scenario_id"

  info "Dispatch: run-${driver}.sh (base_url=$base_url, target_dir=$target_rel)"
  case "$driver" in
    wrk)
      WRK_BASE_URL_OVERRIDE="$base_url" \
      WRK_THREADS_OVERRIDE="$threads" \
      WRK_CONNECTIONS_OVERRIDE="$connections" \
      WRK_DURATION_OVERRIDE="${measurement_seconds}s" \
        "$REPO_ROOT/scripts/run-wrk.sh" "$target_rel" "$scenario_rel"
      ;;
    wrk2)
      WRK_BASE_URL_OVERRIDE="$base_url" \
      WRK2_THREADS_OVERRIDE="$threads" \
      WRK2_CONNECTIONS_OVERRIDE="$connections" \
      WRK2_DURATION_OVERRIDE="${measurement_seconds}s" \
        "$REPO_ROOT/scripts/run-wrk2.sh" "$target_rel" "$scenario_rel"
      ;;
    k6)
      BASE_URL="$base_url" K6_BASE_URL="$base_url" \
        "$REPO_ROOT/scripts/run-k6.sh" "$scenario_rel"
      ;;
    h2load)
      H2LOAD_BASE_URL_OVERRIDE="$base_url" \
      H2LOAD_CLIENTS="$connections" \
        "$REPO_ROOT/scripts/run-h2load.sh" "$target_rel" "$scenario_rel"
      ;;
    *)
      echo "No load driver selected for generic dispatch (driver=$driver)." >&2
      return 3
      ;;
  esac
}

resolve_dispatch_base_url() {
  if [[ "$topology_mode" == "network" ]]; then
    printf '%s\n' "$app_endpoint"
  else
    resolve_local_base_url "${targets[0]}"
  fi
}

# ---- Multi-target: comparative ----
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

# ---- entity-read-by-id (local): specialized runner ----
if [[ "$scenario_id" == "entity-read-by-id" && "$topology_mode" == "localhost" ]]; then
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

# ---- e2e-shop-order-saga: specialized baseline (supports WAN base URL) ----
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

# ---- Generic driver dispatch (local or WAN) ----
if [[ "$driver" != "none" && -n "$driver" ]]; then
  if [[ "$scenario_id" == "entity-read-by-id" && "$topology_mode" == "network" ]]; then
    warn "WAN entity-read-by-id: skipping specialized seeding/preflight/gates — ensure the remote target is seeded and ready."
  fi
  base_url="$(resolve_dispatch_base_url)"
  maybe_apply_netem
  dispatch_generic_driver "$base_url"
  exit $?
fi

echo "Dispatch is not implemented for scenario=$scenario_id with driver=$driver (target_mode=$target_mode)."
echo "This scenario uses a specialized harness (e.g. radamsa/jazzer/slowloris); use the dedicated run-*.sh script."
exit 0
