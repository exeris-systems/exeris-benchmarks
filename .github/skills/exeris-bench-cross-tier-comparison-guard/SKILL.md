---
name: exeris-bench-cross-tier-comparison-guard
description: 'Guard Exeris cross-tier comparisons so Community vs Enterprise claims stay correctly labeled, protocol-consistent, and inference-safe.'
argument-hint: 'Provide compared tiers, protocol mode, scenario mapping, and intended conclusion.'
---

# Exeris Bench Cross-Tier Comparison Guard

## Use When
- Comparing Community and Enterprise results.
- Any report might imply parity or superiority across tiers.

## Checklist
- Same protocol mode for both sides (or explicit non-equivalence label)
- Same scenario semantics and payload envelope
- Same benchmark family and measurement framing
- Explicit statement of unsupported inferences

## Procedure
1. Validate axis: same-tier vs cross-tier vs mode comparison.
2. Detect hidden axis drift (protocol, payload, target behavior).
3. Require explicit report labels for non-equivalent comparisons.
4. Block conclusions that exceed data support.
