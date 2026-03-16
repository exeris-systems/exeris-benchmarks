---
name: exeris-bench-scenario-design-review
description: 'Review Exeris benchmark scenario design quality: scenario semantics, naming clarity, workload realism, and separation across benchmark layers.'
argument-hint: 'Describe scenario intent, workload model, and where it fits in the benchmark catalog.'
---

# Exeris Bench Scenario Design Review

## Use When
- Creating a new scenario or refactoring an existing one.
- Validating that scenario semantics are stable and understandable.

## Checklist
- Scenario answers a concrete benchmark question.
- Naming reflects intent and workload traits.
- Semantics stay stable across reruns.
- Scenario does not mix unrelated benchmark layers.

## Procedure
1. Capture the question the scenario is meant to answer.
2. Verify scenario classification (micro/runtime/compat/guard/exploratory).
3. Check workload realism and comparability constraints.
4. Confirm naming and catalog placement.
5. Emit allow/conditions/refuse with minimal revision set.
