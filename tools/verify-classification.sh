#!/bin/bash
#
# verify-classification.sh — Enforce that every status.csv row has valid/consistent classification.
#
# CRITICAL: This script MUST run after every status.csv generation.
# It validates that:
# - No partial/empty runs have claim_scope="comparison_eligible"
# - All final_reason codes are exactly defined
# - All claim_scope values are derived correctly from runner/repro/reason
# - No invalid combinations exist
#
set -euo pipefail

CSV_FILE="${1:-.}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
ROWS_CHECKED=0
ROWS_VALID=0
ROWS_INVALID=0

# Valid enum values
VALID_RUNNER_STATUS=("success" "partial" "failed")
VALID_REPRO_STATUS=("complete" "incomplete_artifacts" "incomplete_metadata" "not_assessable")
VALID_FINAL_REASON=("ok" "partial_json" "empty_json" "invalid_json" "benchmark_exit_nonzero" "postprocess_exit_nonzero" "missing_jfr" "missing_metrics" "missing_metadata")
VALID_CLAIM_SCOPE=("comparison_eligible" "descriptive_partial" "descriptive_only" "none")
LEGACY_CLAIM_SCOPE=("eligible" "comparison" "comparative" "descriptive" "partial" "ineligible" "not_eligible" "not_comparison_eligible" "no_claims")

error_count=0

log_error() {
  echo -e "${RED}ERROR${NC}: $*" >&2
  ((error_count++))
}

log_warn() {
  echo -e "${YELLOW}WARN${NC}: $*" >&2
}

log_ok() {
  echo -e "${GREEN}✓${NC} $*"
}

# Validate enum value
is_valid_enum() {
  local value="$1"
  shift
  local -a valid_values=("$@")
  
  for v in "${valid_values[@]}"; do
    [[ "$v" == "$value" ]] && return 0
  done
  return 1
}

is_legacy_claim_scope() {
  local value="$1"
  local legacy
  for legacy in "${LEGACY_CLAIM_SCOPE[@]}"; do
    [[ "$legacy" == "$value" ]] && return 0
  done
  return 1
}

# ============================================================
# gc.alloc.rate.norm threshold guard (JMH zero-alloc validation)
# Usage: check_alloc_rate_norm <jmh-result.json>
#   ALLOC_NORM_THRESHOLD_BYTES — threshold in bytes/op (default: 0)
#   ZERO_ALLOC_BENCH_PATTERN  — optional regex to filter benchmark names
# ============================================================
check_alloc_rate_norm() {
  local jmh_result_file="$1"
  local threshold_bytes="${ALLOC_NORM_THRESHOLD_BYTES:-0}"
  local pattern="${ZERO_ALLOC_BENCH_PATTERN:-}"
  local violations=0

  [[ -f "$jmh_result_file" ]] || {
    log_warn "alloc-norm check: file not found: $jmh_result_file"
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    log_warn "alloc-norm check: jq not found, skipping"
    return 0
  }

  while IFS= read -r bench_name; do
    if [[ -n "$pattern" ]] && ! [[ "$bench_name" =~ $pattern ]]; then
      continue
    fi
    local alloc_norm
    alloc_norm=$(jq -r --arg b "$bench_name" \
      '.[] | select(.benchmark == $b) | .secondaryMetrics["·gc.alloc.rate.norm"].score // empty' \
      "$jmh_result_file" 2>/dev/null | head -1)
    if [[ -z "$alloc_norm" ]]; then
      continue
    fi
    local exceeds
    exceeds=$(awk -v val="$alloc_norm" -v thr="$threshold_bytes" \
      'BEGIN{print (val+0 > thr+0) ? "yes" : "no"}')
    if [[ "$exceeds" == "yes" ]]; then
      log_error "BLOCKING: gc.alloc.rate.norm = ${alloc_norm} B/op exceeds threshold ${threshold_bytes} B/op on: $bench_name"
      ((violations++)) || true
    else
      log_ok "alloc.rate.norm OK: $bench_name = ${alloc_norm} B/op (≤ ${threshold_bytes} B/op)"
    fi
  done < <(jq -r '.[].benchmark' "$jmh_result_file" 2>/dev/null)

  return $violations
}

# Validate a single CSV row
validate_row() {
  local row_num="$1"
  local runner_status="$2"
  local repro_status="$3"
  local final_reason="$4"
  local claim_scope="$5"
  local bench_rc="$6"
  local pp_rc="$7"
  local json_rows="$8"
  local benchmark_id="$9"

  ((ROWS_CHECKED++))
  local row_errors=0

  # Validate enum values
  if ! is_valid_enum "$runner_status" "${VALID_RUNNER_STATUS[@]}"; then
    log_error "Row $row_num: invalid runner_status='$runner_status' (must be one of: ${VALID_RUNNER_STATUS[*]})"
    ((row_errors++))
  fi

  if ! is_valid_enum "$repro_status" "${VALID_REPRO_STATUS[@]}"; then
    log_error "Row $row_num: invalid reproducibility_status='$repro_status' (must be one of: ${VALID_REPRO_STATUS[*]})"
    ((row_errors++))
  fi

  if ! is_valid_enum "$final_reason" "${VALID_FINAL_REASON[@]}"; then
    log_error "Row $row_num: invalid final_reason='$final_reason' (must be one of: ${VALID_FINAL_REASON[*]})"
    ((row_errors++))
  fi

  if ! is_valid_enum "$claim_scope" "${VALID_CLAIM_SCOPE[@]}"; then
    if is_legacy_claim_scope "$claim_scope"; then
      log_error "Row $row_num ($benchmark_id): legacy claim_scope synonym '$claim_scope' is not accepted; use canonical claim_scope values only: ${VALID_CLAIM_SCOPE[*]}"
    else
      log_error "Row $row_num ($benchmark_id): invalid claim_scope='$claim_scope' (must be one of: ${VALID_CLAIM_SCOPE[*]})"
    fi
    ((row_errors++))
  fi

  # HARD RULE 1: If runner=success, claim_scope must NOT be "none"
  if [[ "$runner_status" == "success" ]] && [[ "$claim_scope" == "none" ]]; then
    log_error "Row $row_num ($benchmark_id): runner_status=success but claim_scope=none (violation)"
    ((row_errors++))
  fi

  # HARD RULE 2: If runner=failed, claim_scope MUST be "none"
  if [[ "$runner_status" == "failed" ]] && [[ "$claim_scope" != "none" ]]; then
    log_error "Row $row_num ($benchmark_id): runner_status=failed but claim_scope=$claim_scope (must be none)"
    ((row_errors++))
  fi

  # HARD RULE 3: If json_rows=0, runner_status MUST be "failed"
  if [[ "$json_rows" -eq 0 ]] && [[ "$runner_status" != "failed" ]]; then
    log_error "Row $row_num ($benchmark_id): json_rows=0 but runner_status=$runner_status (must be failed)"
    ((row_errors++))
  fi

  # HARD RULE 4: If final_reason=ok, runner MUST be success AND repro MUST be complete
  if [[ "$final_reason" == "ok" ]]; then
    if [[ "$runner_status" != "success" ]]; then
      log_error "Row $row_num ($benchmark_id): final_reason=ok requires runner_status=success, got $runner_status"
      ((row_errors++))
    fi
    if [[ "$repro_status" != "complete" ]]; then
      log_error "Row $row_num ($benchmark_id): final_reason=ok requires reproducibility_status=complete, got $repro_status"
      ((row_errors++))
    fi
  fi

  # HARD RULE 5: If claim_scope=comparison_eligible, MUST have final_reason=ok
  if [[ "$claim_scope" == "comparison_eligible" ]]; then
    if [[ "$final_reason" != "ok" ]]; then
      log_error "Row $row_num ($benchmark_id): claim_scope=comparison_eligible requires final_reason=ok, got $final_reason"
      ((row_errors++))
    fi
    if [[ "$runner_status" != "success" ]]; then
      log_error "Row $row_num ($benchmark_id): claim_scope=comparison_eligible requires runner_status=success, got $runner_status"
      ((row_errors++))
    fi
    if [[ "$repro_status" != "complete" ]]; then
      log_error "Row $row_num ($benchmark_id): claim_scope=comparison_eligible requires reproducibility_status=complete, got $repro_status"
      ((row_errors++))
    fi
  fi

  # HARD RULE 6: If runner=failed, repro_status MUST be "not_assessable"
  if [[ "$runner_status" == "failed" ]] && [[ "$repro_status" != "not_assessable" ]]; then
    log_error "Row $row_num ($benchmark_id): runner_status=failed requires reproducibility_status=not_assessable, got $repro_status"
    ((row_errors++))
  fi

  # Additional semantic checks
  # HARD RULE 7: partial_json requires runner=partial
  if [[ "$final_reason" == "partial_json" ]] && [[ "$runner_status" != "partial" ]]; then
    log_error "Row $row_num ($benchmark_id): final_reason=partial_json requires runner_status=partial, got $runner_status"
    ((row_errors++))
  fi

  # HARD RULE 8: empty_json / invalid_json / benchmark_exit_nonzero require runner=failed
  if [[ "$final_reason" =~ ^(empty_json|invalid_json|benchmark_exit_nonzero)$ ]] && [[ "$runner_status" != "failed" ]]; then
    log_error "Row $row_num ($benchmark_id): final_reason=$final_reason requires runner_status=failed, got $runner_status"
    ((row_errors++))
  fi

  # HARD RULE 9: postprocess_exit_nonzero can only occur with runner=partial
  if [[ "$final_reason" == "postprocess_exit_nonzero" ]] && [[ "$runner_status" != "partial" ]]; then
    log_error "Row $row_num ($benchmark_id): final_reason=postprocess_exit_nonzero requires runner_status=partial, got $runner_status"
    ((row_errors++))
  fi

  # HARD RULE 10: missing_* reasons require reproducibility_status=incomplete_*
  if [[ "$final_reason" =~ ^missing_ ]] && [[ ! "$repro_status" =~ ^incomplete ]]; then
    log_error "Row $row_num ($benchmark_id): final_reason=$final_reason requires reproducibility_status to be incomplete_*, got $repro_status"
    ((row_errors++))
  fi

  if [[ $row_errors -eq 0 ]]; then
    ((ROWS_VALID++))
    return 0
  else
    ((ROWS_INVALID++))
    return 1
  fi
}

# Main entry point
main() {
  if [[ "${1:-}" == "--check-alloc-norm" ]]; then
    JMH_RESULT_FILE="${2:?Usage: $0 --check-alloc-norm <jmh-result.json>}"
    check_alloc_rate_norm "$JMH_RESULT_FILE"
    exit $?
  fi

  if [[ "$CSV_FILE" == "." ]]; then
    # Find status.csv in current directory
    if [[ -f "status.csv" ]]; then
      CSV_FILE="status.csv"
    else
      echo "Usage: $0 <path-to-status.csv>"
      echo "  or run from directory containing status.csv"
      exit 1
    fi
  fi

  if [[ ! -f "$CSV_FILE" ]]; then
    log_error "File not found: $CSV_FILE"
    exit 1
  fi

  echo "Verifying classification in: $CSV_FILE"
  echo

  # Read header to get column indices
  local header
  header=$(head -1 "$CSV_FILE")
  local -a headers
  IFS=, read -ra headers <<< "$header"

  # Find column indices
  local idx_runner_status idx_repro_status idx_final_reason idx_claim_scope
  local idx_bench_rc idx_pp_rc idx_json_rows idx_benchmark_id
  
  for i in "${!headers[@]}"; do
    case "${headers[$i]}" in
      runner_status) idx_runner_status=$i ;;
      reproducibility_status) idx_repro_status=$i ;;
      final_reason) idx_final_reason=$i ;;
      claim_scope) idx_claim_scope=$i ;;
      benchmark_exit_code) idx_bench_rc=$i ;;
      postprocess_exit_code) idx_pp_rc=$i ;;
      json_row_count) idx_json_rows=$i ;;
      benchmark_id) idx_benchmark_id=$i ;;
    esac
  done

  # Validate each row
  local row_num=1
  while IFS=, read -ra fields; do
    ((row_num++))
    
    validate_row "$row_num" \
      "${fields[$idx_runner_status]}" \
      "${fields[$idx_repro_status]}" \
      "${fields[$idx_final_reason]}" \
      "${fields[$idx_claim_scope]}" \
      "${fields[$idx_bench_rc]}" \
      "${fields[$idx_pp_rc]}" \
      "${fields[$idx_json_rows]}" \
      "${fields[$idx_benchmark_id]}" \
      || true
  done < <(tail -n +2 "$CSV_FILE")

  # Summary
  echo
  echo "=========================================="
  echo "Classification Validation Summary"
  echo "=========================================="
  echo "Rows checked:  $ROWS_CHECKED"
  echo -e "Rows valid:    ${GREEN}$ROWS_VALID${NC}"
  echo -e "Rows invalid:  ${RED}$ROWS_INVALID${NC}"
  echo

  if [[ $error_count -gt 0 ]]; then
    echo -e "${RED}FAILED: $error_count error(s) found${NC}"
    exit 1
  else
    log_ok "All rows validated successfully"
    exit 0
  fi
}

main "$@"
