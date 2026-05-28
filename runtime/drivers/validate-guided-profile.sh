#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-guided-profile.sh --profile <path> [--schema <path>] [--dispatch-compatible] [--confirm-comparison-eligibility]

Validates guided run profile JSON parseability, schema compliance, and semantic guards.
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PROFILE_PATH=""
SCHEMA_PATH="${REPO_ROOT}/runtime/profiles/guided-run-profile.schema.json"
DISPATCH_COMPATIBLE=0
CONFIRM_COMPARISON_ELIGIBILITY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE_PATH="$2"
      shift 2
      ;;
    --schema)
      SCHEMA_PATH="$2"
      shift 2
      ;;
    --dispatch-compatible)
      DISPATCH_COMPATIBLE=1
      shift
      ;;
    --confirm-comparison-eligibility)
      CONFIRM_COMPARISON_ELIGIBILITY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$PROFILE_PATH" ]] || fail "Missing required argument: --profile"
[[ -f "$PROFILE_PATH" ]] || fail "Profile file not found: $PROFILE_PATH"
[[ -f "$SCHEMA_PATH" ]] || fail "Schema file not found: $SCHEMA_PATH"

parse_json_file() {
  local path="$1"
  if command -v jq >/dev/null 2>&1; then
    jq empty "$path" >/dev/null
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY' >/dev/null
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    json.load(f)
PY
    return 0
  fi

  return 2
}

if parse_json_file "$PROFILE_PATH"; then
  pass "JSON parseable: $PROFILE_PATH"
else
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    fail "Cannot parse JSON: neither jq nor python3 is available"
  fi
  fail "Invalid JSON: $PROFILE_PATH"
fi

validate_schema() {
  local schema="$1"
  local data="$2"

  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$schema" "$data" >/dev/null
    echo "check-jsonschema"
    return 0
  fi

  if command -v ajv >/dev/null 2>&1; then
    if ajv validate --spec=draft2020 -s "$schema" -d "$data" >/dev/null 2>&1; then
      echo "ajv"
      return 0
    fi
    if ajv validate -s "$schema" -d "$data" >/dev/null 2>&1; then
      echo "ajv"
      return 0
    fi
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$schema" "$data" <<'PY'
import json
import sys

schema_path = sys.argv[1]
data_path = sys.argv[2]

try:
    from jsonschema import Draft202012Validator
except Exception:
    print("ERROR: python3 fallback requires jsonschema (pip install jsonschema)", file=sys.stderr)
    sys.exit(2)

with open(schema_path, "r", encoding="utf-8") as sf:
    schema = json.load(sf)
with open(data_path, "r", encoding="utf-8") as df:
    data = json.load(df)

validator = Draft202012Validator(schema)
errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
if errors:
    first = errors[0]
    instance_path = ".".join(str(p) for p in first.path) if first.path else "$"
    schema_path_str = ".".join(str(p) for p in first.schema_path) if first.schema_path else "$"
    print(f"ERROR: Schema validation failed: {first.message}", file=sys.stderr)
    print(f"  instance path: {instance_path}", file=sys.stderr)
    print(f"  schema path: {schema_path_str}", file=sys.stderr)
    sys.exit(1)
PY
    then
      echo "python3+jsonschema"
      return 0
    fi

    py_rc=$?
    if [[ "$py_rc" -eq 2 ]]; then
      return 2
    fi
    return 1
  fi

  return 3
}

if validator_name="$(validate_schema "$SCHEMA_PATH" "$PROFILE_PATH")"; then
  pass "Schema validation: $validator_name"
else
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    fail "Schema validator unavailable: python3 found but jsonschema module missing"
  fi
  if [[ "$rc" -eq 3 ]]; then
    fail "No schema validator available. Tried: check-jsonschema, ajv, python3+jsonschema"
  fi
  fail "Schema validation failed"
fi

read_scalar() {
  local expr="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$expr // empty" "$PROFILE_PATH"
    return
  fi

  python3 - "$PROFILE_PATH" "$expr" <<'PY'
import json
import sys

path = sys.argv[2]
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

if path == ".target_mode":
    val = data.get("target_mode", "")
elif path == ".run_type":
    val = data.get("run_type", "")
elif path == ".claim_scope":
    val = data.get("claim_scope", "")
elif path == ".benchmark_family":
  val = data.get("benchmark_family", "")
elif path == ".protocol_mode":
  val = data.get("protocol_mode", "")
elif path == ".tier":
  val = data.get("tier", "")
elif path == ".target_classification":
  val = data.get("target_classification", "")
elif path == ".fairness_attestations.payload_equivalent":
  val = data.get("fairness_attestations", {}).get("payload_equivalent", "")
elif path == ".fairness_attestations.concurrency_equivalent":
  val = data.get("fairness_attestations", {}).get("concurrency_equivalent", "")
elif path == ".fairness_attestations.protocol_mode_equivalent":
  val = data.get("fairness_attestations", {}).get("protocol_mode_equivalent", "")
elif path == ".fairness_attestations.target_scope_equivalent":
  val = data.get("fairness_attestations", {}).get("target_scope_equivalent", "")
elif path == ".connectivity":
  val = data.get("connectivity", "")
elif path == ".driver":
  val = data.get("driver", "")
elif path == ".scenario_id":
  val = data.get("scenario_id", "")
elif path == ".graph_track":
  val = data.get("graph_track", "")
elif path == ".network_impairment.enabled":
  val = data.get("network_impairment", {}).get("enabled", "")
elif path == ".network_impairment.applied_to":
  val = data.get("network_impairment", {}).get("applied_to", "")
elif path == ".network_impairment.profile":
  val = data.get("network_impairment", {}).get("profile", "")
elif path == ".network_impairment.delay_ms":
  val = data.get("network_impairment", {}).get("delay_ms", "")
elif path == ".network_impairment.loss_pct":
  val = data.get("network_impairment", {}).get("loss_pct", "")
else:
    val = ""

if isinstance(val, (int, float)) and not isinstance(val, bool):
    print(val)
    sys.exit(0)

if isinstance(val, bool):
    print("true" if val else "false")
elif isinstance(val, str):
    print(val)
else:
    print("")
PY
}

read_targets_len() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.targets // []) | length' "$PROFILE_PATH"
    return
  fi

  python3 - "$PROFILE_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

targets = data.get("targets", [])
if not isinstance(targets, list):
    print(0)
else:
    print(len(targets))
PY
}

target_mode="$(read_scalar '.target_mode')"
run_type="$(read_scalar '.run_type')"
claim_scope="$(read_scalar '.claim_scope')"
benchmark_family="$(read_scalar '.benchmark_family')"
scenario_id="$(read_scalar '.scenario_id')"
graph_track="$(read_scalar '.graph_track')"
protocol_mode="$(read_scalar '.protocol_mode')"
tier="$(read_scalar '.tier')"
target_classification="$(read_scalar '.target_classification')"
fairness_payload_equivalent="$(read_scalar '.fairness_attestations.payload_equivalent')"
fairness_concurrency_equivalent="$(read_scalar '.fairness_attestations.concurrency_equivalent')"
fairness_protocol_mode_equivalent="$(read_scalar '.fairness_attestations.protocol_mode_equivalent')"
fairness_target_scope_equivalent="$(read_scalar '.fairness_attestations.target_scope_equivalent')"
targets_len="$(read_targets_len)"

if [[ "$target_mode" == "multi" ]]; then
  if [[ "$targets_len" -lt 2 ]]; then
    fail "Semantic check failed: target_mode=multi requires at least 2 targets"
  fi
  pass "Semantic check: multi-target length >= 2"

  if [[ "$DISPATCH_COMPATIBLE" -eq 1 ]]; then
    if [[ "$scenario_id" == "e2e-shop-order-saga" ]]; then
      # Saga multi dispatches to the campaign runner, which accepts 2-3 targets.
      if [[ "$targets_len" -lt 2 || "$targets_len" -gt 3 ]]; then
        fail "Dispatcher compatibility failed: saga campaign requires 2 or 3 targets"
      fi
    elif [[ "$targets_len" -ne 2 ]]; then
      fail "Dispatcher compatibility failed: target_mode=multi requires exactly 2 targets"
    fi
  fi
fi

if [[ "$run_type" == "exploratory" && "$claim_scope" == "comparison_eligible" ]]; then
  fail "Semantic check failed: run_type=exploratory cannot use claim_scope=comparison_eligible"
fi

if [[ "$claim_scope" == "comparison_eligible" && "$CONFIRM_COMPARISON_ELIGIBILITY" -ne 1 ]]; then
  fail "Semantic check failed: claim_scope=comparison_eligible requires --confirm-comparison-eligibility"
fi

if [[ "$CONFIRM_COMPARISON_ELIGIBILITY" -eq 1 ]]; then
  [[ "$claim_scope" == "comparison_eligible" ]] || fail "Comparison eligibility confirmation requires claim_scope=comparison_eligible"
  [[ "$run_type" != "exploratory" ]] || fail "Comparison eligibility confirmation requires run_type!=exploratory"
  [[ "$benchmark_family" == "runtime" ]] || fail "Comparison eligibility confirmation requires benchmark_family=runtime"
  [[ "$target_mode" == "multi" ]] || fail "Comparison eligibility confirmation requires target_mode=multi"
  [[ "$targets_len" -eq 2 ]] || fail "Comparison eligibility confirmation requires exactly 2 targets"
  [[ -n "$protocol_mode" ]] || fail "Comparison eligibility confirmation requires non-empty protocol_mode"
  [[ -n "$tier" ]] || fail "Comparison eligibility confirmation requires non-empty tier"
  [[ -n "$target_classification" ]] || fail "Comparison eligibility confirmation requires non-empty target_classification"
  [[ "$DISPATCH_COMPATIBLE" -eq 1 ]] || fail "Comparison eligibility confirmation requires --dispatch-compatible"
  [[ "$fairness_payload_equivalent" == "true" ]] || fail "Comparison eligibility confirmation requires fairness_attestations.payload_equivalent=true"
  [[ "$fairness_concurrency_equivalent" == "true" ]] || fail "Comparison eligibility confirmation requires fairness_attestations.concurrency_equivalent=true"
  [[ "$fairness_protocol_mode_equivalent" == "true" ]] || fail "Comparison eligibility confirmation requires fairness_attestations.protocol_mode_equivalent=true"
  [[ "$fairness_target_scope_equivalent" == "true" ]] || fail "Comparison eligibility confirmation requires fairness_attestations.target_scope_equivalent=true"
  pass "Comparison eligibility confirmation checks passed"
fi

impairment_enabled="$(read_scalar '.network_impairment.enabled')"
if [[ "$impairment_enabled" == "true" ]]; then
  imp_applied_to="$(read_scalar '.network_impairment.applied_to')"
  imp_profile="$(read_scalar '.network_impairment.profile')"
  imp_delay="$(read_scalar '.network_impairment.delay_ms')"
  imp_loss="$(read_scalar '.network_impairment.loss_pct')"

  [[ -n "$imp_applied_to" ]] || fail "Semantic check failed: network_impairment.enabled=true requires applied_to"
  [[ -n "$imp_profile" ]] || fail "Semantic check failed: network_impairment.enabled=true requires profile"
  [[ -n "$imp_delay" ]] || fail "Semantic check failed: network_impairment.enabled=true requires delay_ms"
  [[ -n "$imp_loss" ]] || fail "Semantic check failed: network_impairment.enabled=true requires loss_pct"
  pass "Semantic check: network impairment metadata present (profile=$imp_profile applied_to=$imp_applied_to)"
fi

if [[ "$scenario_id" == "e2e-shop-order-saga" ]]; then
  [[ -n "$graph_track" ]] || fail "Semantic check failed: e2e-shop-order-saga requires a graph_track (neo4j|pgq_pure|age_compat)"
  pass "Semantic check: saga graph_track present (graph_track=$graph_track)"
fi

pass "Semantic checks"
pass "Guided profile validation complete"
