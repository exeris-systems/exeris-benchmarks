# Drivers

Load testing harnesses and their corresponding scenario executors.

## Driver Overview

| Driver | Protocol | Use Case | Concurrency | Latency Metrics |
|---|---|---|---|---|
| wrk | HTTP/1.1 | Simple throughput baseline | threads + connections | p50, p99, max |
| wrk2 | HTTP/1.1 | Steady-rate load (constant RPS) | threads + connections | p50, p99, max |
| h2load | HTTP/2, HTTP/3 | Multiplexed protocol testing | clients + max streams | p50, p90, p99, p999 |
| k6 | HTTP/1.1, HTTP/2 | Scripted scenarios, CI smoke tests | concurrent users, VUs | p50, p90, p99, p999 |
| Hyperfoil | HTTP/1.1, HTTP/2, HTTP/3 | Session-aware fixed-rate studies | sessions, throughput control | full histogram *(Phase 6)* |

## Running a driver

Each driver has a corresponding script under `community/` or `enterprise/`:

### wrk
```bash
./drivers/community/run-wrk.sh --scenario plaintext --concurrency 100 --duration 30s
```

### h2load
```bash
./drivers/community/run-h2load.sh --scenario plaintext --clients 100 --streams 10
```

### k6
```bash
./drivers/community/run-k6.sh --scenario json-1kb --vus 50 --duration 60s
```

### Hyperfoil (Phase 6)
```bash
./drivers/community/run-hyperfoil.sh --scenario plaintext --fixed-rate 10000 --duration 60s
```

## Adding a new driver

1. Create `drivers/community/<driver-name>/` or `drivers/enterprise/<driver-name>/`
2. Add `run-<driver>.sh` entrypoint script
3. Document command-line interface
4. Register scenario mapping in this README
5. Add to [docs/methodology.md](../../docs/methodology.md) if it's a standard tool
