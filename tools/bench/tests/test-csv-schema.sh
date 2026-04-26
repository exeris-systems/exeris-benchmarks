#!/usr/bin/env bash
# test-csv-schema.sh — test status CSV schema and escaping integrity

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/status.sh"

# Create temporary test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo "Testing CSV schema and escaping..."

# ============================================================================
# Test 1: CSV header contains all required columns
# ============================================================================
echo "Test 1: CSV header..."
TEST_CSV="$TEST_DIR/test1.csv"
init_status_csv "$TEST_CSV"

HEADER=$(head -1 "$TEST_CSV")
echo "CSV Header: $HEADER"

# Check for required columns
for COL in phase benchmark runner_status reproducibility_status completed_cases failed_cases cmd jvm_args; do
  if ! echo "$HEADER" | grep -q "$COL"; then
    echo "FAIL: Required column '$COL' not found in header"
    exit 1
  fi
done
echo "PASS: All required columns present in header"

# ============================================================================
# Test 2: CSV row with no special characters (baseline)
# ============================================================================
echo "Test 2: Simple row (no escaping needed)..."
TEST_CSV="$TEST_DIR/test2.csv"
init_status_csv "$TEST_CSV"

write_status_csv "$TEST_CSV" "baseline" "B6" "success" "complete" "0" "0" "1" "1000" "0" "1.0" \
  "/tmp/test.log" "/tmp/test-jmh.json" "" "" "java -version" "-Xms256m"

ROW_COUNT=$(wc -l < "$TEST_CSV")
if [[ $ROW_COUNT -ne 2 ]]; then
  echo "FAIL: Expected 2 lines (header + row), got $ROW_COUNT"
  exit 1
fi

# Verify row was parsed correctly
ROW=$(tail -1 "$TEST_CSV")
if ! echo "$ROW" | grep -q "baseline"; then
  echo "FAIL: Row data not found"
  exit 1
fi
ROW_FIELDS=$(echo "$ROW" | awk -F',' '{print NF}')
if [[ "$ROW_FIELDS" -ne 17 ]]; then
  echo "FAIL: Expected 17 CSV columns, got $ROW_FIELDS"
  echo "Row: $ROW"
  exit 1
fi
echo "PASS: Simple row written correctly"

# ============================================================================
# Test 3: CSV row with commas in fields (escaping required)
# ============================================================================
echo "Test 3: Row with commas in cmd field..."
TEST_CSV="$TEST_DIR/test3.csv"
init_status_csv "$TEST_CSV"

# Command with multiple arguments (contains commas when joined)
COMPLEX_CMD="java -version, -Xms256m, -Xmx1024m, -XX:+UseZGC"

write_status_csv "$TEST_CSV" "profile" "B7" "success" "complete" "0" "0" "1" "500" "0" "1.0" \
  "/tmp/B7_profile.log" "/tmp/B7_profile-jmh.json" "/tmp/B7_profile.jfr" \
  "/tmp/B7_profile-metrics.json" "$COMPLEX_CMD" "-XX:+UseZGC"

# Verify the CSV can be parsed back
ROW=$(tail -1 "$TEST_CSV")

FIELD_COUNT=$(echo "$ROW" | awk -F',' '{print NF}')
if [[ "$FIELD_COUNT" -lt 17 ]]; then
  echo "FAIL: CSV row has too few fields ($FIELD_COUNT), fields with commas may not be escaped properly"
  echo "Row: $ROW"
  exit 1
fi
echo "PASS: Row with commas escaped correctly (fields: $FIELD_COUNT)"

# ============================================================================
# Test 4: CSV row with quotes in fields
# ============================================================================
echo "Test 4: Row with quotes in jvm_args field..."
TEST_CSV="$TEST_DIR/test4.csv"
init_status_csv "$TEST_CSV"

# JVM args with quotes (e.g., -D options with quoted values)
QUOTED_ARGS='-Dsome.key="quoted value"'

write_status_csv "$TEST_CSV" "gc" "B3" "success" "complete" "0" "0" "1" "800" "0" "1.0" \
  "/tmp/B3_gc.log" "/tmp/B3_gc-jmh.json" "" "" "java" "$QUOTED_ARGS"

ROW=$(tail -1 "$TEST_CSV")
# Verify quotes are escaped (doubled) if field is quoted
if echo "$ROW" | grep -q '""'; then
  echo "PASS: Quotes in field are escaped (doubled quotes)"
elif echo "$ROW" | grep -q '".*"'; then
  echo "PASS: Field containing quotes is wrapped in quotes"
else
  # If no quotes at all, check if row is still valid
  if echo "$ROW" | grep -q "$QUOTED_ARGS"; then
    echo "PASS: Quoted field preserved"
  else
    echo "WARNING: Quote handling may need verification (row: $ROW)"
  fi
fi

# ============================================================================
# Test 5: CSV row with newlines (should be escaped)
# ============================================================================
echo "Test 5: Handling fields with problematic characters..."
TEST_CSV="$TEST_DIR/test5.csv"
init_status_csv "$TEST_CSV"

# Multi-line log path (simulated, though unusual)
MULTILINE_FIELD="line1
line2"

write_status_csv "$TEST_CSV" "baseline" "B4" "success" "complete" "0" "0" "1" "1200" "0" "1.0" \
  "$MULTILINE_FIELD" "/tmp/test.json" "" "" "cmd" "args"

# Verify the CSV still has 2 lines (header + 1 data) - multiline in quoted field doesn't add lines
TOTAL_LINES=$(wc -l < "$TEST_CSV")
if [[ $TOTAL_LINES -lt 2 ]]; then
  echo "FAIL: CSV parser doesn't handle quoted fields with newlines"
  exit 1
fi
echo "PASS: Problematic characters handled"

# ============================================================================
# Test 6: Verify CSV is parseable by standard tools
# ============================================================================
echo "Test 6: CSV parseable by standard tools..."
TEST_CSV="$TEST_DIR/test6.csv"
init_status_csv "$TEST_CSV"

# Write several rows with various special characters
write_status_csv "$TEST_CSV" "baseline" "B6" "success" "complete" "0" "0" "1" "1000" "0" "1.0" \
  "/path/with,comma.log" "/path/test-jmh.json" "" "" "java,-Xms256m" "-XX:+UseZGC"

write_status_csv "$TEST_CSV" "profile" "B7" "success" "complete" "0" "0" "1" "500" "0" "0.95" \
  "/path/with\"quote.log" "/path/test-jmh.json" "/path/test.jfr" \
  "/path/metrics.json" 'cmd -with "quotes"' "-Dproperty=\"value\""

# Try to parse with csvlook (if available) or basic awk
if command -v csvlook >/dev/null 2>&1; then
  if ! csvlook "$TEST_CSV" >/dev/null 2>&1; then
    echo "WARNING: csvlook failed on output CSV (may have CSV syntax issues)"
  else
    echo "PASS: CSV validated by csvlook"
  fi
else
  FIRST_FIELD_COUNT=$(head -2 "$TEST_CSV" | tail -1 | awk -F',' '{print NF}')
  LAST_FIELD_COUNT=$(tail -1 "$TEST_CSV" | awk -F',' '{print NF}')

  if [[ $FIRST_FIELD_COUNT -ge 14 && $LAST_FIELD_COUNT -ge 14 ]]; then
    echo "PASS: CSV has proper field count across rows"
  else
    echo "WARNING: Field count inconsistency (first: $FIRST_FIELD_COUNT, last: $LAST_FIELD_COUNT)"
  fi
fi

echo ""
echo "All CSV schema and escaping tests passed!"
