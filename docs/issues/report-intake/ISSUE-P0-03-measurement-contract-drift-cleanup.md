# ISSUE P0-03: Measurement Contract Drift Cleanup

Status: reopened (fail - contract drift remains)
Priority: P0
Primary Agent: Implementer
Secondary Handoff: Reproducibility Review

## Scope

In-scope:
- Remove ad hoc runtime output fallbacks that drift from schema and status contract.
- Align run and postprocess output fields with runtime measurement contract.
- Add drift checks for contract stability on validation samples.

Out-of-scope:
- Defining new benchmark metrics not represented in current schema contract.
- Reworking scenario semantics, load models, or protocol coverage.
- Changing publication claim policy beyond contract enforcement.

## Required Repo Touchpoints

- `tools/bench/`
- `scripts/run-*.sh`
- `schemas/benchmark-result.schema.json`

## Implementation Tasks

1. Inventory runtime result fields emitted by `tools/bench/` and `scripts/run-*.sh` against `schemas/benchmark-result.schema.json`.
2. Replace ad hoc field fallbacks with schema-aligned values and explicit missing-value handling.
3. Add or tighten drift validation checks in runtime postprocess path.
4. Update any run-script adapters in `scripts/run-*.sh` that still emit non-canonical field names.
5. Ensure contract checks fail fast with actionable messages when drift is detected.

## Verification Tasks

1. Validate representative runtime outputs against `schemas/benchmark-result.schema.json` before and after cleanup.
2. Execute drift checks on a validation sample set and confirm no ad hoc fallback paths remain.
3. Confirm run scripts emit canonical field names and status contract values.
4. Confirm failure mode messaging identifies offending fields and source stage.
5. Confirm reproducibility metadata capture remains intact after cleanup.

## Acceptance Criteria

1. Runtime outputs from run and postprocess stages validate against `schemas/benchmark-result.schema.json` without manual patching.
2. Drift checks detect and fail on non-canonical or missing contract-critical fields.
3. No ad hoc fallback logic remains for contract-critical runtime status or measurement fields.
4. `scripts/run-*.sh` outputs align with canonical measurement contract naming.
5. Verification handoff confirms reproducibility metadata coverage is unchanged.

## Risks and Caveats

- Risk of tightening validation beyond current historical artifacts, requiring fixture updates.
- Risk of hidden producer paths under `tools/bench/` that are not covered by default smoke scripts.
- Caveat: this cleanup may expose pre-existing schema debt that should be tracked separately.

## Delivery Artifacts

- Updated files under `tools/bench/`
- Updated files under `scripts/run-*.sh`
- Updated `schemas/benchmark-result.schema.json` if contract clarification is required
- Drift validation evidence on representative runtime sample outputs

## Verification Outcome (2026-03-19)

Verdict: **REOPENED (FAIL - CONTRACT DRIFT REMAINS)**

**Key Evidence (Blocking Issues):**
- Schema enum mismatch: `incomplete_metadata` defined in `schemas/benchmark-result.schema.json` ✓
- `tools/bench/run-jmh-case.sh` validator accepts `incomplete_metadata` in enum list ✓
- Status producer in `tools/bench/lib/status.sh` **does NOT emit** `incomplete_metadata` as `reproducibility_status` value
- Contract drift: schema allows value that producer never generates; validator accepts but status output does not align
- Root cause: enum definition, validator acceptance list, and status.sh producer behavior are out of sync

**Follow-up Required:** Align status.sh producer with validator enum list or remove `incomplete_metadata` from schema enum. Reopen issue for contract reconciliation before verification closure.
