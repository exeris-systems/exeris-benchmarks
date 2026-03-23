#!/usr/bin/env bash
set -euo pipefail

# validate-comparative-readiness.sh — Run all comparative readiness gates against two result files.
#
# Usage:
#   scripts/validate-comparative-readiness.sh \
#     --result-a    <path>              \
#     --result-b    <path>              \
#     [--target-a-id <target_id_or_legacy>] \
#     [--target-b-id <target_id_or_legacy>] \
#     --scenario-id entity-read-by-id  \
#     --contract-id fixed_contract_v1  \
#     [--output     <gate-report.csv>]
#
# Output CSV columns: target_id,gate_id,gate_name,pass_fail,reason,caveat
# Exit code: 0 if all gates PASS or WARN, 1 if any gate FAILS/BLOCKS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_CONTRACT_REGISTRY="${REPO_ROOT}/runtime/drivers/target-contract-registry.sh"

# shellcheck source=/dev/null
source "$TARGET_CONTRACT_REGISTRY"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RESULT_A=""
RESULT_B=""
TARGET_A_ID_ARG=""
TARGET_B_ID_ARG=""
SCENARIO_ID=""
CONTRACT_ID=""
OUTPUT_CSV=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-a)    RESULT_A="$2";    shift 2 ;;
    --result-b)    RESULT_B="$2";    shift 2 ;;
    --target-a-id) TARGET_A_ID_ARG="$2"; shift 2 ;;
    --target-b-id) TARGET_B_ID_ARG="$2"; shift 2 ;;
    --scenario-id) SCENARIO_ID="$2"; shift 2 ;;
    --contract-id) CONTRACT_ID="$2"; shift 2 ;;
    --output)      OUTPUT_CSV="$2";  shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$RESULT_A" || -z "$RESULT_B" || -z "$SCENARIO_ID" || -z "$CONTRACT_ID" ]]; then
  echo "ERROR: --result-a, --result-b, --scenario-id, and --contract-id are all required." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for cmd in jq awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Input file validation
# ---------------------------------------------------------------------------
for f in "$RESULT_A" "$RESULT_B"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Result file not found: $f" >&2
    exit 1
  fi
  if ! jq empty "$f" 2>/dev/null; then
    echo "ERROR: Result file is not valid JSON: $f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
TARGET_A_ID="${TARGET_A_ID_ARG:-$(jq -r '.target.repo // .run_id // "target-a"' "$RESULT_A")}"
TARGET_B_ID="${TARGET_B_ID_ARG:-$(jq -r '.target.repo // .run_id // "target-b"' "$RESULT_B")}"

GATE_PASS=0
GATE_WARN=0
GATE_FAIL=0

# CSV rows accumulated in an array
declare -a CSV_ROWS=()
CSV_ROWS+=("target_id,gate_id,gate_name,pass_fail,reason,caveat")

# Record a gate result for one target
record_gate() {
  local target_id="$1"
  local gate_id="$2"
  local gate_name="$3"
  local pass_fail="$4"
  local reason="$5"
  local caveat="${6:-}"

  # Escape any commas in free-text fields
  local safe_reason="${reason//,/;}"
  local safe_caveat="${caveat//,/;}"

  CSV_ROWS+=("${target_id},${gate_id},${gate_name},${pass_fail},${safe_reason},${safe_caveat}")

  case "$pass_fail" in
    PASS) ((GATE_PASS += 1)) ;;
    WARN) ((GATE_WARN += 1)) ;;
    FAIL|BLOCK) ((GATE_FAIL += 1)) ;;
  esac
}

# jq field extractor (returns empty string when absent)
jq_field() {
  local file="$1"
  local path="$2"
  jq -r "${path} // empty" "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# GATE A — Maturity
# Both results must have claim_scope == "comparison_eligible"
#   AND runner_status == "success"
#   AND reproducibility_status == "complete"
# ---------------------------------------------------------------------------
echo "--- Gate A: Maturity ---"
for pair in "A:$TARGET_A_ID:$RESULT_A" "B:$TARGET_B_ID:$RESULT_B"; do
  IFS=: read -r _label tid rfile <<< "$pair"

  cs="$(jq_field  "$rfile" '.claim_scope')"
  rs="$(jq_field  "$rfile" '.runner_status')"
  repro="$(jq_field "$rfile" '.reproducibility_status')"

  reasons=()
  [[ "$cs"    != "comparison_eligible" ]] && reasons+=("claim_scope=${cs:-missing} (want comparison_eligible)")
  [[ "$rs"    != "success"             ]] && reasons+=("runner_status=${rs:-missing} (want success)")
  [[ "$repro" != "complete"            ]] && reasons+=("reproducibility_status=${repro:-missing} (want complete)")

  if [[ ${#reasons[@]} -eq 0 ]]; then
    record_gate "$tid" "A" "maturity" "PASS" "claim_scope=comparison_eligible; runner_status=success; reproducibility_status=complete"
  else
    record_gate "$tid" "A" "maturity" "FAIL" "$(IFS='; '; echo "${reasons[*]}")"
  fi
done

# ---------------------------------------------------------------------------
# GATE B — Equivalence
# Both must share: scenario_id, contract_id (run_config), tool, transport_mode
# ---------------------------------------------------------------------------
echo "--- Gate B: Equivalence ---"
scen_a="$(jq_field "$RESULT_A" '.scenario')"
scen_b="$(jq_field "$RESULT_B" '.scenario')"
tool_a="$(jq_field "$RESULT_A" '.tool')"
tool_b="$(jq_field "$RESULT_B" '.tool')"
trans_a="$(jq_field "$RESULT_A" '.transport_mode')"
trans_b="$(jq_field "$RESULT_B" '.transport_mode')"
# contract_id is not a native field in benchmark-result; derive from run_config or embedded tag
contract_a="$(jq_field "$RESULT_A" '.run_config.contract_id // .contract_id')"
contract_b="$(jq_field "$RESULT_B" '.run_config.contract_id // .contract_id')"

for pair in "A:$TARGET_A_ID:$RESULT_A" "B:$TARGET_B_ID:$RESULT_B"; do
  IFS=: read -r _label tid rfile <<< "$pair"

  reasons=()
  [[ "$scen_a"     != "$scen_b"     ]] && reasons+=("scenario mismatch: ${scen_a} vs ${scen_b}")
  [[ "$tool_a"     != "$tool_b"     ]] && reasons+=("tool mismatch: ${tool_a} vs ${tool_b}")
  [[ "$trans_a"    != "$trans_b"    ]] && reasons+=("transport_mode mismatch: ${trans_a} vs ${trans_b}")
  # scenario_id must match requested
  scen_val="$(jq_field "$rfile" '.scenario')"
  [[ "$scen_val" != "$SCENARIO_ID" ]] && reasons+=("scenario=${scen_val:-missing} (want ${SCENARIO_ID})")
  # contract_id check (lenient: skip if both empty)
  if [[ -n "$contract_a" || -n "$contract_b" ]]; then
    [[ "$contract_a" != "$contract_b" ]] && reasons+=("contract_id mismatch: ${contract_a:-missing} vs ${contract_b:-missing}")
  fi

  if [[ ${#reasons[@]} -eq 0 ]]; then
    record_gate "$tid" "B" "equivalence" "PASS" "scenario; tool; transport_mode; contract_id all match"
  else
    record_gate "$tid" "B" "equivalence" "FAIL" "$(IFS='; '; echo "${reasons[*]}")"
  fi
done

# ---------------------------------------------------------------------------
# GATE C — Endpoint Health
# total_errors == 0 OR error_rate_pct < 0.5. Block if error_rate >= 1.0.
# ---------------------------------------------------------------------------
echo "--- Gate C: Endpoint ---"
for pair in "A:$TARGET_A_ID:$RESULT_A" "B:$TARGET_B_ID:$RESULT_B"; do
  IFS=: read -r _label tid rfile <<< "$pair"

  total_errors="$(jq_field "$rfile" '.metrics.total_errors')"
  error_rate="$(jq_field "$rfile" '.metrics.error_rate_pct')"
  total_errors="${total_errors:-0}"
  error_rate="${error_rate:-0}"

  pf="$(awk -v er="$error_rate" -v te="$total_errors" 'BEGIN {
    if (er + 0 >= 1.0) { print "FAIL"; exit }
    if (te + 0 == 0 || er + 0 < 0.5) { print "PASS"; exit }
    print "WARN"
  }')"

  reason_text="total_errors=${total_errors}; error_rate_pct=${error_rate}"
  caveat=""
  [[ "$pf" == "WARN" ]] && caveat="error_rate between 0.5% and 1.0% — caveat required in reporting"

  record_gate "$tid" "C" "endpoint" "$pf" "$reason_text" "$caveat"
done

# ---------------------------------------------------------------------------
# GATE D — Payload Equivalence
# threads, connections, duration_seconds must match
# ---------------------------------------------------------------------------
echo "--- Gate D: Payload ---"
thr_a="$(jq_field "$RESULT_A" '.run_config.threads')"
thr_b="$(jq_field "$RESULT_B" '.run_config.threads')"
conn_a="$(jq_field "$RESULT_A" '.run_config.connections')"
conn_b="$(jq_field "$RESULT_B" '.run_config.connections')"
dur_a="$(jq_field "$RESULT_A" '.run_config.duration_seconds')"
dur_b="$(jq_field "$RESULT_B" '.run_config.duration_seconds')"

for pair in "A:$TARGET_A_ID" "B:$TARGET_B_ID"; do
  IFS=: read -r _label tid <<< "$pair"

  reasons=()
  [[ "$thr_a"  != "$thr_b"  ]] && reasons+=("threads mismatch: ${thr_a:-missing} vs ${thr_b:-missing}")
  [[ "$conn_a" != "$conn_b" ]] && reasons+=("connections mismatch: ${conn_a:-missing} vs ${conn_b:-missing}")
  [[ "$dur_a"  != "$dur_b"  ]] && reasons+=("duration_seconds mismatch: ${dur_a:-missing} vs ${dur_b:-missing}")

  if [[ ${#reasons[@]} -eq 0 ]]; then
    record_gate "$tid" "D" "payload" "PASS" "threads=${thr_a}; connections=${conn_a}; duration_seconds=${dur_a}"
  else
    record_gate "$tid" "D" "payload" "FAIL" "$(IFS='; '; echo "${reasons[*]}")"
  fi
done

# ---------------------------------------------------------------------------
# GATE E — Fairness Index
# Invoke compute-fairness-index.sh; block if composite < 0.50; warn if < 0.70
# ---------------------------------------------------------------------------
echo "--- Gate E: Fairness ---"
FAIRNESS_TOOL="${REPO_ROOT}/tools/compute-fairness-index.sh"
FAIRNESS_TMPFILE="$(mktemp /tmp/fairness-index-XXXXXX.json)"

# Trap to clean up temp file
cleanup_tmp() { rm -f "$FAIRNESS_TMPFILE"; }
trap cleanup_tmp EXIT

FAIRNESS_COMPOSITE="0"
FAIRNESS_INTERPRETATION="unsuitable"
FAIRNESS_GATE_PF="FAIL"
FAIRNESS_REASON="compute-fairness-index.sh not available"

if [[ -x "$FAIRNESS_TOOL" ]]; then
  if "$FAIRNESS_TOOL" \
      --result-a "$RESULT_A" \
      --result-b "$RESULT_B" \
      --output   "$FAIRNESS_TMPFILE" >/dev/null 2>&1; then
    FAIRNESS_COMPOSITE="$(jq -r '.composite_score' "$FAIRNESS_TMPFILE")"
    FAIRNESS_INTERPRETATION="$(jq -r '.interpretation' "$FAIRNESS_TMPFILE")"
    FAIRNESS_GATE_PF="$(awk -v c="$FAIRNESS_COMPOSITE" 'BEGIN {
      if (c + 0 >= 0.70) { print "PASS"; exit }
      if (c + 0 >= 0.50) { print "WARN"; exit }
      print "FAIL"
    }')"
    FAIRNESS_REASON="composite_score=${FAIRNESS_COMPOSITE} (${FAIRNESS_INTERPRETATION})"
  else
    FAIRNESS_REASON="compute-fairness-index.sh failed — check metric fields"
  fi
else
  FAIRNESS_REASON="compute-fairness-index.sh not found or not executable at: $FAIRNESS_TOOL"
fi

fairness_caveat=""
[[ "$FAIRNESS_GATE_PF" == "WARN" ]] && fairness_caveat="composite_score < 0.70 — moderate asymmetry; require caveats in report"

for tid in "$TARGET_A_ID" "$TARGET_B_ID"; do
  record_gate "$tid" "E" "fairness" "$FAIRNESS_GATE_PF" "$FAIRNESS_REASON" "$fairness_caveat"
done

# ---------------------------------------------------------------------------
# GATE F — Error Rate
# Both error_rate_pct < 1.0; WARN if either > 0.5
# ---------------------------------------------------------------------------
echo "--- Gate F: Error Rate ---"
for pair in "A:$TARGET_A_ID:$RESULT_A" "B:$TARGET_B_ID:$RESULT_B"; do
  IFS=: read -r _label tid rfile <<< "$pair"

  error_rate="$(jq_field "$rfile" '.metrics.error_rate_pct')"
  error_rate="${error_rate:-0}"

  pf="$(awk -v er="$error_rate" 'BEGIN {
    if (er + 0 >= 1.0)  { print "FAIL"; exit }
    if (er + 0 >= 0.5)  { print "WARN"; exit }
    print "PASS"
  }')"

  caveat_f=""
  [[ "$pf" == "WARN" ]] && caveat_f="error_rate_pct=${error_rate} (> 0.5%) — publish with error caveat"

  record_gate "$tid" "F" "error" "$pf" "error_rate_pct=${error_rate}" "$caveat_f"
done

# ---------------------------------------------------------------------------
# GATE G — Measurement Window
# warmup_seconds >= 30, duration_seconds >= 60, total_requests >= 100
# ---------------------------------------------------------------------------
echo "--- Gate G: Measurement ---"
for pair in "A:$TARGET_A_ID:$RESULT_A" "B:$TARGET_B_ID:$RESULT_B"; do
  IFS=: read -r _label tid rfile <<< "$pair"

  warmup="$(jq_field "$rfile" '.run_config.warmup_seconds')"
  duration="$(jq_field "$rfile" '.run_config.duration_seconds')"
  total_req="$(jq_field "$rfile" '.metrics.total_requests')"
  warmup="${warmup:-0}"
  duration="${duration:-0}"
  total_req="${total_req:-0}"

  reasons=()
  awk -v w="$warmup"    'BEGIN { if (w+0 < 30) exit 0; exit 1 }' && reasons+=("warmup_seconds=${warmup} (want >= 30)")
  awk -v d="$duration"  'BEGIN { if (d+0 < 60) exit 0; exit 1 }' && reasons+=("duration_seconds=${duration} (want >= 60)")
  awk -v r="$total_req" 'BEGIN { if (r+0 < 100) exit 0; exit 1 }' && reasons+=("total_requests=${total_req} (want >= 100)")

  if [[ ${#reasons[@]} -eq 0 ]]; then
    record_gate "$tid" "G" "measurement" "PASS" "warmup=${warmup}s; duration=${duration}s; total_requests=${total_req}"
  else
    record_gate "$tid" "G" "measurement" "FAIL" "$(IFS='; '; echo "${reasons[*]}")"
  fi
done

# ---------------------------------------------------------------------------
# GATE H — Metadata Completeness
# run_id, timestamp, scenario, tool, env_ref must be populated (non-empty, non-null)
# ---------------------------------------------------------------------------
echo "--- Gate H: Metadata ---"
for pair in "A:$TARGET_A_ID:$RESULT_A" "B:$TARGET_B_ID:$RESULT_B"; do
  IFS=: read -r _label tid rfile <<< "$pair"

  reasons=()
  for field in run_id timestamp scenario tool env_ref; do
    val="$(jq_field "$rfile" ".${field}")"
    [[ -z "$val" || "$val" == "null" ]] && reasons+=("${field} is absent or null")
  done

  if [[ ${#reasons[@]} -eq 0 ]]; then
    record_gate "$tid" "H" "metadata" "PASS" "run_id; timestamp; scenario; tool; env_ref all present"
  else
    record_gate "$tid" "H" "metadata" "FAIL" "$(IFS='; '; echo "${reasons[*]}")"
  fi
done

# ---------------------------------------------------------------------------
# GATE I — Target Contract
# Strict baseline path: if target IDs are provided, both must be matrix-resolved,
# runnable via registry, deterministic, same-tier, same-protocol, and transport
# mode (if present) must agree with contract protocol.
# ---------------------------------------------------------------------------
echo "--- Gate I: Target Contract ---"

if [[ -z "$TARGET_A_ID_ARG" || -z "$TARGET_B_ID_ARG" ]]; then
  record_gate "$TARGET_A_ID" "I" "target_contract" "WARN" "target_contract strict baseline checks skipped: target IDs omitted (non-baseline context)"
  record_gate "$TARGET_B_ID" "I" "target_contract" "WARN" "target_contract strict baseline checks skipped: target IDs omitted (non-baseline context)"
else

transport_to_protocol() {
  local transport_mode="${1:-}"
  case "$transport_mode" in
    loopback-h1|network-h1) echo "h1" ;;
    loopback-h2|network-h2) echo "h2" ;;
    loopback-h3|network-h3) echo "h3" ;;
    *) echo "" ;;
  esac
}

declare -a gate_i_a_reasons=()
declare -a gate_i_b_reasons=()

target_a_matrix_json=""
target_b_matrix_json=""
target_a_contract_json=""
target_b_contract_json=""

target_a_matrix_err_file="$(mktemp)"
target_b_matrix_err_file="$(mktemp)"

if target_a_matrix_json="$(target_registry_matrix_row_json "$TARGET_A_ID" 2>"${target_a_matrix_err_file}")"; then
  :
else
  gate_i_a_reasons+=("matrix row missing or invalid for target_id=${TARGET_A_ID}: $(tr '\n' ' ' < "${target_a_matrix_err_file}" | sed 's/[[:space:]]\+/ /g')")
fi

if target_b_matrix_json="$(target_registry_matrix_row_json "$TARGET_B_ID" 2>"${target_b_matrix_err_file}")"; then
  :
else
  gate_i_b_reasons+=("matrix row missing or invalid for target_id=${TARGET_B_ID}: $(tr '\n' ' ' < "${target_b_matrix_err_file}" | sed 's/[[:space:]]\+/ /g')")
fi

rm -f "${target_a_matrix_err_file}" "${target_b_matrix_err_file}"

target_a_resolve_err_file="$(mktemp)"
target_b_resolve_err_file="$(mktemp)"

if resolve_target_contract "$TARGET_A_ID" 2>"${target_a_resolve_err_file}" && assert_target_contract_complete 2>>"${target_a_resolve_err_file}"; then
  target_a_contract_json="$(target_contract_to_json)"
  if resolve_target_contract "$TARGET_A_ID" 2>>"${target_a_resolve_err_file}" && assert_target_contract_complete 2>>"${target_a_resolve_err_file}"; then
    target_a_contract_json_repeat="$(target_contract_to_json)"
    if [[ "$target_a_contract_json" != "$target_a_contract_json_repeat" ]]; then
      gate_i_a_reasons+=("non-deterministic resolution for target_id=${TARGET_A_ID}")
    fi
  else
    gate_i_a_reasons+=("second resolution failed for target_id=${TARGET_A_ID}")
  fi
else
  gate_i_a_reasons+=("target mapping unresolved or non_runnable for target_id=${TARGET_A_ID}: $(tr '\n' ' ' < "${target_a_resolve_err_file}" | sed 's/[[:space:]]\+/ /g')")
fi

if resolve_target_contract "$TARGET_B_ID" 2>"${target_b_resolve_err_file}" && assert_target_contract_complete 2>>"${target_b_resolve_err_file}"; then
  target_b_contract_json="$(target_contract_to_json)"
  if resolve_target_contract "$TARGET_B_ID" 2>>"${target_b_resolve_err_file}" && assert_target_contract_complete 2>>"${target_b_resolve_err_file}"; then
    target_b_contract_json_repeat="$(target_contract_to_json)"
    if [[ "$target_b_contract_json" != "$target_b_contract_json_repeat" ]]; then
      gate_i_b_reasons+=("non-deterministic resolution for target_id=${TARGET_B_ID}")
    fi
  else
    gate_i_b_reasons+=("second resolution failed for target_id=${TARGET_B_ID}")
  fi
else
  gate_i_b_reasons+=("target mapping unresolved or non_runnable for target_id=${TARGET_B_ID}: $(tr '\n' ' ' < "${target_b_resolve_err_file}" | sed 's/[[:space:]]\+/ /g')")
fi

rm -f "${target_a_resolve_err_file}" "${target_b_resolve_err_file}"

if [[ -n "$target_a_matrix_json" && -n "$target_b_matrix_json" ]]; then
  gate_i_a_tier_matrix="$(jq -r '.tier' <<<"$target_a_matrix_json")"
  gate_i_b_tier_matrix="$(jq -r '.tier' <<<"$target_b_matrix_json")"
  gate_i_a_protocol_matrix="$(jq -r '.protocol_mode' <<<"$target_a_matrix_json")"
  gate_i_b_protocol_matrix="$(jq -r '.protocol_mode' <<<"$target_b_matrix_json")"

  if [[ "$gate_i_a_tier_matrix" != "$gate_i_b_tier_matrix" ]]; then
    gate_i_a_reasons+=("tier mismatch across matrix rows: ${TARGET_A_ID}=${gate_i_a_tier_matrix}; ${TARGET_B_ID}=${gate_i_b_tier_matrix}")
    gate_i_b_reasons+=("tier mismatch across matrix rows: ${TARGET_A_ID}=${gate_i_a_tier_matrix}; ${TARGET_B_ID}=${gate_i_b_tier_matrix}")
  fi

  if [[ "$gate_i_a_protocol_matrix" != "$gate_i_b_protocol_matrix" ]]; then
    gate_i_a_reasons+=("protocol_mode mismatch across matrix rows: ${TARGET_A_ID}=${gate_i_a_protocol_matrix}; ${TARGET_B_ID}=${gate_i_b_protocol_matrix}")
    gate_i_b_reasons+=("protocol_mode mismatch across matrix rows: ${TARGET_A_ID}=${gate_i_a_protocol_matrix}; ${TARGET_B_ID}=${gate_i_b_protocol_matrix}")
  fi
fi

if [[ -n "$target_a_contract_json" && -n "$target_b_contract_json" ]]; then
  gate_i_a_protocol="$(jq -r '.protocol_mode' <<<"$target_a_contract_json")"
  gate_i_b_protocol="$(jq -r '.protocol_mode' <<<"$target_b_contract_json")"

  if [[ "$gate_i_a_protocol" != "$gate_i_b_protocol" ]]; then
    gate_i_a_reasons+=("protocol_mode mismatch across targets: ${TARGET_A_ID}=${gate_i_a_protocol}; ${TARGET_B_ID}=${gate_i_b_protocol}")
    gate_i_b_reasons+=("protocol_mode mismatch across targets: ${TARGET_A_ID}=${gate_i_a_protocol}; ${TARGET_B_ID}=${gate_i_b_protocol}")
  fi

  trans_a_val="$(jq_field "$RESULT_A" '.transport_mode')"
  if [[ -n "$trans_a_val" ]]; then
    trans_a_protocol="$(transport_to_protocol "$trans_a_val")"
    if [[ -z "$trans_a_protocol" ]]; then
      gate_i_a_reasons+=("transport_mode=${trans_a_val} is not protocol-decodable")
    elif [[ "$trans_a_protocol" != "$gate_i_a_protocol" ]]; then
      gate_i_a_reasons+=("transport_mode=${trans_a_val} implies ${trans_a_protocol}; contract protocol_mode=${gate_i_a_protocol}")
    fi
  fi

  trans_b_val="$(jq_field "$RESULT_B" '.transport_mode')"
  if [[ -n "$trans_b_val" ]]; then
    trans_b_protocol="$(transport_to_protocol "$trans_b_val")"
    if [[ -z "$trans_b_protocol" ]]; then
      gate_i_b_reasons+=("transport_mode=${trans_b_val} is not protocol-decodable")
    elif [[ "$trans_b_protocol" != "$gate_i_b_protocol" ]]; then
      gate_i_b_reasons+=("transport_mode=${trans_b_val} implies ${trans_b_protocol}; contract protocol_mode=${gate_i_b_protocol}")
    fi
  fi
fi

if [[ ${#gate_i_a_reasons[@]} -eq 0 ]]; then
  record_gate "$TARGET_A_ID" "I" "target_contract" "PASS" "target mapping resolved; deterministic; protocol consistent"
else
  record_gate "$TARGET_A_ID" "I" "target_contract" "FAIL" "$(IFS='; '; echo "${gate_i_a_reasons[*]}")"
fi

if [[ ${#gate_i_b_reasons[@]} -eq 0 ]]; then
  record_gate "$TARGET_B_ID" "I" "target_contract" "PASS" "target mapping resolved; deterministic; protocol consistent"
else
  record_gate "$TARGET_B_ID" "I" "target_contract" "FAIL" "$(IFS='; '; echo "${gate_i_b_reasons[*]}")"
fi

fi

# ---------------------------------------------------------------------------
# Write CSV output
# ---------------------------------------------------------------------------
if [[ -n "$OUTPUT_CSV" ]]; then
  mkdir -p "$(dirname "$OUTPUT_CSV")"
  printf '%s\n' "${CSV_ROWS[@]}" > "$OUTPUT_CSV"
  echo -e "\n${GREEN}Gate report written to:${NC} $OUTPUT_CSV"
fi

# ---------------------------------------------------------------------------
# Human-readable summary
# ---------------------------------------------------------------------------
TOTAL_GATES=${#CSV_ROWS[@]}   # includes header row
DATA_ROWS=$(( TOTAL_GATES - 1 ))

echo ""
echo "============================================================"
echo "  COMPARATIVE READINESS GATE SUMMARY"
echo "  Scenario : ${SCENARIO_ID}"
echo "  Contract : ${CONTRACT_ID}"
echo "  Target A : ${TARGET_A_ID}"
echo "  Target B : ${TARGET_B_ID}"
echo "============================================================"

# Print each gate row with color
for row in "${CSV_ROWS[@]:1}"; do   # skip header
  IFS=, read -r rtid rgid rgname rpf rreason rcaveat <<< "$row"
  case "$rpf" in
    PASS) color="${GREEN}" ;;
    WARN) color="${YELLOW}" ;;
    *)    color="${RED}" ;;
  esac
  printf "  [%s%s${NC}]  Gate %-2s %-12s  %s  %s\n" \
    "$color" "$rpf" "$rgid" "(${rgname})" "$rtid" "$rreason"
  if [[ -n "$rcaveat" ]]; then
    printf "            ${YELLOW}CAVEAT${NC}: %s\n" "$rcaveat"
  fi
done

echo "------------------------------------------------------------"
TOTAL_DATA="${DATA_ROWS}"
echo -e "  ${GREEN}PASS${NC}: ${GATE_PASS} / ${TOTAL_DATA}   ${YELLOW}WARN${NC}: ${GATE_WARN} / ${TOTAL_DATA}   ${RED}FAIL${NC}: ${GATE_FAIL} / ${TOTAL_DATA}"
echo "============================================================"

# ---------------------------------------------------------------------------
# Exit code
# ---------------------------------------------------------------------------
if [[ "$GATE_FAIL" -gt 0 ]]; then
  echo -e "${RED}GATE VALIDATION FAILED — ${GATE_FAIL} gate(s) blocked.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}Gate validation complete — all gates PASS or WARN.${NC}"
exit 0
