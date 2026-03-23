#!/usr/bin/env bash
set -euo pipefail

# run-comparative.sh — Main orchestrator for comparative benchmark runs.
#
# Implements 8-stage execution model for reproducible cross-target comparison.
#
# Usage:
#   scripts/run-comparative.sh \
#     --target-a  exeris-native-community \
#     --target-b  spring-jvm-vt-tuned     \
#     --scenario-id entity-read-by-id     \
#     --contract-id fixed_contract_v1     \
#     --output-dir results/raw/entity-read-by-id/YYYYMMDD-comparative-NNN \
#     [--measurement-seconds 60]          \
#     [--warmup-seconds 60]               \
#     [--dry-run]
#
# In dry-run mode: stages 1, 2 (prerequisites only), 3 run; then writes
# dry-run-summary.json and exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_CONTRACT_REGISTRY="${REPO_ROOT}/runtime/drivers/target-contract-registry.sh"

# shellcheck source=/dev/null
source "$TARGET_CONTRACT_REGISTRY"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TARGET_A=""
TARGET_B=""
SCENARIO_ID=""
CONTRACT_ID=""
OUTPUT_DIR=""
MEASUREMENT_SECONDS="${MEASUREMENT_SECONDS:-60}"
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
DRY_RUN=0

# Default ports for sync wrapper
TARGET_A_PORT="${TARGET_A_PORT:-9001}"
TARGET_B_PORT="${TARGET_B_PORT:-9002}"

# Wrk defaults derived from fixed_contract_v1 defaults
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-32}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-a)           TARGET_A="$2";            shift 2 ;;
    --target-b)           TARGET_B="$2";            shift 2 ;;
    --scenario-id)        SCENARIO_ID="$2";         shift 2 ;;
    --contract-id)        CONTRACT_ID="$2";         shift 2 ;;
    --output-dir)         OUTPUT_DIR="$2";          shift 2 ;;
    --measurement-seconds) MEASUREMENT_SECONDS="$2"; shift 2 ;;
    --warmup-seconds)     WARMUP_SECONDS="$2";      shift 2 ;;
    --dry-run)            DRY_RUN=1;                shift 1 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Required parameter validation
# ---------------------------------------------------------------------------
missing=()
[[ -z "$TARGET_A"    ]] && missing+=("--target-a")
[[ -z "$TARGET_B"    ]] && missing+=("--target-b")
[[ -z "$SCENARIO_ID" ]] && missing+=("--scenario-id")
[[ -z "$CONTRACT_ID" ]] && missing+=("--contract-id")
[[ -z "$OUTPUT_DIR"  ]] && missing+=("--output-dir")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Required arguments missing: ${missing[*]}" >&2
  exit 1
fi

# Dependency check
for cmd in jq uuidgen date curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    # uuidgen fallback
    if [[ "$cmd" == "uuidgen" ]]; then
      if [[ ! -r /proc/sys/kernel/random/uuid ]]; then
        echo "ERROR: Neither uuidgen nor /proc/sys/kernel/random/uuid available." >&2
        exit 1
      fi
    else
      echo "ERROR: Required command '${cmd}' not found in PATH." >&2
      exit 1
    fi
  fi
done

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

ts_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

banner() {
  local title="$1"
  echo ""
  echo -e "${CYAN}# ============================================================${NC}"
  echo -e "${CYAN}# ${title}${NC}"
  echo -e "${CYAN}# ============================================================${NC}"
}

is_slice_c_exploratory_target() {
  local target_id="$1"
  case "$target_id" in
    quarkus-jvm-vt-tuned|quarkus-native-default)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

claim_scope_for_target() {
  local target_id="$1"
  if is_slice_c_exploratory_target "$target_id"; then
    echo "descriptive_only"
  else
    echo "comparison_eligible"
  fi
}

# ============================================================
# STAGE 1: Initialization
# ============================================================
banner "STAGE 1: Initialization"

SCENARIO_DIR="${REPO_ROOT}/scenarios/${SCENARIO_ID}"
SCENARIO_JSON="${SCENARIO_DIR}/scenario.json"
PAIR_MANIFEST="${SCENARIO_DIR}/comparative-pair-manifest.json"
TARGET_A_INPUT="${TARGET_A}"
TARGET_B_INPUT="${TARGET_B}"

if [[ ! -f "$SCENARIO_JSON" ]]; then
  echo "ERROR: Scenario manifest not found: $SCENARIO_JSON" >&2
  exit 1
fi
if [[ ! -f "$PAIR_MANIFEST" ]]; then
  echo "ERROR: Comparative pair manifest not found: $PAIR_MANIFEST" >&2
  exit 1
fi

# Create output directory structure early so exclusion artifacts are always emitted.
mkdir -p "${OUTPUT_DIR}/target-a"
mkdir -p "${OUTPUT_DIR}/target-b"
mkdir -p "${OUTPUT_DIR}/logs"

TARGET_A_CANONICAL="$(normalize_target_alias "$TARGET_A_INPUT")"
TARGET_B_CANONICAL="$(normalize_target_alias "$TARGET_B_INPUT")"
TARGET_A_CLAIM_SCOPE="$(claim_scope_for_target "$TARGET_A_CANONICAL")"
TARGET_B_CLAIM_SCOPE="$(claim_scope_for_target "$TARGET_B_CANONICAL")"

CLAIM_ELIGIBLE_RUN=false
if [[ "$TARGET_A_CLAIM_SCOPE" == "comparison_eligible" && "$TARGET_B_CLAIM_SCOPE" == "comparison_eligible" ]]; then
  CLAIM_ELIGIBLE_RUN=true
fi

TARGET_A_MATRIX_ROW=""
TARGET_B_MATRIX_ROW=""
TARGET_A_MATRIX_ERR_FILE="$(mktemp)"
TARGET_B_MATRIX_ERR_FILE="$(mktemp)"

if ! TARGET_A_MATRIX_ROW="$(target_registry_matrix_row_json "$TARGET_A_INPUT" 2>"${TARGET_A_MATRIX_ERR_FILE}")"; then
  TARGET_A_MATRIX_REASON="$(tr '\n' ' ' < "${TARGET_A_MATRIX_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
else
  TARGET_A_MATRIX_REASON="resolved"
fi

if ! TARGET_B_MATRIX_ROW="$(target_registry_matrix_row_json "$TARGET_B_INPUT" 2>"${TARGET_B_MATRIX_ERR_FILE}")"; then
  TARGET_B_MATRIX_REASON="$(tr '\n' ' ' < "${TARGET_B_MATRIX_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
else
  TARGET_B_MATRIX_REASON="resolved"
fi

rm -f "${TARGET_A_MATRIX_ERR_FILE}" "${TARGET_B_MATRIX_ERR_FILE}"

COMPATIBLE_TARGETS_PASS=true
COMPATIBLE_TARGETS_REASON="both targets listed in compatible_targets"
for target in "$TARGET_A_CANONICAL" "$TARGET_B_CANONICAL"; do
  if ! jq -e --arg t "$target" '.compatible_targets[] | select(.target_id == $t)' "$PAIR_MANIFEST" >/dev/null 2>&1; then
    COMPATIBLE_TARGETS_PASS=false
    COMPATIBLE_TARGETS_REASON="target '${target}' is not listed in compatible_targets of ${PAIR_MANIFEST}"
    break
  fi
done

FORBIDDEN_PAIR_PASS=true
FORBIDDEN_PAIR_REASON="pair is not forbidden"
if jq -e \
    --arg a "$TARGET_A_CANONICAL" --arg b "$TARGET_B_CANONICAL" \
    '.forbidden_pairs[] | select( (.targets | contains([$a])) and (.targets | contains([$b])) )' \
    "$PAIR_MANIFEST" >/dev/null 2>&1; then
  FORBIDDEN_PAIR_PASS=false
  FORBIDDEN_PAIR_REASON="$(jq -r --arg a "$TARGET_A_CANONICAL" --arg b "$TARGET_B_CANONICAL" \
    '.forbidden_pairs[] | select( (.targets | contains([$a])) and (.targets | contains([$b])) ) | .reason' \
    "$PAIR_MANIFEST")"
fi

SAME_TIER_PASS=false
SAME_PROTOCOL_PASS=false
SAME_TIER_REASON=""
SAME_PROTOCOL_REASON=""

if [[ -n "$TARGET_A_MATRIX_ROW" && -n "$TARGET_B_MATRIX_ROW" ]]; then
  TARGET_A_TIER_MATRIX="$(jq -r '.tier' <<<"$TARGET_A_MATRIX_ROW")"
  TARGET_B_TIER_MATRIX="$(jq -r '.tier' <<<"$TARGET_B_MATRIX_ROW")"
  TARGET_A_PROTOCOL_MATRIX="$(jq -r '.protocol_mode' <<<"$TARGET_A_MATRIX_ROW")"
  TARGET_B_PROTOCOL_MATRIX="$(jq -r '.protocol_mode' <<<"$TARGET_B_MATRIX_ROW")"

  if [[ "$TARGET_A_TIER_MATRIX" == "$TARGET_B_TIER_MATRIX" ]]; then
    SAME_TIER_PASS=true
    SAME_TIER_REASON="same tier (${TARGET_A_TIER_MATRIX})"
  else
    SAME_TIER_REASON="tier mismatch: ${TARGET_A_CANONICAL}=${TARGET_A_TIER_MATRIX}, ${TARGET_B_CANONICAL}=${TARGET_B_TIER_MATRIX}"
  fi

  if [[ "$TARGET_A_PROTOCOL_MATRIX" == "$TARGET_B_PROTOCOL_MATRIX" ]]; then
    SAME_PROTOCOL_PASS=true
    SAME_PROTOCOL_REASON="same protocol_mode (${TARGET_A_PROTOCOL_MATRIX})"
  else
    SAME_PROTOCOL_REASON="protocol_mode mismatch: ${TARGET_A_CANONICAL}=${TARGET_A_PROTOCOL_MATRIX}, ${TARGET_B_CANONICAL}=${TARGET_B_PROTOCOL_MATRIX}"
  fi
else
  SAME_TIER_REASON="matrix resolution failed: A='${TARGET_A_MATRIX_REASON}', B='${TARGET_B_MATRIX_REASON}'"
  SAME_PROTOCOL_REASON="matrix resolution failed: A='${TARGET_A_MATRIX_REASON}', B='${TARGET_B_MATRIX_REASON}'"
fi

TARGET_A_CONTRACT_JSON=""
TARGET_B_CONTRACT_JSON=""
TARGET_A_RESOLVE_REASON=""
TARGET_B_RESOLVE_REASON=""
TARGET_A_RESOLVE_ERR_FILE="$(mktemp)"
TARGET_B_RESOLVE_ERR_FILE="$(mktemp)"

if resolve_target_contract "$TARGET_A_INPUT" 2>"${TARGET_A_RESOLVE_ERR_FILE}" && assert_target_contract_complete 2>>"${TARGET_A_RESOLVE_ERR_FILE}"; then
  TARGET_A_CONTRACT_JSON="$(target_contract_to_json)"
  TARGET_A_RESOLVE_REASON="runnable target contract resolved"
else
  TARGET_A_RESOLVE_REASON="$(tr '\n' ' ' < "${TARGET_A_RESOLVE_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
fi

if resolve_target_contract "$TARGET_B_INPUT" 2>"${TARGET_B_RESOLVE_ERR_FILE}" && assert_target_contract_complete 2>>"${TARGET_B_RESOLVE_ERR_FILE}"; then
  TARGET_B_CONTRACT_JSON="$(target_contract_to_json)"
  TARGET_B_RESOLVE_REASON="runnable target contract resolved"
else
  TARGET_B_RESOLVE_REASON="$(tr '\n' ' ' < "${TARGET_B_RESOLVE_ERR_FILE}" | sed 's/[[:space:]]\+/ /g')"
fi

rm -f "${TARGET_A_RESOLVE_ERR_FILE}" "${TARGET_B_RESOLVE_ERR_FILE}"

RUNNABLE_PASS=false
RUNNABLE_REASON=""
if [[ -n "$TARGET_A_CONTRACT_JSON" && -n "$TARGET_B_CONTRACT_JSON" ]]; then
  RUNNABLE_PASS=true
  RUNNABLE_REASON="both targets resolved as runnable"
else
  RUNNABLE_REASON="target-a='${TARGET_A_RESOLVE_REASON}'; target-b='${TARGET_B_RESOLVE_REASON}'"
fi

PAIR_ELIGIBLE=true
PAIR_FAILURE_REASONS=()
if [[ "$COMPATIBLE_TARGETS_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("compatible_targets: ${COMPATIBLE_TARGETS_REASON}")
fi
if [[ "$SAME_TIER_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("same_tier: ${SAME_TIER_REASON}")
fi
if [[ "$SAME_PROTOCOL_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("same_protocol_mode: ${SAME_PROTOCOL_REASON}")
fi
if [[ "$RUNNABLE_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("runnable: ${RUNNABLE_REASON}")
fi
if [[ "$FORBIDDEN_PAIR_PASS" != true ]]; then
  PAIR_ELIGIBLE=false
  PAIR_FAILURE_REASONS+=("forbidden_pair: ${FORBIDDEN_PAIR_REASON}")
fi

jq -n \
  --arg scenario_id "$SCENARIO_ID" \
  --arg contract_id "$CONTRACT_ID" \
  --arg target_a_input "$TARGET_A_INPUT" \
  --arg target_b_input "$TARGET_B_INPUT" \
  --arg target_a_canonical "$TARGET_A_CANONICAL" \
  --arg target_b_canonical "$TARGET_B_CANONICAL" \
  --arg target_a_claim_scope "$TARGET_A_CLAIM_SCOPE" \
  --arg target_b_claim_scope "$TARGET_B_CLAIM_SCOPE" \
  --argjson claim_eligible_run "$CLAIM_ELIGIBLE_RUN" \
  --argjson pair_eligible "$PAIR_ELIGIBLE" \
  --argjson compatible_targets_pass "$COMPATIBLE_TARGETS_PASS" \
  --arg compatible_targets_reason "$COMPATIBLE_TARGETS_REASON" \
  --argjson same_tier_pass "$SAME_TIER_PASS" \
  --arg same_tier_reason "$SAME_TIER_REASON" \
  --argjson same_protocol_pass "$SAME_PROTOCOL_PASS" \
  --arg same_protocol_reason "$SAME_PROTOCOL_REASON" \
  --argjson runnable_pass "$RUNNABLE_PASS" \
  --arg runnable_reason "$RUNNABLE_REASON" \
  --argjson forbidden_pair_pass "$FORBIDDEN_PAIR_PASS" \
  --arg forbidden_pair_reason "$FORBIDDEN_PAIR_REASON" \
'{
  scenario_id: $scenario_id,
  contract_id: $contract_id,
  target_a_input: $target_a_input,
  target_b_input: $target_b_input,
  target_a_canonical: $target_a_canonical,
  target_b_canonical: $target_b_canonical,
  pair_eligible: $pair_eligible,
  claim_policy: {
    target_a_claim_scope: $target_a_claim_scope,
    target_b_claim_scope: $target_b_claim_scope,
    claim_eligible_run: $claim_eligible_run
  },
  checks: {
    compatible_targets: {
      pass: $compatible_targets_pass,
      reason: $compatible_targets_reason
    },
    same_tier: {
      pass: $same_tier_pass,
      reason: $same_tier_reason
    },
    same_protocol_mode: {
      pass: $same_protocol_pass,
      reason: $same_protocol_reason
    },
    runnable_targets: {
      pass: $runnable_pass,
      reason: $runnable_reason
    },
    forbidden_pair: {
      pass: $forbidden_pair_pass,
      reason: $forbidden_pair_reason
    }
  }
}' > "${OUTPUT_DIR}/logs/pair-eligibility.json"

if [[ "$PAIR_ELIGIBLE" != true ]]; then
  echo "CONFIG_ERROR: baseline pair eligibility failed: $(IFS=' | '; echo "${PAIR_FAILURE_REASONS[*]}")" >&2
  exit 64
fi

# Deterministic mapping guard: repeated resolution must produce the same contract.
resolve_target_contract "$TARGET_A_INPUT" || { rc=$?; exit "$rc"; }
assert_target_contract_complete || { rc=$?; exit "$rc"; }
TARGET_A_CONTRACT_JSON_REPEAT="$(target_contract_to_json)"
if [[ "$TARGET_A_CONTRACT_JSON" != "$TARGET_A_CONTRACT_JSON_REPEAT" ]]; then
  echo "CONFIG_ERROR: Non-deterministic target contract resolution for target-a '${TARGET_A_INPUT}'" >&2
  exit 64
fi

resolve_target_contract "$TARGET_B_INPUT" || { rc=$?; exit "$rc"; }
assert_target_contract_complete || { rc=$?; exit "$rc"; }
TARGET_B_CONTRACT_JSON_REPEAT="$(target_contract_to_json)"
if [[ "$TARGET_B_CONTRACT_JSON" != "$TARGET_B_CONTRACT_JSON_REPEAT" ]]; then
  echo "CONFIG_ERROR: Non-deterministic target contract resolution for target-b '${TARGET_B_INPUT}'" >&2
  exit 64
fi

TARGET_A="$(jq -r '.target_id' <<<"$TARGET_A_CONTRACT_JSON")"
TARGET_B="$(jq -r '.target_id' <<<"$TARGET_B_CONTRACT_JSON")"
TARGET_A_PROTOCOL_MODE="$(jq -r '.protocol_mode' <<<"$TARGET_A_CONTRACT_JSON")"
TARGET_B_PROTOCOL_MODE="$(jq -r '.protocol_mode' <<<"$TARGET_B_CONTRACT_JSON")"

if [[ "$TARGET_A_PROTOCOL_MODE" != "$TARGET_B_PROTOCOL_MODE" ]]; then
  echo "CONFIG_ERROR: protocol_mode mismatch between resolved targets: ${TARGET_A}=${TARGET_A_PROTOCOL_MODE}, ${TARGET_B}=${TARGET_B_PROTOCOL_MODE}" >&2
  exit 64
fi

TARGET_A_TIER="$(jq -r '.tier' <<<"$TARGET_A_CONTRACT_JSON")"
TARGET_B_TIER="$(jq -r '.tier' <<<"$TARGET_B_CONTRACT_JSON")"
if [[ "$TARGET_A_TIER" != "$TARGET_B_TIER" ]]; then
  echo "CONFIG_ERROR: tier mismatch between resolved targets: ${TARGET_A}=${TARGET_A_TIER}, ${TARGET_B}=${TARGET_B_TIER}" >&2
  exit 64
fi

COMPARATIVE_ID="$(gen_uuid)"
TIMESTAMP_UTC="$(ts_now_utc)"

jq -n \
  --arg target_a_input "$TARGET_A_INPUT" \
  --arg target_b_input "$TARGET_B_INPUT" \
  --argjson target_a_contract "$TARGET_A_CONTRACT_JSON" \
  --argjson target_b_contract "$TARGET_B_CONTRACT_JSON" \
'{
  target_a_input: $target_a_input,
  target_b_input: $target_b_input,
  target_a_contract: $target_a_contract,
  target_b_contract: $target_b_contract
}' > "${OUTPUT_DIR}/logs/resolved-target-contracts.json"

echo "  comparative_id       : ${COMPARATIVE_ID}"
echo "  timestamp_utc        : ${TIMESTAMP_UTC}"
echo "  scenario_id          : ${SCENARIO_ID}"
echo "  contract_id          : ${CONTRACT_ID}"
echo "  target_a_input       : ${TARGET_A_INPUT}"
echo "  target_b_input       : ${TARGET_B_INPUT}"
echo "  target_a             : ${TARGET_A}"
echo "  target_b             : ${TARGET_B}"
echo "  target_a_claim_scope : ${TARGET_A_CLAIM_SCOPE}"
echo "  target_b_claim_scope : ${TARGET_B_CLAIM_SCOPE}"
echo "  claim_eligible_run   : ${CLAIM_ELIGIBLE_RUN}"
echo "  protocol_mode        : ${TARGET_A_PROTOCOL_MODE}"
echo "  measurement_seconds  : ${MEASUREMENT_SECONDS}"
echo "  warmup_seconds       : ${WARMUP_SECONDS}"
echo "  output_dir           : ${OUTPUT_DIR}"
echo "  dry_run              : ${DRY_RUN}"
echo "  target_a_port        : ${TARGET_A_PORT}"
echo "  target_b_port        : ${TARGET_B_PORT}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "${YELLOW}  [DRY RUN MODE ACTIVE]${NC}"
fi

# ============================================================
# STAGE 2: Pre-flight gate validation
# ============================================================
banner "STAGE 2: Pre-flight Gate Validation"

# Always: verify structural prerequisites
echo "  Checking scenario manifest..."
if ! jq -e ".fixed_contracts.\"${CONTRACT_ID}\"" "$SCENARIO_JSON" >/dev/null 2>&1; then
  echo "ERROR: contract_id '${CONTRACT_ID}' not found in ${SCENARIO_JSON}#fixed_contracts" >&2
  exit 1
fi
echo -e "  ${GREEN}✓${NC} contract_id '${CONTRACT_ID}' found in scenario manifest."

echo "  Checking output-dir writability..."
if ! touch "${OUTPUT_DIR}/.write-check" 2>/dev/null; then
  echo "ERROR: output-dir is not writable: ${OUTPUT_DIR}" >&2
  exit 1
fi
rm -f "${OUTPUT_DIR}/.write-check"
echo -e "  ${GREEN}✓${NC} output-dir writable."

echo "  Checking both targets declared in pair manifest..."
echo -e "  ${GREEN}✓${NC} Both targets verified in comparative-pair-manifest.json."

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo -e "  ${YELLOW}[DRY RUN] Skipping result-file gate validation (no existing result files required).${NC}"
else
  # In non-dry-run, attempt gate validation if result files already exist
  RESULT_A_PATH="${OUTPUT_DIR}/target-a/result.json"
  RESULT_B_PATH="${OUTPUT_DIR}/target-b/result.json"
  GATE_SCRIPT="${REPO_ROOT}/scripts/validate-comparative-readiness.sh"

  if [[ -f "$RESULT_A_PATH" && -f "$RESULT_B_PATH" && -x "$GATE_SCRIPT" ]]; then
    echo "  Running pre-flight gate validation against existing result files..."
    if ! "$GATE_SCRIPT" \
        --result-a    "$RESULT_A_PATH" \
        --result-b    "$RESULT_B_PATH" \
      --target-a-id "$TARGET_A" \
      --target-b-id "$TARGET_B" \
        --scenario-id "$SCENARIO_ID" \
        --contract-id "$CONTRACT_ID" \
        --output      "${OUTPUT_DIR}/logs/preflight-gate-report.csv"; then
      echo "ERROR: Pre-flight gate validation failed." >&2
      exit 1
    fi
  else
    echo -e "  ${YELLOW}No existing result files — skipping pre-flight gate validation.${NC}"
  fi
fi

# ============================================================
# STAGE 3: Infrastructure preparation
# ============================================================
banner "STAGE 3: Infrastructure Preparation"

echo "  NOTE: TARGET LAUNCH IS EXTERNAL — run targets manually before stage 4 if not using --dry-run."
echo "  Infrastructure preparation is provider-specific."
echo "  This stage writes a completion marker only."

touch "${OUTPUT_DIR}/stage3-complete.marker"
echo -e "  ${GREEN}✓${NC} stage3-complete.marker written."

# ---------------------------------------------------------------------------
# DRY RUN early exit — after stage 3
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  banner "DRY RUN COMPLETE"

  jq -n \
    --arg comparative_id   "$COMPARATIVE_ID" \
    --arg timestamp_utc    "$TIMESTAMP_UTC" \
    --arg scenario_id      "$SCENARIO_ID" \
    --arg contract_id      "$CONTRACT_ID" \
    --arg target_a         "$TARGET_A" \
    --arg target_b         "$TARGET_B" \
    --argjson measurement  "$MEASUREMENT_SECONDS" \
    --argjson warmup       "$WARMUP_SECONDS" \
    --arg output_dir       "$OUTPUT_DIR" \
  '{
    dry_run:            true,
    comparative_id:     $comparative_id,
    timestamp_utc:      $timestamp_utc,
    scenario_id:        $scenario_id,
    contract_id:        $contract_id,
    target_a:           $target_a,
    target_b:           $target_b,
    measurement_seconds: $measurement,
    warmup_seconds:     $warmup,
    output_dir:         $output_dir,
    stages_executed:    ["1-initialization","2-preflight","3-infrastructure"],
    preflight_passed:   true
  }' > "${OUTPUT_DIR}/dry-run-summary.json"

  echo -e "${GREEN}DRY RUN COMPLETE — pre-flight checks passed.${NC}"
  echo -e "  Summary: ${OUTPUT_DIR}/dry-run-summary.json"
  exit 0
fi

# ============================================================
# STAGE 4: Synchronized launch
# ============================================================
banner "STAGE 4: Synchronized Launch"

SYNC_WRAPPER="${REPO_ROOT}/targets/launcher-sync-wrapper.sh"

if [[ -x "$SYNC_WRAPPER" ]]; then
  "$SYNC_WRAPPER" \
    --target-a-id    "$TARGET_A" \
    --target-a-port  "$TARGET_A_PORT" \
    --target-b-id    "$TARGET_B" \
    --target-b-port  "$TARGET_B_PORT" \
    --output-dir     "${OUTPUT_DIR}/logs"
else
  echo -e "${YELLOW}WARN${NC}: launcher-sync-wrapper.sh not found or not executable; writing timestamp manually." >&2
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ > "${OUTPUT_DIR}/logs/measurement-start-timestamp.txt"
fi

echo -e "  ${GREEN}✓${NC} Stage 4 complete."

# ============================================================
# STAGE 5: Parallel measurement
# ============================================================
banner "STAGE 5: Parallel Measurement"

# NOTE: Sequential measurement introduces timing asymmetry. Parallel measurement
# requires background processes and merged output; deferred to Phase 6.3.2.

ENDPOINT_A="/api/v1/entities/1"
ENDPOINT_B="/api/v1/entities/1"

run_wrk_target() {
  local target_id="$1"
  local port="$2"
  local outdir="$3"
  local endpoint="$4"

  echo "  Running warmup for ${target_id} (${WARMUP_SECONDS}s, discarded)..."
  wrk -t"${THREADS}" -c"${CONNECTIONS}" -d"${WARMUP_SECONDS}s" \
    "http://localhost:${port}${endpoint}" > /dev/null 2>&1 || true

  echo "  Running measurement for ${target_id} (${MEASUREMENT_SECONDS}s)..."
  wrk -t"${THREADS}" -c"${CONNECTIONS}" -d"${MEASUREMENT_SECONDS}s" \
    "http://localhost:${port}${endpoint}" 2>&1 | tee "${outdir}/wrk-raw.txt"
}

parse_wrk_to_result() {
  local wrk_raw="$1"
  local outfile="$2"
  local target_id="$3"
  local run_ts="$4"
  local target_contract_json="$5"
  local claim_scope="$6"

  local env_ref tier protocol_mode transport_mode
  env_ref="$(jq -r '.env_file' <<<"$target_contract_json")"
  tier="$(jq -r '.tier' <<<"$target_contract_json")"
  protocol_mode="$(jq -r '.protocol_mode' <<<"$target_contract_json")"
  transport_mode="loopback-${protocol_mode}"

  # Extract key metrics from wrk output using awk
  local rps latency_mean_ms latency_stdev_ms latency_p50 latency_p75 latency_p90 latency_p99
  local total_requests total_errors

  rps="$(grep -oP 'Requests/sec:\s+\K[\d.]+' "$wrk_raw" || echo "0")"
  latency_mean_ms="$(grep -oP '^\s+Latency\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" || echo "0us")"
  total_requests="$(grep -oP '(\d+) requests' "$wrk_raw" | head -1 | grep -oP '^\d+' || echo "0")"
  total_errors="$(grep -oP 'Non-2xx or 3xx responses:\s+\K\d+' "$wrk_raw" || echo "0")"

  # Parse latency distribution lines (Thread Stats section may include percentile table)
  # wrk2 outputs explicit percentile columns; plain wrk may not — default to 0 for missing
  p50="$(grep -oP '50\.00%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" || echo "0us")"
  p75="$(grep -oP '75\.00%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" || echo "0us")"
  p90="$(grep -oP '90\.00%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" || echo "0us")"
  p99="$(grep -oP '99\.00%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" || echo "0us")"
  p95="$(grep -oP '95\.00%\s+\K[\d.]+(?:us|ms|s)' "$wrk_raw" || echo "0us")"

  # Use existing repo to_us convention — inline awk conversion
  to_us() {
    local token="$1"
    if [[ -z "$token" || "$token" == "0us" ]]; then echo "0"; return; fi
    awk -v tok="$token" 'BEGIN {
      match(tok, /^([0-9]*\.?[0-9]+)(us|ms|s)$/, arr)
      v = arr[1]; u = arr[2]
      if (u == "us") printf "%.6f", v
      else if (u == "ms") printf "%.6f", v * 1000
      else if (u == "s") printf "%.6f", v * 1000000
      else printf "0"
    }'
  }

  local rps_final="${rps:-0}"
  local total_req_final="${total_requests:-0}"
  local total_err_final="${total_errors:-0}"
  local error_rate_pct="0"
  if [[ "$total_req_final" -gt 0 ]] 2>/dev/null; then
    error_rate_pct="$(awk -v e="$total_err_final" -v t="$total_req_final" \
      'BEGIN { printf "%.4f", (e / t) * 100 }')"
  fi

  local p50_us p75_us p90_us p95_us p99_us
  p50_us="$(to_us "$p50")"
  p75_us="$(to_us "$p75")"
  p90_us="$(to_us "$p90")"
  p95_us="$(to_us "$p95")"
  p99_us="$(to_us "$p99")"

  local run_id="${SCENARIO_ID}-${run_ts}-000000"

  jq -n \
    --arg schema_version      "1" \
    --arg run_id              "$run_id" \
    --arg timestamp           "$(ts_now_utc)" \
    --arg scenario            "$SCENARIO_ID" \
    --arg tool                "wrk" \
    --arg env_ref             "$env_ref" \
    --arg transport_mode      "$transport_mode" \
    --arg tier                "$tier" \
    --arg protocol_mode       "$protocol_mode" \
    --arg target_id           "$target_id" \
    --arg contract_id         "$CONTRACT_ID" \
    --arg claim_scope         "$claim_scope" \
    --argjson target_contract "$target_contract_json" \
    --argjson throughput_rps  "$rps_final" \
    --argjson latency_p50_us  "$p50_us" \
    --argjson latency_p75_us  "$p75_us" \
    --argjson latency_p90_us  "$p90_us" \
    --argjson latency_p95_us  "$p95_us" \
    --argjson latency_p99_us  "$p99_us" \
    --argjson error_rate_pct  "$error_rate_pct" \
    --argjson total_requests  "$total_req_final" \
    --argjson total_errors    "$total_err_final" \
    --argjson duration_seconds "$MEASUREMENT_SECONDS" \
    --argjson warmup_seconds  "$WARMUP_SECONDS" \
    --argjson threads         "$THREADS" \
    --argjson connections     "$CONNECTIONS" \
  '{
    schema_version:      $schema_version,
    run_id:              $run_id,
    timestamp:           $timestamp,
    scenario:            $scenario,
    tool:                $tool,
    env_ref:             $env_ref,
    transport_mode:      $transport_mode,
    target: {
      tier:     $tier,
      repo:     $target_id,
      protocol: $protocol_mode
    },
    run_config: {
      duration_seconds: $duration_seconds,
      warmup_seconds:   $warmup_seconds,
      threads:          $threads,
      connections:      $connections,
      contract_id:      $contract_id,
      target_contract:  $target_contract
    },
    metrics: {
      throughput_rps:  $throughput_rps,
      latency_p50_us:  $latency_p50_us,
      latency_p75_us:  $latency_p75_us,
      latency_p90_us:  $latency_p90_us,
      latency_p95_us:  $latency_p95_us,
      latency_p99_us:  $latency_p99_us,
      error_rate_pct:  $error_rate_pct,
      total_requests:  $total_requests,
      total_errors:    $total_errors
    },
    claim_scope:             $claim_scope,
    runner_status:           "success",
    reproducibility_status:  "complete"
  }' > "$outfile"
}

RUN_TS="$(date -u +%Y%m%d-%H%M%S)"

if ! command -v wrk >/dev/null 2>&1; then
  echo -e "${RED}ERROR${NC}: wrk is not installed or not in PATH. Install wrk to run measurement." >&2
  exit 1
fi

run_wrk_target "$TARGET_A" "$TARGET_A_PORT" "${OUTPUT_DIR}/target-a" "$ENDPOINT_A"
parse_wrk_to_result \
  "${OUTPUT_DIR}/target-a/wrk-raw.txt" \
  "${OUTPUT_DIR}/target-a/result.json" \
  "$TARGET_A" \
  "$RUN_TS" \
  "$TARGET_A_CONTRACT_JSON" \
  "$TARGET_A_CLAIM_SCOPE"
echo -e "  ${GREEN}✓${NC} target-a measurement complete."

run_wrk_target "$TARGET_B" "$TARGET_B_PORT" "${OUTPUT_DIR}/target-b" "$ENDPOINT_B"
parse_wrk_to_result \
  "${OUTPUT_DIR}/target-b/wrk-raw.txt" \
  "${OUTPUT_DIR}/target-b/result.json" \
  "$TARGET_B" \
  "$RUN_TS" \
  "$TARGET_B_CONTRACT_JSON" \
  "$TARGET_B_CLAIM_SCOPE"
echo -e "  ${GREEN}✓${NC} target-b measurement complete."

# ============================================================
# STAGE 6: Cooldown
# ============================================================
banner "STAGE 6: Cooldown"

echo "  Sleeping 5s for target cooldown..."
sleep 5
touch "${OUTPUT_DIR}/stage6-complete.marker"
echo -e "  ${GREEN}✓${NC} stage6-complete.marker written."

# ============================================================
# STAGE 7: Post-flight validation
# ============================================================
banner "STAGE 7: Post-flight Validation"

RESULT_A_PATH="${OUTPUT_DIR}/target-a/result.json"
RESULT_B_PATH="${OUTPUT_DIR}/target-b/result.json"
GATE_SCRIPT="${REPO_ROOT}/scripts/validate-comparative-readiness.sh"
GATE_CSV="${OUTPUT_DIR}/stage7-gate-report.csv"

QUARANTINE_DIR="${REPO_ROOT}/quarantine"
POSTFLIGHT_OK=1

if [[ -f "$RESULT_A_PATH" && -f "$RESULT_B_PATH" && -x "$GATE_SCRIPT" ]]; then
  if ! "$GATE_SCRIPT" \
      --result-a    "$RESULT_A_PATH" \
      --result-b    "$RESULT_B_PATH" \
      --target-a-id "$TARGET_A" \
      --target-b-id "$TARGET_B" \
      --scenario-id "$SCENARIO_ID" \
      --contract-id "$CONTRACT_ID" \
      --output      "$GATE_CSV"; then
    if [[ "$CLAIM_ELIGIBLE_RUN" == true ]]; then
      echo -e "${YELLOW}WARN${NC}: Post-flight gate validation failed for comparison-eligible run. Moving output to quarantine." >&2
      mkdir -p "$QUARANTINE_DIR"
      mv "$OUTPUT_DIR" "${QUARANTINE_DIR}/$(basename "$OUTPUT_DIR")"
      echo "  Results quarantined at: ${QUARANTINE_DIR}/$(basename "$OUTPUT_DIR")"
      POSTFLIGHT_OK=0
      # Exit 0 per policy — notify but do not hard-fail orchestrator
      exit 0
    fi

    echo -e "${YELLOW}WARN${NC}: Post-flight gate validation failed, but run is descriptive-only exploratory (claim_eligible_run=false); continuing without quarantine." >&2
    POSTFLIGHT_OK=0
  else
    echo -e "  ${GREEN}✓${NC} Post-flight gate validation passed."
    echo "  Gate report: ${GATE_CSV}"

    if [[ "$CLAIM_ELIGIBLE_RUN" == true ]]; then
      if [[ -f "$GATE_CSV" ]] && grep -q ',WARN,' "$GATE_CSV"; then
        echo -e "${YELLOW}WARN${NC}: Gate report contains WARN rows for a comparison-eligible run; quarantining output to enforce PASS-only claims." >&2
        mkdir -p "$QUARANTINE_DIR"
        mv "$OUTPUT_DIR" "${QUARANTINE_DIR}/$(basename "$OUTPUT_DIR")"
        echo "  Results quarantined at: ${QUARANTINE_DIR}/$(basename "$OUTPUT_DIR")"
        POSTFLIGHT_OK=0
        exit 0
      fi
    else
      echo "  Run classification: descriptive-only exploratory (claim_eligible_run=false)."
    fi
  fi
else
  echo -e "  ${YELLOW}WARN${NC}: Skipping post-flight gate validation (result files or gate script missing)."
fi

# ============================================================
# STAGE 8: Result aggregation
# ============================================================
banner "STAGE 8: Result Aggregation"

FAIRNESS_TOOL="${REPO_ROOT}/tools/compute-fairness-index.sh"
FAIRNESS_OUT="${OUTPUT_DIR}/fairness-index.json"
COMPARATIVE_OUT="${OUTPUT_DIR}/comparative-result.json"
REPORT_MD="${OUTPUT_DIR}/comparative-report.md"

# Compute fairness index
if [[ -x "$FAIRNESS_TOOL" && -f "$RESULT_A_PATH" && -f "$RESULT_B_PATH" ]]; then
  "$FAIRNESS_TOOL" \
    --result-a "$RESULT_A_PATH" \
    --result-b "$RESULT_B_PATH" \
    --output   "$FAIRNESS_OUT"
  echo -e "  ${GREEN}✓${NC} Fairness index computed."
else
  echo -e "${YELLOW}WARN${NC}: compute-fairness-index.sh not available; writing empty fairness stub." >&2
  jq -n \
    --arg ts "$(ts_now_utc)" \
    --arg ta "$TARGET_A" \
    --arg tb "$TARGET_B" \
  '{
    error_symmetry: 0, latency_symmetry: 0,
    throughput_confidence: 0, composite_score: 0,
    interpretation: "unsuitable",
    computed_at: $ts,
    targets: [$ta, $tb],
    asymmetry_notes: ["fairness tool unavailable"]
  }' > "$FAIRNESS_OUT"
fi

# Build gate_status from CSV if available
build_gate_status() {
  if [[ -f "$GATE_CSV" ]]; then
    jq -Rs '
      split("\n") |
      map(select(length > 0)) |
      .[1:] |
      map(split(",")) |
      group_by(.[1]) |
      map({
        key: (.[0][1]),
        value: {
          pass_fail: (map(select(.[3] == "FAIL")) | if length > 0 then "FAIL"
                      else (map(select(.[3] == "WARN")) | if length > 0 then "WARN" else "PASS" end)
                      end),
          reason: (.[0][4] // "")
        }
      }) |
      from_entries |
      {
        maturity:    (.A // {pass_fail: "WARN", reason: "gate not run"}),
        equivalence: (.B // {pass_fail: "WARN", reason: "gate not run"}),
        endpoint:    (.C // {pass_fail: "WARN", reason: "gate not run"}),
        payload:     (.D // {pass_fail: "WARN", reason: "gate not run"}),
        fairness:    (.E // {pass_fail: "WARN", reason: "gate not run"}),
        error:       (.F // {pass_fail: "WARN", reason: "gate not run"}),
        measurement: (.G // {pass_fail: "WARN", reason: "gate not run"}),
        metadata:    (.H // {pass_fail: "WARN", reason: "gate not run"})
      }
    ' "$GATE_CSV"
  else
    jq -n '{
      maturity:    {pass_fail: "WARN", reason: "post-flight gate validation not run"},
      equivalence: {pass_fail: "WARN", reason: "post-flight gate validation not run"},
      endpoint:    {pass_fail: "WARN", reason: "post-flight gate validation not run"},
      payload:     {pass_fail: "WARN", reason: "post-flight gate validation not run"},
      fairness:    {pass_fail: "WARN", reason: "post-flight gate validation not run"},
      error:       {pass_fail: "WARN", reason: "post-flight gate validation not run"},
      measurement: {pass_fail: "WARN", reason: "post-flight gate validation not run"},
      metadata:    {pass_fail: "WARN", reason: "post-flight gate validation not run"}
    }'
  fi
}

GATE_STATUS_JSON="$(build_gate_status)"

# Assemble per-target metric summaries
build_target_entry() {
  local rfile="$1"
  local target_id="$2"

  # Load maturity info from pair manifest
  local maturity tier protocol transport
  maturity="$(jq -r --arg t "$target_id" '.compatible_targets[] | select(.target_id==$t) | .maturity_level // "unknown"' "$PAIR_MANIFEST")"
  tier="$(jq -r --arg t "$target_id" '.compatible_targets[] | select(.target_id==$t) | .tier // "community"' "$PAIR_MANIFEST")"
  protocol="$(jq -r --arg t "$target_id" '.compatible_targets[] | select(.target_id==$t) | .protocol_mode // "h1"' "$PAIR_MANIFEST")"
  transport="$(jq -r --arg t "$target_id" '.compatible_targets[] | select(.target_id==$t) | .transport_mode // "loopback-h1"' "$PAIR_MANIFEST")"

  jq -n \
    --arg target_id     "$target_id" \
    --arg maturity      "${maturity:-unknown}" \
    --arg tier          "${tier:-community}" \
    --arg protocol_mode "${protocol:-h1}" \
    --arg transport     "${transport:-loopback-h1}" \
    --slurpfile result  "$rfile" \
  '{
    target_id:      $target_id,
    maturity_level: $maturity,
    tier:           $tier,
    protocol_mode:  $protocol_mode,
    transport_mode: $transport,
    metrics: {
      throughput_rps: ($result[0].metrics.throughput_rps // 0),
      latency_p50_us: ($result[0].metrics.latency_p50_us // 0),
      latency_p75_us: ($result[0].metrics.latency_p75_us // 0),
      latency_p90_us: ($result[0].metrics.latency_p90_us // 0),
      latency_p95_us: ($result[0].metrics.latency_p95_us // 0),
      latency_p99_us: ($result[0].metrics.latency_p99_us // 0),
      error_rate_pct: ($result[0].metrics.error_rate_pct // 0),
      total_requests: ($result[0].metrics.total_requests // 0),
      total_errors:   ($result[0].metrics.total_errors // 0)
    }
  }'
}

TARGET_A_ENTRY="$(build_target_entry "$RESULT_A_PATH" "$TARGET_A")"
TARGET_B_ENTRY="$(build_target_entry "$RESULT_B_PATH" "$TARGET_B")"
FAIRNESS_JSON="$(cat "$FAIRNESS_OUT")"

jq -n \
  --arg comparative_id     "$COMPARATIVE_ID" \
  --arg timestamp_utc      "$TIMESTAMP_UTC" \
  --arg scenario_id        "$SCENARIO_ID" \
  --arg contract_id        "$CONTRACT_ID" \
  --argjson measurement    "$MEASUREMENT_SECONDS" \
  --argjson warmup         "$WARMUP_SECONDS" \
  --argjson target_a       "$TARGET_A_ENTRY" \
  --argjson target_b       "$TARGET_B_ENTRY" \
  --argjson fairness_index "$FAIRNESS_JSON" \
  --argjson gate_status    "$GATE_STATUS_JSON" \
'{
  comparative_id:     $comparative_id,
  timestamp_utc:      $timestamp_utc,
  scenario_id:        $scenario_id,
  contract_id:        $contract_id,
  measurement_seconds: $measurement,
  warmup_seconds:     $warmup,
  targets:            [$target_a, $target_b],
  fairness_index:     $fairness_index,
  gate_status:        $gate_status
}' > "$COMPARATIVE_OUT"

echo -e "  ${GREEN}✓${NC} comparative-result.json written: ${COMPARATIVE_OUT}"

# Generate markdown report
{
  echo "# Comparative Benchmark Report"
  echo ""
  echo "| Field               | Value                          |"
  echo "|---------------------|--------------------------------|"
  echo "| comparative_id      | ${COMPARATIVE_ID}              |"
  echo "| scenario_id         | ${SCENARIO_ID}                 |"
  echo "| contract_id         | ${CONTRACT_ID}                 |"
  echo "| timestamp_utc       | ${TIMESTAMP_UTC}               |"
  echo "| measurement_seconds | ${MEASUREMENT_SECONDS}         |"
  echo "| warmup_seconds      | ${WARMUP_SECONDS}              |"
  echo ""
  echo "## Metrics"
  echo ""
  echo "| Metric              | ${TARGET_A}    | ${TARGET_B}    |"
  echo "|---------------------|----------------|----------------|"
  jq -r --argjson a "$TARGET_A_ENTRY" --argjson b "$TARGET_B_ENTRY" -n '
    "| throughput_rps      | \($a.metrics.throughput_rps) | \($b.metrics.throughput_rps) |",
    "| latency_p50_us      | \($a.metrics.latency_p50_us) | \($b.metrics.latency_p50_us) |",
    "| latency_p95_us      | \($a.metrics.latency_p95_us) | \($b.metrics.latency_p95_us) |",
    "| latency_p99_us      | \($a.metrics.latency_p99_us) | \($b.metrics.latency_p99_us) |",
    "| error_rate_pct      | \($a.metrics.error_rate_pct) | \($b.metrics.error_rate_pct) |"
  '
  echo ""
  echo "## Fairness Index"
  echo ""
  COMPOSITE="$(jq -r '.composite_score' "$FAIRNESS_OUT")"
  INTERP="$(jq -r '.interpretation' "$FAIRNESS_OUT")"
  echo "| composite_score | ${COMPOSITE} |"
  echo "| interpretation  | **${INTERP}** |"
  echo ""
  echo "> Axis labels: tier=community | protocol_mode=h1 | transport_mode=loopback-h1 | benchmark_family=runtime-wrk"
  echo ""
  echo "_Generated by run-comparative.sh — Phase 6.3_"
} > "$REPORT_MD"

echo -e "  ${GREEN}✓${NC} comparative-report.md written: ${REPORT_MD}"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  COMPARATIVE RUN COMPLETE${NC}"
echo -e "${GREEN}  comparative_id : ${COMPARATIVE_ID}${NC}"
echo -e "${GREEN}  output_dir     : ${OUTPUT_DIR}${NC}"
echo -e "${GREEN}============================================================${NC}"
