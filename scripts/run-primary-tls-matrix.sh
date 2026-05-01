#!/usr/bin/env bash
# run-primary-tls-matrix.sh — thin orchestrator for primary TLS benchmark matrix
# Orchestrates execution of all benchmarks across selected phases
#
# Usage:
#   MODE=baseline HEADLESS=0 FAIL_FAST=0 ./scripts/run-primary-tls-matrix.sh
#
# ENV variables:
#   MODE: baseline | profile | gc | all (default: all)
#   HEADLESS: 0 or 1 (default: 0)
#   FAIL_FAST: 0 or 1 (default: 0)
#   BENCH_FILTER: regex filter for benchmark IDs (optional)
#   PHASE_FILTER: regex filter for phase names (optional)
#   MANIFEST_FILE: path to matrix manifest JSON (optional)

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/tools/bench"

# Load helpers
source "$TOOLS_DIR/lib/certs.sh"
source "$TOOLS_DIR/lib/compat.sh"
source "$TOOLS_DIR/lib/paths.sh"
source "$TOOLS_DIR/lib/status.sh"

# Configuration
MODE="${MODE:-all}"
HEADLESS="${HEADLESS:-0}"
FAIL_FAST="${FAIL_FAST:-0}"
AUTO_BUILD_JMH="${AUTO_BUILD_JMH:-1}"
BENCH_FILTER="${BENCH_FILTER:-}"
PHASE_FILTER="${PHASE_FILTER:-}"
MANIFEST_FILE="${MANIFEST_FILE:-$REPO_ROOT/tools/matrix/manifests/primary-tls-matrix.json}"

if [[ ! -r "$MANIFEST_FILE" ]]; then
  echo "ERROR: Manifest file is not readable: $MANIFEST_FILE" >&2
  exit 1
fi

# Validate mode
case "$MODE" in
  baseline|profile|gc|all) ;;
  *) echo "ERROR: Invalid MODE: $MODE"; exit 1 ;;
esac

# Iterate benchmarks. Two external baselines (B3/B4) plus the CORE OffHeapTlsEngine
# measured under both ownership models: FD-owner (B6/B6b) and Memory-BIO (B5).
# B7 was removed — the manifest entry referenced ExerisEnterpriseTlsBenchmark which
# has no Java implementation in the JMH module; OffHeapTlsEngine under Memory-BIO
# (B5) is the canonical row for in-process bio-connector measurements.
BENCHMARKS=("B3" "B4" "B5" "B6" "B6b")

# Select newest jar by mtime for a glob pattern.
select_latest_jar() {
  local pattern="$1"
  local newest=""
  local newest_mtime=0
  local candidate
  local mtime

  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] || continue
    mtime=$(portable_stat_mtime "$candidate")
    if (( mtime > newest_mtime )); then
      newest="$candidate"
      newest_mtime=$mtime
    fi
  done < <(compgen -G "$pattern" || true)

  printf '%s' "$newest"
}

is_benchmarks_jar_stale() {
  local jar_path="$1"
  local src_dir="$REPO_ROOT/micro/jmh/src"
  local pom_file="$REPO_ROOT/micro/jmh/pom.xml"
  local reduced_pom_file="$REPO_ROOT/micro/jmh/dependency-reduced-pom.xml"

  [[ -f "$jar_path" ]] || return 0

  if [[ -d "$src_dir" ]] && find "$src_dir" -type f -newer "$jar_path" -print -quit | grep -q .; then
    return 0
  fi

  [[ -f "$pom_file" && "$pom_file" -nt "$jar_path" ]] && return 0
  [[ -f "$reduced_pom_file" && "$reduced_pom_file" -nt "$jar_path" ]] && return 0

  return 1
}

ensure_fresh_benchmarks_jar() {
  local jar_path="$1"

  if [[ "$AUTO_BUILD_JMH" != "1" ]]; then
    if [[ ! -f "$jar_path" ]]; then
      echo "ERROR: benchmarks.jar not found at $jar_path and AUTO_BUILD_JMH=0 disables rebuild." >&2
      exit 1
    fi

    if is_benchmarks_jar_stale "$jar_path"; then
      echo "ERROR: benchmarks.jar at $jar_path is stale and AUTO_BUILD_JMH=0 disables rebuild." >&2
      exit 1
    fi

    return 0
  fi

  if is_benchmarks_jar_stale "$jar_path"; then
    echo "benchmarks.jar missing or stale at $jar_path; rebuilding micro/jmh..."
    if ! (cd "$REPO_ROOT" && mvn -pl micro/jmh -am -DskipTests clean package); then
      echo "ERROR: Failed to rebuild benchmarks.jar with 'mvn -pl micro/jmh -am -DskipTests clean package'." >&2
      exit 1
    fi
  fi
}

# Resolve benchmark/runtime jars
BENCHMARKS_JAR="$REPO_ROOT/micro/jmh/target/benchmarks.jar"
ensure_fresh_benchmarks_jar "$BENCHMARKS_JAR"
if [[ ! -f "$BENCHMARKS_JAR" ]]; then
  echo "ERROR: benchmarks.jar not found at $BENCHMARKS_JAR after freshness check/rebuild." >&2
  exit 1
fi

COMMUNITY_JAR=$(select_latest_jar "$HOME/.m2/repository/eu/exeris/exeris-kernel-community/*/exeris-kernel-community-*.jar")
if [[ -z "$COMMUNITY_JAR" ]]; then
  echo "ERROR: Community jar not found in ~/.m2/repository/eu/exeris/exeris-kernel-community/. Build/install exeris-kernel-community first." >&2
  exit 1
fi

ENTERPRISE_JAR=$(select_latest_jar "$HOME/.m2/repository/eu/exeris/exeris-kernel-enterprise/*/exeris-kernel-enterprise-*.jar")

ENTERPRISE_BENCH_SELECTED=0
for benchmark_id in "${BENCHMARKS[@]}"; do
  if [[ -z "$BENCH_FILTER" || "$benchmark_id" =~ $BENCH_FILTER ]]; then
    if [[ "$benchmark_id" == "B5" ]]; then
      ENTERPRISE_BENCH_SELECTED=1
      break
    fi
  fi
done

if [[ -z "$ENTERPRISE_JAR" && "$ENTERPRISE_BENCH_SELECTED" == "1" ]]; then
  echo "ERROR: Enterprise jar is required for B5 (Memory-BIO) but was not found in ~/.m2/repository/eu/exeris/exeris-kernel-enterprise/." >&2
  exit 1
fi

build_classpath_for_benchmark() {
  local benchmark_id="$1"
  case "$benchmark_id" in
    B3|B4)
      printf '%s' "$BENCHMARKS_JAR"
      ;;
    B6|B6b)
      printf '%s:%s' "$BENCHMARKS_JAR" "$COMMUNITY_JAR"
      ;;
    B5)
      if [[ -z "$ENTERPRISE_JAR" ]]; then
        echo "ERROR: Enterprise jar required for $benchmark_id classpath" >&2
        return 1
      fi
      printf '%s:%s:%s' "$BENCHMARKS_JAR" "$COMMUNITY_JAR" "$ENTERPRISE_JAR"
      ;;
    *)
      echo "ERROR: Unsupported benchmark id for classpath mapping: $benchmark_id" >&2
      return 1
      ;;
  esac
}

# Create output root
OUTROOT="$(generate_output_root "$REPO_ROOT/results/raw/tls-matrix")"
mkdir -p "$OUTROOT"
STATUS_CSV="$OUTROOT/status.csv"

# Initialize status CSV
init_status_csv "$STATUS_CSV"

# Ensure certs (used by B5, B6, B7)
ensure_smoke_cert_key "/tmp/exeris-bench-certs/smoke-cert.pem" "/tmp/exeris-bench-certs/smoke-key.pem" || exit 1
assert_cert_key_type_and_size "/tmp/exeris-bench-certs/smoke-key.pem" "rsa" 2048 || exit 1

# Phases to execute
PHASES=()
[[ "$MODE" == "baseline" || "$MODE" == "all" ]] && PHASES+=("baseline")
[[ "$MODE" == "profile" || "$MODE" == "all" ]] && PHASES+=("profile")
[[ "$MODE" == "gc" || "$MODE" == "all" ]] && PHASES+=("gc")

for phase in "${PHASES[@]}"; do
  if [[ -n "$PHASE_FILTER" && ! "$phase" =~ $PHASE_FILTER ]]; then
    continue
  fi

  PHASE_DIR="$OUTROOT/$phase"
  mkdir -p "$PHASE_DIR"

  for benchmark_id in "${BENCHMARKS[@]}"; do
    if [[ -n "$BENCH_FILTER" && ! "$benchmark_id" =~ $BENCH_FILTER ]]; then
      continue
    fi

    echo "Running $benchmark_id / $phase..."

    # Resolve class from manifest
    CLASS=$(jq -r ".benchmarks[] | select(.id == \"$benchmark_id\") | .class" "$MANIFEST_FILE" 2>/dev/null)
    [[ -z "$CLASS" ]] && { echo "ERROR: Could not find class for $benchmark_id"; exit 1; }

    # Resolve env source from manifest (community|enterprise|none)
    ENV_SOURCE=$(jq -r ".benchmarks[] | select(.id == \"$benchmark_id\") | (.sysprops_env_source // \"community\")" "$MANIFEST_FILE" 2>/dev/null)
    [[ -z "$ENV_SOURCE" || "$ENV_SOURCE" == "null" ]] && { echo "ERROR: Could not resolve sysprops_env_source for $benchmark_id"; exit 1; }

    BENCH_CP="$(build_classpath_for_benchmark "$benchmark_id")" || exit 1

    # Call single-case runner
    export CP="$BENCH_CP"
    export HEADLESS
    "$TOOLS_DIR/run-jmh-case.sh" \
      --benchmark-id "$benchmark_id" \
      --class "$CLASS" \
      --phase "$phase" \
      --output-dir "$PHASE_DIR" \
      --manifest-file "$MANIFEST_FILE" \
      --env-source "$ENV_SOURCE" \
      $([ "$HEADLESS" = "1" ] && echo "--headless")

    RUN_RC=$?

    # Parse status and append to CSV
    STATUS_FILE="$PHASE_DIR/${benchmark_id}_${phase}.status.json"
    if [[ -f "$STATUS_FILE" ]]; then
      RUNNER_STATUS=$(jq -r '.runner_status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
      REPRO_STATUS=$(jq -r '.reproducibility_status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
      JSON_COUNT=$(jq -r '.json_row_count' "$STATUS_FILE" 2>/dev/null || echo "0")
      FAILED_CASES=$(jq -r '.failed_cases // 0' "$STATUS_FILE" 2>/dev/null || echo "0")
      COMPLETENESS=$(jq -r '.artifact_completeness' "$STATUS_FILE" 2>/dev/null || echo "0.0")
      POSTPROCESS_RC=$(jq -r '.postprocess_rc // 0' "$STATUS_FILE" 2>/dev/null || echo "0")
      METRICS_WARN_COUNT=$(jq -r '.metrics_warning_count // 0' "$STATUS_FILE" 2>/dev/null || echo "0")

      JSON_FILE="$PHASE_DIR/${benchmark_id}_${phase}-jmh.json"
      JFR_FILE="$PHASE_DIR/${benchmark_id}_${phase}.jfr"
      METRICS_FILE="$PHASE_DIR/${benchmark_id}_${phase}-metrics.json"
      CMD_FILE="$PHASE_DIR/${benchmark_id}_${phase}.cmd"
      JVM_ARGS_FILE="$PHASE_DIR/${benchmark_id}_${phase}.jvm-args.txt"
      LOG_FILE="$PHASE_DIR/${benchmark_id}_${phase}.log"

      write_status_csv "$STATUS_CSV" "$phase" "$benchmark_id" "$RUNNER_STATUS" "$REPRO_STATUS" \
        "$RUN_RC" "$POSTPROCESS_RC" "$HEADLESS" "$JSON_COUNT" "$FAILED_CASES" "$COMPLETENESS" \
        "$LOG_FILE" "$JSON_FILE" "$JFR_FILE" "$METRICS_FILE" "$CMD_FILE" "$JVM_ARGS_FILE" \
        "$METRICS_WARN_COUNT"

      # Normalize result artifacts for compare/publish pipeline
      STEM="$PHASE_DIR/${benchmark_id}_${phase}"
      NORM_RESULT_FILE="${STEM}-normalized.json"
      # Build optional jfr-metrics arg
      NORMALIZE_JFR_ARG=()
      if [[ -s "${STEM}-metrics.json" ]]; then
        NORMALIZE_JFR_ARG=("--jfr-metrics" "${STEM}-metrics.json")
      fi
      "$TOOLS_DIR/normalize-result.sh" \
        --jmh-json "$JSON_FILE" \
        --status-json "$STATUS_FILE" \
        --repro-json "${STEM}.reproducibility-metadata.json" \
        --output "$NORM_RESULT_FILE" \
        --run-id "${benchmark_id}_${phase}_$(date +%Y%m%d%H%M%S)" \
        --forks "$(jq -r '[.[].forks // 1] | max // 1' "$JSON_FILE" 2>/dev/null || echo 1)" \
        "${NORMALIZE_JFR_ARG[@]}" \
        || echo "WARN: normalization failed for $benchmark_id/$phase (non-blocking)" >&2
    fi

    # Check FAIL_FAST
    if [[ $RUN_RC -ne 0 && "$FAIL_FAST" == "1" ]]; then
      echo "FAIL_FAST=1, aborting after $benchmark_id/$phase (exit code: $RUN_RC)"
      exit $RUN_RC
    fi
  done
done

echo ""
echo "=========================================================================="
echo "BENCHMARK MATRIX COMPLETE"
echo "=========================================================================="
echo "Results written to: $OUTROOT"
echo "Status CSV: $STATUS_CSV"
echo "=========================================================================="