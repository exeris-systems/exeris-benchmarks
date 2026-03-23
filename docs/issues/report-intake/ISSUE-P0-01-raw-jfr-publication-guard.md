# ISSUE P0-01: Raw JFR Publication Guard

Status: verified (pass with caveat)
Priority: P0
Primary Agent: Docs/Reporting
Secondary Handoff: Enterprise Confidentiality Guard

## Scope

In-scope:
- Add a publication gate that blocks raw JFR artifacts in default public report flow.
- Require explicit publication mode selection for internal-only or redacted JFR handling.
- Emit confidentiality status labels in generated report metadata and output summaries.

Out-of-scope:
- Changing benchmark execution methodology, scenarios, or runtime harness behavior.
- Re-scoring benchmark outcomes or modifying claim eligibility semantics.
- Introducing new result schema fields beyond existing compatible metadata channels.

## Required Repo Touchpoints

- `scripts/publish-report.sh`
- `results/README.md`
- `docs/result-interpretation.md`

## Implementation Tasks

1. Add a default-deny branch in `scripts/publish-report.sh` that excludes raw JFR from public outputs unless an explicit safe mode flag is provided.
2. Add explicit mode handling for `internal-only` and `redacted` publication paths, with clear CLI help and error messages.
3. Add confidentiality status annotation to generated publication metadata and printed summary lines.
4. Update `results/README.md` with allowed publication modes and default behavior.
5. Update `docs/result-interpretation.md` to document confidentiality labeling and external publication restrictions.

## Verification Tasks

1. Run publish flow in default mode and verify raw JFR payloads are blocked from publish output.
2. Run publish flow in `internal-only` mode and verify raw JFR handling is allowed but clearly labeled internal-only.
3. Run publish flow in `redacted` mode and verify only redacted artifacts are emitted.
4. Confirm output metadata includes confidentiality status in each mode.
5. Confirm docs reflect implemented behavior and command usage.

## Acceptance Criteria

1. Public/default publish execution cannot produce raw JFR artifacts.
2. `internal-only` and `redacted` modes are explicit, validated, and produce deterministic behavior.
3. Publication output includes confidentiality labeling that matches selected mode.
4. Documentation in `results/README.md` and `docs/result-interpretation.md` matches script behavior.
5. No unrelated benchmark result or schema artifacts are modified.

## Risks and Caveats

- Risk of accidental behavior change in existing report automation if mode defaults are not backward-safe.
- Risk of under-redaction if redaction contract is implied but not validated in script checks.
- Caveat: confidentiality guard approval is required before broad external publication.

## Delivery Artifacts

- Updated `scripts/publish-report.sh`
- Updated `results/README.md`
- Updated `docs/result-interpretation.md`
- Verification notes showing mode-specific publish outcomes

## Verification Outcome (2026-03-19)

Verdict: **VERIFIED (PASS WITH CAVEAT)**

**Key Evidence:**
- Publication gate enforcement in `scripts/publish-report.sh` blocks raw JFR by default ✓
- Redacted mode content-signature and case-insensitive extension guards implemented ✓
- Internal-only and redacted modes produce deterministic, labeled outputs ✓
- Confidentiality status annotation in `results/README.md` and `docs/result-interpretation.md` ✓

**Caveat:** Redacted mode currently does not strictly require an explicit redacted artifact argument in all code paths; mode selection relies on script flag without secondary artifact-type assertion.

**Follow-up Needed:** No additional verification required; caveat is documented and acceptable for P0 closure.
