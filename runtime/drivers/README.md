# Drivers

Load testing harnesses and their corresponding scenario executors.

## Driver Overview

| Driver | Protocol | Use Case | Concurrency | Latency Metrics |
|---|---|---|---|---|
| wrk | HTTP/1.1 | Simple throughput baseline | threads + connections | p50, p99, max |
| wrk2 | HTTP/1.1 | Steady-rate load (constant RPS) | threads + connections | p50, p99, max |
| h2load | HTTP/2 | Multiplexed protocol testing | clients + max streams | p50, p90, p99, p999 |
| k6 | HTTP/1.1, HTTP/2 | Scripted scenarios, CI smoke tests | concurrent users, VUs | p50, p90, p99, p999 |
| Hyperfoil | HTTP/1.1, HTTP/2 | Session-aware fixed-rate studies | sessions, throughput control | full histogram *(Phase 6)* |

## Running a driver

Driver entrypoints are top-level scripts in this directory (no `community/` or `enterprise/` subtrees).

### wrk
```bash
./scripts/run-wrk.sh targets/exeris-community-app scenarios/plaintext
```

### h2load
```bash
./runtime/drivers/h2load-health-h1.sh
```

### k6
```bash
./scripts/run-scenario.sh --scenario json-1kb
```

### Hyperfoil (Phase 6)
```bash
./scripts/run-scenario.sh --scenario plaintext --tool hyperfoil
```

## Adding a new driver

1. Create a top-level driver script under `runtime/drivers/`.
2. Add `run-<driver>.sh` entrypoint script
3. Document command-line interface
4. Register scenario mapping in this README
5. Add to [docs/methodology.md](../../docs/methodology.md) if it's a standard tool
