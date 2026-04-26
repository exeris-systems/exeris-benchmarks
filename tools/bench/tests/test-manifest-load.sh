#!/usr/bin/env bash
# test-manifest-load.sh — test manifest JSON validation

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_FILE="$SCRIPT_DIR/matrix/manifests/primary-tls-matrix.json"

echo "Testing manifest validation..."

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "FAIL: Manifest not found at $MANIFEST_FILE"
  exit 1
fi

# Validate JSON syntax
if ! jq empty "$MANIFEST_FILE" 2>/dev/null; then
  echo "FAIL: Manifest is not valid JSON"
  exit 1
fi
echo "PASS: Manifest JSON is valid"

# Test: benchmarks must be an array
if ! jq -e '.benchmarks | type == "array"' "$MANIFEST_FILE" >/dev/null 2>&1; then
  echo "FAIL: benchmarks field is not an array"
  exit 1
fi
echo "PASS: benchmarks field is an array"

# Check for required benchmarks
for BENCH_ID in B3 B4 B5 B6 B7; do
  CLASS=$(jq -r ".benchmarks[] | select(.id == \"$BENCH_ID\") | .class" "$MANIFEST_FILE" 2>/dev/null)
  if [[ -z "$CLASS" || "$CLASS" == "null" ]]; then
    echo "FAIL: Benchmark $BENCH_ID not found or missing class"
    exit 1
  fi
  echo "PASS: Found $BENCH_ID ($CLASS)"
done

# Check for phases (phases is an object, not array)
for BENCH_ID in B5 B6 B7; do
  # Verify phases field exists and is an object
  if ! jq -e ".benchmarks[] | select(.id == \"$BENCH_ID\") | .phases | type == \"object\"" "$MANIFEST_FILE" >/dev/null 2>&1; then
    echo "FAIL: $BENCH_ID/phases is not an object"
    exit 1
  fi
  
  for PHASE in baseline profile gc; do
    PHASE_CONFIG=$(jq ".benchmarks[] | select(.id == \"$BENCH_ID\") | .phases.${PHASE}" "$MANIFEST_FILE" 2>/dev/null)
    if [[ -z "$PHASE_CONFIG" || "$PHASE_CONFIG" == "null" ]]; then
      echo "FAIL: $BENCH_ID/$PHASE phase not defined"
      exit 1
    fi
    echo "PASS: $BENCH_ID has phase $PHASE"
  done
done

# Verify no enterprise class names in manifest (CONFIDENTIALITY CHECK)
ENTERPRISE_CLASS_COUNT=$(grep -i "EnterpriseKernelCrypto\|EnterpriseKernelMemory\|EnterpriseMemoryProvider" "$MANIFEST_FILE" 2>/dev/null | wc -l)
if [[ $ENTERPRISE_CLASS_COUNT -gt 0 ]]; then
  echo "FAIL: Enterprise class names found in public manifest (CONFIDENTIALITY VIOLATION)"
  exit 1
fi
echo "PASS: No enterprise class names in manifest (confidentiality verified)"

# Verify benchmarks array has at least one entry with sysprops_env_source
SYSPROPS_COUNT=$(jq '[.benchmarks[]? | select((.sysprops_env_source // "") != "")] | length' "$MANIFEST_FILE" 2>/dev/null || echo 0)
if [[ $SYSPROPS_COUNT -lt 1 ]]; then
  echo "FAIL: sysprops_env_source not properly used in benchmarks"
  exit 1
fi
echo "PASS: sysprops_env_source references found in benchmarks ($SYSPROPS_COUNT)"

echo "All manifest validation tests passed!"
