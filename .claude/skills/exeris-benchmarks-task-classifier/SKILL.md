---
name: exeris-benchmarks-task-classifier
description: Router/Planner triage skill for exeris-benchmarks. Classifies task type (architecture / scenario / driver / JMH / target / verification / docs / publication), scope, severity, and recommends primary agent based on primary risk against fairness / reproducibility / strict gate / confidentiality.
---

# Exeris Benchmarks Task Classifier

## Purpose
Classify incoming work before execution starts. Triage only — no implementation.

## Output Contract
Return exactly:
1. `task_class` (`SEPARATION_AXIS` | `COMPARATIVE_GATE` | `SCENARIO_IMPL` | `DRIVER_IMPL` | `JMH_IMPL` | `TARGET_IMPL` | `VERIFICATION` | `DOCS` | `PUBLICATION` | `MULTI_DOMAIN`)
2. `scope` (single-scenario | cross-scenario | cross-track | cross-repo)
3. `severity` (low | medium | high | critical)
4. `primary_risk`
5. `recommended_primary_agent`

## Classification Heuristics
- `SEPARATION_AXIS`: axis labelling / Community-vs-Enterprise / Pure-vs-Compat / Micro-vs-Runtime / Guard-vs-Exploratory framing.
- `COMPARATIVE_GATE`: comparative claim with strict-gate artefacts; `track_id` aggregation discipline.
- `SCENARIO_IMPL`: workload definition under `scenarios/<name>/`.
- `DRIVER_IMPL`: `runtime/drivers/` glue, `scripts/run-*.sh`, launcher-sync.
- `JMH_IMPL`: `micro/jmh/` Maven module.
- `TARGET_IMPL`: `targets/<app>/` runnable benchmark apps.
- `VERIFICATION`: reproducibility metadata, baseline updates, schema validation, classification enums.
- `DOCS`: benchmark-philosophy / methodology / scenario-catalog / protocol-matrix / TLS matrix / regression-policy / hardware-profiles / instructions.
- `PUBLICATION`: `publish-report.sh`, publication-mode scrub, cross-repo movement.
- `MULTI_DOMAIN`: at least two classes above are first-order concerns.

## Guardrails
- Preserve mandatory separation axes.
- Preserve comparative strict gate.
- Preserve not-a-merge-gate rule.
- Preserve enterprise-vs-public scoping.
- If uncertain between two classes, emit `MULTI_DOMAIN` and state both.

## Completion Criteria
All five output fields present and each justified in 1-2 concise bullets.
