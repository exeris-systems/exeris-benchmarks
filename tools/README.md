# tools/

Utility tools for result processing and reporting.

## benchmark-runner-with-metrics.sh

Helper/process-metrics utility that wraps an existing benchmark command with
`/usr/bin/time -v` and writes `<output_json>.with-metrics.json`.

It is not a primary benchmark runner and does not replace
`tools/bench/run-jmh-case.sh` orchestration.

## result-parser/

Parses raw benchmark tool output (wrk `.txt`, k6 `.json`, h2load stdout) into
the normalized `benchmark-result.schema.json` format.

**Status:** Planned. Implement as a Python script or small Java utility once
result normalization becomes a recurring need.

Planned interface:
```bash
tools/result-parser/parse.py --tool wrk --input results/raw/wrk-20260315.txt \
  --env results/raw/env-20260315.json \
  --scenario plaintext \
  --output results/normalized/wrk-20260315.json
```

## dashboard-export/

Exports normalized result history to formats suitable for dashboards:

- CSV for spreadsheet analysis
- Time-series JSON for Grafana / similar

**Status:** Planned.
