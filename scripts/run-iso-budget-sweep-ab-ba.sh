#!/usr/bin/env bash
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

if [[ ! -x ./scripts/capture-env.sh ]]; then
  echo "ERROR: ./scripts/capture-env.sh not found or not executable"
  exit 1
fi

TARGET_START_SCRIPT="./runtime/drivers/start-target.sh"
TARGET_STOP_SCRIPT="./runtime/drivers/stop-target.sh"
TARGET_CONTRACT_REGISTRY="./runtime/drivers/target-contract-registry.sh"

if [[ ! -x "$TARGET_START_SCRIPT" ]]; then
  echo "ERROR: ${TARGET_START_SCRIPT} not found or not executable"
  exit 1
fi

if [[ ! -x "$TARGET_STOP_SCRIPT" ]]; then
  echo "ERROR: ${TARGET_STOP_SCRIPT} not found or not executable"
  exit 1
fi

if [[ ! -f "$TARGET_CONTRACT_REGISTRY" ]]; then
  echo "ERROR: ${TARGET_CONTRACT_REGISTRY} not found"
  exit 1
fi

for cmd in jq mvn git date awk curl wrk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '${cmd}' not found in PATH"
    exit 1
  fi
done

# shellcheck source=/dev/null
source "$TARGET_CONTRACT_REGISTRY"

export HARDWARE_PROFILE="${HARDWARE_PROFILE:-perf-box-amd64}"
export ENTITY_READ_PREFLIGHT_TIMEOUT="${ENTITY_READ_PREFLIGHT_TIMEOUT:-60}"

WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
MEASUREMENT_SECONDS="${MEASUREMENT_SECONDS:-120}"
THREADS_VALUE="${THREADS:-4}"
CONTRACT_ID="${CONTRACT_ID:-fixed_contract_cross_runtime_h1_iso_budget_sweep_v1}"
QUALITY_GATE_P99_MAX_US="${QUALITY_GATE_P99_MAX_US:-250000}"
QUALITY_GATE_ERROR_RATE_MAX_PCT="${QUALITY_GATE_ERROR_RATE_MAX_PCT:-0.50}"

REPEATS="${REPEATS:-3}"
ISO_CPU_AFFINITY="${ISO_CPU_AFFINITY:-${BENCH_SERVER_CPU_AFFINITY:-}}"
VCPU_LEVELS_ENV="${ISO_VCPU_LEVELS:-1,2,4}"

declare -a VCPU_LEVELS=()
declare -a BASE_CPU_POOL=()
BASE_CPU_AFFINITY=""
VCPU_LEVELS_JSON=""

BENCH_DB_POOL_MIN_SIZE="${BENCH_DB_POOL_MIN_SIZE:-16}"
BENCH_DB_POOL_MAX_SIZE="${BENCH_DB_POOL_MAX_SIZE:-256}"
BENCH_ENABLE_NATIVE_MEMORY_TRACKING="${BENCH_ENABLE_NATIVE_MEMORY_TRACKING:-1}"
BENCH_NATIVE_MEMORY_TRACKING_LEVEL="${BENCH_NATIVE_MEMORY_TRACKING_LEVEL:-summary}"

SCENARIO_ID="entity-read-by-id"
SCENARIO_ENDPOINT_PATH="/api/v1/users"
SCENARIO_DIR="./scenarios/${SCENARIO_ID}"
SCENARIO_INFRA_SCRIPT="${SCENARIO_DIR}/infra-setup.sh"
SCENARIO_WRK_SCRIPT="${SCENARIO_DIR}/wrk.lua"
CAMPAIGN_TS="$(date -u +%Y%m%d-%H%M%S)"
CAMPAIGN_OUTPUT_DIR="results/raw/${SCENARIO_ID}/${CAMPAIGN_TS}-iso-budget-sweep-ab-ba"
CAMPAIGN_SUMMARY_CSV="${CAMPAIGN_OUTPUT_DIR}/campaign-summary.csv"

CONNECTIONS=(8 16 32 64 128 256)
TRIAD_LABELS=(A B C)
TRIAD_TARGETS=(
  exeris-community
  spring-hibernate
  quarkus-hibernate
)
PAIR_ORDERS=(ab ba)
SEQUENCE_TOTAL=3
SEQUENCE_MODE="ab-ba-triad"
CAMPAIGN_ID_SUFFIX="iso-budget-sweep-ab-ba"
PAIR_ID="${TRIAD_TARGETS[0]}__${TRIAD_TARGETS[1]}"

PROFILE_IDS=(
  p128-512-512
  p192-768-768
  p256-1280-1280
)

declare -A PROFILE_EXERIS_HEAP_MB=(

  [p128-512-512]=128
  [p192-768-768]=192
  [p256-1280-1280]=256
)

declare -A PROFILE_SPRING_HEAP_MB=(
  [p128-512-512]=512
  [p192-768-768]=768
  [p256-1280-1280]=1280
)

declare -A PROFILE_QUARKUS_HEAP_MB=(
  [p128-512-512]=512
  [p192-768-768]=768
  [p256-1280-1280]=1280
)

declare -A PROFILE_MAX_RAM_MB=(
  [p128-512-512]=512
  [p192-768-768]=768
  [p256-1280-1280]=1280
)

declare -A TARGET_TIER=()
declare -A TARGET_PROTOCOL=()
declare -A TARGET_LAUNCHER=()
declare -A TARGET_HEALTH_URL=()

CLK_TCK=100
if command -v getconf >/dev/null 2>&1; then
  CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
fi

CURRENT_STEP=0
TOTAL_STEPS=0

json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_array_from_strings() {
  local -n source_array_ref=$1
  local item=""
  local escaped=""
  local first=1

  printf '['
  for item in "${source_array_ref[@]}"; do
    escaped="$(printf '%s' "$item" | json_escape)"
    if (( first )); then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$escaped"
  done
  printf ']'
}

validate_positive_integer() {
  local value=$1
  local label=$2

  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value <= 0 )); then
    echo "ERROR: ${label} must be a positive integer, got: ${value}"
    return 1
  fi

  return 0
}

validate_non_negative_decimal() {
  local value=$1
  local label=$2

  if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: ${label} must be a non-negative decimal number, got: ${value}"
    return 1
  fi

  return 0
}

resolve_default_cpu_affinity() {
  local cpu_count=""

  if command -v getconf >/dev/null 2>&1; then
    cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi

  if [[ ! "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count <= 0 )); then
    if command -v nproc >/dev/null 2>&1; then
      cpu_count="$(nproc 2>/dev/null || true)"
    fi
  fi

  if [[ "$cpu_count" =~ ^[0-9]+$ ]] && (( cpu_count > 0 )); then
    if (( cpu_count == 1 )); then
      echo "0"
    else
      echo "0-$((cpu_count - 1))"
    fi
    return 0
  fi

  echo ""
}

expand_cpu_affinity() {
  local affinity_expr=$1
  local token=""
  local range_start=""
  local range_end=""
  local cpu=""
  local -a tokens=()
  local -A seen_cpu=()

  if [[ -z "${affinity_expr//[[:space:]]/}" ]]; then
    echo "ERROR: CPU affinity expression is empty"
    return 1
  fi

  IFS=',' read -r -a tokens <<< "$affinity_expr"

  for token in "${tokens[@]}"; do
    token="${token//[[:space:]]/}"

    if [[ -z "$token" ]]; then
      echo "ERROR: Invalid CPU affinity expression (empty token): ${affinity_expr}"
      return 1
    fi

    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      range_start="${BASH_REMATCH[1]}"
      range_end="${BASH_REMATCH[2]}"

      if (( range_end < range_start )); then
        echo "ERROR: Invalid CPU range '${token}' in affinity '${affinity_expr}'"
        return 1
      fi

      for ((cpu=range_start; cpu<=range_end; cpu++)); do
        if [[ -z "${seen_cpu[$cpu]+x}" ]]; then
          seen_cpu[$cpu]=1
          printf '%s\n' "$cpu"
        fi
      done
      continue
    fi

    if [[ "$token" =~ ^[0-9]+$ ]]; then
      if [[ -z "${seen_cpu[$token]+x}" ]]; then
        seen_cpu[$token]=1
        printf '%s\n' "$token"
      fi
      continue
    fi

    echo "ERROR: Invalid CPU token '${token}' in affinity '${affinity_expr}'"
    return 1
  done
}

derive_cpu_affinity_for_vcpu_count() {
  local -n source_cpu_pool_ref=$1
  local vcpu_count=$2
  local idx=""
  local -a selected_cpus=()

  validate_positive_integer "$vcpu_count" "vCPU level" || return 1

  if (( ${#source_cpu_pool_ref[@]} < vcpu_count )); then
    echo "ERROR: Requested vCPU level ${vcpu_count} exceeds available CPUs in base affinity (${#source_cpu_pool_ref[@]})"
    return 1
  fi

  for ((idx=0; idx<vcpu_count; idx++)); do
    selected_cpus+=("${source_cpu_pool_ref[$idx]}")
  done

  local IFS=','
  printf '%s\n' "${selected_cpus[*]}"
}

parse_vcpu_levels() {
  local token=""
  local normalized=""
  local -a parsed_levels=()
  local -A seen_level=()

  IFS=',' read -r -a parsed_levels <<< "$VCPU_LEVELS_ENV"

  if (( ${#parsed_levels[@]} == 0 )); then
    echo "ERROR: No vCPU levels provided in ISO_VCPU_LEVELS"
    return 1
  fi

  VCPU_LEVELS=()

  for token in "${parsed_levels[@]}"; do
    normalized="${token//[[:space:]]/}"
    validate_positive_integer "$normalized" "vCPU level" || return 1

    if [[ -z "${seen_level[$normalized]+x}" ]]; then
      seen_level[$normalized]=1
      VCPU_LEVELS+=("$normalized")
    fi
  done

  if (( ${#VCPU_LEVELS[@]} == 0 )); then
    echo "ERROR: No valid vCPU levels parsed from ISO_VCPU_LEVELS='${VCPU_LEVELS_ENV}'"
    return 1
  fi

  local IFS=','
  VCPU_LEVELS_JSON="${VCPU_LEVELS[*]}"
}

csv_escape() {
  local value="${1:-}"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

to_microseconds() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    echo "0"
    return 0
  fi

  if [[ "$token" =~ ^([0-9]*\.?[0-9]+)(us|ms|s)$ ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    LC_ALL=C awk -v v="$value" -v u="$unit" 'BEGIN {
      if (u == "us") printf "%.6f", v;
      else if (u == "ms") printf "%.6f", v * 1000.0;
      else if (u == "s") printf "%.6f", v * 1000000.0;
      else printf "0.000000";
    }'
    return 0
  fi

  echo "0"
}

build_target_artifact() {
  local target_id=$1
  local module_path=""
  local pom_path=""

  case "$target_id" in
    exeris-community)
      module_path="targets/exeris-community-app"
      ;;
    spring-hibernate)
      module_path="targets/spring-benchmark-app"
      ;;
    quarkus-hibernate)
      module_path="targets/quarkus-benchmark-app"
      ;;
    *)
      echo "ERROR: No Maven module mapping defined for target ${target_id}"
      return 1
      ;;
  esac

  pom_path="${module_path}/pom.xml"
  echo "[PREBUILD] Building ${target_id} from ${module_path}"
  mvn -q -f "$pom_path" -DskipTests package
  echo "[PREBUILD] Build completed for ${target_id}"
}

prebuild_campaign_targets() {
  echo ""
  echo "============================================================"
  echo "PREBUILD CAMPAIGN TARGET ARTIFACTS"
  echo "============================================================"

  build_target_artifact "exeris-community"
  build_target_artifact "spring-hibernate"
  build_target_artifact "quarkus-hibernate"

  echo "============================================================"
  echo "PREBUILD COMPLETED"
  echo "============================================================"
}

apply_iso_budget_profile() {
  local profile_id=$1
  local current_cpu_affinity=$2
  local exeris_heap_mb="${PROFILE_EXERIS_HEAP_MB[$profile_id]:-}"
  local spring_heap_mb="${PROFILE_SPRING_HEAP_MB[$profile_id]:-}"
  local quarkus_heap_mb="${PROFILE_QUARKUS_HEAP_MB[$profile_id]:-}"
  local max_ram_mb="${PROFILE_MAX_RAM_MB[$profile_id]:-}"

  validate_positive_integer "$exeris_heap_mb" "profile exeris heap" || return 1
  validate_positive_integer "$spring_heap_mb" "profile spring heap" || return 1
  validate_positive_integer "$quarkus_heap_mb" "profile quarkus heap" || return 1
  validate_positive_integer "$max_ram_mb" "profile max ram" || return 1

  if (( exeris_heap_mb > max_ram_mb )); then
    echo "ERROR: profile ${profile_id} exeris heap exceeds shared max RAM"
    return 1
  fi
  if (( spring_heap_mb > max_ram_mb )); then
    echo "ERROR: profile ${profile_id} spring heap exceeds shared max RAM"
    return 1
  fi
  if (( quarkus_heap_mb > max_ram_mb )); then
    echo "ERROR: profile ${profile_id} quarkus heap exceeds shared max RAM"
    return 1
  fi

  export SERVER_CPU_AFFINITY="$current_cpu_affinity"
  export EXERIS_DB_POOL_MIN_SIZE="$BENCH_DB_POOL_MIN_SIZE"
  export EXERIS_DB_POOL_MAX_SIZE="$BENCH_DB_POOL_MAX_SIZE"

  export EXERIS_JAVA_OPTS="-Xms${exeris_heap_mb}m -Xmx${exeris_heap_mb}m -XX:MaxRAM=${max_ram_mb}m"
  export SPRING_JAVA_OPTS="-Xms${spring_heap_mb}m -Xmx${spring_heap_mb}m -XX:MaxRAM=${max_ram_mb}m"
  export QUARKUS_JAVA_OPTS="-Xms${quarkus_heap_mb}m -Xmx${quarkus_heap_mb}m -XX:MaxRAM=${max_ram_mb}m"

  if [[ "$BENCH_ENABLE_NATIVE_MEMORY_TRACKING" == "1" ]]; then
    export EXERIS_JAVA_OPTS="${EXERIS_JAVA_OPTS} -XX:NativeMemoryTracking=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL}"
    export SPRING_JAVA_OPTS="${SPRING_JAVA_OPTS} -XX:NativeMemoryTracking=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL}"
    export QUARKUS_JAVA_OPTS="${QUARKUS_JAVA_OPTS} -XX:NativeMemoryTracking=${BENCH_NATIVE_MEMORY_TRACKING_LEVEL}"
  fi

  echo "ISO budget profile=${profile_id} cpu_affinity=${current_cpu_affinity} max_ram_mb=${max_ram_mb}"
  echo "Heaps MB: exeris=${exeris_heap_mb} spring=${spring_heap_mb} quarkus=${quarkus_heap_mb}"
}

prepare_scenario_infrastructure() {
  local diagnostics_dir=$1

  if [[ ! -f "$SCENARIO_INFRA_SCRIPT" ]]; then
    echo "ERROR: Scenario infrastructure script not found: ${SCENARIO_INFRA_SCRIPT}"
    return 1
  fi

  mkdir -p "$diagnostics_dir"

  if ! BENCH_SCENARIO_DIAGNOSTICS_DIR="$diagnostics_dir" \
    BENCH_CAPTURE_DB_EXPLAIN="${BENCH_CAPTURE_DB_EXPLAIN:-0}" \
    bash "$SCENARIO_INFRA_SCRIPT"; then
    echo "ERROR: Scenario infrastructure setup failed for ${SCENARIO_ID}"
    return 1
  fi

  return 0
}

health_url_to_port() {
  local health_url=$1
  local scheme=""
  local hostport=""
  local port=""

  if [[ "$health_url" =~ ^(https?)://([^/]+) ]]; then
    scheme="${BASH_REMATCH[1]}"
    hostport="${BASH_REMATCH[2]}"
    if [[ "$hostport" == *:* ]]; then
      port="${hostport##*:}"
    else
      if [[ "$scheme" == "https" ]]; then
        port="443"
      else
        port="80"
      fi
    fi
  fi

  if [[ "$port" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$port"
    return 0
  fi

  return 1
}

detect_target_pid() {
  local health_url=$1
  local pid_file="/tmp/exeris-bench-target.pid"
  local pid=""
  local port=""

  if [[ -f "$pid_file" ]]; then
    pid="$(tr -d '[:space:]' < "$pid_file" || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi

  if port="$(health_url_to_port "$health_url" 2>/dev/null)"; then
    if command -v ss >/dev/null 2>&1; then
      pid="$(ss -ltnp "sport = :${port}" 2>/dev/null | awk -F'pid=' 'NR>1 && NF>1 {split($2,a,","); print a[1]; exit}')"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi

    if command -v lsof >/dev/null 2>&1; then
      pid="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
  fi

  printf '%s\n' ""
}

collect_proc_ticks() {
  local pid=$1
  if [[ -r "/proc/${pid}/stat" ]]; then
    awk '{print $14 + $15}' "/proc/${pid}/stat" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

collect_proc_rss_kb() {
  local pid=$1
  if [[ -r "/proc/${pid}/status" ]]; then
    awk '/^VmRSS:/ {print $2; exit}' "/proc/${pid}/status" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

start_resource_sampler() {
  local pid=$1
  local sample_file=$2
  local stop_file=$3

  : > "$sample_file"

  while kill -0 "$pid" 2>/dev/null; do
    if [[ -f "$stop_file" ]]; then
      break
    fi

    local ticks=""
    local rss_kb=""
    ticks="$(collect_proc_ticks "$pid")"
    rss_kb="$(collect_proc_rss_kb "$pid")"

    if [[ "$ticks" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      if [[ ! "$rss_kb" =~ ^[0-9]+$ ]]; then
        rss_kb=0
      fi
      printf '%s,%s,%s\n' "$(date +%s)" "$ticks" "$rss_kb" >> "$sample_file"
    fi

    sleep 1
  done
}

summarize_resource_samples() {
  local sample_file=$1

  if [[ ! -s "$sample_file" ]]; then
    printf '%s\n' "0.000000|0|0"
    return 0
  fi

  LC_ALL=C awk -F, -v clk="$CLK_TCK" '
    NR==1 {first=$2}
    {
      last=$2
      rss_sum += $3
      n += 1
    }
    END {
      cpu = 0
      if (n >= 2 && clk > 0) {
        cpu = (last - first) / clk
      }
      if (cpu < 0) cpu = 0

      rss_avg = 0
      if (n > 0) rss_avg = rss_sum / n

      printf "%.6f|%.2f|%d\n", cpu, rss_avg, n
    }
  ' "$sample_file"
}

capture_jcmd_metrics() {
  local pid=$1
  local output_dir=$2

  local jcmd_available=false
  local heap_info_file="${output_dir}/jcmd-gc-heap-info.txt"
  local nmt_file="${output_dir}/jcmd-native-memory-summary.txt"
  local nmt_attempted=false
  local heap_used_mb=0
  local heap_committed_mb=0
  local native_total_committed_kb=0

  if command -v jcmd >/dev/null 2>&1 && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    if jcmd "$pid" GC.heap_info > "$heap_info_file" 2>&1; then
      jcmd_available=true

      local heap_used_kb=0
      local heap_committed_kb=0
      local parsed_heap_kb=""
      parsed_heap_kb="$(LC_ALL=C awk '
        BEGIN {
          used = ""
          committed = ""
          fallback_total = ""
        }
        {
          line = tolower($0)

          if (used == "" && match(line, /used[[:space:]]+([0-9]+)k/, m)) {
            used = m[1]
          }

          if (committed == "" && match(line, /committed[[:space:]]+([0-9]+)k/, m)) {
            committed = m[1]
          }

          if (fallback_total == "" && match(line, /total[[:space:]]+([0-9]+)k,[[:space:]]*used[[:space:]]+([0-9]+)k/, m)) {
            fallback_total = m[1]
            if (used == "") {
              used = m[2]
            }
          }
        }
        END {
          if (committed == "" && fallback_total != "") {
            committed = fallback_total
          }
          if (used == "") {
            used = 0
          }
          if (committed == "") {
            committed = 0
          }

          printf "%s|%s\n", used, committed
        }
      ' "$heap_info_file" 2>/dev/null || true)"

      heap_used_kb="${parsed_heap_kb%%|*}"
      heap_committed_kb="${parsed_heap_kb##*|}"

      if [[ ! "$heap_used_kb" =~ ^[0-9]+$ ]]; then
        heap_used_kb=0
      fi
      if [[ ! "$heap_committed_kb" =~ ^[0-9]+$ ]]; then
        heap_committed_kb=0
      fi

      heap_used_mb="$(LC_ALL=C awk -v kb="$heap_used_kb" 'BEGIN { printf "%.6f", kb / 1024.0 }')"
      heap_committed_mb="$(LC_ALL=C awk -v kb="$heap_committed_kb" 'BEGIN { printf "%.6f", kb / 1024.0 }')"
    fi

    if [[ "$BENCH_ENABLE_NATIVE_MEMORY_TRACKING" == "1" ]]; then
      nmt_attempted=true
      if jcmd "$pid" VM.native_memory summary > "$nmt_file" 2>&1; then
        jcmd_available=true

        local parsed_nmt_committed_kb=""
        parsed_nmt_committed_kb="$(LC_ALL=C awk '
          {
            line = tolower($0)
            if (line ~ /total/ && match(line, /committed=([0-9]+)k(b)?/, m)) {
              print m[1]
              exit
            }
          }
        ' "$nmt_file" 2>/dev/null || true)"

        if [[ "$parsed_nmt_committed_kb" =~ ^[0-9]+$ ]]; then
          native_total_committed_kb="$parsed_nmt_committed_kb"
        fi
      fi
    fi
  fi

  jq -n \
    --argjson jcmd_available "$jcmd_available" \
    --argjson native_memory_attempted "$nmt_attempted" \
    --argjson heap_used_mb "$heap_used_mb" \
    --argjson heap_committed_mb "$heap_committed_mb" \
    --argjson native_total_committed_kb "$native_total_committed_kb" \
    '{
      jcmd_available: $jcmd_available,
      native_memory_attempted: $native_memory_attempted,
      heap_used_mb: $heap_used_mb,
      heap_committed_mb: $heap_committed_mb,
      native_total_committed_kb: $native_total_committed_kb
    }'
}

write_campaign_metadata() {
  local commit_sha_file="${CAMPAIGN_OUTPUT_DIR}/commit-sha.txt"
  local env_capture_file="${CAMPAIGN_OUTPUT_DIR}/env-capture.json"
  local campaign_manifest_file="${CAMPAIGN_OUTPUT_DIR}/campaign-metadata.json"
  local capture_utc=""
  local benchmark_commit_sha=""
  local triad_targets_json=""
  local triad_labels_json=""
  local profile_ids_json=""
  local pair_orders_json=""

  benchmark_commit_sha="$(git rev-parse HEAD)"
  printf '%s\n' "$benchmark_commit_sha" > "$commit_sha_file"

  ./scripts/capture-env.sh --profile "$HARDWARE_PROFILE" --tool wrk > "$env_capture_file"

  triad_targets_json="$(json_array_from_strings TRIAD_TARGETS)"
  triad_labels_json="$(json_array_from_strings TRIAD_LABELS)"
  profile_ids_json="$(json_array_from_strings PROFILE_IDS)"
  pair_orders_json="$(json_array_from_strings PAIR_ORDERS)"

  capture_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$campaign_manifest_file" <<EOF
{
  "campaign_id": "$(printf '%s' "${CAMPAIGN_TS}-${CAMPAIGN_ID_SUFFIX}" | json_escape)",
  "benchmark_commit_sha": "${benchmark_commit_sha}",
  "generated_at_utc": "${capture_utc}",
  "benchmark_family": "runtime",
  "scenario_id": "${SCENARIO_ID}",
  "scenario_endpoint_path": "${SCENARIO_ENDPOINT_PATH}",
  "contract_id": "${CONTRACT_ID}",
  "target_scope": "community",
  "protocol_mode": "h1",
  "comparison_axis": "cross-runtime-community-h1",
  "sequence_mode": "${SEQUENCE_MODE}",
  "sequence_total": ${SEQUENCE_TOTAL},
  "targets_ordered": ${triad_targets_json},
  "declared_matrix": {
    "pair_orders": ${pair_orders_json},
    "sequence_order_labels": ${triad_labels_json},
    "sequence_targets": ${triad_targets_json},
    "vcpu_levels": [${VCPU_LEVELS_JSON}],
    "profiles": ${profile_ids_json},
    "connections": [8, 16, 32, 64, 128, 256],
    "repeats": ${REPEATS}
  },
  "hardware_profile": "${HARDWARE_PROFILE}",
  "repeat_count": ${REPEATS},
  "warmup_seconds": ${WARMUP_SECONDS},
  "measurement_seconds": ${MEASUREMENT_SECONDS},
  "threads": ${THREADS_VALUE},
  "vcpu_levels": [${VCPU_LEVELS_JSON}],
  "base_cpu_affinity": "$(printf '%s' "$BASE_CPU_AFFINITY" | json_escape)",
  "connections": [8, 16, 32, 64, 128, 256],
  "profiles": [
    {
      "profile_id": "p128-512-512",
      "exeris_heap_mb": 128,
      "spring_heap_mb": 512,
      "quarkus_heap_mb": 512,
      "max_ram_mb": 512
    },
    {
      "profile_id": "p192-768-768",
      "exeris_heap_mb": 192,
      "spring_heap_mb": 768,
      "quarkus_heap_mb": 768,
      "max_ram_mb": 768
    },
    {
      "profile_id": "p256-1280-1280",
      "exeris_heap_mb": 256,
      "spring_heap_mb": 1280,
      "quarkus_heap_mb": 1280,
      "max_ram_mb": 1280
    }
  ],
  "iso_budget": {
    "server_cpu_affinity_base_pool": "$(printf '%s' "$BASE_CPU_AFFINITY" | json_escape)",
    "native_memory_tracking_enabled": $([[ "$BENCH_ENABLE_NATIVE_MEMORY_TRACKING" == "1" ]] && echo true || echo false),
    "native_memory_tracking_level": "$(printf '%s' "$BENCH_NATIVE_MEMORY_TRACKING_LEVEL" | json_escape)",
    "shared_max_ram_policy": "per-profile shared -XX:MaxRAM across all targets"
  },
  "quality_gates": {
    "p99_max_us": ${QUALITY_GATE_P99_MAX_US},
    "error_rate_max_pct": ${QUALITY_GATE_ERROR_RATE_MAX_PCT}
  }
}
EOF
}

write_csv_header() {
  cat > "$CAMPAIGN_SUMMARY_CSV" <<'EOF'
campaign_ts,campaign_id,benchmark_family,scenario_id,scenario_endpoint_path,contract_id,target_scope,protocol_mode,sequence_mode,pair_order,repeat_index,connections,profile_id,max_ram_mb,vcpu_count,cpu_affinity,target_order_label,sequence_index,sequence_total,target_id,target_tier,target_protocol,health_url,benchmark_url,throughput_rps,total_requests,latency_p99_us,error_rate_pct,cpu_time_seconds,rss_kb_avg,requests_per_cpu_second,rps_per_gb_rss,quality_gate_p99_ok,quality_gate_error_rate_ok,quality_gate_pass,run_output_dir
EOF
}

resolve_sequence_target_for_pair_order() {
  local pair_order=$1
  local sequence_index=$2

  case "${pair_order}:${sequence_index}" in
    ab:1)
      printf '%s|%s\n' "${TRIAD_LABELS[0]}" "${TRIAD_TARGETS[0]}"
      ;;
    ab:2)
      printf '%s|%s\n' "${TRIAD_LABELS[1]}" "${TRIAD_TARGETS[1]}"
      ;;
    ab:3)
      printf '%s|%s\n' "${TRIAD_LABELS[2]}" "${TRIAD_TARGETS[2]}"
      ;;
    ba:1)
      printf '%s|%s\n' "${TRIAD_LABELS[1]}" "${TRIAD_TARGETS[1]}"
      ;;
    ba:2)
      printf '%s|%s\n' "${TRIAD_LABELS[0]}" "${TRIAD_TARGETS[0]}"
      ;;
    ba:3)
      printf '%s|%s\n' "${TRIAD_LABELS[2]}" "${TRIAD_TARGETS[2]}"
      ;;
    *)
      echo "ERROR: Invalid pair_order/sequence_index combination: ${pair_order}/${sequence_index}" >&2
      return 1
      ;;
  esac
}

resolve_ab_ba_orders_completed_json() {
  local pair_order=$1

  case "$pair_order" in
    ab)
      printf '%s\n' '["ab"]'
      ;;
    ba)
      printf '%s\n' '["ab","ba"]'
      ;;
    *)
      echo "ERROR: Invalid pair_order: ${pair_order}" >&2
      return 1
      ;;
  esac
}

resolve_triad_target_contracts() {
  local target_id=""

  for target_id in "${TRIAD_TARGETS[@]}"; do
    resolve_target_contract "$target_id"
    assert_target_contract_complete

    if [[ "$TARGET_CONTRACT_TIER" != "community" ]]; then
      echo "ERROR: Target contract tier drift for ${target_id}: expected community, got ${TARGET_CONTRACT_TIER}"
      return 1
    fi

    if [[ "$TARGET_CONTRACT_PROTOCOL_MODE" != "h1" ]]; then
      echo "ERROR: Target contract protocol drift for ${target_id}: expected h1, got ${TARGET_CONTRACT_PROTOCOL_MODE}"
      return 1
    fi

    TARGET_TIER[$target_id]="$TARGET_CONTRACT_TIER"
    TARGET_PROTOCOL[$target_id]="$TARGET_CONTRACT_PROTOCOL_MODE"
    TARGET_LAUNCHER[$target_id]="$TARGET_CONTRACT_LAUNCHER_MODE"
    TARGET_HEALTH_URL[$target_id]="$TARGET_CONTRACT_HEALTH_URL"

    if [[ -z "${TARGET_HEALTH_URL[$target_id]}" ]]; then
      echo "ERROR: Missing health URL from contract for target ${target_id}"
      return 1
    fi
  done
}

append_campaign_row() {
  local pair_order=$1
  local repeat_index=$2
  local connections=$3
  local profile_id=$4
  local max_ram_mb=$5
  local vcpu_count=$6
  local cpu_affinity=$7
  local target_order_label=$8
  local sequence_index=$9
  local target_id=${10}
  local health_url=${11}
  local benchmark_url=${12}
  local throughput_rps=${13}
  local total_requests=${14}
  local latency_p99_us=${15}
  local error_rate_pct=${16}
  local cpu_time_seconds=${17}
  local rss_kb_avg=${18}
  local requests_per_cpu_second=${19}
  local rps_per_gb_rss=${20}
  local quality_gate_p99_ok=${21}
  local quality_gate_error_rate_ok=${22}
  local quality_gate_pass=${23}
  local run_output_dir=${24}

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$CAMPAIGN_TS")" \
    "$(csv_escape "${CAMPAIGN_TS}-${CAMPAIGN_ID_SUFFIX}")" \
    "$(csv_escape "runtime")" \
    "$(csv_escape "$SCENARIO_ID")" \
    "$(csv_escape "$SCENARIO_ENDPOINT_PATH")" \
    "$(csv_escape "$CONTRACT_ID")" \
    "$(csv_escape "community")" \
    "$(csv_escape "h1")" \
    "$(csv_escape "$SEQUENCE_MODE")" \
    "$(csv_escape "$pair_order")" \
    "$(csv_escape "$repeat_index")" \
    "$(csv_escape "$connections")" \
    "$(csv_escape "$profile_id")" \
    "$(csv_escape "$max_ram_mb")" \
    "$(csv_escape "$vcpu_count")" \
    "$(csv_escape "$cpu_affinity")" \
    "$(csv_escape "$target_order_label")" \
    "$(csv_escape "$sequence_index")" \
    "$(csv_escape "$SEQUENCE_TOTAL")" \
    "$(csv_escape "$target_id")" \
    "$(csv_escape "${TARGET_TIER[$target_id]:-unknown}")" \
    "$(csv_escape "${TARGET_PROTOCOL[$target_id]:-unknown}")" \
    "$(csv_escape "$health_url")" \
    "$(csv_escape "$benchmark_url")" \
    "$(csv_escape "$throughput_rps")" \
    "$(csv_escape "$total_requests")" \
    "$(csv_escape "$latency_p99_us")" \
    "$(csv_escape "$error_rate_pct")" \
    "$(csv_escape "$cpu_time_seconds")" \
    "$(csv_escape "$rss_kb_avg")" \
    "$(csv_escape "$requests_per_cpu_second")" \
    "$(csv_escape "$rps_per_gb_rss")" \
    "$(csv_escape "$quality_gate_p99_ok")" \
    "$(csv_escape "$quality_gate_error_rate_ok")" \
    "$(csv_escape "$quality_gate_pass")" \
    "$(csv_escape "$run_output_dir")" \
    >> "$CAMPAIGN_SUMMARY_CSV"
}

run_triad_target_once() {
  local profile_id=$1
  local connections=$2
  local repeat_index=$3
  local max_ram_mb=$4
  local vcpu_count=$5
  local current_cpu_affinity=$6
  local pair_order=$7
  local ab_ba_orders_completed_json=$8
  local sequence_index=$9
  local target_order_label=${10}
  local target_id=${11}

  local run_output_dir="${CAMPAIGN_OUTPUT_DIR}/vcpu-${vcpu_count}/${profile_id}/connections-${connections}/repeat$(printf '%02d' "$repeat_index")/order-${pair_order}/${sequence_index}-${target_order_label}-${target_id}"
  local diagnostics_dir="${run_output_dir}/logs/scenario-diagnostics"
  local run_log="${run_output_dir}/run.log"
  local endpoint_diag_file="${run_output_dir}/endpoint-diag.txt"
  local warmup_log="${run_output_dir}/wrk-warmup.log"
  local measurement_log="${run_output_dir}/wrk-measurement.log"
  local resource_samples_file="${run_output_dir}/resource-samples.csv"
  local sampler_stop_file="${run_output_dir}/resource-sampler.stop"
  local result_json="${run_output_dir}/result.json"
  local resource_metrics_json="${run_output_dir}/resource-metrics.json"
  local efficiency_json="${run_output_dir}/efficiency.json"
  local reproducibility_json="${run_output_dir}/reproducibility-metadata.json"

  local health_url="${TARGET_HEALTH_URL[$target_id]}"
  local base_url=""
  local benchmark_url=""
  local target_started=0
  local target_pid=""
  local sampler_pid=""

  local throughput_rps="0"
  local total_requests="0"
  local latency_p99_us="0"
  local non2xx_errors="0"
  local socket_errors="0"
  local total_errors="0"
  local error_rate_pct="0"

  local cpu_time_seconds="0.000000"
  local rss_kb_avg="0"
  local resource_sample_count="0"

  local requests_per_cpu_second="0.000000"
  local rps_per_gb_rss="0.000000"
  local quality_gate_p99_ok="false"
  local quality_gate_error_rate_ok="false"
  local quality_gate_pass="false"
  local benchmark_tool_version=""
  local target_commit_sha=""
  local java_settings=""
  local jdk_vendor="unknown"
  local jdk_version="unknown"
  local run_hardware_profile="${HARDWARE_PROFILE:-unknown}"
  local target_classification=""
  local target_java_opts=""
  local -a target_jvm_flags=()
  local jvm_flags_json="[]"

  mkdir -p "$run_output_dir"

  if ! base_url="$(bench_normalize_health_base_url "$health_url")"; then
    echo "ERROR: Could not derive base URL from health URL '${health_url}' for ${target_id}" | tee -a "$run_log"
    return 1
  fi
  benchmark_url="${base_url}${SCENARIO_ENDPOINT_PATH}"

  echo "[$CURRENT_STEP/$TOTAL_STEPS] mode=ab-ba-triad order=${pair_order} triad=${target_order_label} seq=${sequence_index}/${SEQUENCE_TOTAL} target=${target_id} vcpu=${vcpu_count} profile=${profile_id} connections=${connections} repeat=${repeat_index}" | tee -a "$run_log"

  if ! prepare_scenario_infrastructure "$diagnostics_dir"; then
    echo "ERROR: scenario infrastructure setup failed" | tee -a "$run_log"
    return 1
  fi

  if ! "$TARGET_START_SCRIPT" "$target_id" >> "$run_log" 2>&1; then
    echo "ERROR: failed to start target ${target_id}" | tee -a "$run_log"
    return 1
  fi
  target_started=1

  target_pid="$(detect_target_pid "$health_url")"
  if [[ -n "$target_pid" ]]; then
    echo "[RESOURCE] detected target pid=${target_pid}" | tee -a "$run_log"
  else
    echo "[RESOURCE] target pid not detected; resource metrics fallback to 0 where unavailable" | tee -a "$run_log"
  fi

  # ============================================================
  # STAGE 4 (PREFLIGHT): Endpoint Diagnostics
  # ============================================================
  echo "" | tee -a "$run_log" "$endpoint_diag_file"
  echo "# =============================================================="| tee -a "$run_log" "$endpoint_diag_file"
  echo "# STAGE 4 (PREFLIGHT): Endpoint Diagnostics" | tee -a "$run_log" "$endpoint_diag_file"
  echo "# =============================================================="| tee -a "$run_log" "$endpoint_diag_file"
  echo "=== ENDPOINT DIAGNOSTIC ===" | tee -a "$run_log" "$endpoint_diag_file"
  echo "Target: $target_id" | tee -a "$run_log" "$endpoint_diag_file"
  echo "URL: $benchmark_url" | tee -a "$run_log" "$endpoint_diag_file"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" | tee -a "$run_log" "$endpoint_diag_file"
  echo "" | tee -a "$run_log" "$endpoint_diag_file"

  local preflight_status=""
  local preflight_body="${run_output_dir}/preflight.txt"
  echo "Attempting curl request..." | tee -a "$run_log" "$endpoint_diag_file"
  if bench_run_endpoint_preflight_with_headers "$benchmark_url" "$preflight_body" "$ENTITY_READ_PREFLIGHT_TIMEOUT"; then
    preflight_status="$BENCH_PREFLIGHT_HTTP_CODE"
  else
    preflight_status="$BENCH_PREFLIGHT_HTTP_CODE"
  fi

  echo "" | tee -a "$run_log" "$endpoint_diag_file"
  echo "HTTP Status Code: $preflight_status" | tee -a "$run_log" "$endpoint_diag_file"
  echo "Response (first 500 chars):" | tee -a "$run_log" "$endpoint_diag_file"
  echo "---" | tee -a "$run_log" "$endpoint_diag_file"
  bench_print_preflight_payload_preview "$preflight_body" 500 | tee -a "$run_log" "$endpoint_diag_file"
  echo "" | tee -a "$run_log" "$endpoint_diag_file"
  echo "---" | tee -a "$run_log" "$endpoint_diag_file"

  if [[ "$preflight_status" != "200" ]]; then
    echo "ERROR: endpoint preflight failed for ${benchmark_url} (status=${preflight_status})" | tee -a "$run_log"
    if (( target_started == 1 )); then
      "$TARGET_STOP_SCRIPT" "$target_id" >> "$run_log" 2>&1 || true
    fi
    return 1
  fi

  local -a warmup_cmd=(wrk -t "$THREADS_VALUE" -c "$connections" -d "${WARMUP_SECONDS}s")
  local -a measurement_cmd=(wrk -t "$THREADS_VALUE" -c "$connections" -d "${MEASUREMENT_SECONDS}s" --latency)

  if [[ -f "$SCENARIO_WRK_SCRIPT" ]]; then
    warmup_cmd+=(--script "$SCENARIO_WRK_SCRIPT")
    measurement_cmd+=(--script "$SCENARIO_WRK_SCRIPT")
  fi

  warmup_cmd+=("$benchmark_url")
  measurement_cmd+=("$benchmark_url")

  echo "  Running warmup for $target_id (${WARMUP_SECONDS}s, latency discarded)..." | tee -a "$run_log"
  "${warmup_cmd[@]}" > "$warmup_log" 2>&1 &
  local warmup_pid=$!
  local warmup_elapsed=0
  while kill -0 "$warmup_pid" 2>/dev/null; do
    sleep 10
    warmup_elapsed=$((warmup_elapsed + 10))
    if kill -0 "$warmup_pid" 2>/dev/null; then
      echo "  Warmup still running for $target_id (${warmup_elapsed}s elapsed)..." | tee -a "$run_log"
    fi
  done
  wait "$warmup_pid" || true

  echo "  Running measurement for $target_id (${MEASUREMENT_SECONDS}s)..." | tee -a "$run_log"
  rm -f "$sampler_stop_file"
  if [[ -n "$target_pid" ]]; then
    start_resource_sampler "$target_pid" "$resource_samples_file" "$sampler_stop_file" &
    sampler_pid=$!
  fi

  set +e
  "${measurement_cmd[@]}" > "$measurement_log" 2>&1 &
  local measurement_pid=$!
  local measurement_elapsed=0
  while kill -0 "$measurement_pid" 2>/dev/null; do
    sleep 10
    measurement_elapsed=$((measurement_elapsed + 10))
    if kill -0 "$measurement_pid" 2>/dev/null; then
      echo "  Measurement still running for $target_id (${measurement_elapsed}s elapsed)..." | tee -a "$run_log"
    fi
  done
  wait "$measurement_pid"
  local wrk_status=$?
  set -e

  touch "$sampler_stop_file"
  if [[ -n "$sampler_pid" ]]; then
    wait "$sampler_pid" || true
  fi

  local jcmd_json
  jcmd_json="$(capture_jcmd_metrics "$target_pid" "$run_output_dir")"

  if (( target_started == 1 )); then
    "$TARGET_STOP_SCRIPT" "$target_id" >> "$run_log" 2>&1 || true
    target_started=0
  fi

  if [[ "$wrk_status" -ne 0 ]]; then
    echo "ERROR: wrk measurement failed for ${target_id}" | tee -a "$run_log"
    return 1
  fi

  local wrk_out=""
  wrk_out="$(cat "$measurement_log")"
  echo "$wrk_out" | tee -a "$run_log"

  throughput_rps="$(awk '/Requests\/sec:/ {print $2; exit}' <<< "$wrk_out")"
  total_requests="$(awk '/requests in/ {gsub(/,/, "", $1); print $1; exit}' <<< "$wrk_out")"
  latency_p99_us="$(to_microseconds "$(awk '$1 == "99%" {print $2; exit}' <<< "$wrk_out")")"
  non2xx_errors="$(awk '/Non-2xx or 3xx responses:/ {print $5; exit}' <<< "$wrk_out")"
  socket_errors="$(awk -F'[:, ]+' '/Socket errors:/ {print ($4 + $6 + $8 + $10); exit}' <<< "$wrk_out")"

  if [[ ! "$throughput_rps" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    throughput_rps="0"
  fi
  if [[ ! "$total_requests" =~ ^[0-9]+$ ]]; then
    total_requests="0"
  fi
  if [[ ! "$latency_p99_us" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    latency_p99_us="0"
  fi
  if [[ ! "$non2xx_errors" =~ ^[0-9]+$ ]]; then
    non2xx_errors="0"
  fi
  if [[ ! "$socket_errors" =~ ^[0-9]+$ ]]; then
    socket_errors="0"
  fi

  total_errors=$((non2xx_errors + socket_errors))
  error_rate_pct="$(LC_ALL=C awk -v errors="$total_errors" -v total="$total_requests" 'BEGIN {if (total > 0) printf "%.6f", (errors * 100.0) / total; else print "0.000000"}')"

  local resource_summary=""
  resource_summary="$(summarize_resource_samples "$resource_samples_file")"
  cpu_time_seconds="${resource_summary%%|*}"
  local remainder="${resource_summary#*|}"
  rss_kb_avg="${remainder%%|*}"
  resource_sample_count="${remainder##*|}"

  requests_per_cpu_second="$(LC_ALL=C awk -v req="$total_requests" -v cpu="$cpu_time_seconds" 'BEGIN {if (cpu > 0) printf "%.6f", req / cpu; else print "0.000000"}')"
  rps_per_gb_rss="$(LC_ALL=C awk -v rps="$throughput_rps" -v rsskb="$rss_kb_avg" 'BEGIN {gb = rsskb / 1048576.0; if (gb > 0) printf "%.6f", rps / gb; else print "0.000000"}')"

  quality_gate_p99_ok="$(LC_ALL=C awk -v p99="$latency_p99_us" -v maxp99="$QUALITY_GATE_P99_MAX_US" 'BEGIN {if (p99 <= maxp99) print "true"; else print "false"}')"
  quality_gate_error_rate_ok="$(LC_ALL=C awk -v err="$error_rate_pct" -v maxerr="$QUALITY_GATE_ERROR_RATE_MAX_PCT" 'BEGIN {if (err <= maxerr) print "true"; else print "false"}')"
  if [[ "$quality_gate_p99_ok" == "true" && "$quality_gate_error_rate_ok" == "true" ]]; then
    quality_gate_pass="true"
  fi

  benchmark_tool_version="$(wrk --version 2>&1 | head -1 || true)"
  if [[ -z "$benchmark_tool_version" ]]; then
    benchmark_tool_version="unknown"
  fi

  target_commit_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$target_commit_sha" ]]; then
    target_commit_sha="unknown"
  fi

  java_settings="$(java -XshowSettings:properties -version 2>&1 || true)"
  if [[ -n "$java_settings" ]]; then
    jdk_vendor="$(awk -F' = ' '/^[[:space:]]*java.vendor = / {print $2; exit}' <<< "$java_settings" | xargs || true)"
    if [[ -z "$jdk_vendor" ]]; then
      jdk_vendor="$(awk -F' = ' '/^[[:space:]]*java.vm.vendor = / {print $2; exit}' <<< "$java_settings" | xargs || true)"
    fi
    jdk_version="$(awk -F' = ' '/^[[:space:]]*java.version = / {print $2; exit}' <<< "$java_settings" | xargs || true)"
  fi
  if [[ -z "$jdk_vendor" ]]; then
    jdk_vendor="unknown"
  fi
  if [[ -z "$jdk_version" ]]; then
    jdk_version="unknown"
  fi

  if [[ -z "${run_hardware_profile//[[:space:]]/}" ]]; then
    run_hardware_profile="unknown"
  fi

  target_classification="${TARGET_TIER[$target_id]:-unknown}/${TARGET_PROTOCOL[$target_id]:-unknown}/${TARGET_LAUNCHER[$target_id]:-unknown}"

  case "$target_id" in
    exeris-community)
      target_java_opts="${EXERIS_JAVA_OPTS:-}"
      ;;
    spring-hibernate)
      target_java_opts="${SPRING_JAVA_OPTS:-}"
      ;;
    quarkus-hibernate)
      target_java_opts="${QUARKUS_JAVA_OPTS:-}"
      ;;
    *)
      target_java_opts=""
      ;;
  esac

  if [[ -n "${target_java_opts//[[:space:]]/}" ]]; then
    read -r -a target_jvm_flags <<< "$target_java_opts"
  fi
  jvm_flags_json="$(json_array_from_strings target_jvm_flags)"

  jq -n \
    --arg schema_version "1" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg scenario_id "$SCENARIO_ID" \
    --arg scenario_endpoint_path "$SCENARIO_ENDPOINT_PATH" \
    --arg contract_id "$CONTRACT_ID" \
    --arg benchmark_url "$benchmark_url" \
    --arg target_id "$target_id" \
    --arg target_tier "${TARGET_TIER[$target_id]}" \
    --arg target_protocol "${TARGET_PROTOCOL[$target_id]}" \
    --arg launcher_mode "${TARGET_LAUNCHER[$target_id]}" \
    --arg target_commit_sha "$target_commit_sha" \
    --arg health_url "$health_url" \
    --arg target_order_label "$target_order_label" \
    --arg pair_id "$PAIR_ID" \
    --arg pair_order "$pair_order" \
    --arg completion_marker_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson ab_ba_orders_completed "$ab_ba_orders_completed_json" \
    --argjson sequence_index "$sequence_index" \
    --argjson sequence_total "$SEQUENCE_TOTAL" \
    --argjson repeat_index "$repeat_index" \
    --argjson vcpu_count "$vcpu_count" \
    --arg cpu_affinity "$current_cpu_affinity" \
    --arg profile_id "$profile_id" \
    --argjson max_ram_mb "$max_ram_mb" \
    --argjson threads "$THREADS_VALUE" \
    --argjson connections "$connections" \
    --argjson warmup_seconds "$WARMUP_SECONDS" \
    --argjson measurement_seconds "$MEASUREMENT_SECONDS" \
    --arg metadata_jdk_vendor "$jdk_vendor" \
    --arg metadata_jdk_version "$jdk_version" \
    --arg metadata_benchmark_tool_version "$benchmark_tool_version" \
    --arg metadata_hardware_profile "$run_hardware_profile" \
    --arg metadata_scenario_id "$SCENARIO_ID" \
    --arg metadata_target_classification "$target_classification" \
    --argjson metadata_jvm_flags "$jvm_flags_json" \
    --argjson throughput_rps "$throughput_rps" \
    --argjson total_requests "$total_requests" \
    --argjson latency_p99_us "$latency_p99_us" \
    --argjson error_rate_pct "$error_rate_pct" \
    '{
      schema_version: $schema_version,
      timestamp: $timestamp,
      benchmark_family: "runtime",
      scenario_id: $scenario_id,
      scenario_endpoint_path: $scenario_endpoint_path,
      contract_id: $contract_id,
      benchmark_url: $benchmark_url,
      target: {
        target_id: $target_id,
        tier: $target_tier,
        protocol_mode: $target_protocol,
        launcher_mode: $launcher_mode,
        commit_sha: $target_commit_sha,
        health_url: $health_url
      },
      run_config: {
        target_order_label: $target_order_label,
        pair_id: $pair_id,
        pair_order: $pair_order,
        ab_ba_orders_completed: $ab_ba_orders_completed,
        pair_completion_evidence: {
          invocation_order: $pair_order,
          completion_marker_utc: $completion_marker_utc
        },
        sequence_index: $sequence_index,
        sequence_total: $sequence_total,
        repeat_index: $repeat_index,
        vcpu_count: $vcpu_count,
        cpu_affinity: $cpu_affinity,
        profile_id: $profile_id,
        max_ram_mb: $max_ram_mb,
        threads: $threads,
        connections: $connections,
        warmup_seconds: $warmup_seconds,
        measurement_seconds: $measurement_seconds,
        metadata: {
          jdk_vendor: $metadata_jdk_vendor,
          jdk_version: $metadata_jdk_version,
          benchmark_tool_version: $metadata_benchmark_tool_version,
          hardware_profile: $metadata_hardware_profile,
          scenario_id: $metadata_scenario_id,
          target_classification: $metadata_target_classification,
          jvm_flags: $metadata_jvm_flags
        }
      },
      metrics: {
        throughput_rps: $throughput_rps,
        total_requests: $total_requests,
        latency_p99_us: $latency_p99_us,
        error_rate_pct: $error_rate_pct
      }
    }' > "$result_json"

  jq -n \
    --argjson cpu_time_seconds "$cpu_time_seconds" \
    --argjson rss_kb_avg "$rss_kb_avg" \
    --argjson resource_sample_count "$resource_sample_count" \
    --argjson pid_detected "$([[ -n "$target_pid" ]] && echo true || echo false)" \
    --argjson jcmd "$jcmd_json" \
    '{
      cpu_time_seconds: $cpu_time_seconds,
      rss_kb_avg: $rss_kb_avg,
      resource_sample_count: $resource_sample_count,
      pid_detected: $pid_detected,
      jcmd: $jcmd
    }' > "$resource_metrics_json"

  jq -n \
    --argjson requests_per_cpu_second "$requests_per_cpu_second" \
    --argjson rps_per_gb_rss "$rps_per_gb_rss" \
    --argjson threshold_p99_max_us "$QUALITY_GATE_P99_MAX_US" \
    --argjson threshold_error_rate_max_pct "$QUALITY_GATE_ERROR_RATE_MAX_PCT" \
    --argjson quality_gate_p99_ok "$quality_gate_p99_ok" \
    --argjson quality_gate_error_rate_ok "$quality_gate_error_rate_ok" \
    --argjson quality_gate_pass "$quality_gate_pass" \
    '{
      requests_per_cpu_second: $requests_per_cpu_second,
      rps_per_gb_rss: $rps_per_gb_rss,
      quality_gates: {
        threshold_p99_max_us: $threshold_p99_max_us,
        threshold_error_rate_max_pct: $threshold_error_rate_max_pct,
        p99_ok: $quality_gate_p99_ok,
        error_rate_ok: $quality_gate_error_rate_ok,
        pass: $quality_gate_pass
      }
    }' > "$efficiency_json"

  jq -n \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg benchmark_commit_sha "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
    --arg hardware_profile "$HARDWARE_PROFILE" \
    --arg contract_id "$CONTRACT_ID" \
    --arg scenario_id "$SCENARIO_ID" \
    --arg target_id "$target_id" \
    --arg target_tier "${TARGET_TIER[$target_id]}" \
    --arg protocol_mode "${TARGET_PROTOCOL[$target_id]}" \
    --arg benchmark_family "runtime" \
    --arg tool_name "wrk" \
    --arg tool_version "$benchmark_tool_version" \
    --argjson warmup_seconds "$WARMUP_SECONDS" \
    --argjson measurement_seconds "$MEASUREMENT_SECONDS" \
    --argjson threads "$THREADS_VALUE" \
    --argjson connections "$connections" \
    --argjson vcpu_count "$vcpu_count" \
    --arg cpu_affinity "$current_cpu_affinity" \
    --arg profile_id "$profile_id" \
    --argjson repeat_index "$repeat_index" \
    --arg pair_id "$PAIR_ID" \
    --arg pair_order "$pair_order" \
    --arg completion_marker_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson ab_ba_orders_completed "$ab_ba_orders_completed_json" \
    --argjson sequence_index "$sequence_index" \
    --arg target_order_label "$target_order_label" \
    '{
      timestamp: $timestamp,
      benchmark_commit_sha: $benchmark_commit_sha,
      hardware_profile: $hardware_profile,
      contract_id: $contract_id,
      scenario_id: $scenario_id,
      axis_labels: {
        tier: $target_tier,
        protocol_mode: $protocol_mode,
        benchmark_family: $benchmark_family,
        sequence_mode: "ab-ba-triad"
      },
      tool: {
        name: $tool_name,
        version: $tool_version
      },
      run_config: {
        warmup_seconds: $warmup_seconds,
        measurement_seconds: $measurement_seconds,
        threads: $threads,
        connections: $connections,
        vcpu_count: $vcpu_count,
        cpu_affinity: $cpu_affinity,
        profile_id: $profile_id,
        repeat_index: $repeat_index,
        pair_id: $pair_id,
        pair_order: $pair_order,
        ab_ba_orders_completed: $ab_ba_orders_completed,
        pair_completion_evidence: {
          invocation_order: $pair_order,
          completion_marker_utc: $completion_marker_utc
        },
        sequence_index: $sequence_index,
        target_order_label: $target_order_label,
        target_id: $target_id
      }
    }' > "$reproducibility_json"

  append_campaign_row \
    "$pair_order" \
    "$repeat_index" \
    "$connections" \
    "$profile_id" \
    "$max_ram_mb" \
    "$vcpu_count" \
    "$current_cpu_affinity" \
    "$target_order_label" \
    "$sequence_index" \
    "$target_id" \
    "$health_url" \
    "$benchmark_url" \
    "$throughput_rps" \
    "$total_requests" \
    "$latency_p99_us" \
    "$error_rate_pct" \
    "$cpu_time_seconds" \
    "$rss_kb_avg" \
    "$requests_per_cpu_second" \
    "$rps_per_gb_rss" \
    "$quality_gate_p99_ok" \
    "$quality_gate_error_rate_ok" \
    "$quality_gate_pass" \
    "$run_output_dir"

  return 0
}

validate_inputs() {
  validate_positive_integer "$WARMUP_SECONDS" "WARMUP_SECONDS"
  validate_positive_integer "$MEASUREMENT_SECONDS" "MEASUREMENT_SECONDS"
  validate_positive_integer "$THREADS_VALUE" "THREADS"
  validate_positive_integer "$REPEATS" "REPEATS"
  validate_positive_integer "$BENCH_DB_POOL_MIN_SIZE" "BENCH_DB_POOL_MIN_SIZE"
  validate_positive_integer "$BENCH_DB_POOL_MAX_SIZE" "BENCH_DB_POOL_MAX_SIZE"

  if [[ "$BENCH_ENABLE_NATIVE_MEMORY_TRACKING" != "0" && "$BENCH_ENABLE_NATIVE_MEMORY_TRACKING" != "1" ]]; then
    echo "ERROR: BENCH_ENABLE_NATIVE_MEMORY_TRACKING must be 0 or 1, got: ${BENCH_ENABLE_NATIVE_MEMORY_TRACKING}"
    exit 1
  fi

  validate_non_negative_decimal "$QUALITY_GATE_P99_MAX_US" "QUALITY_GATE_P99_MAX_US"
  validate_non_negative_decimal "$QUALITY_GATE_ERROR_RATE_MAX_PCT" "QUALITY_GATE_ERROR_RATE_MAX_PCT"
  parse_vcpu_levels

  if [[ -z "$ISO_CPU_AFFINITY" ]]; then
    ISO_CPU_AFFINITY="$(resolve_default_cpu_affinity)"
    if [[ -z "$ISO_CPU_AFFINITY" ]]; then
      echo "ERROR: ISO_CPU_AFFINITY not set and automatic CPU affinity detection failed"
      exit 1
    fi
    echo "WARNING: ISO_CPU_AFFINITY not set; auto-derived shared CPU affinity: ${ISO_CPU_AFFINITY}"
  fi

  BASE_CPU_AFFINITY="$ISO_CPU_AFFINITY"
  mapfile -t BASE_CPU_POOL < <(expand_cpu_affinity "$BASE_CPU_AFFINITY")

  if (( ${#BASE_CPU_POOL[@]} == 0 )); then
    echo "ERROR: No CPUs resolved from base affinity '${BASE_CPU_AFFINITY}'"
    exit 1
  fi

  local vcpu_level
  for vcpu_level in "${VCPU_LEVELS[@]}"; do
    if (( vcpu_level > ${#BASE_CPU_POOL[@]} )); then
      echo "ERROR: vCPU level ${vcpu_level} exceeds CPU base affinity capacity (${#BASE_CPU_POOL[@]})"
      exit 1
    fi
  done

  local profile_id
  for profile_id in "${PROFILE_IDS[@]}"; do
    validate_positive_integer "${PROFILE_EXERIS_HEAP_MB[$profile_id]}" "${profile_id} exeris heap"
    validate_positive_integer "${PROFILE_SPRING_HEAP_MB[$profile_id]}" "${profile_id} spring heap"
    validate_positive_integer "${PROFILE_QUARKUS_HEAP_MB[$profile_id]}" "${profile_id} quarkus heap"
    validate_positive_integer "${PROFILE_MAX_RAM_MB[$profile_id]}" "${profile_id} max RAM"
  done

  local c
  for c in "${CONNECTIONS[@]}"; do
    validate_positive_integer "$c" "connection"
  done

  local pair_order
  for pair_order in "${PAIR_ORDERS[@]}"; do
    if [[ "$pair_order" != "ab" && "$pair_order" != "ba" ]]; then
      echo "ERROR: Unsupported pair order '${pair_order}', expected ab or ba"
      exit 1
    fi
  done

  resolve_triad_target_contracts
}

mkdir -p "$CAMPAIGN_OUTPUT_DIR"

validate_inputs
write_csv_header
write_campaign_metadata

TOTAL_STEPS=$(( ${#VCPU_LEVELS[@]} * ${#PROFILE_IDS[@]} * ${#CONNECTIONS[@]} * REPEATS * ${#PAIR_ORDERS[@]} * SEQUENCE_TOTAL ))

echo ""
echo "============================================================"
echo "ISO-BUDGET SWEEP AB/BA TRIAD CAMPAIGN START"
echo "Repository: $REPO_ROOT"
echo "Campaign TS: $CAMPAIGN_TS"
echo "Output Root: $CAMPAIGN_OUTPUT_DIR"
echo "Scenario: $SCENARIO_ID (${SCENARIO_ENDPOINT_PATH})"
echo "Contract: $CONTRACT_ID"
echo "Hardware Profile: $HARDWARE_PROFILE"
echo "CPU Base Affinity: $BASE_CPU_AFFINITY"
echo "vCPU Levels: ${VCPU_LEVELS[*]}"
echo "Triad Sequence (AB/BA): ab=A->B->C, ba=B->A->C"
echo "============================================================"

prebuild_campaign_targets

for vcpu_count in "${VCPU_LEVELS[@]}"; do
  CURRENT_CPU_AFFINITY="$(derive_cpu_affinity_for_vcpu_count BASE_CPU_POOL "$vcpu_count")"

  for profile_id in "${PROFILE_IDS[@]}"; do
    apply_iso_budget_profile "$profile_id" "$CURRENT_CPU_AFFINITY"
    max_ram_mb="${PROFILE_MAX_RAM_MB[$profile_id]}"

    for connections in "${CONNECTIONS[@]}"; do
      for ((repeat_index=1; repeat_index<=REPEATS; repeat_index++)); do
        for pair_order in "${PAIR_ORDERS[@]}"; do
          ab_ba_orders_completed_json="$(resolve_ab_ba_orders_completed_json "$pair_order")"

          for ((seq_idx=1; seq_idx<=SEQUENCE_TOTAL; seq_idx++)); do
            CURRENT_STEP=$((CURRENT_STEP + 1))
            sequence_resolution="$(resolve_sequence_target_for_pair_order "$pair_order" "$seq_idx")"
            target_order_label="${sequence_resolution%%|*}"
            target_id="${sequence_resolution##*|}"

            run_triad_target_once \
              "$profile_id" \
              "$connections" \
              "$repeat_index" \
              "$max_ram_mb" \
              "$vcpu_count" \
              "$CURRENT_CPU_AFFINITY" \
              "$pair_order" \
              "$ab_ba_orders_completed_json" \
              "$seq_idx" \
              "$target_order_label" \
              "$target_id"
          done
        done
      done
    done
  done
done

echo ""
echo "============================================================"
echo "ISO-BUDGET SWEEP AB/BA TRIAD CAMPAIGN COMPLETED"
echo "============================================================"
echo "Target runs: $TOTAL_STEPS"
echo "Summary CSV: $CAMPAIGN_SUMMARY_CSV"
echo "Campaign metadata: ${CAMPAIGN_OUTPUT_DIR}/campaign-metadata.json"
