#!/usr/bin/env bash
set -euo pipefail

REPEATS=5
CAMPAIGN_DIR="results/raw/entity-read-by-id/$(date +%Y%m%d-%H%M%S)-campaign"

require_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    echo "ERROR: $name must be a positive integer (got: $value)"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeats)
      REPEATS="$2"
      shift 2
      ;;
    --output-dir)
      CAMPAIGN_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

require_positive_int "--repeats" "$REPEATS"

mkdir -p "$CAMPAIGN_DIR"
STATUS_FILE="$CAMPAIGN_DIR/status.csv"

echo "run_label,run_dir,runner_status,reproducibility_status,final_reason,claim_scope,json_present,benchmark_id,benchmark_exit_code,postprocess_exit_code,json_row_count" > "$STATUS_FILE"

any_fail=0

for i in $(seq 1 "$REPEATS"); do
  run_label="repeat-$i"
  run_dir="$CAMPAIGN_DIR/$run_label"
  mkdir -p "$run_dir"

  benchmark_exit_code=0
  if ./scripts/run-entity-read-by-id.sh \
    --contract fixed_contract_v1 \
    --claim-scope comparison-eligible \
    --profile perf-box-amd64 \
    --output-dir "$run_dir"; then
    benchmark_exit_code=0
  else
    benchmark_exit_code=$?
  fi

  result_file="$run_dir/result.json"
  repro_file="$run_dir/reproducibility-metadata.json"
  steady_file="$run_dir/steady-state-evidence.json"

  json_present="false"
  json_row_count=0
  json_valid=0
  json_claim_scope="none"

  if [[ -f "$result_file" ]]; then
    json_present="true"
    if jq -e . "$result_file" >/dev/null 2>&1; then
      json_valid=1
      json_row_count=1
      json_claim_scope="$(jq -r '.claim_scope // "none"' "$result_file")"
    fi
  fi

  repro_valid=0
  if [[ -f "$repro_file" ]] && jq -e . "$repro_file" >/dev/null 2>&1; then
    repro_valid=1
  fi

  steady_valid=0
  if [[ -f "$steady_file" ]] && jq -e . "$steady_file" >/dev/null 2>&1; then
    steady_valid=1
  fi

  runner_status="failed"
  if [[ "$benchmark_exit_code" -eq 0 ]] && [[ "$json_valid" -eq 1 ]]; then
    runner_status="success"
  elif [[ "$json_valid" -eq 1 ]]; then
    runner_status="partial"
  fi

  reproducibility_status="not_assessable"
  if [[ "$runner_status" != "failed" ]]; then
    if [[ "$repro_valid" -ne 1 ]]; then
      reproducibility_status="incomplete_metadata"
    elif [[ "$steady_valid" -ne 1 ]]; then
      reproducibility_status="incomplete_artifacts"
    else
      reproducibility_status="complete"
    fi
  fi

  final_reason="ok"
  if [[ "$json_present" != "true" ]] && [[ "$benchmark_exit_code" -ne 0 ]]; then
    final_reason="benchmark_exit_nonzero"
  elif [[ "$json_present" != "true" ]] && [[ "$benchmark_exit_code" -eq 0 ]]; then
    final_reason="empty_json"
  elif [[ "$json_valid" -ne 1 ]]; then
    final_reason="invalid_json"
  elif [[ "$runner_status" == "partial" ]] && [[ "$benchmark_exit_code" -ne 0 ]]; then
    final_reason="partial_json"
  elif [[ "$reproducibility_status" == "incomplete_metadata" ]]; then
    final_reason="missing_metadata"
  elif [[ "$reproducibility_status" == "incomplete_artifacts" ]]; then
    final_reason="missing_metrics"
  elif [[ "$benchmark_exit_code" -ne 0 ]]; then
    final_reason="benchmark_exit_nonzero"
  fi

  claim_scope="none"
  if [[ "$final_reason" == "ok" ]]; then
    if [[ "$json_claim_scope" == "comparison_eligible" ]]; then
      claim_scope="comparison_eligible"
    else
      claim_scope="descriptive_only"
    fi
  elif [[ "$runner_status" == "partial" ]]; then
    claim_scope="descriptive_partial"
  fi

  postprocess_exit_code=0
  if [[ "$reproducibility_status" != "complete" ]]; then
    postprocess_exit_code=1
  fi

  echo "$run_label,$run_dir,$runner_status,$reproducibility_status,$final_reason,$claim_scope,$json_present,$run_label,$benchmark_exit_code,$postprocess_exit_code,$json_row_count" >> "$STATUS_FILE"

  if [[ "$final_reason" != "ok" ]] || [[ "$claim_scope" != "comparison_eligible" ]]; then
    any_fail=1
  fi
done

schema_ok=1
for required_column in runner_status reproducibility_status final_reason claim_scope benchmark_exit_code postprocess_exit_code json_row_count benchmark_id; do
  if ! head -1 "$STATUS_FILE" | tr ',' '\n' | grep -Fxq "$required_column"; then
    schema_ok=0
    break
  fi
done

if [[ "$schema_ok" -eq 1 ]]; then
  if ! ./tools/verify-classification.sh "$STATUS_FILE"; then
    any_fail=1
  fi
else
  echo "WARN: status.csv schema does not match verify-classification expectations; using local validation only"
  any_fail=1
fi

if [[ "$any_fail" -ne 0 ]]; then
  echo "Campaign failed. See $STATUS_FILE"
  exit 1
fi

echo "Campaign succeeded. status.csv: $STATUS_FILE"
