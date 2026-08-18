# baselines/

This directory stores **reference result files** used for regression detection.

## Structure

```
baselines/
└── README.md
```

At the moment, the repository does not contain committed baseline JSON files.
Use this directory as the canonical location when baseline artifacts are introduced.

## Environment fences — read before adding the first baseline

A baseline is only meaningful against a run measured in the same environment. Two conditions
are enforced as **fences** by `scripts/compare-results.sh`, and both were measured here rather
than assumed:

| fence | field | measured effect |
|---|---|---|
| DB container network | `run_config.metadata.backend_network_mode` | **+20.5 %** throughput host vs bridge, at *unchanged* application cpu/req (0.357 → 0.358 ms), target-thread `%wait` 265 % → 57 % |
| DB CPU pinning | `run_config.metadata.db_cpuset` | unpinned Postgres shares all cores with the measured target (verified: `Cpus_allowed_list=0-15` against a target pinned to `0-1,8-9`) — it contends with the arm *and* makes DB CPU unattributable |

The network fence alone is **twice the −10 % blocking threshold**. A baseline recorded under
one mode and compared against a run under the other does not produce a noisy answer; it
produces a confident wrong one. `compare-results.sh` therefore refuses the comparison outright
when either fence differs — that refusal is not overridable.

When an artifact simply does not *record* a fence (everything written before 2026-08-08 lacks
`db_cpuset`), the comparison is refused too, but that refusal can be lifted with
`BENCH_ALLOW_UNVERIFIED_FENCES=1`. The output is then stamped **FENCE-UNVERIFIED** and must not
be used to accept or reject a regression.

**Practical consequence:** a baseline file is not self-describing enough on its own. Record the
campaign it came from, `n`, and the observed spread alongside it — a single leaf drawn from an
n=12 campaign carries that leaf's neighbour/slot effect, measured at 2.3–3.9 % on this box.

## Threshold headroom

The thresholds in `docs/regression-policy.md` sit above this box's measured non-regression
spread, but not by much:

| source of spread | magnitude |
|---|---|
| AB/BA legs within a pair | ≤ 1.6 % |
| repeats of the same target across pairs | ≤ 2.7 % |
| neighbour / slot effect | **2.3–3.9 %** |

The worst known non-regression effect is ~1.1 points under the −5 % warning line. Do not lower
the thresholds without re-measuring that spread. Note the neighbour effect is *systematic* — it
depends on which arm shares the leaf — so adding repeats does not shrink it.

## File format

All files conform to [`schemas/benchmark-result.schema.json`](../schemas/benchmark-result.schema.json).

## Updating a baseline

```bash
./scripts/publish-report.sh \
  --result results/raw/<run>.json \
  --env    results/raw/<env>.json \
  --output results/reports/ \
  --archive results/history/jdk/
```

Then copy the result to the appropriate baseline path:

```bash
mkdir -p baselines/community/h1
cp results/raw/<run>.json baselines/community/h1/perf-box-amd64.json
```

Commit with message: `chore(baselines): update community/pure perf-box-amd64 baseline [v1.2.0]`

## Policy

See [docs/regression-policy.md](../docs/regression-policy.md) for update policy.
Baselines are **never updated silently to hide regressions.**
