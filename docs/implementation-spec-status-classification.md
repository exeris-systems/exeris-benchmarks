---
title: "Implementation Spec: Status Classification & Claim Eligibility"
description: "Step-by-step implementation of runner_status, reproducibility_status, final_reason, and claim_scope classification logic."
---

# Implementation Spec: Status Classification

## Files to Modify

### 1. tools/bench/lib/status.sh — Main Classification Logic

**Current state:**
- `classify_bench_status()` produces fuzzy statuses: "ok", "benchmark_failed", "postprocess_failed", etc.
- Uses floating-point `artifact_completeness` (0.0–1.0) instead of enum statuses
- Does not compute `final_reason` or `claim_scope`

**Required changes:**

#### Update `classify_bench_status()` signature and output

```bash
classify_bench_status() {
  local bench_rc="$1"
  local postprocess_rc="$2"
  local json_file="$3"
  local jfr_file="$4"
  local metrics_file="$5"
  local log_file="$6"
  # NEW PARAMS:
  local jfr_expected="$7"          # boolean: true if JFR recording was enabled
  local metrics_expected="$8"      # boolean: true if -prof gc/-prof async expected
  local commit_sha="$9"
  local jdk_version="${10}"
  local hardware_profile="${11}"
  local jvm_flags="${12}"
  local scenario_id="${13}"

  # Compute runner_status
  local runner_status=$(compute_runner_status "$bench_rc" "$json_file")
  # Values: success | partial | failed

  # Compute reproducibility_status (only if runner != failed)
  local reproducibility_status
  if [[ "$runner_status" == "failed" ]]; then
    reproducibility_status="not_assessable"
  else
    reproducibility_status=$(compute_reproducibility_status \
      "$jfr_expected" "$jfr_file" \
      "$metrics_expected" "$metrics_file" \
      "$commit_sha" "$jdk_version" "$hardware_profile" "$jvm_flags" "$scenario_id")
  fi
  # Values: complete | incomplete_artifacts | incomplete_metadata | not_assessable

  # Compute final_reason (priority order)
  local final_reason=$(compute_final_reason \
    "$runner_status" "$reproducibility_status" \
    "$bench_rc" "$postprocess_rc" \
    "$json_file" "$jfr_expected" "$jfr_file" \
    "$metrics_expected" "$metrics_file" \
    "$commit_sha" "$jdk_version" "$hardware_profile" "$jvm_flags" "$scenario_id")
  # Values: ok | partial_json | empty_json | invalid_json | benchmark_exit_nonzero | postprocess_exit_nonzero | missing_jfr | missing_metrics | missing_metadata

  # Compute claim_scope (derived from above)
  local claim_scope=$(compute_claim_scope "$runner_status" "$reproducibility_status" "$final_reason")
  # Values: comparison_eligible | descriptive_partial | descriptive_only | none

  # Output JSON
  cat <<EOF
{
  "runner_status": "$runner_status",
  "reproducibility_status": "$reproducibility_status",
  "final_reason": "$final_reason",
  "claim_scope": "$claim_scope",
  "json_row_count": $(count_json_rows "$json_file"),
  "jfr_collected": $(bool_to_json $(test -s "$jfr_file"; echo $?)),
  "metrics_collected": $(bool_to_json $(test -s "$metrics_file"; echo $?))
}
EOF
}
```

#### New Helper Functions

```bash
# compute_runner_status(bench_rc, json_file) → success | partial | failed
compute_runner_status() {
  local bench_rc="$1"
  local json_file="$2"

  local json_count=0
  if [[ -s "$json_file" ]]; then
    json_count=$(jq 'length // 0' "$json_file" 2>/dev/null || echo 0)
  fi

  if [[ $bench_rc -eq 0 && $json_count -gt 0 ]]; then
    echo "success"
  elif [[ $json_count -gt 0 ]]; then
    echo "partial"
  else
    echo "failed"
  fi
}

# compute_reproducibility_status(...) → complete | incomplete_artifacts | incomplete_metadata | not_assessable
compute_reproducibility_status() {
  local jfr_expected="$1"  jfr_file="$2"
  local metrics_expected="$3"  metrics_file="$4"
  local commit_sha="$5"  jdk_version="$6"  hardware_profile="$7"  jvm_flags="$8"  scenario_id="$9"

  # Check metadata completeness first
  if [[ -z "$commit_sha" || -z "$jdk_version" || -z "$hardware_profile" || -z "$jvm_flags" || -z "$scenario_id" ]]; then
    echo "incomplete_metadata"
    return
  fi

  # Check artifact completeness
  local jfr_ok=true  metrics_ok=true
  if [[ "$jfr_expected" == "true" && ! -s "$jfr_file" ]]; then
    jfr_ok=false
  fi
  if [[ "$metrics_expected" == "true" && ! -s "$metrics_file" ]]; then
    metrics_ok=false
  fi

  if [[ "$jfr_ok" == "true" && "$metrics_ok" == "true" ]]; then
    echo "complete"
  else
    echo "incomplete_artifacts"
  fi
}

# compute_final_reason(...) → ok | partial_json | empty_json | invalid_json | benchmark_exit_nonzero | postprocess_exit_nonzero | missing_jfr | missing_metrics | missing_metadata
compute_final_reason() {
  local runner_status="$1"  reproducibility_status="$2"
  local bench_rc="$3"  postprocess_rc="$4"
  local json_file="$5"
  local jfr_expected="$6"  jfr_file="$7"
  local metrics_expected="$8"  metrics_file="$9"
  local commit_sha="${10}"  jdk_version="${11}"  hardware_profile="${12}"  jvm_flags="${13}"  scenario_id="${14}"

  # Priority order: check in exact order, return first match

  # 1. ok
  if [[ "$runner_status" == "success" && "$reproducibility_status" == "complete" ]]; then
    echo "ok"
    return
  fi

  # 2. partial_json
  if [[ "$runner_status" == "partial" ]]; then
    echo "partial_json"
    return
  fi

  # 3. empty_json
  if [[ "$runner_status" == "failed" ]]; then
    local json_count=0
    if [[ -s "$json_file" ]]; then
      json_count=$(jq 'length // 0' "$json_file" 2>/dev/null || echo 0)
    fi
    if [[ $json_count -eq 0 ]]; then
      echo "empty_json"
      return
    fi

    # 4. invalid_json
    if ! jq empty "$json_file" 2>/dev/null; then
      echo "invalid_json"
      return
    fi

    # 5. benchmark_exit_nonzero
    if [[ $bench_rc -ne 0 ]]; then
      echo "benchmark_exit_nonzero"
      return
    fi
  fi

  # 6. postprocess_exit_nonzero (only if runner=partial)
  if [[ "$runner_status" == "partial" && $postprocess_rc -ne 0 ]]; then
    echo "postprocess_exit_nonzero"
    return
  fi

  # 7. missing_jfr
  if [[ "$reproducibility_status" == "incomplete_artifacts" && "$jfr_expected" == "true" && ! -s "$jfr_file" ]]; then
    echo "missing_jfr"
    return
  fi

  # 8. missing_metrics
  if [[ "$reproducibility_status" == "incomplete_artifacts" && "$metrics_expected" == "true" && ! -s "$metrics_file" ]]; then
    echo "missing_metrics"
    return
  fi

  # 9. missing_metadata
  if [[ "$reproducibility_status" == "incomplete_metadata" ]]; then
    echo "missing_metadata"
    return
  fi

  # Fallback (should not reach)
  echo "unknown"
}

# compute_claim_scope(runner_status, reproducibility_status, final_reason) → comparison_eligible | descriptive_partial | descriptive_only | none
compute_claim_scope() {
  local runner_status="$1"  reproducibility_status="$2"  final_reason="$3"

  if [[ "$final_reason" == "ok" ]]; then
    echo "comparison_eligible"
  elif [[ "$runner_status" == "partial" ]]; then
    echo "descriptive_partial"
  elif [[ "$runner_status" == "success" ]]; then
    echo "descriptive_only"
  else
    echo "none"
  fi
}

# Helper: count JSON array rows
count_json_rows() {
  local json_file="$1"
  if [[ -s "$json_file" ]]; then
    jq 'length // 0' "$json_file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Helper: convert shell boolean to JSON
bool_to_json() {
  if [[ "$1" -eq 0 ]]; then echo "true"; else echo "false"; fi
}
```

### 2. tools/bench/lib/csv-writer.sh — Update CSV Functions

**Current state:**
- `init_status_csv()` uses only 16 columns
- `write_status_csv()` takes 17 positional parameters

**Required changes:**

```bash
# Update header
init_status_csv() {
  local output_csv="$1"
  cat > "$output_csv" <<'EOF'
timestamp,phase,benchmark_id,tier,implementation_variant,benchmark_family,protocol_mode,execution_class,runner_status,reproducibility_status,final_reason,claim_scope,benchmark_exit_code,postprocess_exit_code,expected_case_count,json_row_count,failed_case_count,log_failure_count,jfr_expected,jfr_collected,metrics_expected,metrics_collected,metadata_complete,log_file,json_file,jfr_file,metrics_file,cmd_file,jvm_args_file,reproducibility_metadata_file
EOF
}

# Update write function (use associative array for clarity)
write_status_csv() {
  local output_csv="$1"
  local -A row=(
    [timestamp]="$2"
    [phase]="$3"
    [benchmark_id]="$4"
    [tier]="$5"
    [implementation_variant]="$6"
    [benchmark_family]="$7"
    [protocol_mode]="$8"
    [execution_class]="$9"
    [runner_status]="${10}"
    [reproducibility_status]="${11}"
    [final_reason]="${12}"
    [claim_scope]="${13}"
    [benchmark_exit_code]="${14}"
    [postprocess_exit_code]="${15}"
    [expected_case_count]="${16}"
    [json_row_count]="${17}"
    [failed_case_count]="${18}"
    [log_failure_count]="${19}"
    [jfr_expected]="${20}"
    [jfr_collected]="${21}"
    [metrics_expected]="${22}"
    [metrics_collected]="${23}"
    [metadata_complete]="${24}"
    [log_file]="${25}"
    [json_file]="${26}"
    [jfr_file]="${27}"
    [metrics_file]="${28}"
    [cmd_file]="${29}"
    [jvm_args_file]="${30}"
    [reproducibility_metadata_file]="${31}"
  )

  # Build CSV row (note: quote fields that may contain commas)
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${row[timestamp]}" "${row[phase]}" "${row[benchmark_id]}" "${row[tier]}" \
    "${row[implementation_variant]}" "${row[benchmark_family]}" "${row[protocol_mode]}" \
    "${row[execution_class]}" "${row[runner_status]}" "${row[reproducibility_status]}" \
    "${row[final_reason]}" "${row[claim_scope]}" "${row[benchmark_exit_code]}" \
    "${row[postprocess_exit_code]}" "${row[expected_case_count]}" "${row[json_row_count]}" \
    "${row[failed_case_count]}" "${row[log_failure_count]}" "${row[jfr_expected]}" \
    "${row[jfr_collected]}" "${row[metrics_expected]}" "${row[metrics_collected]}" \
    "${row[metadata_complete]}" "${row[log_file]}" "${row[json_file]}" "${row[jfr_file]}" \
    "${row[metrics_file]}" "${row[cmd_file]}" "${row[jvm_args_file]}" \
    "${row[reproducibility_metadata_file]}" >> "$output_csv"
}
```

### 3. tools/bench/tests/test-classification.sh — Validation Tests

Create new test file to verify all 10 matrix cases:

```bash
#!/bin/bash
set -euo pipefail

# Source classification functions
source "$(dirname "$0")/../lib/status.sh"

TEST_DIR="/tmp/bench-test-$$"
mkdir -p "$TEST_DIR"
trap "rm -rf $TEST_DIR" EXIT

# Test Case 1: Success
test_case_1() {
  echo "TEST 1: Perfect run (exit=0, json=3 rows, metadata complete)"
  
  echo '[{"benchmark":"test","score":100},{"benchmark":"test","score":101},{"benchmark":"test","score":102}]' > "$TEST_DIR/result.json"
  
  local result=$(classify_bench_status 0 0 "$TEST_DIR/result.json" "$TEST_DIR/test.jfr" "$TEST_DIR/test-metrics.json" "$TEST_DIR/test.log" \
    true "$TEST_DIR/test.jfr" \
    true "$TEST_DIR/test-metrics.json" \
    "abc1234567" "21.0.1" "perf-box-amd64" "-XX:+UseG1GC" "wrapUnwrapRoundTrip-16384")
  
  assert_field "$result" "runner_status" "success"
  assert_field "$result" "reproducibility_status" "complete"
  assert_field "$result" "final_reason" "ok"
  assert_field "$result" "claim_scope" "comparison_eligible"
}

# Test Case 5: Exit 0 but empty JSON
test_case_5() {
  echo "TEST 5: Exit 0 but no results (warmup loop issue)"
  
  echo '[]' > "$TEST_DIR/result.json"
  
  local result=$(classify_bench_status 0 0 "$TEST_DIR/result.json" "" "" "$TEST_DIR/test.log" \
    false "" false "" \
    "abc1234567" "21.0.1" "perf-box-amd64" "-XX:+UseG1GC" "wrapUnwrapRoundTrip-16384")
  
  assert_field "$result" "runner_status" "failed"
  assert_field "$result" "reproducibility_status" "not_assessable"
  assert_field "$result" "final_reason" "empty_json"
  assert_field "$result" "claim_scope" "none"
}

# Test Case 7: Partial (exit nonzero but some rows)
test_case_7() {
  echo "TEST 7: Benchmark crashed mid-measurement but some rows exist"
  
  echo '[{"benchmark":"test","score":100},{"benchmark":"test","score":101}]' > "$TEST_DIR/result.json"
  
  local result=$(classify_bench_status 139 0 "$TEST_DIR/result.json" "$TEST_DIR/test.jfr" "$TEST_DIR/test-metrics.json" "$TEST_DIR/test.log" \
    true "$TEST_DIR/test.jfr" \
    true "$TEST_DIR/test-metrics.json" \
    "abc1234567" "21.0.1" "perf-box-amd64" "-XX:+UseG1GC" "wrapUnwrapRoundTrip-16384")
  
  assert_field "$result" "runner_status" "partial"
  assert_field "$result" "reproducibility_status" "complete"
  assert_field "$result" "final_reason" "partial_json"
  assert_field "$result" "claim_scope" "descriptive_partial"
}

# Helper
assert_field() {
  local json="$1"  field="$2"  expected="$3"
  local actual=$(echo "$json" | jq -r ".$field")
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $field expected '$expected' got '$actual'"
    return 1
  fi
  echo "  ✓ $field = $actual"
}

# Run all tests
test_case_1
test_case_5
test_case_7

echo "✅ All classification tests passed"
```

### 4. Evidence Lab / Report Tools — Add Gating

Any tool that reads status.csv for comparisons/aggregations must:

```bash
# Example: scripts/compare-results.sh needs this check
read_comparison_eligible_runs() {
  local status_csv="$1"
  # Skip header
  tail -n +2 "$status_csv" | while IFS=, read -r -u 3 -A fields; do
    local claim_scope="${fields[11]}"  # 12th column (0-indexed)
    if [[ "$claim_scope" != "comparison_eligible" ]]; then
      echo "⚠️ Skipping non-comparison run: ${fields[3]} (claim_scope=$claim_scope, reason=${fields[10]})" >&2
      continue
    fi
    echo "$line"
  done 3< <(tail -n +2 "$status_csv")
}
```

---

## Testing & Validation

### Test Execution

```bash
# Run classification tests
bash tools/bench/tests/test-classification.sh

# Verify all future status.csv rows
bash tools/verify-classification.sh results/status.csv
```

### Verification Script (tools/verify-classification.sh)

See [verify-classification.sh](#verification-script-below).

---

## Migration Plan

### Step 1: Merge new functions (backward compatible)

- Add new helper functions to status.sh
- Keep old `classify_bench_status()` as deprecated wrapper
- All calls still work

### Step 2: Update call sites

- Update `tools/bench/run-jmh-case.sh` to call new functions with full parameters
- Update `run-primary-tls-matrix.sh` to pass new parameters
- Update runtime benchmark runners similarly

### Step 3: Verify CSV output

- Run test benchmarks
- Check status.csv for correct classification
- Run verification script; must pass 100%

### Step 4: Deploy gating in evidence lab

- Update comparison scripts to check `claim_scope`
- Add test case: verify partial runs excluded from regression analysis
- Verify dashboards only read `comparison_eligible` runs

---

## Sign-Off Checklist

- [ ] New functions added to status.sh
- [ ] CSV schema committed + fields documented
- [ ] Test matrix (10 cases) all pass
- [ ] Verification script runs without errors
- [ ] All benchmark runners updated to pass new parameters
- [ ] Evidence lab gating implemented + tested
- [ ] Status.csv produced matches schema
- [ ] No comparison claim can pass when claim_scope ≠ "comparison_eligible"
- [ ] Partial/failed runs correctly excluded from comparisons
- [ ] Documentation updated in result-interpretation.md

