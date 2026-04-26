#!/usr/bin/env bash
set -euo pipefail

# validate-comparative-readiness.sh
#
# Strict, fail-closed comparative gate validator.
# Exit code:
#   0 -> all gates PASS
#   1 -> any gate FAIL/BLOCK
#
# CSV columns:
#   scope,gate_id,gate_name,pass_fail,rejection_code,reason,caveat
#
# Summary JSON contains machine-readable rejection_codes and gate rows.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA_BENCHMARK_RESULT="${REPO_ROOT}/schemas/benchmark-result.schema.json"

RESULT_A=""
RESULT_B=""
TARGET_A_ID_ARG=""
TARGET_B_ID_ARG=""
SCENARIO_ID=""
CONTRACT_ID=""
OUTPUT_CSV=""
SUMMARY_JSON=""
TRACK_ID_EXPECTED=""
REPORT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-a)      RESULT_A="$2"; shift 2 ;;
    --result-b)      RESULT_B="$2"; shift 2 ;;
    --target-a-id)   TARGET_A_ID_ARG="$2"; shift 2 ;;
    --target-b-id)   TARGET_B_ID_ARG="$2"; shift 2 ;;
    --scenario-id)   SCENARIO_ID="$2"; shift 2 ;;
    --contract-id)   CONTRACT_ID="$2"; shift 2 ;;
    --output)        OUTPUT_CSV="$2"; shift 2 ;;
    --summary-json)  SUMMARY_JSON="$2"; shift 2 ;;
    --track-id)      TRACK_ID_EXPECTED="$2"; shift 2 ;;
    --report-file)   REPORT_FILE="$2"; shift 2 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$RESULT_A" || -z "$RESULT_B" || -z "$SCENARIO_ID" || -z "$CONTRACT_ID" ]]; then
  echo "ERROR: --result-a, --result-b, --scenario-id, and --contract-id are required." >&2
  exit 1
fi

for cmd in jq awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

for f in "$RESULT_A" "$RESULT_B"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Result file not found: $f" >&2
    exit 1
  fi
  if ! jq empty "$f" >/dev/null 2>&1; then
    echo "ERROR: Result file is not valid JSON: $f" >&2
    exit 1
  fi
done

TARGET_A_ID="${TARGET_A_ID_ARG:-$(jq -r '.target.repo // .run_id // "target-a"' "$RESULT_A")}"
TARGET_B_ID="${TARGET_B_ID_ARG:-$(jq -r '.target.repo // .run_id // "target-b"' "$RESULT_B")}"

GATE_PASS=0
GATE_FAIL=0

declare -a CSV_ROWS=()
CSV_ROWS+=("scope,gate_id,gate_name,pass_fail,rejection_code,reason,caveat")

declare -A REJECTION_CODES=()

jq_field() {
  local file="$1"
  local path="$2"
  jq -r "${path} // empty" "$file" 2>/dev/null || true
}

normalize_text() {
  local value="${1:-}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  value="${value//,/;}"
  echo "$value"
}

constrained_contract_id() {
  local contract_id="${1:-}"
  [[ -n "$contract_id" && ( "$contract_id" == fixed_contract_runtime_h1_constrained* || "$contract_id" == *_constrained_* ) ]]
}

constrained_execution_profile_id() {
  local execution_profile_id="${1:-}"
  [[ -n "$execution_profile_id" && "$execution_profile_id" == runtime-constrained-* ]]
}

constrained_track_id() {
  local track_id="${1:-}"
  [[ -n "$track_id" && "$track_id" == track-c* ]]
}

constrained_result_path() {
  local path_value="${1:-}"
  [[ -n "$path_value" && ( "$path_value" == */results/constrained/* || "$path_value" == results/constrained/* ) ]]
}

result_constrained_reason() {
  local file="$1"
  local execution_profile_id=""
  local track_id=""
  local run_contract_id=""
  local top_contract_id=""

  if constrained_result_path "$file"; then
    echo "result_path=${file}"
    return 0
  fi

  execution_profile_id="$(jq_field "$file" '.run_config.execution_profile_id')"
  if constrained_execution_profile_id "$execution_profile_id"; then
    echo "run_config.execution_profile_id=${execution_profile_id}"
    return 0
  fi

  track_id="$(jq_field "$file" '.run_config.track_id')"
  if constrained_track_id "$track_id"; then
    echo "run_config.track_id=${track_id}"
    return 0
  fi

  run_contract_id="$(jq_field "$file" '.run_config.contract_id')"
  if constrained_contract_id "$run_contract_id"; then
    echo "run_config.contract_id=${run_contract_id}"
    return 0
  fi

  top_contract_id="$(jq_field "$file" '.contract_id')"
  if constrained_contract_id "$top_contract_id"; then
    echo "contract_id=${top_contract_id}"
    return 0
  fi

  return 1
}

record_gate() {
  local scope="$1"
  local gate_id="$2"
  local gate_name="$3"
  local pass_fail="$4"
  local rejection_code="$5"
  local reason="$6"
  local caveat="${7:-}"

  local safe_reason safe_caveat
  safe_reason="$(normalize_text "$reason")"
  safe_caveat="$(normalize_text "$caveat")"

  CSV_ROWS+=("${scope},${gate_id},${gate_name},${pass_fail},${rejection_code},${safe_reason},${safe_caveat}")

  if [[ "$pass_fail" == "PASS" ]]; then
    ((GATE_PASS += 1))
  else
    ((GATE_FAIL += 1))
    if [[ -n "$rejection_code" && "$rejection_code" != "none" ]]; then
      REJECTION_CODES["$rejection_code"]=1
    fi
  fi
}

num_leq() {
  local left="$1"
  local right="$2"
  awk -v l="$left" -v r="$right" 'BEGIN { exit !(l + 0 <= r + 0) }'
}

validate_against_schema() {
  local file="$1"
  local schema="$2"

  if ! command -v python3 >/dev/null 2>&1; then
    return 50
  fi

  python3 - "$file" "$schema" <<'PY'
import json
import sys

file_path = sys.argv[1]
schema_path = sys.argv[2]

try:
    import jsonschema
except Exception:
    sys.exit(50)

with open(file_path, "r", encoding="utf-8") as f:
    data = json.load(f)
with open(schema_path, "r", encoding="utf-8") as f:
    schema = json.load(f)

validator = jsonschema.Draft202012Validator(schema)
errors = sorted(validator.iter_errors(data), key=lambda e: e.path)
if errors:
    print(errors[0].message)
    sys.exit(1)

sys.exit(0)
PY
}

# Gate 8 first: schema gate, fail closed if validator unavailable.
schema_reason=""
schema_ok=true
for pair in "A:$TARGET_A_ID:$RESULT_A" "B:$TARGET_B_ID:$RESULT_B"; do
  IFS=: read -r label tid rfile <<< "$pair"
  set +e
  schema_msg="$(validate_against_schema "$rfile" "$SCHEMA_BENCHMARK_RESULT" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 50 ]]; then
    schema_ok=false
    schema_reason="jsonschema validator unavailable (python3/jsonschema missing)"
    break
  elif [[ $rc -ne 0 ]]; then
    schema_ok=false
    schema_reason="${label}: schema invalid: ${schema_msg}"
    break
  fi
done

if [[ "$schema_ok" == true ]]; then
  record_gate "pair" "G8" "schema_validation" "PASS" "none" "both artifacts validate against benchmark-result.schema.json"
else
  code="SCHEMA_VALIDATION_FAILED"
  if [[ "$schema_reason" == *"validator unavailable"* ]]; then
    code="SCHEMA_VALIDATOR_UNAVAILABLE"
  fi
  record_gate "pair" "G8" "schema_validation" "FAIL" "$code" "$schema_reason"
fi

# Gate 1: track isolation.
track_a="$(jq_field "$RESULT_A" '.run_config.track_id')"
track_b="$(jq_field "$RESULT_B" '.run_config.track_id')"

constrained_reasons=()
if constrained_reason="$(result_constrained_reason "$RESULT_A")"; then
  constrained_reasons+=("A:${constrained_reason}")
fi
if constrained_reason="$(result_constrained_reason "$RESULT_B")"; then
  constrained_reasons+=("B:${constrained_reason}")
fi

if [[ ${#constrained_reasons[@]} -gt 0 ]]; then
  record_gate "pair" "G1" "track_isolation" "FAIL" "CONSTRAINED_PROFILE_FORBIDDEN" "$(IFS='; '; echo "${constrained_reasons[*]}")"
elif [[ -z "$track_a" || -z "$track_b" ]]; then
  record_gate "pair" "G1" "track_isolation" "FAIL" "TRACK_METADATA_MISSING" "run_config.track_id required on both artifacts"
elif [[ -n "$TRACK_ID_EXPECTED" && "$track_a" != "$TRACK_ID_EXPECTED" ]]; then
  record_gate "pair" "G1" "track_isolation" "FAIL" "TRACK_EXPECTED_MISMATCH" "track_id A=${track_a} does not match expected=${TRACK_ID_EXPECTED}"
elif [[ -n "$TRACK_ID_EXPECTED" && "$track_b" != "$TRACK_ID_EXPECTED" ]]; then
  record_gate "pair" "G1" "track_isolation" "FAIL" "TRACK_EXPECTED_MISMATCH" "track_id B=${track_b} does not match expected=${TRACK_ID_EXPECTED}"
elif [[ "$track_a" != "$track_b" ]]; then
  record_gate "pair" "G1" "track_isolation" "FAIL" "TRACK_MIXED" "track_id mismatch: A=${track_a}, B=${track_b}"
else
  record_gate "pair" "G1" "track_isolation" "PASS" "none" "track_id=${track_a}"
fi

# Gate 2: eligibility gate.
eligibility_reasons=()
for pair in "A:$RESULT_A" "B:$RESULT_B"; do
  IFS=: read -r label rfile <<< "$pair"
  claim_scope="$(jq_field "$rfile" '.claim_scope')"
  runner_status="$(jq_field "$rfile" '.runner_status')"
  reproducibility_status="$(jq_field "$rfile" '.reproducibility_status')"
  final_reason="$(jq_field "$rfile" '.final_reason')"

  [[ "$claim_scope" != "comparison_eligible" ]] && eligibility_reasons+=("${label}.claim_scope=${claim_scope:-missing}")
  [[ "$runner_status" != "success" ]] && eligibility_reasons+=("${label}.runner_status=${runner_status:-missing}")
  [[ "$reproducibility_status" != "complete" ]] && eligibility_reasons+=("${label}.reproducibility_status=${reproducibility_status:-missing}")
  [[ "$final_reason" != "ok" ]] && eligibility_reasons+=("${label}.final_reason=${final_reason:-missing}")
done

if [[ ${#eligibility_reasons[@]} -eq 0 ]]; then
  record_gate "pair" "G2" "eligibility_only" "PASS" "none" "both artifacts are comparison_eligible/success/complete/ok"
else
  record_gate "pair" "G2" "eligibility_only" "FAIL" "NOT_COMPARISON_ELIGIBLE" "$(IFS='; '; echo "${eligibility_reasons[*]}")"
fi

# Gate 3: strict equivalence gate.
scenario_a="$(jq_field "$RESULT_A" '.scenario')"
scenario_b="$(jq_field "$RESULT_B" '.scenario')"
contract_a="$(jq_field "$RESULT_A" '.run_config.contract_id // .contract_id')"
contract_b="$(jq_field "$RESULT_B" '.run_config.contract_id // .contract_id')"
tier_a="$(jq_field "$RESULT_A" '.target.tier')"
tier_b="$(jq_field "$RESULT_B" '.target.tier')"
protocol_a="$(jq_field "$RESULT_A" '.target.protocol // .run_config.protocol_mode')"
protocol_b="$(jq_field "$RESULT_B" '.target.protocol // .run_config.protocol_mode')"
mode_a="$(jq_field "$RESULT_A" '.target.mode // .run_config.mode')"
mode_b="$(jq_field "$RESULT_B" '.target.mode // .run_config.mode')"
payload_a="$(jq_field "$RESULT_A" '.run_config.payload_size_bytes // .run_config.payload_file')"
payload_b="$(jq_field "$RESULT_B" '.run_config.payload_size_bytes // .run_config.payload_file')"
threads_a="$(jq_field "$RESULT_A" '.run_config.threads')"
threads_b="$(jq_field "$RESULT_B" '.run_config.threads')"
conn_a="$(jq_field "$RESULT_A" '.run_config.connections')"
conn_b="$(jq_field "$RESULT_B" '.run_config.connections')"
warmup_a="$(jq_field "$RESULT_A" '.run_config.warmup_seconds')"
warmup_b="$(jq_field "$RESULT_B" '.run_config.warmup_seconds')"
meas_a="$(jq_field "$RESULT_A" '.run_config.duration_seconds')"
meas_b="$(jq_field "$RESULT_B" '.run_config.duration_seconds')"
jvm_class_a="$(jq_field "$RESULT_A" '.run_config.jvm_class')"
jvm_class_b="$(jq_field "$RESULT_B" '.run_config.jvm_class')"

eq_reasons=()
[[ "$scenario_a" != "$SCENARIO_ID" ]] && eq_reasons+=("scenario A=${scenario_a:-missing} expected=${SCENARIO_ID}")
[[ "$scenario_b" != "$SCENARIO_ID" ]] && eq_reasons+=("scenario B=${scenario_b:-missing} expected=${SCENARIO_ID}")
[[ "$scenario_a" != "$scenario_b" ]] && eq_reasons+=("scenario mismatch A=${scenario_a:-missing} B=${scenario_b:-missing}")
[[ "$contract_a" != "$CONTRACT_ID" ]] && eq_reasons+=("contract A=${contract_a:-missing} expected=${CONTRACT_ID}")
[[ "$contract_b" != "$CONTRACT_ID" ]] && eq_reasons+=("contract B=${contract_b:-missing} expected=${CONTRACT_ID}")
[[ "$contract_a" != "$contract_b" ]] && eq_reasons+=("contract mismatch A=${contract_a:-missing} B=${contract_b:-missing}")
[[ -z "$tier_a" || -z "$tier_b" ]] && eq_reasons+=("tier missing")
[[ "$tier_a" != "$tier_b" ]] && eq_reasons+=("tier mismatch A=${tier_a:-missing} B=${tier_b:-missing}")
[[ -z "$protocol_a" || -z "$protocol_b" ]] && eq_reasons+=("protocol missing")
[[ "$protocol_a" != "$protocol_b" ]] && eq_reasons+=("protocol mismatch A=${protocol_a:-missing} B=${protocol_b:-missing}")
[[ -z "$mode_a" || -z "$mode_b" ]] && eq_reasons+=("mode missing")
[[ "$mode_a" != "$mode_b" ]] && eq_reasons+=("mode mismatch A=${mode_a:-missing} B=${mode_b:-missing}")
[[ -z "$payload_a" || -z "$payload_b" ]] && eq_reasons+=("payload metadata missing")
[[ "$payload_a" != "$payload_b" ]] && eq_reasons+=("payload mismatch A=${payload_a:-missing} B=${payload_b:-missing}")
[[ -z "$threads_a" || -z "$threads_b" ]] && eq_reasons+=("threads missing")
[[ "$threads_a" != "$threads_b" ]] && eq_reasons+=("threads mismatch A=${threads_a:-missing} B=${threads_b:-missing}")
[[ -z "$conn_a" || -z "$conn_b" ]] && eq_reasons+=("connections missing")
[[ "$conn_a" != "$conn_b" ]] && eq_reasons+=("connections mismatch A=${conn_a:-missing} B=${conn_b:-missing}")
[[ -z "$warmup_a" || -z "$warmup_b" ]] && eq_reasons+=("warmup missing")
[[ "$warmup_a" != "$warmup_b" ]] && eq_reasons+=("warmup mismatch A=${warmup_a:-missing} B=${warmup_b:-missing}")
[[ -z "$meas_a" || -z "$meas_b" ]] && eq_reasons+=("measurement missing")
[[ "$meas_a" != "$meas_b" ]] && eq_reasons+=("measurement mismatch A=${meas_a:-missing} B=${meas_b:-missing}")
[[ -z "$jvm_class_a" || -z "$jvm_class_b" ]] && eq_reasons+=("jvm_class missing")
[[ "$jvm_class_a" != "$jvm_class_b" ]] && eq_reasons+=("jvm_class mismatch A=${jvm_class_a:-missing} B=${jvm_class_b:-missing}")

if [[ ${#eq_reasons[@]} -eq 0 ]]; then
  record_gate "pair" "G3" "equivalence_strict" "PASS" "none" "scenario/contract/tier/protocol/mode/payload/concurrency/windows/jvm_class equivalent"
else
  record_gate "pair" "G3" "equivalence_strict" "FAIL" "EQUIVALENCE_MISMATCH" "$(IFS='; '; echo "${eq_reasons[*]}")"
fi

# Gate 4: AB/BA execution gate.
pair_id_a="$(jq_field "$RESULT_A" '.run_config.pair_id')"
pair_id_b="$(jq_field "$RESULT_B" '.run_config.pair_id')"
pair_order_a="$(jq_field "$RESULT_A" '.run_config.pair_order')"
pair_order_b="$(jq_field "$RESULT_B" '.run_config.pair_order')"
evidence_order_a="$(jq_field "$RESULT_A" '.run_config.pair_completion_evidence.invocation_order')"
evidence_order_b="$(jq_field "$RESULT_B" '.run_config.pair_completion_evidence.invocation_order')"
evidence_marker_a="$(jq_field "$RESULT_A" '.run_config.pair_completion_evidence.completion_marker_utc')"
evidence_marker_b="$(jq_field "$RESULT_B" '.run_config.pair_completion_evidence.completion_marker_utc')"

abba_reasons=()
[[ -z "$pair_id_a" || -z "$pair_id_b" ]] && abba_reasons+=("pair_id missing")
[[ "$pair_id_a" != "$pair_id_b" ]] && abba_reasons+=("pair_id mismatch A=${pair_id_a:-missing} B=${pair_id_b:-missing}")
[[ "$pair_order_a" != "ab" && "$pair_order_a" != "ba" ]] && abba_reasons+=("pair_order A invalid=${pair_order_a:-missing}")
[[ "$pair_order_b" != "ab" && "$pair_order_b" != "ba" ]] && abba_reasons+=("pair_order B invalid=${pair_order_b:-missing}")
[[ "$pair_order_a" != "$pair_order_b" ]] && abba_reasons+=("pair_order mismatch A=${pair_order_a:-missing} B=${pair_order_b:-missing}")
[[ "$evidence_order_a" != "$pair_order_a" ]] && abba_reasons+=("A.evidence.invocation_order does not match pair_order")
[[ "$evidence_order_b" != "$pair_order_b" ]] && abba_reasons+=("B.evidence.invocation_order does not match pair_order")
[[ -z "$evidence_marker_a" ]] && abba_reasons+=("A.evidence.completion_marker_utc missing")
[[ -z "$evidence_marker_b" ]] && abba_reasons+=("B.evidence.completion_marker_utc missing")

if ! jq -e --arg o "$pair_order_a" '.run_config.ab_ba_orders_completed | type == "array" and (index($o) != null)' "$RESULT_A" >/dev/null 2>&1; then
  abba_reasons+=("A.ab_ba_orders_completed missing invocation order ${pair_order_a:-unknown}")
fi
if ! jq -e --arg o "$pair_order_b" '.run_config.ab_ba_orders_completed | type == "array" and (index($o) != null)' "$RESULT_B" >/dev/null 2>&1; then
  abba_reasons+=("B.ab_ba_orders_completed missing invocation order ${pair_order_b:-unknown}")
fi

if [[ ${#abba_reasons[@]} -eq 0 ]]; then
  record_gate "pair" "G4" "ab_ba_required" "PASS" "none" "pair_id=${pair_id_a}; directional completion evidence present for order=${pair_order_a}"
else
  record_gate "pair" "G4" "ab_ba_required" "FAIL" "AB_BA_INCOMPLETE" "$(IFS='; '; echo "${abba_reasons[*]}")"
fi

# Gate 5: drift gate placeholder (strict metadata + thresholds).
drift_reasons=()
for pair in "A:$RESULT_A" "B:$RESULT_B"; do
  IFS=: read -r label rfile <<< "$pair"
  if ! jq -e '.run_config.drift_snapshot | type == "object"' "$rfile" >/dev/null 2>&1; then
    drift_reasons+=("${label}.drift_snapshot missing")
    continue
  fi

  required_present="$(jq_field "$rfile" '.run_config.drift_snapshot.required_metadata_present')"
  max_lat="$(jq_field "$rfile" '.run_config.drift_snapshot.max_latency_drift_pct')"
  obs_lat="$(jq_field "$rfile" '.run_config.drift_snapshot.observed_latency_drift_pct')"
  max_thr="$(jq_field "$rfile" '.run_config.drift_snapshot.max_throughput_drift_pct')"
  obs_thr="$(jq_field "$rfile" '.run_config.drift_snapshot.observed_throughput_drift_pct')"

  [[ "$required_present" != "true" ]] && drift_reasons+=("${label}.required_metadata_present!=true")
  [[ -z "$max_lat" || -z "$obs_lat" || -z "$max_thr" || -z "$obs_thr" ]] && drift_reasons+=("${label}.drift thresholds/observed missing")

  if [[ -n "$max_lat" && -n "$obs_lat" ]] && ! num_leq "$obs_lat" "$max_lat"; then
    drift_reasons+=("${label}.latency drift ${obs_lat} > ${max_lat}")
  fi
  if [[ -n "$max_thr" && -n "$obs_thr" ]] && ! num_leq "$obs_thr" "$max_thr"; then
    drift_reasons+=("${label}.throughput drift ${obs_thr} > ${max_thr}")
  fi
done

if [[ ${#drift_reasons[@]} -eq 0 ]]; then
  record_gate "pair" "G5" "drift_placeholder" "PASS" "none" "drift snapshot metadata present and within thresholds"
else
  code="DRIFT_METADATA_MISSING"
  if printf '%s\n' "${drift_reasons[@]}" | grep -q ' > '; then
    code="DRIFT_THRESHOLD_EXCEEDED"
  fi
  record_gate "pair" "G5" "drift_placeholder" "FAIL" "$code" "$(IFS='; '; echo "${drift_reasons[*]}")"
fi

# Gate 6: reproducibility metadata completeness.
meta_reasons=()
for pair in "A:$RESULT_A" "B:$RESULT_B"; do
  IFS=: read -r label rfile <<< "$pair"

  commit_sha="$(jq_field "$rfile" '.target.commit_sha')"
  jdk_vendor="$(jq_field "$rfile" '.run_config.metadata.jdk_vendor')"
  jdk_version="$(jq_field "$rfile" '.run_config.metadata.jdk_version')"
  tool_version="$(jq_field "$rfile" '.run_config.metadata.benchmark_tool_version')"
  hardware_profile="$(jq_field "$rfile" '.run_config.metadata.hardware_profile')"
  scenario_meta="$(jq_field "$rfile" '.run_config.metadata.scenario_id')"
  target_classification="$(jq_field "$rfile" '.run_config.metadata.target_classification')"

  if ! jq -e '.run_config.metadata.jvm_flags | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' "$rfile" >/dev/null 2>&1; then
    meta_reasons+=("${label}.metadata.jvm_flags missing/empty")
  fi

  [[ -z "$commit_sha" || "$commit_sha" == "unknown" ]] && meta_reasons+=("${label}.target.commit_sha missing")
  [[ -z "$jdk_vendor" || "$jdk_vendor" == "unknown" ]] && meta_reasons+=("${label}.metadata.jdk_vendor missing")
  [[ -z "$jdk_version" || "$jdk_version" == "unknown" ]] && meta_reasons+=("${label}.metadata.jdk_version missing")
  [[ -z "$tool_version" || "$tool_version" == "unknown" ]] && meta_reasons+=("${label}.metadata.benchmark_tool_version missing")
  [[ -z "$hardware_profile" || "$hardware_profile" == "unknown" ]] && meta_reasons+=("${label}.metadata.hardware_profile missing")
  [[ -z "$scenario_meta" || "$scenario_meta" == "unknown" ]] && meta_reasons+=("${label}.metadata.scenario_id missing")
  [[ -z "$target_classification" || "$target_classification" == "unknown" ]] && meta_reasons+=("${label}.metadata.target_classification missing")
done

if [[ ${#meta_reasons[@]} -eq 0 ]]; then
  record_gate "pair" "G6" "metadata_completeness" "PASS" "none" "required reproducibility metadata complete"
else
  record_gate "pair" "G6" "metadata_completeness" "FAIL" "METADATA_INCOMPLETE" "$(IFS='; '; echo "${meta_reasons[*]}")"
fi

# Gate 7: pin verification gate.
pin_reasons=()
for pair in "A:$RESULT_A" "B:$RESULT_B"; do
  IFS=: read -r label rfile <<< "$pair"

  if ! jq -e '.run_config.pinned_versions | type == "object"' "$rfile" >/dev/null 2>&1; then
    pin_reasons+=("${label}.pinned_versions missing")
    continue
  fi
  if ! jq -e '.run_config.actual_versions | type == "object"' "$rfile" >/dev/null 2>&1; then
    pin_reasons+=("${label}.actual_versions missing")
    continue
  fi

  for key in jdk_version benchmark_tool_version target_commit_sha; do
    pinned="$(jq_field "$rfile" ".run_config.pinned_versions.${key}")"
    actual="$(jq_field "$rfile" ".run_config.actual_versions.${key}")"
    if [[ -z "$pinned" || -z "$actual" ]]; then
      pin_reasons+=("${label}.${key} pin/actual missing")
    elif [[ "$pinned" != "$actual" ]]; then
      pin_reasons+=("${label}.${key} mismatch pinned=${pinned} actual=${actual}")
    fi
  done
done

if [[ ${#pin_reasons[@]} -eq 0 ]]; then
  record_gate "pair" "G7" "pin_verification" "PASS" "none" "all required pinned versions match actual versions"
else
  pin_code="PIN_METADATA_MISSING"
  if printf '%s\n' "${pin_reasons[@]}" | grep -q ' mismatch '; then
    pin_code="PIN_MISMATCH"
  fi
  record_gate "pair" "G7" "pin_verification" "FAIL" "$pin_code" "$(IFS='; '; echo "${pin_reasons[*]}")"
fi

# Gate 9: quarantine transparency gate.
if [[ -n "$OUTPUT_CSV" || -n "$SUMMARY_JSON" ]]; then
  record_gate "pair" "G9" "quarantine_transparency" "PASS" "none" "machine-readable rejection output enabled"
else
  record_gate "pair" "G9" "quarantine_transparency" "FAIL" "QUARANTINE_REASON_OUTPUT_MISSING" "provide --output and/or --summary-json for machine-readable rejection codes"
fi

# Gate 10: reporting guard gate.
# If report file is provided, enforce axis labels and block cross-track wording.
if [[ -n "$REPORT_FILE" ]]; then
  if [[ ! -f "$REPORT_FILE" ]]; then
    record_gate "pair" "G10" "reporting_guard" "FAIL" "REPORT_FILE_MISSING" "report file does not exist: ${REPORT_FILE}"
  else
    report_reasons=()
    grep -q 'tier=' "$REPORT_FILE" || report_reasons+=("missing tier label")
    grep -q 'protocol_mode=' "$REPORT_FILE" || report_reasons+=("missing protocol_mode label")
    grep -q 'benchmark_family=' "$REPORT_FILE" || report_reasons+=("missing benchmark_family label")
    grep -q 'track_id=' "$REPORT_FILE" || report_reasons+=("missing track_id label")

    if grep -Eiq 'cross-track|track[[:space:]]*r[[:space:]]*vs[[:space:]]*track[[:space:]]*n|track[[:space:]]*n[[:space:]]*vs[[:space:]]*track[[:space:]]*r' "$REPORT_FILE"; then
      report_reasons+=("cross-track claim text detected")
    fi

    if [[ ${#report_reasons[@]} -eq 0 ]]; then
      record_gate "pair" "G10" "reporting_guard" "PASS" "none" "report carries required axis labels and no cross-track claims"
    else
      code="REPORT_AXIS_LABELS_MISSING"
      if printf '%s\n' "${report_reasons[@]}" | grep -qi 'cross-track'; then
        code="CROSS_TRACK_CLAIM_TEXT_DETECTED"
      fi
      record_gate "pair" "G10" "reporting_guard" "FAIL" "$code" "$(IFS='; '; echo "${report_reasons[*]}")"
    fi
  fi
else
  record_gate "pair" "G10" "reporting_guard" "PASS" "none" "reporting guard deferred (no --report-file provided)"
fi

TMP_CSV="$(mktemp /tmp/comparative-gates-XXXXXX.csv)"
printf '%s\n' "${CSV_ROWS[@]}" > "$TMP_CSV"

if [[ -n "$OUTPUT_CSV" ]]; then
  mkdir -p "$(dirname "$OUTPUT_CSV")"
  cp "$TMP_CSV" "$OUTPUT_CSV"
fi

REJECTION_CODES_JSON="[]"
if [[ ${#REJECTION_CODES[@]} -gt 0 ]]; then
  REJECTION_CODES_JSON="$(printf '%s\n' "${!REJECTION_CODES[@]}" | sort | jq -Rsc 'split("\n") | map(select(length > 0))')"
fi

GATES_JSON="$(jq -Rsc '
  split("\n") |
  map(select(length > 0)) |
  .[1:] |
  map(split(",")) |
  map({
    scope: .[0],
    gate_id: .[1],
    gate_name: .[2],
    pass_fail: .[3],
    rejection_code: .[4],
    reason: .[5],
    caveat: (.[6] // "")
  })
' "$TMP_CSV")"

if [[ -n "$SUMMARY_JSON" ]]; then
  mkdir -p "$(dirname "$SUMMARY_JSON")"
  jq -n \
    --arg scenario_id "$SCENARIO_ID" \
    --arg contract_id "$CONTRACT_ID" \
    --arg target_a_id "$TARGET_A_ID" \
    --arg target_b_id "$TARGET_B_ID" \
    --arg track_id_a "$track_a" \
    --arg track_id_b "$track_b" \
    --argjson pass_count "$GATE_PASS" \
    --argjson fail_count "$GATE_FAIL" \
    --argjson all_passed "$( [[ "$GATE_FAIL" -eq 0 ]] && echo true || echo false )" \
    --argjson rejection_codes "$REJECTION_CODES_JSON" \
    --argjson gates "$GATES_JSON" \
    '{
      scenario_id: $scenario_id,
      contract_id: $contract_id,
      target_a_id: $target_a_id,
      target_b_id: $target_b_id,
      track_id: {
        target_a: ($track_id_a // ""),
        target_b: ($track_id_b // "")
      },
      pass_count: $pass_count,
      fail_count: $fail_count,
      all_passed: $all_passed,
      rejection_codes: $rejection_codes,
      gates: $gates
    }' > "$SUMMARY_JSON"
fi

rm -f "$TMP_CSV"

printf 'COMPARATIVE_GATES_PASS=%s\n' "$GATE_PASS"
printf 'COMPARATIVE_GATES_FAIL=%s\n' "$GATE_FAIL"
printf 'TARGET_A_ID=%s\n' "$TARGET_A_ID"
printf 'TARGET_B_ID=%s\n' "$TARGET_B_ID"
if [[ -n "$OUTPUT_CSV" ]]; then
  printf 'GATE_CSV=%s\n' "$OUTPUT_CSV"
fi
if [[ -n "$SUMMARY_JSON" ]]; then
  printf 'GATE_SUMMARY_JSON=%s\n' "$SUMMARY_JSON"
fi

if [[ "$GATE_FAIL" -gt 0 ]]; then
  echo "GATE VALIDATION FAILED" >&2
  exit 1
fi

echo "GATE VALIDATION PASSED"
exit 0
