---
applyTo: "scenarios/**,runtime/**,scripts/**,targets/**,compat/**"
description: "Runtime benchmark implementation and verification rules for harnesses, scenarios, target launchers, and compatibility modes."
---

# Exeris Bench Runtime Instructions

Apply these rules when editing runtime scenarios, harness drivers, and run scripts.

## Scenario Semantics
- Keep scenario intent explicit and stable.
- Avoid mixing benchmark layers in one scenario.
- Keep naming descriptive and comparable over time.

## Harness and Driver Discipline
- Do not silently change protocol/tier/mode assumptions.
- Keep launcher and env behavior auditable.
- Prefer minimal changes that preserve existing scenario contracts.

## Verification Expectations
- Ensure workload executed matches declared scenario semantics.
- Confirm metadata capture remains intact after changes.
- Validate output compatibility with repository result/environment schemas.

## Comparison Safety
- For cross-tier or cross-protocol work, label limitations explicitly.
- If equivalence conditions are not met, do not present comparative conclusions.
