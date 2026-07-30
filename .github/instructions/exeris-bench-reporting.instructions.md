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

## Summarizing Surfaces — sweep all four when any section changes

A report states its findings in more places than the section that owns them. When a
section changes, walk **all four** summarizing surfaces and reconcile each against the
section body:

1. frontmatter `summary:`
2. TL;DR bullets
3. revision history
4. the conclusions section

This is a recurring, empirically-established failure mode in this repo, not a
hypothetical: three consecutive review rounds on the 2026-07-21 triad report found the
section body correct and a summary wrong — a contradicted TL;DR claim, a mislabeled
comparator in the conclusions ("out of the box"), and an over-generalized quantifier in
all three summaries at once ("resident heap dominates heavy", true against one of two
comparators). Cross-cutting facts belong on this list for the same reason — the pgjdbc
fetch-configuration normalization is the standing example.

Two specific traps the same history produced:

- **Do not let a summary strengthen a body's quantifier.** "Rises to 39–59 %" is not
  "dominates"; a range whose lower bound is under half cannot describe dominance. If the
  body says "about half", the summary may not say "most".
- **Cite the bound measured on the axis being claimed.** An order-effect bound of ≤ 2 %
  established for throughput and CPU/req says nothing about RSS, where the same control
  measured +13.5 % on one arm.

## Publication Readiness
If confidentiality or methodological ambiguity remains, recommend:
- internal-only publication, or
- redaction before publication.
