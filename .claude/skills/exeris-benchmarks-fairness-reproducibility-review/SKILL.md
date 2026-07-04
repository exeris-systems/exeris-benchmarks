---
name: exeris-benchmarks-fairness-reproducibility-review
description: Fairness + reproducibility review for exeris-benchmarks. Use on every committed result and every cross-target claim — enforces matched scoping, separation axes, and complete metadata.
---

# Exeris Benchmarks Fairness + Reproducibility Review

## Purpose
Enforce: matched payload / concurrency / protocol / target for cross-target claims; mandatory separation axes always labelled; every committed result captures complete reproducibility metadata.

## When to Use
- Any PR committing a result artefact under `results/raw/`, `results/reports/`, `results/history/`, `results/constrained/`, `results/verify-phasemarker/`, `results/quick-verify-fix-jfr/`.
- Any PR making a comparative claim.
- Any PR adding / modifying a JMH benchmark.
- Any PR updating a baseline under `baselines/<repo>/<mode>/<hardware>.json`.

## Required Inputs
- PR diff scoped to result artefacts and claims.
- Reproducibility metadata fields claimed.
- For comparative: scoping (payload / concurrency / protocol / target).
- For baseline updates: regression-policy citation.

## Review Procedure
1. **Reproducibility metadata** — every committed result MUST capture: commit SHA, JDK version, tool versions, JVM flags, hardware profile, scenario id, target classification. Missing any → reject.
2. **Fairness scoping** — cross-target claims need matched payload, concurrency, protocol mode, target scope. Mismatch without explicit caveat → reject.
3. **Separation axes** — Community/Enterprise, H1/H2/H3, Pure/Compat, Micro/Runtime, Guard/Exploratory all labelled. Collapsed without caveat → reject.
4. **Schema validation** — artefact validates against the relevant schema in `schemas/` (`benchmark-result.schema.json`, `benchmark-env.schema.json`, `comparative-result.schema.json`, `fairness-index.schema.json`, `runtime-execution-profile-matrix.schema.json`, `enterprise-target-contract.schema.json`).
5. **JMH discipline** — `-f 3` minimum for publishable runs. `-f 1` in committed results → reject. Standard JVM flags present.
6. **Baseline updates** — must cite `docs/regression-policy.md`; baseline never silently refreshed to mask regression.
7. **Decision and report** — `APPROVE` / `CONDITIONAL` / `REJECT`.

## Decision Logic
- **APPROVE**: Complete metadata; matched fairness scoping; axes labelled; schema valid; JMH `-f 3`+; baseline cite if applicable.
- **CONDITIONAL**: Sound but missing one specific field — propose the specific addition.
- **REJECT**: Missing metadata; collapsed axis without caveat; schema invalid; `-f 1` published; silent baseline update.

## Completion Criteria
- Reproducibility metadata audited.
- Fairness scoping confirmed.
- Separation axes labelled.
- Schema validation confirmed.
- JMH discipline checked.
- Baseline policy citation confirmed (if baseline updated).
- Verdict and remediation recorded.

## Review Output Template
1. **Scope analysed** (result artefacts / claims)
2. **Reproducibility metadata** (per field present / missing)
3. **Fairness scoping** (matched / mismatched + caveat)
4. **Separation axes** (labelled / collapsed)
5. **Schema validation** (pass / fail)
6. **JMH discipline** (`-f` value)
7. **Baseline policy** (cite / silent / N/A)
8. **Verdict** (`APPROVE` / `CONDITIONAL` / `REJECT`)
9. **Required actions** (precise and minimal)

## Non-Negotiable Rules
- Never approve a committed result without complete reproducibility metadata.
- Never approve a cross-target claim with mismatched scoping.
- Never approve `-f 1` in a published run.
- Never approve a silent baseline update.
