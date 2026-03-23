#!/usr/bin/env bash
# capture-env.sh — Capture benchmark execution environment to stdout as JSON.
# Usage:
#   ./scripts/capture-env.sh > results/raw/$(date +%Y%m%d-%H%M%S)-env.json
#   ./scripts/capture-env.sh --profile perf-box-amd64 > results/raw/env.json
set -euo pipefail

PROFILE="dev-laptop"
BENCH_TOOL="${BENCH_TOOL:-jmh}"

# Parse arguments
_args=("$@")
_i=0
while [[ $_i -lt ${#_args[@]} ]]; do
  case "${_args[$_i]}" in
    --profile)
      (( _i++ )) || true
      PROFILE="${_args[$_i]:-dev-laptop}"
      ;;
    --tool)
      (( _i++ )) || true
      BENCH_TOOL="${_args[$_i]:-jmh}"
      ;;
  esac
  (( _i++ )) || true
done

MALLOC_ARENA_MAX_VAL="${MALLOC_ARENA_MAX:-not_set}"

normalize_integer_json() {
  local value="${1:-}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

normalize_number_json() {
  local value="${1:-}"
  if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

extract_java_major() {
  local java_output="${1:-}"
  local first_line version_value

  first_line="$(printf '%s\n' "$java_output" | head -1)"
  version_value=""

  if [[ "$first_line" =~ version[[:space:]]+\"([^\"]+)\" ]]; then
    version_value="${BASH_REMATCH[1]}"
  elif [[ "$first_line" =~ ^openjdk[[:space:]]+([0-9][^[:space:]]*) ]]; then
    version_value="${BASH_REMATCH[1]}"
  elif [[ "$first_line" =~ ^java[[:space:]]+([0-9][^[:space:]]*) ]]; then
    version_value="${BASH_REMATCH[1]}"
  fi

  version_value="${version_value%%-*}"
  version_value="${version_value%%+*}"

  if [[ "$version_value" =~ ^1[.]([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$version_value" =~ ^([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '0\n'
  fi
}

detect_jdk_vendor() {
  local vendor_raw=""
  local vendor_norm=""

  vendor_raw=$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/^[[:space:]]*java.vendor[[:space:]]*=/ {print $2; exit}')
  if [[ -z "$vendor_raw" ]]; then
    vendor_raw=$(java -version 2>&1 | head -1)
  fi

  vendor_norm=$(echo "$vendor_raw" | tr '[:upper:]' '[:lower:]')
  case "$vendor_norm" in
    *oracle*) printf '%s\n' "oracle|$vendor_raw" ;;
    *eclipse*adoptium*|*temurin*) printf '%s\n' "temurin|$vendor_raw" ;;
    *graalvm*|*graal\ vm*|*graal*) printf '%s\n' "graalvm|$vendor_raw" ;;
    *openjdk*) printf '%s\n' "openjdk|$vendor_raw" ;;
    *) printf '%s\n' "unknown|$vendor_raw" ;;
  esac
}

ISO_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# CPU
CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
PHYSICAL_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null || echo 0)"
LOGICAL_THREADS="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 0)"
ARCH="$(uname -m)"
CPU_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'unknown')"

# Memory
MEM_GB="$(LC_ALL=C awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || \
  python3 -c "import subprocess; r=subprocess.run(['sysctl','-n','hw.memsize'],capture_output=True,text=True); print(round(int(r.stdout)/(1024**3),1))" 2>/dev/null || \
  echo 0)"

# OS / kernel
OS_NAME="$(uname -s)"
OS_VERSION="$(uname -r)"
KERNEL_RELEASE="$(uname -r)"

# JDK
JAVA_VERSION_OUTPUT="$(java -version 2>&1 || true)"
JAVA_VERSION_STR="$(printf '%s\n' "$JAVA_VERSION_OUTPUT" | head -1)"
if [[ -z "$JAVA_VERSION_STR" ]]; then
  JAVA_VERSION_STR='unknown'
fi
JAVA_MAJOR="$(extract_java_major "$JAVA_VERSION_OUTPUT")"
JDK_VENDOR_INFO="$(detect_jdk_vendor)"
JAVA_VENDOR="${JDK_VENDOR_INFO%%|*}"
JAVA_VENDOR_RAW="${JDK_VENDOR_INFO#*|}"
if [[ -z "$JAVA_VENDOR_RAW" ]]; then
  JAVA_VENDOR_RAW='unknown'
fi

# JMH version (from micro/jmh if present)
JMH_VERSION="$(grep -m1 '<jmh.version>' "$(dirname "$0")/../micro/jmh/pom.xml" 2>/dev/null | grep -oP '(?<=>)[^<]+' || echo 'unknown')"

# Tool versions
WRK_VERSION="$(wrk --version 2>&1 | head -1 || echo 'not_installed')"
WRK2_VERSION="$(wrk2 --version 2>&1 | head -1 || echo 'not_installed')"
H2LOAD_VERSION="$(h2load --version 2>&1 | head -1 || echo 'not_installed')"
K6_VERSION="$(k6 version 2>&1 | head -1 || echo 'not_installed')"

# Resolve active tool version for benchmark_tool.version
case "$BENCH_TOOL" in
  wrk)    BENCH_TOOL_VERSION="$WRK_VERSION" ;;
  wrk2)   BENCH_TOOL_VERSION="$WRK2_VERSION" ;;
  h2load) BENCH_TOOL_VERSION="$H2LOAD_VERSION" ;;
  k6)     BENCH_TOOL_VERSION="$K6_VERSION" ;;
  jmh)    BENCH_TOOL_VERSION="$JMH_VERSION" ;;
  *)      BENCH_TOOL_VERSION="unknown" ;;
esac

# JVM flags: collect from benchmark env vars used in this repo.
_jvm_flags_parts=()
for _jvmvar in BENCHMARK_JVM_ARGS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS; do
  if [[ -n "${!_jvmvar:-}" ]]; then
    _jvm_flags_parts+=("${!_jvmvar}")
  fi
done
JVM_FLAGS_COLLECTED="$(IFS=' '; printf '%s' "${_jvm_flags_parts[*]}")"

# cgroup / CPU limit context (best-effort, Linux only).
CGROUP_VERSION="unknown"
CGROUP_CPU_QUOTA="unknown"
CGROUP_CPU_PERIOD="unknown"
CGROUP_CPUSET="unknown"
CGROUP_MEM_LIMIT="unknown"
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  CGROUP_VERSION="v2"
  if [[ -f /sys/fs/cgroup/cpu.max ]]; then
    read -r _cg_quota _cg_period < /sys/fs/cgroup/cpu.max 2>/dev/null || true
    CGROUP_CPU_QUOTA="${_cg_quota:-unknown}"
    CGROUP_CPU_PERIOD="${_cg_period:-unknown}"
  fi
  CGROUP_CPUSET="$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo 'unknown')"
  CGROUP_MEM_LIMIT="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo 'unknown')"
elif [[ -d /sys/fs/cgroup/cpu ]]; then
  CGROUP_VERSION="v1"
  CGROUP_CPU_QUOTA="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo 'unknown')"
  CGROUP_CPU_PERIOD="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 'unknown')"
  CGROUP_CPUSET="$(cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null || echo 'unknown')"
  CGROUP_MEM_LIMIT="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 'unknown')"
fi

# cgroups v2 memory (container-aware RSS/WSS for Kubernetes eviction tracking)
CGROUP_V2_AVAILABLE=false
CGROUP_MEM_CURRENT_BYTES=0
CGROUP_MEM_WSS_BYTES=0
if [[ -f /sys/fs/cgroup/memory.current ]]; then
  CGROUP_V2_AVAILABLE=true
  CGROUP_MEM_CURRENT_BYTES="$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo '0')"
  # WSS = inactive_file + active_file from cgroups v2 memory.stat
  CGROUP_MEM_WSS_BYTES="$(awk \
    '/^inactive_file/{inactive=$2} /^active_file/{active=$2} END{print active+0+inactive+0}' \
    /sys/fs/cgroup/memory.stat 2>/dev/null || echo '0')"
fi

# CPU Steal Time sample (advisory — hypervisor/cloud environments only)
CPU_STEAL_PCT_SAMPLE=0
if command -v vmstat >/dev/null 2>&1; then
  CPU_STEAL_PCT_SAMPLE="$(vmstat 1 3 2>/dev/null \
    | awk 'NR>2{sum+=$17; count++} END{if(count>0) printf "%.2f", sum/count; else print 0}')"
fi

jq -n \
  --arg schema_version "1" \
  --arg captured_at "$ISO_NOW" \
  --arg hardware_profile "$PROFILE" \
  --arg cpu_model "$CPU_MODEL" \
  --argjson physical_cores "$(normalize_integer_json "$PHYSICAL_CORES")" \
  --argjson logical_threads "$(normalize_integer_json "$LOGICAL_THREADS")" \
  --arg arch "$ARCH" \
  --arg cpu_governor "$CPU_GOVERNOR" \
  --argjson memory_gb "$(normalize_number_json "$MEM_GB")" \
  --arg os_name "$OS_NAME" \
  --arg os_version "$OS_VERSION" \
  --arg kernel "$KERNEL_RELEASE" \
  --arg jdk_vendor "$JAVA_VENDOR" \
  --arg jdk_vendor_raw "$JAVA_VENDOR_RAW" \
  --arg jdk_version "$JAVA_VERSION_STR" \
  --argjson jdk_major "$(normalize_integer_json "$JAVA_MAJOR")" \
  --arg jmh_version "$JMH_VERSION" \
  --arg bench_tool "$BENCH_TOOL" \
  --arg bench_tool_version "$BENCH_TOOL_VERSION" \
  --arg wrk_version "$WRK_VERSION" \
  --arg wrk2_version "$WRK2_VERSION" \
  --arg h2load_version "$H2LOAD_VERSION" \
  --arg k6_version "$K6_VERSION" \
  --arg jvm_flags_raw "$JVM_FLAGS_COLLECTED" \
  --arg malloc_arena_max "$MALLOC_ARENA_MAX_VAL" \
  --arg cgroup_version "$CGROUP_VERSION" \
  --arg cgroup_cpu_quota "$CGROUP_CPU_QUOTA" \
  --arg cgroup_cpu_period "$CGROUP_CPU_PERIOD" \
  --arg cgroup_cpuset "$CGROUP_CPUSET" \
  --arg cgroup_mem_limit "$CGROUP_MEM_LIMIT" \
  --argjson cgroup_v2_available "$CGROUP_V2_AVAILABLE" \
  --argjson cgroup_memory_current_bytes "$(normalize_integer_json "$CGROUP_MEM_CURRENT_BYTES")" \
  --argjson cgroup_memory_wss_bytes "$(normalize_integer_json "$CGROUP_MEM_WSS_BYTES")" \
  --argjson cpu_steal_pct_sample "$(normalize_number_json "$CPU_STEAL_PCT_SAMPLE")" \
  '{
    schema_version: $schema_version,
    captured_at: $captured_at,
    hardware_profile: $hardware_profile,
    cpu: {
      model: $cpu_model,
      physical_cores: $physical_cores,
      logical_threads: $logical_threads,
      architecture: $arch,
      cpu_governor: $cpu_governor
    },
    memory_gb: $memory_gb,
    os: { name: $os_name, version: $os_version },
    kernel: $kernel,
    jdk: {
      vendor: $jdk_vendor,
      vendor_raw: $jdk_vendor_raw,
      version: $jdk_version,
      major_version: $jdk_major
    },
    jvm_flags: ($jvm_flags_raw | split(" ") | map(select(length > 0))),
    malloc_arena_max: $malloc_arena_max,
    cgroup: {
      version: $cgroup_version,
      cpu_quota_us: $cgroup_cpu_quota,
      cpu_period_us: $cgroup_cpu_period,
      cpuset: $cgroup_cpuset,
      memory_limit: $cgroup_mem_limit
    },
    cgroup_v2_available: $cgroup_v2_available,
    cgroup_memory_current_bytes: $cgroup_memory_current_bytes,
    cgroup_memory_wss_bytes: $cgroup_memory_wss_bytes,
    cpu_steal_pct_sample: $cpu_steal_pct_sample,
    cpu_steal_advisory: true,
    benchmark_tool: { name: $bench_tool, version: $bench_tool_version },
    toolchain: {
      wrk: $wrk_version,
      wrk2: $wrk2_version,
      h2load: $h2load_version,
      k6: $k6_version,
      jmh: $jmh_version
    }
  }'
