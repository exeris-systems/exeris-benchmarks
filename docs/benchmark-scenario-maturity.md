# Benchmark Scenario Maturity and Tool Roles

## Purpose

Define a practical maturity progression for runtime benchmark scenarios and keep tool choice separate from claim strategy. A scenario moves from exploratory evidence to comparison-ready evidence only after explicit gates are satisfied.

## Required Labels and Axes

Every maturity assessment and report must label:

- `tier`: Community or Enterprise
- `protocol_mode`: H1, H2, or H3
- `benchmark_family`: Micro, Runtime, or Compat
- `comparison_axis`: for example within-tier same-protocol, cross-protocol, or cross-tier

Do not collapse conclusions across these axes without explicit caveats.

## Maturity Levels

### 1. Exploratory

Use case:

- Early scenario bring-up
- Harness verification
- Directional signal only

Allowed interpretation:

- Descriptive observations only
- No regression or improvement claim

Typical claim classification:

- `claim_scope` from classifier is exploratory or `descriptive_only` depending on pipeline outputs

### 2. Descriptive Baseline

Use case:

- Stable scenario semantics with repeatable execution
- Internal trend tracking for one target/scope

Allowed interpretation:

- Descriptive baseline statements
- Within-target trend tracking may be allowed with explicit caveats and strict scope consistency

Typical claim classification:

- Usually `descriptive_only`
- Can be `comparison_eligible` only for constrained within-target trend tracking when caveats are explicit

### 3. Comparative Baseline

Use case:

- Comparison-ready evidence for guarded performance conclusions

Allowed interpretation:

- Comparative statements only when all equivalence constraints are met

Required claim classification:

- `comparison_eligible`
- Plus explicit axis equivalence checks (same tier scope, protocol mode, payload, concurrency, and benchmark family)

## Hard Gates for Promotion

A scenario must satisfy all gates at its current level before promotion:

1. Semantic correctness: executed workload matches declared scenario intent and contract.
2. Repeatability: repeated runs show stable ordering and bounded variance for the same setup.
3. Steady-state check: warmup and measurement windows indicate steady behavior before claim use.
4. Structured metrics: required outputs are schema-compatible and parseable.
5. Environment disclosure: commit SHA, tool/JDK versions, JVM flags, hardware profile, and scenario classification are captured.
6. Scenario contract stability: scenario id, payload model, concurrency model, and protocol assumptions are stable across compared runs.
7. Interpretation discipline: wording remains evidence-bounded and aligned with `claim_scope`.

Failing any gate blocks promotion.

## Crosswalk to Claim/Status Vocabulary

| Maturity term | Typical claim/status mapping | Claim limits |
| --- | --- | --- |
| Exploratory | `claim_scope` exploratory or `descriptive_only` depending classifier outputs | No comparative claim. Use directional language only. |
| Descriptive Baseline | Typically `descriptive_only`; in narrow cases may be `comparison_eligible` for within-target trend tracking with caveats | Must keep same target/scope and state caveats. Avoid broad performance claims. |
| Comparative Baseline | Requires `comparison_eligible` plus axis equivalence constraints | Comparative claims allowed only after equivalence checks pass. |

## Tool Roles

- `wrk`: High-throughput HTTP/1.1 and simple endpoint stress. Best for fast runtime signal with controlled payload and connection settings.
- `k6`: Multi-step workflow and user-journey scripting. Best for scenario logic, checks, and staged load profiles.
- `h2load`: HTTP/2 transport and multiplexing focus. Best for H2-specific concurrency behavior and transport-level comparisons.
- `Hyperfoil` (reserve): Reserved for large-scale or distributed load campaigns requiring richer orchestration than local runners.

## Tool Selection Guidance

- Single endpoint throughput/latency smoke or guard: prefer `wrk`.
- Multi-step workflow, assertions, and staged traffic: prefer `k6`.
- H2 transport comparison or multiplex behavior: prefer `h2load`.
- Quick smoke verification before deeper runs: use the lightest relevant tool with explicit exploratory labeling.
- Cross-runtime comparison: use one primary tool and keep payload, concurrency, warmup, and protocol mode equivalent across targets.

## HTTP/3 Note

Current policy:

- Treat H3 results as exploratory unless strict comparability conditions are met, including equivalent payload, concurrency, protocol configuration, target readiness, and reproducibility metadata.

Future direction:

- Promote H3 scenarios to comparative baseline only after repeatability and equivalence checks are routinely passing in guard/regression workflows.

## Interpretation Rule

`tool != strategy`, `run != mature baseline`, and `mature baseline != comparison claim`.

A tool executes workload, maturity describes evidence quality, and claim scope controls what can be said publicly.
