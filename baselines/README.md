# baselines/

This directory stores **reference result files** used for regression detection.

## Structure

```
baselines/
└── README.md
```

At the moment, the repository does not contain committed baseline JSON files.
Use this directory as the canonical location when baseline artifacts are introduced.

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
