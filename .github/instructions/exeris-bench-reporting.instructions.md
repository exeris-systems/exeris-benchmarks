---
applyTo: "docs/**,results/**,baselines/**,tools/**,README.md"
description: "Reporting guardrails for benchmark docs/results: honest interpretation, explicit labels, and enterprise confidentiality-safe publication."
---

# Exeris Bench Reporting Instructions

Apply these rules when preparing benchmark documentation, result narratives, and publishable assets.

## Interpretation Discipline
- Keep conclusions proportional to observed evidence.
- Separate descriptive metrics from causal claims.
- State uncertainty when data is noisy, narrow, or exploratory.

## Labeling Requirements
Always label:
- tier (Community or Enterprise)
- protocol mode (H1/H2/H3)
- benchmark family (Micro/Runtime/Compat)
- comparison axis and its limits

Do not present H3-only Enterprise behavior as Community capability.

## Confidentiality Guard
- Treat raw traces/flamegraphs/diagnostics as potentially sensitive.
- Avoid leaking proprietary Enterprise internals in public artifacts.
- Prefer normalized, schema-compliant outputs for cross-tier publications.

## Publication Readiness
If confidentiality or methodological ambiguity remains, recommend:
- internal-only publication, or
- redaction before publication.
