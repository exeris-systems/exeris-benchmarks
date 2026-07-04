---
name: exeris-benchmarks-comparative-strict-gate-review
description: Comparative strict-gate review for exeris-benchmarks. Use on every PR making a cross-target comparative claim — verifies 4 gate artefacts present + `claim-status.json = comparison_eligible` + `track_id` consistent.
---

# Exeris Benchmarks Comparative Strict-Gate Review

## Purpose
Enforce: comparative runtime runs fail closed. Comparative math is valid only when `claim-status.json = comparison_eligible` AND strict gates pass. `track_id` is an isolation boundary.

## When to Use
- Any PR making a cross-target / cross-protocol / cross-tier comparative claim.
- Any PR aggregating across `track_id`.
- Any PR running `scripts/run-comparative.sh`, `run-entity-read-by-id-campaign.sh`, `run-e2e-shop-order-saga-campaign.sh`, `run-tls-matrix.sh`, `run-iso-budget-sweep-ab-ba.sh`, `run-full-triad-ab-ba.sh`.

## Required Inputs
- Comparative output directory.
- Stated claim (what is being compared, on what axis).
- `track_id` assignments per row.

## Review Procedure
1. **Artefact presence** — confirm all four artefacts present:
   - `stage7-gate-report.csv`
   - `stage7-gate-summary.json`
   - `claim-status.json`
   - `rejection-codes.json`
2. **Claim status** — `claim-status.json` final status MUST be `comparison_eligible`. `non_eligible` → reject the claim (but `non_eligible` labelling itself is honest and OK).
3. **Gate rows** — every row in `stage7-gate-report.csv` should be `pass`. `fail` rows MUST have `rejection_code` populated; comparative math against fail rows is invalid.
4. **`track_id` isolation** — every aggregated row carries the same `track_id`. Cross-track aggregation is a hard reject.
5. **Axis + track labelling** — report outputs MUST include explicit axis labels (tier, protocol, family, comparison axis) AND the track label.
6. **Run scripts** — confirm `scripts/validate-comparative-readiness.sh` and `scripts/aggregate-comparative-results.sh` were used in the right order.
7. **Decision and report** — `APPROVE` / `CONDITIONAL` / `REJECT`.

## Decision Logic
- **APPROVE**: All four artefacts present, `comparison_eligible`, gate rows pass, `track_id` consistent, labels present.
- **CONDITIONAL**: Sound run but missing one specific label / report stamp — propose the specific addition.
- **REJECT**: Missing gate artefact, `non_eligible` status, fail rows used in math, cross-track aggregation, missing labels.

## Completion Criteria
- Artefact presence checked.
- Claim status confirmed.
- Gate rows audited.
- `track_id` isolation confirmed.
- Labelling confirmed.
- Verdict and remediation recorded.

## Review Output Template
1. **Scope analysed** (comparative directory / claim)
2. **Artefact presence** (4/4 present?)
3. **Claim status** (`comparison_eligible` / `non_eligible`)
4. **Gate rows** (pass / fail count + rejection codes)
5. **`track_id` isolation** (consistent / cross-track aggregation)
6. **Labelling** (axis + track labels present)
7. **Verdict** (`APPROVE` / `CONDITIONAL` / `REJECT`)
8. **Required actions** (precise and minimal)

## Non-Negotiable Rules
- Never approve a comparative claim without all four gate artefacts.
- Never approve a claim with `non_eligible` status as if it were eligible.
- Never approve cross-`track_id` aggregation.
- Never approve a comparative claim that bypasses `scripts/validate-comparative-readiness.sh`.
