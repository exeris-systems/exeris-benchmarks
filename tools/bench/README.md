# tools/bench

Manifest-driven shell runners for the primary TLS JMH matrix.

## Components

- `tools/matrix/manifests/primary-tls-matrix.json`: benchmark definitions (B3, B4, B5, B6, B6b, B7), phases (`baseline`, `profile`, `gc`), JVM args, cert requirements, and metadata fields (`tier`, `family`, `implementation_variant`)
- `tools/bench/run-jmh-case.sh`: executes one benchmark case from manifest
- `scripts/run-primary-tls-matrix.sh`: thin orchestrator that iterates benchmarks and phases
- `tools/bench/normalize-result.sh`: converts run artifacts to normalized result JSON for compare/publish flows
- `tools/bench/lib/*.sh`: helper libraries for certs, paths, JMH artifacts, status, reproducibility metadata

## Single-Case Runner

```bash
./tools/bench/run-jmh-case.sh \
  --benchmark-id B6 \
  --class FdOwnerTlsEngineLoopbackBenchmark \
  --phase baseline \
  --output-dir results/manual-run \
  --manifest-file tools/matrix/manifests/primary-tls-matrix.json \
  --env-source community \
  --headless
```

Supported options: `--benchmark-id`, `--class`, `--phase`, `--output-dir`, `--manifest-file`, `--env-source`, optional `--headless`.

Additional behavior:

- `BENCH_TIMEOUT` environment variable can override timeout (seconds or `s|m|h` suffix).
- `--env-source` is validated against manifest `sysprops_env_source`; manifest value is authoritative.
- `jq` is required; `timeout` is used when available.

## Orchestrator

```bash
MODE=all HEADLESS=0 FAIL_FAST=0 ./scripts/run-primary-tls-matrix.sh
```

Supported env vars:

- `MODE=baseline|profile|gc|all`
- `HEADLESS=0|1`
- `FAIL_FAST=0|1`
- `AUTO_BUILD_JMH=0|1`: rebuild `micro/jmh/target/benchmarks.jar` when missing/stale (default `1`)
- `MANIFEST_FILE=<path>`: custom matrix manifest path
- `BENCH_FILTER=<regex>`: filters benchmark IDs (e.g. `B6|B6b|B7`)
- `PHASE_FILTER=<regex>`: filters phases (e.g. `baseline|profile`)

## Artifacts and Status

Each case writes artifacts under `results/raw/tls-matrix/<timestamp>/<phase>/`:

- `<id>_<phase>.log`
- `<id>_<phase>-jmh.json`
- `<id>_<phase>.cmd`
- `<id>_<phase>.jvm-args.txt`
- `<id>_<phase>.status.json`
- `<id>_<phase>.reproducibility-metadata.json`
- `<id>_<phase>-normalized.json` (orchestrator normalization step)
- optionally `<id>_<phase>.jfr` and `<id>_<phase>-metrics.json` (when JFR/profile is enabled)

Run-level artifact:

- `results/raw/tls-matrix/<timestamp>/status.csv`

Current status enums in `.status.json`:

- `runner_status`: `success | partial | failed`
- `reproducibility_status`: `complete | incomplete_artifacts | incomplete_metadata | not_assessable`

`write_cmd_artifacts` stores the executed command and initializes an empty `.jvm-args.txt`; `run-jmh-case.sh` then writes the full runtime JVM args list to `.jvm-args.txt`.

`run-jmh-case.sh` exits with the benchmark process exit code. Use `.status.json` for classification and artifact completeness.

## Validation

```bash
for t in tools/bench/tests/*.sh; do echo "==> $t"; bash "$t" || exit 1; done
```

Recommended post-run checks:

```bash
tools/verify-classification.sh results/raw/tls-matrix/<timestamp>/status.csv
tools/verify-target-asset-matrix.sh
```
