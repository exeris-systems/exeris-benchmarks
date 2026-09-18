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

## Canonical Target Set Labels

The active allowed `target_id` set is **framework-centric** and protocol-agnostic:
each id names one physical app. Protocol (H1/H2/H2C) and TLS are an **override
axis** resolved at run time (run-guided protocol+TLS toggle, saga runner), not an
id component — `protocol_mode` in the asset matrix is only the fair-baseline
default (community H1 loopback). Tuning/substrate are likewise not encoded in the
id; native-image variants, when reintroduced, must use explicit native ids.

| `target_id` | `target_descriptor` | app dir |
|---|---|---|
| `exeris-community` | Exeris Community (native kernel) | `targets/exeris-community-app` |
| `spring-hibernate` | Spring Boot + Hibernate ORM (JVM, virtual threads) | `targets/spring-benchmark-app` |
| `spring-on-exeris` | Spring on Exeris (compatibility mode + Exeris Flow) | `targets/exeris-spring-runtime-app-comp` |
| `quarkus-hibernate` | Quarkus + Hibernate ORM, default Quarkus transport (JDK NIO + JSSE), JVM, virtual threads | `targets/quarkus-benchmark-app` |
| `quarkus-tuned` | Quarkus + pure JDBC (no ORM), tuned transport: native epoll + native BoringSSL TLS, JVM, virtual threads | `targets/quarkus-benchmark-app-tuned` |

`quarkus-tuned` (legacy id `quarkus-jdbc`) differs from `quarkus-hibernate` on two
axes: it runs a native network stack (native epoll transport + native BoringSSL TLS,
on by default — the pure-Java JDK NIO + JSSE paths are runtime-selectable via
`EXERIS_NETTY_NATIVE_TRANSPORT` / `EXERIS_TLS_NATIVE`), and it uses pure JDBC instead
of Hibernate ORM (same SQL shapes, no ORM mapping layer), isolating ORM cost.
`quarkus-hibernate` is the default-Quarkus baseline (JDK NIO + JSSE).

### Legacy alias map (frozen)

The pre-consolidation `target_id` values below resolve to a canonical id via
`normalize_target_alias` in `runtime/drivers/target-contract-registry.sh`, so
historical `results/` rows stay resolvable. Do not remove an alias once a
published run used it.

| Legacy `target_id` | Canonical |
|---|---|
| `exeris-benchmark-app-community-h1`, `exeris-community-app`, `exeris-e2e-community-h2`, `exeris-native-community`, `exeris-runtime-community` | `exeris-community` |
| `spring-jvm-vt-tuned`, `spring-app-axon`, `spring-native-default` | `spring-hibernate` |
| `spring-runtime-on-exeris-flow` | `spring-on-exeris` |
| `quarkus-jvm-vt-tuned`, `quarkus-app-axon`, `quarkus-native-default` | `quarkus-hibernate` |
| `quarkus-jdbc`, `quarkus-benchmark-app-jdbc` | `quarkus-tuned` |

A legacy id naming a saga comparator (e.g. `spring-app-axon`) carried Axon-Framework
axis semantics. Those semantics are preserved as scenario-manifest metadata
(`saga_framework`, `framework_difference`, `target_backend_support`), NOT in the
id — the id names the physical app; the axis label lives in the contract.

### Saga-only baseline target (`restate`)

`restate` is a **scenario-scoped, baseline-only** target for
`e2e-shop-order-saga` (CONTRACT-v2). It is **not** one of the canonical
comparison ids above and is intentionally absent from any `scenario.json`
`fixed_contract` and from every `comparative-pair-manifest.json` row. It is
listed as a runnable row in `runtime/drivers/target-asset-matrix.json`
(port 9004, `protocol_mode: h1`) and whitelisted in
`tools/verify-target-asset-matrix.sh` as a justified-unused-runnable target.
Its k6-facing facade speaks **HTTP/1.1 only** — an h1-vs-h2c protocol
mismatch against the canonical H2C saga contracts and therefore a strict-gate
disqualifier (same class as `spring-on-exeris`). Its deployment unit includes
an external `restate-server` container whose CPU/RSS is sampled separately
(`logs/restate-server-docker-stats.csv`). **No comparative claim may reference
`restate`** until it is wired as a fixed contract + manifest row and the
protocol mismatch is resolved or the comparison is explicitly scoped h1-vs-h1.

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

### Saga (CONTRACT-v2) additional required fields

For the `e2e-shop-order-saga` scenario only, contract revision `2.0`
(`scenarios/e2e-shop-order-saga/CONTRACT-v2.md`) adds these required
per-run/per-row fields on top of the list above. They are **scenario-scoped**,
not global contract fields:

- `fault_class`: `terminal` or `transient` (§4). Never mixed in one run;
  headline claims come from `terminal` runs only.
- `durability_tier`: `T1` (process-durable) or `T2` (fsync node-durable),
  declared per run (§8). **Cross-tier comparison is forbidden** in all tables
  and prose.
- `latency_population`: `COMPLETED` or `COMPENSATED` — latency is reported
  **separately** per population (§8); mixed-population latency tables are
  non-citable under v2.
- `resolution_model`: `inline` (terminal outcome in the order-POST body) or
  `polled` (status-poll loop) — cross-model latency rows must name each stack's
  model (§3 measurement-model asymmetry).

Enforcement status of each is tracked in
`scenarios/e2e-shop-order-saga/CONTRACT-v2-IMPLEMENTATION.md`; a `partial` or
`deferred` row there means the field may be declared but its guarantee is not
yet fully verified.

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
