# Comparative Readiness Checklist (Cross-Runtime)

## Purpose

This checklist defines when a cross-runtime comparison is allowed in Exeris runtime benchmarks.

Scope labels used in this document:

- tier: Community or Enterprise
- protocol: H1, H2, or H3
- family: Runtime (not Micro)
- mode: Pure or Compatibility
- execution class: Guard/Regression or Exploratory

All conclusions must remain evidence-bounded to measured data in the same labeled scope.

## Maturity Levels

Use scenario maturity before any cross-runtime claim:

1. `exploratory`
Evidence can be used for local investigation only. No performance comparison claims.
2. `descriptive-baseline`
Evidence can be reported descriptively with caveats. No regression or superiority claims.
3. `comparative-baseline`
Evidence can be compared only if all equivalence checks pass.

Promotion to `comparative-baseline` requires complete reproducibility metadata and stable repeated runs.

## Equivalence Checklist

A cross-runtime comparison is permitted only when all items are true:

- Same scenario contract id and revision.
- Same endpoint workflow semantics (not just similar URI shape).
- Same payload shape and size distribution.
- Same concurrency model and limits.
- Same protocol mode (H1/H2/H3).
- Same transport expectations (TLS/plaintext, keepalive behavior).
- Same benchmark family and tool role.
- Same execution class intent (Guard/Regression vs Exploratory).
- Same target scope and tier labeling in outputs.

If any item differs, comparison is blocked.

## Runtime Fairness

Fairness requirements for cross-runtime runs:

- Compare equivalent workloads, not framework defaults against tuned custom paths.
- Keep request routing, serialization expectations, and error behavior aligned.
- Match warmup, measurement window, and load profile.
- Keep infrastructure parity (host class, CPU pinning policy, JVM major version).
- Separate Pure vs Compatibility mode results.

Use explicit axis labels in all tables and result captions.

## Measurement Policy

Measurement policy for comparative eligibility:

- Capture commit SHA for benchmark harness and target runtime.
- Capture JDK vendor/version and JVM flags.
- Capture hardware profile and kernel/system constraints.
- Capture scenario id, contract revision, target_id, and target_descriptor.
- Capture raw outputs plus normalized schema-compatible result files.

Runs with incomplete required metadata are descriptive-only.

## Claim Discipline

Allowed wording:

- "In this labeled scenario and environment, runtime A measured X and runtime B measured Y."
- "Observed difference under this contract was Z%, within this run set."

Not allowed:

- Global or universal language (for example, "always faster", "best runtime").
- Claims that cross tiers, protocols, or maturity classes without caveats.
- Causal claims not directly supported by measured evidence.

Context note for external references:

- External Quarkus benchmark notes may be cited as contextual background only.
- They are not direct evidence for Exeris claims unless rerun under an equivalent Exeris scenario contract.

## Required Artifacts

A comparison-ready bundle must include:

- Scenario contract file (id + revision + endpoint/workflow definition).
- Target matrix row showing exact target labels used.
- Raw tool outputs and parsed summary outputs.
- Reproducibility metadata (commit, JDK, JVM flags, hardware).
- Classification/status output showing comparison eligibility.

Missing artifacts downgrade results to descriptive-only.

## Target Matrix Policy

Target matrix rows must:

- Use stable `target_id` values.
- Include a concise `target_descriptor` with runtime mode and major tuning profile.
- Keep one row per unique runtime profile.
- Prohibit merging tuned and default variants into one aggregate row.

Cross-runtime comparison rows are valid only when the same scenario contract is attached.

## Final Rule

No cross-runtime comparison claim is allowed without an equivalent scenario contract and complete reproducibility evidence on both sides.
