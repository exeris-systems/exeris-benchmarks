#!/usr/bin/env bash
# run-jmh-case.sh — execute a single JMH benchmark case from manifest
# 
# Usage:
#   ./tools/bench/run-jmh-case.sh \
#     --benchmark-id B6 \
#     --class FdOwnerTlsEngineLoopbackBenchmark \
#     --phase baseline \
#     --output-dir results/run-1 \
#     --manifest-file tools/matrix/manifests/primary-tls-matrix.json \
#     --env-source community \
#     [--headless]

set -u -o pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source helpers
source "$SCRIPT_DIR/lib/certs.sh"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/jmh.sh"
source "$SCRIPT_DIR/lib/status.sh"

# Defaults
BENCHMARK_ID=""
CLASS=""
PHASE=""
OUTPUT_DIR=""
MANIFEST_FILE=""
ENV_SOURCE=""
EFFECTIVE_ENV_SOURCE=""
HEADLESS=0
BENCH_TIMEOUT="${BENCH_TIMEOUT:-}"

detect_hardware_profile() {
  if [[ -n "${HARDWARE_PROFILE:-}" ]]; then
    echo "$HARDWARE_PROFILE"
  elif [[ -f "/.dockerenv" ]]; then
    echo "docker-container"
  elif [[ -n "${CI:-}" ]]; then
    echo "ci-runner"
  elif [[ "$(uname -m 2>/dev/null || echo unknown)" == "aarch64" ]]; then
    echo "aarch64-generic"
  else
    echo "linux-generic"
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
    *oracle*) echo "oracle" ;;
    *eclipse*adoptium*|*temurin*) echo "temurin" ;;
    *graalvm*|*graal\ vm*|*graal*) echo "graalvm" ;;
    *openjdk*) echo "openjdk" ;;
    *) echo "unknown" ;;
  esac
}

dedupe_jvm_args() {
  local -a input=("$@")
  local -a output=()
  declare -A seen=()
  local arg

  for arg in "${input[@]}"; do
    if [[ -z "${seen[$arg]+x}" ]]; then
      output+=("$arg")
      seen[$arg]=1
    fi
  done

  JVM_ARGS=("${output[@]}")
}

parse_duration_to_seconds() {
  local duration="$1"
  local value
  local suffix

  if [[ "$duration" =~ ^[0-9]+$ ]]; then
    echo "$duration"
    return 0
  fi

  if [[ "$duration" =~ ^([0-9]+)([smh])$ ]]; then
    value="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    case "$suffix" in
      s)
        echo "$value"
        ;;
      m)
        echo $((value * 60))
        ;;
      h)
        echo $((value * 3600))
        ;;
      *)
        return 1
        ;;
    esac
    return 0
  fi

  return 1
}

jmh_opt_value() {
  local flag="$1"
  local default_value="$2"
  local idx

  for ((idx = 0; idx < ${#JMH_OPTS[@]}; idx++)); do
    if [[ "${JMH_OPTS[$idx]}" == "$flag" ]]; then
      if (( idx + 1 < ${#JMH_OPTS[@]} )); then
        echo "${JMH_OPTS[$((idx + 1))]}"
        return 0
      fi
      break
    fi
  done

  echo "$default_value"
}

compute_default_bench_timeout() {
  local expected_case_count="$1"
  local warmup_iterations
  local measurement_iterations
  local warmup_duration_raw
  local measurement_duration_raw
  local forks
  local warmup_seconds
  local measurement_seconds
  local per_fork_seconds
  local per_case_seconds
  local total_timeout

  warmup_iterations=$(jmh_opt_value "-wi" "0")
  measurement_iterations=$(jmh_opt_value "-i" "0")
  warmup_duration_raw=$(jmh_opt_value "-w" "0s")
  measurement_duration_raw=$(jmh_opt_value "-r" "0s")
  forks=$(jmh_opt_value "-f" "1")

  if ! warmup_seconds=$(parse_duration_to_seconds "$warmup_duration_raw"); then
    echo "600"
    return 0
  fi
  if ! measurement_seconds=$(parse_duration_to_seconds "$measurement_duration_raw"); then
    echo "600"
    return 0
  fi

  if ! [[ "$expected_case_count" =~ ^[0-9]+$ && "$warmup_iterations" =~ ^[0-9]+$ && "$measurement_iterations" =~ ^[0-9]+$ && "$forks" =~ ^[0-9]+$ ]]; then
    echo "600"
    return 0
  fi

  per_fork_seconds=$((warmup_iterations * warmup_seconds + measurement_iterations * measurement_seconds))
  per_case_seconds=$((forks * per_fork_seconds))
  total_timeout=$((expected_case_count * (per_case_seconds + 15) + 120))

  if (( total_timeout <= 0 )); then
    echo "600"
    return 0
  fi

  echo "$total_timeout"
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark-id)
      BENCHMARK_ID="$2"
      shift 2
      ;;
    --class)
      CLASS="$2"
      shift 2
      ;;
    --phase)
      PHASE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --manifest-file)
      MANIFEST_FILE="$2"
      shift 2
      ;;
    --env-source)
      ENV_SOURCE="$2"
      shift 2
      ;;
    --headless)
      HEADLESS=1
      shift
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validation
if [[ -z "$BENCHMARK_ID" || -z "$CLASS" || -z "$PHASE" || -z "$OUTPUT_DIR" || -z "$MANIFEST_FILE" ]]; then
  echo "ERROR: Missing required arguments" >&2
  echo "Usage: $0 --benchmark-id B6 --class FdOwnerTlsEngineLoopbackBenchmark --phase baseline --output-dir DIR --manifest-file FILE [--env-source community] [--headless]" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "ERROR: Manifest file not found: $MANIFEST_FILE" >&2
  exit 1
fi

# Parse manifest and extract benchmark config
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to parse manifest" >&2
  exit 1
fi

BENCH_CONFIG=$(jq ".benchmarks[] | select(.id == \"$BENCHMARK_ID\")" "$MANIFEST_FILE" 2>/dev/null)
if [[ -z "$BENCH_CONFIG" ]]; then
  echo "ERROR: Benchmark $BENCHMARK_ID not found in manifest" >&2
  exit 1
fi

# Extract phase config
PHASE_CONFIG=$(echo "$BENCH_CONFIG" | jq ".phases[\"$PHASE\"]" 2>/dev/null)
if [[ -z "$PHASE_CONFIG" || "$PHASE_CONFIG" == "null" ]]; then
  echo "ERROR: Phase $PHASE not defined for benchmark $BENCHMARK_ID" >&2
  exit 1
fi

# Determine tier for metadata (contract-critical)
TIER=$(echo "$BENCH_CONFIG" | jq -r '.tier // empty' 2>/dev/null)
if [[ -z "$TIER" ]]; then
  echo "ERROR: Manifest contract drift for $BENCHMARK_ID: required field .tier is missing/empty" >&2
  exit 1
fi

# Create output directories
mkdir -p "$OUTPUT_DIR" || {
  echo "ERROR: Unable to create output directory: $OUTPUT_DIR" >&2
  exit 1
}

# Setup stem for artifact naming
STEM="$OUTPUT_DIR/${BENCHMARK_ID}_${PHASE}"

# Setup TLS certs if required
REQUIRES_CERTS=$(echo "$BENCH_CONFIG" | jq -r '.requires_certs' 2>/dev/null || echo "false")
COMM_CERT="/tmp/exeris-bench-certs/smoke-cert.pem"
COMM_KEY="/tmp/exeris-bench-certs/smoke-key.pem"

if [[ "$REQUIRES_CERTS" == "true" ]]; then
  if ! ensure_smoke_cert_key "$COMM_CERT" "$COMM_KEY"; then
    echo "ERROR: Failed to ensure TLS certificates" >&2
    exit 1
  fi
  if ! assert_cert_key_type_and_size "$COMM_KEY" "rsa" 2048; then
    echo "ERROR: TLS private key must be RSA-2048 for matrix consistency" >&2
    exit 1
  fi
fi

# Setup environment variables based on manifest sysprops_env_source
MANIFEST_ENV_SOURCE=$(echo "$BENCH_CONFIG" | jq -r '.sysprops_env_source // "community"' 2>/dev/null)
EFFECTIVE_ENV_SOURCE="$MANIFEST_ENV_SOURCE"

if [[ -n "$ENV_SOURCE" && "$ENV_SOURCE" != "$MANIFEST_ENV_SOURCE" ]]; then
  echo "WARNING: --env-source=$ENV_SOURCE differs from manifest sysprops_env_source=$MANIFEST_ENV_SOURCE; using manifest source" >&2
fi

case "$EFFECTIVE_ENV_SOURCE" in
  community|enterprise|none) ;;
  *)
    echo "ERROR: Unsupported sysprops_env_source '$EFFECTIVE_ENV_SOURCE' for benchmark $BENCHMARK_ID" >&2
    exit 1
    ;;
esac

if [[ "$EFFECTIVE_ENV_SOURCE" != "none" ]]; then
  if [[ "$EFFECTIVE_ENV_SOURCE" == "enterprise" ]]; then
    ENV_FILE="$REPO_ROOT/enterprise/env/enterprise-sysprops.env"
  else
    ENV_FILE="$REPO_ROOT/env/${EFFECTIVE_ENV_SOURCE}-sysprops.env"
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Environment file not found: $ENV_FILE" >&2
    exit 1
  fi
  # Source environment (this sets EXERIS_*_CLASS vars)
  source "$ENV_FILE"
else
  # No environment sourcing for sysprops_env_source=none (pure JDK benchmarks)
  : # No sysprops to source
fi

# Build command
LOG_FILE="${STEM}.log"
JSON_FILE="${STEM}-jmh.json"
JFR_FILE=""
METRICS_FILE=""

# Check if JFR is enabled in phase config
JFR_ENABLED=$(echo "$PHASE_CONFIG" | jq -r '.jfr_enabled' 2>/dev/null || echo "false")
if [[ "$JFR_ENABLED" == "true" ]]; then
  JFR_FILE="${STEM}.jfr"
  METRICS_FILE="${STEM}-metrics.json"
fi

# Build JVM args array from manifest
JVM_ARGS=()

# Add common JVM args
COMMON_JVM_ARGS=$(echo "$BENCH_CONFIG" | jq -r '.common_jvm_args[]' 2>/dev/null)
while IFS= read -r arg; do
  [[ -n "$arg" ]] && JVM_ARGS+=("$arg")
done <<< "$COMMON_JVM_ARGS"

# NOTE: jvm_arg_overrides in manifest are now processed below and separated into
# JVM_ARGS (JVM-only flags) vs JMH_PROFILER_OPTS (JMH profiler flags like -prof)
# This ensures -prof gc is placed AFTER JMH options, not before class name.

# Add cert properties if needed
if [[ "$REQUIRES_CERTS" == "true" ]]; then
  CERT_PROP=$(echo "$BENCH_CONFIG" | jq -r '.cert_properties.certPem' 2>/dev/null || echo "")
  KEY_PROP=$(echo "$BENCH_CONFIG" | jq -r '.cert_properties.keyPem' 2>/dev/null || echo "")
  if [[ -n "$CERT_PROP" && -n "$KEY_PROP" ]]; then
    JVM_ARGS+=("-D${CERT_PROP}=$COMM_CERT")
    JVM_ARGS+=("-D${KEY_PROP}=$COMM_KEY")
  fi
fi

# Add provider class properties from env vars only when source is explicit tier env.
if [[ "$EFFECTIVE_ENV_SOURCE" == "community" ]]; then
  JVM_ARGS+=("-Dexeris.tls.community.cryptoProviderClass=${EXERIS_COMMUNITY_CRYPTO_PROVIDER_CLASS}")
  JVM_ARGS+=("-Dexeris.tls.community.memoryProviderClass=${EXERIS_COMMUNITY_MEMORY_PROVIDER_CLASS}")
elif [[ "$EFFECTIVE_ENV_SOURCE" == "enterprise" ]]; then
  JVM_ARGS+=("-Dexeris.tls.enterprise.cryptoProviderClass=${EXERIS_ENTERPRISE_CRYPTO_PROVIDER_CLASS}")
  JVM_ARGS+=("-Dexeris.tls.enterprise.memoryProviderClass=${EXERIS_ENTERPRISE_MEMORY_PROVIDER_CLASS}")
fi

# Add headless flag if requested
if [[ "$HEADLESS" == "1" ]]; then
  JVM_ARGS+=("-Djava.awt.headless=true")
fi

# Extract JMH opts from phase config
JMH_OPTS=()
JMH_OPTS_ARRAY=$(echo "$PHASE_CONFIG" | jq -r '.jmh_opts[]' 2>/dev/null)
while IFS= read -r opt; do
  [[ -n "$opt" ]] && JMH_OPTS+=("$opt")
done <<< "$JMH_OPTS_ARRAY"

# Add JFR recording to the forked JMH JVM (not the parent harness JVM).
if [[ "$JFR_ENABLED" == "true" && -n "$JFR_FILE" ]]; then
  JMH_OPTS+=(
    "-jvmArgsAppend"
    "-XX:StartFlightRecording=filename=${JFR_FILE},settings=profile,dumponexit=true"
  )
fi

EXPECTED_CASE_COUNT=$(echo "$PHASE_CONFIG" | jq -r '.expected_case_count // 0' 2>/dev/null || echo "0")
if [[ -z "$BENCH_TIMEOUT" ]]; then
  BENCH_TIMEOUT=$(compute_default_bench_timeout "$EXPECTED_CASE_COUNT")
fi

# Extract JMH profiler overrides from phase config (these must go AFTER class name + JMH opts)
# Parse jvm_arg_overrides as a token stream so "-prof <value>" stays paired in JMH_PROFILER_OPTS.
JMH_PROFILER_OPTS=()
PHASE_OVERRIDES_RAW=$(echo "$PHASE_CONFIG" | jq -r '.jvm_arg_overrides[]' 2>/dev/null)
PHASE_OVERRIDES=()
while IFS= read -r arg; do
  [[ -n "$arg" ]] && PHASE_OVERRIDES+=("$arg")
done <<< "$PHASE_OVERRIDES_RAW"

for ((idx = 0; idx < ${#PHASE_OVERRIDES[@]}; idx++)); do
  arg="${PHASE_OVERRIDES[$idx]}"

  if [[ "$arg" == "-prof" ]]; then
    if (( idx + 1 >= ${#PHASE_OVERRIDES[@]} )); then
      echo "ERROR: Malformed jvm_arg_overrides for benchmark $BENCHMARK_ID phase $PHASE: '-prof' requires a profiler value" >&2
      exit 1
    fi
    JMH_PROFILER_OPTS+=("$arg" "${PHASE_OVERRIDES[$((idx + 1))]}")
    ((idx++))
  elif [[ "$arg" =~ ^-prof ]]; then
    JMH_PROFILER_OPTS+=("$arg")
  else
    # Other overrides stay in JVM_ARGS
    JVM_ARGS+=("$arg")
  fi
done

# Final deduplication — must stay here, AFTER all JVM_ARGS sources have been merged:
# common_jvm_args, cert -D props, provider -D props, headless, JFR recording, and
# jvm_arg_overrides (non-profiler). Moving this before any of those additions would
# silently re-introduce duplicate flags in the fork's VM options.
dedupe_jvm_args "${JVM_ARGS[@]}"

# Construct full command  
# CP is expected to be set by caller or from environment
if [[ -z "${CP:-}" ]]; then
  # Fall back to finding benchmarks.jar in micro/jmh/target
  if [[ -f "$REPO_ROOT/micro/jmh/target/benchmarks.jar" ]]; then
    CP="$REPO_ROOT/micro/jmh/target/benchmarks.jar"
  else
    echo "ERROR: Unable to find benchmarks.jar or CP not set" >&2
    exit 1
  fi
fi

# Build the full command
CMD=(
  "java"
)

# Add JVM args directly to the java invocation
for jvm_arg in "${JVM_ARGS[@]}"; do
  CMD+=("$jvm_arg")
done

CMD+=(
  "-cp" "$CP"
)

# Add JMH main and benchmark class
CMD+=(
  "org.openjdk.jmh.Main"
  "$CLASS"
)

# Add JMH options
CMD+=("${JMH_OPTS[@]}")

# Add output options
CMD+=(
  "-rf" "json"
  "-rff" "$JSON_FILE"
)

# Add JMH profiler options at the very end (CRITICAL: -prof must come after all JMH opts)
CMD+=("${JMH_PROFILER_OPTS[@]}")

# Write command and JVM args artifacts for reproducibility
CMD_FILE="${STEM}.cmd"
JVM_ARGS_FILE="${STEM}.jvm-args.txt"
write_cmd_artifacts "$CMD_FILE" "$JVM_ARGS_FILE" "${CMD[@]}"

# Print execution info
echo ""
echo "=========================================================================="
echo "BENCHMARK RUN"
echo "=========================================================================="
echo "ID                : $BENCHMARK_ID"
echo "CLASS             : $CLASS"
echo "TIER              : $TIER"
echo "PHASE             : $PHASE"
echo "ENV_SOURCE        : $EFFECTIVE_ENV_SOURCE"
echo "HEADLESS          : $HEADLESS"
echo "BENCH_TIMEOUT(s)  : $BENCH_TIMEOUT"
echo "CLASSPATH         : $CP"
echo "Output directory  : $OUTPUT_DIR"
echo "Log file          : $LOG_FILE"
echo "JSON file         : $JSON_FILE"
if [[ -n "$JFR_FILE" ]]; then
  echo "JFR file          : $JFR_FILE"
fi
echo "=========================================================================="
echo ""

# Execute benchmark
if ! [[ "$BENCH_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$BENCH_TIMEOUT" -le 0 ]]; then
  echo "ERROR: BENCH_TIMEOUT must be a positive integer, got '$BENCH_TIMEOUT'" >&2
  exit 1
fi

if command -v timeout >/dev/null 2>&1; then
  timeout --signal=TERM --kill-after=30s "${BENCH_TIMEOUT:-600}" "${CMD[@]}" 2>&1 | tee "$LOG_FILE"
  BENCH_RC=${PIPESTATUS[0]}
  if [[ $BENCH_RC -eq 124 ]]; then
    echo "WARNING: Benchmark timed out after ${BENCH_TIMEOUT}s" >&2
  fi
else
  echo "WARNING: 'timeout' command not found; running benchmark without timeout wrapper" >&2
  "${CMD[@]}" 2>&1 | tee "$LOG_FILE"
  BENCH_RC=${PIPESTATUS[0]}
fi

# Run postprocessing if needed
POSTPROCESS_RC=0
if [[ $BENCH_RC -eq 0 && -n "$JFR_FILE" && -f "$JFR_FILE" && -n "$METRICS_FILE" ]]; then
  if [[ -x "$REPO_ROOT/tools/extract-jfr-metrics.sh" ]]; then
    "$REPO_ROOT/tools/extract-jfr-metrics.sh" "$JFR_FILE" "$METRICS_FILE"
    POSTPROCESS_RC=$?
  fi
fi

# Extract metadata for reproducibility contract (must occur before classify_bench_status)
JDK_VERSION=$(java -version 2>&1 | head -1 | sed 's/.*version "//' | sed 's/".*//')
COMMIT_SHA=$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null || echo "unknown")
TARGET_COMMIT_SHA="$COMMIT_SHA"
HARDWARE_PROFILE=$(detect_hardware_profile)
MANIFEST_VERSION=$(jq -r '.manifest_version // "1.0.0"' "$MANIFEST_FILE" 2>/dev/null || echo "1.0.0")
SCENARIO_ID=$(echo "$BENCH_CONFIG" | jq -r '.scenario_id // .id // empty' 2>/dev/null)
if [[ -z "$SCENARIO_ID" ]]; then
  echo "ERROR: Manifest contract drift for $BENCHMARK_ID: require .scenario_id or .id" >&2
  exit 1
fi
SCENARIO_CLASSIFICATION=$(echo "$BENCH_CONFIG" | jq -r '.scenario_classification // empty' 2>/dev/null)
if [[ -z "$SCENARIO_CLASSIFICATION" ]]; then
  echo "ERROR: Manifest contract drift for $BENCHMARK_ID: required field .scenario_classification is missing/empty" >&2
  exit 1
fi

# Classify benchmark status
STATUS_JSON=$(classify_bench_status "$BENCH_RC" "$POSTPROCESS_RC" "$JSON_FILE" "$JFR_FILE" "$METRICS_FILE" "$LOG_FILE" "$EXPECTED_CASE_COUNT" "$COMMIT_SHA" "$TARGET_COMMIT_SHA" "$JDK_VERSION" "$HARDWARE_PROFILE" "$MANIFEST_VERSION" "$SCENARIO_ID" "$SCENARIO_CLASSIFICATION")
if command -v jq >/dev/null 2>&1; then
  STATUS_JSON=$(echo "$STATUS_JSON" | jq --argjson postprocess_rc "$POSTPROCESS_RC" --argjson benchmark_exit_code "$BENCH_RC" '. + {postprocess_rc: $postprocess_rc, benchmark_exit_code: $benchmark_exit_code}' 2>/dev/null)
  if [[ -z "$STATUS_JSON" ]]; then
    echo "ERROR: Postprocess contract drift: unable to augment status JSON with exit codes" >&2
    exit 1
  fi

  # Fail fast when status contract drifts from canonical enums/shape.
  if ! echo "$STATUS_JSON" | jq -e '
    (.runner_status | type == "string") and
    (.runner_status == "success" or .runner_status == "partial" or .runner_status == "failed") and
    (.reproducibility_status | type == "string") and
      (.reproducibility_status == "complete" or .reproducibility_status == "incomplete_artifacts" or .reproducibility_status == "incomplete_metadata" or .reproducibility_status == "not_assessable") and
    (.json_row_count | type == "number") and
    (.failed_cases | type == "number") and
    (.benchmark_exit_code | type == "number") and
    (.postprocess_rc | type == "number")
  ' >/dev/null 2>&1; then
    echo "ERROR: Status contract drift detected for $BENCHMARK_ID/$PHASE." >&2
    echo "  Stage: classify_bench_status -> status.json emit" >&2
    echo "  Expected canonical fields/enums:" >&2
    echo "    runner_status: success|partial|failed" >&2
      echo "    reproducibility_status: complete|incomplete_artifacts|incomplete_metadata|not_assessable" >&2
    echo "    numeric: json_row_count, failed_cases, benchmark_exit_code, postprocess_rc" >&2
    echo "  Observed status JSON:" >&2
    echo "$STATUS_JSON" >&2
    exit 1
  fi

  RUNNER_STATUS=$(echo "$STATUS_JSON" | jq -er '.runner_status' 2>/dev/null)
  REPRODUCIBILITY_STATUS=$(echo "$STATUS_JSON" | jq -er '.reproducibility_status' 2>/dev/null)
  JSON_COUNT=$(echo "$STATUS_JSON" | jq -er '.json_row_count' 2>/dev/null)
  ARTIFACT_COMPLETENESS=$(echo "$STATUS_JSON" | jq -er '.artifact_completeness' 2>/dev/null)
else
  echo "ERROR: jq is required for contract-safe status extraction" >&2
  exit 1
fi

# Write status JSON
STATUS_FILE="${STEM}.status.json"
printf '%s\n' "$STATUS_JSON" > "$STATUS_FILE"

# Write reproducibility metadata (extract JDK vendor for additional metadata)
JDK_VENDOR=$(detect_jdk_vendor)
IMPL_VARIANT=$(echo "$BENCH_CONFIG" | jq -r '.implementation_variant // .class // empty' 2>/dev/null)
if [[ -z "$IMPL_VARIANT" ]]; then
  echo "ERROR: Manifest contract drift for $BENCHMARK_ID: require .implementation_variant or .class" >&2
  exit 1
fi
FAMILY=$(echo "$BENCH_CONFIG" | jq -r '.family // empty' 2>/dev/null)
if [[ -z "$FAMILY" ]]; then
  echo "ERROR: Manifest contract drift for $BENCHMARK_ID: required field .family is missing/empty" >&2
  exit 1
fi
WIRING_MODEL=$(echo "$BENCH_CONFIG" | jq -r '.wiring_model // .scenario_classification_wiring_model // empty' 2>/dev/null)

# Build JVM flags array for metadata
JVM_FLAGS_JSON="["
for jvm_arg in "${JVM_ARGS[@]}"; do
  JVM_FLAGS_JSON+="\"${jvm_arg//\"/\\\"}\","
done
JVM_FLAGS_JSON="${JVM_FLAGS_JSON%,}]"

REPRODUCIBILITY_FILE="${STEM}.reproducibility-metadata.json"
write_reproducibility_metadata \
  "$REPRODUCIBILITY_FILE" \
  "$BENCHMARK_ID" \
  "$TIER" \
  "$PHASE" \
  "$IMPL_VARIANT" \
  "$FAMILY" \
  "$COMMIT_SHA" \
  "$TARGET_COMMIT_SHA" \
  "$JDK_VENDOR" \
  "$JDK_VERSION" \
  "$JVM_FLAGS_JSON" \
  "$HARDWARE_PROFILE" \
  "$MANIFEST_VERSION" \
  "$SCENARIO_ID" \
  "$SCENARIO_CLASSIFICATION" \
  "$WIRING_MODEL"

# Print result summary
echo ""
echo "=========================================================================="
echo "RESULT SUMMARY"
echo "=========================================================================="
echo "Runner status          : $RUNNER_STATUS"
echo "Reproducibility status : $REPRODUCIBILITY_STATUS"
echo "Benchmark exit code    : $BENCH_RC"
echo "Postprocess exit code  : $POSTPROCESS_RC"
echo "Completed cases        : $JSON_COUNT"
echo "Artifact completeness  : $ARTIFACT_COMPLETENESS"
echo "=========================================================================="
echo ""

exit $BENCH_RC
