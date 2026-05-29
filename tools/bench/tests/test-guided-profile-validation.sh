#!/usr/bin/env bash
# test-guided-profile-validation.sh — fixture tests for the guided-run-profile
# validator (runtime/drivers/validate-guided-profile.sh).
#
# Locks in the semantic rules the guided launcher depends on so they don't rot:
#   - network_impairment metadata required when enabled
#   - e2e-shop-order-saga requires a graph_track
#   - saga campaign allows 2-3 targets; other multi requires exactly 2
#   - H3 is Enterprise-only (community+h3 rejected)

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VALIDATOR="$REPO_ROOT/runtime/drivers/validate-guided-profile.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAILURES=0

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available" >&2
  exit 0
fi

# The validator needs a JSON-schema validator to reach the semantic checks.
if ! command -v check-jsonschema >/dev/null 2>&1 \
   && ! command -v ajv >/dev/null 2>&1 \
   && ! python3 -c 'import jsonschema' >/dev/null 2>&1; then
  echo "SKIP: no JSON-schema validator (check-jsonschema/ajv/python3+jsonschema)" >&2
  exit 0
fi

# Emit a base valid local/single guided profile; callers pipe it through jq to
# mutate it per case.
base_profile() {
  jq -n '{
    schema_version: "1",
    benchmark_family: "runtime",
    benchmark_commit_sha: "unknown",
    jdk_version: "openjdk 21",
    tool_versions: { jq: "jq-1.7" },
    jvm_flags: [],
    hardware_profile: "dev-laptop",
    scenario_id: "plaintext",
    target_classification: "pure",
    protocol_mode: "h1",
    tier: "community",
    topology_mode: "localhost",
    connectivity: "local",
    run_type: "exploratory",
    target_mode: "single",
    claim_scope: "descriptive_only",
    targets: ["exeris-community-app"],
    launch_mode: "prebuild",
    runtime_mode: "jvm"
  }'
}

# assert_validator <expect:pass|fail> <name> <profile-json> [extra validator args...]
assert_validator() {
  local expect="$1" name="$2" profile_json="$3"
  shift 3
  local file="$TEST_DIR/${name// /_}.json"
  printf '%s\n' "$profile_json" > "$file"

  if "$VALIDATOR" --profile "$file" "$@" >/dev/null 2>&1; then
    local actual="pass"
  else
    local actual="fail"
  fi

  if [[ "$actual" == "$expect" ]]; then
    echo "  ok   [$name] expected=$expect"
  else
    echo "  FAIL [$name] expected=$expect actual=$actual"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "Testing guided-run-profile validator semantics..."

# 1) Baseline valid profile passes.
assert_validator pass "valid-local-single" "$(base_profile)" --dispatch-compatible

# 2) Impairment enabled but missing required metadata -> fail.
assert_validator fail "impairment-missing-metadata" \
  "$(base_profile | jq '.network_impairment = { enabled: true }')"

# 3) Impairment enabled with full metadata -> pass.
assert_validator pass "impairment-complete" \
  "$(base_profile | jq '.network_impairment = {
        enabled: true, apply_requested: false, applied_to: "loopback",
        profile: "moderate", tool: "tc netem",
        delay_ms: 20, loss_pct: 1.0, jitter_ms: 5 }')"

# 4) Saga without graph_track -> fail.
assert_validator fail "saga-missing-graph-track" \
  "$(base_profile | jq '.scenario_id = "e2e-shop-order-saga" | .protocol_mode = "h2"')"

# 5) Saga single with graph_track -> pass.
assert_validator pass "saga-single-graph-track" \
  "$(base_profile | jq '.scenario_id = "e2e-shop-order-saga" | .protocol_mode = "h2" | .graph_track = "neo4j"')"

# 6) Saga campaign with 3 targets (dispatch-compatible) -> pass.
assert_validator pass "saga-multi-3-targets" \
  "$(base_profile | jq '.scenario_id = "e2e-shop-order-saga" | .protocol_mode = "h2"
        | .graph_track = "neo4j" | .target_mode = "multi"
        | .targets = ["exeris-community-app","quarkus-app-axon","spring-app-axon"]')" \
  --dispatch-compatible

# 7) Non-saga multi with 3 targets (dispatch-compatible) -> fail (exactly 2).
assert_validator fail "multi-3-targets-nonsaga" \
  "$(base_profile | jq '.target_mode = "multi"
        | .targets = ["exeris-community-app","spring-jvm-vt-tuned","quarkus-jvm-vt-tuned"]')" \
  --dispatch-compatible

# 8) Community + H3 -> fail (Enterprise-only).
assert_validator fail "community-h3" \
  "$(base_profile | jq '.protocol_mode = "h3"')"

# 9) Enterprise + H3 -> pass.
assert_validator pass "enterprise-h3" \
  "$(base_profile | jq '.protocol_mode = "h3" | .tier = "enterprise"')"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "PASS: all guided-profile validator fixtures behaved as expected"
  exit 0
fi
echo "FAIL: $FAILURES guided-profile validator fixture(s) misbehaved"
exit 1
