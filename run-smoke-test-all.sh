#!/usr/bin/env bash
# run-smoke-test-all.sh — minimal smoke test for all primary TLS benchmarks
# Executes baseline phase for B3, B4, B5, B6, B6b, B7 and reports results

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$REPO_ROOT/tools/bench"
MANIFEST_FILE="$REPO_ROOT/tools/matrix/manifests/primary-tls-matrix.json"

# Kill any remaining JMH processes
echo "=== Killing any remaining JMH processes ==="
pkill -f "java.*jmh" 2>/dev/null || true
sleep 1

# Create output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="$REPO_ROOT/results/raw/smoke-test-all-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"
echo "Output directory: $OUTPUT_DIR"
echo

# Initialize results tracking
declare -A RESULTS
SUCCESS_COUNT=0
FAILURE_COUNT=0
FAILED_BENCHMARKS=""

# Benchmark list to test
BENCHMARKS=("B3" "B4" "B5" "B6" "B6b" "B7")

# Create phase directory
PHASE_DIR="$OUTPUT_DIR/baseline"
mkdir -p "$PHASE_DIR"

echo "=== Starting smoke test ==="
echo "Manifest: $MANIFEST_FILE"
echo "Benchmarks to test: ${BENCHMARKS[*]}"
echo

# Test each benchmark
for benchmark_id in "${BENCHMARKS[@]}"; do
  echo "--- Testing $benchmark_id ---"
  
  # Extract class and env source from manifest
  CLASS=$(jq -r ".benchmarks[] | select(.id == \"$benchmark_id\") | .class" "$MANIFEST_FILE" 2>/dev/null)
  ENV_SOURCE=$(jq -r ".benchmarks[] | select(.id == \"$benchmark_id\") | (.sysprops_env_source // \"community\")" "$MANIFEST_FILE" 2>/dev/null)
  
  if [[ -z "$CLASS" ]]; then
    echo "ERROR: Could not find class for $benchmark_id in manifest"
    RESULTS["$benchmark_id"]="FAIL (manifest lookup)"
    FAILED_BENCHMARKS="$FAILED_BENCHMARKS $benchmark_id"
    ((FAILURE_COUNT++))
    continue
  fi
  
  echo "Class: $CLASS"
  echo "Env source: $ENV_SOURCE"
  
  # Call run-jmh-case.sh
  if "$TOOLS_DIR/run-jmh-case.sh" \
    --benchmark-id "$benchmark_id" \
    --class "$CLASS" \
    --phase baseline \
    --output-dir "$PHASE_DIR" \
    --manifest-file "$MANIFEST_FILE" \
    --env-source "$ENV_SOURCE" \
    --headless > "$PHASE_DIR/${benchmark_id}_baseline.log" 2>&1; then
    
    echo "Status: PASS"
    RESULTS["$benchmark_id"]="PASS"
    ((SUCCESS_COUNT++))
  else
    echo "Status: FAIL (exit code: $?)"
    RESULTS["$benchmark_id"]="FAIL"
    FAILED_BENCHMARKS="$FAILED_BENCHMARKS $benchmark_id"
    ((FAILURE_COUNT++))
  fi
  echo
done

# Generate summary report
echo "=== SMOKE TEST SUMMARY ==="
echo
echo "Results Directory: $OUTPUT_DIR"
echo "Timestamp: $TIMESTAMP"
echo
echo "| Benchmark ID | Status |"
echo "|---|---|"
for benchmark_id in "${BENCHMARKS[@]}"; do
  status="${RESULTS[$benchmark_id]:-UNKNOWN}"
  echo "| $benchmark_id | $status |"
done
echo
echo "Summary:"
echo "  Passed: $SUCCESS_COUNT"
echo "  Failed: $FAILURE_COUNT"

if [[ -n "$FAILED_BENCHMARKS" ]]; then
  echo "  Failed benchmarks:$FAILED_BENCHMARKS"
fi

echo
echo "Output files:"
ls -lh "$PHASE_DIR"/ 2>/dev/null | tail -n +2

# Exit with appropriate code
if [[ $FAILURE_COUNT -gt 0 ]]; then
  exit 1
fi

exit 0
