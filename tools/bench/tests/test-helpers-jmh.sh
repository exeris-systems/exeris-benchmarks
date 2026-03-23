#!/usr/bin/env bash
# test-helpers-jmh.sh — test JMH helper functions

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/jmh.sh"

echo "Testing JMH helpers..."

# Create test JSON
TEST_JSON=$(mktemp)
cat > "$TEST_JSON" <<'EOF'
[
  {"benchmark": "B1", "score": 123.45},
  {"benchmark": "B2", "score": 234.56},
  {"benchmark": "B3", "score": 345.67}
]
EOF

# Test json_row_count
echo "Testing json_row_count..."
COUNT=$(json_row_count "$TEST_JSON")
if [[ "$COUNT" -ne 3 ]]; then
  echo "FAIL: Expected 3, got $COUNT"
  exit 1
fi
echo "PASS: json_row_count returned $COUNT"

# Test estimate_failed_cases
echo "Testing estimate_failed_cases..."
FAILED=$(estimate_failed_cases 0 3 "/nonexistent/log.txt")
if [[ "$FAILED" -ne 0 ]]; then
  echo "FAIL: Expected 0 failures for rc=0, got $FAILED"
  exit 1
fi
echo "PASS: estimate_failed_cases returned $FAILED"

# Clean up
rm -f "$TEST_JSON"

echo "All JMH helper tests passed!"
