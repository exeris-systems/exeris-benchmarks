# results/

This directory stores benchmark run outputs.

## Structure

```
results/
├── raw/                 # Direct tool output — wrk .txt, JMH .json, k6 .json
├── reports/             # Generated summaries and report artifacts
├── constrained/         # Constrained execution artifacts
├── quick-verify-fix-jfr/# Verification snapshots related to JFR fixes
├── verify-phasemarker/  # Verification run marker artifacts
└── history/
    └── jdk/             # Archived JDK-oriented history bundles
```

## What goes here

- `raw/` — unmodified output from wrk, h2load, k6, JMH. Committed for traceability.
- `reports/` — human-readable Markdown summaries and generated report bundles.
- `history/` — archived per-run results for long-term trend tracking.
- `reports/protocol-matrix.md` — protocol and comparison report output path.

## Comparative Strict-Gate Artifacts

Comparative runtime runs now emit strict gate artifacts and fail closed.

Expected files under comparative output directories:

- `stage7-gate-report.csv`: machine-readable gate rows (`scope,gate_id,gate_name,pass_fail,rejection_code,...`).
- `stage7-gate-summary.json`: structured gate summary with `rejection_codes`.
- `claim-status.json`: final claim status (`comparison_eligible` or `non_eligible`) plus track/pair metadata.
- `rejection-codes.json`: machine-readable reason-code list for rejected runs.

Interpretation rules:

- Comparative math is valid only when claim status is `comparison_eligible` and strict gates pass.
- `track_id` is an isolation boundary. Do not aggregate or compare across mixed tracks.
- Report outputs must include explicit axis labels and track label; cross-track claims are blocked.

Generate protocol matrix report:

```bash
./scripts/report-protocol-matrix.sh results/normalized > results/reports/protocol-matrix.md
```

## Publication modes and JFR confidentiality guard

`scripts/publish-report.sh` defaults to `--publication-mode public`.

- `public` (default): default-deny for raw JFR. Inputs are checked with case-insensitive `.jfr` extension matching and content-level JFR signature detection (`FLR\0`), and any detected raw JFR is blocked.
- `internal-only`: permits raw `.jfr` handling for restricted/internal publication only.
- `redacted`: permits JFR-related attachments only when raw JFR is not detected by case-insensitive extension/signature checks.

Confidentiality labels are emitted in generated report metadata:

- `publication_mode`
- `confidentiality_status`
- `jfr_handling`

Examples:

```bash
# Public/default publication (raw JFR blocked)
./scripts/publish-report.sh --result results/raw/run.json --output results/reports/

# Internal-only publication (raw JFR allowed)
./scripts/publish-report.sh \
    --result results/raw/run.json \
    --output results/reports/ \
    --archive results/history/jdk/ \
    --publication-mode internal-only \
    --jfr-artifact results/raw/jfr/run-01.jfr

# Redacted publication (non-.jfr artifact required)
./scripts/publish-report.sh \
    --result results/raw/run.json \
    --output results/reports/ \
    --publication-mode redacted \
    --jfr-artifact results/raw/jfr/run-01-redacted.txt
```

## Profile label legend (B3/B4/B5/B6/B7)

Use explicit labels in published artifacts:

| Label | Meaning |
|---|---|
| `B3` | JDK `SSLEngine` baseline |
| `B4` | Netty tcNative baseline |
| `B5` | Exeris OffHeapTlsEngine engine-level benchmark via neutral in-process Memory-BIO harness |
| `B6` | Exeris Community FD-owner/socket path (includes kernel crossing) |
| `B7` | Exeris Memory-BIO path (in-process) |

GC/heap comparisons are publishable only when these model labels are present with tier/protocol context.

## gitignore note

Raw files can be large. If raw/ becomes too large, consider adding large files to
`.gitignore` and archiving them externally, keeping only `reports/` and `history/`
in git.
