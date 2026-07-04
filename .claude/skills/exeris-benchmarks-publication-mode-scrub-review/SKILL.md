---
name: exeris-benchmarks-publication-mode-scrub-review
description: Publication-mode scrub review for exeris-benchmarks. Use whenever `publish-report.sh` runs, when an artefact crosses to a publishable surface, or when raw `.jfr` / flamegraph appears.
---

# Exeris Benchmarks Publication Mode Scrub Review

## Purpose
Enforce: `publish-report.sh` default `--publication-mode public` blocks raw `.jfr` by extension AND `FLR\0` content signature. `internal-only` / `redacted` modes require explicit justification. Enterprise-only behaviour (H3 / locality / enterprise targets) excluded from public-track artefacts.

## When to Use
- Any PR running / configuring `publish-report.sh`.
- Any PR adding artefacts under `results/reports/` or `results/history/` destined for publication.
- Any PR adding raw `.jfr` / flamegraph files.
- Any PR cross-repo movement to `~/exeris-systems/exeris-benchmarks-enterprise/` or external destination.

## Required Inputs
- Publication command + flags.
- Artefacts being published.
- Publication destination.
- Recipient / audience (for `internal-only` / `redacted`).

## Review Procedure
1. **Mode choice** — what `--publication-mode` is chosen? `public` is default; `internal-only` / `redacted` need explicit reason.
2. **`.jfr` extension check** — `public` mode blocks `.jfr` extension (case-insensitive). Confirm.
3. **`FLR\0` content signature check** — `public` mode blocks files starting with `FLR\0`. Confirm.
4. **Enterprise behaviour exclusion** — public artefacts MUST NOT surface H3, locality strategies, or enterprise target classifications (`targets/exeris-community-app-locality/`, `targets/exeris-spring-runtime-benchmark-app-comp/`, `enterprise/` tree).
5. **Report stamps** — generated reports MUST stamp `publication_mode`, `confidentiality_status`, `jfr_handling`.
6. **Cross-repo movement** — if movement to enterprise sister or external, confirm an explicit scrub was performed and documented.
7. **Decision and report** — `APPROVE` / `CONDITIONAL` / `REJECT`.

## Decision Logic
- **APPROVE**: Mode justified; `.jfr` blocked in `public`; enterprise behaviour excluded; stamps present; cross-repo movement scrubbed.
- **CONDITIONAL**: Sound but missing one stamp or one scrub doc — propose the specific addition.
- **REJECT**: `public` mode with raw `.jfr` slipping through; enterprise behaviour in Community-labelled report; cross-repo movement without scrub.

## Completion Criteria
- Mode choice audited.
- `.jfr` extension + content signature checked.
- Enterprise behaviour exclusion confirmed.
- Stamps confirmed.
- Cross-repo movement audited.
- Verdict and remediation recorded.

## Review Output Template
1. **Scope analysed** (publication step / artefacts)
2. **Mode choice** (`public` / `internal-only` / `redacted` + justification)
3. **`.jfr` block** (extension + content signature checks)
4. **Enterprise behaviour exclusion** (clean / leak)
5. **Stamps** (publication_mode / confidentiality_status / jfr_handling)
6. **Cross-repo movement** (none / scrubbed / unscrubbed)
7. **Verdict** (`APPROVE` / `CONDITIONAL` / `REJECT`)
8. **Required actions** (precise and minimal)

## Non-Negotiable Rules
- Never approve raw `.jfr` reaching the `public` publication surface.
- Never approve enterprise-only behaviour in Community-labelled reports.
- Never approve cross-repo movement without explicit, documented scrub.
- Never approve missing publication-mode stamps in generated reports.
