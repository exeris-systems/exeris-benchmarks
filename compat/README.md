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

## Sourcing data from the comparative harness (entity-read-by-id)

The sequential protocol above measures the two modes in **separate runs**, so drift
between them lands inside the overhead figure. The `entity-read-by-id` comparative
harness collects the same two arms in **one leaf**, under matched conditions, in both
`ab` and `ba` order — which is strictly stronger. Two of its pairs exist for that
reason and route their results here:

| pair | what it isolates |
|---|---|
| `spring-on-exeris__spring-on-exeris-pure` | the compat layer alone — one app, one host runtime, one kernel, differing only in whether requests traverse `ExerisCompatDispatcher` |
| `spring-hibernate__spring-on-exeris` | Tomcat hosting vs the Exeris compatibility ingress |

**Their leaves are `non_eligible` and that is correct.** Strict gate G3
(`equivalence_strict`) requires `mode_a == mode_b`, so any cross-mode pair fails with
`EQUIVALENCE_MISMATCH`. The comparative runtime track compares targets *within* one
side of the Pure-vs-Compat axis; these pairs deliberately cross it, because the
crossing is the measurement. The harness is the right way to **collect** them and the
wrong way to **claim** them.

So: take the per-arm numbers out of those leaves, compute overhead by the formula
below, and report it here as compatibility cost. Do **not** publish a leaf from those
pairs as a comparative claim, and do not read `non_eligible` on them as a failed run —
it is the declared expected outcome, recorded as `claim_track: "compat"` and
`expected_claim_status` in `scenarios/entity-read-by-id/comparative-pair-manifest.json`.

The third pair, `spring-hibernate__spring-on-exeris-pure`, is within-mode (both
`pure`) and stays in the comparative track as a normal eligible claim.

## Reporting rules

- Pure mode and compat mode results must always be stored separately.
- Overhead = `(compat_latency_mean - pure_latency_mean) / pure_latency_mean × 100`.
- Label all compat results explicitly as "compatibility mode" in any report.
