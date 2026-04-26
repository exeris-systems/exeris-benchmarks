---
name: exeris-bench-reproducibility-review
description: 'Review Exeris benchmark reproducibility and environment capture: metadata completeness, JDK/toolchain versions, hardware profile, JVM flags, repeatability, and naming consistency.'
argument-hint: 'Provide benchmark result artifacts and environment capture details.'
---

# Exeris Bench Reproducibility Review

## Use When
- A benchmark run is prepared for sharing, comparison, or regression tracking.
- Result credibility depends on environment transparency.

## Required Metadata
- Commit SHA
- JDK version and vendor
- Tool versions (k6/wrk/h2load/JMH)
- JVM flags
- Hardware profile
- Scenario name and target classification

## Procedure
1. Validate metadata presence and consistency.
2. Confirm scenario naming and semantics are stable.
3. Check repeatability evidence (multiple runs or variance notes).
4. Identify blockers for reproduction by another engineer.
5. Produce fix list ordered by impact.
