# tools/

Utility tools for result processing and reporting.

## Current Layout

- `tools/bench/` — manifest-driven TLS/JMH runners and helpers
- `tools/matrix/` — matrix manifests used by orchestrators
- `tools/benchmark-runner-with-metrics.sh` — wraps an arbitrary benchmark command with `/usr/bin/time -v`
- `tools/extract-jfr-metrics.sh` — extracts CPU/memory/GC metrics from JFR files
- `tools/compute-fairness-index.sh` — computes fairness index between two normalized result files
- `tools/verify-classification.sh` — validates classification fields in generated `status.csv`
- `tools/verify-target-asset-matrix.sh` — validates runtime target asset matrix integrity

## benchmark-runner-with-metrics.sh

Helper/process-metrics utility that wraps an existing benchmark command with
`/usr/bin/time -v` and writes `<output_json>.with-metrics.json`.

It is not a primary benchmark runner and does not replace
`tools/bench/run-jmh-case.sh` orchestration.

## extract-jfr-metrics.sh

Extracts resource metrics from JFR recording files using `jfr print --json`.

Usage:

```bash
tools/extract-jfr-metrics.sh <input.jfr> [output.json]
```

- When `output.json` is omitted, metrics are printed to stdout.
- When output path ends with `.with-metrics.json`, the script patches `resource_metrics` into that file.

## compute-fairness-index.sh

Computes fairness index between two normalized benchmark results and writes JSON compliant with `schemas/fairness-index.schema.json`.

Usage:

```bash
tools/compute-fairness-index.sh \
  --result-a results/a-normalized.json \
  --result-b results/b-normalized.json \
  --output results/fairness-index.json
```

## verify-classification.sh

Validates generated `status.csv` rows and enforces canonical enums and consistency rules for:

- `runner_status`
- `reproducibility_status`
- `final_reason`
- `claim_scope`

Usage:

```bash
tools/verify-classification.sh <status.csv>
```

## verify-target-asset-matrix.sh

Validates `runtime/drivers/target-asset-matrix.json` structure and checks scenario/target consistency against `scenarios/**/comparative-pair-manifest.json`.

Usage:

```bash
tools/verify-target-asset-matrix.sh
```

## Notes

- For matrix-driven TLS runs, use `scripts/run-primary-tls-matrix.sh` and `tools/bench/run-jmh-case.sh`.
- `tools/bench/tests/` contains shell smoke/contract tests for helper behavior.
