# Comparative Readiness Checklist for Cross-Runtime Benchmarks

## Purpose

Define minimum requirements for classifying a scenario as cross-runtime comparative baseline eligible.
All decisions remain constrained to same-tier, same-protocol, same-scenario evidence.

## Maturity Levels

1. `exploratory`: local investigation only, no comparative claims.
2. `descriptive-baseline`: publishable descriptive reporting with caveats, no baseline ranking claims.
3. `comparative-baseline`: baseline comparison permitted only when every checklist section passes.

## Scenario Equivalence

- Same scenario contract ID and revision.
- Same endpoint or workflow semantics.
- Same payload shape and size envelope.
- Same concurrency model and limits.
- Same protocol mode (H1, H2, or H3).
- Same transport expectations (TLS or plaintext, keepalive behavior).

## Runtime Fairness

- Match workload intent across runtimes; do not compare tuned custom path vs default path unless labeled and intentionally scoped.
- Keep warmup, duration, and load profile equivalent.
- Keep environment class, JVM major version, and host constraints comparable.
- Separate Pure vs Compatibility mode outputs.
- Prevent apples-to-oranges target pairing at matrix generation time.

## Measurement Policy

- Capture commit SHA for harness and target runtime.
- Capture JDK vendor/version and JVM flags.
- Capture hardware profile and execution constraints.
- Capture `scenario_id`, `target_id`, protocol mode, and target descriptor.
- Keep raw and normalized outputs schema-compatible.

## Claim Discipline

- Report only measured differences inside the declared labeled scope.
- Do not claim universal runtime superiority.
- Do not infer causality without direct supporting measurements.
- Do not collapse conclusions across tier, protocol, family, or maturity axes.
- Onboarding targets may be runnable but remain descriptive-only until claim gates are fully PASS with no WARN rows.

## Required Artifacts

- Scenario contract definition and revision.
- Target descriptor and target matrix entries for each compared runtime.
- Raw outputs and normalized result artifacts.
- Reproducibility metadata bundle.
- Classification output confirming comparative eligibility.

## Target Matrix Policy

- Every declared comparative `target_id` must map to concrete launcher assets, or be explicitly labeled non-runnable.
- Baseline comparative matrix generation must include only runnable, same-protocol pairs.
- If Spring/Quarkus runnable launcher assets are missing, scenario cannot be classified as comparative baseline.

## Final Rule

No cross-runtime baseline claim is allowed unless both sides are runnable, protocol-compatible, scenario-equivalent, and fully reproducible in captured artifacts.
