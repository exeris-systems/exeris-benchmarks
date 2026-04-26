---
name: exeris-bench-enterprise-confidentiality-guard
description: 'Protect proprietary Enterprise details in benchmark outputs by reviewing traces, symbols, and publication artifacts before public reporting.'
argument-hint: 'Provide candidate artifacts to publish and their intended audience.'
---

# Exeris Bench Enterprise Confidentiality Guard

## Use When
- Benchmark artifacts involve Enterprise runtime behavior.
- Public publication or cross-repo sharing is planned.

## Review Scope
- Raw traces, flamegraphs, and diagnostics
- Symbol names and stack detail exposure
- Scenario/config payloads that reveal proprietary internals
- Public vs internal artifact split

## Procedure
1. Classify each artifact as public-safe, internal-only, or redaction-required.
2. Detect proprietary implementation leakage risk.
3. Recommend normalized export alternatives where possible.
4. Emit publish decision with required redactions.
