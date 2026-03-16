# Community Runtime Integration

This document explains the canonical Community runtime probes integrated directly
into this benchmark repository.

## Canonical source

- Launcher: `runtime/drivers/community-stack-launcher.sh`
- k6 probe: `scenarios/health-probe/k6.js`
- h2load probe: `runtime/drivers/h2load-health-h1.sh`
- Flamegraph assets/scripts: `tools/flamegraphs/`

## How it maps to current taxonomy

- `scenarios/health-probe/k6.js` -> runtime smoke/health probe (`community-h1-health-probe`, `community-h2-health-probe`)
- `runtime/drivers/h2load-health-h1.sh` -> protocol probe (`community-h1-health-probe`)
- Flamegraphs -> historical/perf-forensics artifacts (not merge-gate)

## Recommended use

1. Use canonical Community launcher as quick runtime smoke baseline.
2. Save outputs to `results/raw/` with protocol/tier naming.
3. Normalize selected runs to `results/normalized/` with:
   - `target.tier=community`
   - `target.protocol=h1|h2`
   - `comparison_axis=within-tier`
4. Keep flamegraph HTML/JSON as exploratory artifacts, not canonical baseline metrics.

## Command

Use runner script:

```bash
./scripts/run-community-e2e.sh --protocol h1 --probe k6
./scripts/run-community-e2e.sh --protocol h2 --probe k6
./scripts/run-community-e2e.sh --protocol h1 --probe h2load
```

## Note

This integration is native: scenarios and runtime drivers already live in canonical paths.
