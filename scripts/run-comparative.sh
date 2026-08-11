#!/usr/bin/env bash
set -euo pipefail

# run-comparative.sh — Main orchestrator for comparative benchmark runs.
#
# Implements 8-stage execution model for reproducible cross-target comparison.
#
# Usage:
#   scripts/run-comparative.sh \
#     --target-a  exeris-community \
#     --target-b  spring-hibernate     \
#     --scenario-id entity-read-by-id     \
#     --contract-id fixed_contract_v1     \
#     --output-dir results/raw/entity-read-by-id/YYYYMMDD-comparative-NNN \
#     [--measurement-seconds 60]          \
#     [--warmup-seconds 60]               \
#     [--threads 4]                       \
#     [--connections 32]                  \
#     [--dry-run]
#
# In dry-run mode: stages 1, 2 (prerequisites only), 3 run; then writes
# dry-run-summary.json and exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_CONTRACT_REGISTRY="${REPO_ROOT}/runtime/drivers/target-contract-registry.sh"
READINESS_LIB="${REPO_ROOT}/tools/bench/lib/readiness.sh"

if [[ ! -f "$READINESS_LIB" ]]; then
  echo "ERROR: readiness library not found: $READINESS_LIB" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$READINESS_LIB"

# shellcheck source=/dev/null
source "$TARGET_CONTRACT_REGISTRY"

# OS-level sidecar samplers (mpstat/pidstat). Optional: used for the per-target DB-CPU
# sampler over the Postgres cpuset during the measurement window (fine-grained 1s cadence,
# independent of any host sar cron). Degrades to a no-op when the library or the sampling
# tools are absent.
OS_SAMPLER_LIB="${REPO_ROOT}/tools/bench/lib/os-sampler.sh"
if [[ -f "$OS_SAMPLER_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$OS_SAMPLER_LIB"
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TARGET_A=""
TARGET_B=""
SCENARIO_ID=""
CONTRACT_ID=""
OUTPUT_DIR=""
MEASUREMENT_SECONDS="${MEASUREMENT_SECONDS:-120}"
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
DRY_RUN=0
BENCH_SKIP_SCENARIO_INFRA_SETUP="${BENCH_SKIP_SCENARIO_INFRA_SETUP:-0}"
ENTITY_READ_PREFLIGHT_TIMEOUT="${ENTITY_READ_PREFLIGHT_TIMEOUT:-60}"

# Optional explicit ports (resolved from target contracts when not provided)
TARGET_A_PORT="${TARGET_A_PORT:-}"
TARGET_B_PORT="${TARGET_B_PORT:-}"

# Wrk defaults derived from fixed_contract_v1 defaults
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
LOADGEN_CPU_AFFINITY="${LOADGEN_CPU_AFFINITY:-}"
PERF_STAT_REQUIRED="${BENCHMARK_REQUIRE_PERF_STAT:-0}"
PERF_STAT_CAPTURE_REQUESTED="${BENCHMARK_CAPTURE_PERF_STAT:-0}"

# Protocol-as-run-axis (additive). A fixed_contract MAY omit protocol_mode/transport_mode
# (protocol-agnostic); when omitted, the effective protocol comes from this run axis.
# When a contract pins protocol_mode (legacy), the pin wins and the axis may not override it.
# Reuse the existing downstream env name BENCH_PROTOCOL_MODE_OVERRIDE (tools/bench/lib/protocol.sh,
# run-guided.sh) for continuity, plus a friendly BENCH_PROTOCOL_MODE alias.
PROTOCOL_MODE_AXIS="${BENCH_PROTOCOL_MODE_OVERRIDE:-${BENCH_PROTOCOL_MODE:-}}"
TRANSPORT_MODE_AXIS="${BENCH_TRANSPORT_MODE:-}"
# Driver-capability allowlist: the wrk comparative driver serves cleartext HTTP/1.1 only
# (honesty guard mirroring run-guided.sh). Effective protocols outside this set fail closed
# until an h2-capable comparative driver is wired. One-line widening point when that lands.
COMPARATIVE_DRIVER_PROTOCOL_ALLOWLIST="${BENCH_COMPARATIVE_PROTOCOL_ALLOWLIST:-h1}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-a)           TARGET_A="$2";            shift 2 ;;
    --target-b)           TARGET_B="$2";            shift 2 ;;
    --scenario-id)        SCENARIO_ID="$2";         shift 2 ;;
    --contract-id)        CONTRACT_ID="$2";         shift 2 ;;
    --output-dir)         OUTPUT_DIR="$2";          shift 2 ;;
    --measurement-seconds) MEASUREMENT_SECONDS="$2"; shift 2 ;;
    --warmup-seconds)     WARMUP_SECONDS="$2";      shift 2 ;;
    --threads)            THREADS="$2";             shift 2 ;;
    --connections)        CONNECTIONS="$2";         shift 2 ;;
    --protocol-mode)      PROTOCOL_MODE_AXIS="$2";  shift 2 ;;
    --transport-mode)     TRANSPORT_MODE_AXIS="$2"; shift 2 ;;
    --dry-run)            DRY_RUN=1;                shift 1 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Required parameter validation
# ---------------------------------------------------------------------------
missing=()
[[ -z "$TARGET_A"    ]] && missing+=("--target-a")
[[ -z "$TARGET_B"    ]] && missing+=("--target-b")
[[ -z "$SCENARIO_ID" ]] && missing+=("--scenario-id")
[[ -z "$CONTRACT_ID" ]] && missing+=("--contract-id")
[[ -z "$OUTPUT_DIR"  ]] && missing+=("--output-dir")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Required arguments missing: ${missing[*]}" >&2
  exit 1
fi

SCENARIO_DIAGNOSTICS_DIR="${BENCH_SCENARIO_DIAGNOSTICS_DIR:-${OUTPUT_DIR}/logs/scenario-diagnostics}"
SCENARIO_DB_DIAGNOSTICS_HOOK="${REPO_ROOT}/scenarios/${SCENARIO_ID}/capture-db-diagnostics.sh"
POST_MEASUREMENT_DIAGNOSTICS_ATTEMPTED=0
MEASUREMENT_STAGE_STARTED=0

# Scenario-specific pg_stat_statements helpers (optional). When present, run_wrk_target
# brackets each target's measurement window with a per-target baseline/final snapshot and
# emits a delta — so pg_stat attribution is per leaf/per target and cannot be clobbered by
# the next leaf's reset (the shared post-measurement snapshot alone could not do this).
SCENARIO_PGSS_WRAPPER="${REPO_ROOT}/scenarios/${SCENARIO_ID}/pg_stat_statements-wrapper.sh"
PGSS_WRAPPER_AVAILABLE=0
if [[ -f "$SCENARIO_PGSS_WRAPPER" ]]; then
  # shellcheck source=/dev/null
  if source "$SCENARIO_PGSS_WRAPPER" 2>/dev/null; then
    PGSS_WRAPPER_AVAILABLE=1
  fi
fi

run_post_measurement_diagnostics() {
  if [[ "$MEASUREMENT_STAGE_STARTED" != "1" ]]; then
    return 0
  fi

  if [[ "$POST_MEASUREMENT_DIAGNOSTICS_ATTEMPTED" == "1" ]]; then
    return 0
  fi
  POST_MEASUREMENT_DIAGNOSTICS_ATTEMPTED=1

  if [[ ! -f "$SCENARIO_DB_DIAGNOSTICS_HOOK" ]]; then
    return 0
  fi

  mkdir -p "$SCENARIO_DIAGNOSTICS_DIR" || true
  if ! BENCH_SCENARIO_DIAGNOSTICS_DIR="$SCENARIO_DIAGNOSTICS_DIR" \
       BENCH_DB_DIAGNOSTICS_PHASE="post-measurement" \
       BENCH_CAPTURE_DB_EXPLAIN="${BENCH_CAPTURE_DB_EXPLAIN:-0}" \
       bash "$SCENARIO_DB_DIAGNOSTICS_HOOK"; then
    echo "WARNING: post-measurement scenario diagnostics failed (best-effort), hook=${SCENARIO_DB_DIAGNOSTICS_HOOK}" >&2
    return 0
  fi

  echo "  ${GREEN}✓${NC} Scenario post-measurement diagnostics captured: ${SCENARIO_DIAGNOSTICS_DIR}"
  return 0
}

comparative_exit_trap() {
  local rc="${1:-0}"
  trap - EXIT
  if [[ "$rc" -ne 0 ]]; then
    run_post_measurement_diagnostics || true
  fi
  exit "$rc"
}

trap 'comparative_exit_trap $?' EXIT

# Dependency check
for cmd in jq uuidgen date curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    # uuidgen fallback
    if [[ "$cmd" == "uuidgen" ]]; then
      if [[ ! -r /proc/sys/kernel/random/uuid ]]; then
        echo "ERROR: Neither uuidgen nor /proc/sys/kernel/random/uuid available." >&2
        exit 1
      fi
    else
      echo "ERROR: Required command '${cmd}' not found in PATH." >&2
      exit 1
    fi
  fi
done

validate_binary_env_flag() {
  local value="${1:-}"
  local label="${2:-flag}"

  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "ERROR: ${label} must be 0 or 1 (got '$value')" >&2
    exit 1
  fi
}

validate_perf_stat_config() {
  validate_binary_env_flag "$PERF_STAT_REQUIRED" "BENCHMARK_REQUIRE_PERF_STAT"
  validate_binary_env_flag "$PERF_STAT_CAPTURE_REQUESTED" "BENCHMARK_CAPTURE_PERF_STAT"

  if [[ "$PERF_STAT_REQUIRED" == "1" || "$PERF_STAT_CAPTURE_REQUESTED" == "1" ]]; then
    local perf_no_scale="${BENCHMARK_PERF_NO_SCALE:-1}"

    validate_binary_env_flag "$perf_no_scale" "BENCHMARK_PERF_NO_SCALE"

    if ! command -v perf >/dev/null 2>&1; then
      if [[ "$PERF_STAT_REQUIRED" == "1" ]]; then
        echo "ERROR: BENCHMARK_REQUIRE_PERF_STAT=1 requires perf command" >&2
      else
        echo "ERROR: perf-stat capture requested but perf command is unavailable" >&2
      fi
      exit 1
    fi
  fi
}

validate_perf_stat_config

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

ts_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

extract_health_port() {
  local url="${1:-}"
  if [[ "$url" =~ ^https?://[^/:]+:([0-9]+)(/|$) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

comparative_base_url_from_health_url() {
  local health_url="${1:-}"
  local base_url=""

  if ! base_url="$(bench_normalize_health_base_url "$health_url")"; then
    echo "CONFIG_ERROR: unable to derive base URL from health_url '${health_url}'" >&2
    return 64
  fi

  printf '%s\n' "$base_url"
}

comparative_endpoint_url_from_health_url() {
  local health_url="${1:-}"
  local path="${2:-}"
  local base_url=""

  if ! base_url="$(comparative_base_url_from_health_url "$health_url")"; then
    return 64
  fi

  printf '%s%s\n' "$base_url" "$path"
}

extract_endpoint_path_from_method_endpoint() {
  local method_endpoint="${1:-}"
  # Input format: "GET /api/v1/users" -> extract "/api/v1/users"
  echo "$method_endpoint" | awk '{print $NF}'
}

resolve_scenario_endpoint_path() {
  local scenario_json="$1"
  local contract_id="$2"
  local endpoint
  
  # Try fixed_contracts[contract].endpoint first
  endpoint="$(jq -r --arg c "$contract_id" '.fixed_contracts[$c].endpoint // empty' "$scenario_json" 2>/dev/null || echo '')"
  if [[ -n "$endpoint" && "$endpoint" != "null" ]]; then
    echo "$(extract_endpoint_path_from_method_endpoint "$endpoint")"
    return 0
  fi
  
  # Fallback to .endpoint at top level
  endpoint="$(jq -r '.endpoint // empty' "$scenario_json" 2>/dev/null || echo '')"
  if [[ -n "$endpoint" && "$endpoint" != "null" ]]; then
    echo "$(extract_endpoint_path_from_method_endpoint "$endpoint")"
    return 0
  fi
  
  # Final fallback to hardcoded users endpoint default
  echo "/api/v1/users"
}

comparative_contract_execution_profile_id() {
  local scenario_json="$1"
  local contract_id="$2"

  jq -r --arg c "$contract_id" '.fixed_contracts[$c].execution_profile_id // empty' "$scenario_json" 2>/dev/null || true
}

comparative_execution_profile_is_constrained() {
  local execution_profile_id="${1:-}"
  [[ -n "$execution_profile_id" && "$execution_profile_id" == runtime-constrained-* ]]
}

comparative_track_is_constrained() {
  local track_id="${1:-}"
  [[ -n "$track_id" && "$track_id" == track-c* ]]
}

comparative_contract_is_constrained() {
  local scenario_json="$1"
  local contract_id="$2"
  local execution_profile_id=""

  if [[ "$contract_id" == fixed_contract_runtime_h1_constrained* || "$contract_id" == *_constrained_* ]]; then
    return 0
  fi

  execution_profile_id="$(comparative_contract_execution_profile_id "$scenario_json" "$contract_id")"
  comparative_execution_profile_is_constrained "$execution_profile_id"
}

comparative_path_is_constrained() {
  local path_value="${1:-}"
  local execution_profile_id="${2:-}"
  local track_id="${3:-}"

  if [[ -n "$path_value" && ( "$path_value" == */results/constrained/* || "$path_value" == results/constrained/* ) ]]; then
    return 0
  fi

  if comparative_execution_profile_is_constrained "$execution_profile_id"; then
    return 0
  fi

  if comparative_track_is_constrained "$track_id"; then
    return 0
  fi

  return 1
}

comparative_fail_closed_constrained() {
  echo "CONFIG_ERROR: constrained execution profiles are exploratory only and must not run through run-comparative.sh" >&2
  exit 64
}

detect_pid_for_port() {
  local port="$1"
  local pid
  
  # Try lsof first
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -ti :"$port" 2>/dev/null | head -1 || true)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
  fi
  
  # Try ss as fallback
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -tlnpH 2>/dev/null | grep ":$port " | awk '{print $NF}' | grep -oP '\d+(?=/)' | head -1 || true)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
  fi
  
  return 1
}

read_process_smaps_rss_kb() {
  local pid="$1"
  local smaps_rollup="/proc/${pid}/smaps_rollup"

  if [[ ! -r "$smaps_rollup" ]]; then
    echo 0
    return 0
  fi

  awk '/^Rss:/ {print $2; found=1; exit} END {if (!found) print 0}' "$smaps_rollup" 2>/dev/null || echo 0
}

read_cgroup_memory_current_kb() {
  local file_path="$1"
  local bytes

  if [[ ! -r "$file_path" ]]; then
    echo 0
    return 0
  fi

  bytes="$(cat "$file_path" 2>/dev/null || echo 0)"
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    LC_ALL=C awk -v b="$bytes" 'BEGIN {printf "%d", int(b / 1024)}'
  else
    echo 0
  fi
}

resolve_cgroup_memory_current_kb() {
  local pid="$1"
  local cgroup_file="/proc/${pid}/cgroup"
  local path controllers raw_value
  local v2_path
  local -a candidates=()

  if [[ ! -r "$cgroup_file" ]]; then
    echo 0
    return 0
  fi

  # cgroup v2 format: 0::/path
  path="$(awk -F: '$1=="0" && $2=="" {print $3; exit}' "$cgroup_file" 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    v2_path="/sys/fs/cgroup${path}/memory.current"
    raw_value="$(read_cgroup_memory_current_kb "$v2_path")"
    if [[ "$raw_value" =~ ^[0-9]+$ && "$raw_value" -gt 0 ]]; then
      echo "$raw_value"
      return 0
    fi
  fi

  # cgroup v1 memory controller format: N:...memory...:/path
  while IFS=: read -r _ controllers path; do
    if [[ ",$controllers," != *",memory,"* ]]; then
      continue
    fi

    candidates=(
      "/sys/fs/cgroup/memory${path}/memory.current"
      "/sys/fs/cgroup/memory${path}/memory.usage_in_bytes"
      "/sys/fs/cgroup${path}/memory.current"
      "/sys/fs/cgroup${path}/memory.usage_in_bytes"
    )

    for candidate in "${candidates[@]}"; do
      raw_value="$(read_cgroup_memory_current_kb "$candidate")"
      if [[ "$raw_value" =~ ^[0-9]+$ && "$raw_value" -gt 0 ]]; then
        echo "$raw_value"
        return 0
      fi
    done
  done < "$cgroup_file"

  echo 0
}

read_proc_sample() {
  local pid="$1"
  if [[ ! -d "/proc/$pid" ]]; then
    return 1
  fi
  
  local epoch_s utime stime vmrss_kb vmsize_kb vmhwm_kb threads smaps_rss_kb cgroup_memory_current_kb
  epoch_s="$(date +%s)"
  
  # Read /proc/<pid>/stat
  if [[ ! -r "/proc/$pid/stat" ]]; then
    return 1
  fi
  utime="$(awk '{print $14}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
  stime="$(awk '{print $15}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
  
  # Read /proc/<pid>/status for memory and thread counters.
  if [[ ! -r "/proc/$pid/status" ]]; then
    return 1
  fi
  vmrss_kb="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
  vmsize_kb="$(awk '/^VmSize:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
  vmhwm_kb="$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
  threads="$(awk '/^Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
  smaps_rss_kb="$(read_process_smaps_rss_kb "$pid")"
  cgroup_memory_current_kb="$(resolve_cgroup_memory_current_kb "$pid")"
  
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$epoch_s" "$utime" "$stime" "$vmrss_kb" "$vmsize_kb" "$vmhwm_kb" "$threads" "$smaps_rss_kb" "$cgroup_memory_current_kb"
}

start_resource_sampler() {
  local pid="$1"
  local csv_file="$2"
  local interval_seconds="${3:-1}"
  
  # Write CSV header
  echo "epoch_s,utime_ticks,stime_ticks,vmrss_kb,vmsize_kb,vmhwm_kb,threads,smaps_rss_kb,cgroup_memory_current_kb" > "$csv_file"
  
  # Foreground loop (backgrounding controlled by caller)
  while [[ -d "/proc/$pid" ]]; do
    read_proc_sample "$pid" >> "$csv_file" 2>/dev/null || true
    sleep "$interval_seconds"
  done
}

summarize_resource_samples() {
  local csv_file="$1"
  local output_json="$2"
  local measurement_seconds="$3"
  
  if [[ ! -f "$csv_file" ]]; then
    jq -n \
      --arg note "resource samples file not found" \
      '{
        sample_count: 0,
        cpu_time_seconds: 0,
        cpu_util_percent_of_one_core: 0,
        avg_cores_used: 0,
        host_logical_cpus: 0,
        cpu_util_percent_of_host_total: 0,
        vmrss_kb_min: 0,
        vmrss_kb_max: 0,
        vmrss_kb_avg: 0,
        vmsize_kb_min: 0,
        vmsize_kb_max: 0,
        vmsize_kb_avg: 0,
        vmhwm_kb_max: 0,
        threads_min: 0,
        threads_max: 0,
        threads_avg: 0,
        smaps_rss_kb_min: 0,
        smaps_rss_kb_max: 0,
        smaps_rss_kb_avg: 0,
        cgroup_memory_current_kb_min: 0,
        cgroup_memory_current_kb_max: 0,
        cgroup_memory_current_kb_avg: 0,
        rss_kb_min: 0,
        rss_kb_max: 0,
        rss_kb_avg: 0,
        note: $note
      }' > "$output_json"
    return 0
  fi
  
  local sample_count cpu_time_seconds cpu_util_pct avg_cores_used host_logical_cpus cpu_util_pct_host
  local vmrss_min vmrss_max vmrss_avg vmsize_min vmsize_max vmsize_avg vmhwm_max
  local threads_min threads_max threads_avg
  local smaps_rss_min smaps_rss_max smaps_rss_avg cgroup_memory_current_min cgroup_memory_current_max cgroup_memory_current_avg
  local rss_pref_min rss_pref_max rss_pref_avg
  local CLK_TCK=100  # Standard Linux value
  
  # Calculate statistics from CSV (skip header)
  sample_count="$(tail -n +2 "$csv_file" | wc -l | awk '{print $1}')"
  
  if [[ "$sample_count" -lt 2 ]]; then
    jq -n \
      --arg note "insufficient samples" \
      '{
        sample_count: 0,
        cpu_time_seconds: 0,
        cpu_util_percent_of_one_core: 0,
        avg_cores_used: 0,
        host_logical_cpus: 0,
        cpu_util_percent_of_host_total: 0,
        vmrss_kb_min: 0,
        vmrss_kb_max: 0,
        vmrss_kb_avg: 0,
        vmsize_kb_min: 0,
        vmsize_kb_max: 0,
        vmsize_kb_avg: 0,
        vmhwm_kb_max: 0,
        threads_min: 0,
        threads_max: 0,
        threads_avg: 0,
        smaps_rss_kb_min: 0,
        smaps_rss_kb_max: 0,
        smaps_rss_kb_avg: 0,
        cgroup_memory_current_kb_min: 0,
        cgroup_memory_current_kb_max: 0,
        cgroup_memory_current_kb_avg: 0,
        rss_kb_min: 0,
        rss_kb_max: 0,
        rss_kb_avg: 0,
        note: $note
      }' > "$output_json"
    return 0
  fi
  
  local first_utime first_stime last_utime last_stime
# Best-effort stat pipelines below use `... | head -1` / `sort -n | head -1`. head closes the
# pipe after the first line, so the upstream tail/sort can take SIGPIPE (exit 141). Under
# `set -o pipefail` + errexit that RACILY aborts the whole run once the CSV is large enough that
# sort's output does not finish in one atomic pipe write — a real 900s measurement (~840 rows)
# loses the race and silently kills every leaf at post-measurement, while a 15s debug run (~15
# rows, one atomic write) never does. The captured min/first value is already correct (head read
# it); only the benign SIGPIPE exit code must not abort. Re-armed right after the block.
  set +o pipefail
  first_utime="$(tail -n +2 "$csv_file" | head -1 | cut -d, -f2)"
  first_stime="$(tail -n +2 "$csv_file" | head -1 | cut -d, -f3)"
  last_utime="$(tail -n +2 "$csv_file" | tail -1 | cut -d, -f2)"
  last_stime="$(tail -n +2 "$csv_file" | tail -1 | cut -d, -f3)"
  
  local delta_ticks
  delta_ticks=$(( (last_utime - first_utime) + (last_stime - first_stime) ))
  cpu_time_seconds=$(LC_ALL=C awk -v d="$delta_ticks" -v clk="$CLK_TCK" 'BEGIN {printf "%.2f", d / clk}')
  cpu_time_seconds="${cpu_time_seconds/,/.}"
  
  cpu_util_pct="0"
  avg_cores_used="0"
  host_logical_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [[ -z "$host_logical_cpus" || ! "$host_logical_cpus" =~ ^[0-9]+$ || "$host_logical_cpus" -le 0 ]]; then
    host_logical_cpus="$(nproc 2>/dev/null || true)"
  fi
  if [[ -z "$host_logical_cpus" || ! "$host_logical_cpus" =~ ^[0-9]+$ || "$host_logical_cpus" -le 0 ]]; then
    host_logical_cpus=1
  fi
  if [[ "$measurement_seconds" -gt 0 ]]; then
    cpu_util_pct=$(LC_ALL=C awk -v c="$cpu_time_seconds" -v m="$measurement_seconds" 'BEGIN {printf "%.2f", (c / m) * 100}')
    cpu_util_pct="${cpu_util_pct/,/.}"
    avg_cores_used=$(LC_ALL=C awk -v c="$cpu_time_seconds" -v m="$measurement_seconds" 'BEGIN {printf "%.4f", c / m}')
    avg_cores_used="${avg_cores_used/,/.}"
  fi
  cpu_util_pct_host=$(LC_ALL=C awk -v p="$cpu_util_pct" -v h="$host_logical_cpus" 'BEGIN {if (h > 0) printf "%.2f", p / h; else print 0}')
  cpu_util_pct_host="${cpu_util_pct_host/,/.}"
  
  vmrss_min="$(tail -n +2 "$csv_file" | cut -d, -f4 | sort -n | head -1)"
  vmrss_max="$(tail -n +2 "$csv_file" | cut -d, -f4 | sort -n | tail -1)"
  vmrss_avg="$(tail -n +2 "$csv_file" | cut -d, -f4 | LC_ALL=C awk '{sum+=$1} END {if (NR>0) printf "%.0f", sum/NR; else print 0}')"
  vmsize_min="$(tail -n +2 "$csv_file" | cut -d, -f5 | sort -n | head -1)"
  vmsize_max="$(tail -n +2 "$csv_file" | cut -d, -f5 | sort -n | tail -1)"
  vmsize_avg="$(tail -n +2 "$csv_file" | cut -d, -f5 | LC_ALL=C awk '{sum+=$1} END {if (NR>0) printf "%.0f", sum/NR; else print 0}')"
  vmhwm_max="$(tail -n +2 "$csv_file" | cut -d, -f6 | sort -n | tail -1)"
  threads_min="$(tail -n +2 "$csv_file" | cut -d, -f7 | sort -n | head -1)"
  threads_max="$(tail -n +2 "$csv_file" | cut -d, -f7 | sort -n | tail -1)"
  threads_avg="$(tail -n +2 "$csv_file" | cut -d, -f7 | LC_ALL=C awk '{sum+=$1} END {if (NR>0) printf "%.2f", sum/NR; else print 0}')"
  smaps_rss_min="$(tail -n +2 "$csv_file" | cut -d, -f8 | sort -n | head -1)"
  smaps_rss_max="$(tail -n +2 "$csv_file" | cut -d, -f8 | sort -n | tail -1)"
  smaps_rss_avg="$(tail -n +2 "$csv_file" | cut -d, -f8 | LC_ALL=C awk '{sum+=$1} END {if (NR>0) printf "%.0f", sum/NR; else print 0}')"
  cgroup_memory_current_min="$(tail -n +2 "$csv_file" | cut -d, -f9 | sort -n | head -1)"
  cgroup_memory_current_max="$(tail -n +2 "$csv_file" | cut -d, -f9 | sort -n | tail -1)"
  cgroup_memory_current_avg="$(tail -n +2 "$csv_file" | cut -d, -f9 | LC_ALL=C awk '{sum+=$1} END {if (NR>0) printf "%.0f", sum/NR; else print 0}')"
  rss_pref_min="$(tail -n +2 "$csv_file" | LC_ALL=C awk -F, '{rss=(($8+0)>0?$8:$4); print rss}' | sort -n | head -1)"
  rss_pref_max="$(tail -n +2 "$csv_file" | LC_ALL=C awk -F, '{rss=(($8+0)>0?$8:$4); print rss}' | sort -n | tail -1)"
  rss_pref_avg="$(tail -n +2 "$csv_file" | LC_ALL=C awk -F, '{rss=(($8+0)>0?$8:$4); sum+=rss} END {if (NR>0) printf "%.0f", sum/NR; else print 0}')"
  set -o pipefail  # re-arm errexit-on-pipe-failure after the best-effort stat pipelines above

  jq -n \
    --argjson sample_count "$sample_count" \
    --arg cpu_time_seconds "$cpu_time_seconds" \
    --arg cpu_util_pct "$cpu_util_pct" \
    --arg avg_cores_used "$avg_cores_used" \
    --argjson host_logical_cpus "$host_logical_cpus" \
    --arg cpu_util_pct_host "$cpu_util_pct_host" \
    --argjson vmrss_min "$vmrss_min" \
    --argjson vmrss_max "$vmrss_max" \
    --argjson vmrss_avg "$vmrss_avg" \
    --argjson vmsize_min "$vmsize_min" \
    --argjson vmsize_max "$vmsize_max" \
    --argjson vmsize_avg "$vmsize_avg" \
    --argjson vmhwm_max "$vmhwm_max" \
    --argjson threads_min "$threads_min" \
    --argjson threads_max "$threads_max" \
    --argjson smaps_rss_min "$smaps_rss_min" \
    --argjson smaps_rss_max "$smaps_rss_max" \
    --argjson smaps_rss_avg "$smaps_rss_avg" \
    --argjson cgroup_memory_current_min "$cgroup_memory_current_min" \
    --argjson cgroup_memory_current_max "$cgroup_memory_current_max" \
    --argjson cgroup_memory_current_avg "$cgroup_memory_current_avg" \
    --argjson rss_pref_min "$rss_pref_min" \
    --argjson rss_pref_max "$rss_pref_max" \
    --argjson rss_pref_avg "$rss_pref_avg" \
    --arg threads_avg "$threads_avg" \
  '{
    sample_count: $sample_count,
    cpu_time_seconds: ($cpu_time_seconds | tonumber),
    cpu_util_percent_of_one_core: ($cpu_util_pct | tonumber),
    avg_cores_used: ($avg_cores_used | tonumber),
    host_logical_cpus: $host_logical_cpus,
    cpu_util_percent_of_host_total: ($cpu_util_pct_host | tonumber),
    vmrss_kb_min: $vmrss_min,
    vmrss_kb_max: $vmrss_max,
    vmrss_kb_avg: $vmrss_avg,
    vmsize_kb_min: $vmsize_min,
    vmsize_kb_max: $vmsize_max,
    vmsize_kb_avg: $vmsize_avg,
    vmhwm_kb_max: $vmhwm_max,
    threads_min: $threads_min,
    threads_max: $threads_max,
    threads_avg: ($threads_avg | tonumber),
    smaps_rss_kb_min: $smaps_rss_min,
    smaps_rss_kb_max: $smaps_rss_max,
    smaps_rss_kb_avg: $smaps_rss_avg,
    cgroup_memory_current_kb_min: $cgroup_memory_current_min,
    cgroup_memory_current_kb_max: $cgroup_memory_current_max,
    cgroup_memory_current_kb_avg: $cgroup_memory_current_avg,
    rss_kb_min: $rss_pref_min,
    rss_kb_max: $rss_pref_max,
    rss_kb_avg: $rss_pref_avg
  }' > "$output_json"
}

size_token_to_kb() {
  local token="${1:-}"
  local value=""
  local unit=""

  token="${token//,/}"
  token="${token// /}"
  token="${token^^}"
  token="${token%%[!0-9A-Z.]*}"

  if [[ -z "$token" ]]; then
    echo 0
    return 0
  fi

  if [[ "$token" =~ ^([0-9]+([.][0-9]+)?)([KMG])B?$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
    case "$unit" in
      K) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", int(v) }' ;;
      M) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", int(v * 1024) }' ;;
      G) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", int(v * 1024 * 1024) }' ;;
      *) echo 0 ;;
    esac
    return 0
  fi

  if [[ "$token" =~ ^([0-9]+([.][0-9]+)?)B?$ ]]; then
    value="${BASH_REMATCH[1]}"
    LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", int((v + 1023) / 1024) }'
    return 0
  fi

  echo 0
}

augment_resource_metrics_with_jvm_breakdown() {
  local pid="${1:-}"
  local resource_json_path="${2:-}"

  if [[ -z "$resource_json_path" || ! -f "$resource_json_path" ]]; then
    return 0
  fi

  local jcmd_available=false
  local jcmd_heap_info_succeeded=false
  local heap_metrics_present=false
  local heap_metrics_from_gc_heap_info=false
  local breakdown_valid=false
  local nmt_enabled=false
  local heap_used_kb=0
  local heap_committed_kb=0
  local heap_max_kb=0
  local native_total_committed_kb=0
  local native_total_reserved_kb=0
  local native_java_heap_committed_kb=0
  local offheap_kb_estimate=0
  local heap_plus_offheap_kb_estimate=0
  local offheap_estimate_source="unavailable"
  local breakdown_note=""
  local vmrss_kb_avg=0
  local total_committed_present=false
  local java_heap_committed_present=false
  local heap_committed_backfilled_from_nmt=false

  local heap_tmp=""
  local nmt_tmp=""

  if command -v jcmd >/dev/null 2>&1; then
    jcmd_available=true
  fi

  if [[ "$jcmd_available" == true && -n "$pid" && "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]]; then
    heap_tmp="$(mktemp)"
    if jcmd "$pid" GC.heap_info > "$heap_tmp" 2>/dev/null; then
      jcmd_heap_info_succeeded=true
      local heap_line zheap_line zheap_block token
      local -a heap_tokens=()
      local -a heap_range_addrs=()
      local -a zheap_tokens=()

      heap_line="$(grep -im1 -E 'heap[[:space:]]+total[[:space:]]+[0-9]' "$heap_tmp" || true)"
      if [[ -n "$heap_line" ]]; then
        mapfile -t heap_tokens < <(printf '%s\n' "$heap_line" | awk '
          BEGIN { IGNORECASE=1 }
          {
            for (i = 1; i <= NF; i++) {
              word = $i
              gsub(/[,():]/, "", word)
              lower = tolower(word)
              if (lower == "total" && total == "") {
                token = $(i + 1)
                gsub(/[,():]/, "", token)
                total = token
              } else if (lower == "used" && used == "") {
                token = $(i + 1)
                gsub(/[,():]/, "", token)
                used = token
              }
            }
          }
          END {
            print total
            print used
          }
        ')

        if [[ -n "${heap_tokens[0]:-}" ]]; then
          heap_committed_kb="$(size_token_to_kb "${heap_tokens[0]}")"
          heap_metrics_from_gc_heap_info=true
        fi
        if [[ -n "${heap_tokens[1]:-}" ]]; then
          heap_used_kb="$(size_token_to_kb "${heap_tokens[1]}")"
          heap_metrics_from_gc_heap_info=true
        fi

        if [[ "$heap_max_kb" -eq 0 ]]; then
          mapfile -t heap_range_addrs < <(printf '%s\n' "$heap_line" | grep -oE '0x[0-9a-fA-F]+' | head -2)
          if [[ "${#heap_range_addrs[@]}" -ge 2 ]]; then
            local heap_range_start heap_range_end
            heap_range_start=$(( ${heap_range_addrs[0]} ))
            heap_range_end=$(( ${heap_range_addrs[1]} ))
            if [[ "$heap_range_end" -gt "$heap_range_start" ]]; then
              heap_max_kb=$(( (heap_range_end - heap_range_start) / 1024 ))
              if [[ "$heap_max_kb" -gt 0 ]]; then
                heap_metrics_from_gc_heap_info=true
              fi
            fi
          fi
        fi
      fi

      zheap_line="$(grep -im1 -E 'ZHeap.*used[[:space:]]+[0-9]' "$heap_tmp" || true)"
      if [[ -n "$zheap_line" ]]; then
        token="$(printf '%s\n' "$zheap_line" | sed -nE 's/.*used[[:space:]]+([^,[:space:]]+).*/\1/ip' | head -1)"
        if [[ -n "$token" ]]; then
          heap_used_kb="$(size_token_to_kb "$token")"
          heap_metrics_from_gc_heap_info=true
        fi
        token="$(printf '%s\n' "$zheap_line" | sed -nE 's/.*capacity[[:space:]]+([^,[:space:]]+).*/\1/ip' | head -1)"
        if [[ -n "$token" ]]; then
          heap_committed_kb="$(size_token_to_kb "$token")"
          heap_metrics_from_gc_heap_info=true
        fi
        token="$(printf '%s\n' "$zheap_line" | sed -nE 's/.*max[[:space:]]+capacity[[:space:]]+([^,[:space:]]+).*/\1/ip' | head -1)"
        if [[ -n "$token" ]]; then
          heap_max_kb="$(size_token_to_kb "$token")"
          heap_metrics_from_gc_heap_info=true
        fi
      fi

      if grep -qi 'ZHeap' "$heap_tmp"; then
        zheap_block="$(awk '
          BEGIN { capture=0; lines=0 }
          /ZHeap/ { capture=1 }
          capture {
            print
            lines++
            if (lines >= 12) {
              exit
            }
          }
        ' "$heap_tmp")"
        if [[ -n "$zheap_block" ]]; then
          mapfile -t zheap_tokens < <(printf '%s\n' "$zheap_block" | awk '
            BEGIN { IGNORECASE=1 }
            {
              for (i = 1; i <= NF; i++) {
                word = $i
                gsub(/[,():]/, "", word)
                lower = tolower(word)
                if (lower == "used" && used == "") {
                  token = $(i + 1)
                  gsub(/[,():]/, "", token)
                  used = token
                } else if (lower == "capacity" && committed == "") {
                  prev = (i > 1 ? $(i - 1) : "")
                  gsub(/[,():]/, "", prev)
                  if (tolower(prev) != "max") {
                    token = $(i + 1)
                    gsub(/[,():]/, "", token)
                    committed = token
                  }
                } else if (lower == "max" && i + 2 <= NF) {
                  next = $(i + 1)
                  gsub(/[,():]/, "", next)
                  if (tolower(next) == "capacity" && max == "") {
                    token = $(i + 2)
                    gsub(/[,():]/, "", token)
                    max = token
                  }
                }
              }
            }
            END {
              print used
              print committed
              print max
            }
          ')

          if [[ "$heap_used_kb" -eq 0 && -n "${zheap_tokens[0]:-}" ]]; then
            heap_used_kb="$(size_token_to_kb "${zheap_tokens[0]}")"
            heap_metrics_from_gc_heap_info=true
          fi
          if [[ "$heap_committed_kb" -eq 0 && -n "${zheap_tokens[1]:-}" ]]; then
            heap_committed_kb="$(size_token_to_kb "${zheap_tokens[1]}")"
            heap_metrics_from_gc_heap_info=true
          fi
          if [[ "$heap_max_kb" -eq 0 && -n "${zheap_tokens[2]:-}" ]]; then
            heap_max_kb="$(size_token_to_kb "${zheap_tokens[2]}")"
            heap_metrics_from_gc_heap_info=true
          fi
        fi
      fi

      if [[ "$heap_max_kb" -eq 0 ]]; then
        token="$(grep -ioE 'max[[:space:]]+capacity[[:space:]]+[0-9]+([.][0-9]+)?[KMG]B?' "$heap_tmp" | sed -nE 's/.*[[:space:]]([0-9]+([.][0-9]+)?[KMG]B?).*/\1/ip' | head -1 || true)"
        if [[ -z "$token" ]]; then
          token="$(grep -ioE 'max[[:space:]]+[0-9]+([.][0-9]+)?[KMG]B?' "$heap_tmp" | sed -nE 's/.*[[:space:]]([0-9]+([.][0-9]+)?[KMG]B?).*/\1/ip' | head -1 || true)"
        fi
        if [[ -n "$token" ]]; then
          heap_max_kb="$(size_token_to_kb "$token")"
          heap_metrics_from_gc_heap_info=true
        fi
      fi

      # Generic fallback for alternate GC.heap_info layouts.
      if [[ "$heap_used_kb" -eq 0 || "$heap_committed_kb" -eq 0 || "$heap_max_kb" -eq 0 ]]; then
        local fallback_used_token fallback_committed_token fallback_total_token fallback_capacity_token fallback_max_token
        local fallback_used_kb fallback_committed_kb fallback_total_kb fallback_capacity_kb fallback_max_kb
        local fallback_backfilled=false

        mapfile -t heap_tokens < <(head -50 "$heap_tmp" | awk '
          BEGIN {
            IGNORECASE=1
            used=""
            committed=""
            total=""
            capacity=""
            max=""
          }

          function clean(tok, t) {
            t = tok
            gsub(/^[^0-9.]*/, "", t)
            gsub(/[^0-9A-Za-z.]*$/, "", t)
            return t
          }

          function token_ok(tok, t) {
            t = toupper(clean(tok))
            return (t ~ /^[0-9]+([.][0-9]+)?([KMG]B?|B)?$/)
          }

          function next_token(idx,   j, candidate) {
            for (j = idx + 1; j <= NF; j++) {
              candidate = clean($j)
              if (token_ok(candidate)) {
                return candidate
              }
            }
            return ""
          }

          {
            line = tolower($0)
            if (line ~ /metaspace/ || line ~ /class[[:space:]]*-?[[:space:]]*space/) {
              next
            }

            for (i = 1; i <= NF; i++) {
              word = tolower(clean($i))

              if (word == "used" && used == "") {
                candidate = next_token(i)
                if (candidate != "") {
                  used = candidate
                }
              } else if (word == "committed" && committed == "") {
                candidate = next_token(i)
                if (candidate != "") {
                  committed = candidate
                }
              } else if (word == "total" && total == "") {
                candidate = next_token(i)
                if (candidate != "") {
                  total = candidate
                }
              } else if (word == "capacity" && capacity == "") {
                prev = (i > 1 ? tolower(clean($(i - 1))) : "")
                if (prev != "max") {
                  candidate = next_token(i)
                  if (candidate != "") {
                    capacity = candidate
                  }
                }
              } else if (word == "max" && max == "") {
                next_word = (i < NF ? tolower(clean($(i + 1))) : "")
                if (next_word == "capacity") {
                  candidate = next_token(i + 1)
                } else {
                  candidate = next_token(i)
                }
                if (candidate != "") {
                  max = candidate
                }
              }
            }
          }

          END {
            print used
            print committed
            print total
            print capacity
            print max
          }
        ')

        fallback_used_token="${heap_tokens[0]:-}"
        fallback_committed_token="${heap_tokens[1]:-}"
        fallback_total_token="${heap_tokens[2]:-}"
        fallback_capacity_token="${heap_tokens[3]:-}"
        fallback_max_token="${heap_tokens[4]:-}"

        fallback_used_kb=0
        fallback_committed_kb=0
        fallback_total_kb=0
        fallback_capacity_kb=0
        fallback_max_kb=0

        if [[ -n "$fallback_used_token" ]]; then
          fallback_used_kb="$(size_token_to_kb "$fallback_used_token")"
        fi
        if [[ -n "$fallback_committed_token" ]]; then
          fallback_committed_kb="$(size_token_to_kb "$fallback_committed_token")"
        fi
        if [[ -n "$fallback_total_token" ]]; then
          fallback_total_kb="$(size_token_to_kb "$fallback_total_token")"
        fi
        if [[ -n "$fallback_capacity_token" ]]; then
          fallback_capacity_kb="$(size_token_to_kb "$fallback_capacity_token")"
        fi
        if [[ -n "$fallback_max_token" ]]; then
          fallback_max_kb="$(size_token_to_kb "$fallback_max_token")"
        fi

        if [[ "$heap_used_kb" -eq 0 && "$fallback_used_kb" -gt 0 ]]; then
          heap_used_kb="$fallback_used_kb"
          fallback_backfilled=true
        fi

        if [[ "$heap_committed_kb" -eq 0 ]]; then
          if [[ "$fallback_committed_kb" -gt 0 ]]; then
            heap_committed_kb="$fallback_committed_kb"
            fallback_backfilled=true
          elif [[ "$fallback_total_kb" -gt 0 ]]; then
            heap_committed_kb="$fallback_total_kb"
            fallback_backfilled=true
          elif [[ "$fallback_capacity_kb" -gt 0 ]]; then
            heap_committed_kb="$fallback_capacity_kb"
            fallback_backfilled=true
          fi
        fi

        if [[ "$heap_max_kb" -eq 0 ]]; then
          if [[ "$fallback_max_kb" -gt 0 ]]; then
            heap_max_kb="$fallback_max_kb"
            fallback_backfilled=true
          elif [[ "$fallback_total_kb" -gt 0 ]]; then
            heap_max_kb="$fallback_total_kb"
            fallback_backfilled=true
          fi
        fi

        if [[ "$fallback_backfilled" == true ]]; then
          heap_metrics_from_gc_heap_info=true
        fi
      fi
    fi
    rm -f "$heap_tmp"

    nmt_tmp="$(mktemp)"
    if jcmd "$pid" VM.native_memory summary scale=KB > "$nmt_tmp" 2>/dev/null; then
      if grep -qi 'Native memory tracking is not enabled' "$nmt_tmp"; then
        nmt_enabled=false
      else
        local total_line java_heap_line
        nmt_enabled=true
        total_line="$(grep -im1 '^Total:' "$nmt_tmp" || true)"
        java_heap_line="$(grep -im1 'Java Heap' "$nmt_tmp" || true)"

        if [[ -n "$total_line" ]]; then
          native_total_reserved_kb="$(printf '%s\n' "$total_line" | sed -nE 's/.*reserved[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*KB?.*/\1/ip' | head -1)"
          native_total_committed_kb="$(printf '%s\n' "$total_line" | sed -nE 's/.*committed[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*KB?.*/\1/ip' | head -1)"
          if [[ "$native_total_reserved_kb" =~ ^[0-9]+$ ]]; then
            :
          else
            native_total_reserved_kb=0
          fi
          if [[ "$native_total_committed_kb" =~ ^[0-9]+$ ]]; then
            total_committed_present=true
          else
            native_total_committed_kb=0
          fi
        fi

        if [[ -n "$java_heap_line" ]]; then
          native_java_heap_committed_kb="$(printf '%s\n' "$java_heap_line" | sed -nE 's/.*committed[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*KB?.*/\1/ip' | head -1)"
          if [[ "$native_java_heap_committed_kb" =~ ^[0-9]+$ ]]; then
            java_heap_committed_present=true
          else
            native_java_heap_committed_kb=0
          fi
        fi
      fi
    fi
    rm -f "$nmt_tmp"

    if [[ "$heap_committed_kb" -eq 0 && "$java_heap_committed_present" == true ]]; then
      heap_committed_kb="$native_java_heap_committed_kb"
      heap_committed_backfilled_from_nmt=true
    fi

    if [[ "$heap_metrics_from_gc_heap_info" == true ]]; then
      heap_metrics_present=true
    fi
  fi

  # Preferred: NMT breakdown if available
  if [[ "$nmt_enabled" == true && "$total_committed_present" == true && "$java_heap_committed_present" == true ]]; then
    offheap_kb_estimate=$((native_total_committed_kb - native_java_heap_committed_kb))
    if [[ "$offheap_kb_estimate" -lt 0 ]]; then
      offheap_kb_estimate=0
    fi
    offheap_estimate_source="nmt_minus_java_heap"
    breakdown_valid=true
    if [[ "$heap_committed_backfilled_from_nmt" == true ]]; then
      breakdown_note="NMT breakdown present; heap_committed_kb backfilled from NMT after partial GC.heap_info parse."
    elif [[ "$heap_metrics_present" == false && "$jcmd_heap_info_succeeded" == true ]]; then
      breakdown_note="NMT breakdown present; GC.heap_info succeeded but heap metrics were unavailable."
    elif [[ "$heap_used_kb" -eq 0 || "$heap_committed_kb" -eq 0 || "$heap_max_kb" -eq 0 ]]; then
      breakdown_note="NMT breakdown present; heap metrics are partial."
    else
      breakdown_note="NMT breakdown present."
    fi
  # Fallback: only if heap metrics are present
  elif [[ "$heap_metrics_present" == true ]]; then
    vmrss_kb_avg="$(jq -r '.vmrss_kb_avg // 0' "$resource_json_path" 2>/dev/null || echo 0)"
    if [[ ! "$vmrss_kb_avg" =~ ^[0-9]+$ ]]; then
      vmrss_kb_avg=0
    fi
    offheap_kb_estimate=$((vmrss_kb_avg - heap_used_kb))
    if [[ "$offheap_kb_estimate" -lt 0 ]]; then
      offheap_kb_estimate=0
    fi
    offheap_estimate_source="vmrss_minus_heap_used"
    breakdown_valid=true
    if [[ "$heap_committed_backfilled_from_nmt" == true ]]; then
      breakdown_note="Heap metrics are partial; heap_committed_kb backfilled from NMT and vmrss minus heap_used fallback was used."
    elif [[ "$heap_used_kb" -eq 0 || "$heap_committed_kb" -eq 0 || "$heap_max_kb" -eq 0 ]]; then
      breakdown_note="Heap metrics are partial; used vmrss minus heap_used fallback."
    else
      breakdown_note="Heap metrics present, used vmrss minus heap_used fallback."
    fi
  else
    # No valid heap metrics, no NMT: do not synthesize offheap
    offheap_kb_estimate=0
    heap_plus_offheap_kb_estimate=0
    offheap_estimate_source="unavailable_heap_unknown"
    breakdown_valid=false
    if [[ "$jcmd_heap_info_succeeded" == true ]]; then
      breakdown_note="GC.heap_info succeeded but heap metrics were unavailable; offheap estimate not possible."
    else
      breakdown_note="Heap metrics unavailable or parse failed; offheap estimate not possible."
    fi
  fi

  heap_plus_offheap_kb_estimate=$((heap_used_kb + offheap_kb_estimate))

  local tmp_output
  tmp_output="$(mktemp)"
  if jq \
    --argjson jcmd_available "$jcmd_available" \
    --argjson jcmd_heap_info_succeeded "$jcmd_heap_info_succeeded" \
    --argjson heap_metrics_present "$heap_metrics_present" \
    --argjson breakdown_valid "$breakdown_valid" \
    --arg breakdown_note "$breakdown_note" \
    --argjson heap_used_kb "$heap_used_kb" \
    --argjson heap_committed_kb "$heap_committed_kb" \
    --argjson heap_max_kb "$heap_max_kb" \
    --argjson native_total_committed_kb "$native_total_committed_kb" \
    --argjson native_total_reserved_kb "$native_total_reserved_kb" \
    --argjson native_java_heap_committed_kb "$native_java_heap_committed_kb" \
    --argjson offheap_kb_estimate "$offheap_kb_estimate" \
    --argjson heap_plus_offheap_kb_estimate "$heap_plus_offheap_kb_estimate" \
    --arg offheap_estimate_source "$offheap_estimate_source" \
    --argjson nmt_enabled "$nmt_enabled" \
    '.jvm_memory_breakdown = {
      jcmd_available: $jcmd_available,
      jcmd_heap_info_succeeded: $jcmd_heap_info_succeeded,
      heap_metrics_present: $heap_metrics_present,
      breakdown_valid: $breakdown_valid,
      breakdown_note: $breakdown_note,
      heap_used_kb: $heap_used_kb,
      heap_committed_kb: $heap_committed_kb,
      heap_max_kb: $heap_max_kb,
      native_total_committed_kb: $native_total_committed_kb,
      native_total_reserved_kb: $native_total_reserved_kb,
      native_java_heap_committed_kb: $native_java_heap_committed_kb,
      offheap_kb_estimate: $offheap_kb_estimate,
      heap_plus_offheap_kb_estimate: $heap_plus_offheap_kb_estimate,
      offheap_estimate_source: $offheap_estimate_source,
      nmt_enabled: $nmt_enabled
    }' "$resource_json_path" > "$tmp_output" 2>/dev/null; then
    mv "$tmp_output" "$resource_json_path"
  else
    rm -f "$tmp_output"
  fi

  return 0
}

capture_jfr_metadata() {
  local pid="$1"
  local outdir="$2"
  local target_id="$3"
  local run_ts="$4"

  local jcmd_available=false
  local check_ok=false
  local recording_detected=false
  local dump_attempted=false
  local dump_success=false
  local jfr_file=""
  local note=""
  local stop_attempted=false
  local stop_success=false
  local stop_recording_name=""
  local start_meta_file="${outdir}/jfr-start.json"
  local own_recording=""

  if command -v jcmd >/dev/null 2>&1; then
    jcmd_available=true
  fi

  # Resolve recording name started by this run (from jfr-start.json).
  if command -v jq >/dev/null 2>&1 && [[ -f "$start_meta_file" ]]; then
    own_recording="$(jq -r 'if (.start_success == true and .recording_already_present == false) then (.recording_name // "") else "" end' "$start_meta_file" 2>/dev/null || true)"
    if [[ "$own_recording" == "null" ]]; then own_recording=""; fi
  fi

  if [[ "$jcmd_available" == true && -n "$pid" && -d "/proc/$pid" ]]; then
    # Run jcmd JFR.check — output format: "Recording N: name=..."
    if jcmd "$pid" JFR.check > "${outdir}/jfr-check.txt" 2>&1; then
      check_ok=true
      # Match "Recording N:" where N is an integer
      if grep -qE "^Recording [0-9]+:" "${outdir}/jfr-check.txt" 2>/dev/null; then
        recording_detected=true
        dump_attempted=true
        jfr_file="${outdir}/target-${target_id}-${run_ts}.jfr"
        local dump_name_arg=""
        if [[ -n "$own_recording" ]]; then
          dump_name_arg="name=${own_recording} "
        fi
        if jcmd "$pid" "JFR.dump ${dump_name_arg}filename=${jfr_file}" > /dev/null 2>&1; then
          if [[ -f "$jfr_file" ]]; then
            dump_success=true
          fi
        fi
      fi
    fi
  fi

  # Stop recording if this run owns it — attempt even when dump failed.
  if [[ "$recording_detected" == true && -n "$own_recording" ]]; then
    stop_recording_name="$own_recording"
    stop_attempted=true
    if jcmd "$pid" "JFR.stop name=${stop_recording_name}" > "${outdir}/jfr-stop.txt" 2>&1; then
      stop_success=true
    else
      note="jfr stop attempted but failed"
    fi
  elif [[ "$recording_detected" == true && -z "$own_recording" ]]; then
    if [[ -z "$note" ]]; then
      note="jfr stop skipped: recording ownership not from this run"
    fi
  fi

  jq -n \
    --arg pid "$pid" \
    --argjson jcmd_available "$jcmd_available" \
    --argjson check_ok "$check_ok" \
    --argjson recording_detected "$recording_detected" \
    --argjson dump_attempted "$dump_attempted" \
    --argjson dump_success "$dump_success" \
    --argjson stop_attempted "$stop_attempted" \
    --argjson stop_success "$stop_success" \
    --arg stop_recording_name "$stop_recording_name" \
    --arg jfr_file "$jfr_file" \
    --arg note "$note" \
  '{pid: $pid, jcmd_available: $jcmd_available, check_ok: $check_ok, recording_detected: $recording_detected, dump_attempted: $dump_attempted, dump_success: $dump_success, stop_attempted: $stop_attempted, stop_success: $stop_success, stop_recording_name: $stop_recording_name, jfr_file: $jfr_file, note: $note}' > "${outdir}/jfr-metadata.json"
}

diagnose_endpoint() {
  local target_id="$1"
  local health_url="$2"
  local path="$3"
  local output_file="${4:-/tmp/endpoint-diag.txt}"
  local url=""
  local response_file http_code
  local -a curl_args=()

  if ! url="$(comparative_endpoint_url_from_health_url "$health_url" "$path")"; then
    return 64
  fi

  if [[ "$url" == https://* ]]; then
    curl_args=(-k)
  fi

  response_file=$(mktemp)
  
  echo "=== ENDPOINT DIAGNOSTIC ===" | tee "$output_file"
  echo "Target: $target_id" | tee -a "$output_file"
  echo "URL: $url" | tee -a "$output_file"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" | tee -a "$output_file"
  echo "" | tee -a "$output_file"
  
  # Perform endpoint preflight and capture response payload with headers.
  echo "Attempting curl request..." | tee -a "$output_file"
  http_code="$(curl -sS "${curl_args[@]}" -i -o "$response_file" -w "%{http_code}" --max-time "$ENTITY_READ_PREFLIGHT_TIMEOUT" "$url" 2>/dev/null || true)"
  if [[ -z "$http_code" ]]; then
    http_code="000"
  fi
  
  echo "" | tee -a "$output_file"
  echo "HTTP Status Code: $http_code" | tee -a "$output_file"
  echo "Response (first 500 chars):" | tee -a "$output_file"
  echo "---" | tee -a "$output_file"
  bench_print_preflight_payload_preview "$response_file" 500 | tee -a "$output_file"
  echo "" | tee -a "$output_file"
  echo "---" | tee -a "$output_file"
  
  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: Endpoint returned non-200 status: $http_code" | tee -a "$output_file"
    rm -f "$response_file"
    return 1
  fi
  
  rm -f "$response_file"
  return 0
}

wait_for_target_ready() {
  local target_id="$1"
  local health_url="$2"
  local timeout_seconds="${3:-60}"
  local ready_file="${4:-}"
  local sync_log="${OUTPUT_DIR}/logs/sync-log.txt"
  local deadline attempts now http_status ts
  local -a curl_args=()

  if [[ "$health_url" == https://* ]]; then
    curl_args=(-k)
  fi

  mkdir -p "${OUTPUT_DIR}/logs"
  touch "$sync_log"

  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  echo "[${ts}] waiting for ${target_id} on ${health_url} (timeout=${timeout_seconds}s)" | tee -a "$sync_log"

  deadline=$(( $(date +%s) + timeout_seconds ))
  attempts=0

  while true; do
    now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      echo "[${ts}] TIMEOUT waiting for ${target_id} on ${health_url}" | tee -a "$sync_log"
      echo "ERROR: ${target_id} not ready within ${timeout_seconds}s on ${health_url}" >&2
      exit 1
    fi

    http_status="$(curl -s "${curl_args[@]}" -o /dev/null -w "%{http_code}" --max-time 2 "$health_url" 2>/dev/null || echo "000")"
    attempts=$((attempts + 1))
    if [[ "$http_status" == "200" ]]; then
      ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      echo "[${ts}] ${target_id} ready after ${attempts} attempt(s)" | tee -a "$sync_log"
      if [[ -n "$ready_file" ]]; then
        echo "$ts" > "$ready_file"
      fi
      return 0
    fi

    sleep 1
  done
}

wait_for_target_endpoint_ready() {
  local target_id="$1"
  local health_url="$2"
  local path="$3"
  local timeout_seconds="${4:-60}"
  local label="$5"
  local sync_log="${OUTPUT_DIR}/logs/sync-log.txt"
  local endpoint deadline attempts now http_status ts elapsed
  local -a curl_args=()

  mkdir -p "${OUTPUT_DIR}/logs"
  touch "$sync_log"

  if ! endpoint="$(comparative_endpoint_url_from_health_url "$health_url" "$path")"; then
    exit 64
  fi

  if [[ "$endpoint" == https://* ]]; then
    curl_args=(-k)
  fi

  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  echo "[${ts}] waiting for ${target_id} endpoint ${endpoint} label=${label} (timeout=${timeout_seconds}s)" | tee -a "$sync_log"

  deadline=$(( $(date +%s) + timeout_seconds ))
  attempts=0
  start_time=$(date +%s)

  while true; do
    now="$(date +%s)"
    elapsed=$((now - start_time))
    if [[ "$now" -ge "$deadline" ]]; then
      ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      echo "[${ts}] TIMEOUT waiting for ${target_id} endpoint ${endpoint} label=${label}" | tee -a "$sync_log"
      echo "ERROR: endpoint readiness timeout target_id=${target_id} endpoint=${endpoint} label=${label} timeout_seconds=${timeout_seconds}" >&2
      echo "Running verbose diagnostic on endpoint after timeout..." | tee -a "$sync_log"
      diagnose_endpoint "$target_id" "$health_url" "$path" "${OUTPUT_DIR}/logs/endpoint-diag-timeout-${target_id}.txt"
      exit 1
    fi

    http_status="$(curl -s "${curl_args[@]}" -o /dev/null -w "%{http_code}" --max-time 2 "$endpoint" 2>/dev/null || echo "000")"
    attempts=$((attempts + 1))
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    if [[ "$http_status" == "200" ]]; then
      echo "[${ts}] endpoint ready target_id=${target_id} endpoint=${endpoint} label=${label} attempts=${attempts} elapsed=${elapsed}s" | tee -a "$sync_log"
      return 0
    else
      if (( attempts % 5 == 0 )); then
        echo "[${ts}] retry attempt=${attempts} elapsed=${elapsed}s http_status=${http_status} endpoint=${endpoint}" | tee -a "$sync_log"
      fi
    fi

    sleep 1
  done
}

extract_external_jar_path_from_cmd() {
  local cmd="${1:-}"
  local -a tokens=()
  local i jar_path

  read -r -a tokens <<<"$cmd"
  for ((i = 0; i < ${#tokens[@]}; i++)); do
    if [[ "${tokens[$i]}" == "-jar" && $((i + 1)) -lt ${#tokens[@]} ]]; then
      jar_path="${tokens[$((i + 1))]}"
      jar_path="${jar_path%\"}"
      jar_path="${jar_path#\"}"
      jar_path="${jar_path%\'}"
      jar_path="${jar_path#\'}"
      echo "$jar_path"
      return 0
    fi
  done
  return 1
}

extract_external_log_path_from_cmd() {
  local cmd="${1:-}"
  local log_path=""

  if [[ "$cmd" =~ [[:space:]]\>[[:space:]]*([^[:space:]]+) ]]; then
    log_path="${BASH_REMATCH[1]}"
    log_path="${log_path%\"}"
    log_path="${log_path#\"}"
    log_path="${log_path%\'}"
    log_path="${log_path#\'}"
    echo "$log_path"
    return 0
  fi

  return 1
}

capture_external_runtime_log() {
  local target_contract_json="$1"
  local target_id="$2"
  local outdir="$3"

  local launcher_mode env_file external_start_cmd log_path output_file
  local external_jar_path resolved_jar_path jar_sha256 jar_size_bytes jar_mtime_utc
  local jar_exists=false mtime_epoch=""
  local copied=false
  local note=""

  launcher_mode="$(jq -r '.launcher_mode // ""' <<<"$target_contract_json")"
  env_file="$(jq -r '.env_file // ""' <<<"$target_contract_json")"
  output_file="${outdir}/target-runtime.log"
  external_jar_path=""
  resolved_jar_path=""
  jar_sha256=""
  jar_size_bytes=0
  jar_mtime_utc=""

  if [[ "$launcher_mode" != "external" ]]; then
    note="launcher_mode is not external; skipping runtime log capture"
    jq -n \
      --arg launcher_mode "$launcher_mode" \
      --arg env_file "$env_file" \
      --arg log_path "" \
      --arg external_jar_path "$external_jar_path" \
      --arg resolved_jar_path "$resolved_jar_path" \
      --argjson jar_exists "$jar_exists" \
      --arg jar_sha256 "$jar_sha256" \
      --argjson jar_size_bytes "$jar_size_bytes" \
      --arg jar_mtime_utc "$jar_mtime_utc" \
      --argjson copied "$copied" \
      --arg output_file "$output_file" \
      --arg note "$note" \
      '{launcher_mode: $launcher_mode, env_file: $env_file, log_path: $log_path, external_jar_path: $external_jar_path, resolved_jar_path: $resolved_jar_path, jar_exists: $jar_exists, jar_sha256: $jar_sha256, jar_size_bytes: $jar_size_bytes, jar_mtime_utc: $jar_mtime_utc, copied: $copied, output_file: $output_file, note: $note}' > "${outdir}/runtime-log-metadata.json"
    return 0
  fi

  if [[ -z "$env_file" || "$env_file" == "null" ]]; then
    note="missing env_file in target contract"
  elif [[ ! -f "$env_file" ]]; then
    note="env_file not found"
  else
    external_start_cmd="$(bash -c 'set -a; source "$1" >/dev/null 2>&1; printf "%s" "${EXTERNAL_START_CMD:-}"' -- "$env_file")"
    if [[ -n "$external_start_cmd" ]] && external_jar_path="$(extract_external_jar_path_from_cmd "$external_start_cmd" 2>/dev/null)"; then
      if [[ "$external_jar_path" = /* ]]; then
        resolved_jar_path="$external_jar_path"
      else
        resolved_jar_path="${REPO_ROOT}/${external_jar_path}"
      fi

      if [[ -f "$resolved_jar_path" ]]; then
        jar_exists=true

        if command -v sha256sum >/dev/null 2>&1; then
          jar_sha256="$(sha256sum "$resolved_jar_path" 2>/dev/null | awk '{print $1}' || true)"
        elif command -v shasum >/dev/null 2>&1; then
          jar_sha256="$(shasum -a 256 "$resolved_jar_path" 2>/dev/null | awk '{print $1}' || true)"
        fi

        if stat -c %s "$resolved_jar_path" >/dev/null 2>&1; then
          jar_size_bytes="$(stat -c %s "$resolved_jar_path" 2>/dev/null || echo 0)"
        else
          jar_size_bytes="$(wc -c < "$resolved_jar_path" 2>/dev/null | awk '{print $1}' || echo 0)"
        fi
        if [[ ! "$jar_size_bytes" =~ ^[0-9]+$ ]]; then
          jar_size_bytes=0
        fi

        if stat -c %Y "$resolved_jar_path" >/dev/null 2>&1; then
          mtime_epoch="$(stat -c %Y "$resolved_jar_path" 2>/dev/null || true)"
          if [[ -n "$mtime_epoch" ]] && date -u -d "@${mtime_epoch}" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
            jar_mtime_utc="$(date -u -d "@${mtime_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
          fi
        fi
      fi
    fi

    if [[ -z "$external_start_cmd" ]]; then
      note="EXTERNAL_START_CMD is empty in env_file"
    elif log_path="$(extract_external_log_path_from_cmd "$external_start_cmd" 2>/dev/null)"; then
      if [[ -f "$log_path" ]]; then
        if cp "$log_path" "$output_file" 2>/dev/null; then
          copied=true
          note="runtime log copied"
        else
          note="failed to copy runtime log from parsed log_path"
        fi
      else
        note="parsed log_path does not exist"
      fi
    else
      note="no output redirection log path found in EXTERNAL_START_CMD"
    fi
  fi

  jq -n \
    --arg launcher_mode "$launcher_mode" \
    --arg env_file "$env_file" \
    --arg log_path "${log_path:-}" \
    --arg external_jar_path "$external_jar_path" \
    --arg resolved_jar_path "$resolved_jar_path" \
    --argjson jar_exists "$jar_exists" \
    --arg jar_sha256 "$jar_sha256" \
    --argjson jar_size_bytes "$jar_size_bytes" \
    --arg jar_mtime_utc "$jar_mtime_utc" \
    --argjson copied "$copied" \
    --arg output_file "$output_file" \
    --arg note "$note" \
    '{launcher_mode: $launcher_mode, env_file: $env_file, log_path: $log_path, external_jar_path: $external_jar_path, resolved_jar_path: $resolved_jar_path, jar_exists: $jar_exists, jar_sha256: $jar_sha256, jar_size_bytes: $jar_size_bytes, jar_mtime_utc: $jar_mtime_utc, copied: $copied, output_file: $output_file, note: $note}' > "${outdir}/runtime-log-metadata.json"

  return 0
}

ensure_jfr_recording_started() {
  local pid="$1"
  local outdir="$2"
  local target_id="$3"
  local run_ts="$4"

  local jcmd_available=false
  local start_attempted=false
  local start_success=false
  local recording_already_present=false
  local recording_name=""
  local note=""

  recording_name="$(printf '%s_%s' "$target_id" "$run_ts" | tr -c '[:alnum:]' '_')"
  recording_name="$(printf '%s' "$recording_name" | sed 's/^_*//; s/_*$//')"
  if [[ -z "$recording_name" ]]; then
    recording_name="benchmark_recording"
  fi

  : > "${outdir}/jfr-start.txt"

  if command -v jcmd >/dev/null 2>&1; then
    jcmd_available=true
  fi

  if [[ "$jcmd_available" != true ]]; then
    note="jcmd not available"
    jq -n \
      --arg pid "$pid" \
      --argjson jcmd_available "$jcmd_available" \
      --argjson start_attempted "$start_attempted" \
      --argjson start_success "$start_success" \
      --argjson recording_already_present "$recording_already_present" \
      --arg recording_name "$recording_name" \
      --arg note "$note" \
      '{pid: $pid, jcmd_available: $jcmd_available, start_attempted: $start_attempted, start_success: $start_success, recording_already_present: $recording_already_present, recording_name: $recording_name, note: $note}' > "${outdir}/jfr-start.json"
    return 0
  fi

  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || ! -d "/proc/$pid" ]]; then
    note="target pid invalid or not running"
    jq -n \
      --arg pid "$pid" \
      --argjson jcmd_available "$jcmd_available" \
      --argjson start_attempted "$start_attempted" \
      --argjson start_success "$start_success" \
      --argjson recording_already_present "$recording_already_present" \
      --arg recording_name "$recording_name" \
      --arg note "$note" \
      '{pid: $pid, jcmd_available: $jcmd_available, start_attempted: $start_attempted, start_success: $start_success, recording_already_present: $recording_already_present, recording_name: $recording_name, note: $note}' > "${outdir}/jfr-start.json"
    return 0
  fi

  if jcmd "$pid" JFR.check > "${outdir}/jfr-start.txt" 2>&1; then
    if grep -qE "^Recording [0-9]+:" "${outdir}/jfr-start.txt" 2>/dev/null; then
      recording_already_present=true
      start_success=true
      note="recording already present"
    else
      start_attempted=true
      if jcmd "$pid" "JFR.start name=${recording_name} settings=profile disk=true" >> "${outdir}/jfr-start.txt" 2>&1; then
        start_success=true
        note="recording started"
      else
        note="JFR.start command failed"
      fi
    fi
  else
    note="JFR.check command failed"
  fi

  jq -n \
    --arg pid "$pid" \
    --argjson jcmd_available "$jcmd_available" \
    --argjson start_attempted "$start_attempted" \
    --argjson start_success "$start_success" \
    --argjson recording_already_present "$recording_already_present" \
    --arg recording_name "$recording_name" \
    --arg note "$note" \
    '{pid: $pid, jcmd_available: $jcmd_available, start_attempted: $start_attempted, start_success: $start_success, recording_already_present: $recording_already_present, recording_name: $recording_name, note: $note}' > "${outdir}/jfr-start.json"

  return 0
}

derive_jvm_flags_json() {
  local target_contract_json="$1"
  local env_file external_start_cmd
  local -a tokens=()
  local -a flags=()
  local java_idx=-1
  local i

  env_file="$(jq -r '.env_file // empty' <<<"$target_contract_json")"
  if [[ -z "$env_file" || ! -f "$env_file" ]]; then
    echo '[]'
    return 0
  fi

  external_start_cmd="$(bash -c 'set -a; source "$1" >/dev/null 2>&1; printf "%s" "${EXTERNAL_START_CMD:-}"' -- "$env_file")"
  if [[ -z "$external_start_cmd" ]]; then
    echo '[]'
    return 0
  fi

  read -r -a tokens <<<"$external_start_cmd"
  for ((i = 0; i < ${#tokens[@]}; i++)); do
    if [[ "${tokens[$i]}" =~ (^|/)java$ ]]; then
      java_idx="$i"
      break
    fi
  done

  if [[ "$java_idx" -lt 0 ]]; then
    echo '[]'
    return 0
  fi

  for ((i = java_idx + 1; i < ${#tokens[@]}; i++)); do
    if [[ "${tokens[$i]}" == "-jar" ]]; then
      break
    fi
    if [[ "${tokens[$i]}" == -* ]]; then
      flags+=("${tokens[$i]}")
    fi
  done

  if [[ ${#flags[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${flags[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
  fi
}

validate_external_target_prereqs() {
  local target_id="$1"
  local target_port="$2"
  local target_contract_json="$3"
  local launcher_mode env_file external_start_cmd external_jar_path resolved_jar_path

  launcher_mode="$(jq -r '.launcher_mode' <<<"$target_contract_json")"
  if [[ "$launcher_mode" != "external" ]]; then
    return 0
  fi

  env_file="$(jq -r '.env_file' <<<"$target_contract_json")"
  external_start_cmd=""
  if [[ -n "$env_file" && "$env_file" != "null" && -f "$env_file" ]]; then
    external_start_cmd="$(bash -c 'set -a; source "$1" >/dev/null 2>&1; printf "%s" "${EXTERNAL_START_CMD:-}"' -- "$env_file")"
  fi

  if [[ -n "$external_start_cmd" ]] && extract_external_jar_path_from_cmd "$external_start_cmd" >/dev/null; then
    external_jar_path="$(extract_external_jar_path_from_cmd "$external_start_cmd")"
    if [[ "$external_jar_path" = /* ]]; then
      resolved_jar_path="$external_jar_path"
    else
      resolved_jar_path="${REPO_ROOT}/${external_jar_path}"
    fi

    if [[ ! -f "$resolved_jar_path" ]]; then
      echo "CONFIG_ERROR: target '${target_id}' (launcher_mode=external) has EXTERNAL_START_CMD with '-jar ${external_jar_path}' but jar file is missing: ${resolved_jar_path}" >&2
      echo "ACTION: build or fix EXTERNAL_START_CMD in ${env_file}, then start target manually: runtime/drivers/start-target.sh ${target_id}" >&2
      exit 64
    fi
  fi

  return 0
}

validate_external_target_readiness() {
  local target_id="$1"
  local target_contract_json="$2"
  local launcher_mode health_url http_status
  local -a curl_args=()

  launcher_mode="$(jq -r '.launcher_mode' <<<"$target_contract_json")"
  if [[ "$launcher_mode" != "external" ]]; then
    return 0
  fi

  health_url="$(jq -r '.health_url // empty' <<<"$target_contract_json")"
  if [[ -z "$health_url" ]]; then
    echo "CONFIG_ERROR: target '${target_id}' (launcher_mode=external) is missing contract health_url" >&2
    exit 64
  fi

  if [[ "$health_url" == https://* ]]; then
    curl_args=(-k)
  fi

  http_status="$(curl -s "${curl_args[@]}" -o /dev/null -w "%{http_code}" --max-time 2 "$health_url" 2>/dev/null || echo "000")"
  if [[ "$http_status" != "200" ]]; then
    echo "ERROR: target '${target_id}' (launcher_mode=external) is not ready before Stage 4: ${health_url} returned HTTP ${http_status}" >&2
    echo "ACTION: start target first, then re-run: runtime/drivers/start-target.sh ${target_id}" >&2
    exit 1
  fi

  echo -e "  ${GREEN}✓${NC} External target '${target_id}' is ready on ${health_url}."
}

run_endpoint_contract_test_gate() {
  local spring_pom="${REPO_ROOT}/targets/spring-benchmark-app/pom.xml"
  local quarkus_pom="${REPO_ROOT}/targets/quarkus-benchmark-app/pom.xml"

  if [[ "${BENCHMARK_SKIP_ENDPOINT_CONTRACT_GATE:-0}" == "1" ]]; then
    echo -e "  ${YELLOW}Skipping endpoint contract test gate (BENCHMARK_SKIP_ENDPOINT_CONTRACT_GATE=1).${NC}"
    return 0
  fi

  if [[ "$SCENARIO_ENDPOINT_PATH" != "/api/v1/users" ]]; then
    echo "  Endpoint contract test gate not required for scenario endpoint: ${SCENARIO_ENDPOINT_PATH}"
    return 0
  fi

  echo "  Running endpoint contract test gate for Spring target..."
  if ! mvn -f "$spring_pom" -Dtest=SpringUsersEndpointContractTest test; then
    echo "ERROR: Spring endpoint contract test gate failed." >&2
    exit 1
  fi

  echo "  Running endpoint contract test gate for Quarkus target..."
  if ! mvn -f "$quarkus_pom" -Dtest=QuarkusUsersEndpointContractTest test; then
    echo "ERROR: Quarkus endpoint contract test gate failed." >&2
    exit 1
  fi

  echo -e "  ${GREEN}✓${NC} Endpoint contract test gate passed (Spring + Quarkus)."
}

banner() {
  local title="$1"
  echo ""
  echo -e "${CYAN}# ============================================================${NC}"
  echo -e "${CYAN}# ${title}${NC}"
  echo -e "${CYAN}# ============================================================${NC}"
}

claim_scope_for_target() {
  local target_id="$1"
  local pair_manifest_path="$2"
  local target_present="false"
  local explicit_claim_scope=""
  local maturity=""

  if jq -e --arg t "$target_id" '.compatible_targets[]? | select(.target_id == $t)' "$pair_manifest_path" >/dev/null 2>&1; then
    target_present="true"
    explicit_claim_scope="$(jq -r --arg t "$target_id" '
      [.compatible_targets[]? | select(.target_id == $t)][0].claim_scope // empty
    ' "$pair_manifest_path" 2>/dev/null || true)"
    maturity="$(jq -r --arg t "$target_id" '
      [.compatible_targets[]? | select(.target_id == $t)][0].maturity // empty
    ' "$pair_manifest_path" 2>/dev/null || true)"
  fi

  if [[ "$explicit_claim_scope" == "comparison_eligible" || "$explicit_claim_scope" == "descriptive_only" ]]; then
    echo "$explicit_claim_scope"
    return 0
  fi

  if [[ "$target_present" != "true" ]]; then
    echo "descriptive_only"
  elif [[ "$maturity" == "exploratory" ]]; then
    echo "descriptive_only"
  else
    echo "comparison_eligible"
  fi
}

# ============================================================
# STAGE 1: Initialization
# ============================================================
banner "STAGE 1: Initialization"

SCENARIO_DIR="${REPO_ROOT}/scenarios/${SCENARIO_ID}"
SCENARIO_JSON="${SCENARIO_DIR}/scenario.json"
PAIR_MANIFEST="${SCENARIO_DIR}/comparative-pair-manifest.json"
TARGET_A_INPUT="${TARGET_A}"
TARGET_B_INPUT="${TARGET_B}"

if [[ ! -f "$SCENARIO_JSON" ]]; then
  echo "ERROR: Scenario manifest not found: $SCENARIO_JSON" >&2
  exit 1
fi
if [[ ! -f "$PAIR_MANIFEST" ]]; then
  echo "ERROR: Comparative pair manifest not found: $PAIR_MANIFEST" >&2
  exit 1
fi

PAIR_REQUIRED_CONTRACT="$(jq -r '.required_contract // empty' "$PAIR_MANIFEST")"
PAIR_REQUIRED_CONTRACTS_COUNT="$(jq '(.required_contracts // []) | length' "$PAIR_MANIFEST")"
if [[ "$PAIR_REQUIRED_CONTRACTS_COUNT" -gt 0 ]]; then
  if ! jq -e --arg cid "$CONTRACT_ID" '(.required_contracts // []) | index($cid) != null' "$PAIR_MANIFEST" >/dev/null; then
    PAIR_REQUIRED_CONTRACTS_ALLOWED="$(jq -r '(.required_contracts // []) | join(", ")' "$PAIR_MANIFEST")"
    echo "CONFIG_ERROR: contract mismatch with pair manifest: --contract-id=${CONTRACT_ID} but ${PAIR_MANIFEST} requires one of [${PAIR_REQUIRED_CONTRACTS_ALLOWED}]" >&2
    exit 64
  fi
elif [[ -n "$PAIR_REQUIRED_CONTRACT" && "$PAIR_REQUIRED_CONTRACT" != "$CONTRACT_ID" ]]; then
  echo "CONFIG_ERROR: contract mismatch with pair manifest: --contract-id=${CONTRACT_ID} but ${PAIR_MANIFEST} requires ${PAIR_REQUIRED_CONTRACT}" >&2
  exit 64
fi

# Create output directory structure early so exclusion artifacts are always emitted.
mkdir -p "${OUTPUT_DIR}/target-a"
mkdir -p "${OUTPUT_DIR}/target-b"
mkdir -p "${OUTPUT_DIR}/logs"
mkdir -p "$SCENARIO_DIAGNOSTICS_DIR"

TARGET_A_CANONICAL="$(normalize_target_alias "$TARGET_A_INPUT")"
TARGET_B_CANONICAL="$(normalize_target_alias "$TARGET_B_INPUT")"
TARGET_A_CLAIM_SCOPE="$(claim_scope_for_target "$TARGET_A_CANONICAL" "$PAIR_MANIFEST")"
TARGET_B_CLAIM_SCOPE="$(claim_scope_for_target "$TARGET_B_CANONICAL" "$PAIR_MANIFEST")"

STRICT_SCENARIO_ID="entity-read-by-id"

# Fail-fast canonical id guard for entity-read-by-id comparative path.
if [[ "$SCENARIO_ID" == "$STRICT_SCENARIO_ID" ]]; then
  if [[ "$TARGET_A_INPUT" != "$TARGET_A_CANONICAL" || "$TARGET_B_INPUT" != "$TARGET_B_CANONICAL" ]]; then
    echo "CONFIG_ERROR: comparative path for scenario '${STRICT_SCENARIO_ID}' forbids aliases/fallbacks; provide canonical target ids only." >&2
    exit 64
  fi
fi

CLAIM_ELIGIBLE_RUN=false
if [[ "$TARGET_A_CLAIM_SCOPE" == "comparison_eligible" && "$TARGET_B_CLAIM_SCOPE" == "comparison_eligible" ]]; then
  CLAIM_ELIGIBLE_RUN=true
fi

TRACK_ID="${BENCHMARK_TRACK_ID:-}"
if [[ -z "$TRACK_ID" ]]; then
  if [[ "${BENCHMARK_ENABLE_LOCALITY_MODE:-0}" == "1" ]]; then
    TRACK_ID="track-r"
  else
    TRACK_ID="track-n"
  fi
fi

if comparative_contract_is_constrained "$SCENARIO_JSON" "$CONTRACT_ID" || \
   comparative_path_is_constrained "$OUTPUT_DIR" "${BENCHMARK_EXECUTION_PROFILE_ID:-}" "$TRACK_ID"; then
  comparative_fail_closed_constrained
fi

CANONICAL_UNORDERED_TARGETS="$(printf '%s\n%s\n' "$TARGET_A_CANONICAL" "$TARGET_B_CANONICAL" | sort | paste -sd ',' -)"
CANONICAL_UNORDERED_TARGETS_ID="${CANONICAL_UNORDERED_TARGETS/,/__}"
# Protocol-as-run-axis PAIR_ID isolation (additive). PAIR_ID is built here, BEFORE the full
# protocol resolution below. For a PINNED contract the protocol is implied by the contract id
# (h1_* etc.), so PAIR_ID must stay byte-identical (the live _h1_v2 run). For an AGNOSTIC
# contract the id carries no protocol, so PAIR_ID gains an effective-protocol segment to keep
# h1 and h2 of the same agnostic contract in separate AB/BA groups + aggregation buckets. This
# is a cheap key-construction pre-read only; the fail-closed axis validation happens below.
_PAIR_CONTRACT_PROTO="$(jq -r --arg c "$CONTRACT_ID" '.fixed_contracts[$c].protocol_mode // empty' "$SCENARIO_JSON")"
_PAIR_PROTO_SEG=""
if [[ -z "$_PAIR_CONTRACT_PROTO" ]]; then
  _PAIR_EFF="${PROTOCOL_MODE_AXIS:-${BENCH_PROTOCOL_MODE_OVERRIDE:-${BENCH_PROTOCOL_MODE:-}}}"
  [[ -n "$_PAIR_EFF" ]] && _PAIR_PROTO_SEG="-${_PAIR_EFF}"
fi
PAIR_ID="${BENCHMARK_PAIR_ID:-${SCENARIO_ID}-${CONTRACT_ID}${_PAIR_PROTO_SEG}-${CANONICAL_UNORDERED_TARGETS_ID}}"
PAIR_ORDER="${BENCHMARK_PAIR_ORDER:-ab}"
if [[ "$PAIR_ORDER" != "ab" && "$PAIR_ORDER" != "ba" ]]; then
  echo "CONFIG_ERROR: invalid BENCHMARK_PAIR_ORDER='${PAIR_ORDER}' (expected: ab or ba)" >&2
  exit 64
fi
AB_BA_ORDERS_COMPLETED_RAW="${BENCHMARK_AB_BA_ORDERS_COMPLETED:-${PAIR_ORDER}}"

TARGET_A_MATRIX_ROW=""
TARGET_B_MATRIX_ROW=""
TARGET_A_MATRIX_ERR_FILE="$(mktemp)"
TARGET_B_MATRIX_ERR_FILE="$(mktemp)"

if ! TARGET_A_MATRIX_ROW="$(target_registry_matrix_row_json "$TARGET_A_INPUT" 2>"${TARGET_A_MATRIX_ERR_FILE}")"; then
  TARGET_A_MATRIX_REASON="$(tr '\n' ' ' < "${TARGET_A_MATRIX_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
else
  TARGET_A_MATRIX_REASON="resolved"
fi

if ! TARGET_B_MATRIX_ROW="$(target_registry_matrix_row_json "$TARGET_B_INPUT" 2>"${TARGET_B_MATRIX_ERR_FILE}")"; then
  TARGET_B_MATRIX_REASON="$(tr '\n' ' ' < "${TARGET_B_MATRIX_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
else
  TARGET_B_MATRIX_REASON="resolved"
fi

rm -f "${TARGET_A_MATRIX_ERR_FILE}" "${TARGET_B_MATRIX_ERR_FILE}"

COMPATIBLE_TARGETS_PASS=true
COMPATIBLE_TARGETS_REASON="both targets listed in compatible_targets"
for target in "$TARGET_A_CANONICAL" "$TARGET_B_CANONICAL"; do
  if ! jq -e --arg t "$target" '.compatible_targets[] | select(.target_id == $t)' "$PAIR_MANIFEST" >/dev/null 2>&1; then
    COMPATIBLE_TARGETS_PASS=false
    COMPATIBLE_TARGETS_REASON="target '${target}' is not listed in compatible_targets of ${PAIR_MANIFEST}"
    break
  fi
done

# Per-target contract scoping. A compatible_targets entry MAY carry an
# `eligible_contracts` array; when present, that target participates only in
# runs whose --contract-id appears in it. Absent means unrestricted, so every
# target declared before this check existed is unaffected.
#
# This exists because eligibility is not always uniform across a scenario's
# contract family. spring-on-exeris-pure serves the heavy aggregate endpoint but
# cannot serve the light single-read one: its path carries a query string, and
# the Exeris pure-mode dispatcher resolves routes by exact match on the full
# request target (BudgetHQ DEC-046). Listing the target against every entry in
# required_contracts would assert a capability it does not have, and the run
# would fail later and less legibly at endpoint preflight.
TARGET_CONTRACT_SCOPE_PASS=true
TARGET_CONTRACT_SCOPE_REASON="no per-target contract restriction applies"
for target in "$TARGET_A_CANONICAL" "$TARGET_B_CANONICAL"; do
  if ! jq -e --arg t "$target" \
      '([.compatible_targets[]? | select(.target_id == $t)][0].eligible_contracts // null) | type == "array"' \
      "$PAIR_MANIFEST" >/dev/null 2>&1; then
    continue
  fi
  if ! jq -e --arg t "$target" --arg c "$CONTRACT_ID" \
      '[.compatible_targets[]? | select(.target_id == $t)][0].eligible_contracts | index($c) != null' \
      "$PAIR_MANIFEST" >/dev/null 2>&1; then
    TARGET_CONTRACT_SCOPE_ALLOWED="$(jq -r --arg t "$target" \
      '[.compatible_targets[]? | select(.target_id == $t)][0].eligible_contracts | join(", ")' \
      "$PAIR_MANIFEST")"
    TARGET_CONTRACT_SCOPE_PASS=false
    TARGET_CONTRACT_SCOPE_REASON="target '${target}' is declared eligible only for contracts [${TARGET_CONTRACT_SCOPE_ALLOWED}] but --contract-id=${CONTRACT_ID}"
    break
  fi
done

ALLOWED_PAIR_PASS=true
ALLOWED_PAIR_REASON="pair declared in allowed_pairs"
ALLOWED_PAIR_ID=""
ALLOWED_PAIR_WORKLOAD_KEY=""
ALLOWED_PAIR_MATCH_COUNT="$(jq -r --arg a "$TARGET_A_CANONICAL" --arg b "$TARGET_B_CANONICAL" '
  (.allowed_pairs // [])
  | map(select((.targets | type == "array") and (.targets | length == 2) and (.targets | index($a) != null) and (.targets | index($b) != null)))
  | length
' "$PAIR_MANIFEST")"

if [[ "$ALLOWED_PAIR_MATCH_COUNT" == "0" ]]; then
  ALLOWED_PAIR_PASS=false
  ALLOWED_PAIR_REASON="pair '${TARGET_A_CANONICAL}' + '${TARGET_B_CANONICAL}' is not declared in allowed_pairs of ${PAIR_MANIFEST}"
elif [[ "$ALLOWED_PAIR_MATCH_COUNT" != "1" ]]; then
  ALLOWED_PAIR_PASS=false
  ALLOWED_PAIR_REASON="ambiguous allowed_pairs declaration for '${TARGET_A_CANONICAL}' + '${TARGET_B_CANONICAL}' (matches=${ALLOWED_PAIR_MATCH_COUNT})"
else
  ALLOWED_PAIR_ID="$(jq -r --arg a "$TARGET_A_CANONICAL" --arg b "$TARGET_B_CANONICAL" '
    (.allowed_pairs // [])
    | map(select((.targets | type == "array") and (.targets | length == 2) and (.targets | index($a) != null) and (.targets | index($b) != null)))
    | .[0].pair_id // empty
  ' "$PAIR_MANIFEST")"
  ALLOWED_PAIR_WORKLOAD_KEY="$(jq -r --arg a "$TARGET_A_CANONICAL" --arg b "$TARGET_B_CANONICAL" '
    (.allowed_pairs // [])
    | map(select((.targets | type == "array") and (.targets | length == 2) and (.targets | index($a) != null) and (.targets | index($b) != null)))
    | .[0].workload_profile_key // empty
  ' "$PAIR_MANIFEST")"
fi

WORKLOAD_PROFILE_KEY="${ALLOWED_PAIR_WORKLOAD_KEY:-}"
if [[ -z "$WORKLOAD_PROFILE_KEY" ]]; then
  WORKLOAD_PROFILE_KEY="$(jq -r '.workload_profile_key // empty' "$PAIR_MANIFEST")"
fi
if [[ -z "$WORKLOAD_PROFILE_KEY" ]]; then
  echo "CONFIG_ERROR: workload_profile_key is required in comparative pair manifest for scenario '${SCENARIO_ID}'" >&2
  exit 64
fi

# Align the workload_profile_key's driver-family suffix with the CONTRACT's benchmark_family.
# The manifest's allowed_pairs carry a '-runtime-wrk' key (the wrk throughput family). A wrk2
# (CO-free latency, p99_stable) contract registered on those same pairs must NOT inherit that
# key: its p99 latency data must never aggregate with wrk throughput. Suffix '-runtime-wrk' ->
# '-runtime-wrk2' so the key self-identifies and stays isolated (belt-and-suspenders on top of
# contract_id isolation). wrk (throughput) contracts are unchanged.
CONTRACT_BENCHMARK_FAMILY="$(jq -r --arg c "$CONTRACT_ID" '.fixed_contracts[$c].benchmark_family // empty' "$SCENARIO_JSON" 2>/dev/null)"
if [[ "$CONTRACT_BENCHMARK_FAMILY" == "runtime-wrk2" && "$WORKLOAD_PROFILE_KEY" == *-runtime-wrk ]]; then
  WORKLOAD_PROFILE_KEY="${WORKLOAD_PROFILE_KEY}2"
  echo "  workload_profile_key: suffixed to '${WORKLOAD_PROFILE_KEY}' for runtime-wrk2 contract (isolated from the wrk throughput family)"
fi

FORBIDDEN_PAIR_PASS=true
FORBIDDEN_PAIR_REASON="pair is not forbidden"
if jq -e \
    --arg a "$TARGET_A_CANONICAL" --arg b "$TARGET_B_CANONICAL" \
    '.forbidden_pairs[] | select( (.targets | contains([$a])) and (.targets | contains([$b])) )' \
    "$PAIR_MANIFEST" >/dev/null 2>&1; then
  FORBIDDEN_PAIR_PASS=false
  FORBIDDEN_PAIR_REASON="$(jq -r --arg a "$TARGET_A_CANONICAL" --arg b "$TARGET_B_CANONICAL" \
    '.forbidden_pairs[] | select( (.targets | contains([$a])) and (.targets | contains([$b])) ) | .reason' \
    "$PAIR_MANIFEST")"
fi

CLAIM_POLICY_REQUIRED_PASS=true
CLAIM_POLICY_REQUIRED_REASON="pair claim eligibility requirement disabled"
REQUIRE_CLAIM_ELIGIBLE_RUN_FOR_PAIR="$(jq -r '.require_claim_eligible_run_for_pair // false' "$PAIR_MANIFEST")"
if [[ "$REQUIRE_CLAIM_ELIGIBLE_RUN_FOR_PAIR" == "true" ]]; then
  if [[ "$TARGET_A_CLAIM_SCOPE" == "comparison_eligible" && "$TARGET_B_CLAIM_SCOPE" == "comparison_eligible" ]]; then
    CLAIM_POLICY_REQUIRED_REASON="both targets are comparison_eligible"
  else
    CLAIM_POLICY_REQUIRED_PASS=false
    CLAIM_POLICY_REQUIRED_REASON="require_claim_eligible_run_for_pair=true but claim_scope is target_a=${TARGET_A_CLAIM_SCOPE}, target_b=${TARGET_B_CLAIM_SCOPE}"
  fi
fi

SAME_TIER_PASS=false
SAME_PROTOCOL_PASS=false
SAME_TIER_REASON=""
SAME_PROTOCOL_REASON=""

if [[ -n "$TARGET_A_MATRIX_ROW" && -n "$TARGET_B_MATRIX_ROW" ]]; then
  TARGET_A_TIER_MATRIX="$(jq -r '.tier' <<<"$TARGET_A_MATRIX_ROW")"
  TARGET_B_TIER_MATRIX="$(jq -r '.tier' <<<"$TARGET_B_MATRIX_ROW")"
  TARGET_A_PROTOCOL_MATRIX="$(jq -r '.protocol_mode' <<<"$TARGET_A_MATRIX_ROW")"
  TARGET_B_PROTOCOL_MATRIX="$(jq -r '.protocol_mode' <<<"$TARGET_B_MATRIX_ROW")"

  if [[ "$TARGET_A_TIER_MATRIX" == "$TARGET_B_TIER_MATRIX" ]]; then
    SAME_TIER_PASS=true
    SAME_TIER_REASON="same tier (${TARGET_A_TIER_MATRIX})"
  else
    SAME_TIER_REASON="tier mismatch: ${TARGET_A_CANONICAL}=${TARGET_A_TIER_MATRIX}, ${TARGET_B_CANONICAL}=${TARGET_B_TIER_MATRIX}"
  fi

  if [[ "$TARGET_A_PROTOCOL_MATRIX" == "$TARGET_B_PROTOCOL_MATRIX" ]]; then
    SAME_PROTOCOL_PASS=true
    SAME_PROTOCOL_REASON="same protocol_mode (${TARGET_A_PROTOCOL_MATRIX})"
  else
    SAME_PROTOCOL_REASON="protocol_mode mismatch: ${TARGET_A_CANONICAL}=${TARGET_A_PROTOCOL_MATRIX}, ${TARGET_B_CANONICAL}=${TARGET_B_PROTOCOL_MATRIX}"
  fi
else
  SAME_TIER_REASON="matrix resolution failed: A='${TARGET_A_MATRIX_REASON}', B='${TARGET_B_MATRIX_REASON}'"
  SAME_PROTOCOL_REASON="matrix resolution failed: A='${TARGET_A_MATRIX_REASON}', B='${TARGET_B_MATRIX_REASON}'"
fi

TARGET_A_CONTRACT_JSON=""
TARGET_B_CONTRACT_JSON=""
TARGET_A_RESOLVE_REASON=""
TARGET_B_RESOLVE_REASON=""
TARGET_A_RESOLVE_ERR_FILE="$(mktemp)"
TARGET_B_RESOLVE_ERR_FILE="$(mktemp)"

if resolve_target_contract "$TARGET_A_INPUT" 2>"${TARGET_A_RESOLVE_ERR_FILE}" && assert_target_contract_complete 2>>"${TARGET_A_RESOLVE_ERR_FILE}"; then
  TARGET_A_CONTRACT_JSON="$(target_contract_to_json)"
  TARGET_A_RESOLVE_REASON="runnable target contract resolved"
else
  TARGET_A_RESOLVE_REASON="$(tr '\n' ' ' < "${TARGET_A_RESOLVE_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
fi

if resolve_target_contract "$TARGET_B_INPUT" 2>"${TARGET_B_RESOLVE_ERR_FILE}" && assert_target_contract_complete 2>>"${TARGET_B_RESOLVE_ERR_FILE}"; then
  TARGET_B_CONTRACT_JSON="$(target_contract_to_json)"
  TARGET_B_RESOLVE_REASON="runnable target contract resolved"
else
  TARGET_B_RESOLVE_REASON="$(tr '\n' ' ' < "${TARGET_B_RESOLVE_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
fi

rm -f "${TARGET_A_RESOLVE_ERR_FILE}" "${TARGET_B_RESOLVE_ERR_FILE}"

RUNNABLE_PASS=false
RUNNABLE_REASON=""
if [[ -n "$TARGET_A_CONTRACT_JSON" && -n "$TARGET_B_CONTRACT_JSON" ]]; then
  RUNNABLE_PASS=true
  RUNNABLE_REASON="both targets resolved as runnable"
else
  RUNNABLE_REASON="target-a='${TARGET_A_RESOLVE_REASON}'; target-b='${TARGET_B_RESOLVE_REASON}'"
fi

PAIR_ELIGIBLE=true
PAIR_FAILURE_REASONS=()
if [[ "$COMPATIBLE_TARGETS_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("compatible_targets: ${COMPATIBLE_TARGETS_REASON}")
fi
if [[ "$SAME_TIER_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("same_tier: ${SAME_TIER_REASON}")
fi
if [[ "$SAME_PROTOCOL_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("same_protocol_mode: ${SAME_PROTOCOL_REASON}")
fi
if [[ "$RUNNABLE_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("runnable: ${RUNNABLE_REASON}")
fi
if [[ "$TARGET_CONTRACT_SCOPE_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("target_contract_scope: ${TARGET_CONTRACT_SCOPE_REASON}")
fi
if [[ "$ALLOWED_PAIR_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("allowed_pairs: ${ALLOWED_PAIR_REASON}")
fi
if [[ "$FORBIDDEN_PAIR_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("forbidden_pair: ${FORBIDDEN_PAIR_REASON}")
fi
if [[ "$CLAIM_POLICY_REQUIRED_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("claim_policy_required: ${CLAIM_POLICY_REQUIRED_REASON}")
fi

jq -n \
  --arg scenario_id "$SCENARIO_ID" \
  --arg contract_id "$CONTRACT_ID" \
  --arg target_a_input "$TARGET_A_INPUT" \
  --arg target_b_input "$TARGET_B_INPUT" \
  --arg target_a_canonical "$TARGET_A_CANONICAL" \
  --arg target_b_canonical "$TARGET_B_CANONICAL" \
  --arg target_a_claim_scope "$TARGET_A_CLAIM_SCOPE" \
  --arg target_b_claim_scope "$TARGET_B_CLAIM_SCOPE" \
  --argjson claim_eligible_run "$CLAIM_ELIGIBLE_RUN" \
  --argjson pair_eligible "$PAIR_ELIGIBLE" \
  --argjson compatible_targets_pass "$COMPATIBLE_TARGETS_PASS" \
  --arg compatible_targets_reason "$COMPATIBLE_TARGETS_REASON" \
  --argjson same_tier_pass "$SAME_TIER_PASS" \
  --arg same_tier_reason "$SAME_TIER_REASON" \
  --argjson same_protocol_pass "$SAME_PROTOCOL_PASS" \
  --arg same_protocol_reason "$SAME_PROTOCOL_REASON" \
  --argjson runnable_pass "$RUNNABLE_PASS" \
  --arg runnable_reason "$RUNNABLE_REASON" \
  --argjson target_contract_scope_pass "$TARGET_CONTRACT_SCOPE_PASS" \
  --arg target_contract_scope_reason "$TARGET_CONTRACT_SCOPE_REASON" \
  --argjson allowed_pair_pass "$ALLOWED_PAIR_PASS" \
  --arg allowed_pair_reason "$ALLOWED_PAIR_REASON" \
  --arg allowed_pair_id "$ALLOWED_PAIR_ID" \
  --arg workload_profile_key "$WORKLOAD_PROFILE_KEY" \
  --argjson forbidden_pair_pass "$FORBIDDEN_PAIR_PASS" \
  --arg forbidden_pair_reason "$FORBIDDEN_PAIR_REASON" \
  --argjson claim_policy_required_pass "$CLAIM_POLICY_REQUIRED_PASS" \
  --arg claim_policy_required_reason "$CLAIM_POLICY_REQUIRED_REASON" \
'{
  scenario_id: $scenario_id,
  contract_id: $contract_id,
  target_a_input: $target_a_input,
  target_b_input: $target_b_input,
  target_a_canonical: $target_a_canonical,
  target_b_canonical: $target_b_canonical,
  pair_eligible: $pair_eligible,
  claim_policy: {
    target_a_claim_scope: $target_a_claim_scope,
    target_b_claim_scope: $target_b_claim_scope,
    claim_eligible_run: $claim_eligible_run
  },
  checks: {
    compatible_targets: {
      pass: $compatible_targets_pass,
      reason: $compatible_targets_reason
    },
    same_tier: {
      pass: $same_tier_pass,
      reason: $same_tier_reason
    },
    same_protocol_mode: {
      pass: $same_protocol_pass,
      reason: $same_protocol_reason
    },
    target_contract_scope: {
      pass: $target_contract_scope_pass,
      reason: $target_contract_scope_reason
    },
    runnable_targets: {
      pass: $runnable_pass,
      reason: $runnable_reason
    },
    allowed_pairs: {
      pass: $allowed_pair_pass,
      reason: $allowed_pair_reason,
      pair_id: $allowed_pair_id,
      workload_profile_key: $workload_profile_key
    },
    forbidden_pair: {
      pass: $forbidden_pair_pass,
      reason: $forbidden_pair_reason
    },
    claim_policy_required: {
      pass: $claim_policy_required_pass,
      reason: $claim_policy_required_reason
    }
  }
}' > "${OUTPUT_DIR}/logs/pair-eligibility.json"

if [[ "$PAIR_ELIGIBLE" != true ]]; then
  echo "CONFIG_ERROR: baseline pair eligibility failed: $(IFS=' | '; echo "${PAIR_FAILURE_REASONS[*]}")" >&2
  exit 64
fi

# Deterministic mapping guard: repeated resolution must produce the same contract.
resolve_target_contract "$TARGET_A_INPUT" || { rc=$?; exit "$rc"; }
assert_target_contract_complete || { rc=$?; exit "$rc"; }
TARGET_A_CONTRACT_JSON_REPEAT="$(target_contract_to_json)"
if [[ "$TARGET_A_CONTRACT_JSON" != "$TARGET_A_CONTRACT_JSON_REPEAT" ]]; then
  echo "CONFIG_ERROR: Non-deterministic target contract resolution for target-a '${TARGET_A_INPUT}'" >&2
  exit 64
fi

resolve_target_contract "$TARGET_B_INPUT" || { rc=$?; exit "$rc"; }
assert_target_contract_complete || { rc=$?; exit "$rc"; }
TARGET_B_CONTRACT_JSON_REPEAT="$(target_contract_to_json)"
if [[ "$TARGET_B_CONTRACT_JSON" != "$TARGET_B_CONTRACT_JSON_REPEAT" ]]; then
  echo "CONFIG_ERROR: Non-deterministic target contract resolution for target-b '${TARGET_B_INPUT}'" >&2
  exit 64
fi

TARGET_A="$(jq -r '.target_id' <<<"$TARGET_A_CONTRACT_JSON")"
TARGET_B="$(jq -r '.target_id' <<<"$TARGET_B_CONTRACT_JSON")"
TARGET_A_PROTOCOL_MODE="$(jq -r '.protocol_mode' <<<"$TARGET_A_CONTRACT_JSON")"
TARGET_B_PROTOCOL_MODE="$(jq -r '.protocol_mode' <<<"$TARGET_B_CONTRACT_JSON")"

if [[ "$SCENARIO_ID" == "$STRICT_SCENARIO_ID" ]]; then
  TARGET_A_PROFILE_ID="$(jq -r '.profile_id' <<<"$TARGET_A_CONTRACT_JSON")"
  TARGET_B_PROFILE_ID="$(jq -r '.profile_id' <<<"$TARGET_B_CONTRACT_JSON")"

  if [[ "$TARGET_A_PROFILE_ID" != "$TARGET_A" ]]; then
    echo "CONFIG_ERROR: strict comparative path requires profile immutability: target-a profile_id='${TARGET_A_PROFILE_ID}' must equal target_id='${TARGET_A}'" >&2
    exit 64
  fi

  if [[ "$TARGET_B_PROFILE_ID" != "$TARGET_B" ]]; then
    echo "CONFIG_ERROR: strict comparative path requires profile immutability: target-b profile_id='${TARGET_B_PROFILE_ID}' must equal target_id='${TARGET_B}'" >&2
    exit 64
  fi
fi

if [[ "$TARGET_A_PROTOCOL_MODE" != "$TARGET_B_PROTOCOL_MODE" ]]; then
  echo "CONFIG_ERROR: protocol_mode mismatch between resolved targets: ${TARGET_A}=${TARGET_A_PROTOCOL_MODE}, ${TARGET_B}=${TARGET_B_PROTOCOL_MODE}" >&2
  exit 64
fi

# ---------------------------------------------------------------------------
# Protocol-as-run-axis resolution (additive; runs AFTER the native A==B check
# above so the overwrite in step (vi) cannot neuter that check — the native
# values are still authoritative for A==B agreement here).
#   contract pin wins → else run axis → else FAIL CLOSED.
# For a legacy pinned h1 contract with no axis: EFFECTIVE=h1, every guard passes,
# and step (vi) is an h1→h1 no-op — byte-identical to pre-refactor behavior.
# ---------------------------------------------------------------------------
CONTRACT_PROTOCOL_MODE="$(jq -r --arg c "$CONTRACT_ID" \
  '.fixed_contracts[$c].protocol_mode // empty' "$SCENARIO_JSON")"
CONTRACT_TRANSPORT_MODE="$(jq -r --arg c "$CONTRACT_ID" \
  '.fixed_contracts[$c].transport_mode // empty' "$SCENARIO_JSON")"

# (i) effective protocol: contract pin wins; else axis; else FAIL CLOSED.
if [[ -n "$CONTRACT_PROTOCOL_MODE" ]]; then
  if [[ -n "$PROTOCOL_MODE_AXIS" && "$PROTOCOL_MODE_AXIS" != "$CONTRACT_PROTOCOL_MODE" ]]; then
    echo "CONFIG_ERROR: protocol axis conflict — contract '${CONTRACT_ID}' pins protocol_mode=${CONTRACT_PROTOCOL_MODE} but run axis supplied ${PROTOCOL_MODE_AXIS}; a pinned contract may not be overridden [rejection_code=PROTOCOL_AXIS_CONFLICT]" >&2
    exit 64
  fi
  EFFECTIVE_PROTOCOL_MODE="$CONTRACT_PROTOCOL_MODE"
  CONTRACT_PROTOCOL_AGNOSTIC=false
elif [[ -n "$PROTOCOL_MODE_AXIS" ]]; then
  EFFECTIVE_PROTOCOL_MODE="$PROTOCOL_MODE_AXIS"
  CONTRACT_PROTOCOL_AGNOSTIC=true
else
  echo "CONFIG_ERROR: contract '${CONTRACT_ID}' is protocol-agnostic and no protocol axis was supplied; pass --protocol-mode <h1|h2|h2c|h3> or set BENCH_PROTOCOL_MODE_OVERRIDE [rejection_code=PROTOCOL_AXIS_MISSING]" >&2
  exit 64
fi

# (ii) enum-validate the effective protocol (mirror target-contract-registry.sh enum case).
case "$EFFECTIVE_PROTOCOL_MODE" in
  h1|h2|h2c|h3) ;;
  *) echo "CONFIG_ERROR: invalid effective protocol_mode='${EFFECTIVE_PROTOCOL_MODE}' (expected h1|h2|h2c|h3) [rejection_code=PROTOCOL_ENUM_INVALID]" >&2; exit 64 ;;
esac

# (iii) effective transport: axis override, else contract pin, else loopback-<p>
#       (h2c collapses to loopback-h2 per transport enum + run-guided.sh convention).
if [[ -n "$TRANSPORT_MODE_AXIS" ]]; then
  EFFECTIVE_TRANSPORT_MODE="$TRANSPORT_MODE_AXIS"
elif [[ -n "$CONTRACT_TRANSPORT_MODE" ]]; then
  EFFECTIVE_TRANSPORT_MODE="$CONTRACT_TRANSPORT_MODE"
elif [[ "$EFFECTIVE_PROTOCOL_MODE" == "h2c" ]]; then
  EFFECTIVE_TRANSPORT_MODE="loopback-h2"
else
  EFFECTIVE_TRANSPORT_MODE="loopback-${EFFECTIVE_PROTOCOL_MODE}"
fi

# (iv) driver-capability honesty guard — do NOT mint a label-only non-h1 wrk claim.
#      Scoped to AXIS-derived protocols only. A contract that explicitly PINS its
#      protocol is the operator's deliberate, pre-existing choice, so a legacy pinned
#      non-h1 contract keeps working exactly as it did before this refactor. (A pinned
#      h1 passes anyway — h1 is in the allowlist.) Only an agnostic contract steered by
#      the run axis into a protocol the wrk driver cannot serve is refused here.
if [[ "$CONTRACT_PROTOCOL_AGNOSTIC" == true ]]; then
  case " $COMPARATIVE_DRIVER_PROTOCOL_ALLOWLIST " in
    *" $EFFECTIVE_PROTOCOL_MODE "*) ;;
    *) echo "CONFIG_ERROR: effective protocol_mode=${EFFECTIVE_PROTOCOL_MODE} is not served by the wrk comparative driver (allowlist='${COMPARATIVE_DRIVER_PROTOCOL_ALLOWLIST}'); the wrk comparative path drives cleartext HTTP/1.1 only — refusing a label-only claim [rejection_code=PROTOCOL_DRIVER_UNSUPPORTED]" >&2; exit 64 ;;
  esac
fi

# (v) tie the effective protocol to the resolved targets' native protocol. The native
#     A==B check above already guarantees the two targets agree; assert that shared native
#     protocol equals the effective protocol so an axis value can never silently diverge
#     from what the targets actually serve.
if [[ "$TARGET_A_PROTOCOL_MODE" != "$EFFECTIVE_PROTOCOL_MODE" ]]; then
  echo "CONFIG_ERROR: effective protocol_mode=${EFFECTIVE_PROTOCOL_MODE} does not match resolved target-native protocol=${TARGET_A_PROTOCOL_MODE} for '${TARGET_A}'; the run axis may not relabel a target's native protocol [rejection_code=PROTOCOL_TARGET_MISMATCH]" >&2
  exit 64
fi

# (vi) make the effective protocol authoritative for ALL downstream stamps/keys/echoes
#      (echo, per-target result stamping, pair_fingerprint, axis label all inherit this).
TARGET_A_PROTOCOL_MODE="$EFFECTIVE_PROTOCOL_MODE"
TARGET_B_PROTOCOL_MODE="$EFFECTIVE_PROTOCOL_MODE"

TARGET_A_TIER="$(jq -r '.tier' <<<"$TARGET_A_CONTRACT_JSON")"
TARGET_B_TIER="$(jq -r '.tier' <<<"$TARGET_B_CONTRACT_JSON")"
if [[ "$TARGET_A_TIER" != "$TARGET_B_TIER" ]]; then
  echo "CONFIG_ERROR: tier mismatch between resolved targets: ${TARGET_A}=${TARGET_A_TIER}, ${TARGET_B}=${TARGET_B_TIER}" >&2
  exit 64
fi

TARGET_A_HEALTH_URL="$(jq -r '.health_url' <<<"$TARGET_A_CONTRACT_JSON")"
TARGET_B_HEALTH_URL="$(jq -r '.health_url' <<<"$TARGET_B_CONTRACT_JSON")"

CONTRACT_REQUIRED_PROFILE="$(jq -r --arg c "$CONTRACT_ID" '.fixed_contracts[$c].required_profile // empty' "$SCENARIO_JSON")"
if [[ -n "$CONTRACT_REQUIRED_PROFILE" ]]; then
  EFFECTIVE_HARDWARE_PROFILE="${HARDWARE_PROFILE:-}"
  if [[ -z "$EFFECTIVE_HARDWARE_PROFILE" ]]; then
    echo "CONFIG_ERROR: missing HARDWARE_PROFILE for contract '${CONTRACT_ID}' (required_profile=${CONTRACT_REQUIRED_PROFILE})" >&2
    exit 64
  fi
  if [[ "$EFFECTIVE_HARDWARE_PROFILE" != "$CONTRACT_REQUIRED_PROFILE" ]]; then
    echo "CONFIG_ERROR: hardware profile mismatch for contract '${CONTRACT_ID}': HARDWARE_PROFILE=${EFFECTIVE_HARDWARE_PROFILE} required_profile=${CONTRACT_REQUIRED_PROFILE}" >&2
    exit 64
  fi
fi

TARGET_A_CONTRACT_PORT=""
TARGET_B_CONTRACT_PORT=""
if ! TARGET_A_CONTRACT_PORT="$(extract_health_port "$TARGET_A_HEALTH_URL")"; then
  echo "CONFIG_ERROR: unable to derive port from target-a health_url '${TARGET_A_HEALTH_URL}' for '${TARGET_A}'" >&2
  exit 64
fi
if ! TARGET_B_CONTRACT_PORT="$(extract_health_port "$TARGET_B_HEALTH_URL")"; then
  echo "CONFIG_ERROR: unable to derive port from target-b health_url '${TARGET_B_HEALTH_URL}' for '${TARGET_B}'" >&2
  exit 64
fi

if [[ -z "$TARGET_A_PORT" ]]; then
  TARGET_A_PORT="$TARGET_A_CONTRACT_PORT"
fi
if [[ -z "$TARGET_B_PORT" ]]; then
  TARGET_B_PORT="$TARGET_B_CONTRACT_PORT"
fi

if [[ "$TARGET_A_PORT" != "$TARGET_A_CONTRACT_PORT" ]]; then
  echo "CONFIG_ERROR: target-a port mismatch for '${TARGET_A}': TARGET_A_PORT=${TARGET_A_PORT} but contract health_url port=${TARGET_A_CONTRACT_PORT} (${TARGET_A_HEALTH_URL})" >&2
  exit 64
fi
if [[ "$TARGET_B_PORT" != "$TARGET_B_CONTRACT_PORT" ]]; then
  echo "CONFIG_ERROR: target-b port mismatch for '${TARGET_B}': TARGET_B_PORT=${TARGET_B_PORT} but contract health_url port=${TARGET_B_CONTRACT_PORT} (${TARGET_B_HEALTH_URL})" >&2
  exit 64
fi

COMPARATIVE_ID="$(gen_uuid)"
TIMESTAMP_UTC="$(ts_now_utc)"
SCENARIO_ENDPOINT_PATH="$(resolve_scenario_endpoint_path "$SCENARIO_JSON" "$CONTRACT_ID")"

jq -n \
  --arg target_a_input "$TARGET_A_INPUT" \
  --arg target_b_input "$TARGET_B_INPUT" \
  --argjson target_a_contract "$TARGET_A_CONTRACT_JSON" \
  --argjson target_b_contract "$TARGET_B_CONTRACT_JSON" \
'{
  target_a_input: $target_a_input,
  target_b_input: $target_b_input,
  target_a_contract: $target_a_contract,
  target_b_contract: $target_b_contract
}' > "${OUTPUT_DIR}/logs/resolved-target-contracts.json"

echo "  comparative_id       : ${COMPARATIVE_ID}"
echo "  timestamp_utc        : ${TIMESTAMP_UTC}"
echo "  scenario_id          : ${SCENARIO_ID}"
echo "  contract_id          : ${CONTRACT_ID}"
echo "  scenario_endpoint_path : ${SCENARIO_ENDPOINT_PATH}"
echo "  target_a_input       : ${TARGET_A_INPUT}"
echo "  target_b_input       : ${TARGET_B_INPUT}"
echo "  target_a             : ${TARGET_A}"
echo "  target_b             : ${TARGET_B}"
echo "  target_a_claim_scope : ${TARGET_A_CLAIM_SCOPE}"
echo "  target_b_claim_scope : ${TARGET_B_CLAIM_SCOPE}"
echo "  claim_eligible_run   : ${CLAIM_ELIGIBLE_RUN}"
echo "  track_id             : ${TRACK_ID}"
echo "  pair_id              : ${PAIR_ID}"
echo "  allowed_pair_id      : ${ALLOWED_PAIR_ID}"
echo "  pair_order           : ${PAIR_ORDER}"
echo "  ab_ba_completed      : ${AB_BA_ORDERS_COMPLETED_RAW}"
echo "  workload_profile_key : ${WORKLOAD_PROFILE_KEY}"
echo "  protocol_mode        : ${TARGET_A_PROTOCOL_MODE}"
echo "  measurement_seconds  : ${MEASUREMENT_SECONDS}"
echo "  warmup_seconds       : ${WARMUP_SECONDS}"
echo "  output_dir           : ${OUTPUT_DIR}"
echo "  dry_run              : ${DRY_RUN}"
echo "  target_a_port        : ${TARGET_A_PORT}"
echo "  target_b_port        : ${TARGET_B_PORT}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "${YELLOW}  [DRY RUN MODE ACTIVE]${NC}"
fi

# ============================================================
# STAGE 2: Pre-flight gate validation
# ============================================================
banner "STAGE 2: Pre-flight Gate Validation"

# Always: verify structural prerequisites
echo "  Checking scenario manifest..."
if ! jq -e ".fixed_contracts.\"${CONTRACT_ID}\"" "$SCENARIO_JSON" >/dev/null 2>&1; then
  echo "ERROR: contract_id '${CONTRACT_ID}' not found in ${SCENARIO_JSON}#fixed_contracts" >&2
  exit 1
fi
echo -e "  ${GREEN}✓${NC} contract_id '${CONTRACT_ID}' found in scenario manifest."

if comparative_contract_is_constrained "$SCENARIO_JSON" "$CONTRACT_ID" || \
   comparative_path_is_constrained "$OUTPUT_DIR" "${BENCHMARK_EXECUTION_PROFILE_ID:-$(comparative_contract_execution_profile_id "$SCENARIO_JSON" "$CONTRACT_ID")}" "$TRACK_ID"; then
  comparative_fail_closed_constrained
fi

if [[ "$SCENARIO_ID" == "entity-read-by-id" ]]; then
  expected_warmup_seconds="$(jq -r --arg c "$CONTRACT_ID" '.fixed_contracts[$c].warmup_seconds // empty' "$SCENARIO_JSON")"
  expected_duration_seconds="$(jq -r --arg c "$CONTRACT_ID" '.fixed_contracts[$c].duration_seconds // empty' "$SCENARIO_JSON")"
  expected_threads="$(jq -r --arg c "$CONTRACT_ID" '.fixed_contracts[$c].threads // empty' "$SCENARIO_JSON")"
  expected_connections="$(jq -r --arg c "$CONTRACT_ID" '.fixed_contracts[$c].connections // empty' "$SCENARIO_JSON")"

  if [[ -n "$expected_warmup_seconds" && "$WARMUP_SECONDS" != "$expected_warmup_seconds" ]]; then
    echo "CONFIG_ERROR: immutable scenario contract knob mismatch scenario_id=${SCENARIO_ID} contract_id=${CONTRACT_ID} knob=warmup_seconds expected=${expected_warmup_seconds} actual=${WARMUP_SECONDS}" >&2
    exit 64
  fi
  if [[ -n "$expected_duration_seconds" && "$MEASUREMENT_SECONDS" != "$expected_duration_seconds" ]]; then
    echo "CONFIG_ERROR: immutable scenario contract knob mismatch scenario_id=${SCENARIO_ID} contract_id=${CONTRACT_ID} knob=duration_seconds expected=${expected_duration_seconds} actual=${MEASUREMENT_SECONDS}" >&2
    exit 64
  fi
  if [[ -n "$expected_threads" && "$THREADS" != "$expected_threads" ]]; then
    echo "CONFIG_ERROR: immutable scenario contract knob mismatch scenario_id=${SCENARIO_ID} contract_id=${CONTRACT_ID} knob=threads expected=${expected_threads} actual=${THREADS}" >&2
    exit 64
  fi
  if [[ -n "$expected_connections" && "$CONNECTIONS" != "$expected_connections" ]]; then
    echo "CONFIG_ERROR: immutable scenario contract knob mismatch scenario_id=${SCENARIO_ID} contract_id=${CONTRACT_ID} knob=connections expected=${expected_connections} actual=${CONNECTIONS}" >&2
    exit 64
  fi
  # Protocol-as-run-axis immutable-knob audit line (parity with the knobs above). Uses the
  # EFFECTIVE protocol resolved earlier: pinned ⇒ effective must equal the pin; agnostic ⇒
  # the axis must have supplied a non-empty protocol (already fail-closed at resolution).
  if [[ -n "$CONTRACT_PROTOCOL_MODE" ]]; then
    if [[ "$EFFECTIVE_PROTOCOL_MODE" != "$CONTRACT_PROTOCOL_MODE" ]]; then
      echo "CONFIG_ERROR: immutable scenario contract knob mismatch scenario_id=${SCENARIO_ID} contract_id=${CONTRACT_ID} knob=protocol_mode expected=${CONTRACT_PROTOCOL_MODE} actual=${EFFECTIVE_PROTOCOL_MODE}" >&2
      exit 64
    fi
  else
    if [[ -z "$EFFECTIVE_PROTOCOL_MODE" ]]; then
      echo "CONFIG_ERROR: immutable scenario contract knob missing scenario_id=${SCENARIO_ID} contract_id=${CONTRACT_ID} knob=protocol_mode (protocol-agnostic contract requires --protocol-mode / BENCH_PROTOCOL_MODE_OVERRIDE)" >&2
      exit 64
    fi
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "  ${YELLOW}[DRY RUN] Skipping endpoint contract test gate.${NC}"
else
  run_endpoint_contract_test_gate
fi

echo "  Checking output-dir writability..."
if ! touch "${OUTPUT_DIR}/.write-check" 2>/dev/null; then
  echo "ERROR: output-dir is not writable: ${OUTPUT_DIR}" >&2
  exit 1
fi
rm -f "${OUTPUT_DIR}/.write-check"
echo -e "  ${GREEN}✓${NC} output-dir writable."

echo "  Checking both targets declared in pair manifest..."
echo -e "  ${GREEN}✓${NC} Both targets verified in comparative-pair-manifest.json."

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "  ${YELLOW}[DRY RUN] Skipping result-file gate validation (no existing result files required).${NC}"
else
  # In non-dry-run, attempt gate validation if result files already exist
  RESULT_A_PATH="${OUTPUT_DIR}/target-a/result.json"
  RESULT_B_PATH="${OUTPUT_DIR}/target-b/result.json"
  GATE_SCRIPT="${REPO_ROOT}/scripts/validate-comparative-readiness.sh"

  if [[ -f "$RESULT_A_PATH" && -f "$RESULT_B_PATH" && -x "$GATE_SCRIPT" ]]; then
    echo "  Running pre-flight gate validation against existing result files..."
    if ! "$GATE_SCRIPT" \
        --result-a    "$RESULT_A_PATH" \
        --result-b    "$RESULT_B_PATH" \
        --target-a-id "$TARGET_A" \
        --target-b-id "$TARGET_B" \
        --scenario-id "$SCENARIO_ID" \
        --contract-id "$CONTRACT_ID" \
        --track-id    "$TRACK_ID" \
        --summary-json "${OUTPUT_DIR}/logs/preflight-gate-summary.json" \
        --output      "${OUTPUT_DIR}/logs/preflight-gate-report.csv"; then
      echo "ERROR: Pre-flight gate validation failed." >&2
      exit 1
    fi
  else
    echo -e "  ${YELLOW}No existing result files — skipping pre-flight gate validation.${NC}"
  fi
fi

# ============================================================
# STAGE 3: Infrastructure preparation
# ============================================================
banner "STAGE 3: Infrastructure Preparation"

echo "  NOTE: TARGET LAUNCH IS EXTERNAL — this stage validates external jar prerequisites, runs scenario infra setup, then checks external readiness before Stage 4."
echo "  Infrastructure preparation is provider-specific."
echo "  For external targets, Stage 3 checks jar prerequisites before infra setup and health endpoint reachability after infra setup."

validate_external_target_prereqs "$TARGET_A" "$TARGET_A_PORT" "$TARGET_A_CONTRACT_JSON"
validate_external_target_prereqs "$TARGET_B" "$TARGET_B_PORT" "$TARGET_B_CONTRACT_JSON"

  # Optional scenario infrastructure hook — run when script is present unless caller pre-prepared infra.
  SCENARIO_INFRA_SCRIPT="${REPO_ROOT}/scenarios/${SCENARIO_ID}/infra-setup.sh"
  if [[ "$BENCH_SKIP_SCENARIO_INFRA_SETUP" == "1" ]]; then
    echo "  Scenario infra-setup skipped because it was pre-prepared by the caller (BENCH_SKIP_SCENARIO_INFRA_SETUP=1)."
  elif [[ -f "$SCENARIO_INFRA_SCRIPT" ]]; then
    echo "  Running scenario infra-setup: scenarios/${SCENARIO_ID}/infra-setup.sh"
    mkdir -p "$SCENARIO_DIAGNOSTICS_DIR"
    if ! BENCH_SCENARIO_DIAGNOSTICS_DIR="$SCENARIO_DIAGNOSTICS_DIR" \
      BENCH_CAPTURE_DB_EXPLAIN="${BENCH_CAPTURE_DB_EXPLAIN:-0}" \
      bash "$SCENARIO_INFRA_SCRIPT" 2>&1; then
      echo -e "${RED}ERROR${NC}: Scenario infrastructure setup failed." >&2
      exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Scenario infra-setup complete."
  else
    echo "  WARNING: No scenario infra-setup script found for ${SCENARIO_ID}; skipping DB/seed preparation."
  fi

validate_external_target_readiness "$TARGET_A" "$TARGET_A_CONTRACT_JSON"
validate_external_target_readiness "$TARGET_B" "$TARGET_B_CONTRACT_JSON"

touch "${OUTPUT_DIR}/stage3-complete.marker"
echo -e "  ${GREEN}✓${NC} stage3-complete.marker written."

# ---------------------------------------------------------------------------
# DRY RUN early exit — after stage 3
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  banner "DRY RUN COMPLETE"

  jq -n \
    --arg comparative_id   "$COMPARATIVE_ID" \
    --arg timestamp_utc    "$TIMESTAMP_UTC" \
    --arg scenario_id      "$SCENARIO_ID" \
    --arg contract_id      "$CONTRACT_ID" \
    --arg target_a         "$TARGET_A" \
    --arg target_b         "$TARGET_B" \
    --argjson measurement  "$MEASUREMENT_SECONDS" \
    --argjson warmup       "$WARMUP_SECONDS" \
    --arg output_dir       "$OUTPUT_DIR" \
  '{
    dry_run:            true,
    comparative_id:     $comparative_id,
    timestamp_utc:      $timestamp_utc,
    scenario_id:        $scenario_id,
    contract_id:        $contract_id,
    target_a:           $target_a,
    target_b:           $target_b,
    measurement_seconds: $measurement,
    warmup_seconds:     $warmup,
    output_dir:         $output_dir,
    stages_executed:    ["1-initialization","2-preflight","3-infrastructure"],
    preflight_passed:   true
  }' > "${OUTPUT_DIR}/dry-run-summary.json"

  echo -e "${GREEN}DRY RUN COMPLETE — pre-flight checks passed.${NC}"
  echo -e "  Summary: ${OUTPUT_DIR}/dry-run-summary.json"
  exit 0
fi

# ============================================================
# STAGE 4: Synchronized launch
# ============================================================
banner "STAGE 4: Synchronized Launch"

date -u +%Y-%m-%dT%H:%M:%S.%3NZ > "${OUTPUT_DIR}/logs/measurement-start-timestamp.txt"

FIRST_TARGET_ID="$TARGET_A"
FIRST_TARGET_PORT="$TARGET_A_PORT"
FIRST_TARGET_HEALTH_URL="$TARGET_A_HEALTH_URL"
FIRST_TARGET_OUTDIR="${OUTPUT_DIR}/target-a"
FIRST_TARGET_ENDPOINT="$SCENARIO_ENDPOINT_PATH"
FIRST_TARGET_CONTRACT_JSON="$TARGET_A_CONTRACT_JSON"
FIRST_TARGET_CLAIM_SCOPE="$TARGET_A_CLAIM_SCOPE"
FIRST_TARGET_SLOT="target-a"

SECOND_TARGET_ID="$TARGET_B"
SECOND_TARGET_PORT="$TARGET_B_PORT"
SECOND_TARGET_HEALTH_URL="$TARGET_B_HEALTH_URL"
SECOND_TARGET_OUTDIR="${OUTPUT_DIR}/target-b"
SECOND_TARGET_ENDPOINT="$SCENARIO_ENDPOINT_PATH"
SECOND_TARGET_CONTRACT_JSON="$TARGET_B_CONTRACT_JSON"
SECOND_TARGET_CLAIM_SCOPE="$TARGET_B_CLAIM_SCOPE"
SECOND_TARGET_SLOT="target-b"

if [[ "$PAIR_ORDER" == "ba" ]]; then
  FIRST_TARGET_ID="$TARGET_B"
  FIRST_TARGET_PORT="$TARGET_B_PORT"
  FIRST_TARGET_HEALTH_URL="$TARGET_B_HEALTH_URL"
  FIRST_TARGET_OUTDIR="${OUTPUT_DIR}/target-b"
  FIRST_TARGET_ENDPOINT="$SCENARIO_ENDPOINT_PATH"
  FIRST_TARGET_CONTRACT_JSON="$TARGET_B_CONTRACT_JSON"
  FIRST_TARGET_CLAIM_SCOPE="$TARGET_B_CLAIM_SCOPE"
  FIRST_TARGET_SLOT="target-b"

  SECOND_TARGET_ID="$TARGET_A"
  SECOND_TARGET_PORT="$TARGET_A_PORT"
  SECOND_TARGET_HEALTH_URL="$TARGET_A_HEALTH_URL"
  SECOND_TARGET_OUTDIR="${OUTPUT_DIR}/target-a"
  SECOND_TARGET_ENDPOINT="$SCENARIO_ENDPOINT_PATH"
  SECOND_TARGET_CONTRACT_JSON="$TARGET_A_CONTRACT_JSON"
  SECOND_TARGET_CLAIM_SCOPE="$TARGET_A_CLAIM_SCOPE"
  SECOND_TARGET_SLOT="target-a"
fi

wait_for_target_ready "$FIRST_TARGET_ID" "$FIRST_TARGET_HEALTH_URL" "${HEALTH_TIMEOUT_SECONDS:-60}" "${OUTPUT_DIR}/logs/${FIRST_TARGET_SLOT}-ready-timestamp.txt"
wait_for_target_ready "$SECOND_TARGET_ID" "$SECOND_TARGET_HEALTH_URL" "${HEALTH_TIMEOUT_SECONDS:-60}" "${OUTPUT_DIR}/logs/${SECOND_TARGET_SLOT}-ready-timestamp.txt"

# Define sync_log for this stage (it's used by multiple functions below)
sync_log="${OUTPUT_DIR}/logs/sync-log.txt"
mkdir -p "${OUTPUT_DIR}/logs"

if [[ "$SCENARIO_ID" == "entity-read-by-id" ]]; then
  # ============================================================
  # STAGE 4 (PREFLIGHT): Endpoint Diagnostics
  # ============================================================
  local_diag_log_first="${OUTPUT_DIR}/logs/endpoint-diag-target-${FIRST_TARGET_SLOT}.txt"
  local_diag_log_second="${OUTPUT_DIR}/logs/endpoint-diag-target-${SECOND_TARGET_SLOT}.txt"

  echo "
# ============================================================
# STAGE 4 (PREFLIGHT): Endpoint Diagnostics
# ============================================================
" | tee -a "$sync_log"
  
  if ! diagnose_endpoint "$FIRST_TARGET_ID" "$FIRST_TARGET_HEALTH_URL" "$SCENARIO_ENDPOINT_PATH" "$local_diag_log_first"; then
    echo "CONFIG_ERROR: endpoint preflight failed target_id=${FIRST_TARGET_ID} path=${SCENARIO_ENDPOINT_PATH} diagnostic_log=${local_diag_log_first} likely_cause=wrong external process/version on port ${FIRST_TARGET_PORT}" >&2
    echo "ERROR: refusing to continue Stage 4 after failed endpoint diagnostic for target_id=${FIRST_TARGET_ID}" >&2
    exit 1
  fi

  if ! diagnose_endpoint "$SECOND_TARGET_ID" "$SECOND_TARGET_HEALTH_URL" "$SCENARIO_ENDPOINT_PATH" "$local_diag_log_second"; then
    echo "CONFIG_ERROR: endpoint preflight failed target_id=${SECOND_TARGET_ID} path=${SCENARIO_ENDPOINT_PATH} diagnostic_log=${local_diag_log_second} likely_cause=wrong external process/version on port ${SECOND_TARGET_PORT}" >&2
    echo "ERROR: refusing to continue Stage 4 after failed endpoint diagnostic for target_id=${SECOND_TARGET_ID}" >&2
    exit 1
  fi
  
  echo "Diagnostic files saved. Now attempting to wait for endpoints..." | tee -a "$sync_log"
  
  wait_for_target_endpoint_ready "$FIRST_TARGET_ID" "$FIRST_TARGET_HEALTH_URL" "/db/ping" 60 "stage4-preflight-db-ping-${FIRST_TARGET_SLOT}"
  wait_for_target_endpoint_ready "$FIRST_TARGET_ID" "$FIRST_TARGET_HEALTH_URL" "$SCENARIO_ENDPOINT_PATH" 60 "stage4-preflight-entity-read-${FIRST_TARGET_SLOT}"
  wait_for_target_endpoint_ready "$SECOND_TARGET_ID" "$SECOND_TARGET_HEALTH_URL" "/db/ping" 60 "stage4-preflight-db-ping-${SECOND_TARGET_SLOT}"
  wait_for_target_endpoint_ready "$SECOND_TARGET_ID" "$SECOND_TARGET_HEALTH_URL" "$SCENARIO_ENDPOINT_PATH" 60 "stage4-preflight-entity-read-${SECOND_TARGET_SLOT}"
fi

# ------------------------------------------------------------------------------------------
# Artifact-identity assertion (fail-closed).
#
# Readiness proves SOMETHING is serving the port. It does not prove it is the build we meant.
# The serialisation-matrix arms are all produced from one Maven module and kept apart only by a
# version-staged jar plus a customizer on the classpath; if either mechanism regresses, all four
# arms launch the same runtime, every gate passes, and the campaign reports four different numbers
# for one binary. Asserting here costs a preflight failure instead of a full campaign of numbers
# attributed to the wrong build.
# ------------------------------------------------------------------------------------------
#
# ON BY DEFAULT since 2026-07-20, after a debug-contract run exercised it end-to-end on the perf
# box against targets already known to be correct: both arms of a two-instance exeris pair passed
# artifact identity, and the customizer arm passed the classpath and bootstrap-breadcrumb checks.
# It depends on `ss -ltnp` and /proc, so it cannot be tested from the Windows dev environment —
# that is why it shipped gated. Set BENCH_ASSERT_LAUNCH=0 to disable it for a run that genuinely
# cannot satisfy it (e.g. a target launched outside the harness).
LAUNCH_VERIFIER="${REPO_ROOT}/tools/verify-target-launch.sh"
if [[ "${BENCH_ASSERT_LAUNCH:-1}" != "1" ]]; then
  echo "NOTE: artifact-identity assertion disabled (BENCH_ASSERT_LAUNCH != 1)."
elif [[ -f "$LAUNCH_VERIFIER" ]]; then
  for _tv_pair in "${FIRST_TARGET_ID}|${FIRST_TARGET_HEALTH_URL}" "${SECOND_TARGET_ID}|${SECOND_TARGET_HEALTH_URL}"; do
    _tv_id="${_tv_pair%%|*}"
    _tv_url="${_tv_pair#*|}"
    _tv_port="$(printf '%s' "$_tv_url" | sed -E 's#.*:([0-9]+).*#\1#')"
    # Log path conventions differ per env file; match on the port when the log carries it.
    # Absent log => the verifier reports the breadcrumb as NOT asserted rather than passing.
    # `|| true` is REQUIRED under `set -euo pipefail`: portless logs (exeris-community writes
    # /tmp/exeris-community.log, no port) make the glob match nothing, `ls` exit non-zero, and
    # pipefail+errexit would then silently abort the whole run BEFORE the verifier — which is
    # exactly what turning this assertion on by default (f0e82ec) did to every exeris-community
    # pair. An absent log must yield an empty _tv_log, per the line above, not kill the leaf.
    _tv_log="$(ls -1t /tmp/exeris-*"${_tv_port}"*.log 2>/dev/null | head -1 || true)"
    if ! bash "$LAUNCH_VERIFIER" "$_tv_id" "$_tv_port" "$_tv_log"; then
      echo "ERROR: launch verification failed for ${_tv_id} — refusing to measure an unidentified artifact." >&2
      exit 1
    fi
  done
else
  echo "WARN: ${LAUNCH_VERIFIER} not found; artifact identity NOT asserted for this run." >&2
fi

echo -e "  ${GREEN}✓${NC} Stage 4 complete."

# ============================================================
# STAGE 5: Sequential measurement
# ============================================================
banner "STAGE 5: Sequential Measurement"

# NOTE: This stage is intentionally sequential so operators can switch between
# target-a and target-b processes between measurements when running externally.

# Prefer a live git rev-parse; fall back to .synced-commit-sha (written by
# tools/cloud/do/sync-repo.sh, since `git archive` ships no .git to a remote box);
# finally an explicit BENCH_COMMIT_SHA override.
BENCH_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || cat "$REPO_ROOT/.synced-commit-sha" 2>/dev/null || echo "${BENCH_COMMIT_SHA:-unknown}")"
JDK_VERSION_DETECTED="$(java -version 2>&1 | awk -F '"' '/version/ {print $2; exit}' || true)"
if [[ -z "$JDK_VERSION_DETECTED" ]]; then
  JDK_VERSION_DETECTED="unknown"
fi
WRK_VERSION_DETECTED="$(wrk --version 2>&1 | head -n 1 | tr -d '\r' || true)"
if [[ -z "$WRK_VERSION_DETECTED" ]]; then
  WRK_VERSION_DETECTED="unknown"
fi

JDK_VENDOR_DETECTED="$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.vendor =/ {print $2; exit}' || true)"
if [[ -z "$JDK_VENDOR_DETECTED" ]]; then
  JDK_VENDOR_DETECTED="unknown"
fi

HARDWARE_PROFILE_REF="${HARDWARE_PROFILE:-dev-laptop}"
# Backend container network mode (fairness gate). run-comparative.sh drives
# EXTERNALLY-launched targets + DB, so it cannot set the mode — it records what the
# operator declares via DB_HOST_NETWORK / BENCH_BACKEND_NETWORK so the comparative
# artifact is honest about it. Cross-stack comparisons MUST use host networking (a
# bridged DB taxes chattier runtimes asymmetrically); warn loudly otherwise.
if [[ "${DB_HOST_NETWORK:-0}" == "1" || "${BENCH_BACKEND_NETWORK:-}" == "host" ]]; then
  BACKEND_NETWORK_MODE="host"
else
  BACKEND_NETWORK_MODE="bridge"
  echo "WARN: comparative run with backend_network_mode=bridge. Cross-stack comparisons should launch the DB with the host-net override (DB_HOST_NETWORK=1) — bridge/NAT taxes chattier stacks asymmetrically. See docs/methodology.md." >&2
fi
JVM_CLASS="${BENCHMARK_JVM_CLASS:-jvm}"
TARGET_MODE="${BENCHMARK_TARGET_MODE:-compat}"
PAYLOAD_SIZE_BYTES="${BENCHMARK_PAYLOAD_SIZE_BYTES:-1024}"
TARGET_CLASSIFICATION="${BENCHMARK_TARGET_CLASSIFICATION:-runtime-comparative}"

PINNED_JDK_VERSION="${BENCHMARK_PINNED_JDK_VERSION:-$JDK_VERSION_DETECTED}"
PINNED_BENCH_TOOL_VERSION="${BENCHMARK_PINNED_BENCH_TOOL_VERSION:-$WRK_VERSION_DETECTED}"
PINNED_TARGET_COMMIT_SHA="${BENCHMARK_PINNED_TARGET_COMMIT_SHA:-$BENCH_COMMIT_SHA}"

DEFAULT_JVM_FLAGS_JSON='["jvm-defaults-no-explicit-launcher-flags"]'

FIRST_TARGET_JVM_FLAGS_JSON="$(derive_jvm_flags_json "$FIRST_TARGET_CONTRACT_JSON")"
SECOND_TARGET_JVM_FLAGS_JSON="$(derive_jvm_flags_json "$SECOND_TARGET_CONTRACT_JSON")"

if [[ "$FIRST_TARGET_JVM_FLAGS_JSON" == "[]" ]]; then
  FIRST_TARGET_JVM_FLAGS_JSON="$DEFAULT_JVM_FLAGS_JSON"
fi
if [[ "$SECOND_TARGET_JVM_FLAGS_JSON" == "[]" ]]; then
  SECOND_TARGET_JVM_FLAGS_JSON="$DEFAULT_JVM_FLAGS_JSON"
fi

require_non_empty_field() {
  local field_name="$1"
  local field_value="$2"
  if [[ -z "$field_value" || "$field_value" == "unknown" ]]; then
    echo "CONFIG_ERROR: required reproducibility field '${field_name}' is missing/empty" >&2
    exit 64
  fi
}

require_non_empty_field "target.commit_sha" "$BENCH_COMMIT_SHA"
require_non_empty_field "run_config.metadata.jdk_vendor" "$JDK_VENDOR_DETECTED"
require_non_empty_field "run_config.metadata.jdk_version" "$JDK_VERSION_DETECTED"
require_non_empty_field "run_config.metadata.benchmark_tool_version" "$WRK_VERSION_DETECTED"
require_non_empty_field "run_config.metadata.hardware_profile" "$HARDWARE_PROFILE_REF"
require_non_empty_field "run_config.metadata.target_classification" "$TARGET_CLASSIFICATION"

if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and (length > 0))' <<<"$FIRST_TARGET_JVM_FLAGS_JSON" >/dev/null 2>&1; then
  echo "CONFIG_ERROR: reproducibility requirement failed: unable to derive valid jvm_flags for first target" >&2
  exit 64
fi
if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and (length > 0))' <<<"$SECOND_TARGET_JVM_FLAGS_JSON" >/dev/null 2>&1; then
  echo "CONFIG_ERROR: reproducibility requirement failed: unable to derive valid jvm_flags for second target" >&2
  exit 64
fi

AB_BA_ORDERS_COMPLETED_JSON="$(printf '%s' "$AB_BA_ORDERS_COMPLETED_RAW" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF>0' | jq -Rsc 'split("\n") | map(select(length > 0) | ascii_downcase) | unique')"

# --- DB measurement-window diagnostics (BUG 1 pg_stat delta + BUG 3 DB-CPU sampler) --------
# The Postgres cpuset is discoverable via BENCH_DB_CPUSET, else docker-inspect of the
# benchmark-db container, else empty (mpstat then falls back to -P ALL). Echoes the core list.
# Set as a side effect of resolve_db_cpuset so the label reports which probe actually answered.
#
# BOTH results are returned through globals, and the function prints NOTHING. It used to print
# the cpuset and set the source as a side effect, which meant the only way to call it was
# `x="$(resolve_db_cpuset)"` — a command substitution, i.e. a SUBSHELL. The assignment to
# DB_CPUSET_SOURCE died with that subshell, so every meta file recorded source "unresolved"
# while carrying a correctly resolved cpuset (observed on the first 15 leaves of the
# 2026-08-06 ladder: resolved_cpuset "4-7,12-15", source "unresolved"). The measurement was
# fine; only its provenance was lost, which is exactly the field that says whether to trust it.
DB_CPUSET_SOURCE="unresolved"
DB_CPUSET_RESOLVED=""

resolve_db_cpuset() {
  local db_container="${DB_CONTAINER_NAME:-exeris-benchmark-db}"
  local resolved=""
  DB_CPUSET_RESOLVED=""

  if [[ -n "${BENCH_DB_CPUSET:-}" ]]; then
    DB_CPUSET_SOURCE="env:BENCH_DB_CPUSET"
    DB_CPUSET_RESOLVED="$BENCH_DB_CPUSET"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    # HostConfig.CpusetCpus is populated only when the container was started with an explicit
    # --cpuset-cpus. The compose stack does not set one, so this probe returned empty on every
    # run to date and the sampler silently fell back to -P ALL — producing an all-core mpstat
    # capture filed under the name db-cpuset-mpstat.csv. Campaign
    # 20260805T140104Z-spring-triad-n3 recorded 'all-cores-fallback' in 58 of 58 meta files,
    # i.e. it has no DB-CPU measurement at all despite carrying a well-formed artifact.
    resolved="$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$db_container" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      DB_CPUSET_SOURCE="docker-hostconfig"
      DB_CPUSET_RESOLVED="$resolved"
      return 0
    fi

    # The cgroup the container actually runs under. Answers even when no explicit cpuset was
    # requested — in that case it reports every online CPU, which is the honest answer and is
    # distinguished downstream by cpuset_is_restricted rather than by pretending to be narrower.
    resolved="$(docker exec "$db_container" cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$resolved" ]]; then
      DB_CPUSET_SOURCE="cgroup-effective"
      DB_CPUSET_RESOLVED="$resolved"
      return 0
    fi

    # Last resort: the postmaster's own allowed-CPU mask, read from the host.
    local dbpid
    dbpid="$(docker inspect -f '{{.State.Pid}}' "$db_container" 2>/dev/null || true)"
    if [[ -n "$dbpid" && "$dbpid" != "0" && -r "/proc/${dbpid}/status" ]]; then
      resolved="$(awk '/^Cpus_allowed_list:/{print $2}' "/proc/${dbpid}/status" 2>/dev/null || true)"
      if [[ -n "$resolved" ]]; then
        DB_CPUSET_SOURCE="proc-cpus-allowed"
        DB_CPUSET_RESOLVED="$resolved"
        return 0
      fi
    fi
  fi

  DB_CPUSET_SOURCE="all-cores-fallback"
  DB_CPUSET_RESOLVED=""
  return 0
}

# Records how the cpuset was resolved (for reproducibility of the DB-CPU attribution).
db_cpuset_source_label() {
  printf '%s' "${DB_CPUSET_SOURCE:-unresolved}"
}

# Whether the resolved set is actually narrower than the host's online CPUs. A resolved-but-
# unrestricted cpuset still yields no DB-CPU attribution: the sampler measures every core and
# the DB's share is not separable. Reported so a reader cannot mistake "resolved" for "usable".
db_cpuset_is_restricted() {
  local resolved="$1"
  [[ -n "$resolved" ]] || { printf 'false'; return 0; }
  local online
  online="$(cat /sys/devices/system/cpu/online 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$online" && "$resolved" == "$online" ]]; then
    printf 'false'
  else
    printf 'true'
  fi
}

# Best-effort pg_stat_statements snapshot (no reset). No-op unless the scenario wrapper loaded.
pgss_snapshot_best_effort() {
  local out_file="$1" phase="$2"
  [[ "${PGSS_WRAPPER_AVAILABLE:-0}" == "1" ]] || return 0
  pg_stat_statements_snapshot "$out_file" "$phase" >/dev/null 2>&1 || true
  return 0
}

# Emit a per-target measurement-window delta (final minus baseline), keyed by queryid, with
# diagnostic meta-queries filtered out. mean_time_ms is derived over the window; the pg_stat
# running max is carried as max_time_ms_cumulative (not window-scoped). Best-effort.
pgss_compute_delta_best_effort() {
  local baseline_file="$1" final_file="$2" out_file="$3"
  [[ -f "$baseline_file" && -f "$final_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -n --slurpfile b "$baseline_file" --slurpfile f "$final_file" '
    ($b[0].queries // []) as $bq
    | ($f[0].queries // []) as $fq
    | ($bq | map({ (.queryid): {calls: (.calls // 0), total_time_ms: (.total_time_ms // 0)} }) | add // {}) as $bmap
    | ([ $fq[]
         | select($bmap[.queryid] != null)
         | select((.calls // 0) < ($bmap[.queryid].calls // 0)) ] | length > 0) as $reset_detected
    | {
        timestamp: ($f[0].timestamp // null),
        phase: "measurement-delta",
        server_version_num: ($f[0].server_version_num // null),
        column_profile: ($f[0].column_profile // null),
        baseline_timestamp: ($b[0].timestamp // null),
        final_timestamp: ($f[0].timestamp // null),
        reset_detected: $reset_detected,
        warning: (if $reset_detected then
            "pg_stat_statements was RESET inside this measurement window (final call counts fall below baseline for at least one queryid). The delta below is NOT window-scoped and MUST NOT be used for query-shape equivalence or query-cost comparison. Without this flag the artifact is an empty-but-well-formed queries:[] and reads as a valid measurement of nothing."
          else null end),
        note: "Per-target delta over this target'"'"'s measurement window (final minus baseline). mean_time_ms is derived (total/calls) for the window; max_time_ms_cumulative is the pg_stat running max and is NOT window-scoped. Diagnostic meta-queries are filtered out.",
        queries: [
          $fq[]
          | . as $q
          | ($bmap[$q.queryid] // {calls: 0, total_time_ms: 0}) as $base
          | (($q.calls // 0) - ($base.calls // 0)) as $dcalls
          | (($q.total_time_ms // 0) - ($base.total_time_ms // 0)) as $dtotal
          | select($dcalls > 0)
          | select((($q.query // "") | test("pg_stat_statements|pg_extension|pg_settings|shared_preload_libraries|server_version_num"; "i")) | not)
          | {
              queryid: $q.queryid,
              query: $q.query,
              calls: $dcalls,
              total_time_ms: $dtotal,
              mean_time_ms: (if $dcalls > 0 then ($dtotal / $dcalls) else 0 end),
              max_time_ms_cumulative: ($q.max_time_ms // null)
            }
        ]
      }' > "$out_file" 2>/dev/null || true
  return 0
}

run_wrk_target() {
  local target_id="$1"
  local port="$2"
  local outdir="$3"
  local endpoint="$4"
  local target_contract_json="$5"
  local wrk_pid
  local wrk_rc=0
  local elapsed=0
  local endpoint_url="http://localhost:${port}${endpoint}"
  local endpoint_preflight_body="${outdir}/endpoint-preflight-body.txt"
  local endpoint_preflight_status
  local -a wrk_cmd_prefix=()
  local -a perf_stat_args=()
  local sampler_pid=""
  local detected_pid=""
  local perf_stat_enabled=0
  local perf_no_scale="${BENCHMARK_PERF_NO_SCALE:-1}"
  local perf_stat_file="${outdir}/perf-stat.csv"
  # BUG 3: fine-grained DB-CPU sampler (Postgres cpuset) bracketed to the measurement window.
  local db_cpu_mpstat_pid="" db_cpu_mpstat_csv="${outdir}/db-cpuset-mpstat.csv"
  local db_cpuset_resolved=""
  # Load generator CPU, on the same window and cadence as the DB sampler.
  #
  # This was the LAST unmeasured ceiling in the harness. A closed-loop result is only an
  # application measurement while every resource other than the application has headroom, and
  # until 2026-08-07 we sampled the measured arm, the idle neighbour and the DB cpuset — but
  # never wrk itself. The ladder run of 2026-08-06 made that gap concrete: on light the fastest
  # arm reached 74.6k rps on a 4-CPU loadgen pin, and nothing in the artefacts could confirm the
  # generator was not the thing capping it. The spread across arms (26.7k/42k/56k/74.6k) proves
  # there was no cap BELOW 74.6k, which is weaker than knowing the top arm had headroom.
  #
  # Cheap and symmetric with the DB sampler, so a leaf now carries all four consumers of the
  # host: measured arm, neighbour, database, generator.
  local loadgen_cpu_mpstat_pid="" loadgen_cpu_mpstat_csv="${outdir}/loadgen-cpuset-mpstat.csv"
  # Idle co-resident neighbour. Both targets are launched and stay resident while only one is
  # driven, but sampling covered the measured arm alone — so the cost of the idle JVM beside it
  # was never recorded. That is the missing evidence for two open findings: the heavy-10k
  # co-residence contamination, and the Spring ladder's 2.3-3.9 % between-leaf penalty that
  # appears whenever the resident neighbour is the other Exeris arm.
  local neighbour_sampler_pid="" neighbour_pid="" neighbour_port=""
  local neighbour_jfr_name="" neighbour_jfr_file="" neighbour_jfr_started=0
  local neighbour_csv="${outdir}/neighbour-resource-samples.csv"
  # BUG 1: per-target pg_stat_statements measurement-window delta artifacts.
  local pgss_baseline="${outdir}/pg_stat_statements-measurement-baseline.json"
  local pgss_final="${outdir}/pg_stat_statements-measurement-final.json"
  local pgss_delta="${outdir}/pg_stat_statements-measurement-delta.json"

  if [[ -n "$LOADGEN_CPU_AFFINITY" ]]; then
    if ! command -v taskset >/dev/null 2>&1; then
      echo "CONFIG_ERROR: LOADGEN_CPU_AFFINITY is set but 'taskset' is not available in PATH." >&2
      return 64
    fi
    wrk_cmd_prefix=(taskset -c "$LOADGEN_CPU_AFFINITY")
  fi

  if ! bench_run_endpoint_preflight "$endpoint_url" "$endpoint_preflight_body" "$ENTITY_READ_PREFLIGHT_TIMEOUT"; then
    endpoint_preflight_status="${BENCH_PREFLIGHT_HTTP_CODE:-000}"
  else
    endpoint_preflight_status="$BENCH_PREFLIGHT_HTTP_CODE"
  fi
  if [[ "$endpoint_preflight_status" != "200" ]]; then
    echo "ERROR: endpoint preflight failed for ${target_id}: ${endpoint_url} returned HTTP ${endpoint_preflight_status}. Body saved to ${endpoint_preflight_body}" >&2
    return 1
  fi

  # Detect PID and ensure JFR recording is started before warmup/measurement.
  detected_pid="$(detect_pid_for_port "$port" 2>/dev/null || true)"
  ensure_jfr_recording_started "$detected_pid" "$outdir" "$target_id" "$RUN_TS"

  echo "  Running warmup for ${target_id} (${WARMUP_SECONDS}s, latency discarded)..."
  "${wrk_cmd_prefix[@]}" wrk -t"${THREADS}" -c"${CONNECTIONS}" -d"${WARMUP_SECONDS}s" --latency \
    "$endpoint_url" > /dev/null 2>&1 &
  wrk_pid=$!
  while kill -0 "$wrk_pid" 2>/dev/null; do
    sleep 10
    elapsed=$((elapsed + 10))
    if kill -0 "$wrk_pid" 2>/dev/null; then
      echo "  Warmup still running for ${target_id} (${elapsed}s elapsed)..."
    fi
  done
  wait "$wrk_pid" || true

  # Start resource sampler before measurement when PID is available.
  if [[ -n "$detected_pid" ]]; then
    start_resource_sampler "$detected_pid" "${outdir}/resource-samples.csv" 1 &
    sampler_pid=$!
  fi

  # Sample the idle neighbour over the SAME window, so its CPU and RSS are directly comparable
  # with the measured arm's. Best-effort: absent when the pair shares a port or the neighbour is
  # not up, in which case no artifact is written rather than an empty one.
  if [[ "$port" == "$TARGET_A_PORT" ]]; then
    neighbour_port="$TARGET_B_PORT"
  elif [[ "$port" == "$TARGET_B_PORT" ]]; then
    neighbour_port="$TARGET_A_PORT"
  fi
  if [[ -n "$neighbour_port" && "$neighbour_port" != "$port" ]]; then
    neighbour_pid="$(detect_pid_for_port "$neighbour_port" 2>/dev/null || true)"
    if [[ -n "$neighbour_pid" && -d "/proc/$neighbour_pid" ]]; then
      start_resource_sampler "$neighbour_pid" "$neighbour_csv" 1 &
      neighbour_sampler_pid=$!

      # IDLE PROFILE of the co-resident target. The sampler above says HOW MUCH an idle arm
      # costs; this says WHAT it is doing. Both are needed, and only this half was missing.
      #
      # Measured on the 2026-08-06 ladder: an idle spring-on-exeris process burns 0.67-0.70 %
      # of the 4-core server pin, against 0.04-0.05 % for Tomcat and for exeris-community —
      # ~18x, split by hosting model rather than runtime family. Actuator, Micrometer, Quartz,
      # spring-integration and every management/task/jmx property were ruled out statically,
      # and thread count is flat (36.7 vs 43.9 against an 18x CPU difference), so the cause is
      # in the composition and cannot be narrowed further from counters.
      #
      # An idle process is the ideal profiling subject: with no traffic, whatever appears in
      # the profile IS the answer, because nothing else is running. That is why this is worth a
      # recording rather than more sampling.
      #
      # Per-target JFR (jfr-start.json) brackets only that target's OWN window — verified from
      # the ladder's sidecar timestamps: target-a recorded 23:13:44-23:33:47 and target-b
      # 23:33:47-23:53:51, back to back, never overlapping. So the idle arm was never recorded
      # and this data did not already exist in the campaign's ~23 GB of JFR.
      #
      # maxsize is deliberately small: the subject is idle, so the recording is tiny, and a cap
      # keeps this from adding meaningfully to a campaign whose JFR volume is already the
      # dominant artefact cost. settings=profile matches the driven recordings so the two are
      # readable with the same views.
      #
      # THE PROFILE WILL PARTLY CONTAIN JFR ITSELF, AND THAT IS HANDLED BY DESIGN.
      # On a loaded application JFR's overhead is ~1-2 % and vanishes into the background. On a
      # process burning 0.027 cores the same absolute overhead is proportionally enormous, and
      # `profile` adds its own periodic work (jdk.CPULoad every second, the sampler thread,
      # chunk rotation) which shows up in the profile AS work. Read naively, an idle profile
      # therefore reports JFR.
      #
      # The floor comes free from this very change: exeris-community (0.0020 cores) and
      # spring-hibernate (0.0015) are recorded as neighbours under IDENTICAL settings. Their
      # profiles ARE the instrument's noise floor. Anything in a spring-on-exeris idle profile
      # that is not also in theirs is signal. Do not skip the quiet arms as "nothing
      # interesting" — they are the control, and without them the noisy profile cannot be read.
      #
      # READING ORDER: park intervals BEFORE hot-methods.
      # 0.027 cores over a 20-minute window is ~32 CPU-seconds arriving as periodic wakeups.
      # ExecutionSample will catch it but smear it across many frames; a periodic wakeup is far
      # more legible in PARK DURATION, because a thread parking on a fixed interval is the
      # signature of a timer rather than of work. This lab has the precedent: the triad report
      # §7 identified Agroal pool housekeeping from "ThreadPark/JavaMonitorWait on agroal-*
      # threads with 2-minute and exactly-2000 ms timers". "Exactly 2000 ms" is what names a
      # timer; an averaged CPU figure never could. So: repeated exact park durations first (they
      # yield a thread name and a period), hot-methods second.
      if [[ "${BENCH_PROFILE_IDLE_NEIGHBOUR:-1}" == "1" ]] && command -v jcmd >/dev/null 2>&1; then
        neighbour_jfr_name="idle_neighbour_$(date -u +%Y%m%d_%H%M%S)"
        neighbour_jfr_file="${outdir}/neighbour-idle.jfr"
        if jcmd "$neighbour_pid" \
             "JFR.start name=${neighbour_jfr_name} settings=profile disk=true maxsize=64m" \
             > "${outdir}/neighbour-jfr-start.txt" 2>&1; then
          neighbour_jfr_started=1
        else
          neighbour_jfr_started=0
        fi
      fi
    fi
  fi

  # BUG 3: start a fine-grained (1s) DB-CPU sampler over the Postgres cpuset, bracketed to
  # THIS target's measurement window (after warmup, stopped right after measurement). This
  # replaces reliance on the system sar cron (10-min cadence, uselessly coarse for a
  # 120/300/900s window). Falls back to all cores when the cpuset is not discoverable.
  # No command substitution: resolve_db_cpuset returns through globals precisely so the
  # source label survives. See the note on the function.
  resolve_db_cpuset
  db_cpuset_resolved="$DB_CPUSET_RESOLVED"
  if command -v bench_start_mpstat_sampler_for_cpus >/dev/null 2>&1; then
    db_cpu_mpstat_pid="$(bench_start_mpstat_sampler_for_cpus "$db_cpu_mpstat_csv" "$db_cpuset_resolved" 1 2>/dev/null || true)"
  fi
  jq -n \
    --arg cpuset "$db_cpuset_resolved" \
    --arg source "$(db_cpuset_source_label "$db_cpuset_resolved")" \
    --arg target_id "$target_id" \
    --arg started "$([[ -n "$db_cpu_mpstat_pid" ]] && echo true || echo false)" \
    --arg restricted "$(db_cpuset_is_restricted "$db_cpuset_resolved")" \
    '{resolved_cpuset: $cpuset, source: $source, cpuset_is_restricted: ($restricted == "true"), db_cpu_attributable: ($restricted == "true"), interval_seconds: 1, window: "measurement", target_id: $target_id, sampler_started: ($started == "true")}' \
    > "${outdir}/db-cpuset-mpstat.meta.json" 2>/dev/null || true

  # Same window, same cadence, for the load generator's pin. Unlike the DB cpuset there is
  # nothing to discover: LOADGEN_CPU_AFFINITY is what this script itself passes to taskset for
  # wrk, so when it is set the attribution is exact. When it is UNSET the generator is not
  # pinned at all, its CPU cannot be separated from everything else on the host, and no sampler
  # is started — recorded honestly as loadgen_cpu_attributable:false rather than filed as an
  # all-core capture under a name that implies the generator. That mislabelling is precisely
  # what bit the DB sampler before its cpuset was resolved properly.
  if [[ -n "$LOADGEN_CPU_AFFINITY" ]] && command -v bench_start_mpstat_sampler_for_cpus >/dev/null 2>&1; then
    loadgen_cpu_mpstat_pid="$(bench_start_mpstat_sampler_for_cpus "$loadgen_cpu_mpstat_csv" "$LOADGEN_CPU_AFFINITY" 1 2>/dev/null || true)"
  fi
  jq -n \
    --arg cpuset "${LOADGEN_CPU_AFFINITY:-}" \
    --arg target_id "$target_id" \
    --arg started "$([[ -n "$loadgen_cpu_mpstat_pid" ]] && echo true || echo false)" \
    '{resolved_cpuset: $cpuset, source: (if ($cpuset | length) > 0 then "env:LOADGEN_CPU_AFFINITY" else "unpinned" end), cpuset_is_restricted: (($cpuset | length) > 0), loadgen_cpu_attributable: (($cpuset | length) > 0), interval_seconds: 1, window: "measurement", target_id: $target_id, sampler_started: ($started == "true"), note: "Load generator (wrk) CPU over the measurement window. Read it as a CEILING CHECK, not as a cost: a closed-loop throughput number is an application measurement only while the generator has headroom. If busy cores approach the pin width, the arm was generator-bound and the rps figure is a floor, not a result."}' \
    > "${outdir}/loadgen-cpuset-mpstat.meta.json" 2>/dev/null || true

  # BUG 1: pg_stat_statements baseline at measurement-start (after warmup). The matching
  # final+delta are taken at measurement-end below, both strictly inside this run-comparative
  # invocation — so the delta reflects only THIS target's measurement window and cannot be
  # clobbered by the next leaf's reset (robust for both ab and ba order).
  #
  # Being inside this invocation is necessary but not sufficient. The defect that emptied 34 of
  # 58 arm-windows in campaign 20260805T140104Z-spring-triad-n3 was the DB container's own
  # healthcheck resetting pg_stat_statements every 5 s (fixed in the compose file) — a caller
  # no ordering here could reach. The exported inhibit flag closes the remaining shell-side
  # hole: this script nests copies of itself, so a nested invocation can reach the scenario
  # diagnostics hook mid-window. Every descendant inherits the flag; it is released only after
  # the final snapshot.
  export BENCH_PGSS_RESET_INHIBIT=1
  pgss_snapshot_best_effort "$pgss_baseline" "measurement-baseline"

  if [[ "$PERF_STAT_REQUIRED" == "1" || "$PERF_STAT_CAPTURE_REQUESTED" == "1" ]]; then
    perf_stat_enabled=1
    perf_stat_args=(-x, -o "$perf_stat_file")
    if [[ "$perf_no_scale" == "1" ]]; then
      if perf stat --help 2>&1 | grep -q -- '--no-scale'; then
        perf_stat_args=(--no-scale "${perf_stat_args[@]}")
      else
        echo "WARN: perf --no-scale not supported by this perf version; running perf stat with scaling enabled"
      fi
    fi
  fi

  echo "  Running measurement for ${target_id} (${MEASUREMENT_SECONDS}s)..."
  elapsed=0
  # ------------------------------------------------------------------------------------------
  # Driver selection.
  #
  # closed (default) — wrk drives the target to saturation. That measures MAX THROUGHPUT and
  #   resource cost well, and its latency percentiles badly: with no think-time the in-flight
  #   count equals the connection count, so reported latency is queue-depth / throughput
  #   (Little's law), a property of the harness rather than the server.
  # open — wrk2 at a fixed offered rate. The only mode whose percentiles mean service time.
  #   See results/reports/2026-06-20 and the latency_percentile_eligibility gate in Stage 7.
  # ------------------------------------------------------------------------------------------
  local -a driver_cmd
  if [[ "${BENCH_DRIVER_MODE:-closed}" == "open" ]]; then
    if [[ -z "${BENCH_OFFERED_RPS:-}" ]]; then
      echo "ERROR: BENCH_DRIVER_MODE=open requires BENCH_OFFERED_RPS (the fixed arrival rate)." >&2
      return 1
    fi
    if ! command -v wrk2 >/dev/null 2>&1; then
      echo "ERROR: BENCH_DRIVER_MODE=open requires wrk2 in PATH." >&2
      return 1
    fi
    echo "  Driver: wrk2 OPEN loop, fixed offered rate ${BENCH_OFFERED_RPS} rps"
    driver_cmd=(wrk2 -t"${THREADS}" -c"${CONNECTIONS}" -d"${MEASUREMENT_SECONDS}s" \
                -R"${BENCH_OFFERED_RPS}" --latency "$endpoint_url")
  else
    driver_cmd=(wrk -t"${THREADS}" -c"${CONNECTIONS}" -d"${MEASUREMENT_SECONDS}s" --latency \
                --script "${REPO_ROOT}/runtime/drivers/wrk-p95.lua" "$endpoint_url")
  fi

  if [[ "$perf_stat_enabled" == "1" ]]; then
    echo "  Capturing perf stat for ${target_id}: ${perf_stat_file}"
    "${wrk_cmd_prefix[@]}" perf stat "${perf_stat_args[@]}" -- \
      "${driver_cmd[@]}" > "${outdir}/wrk-raw.txt" 2>&1 &
  else
    "${wrk_cmd_prefix[@]}" "${driver_cmd[@]}" > "${outdir}/wrk-raw.txt" 2>&1 &
  fi
  wrk_pid=$!
  while kill -0 "$wrk_pid" 2>/dev/null; do
    sleep 10
    elapsed=$((elapsed + 10))
    if kill -0 "$wrk_pid" 2>/dev/null; then
      echo "  Measurement still running for ${target_id} (${elapsed}s elapsed)..."
    fi
  done
  wait "$wrk_pid" || wrk_rc=$?
  
  # Stop sampler and finalize telemetry
  if [[ -n "$sampler_pid" ]]; then
    sleep 1  # Allow sampler to finish collecting
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
  fi

  if [[ -n "$neighbour_sampler_pid" ]]; then
    kill "$neighbour_sampler_pid" 2>/dev/null || true
    wait "$neighbour_sampler_pid" 2>/dev/null || true
  fi

  # Dump and stop the idle-neighbour recording, bracketed to the same window as its sampler so
  # the profile and the 0.0x-cores figure describe the same interval. Best-effort throughout:
  # the neighbour is not the measured target, so nothing here may fail a leaf.
  if [[ "${neighbour_jfr_started:-0}" == "1" && -n "$neighbour_pid" && -d "/proc/$neighbour_pid" ]]; then
    jcmd "$neighbour_pid" "JFR.dump name=${neighbour_jfr_name} filename=${neighbour_jfr_file}" \
      >> "${outdir}/neighbour-jfr-stop.txt" 2>&1 || true
    jcmd "$neighbour_pid" "JFR.stop name=${neighbour_jfr_name}" \
      >> "${outdir}/neighbour-jfr-stop.txt" 2>&1 || true
    jq -n \
      --arg measured "$target_id" \
      --arg neighbour_port "${neighbour_port:-}" \
      --arg neighbour_pid "$neighbour_pid" \
      --arg file "$neighbour_jfr_file" \
      --argjson present "$([[ -f "$neighbour_jfr_file" ]] && echo true || echo false)" \
      '{measured_target_id: $measured, neighbour_port: $neighbour_port, neighbour_pid: $neighbour_pid,
        jfr_file: $file, dumped: $present, window: "measurement", role: "resident-idle",
        note: "JFR of the co-resident target that was launched but NOT driven during this window. With no traffic on it, the profile is the whole answer to what an idle instance spends CPU on — the companion to neighbour-resource-metrics.json, which says how much rather than what. READ WITH A NOISE FLOOR: settings=profile costs the same absolute overhead on an idle process as on a busy one, and contributes its own periodic events, so an idle profile partly contains JFR. The quiet arms recorded under identical settings (exeris-community 0.0020 cores, spring-hibernate 0.0015) are that floor; anything not also present in them is signal. READING ORDER: repeated exact park durations first (a fixed interval names a timer and a thread — cf. triad report section 7, which identified Agroal housekeeping from exactly-2000 ms ThreadPark on agroal-* threads), hot-methods second, because ~32 CPU-seconds of periodic wakeups smear across frames in an execution profile."}' \
      > "${outdir}/neighbour-jfr-metadata.json" 2>/dev/null || true
  fi
  if [[ -f "$neighbour_csv" ]]; then
    summarize_resource_samples "$neighbour_csv" "${outdir}/neighbour-resource-metrics.json" "$MEASUREMENT_SECONDS"
    jq -n \
      --arg measured "$target_id" \
      --arg neighbour_port "$neighbour_port" \
      --arg neighbour_pid "$neighbour_pid" \
      '{measured_target_id: $measured, neighbour_port: $neighbour_port, neighbour_pid: $neighbour_pid, window: "measurement", role: "resident-idle", note: "Resource samples for the co-resident target that was launched but NOT driven during this window. Its CPU and RSS are the cost of co-residence, not of serving traffic."}' \
      > "${outdir}/neighbour-resource-metrics.meta.json" 2>/dev/null || true
  fi

  # BUG 3: stop the DB-CPU sampler at measurement-end (converts its raw capture to CSV).
  if [[ -n "$db_cpu_mpstat_pid" ]] && command -v bench_stop_mpstat_sampler >/dev/null 2>&1; then
    bench_stop_mpstat_sampler "$db_cpu_mpstat_pid" "$db_cpu_mpstat_csv" || true
  fi
  # Load generator sampler, stopped on the same boundary so both cover one identical window.
  if [[ -n "$loadgen_cpu_mpstat_pid" ]] && command -v bench_stop_mpstat_sampler >/dev/null 2>&1; then
    bench_stop_mpstat_sampler "$loadgen_cpu_mpstat_pid" "$loadgen_cpu_mpstat_csv" || true
  fi

  # Aggregate both mpstat streams HERE, at window close, not at campaign end.
  #
  # Both CSVs are git-ignored for size (.gitignore: results/**/db-cpuset-mpstat.csv), so the
  # committable evidence is the derived -metrics.json and nothing else. Until 2026-08-11 the
  # aggregation was a manual post-hoc step that nothing in the harness called: campaign
  # 20260810T131208Z-hibernate-vs-jdbc-n3 finished with 24 raw streams and ZERO aggregates,
  # which left its DB-ceiling reading (97.4 % under spring-jdbc vs 26.4 % under
  # spring-hibernate — the fact that decides whether heavy throughput may be quoted at all)
  # citable only from a perf-box file that disk reclaim is free to delete.
  #
  # Deriving it per window rather than per campaign also bounds the blast radius: a stream
  # that never gets aggregated costs one arm-window, not every leaf behind it.
  #
  # Best-effort by design. A missing or malformed stream must not fail a measured leaf that
  # is otherwise complete — the aggregate is evidence ABOUT the leaf, and its absence is
  # visible as a missing file plus this warning.
  if [[ -x "${REPO_ROOT}/tools/aggregate-db-cpuset-mpstat.sh" ]]; then
    for _mpstat_csv in "$db_cpu_mpstat_csv" "$loadgen_cpu_mpstat_csv"; do
      [[ -n "$_mpstat_csv" && -s "$_mpstat_csv" ]] || continue
      if ! "${REPO_ROOT}/tools/aggregate-db-cpuset-mpstat.sh" "$_mpstat_csv" >/dev/null 2>&1; then
        echo "  WARN: mpstat aggregation failed for $(basename "$_mpstat_csv") — raw stream kept, aggregate missing" >&2
      fi
    done
    unset _mpstat_csv
  else
    echo "  WARN: tools/aggregate-db-cpuset-mpstat.sh not executable — cpuset ceiling readings will be missing" >&2
  fi

  # BUG 1: pg_stat_statements final at measurement-end, then emit the per-target window delta.
  # The inhibit flag is released only after the final snapshot — a reset between the two would
  # reproduce exactly the defect it guards against.
  pgss_snapshot_best_effort "$pgss_final" "measurement-final"
  unset BENCH_PGSS_RESET_INHIBIT
  pgss_compute_delta_best_effort "$pgss_baseline" "$pgss_final" "$pgss_delta"

  if [[ -f "${outdir}/resource-samples.csv" ]]; then
    summarize_resource_samples "${outdir}/resource-samples.csv" "${outdir}/resource-metrics.json" "$MEASUREMENT_SECONDS"
  fi

  if [[ -n "$detected_pid" && -f "${outdir}/resource-metrics.json" ]]; then
    augment_resource_metrics_with_jvm_breakdown "$detected_pid" "${outdir}/resource-metrics.json"
  fi
  
  if [[ -n "$detected_pid" ]]; then
    capture_jfr_metadata "$detected_pid" "$outdir" "$target_id" "$RUN_TS"
    capture_external_runtime_log "$target_contract_json" "$target_id" "$outdir"
  else
    jq -n '{pid: "", jcmd_available: false, check_ok: false, recording_detected: false, dump_attempted: false, dump_success: false, jfr_file: "", note: "target pid not detected"}' > "${outdir}/jfr-metadata.json"
    capture_external_runtime_log "$target_contract_json" "$target_id" "$outdir"
  fi
  
  cat "${outdir}/wrk-raw.txt"
  return "$wrk_rc"
}

parse_wrk_to_result() {
  local wrk_raw="$1"
  local outfile="$2"
  local target_id="$3"
  local run_ts="$4"
  local target_contract_json="$5"
  local claim_scope="$6"
  local pair_order="$7"
  local pair_slot="$8"
  local jvm_flags_json="$9"

  local env_ref tier protocol_mode transport_mode
  local outdir resource_json jfr_json runtime_log_json jfr_start_json
  env_ref="$(jq -r '.env_file' <<<"$target_contract_json")"
  tier="$(jq -r '.tier' <<<"$target_contract_json")"
  # Prefer the EFFECTIVE protocol/transport resolved for this run (protocol-as-run-axis);
  # fall back to the target-native contract value if ever called before resolution. On the
  # real path EFFECTIVE_* is always set; for a legacy h1 pin this yields h1/loopback-h1,
  # byte-identical to the pre-refactor derivation.
  protocol_mode="${EFFECTIVE_PROTOCOL_MODE:-$(jq -r '.protocol_mode' <<<"$target_contract_json")}"
  transport_mode="${EFFECTIVE_TRANSPORT_MODE:-loopback-${protocol_mode}}"

  # Load resource metrics and JFR metadata from sidecars
  outdir="$(dirname "$outfile")"
  if [[ -f "${outdir}/resource-metrics.json" ]]; then
    resource_json="$(cat "${outdir}/resource-metrics.json")"
  else
    resource_json='{"sample_count": 0, "cpu_time_seconds": 0, "cpu_util_percent_of_one_core": 0, "avg_cores_used": 0, "host_logical_cpus": 0, "cpu_util_percent_of_host_total": 0, "vmrss_kb_min": 0, "vmrss_kb_max": 0, "vmrss_kb_avg": 0, "vmsize_kb_min": 0, "vmsize_kb_max": 0, "vmsize_kb_avg": 0, "vmhwm_kb_max": 0, "threads_min": 0, "threads_max": 0, "threads_avg": 0, "smaps_rss_kb_min": 0, "smaps_rss_kb_max": 0, "smaps_rss_kb_avg": 0, "cgroup_memory_current_kb_min": 0, "cgroup_memory_current_kb_max": 0, "cgroup_memory_current_kb_avg": 0, "rss_kb_min": 0, "rss_kb_max": 0, "rss_kb_avg": 0, "jvm_memory_breakdown": {"jcmd_available": false, "heap_used_kb": 0, "heap_committed_kb": 0, "heap_max_kb": 0, "native_total_committed_kb": 0, "native_total_reserved_kb": 0, "native_java_heap_committed_kb": 0, "offheap_kb_estimate": 0, "heap_plus_offheap_kb_estimate": 0, "offheap_estimate_source": "unavailable", "nmt_enabled": false}}'
  fi
  
  if [[ -f "${outdir}/jfr-metadata.json" ]]; then
    jfr_json="$(cat "${outdir}/jfr-metadata.json")"
  else
    jfr_json='{"pid": "", "jcmd_available": false, "check_ok": false, "recording_detected": false, "dump_attempted": false, "dump_success": false, "jfr_file": ""}'
  fi

  if [[ -f "${outdir}/runtime-log-metadata.json" ]]; then
    runtime_log_json="$(cat "${outdir}/runtime-log-metadata.json")"
  else
    runtime_log_json='{"launcher_mode": "", "env_file": "", "log_path": "", "copied": false, "output_file": "", "note": "runtime log metadata not captured"}'
  fi

  if [[ -f "${outdir}/jfr-start.json" ]]; then
    jfr_start_json="$(cat "${outdir}/jfr-start.json")"
  else
    jfr_start_json='{"pid": "", "jcmd_available": false, "start_attempted": false, "start_success": false, "recording_already_present": false, "recording_name": "", "note": "jfr start metadata not captured"}'
  fi

  # Extract key metrics from wrk output using awk
  local rps latency_mean_ms latency_stdev_ms latency_p50 latency_p75 latency_p90 latency_p99
  local total_requests total_errors
  local total_requests_sanitized total_errors_sanitized

  rps="$(grep -oP 'Requests/sec:\s+\K[\d.]+' "$wrk_raw" || echo "0")"
  latency_mean_ms="$(grep -oP '^\s+Latency\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" || echo "0us")"
  total_requests="$(grep -oP '(\d+) requests' "$wrk_raw" | head -1 | grep -oP '^\d+' || echo "0")"
  total_errors="$(grep -oP 'Non-2xx or 3xx responses:\s+\K\d+' "$wrk_raw" || echo "0")"
  # Socket errors are reported by wrk on a SEPARATE line and were previously not parsed at all.
  # total_errors above counts only non-2xx/3xx RESPONSES; a request that timed out never produced
  # a response and so was invisible — a run drowning in timeouts reported error_rate_pct 0.0000.
  # That matters most exactly where the memory sweep is heading: under a tight memory.max, timeouts
  # and dropped connections are the expected failure mode, not 503s.
  # wrk line format: "  Socket errors: connect 0, read 0, write 0, timeout 0"
  socket_err_connect="$(grep -oP 'Socket errors:.*?connect\s+\K\d+' "$wrk_raw" || echo "0")"
  socket_err_read="$(grep -oP 'Socket errors:.*?read\s+\K\d+' "$wrk_raw" || echo "0")"
  socket_err_write="$(grep -oP 'Socket errors:.*?write\s+\K\d+' "$wrk_raw" || echo "0")"
  socket_err_timeout="$(grep -oP 'Socket errors:.*?timeout\s+\K\d+' "$wrk_raw" || echo "0")"
  for _sv in socket_err_connect socket_err_read socket_err_write socket_err_timeout; do
    printf -v "$_sv" '%s' "$(printf '%s' "${!_sv}" | tr -cd '0-9')"
    [[ -n "${!_sv}" ]] || printf -v "$_sv" '%s' "0"
  done
  socket_err_total="$(( socket_err_connect + socket_err_read + socket_err_write + socket_err_timeout ))"
  total_requests_sanitized="$(printf '%s' "$total_requests" | tr -cd '0-9')"
  total_errors_sanitized="$(printf '%s' "$total_errors" | tr -cd '0-9')"
  if [[ -z "$total_requests_sanitized" ]]; then
    total_requests_sanitized="0"
  fi
  if [[ -z "$total_errors_sanitized" ]]; then
    total_errors_sanitized="0"
  fi

  # Parse latency distribution lines (Thread Stats section may include percentile table)
  # Support both "50.00%" and "50%" formats; wrk2 outputs explicit percentile columns; plain wrk may not — default to 0 for missing
  # Percentile patterns accept BOTH driver formats. Closed-loop wrk (plus wrk-p95.lua) prints
  # "50%" or "50.00%"; wrk2's HdrHistogram block prints "50.000%". Widening the optional-zeros
  # group to (?:\.0+)? covers both, so no parser branch is needed for these five.
  # head -1 matters for wrk2, whose block also carries 99.900% / 99.990% / 99.999%.
  p50="$(grep -oP '50(?:\.0+)?%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" | head -1 || echo "0us")"
  p75="$(grep -oP '75(?:\.0+)?%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" | head -1 || echo "0us")"
  p90="$(grep -oP '90(?:\.0+)?%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" | head -1 || echo "0us")"
  p99="$(grep -oP '99(?:\.0+)?%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" | head -1 || echo "0us")"
  p95="$(grep -oP '95(?:\.0+)?%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" | head -1 || echo "0us")"
  # wrk2 prints 50/75/90/99/99.9/99.99/99.999/100 in its summary block but NOT 95, so fall back
  # to the Detailed Percentile spectrum, whose Value column is bare milliseconds:
  #        6.575     0.950000       700819        20.00
  if [[ -z "$p95" || "$p95" == "0us" ]]; then
    local _p95_ms
    _p95_ms="$(grep -oP '^\s+\K[\d.]+(?=\s+0\.950000\s)' "$wrk_raw" | head -1 || true)"
    [[ -n "$_p95_ms" ]] && p95="${_p95_ms}ms"
  fi
  # p99.9 is only available from wrk2; closed-loop runs leave it at 0 and it is reported as
  # absent rather than as a measured zero.
  p999="$(grep -oP '99\.9(?:0+)?%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" | head -1 || echo "0us")"

  # Use existing repo to_us convention — inline awk conversion
  to_us() {
    local token="$1"
    if [[ -z "$token" || "$token" == "0us" ]]; then echo "0"; return; fi
    local v u
    if [[ "$token" =~ ^([0-9]*\.?[0-9]+)(us|ms|s)$ ]]; then
      v="${BASH_REMATCH[1]}"
      u="${BASH_REMATCH[2]}"
    else
      echo "0"
      return
    fi

    case "$u" in
      us) LC_ALL=C awk -v v="$v" 'BEGIN { printf "%.6f", v }' ;;
      ms) LC_ALL=C awk -v v="$v" 'BEGIN { printf "%.6f", v * 1000 }' ;;
      s) LC_ALL=C awk -v v="$v" 'BEGIN { printf "%.6f", v * 1000000 }' ;;
      *) echo "0" ;;
    esac
  }

  # Ensure values passed to jq --argjson are always valid JSON numbers.
  normalize_json_number() {
    local raw="${1:-}"
    raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
    if [[ "$raw" =~ ^[+-]?([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]; then
      echo "$raw"
    else
      echo "0"
    fi
  }

  local rps_final="${rps:-0}"
  local total_req_final="$total_requests_sanitized"
  local total_err_final="$total_errors_sanitized"
  local error_rate_pct="0"
  if [[ "$total_req_final" -gt 0 ]]; then
    error_rate_pct="$(LC_ALL=C awk -v e="$total_err_final" -v t="$total_req_final" 'BEGIN { if (t > 0) printf "%.4f", (e / t) * 100; else printf "0.0000" }')"
  fi

  # Combined failure view. error_rate_pct counts only non-2xx/3xx RESPONSES; requests that never
  # completed (timeouts, dropped connections) are absent from BOTH its numerator and wrk's
  # "N requests" denominator, so a badly failing run can report 0.0000. The denominator below adds
  # the non-completing requests back, so the rate reflects offered load rather than served load.
  # This is the figure an eligibility gate should act on.
  local failed_requests_total=$(( total_err_final + socket_err_total ))
  local failed_request_denominator=$(( total_req_final + socket_err_total ))
  local failed_request_rate_pct="0"
  if [[ "$failed_request_denominator" -gt 0 ]]; then
    failed_request_rate_pct="$(LC_ALL=C awk -v e="$failed_requests_total" -v t="$failed_request_denominator" 'BEGIN { printf "%.4f", (e / t) * 100 }')"
  fi

  # Driver provenance. Which loop produced these numbers decides whether the percentiles mean
  # service time at all, so it belongs in the artefact rather than in the operator's memory.
  # Rate attainment is the open-loop saturation signal: wrk2 that cannot sustain its offered
  # rate has hit a wall, and a throughput figure alone hides that.
  local driver_mode="${BENCH_DRIVER_MODE:-closed}"
  local offered_rps="${BENCH_OFFERED_RPS:-0}"
  local rate_attainment_pct="0"
  if [[ "$driver_mode" == "open" && "$offered_rps" != "0" ]]; then
    rate_attainment_pct="$(LC_ALL=C awk -v a="$rps_final" -v o="$offered_rps" 'BEGIN { if (o > 0) printf "%.2f", (a / o) * 100; else printf "0" }')"
  fi

  local p50_us p75_us p90_us p95_us p99_us p999_us
  p999_us="$(to_us "$p999")"
  p50_us="$(to_us "$p50")"
  p75_us="$(to_us "$p75")"
  p90_us="$(to_us "$p90")"
  p95_us="$(to_us "$p95")"
  p99_us="$(to_us "$p99")"

  local throughput_rps_json latency_p50_us_json latency_p75_us_json latency_p90_us_json latency_p95_us_json latency_p99_us_json
  local error_rate_pct_json total_requests_json total_errors_json duration_seconds_json warmup_seconds_json threads_json connections_json
  throughput_rps_json="$(normalize_json_number "$rps_final")"
  latency_p50_us_json="$(normalize_json_number "$p50_us")"
  latency_p75_us_json="$(normalize_json_number "$p75_us")"
  latency_p90_us_json="$(normalize_json_number "$p90_us")"
  latency_p95_us_json="$(normalize_json_number "$p95_us")"
  latency_p99_us_json="$(normalize_json_number "$p99_us")"
  latency_p999_us_json="$(normalize_json_number "$p999_us")"
  rate_attainment_pct_json="$(normalize_json_number "$rate_attainment_pct")"
  offered_rps_json="$(normalize_json_number "$offered_rps")"
  error_rate_pct_json="$(normalize_json_number "$error_rate_pct")"
  total_requests_json="$(normalize_json_number "$total_req_final")"
  total_errors_json="$(normalize_json_number "$total_err_final")"
  socket_err_connect_json="$(normalize_json_number "$socket_err_connect")"
  socket_err_read_json="$(normalize_json_number "$socket_err_read")"
  socket_err_write_json="$(normalize_json_number "$socket_err_write")"
  socket_err_timeout_json="$(normalize_json_number "$socket_err_timeout")"
  socket_err_total_json="$(normalize_json_number "$socket_err_total")"
  failed_requests_total_json="$(normalize_json_number "$failed_requests_total")"
  failed_request_rate_pct_json="$(normalize_json_number "$failed_request_rate_pct")"
  duration_seconds_json="$(normalize_json_number "$MEASUREMENT_SECONDS")"
  warmup_seconds_json="$(normalize_json_number "$WARMUP_SECONDS")"
  threads_json="$(normalize_json_number "$THREADS")"
  connections_json="$(normalize_json_number "$CONNECTIONS")"

  local run_id="${SCENARIO_ID}-${run_ts}-000000"

  local drift_required="${BENCHMARK_DRIFT_REQUIRED_METADATA_PRESENT:-true}"
  local drift_max_latency="${BENCHMARK_DRIFT_MAX_LATENCY_PCT:-0}"
  local drift_obs_latency="${BENCHMARK_DRIFT_OBS_LATENCY_PCT:-0}"
  local drift_max_throughput="${BENCHMARK_DRIFT_MAX_THROUGHPUT_PCT:-0}"
  local drift_obs_throughput="${BENCHMARK_DRIFT_OBS_THROUGHPUT_PCT:-0}"

  # ----------------------------------------------------------------------------------------
  # Pure-vs-Compat is a mandatory separation axis, so a target's mode must come from the
  # target's OWN registry entry. The legacy TARGET_MODE is a single variable shared by BOTH
  # targets of a pair and defaults to "compat", which (a) mislabelled every pure target and
  # (b) made the spring-hibernate (pure) vs spring-on-exeris (compat) pair — the one pair the
  # axis exists for — structurally impossible to label correctly. Keep it only as a fallback.
  # ----------------------------------------------------------------------------------------
  local resolved_target_mode="$TARGET_MODE"
  local _mode_matrix="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"
  if [[ -f "$_mode_matrix" ]]; then
    local _matrix_mode
    _matrix_mode="$(jq -r --arg id "$target_id" \
      '.targets[] | select(.target_id == $id) | .mode // empty' "$_mode_matrix" 2>/dev/null)"
    if [[ -n "$_matrix_mode" ]]; then
      resolved_target_mode="$_matrix_mode"
    else
      echo "WARN: target '${target_id}' declares no mode in target-asset-matrix.json; falling back to '${TARGET_MODE}' — the Pure-vs-Compat label for this result is NOT authoritative." >&2
    fi
  fi

  # ----------------------------------------------------------------------------------------
  # Build provenance. Every target in a campaign records the same commit_sha — the BENCHMARKS
  # repo SHA — which says nothing about which application build produced the numbers. That is
  # fatal for the serialisation matrix, whose four arms come from ONE Maven module and differ
  # only by the pinned kernel version: without per-target artefact identity the four results are
  # indistinguishable in the artefacts.
  #
  # The identity is already computed per target into the sibling runtime-log-metadata.json
  # (resolved_jar_path, jar_sha256, jar_size_bytes). Lift it into the target block, where reports
  # and comparisons actually read from. A different kernel version yields a different jar and
  # therefore a different sha256, so the arms become self-identifying without any new mechanism.
  # ----------------------------------------------------------------------------------------
  local _prov_meta="$(dirname "$outfile")/runtime-log-metadata.json"
  local target_jar_sha256="" target_jar_path=""
  if [[ -f "$_prov_meta" ]]; then
    target_jar_sha256="$(jq -r '.jar_sha256 // empty' "$_prov_meta" 2>/dev/null)"
    target_jar_path="$(jq -r '.resolved_jar_path // empty' "$_prov_meta" 2>/dev/null)"
  fi
  # Fallback for targets launched via -cp rather than -jar. The harness derives
  # runtime-log-metadata.json's jar fields by parsing `-jar <path>` out of EXTERNAL_START_CMD,
  # so any target using `-cp app.jar:customizer.jar <MainClass>` — every Blackbird arm — records
  # an empty path and empty sha. That would leave the 0.10.1-bb vs 0.10.2-bb pair with NO
  # provenance on EITHER side: precisely the contrast where telling the two builds apart in the
  # artefacts matters most. Fall back to the matrix's jar_path, which is the same authoritative
  # source the launch assertion checks the live process against.
  if [[ -z "$target_jar_sha256" ]]; then
    local _prov_matrix="${REPO_ROOT}/runtime/drivers/target-asset-matrix.json"
    local _matrix_jar=""
    if [[ -f "$_prov_matrix" ]]; then
      _matrix_jar="$(jq -r --arg id "$target_id" \
        '.targets[] | select(.target_id == $id) | .jar_path // ""' "$_prov_matrix" 2>/dev/null)"
    fi
    if [[ -n "$_matrix_jar" && -f "${REPO_ROOT}/${_matrix_jar}" ]]; then
      target_jar_path="${REPO_ROOT}/${_matrix_jar}"
      target_jar_sha256="$(sha256sum "${REPO_ROOT}/${_matrix_jar}" 2>/dev/null | awk '{print $1}')"
      echo "  Build provenance for '${target_id}' resolved from the matrix jar_path (target launches via -cp, not -jar)."
    fi
  fi
  if [[ -z "$target_jar_sha256" ]]; then
    echo "WARN: no jar_sha256 for target '${target_id}' (${_prov_meta}); this result carries NO build provenance and cannot be attributed to a specific artefact." >&2
  fi

  jq -n \
    --arg schema_version      "1" \
    --arg run_id              "$run_id" \
    --arg timestamp           "$(ts_now_utc)" \
    --arg scenario            "$SCENARIO_ID" \
    --arg tool                "wrk" \
    --arg env_ref             "$env_ref" \
    --arg transport_mode      "$transport_mode" \
    --arg tier                "$tier" \
    --arg protocol_mode       "$protocol_mode" \
    --arg target_id           "$target_id" \
    --arg contract_id         "$CONTRACT_ID" \
    --arg claim_scope         "$claim_scope" \
    --arg track_id            "$TRACK_ID" \
    --arg pair_id             "$PAIR_ID" \
    --arg pair_order          "$pair_order" \
    --arg pair_slot           "$pair_slot" \
    --arg jvm_class           "$JVM_CLASS" \
    --arg target_mode         "$resolved_target_mode" \
    --argjson payload_size_bytes "$(normalize_json_number "$PAYLOAD_SIZE_BYTES")" \
    --arg benchmark_commit_sha "$BENCH_COMMIT_SHA" \
    --arg target_jar_path     "$target_jar_path" \
    --arg target_jar_sha256   "$target_jar_sha256" \
    --arg jdk_vendor          "$JDK_VENDOR_DETECTED" \
    --arg jdk_version         "$JDK_VERSION_DETECTED" \
    --arg benchmark_tool_version "$WRK_VERSION_DETECTED" \
    --arg hardware_profile    "$HARDWARE_PROFILE_REF" \
    --arg backend_network_mode "$BACKEND_NETWORK_MODE" \
    --arg db_cpuset           "${DB_CPUSET_RESOLVED:-}" \
    --arg db_cpuset_source    "${DB_CPUSET_SOURCE:-unresolved}" \
    --arg target_classification "$TARGET_CLASSIFICATION" \
    --arg pinned_jdk_version "${PINNED_JDK_VERSION:-${JDK_VERSION_DETECTED:-unknown}}" \
    --arg pinned_tool_version "${PINNED_BENCH_TOOL_VERSION:-${WRK_VERSION_DETECTED:-unknown}}" \
    --arg pinned_target_commit_sha "${PINNED_TARGET_COMMIT_SHA:-${BENCH_COMMIT_SHA:-unknown}}" \
    --argjson jvm_flags       "$jvm_flags_json" \
    --argjson ab_ba_orders_completed "$AB_BA_ORDERS_COMPLETED_JSON" \
    --argjson drift_required_metadata_present "$drift_required" \
    --argjson drift_max_latency "$(normalize_json_number "$drift_max_latency")" \
    --argjson drift_obs_latency "$(normalize_json_number "$drift_obs_latency")" \
    --argjson drift_max_throughput "$(normalize_json_number "$drift_max_throughput")" \
    --argjson drift_obs_throughput "$(normalize_json_number "$drift_obs_throughput")" \
    --argjson target_contract "$target_contract_json" \
    --argjson throughput_rps  "$throughput_rps_json" \
    --argjson latency_p50_us  "$latency_p50_us_json" \
    --argjson latency_p75_us  "$latency_p75_us_json" \
    --argjson latency_p90_us  "$latency_p90_us_json" \
    --argjson latency_p95_us  "$latency_p95_us_json" \
    --argjson latency_p99_us  "$latency_p99_us_json" \
    --argjson error_rate_pct  "$error_rate_pct_json" \
    --argjson total_requests  "$total_requests_json" \
    --argjson total_errors    "$total_errors_json" \
    --argjson socket_err_connect "$socket_err_connect_json" \
    --argjson socket_err_read "$socket_err_read_json" \
    --argjson socket_err_write "$socket_err_write_json" \
    --argjson socket_err_timeout "$socket_err_timeout_json" \
    --argjson socket_err_total "$socket_err_total_json" \
    --argjson failed_requests_total "$failed_requests_total_json" \
    --argjson failed_request_rate_pct "$failed_request_rate_pct_json" \
    --argjson latency_p999_us "$latency_p999_us_json" \
    --arg driver_mode         "$driver_mode" \
    --argjson offered_rps     "$offered_rps_json" \
    --argjson rate_attainment_pct "$rate_attainment_pct_json" \
    --argjson duration_seconds "$duration_seconds_json" \
    --argjson warmup_seconds  "$warmup_seconds_json" \
    --argjson threads         "$threads_json" \
    --argjson connections     "$connections_json" \
    --argjson resource_metrics "$resource_json" \
    --argjson jfr_capture    "$jfr_json" \
    --argjson runtime_log    "$runtime_log_json" \
    --argjson jfr_start      "$jfr_start_json" \
  '{
    schema_version:      $schema_version,
    run_id:              $run_id,
    timestamp:           $timestamp,
    scenario:            $scenario,
    tool:                $tool,
    env_ref:             $env_ref,
    transport_mode:      $transport_mode,
    target: {
      tier:     $tier,
      repo:     $target_id,
      protocol: $protocol_mode,
      mode:     $target_mode,
      commit_sha: $benchmark_commit_sha,
      build_provenance: {
        artifact_path:   $target_jar_path,
        artifact_sha256: $target_jar_sha256
      }
    },
    run_config: {
      duration_seconds: $duration_seconds,
      warmup_seconds:   $warmup_seconds,
      threads:          $threads,
      connections:      $connections,
      contract_id:      $contract_id,
      protocol_mode:    $protocol_mode,
      transport_mode:   $transport_mode,
      track_id:         $track_id,
      pair_id:          $pair_id,
      pair_order:       $pair_order,
      ab_ba_orders_completed: $ab_ba_orders_completed,
      pair_completion_evidence: {
        invocation_order: $pair_order,
        target_slot: $pair_slot,
        completion_marker_utc: $timestamp,
        completed_orders: $ab_ba_orders_completed
      },
      jvm_class:        $jvm_class,
      mode:             $target_mode,
      driver: {
        mode:                $driver_mode,
        offered_rps:         $offered_rps,
        rate_attainment_pct: $rate_attainment_pct,
        note: "closed = wrk at saturation: throughput and resource metrics valid, percentiles are queue-depth/throughput. open = wrk2 at a fixed arrival rate: percentiles are service time."
      },
      payload_size_bytes: $payload_size_bytes,
      drift_snapshot: {
        required_metadata_present: $drift_required_metadata_present,
        max_latency_drift_pct: $drift_max_latency,
        observed_latency_drift_pct: $drift_obs_latency,
        max_throughput_drift_pct: $drift_max_throughput,
        observed_throughput_drift_pct: $drift_obs_throughput
      },
      metadata: {
        jdk_vendor: $jdk_vendor,
        jdk_version: $jdk_version,
        benchmark_tool_version: $benchmark_tool_version,
        jvm_flags: $jvm_flags,
        hardware_profile: $hardware_profile,
        backend_network_mode: $backend_network_mode,
        db_cpuset: $db_cpuset,
        db_cpuset_source: $db_cpuset_source,
        scenario_id: $scenario,
        target_classification: $target_classification
      },
      pinned_versions: {
        jdk_version: $pinned_jdk_version,
        benchmark_tool_version: $pinned_tool_version,
        target_commit_sha: $pinned_target_commit_sha
      },
      actual_versions: {
        jdk_version: $jdk_version,
        benchmark_tool_version: $benchmark_tool_version,
        target_commit_sha: $benchmark_commit_sha
      },
      target_contract:  $target_contract,
      resource_metrics: $resource_metrics,
      jfr_capture: $jfr_capture,
      runtime_log: $runtime_log,
      jfr_start: $jfr_start
    },
    metrics: {
      throughput_rps:  $throughput_rps,
      latency_p50_us:  $latency_p50_us,
      latency_p75_us:  $latency_p75_us,
      latency_p90_us:  $latency_p90_us,
      latency_p95_us:  $latency_p95_us,
      latency_p99_us:  $latency_p99_us,
      error_rate_pct:  $error_rate_pct,
      total_requests:  $total_requests,
      total_errors:    $total_errors,
      socket_errors: {
        connect: $socket_err_connect,
        read:    $socket_err_read,
        write:   $socket_err_write,
        timeout: $socket_err_timeout,
        total:   $socket_err_total
      },
      failed_requests_total:   $failed_requests_total,
      failed_request_rate_pct: $failed_request_rate_pct,
      latency_p999_us:         $latency_p999_us
    },
    claim_scope:             $claim_scope,
    runner_status:           "success",
    final_reason:            "ok",
    reproducibility_status:  "complete"
  }' > "$outfile"
}

RUN_TS="$(date -u +%Y%m%d-%H%M%S)"

if ! command -v wrk >/dev/null 2>&1; then
  echo -e "${RED}ERROR${NC}: wrk is not installed or not in PATH. Install wrk to run measurement." >&2
  exit 1
fi

MEASUREMENT_STAGE_STARTED=1

run_wrk_target "$FIRST_TARGET_ID" "$FIRST_TARGET_PORT" "${FIRST_TARGET_OUTDIR}" "$FIRST_TARGET_ENDPOINT" "$FIRST_TARGET_CONTRACT_JSON"
parse_wrk_to_result "${FIRST_TARGET_OUTDIR}/wrk-raw.txt" "${FIRST_TARGET_OUTDIR}/result.json" "$FIRST_TARGET_ID" "$RUN_TS" "$FIRST_TARGET_CONTRACT_JSON" "$FIRST_TARGET_CLAIM_SCOPE" "$PAIR_ORDER" "$FIRST_TARGET_SLOT" "$FIRST_TARGET_JVM_FLAGS_JSON"
echo -e "  ${GREEN}✓${NC} target-a measurement complete."

wait_for_target_ready "$SECOND_TARGET_ID" "$SECOND_TARGET_HEALTH_URL" "${HEALTH_TIMEOUT_SECONDS:-60}" "${OUTPUT_DIR}/logs/${SECOND_TARGET_SLOT}-ready-timestamp.txt"

run_wrk_target "$SECOND_TARGET_ID" "$SECOND_TARGET_PORT" "${SECOND_TARGET_OUTDIR}" "$SECOND_TARGET_ENDPOINT" "$SECOND_TARGET_CONTRACT_JSON"
parse_wrk_to_result "${SECOND_TARGET_OUTDIR}/wrk-raw.txt" "${SECOND_TARGET_OUTDIR}/result.json" "$SECOND_TARGET_ID" "$RUN_TS" "$SECOND_TARGET_CONTRACT_JSON" "$SECOND_TARGET_CLAIM_SCOPE" "$PAIR_ORDER" "$SECOND_TARGET_SLOT" "$SECOND_TARGET_JVM_FLAGS_JSON"
echo -e "  ${GREEN}✓${NC} target-b measurement complete."

run_post_measurement_diagnostics || true

# ============================================================
# STAGE 6: Cooldown
# ============================================================
banner "STAGE 6: Cooldown"

echo "  Sleeping 5s for target cooldown..."
sleep 5
touch "${OUTPUT_DIR}/stage6-complete.marker"
echo -e "  ${GREEN}✓${NC} stage6-complete.marker written."

# ============================================================
# STAGE 7: Post-flight validation
# ============================================================
banner "STAGE 7: Post-flight Validation"

RESULT_A_PATH="${OUTPUT_DIR}/target-a/result.json"
RESULT_B_PATH="${OUTPUT_DIR}/target-b/result.json"
GATE_SCRIPT="${REPO_ROOT}/scripts/validate-comparative-readiness.sh"
GATE_CSV="${OUTPUT_DIR}/stage7-gate-report.csv"
GATE_SUMMARY_JSON="${OUTPUT_DIR}/stage7-gate-summary.json"
REJECTION_CODES_JSON="${OUTPUT_DIR}/rejection-codes.json"
CLAIM_STATUS_JSON="${OUTPUT_DIR}/claim-status.json"

QUARANTINE_DIR="${REPO_ROOT}/quarantine"
POSTFLIGHT_OK=1

if [[ -f "$RESULT_A_PATH" && -f "$RESULT_B_PATH" && -x "$GATE_SCRIPT" ]]; then
  if ! "$GATE_SCRIPT" \
      --result-a    "$RESULT_A_PATH" \
      --result-b    "$RESULT_B_PATH" \
      --target-a-id "$TARGET_A" \
      --target-b-id "$TARGET_B" \
      --scenario-id "$SCENARIO_ID" \
      --contract-id "$CONTRACT_ID" \
      --track-id    "$TRACK_ID" \
      --summary-json "$GATE_SUMMARY_JSON" \
      --output      "$GATE_CSV"; then
    echo -e "${RED}ERROR${NC}: Post-flight gate validation failed (fail-closed)." >&2
    if [[ -f "$GATE_SUMMARY_JSON" ]]; then
      jq -c '.rejection_codes' "$GATE_SUMMARY_JSON" > "$REJECTION_CODES_JSON"
    else
      echo '[]' > "$REJECTION_CODES_JSON"
    fi
    jq -n \
      --arg claim_status "non_eligible" \
      --arg reason "postflight_gate_failure" \
      --arg track_id "$TRACK_ID" \
      --arg pair_id "$PAIR_ID" \
      --arg pair_order "$PAIR_ORDER" \
      --argjson rejection_codes "$(cat "$REJECTION_CODES_JSON")" \
      '{
        claim_status: $claim_status,
        reason: $reason,
        track_id: $track_id,
        pair_id: $pair_id,
        pair_order: $pair_order,
        rejection_codes: $rejection_codes
      }' > "$CLAIM_STATUS_JSON"
    POSTFLIGHT_OK=0
    exit 64
  else
    echo -e "  ${GREEN}✓${NC} Post-flight gate validation passed."
    echo "  Gate report: ${GATE_CSV}"

    # ------------------------------------------------------------------------------------
    # Failure-rate eligibility gate.
    #
    # A run in which a meaningful share of the offered load did not succeed is not a valid
    # basis for comparison however clean its other gates are — and the bias runs in the
    # FLATTERING direction: cheap failures (fast admission-control 503s, dropped connections)
    # cost almost no CPU and complete almost instantly, so they inflate throughput and deflate
    # latency. A target that fails 10% of requests can look faster than one that serves them.
    # Fail closed rather than leave this to interpretation.
    # ------------------------------------------------------------------------------------
    MAX_FAILED_REQUEST_RATE_PCT="${BENCH_MAX_FAILED_REQUEST_RATE_PCT:-2}"
    fr_a="$(jq -r '.metrics.failed_request_rate_pct // 0' "$RESULT_A_PATH" 2>/dev/null || echo 0)"
    fr_b="$(jq -r '.metrics.failed_request_rate_pct // 0' "$RESULT_B_PATH" 2>/dev/null || echo 0)"
    fr_exceeded="$(LC_ALL=C awk -v a="$fr_a" -v b="$fr_b" -v m="$MAX_FAILED_REQUEST_RATE_PCT" \
      'BEGIN { print ((a+0 > m+0) || (b+0 > m+0)) ? "1" : "0" }')"

    if [[ "$fr_exceeded" == "1" ]]; then
      echo -e "${RED}ERROR${NC}: failed-request rate exceeds ${MAX_FAILED_REQUEST_RATE_PCT}% (target-a=${fr_a}%, target-b=${fr_b}%) — run is NOT comparison-eligible." >&2
      echo '["FAILED_REQUEST_RATE_EXCEEDED"]' > "$REJECTION_CODES_JSON"
      jq -n \
        --arg claim_status "non_eligible" \
        --arg reason "failed_request_rate_exceeded" \
        --arg track_id "$TRACK_ID" \
        --arg pair_id "$PAIR_ID" \
        --arg pair_order "$PAIR_ORDER" \
        --argjson rejection_codes '["FAILED_REQUEST_RATE_EXCEEDED"]' \
        --arg fr_a "$fr_a" \
        --arg fr_b "$fr_b" \
        --arg threshold "$MAX_FAILED_REQUEST_RATE_PCT" \
        '{
          claim_status: $claim_status,
          reason: $reason,
          track_id: $track_id,
          pair_id: $pair_id,
          pair_order: $pair_order,
          rejection_codes: $rejection_codes,
          failed_request_rate_pct: {
            target_a: $fr_a,
            target_b: $fr_b,
            threshold_pct: $threshold
          }
        }' > "$CLAIM_STATUS_JSON"
      exit 64
    fi

    # ------------------------------------------------------------------------------------
    # Closed-loop percentile eligibility.
    #
    # A closed-loop driver at saturation does not measure latency. With no think-time the
    # in-flight count EQUALS the connection count, so reported percentiles are queue-depth
    # divided by throughput (Little's law) — a property of the harness, not the server.
    # This lab documented exactly that failure mode in results/reports/2026-06-20 (h2load
    # p50 146 ms against a real ~3 ms service time) and then walked into it anyway with wrk
    # at saturation: 128 connections / 83691 rps = 1.53 ms mean, which is what the "latency"
    # column was reporting.
    #
    # Scope restriction, NOT a run failure: throughput and resource metrics are unaffected by
    # queueing and remain valid — saturation is precisely what measures max throughput well.
    # Only the percentiles become non-publishable.
    # ------------------------------------------------------------------------------------
    CLOSED_LOOP_UTIL_LIMIT="${BENCH_CLOSED_LOOP_UTIL_LIMIT:-0.90}"
    server_cpu_count=0
    if [[ -n "${SERVER_CPU_AFFINITY:-}" ]]; then
      server_cpu_count="$(LC_ALL=C awk -v s="$SERVER_CPU_AFFINITY" 'BEGIN{
        n=0; c=split(s,parts,",");
        for(i=1;i<=c;i++){ if(parts[i]~/-/){ split(parts[i],r,"-"); n+=r[2]-r[1]+1 } else if(parts[i]!=""){ n++ } }
        print n }')"
    fi
    util_a="$(jq -r '.run_config.resource_metrics.avg_cores_used // 0' "$RESULT_A_PATH" 2>/dev/null || echo 0)"
    util_b="$(jq -r '.run_config.resource_metrics.avg_cores_used // 0' "$RESULT_B_PATH" 2>/dev/null || echo 0)"
    percentiles_publishable="true"
    percentile_reason="below_saturation_or_unknown_affinity"
    if [[ "${BENCH_DRIVER_MODE:-closed}" == "open" ]]; then
      # Open-loop percentiles measure service time however loaded the target is — that is the
      # entire point of a fixed arrival rate, and gating them on utilisation would suppress
      # exactly the measurements this mode exists to produce. What DOES invalidate them is the
      # generator failing to sustain the offered rate: the target saturated and the run
      # degenerated back into a closed loop, so the numbers are queue depth again.
      MIN_RATE_ATTAINMENT_PCT="${BENCH_MIN_RATE_ATTAINMENT_PCT:-95}"
      att_a="$(jq -r '.run_config.driver.rate_attainment_pct // 0' "$RESULT_A_PATH" 2>/dev/null || echo 0)"
      att_b="$(jq -r '.run_config.driver.rate_attainment_pct // 0' "$RESULT_B_PATH" 2>/dev/null || echo 0)"
      if [[ "$(LC_ALL=C awk -v a="$att_a" -v b="$att_b" -v m="$MIN_RATE_ATTAINMENT_PCT" \
            'BEGIN { print ((a+0 < m+0) || (b+0 < m+0)) ? "1" : "0" }')" == "1" ]]; then
        percentiles_publishable="false"
        percentile_reason="open_loop_rate_not_sustained"
        echo "  NOTE: the generator did not sustain its offered rate (target-a=${att_a}%, target-b=${att_b}%,"
        echo "        floor ${MIN_RATE_ATTAINMENT_PCT}%). The run degenerated toward a closed loop, so its"
        echo "        percentiles are queue depth again and are marked NON-PUBLISHABLE."
      else
        percentile_reason="open_loop_fixed_rate"
      fi
    elif [[ "${server_cpu_count:-0}" -gt 0 ]]; then
      if [[ "$(LC_ALL=C awk -v a="$util_a" -v b="$util_b" -v n="$server_cpu_count" -v lim="$CLOSED_LOOP_UTIL_LIMIT" \
            'BEGIN{ print ((a/n > lim) || (b/n > lim)) ? "1" : "0" }')" == "1" ]]; then
        percentiles_publishable="false"
        percentile_reason="closed_loop_driver_at_saturation"
        echo -e "  ${YELLOW:-}NOTE${NC:-}: pinned-cpuset utilisation exceeds ${CLOSED_LOOP_UTIL_LIMIT} with a closed-loop driver."
        echo "        Latency percentiles from this run are queue-depth/throughput artefacts and are marked"
        echo "        NON-PUBLISHABLE. Throughput, CPU-per-request and RSS remain valid."
      else
        percentile_reason="below_saturation"
      fi
    fi

    jq -n \
      --arg claim_status "comparison_eligible" \
      --arg reason "all_gates_passed" \
      --arg track_id "$TRACK_ID" \
      --arg pair_id "$PAIR_ID" \
      --arg pair_order "$PAIR_ORDER" \
      --argjson rejection_codes '[]' \
      --arg fr_a "$fr_a" \
      --arg fr_b "$fr_b" \
      --arg threshold "$MAX_FAILED_REQUEST_RATE_PCT" \
      --argjson percentiles_publishable "$percentiles_publishable" \
      --arg percentile_reason "$percentile_reason" \
      --arg gate_driver_mode "${BENCH_DRIVER_MODE:-closed}" \
      --arg util_a "$util_a" \
      --arg util_b "$util_b" \
      --arg server_cpus "$server_cpu_count" \
      '{
        claim_status: $claim_status,
        reason: $reason,
        track_id: $track_id,
        pair_id: $pair_id,
        pair_order: $pair_order,
        rejection_codes: $rejection_codes,
        failed_request_rate_pct: {
          target_a: $fr_a,
          target_b: $fr_b,
          threshold_pct: $threshold
        },
        latency_percentile_eligibility: {
          publishable: $percentiles_publishable,
          reason: $percentile_reason,
          driver_mode: $gate_driver_mode,
          cores_used_target_a: $util_a,
          cores_used_target_b: $util_b,
          pinned_cpus: $server_cpus,
          note: "Closed-loop percentiles at saturation are queue-depth/throughput, not service time. Throughput and resource metrics are unaffected."
        }
      }' > "$CLAIM_STATUS_JSON"

    # Strict-gate completeness (CLAUDE.md requires all 4 artifacts in a comparative output dir):
    # the comparison_eligible SUCCESS path must ALSO emit rejection-codes.json. Previously only the
    # failure branches wrote it (FAILED_REQUEST_RATE_EXCEEDED / GATE_VALIDATOR_MISSING), so every
    # PASSING comparative leaf was missing this required file. Mirror the gate summary's
    # rejection_codes (empty [] on the passing path).
    jq -c '.rejection_codes // []' "$GATE_SUMMARY_JSON" > "$REJECTION_CODES_JSON" 2>/dev/null || echo '[]' > "$REJECTION_CODES_JSON"
  fi
else
  echo -e "${RED}ERROR${NC}: Skipping post-flight gate validation is not allowed in fail-closed mode." >&2
  jq -n \
    --arg claim_status "non_eligible" \
    --arg reason "postflight_gate_not_run" \
    --arg track_id "$TRACK_ID" \
    --arg pair_id "$PAIR_ID" \
    --arg pair_order "$PAIR_ORDER" \
    --argjson rejection_codes '["GATE_VALIDATOR_MISSING"]' \
    '{
      claim_status: $claim_status,
      reason: $reason,
      track_id: $track_id,
      pair_id: $pair_id,
      pair_order: $pair_order,
      rejection_codes: $rejection_codes
    }' > "$CLAIM_STATUS_JSON"
  echo '["GATE_VALIDATOR_MISSING"]' > "$REJECTION_CODES_JSON"
  exit 64
fi

# ============================================================
# STAGE 8: Result aggregation
# ============================================================
banner "STAGE 8: Result Aggregation"

FAIRNESS_TOOL="${REPO_ROOT}/tools/compute-fairness-index.sh"
FAIRNESS_OUT="${OUTPUT_DIR}/fairness-index.json"
COMPARATIVE_OUT="${OUTPUT_DIR}/comparative-result.json"
REPORT_MD="${OUTPUT_DIR}/comparative-report.md"

# ---------------------------------------------------------------------------
# DB-config fingerprint (fairness axis on run INPUTS).
#
# Targets read their datasource from EXERIS_DB_* in the environment, and this script
# passes that environment down by inheritance — it never recorded it, so the strict
# gate was structurally blind to the DB-config axis. Every caller therefore had to
# remember to normalize the JDBC URL itself, and three separate incidents (9f2b182,
# d1032c8, and the promotion re-run) were each fixed by patching one more caller.
# Fingerprinting the inherited environment here moves the check off the callers.
#
# Password-bearing variables are excluded from both the emitted document and the
# digest: the secret is not a fairness axis.
DB_CONFIG_JSON="${OUTPUT_DIR}/db-config.json"
capture_db_config() {
  local jdbc_url query base
  jdbc_url="${EXERIS_DB_JDBC_URL:-}"
  base="${jdbc_url%%\?*}"
  query=""
  [[ "$jdbc_url" == *\?* ]] && query="${jdbc_url#*\?}"

  # Canonical env slice: every EXERIS_DB_* except secrets, sorted for a stable digest.
  local env_slice
  env_slice="$(env | grep -E '^EXERIS_DB_' | grep -viE 'password|passwd|secret' | LC_ALL=C sort || true)"
  local digest
  digest="sha256:$(printf '%s' "$env_slice" | sha256sum | cut -d' ' -f1)"

  # The pgjdbc parameters that decide fetch/prepare behaviour. Absent params are the
  # real-world failure mode, so they are reported explicitly rather than defaulted.
  local -a fairness_keys=(preferQueryMode prepareThreshold defaultRowFetchSize adaptiveFetch)
  local params_json='{}' missing_json='[]' k v
  for k in "${fairness_keys[@]}"; do
    v="$(printf '%s' "$query" | tr '&' '\n' | awk -F= -v key="$k" '$1==key {print $2; exit}')"
    if [[ -n "$v" ]]; then
      params_json="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$params_json")"
    else
      missing_json="$(jq -c --arg k "$k" '. + [$k]' <<<"$missing_json")"
    fi
  done

  local complete=true
  [[ "$(jq -r 'length' <<<"$missing_json")" != "0" ]] && complete=false

  jq -n \
    --arg     jdbc_base   "$base" \
    --arg     env_digest  "$digest" \
    --argjson params      "$params_json" \
    --argjson missing     "$missing_json" \
    --argjson complete    "$complete" \
    --arg     captured_at "$(ts_now_utc)" \
  '{
     jdbc_base_url:             $jdbc_base,
     fairness_params:           $params,
     fairness_params_missing:   $missing,
     fairness_params_complete:  $complete,
     env_digest:                $env_digest,
     captured_at:               $captured_at,
     note: "Fingerprint of the EXERIS_DB_* environment this harness passes down to both arms (secrets excluded). Both arms inherit one environment, so equality alone proves nothing — fairness_params_complete is the check that catches an un-normalized URL."
   }' > "$DB_CONFIG_JSON"
}
capture_db_config || echo -e "${YELLOW}WARN${NC}: DB-config capture failed." >&2

# Compute fairness index
if [[ -x "$FAIRNESS_TOOL" && -f "$RESULT_A_PATH" && -f "$RESULT_B_PATH" ]]; then
  "$FAIRNESS_TOOL" \
    --result-a "$RESULT_A_PATH" \
    --result-b "$RESULT_B_PATH" \
    --db-config-a "$DB_CONFIG_JSON" \
    --db-config-b "$DB_CONFIG_JSON" \
    --output   "$FAIRNESS_OUT"
  echo -e "  ${GREEN}✓${NC} Fairness index computed."
else
  echo -e "${YELLOW}WARN${NC}: compute-fairness-index.sh not available; writing empty fairness stub." >&2
  jq -n \
    --arg ts "$(ts_now_utc)" \
    --arg ta "$TARGET_A" \
    --arg tb "$TARGET_B" \
  '{
    error_symmetry: 0, latency_symmetry: 0,
    throughput_confidence: 0, composite_score: 0,
    db_config_symmetry: 0,
    db_config: { status: "unverified", a: null, b: null },
    interpretation: "unsuitable",
    computed_at: $ts,
    targets: [$ta, $tb],
    asymmetry_notes: ["fairness tool unavailable"]
  }' > "$FAIRNESS_OUT"
fi

# ---------------------------------------------------------------------------
# Fail-closed enforcement of the DB-config axis.
#
# The fairness index is computed in Stage 8, i.e. AFTER Stage 7 has already written
# claim-status.json. Recording the axis without enforcing it would reproduce the very
# failure being fixed — visible, and ignored — so a non-ok status demotes the claim
# here rather than merely annotating it.
DB_CONFIG_STATUS_EFFECTIVE="$(jq -r '.db_config.status // "unverified"' "$FAIRNESS_OUT" 2>/dev/null || echo unverified)"
if [[ "$DB_CONFIG_STATUS_EFFECTIVE" != "ok" ]]; then
  case "$DB_CONFIG_STATUS_EFFECTIVE" in
    asymmetric)               DB_REJECTION_CODE="DB_CONFIG_ASYMMETRIC" ;;
    incomplete_normalization) DB_REJECTION_CODE="DB_CONFIG_NOT_NORMALIZED" ;;
    *)                        DB_REJECTION_CODE="DB_CONFIG_UNVERIFIED" ;;
  esac
  echo -e "${RED}ERROR${NC}: DB-config fairness gate failed (status=${DB_CONFIG_STATUS_EFFECTIVE}) [rejection_code=${DB_REJECTION_CODE}]" >&2
  jq -r '.asymmetry_notes[]? | "  - " + .' "$FAIRNESS_OUT" >&2 2>/dev/null || true

  jq -c --arg c "$DB_REJECTION_CODE" '(. // []) + [$c] | unique' "$REJECTION_CODES_JSON" \
    > "${REJECTION_CODES_JSON}.tmp" 2>/dev/null \
    && mv "${REJECTION_CODES_JSON}.tmp" "$REJECTION_CODES_JSON" \
    || jq -nc --arg c "$DB_REJECTION_CODE" '[$c]' > "$REJECTION_CODES_JSON"

  if [[ -f "$CLAIM_STATUS_JSON" ]]; then
    jq --arg c "$DB_REJECTION_CODE" --arg s "$DB_CONFIG_STATUS_EFFECTIVE" \
      '.claim_status = "non_eligible"
       | .final_reason = ("db_config_" + $s)
       | .rejection_codes = (((.rejection_codes // []) + [$c]) | unique)' \
      "$CLAIM_STATUS_JSON" > "${CLAIM_STATUS_JSON}.tmp" \
      && mv "${CLAIM_STATUS_JSON}.tmp" "$CLAIM_STATUS_JSON"
  fi
  POSTFLIGHT_OK=0
fi

# Build gate_status from CSV if available
build_gate_status() {
  if [[ -f "$GATE_CSV" ]]; then
    jq -Rs '
      split("\n") |
      map(select(length > 0)) |
      .[1:] |
      map(split(",")) |
      group_by(.[1]) |
      map({
        key: (.[0][1]),
        value: {
          pass_fail: (map(select(.[3] != "PASS")) | if length > 0 then "FAIL" else "PASS" end),
          reason: (.[0][5] // ""),
          rejection_code: (.[0][4] // "none")
        }
      }) |
      from_entries |
      {
        track_isolation: (.G1 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        eligibility:     (.G2 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        equivalence:     (.G3 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        ab_ba:           (.G4 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        drift:           (.G5 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        metadata:        (.G6 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        pin_verification:(.G7 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        schema:          (.G8 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        quarantine:      (.G9 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"}),
        reporting_guard: (.G10 // {pass_fail: "FAIL", reason: "gate not run", rejection_code: "GATE_NOT_RUN"})
      }
    ' "$GATE_CSV"
  else
    jq -n '{
      track_isolation: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      eligibility: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      equivalence: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      ab_ba: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      drift: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      metadata: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      pin_verification: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      schema: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      quarantine: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"},
      reporting_guard: {pass_fail: "FAIL", reason: "post-flight gate validation not run", rejection_code: "GATE_NOT_RUN"}
    }'
  fi
}

GATE_STATUS_JSON="$(build_gate_status)"
if [[ -f "$GATE_SUMMARY_JSON" ]]; then
  REJECTION_CODES_JSON_VALUE="$(jq -c '.rejection_codes // []' "$GATE_SUMMARY_JSON")"
else
  REJECTION_CODES_JSON_VALUE='[]'
fi
CLAIM_STATUS_VALUE="comparison_eligible"
if [[ -f "$CLAIM_STATUS_JSON" ]]; then
  CLAIM_STATUS_VALUE="$(jq -r '.claim_status // "non_eligible"' "$CLAIM_STATUS_JSON")"
fi

# Assemble per-target metric summaries
build_target_entry() {
  local rfile="$1"
  local target_id="$2"

  # Load maturity/tier from pair manifest; source protocol/transport from the EFFECTIVE value
  # stamped into the result file (protocol-as-run-axis) rather than the manifest's advisory
  # h1 default — the aggregation fingerprint keys on this field, so a manifest default of h1
  # would silently blend an agnostic h2 run into h1. Fail closed rather than defaulting.
  local maturity tier protocol transport
  maturity="$(jq -r --arg t "$target_id" '.compatible_targets[] | select(.target_id==$t) | .maturity_level // "unknown"' "$PAIR_MANIFEST")"
  tier="$(jq -r --arg t "$target_id" '.compatible_targets[] | select(.target_id==$t) | .tier // "community"' "$PAIR_MANIFEST")"
  protocol="$(jq -r '.target.protocol // empty' "$rfile")"
  transport="$(jq -r '.transport_mode // empty' "$rfile")"
  if [[ -z "$protocol" || -z "$transport" ]]; then
    echo "CONFIG_ERROR: result '${rfile}' missing effective .target.protocol/.transport_mode for build_target_entry — refusing to default to h1 [rejection_code=RESULT_PROTOCOL_MISSING]" >&2
    exit 64
  fi

  jq -n \
    --arg target_id     "$target_id" \
    --arg maturity      "${maturity:-unknown}" \
    --arg tier          "${tier:-community}" \
    --arg protocol_mode "$protocol" \
    --arg transport     "$transport" \
    --slurpfile result  "$rfile" \
  '{
    target_id:      $target_id,
    maturity_level: $maturity,
    tier:           $tier,
    protocol_mode:  $protocol_mode,
    transport_mode: $transport,
    metrics: {
      throughput_rps: ($result[0].metrics.throughput_rps // 0),
      latency_p50_us: ($result[0].metrics.latency_p50_us // 0),
      latency_p75_us: ($result[0].metrics.latency_p75_us // 0),
      latency_p90_us: ($result[0].metrics.latency_p90_us // 0),
      latency_p95_us: ($result[0].metrics.latency_p95_us // 0),
      latency_p99_us: ($result[0].metrics.latency_p99_us // 0),
      error_rate_pct: ($result[0].metrics.error_rate_pct // 0),
      total_requests: ($result[0].metrics.total_requests // 0),
      total_errors:   ($result[0].metrics.total_errors // 0)
    }
  }'
}

TARGET_A_ENTRY="$(build_target_entry "$RESULT_A_PATH" "$TARGET_A")"
TARGET_B_ENTRY="$(build_target_entry "$RESULT_B_PATH" "$TARGET_B")"
FAIRNESS_JSON="$(cat "$FAIRNESS_OUT")"
AB_BA_ORDERS_COMPLETED_JSON_VALUE="$(printf '%s' "$AB_BA_ORDERS_COMPLETED_RAW" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF>0' | jq -Rsc 'split("\n") | map(select(length > 0) | ascii_downcase) | unique')"
PAIR_FINGERPRINT_JSON="$(jq -n \
  --arg scenario_id "$SCENARIO_ID" \
  --arg contract_id "$CONTRACT_ID" \
  --arg tier "$TARGET_A_TIER" \
  --arg protocol_mode "$TARGET_A_PROTOCOL_MODE" \
  --arg transport_mode "$EFFECTIVE_TRANSPORT_MODE" \
  --arg workload_profile_key "$WORKLOAD_PROFILE_KEY" \
  --arg t1 "$TARGET_A" \
  --arg t2 "$TARGET_B" \
  '{
    scenario_id: $scenario_id,
    contract_id: $contract_id,
    canonical_unordered_targets: [$t1, $t2] | sort,
    tier: $tier,
    protocol_mode: $protocol_mode,
    transport_mode: $transport_mode,
    workload_profile_key: $workload_profile_key
  }')"

jq -n \
  --arg comparative_id     "$COMPARATIVE_ID" \
  --arg timestamp_utc      "$TIMESTAMP_UTC" \
  --arg scenario_id        "$SCENARIO_ID" \
  --arg contract_id        "$CONTRACT_ID" \
  --arg track_id           "$TRACK_ID" \
  --arg pair_id            "$PAIR_ID" \
  --arg pair_order         "$PAIR_ORDER" \
  --arg claim_status       "$CLAIM_STATUS_VALUE" \
  --arg workload_profile_key "$WORKLOAD_PROFILE_KEY" \
  --argjson measurement    "$MEASUREMENT_SECONDS" \
  --argjson warmup         "$WARMUP_SECONDS" \
  --argjson target_a       "$TARGET_A_ENTRY" \
  --argjson target_b       "$TARGET_B_ENTRY" \
  --argjson pair_fingerprint "$PAIR_FINGERPRINT_JSON" \
  --argjson ab_ba_orders_completed "$AB_BA_ORDERS_COMPLETED_JSON_VALUE" \
  --argjson fairness_index "$FAIRNESS_JSON" \
  --argjson gate_status    "$GATE_STATUS_JSON" \
  --argjson eligibility_gates "$GATE_STATUS_JSON" \
  --argjson rejection_codes "$REJECTION_CODES_JSON_VALUE" \
'{
  comparative_id:     $comparative_id,
  timestamp_utc:      $timestamp_utc,
  scenario_id:        $scenario_id,
  contract_id:        $contract_id,
  track_id:           $track_id,
  pair_id:            $pair_id,
  pair_order:         $pair_order,
  workload_profile_key: $workload_profile_key,
  ab_ba_orders_completed: $ab_ba_orders_completed,
  pair_completion_evidence: {
    invocation_order: $pair_order,
    completed_orders: $ab_ba_orders_completed,
    completion_marker_utc: $timestamp_utc
  },
  pair_fingerprint:   $pair_fingerprint,
  claim_status:       $claim_status,
  measurement_seconds: $measurement,
  warmup_seconds:     $warmup,
  targets:            [$target_a, $target_b],
  fairness_index:     $fairness_index,
  gate_status:        $gate_status,
  eligibility_gates:  $eligibility_gates,
  rejection_codes:    $rejection_codes
}' > "$COMPARATIVE_OUT"

echo -e "  ${GREEN}✓${NC} comparative-result.json written: ${COMPARATIVE_OUT}"

# Generate markdown report
{
  echo "# Comparative Benchmark Report"
  echo ""
  echo "| Field               | Value                          |"
  echo "|---------------------|--------------------------------|"
  echo "| comparative_id      | ${COMPARATIVE_ID}              |"
  echo "| scenario_id         | ${SCENARIO_ID}                 |"
  echo "| contract_id         | ${CONTRACT_ID}                 |"
  echo "| track_id            | ${TRACK_ID}                    |"
  echo "| pair_id             | ${PAIR_ID}                     |"
  echo "| pair_order          | ${PAIR_ORDER}                  |"
  echo "| timestamp_utc       | ${TIMESTAMP_UTC}               |"
  echo "| measurement_seconds | ${MEASUREMENT_SECONDS}         |"
  echo "| warmup_seconds      | ${WARMUP_SECONDS}              |"
  echo ""
  echo "## Metrics"
  echo ""
  echo "| Metric              | ${TARGET_A}    | ${TARGET_B}    |"
  echo "|---------------------|----------------|----------------|"
  jq -r --argjson a "$TARGET_A_ENTRY" --argjson b "$TARGET_B_ENTRY" -n '
    "| throughput_rps      | \($a.metrics.throughput_rps) | \($b.metrics.throughput_rps) |",
    "| latency_p50_us      | \($a.metrics.latency_p50_us) | \($b.metrics.latency_p50_us) |",
    "| latency_p95_us      | \($a.metrics.latency_p95_us) | \($b.metrics.latency_p95_us) |",
    "| latency_p99_us      | \($a.metrics.latency_p99_us) | \($b.metrics.latency_p99_us) |",
    "| error_rate_pct      | \($a.metrics.error_rate_pct) | \($b.metrics.error_rate_pct) |"
  '
  echo ""
  echo "## Fairness Index"
  echo ""
  COMPOSITE="$(jq -r '.composite_score' "$FAIRNESS_OUT")"
  INTERP="$(jq -r '.interpretation' "$FAIRNESS_OUT")"
  echo "| composite_score | ${COMPOSITE} |"
  echo "| interpretation  | **${INTERP}** |"
  echo ""
  echo "> Axis labels: tier=${TARGET_A_TIER} | protocol_mode=${TARGET_A_PROTOCOL_MODE} | transport_mode=${EFFECTIVE_TRANSPORT_MODE} | benchmark_family=runtime | track_id=${TRACK_ID}"
  echo ""
  echo "_Generated by run-comparative.sh — Phase 6.3_"
} > "$REPORT_MD"

echo -e "  ${GREEN}✓${NC} comparative-report.md written: ${REPORT_MD}"

echo "  Running final reporting guard validation..."
if ! "$GATE_SCRIPT" \
    --result-a    "$RESULT_A_PATH" \
    --result-b    "$RESULT_B_PATH" \
    --target-a-id "$TARGET_A" \
    --target-b-id "$TARGET_B" \
    --scenario-id "$SCENARIO_ID" \
    --contract-id "$CONTRACT_ID" \
    --track-id    "$TRACK_ID" \
    --report-file "$REPORT_MD" \
    --summary-json "$GATE_SUMMARY_JSON" \
    --output      "$GATE_CSV"; then
  echo -e "${RED}ERROR${NC}: Reporting guard gate failed (fail-closed)." >&2
  if [[ -f "$GATE_SUMMARY_JSON" ]]; then
    jq -c '.rejection_codes // []' "$GATE_SUMMARY_JSON" > "$REJECTION_CODES_JSON"
  else
    echo '[]' > "$REJECTION_CODES_JSON"
  fi
  jq -n \
    --arg claim_status "non_eligible" \
    --arg reason "reporting_guard_failure" \
    --arg track_id "$TRACK_ID" \
    --arg pair_id "$PAIR_ID" \
    --arg pair_order "$PAIR_ORDER" \
    --argjson rejection_codes "$(cat "$REJECTION_CODES_JSON")" \
    '{
      claim_status: $claim_status,
      reason: $reason,
      track_id: $track_id,
      pair_id: $pair_id,
      pair_order: $pair_order,
      rejection_codes: $rejection_codes
    }' > "$CLAIM_STATUS_JSON"
  rm -f "$COMPARATIVE_OUT"
  exit 64
fi

echo -e "  ${GREEN}✓${NC} reporting guard gate passed."

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  COMPARATIVE RUN COMPLETE${NC}"
echo -e "${GREEN}  comparative_id : ${COMPARATIVE_ID}${NC}"
echo -e "${GREEN}  output_dir     : ${OUTPUT_DIR}${NC}"
echo -e "${GREEN}============================================================${NC}"
