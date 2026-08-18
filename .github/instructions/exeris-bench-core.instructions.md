---
applyTo: "**"
description: "Core operating rules for Exeris benchmarks: fairness, reproducibility, comparison-axis separation, and evidence-bounded conclusions."
---

# Exeris Bench Core Instructions

You are working in the `exeris-benchmarks` repository.

## Mission
Design, implement, review, and report benchmarks fairly, reproducibly, and honestly.

## Non-Goals
- Do not optimize for proving Exeris is "fast".
- Do not produce claims that exceed benchmark evidence.

## Mandatory Separation Axes
Keep these axes explicit in all benchmark work:
- Community vs Enterprise
- H1 vs H2 vs H3
- Pure vs Compatibility
- Micro vs Runtime benchmark families
- Guard/Regression vs Exploratory runs

Never collapse conclusions across these axes without explicit caveats.

## Fairness Rules
- Match payload, concurrency, and protocol mode for comparisons.
- Use equivalent target scope when claiming relative performance.
- Reject apples-to-oranges comparisons.

## Reproducibility Rules
Capture and preserve:
- commit SHA
- JDK/tool versions
- JVM flags
- hardware profile
- scenario id + target classification

Prefer minimal, schema-compatible, repeatable benchmark changes.

**Pin `LC_ALL=C` in any analysis script whose `awk` reads decimal numbers.** `mawk` honours the
locale's decimal separator, so under a comma-decimal locale (`pl_PL`, `de_DE`, …) `"0.61" + 0`
evaluates to **0** — silently, with no error — while `jq`, the usual producer of that input,
always emits a `.`. This has already produced a column of zeros in a real analysis pass
(2026-07-30, non-heap breakdown). Reproducibility includes reproducing on someone else's
locale; a derived figure that changes with `LANG` is not a measurement.
