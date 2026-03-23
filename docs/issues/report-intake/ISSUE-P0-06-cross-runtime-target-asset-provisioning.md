# ISSUE P0-06: Cross-Runtime Target Asset Provisioning (Spring/Quarkus)

Status: implemented (verification conditional)
Priority: P0
Primary Agent: Architect
Secondary Handoff: Implementer

## Methodology Corrections Checklist (P0-06 Slice A Governance)

- [x] Keep `comparative-pair-manifest` as scenario claim contract.
- [x] Add `target-asset-matrix` as operational runnable contract.
- [x] Enforce strict baseline eligibility for same-tier and same-protocol pairs only.
- [x] Require both requested targets to be runnable for baseline path execution.
- [x] Fail fast with explicit `CONFIG_ERROR` reasons for unknown/non-runnable/ineligible targets.
- [x] Emit pair eligibility artifact for exclusion traceability (`pair-eligibility.json`).

## Progress Notes

- Date: 2026-03-23
- Slice A governance complete.
- Slice B: concrete env assets for first runnable Spring pair are present (`runtime/drivers/env/community.env`, `runtime/drivers/env/spring-runtime.env`).
- Slice C complete: Quarkus JVM runnable launcher assets are provisioned (`runtime/drivers/env/quarkus-runtime.env`, `runtime/drivers/docker-compose/quarkus-runtime.yml`), with claim-policy guardrails marking Quarkus onboarding runs as descriptive-only until PASS-only gate status is achieved.
- Quarkus native remains explicitly non-runnable in the target asset matrix.
- Post-approval verification (2026-03-23): matrix/schema/syntax checks passed; dry-run pair gating behaves as expected (`spring-jvm-vt-tuned` vs `quarkus-jvm-vt-tuned` passes, `exeris-native-community` vs `quarkus-jvm-vt-tuned` fails with `CONFIG_ERROR`); non-dry-run attempt is blocked at Stage 4 because target launch is external and required services were not running.
- Real-run retry (2026-03-23): runtime driver launch/stop precondition failed for both targets with `RC=125` (`unknown shorthand flag: 'f' in -f` from Docker CLI invocation), and comparative non-dry execution exited `RC=1` in Stage 4 while waiting for `spring-jvm-vt-tuned` health; `pair-eligibility.json` and `resolved-target-contracts.json` were written but `stage7-gate-report.csv` was not produced.

## Problem Statement

Comparative target IDs exist for Spring and Quarkus runtime profiles, but runnable launcher assets are missing for part of the declared profile set.
As a result, the full cross-runtime baseline matrix cannot yet be executed under a consistent same-protocol comparative contract.

## Scope

In-scope:

- Inventory current Spring/Quarkus comparative `target_id` declarations against launcher assets.
- Build and maintain a deterministic `target_id -> asset` matrix for declared comparative targets.
- Label each declared target as runnable or non-runnable based on concrete launcher asset availability.
- Add or complete launcher assets for selected P0 comparative targets.
- Filter comparative pairs so baseline claims only include runnable, protocol-compatible pairs.

Out-of-scope:

- Changing scenario payload, concurrency, or methodology policy.
- Cross-tier superiority claims or claims across protocol modes.
- Hidden target-specific tuning that creates asymmetry between compared runtimes.
- Expanding benchmark family scope beyond runtime comparative baseline enablement.

## Required Touchpoints

- `runtime/drivers/env/`
- `runtime/drivers/docker-compose/`
- `targets/`
- `scripts/run-comparative.sh`
- `docs/benchmark-target-labels-and-scenario-contracts.md`

## Implementation Tasks

1. Produce a complete Spring/Quarkus target asset inventory for declared comparative `target_id` values.
2. Create a maintained `target_id` to launcher-asset matrix with protocol mode and profile metadata.
3. Add explicit runnable/non-runnable labels for each declared comparative target.
4. Implement launcher assets for selected P0 Spring/Quarkus targets required for baseline execution.
5. Update comparative execution filtering so only runnable, same-protocol pairs are considered baseline-eligible.

## Verification Tasks

1. Validate every declared comparative `target_id` resolves to runnable assets or explicit non-runnable label.
2. Validate comparative scripts exclude non-runnable targets from baseline pair generation.
3. Verify protocol-mode consistency checks remain enforced for all generated comparative pairs.
4. Verify run outputs preserve reproducibility metadata and target labeling after filtering.
5. Verify no baseline section includes a pair that lacks runnable launcher assets on either side.

## Acceptance Criteria

1. Each declared comparative `target_id` is classified as runnable (with concrete launcher assets) or explicitly non-runnable.
2. A target-asset matrix exists and is used to gate comparative pair generation.
3. Comparative baseline matrix generation includes only runnable, same-protocol pairs.
4. Spring/Quarkus comparative execution path fails early when a requested target lacks required launcher assets.
5. Documentation reflects runnable/non-runnable status and baseline eligibility boundaries.

## Risks and Caveats

- Fairness risk: provisioning only one side of a pair can produce apples-to-oranges comparisons if pair filtering is not strict.
- Methodology risk: profile-level drift can invalidate same-contract comparability even when launchers exist.
- Reproducibility risk: missing profile metadata can hide why a target was classified non-runnable.
- Caveat: no hidden tuning asymmetry is allowed; asset provisioning must preserve equivalent scenario semantics across compared runtimes.
