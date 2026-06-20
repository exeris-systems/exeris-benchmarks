# Source artifacts — *When throughput lies* (entity-read-by-id, 2026-06-20)

Reproducibility bundle for [the report](2026-06-20-entity-read-by-id-steady-state-and-cost-per-request.md).
Every run cited in the report ships its **structured** artifacts here so the numbers can be
re-derived independently. All runs: `entity-read-by-id`, `dev-laptop`, JDK 26, kernel `7.0.0-22`
(EEVDF), host-net unless the report says otherwise.

**Claim scope:** `exploratory` · **Reproducibility:** `complete` · **Comparison axis:** within-tier.

## What is included per run (under `results/raw/guided/<timestamp>/`)

| File | Purpose |
|---|---|
| `result.json` | normalized metrics (throughput, latency percentiles, errors) + run config + classification |
| `steady-state-evidence.json` | C2 compiler-queue / compilation overlay used to prove warm |
| `h2load-latency.json` / `wrk2-latency.json` (+ `.raw.txt`) | derived percentiles; wrk2 carries `at_saturation` + `load_fraction` |
| `logs/target-pidstat.csv` | per-thread `%CPU` — the source for **CPU-per-request** |
| `logs/host-mpstat.csv` | host CPU breakdown (`%sys` / `%soft` / `%wait`) — the bridge-tax evidence |
| `env.json`, `reproducibility-metadata.json` | SHA, JDK/tool versions, JVM flags, hardware profile |
| `guided-run-profile.json` | affinity, network mode, warmup/measure, driver options |
| `postgres-version.txt`, `postgres-settings.tsv`, `pg_stat_statements-*.json` | DB-side reproducibility |
| `preflight-users-aggregate.json`, `users-endpoint-query-metadata.txt` | workload / dataset shape |

## What is **excluded**, and why

- **Raw `.jfr` recordings** — kept out of git for **size**, not confidentiality. These are
  Community / open-core recordings (the code is open; no Enterprise H3 / locality content), so
  they are not secret — but each is ~190 MB (~2.2 GB for the set), and git is the wrong place for
  that. The published form is the **derived** interactive flame graphs (`assets/flame-*.svg`);
  the raw recordings are available on request (or as download/release assets). The `.jfr`
  default-deny in `public` mode is the **Enterprise**-track confidentiality rule.
- **`h2load-requests.log`** (per-request `--log-file` dumps, 100+ MB each) and other `*.log` —
  excluded by size/`.gitignore`. The percentiles they feed are already in `h2load-latency.json`.

## Run index

| Timestamp (UTC) | Target | Driver | Key figures (see report) |
|---|---|---|---|
| `20260620T111404Z` | Spring (reference) | h2load | 3 052 rps, CPU/req 0.956 ms |
| `20260620T114151Z` | Exeris (Community) | h2load | 8 844 rps, CPU/req 0.390 ms, C2=0 |
| `20260620T121411Z` | Quarkus | h2load | 7 836 rps, CPU/req 0.552 ms, C2 peak 97 |
| `20260620T123114Z` | Exeris | wrk2 | 75%-own-sat — p50 2.95, p99 8.19 ms |
| `20260620T123720Z` | Quarkus | wrk2 | 75%-own-sat — p50 9.03, p99 14.73 ms |
| `20260620T125344Z` | Exeris | wrk2 | matched 6 000 rps — p50 6.73, p99 18.05 ms |
| `20260620T130014Z` | Quarkus | wrk2 | matched 6 000 rps — p50 6.48, p99 46.78 ms |
| `20260620T134826Z` | Exeris | h2load | firm-up #1 — 9 454 rps, CPU/req 0.359 ms |
| `20260620T140518Z` | Quarkus | h2load | firm-up #1 — 8 158 rps, CPU/req 0.534 ms |
| `20260620T142125Z` | Exeris | h2load | firm-up #2 — 9 296 rps, CPU/req 0.358 ms |
| `20260620T143724Z` | Quarkus | h2load | firm-up #2 — 7 952 rps, CPU/req 0.550 ms |
| `20260620T145345Z` | Exeris | h2load | firm-up #3 — 9 373 rps, CPU/req 0.359 ms |
| `20260620T151001Z` | Quarkus | h2load | firm-up #3 — 8 096 rps, CPU/req 0.539 ms |

The firm-up set (`…134826Z`–`…151001Z`) is interleaved A,B,A,B,A,B, host-net, warmed (C2=0),
target pinned `0-4` / driver `5-9`. Bridge-vs-host (§2) and the warmup progression (§1) draw on
additional earlier runs in the same session under `results/raw/guided/`.

## Reproduce the headline numbers

```bash
# n=3 interleaved means ± CV%  (throughput + CPU-per-request)
tools/aggregate-runs.py results/raw/guided/{20260620T134826Z,20260620T142125Z,20260620T145345Z}   # Exeris
tools/aggregate-runs.py results/raw/guided/{20260620T140518Z,20260620T143724Z,20260620T151001Z}   # Quarkus

# Re-derive flame graphs from a raw .jfr (internal-only artifact)
tools/jfr-flamegraph.py <run>/target-*.jfr out.svg --title "..."

# Re-aggregate h2load percentiles from a raw --log-file (internal-only)
tools/aggregate-h2load-latency.sh <run>/h2load-requests.log
```
