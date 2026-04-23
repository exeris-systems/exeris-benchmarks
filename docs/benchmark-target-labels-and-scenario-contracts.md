# Benchmark Target Labels and Scenario Contracts

## Purpose

This document standardizes target labeling and scenario contract fields for runtime benchmarking.
It supports fair, reproducible, and evidence-bounded comparisons across labeled axes.

## Exeris Axis Labels

Every result and report section must keep these axes explicit:

- tier: Community or Enterprise
- protocol: H1, H2, or H3
- mode: Pure or Compatibility
- family: Micro or Runtime
- execution class: Guard/Regression or Exploratory

Do not collapse conclusions across axes without explicit caveats.

## Definitions

### `target_id`

Stable machine-readable identifier for a benchmark target profile.

Rules:

- Lowercase kebab-case.
- Unique per runtime profile.
- Encodes framework/runtime and major tuning profile.
- Must not change retroactively for published historical rows.

### `target_descriptor`

Human-readable short descriptor for benchmark tables and report captions.

Rules:

- Concise and operational (runtime, VM mode, relevant tuning class).
- No marketing or superiority language.
- Must match actual launch profile used in run artifacts.

## Initial Target Set Labels

The active allowed `target_id` set is:

Substrate must not be inferred from tuning labels; native-image targets must use explicit native `target_id` values.

- `exeris-benchmark-app-community-h1`
- `spring-jvm-vt-tuned`
- `spring-native-default`
- `quarkus-jvm-vt-tuned`
- `quarkus-native-default`

Legacy, non-runnable historical `target_id` values retained only for auditability:

- `exeris-native-community`
- `exeris-runtime-community`

Suggested `target_descriptor` values:

- `Exeris standalone benchmark app (Community, H1)`
- `Spring Boot JVM + virtual threads (tuned)`
- `Spring Boot native image`
- `Quarkus JVM + virtual threads (tuned)`
- `Quarkus native image`

Legacy historical descriptors:

- `Exeris native image (Community, legacy non-runnable)`
- `Exeris runtime JVM (Community, legacy non-runnable)`
## Runtime Target Contract Registry

Runtime driver scripts resolve launch settings through `runtime/drivers/target-contract-registry.sh`.

Registry contract fields:

- `target_id`
- `tier`
- `protocol_mode`
- `launcher_mode`
- `env_file`
- `profile_id`
- `compose_file`
- `jar_path`
- `health_url`

Fail-fast behavior:

- Unknown `target_id` values fail with `CONFIG_ERROR` and a non-zero exit.
- Unsupported but recognized `target_id` values (for example, native/quarkus profiles without launcher assets) fail with `CONFIG_ERROR` and an explicit unsupported reason.

## Comparative Claim Contract vs Operational Runnable Contract

Two contracts are enforced and must both pass:

- Scenario claim contract: `scenarios/*/comparative-pair-manifest.json` defines declared comparative scope, including `compatible_targets` and forbidden pairs.
- Operational runnable contract: `runtime/drivers/target-asset-matrix.json` defines whether each declared `target_id` is runnable, with explicit non-runnable reasons.

Precedence and enforcement:

- Claim eligibility requires manifest compatibility and matrix runnable status.
- Non-runnable or unresolved matrix rows are fail-fast `CONFIG_ERROR` conditions for baseline comparative execution.
- Scenario manifests remain the source of comparison claims; the matrix is the source of operational launch eligibility.

## Scenario Contract Required Fields

A scenario contract is mandatory for cross-runtime comparisons.
If two runs do not reference an equivalent contract, comparison is not allowed.

Required fields:

- `scenario_id`: Stable id for the scenario.
- `contract_revision`: Monotonic revision label.
- `benchmark_family`: Runtime or Micro.
- `protocol_mode`: H1, H2, or H3.
- `tier_scope`: Community (or explicit scope note for non-community tracks outside this repo's active docs path).
- `mode`: Pure or Compatibility.
- `workload_class`: Guard/Regression or Exploratory.
- `endpoint.name`: Logical endpoint/workflow name.
- `endpoint.method`: HTTP method.
- `endpoint.path_template`: Canonical route template.
- `request.payload_profile`: Size and shape profile.
- `request.headers_profile`: Required header behavior.
- `response.expectation`: Status/body invariants.
- `concurrency.profile`: Client concurrency model and target level.
- `duration_policy`: Warmup and measurement windows.
- `fairness_constraints`: Explicit equivalence requirements.
- `required_artifacts`: Artifact checklist for comparison eligibility.

## Comparative Pair Manifests and Execution Tooling

For any declared dual-target comparative execution path, a scenario contract is necessary but not sufficient; a comparative pair manifest is also required for the declared targets, and the repository scripts enforce that flow.

For the current `entity-read-by-id` path, use:

- `scenarios/entity-read-by-id/comparative-pair-manifest.json` as the source of allowed target pairs, declared asymmetries, and fixed measurement expectations.
- `fixed_contract_cross_runtime_h1_v1` for pairwise cross-runtime Community/H1/loopback runs.
- `fixed_contract_backend_mode_h1_v1` only for intra-target backend-mode comparisons (default-vt vs locality-aware).
- `scripts/run-comparative.sh` to orchestrate the paired run.
- `scripts/validate-comparative-readiness.sh` to enforce readiness gates across both result bundles.
- `tools/compute-fairness-index.sh` to generate the fairness artifact used by comparative outputs.
- `scripts/aggregate-comparative-results.sh` only after multiple comparative runs exist.

Implemented machinery and structural checks are not evidence of a completed, claim-eligible, or publishable comparative run.

## Endpoint Contract YAML Template

```yaml
scenario_id: json-1kb-h1-runtime
contract_revision: r1
benchmark_family: runtime
protocol_mode: h1
tier_scope: community
mode: pure
workload_class: guard

endpoint:
  name: json_read_1kb
  method: GET
  path_template: /api/v1/items/{id}

request:
  payload_profile:
    type: json
    nominal_bytes: 1024
    distribution: fixed
  headers_profile:
    required:
      - accept: application/json

response:
  expectation:
    status_code: 200
    body_schema: item-v1

concurrency:
  profile:
    model: closed_loop
    clients: 32

duration_policy:
  warmup: 30s
  measurement: 120s

fairness_constraints:
  - same_payload_shape
  - same_protocol_mode
  - same_concurrency_profile

required_artifacts:
  - raw_output
  - parsed_summary
  - reproducibility_metadata
  - status_classification
```

## Workflow Contract YAML Template

```yaml
scenario_id: checkout-workflow-h2-runtime
contract_revision: r1
benchmark_family: runtime
protocol_mode: h2
tier_scope: community
mode: compatibility
workload_class: regression

workflow:
  name: checkout_flow
  steps:
    - id: cart_read
      method: GET
      path_template: /api/v1/cart/{cartId}
      expected_status: 200
    - id: payment_authorize
      method: POST
      path_template: /api/v1/payment/authorize
      expected_status: 200
    - id: order_commit
      method: POST
      path_template: /api/v1/order/commit
      expected_status: 201

request_profiles:
  cart_read:
    payload_profile:
      type: none
  payment_authorize:
    payload_profile:
      type: json
      nominal_bytes: 2048
  order_commit:
    payload_profile:
      type: json
      nominal_bytes: 1024

concurrency:
  profile:
    model: open_loop
    arrival_rate_rps: 500

duration_policy:
  warmup: 60s
  measurement: 300s

fairness_constraints:
  - same_workflow_step_semantics
  - same_payload_distribution
  - same_transport_and_tls_mode

required_artifacts:
  - raw_output
  - parsed_summary
  - reproducibility_metadata
  - status_classification
```

## Claim Discipline

Target labels and contract references enable scoped statements only.

Allowed:

- "For contract `json-1kb-h1-runtime@r1`, `spring-jvm-vt-tuned` measured X and `quarkus-jvm-vt-tuned` measured Y."

Not allowed:

- "Framework A is faster than framework B" without contract- and axis-qualified scope.

External Quarkus notes may appear as context, not as direct proof for Exeris claims.

## Final Rule

No comparative claim is allowed unless both sides declare equivalent scenario contracts, valid target labels, complete reproducibility artifacts, and a matching comparative pair manifest where that workflow is used. Implemented machinery or structural checks alone do not constitute comparative evidence.
