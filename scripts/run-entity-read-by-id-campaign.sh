#!/usr/bin/env bash
set -euo pipefail

REPEATS=5
CAMPAIGN_DIR="results/raw/entity-read-by-id/$(date +%Y%m%d-%H%M%S)-campaign"
CPU_AFFINITY=""
REQUIRE_PERF_STAT=0
MODES=("default-vt" "locality-aware")
LOCALITY_MODE_ENABLED="${BENCHMARK_ENABLE_LOCALITY_MODE:-0}"
BENCHMARK_LOCALITY_STRICT="${BENCHMARK_LOCALITY_STRICT:-0}"
MODE="backend-mode"
SCENARIO_ID="entity-read-by-id"
CONTRACT_ID="fixed_contract_backend_mode_h1_v1"
MEASUREMENT_SECONDS="${MEASUREMENT_SECONDS:-60}"
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"

require_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    echo "ERROR: $name must be a positive integer (got: $value)"
    exit 1
  fi
}

require_value() {
  local flag_name="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "ERROR: $flag_name requires a value"
    exit 1
  fi
}

campaign_constrained_contract_id() {
  local contract_id="${1:-}"
  [[ -n "$contract_id" && ( "$contract_id" == fixed_contract_runtime_h1_constrained* || "$contract_id" == *_constrained_* ) ]]
}

campaign_constrained_execution_profile_id() {
  local execution_profile_id="${1:-}"
  [[ -n "$execution_profile_id" && "$execution_profile_id" == runtime-constrained-* ]]
}

campaign_constrained_track_id() {
  local track_id="${1:-}"
  [[ -n "$track_id" && "$track_id" == track-c* ]]
}

campaign_constrained_path() {
  local path_value="${1:-}"
  [[ -n "$path_value" && ( "$path_value" == */results/constrained/* || "$path_value" == results/constrained/* ) ]]
}

campaign_fail_closed_if_constrained() {
  if campaign_constrained_contract_id "$CONTRACT_ID" || \
     campaign_constrained_execution_profile_id "${BENCHMARK_EXECUTION_PROFILE_ID:-}" || \
     campaign_constrained_track_id "${BENCHMARK_TRACK_ID:-}" || \
     campaign_constrained_path "$CAMPAIGN_DIR"; then
    echo "ERROR: standard campaign script is not valid for constrained exploratory runs" >&2
    exit 1
  fi
}

derive_mode_stats() {
  local status_file="$1"
  local mode="$2"

  LC_ALL=C awk -F',' -v m="$mode" '
    BEGIN {
      rows = 0
      sum_requests = 0
      n_success = 0
      sum = 0
      sumsq = 0
      claim_ok = 1
      perf_all_true = 1
      min_rps_floor_pass = "false"
    }

    NR == 1 { next }

    $10 == m {
      rows++
      sum_requests += ($13 + 0)

      if ($4 != "comparison_eligible") {
        claim_ok = 0
      }
      if ($15 != "true") {
        perf_all_true = 0
      }

      if ($1 == "success") {
        x = ($14 + 0)
        n_success++
        sum += x
        sumsq += (x * x)
      }
    }

    END {
      mean = 0
      stddev = 0
      ci95_half_width = 0
      relative_error_pct = 999999

      if (n_success > 0) {
        mean = sum / n_success
      }

      if (n_success > 1) {
        variance = (sumsq - (n_success * mean * mean)) / (n_success - 1)
        if (variance < 0 && variance > -1e-9) {
          variance = 0
        }
        if (variance > 0) {
          stddev = sqrt(variance)
        }
      }

      if (n_success > 0) {
        ci95_half_width = 1.96 * stddev / sqrt(n_success)
      }

      if (mean > 0) {
        relative_error_pct = (ci95_half_width / mean) * 100
      }

      min_samples_pass = "false"
      ci_gate_pass = "false"
      claim_scope_pass = "false"
      perf_all_true_str = "false"

      if (sum_requests >= 600) {
        min_samples_pass = "true"
      }
      if (n_success >= 3 && mean > 0 && relative_error_pct <= 10) {
        ci_gate_pass = "true"
      }
      if (rows > 0 && claim_ok == 1) {
        claim_scope_pass = "true"
      }
      if (rows > 0 && perf_all_true == 1) {
        perf_all_true_str = "true"
      }

      if (n_success > 0 && mean >= 500) {
        min_rps_floor_pass = "true"
      }

      printf "%d|%.0f|%d|%.6f|%.6f|%.6f|%.6f|%s|%s|%s|%s|%s\n", \
        rows, \
        sum_requests, \
        n_success, \
        mean, \
        stddev, \
        ci95_half_width, \
        relative_error_pct, \
        min_samples_pass, \
        ci_gate_pass, \
        claim_scope_pass, \
        perf_all_true_str, \
        min_rps_floor_pass
    }
  ' "$status_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      require_value "$1" "${2:-}"
      MODE="$2"
      shift 2
      ;;
    --scenario-id)
      require_value "$1" "${2:-}"
      SCENARIO_ID="$2"
      shift 2
      ;;
    --contract-id)
      require_value "$1" "${2:-}"
      CONTRACT_ID="$2"
      shift 2
      ;;
    --measurement-seconds)
      require_value "$1" "${2:-}"
      MEASUREMENT_SECONDS="$2"
      shift 2
      ;;
    --warmup-seconds)
      require_value "$1" "${2:-}"
      WARMUP_SECONDS="$2"
      shift 2
      ;;
    --repeats)
      require_value "$1" "${2:-}"
      REPEATS="$2"
      shift 2
      ;;
    --output-dir)
      require_value "$1" "${2:-}"
      CAMPAIGN_DIR="$2"
      shift 2
      ;;
    --cpu-affinity)
      require_value "$1" "${2:-}"
      CPU_AFFINITY="$2"
      shift 2
      ;;
    --require-perf-stat)
      REQUIRE_PERF_STAT=1
      shift
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

campaign_fail_closed_if_constrained

require_positive_int "--repeats" "$REPEATS"

if [[ "$MODE" != "backend-mode" && "$MODE" != "pairwise-runtime" ]]; then
  echo "ERROR: --mode must be one of: backend-mode, pairwise-runtime (got: $MODE)"
  exit 1
fi

run_pairwise_runtime_campaign() {
  local status_file summary_file any_fail
  local pair_id target_a target_b pair_dir order completed_orders run_dir rc
  local -a pairs

  pairs=(
    "exeris-benchmark-app-community-h1__spring-jvm-vt-tuned|exeris-benchmark-app-community-h1|spring-jvm-vt-tuned"
    "exeris-benchmark-app-community-h1__quarkus-jvm-vt-tuned|exeris-benchmark-app-community-h1|quarkus-jvm-vt-tuned"
    "spring-jvm-vt-tuned__quarkus-jvm-vt-tuned|spring-jvm-vt-tuned|quarkus-jvm-vt-tuned"
  )

  mkdir -p "$CAMPAIGN_DIR"
  status_file="$CAMPAIGN_DIR/pairwise-status.csv"
  summary_file="$CAMPAIGN_DIR/pairwise-summary.json"
  any_fail=0

  echo "pair_id,pair_order,target_a,target_b,ab_ba_orders_completed,exit_code,run_dir" > "$status_file"

  for pair in "${pairs[@]}"; do
    IFS='|' read -r pair_id target_a target_b <<< "$pair"
    pair_dir="$CAMPAIGN_DIR/$pair_id"
    mkdir -p "$pair_dir"

    for order in ab ba; do
      completed_orders="$order"
      if [[ "$order" == "ba" ]]; then
        completed_orders="ab,ba"
      fi

      run_dir="$pair_dir/$order"
      mkdir -p "$run_dir"

      set +e
      BENCHMARK_PAIR_ID="$pair_id" \
      BENCHMARK_PAIR_ORDER="$order" \
      BENCHMARK_AB_BA_ORDERS_COMPLETED="$completed_orders" \
      ./scripts/run-comparative.sh \
        --target-a "$target_a" \
        --target-b "$target_b" \
        --scenario-id "$SCENARIO_ID" \
        --contract-id fixed_contract_cross_runtime_h1_v1 \
        --measurement-seconds "$MEASUREMENT_SECONDS" \
        --warmup-seconds "$WARMUP_SECONDS" \
        --output-dir "$run_dir"
      rc=$?
      set -e
      if [[ "$rc" -ne 0 ]]; then
        any_fail=1
      fi

      echo "$pair_id,$order,$target_a,$target_b,$completed_orders,$rc,$run_dir" >> "$status_file"
    done
  done

  jq -n \
    --arg mode "$MODE" \
    --arg scenario_id "$SCENARIO_ID" \
    --arg contract_id "fixed_contract_cross_runtime_h1_v1" \
    --arg status_csv "$status_file" \
    --argjson all_passed "$( [[ "$any_fail" -eq 0 ]] && echo true || echo false )" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schema_version: "1",
      mode: $mode,
      scenario_id: $scenario_id,
      contract_id: $contract_id,
      generated_at: $generated_at,
      status_csv: $status_csv,
      all_passed: $all_passed
    }' > "$summary_file"

  if [[ "$any_fail" -ne 0 ]]; then
    echo "Pairwise runtime campaign failed. See $status_file and $summary_file"
    return 1
  fi

  echo "Pairwise runtime campaign succeeded. status.csv: $status_file"
  echo "Pairwise summary: $summary_file"
  return 0
}

if [[ "$MODE" == "pairwise-runtime" ]]; then
  run_pairwise_runtime_campaign
  exit $?
fi

if [[ -z "$CPU_AFFINITY" ]]; then
  echo "ERROR: Phase A comparison requires --cpu-affinity"
  exit 1
fi

if [[ "$LOCALITY_MODE_ENABLED" != "0" && "$LOCALITY_MODE_ENABLED" != "1" ]]; then
  echo "ERROR: BENCHMARK_ENABLE_LOCALITY_MODE must be 0 or 1 (got: $LOCALITY_MODE_ENABLED)"
  exit 1
fi

if [[ "$BENCHMARK_LOCALITY_STRICT" != "0" && "$BENCHMARK_LOCALITY_STRICT" != "1" ]]; then
  echo "ERROR: BENCHMARK_LOCALITY_STRICT must be 0 or 1 (got: $BENCHMARK_LOCALITY_STRICT)"
  exit 1
fi

if [[ "$BENCHMARK_LOCALITY_STRICT" == "1" ]] && [[ "$LOCALITY_MODE_ENABLED" != "1" ]]; then
  echo "ERROR: Phase A mode-comparison in strict locality mode requires BENCHMARK_ENABLE_LOCALITY_MODE=1."
  echo "       Unset BENCHMARK_LOCALITY_STRICT or set BENCHMARK_ENABLE_LOCALITY_MODE=1."
  exit 1
fi
if [[ "$BENCHMARK_LOCALITY_STRICT" == "0" ]]; then
  echo "WARN: [locality] Running Phase A with non-strict locality (BENCHMARK_LOCALITY_STRICT=0); VT scheduler override may fall back to default scheduler."
fi

mkdir -p "$CAMPAIGN_DIR"
STATUS_FILE="$CAMPAIGN_DIR/status.csv"
SUMMARY_FILE="$CAMPAIGN_DIR/comparative-summary.json"

echo "runner_status,reproducibility_status,final_reason,claim_scope,benchmark_exit_code,postprocess_exit_code,json_row_count,benchmark_id,run_label,backend_mode,run_dir,json_present,total_requests,throughput_rps,perf_stat_present" > "$STATUS_FILE"

any_fail=0

echo "Campaign config: repeats=$REPEATS cpu_affinity=$CPU_AFFINITY require_perf_stat=$REQUIRE_PERF_STAT"

# --- Campaign preflight: validate toolchain and artifacts before committing to full repeats
echo "[preflight] Validating campaign prerequisites..."
COMMUNITY_JAR_PREFLIGHT=$(ls -1 "$HOME"/.m2/repository/eu/exeris/exeris-kernel-community/*/exeris-kernel-community-*.jar 2>/dev/null | sort | tail -n 1 || true)
if [[ -z "$COMMUNITY_JAR_PREFLIGHT" ]]; then
  echo "ERROR: [preflight] exeris-kernel-community jar not found in ~/.m2; install it before running campaign"
  exit 1
fi
if ! command -v taskset >/dev/null 2>&1; then
  echo "ERROR: [preflight] taskset is required for --cpu-affinity '$CPU_AFFINITY'"
  exit 1
fi
if ! command -v wrk >/dev/null 2>&1; then
  echo "ERROR: [preflight] wrk is required"
  exit 1
fi
if [[ "$REQUIRE_PERF_STAT" -eq 1 ]] && ! command -v perf >/dev/null 2>&1; then
  echo "ERROR: [preflight] perf is required when REQUIRE_PERF_STAT=1"
  exit 1
fi
if [[ "$REQUIRE_PERF_STAT" -eq 1 ]]; then
  set +e
  PERF_PROBE_OUT=$(perf stat -x, -e task-clock -- true 2>&1)
  PERF_PROBE_EXIT_CODE=$?
  set -e
  if [[ "$PERF_PROBE_EXIT_CODE" -ne 0 ]]; then
    echo "ERROR: [preflight] perf usability probe failed (exit_code=$PERF_PROBE_EXIT_CODE)"
    echo "ERROR: [preflight] perf probe output:"
    echo "$PERF_PROBE_OUT"
    exit 1
  fi
  echo "[preflight] perf probe OK"
fi
if [[ ! -d "targets/exeris-community-app-locality/target" ]]; then
  echo "[preflight] WARN: targets/exeris-community-app-locality/target not found; jar build may happen on first run"
fi
echo "[preflight] modes=${MODES[*]} repeats=$REPEATS cpu_affinity=$CPU_AFFINITY"
echo "[preflight] locality_mode_enabled=$LOCALITY_MODE_ENABLED locality_strict=$BENCHMARK_LOCALITY_STRICT"
echo "[preflight] community_jar=$(basename "$COMMUNITY_JAR_PREFLIGHT")"
echo "[preflight] Prerequisites OK"

for backend_mode in "${MODES[@]}"; do
  for i in $(seq 1 "$REPEATS"); do
    run_label="${backend_mode}-repeat-$i"
    benchmark_id="${backend_mode}-repeat-$i"
    run_dir="$CAMPAIGN_DIR/$run_label"
    mkdir -p "$run_dir"

    benchmark_exit_code=0
    run_cmd=(./scripts/run-entity-read-by-id.sh
      --contract fixed_contract_backend_mode_h1_v1
      --claim-scope comparison-eligible
      --profile perf-box-amd64
      --backend-mode "$backend_mode"
      --output-dir "$run_dir")

    if [[ -n "$CPU_AFFINITY" ]]; then
      run_cmd+=(--cpu-affinity "$CPU_AFFINITY")
    fi

    if [[ "$REQUIRE_PERF_STAT" -eq 1 ]]; then
      if BENCHMARK_REQUIRE_PERF_STAT=1 BENCHMARK_LOCALITY_STRICT="$BENCHMARK_LOCALITY_STRICT" BENCHMARK_ENABLE_LOCALITY_MODE=1 "${run_cmd[@]}"; then
        benchmark_exit_code=0
      else
        benchmark_exit_code=$?
      fi
    else
      if BENCHMARK_LOCALITY_STRICT="$BENCHMARK_LOCALITY_STRICT" BENCHMARK_ENABLE_LOCALITY_MODE=1 "${run_cmd[@]}"; then
        benchmark_exit_code=0
      else
        benchmark_exit_code=$?
      fi
    fi

    result_file="$run_dir/result.json"
    repro_file="$run_dir/reproducibility-metadata.json"
    steady_file="$run_dir/steady-state-evidence.json"
    perf_stat_file="$run_dir/perf-stat.csv"

    json_present="false"
    json_row_count=0
    json_valid=0
    json_claim_scope="none"
    total_requests=0
    throughput_rps=0

    if [[ -f "$result_file" ]]; then
      json_present="true"
      if jq -e . "$result_file" >/dev/null 2>&1; then
        json_valid=1
        json_row_count=1
        json_claim_scope="$(jq -r '.claim_scope // "none"' "$result_file")"
        total_requests="$(jq -r '(.metrics.total_requests // 0) | if type == "number" then . else 0 end' "$result_file")"
        throughput_rps="$(jq -r '(.metrics.throughput_rps // 0) | if type == "number" then . else 0 end' "$result_file")"
      fi
    fi

    perf_stat_present="false"
    if [[ -s "$perf_stat_file" ]]; then
      perf_stat_present="true"
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

    echo "$runner_status,$reproducibility_status,$final_reason,$claim_scope,$benchmark_exit_code,$postprocess_exit_code,$json_row_count,$benchmark_id,$run_label,$backend_mode,$run_dir,$json_present,$total_requests,$throughput_rps,$perf_stat_present" >> "$STATUS_FILE"
  done
done

schema_ok=1
for required_column in runner_status reproducibility_status final_reason claim_scope benchmark_exit_code postprocess_exit_code json_row_count benchmark_id; do
  if ! head -1 "$STATUS_FILE" | tr ',' '\n' | grep -Fxq "$required_column"; then
    schema_ok=0
    break
  fi
done

classification_gate_pass="false"
if [[ "$schema_ok" -eq 1 ]]; then
  if ./tools/verify-classification.sh "$STATUS_FILE"; then
    classification_gate_pass="true"
  else
    any_fail=1
  fi
else
  echo "ERROR: status.csv schema does not match verify-classification expectations"
  any_fail=1
fi

IFS='|' read -r dv_rows dv_sum_requests dv_n_success dv_mean dv_stddev dv_ci95 dv_rel_err dv_min_samples_pass dv_ci_pass dv_claim_pass dv_perf_all_true dv_min_rps_floor_pass < <(derive_mode_stats "$STATUS_FILE" "default-vt")
IFS='|' read -r la_rows la_sum_requests la_n_success la_mean la_stddev la_ci95 la_rel_err la_min_samples_pass la_ci_pass la_claim_pass la_perf_all_true la_min_rps_floor_pass < <(derive_mode_stats "$STATUS_FILE" "locality-aware")

dv_perf_pass="true"
la_perf_pass="true"
if [[ "$REQUIRE_PERF_STAT" -eq 1 ]]; then
  dv_perf_pass="$dv_perf_all_true"
  la_perf_pass="$la_perf_all_true"
fi

if [[ "$dv_min_samples_pass" != "true" || "$la_min_samples_pass" != "true" ]]; then
  any_fail=1
fi
if [[ "$dv_ci_pass" != "true" || "$la_ci_pass" != "true" ]]; then
  any_fail=1
fi
if [[ "$dv_claim_pass" != "true" || "$la_claim_pass" != "true" ]]; then
  any_fail=1
fi
if [[ "$REQUIRE_PERF_STAT" -eq 1 && ( "$dv_perf_pass" != "true" || "$la_perf_pass" != "true" ) ]]; then
  any_fail=1
fi

if [[ "$dv_min_rps_floor_pass" != "true" || "$la_min_rps_floor_pass" != "true" ]]; then
  echo "WARN: [gate] min_rps_floor (500 rps) not met: dv=$dv_min_rps_floor_pass la=$la_min_rps_floor_pass"
  any_fail=1
fi

comparison_ratio_gate_pass="true"
if [[ "$dv_n_success" -gt 0 ]] && [[ "$la_n_success" -gt 0 ]]; then
  comparison_ratio_gate_pass=$(LC_ALL=C awk -v dv="$dv_mean" -v la="$la_mean" 'BEGIN {
    if (dv > 0) {
      r = la / dv
      if (r >= 0.25 && r <= 4.0) print "true"
      else print "false"
    } else {
      print "false"
    }
  }')
fi
if [[ "$comparison_ratio_gate_pass" != "true" ]]; then
  echo "WARN: [gate] comparison ratio (locality_aware/default_vt) outside [0.25, 4.0]; possible pathological result"
  any_fail=1
fi

if [[ "$classification_gate_pass" != "true" ]]; then
  any_fail=1
fi

overall_status="pass"
if [[ "$any_fail" -ne 0 ]]; then
  overall_status="fail"
fi

jq -n \
  --arg campaign_dir "$CAMPAIGN_DIR" \
  --arg status_file "$STATUS_FILE" \
  --arg overall_status "$overall_status" \
  --argjson repeats "$REPEATS" \
  --argjson require_perf_stat "$REQUIRE_PERF_STAT" \
  --arg cpu_affinity "${CPU_AFFINITY:-none}" \
  --arg classification_gate_pass "$classification_gate_pass" \
  --arg dv_rows "$dv_rows" \
  --arg dv_sum_requests "$dv_sum_requests" \
  --arg dv_n_success "$dv_n_success" \
  --arg dv_mean "$dv_mean" \
  --arg dv_stddev "$dv_stddev" \
  --arg dv_ci95 "$dv_ci95" \
  --arg dv_rel_err "$dv_rel_err" \
  --arg dv_min_samples_pass "$dv_min_samples_pass" \
  --arg dv_ci_pass "$dv_ci_pass" \
  --arg dv_claim_pass "$dv_claim_pass" \
  --arg dv_perf_all_true "$dv_perf_all_true" \
  --arg dv_perf_pass "$dv_perf_pass" \
  --arg la_rows "$la_rows" \
  --arg la_sum_requests "$la_sum_requests" \
  --arg la_n_success "$la_n_success" \
  --arg la_mean "$la_mean" \
  --arg la_stddev "$la_stddev" \
  --arg la_ci95 "$la_ci95" \
  --arg la_rel_err "$la_rel_err" \
  --arg la_min_samples_pass "$la_min_samples_pass" \
  --arg la_ci_pass "$la_ci_pass" \
  --arg la_claim_pass "$la_claim_pass" \
  --arg la_perf_all_true "$la_perf_all_true" \
  --arg la_perf_pass "$la_perf_pass" \
  --argjson locality_mode_enabled "$LOCALITY_MODE_ENABLED" \
  --argjson locality_strict "$BENCHMARK_LOCALITY_STRICT" \
  --arg dv_min_rps_floor_pass "$dv_min_rps_floor_pass" \
  --arg la_min_rps_floor_pass "$la_min_rps_floor_pass" \
  --arg comparison_ratio_gate_pass "$comparison_ratio_gate_pass" \
  '
  def to_num($v): ($v | tonumber);
  def to_bool($v): ($v == "true");

  {
    schema_version: "1",
    scenario: "entity-read-by-id",
    comparison_type: "intra-target-backend-mode",
    campaign_dir: $campaign_dir,
    status_csv: $status_file,
    modes_order: ["default-vt", "locality-aware"],
    config: {
      repeats: $repeats,
      cpu_affinity: $cpu_affinity,
      require_perf_stat: ($require_perf_stat == 1),
      locality_mode_enabled: ($locality_mode_enabled == 1),
      locality_strict: ($locality_strict == 1)
    },
    gates: {
      classification_verify_pass: to_bool($classification_gate_pass),
      min_samples_per_mode_pass: (to_bool($dv_min_samples_pass) and to_bool($la_min_samples_pass)),
      ci_per_mode_pass: (to_bool($dv_ci_pass) and to_bool($la_ci_pass)),
      comparison_eligible_all_rows_pass: (to_bool($dv_claim_pass) and to_bool($la_claim_pass)),
      perf_required_all_rows_pass: (
        if ($require_perf_stat == 1)
        then (to_bool($dv_perf_pass) and to_bool($la_perf_pass))
        else true
        end
      ),
      min_rps_floor_per_mode_pass: (to_bool($dv_min_rps_floor_pass) and to_bool($la_min_rps_floor_pass)),
      comparison_ratio_gate_pass: to_bool($comparison_ratio_gate_pass)
    },
    per_mode: {
      "default-vt": {
        rows: to_num($dv_rows),
        successful_rows: to_num($dv_n_success),
        sum_total_requests: to_num($dv_sum_requests),
        throughput_rps: {
          mean: to_num($dv_mean),
          sample_stddev: to_num($dv_stddev),
          ci95_half_width: to_num($dv_ci95),
          relative_error_pct: to_num($dv_rel_err)
        },
        gates: {
          min_samples_pass: to_bool($dv_min_samples_pass),
          ci_pass: to_bool($dv_ci_pass),
          comparison_eligible_all_rows_pass: to_bool($dv_claim_pass),
          perf_rows_all_present: to_bool($dv_perf_all_true),
          perf_gate_pass: to_bool($dv_perf_pass),
          min_rps_floor_pass: to_bool($dv_min_rps_floor_pass)
        }
      },
      "locality-aware": {
        rows: to_num($la_rows),
        successful_rows: to_num($la_n_success),
        sum_total_requests: to_num($la_sum_requests),
        throughput_rps: {
          mean: to_num($la_mean),
          sample_stddev: to_num($la_stddev),
          ci95_half_width: to_num($la_ci95),
          relative_error_pct: to_num($la_rel_err)
        },
        gates: {
          min_samples_pass: to_bool($la_min_samples_pass),
          ci_pass: to_bool($la_ci_pass),
          comparison_eligible_all_rows_pass: to_bool($la_claim_pass),
          perf_rows_all_present: to_bool($la_perf_all_true),
          perf_gate_pass: to_bool($la_perf_pass),
          min_rps_floor_pass: to_bool($la_min_rps_floor_pass)
        }
      }
    },
    comparison_ratio_gate_pass: to_bool($comparison_ratio_gate_pass),
    overall_status: $overall_status
  }
  ' > "$SUMMARY_FILE"

if [[ "$any_fail" -ne 0 ]]; then
  echo "Campaign failed. See $STATUS_FILE and $SUMMARY_FILE"
  exit 1
fi

echo "Campaign succeeded. status.csv: $STATUS_FILE"
echo "Comparative summary: $SUMMARY_FILE"
