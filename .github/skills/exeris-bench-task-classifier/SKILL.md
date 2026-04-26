---
name: exeris-bench-task-classifier
description: 'Classify Exeris benchmark requests by family, target, and comparison axis. Use for benchmark triage before architecture, implementation, or reporting work.'
argument-hint: 'Describe benchmark goal, target (Community/Enterprise/Spring), protocol mode, and expected comparison.'
---

# Exeris Bench Task Classifier

## Use When
- A new benchmark request arrives and scope is unclear.
- A task mixes runtime/micro/docs concerns.
- You need normalized routing metadata.

## Output Schema
- `benchmark_family`: `MICRO | RUNTIME | COMPAT | RESULTS | DOCS_REPORTING | MULTI_DOMAIN`
- `target_scope`: `KERNEL_COMMUNITY | KERNEL_ENTERPRISE | SPRING_RUNTIME | MULTI_TARGET`
- `comparison_axis`: `WITHIN_TIER_PROTOCOL | CROSS_TIER_SAME_PROTOCOL | MODE_COMPARISON | HISTORICAL_REGRESSION | NONE`
- `risk_flags`: list of detected primary risks

## Procedure
1. Extract explicit benchmark objective.
2. Map task to exactly one primary family (or `MULTI_DOMAIN`).
3. Map target scope from scenario/runtime context.
4. Determine comparison axis from expected claim.
5. Emit risk flags for fairness, reproducibility, or confidentiality.
