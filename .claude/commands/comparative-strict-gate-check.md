---
description: Verify a comparative claim passes the strict gate — 4 artefacts present + `claim-status.json = comparison_eligible` + `track_id` consistent.
argument-hint: comparative-result directory / PR claiming cross-target comparison
---

Audit this comparative claim against the strict gate.

Strict gate (per repo `CLAUDE.md`):
- Comparative runtime runs fail closed.
- Any comparative output directory MUST contain:
  - `stage7-gate-report.csv` (`scope,gate_id,gate_name,pass_fail,rejection_code,...`)
  - `stage7-gate-summary.json`
  - `claim-status.json` (final status: `comparison_eligible` or `non_eligible`)
  - `rejection-codes.json`
- Comparative math is valid **only** when `claim-status.json` is `comparison_eligible` AND strict gates pass.
- `track_id` is an isolation boundary — never aggregate across mixed tracks.
- Report outputs MUST include explicit axis labels and the track label.

Change:
$ARGUMENTS

Please review:
1. Are all four strict-gate artefacts present in the comparative output directory?
2. Is `claim-status.json` final status `comparison_eligible` (not `non_eligible`)?
3. Are `stage7-gate-report.csv` rows all `pass`, or are there `fail` rows with `rejection_code` populated?
4. Is `track_id` consistent across the aggregated rows (no cross-track aggregation)?
5. Do report outputs include explicit axis labels (tier, protocol, family, comparison axis) AND the track label?
6. Minimal correction if the gate is at risk.

A claim that bypasses the strict gate is a hard reject. Don't propose loosening — propose `non_eligible` labelling instead, which is honest.
