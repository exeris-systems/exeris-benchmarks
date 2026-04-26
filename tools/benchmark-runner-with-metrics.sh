#!/bin/bash
# benchmark-runner-with-metrics.sh
# Helper utility that wraps an existing benchmark command and captures
# process-level resource metrics from `/usr/bin/time -v`.
#
# This script is not the primary benchmark orchestrator/runner. It is an
# auxiliary metrics collector that preserves the benchmark output and writes
# an additional `<output_json>.with-metrics.json` artifact.
#
# Usage:
#   ./benchmark-runner-with-metrics.sh \
#       <benchmark_name> \
#       <output_json_path> \
#       <command> [args...]
#
# Example:
#   ./benchmark-runner-with-metrics.sh \
#       SslEngineTlsBenchmark \
#       results/B3-jmh-result.json \
#       mvn -f micro/jmh/pom.xml test -Dbenchmark.class=SslEngineTlsBenchmark
#
# Output: <output_json_path>.with-metrics.json (original preserved)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BENCH_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WORKSPACE_ROOT="${BENCH_WORKSPACE_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"

# ============================================================================
# FUNCTIONS
# ============================================================================

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[benchmark-runner] $*" >&2
}

detect_hardware_profile() {
    # Auto-detect hardware profile from environment or return default
    if [[ -n "${HARDWARE_PROFILE:-}" ]]; then
        echo "$HARDWARE_PROFILE"
    elif [[ -f /.dockerenv ]]; then
        echo "docker-container"
    elif [[ -n "${CI:-}" ]]; then
        echo "ci-runner"
    else
        echo "dev-laptop"
    fi
}

detect_jdk_info() {
    # Extract JDK vendor and version from java -version
    local java_version_output
    java_version_output=$(java -version 2>&1) || return 1
    
    # Extract vendor (OpenJDK, Oracle, etc.)
    if echo "$java_version_output" | grep -qi "openjdk"; then
        echo "openjdk"
    elif echo "$java_version_output" | grep -qi "oracle"; then
        echo "oracle"
    else
        echo "unknown"
    fi
}

get_jdk_version() {
    # Extract version string from java -version
    java -version 2>&1 | head -1 || echo "unknown"
}

get_commit_sha() {
    # Get current HEAD commit SHA from git
    # $1: optional git directory
    local git_dir="${1:-.}"
    git -C "$git_dir" rev-parse HEAD 2>/dev/null || echo "unknown"
}

get_jvm_flags() {
    # Extract JVM flags from running process if available
    # For now, return flags from BENCHMARK_JVM_ARGS or detect from Maven
    echo "${BENCHMARK_JVM_ARGS:-}"
}

parse_time_output() {
    # Parse /usr/bin/time -v output into JSON
    # Expected format from GNU time -v output file
    local time_output="$1"

    # Normalize locale-formatted numerics (e.g. decimal commas) to JSON-safe dot decimals.
    normalize_number() {
        local raw="$1"
        raw=$(echo "$raw" | tr ',' '.')
        raw="${raw// /}"
        raw="${raw//$'\t'/}"
        if [[ "$raw" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            echo "$raw"
        else
            echo ""
        fi
    }

    extract_value() {
        local key="$1"
        local value
        value=$(printf '%s\n' "$time_output" | LC_ALL=C awk -F: -v k="$key" '$0 ~ k { sub(/^[[:space:]]+/, "", $2); print $2; exit }')
        echo "$value"
    }

    parse_elapsed_seconds() {
        local raw
        raw=$(echo "$1" | tr ',' '.')
        raw="${raw// /}"

        if [[ "$raw" =~ ^([0-9]+):([0-9]{2}):([0-9]+([.][0-9]+)?)$ ]]; then
            local hours="${BASH_REMATCH[1]}"
            local mins="${BASH_REMATCH[2]}"
            local secs="${BASH_REMATCH[3]}"
            awk -v h="$hours" -v m="$mins" -v s="$secs" 'BEGIN { printf "%.6f", (h * 3600) + (m * 60) + s }'
            return 0
        fi

        if [[ "$raw" =~ ^([0-9]+):([0-9]+([.][0-9]+)?)$ ]]; then
            local mins="${BASH_REMATCH[1]}"
            local secs="${BASH_REMATCH[2]}"
            awk -v m="$mins" -v s="$secs" 'BEGIN { printf "%.6f", (m * 60) + s }'
            return 0
        fi

        normalize_number "$raw"
    }

    local user_sec_raw sys_sec_raw elapsed_raw max_rss_raw major_pf_raw minor_pf_raw cpu_percent_raw
    user_sec_raw=$(extract_value '^\s*User time \(seconds\)')
    sys_sec_raw=$(extract_value '^\s*System time \(seconds\)')
    elapsed_raw=$(extract_value '^\s*Elapsed \(wall clock\) time')
    max_rss_raw=$(extract_value '^\s*Maximum resident set size \(kbytes\)')
    major_pf_raw=$(extract_value '^\s*Major \(requiring I/O\) page faults')
    minor_pf_raw=$(extract_value '^\s*Minor \(reclaiming a frame\) page faults')
    cpu_percent_raw=$(extract_value '^\s*Percent of CPU this job got')

    cpu_percent_raw="${cpu_percent_raw%%%}"

    local user_sec sys_sec elapsed_sec max_rss major_pf minor_pf cpu_percent
    user_sec=$(normalize_number "$user_sec_raw")
    sys_sec=$(normalize_number "$sys_sec_raw")
    elapsed_sec=$(parse_elapsed_seconds "$elapsed_raw")
    max_rss=$(normalize_number "$max_rss_raw")
    major_pf=$(normalize_number "$major_pf_raw")
    minor_pf=$(normalize_number "$minor_pf_raw")
    cpu_percent=$(normalize_number "$cpu_percent_raw")

    # Validate mandatory fields.
    if [[ -z "$user_sec" ]] || [[ -z "$elapsed_sec" ]]; then
        return 1
    fi

    # Prefer GNU time reported CPU%; fallback to computed percentage.
    if [[ -z "$cpu_percent" ]]; then
        local total_cpu
        total_cpu=$(awk -v u="${user_sec:-0}" -v s="${sys_sec:-0}" -v e="$elapsed_sec" 'BEGIN { if (e <= 0) { print "0" } else { printf "%.6f", ((u + s) / e) * 100 } }')
        cpu_percent=$(normalize_number "$total_cpu")
    fi

    if [[ -z "$sys_sec" ]]; then
        sys_sec="0"
    fi
    if [[ -z "$max_rss" ]]; then
        max_rss="0"
    fi
    if [[ -z "$major_pf" ]]; then
        major_pf="0"
    fi
    if [[ -z "$minor_pf" ]]; then
        minor_pf="0"
    fi
    if [[ -z "$cpu_percent" ]]; then
        cpu_percent="0"
    fi

    # Max RSS is in KB, convert to MB and bytes.
    local max_rss_mb max_rss_bytes
    max_rss_mb=$(awk -v rss="$max_rss" 'BEGIN { printf "%.0f", rss / 1024 }')
    max_rss_bytes=$(awk -v rss="$max_rss" 'BEGIN { printf "%.0f", rss * 1024 }')
    
    # Output JSON object (nested)
    cat <<EOF
{
    "schema_version": "1.0",
    "source": "time",
    "collection_scope": "whole_process",
  "cpu": {
    "user_seconds": $user_sec,
    "system_seconds": $sys_sec,
    "elapsed_seconds": $elapsed_sec,
                "cpu_percent_max": $cpu_percent
  },
  "memory": {
        "max_rss_kb": $max_rss,
    "max_rss_mb": $max_rss_mb,
    "max_rss_bytes": $max_rss_bytes,
        "major_page_faults": $major_pf,
        "minor_page_faults": $minor_pf
  }
}
EOF
    return 0
}

# ============================================================================
# MAIN
# ============================================================================

BENCHMARK_NAME="${1:-}"
OUTPUT_JSON="${2:-}"
shift 2 || fail "Usage: $0 <benchmark_name> <output_json> <command> [args...] (helper for /usr/bin/time -v process metrics)"

if [[ -z "$BENCHMARK_NAME" ]]; then
    fail "benchmark_name required (e.g., SslEngineTlsBenchmark)"
fi

if [[ -z "$OUTPUT_JSON" ]]; then
    fail "output_json path required"
fi

# Remaining args are the command
COMMAND=("$@")

if (( ${#COMMAND[@]} == 0 )); then
    fail "command required"
fi

log "Benchmark: $BENCHMARK_NAME"
log "Output JSON: $OUTPUT_JSON"
log "Command: ${COMMAND[*]}"

# ============================================================================
# EXECUTE BENCHMARK WITH RESOURCE CAPTURE
# ============================================================================

# Create temp file for time output
TIME_OUTPUT=$(mktemp)
RESOURCE_METRICS_FILE=$(mktemp)
trap "rm -f '$TIME_OUTPUT' '$RESOURCE_METRICS_FILE'" EXIT

# Run command with /usr/bin/time -v wrapper
log "Executing: ${COMMAND[*]}"
BENCHMARK_EXIT_CODE=0
VOLUNTARY_CTX=0
INVOLUNTARY_CTX=0
BENCH_PID=""

LC_ALL=C /usr/bin/time -v -o "$TIME_OUTPUT" -- "${COMMAND[@]}" &
BENCH_PID=$!

# NMT baseline (optional). Requires -XX:NativeMemoryTracking=summary in the target JVM.
# NMT WARNING: Does NOT track JNI-native allocations (BoringSSL/OpenSSL via netty-tcnative).
# NMT output is JVM-heap + JVM-internal only. For TLS benchmarks, RSS from /usr/bin/time -v
# is the authoritative total process memory figure. See docs/methodology.md.
NMT_DIFF_FILE=""
if [[ "${NMT_TRACKING:-false}" == "true" ]] && [[ -n "${BENCH_PID:-}" ]]; then
    log "NMT: setting baseline for PID $BENCH_PID"
    jcmd "$BENCH_PID" VM.native_memory baseline 2>/dev/null \
        || log "WARN: NMT baseline failed — is -XX:NativeMemoryTracking=summary set?"
    NMT_DIFF_FILE="${OUTPUT_JSON}.nmt-diff.txt"
fi

# Optional pidstat context-switch monitoring
PIDSTAT_LOG_FILE=""
PIDSTAT_BG_PID=""
if [[ "${PIDSTAT_ENABLED:-false}" == "true" ]] && command -v pidstat >/dev/null 2>&1; then
    PIDSTAT_LOG_FILE="${OUTPUT_JSON}.pidstat.txt"
    pidstat -p "${BENCH_PID}" -w -t 1 > "$PIDSTAT_LOG_FILE" 2>&1 &
    PIDSTAT_BG_PID=$!
    log "pidstat started (PID $PIDSTAT_BG_PID) → $PIDSTAT_LOG_FILE"
fi

if wait "$BENCH_PID"; then
    BENCHMARK_EXIT_CODE=0
else
    BENCHMARK_EXIT_CODE=$?
fi

# NMT diff capture
if [[ "${NMT_TRACKING:-false}" == "true" ]] && [[ -n "${BENCH_PID:-}" ]] && [[ -n "$NMT_DIFF_FILE" ]]; then
    log "NMT: capturing summary.diff"
    jcmd "$BENCH_PID" VM.native_memory summary.diff > "$NMT_DIFF_FILE" 2>&1 \
        || log "WARN: NMT diff capture failed"
    log "NMT diff written to: $NMT_DIFF_FILE"
fi

# Terminate pidstat
if [[ -n "$PIDSTAT_BG_PID" ]]; then
    kill "$PIDSTAT_BG_PID" 2>/dev/null || true
    wait "$PIDSTAT_BG_PID" 2>/dev/null || true
    VOLUNTARY_CTX=0
    INVOLUNTARY_CTX=0
    if [[ -f "${PIDSTAT_LOG_FILE:-}" ]]; then
        VOLUNTARY_CTX="$(awk '/^Average:/{print $6+0; exit}' "$PIDSTAT_LOG_FILE" 2>/dev/null || echo 0)"
        INVOLUNTARY_CTX="$(awk '/^Average:/{print $7+0; exit}' "$PIDSTAT_LOG_FILE" 2>/dev/null || echo 0)"
        log "pidstat: voluntary_ctx_switches/s=$VOLUNTARY_CTX involuntary_ctx_switches/s=$INVOLUNTARY_CTX"
    fi
fi

log "Benchmark exit code: $BENCHMARK_EXIT_CODE"

# ============================================================================
# PARSE JMH RESULT
# ============================================================================

if [[ ! -f "$OUTPUT_JSON" ]]; then
    fail "JMH result file not found: $OUTPUT_JSON (exit code: $BENCHMARK_EXIT_CODE)"
fi

jq -e . "$OUTPUT_JSON" >/dev/null 2>&1 || \
    fail "Failed to parse JMH result as JSON: $OUTPUT_JSON"

# ============================================================================
# PARSE RESOURCE METRICS
# ============================================================================

TIME_CONTENT=$(cat "$TIME_OUTPUT")
cat > "$RESOURCE_METRICS_FILE" <<'EOF'
{
  "schema_version": "1.0",
  "source": "time",
  "collection_scope": "whole_process",
  "cpu": {},
  "memory": {},
  "gc": {},
  "events": {},
  "warnings": ["time output parsing failed"]
}
EOF

if parse_time_output "$TIME_CONTENT" > "$RESOURCE_METRICS_FILE" 2>/dev/null; then
    # Normalize time-based metrics to the shared resource metrics envelope.
    if ! jq '{
        schema_version: (.schema_version // "1.0"),
        source: (.source // "time"),
        collection_scope: (.collection_scope // "whole_process"),
        cpu: (.cpu // {}),
        memory: (.memory // {}),
        gc: {},
        events: {
            "time.user_seconds": (.cpu.user_seconds // 0),
            "time.system_seconds": (.cpu.system_seconds // 0),
            "time.elapsed_seconds": (.cpu.elapsed_seconds // 0)
        },
        warnings: []
    }' "$RESOURCE_METRICS_FILE" > "$RESOURCE_METRICS_FILE.tmp"; then
        rm -f "$RESOURCE_METRICS_FILE.tmp"
        log "WARNING: Failed to normalize time metrics envelope"
    else
        mv "$RESOURCE_METRICS_FILE.tmp" "$RESOURCE_METRICS_FILE"
    fi
    log "Resource metrics captured successfully"
else
    log "WARNING: Failed to parse /usr/bin/time output, metrics unavailable"
fi

# ============================================================================
# GATHER METADATA
# ============================================================================

TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
HOSTNAME=$(hostname)
HARDWARE_PROFILE=$(detect_hardware_profile)
JDK_VENDOR=$(detect_jdk_info)
JDK_VERSION=$(get_jdk_version)
JVM_FLAGS=$(get_jvm_flags)

# Detect commit SHAs
BENCH_COMMIT=$(get_commit_sha "$REPO_ROOT")
TARGET_PRIMARY_REPO="${TARGET_REPO_ROOT:-$WORKSPACE_ROOT/exeris-kernel}"
TARGET_SECONDARY_REPO="${TARGET_FALLBACK_REPO_ROOT:-$WORKSPACE_ROOT/exeris-enterprise}"
TARGET_COMMIT=$(get_commit_sha "$TARGET_PRIMARY_REPO" 2>/dev/null || \
                 get_commit_sha "$TARGET_SECONDARY_REPO" 2>/dev/null || \
                 echo "unknown")

log "Metadata: timestamp=$TIMESTAMP, hostname=$HOSTNAME, hardware=$HARDWARE_PROFILE"
log "  Bench commit: $BENCH_COMMIT"
log "  Target commit: $TARGET_COMMIT"

# ============================================================================
# BUILD OUTPUT STRUCTURE
# ============================================================================

COMMAND_STRING="${COMMAND[*]}"
OUTPUT_WITH_METRICS="${OUTPUT_JSON}.with-metrics.json"

# Use jq to build and write the merged output directly
if [[ "${NMT_TRACKING:-false}" == "true" ]]; then
    NMT_TRACKING_ENABLED_JSON=true
else
    NMT_TRACKING_ENABLED_JSON=false
fi

if [[ "${PIDSTAT_ENABLED:-false}" == "true" ]]; then
    PIDSTAT_ENABLED_JSON=true
else
    PIDSTAT_ENABLED_JSON=false
fi

if ! jq -n \
    --slurpfile jmh_results "$OUTPUT_JSON" \
    --slurpfile resource_metrics "$RESOURCE_METRICS_FILE" \
  --arg runner_version "1.0" \
  --arg benchmark_name "$BENCHMARK_NAME" \
  --arg timestamp "$TIMESTAMP" \
  --arg hostname "$HOSTNAME" \
  --arg commit_sha "$BENCH_COMMIT" \
  --arg target_commit_sha "$TARGET_COMMIT" \
  --arg hardware_profile "$HARDWARE_PROFILE" \
  --arg jdk_vendor "$JDK_VENDOR" \
  --arg jdk_version "$JDK_VERSION" \
  --arg jvm_flags "$JVM_FLAGS" \
  --arg command_str "$COMMAND_STRING" \
        --arg nmt_diff_file "${NMT_DIFF_FILE:-}" \
    --argjson benchmark_exit_code "$BENCHMARK_EXIT_CODE" \
        --argjson nmt_tracking_enabled "$NMT_TRACKING_ENABLED_JSON" \
        --argjson pidstat_enabled "$PIDSTAT_ENABLED_JSON" \
        --argjson cpu_voluntary_ctx_switches_per_sec "$VOLUNTARY_CTX" \
        --argjson cpu_involuntary_ctx_switches_per_sec "$INVOLUNTARY_CTX" \
  '{
    "runner_version": $runner_version,
    "benchmark_name": $benchmark_name,
    "execution_class": "exploratory",
        "nmt_tracking_enabled": $nmt_tracking_enabled,
        "nmt_diff_file": $nmt_diff_file,
        "pidstat_enabled": $pidstat_enabled,
        "cpu_voluntary_ctx_switches_per_sec": $cpu_voluntary_ctx_switches_per_sec,
        "cpu_involuntary_ctx_switches_per_sec": $cpu_involuntary_ctx_switches_per_sec,
        "jmh_results": $jmh_results[0],
        "resource_metrics": $resource_metrics[0],
    "metadata": {
      "timestamp": $timestamp,
      "hostname": $hostname,
      "commit_sha": $commit_sha,
      "target_commit_sha": $target_commit_sha,
      "hardware_profile": $hardware_profile,
      "jdk_vendor": $jdk_vendor,
      "jdk_version": $jdk_version,
      "jvm_flags": $jvm_flags,
      "measurements_scope": "whole-jvm-process",
      "jmh_scope": "steady-state measurement window only",
      "caveat": "Not suitable for regression comparison or cross-target claims. Dev-host exploratory only.",
      "command": $command_str,
      "benchmark_exit_code": $benchmark_exit_code
    }
    }' > "$OUTPUT_WITH_METRICS"; then
        fail "Failed to build merged JSON output with jq: $OUTPUT_WITH_METRICS"
fi

# ============================================================================
# WRITE OUTPUT
# ============================================================================

log "SUCCESS: Merged output written to: $OUTPUT_WITH_METRICS"
log "Original JMH result preserved at: $OUTPUT_JSON"
exit 0
