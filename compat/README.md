# compat/ — Compatibility Cost Benchmarks

Benchmarks specifically designed to measure compatibility mode overhead.

See [docs/benchmark-philosophy.md](../docs/benchmark-philosophy.md#layers-of-truth)
for definition of the **compat layer**.

## Structure

Compatibility benchmarks live here or reference scenarios from [scenarios/](../scenarios/)
with compat-specific drivers or configurations.

## What is measured

This directory quantifies the overhead introduced by Exeris compatibility layers:

- **spring-runtime**: Phase 1 pure mode vs Phase 2 compatibility mode overhead
- **persistence**: Native repository path vs JDBC bridge overhead

## Why this matters

Exeris claims specific performance characteristics for each mode. The compat/
benchmarks exist to make the cost of compatibility **explicit, measured, and
documented** — not hidden.

## Running a comparison

```bash
# Start spring-runtime in pure mode
EXERIS_SPRING_MODE=pure ./runtime/drivers/start-target.sh spring-runtime
./scripts/run-wrk.sh targets/exeris-spring-runtime scenarios/plaintext
cp results/raw/wrk-latest.txt /tmp/pure-result.txt

# Restart in compat mode
./runtime/drivers/stop-target.sh spring-runtime
EXERIS_SPRING_MODE=compat ./runtime/drivers/start-target.sh spring-runtime
./scripts/run-wrk.sh targets/exeris-spring-runtime scenarios/plaintext
cp results/raw/wrk-latest.txt /tmp/compat-result.txt
```

Then normalize and compare:

```bash
./scripts/compare-results.sh \
  baselines/spring-runtime/pure/perf-box-amd64.json \
  results/normalized/compat-latest.json
```

## Reporting rules

- Pure mode and compat mode results must always be stored separately.
- Overhead = `(compat_latency_mean - pure_latency_mean) / pure_latency_mean × 100`.
- Label all compat results explicitly as "compatibility mode" in any report.
