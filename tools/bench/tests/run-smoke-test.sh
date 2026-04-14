#!/usr/bin/env bash
# run-smoke-test.sh — smoke test for Phase 1 refactor (run B3 baseline)
#
# This minimal test verifies the ref actor doesn't have fatal issues.
# NOT a full benchmark; just a sanity check with minimal warmup/iterations.

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS_DIR="$REPO_ROOT/tools/bench"
TEST_DIR="$REPO_ROOT/.smoke-test"

echo "=========================================================================="
echo "SMOKE TEST: Phase 1 Runner Stabilization"
echo "=========================================================================="
echo ""

# Cleanup from previous run
rm -rf "$TEST_DIR"

# Verify structure
echo "Checking Phase 1 implementation structure..."
CHECKS_PASSED=0
for FILE in lib/{certs,paths,jmh,status}.sh run-jmh-case.sh \
           ../matrix/manifests/primary-tls-matrix.json \
           ../../../env/community-sysprops.env \
           ../../../enterprise/env/enterprise-sysprops.env.template \
           ../../../.gitignore; do
  if [[ -f "$TOOLS_DIR/$FILE" || -f "$REPO_ROOT/${FILE}" ]]; then
    echo "✓ Found: $FILE"
    ((CHECKS_PASSED++))
  else
    echo "✗ Missing: $FILE"
  fi
done

if [[ $CHECKS_PASSED -lt 8 ]]; then
  echo "FAIL: Not all required files present"
  exit 1
fi

echo ""
echo "Running B3 baseline (smoke test) with minimal iterations..."
echo ""

# Run trivial B3 baseline (wi=1, i=1)
MODE=baseline HEADLESS=1 FAIL_FAST=0 "$REPO_ROOT/scripts/run-primary-tls-matrix.sh" 2>&1 | head -100

RESULT=$?

if [[ $RESULT -eq 0 ]]; then
  echo ""
  echo "=========================================================================="
  echo "SMOKE TEST PASSED"
  echo "=========================================================================="
  exit 0
else
  echo ""
  echo "=========================================================================="
  echo "SMOKE TEST FAILED (exit code: $RESULT)"
  echo "=========================================================================="
  exit $RESULT
fi
