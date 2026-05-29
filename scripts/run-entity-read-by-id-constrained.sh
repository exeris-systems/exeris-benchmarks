#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCENARIO_JSON="${REPO_ROOT}/scenarios/entity-read-by-id/scenario.json"
PROFILES_JSON="${REPO_ROOT}/runtime/profiles/runtime-execution-profiles.json"
BASE_RUNNER="${REPO_ROOT}/scripts/run-entity-read-by-id.sh"

EXECUTION_PROFILE_ID="runtime-constrained-256m-1vcpu-v1"
CONTRACT_ID="fixed_contract_runtime_h1_constrained_smoke_256m_1vcpu_v1"
TARGET_RUNTIME="community"
TARGET_BUILD="jvm"
CPU_AFFINITY="${CPU_AFFINITY:-}"
BENCHMARK_SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-1}"
UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_NAMESPACE="results/constrained/entity-read-by-id/${UTC_STAMP}-constrained-smoke"
OUTPUT_DIR="${REPO_ROOT}/${RESULT_NAMESPACE}"

usage() {
  cat <<EOF
Usage: scripts/run-entity-read-by-id-constrained.sh [--execution-profile-id ID] [--contract-id ID] [--target-runtime <community|locality|spring|quarkus>] [--target-build <jvm|native>] [--cpu-affinity <cpuset>] [--output-dir PATH]

Defaults:
  --execution-profile-id runtime-constrained-256m-1vcpu-v1
  --contract-id fixed_contract_runtime_h1_constrained_smoke_256m_1vcpu_v1
  --target-runtime <community|locality|spring|quarkus> (default: community)
  --target-build <jvm|native> (default: jvm)
  --cpu-affinity <cpuset>  pin the target app to this cpuset via taskset (e.g. 0-1); empty = no pin
  --output-dir <repo>/results/constrained/entity-read-by-id/<utc-timestamp>-constrained-smoke
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execution-profile-id)
      EXECUTION_PROFILE_ID="$2"
      shift 2
      ;;
    --contract-id)
      CONTRACT_ID="$2"
      shift 2
      ;;
    --target-runtime)
      TARGET_RUNTIME="$2"
      shift 2
      ;;
    --target-build)
      TARGET_BUILD="$2"
      shift 2
      ;;
    --cpu-affinity)
      CPU_AFFINITY="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      RESULT_NAMESPACE="${OUTPUT_DIR#${REPO_ROOT}/}"
      shift 2
      ;;
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

case "$TARGET_RUNTIME" in
  community|locality|spring|quarkus)
    ;;
  *)
    echo "ERROR: Invalid --target-runtime '$TARGET_RUNTIME' (allowed: community|locality|spring|quarkus)" >&2
    exit 1
    ;;
esac

case "$TARGET_BUILD" in
  jvm|native)
    ;;
  *)
    echo "ERROR: Invalid --target-build '$TARGET_BUILD' (allowed: jvm|native)" >&2
    exit 1
    ;;
esac

if [[ "$BENCHMARK_SKIP_TARGET_BUILD" != "0" && "$BENCHMARK_SKIP_TARGET_BUILD" != "1" ]]; then
  echo "ERROR: BENCHMARK_SKIP_TARGET_BUILD must be 0 or 1 (got: $BENCHMARK_SKIP_TARGET_BUILD)" >&2
  exit 1
fi

if [[ ! -f "$SCENARIO_JSON" ]]; then
  echo "ERROR: Missing scenario contract file: $SCENARIO_JSON" >&2
  exit 1
fi
if [[ ! -f "$PROFILES_JSON" ]]; then
  echo "ERROR: Missing runtime execution profile file: $PROFILES_JSON" >&2
  exit 1
fi
if [[ ! -x "$BASE_RUNNER" ]]; then
  echo "ERROR: Missing executable base runner: $BASE_RUNNER" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

CG_MEMORY_MAX_RAW="unknown"
CG_CPU_MAX_RAW="unknown"
CG_MEMORY_MAX_BYTES="unknown"
CG_CPU_QUOTA_US="unknown"
CG_CPU_PERIOD_US="unknown"
CGROUP_DIR="unknown"

config_error() {
  local msg="$1"
  echo "CONFIG_ERROR: $msg" >&2
  echo "output_dir=$OUTPUT_DIR"
  echo "cgroup_path=${CGROUP_DIR}"
  echo "cgroup_memory_max_bytes=${CG_MEMORY_MAX_BYTES} cgroup_cpu_quota_us=${CG_CPU_QUOTA_US} cgroup_cpu_period_us=${CG_CPU_PERIOD_US}"
  echo "outcome=limit_mismatch rc=64"
  exit 64
}

ensure_constrained_scope() {
  local reason="$1"

  if [[ "${BENCHMARK_CONSTRAINED_SCOPE_ACTIVE:-0}" == "1" ]]; then
    config_error "$reason"
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then
    config_error "${reason}; systemd-run unavailable for auto-enforcement"
  fi

  local cpu_quota_pct
  cpu_quota_pct="$(awk -v v="$VCPU" 'BEGIN { printf "%.0f", v * 100 }')"

  echo "[info] ${reason}"
  echo "[info] Relaunching constrained run in user scope with MemoryMax=${LIMIT_MB}M CPUQuota=${cpu_quota_pct}%"

  local relaunch_args=(
    --execution-profile-id "$EXECUTION_PROFILE_ID"
    --contract-id "$CONTRACT_ID"
    --target-runtime "$TARGET_RUNTIME"
    --target-build "$TARGET_BUILD"
    --output-dir "$OUTPUT_DIR"
  )
  if [[ -n "$CPU_AFFINITY" ]]; then
    relaunch_args+=(--cpu-affinity "$CPU_AFFINITY")
  fi

  exec systemd-run --user --scope \
    -p "MemoryMax=${LIMIT_MB}M" \
    -p "MemorySwapMax=0" \
    -p "CPUQuota=${cpu_quota_pct}%" \
    env \
      BENCHMARK_CONSTRAINED_SCOPE_ACTIVE=1 \
      BENCHMARK_SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD}" \
      "$0" \
      "${relaunch_args[@]}"
}

CONTRACT_JSON="$(jq -ce --arg id "$CONTRACT_ID" '.fixed_contracts[$id] // empty' "$SCENARIO_JSON")" \
  || { echo "ERROR: Contract '$CONTRACT_ID' not found in scenario file" >&2; exit 1; }

CONTRACT_EXECUTION_PROFILE_ID="$(jq -r '.execution_profile_id // empty' <<<"$CONTRACT_JSON")"
if [[ -z "$CONTRACT_EXECUTION_PROFILE_ID" ]]; then
  echo "ERROR: Contract '$CONTRACT_ID' is missing execution_profile_id" >&2
  exit 1
fi
if [[ "$CONTRACT_EXECUTION_PROFILE_ID" != "$EXECUTION_PROFILE_ID" ]]; then
  echo "ERROR: Contract '$CONTRACT_ID' execution_profile_id='$CONTRACT_EXECUTION_PROFILE_ID' does not match selected profile '$EXECUTION_PROFILE_ID'" >&2
  exit 1
fi

THREADS="$(jq -r '.threads' <<<"$CONTRACT_JSON")"
CONNECTIONS="$(jq -r '.connections' <<<"$CONTRACT_JSON")"
WARMUP_SECONDS="$(jq -r '.warmup_seconds' <<<"$CONTRACT_JSON")"
DURATION_SECONDS="$(jq -r '.duration_seconds' <<<"$CONTRACT_JSON")"
CONSTRAINED_DB_POOL_MIN_SIZE="${EXERIS_DB_POOL_MIN_SIZE:-2}"
CONSTRAINED_DB_POOL_MAX_SIZE="${EXERIS_DB_POOL_MAX_SIZE:-8}"

if ! [[ "$CONSTRAINED_DB_POOL_MIN_SIZE" =~ ^[0-9]+$ && "$CONSTRAINED_DB_POOL_MAX_SIZE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: constrained DB pool sizes must be numeric" >&2
  exit 1
fi
if (( CONSTRAINED_DB_POOL_MIN_SIZE < 1 )); then
  CONSTRAINED_DB_POOL_MIN_SIZE=1
fi
if (( CONSTRAINED_DB_POOL_MAX_SIZE < CONSTRAINED_DB_POOL_MIN_SIZE )); then
  CONSTRAINED_DB_POOL_MAX_SIZE="$CONSTRAINED_DB_POOL_MIN_SIZE"
fi

PROFILE_JSON="$(jq -ce --arg id "$EXECUTION_PROFILE_ID" '.profiles[] | select(.execution_profile_id == $id)' "$PROFILES_JSON")" \
  || { echo "ERROR: Execution profile '$EXECUTION_PROFILE_ID' not found" >&2; exit 1; }

LIMIT_MB="$(jq -r '.memory_limit.limit_mb // empty' <<<"$PROFILE_JSON")"
VCPU="$(jq -r '.cpu_limit.vcpu // empty' <<<"$PROFILE_JSON")"
REQUIRED_TRACK_ID="$(jq -r '.required_track_id // empty' <<<"$PROFILE_JSON")"
JVM_GC="$(jq -r '.jvm.gc // empty' <<<"$PROFILE_JSON")"
JVM_ACTIVE_PROCESSOR_COUNT="$(jq -r '.jvm.active_processor_count // empty' <<<"$PROFILE_JSON")"
JVM_MAX_RAM_MB="$(jq -r '.jvm.max_ram_mb // empty' <<<"$PROFILE_JSON")"

if [[ -z "$LIMIT_MB" || -z "$VCPU" || -z "$REQUIRED_TRACK_ID" || -z "$JVM_GC" || -z "$JVM_ACTIVE_PROCESSOR_COUNT" || -z "$JVM_MAX_RAM_MB" ]]; then
  echo "ERROR: Execution profile '$EXECUTION_PROFILE_ID' is missing required constrained fields" >&2
  exit 1
fi

CGROUP_ROOT="/sys/fs/cgroup"
if [[ ! -f "${CGROUP_ROOT}/cgroup.controllers" ]]; then
  config_error "cgroup v2 is required: missing ${CGROUP_ROOT}/cgroup.controllers"
fi
CGROUP_REL_PATH="$(awk -F: '$1=="0" { print $3; exit }' /proc/self/cgroup 2>/dev/null || true)"
if [[ -z "$CGROUP_REL_PATH" || "$CGROUP_REL_PATH" == "/" ]]; then
  CGROUP_DIR="$CGROUP_ROOT"
else
  CGROUP_DIR="${CGROUP_ROOT}${CGROUP_REL_PATH}"
fi

if [[ ! -f "${CGROUP_DIR}/memory.max" || ! -f "${CGROUP_DIR}/cpu.max" ]]; then
  ensure_constrained_scope "cgroup v2 required files memory.max and cpu.max are missing"
fi

CG_MEMORY_MAX_RAW="$(<"${CGROUP_DIR}/memory.max")"
if [[ "$CG_MEMORY_MAX_RAW" == "max" ]]; then
  ensure_constrained_scope "memory.max is unlimited; expected finite cap <= ${LIMIT_MB}MB"
fi
if ! [[ "$CG_MEMORY_MAX_RAW" =~ ^[0-9]+$ ]]; then
  config_error "memory.max has non-numeric value '$CG_MEMORY_MAX_RAW'"
fi
CG_MEMORY_MAX_BYTES="$CG_MEMORY_MAX_RAW"
REQUIRED_MEMORY_MAX_BYTES="$((LIMIT_MB * 1024 * 1024))"
if (( CG_MEMORY_MAX_BYTES > REQUIRED_MEMORY_MAX_BYTES )); then
  ensure_constrained_scope "memory.max=${CG_MEMORY_MAX_BYTES} exceeds profile limit ${REQUIRED_MEMORY_MAX_BYTES}"
fi

CG_CPU_MAX_RAW="$(<"${CGROUP_DIR}/cpu.max")"
read -r CG_CPU_QUOTA_US CG_CPU_PERIOD_US <<<"$CG_CPU_MAX_RAW"
if [[ -z "${CG_CPU_QUOTA_US:-}" || -z "${CG_CPU_PERIOD_US:-}" ]]; then
  config_error "cpu.max has unexpected format '$CG_CPU_MAX_RAW'"
fi
if [[ "$CG_CPU_QUOTA_US" == "max" ]]; then
  ensure_constrained_scope "cpu.max is unlimited; expected finite quota/period <= ${VCPU}"
fi
if ! [[ "$CG_CPU_QUOTA_US" =~ ^[0-9]+$ && "$CG_CPU_PERIOD_US" =~ ^[0-9]+$ ]]; then
  config_error "cpu.max values must be numeric, got '$CG_CPU_MAX_RAW'"
fi

CG_EFFECTIVE_VCPU="$(LC_ALL=C awk -v q="$CG_CPU_QUOTA_US" -v p="$CG_CPU_PERIOD_US" 'BEGIN { if (p == 0) { print "nan" } else { printf "%.6f", q/p } }')"
if [[ "$CG_EFFECTIVE_VCPU" == "nan" ]]; then
  config_error "cpu.max period is zero"
fi
CPU_OVER_LIMIT="$(LC_ALL=C awk -v q="$CG_CPU_QUOTA_US" -v p="$CG_CPU_PERIOD_US" -v expected="$VCPU" 'BEGIN { if (p == 0) { print 1 } else { print ((q / p) > (expected + 1e-9)) ? 1 : 0 } }')"
if [[ "$CPU_OVER_LIMIT" == "1" ]]; then
  ensure_constrained_scope "cpu quota/period=${CG_EFFECTIVE_VCPU} exceeds profile vcpu=${VCPU}"
fi

JVM_OVERLAY_FLAGS=()
case "$JVM_GC" in
  serial)
    JVM_OVERLAY_FLAGS+=("-XX:+UseSerialGC")
    ;;
  *)
    echo "ERROR: Unsupported constrained JVM gc value '$JVM_GC' (expected serial)" >&2
    exit 1
    ;;
esac

JVM_XMS_MB="$(awk -v max_ram="$JVM_MAX_RAM_MB" 'BEGIN {
  x = int(max_ram / 4)
  if (x < 64) x = 64
  if (x > max_ram - 32) x = max_ram - 32
  if (x < 32) x = 32
  print x
}')"
JVM_XMX_MB="$(awk -v max_ram="$JVM_MAX_RAM_MB" 'BEGIN {
  x = int((max_ram * 3) / 4)
  if (x < 96) x = 96
  if (x >= max_ram) x = max_ram - 16
  if (x < 64) x = 64
  print x
}')"
if (( JVM_XMS_MB > JVM_XMX_MB )); then
  JVM_XMS_MB="$JVM_XMX_MB"
fi

JVM_OVERLAY_FLAGS+=("-XX:ActiveProcessorCount=${JVM_ACTIVE_PROCESSOR_COUNT}")
JVM_OVERLAY_FLAGS+=("-XX:MaxRAM=${JVM_MAX_RAM_MB}m")
JVM_OVERLAY_FLAGS+=("-Xms${JVM_XMS_MB}m")
JVM_OVERLAY_FLAGS+=("-Xmx${JVM_XMX_MB}m")

OVERLAY_JOINED="${JVM_OVERLAY_FLAGS[*]}"
if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
  export JAVA_TOOL_OPTIONS="${OVERLAY_JOINED} ${JAVA_TOOL_OPTIONS}"
else
  export JAVA_TOOL_OPTIONS="${OVERLAY_JOINED}"
fi

export BENCHMARK_EXECUTION_PROFILE_ID="$EXECUTION_PROFILE_ID"
export BENCHMARK_TRACK_ID="track-c"
export BENCHMARK_SKIP_TARGET_BUILD
export EXERIS_DB_POOL_MIN_SIZE="$CONSTRAINED_DB_POOL_MIN_SIZE"
export EXERIS_DB_POOL_MAX_SIZE="$CONSTRAINED_DB_POOL_MAX_SIZE"

if [[ "$BENCHMARK_SKIP_TARGET_BUILD" == "1" ]]; then
  echo "[info] BENCHMARK_SKIP_TARGET_BUILD=1 active: constrained mode will use prebuilt target artifacts only"
fi

echo "[info] Constrained DB pool sizing: min=${EXERIS_DB_POOL_MIN_SIZE} max=${EXERIS_DB_POOL_MAX_SIZE}"

LAUNCH_COMMAND=(
  "./scripts/run-entity-read-by-id.sh"
  "--claim-scope" "exploratory"
  "--profile" "dev-laptop"
  "--output-dir" "$OUTPUT_DIR"
  "--target-runtime" "$TARGET_RUNTIME"
  "--target-build" "$TARGET_BUILD"
  "--threads" "$THREADS"
  "--connections" "$CONNECTIONS"
  "--warmup" "${WARMUP_SECONDS}s"
  "--duration" "${DURATION_SECONDS}s"
)
if [[ -n "$CPU_AFFINITY" ]]; then
  # Base runner pins the target app to this cpuset via taskset (server-side pin,
  # orthogonal to the scope CPUQuota).
  LAUNCH_COMMAND+=("--cpu-affinity" "$CPU_AFFINITY")
fi

set +e
(
  cd "$REPO_ROOT"
  "${LAUNCH_COMMAND[@]}"
)
BENCHMARK_RC=$?
set -e

OUTCOME="ok"
TARGET_APP_LOG="${OUTPUT_DIR}/target-app.log"
if [[ "$BENCHMARK_RC" -ne 0 ]]; then
  OUTCOME="startup_failed"
  if [[ -f "$TARGET_APP_LOG" ]]; then
    if grep -Eq 'OutOfMemoryError|Killed' "$TARGET_APP_LOG"; then
      OUTCOME="oom_killed"
    elif grep -Eqi 'readiness check failed|failed readiness check' "$TARGET_APP_LOG"; then
      OUTCOME="readiness_timeout"
    fi
  fi
fi

CG_MEMORY_PEAK_BYTES="unknown"
if [[ -f "${CGROUP_DIR}/memory.peak" ]]; then
  CG_MEMORY_PEAK_BYTES="$(<"${CGROUP_DIR}/memory.peak")"
elif [[ -f "${CGROUP_DIR}/memory.current" ]]; then
  CG_MEMORY_PEAK_BYTES="$(<"${CGROUP_DIR}/memory.current")"
fi

CPU_STAT_NR_PERIODS="0"
CPU_STAT_NR_THROTTLED="0"
CPU_STAT_THROTTLED_USEC="0"
if [[ -f "${CGROUP_DIR}/cpu.stat" ]]; then
  CPU_STAT_NR_PERIODS="$(awk '$1=="nr_periods" {print $2}' "${CGROUP_DIR}/cpu.stat" | head -n1)"
  CPU_STAT_NR_THROTTLED="$(awk '$1=="nr_throttled" {print $2}' "${CGROUP_DIR}/cpu.stat" | head -n1)"
  CPU_STAT_THROTTLED_USEC="$(awk '$1=="throttled_usec" {print $2}' "${CGROUP_DIR}/cpu.stat" | head -n1)"
  CPU_STAT_NR_PERIODS="${CPU_STAT_NR_PERIODS:-0}"
  CPU_STAT_NR_THROTTLED="${CPU_STAT_NR_THROTTLED:-0}"
  CPU_STAT_THROTTLED_USEC="${CPU_STAT_THROTTLED_USEC:-0}"
fi

EVIDENCE_FILE="${OUTPUT_DIR}/constrained-execution-evidence.json"
LAUNCH_OVERLAY_FILE="${OUTPUT_DIR}/constrained-launch-overlay.env"
GENERATED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

JVM_FLAGS_JSON="$(printf '%s\n' "${JVM_OVERLAY_FLAGS[@]}" | jq -R . | jq -s .)"
LAUNCH_COMMAND_JSON="$(printf '%s\n' "${LAUNCH_COMMAND[@]}" | jq -R . | jq -s .)"

jq -n \
  --arg execution_profile_id "$EXECUTION_PROFILE_ID" \
  --arg contract_id "$CONTRACT_ID" \
  --arg target_runtime "$TARGET_RUNTIME" \
  --arg target_build "$TARGET_BUILD" \
  --argjson benchmark_skip_target_build "$BENCHMARK_SKIP_TARGET_BUILD" \
  --arg required_track_id "$REQUIRED_TRACK_ID" \
  --arg track_id "track-c" \
  --arg result_namespace "$RESULT_NAMESPACE" \
  --arg memory_max_bytes "$CG_MEMORY_MAX_BYTES" \
  --arg cpu_quota_us "$CG_CPU_QUOTA_US" \
  --arg cpu_period_us "$CG_CPU_PERIOD_US" \
  --arg memory_peak_bytes "$CG_MEMORY_PEAK_BYTES" \
  --arg nr_periods "$CPU_STAT_NR_PERIODS" \
  --arg nr_throttled "$CPU_STAT_NR_THROTTLED" \
  --arg throttled_usec "$CPU_STAT_THROTTLED_USEC" \
  --argjson jvm_overlay_flags "$JVM_FLAGS_JSON" \
  --argjson launch_command "$LAUNCH_COMMAND_JSON" \
  --argjson benchmark_exit_code "$BENCHMARK_RC" \
  --arg outcome "$OUTCOME" \
  --arg generated_at_utc "$GENERATED_AT_UTC" \
  '{
    execution_profile_id: $execution_profile_id,
    contract_id: $contract_id,
    target_runtime: $target_runtime,
    target_build: $target_build,
    benchmark_skip_target_build: $benchmark_skip_target_build,
    required_track_id: $required_track_id,
    track_id: $track_id,
    result_namespace: $result_namespace,
    cgroup_effective: {
      memory_max_bytes: ($memory_max_bytes|tonumber?),
      cpu_quota_us: ($cpu_quota_us|tonumber?),
      cpu_period_us: ($cpu_period_us|tonumber?),
      memory_peak_bytes: ($memory_peak_bytes|tonumber?),
      cpu_stat: {
        nr_periods: ($nr_periods|tonumber?),
        nr_throttled: ($nr_throttled|tonumber?),
        throttled_usec: ($throttled_usec|tonumber?)
      }
    },
    jvm_overlay_flags: $jvm_overlay_flags,
    launch_command: $launch_command,
    benchmark_exit_code: $benchmark_exit_code,
    outcome: $outcome,
    generated_at_utc: $generated_at_utc
  }' > "$EVIDENCE_FILE"

{
  printf 'export JAVA_TOOL_OPTIONS=%q\n' "$JAVA_TOOL_OPTIONS"
  printf 'export BENCHMARK_EXECUTION_PROFILE_ID=%q\n' "$BENCHMARK_EXECUTION_PROFILE_ID"
  printf 'export BENCHMARK_TRACK_ID=%q\n' "$BENCHMARK_TRACK_ID"
  printf 'export EXERIS_DB_POOL_MIN_SIZE=%q\n' "$EXERIS_DB_POOL_MIN_SIZE"
  printf 'export EXERIS_DB_POOL_MAX_SIZE=%q\n' "$EXERIS_DB_POOL_MAX_SIZE"
} > "$LAUNCH_OVERLAY_FILE"

RESULT_FILE="${OUTPUT_DIR}/result.json"
if [[ -f "$RESULT_FILE" ]]; then
  TMP_RESULT="$(mktemp)"
  jq \
    --arg execution_profile_id "$EXECUTION_PROFILE_ID" \
    --arg contract_id "$CONTRACT_ID" \
    --arg track_id "track-c" \
    --arg result_namespace "$RESULT_NAMESPACE" \
    '.run_config = ((.run_config // {}) + {
      execution_profile_id: $execution_profile_id,
      contract_id: $contract_id,
      track_id: $track_id,
      result_namespace: $result_namespace
    })' "$RESULT_FILE" > "$TMP_RESULT"
  mv "$TMP_RESULT" "$RESULT_FILE"

  TMP_RESULT_TRACK="$(mktemp)"
  if jq 'try (. + {run_track: "constrained"}) catch .' "$RESULT_FILE" > "$TMP_RESULT_TRACK"; then
    mv "$TMP_RESULT_TRACK" "$RESULT_FILE"
  else
    rm -f "$TMP_RESULT_TRACK"
  fi
fi

REPRO_FILE="${OUTPUT_DIR}/reproducibility-metadata.json"
if [[ -f "$REPRO_FILE" ]]; then
  TMP_REPRO="$(mktemp)"
  jq \
    --arg contract_id "$CONTRACT_ID" \
    '.axis_labels = ((.axis_labels // {}) + {
      claim_scope: "descriptive_only",
      execution_class: "exploratory"
    })
    | .contract = $contract_id' "$REPRO_FILE" > "$TMP_REPRO"
  mv "$TMP_REPRO" "$REPRO_FILE"
fi

echo "output_dir=$OUTPUT_DIR"
echo "cgroup_memory_max_bytes=$CG_MEMORY_MAX_BYTES cgroup_cpu_quota_us=$CG_CPU_QUOTA_US cgroup_cpu_period_us=$CG_CPU_PERIOD_US"
echo "outcome=$OUTCOME rc=$BENCHMARK_RC"

exit "$BENCHMARK_RC"
