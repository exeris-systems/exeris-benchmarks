#!/usr/bin/env bash
# Helper functions for benchmark status classification and reproducibility metadata
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/compat.sh"

# ============================================================================
# CSV ESCAPING FUNCTION
# ============================================================================

# escape_csv_field(field_value) — escape a CSV field value
# Wraps field in quotes if it contains comma, quote, or newline
# Doubles any internal quotes following RFC 4180
escape_csv_field() {
  local field="$1"
  
  # If field contains comma, quote, or newline, escape it
  if [[ "$field" == *","* || "$field" == *'"'* || "$field" == *$'\n'* ]]; then
    # Escape internal quotes by doubling them
    field="${field//\"/\"\"}"
    # Wrap in quotes
    echo "\"$field\""
  else
    echo "$field"
  fi
}

# ============================================================================
# ARTIFACT VALIDATION
# ============================================================================

# validate_artifacts(phase, benchmark_id, output_dir, jfr_enabled, metrics_enabled)
# Returns JSON with {artifacts_valid, missing_artifacts, artifact_sizes}
# Validates that expected artifacts exist and are non-empty (>= 100 bytes)
validate_artifacts() {
  local phase="$1"
  local benchmark_id="$2"
  local output_dir="$3"
  local jfr_enabled="${4:-false}"
  local metrics_enabled="${5:-false}"

  local base_path="$output_dir/${benchmark_id}_${phase}"
  local missing=()
  local undersized=()
  local found=0

  # Expected artifacts for all phases
  local required_files=(
    "${base_path}.log"
    "${base_path}-jmh.json"
    "${base_path}.cmd"
    "${base_path}.jvm-args.txt"
    "${base_path}.status.json"
    "${base_path}.reproducibility-metadata.json"
  )

  # Additional artifacts for profile phase
  if [[ "$phase" == "profile" ]]; then
    if [[ "$jfr_enabled" == "true" ]]; then
      required_files+=("${base_path}.jfr")
    fi
    if [[ "$metrics_enabled" == "true" ]]; then
      required_files+=("${base_path}-metrics.json")
    fi
  fi

  # Check artifact presence and size
  for artifact in "${required_files[@]}"; do
    if [[ -f "$artifact" ]]; then
      local size
      size=$(portable_stat_size "$artifact")
      if [[ $size -ge 100 ]]; then
        ((found++))
      else
        undersized+=("$artifact ($size bytes)")
      fi
    else
      missing+=("$artifact")
    fi
  done

  # For gc phase, check that -prof gc was added to JMH output
  if [[ "$phase" == "gc" ]]; then
    if [[ -f "${base_path}-jmh.json" ]]; then
      if ! grep -q "gc" "${base_path}-jmh.json" 2>/dev/null; then
        missing+=("gc profiler output in -jmh.json")
      fi
    fi
  fi

  local artifacts_valid="true"
  [[ ${#missing[@]} -gt 0 || ${#undersized[@]} -gt 0 ]] && artifacts_valid="false"

  # Format report
  local missing_str=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)
  local undersized_str=$(printf '%s\n' "${undersized[@]}" | jq -R . | jq -s .)

  cat <<EOF
{
  "artifacts_valid": $artifacts_valid,
  "missing": $missing_str,
  "undersized": $undersized_str,
  "found_count": $found,
  "expected_count": ${#required_files[@]}
}
EOF
}

# ============================================================================
# METADATA VALIDATION
# ============================================================================

# validate_reproducibility_metadata(metadata_json_file)
# Validates metadata against reproducibility schema
# Returns JSON with {valid, errors, warnings}
validate_reproducibility_metadata() {
  local metadata_file="$1"

  local errors=()
  local warnings=()
  
  if [[ ! -f "$metadata_file" ]]; then
    cat <<EOF
{
  "valid": false,
  "errors": ["Metadata file does not exist: $metadata_file"],
  "warnings": []
}
EOF
    return 1
  fi

  # Validate JSON syntax
  if ! jq empty "$metadata_file" 2>/dev/null; then
    cat <<EOF
{
  "valid": false,
  "errors": ["Metadata file is not valid JSON"],
  "warnings": []
}
EOF
    return 1
  fi

  # Required fields and their types
  local required_fields=(
    "timestamp:string"
    "benchmark_id:string"
    "tier:string"
    "phase:string"
    "implementation_variant:string"
    "family:string"
    "manifest_version:string"
    "benchmark_commit_sha:string"
    "target_commit_sha:string"
    "jdk_vendor:string"
    "jdk_version:string"
    "jvm_flags:array"
    "hardware_profile:string"
    "scenario_id:string"
    "scenario_classification:string"
  )

  # Check required fields
  for field_spec in "${required_fields[@]}"; do
    local field="${field_spec%:*}"
    local expected_type="${field_spec#*:}"
    
    local value=$(jq -r ".${field} // empty" "$metadata_file" 2>/dev/null)
    
    if [[ -z "$value" ]]; then
      errors+=("Missing required field: $field")
    else
      # Type validation
      case "$expected_type" in
        string)
          if [[ -z "$value" ]]; then
            errors+=("Empty string field: $field")
          fi
          ;;
        array)
          if ! jq -e ".${field} | type == \"array\"" "$metadata_file" >/dev/null 2>&1; then
            errors+=("Field $field is not an array")
          fi
          ;;
      esac
    fi
  done

  # Validate hardware_profile is from canonical vocabulary
  local hw_profile=$(jq -r '.hardware_profile // empty' "$metadata_file" 2>/dev/null)
  if [[ -n "$hw_profile" ]]; then
    case "$hw_profile" in
      "linux-generic"|"dev-laptop"|"ci-runner"|"docker-container"|"aarch64-generic")
        # Valid canonical profiles
        ;;
      *)
        warnings+=("Non-canonical hardware_profile: $hw_profile (expected: linux-generic, dev-laptop, ci-runner, docker-container, aarch64-generic)")
        ;;
    esac
  fi

  # Validate commit SHAs format
  for sha_field in "benchmark_commit_sha" "target_commit_sha"; do
    local sha=$(jq -r ".${sha_field} // empty" "$metadata_file" 2>/dev/null)
    if [[ -n "$sha" && "$sha" != "unknown" ]]; then
      if ! [[ "$sha" =~ ^[a-f0-9]{40}$ ]]; then
        errors+=("Invalid commit SHA format in $sha_field: $sha")
      fi
    fi
  done

  local valid="true"
  [[ ${#errors[@]} -gt 0 ]] && valid="false"

  # Format response
  local errors_str=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  local warnings_str=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)

  cat <<EOF
{
  "valid": $valid,
  "errors": $errors_str,
  "warnings": $warnings_str
}
EOF
}

# ============================================================================
# STATUS CLASSIFICATION
# ============================================================================

# classify_bench_status(bench_rc, postprocess_rc, json_file, jfr_file, metrics_file, log_file)
# classify_bench_status(bench_rc, postprocess_rc, json_file, jfr_file, metrics_file, log_file, expected_case_count)
# Returns JSON with {runner_status, reproducibility_status, reason, json_row_count, log_failure_count, failed_cases, jfr_collected, metrics_collected, artifact_completeness, metrics_warning_count, metrics_warnings}
classify_bench_status() {
  local bench_rc="$1"
  local postprocess_rc="$2"
  local json_file="$3"
  local jfr_file="$4"
  local metrics_file="$5"
  local log_file="$6"
  local expected_case_count="${7:-0}"
  local benchmark_commit_sha="${8:-}"
  local target_commit_sha="${9:-}"
  local jdk_version="${10:-}"
  local hardware_profile="${11:-}"
  local manifest_version="${12:-}"
  local scenario_id="${13:-}"
  local scenario_classification="${14:-}"

  # Canonical value per schemas/benchmark-result.schema.json: failed (not benchmark_failed/postprocess_failed)
  local runner_status="failed"
  local reproducibility_status="complete"
  local reason=""
  local json_count=0
  local log_failures=0
  local failed_cases=0
  local jfr_collected=false
  local metrics_collected=false
  local artifact_completeness="1.00"
  local present_artifacts=0
  local expected_artifacts=4
  local base_path=""
  local cmd_file=""
  local jvm_args_file=""
  local metrics_warnings_json="[]"
  local metrics_warning_count=0

  # Check JSON output for completed cases
  if [[ -s "$json_file" ]]; then
    if command -v jq >/dev/null 2>&1; then
      json_count=$(jq 'length' "$json_file" 2>/dev/null || echo 0)
    else
      json_count=$(grep -c '"benchmark"' "$json_file" 2>/dev/null || true)
      [[ -z "$json_count" ]] && json_count=0
    fi
  fi

  # Check log for failures using scoped patterns to reduce false positives.
  if [[ -f "$log_file" ]]; then
    log_failures=$(grep -Eic 'Benchmark.*(failed|error)|FAIL:' "$log_file" 2>/dev/null || true)
    [[ -z "$log_failures" ]] && log_failures=0
  fi

  # Derive base path for cmd/jvm args artifacts from JSON naming convention.
  if [[ "$json_file" == *"-jmh.json" ]]; then
    base_path="${json_file%-jmh.json}"
  elif [[ "$json_file" == *".json" ]]; then
    base_path="${json_file%.json}"
  fi
  cmd_file="${base_path}.cmd"
  jvm_args_file="${base_path}.jvm-args.txt"

  # Calculate failed_cases formally from expected vs actual
  if [[ $expected_case_count -gt 0 ]]; then
    failed_cases=$((expected_case_count - json_count))
    # Ensure failed_cases is never negative (json_count may exceed iterations due to forking)
    if [[ $failed_cases -lt 0 ]]; then
      failed_cases=0
    fi
  else
    # If expected_case_count not provided, use log_failures as fallback
    failed_cases=$log_failures
  fi

  # Compute artifact completeness as present/expected ratio.
  [[ -s "$log_file" ]] && ((present_artifacts++))
  [[ -s "$json_file" ]] && ((present_artifacts++))
  [[ -s "$cmd_file" ]] && ((present_artifacts++))
  [[ -s "$jvm_args_file" ]] && ((present_artifacts++))

  if [[ -n "$jfr_file" ]]; then
    ((expected_artifacts++))
    if [[ -s "$jfr_file" ]]; then
      jfr_collected=true
      ((present_artifacts++))
    else
      reproducibility_status="incomplete_artifacts"
      reason="JFR file expected but missing"
    fi
  fi

  if [[ -n "$metrics_file" ]]; then
    ((expected_artifacts++))
    if [[ -s "$metrics_file" ]]; then
      metrics_collected=true
      ((present_artifacts++))
    else
      reproducibility_status="incomplete_artifacts"
      if [[ -z "$reason" ]]; then
        reason="Metrics file expected but missing"
      fi
    fi
  fi

  # Extract warnings array from metrics file if it was collected and is valid JSON
  if [[ "$metrics_collected" == "true" ]] && jq empty "$metrics_file" 2>/dev/null; then
    local raw_warn_count
    raw_warn_count=$(jq '(.warnings // []) | length' "$metrics_file" 2>/dev/null || echo "0")
    if [[ "$raw_warn_count" =~ ^[0-9]+$ ]] && [[ "$raw_warn_count" -gt 0 ]]; then
      metrics_warning_count=$raw_warn_count
      metrics_warnings_json=$(jq -c '.warnings // []' "$metrics_file" 2>/dev/null || echo "[]")
    fi
  fi

  artifact_completeness=$(LC_ALL=C awk -v p="$present_artifacts" -v e="$expected_artifacts" 'BEGIN { if (e <= 0) { printf "1.00" } else { printf "%.2f", p / e } }')

  # Runner classification:
  # success: bench_rc=0, json_count>0, failed_cases=0
  # partial: json_count>0 and (bench_rc!=0 or failed_cases>0)
  # failed: json_count=0 and bench_rc!=0, or bench_rc=0 and json_count>0 and postprocess_rc!=0
  # fallback failed otherwise
  if [[ $bench_rc -eq 0 && "$json_count" -gt 0 && $postprocess_rc -ne 0 ]]; then
    # Canonical value per schemas/benchmark-result.schema.json: failed (not benchmark_failed/postprocess_failed)
    runner_status="failed"
    reason="Benchmark completed but postprocessing failed (postprocess_rc=$postprocess_rc)"
  elif [[ $bench_rc -eq 0 && "$json_count" -gt 0 && "$failed_cases" -eq 0 ]]; then
    runner_status="success"
  elif [[ "$json_count" -gt 0 && ($bench_rc -ne 0 || "$failed_cases" -gt 0) ]]; then
    runner_status="partial"
    if [[ $bench_rc -ne 0 ]]; then
      reason="Benchmark exited non-zero with $json_count/$((json_count + failed_cases)) cases completed"
    else
      reason="$failed_cases failures detected in $((json_count + failed_cases)) cases"
    fi
  elif [[ $bench_rc -eq 0 && "$json_count" -eq 0 ]]; then
    # Canonical value per schemas/benchmark-result.schema.json: failed (not benchmark_failed/postprocess_failed)
    runner_status="failed"
    reason="Benchmark returned zero exit code but completed zero cases"
    if [[ $expected_case_count -le 0 && $failed_cases -eq 0 ]]; then
      failed_cases=1
    fi
  elif [[ "$json_count" -eq 0 && $bench_rc -ne 0 ]]; then
    # Canonical value per schemas/benchmark-result.schema.json: failed (not benchmark_failed/postprocess_failed)
    runner_status="failed"
    reason="Benchmark failed with zero cases completed (exit code=$bench_rc)"
    # Preserve formal expected-case math; only fallback to 1 when expected count was unavailable.
    if [[ $expected_case_count -le 0 && $failed_cases -eq 0 ]]; then
      failed_cases=1
    fi
  else
    # Canonical value per schemas/benchmark-result.schema.json: failed (not benchmark_failed/postprocess_failed)
    runner_status="failed"
    reason="Unable to classify status (contract drift: unclassifiable combination)"
  fi

  # Determine reproducibility status with canonical values only.
  if [[ "$runner_status" == "success" ]]; then
    reproducibility_status="complete"
  elif [[ "$runner_status" == "partial" || "$runner_status" == "failed" ]]; then
    reproducibility_status="incomplete_artifacts"
  else
    reproducibility_status="not_assessable"
  fi

  # Propagate metrics warnings as informational reason when run succeeded but reason is still empty
  if [[ "$runner_status" == "success" && "$metrics_warning_count" -gt 0 && -z "$reason" ]]; then
    reason="Metrics reported $metrics_warning_count warning(s)"
  fi

    # Metadata validation: align with schema enum for incomplete_metadata
    # Reference: schemas/benchmark-result.schema.json line 91
    if [[ "$runner_status" == "success" || "$runner_status" == "partial" ]]; then
      if [[ -z "$benchmark_commit_sha" || -z "$target_commit_sha" || -z "$jdk_version" || \
            -z "$hardware_profile" || -z "$manifest_version" || -z "$scenario_id" || \
            -z "$scenario_classification" ]]; then
        reproducibility_status="incomplete_metadata"
        if [[ -z "$reason" ]]; then
          reason="Required reproducibility metadata missing"
        fi
      fi
    fi

  cat <<EOF
{
  "runner_status": "$runner_status",
  "reproducibility_status": "$reproducibility_status",
  "reason": "$reason",
  "json_row_count": $json_count,
  "expected_case_count": $expected_case_count,
  "log_failure_count": $log_failures,
  "failed_cases": $failed_cases,
  "jfr_collected": $jfr_collected,
  "metrics_collected": $metrics_collected,
  "artifact_completeness": $artifact_completeness,
  "metrics_warning_count": $metrics_warning_count,
  "metrics_warnings": $metrics_warnings_json
}
EOF
}

# ============================================================================
# CSV FUNCTIONS
# ============================================================================

# init_status_csv(output_csv) — create status.csv with header
init_status_csv() {
  local output_csv="$1"
  cat > "$output_csv" <<'EOF'
phase,benchmark,runner_status,reproducibility_status,benchmark_exit_code,postprocess_exit_code,headless,completed_cases,failed_cases,artifact_completeness,metrics_warning_count,log,json,jfr,metrics,cmd,jvm_args
EOF
}

# write_status_csv(status_csv, phase, benchmark, runner_status, reproducibility_status, bench_rc, postprocess_rc, headless, completed_cases, failed_cases, artifact_completeness, log, json, jfr, metrics, cmd, jvm_args[, metrics_warning_count])
# metrics_warning_count is optional; defaults to 0 for backward compatibility with existing call sites
# All string fields are CSV-escaped to prevent corruption from special characters
write_status_csv() {
  local status_csv="$1"
  local phase="$2"
  local benchmark="$3"
  local runner_status="$4"
  local reproducibility_status="$5"
  local bench_rc="$6"
  local postprocess_rc="$7"
  local headless="$8"
  local completed_cases="$9"
  local failed_cases="${10}"
  local artifact_completeness="${11}"
  local log="${12}"
  local json="${13}"
  local jfr="${14}"
  local metrics="${15}"
  local cmd="${16}"
  local jvm_args="${17}"
  local metrics_warning_count="${18:-0}"

  # Escape all string fields that might contain commas, quotes, or newlines
  local escaped_phase=$(escape_csv_field "$phase")
  local escaped_benchmark=$(escape_csv_field "$benchmark")
  local escaped_runner_status=$(escape_csv_field "$runner_status")
  local escaped_reproducibility_status=$(escape_csv_field "$reproducibility_status")
  local escaped_log=$(escape_csv_field "$log")
  local escaped_json=$(escape_csv_field "$json")
  local escaped_jfr=$(escape_csv_field "$jfr")
  local escaped_metrics=$(escape_csv_field "$metrics")
  local escaped_cmd=$(escape_csv_field "$cmd")
  local escaped_jvm_args=$(escape_csv_field "$jvm_args")

  echo "$escaped_phase,$escaped_benchmark,$escaped_runner_status,$escaped_reproducibility_status,$bench_rc,$postprocess_rc,$headless,$completed_cases,$failed_cases,$artifact_completeness,$metrics_warning_count,$escaped_log,$escaped_json,$escaped_jfr,$escaped_metrics,$escaped_cmd,$escaped_jvm_args" >> "$status_csv"
}

# ============================================================================
# METADATA FUNCTIONS
# ============================================================================

# write_reproducibility_metadata(output_json, benchmark_id, tier, phase, implementation_variant, family, benchmark_commit_sha, target_commit_sha, jdk_vendor, jdk_version, jvm_flags_json, hardware_profile, manifest_version, scenario_id, scenario_classification, wiring_model)
write_reproducibility_metadata() {
  local output_json="$1"
  local benchmark_id="$2"
  local tier="$3"
  local phase="$4"
  local implementation_variant="$5"
  local family="$6"
  local benchmark_commit_sha="$7"
  local target_commit_sha="$8"
  local jdk_vendor="$9"
  local jdk_version="${10}"
  local jvm_flags_json="${11}"
  local hardware_profile="${12}"
  local manifest_version="${13}"
  local scenario_id="${14}"
  local scenario_classification="${15}"
  local wiring_model="${16:-}"

  # Ensure hardware_profile is canonical or default
  if [[ -z "$hardware_profile" || "$hardware_profile" == "linux-generic" ]]; then
    hardware_profile="linux-generic"
  fi

  jq -n \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg benchmark_id "$benchmark_id" \
    --arg tier "$tier" \
    --arg phase "$phase" \
    --arg implementation_variant "$implementation_variant" \
    --arg family "$family" \
    --arg benchmark_commit_sha "$benchmark_commit_sha" \
    --arg target_commit_sha "$target_commit_sha" \
    --arg jdk_vendor "$jdk_vendor" \
    --arg jdk_version "$jdk_version" \
    --arg hardware_profile "$hardware_profile" \
    --arg manifest_version "$manifest_version" \
    --arg scenario_id "$scenario_id" \
    --arg scenario_classification "$scenario_classification" \
    --arg wiring_model "$wiring_model" \
    --argjson jvm_flags "$jvm_flags_json" \
    '{
      timestamp: $timestamp,
      benchmark_id: $benchmark_id,
      tier: $tier,
      phase: $phase,
      implementation_variant: $implementation_variant,
      family: $family,
      benchmark_commit_sha: $benchmark_commit_sha,
      target_commit_sha: $target_commit_sha,
      jdk_vendor: $jdk_vendor,
      jdk_version: $jdk_version,
      jvm_flags: $jvm_flags,
      hardware_profile: $hardware_profile,
      manifest_version: $manifest_version,
      scenario_id: $scenario_id,
      scenario_classification: $scenario_classification
    } + (if $wiring_model == "" then {} else {wiring_model: $wiring_model} end)' > "$output_json"
}
