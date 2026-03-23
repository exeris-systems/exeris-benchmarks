# ISSUE P0-02: Runtime Claim-Eligibility Normalization

Status: verified (pass with caveat)
Priority: P0
Primary Agent: Implementer
Secondary Handoff: Methodology/Results Review

## Scope

In-scope:
- Normalize claim-eligibility handling across compare and classification tooling.
- Ensure non-eligible runs are excluded from comparative report sections.
- Align `claim_scope` interpretation across scripts and verifier checks.

Out-of-scope:
- Redefining claim policy semantics or introducing new policy categories.
- Cross-tier or cross-protocol comparison expansion beyond current rules.
- Runtime harness or scenario workload redesign.

## Required Repo Touchpoints

- `scripts/compare-results.sh`
- `tools/verify-classification.sh`
- `docs/status-and-claim-eligibility.md`

## Implementation Tasks

1. Audit `scripts/compare-results.sh` paths that include runs in comparative sections and gate by normalized claim eligibility.
2. Normalize `claim_scope` handling in `scripts/compare-results.sh` and `tools/verify-classification.sh` to one canonical interpretation.
3. Add explicit exclusion reason output when a run is filtered from comparative sections.
4. Update `docs/status-and-claim-eligibility.md` with canonical eligibility and exclusion behavior.
5. Add or update lightweight validation fixture inputs used by classification verification checks.

## Verification Tasks

1. Run classification verification and confirm claim-scope vocabulary is consistently accepted and validated.
2. Run comparison script on mixed eligible/non-eligible inputs and confirm only eligible runs appear in comparative sections.
3. Verify exclusion reason output is present and accurate for filtered runs.
4. Confirm documentation examples match script output behavior.
5. Confirm no cross-tier or mixed-protocol comparisons are newly enabled.

## Acceptance Criteria

1. Non-eligible runs are excluded from comparative sections in `scripts/compare-results.sh`.
2. `claim_scope` handling is consistent between compare and classification tooling.
3. Filtered runs produce concrete exclusion reasons in output.
4. `docs/status-and-claim-eligibility.md` documents implemented canonical behavior.
5. Verification checks pass without introducing schema or publication regressions.

## Risks and Caveats

- Risk of breaking legacy artifacts that used older `claim_scope` synonyms.
- Risk of silent exclusions if reason codes are not surfaced in output.
- Caveat: methodology review must approve any interpretation edge-case handling.

## Delivery Artifacts

- Updated `scripts/compare-results.sh`
- Updated `tools/verify-classification.sh`
- Updated `docs/status-and-claim-eligibility.md`
- Verification notes for mixed eligibility comparison inputs

## Verification Outcome (2026-03-19)

Verdict: **VERIFIED (PASS WITH CAVEAT)**

**Key Evidence:**
- Canonical `claim_scope` interpretation normalized across compare and classification tooling ✓
- Non-eligible runs excluded from comparative sections with explicit exclusion reasons ✓
- `scripts/compare-results.sh` gates comparative output by `claim_scope != comparison_eligible` ✓
- `docs/status-and-claim-eligibility.md` documents implemented canonical behavior ✓

**Caveat:** Locale-sensitive formatting in compare path may produce inconsistent string representations when comparing eligible-vs-eligible cases across different environments; normalization contracts for locale-independent output are recommended for future enhancement.

**Follow-up Needed:** No blocker; caveat is environment-scoped and does not affect P0 closure.
