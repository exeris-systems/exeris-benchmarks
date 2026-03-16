# Regression Policy

## What is a regression?

A **regression** is a statistically significant performance degradation relative
to the stored baseline for the same scenario, hardware profile, and mode
(pure / compat, community / enterprise).

---

## Regression thresholds

| Metric | Warning threshold | Blocking threshold |
|---|---|---|
| Throughput (req/s) | −5% | −10% |
| Mean latency | +5% | +10% |
| p99 latency | +10% | +20% |
| p999 latency | +15% | +30% |
| JMH Score (avgt / thrpt) | +/- 5% | +/- 10% |
| Allocation rate (gc.alloc.rate.norm) | any non-zero on zero-alloc path | ≥ 1 B/op |

Warning: the CI job posts a comment on the associated PR.  
Blocking: the CI job fails and the result must be investigated before merge.

For zero-allocation paths (hot telemetry, PAQS core, route resolution), **any
measurable allocation is a blocking regression regardless of threshold.**

---

## What triggers a regression evaluation?

1. Any commit to a product repo that is tracked by this benchmark repo triggers
   the `compare-baseline.yml` workflow.
2. Any manual `workflow_dispatch` of `runtime-bench.yml` or `microbench.yml`
   followed by `compare-baseline.yml`.
3. Any PR that modifies a scenario, JMH benchmark, or target configuration
   triggers a re-run against the stored baseline.

---

## How to handle a blocking regression

1. **Do not merge the PR** until the regression is resolved.
2. Identify whether the regression is:
   - **Intentional** — a conscious tradeoff (e.g., adding a feature that costs
     latency). In this case update the baseline after explicit sign-off, and
     document the tradeoff in the scenario README.
   - **Unintentional** — a bug or inefficiency introduced by the change.
     Fix it before merging.
3. Use `scripts/compare-results.sh` to pinpoint which scenario(s) regressed.
4. If the regression is environment noise (stddev > threshold on both sides),
   re-run with a longer duration on the `perf-box-amd64` profile before deciding.

---

## Baseline update policy

Baselines are updated **only** when:

- A new feature intentionally changes the performance envelope (with sign-off).
- A hardware profile is retired and a new one substituted.
- A methodology change (e.g., new warmup duration) requires resetting all
  baselines — documented in a commit message with justification.

Baselines are **never** updated silently to hide regressions.

---

## CI regression jobs

| Workflow | Trigger | Scope |
|---|---|---|
| `microbench.yml` | PR, push to main | JMH smoke — selected fast microbenchmarks |
| `runtime-bench.yml` | Nightly, manual | Full HTTP load run on `ci-runner` profile |
| `compare-baseline.yml` | After runtime-bench or microbench | Diff current vs baseline, post result |
| `publish-results.yml` | After tagged release | Archive result to `results/history/` |

The `ci-runner` profile has high variance; regressions detected there are
**warnings only**. Blocking regressions must be confirmed on `perf-box-amd64`
before blocking a release.

---

## Handling false positives

If a regression alert fires but the underlying code did not change the relevant
path:

1. Check the environment capture for both runs (different CPU governor? GC mode?).
2. Re-run three times and take the median.
3. If the median confirms no regression, the alert was noise — document this in
   the PR and re-run.
4. If the variance profile for the scenario is persistently high, tighten the
   scenario (longer warmup, pinned CPU) rather than widening the threshold.
