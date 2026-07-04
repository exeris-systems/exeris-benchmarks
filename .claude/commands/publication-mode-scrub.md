---
description: Verify publication-mode discipline — `publish-report.sh` default `public` blocks raw `.jfr`; `internal-only` or `redacted` modes require explicit reason.
argument-hint: publication / report / artefact promotion change to audit
---

Audit this publication step against publication-mode discipline.

Publication modes (per repo `CLAUDE.md`):
- `publish-report.sh` defaults to `--publication-mode public`.
- `public` blocks raw JFR by **extension** (case-insensitive `.jfr`) AND **content signature** (`FLR\0`).
- `internal-only` permits raw JFR for restricted publication.
- `redacted` permits only non-`.jfr` JFR-derived artefacts.
- Generated reports stamp `publication_mode`, `confidentiality_status`, and `jfr_handling`.

Confidentiality rules:
- Raw JFR, flamegraphs, diagnostics treated as potentially sensitive.
- Enterprise internals (H3, locality, enterprise targets) excluded from public-track artefacts.
- Default position: refuse cross-repo / public movement unless explicit scrub has been done.

Change:
$ARGUMENTS

Please review:
1. What `--publication-mode` is the run claiming? Is the choice justified?
2. If `public`: are all `.jfr` files blocked (extension AND content-signature check passes)?
3. If `internal-only` or `redacted`: is the recipient / audience explicitly named?
4. Does the generated report stamp `publication_mode`, `confidentiality_status`, `jfr_handling`?
5. Does any enterprise-only behaviour (H3, locality, enterprise targets) appear on a Community-labelled report?
6. Minimal correction if publication discipline is at risk.

Default is `public` for a reason. Deviation needs explicit justification, not "it's easier this way".
