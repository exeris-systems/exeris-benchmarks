#!/usr/bin/env bash
# capture-env.sh — Capture benchmark execution environment to stdout as JSON.
# Usage:
#   ./scripts/capture-env.sh > results/raw/$(date +%Y%m%d-%H%M%S)-env.json
#   ./scripts/capture-env.sh --profile perf-box-amd64 > results/raw/env.json
set -euo pipefail

PROFILE="${1:-}"
if [[ "$PROFILE" == "--profile" ]]; then
  PROFILE="${2:-dev-laptop}"
elif [[ -z "$PROFILE" ]]; then
  PROFILE="dev-laptop"
fi

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
JAVA_VENDOR="$(printf '%s\n' "$JAVA_VERSION_OUTPUT" | tail -1 | cut -d' ' -f1)"
if [[ -z "$JAVA_VENDOR" ]]; then
  JAVA_VENDOR='unknown'
fi

# JMH version (from micro/jmh if present)
JMH_VERSION="$(grep -m1 '<jmh.version>' "$(dirname "$0")/../micro/jmh/pom.xml" 2>/dev/null | grep -oP '(?<=>)[^<]+' || echo 'unknown')"

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
  --arg jdk_version "$JAVA_VERSION_STR" \
  --argjson jdk_major "$(normalize_integer_json "$JAVA_MAJOR")" \
  '{
    schema_version: $schema_version,
    captured_at: $captured_at,
    hardware_profile: $hardware_profile,
    cpu: {
      model: $cpu_model,
      physical_cores: $physical_cores,
      logical_threads: $logical_threads,
      architecture: (if $arch == "x86_64" then "x86_64" else "aarch64" end),
      cpu_governor: $cpu_governor
    },
    memory_gb: $memory_gb,
    os: { name: $os_name, version: $os_version },
    kernel: $kernel,
    jdk: {
      vendor: $jdk_vendor,
      version: $jdk_version,
      major_version: $jdk_major
    },
    jvm_flags: [],
    benchmark_tool: { name: "jmh", version: "unknown" }
  }'
