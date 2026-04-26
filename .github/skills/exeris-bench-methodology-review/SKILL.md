---
name: exeris-bench-methodology-review
description: 'Review Exeris benchmark methodology for fairness and evidence quality: warmup, measurement windows, target/payload/concurrency equivalence, and overclaiming risk.'
argument-hint: 'Provide scenario, compared targets/protocols, run config, and intended conclusion.'
---

# Exeris Bench Methodology Review

## Use When
- Designing or reviewing benchmark methodology.
- Validating whether a comparison can support a claim.

## Checklist
- Fairness: equivalent payloads, concurrency, and protocol mode.
- Warmup: sufficient pre-measurement stabilization.
- Measurement window: enough duration and sample stability.
- Target equivalence: same scope and comparable runtime path.
- Conclusion fit: no inference beyond data.

## Procedure
1. Identify comparison axis and hypothesis.
2. Evaluate fairness and workload equivalence.
3. Evaluate run stability (warmup/window/repeats).
4. Classify verdict: `SOUND`, `CONDITIONALLY_SOUND`, or `UNSOUND`.
5. Provide minimal corrections and reporting limits.
