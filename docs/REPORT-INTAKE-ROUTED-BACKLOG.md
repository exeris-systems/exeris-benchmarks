# Report Intake Routed Backlog

This backlog is derived from external Java performance report analysis and routed by Exeris benchmark separation axes and evidence-first constraints.

## Current State

- Claim gating semantics are documented and enforceable via `runner_status`, `reproducibility_status`, `final_reason`, and `claim_scope`.
- Environment and reproducibility capture paths are defined, including commit SHA, toolchain, JVM flags, and hardware metadata expectations.
- `execution_class` and related status normalization work has reduced ambiguity between success, partial, and failed benchmark outcomes.
- Publication paths now include explicit caveats and eligibility boundaries so descriptive output is not presented as comparison-eligible evidence.
- Methodology review mapping exists from specification to implementation phases, with sign-off criteria linked to concrete gates.
- P0-05 resolver and readiness gate I are implemented and dry-run validated, with fail-fast behavior confirmed; caveat: only mapped runnable targets are currently executable.
- Remaining publication caveat: raw JFR artifacts still require stricter confidentiality and publication guards before broad external release.

## Execution Order

- P0: Release gate hardening for publication safety and claim eligibility consistency.
- P1: Contract completion for runtime metadata and naming normalization.
- P2: Capability expansion and follow-on benchmark families after P0 and P1 closure.

## Backlog

| ID | Priority | Title | Benchmark Family | Target Scope | Comparison Axis | Primary Agent | Secondary Handoff | Repo Touchpoints | Dependency | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P0-01 | P0 | Raw JFR Publication Guard | Runtime | Community and Enterprise, all protocol modes | Cross-tier publication safety, not performance ranking | Docs/Reporting | Enterprise Confidentiality Guard | `scripts/publish-report.sh`, `results/README.md`, `docs/result-interpretation.md` | Existing result schema and publish flow | Public report path blocks raw JFR by default, requires explicit internal-only or redacted mode, and labels confidentiality status in output metadata. |
| P0-02 | P0 | Runtime Claim-Eligibility Normalization | Runtime | Community and Enterprise, same scenario and protocol only | Within-tier same-protocol comparability | Implementer | Methodology/Results Review | `scripts/compare-results.sh`, `tools/verify-classification.sh`, `docs/status-and-claim-eligibility.md` | P0-01 publication guard for external outputs | Non-eligible runs are excluded from comparative sections; `claim_scope` handling is consistent across compare and publish scripts. |
| P0-03 | P0 | Measurement Contract Drift Cleanup | Runtime | Runtime harness outputs | Contract stability across run and postprocess stages | Implementer | Reproducibility Review | `tools/bench/`, `scripts/run-*.sh`, `schemas/benchmark-result.schema.json` | P0-02 normalization logic | Runtime output fields match schema and status contract without ad hoc fallbacks; drift checks pass on validation set. |
| P0-04 | P0 | cert_key_bits OpenSSL 3.x Compat Fix | Runtime | TLS cert harness path | Toolchain compatibility axis | Implementer | None | `tools/bench/lib/certs.sh` | None | `cert_key_bits()` returns correct bit count for RSA/EC keys on both OpenSSL 1.x and 3.x; TLS matrix smoke runs pass cert assertion. |
| P0-05 | P0 | Comparative Target-ID Runtime Registry | Runtime | Community, Enterprise, and Spring Runtime comparative targets | Within-tier same-protocol comparability enablement | Implementer | Verification | `runtime/drivers/start-target.sh`, `runtime/drivers/stop-target.sh`, `runtime/drivers/env/`, `runtime/drivers/docker-compose/`, `scripts/run-comparative.sh`, `scripts/validate-comparative-readiness.sh`, `docs/benchmark-target-labels-and-scenario-contracts.md` | P0-03 measurement contract stability | Deterministic `target_id -> launch` contract resolver exists; unsupported IDs fail fast with explicit reason; comparative readiness check validates mapping and protocol-mode consistency; Spring/Quarkus native or JVM profiles without launcher assets remain explicitly unsupported by design. |
| P0-06 | P0 | Cross-Runtime Target Asset Provisioning (Spring/Quarkus) | Runtime | Spring Runtime and Quarkus comparative targets | Within-tier same-protocol comparability enablement | Architect | Implementer | `runtime/drivers/env/`, `runtime/drivers/docker-compose/`, `targets/`, `scripts/run-comparative.sh`, `docs/benchmark-target-labels-and-scenario-contracts.md` | P0-05 resolver integration complete | Each declared comparative `target_id` has runnable launcher assets or is explicitly labeled non-runnable; comparative matrix only includes runnable pairs for baseline claims. |
| P1-01 | P1 | Loom Thread-Model Contract | Runtime | JVM thread model variants by scenario | Intra-target thread-model axis, no cross-tier claims by default | Architect | Implementer | `runtime/`, `scenarios/`, `docs/methodology.md` | P0 contract cleanup complete | Thread-model metadata is captured per run and reports label model explicitly; no mixed-model comparison is emitted without caveat. |
| P1-02 | P1 | CPU Affinity and cgroup Telemetry Completeness | Runtime | Host and container execution contexts | Environment-control reproducibility axis | Implementer | Reproducibility Review | `scripts/capture-env.sh`, `schemas/reproducibility-metadata.schema.json`, `docs/hardware-profiles.md` | P0-03 measurement contract stability | Captured metadata includes affinity and cgroup fields when available, with explicit missing-value semantics and verifier coverage. |
| P1-03 | P1 | Canonical claim_scope Vocabulary Cleanup | Runtime and reporting | Status CSV, report generation, dashboard inputs | Claim vocabulary consistency axis | Implementer | Docs/Reporting | `tools/bench/lib/`, `scripts/compare-results.sh`, `docs/status-and-claim-eligibility.md` | P0-02 normalization | All producers and consumers use one canonical `claim_scope` vocabulary; no legacy synonyms appear in generated artifacts. |
| P2-01 | P2 | AOT/Native-Image Benchmark Family | Runtime | Community and Enterprise where supported | Family separation: runtime vs compatibility capabilities | Architect | Implementer | `scenarios/`, `runtime/`, `docs/scenario-catalog.md` | P1 metadata completeness and claim vocabulary cleanup | New family is labeled as exploratory until repeatability gates are met; results are isolated from baseline regression claims. |
| P2-02 | P2 | D3 Community Loopback Handshake Benchmark | Runtime | Community D3 loopback handshake path | Protocol and target-scope constrained handshake comparison | Implementer | Methodology/Results Review | `scenarios/handshake-cold/`, `scripts/run-tls-matrix.sh`, `docs/tls-zero-copy-benchmark-matrix.md` | P0 claim normalization and JFR guard | Scenario defines payload, concurrency, and protocol controls; outputs include full reproducibility metadata before any comparative interpretation. |
| P2-03 | P2 | D4 Lifecycle Probes for Runtime Harness | Runtime | Harness lifecycle and launcher orchestration | Harness observability axis, not throughput ranking | Implementer | Reproducibility Review | `runtime/drivers/`, `tools/bench/`, `docs/community-runtime-integration.md` | P0-03 contract cleanup | Lifecycle probe events are schema-compatible and do not alter workload semantics; validation confirms no benchmark timing contamination. |
| P2-04 | P2 | Methodology Sign-off Closure | Reporting and governance | Entire benchmark program | Final evidence-bound claim readiness axis | Methodology/Results Review | Docs/Reporting | `docs/METHODOLOGY-REVIEW-STATUS-CLAIM-ELIGIBILITY.md`, `docs/README-STATUS-METHODOLOGY.md` | P0 and P1 backlog closure evidence | Sign-off checklist is fully satisfied with linked artifacts, and any remaining caveats are explicitly documented as non-comparison-eligible. |

## Agent Routing Notes

- Implementer owns script and harness changes, but must not reinterpret claim policy beyond approved semantics.
- Methodology/Results Review owns acceptance on claim eligibility and must reject cross-axis overclaims.
- Reproducibility Review owns metadata completeness checks, including hardware, JVM flags, and environment controls.
- Docs/Reporting owns publication wording and caveats, and must label tier, protocol, family, and comparison limits in every summary.
- Enterprise Confidentiality Guard must review raw traces and diagnostics before any public artifact is published.
- Architect should be engaged when a backlog item changes benchmark family boundaries or introduces a new comparison axis.
- No agent may claim cross-tier superiority, protocol-general performance, or causal explanations beyond measured evidence.

## Issue Packets

- `P0-01` Raw JFR Publication Guard: `in-review (fix required)` (`docs/issues/report-intake/ISSUE-P0-01-raw-jfr-publication-guard.md`) - follow-up blocker: redacted-mode content validation
- `P0-02` Runtime Claim-Eligibility Normalization: `ready-for-implementation` (`docs/issues/report-intake/ISSUE-P0-02-claim-eligibility-normalization.md`)
- `P0-03` Measurement Contract Drift Cleanup: `verified (pass with caveat)` (`docs/issues/report-intake/ISSUE-P0-03-measurement-contract-drift-cleanup.md`)
- `P0-04` cert_key_bits OpenSSL 3.x Compat Fix: `in-progress` (`docs/issues/report-intake/ISSUE-P0-04-cert-key-bits-openssl3-compat.md`)
- `P0-05` Comparative Target-ID Runtime Registry: `implemented (verification in progress)` (`docs/issues/report-intake/ISSUE-P0-05-comparative-target-id-runtime-registry.md`) - fail-fast behavior verified in dry-run; readiness verification continues
- `P0-06` Cross-Runtime Target Asset Provisioning (Spring/Quarkus): `implemented (verification conditional)` (`docs/issues/report-intake/ISSUE-P0-06-cross-runtime-target-asset-provisioning.md`) - Slice A governance complete; Slice B runnable Spring pair assets added; Slice C promotes Quarkus JVM to runnable with descriptive-only claim guardrails (Quarkus native remains non-runnable); post-approval verification confirms dry-run pass/forbidden gating and real-run block at external-launch Stage 4 precondition; 2026-03-23 retry shows runtime driver launch/stop currently fails with Docker CLI `-f` flag handling (`RC=125`), so comparative real-run still stops in Stage 4 before Stage 7 gate output
