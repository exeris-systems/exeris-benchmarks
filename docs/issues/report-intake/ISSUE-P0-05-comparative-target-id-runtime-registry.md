# ISSUE P0-05: Comparative Target-ID Runtime Registry

Status: in-progress
Priority: P0
Primary Agent: Implementer
Secondary Handoff: Verification

## Scope

In-scope:
- Add a first-class resolver from comparative `target_id` to a runnable target contract.
- Resolve and enforce launcher mode, env file, compose or jar profile, health endpoint, and protocol mode per `target_id`.
- Validate mapping determinism and protocol-mode consistency in comparative readiness checks.
- Fail fast on unknown or unsupported `target_id` before workload execution.
- Require reproducibility metadata capture for each resolved target contract.

Out-of-scope:
- Introducing new comparative scenarios, payload models, or concurrency policies.
- Auto-fallback between substrates or launch profiles (for example, JVM tuned profile to native profile).
- Redefining claim eligibility policy or cross-tier interpretation rules.
- Altering benchmark family boundaries beyond runtime comparative target resolution.

## Required Repo Touchpoints

- `runtime/drivers/start-target.sh`
- `runtime/drivers/stop-target.sh`
- `runtime/drivers/env/`
- `runtime/drivers/docker-compose/`
- `scripts/run-comparative.sh`
- `scripts/validate-comparative-readiness.sh`
- `docs/benchmark-target-labels-and-scenario-contracts.md`

## Implementation Tasks

1. Define canonical comparative `target_id` entries and map each to one runtime launch contract source.
2. Implement a deterministic resolver in runtime driver flow that returns launcher mode, env source, profile, health endpoint, and protocol mode.
3. Integrate resolver output into `start-target.sh` and `stop-target.sh` so launch and teardown use the same resolved contract.
4. Update comparative run path to require resolver output and block execution when target contract fields are missing or inconsistent.
5. Add explicit fail-fast error classification for unknown `target_id` as configuration error before benchmark run starts.
6. Ensure resolved contract metadata is attached to run artifacts needed for reproducibility review.

## Verification Tasks

1. Run comparative readiness validation and confirm all declared `target_id` mappings resolve deterministically.
2. Validate unknown `target_id` fails before run start with explicit configuration error reason.
3. Confirm resolver does not auto-fallback to alternate substrate or profile when requested mapping is unavailable.
4. Verify same-protocol comparative runs enforce protocol-mode consistency in readiness checks.
5. Verify reproducibility metadata includes resolved target contract fields for each comparative run.

## Acceptance Criteria

1. A deterministic `target_id -> launch contract` resolver exists and is used by comparative runtime flow.
2. Resolver contract includes launcher mode, env file, compose or jar profile, health endpoint, and protocol mode.
3. Unsupported or unknown `target_id` fails fast before execution with explicit configuration error output.
4. Comparative readiness checks validate mapping completeness and protocol-mode consistency for compared targets.
5. Comparative runs capture reproducibility metadata for the resolved target contract without silent defaults.

## Risks and Caveats

- Risk: stale registry entries may drift from runtime launch assets; validation must check file/profile existence.
- Risk: partial migration can create split resolution paths if scripts bypass resolver.
- Caveat: fairness requires same protocol, payload, and concurrency across compared targets; resolver enablement does not waive this constraint.
- Caveat: registry must remain explicit; automatic substrate fallback would invalidate comparability and hide configuration defects.

## Delivery Artifacts

- Updated runtime driver scripts with deterministic target contract resolver integration.
- Updated comparative run and readiness validation scripts with fail-fast contract checks.
- Updated target-label and scenario-contract documentation reflecting canonical comparative `target_id` mapping.
- Verification notes demonstrating deterministic resolution, protocol consistency checks, and reproducibility metadata capture.

## Coordination Kickoff (2026-03-23)

- `Primary owner`: Implementer
- `Verification owner`: Verification
- `Checkpoint 1`: resolver contract shape agreed and documented before code merge
- `Checkpoint 2`: fail-fast unknown-target behavior validated in readiness gate
- `Checkpoint 3`: reproducibility metadata fields present in produced artifacts
- `Exit condition`: verification sign-off confirms deterministic mapping and same-protocol enforcement
