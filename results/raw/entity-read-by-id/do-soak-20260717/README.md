# entity-read-by-id — 24h mixed-traffic soak (DigitalOcean, exploratory)

**Classification: EXPLORATORY. NOT comparison-eligible. NOT a baseline.**

| Field | Value |
|---|---|
| Scenario | entity-read-by-id (k6 mixed traffic: 90% users read hot/cold, 5% db-ping, 5% health) |
| Driver | k6 (constant-arrival-rate) — **not** the wrk-defined comparison contract for this scenario |
| Hardware profile | `cloud-vm-do-shared` (shared vCPU — steal time possible, unmeasurable in advance) |
| Topology | split: target on `exeris-bench-target`, k6 on `exeris-bench-loadgen`, over the DO VPC private subnet (`private-net-h1`) |
| Target | exeris-community-app, kernel 0.10.0, `taskset 0-2`, `-Xms1g -Xmx1g` |
| Window | 2026-07-17 07:03 UTC → +24h (warmup 2m + measurement 24h + cooldown 1m) |
| Rate | 300 iters/s (~22% of the ~1126 rps wrk saturation probe — sub-saturation, drift-detection) |

## What this run answers (and what it does NOT)

This was a **stability / drift** test: does the runtime degrade or leak over a
full day of continuous mixed traffic? It is **not** a capacity or latency-baseline
measurement — shared vCPU + k6 driver + sub-saturation rate all disqualify it from
comparison-eligibility. Use only for descriptive within-run trends.

## Headline (from `SUMMARY.txt` / `k6-summary.json`)

- **25,973,957 iterations, 0 interrupted, 0 errors** (100% checks succeeded), 300.00 iters/s held flat for 24h.
- `http_req_duration`: med 3.70 ms, p90 5.37 ms, p95 6.38 ms, p99 10.93 ms, max 276.9 ms.
- `users_read` hot vs cold: statistically identical (both avg 4.16 ms, p99 ~11.24 ms) — the seeded 1000-entity working set is small enough to be fully resident, so the hot/cold split does not separate here. A larger id-space would be needed to exercise a real cache-miss path.
- Target RSS flat at ~852 MB (1 GB heap cap) across the full 24h; G1 pauses max ~33 ms, no drift → **no leak, no degradation**.

Raw 5.2 GB gzipped k6 point stream (`k6-*.json.gz`) retained on the loadgen droplet
only (not committed — see `.gitignore`); the aggregates here carry the signal.
