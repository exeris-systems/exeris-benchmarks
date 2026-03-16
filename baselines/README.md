# baselines/

This directory stores **reference result files** used for regression detection.

## Structure

```
baselines/
├── community/
│   ├── h1/
│   │   ├── perf-box-amd64.json
│   │   └── ci-runner.json
│   └── h2/
│       ├── perf-box-amd64.json
│       └── ci-runner.json
├── enterprise/
│   ├── h1/
│   │   └── perf-box-amd64.json
│   ├── h2/
│   │   └── perf-box-amd64.json
│   └── h3/
│       └── perf-box-amd64.json
└── spring-runtime/
    ├── pure/
    │   └── perf-box-amd64.json
    └── compat/
        └── perf-box-amd64.json
```

## File format

All files conform to [`schemas/benchmark-result.schema.json`](../schemas/benchmark-result.schema.json).

## Updating a baseline

```bash
./scripts/publish-report.sh \
  --result results/raw/<run>.json \
  --env    results/raw/<env>.json \
  --output results/summaries/ \
  --archive results/history/community/pure/
```

Then copy the result to the appropriate baseline path:

```bash
cp results/raw/<run>.json baselines/community/h1/perf-box-amd64.json
```

Commit with message: `chore(baselines): update community/pure perf-box-amd64 baseline [v1.2.0]`

## Policy

See [docs/regression-policy.md](../docs/regression-policy.md) for update policy.
Baselines are **never updated silently to hide regressions.**
