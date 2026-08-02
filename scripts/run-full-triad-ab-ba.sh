#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

READINESS_LIB="${REPO_ROOT}/tools/bench/lib/readiness.sh"
if [[ ! -f "$READINESS_LIB" ]]; then
  echo "ERROR: ${READINESS_LIB} not found"
  exit 1
fi

# shellcheck source=/dev/null
source "$READINESS_LIB"

if [[ ! -x ./scripts/run-comparative.sh ]]; then
  echo "ERROR: ./scripts/run-comparative.sh not found or not executable"
  exit 1
fi

export HARDWARE_PROFILE="perf-box-amd64"

# Increase preflight timeout for slower app startup.
export ENTITY_READ_PREFLIGHT_TIMEOUT="60"

SCENARIO_ENDPOINT_PATH="/api/v1/users"
SCENARIO_ID="entity-read-by-id"
SCENARIO_INFRA_SCRIPT="./scenarios/${SCENARIO_ID}/infra-setup.sh"
TARGET_START_SCRIPT="./runtime/drivers/start-target.sh"
TARGET_STOP_SCRIPT="./runtime/drivers/stop-target.sh"

CAMPAIGN_TS=$(date -u +%Y%m%d-%H%M%S)
# BENCH_CAMPAIGN_OUTPUT_DIR_OVERRIDE lets a caller (e.g. the latency-curve wrapper, which
# invokes this harness once per (endpoint,rung)) pin each invocation's output under its own
# organized path instead of a fresh ${TS}-full-triad-ab-ba dir. Default is unchanged.
CAMPAIGN_OUTPUT_DIR="${BENCH_CAMPAIGN_OUTPUT_DIR_OVERRIDE:-results/raw/entity-read-by-id/${CAMPAIGN_TS}-full-triad-ab-ba}"

BENCH_DB_POOL_MIN_SIZE=${BENCH_DB_POOL_MIN_SIZE:-16}
BENCH_DB_POOL_MAX_SIZE=${BENCH_DB_POOL_MAX_SIZE:-256}
BENCH_SERVER_CPU_AFFINITY=${BENCH_SERVER_CPU_AFFINITY:-}
BENCH_LOADGEN_CPU_AFFINITY=${BENCH_LOADGEN_CPU_AFFINITY:-${LOADGEN_CPU_AFFINITY:-}}
BENCH_TOTAL_MEMORY_MB=${BENCH_TOTAL_MEMORY_MB:-2048}
BENCH_EXERIS_HEAP_MB=${BENCH_EXERIS_HEAP_MB:-256}
BENCH_SPRING_HEAP_MB=${BENCH_SPRING_HEAP_MB:-1280}
BENCH_QUARKUS_HEAP_MB=${BENCH_QUARKUS_HEAP_MB:-1280}
BENCH_CONTRACT_ID=${BENCH_CONTRACT_ID:-fixed_contract_cross_runtime_h1_v1}
BENCH_CONNECTIONS=${BENCH_CONNECTIONS:-}
BENCH_THREADS=${BENCH_THREADS:-}
BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS=${BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS:-1}
BENCH_JFR_SETTINGS=${BENCH_JFR_SETTINGS:-profile}
# COMPLETENESS (BUG 4b): the diagnostic JFR is a size-rotated recording (maxsize). At 512MB
# it kept only a tail (~39s light / ~3.5min heavy) — an incomplete slice of the measurement
# window. Default raised so the FULL window is retained without rotation, yielding a COMPLETE
# recording for every arm. This is a non-rotating CEILING, not a fixed file size: the dump is
# still only the actual recorded data (~2-3GB/target light, <1GB heavy), so heavy runs are
# unchanged. Env-overridable. NOTE: complete light recordings are ~2-3GB each — ensure disk
# headroom across the campaign (or lower BENCH_RUNS_PER_PAIR) since every leaf dumps per target.
BENCH_JFR_MAX_SIZE_MB=${BENCH_JFR_MAX_SIZE_MB:-6144}
BENCH_JFR_VTHREAD_PINNED=${BENCH_JFR_VTHREAD_PINNED:-0}
BENCH_ENABLE_NATIVE_MEMORY_TRACKING=${BENCH_ENABLE_NATIVE_MEMORY_TRACKING:-1}
BENCH_NATIVE_MEMORY_TRACKING_LEVEL=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL:-summary}
BENCH_REQUIRE_PERF_STAT=${BENCH_REQUIRE_PERF_STAT:-${BENCHMARK_REQUIRE_PERF_STAT:-0}}

export BENCHMARK_REQUIRE_PERF_STAT="$BENCH_REQUIRE_PERF_STAT"

STEP_COUNTER=0
TOTAL_STEPS=120

triad_constrained_execution_profile_id() {
  local execution_profile_id="${1:-}"
  [[ -n "$execution_profile_id" && "$execution_profile_id" == runtime-constrained-* ]]
}

triad_constrained_track_id() {
  local track_id="${1:-}"
  [[ -n "$track_id" && "$track_id" == track-c* ]]
}

triad_constrained_path() {
  local path_value="${1:-}"
  [[ -n "$path_value" && ( "$path_value" == */results/constrained/* || "$path_value" == results/constrained/* ) ]]
}

triad_fail_closed_if_constrained() {
  if triad_constrained_execution_profile_id "${BENCHMARK_EXECUTION_PROFILE_ID:-}" || \
     triad_constrained_track_id "${BENCHMARK_TRACK_ID:-}" || \
     triad_constrained_path "$CAMPAIGN_OUTPUT_DIR"; then
    echo "ERROR: full triad comparative workflow cannot be used for constrained exploratory profiles" >&2
    exit 1
  fi
}

triad_fail_closed_if_constrained

validate_positive_integer() {
  local value=$1
  local label=$2

  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value <= 0 )); then
    echo "ERROR: ${label} must be a positive integer, got: ${value}"
    return 1
  fi

  return 0
}

validate_binary_flag() {
  local value=$1
  local label=$2

  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "ERROR: ${label} must be 0 or 1, got: ${value}"
    return 1
  fi

  return 0
}

json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

capture_campaign_env() {
  local output_path="${CAMPAIGN_OUTPUT_DIR}/campaign-env.json"

  if [[ ! -x "${REPO_ROOT}/scripts/capture-env.sh" ]]; then
    echo "ERROR: ./scripts/capture-env.sh not found or not executable"
    return 1
  fi

  ./scripts/capture-env.sh --profile "$HARDWARE_PROFILE" --tool wrk > "$output_path"
  echo "Campaign environment JSON: ${output_path}"
}

capture_campaign_cgroup_limits() {
  local output_path="${CAMPAIGN_OUTPUT_DIR}/campaign-cgroup-limits.json"
  local generated_at_utc=""
  local cgroup_version="unknown"
  local cpu_max="unknown"
  local cpu_cfs_quota_us="unknown"
  local cpu_cfs_period_us="unknown"
  local cpuset_effective="unknown"
  local memory_max="unknown"
  local memory_current="unknown"

  generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    cgroup_version="v2"
    cpu_max="$(tr -d '\n' < /sys/fs/cgroup/cpu.max 2>/dev/null || echo 'unknown')"
    cpuset_effective="$(tr -d '\n' < /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo 'unknown')"
    memory_max="$(tr -d '\n' < /sys/fs/cgroup/memory.max 2>/dev/null || echo 'unknown')"
    memory_current="$(tr -d '\n' < /sys/fs/cgroup/memory.current 2>/dev/null || echo 'unknown')"
  elif [[ -d /sys/fs/cgroup/cpu ]]; then
    cgroup_version="v1"
    cpu_cfs_quota_us="$(tr -d '\n' < /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo 'unknown')"
    cpu_cfs_period_us="$(tr -d '\n' < /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 'unknown')"
    cpuset_effective="$(tr -d '\n' < /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null || echo 'unknown')"
    memory_max="$(tr -d '\n' < /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 'unknown')"
    memory_current="$(tr -d '\n' < /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 'unknown')"
  fi

  cat > "$output_path" <<EOF
{
  "generated_at_utc": "${generated_at_utc}",
  "cgroup_version": "$(printf '%s' "$cgroup_version" | json_escape)",
  "cpu_max": "$(printf '%s' "$cpu_max" | json_escape)",
  "cpu_cfs_quota_us": "$(printf '%s' "$cpu_cfs_quota_us" | json_escape)",
  "cpu_cfs_period_us": "$(printf '%s' "$cpu_cfs_period_us" | json_escape)",
  "cpuset_effective": "$(printf '%s' "$cpuset_effective" | json_escape)",
  "memory_max": "$(printf '%s' "$memory_max" | json_escape)",
  "memory_current": "$(printf '%s' "$memory_current" | json_escape)"
}
EOF

  echo "Campaign cgroup limits JSON: ${output_path}"
}

apply_fair_resource_profile() {
  local exeris_headroom=0
  local spring_headroom=0
  local quarkus_headroom=0
  local native_memory_tracking_enabled=false
  local generated_at_utc=""
  local profile_path="${CAMPAIGN_OUTPUT_DIR}/resource-profile.json"
  local diagnostics_dir="${CAMPAIGN_OUTPUT_DIR}/diagnostics"
  local startup_options_manifest="${diagnostics_dir}/jvm-startup-options.json"
  local exeris_safepoint_log="${diagnostics_dir}/exeris-community.safepoint.log"
  local spring_safepoint_log="${diagnostics_dir}/spring-hibernate.safepoint.log"
  local quarkus_safepoint_log="${diagnostics_dir}/quarkus-hibernate.safepoint.log"
  local exeris_jfr_file="${diagnostics_dir}/exeris-community.jfr"
  local spring_jfr_file="${diagnostics_dir}/spring-hibernate.jfr"
  local quarkus_jfr_file="${diagnostics_dir}/quarkus-hibernate.jfr"
  local jfr_settings="${BENCH_JFR_SETTINGS}"

  validate_positive_integer "$BENCH_TOTAL_MEMORY_MB" "BENCH_TOTAL_MEMORY_MB" || return 1
  validate_positive_integer "$BENCH_EXERIS_HEAP_MB" "BENCH_EXERIS_HEAP_MB" || return 1
  validate_positive_integer "$BENCH_SPRING_HEAP_MB" "BENCH_SPRING_HEAP_MB" || return 1
  validate_positive_integer "$BENCH_QUARKUS_HEAP_MB" "BENCH_QUARKUS_HEAP_MB" || return 1
  validate_binary_flag "$BENCH_REQUIRE_PERF_STAT" "BENCH_REQUIRE_PERF_STAT" || return 1

  if (( BENCH_EXERIS_HEAP_MB >= BENCH_TOTAL_MEMORY_MB )); then
    echo "ERROR: BENCH_EXERIS_HEAP_MB must be less than BENCH_TOTAL_MEMORY_MB"
    return 1
  fi
  if (( BENCH_SPRING_HEAP_MB >= BENCH_TOTAL_MEMORY_MB )); then
    echo "ERROR: BENCH_SPRING_HEAP_MB must be less than BENCH_TOTAL_MEMORY_MB"
    return 1
  fi
  if (( BENCH_QUARKUS_HEAP_MB >= BENCH_TOTAL_MEMORY_MB )); then
    echo "ERROR: BENCH_QUARKUS_HEAP_MB must be less than BENCH_TOTAL_MEMORY_MB"
    return 1
  fi

  exeris_headroom=$((BENCH_TOTAL_MEMORY_MB - BENCH_EXERIS_HEAP_MB))
  spring_headroom=$((BENCH_TOTAL_MEMORY_MB - BENCH_SPRING_HEAP_MB))
  quarkus_headroom=$((BENCH_TOTAL_MEMORY_MB - BENCH_QUARKUS_HEAP_MB))

  export EXERIS_DB_POOL_MIN_SIZE="$BENCH_DB_POOL_MIN_SIZE"
  export EXERIS_DB_POOL_MAX_SIZE="$BENCH_DB_POOL_MAX_SIZE"
  export SERVER_CPU_AFFINITY="$BENCH_SERVER_CPU_AFFINITY"
  export LOADGEN_CPU_AFFINITY="$BENCH_LOADGEN_CPU_AFFINITY"

  # FAIRNESS (BUG 4a): the Exeris telemetry subsystem (and its telemetry-JFR emission) is an
  # Exeris-only overhead that spring/quarkus do not pay; enabling it on the Exeris arm would
  # bias the cross-runtime comparison. Env defaults are already false, but enforce it here so
  # an inherited/exported truthy value cannot defeat it. Unconditional (overrides any inherited
  # value); harmless no-op for the spring/quarkus arms, which ignore these vars.
  export EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false
  export EXERIS_TELEMETRY_JFR_ENABLED=false
  export EXERIS_JAVA_OPTS="-Xms${BENCH_EXERIS_HEAP_MB}m -Xmx${BENCH_EXERIS_HEAP_MB}m -XX:MaxRAM=${BENCH_TOTAL_MEMORY_MB}m"
  export SPRING_JAVA_OPTS="-Xms${BENCH_SPRING_HEAP_MB}m -Xmx${BENCH_SPRING_HEAP_MB}m -XX:MaxRAM=${BENCH_TOTAL_MEMORY_MB}m"
  export QUARKUS_JAVA_OPTS="-Xms${BENCH_QUARKUS_HEAP_MB}m -Xmx${BENCH_QUARKUS_HEAP_MB}m -XX:MaxRAM=${BENCH_TOTAL_MEMORY_MB}m"

  if [[ "$BENCH_ENABLE_NATIVE_MEMORY_TRACKING" == "1" ]]; then
    native_memory_tracking_enabled=true
    export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS} -XX:NativeMemoryTracking=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL}"
    export SPRING_JAVA_OPTS="${SPRING_JAVA_OPTS} -XX:NativeMemoryTracking=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL}"
    export QUARKUS_JAVA_OPTS="${QUARKUS_JAVA_OPTS} -XX:NativeMemoryTracking=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL}"
  fi

  if [[ "$BENCH_JFR_VTHREAD_PINNED" == "1" ]]; then
    local vthread_jfc="${REPO_ROOT}/env/jfr-vthread-pinned-override.jfc"
    if [[ ! -f "$vthread_jfc" ]]; then
      echo "ERROR: BENCH_JFR_VTHREAD_PINNED=1 but JFC override file not found: ${vthread_jfc}"
      return 1
    fi
    jfr_settings="${jfr_settings},settings=${vthread_jfc}"
    export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS} -Djdk.tracePinnedThreads=full"
    export SPRING_JAVA_OPTS="${SPRING_JAVA_OPTS} -Djdk.tracePinnedThreads=full"
    export QUARKUS_JAVA_OPTS="${QUARKUS_JAVA_OPTS} -Djdk.tracePinnedThreads=full"
    export EXERIS_JFR_VTHREAD_PINNED=true
    echo "VirtualThread pinning diagnostics enabled: jdk.VirtualThreadPinned + tracePinnedThreads=full"
  fi

  # Additive steady-state compiler telemetry (opt-in, default OFF). Merged into the
  # shared jfr_settings so all three targets record it symmetrically — a fairness
  # requirement, since an asymmetric JFR overlay would bias one runtime's profile.
  # BENCH_JFR_STEADY_STATE=1 uses env/jfr-steady-state.jfc; BENCH_JFR_EXTRA_SETTINGS
  # overrides with a custom overlay. See docs/methodology.md.
  if [[ -n "${BENCH_JFR_EXTRA_SETTINGS:-}" ]]; then
    # The value is spliced verbatim into each target's StartFlightRecording
    # settings=, and JFR resolves a relative path against the TARGET JVM's CWD
    # (a target module dir, not the repo root) — so a bare 'env/foo.jfc' would
    # silently fail to load there. Absolutize against REPO_ROOT and verify it
    # exists, mirroring the vthread/steady overlays above.
    local extra_jfc="${BENCH_JFR_EXTRA_SETTINGS}"
    if [[ "$extra_jfc" != /* ]]; then
      extra_jfc="${REPO_ROOT}/${extra_jfc}"
    fi
    if [[ ! -f "$extra_jfc" ]]; then
      echo "ERROR: BENCH_JFR_EXTRA_SETTINGS set but overlay file not found: ${extra_jfc}" >&2
      return 1
    fi
    jfr_settings="${jfr_settings},settings=${extra_jfc}"
    echo "Steady-state JFR overlay (custom): ${extra_jfc}"
  elif [[ "${BENCH_JFR_STEADY_STATE:-0}" == "1" ]]; then
    local steady_jfc="${REPO_ROOT}/env/jfr-steady-state.jfc"
    if [[ ! -f "$steady_jfc" ]]; then
      echo "ERROR: BENCH_JFR_STEADY_STATE=1 but overlay file not found: ${steady_jfc}" >&2
      return 1
    fi
    jfr_settings="${jfr_settings},settings=${steady_jfc}"
    echo "Steady-state JFR overlay enabled: ${steady_jfc} (CompilerStatistics/QueueUtilization/Compilation)"
  fi

  if [[ "$BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS" == "1" ]]; then
    validate_positive_integer "$BENCH_JFR_MAX_SIZE_MB" "BENCH_JFR_MAX_SIZE_MB" || return 1

    mkdir -p "$diagnostics_dir"

    export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS} -Xlog:safepoint=debug:file=${exeris_safepoint_log}:time,level,tags -XX:StartFlightRecording=filename=${exeris_jfr_file},settings=${jfr_settings},maxsize=${BENCH_JFR_MAX_SIZE_MB}m,dumponexit=true"
    export SPRING_JAVA_OPTS="${SPRING_JAVA_OPTS} -Xlog:safepoint=debug:file=${spring_safepoint_log}:time,level,tags -XX:StartFlightRecording=filename=${spring_jfr_file},settings=${jfr_settings},maxsize=${BENCH_JFR_MAX_SIZE_MB}m,dumponexit=true"
    export QUARKUS_JAVA_OPTS="${QUARKUS_JAVA_OPTS} -Xlog:safepoint=debug:file=${quarkus_safepoint_log}:time,level,tags -XX:StartFlightRecording=filename=${quarkus_jfr_file},settings=${jfr_settings},maxsize=${BENCH_JFR_MAX_SIZE_MB}m,dumponexit=true"

    generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$startup_options_manifest" <<EOF
{
  "generated_at_utc": "${generated_at_utc}",
  "diagnostics_enabled": true,
  "require_perf_stat": ${BENCH_REQUIRE_PERF_STAT},
  "loadgen_cpu_affinity": "$(printf '%s' "$LOADGEN_CPU_AFFINITY" | json_escape)",
  "native_memory_tracking_enabled": ${native_memory_tracking_enabled},
  "native_memory_tracking_level": "$(printf '%s' "$BENCH_NATIVE_MEMORY_TRACKING_LEVEL" | json_escape)",
  "jfr_settings": "$(printf '%s' "$jfr_settings" | json_escape)",
  "jfr_max_size_mb": ${BENCH_JFR_MAX_SIZE_MB},
  "jfr_recording_complete_non_rotated": true,
  "exeris_telemetry_subsystem_enabled": false,
  "exeris_telemetry_jfr_enabled": false,
  "targets": {
    "exeris-community": {
      "java_opts": "$(printf '%s' "$EXERIS_JAVA_OPTS" | json_escape)",
      "safepoint_log": "$(printf '%s' "$exeris_safepoint_log" | json_escape)",
      "jfr_file": "$(printf '%s' "$exeris_jfr_file" | json_escape)"
    },
    "spring-hibernate": {
      "java_opts": "$(printf '%s' "$SPRING_JAVA_OPTS" | json_escape)",
      "safepoint_log": "$(printf '%s' "$spring_safepoint_log" | json_escape)",
      "jfr_file": "$(printf '%s' "$spring_jfr_file" | json_escape)"
    },
    "quarkus-hibernate": {
      "java_opts": "$(printf '%s' "$QUARKUS_JAVA_OPTS" | json_escape)",
      "safepoint_log": "$(printf '%s' "$quarkus_safepoint_log" | json_escape)",
      "jfr_file": "$(printf '%s' "$quarkus_jfr_file" | json_escape)"
    }
  }
}
EOF

    echo "Diagnostics enabled: safepoint logs + JFR startup recordings"
    echo "JVM startup options manifest: ${startup_options_manifest}"
  fi

  generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > "$profile_path" <<EOF
{
  "total_memory_mb": ${BENCH_TOTAL_MEMORY_MB},
  "db_pool_min": ${BENCH_DB_POOL_MIN_SIZE},
  "db_pool_max": ${BENCH_DB_POOL_MAX_SIZE},
  "require_perf_stat": ${BENCH_REQUIRE_PERF_STAT},
  "exeris_telemetry_subsystem_enabled": false,
  "exeris_telemetry_jfr_enabled": false,
  "server_cpu_affinity": "${SERVER_CPU_AFFINITY}",
  "loadgen_cpu_affinity": "$(printf '%s' "$LOADGEN_CPU_AFFINITY" | json_escape)",
  "native_memory_tracking_enabled": ${native_memory_tracking_enabled},
  "native_memory_tracking_level": "$(printf '%s' "$BENCH_NATIVE_MEMORY_TRACKING_LEVEL" | json_escape)",
  "exeris_heap_mb": ${BENCH_EXERIS_HEAP_MB},
  "spring_heap_mb": ${BENCH_SPRING_HEAP_MB},
  "quarkus_heap_mb": ${BENCH_QUARKUS_HEAP_MB},
  "exeris_non_heap_headroom_mb": ${exeris_headroom},
  "spring_non_heap_headroom_mb": ${spring_headroom},
  "quarkus_non_heap_headroom_mb": ${quarkus_headroom},
  "generated_at_utc": "${generated_at_utc}"
}
EOF

  echo "Fairness profile: total=${BENCH_TOTAL_MEMORY_MB}MB | DB pool ${BENCH_DB_POOL_MIN_SIZE}-${BENCH_DB_POOL_MAX_SIZE} | CPU affinity=${SERVER_CPU_AFFINITY:-none}"
  echo "NMT: enabled=${native_memory_tracking_enabled} level=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL}"
  echo "Heap/Headroom MB: exeris=${BENCH_EXERIS_HEAP_MB}/${exeris_headroom}, spring=${BENCH_SPRING_HEAP_MB}/${spring_headroom}, quarkus=${BENCH_QUARKUS_HEAP_MB}/${quarkus_headroom}"
  echo "Resource profile JSON: ${profile_path}"

  return 0
}

wait_for_http_200() {
  local target_id=$1
  local url=$2
  local label=$3
  local max_wait_seconds=${4:-60}
  wait_for_http_200_with_metrics "$target_id" "$url" "$label" "$max_wait_seconds"
}

is_target_healthy() {
  local target_id=$1
  local port=$2
  local health_url="http://127.0.0.1:${port}/health"
  local code=""

  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 "$health_url" || true)
  [[ "$code" == "200" ]]
}

prepare_scenario_infrastructure() {
  local scenario_diagnostics_dir=${1:-}

  echo "Preparing scenario infrastructure for ${SCENARIO_ID}..."

  if [[ ! -f "$SCENARIO_INFRA_SCRIPT" ]]; then
    echo "WARNING: Scenario infrastructure script missing: ${SCENARIO_INFRA_SCRIPT}"
    return 1
  fi

  if [[ -n "$scenario_diagnostics_dir" ]]; then
    mkdir -p "$scenario_diagnostics_dir"
  fi

  if ! BENCH_SCENARIO_DIAGNOSTICS_DIR="$scenario_diagnostics_dir" \
       BENCH_CAPTURE_DB_EXPLAIN="${BENCH_CAPTURE_DB_EXPLAIN:-0}" \
       bash "$SCENARIO_INFRA_SCRIPT"; then
    echo "ERROR: Scenario infrastructure setup failed for ${SCENARIO_ID}"
    return 1
  fi

  echo "Scenario infrastructure ready for ${SCENARIO_ID}"
  return 0
}

wait_for_http_200_with_metrics() {
  local target_id=$1
  local url=$2
  local label=$3
  local max_wait_seconds=${4:-60}

  WAIT_HTTP_200_UTC=""
  WAIT_HTTP_200_EPOCH_MS=""
  WAIT_HTTP_200_ATTEMPTS=""
  WAIT_HTTP_200_ELAPSED_SECONDS=""

  if ! bench_wait_for_http_200_with_metrics "$target_id" "$url" "$label" "$max_wait_seconds"; then
    return 1
  fi

  WAIT_HTTP_200_UTC="$BENCH_WAIT_HTTP_200_UTC"
  WAIT_HTTP_200_EPOCH_MS="$BENCH_WAIT_HTTP_200_EPOCH_MS"
  WAIT_HTTP_200_ATTEMPTS="$BENCH_WAIT_HTTP_200_ATTEMPTS"
  WAIT_HTTP_200_ELAPSED_SECONDS="$BENCH_WAIT_HTTP_200_ELAPSED_SECONDS"
  return 0
}

detect_pid_for_port() {
  local port=$1
  local pid=""

  pid=$(lsof -ti ":${port}" 2>/dev/null | head -n 1 || true)
  if [[ -n "$pid" ]]; then
    echo "$pid"
    return 0
  fi

  pid=$(ss -tlnpH 2>/dev/null | awk -v port=":${port}" '
    $4 ~ port"$" {
      if (match($0, /pid=([0-9]+)/, m)) {
        print m[1]
        exit
      }
    }
  ' || true)
  if [[ -n "$pid" ]]; then
    echo "$pid"
    return 0
  fi

  return 1
}

capture_runtime_jvm_diagnostics() {
  local target_id=$1
  local port=$2
  local startup_sequence_dir=$3
  local pid=""
  local capture_utc=""
  local metadata_path="${startup_sequence_dir}/${target_id}.jvm-diagnostics.json"
  local vm_flags_path="${startup_sequence_dir}/${target_id}.jcmd-vm.flags.txt"
  local vm_command_line_path="${startup_sequence_dir}/${target_id}.jcmd-vm.command_line.txt"
  local jfr_check_path="${startup_sequence_dir}/${target_id}.jcmd-jfr.check.txt"
  local vm_flags_status="skipped"
  local vm_command_line_status="skipped"
  local jfr_check_status="skipped"
  local jcmd_available="false"
  local pid_json="null"

  mkdir -p "$startup_sequence_dir"
  capture_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  pid=$(detect_pid_for_port "$port" 2>/dev/null || true)

  if command -v jcmd >/dev/null 2>&1; then
    jcmd_available="true"
  fi

  if [[ "$jcmd_available" == "true" && -n "$pid" ]]; then
    if jcmd "$pid" VM.flags > "$vm_flags_path" 2>&1; then
      vm_flags_status="captured"
    else
      vm_flags_status="failed"
    fi

    if jcmd "$pid" VM.command_line > "$vm_command_line_path" 2>&1; then
      vm_command_line_status="captured"
    else
      vm_command_line_status="failed"
    fi

    if jcmd "$pid" JFR.check > "$jfr_check_path" 2>&1; then
      jfr_check_status="captured"
    else
      jfr_check_status="failed"
    fi
  fi

  if [[ -n "$pid" ]]; then
    pid_json="$pid"
  fi

  cat > "$metadata_path" <<EOF
{
  "target_id": "$(printf '%s' "$target_id" | json_escape)",
  "pid": ${pid_json},
  "capture_utc": "${capture_utc}",
  "jcmd_available": ${jcmd_available},
  "captures": {
    "vm_flags": {
      "path": "$(printf '%s' "$vm_flags_path" | json_escape)",
      "status": "${vm_flags_status}"
    },
    "vm_command_line": {
      "path": "$(printf '%s' "$vm_command_line_path" | json_escape)",
      "status": "${vm_command_line_status}"
    },
    "jfr_check": {
      "path": "$(printf '%s' "$jfr_check_path" | json_escape)",
      "status": "${jfr_check_status}"
    }
  }
}
EOF

  return 0
}

force_free_port() {
  local target_id=$1
  local port=$2
  local pid=""
  local still_pid=""
  local i=0

  pid=$(detect_pid_for_port "$port" 2>/dev/null || true)
  if [[ -z "$pid" ]]; then
    return 0
  fi

  echo "WARNING: Target ${target_id} port ${port} is occupied by pid ${pid}; attempting to free it"

  kill -TERM "$pid" >/dev/null 2>&1 || true

  for ((i=0; i<10; i++)); do
    sleep 1
    still_pid=$(detect_pid_for_port "$port" 2>/dev/null || true)
    if [[ -z "$still_pid" ]]; then
      return 0
    fi
  done

  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi

  for ((i=0; i<5; i++)); do
    sleep 1
    still_pid=$(detect_pid_for_port "$port" 2>/dev/null || true)
    if [[ -z "$still_pid" ]]; then
      return 0
    fi
  done

  still_pid=$(detect_pid_for_port "$port" 2>/dev/null || true)
  echo "ERROR: Target ${target_id} port ${port} is still occupied after TERM/KILL (pid: ${still_pid:-unknown})"
  return 1
}

# Tear down BOTH targets of a pair once the pair block is done. A pair's target
# JVMs keep their JDBC connection pools open for the whole block; if they are
# left running, the NEXT pair's prepare_scenario_infrastructure psql hits the
# shared Postgres 'sorry, too many clients already' ceiling (max_connections)
# because the previous pair's pools are still connected. Stopping here releases
# those connections before the next pair's infra setup, and leaves a clean box
# after the last pair. stop-target is by id (graceful); force_free_port is the
# hard port-based backstop in case stop-target does not fully reap the JVM.
stop_pair_targets() {
  local ta=$1 ta_port=$2 tb=$3 tb_port=$4
  echo "  [teardown] Stopping pair targets ${ta} (:${ta_port}) and ${tb} (:${tb_port}) to release DB connections..."
  "$TARGET_STOP_SCRIPT" "$ta" >/dev/null 2>&1 || true
  "$TARGET_STOP_SCRIPT" "$tb" >/dev/null 2>&1 || true
  force_free_port "$ta" "$ta_port" || true
  force_free_port "$tb" "$tb_port" || true
}

ensure_target_on_endpoint() {
  local target_id=$1
  local port=$2
  local artifact_path=${3:-}
  local base_url="http://127.0.0.1:${port}"
  local health_url="${base_url}/health"
  local endpoint_url="${base_url}${SCENARIO_ENDPOINT_PATH}"
  local startup_init_utc=""
  local startup_init_epoch_ms=""
  local health_ready_utc=""
  local health_ready_epoch_ms=""
  local health_attempts=""
  local first_request_utc=""
  local first_request_epoch_ms=""
  local first_request_attempts=""
  local startup_to_health_ms=""
  local startup_to_first_request_ms=""
  local health_to_first_request_ms=""
  local generated_at_utc=""

  if [[ ! -x "$TARGET_START_SCRIPT" ]]; then
    echo "ERROR: Target ${target_id} cannot be started because script is not executable: ${TARGET_START_SCRIPT}"
    return 1
  fi

  if [[ ! -x "$TARGET_STOP_SCRIPT" ]]; then
    echo "ERROR: Target ${target_id} cannot be stopped because script is not executable: ${TARGET_STOP_SCRIPT}"
    return 1
  fi

  "$TARGET_STOP_SCRIPT" "$target_id" >/dev/null 2>&1 || true

  force_free_port "$target_id" "$port" || return 1

  startup_init_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  startup_init_epoch_ms=$(date -u +%s%3N)

  if ! "$TARGET_START_SCRIPT" "$target_id"; then
    echo "ERROR: Failed to start target ${target_id} with ${TARGET_START_SCRIPT}"
    return 1
  fi

  wait_for_http_200_with_metrics "$target_id" "$health_url" "/health" 60 || return 1
  health_ready_utc="$WAIT_HTTP_200_UTC"
  health_ready_epoch_ms="$WAIT_HTTP_200_EPOCH_MS"
  health_attempts="$WAIT_HTTP_200_ATTEMPTS"

  wait_for_http_200_with_metrics "$target_id" "$endpoint_url" "$SCENARIO_ENDPOINT_PATH" 60 || return 1
  first_request_utc="$WAIT_HTTP_200_UTC"
  first_request_epoch_ms="$WAIT_HTTP_200_EPOCH_MS"
  first_request_attempts="$WAIT_HTTP_200_ATTEMPTS"

  startup_to_health_ms=$((health_ready_epoch_ms - startup_init_epoch_ms))
  startup_to_first_request_ms=$((first_request_epoch_ms - startup_init_epoch_ms))
  health_to_first_request_ms=$((first_request_epoch_ms - health_ready_epoch_ms))

  if [[ -n "$artifact_path" ]]; then
    mkdir -p "$(dirname "$artifact_path")"
    generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$artifact_path" <<EOF
{
  "target_id": "${target_id}",
  "port": ${port},
  "scenario_endpoint_path": "${SCENARIO_ENDPOINT_PATH}",
  "startup_init_utc": "${startup_init_utc}",
  "health_ready_utc": "${health_ready_utc}",
  "first_request_utc": "${first_request_utc}",
  "startup_to_health_ms": ${startup_to_health_ms},
  "startup_to_first_request_ms": ${startup_to_first_request_ms},
  "health_to_first_request_ms": ${health_to_first_request_ms},
  "health_attempts": ${health_attempts},
  "first_request_attempts": ${first_request_attempts},
  "generated_at_utc": "${generated_at_utc}"
}
EOF
  fi

  return 0
}

ensure_target_healthy_or_recover() {
  local target_id=$1
  local port=$2
  local artifact_path=${3:-}

  if is_target_healthy "$target_id" "$port"; then
    return 0
  fi

  echo "WARNING: Target ${target_id} is not healthy on port ${port}; attempting recovery (restart + readiness)"
  ensure_target_on_endpoint "$target_id" "$port" "$artifact_path"
}

build_target_artifact() {
  local target_id=$1
  local module_path=""
  local pom_path=""
  # Empty for every pre-existing target: build with the module pom's own exeris.kernel.version
  # and leave the artifact where it lands. Non-empty only for the serialisation-matrix arms,
  # which pin a kernel version and stage the jar under a version-qualified name.
  local kernel_version=""

  case "$target_id" in
    exeris-community)
      module_path="targets/exeris-community-app"
      ;;
    exeris-blackbird)
      # Same app jar as exeris-community (kernel 0.10.1) PLUS the ADR-052 Blackbird customizer
      # uber-jar, added to the launch classpath by runtime/drivers/env/exeris-community-blackbird.env.
      # Build the customizer module first, then fall through to build the shared app jar.
      echo "[PREBUILD] Building blackbird customizer (targets/exeris-community-blackbird-customizer)..."
      if ! mvn -q -f "targets/exeris-community-blackbird-customizer/pom.xml" -DskipTests package; then
        echo "[PREBUILD] ERROR: Build failed for blackbird customizer"
        return 1
      fi
      module_path="targets/exeris-community-app"
      ;;
    exeris-k0101|exeris-k0101-bb|exeris-k0102|exeris-k0102-bb)
      # Serialisation-matrix arms (2x2: kernel version x Blackbird accessor). Same app module as
      # exeris-community, but built against a PINNED kernel version and staged under a
      # version-qualified name. Without the pin+stage, prebuild would build every target in turn
      # and the 0.10.2 build would overwrite the 0.10.1 jar at the identical path — every arm would
      # then launch whichever version was built last. Four campaigns, one runtime, no error raised.
      case "$target_id" in
        exeris-k0101*) kernel_version="0.10.1" ;;
        exeris-k0102*) kernel_version="0.10.2" ;;
      esac
      if [[ "$target_id" == *-bb ]]; then
        # Seam verified identical between v0.10.1 and v0.10.2 (zero commits touching
        # */community/json/*), so ONE customizer jar serves both versions.
        echo "[PREBUILD] Building blackbird customizer for ${target_id}..."
        if ! mvn -q -f "targets/exeris-community-blackbird-customizer/pom.xml" -DskipTests package; then
          echo "[PREBUILD] ERROR: Build failed for blackbird customizer"
          return 1
        fi
      fi
      module_path="targets/exeris-community-app"
      ;;
    spring-hibernate)
      module_path="targets/spring-benchmark-app"
      ;;
    quarkus-hibernate)
      module_path="targets/quarkus-benchmark-app"
      ;;
    quarkus-tuned)
      module_path="targets/quarkus-benchmark-app-tuned"
      ;;
    spring-on-exeris)
      module_path="targets/exeris-spring-runtime-app-comp"
      ;;
    spring-on-exeris-pure)
      # Third arm of the Spring hosting comparison: same app, Exeris NATIVE web layer
      # (@ExerisRoute) instead of the compatibility dispatcher. Must be rebuilt whenever
      # spring-on-exeris is — the two are the arms of the compat-seam pair and share a
      # runtime (and therefore a kernel) version; building one alone puts a kernel-version
      # difference inside a measurement meant to isolate the dispatcher.
      module_path="targets/exeris-spring-runtime-app-pure"
      ;;
    *)
      echo "ERROR: No Maven module mapping defined for target ${target_id}"
      return 1
      ;;
  esac

  pom_path="${module_path}/pom.xml"

  local staged_jar=""
  if [[ -n "$kernel_version" ]]; then
    staged_jar="targets/_staging/exeris-community-app-k${kernel_version}.jar"
    # exeris-kXXXX and exeris-kXXXX-bb share one jar (the customizer is a classpath toggle, not a
    # different build), so the second arm of a version reuses the first arm's artifact. Keyed on
    # what THIS campaign built, never on file existence — a leftover jar from an earlier run must
    # not be silently reused, which is exactly the stale-artifact failure this task exists to prevent.
    if [[ " ${PREBUILT_KERNEL_VERSIONS:-} " == *" ${kernel_version} "* ]]; then
      echo "[PREBUILD] Reusing artifact staged earlier in this campaign: ${staged_jar}"
      echo "[PREBUILD] Build completed for ${target_id}"
      return 0
    fi
  fi

  local -a mvn_args=(-q -f "$pom_path" -DskipTests package)
  if [[ -n "$kernel_version" ]]; then
    mvn_args+=("-Dexeris.kernel.version=${kernel_version}")
    echo "[PREBUILD] Building ${target_id} from module ${module_path} (kernel pinned to ${kernel_version})..."
  else
    echo "[PREBUILD] Building ${target_id} from module ${module_path}..."
  fi

  if ! mvn "${mvn_args[@]}"; then
    echo "[PREBUILD] ERROR: Build failed for ${target_id} using module-local pom ${pom_path}; missing root reactor is intentionally avoided"
    return 1
  fi

  if [[ -n "$staged_jar" ]]; then
    mkdir -p targets/_staging
    if ! cp -f "${module_path}/target/exeris-community-app-1.0.0-SNAPSHOT.jar" "$staged_jar"; then
      echo "[PREBUILD] ERROR: Could not stage ${target_id} artifact to ${staged_jar}"
      return 1
    fi
    PREBUILT_KERNEL_VERSIONS="${PREBUILT_KERNEL_VERSIONS:-} ${kernel_version}"
    echo "[PREBUILD] Staged ${target_id} -> ${staged_jar} (kernel ${kernel_version})"
  fi

  echo "[PREBUILD] Build completed for ${target_id}"

  return 0
}

prebuild_campaign_targets() {
  echo ""
  echo "============================================================"
  echo "PREBUILD CAMPAIGN TARGET ARTIFACTS"
  echo "============================================================"

  # Build exactly the targets referenced by the effective pair set (deduped),
  # so a non-default BENCH_TRIAD_PAIRS (e.g. the quarkus-focused triad with
  # quarkus-tuned) builds the right modules and skips unused ones.
  local entry _name _ta _tb _label _pa _pb t
  declare -A _built=()
  for entry in "${TRIAD_PAIRS[@]}"; do
    IFS=':' read -r _name _ta _tb _label _pa _pb <<< "$entry"
    for t in "$_ta" "$_tb"; do
      if [[ -z "${_built[$t]:-}" ]]; then
        _built[$t]=1
        build_target_artifact "$t" || return 1
      fi
    done
  done

  echo "============================================================"
  echo "PREBUILD COMPLETED"
  echo "============================================================"

  return 0
}

run_benchmark() {
  local pair_name=$1
  local target_a=$2
  local target_b=$3
  local order=$4
  local step=$5
  local run_num=$6
  local scenario_diagnostics_dir=$7
  local output_subdir="${CAMPAIGN_OUTPUT_DIR}/${pair_name}/run$(printf '%02d' "$run_num")/${order}"
  local track_id="track-${order}-$(printf '%02d' "$run_num")"
  local -a comparative_args=(
    --target-a "$target_a"
    --target-b "$target_b"
    --scenario-id "$SCENARIO_ID"
    --contract-id "$BENCH_CONTRACT_ID"
    --warmup-seconds "${WARMUP_SECONDS:-60}"
    --measurement-seconds "${MEASUREMENT_SECONDS:-120}"
    --output-dir "$output_subdir"
  )

  if [[ -n "$BENCH_CONNECTIONS" ]]; then
    comparative_args+=(--connections "$BENCH_CONNECTIONS")
  fi

  if [[ -n "$BENCH_THREADS" ]]; then
    comparative_args+=(--threads "$BENCH_THREADS")
  fi
  
  mkdir -p "$output_subdir"
  
  echo "[$step/$TOTAL_STEPS] [RUN $(printf '%02d' "$run_num")] ${pair_name} - ${order}"
  set +e
  BENCH_SKIP_SCENARIO_INFRA_SETUP=1 BENCH_SCENARIO_DIAGNOSTICS_DIR="$scenario_diagnostics_dir" BENCHMARK_REQUIRE_PERF_STAT="$BENCH_REQUIRE_PERF_STAT" BENCHMARK_PAIR_ORDER="$order" BENCHMARK_AB_BA_ORDERS_COMPLETED="ab,ba" BENCHMARK_TRACK_ID="$track_id" \
    ./scripts/run-comparative.sh "${comparative_args[@]}" 2>&1 | tee -a "$output_subdir/run.log"
  local -a pipe_statuses=("${PIPESTATUS[@]}")
  local comparative_status="${pipe_statuses[0]:-1}"
  local tee_status="${pipe_statuses[1]:-0}"
  set -e

  if [[ $comparative_status -ne 0 || $tee_status -ne 0 ]]; then
    echo "WARNING: Step [$step/$TOTAL_STEPS] [RUN $(printf '%02d' "$run_num")] ${pair_name} (${order}) failed"
    echo "Run log: $output_subdir/run.log"
    return 1
  fi
  return 0
}

run_pair_block() {
  local pair_name=$1
  local target_a=$2
  local target_b=$3
  local pair_label=$4
  local target_a_port=$5
  local target_b_port=$6

  echo ""
  echo "============================================================"
  echo "PAIR BLOCK ${pair_label}: ${pair_name}"
  echo "Targets: A=${target_a}, B=${target_b}"
  echo "============================================================"

  for run_num in $(seq 1 "${BENCH_RUNS_PER_PAIR:-20}"); do
    local run_base_dir="${CAMPAIGN_OUTPUT_DIR}/${pair_name}/run$(printf '%02d' "$run_num")"
    local scenario_diag_dir="${run_base_dir}/logs/scenario-diagnostics"
    local startup_sequence_dir="${run_base_dir}/startup-sequence"
    local target_a_artifact="${startup_sequence_dir}/${target_a}.json"
    local target_b_artifact="${startup_sequence_dir}/${target_b}.json"

    echo ""
    echo "------------------------------------------------------------"
    echo "PAIR ${pair_label} | RUN $(printf '%02d' "$run_num")/${BENCH_RUNS_PER_PAIR:-20}"
    echo "Output base: ${run_base_dir}"
    echo "------------------------------------------------------------"

    mkdir -p "$startup_sequence_dir"

    if ! prepare_scenario_infrastructure "$scenario_diag_dir"; then
      echo "Skipping run $(printf '%02d' "$run_num") for pair ${pair_label} due to scenario infrastructure setup failure"
      STEP_COUNTER=$((STEP_COUNTER + 2))
      failed_steps=$((failed_steps + 2))
      continue
    fi

    if ! ensure_target_on_endpoint "$target_a" "$target_a_port" "$target_a_artifact" || ! ensure_target_on_endpoint "$target_b" "$target_b_port" "$target_b_artifact"; then
      echo "Skipping run $(printf '%02d' "$run_num") for pair ${pair_label} due to target readiness failure"
      STEP_COUNTER=$((STEP_COUNTER + 2))
      failed_steps=$((failed_steps + 2))
      continue
    fi

    capture_runtime_jvm_diagnostics "$target_a" "$target_a_port" "$startup_sequence_dir" || true
    capture_runtime_jvm_diagnostics "$target_b" "$target_b_port" "$startup_sequence_dir" || true

    STEP_COUNTER=$((STEP_COUNTER + 1))
    if ! ensure_target_healthy_or_recover "$target_a" "$target_a_port" "$target_a_artifact" || ! ensure_target_healthy_or_recover "$target_b" "$target_b_port" "$target_b_artifact"; then
      echo "Skipping step [$STEP_COUNTER/$TOTAL_STEPS] [RUN $(printf '%02d' "$run_num")] pair ${pair_label} (ab) due to target health recovery failure"
      failed_steps=$((failed_steps + 1))
    else
      run_benchmark "$pair_name" "$target_a" "$target_b" "ab" "$STEP_COUNTER" "$run_num" "$scenario_diag_dir" || failed_steps=$((failed_steps + 1))
    fi

    STEP_COUNTER=$((STEP_COUNTER + 1))
    if ! ensure_target_healthy_or_recover "$target_a" "$target_a_port" "$target_a_artifact" || ! ensure_target_healthy_or_recover "$target_b" "$target_b_port" "$target_b_artifact"; then
      echo "Skipping step [$STEP_COUNTER/$TOTAL_STEPS] [RUN $(printf '%02d' "$run_num")] pair ${pair_label} (ba) due to target health recovery failure"
      failed_steps=$((failed_steps + 1))
    else
      run_benchmark "$pair_name" "$target_a" "$target_b" "ba" "$STEP_COUNTER" "$run_num" "$scenario_diag_dir" || failed_steps=$((failed_steps + 1))
    fi

    if [[ $run_num -lt "${BENCH_RUNS_PER_PAIR:-20}" ]]; then
      echo "Cooldown 10s before next run in pair block ${pair_label}..."
      sleep 10
    fi
  done

  # Release this pair's target JVMs (and their Postgres connection pools) before
  # the next pair block's prepare_scenario_infrastructure runs, and leave the box
  # clean after the final pair. Without this, connections leak across pairs and
  # the second/third pair's infra-setup psql fails with 'too many clients'.
  stop_pair_targets "$target_a" "$target_a_port" "$target_b" "$target_b_port"
}

mkdir -p "$CAMPAIGN_OUTPUT_DIR"

apply_fair_resource_profile
capture_campaign_env
capture_campaign_cgroup_limits

echo ""
echo "============================================================"
echo "FULL TRIAD AB/BA CAMPAIGN START"
echo "Repository: $REPO_ROOT"
echo "Hardware Profile: $HARDWARE_PROFILE"
echo "Campaign TS: $CAMPAIGN_TS"
echo "Output Root: $CAMPAIGN_OUTPUT_DIR"
echo "============================================================"

failed_steps=0

# Effective pair list — each entry: "name:target_a:target_b:label:port_a:port_b".
# Default = the canonical exeris / spring / quarkus-hibernate triad (unchanged).
# Override with BENCH_TRIAD_PAIRS (';'-separated entries, same field order) to run
# a different set, e.g. the quarkus-focused triad (exeris vs quarkus-tuned, plus the
# ORM/transport decomposition):
#   BENCH_TRIAD_PAIRS="1-exeris-vs-quarkus-tuned:exeris-community:quarkus-tuned:1:9000:9003;2-exeris-vs-quarkus-hibernate:exeris-community:quarkus-hibernate:2:9000:9002;3-quarkus-hibernate-vs-tuned:quarkus-hibernate:quarkus-tuned:3:9002:9003"
if [[ -n "${BENCH_TRIAD_PAIRS:-}" ]]; then
  IFS=';' read -ra TRIAD_PAIRS <<< "$BENCH_TRIAD_PAIRS"
else
  TRIAD_PAIRS=(
    "1-exeris-vs-quarkus:exeris-community:quarkus-hibernate:1:9000:9002"
    "3-exeris-vs-spring:exeris-community:spring-hibernate:3:9000:9001"
    "2-spring-vs-quarkus:spring-hibernate:quarkus-hibernate:2:9001:9002"
  )
fi

if ! prebuild_campaign_targets; then
  echo "ERROR: Campaign aborted due to prebuild failure"
  exit 1
fi

for _entry in "${TRIAD_PAIRS[@]}"; do
  IFS=':' read -r _pname _pta _ptb _plabel _ppa _ppb <<< "$_entry"
  run_pair_block "$_pname" "$_pta" "$_ptb" "$_plabel" "$_ppa" "$_ppb"
done

echo ""
echo "============================================================"
echo "CAMPAIGN COMPLETED"
echo "============================================================"
if [[ $failed_steps -eq 0 ]]; then
  echo "Status: ALL STEPS PASSED"
else
  echo "Status: $failed_steps step(s) failed"
fi
echo "Results in: $CAMPAIGN_OUTPUT_DIR"