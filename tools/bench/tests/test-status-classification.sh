#!/usr/bin/env bash
# test-status-classification.sh — test status classification logic
# CREATE controlled temp files for each test case

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/status.sh"

# Create temporary test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo "Testing status classification..."

# ============================================================================
# Test 1: Successful benchmark run (exit 0, no failures)
# ============================================================================
echo "Test 1: Successful run..."
TEST_LOG="$TEST_DIR/test1.log"
TEST_JSON="$TEST_DIR/test1.json"
TEST_JFR="$TEST_DIR/test1.jfr"
TEST_METRICS="$TEST_DIR/test1-metrics.json"

# Create test artifacts
cat > "$TEST_LOG" << 'EOF'
[00:00:00] Starting benchmark...
[00:00:05] Warmup iterations completed
[00:00:10] Measurement iterations completed
[00:00:15] Benchmark completed successfully
EOF

echo '[{"benchmark":"Test","mode":"thrpt","value":1000.0}]' > "$TEST_JSON"

touch "$TEST_JFR"
echo '{"cpu":1.0}' > "$TEST_METRICS"

STATUS=$(classify_bench_status 0 0 "$TEST_JSON" "$TEST_JFR" "$TEST_METRICS" "$TEST_LOG")
RUNNER_STATUS=$(echo "$STATUS" | jq -r '.runner_status')
REPRO_STATUS=$(echo "$STATUS" | jq -r '.reproducibility_status')
FAILED_CASES=$(echo "$STATUS" | jq -r '.failed_cases')

if [[ "$RUNNER_STATUS" != "success" ]] || [[ "$REPRO_STATUS" != "complete" ]]; then
  echo "FAIL: Expected runner_status=success, repro_status=complete. Got: $RUNNER_STATUS, $REPRO_STATUS"
  exit 1
fi
if [[ "$FAILED_CASES" != "0" ]]; then
  echo "FAIL: Expected failed_cases=0 for successful run. Got: $FAILED_CASES"
  exit 1
fi
echo "PASS: Successful run classified correctly"

# ============================================================================
# Test 2: Benchmark failed with zero completed cases (exit nonzero)
# ============================================================================
echo "Test 2: Complete failure (zero cases)..."
TEST_LOG="$TEST_DIR/test2.log"
TEST_JSON="$TEST_DIR/test2.json"

# Create test artifacts: empty JSON (no completed cases)
cat > "$TEST_LOG" << 'EOF'
[00:00:00] Starting benchmark...
[00:00:02] ERROR: Benchmark failed with exception
[00:00:02] FAIL: Unable to parse input
EOF

echo '[]' > "$TEST_JSON"

STATUS=$(classify_bench_status 1 0 "$TEST_JSON" "" "" "$TEST_LOG")
RUNNER_STATUS=$(echo "$STATUS" | jq -r '.runner_status')
REPRO_STATUS=$(echo "$STATUS" | jq -r '.reproducibility_status')
FAILED_CASES=$(echo "$STATUS" | jq -r '.failed_cases')
LOG_FAILURES=$(echo "$STATUS" | jq -r '.log_failure_count')

if [[ "$RUNNER_STATUS" != "benchmark_failed" ]] || [[ "$REPRO_STATUS" != "incomplete_artifacts" ]]; then
  echo "FAIL: Expected runner_status=benchmark_failed, repro_status=incomplete_artifacts. Got: $RUNNER_STATUS, $REPRO_STATUS"
  exit 1
fi
if [[ "$FAILED_CASES" -lt 1 ]]; then
  echo "FAIL: Expected failed_cases >= 1 from log, got: $FAILED_CASES (log_failures: $LOG_FAILURES)"
  exit 1
fi
echo "PASS: Complete failure classified correctly (failed_cases: $FAILED_CASES)"

# ============================================================================
# Test 3: Partial failure (some cases completed, but exit nonzero)
# ============================================================================
echo "Test 3: Partial failure..."
TEST_LOG="$TEST_DIR/test3.log"
TEST_JSON="$TEST_DIR/test3.json"

cat > "$TEST_LOG" << 'EOF'
[00:00:00] Starting benchmark...
[00:00:03] 5 iterations completed
[00:00:05] ERROR: Benchmark interrupted
[00:00:05] FAIL: Timeout
EOF

echo '[{"benchmark":"Test","mode":"thrpt","value":1000.0},{"benchmark":"Test","mode":"thrpt","value":950.0}]' > "$TEST_JSON"

STATUS=$(classify_bench_status 1 0 "$TEST_JSON" "" "" "$TEST_LOG")
RUNNER_STATUS=$(echo "$STATUS" | jq -r '.runner_status')
REPRO_STATUS=$(echo "$STATUS" | jq -r '.reproducibility_status')
FAILED_CASES=$(echo "$STATUS" | jq -r '.failed_cases')
JSON_COUNT=$(echo "$STATUS" | jq -r '.json_row_count')

if [[ "$RUNNER_STATUS" != "partial" ]] || [[ "$REPRO_STATUS" != "incomplete_artifacts" ]]; then
  echo "FAIL: Expected runner_status=partial, repro_status=incomplete_artifacts. Got: $RUNNER_STATUS, $REPRO_STATUS"
  exit 1
fi
if [[ "$JSON_COUNT" -ne 2 ]]; then
  echo "FAIL: Expected json_row_count=2, got: $JSON_COUNT"
  exit 1
fi
echo "PASS: Partial failure classified correctly"

# ============================================================================
# Test 4: Postprocess failure (runner succeeds but metrics fail)
# ============================================================================
echo "Test 4: Postprocess failure..."
TEST_LOG="$TEST_DIR/test4.log"
TEST_JSON="$TEST_DIR/test4.json"

cat > "$TEST_LOG" << 'EOF'
[00:00:00] Starting benchmark...
[00:00:10] Benchmark completed successfully
EOF

echo '[{"benchmark":"Test","mode":"thrpt","value":1000.0}]' > "$TEST_JSON"

STATUS=$(classify_bench_status 0 1 "$TEST_JSON" "" "" "$TEST_LOG")
RUNNER_STATUS=$(echo "$STATUS" | jq -r '.runner_status')
REPRO_STATUS=$(echo "$STATUS" | jq -r '.reproducibility_status')
FAILED_CASES=$(echo "$STATUS" | jq -r '.failed_cases')

if [[ "$RUNNER_STATUS" != "postprocess_failed" ]] || [[ "$REPRO_STATUS" != "incomplete_artifacts" ]]; then
  echo "FAIL: Expected runner_status=postprocess_failed, repro_status=incomplete_artifacts. Got: $RUNNER_STATUS, $REPRO_STATUS"
  exit 1
fi
if [[ "$FAILED_CASES" != "0" ]]; then
  echo "FAIL: Expected failed_cases=0 for postprocess failure, got: $FAILED_CASES"
  exit 1
fi
echo "PASS: Postprocess failure classified correctly"

echo ""
echo "All status classification tests passed!"
