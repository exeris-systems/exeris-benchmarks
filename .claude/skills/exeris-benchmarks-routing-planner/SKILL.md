---
name: exeris-benchmarks-routing-planner
description: Router/Planner skill for exeris-benchmarks. Produces primary agent, secondary handoffs, execution order, validation gates, and minimal next action for a benchmark task.
---

# Exeris Benchmarks Routing Planner

## Purpose
Given a classified task (see `exeris-benchmarks-task-classifier`), produce a minimal, risk-aware execution order across `exeris-benchmarks-{router,architect,implementer,verification,docs-adr}`.

## Output Contract
1. `primary_agent`
2. `secondary_handoffs` (ordered list with reason)
3. `execution_plan` (3–5 steps)
4. `validation_gates` (must-pass list)
5. `minimal_next_action`

## Routing Patterns
- `SEPARATION_AXIS` / `COMPARATIVE_GATE` → `exeris-benchmarks-architect` primary; `verification` secondary.
- `SCENARIO_IMPL` / `DRIVER_IMPL` / `JMH_IMPL` / `TARGET_IMPL` → `exeris-benchmarks-implementer` primary; `verification` mandatory when result is committed; `architect` if axis discipline at risk.
- `VERIFICATION` → `exeris-benchmarks-verification` primary; `architect` if claim shape in scope; `docs-adr` if methodology amendment needed.
- `DOCS` → `exeris-benchmarks-docs-adr` primary; `architect` if methodology change crosses cross-repo discipline.
- `PUBLICATION` → `exeris-benchmarks-architect` primary (publication-mode); `implementer` secondary for the actual publish step.
- `MULTI_DOMAIN` → start with `architect`, list all dominant handoffs.

## Default Validation Gates
- Axis labelling preserved.
- Strict-gate artefacts present (comparative claims).
- Reproducibility metadata complete on committed results.
- TLS label set populated (TLS work).
- Schema validation green on committed results.
- Publication-mode scrub before public artefact.
- Baseline policy citation when baseline updated.

## Completion Criteria
All five contract fields present and gates tied to the specific risk surface.
