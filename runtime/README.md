# Runtime Layer

The runtime layer provides execution harnesses for runtime-scale benchmark scenarios
(see [docs/scenario-catalog.md](../docs/scenario-catalog.md)).

## Organization

| Directory | Purpose |
|---|---|
| `drivers/` | Load testing and harness executors (wrk, h2load, k6, Hyperfoil, custom probes) |
| `launchers/` | Target startup and orchestration scripts (community stack launcher, Docker startup) |
| `compose/` | Docker Compose configurations and container setup |
| `env/` | Environment configuration files and templates |

## What is measured here

Runtime scenarios measure **full server under realistic HTTP load**:
- Request/response throughput (req/s)
- Latency under load (p50, p90, p99, p999)
- Connection lifecycle stress
- Protocol modes (H1, H2, H3)
- Concurrent connection count and keep-alive behavior

See [docs/methodology.md](../docs/methodology.md#http-load-benchmarks) for standard configurations.

## How to run a scenario

1. Start target: `./launchers/community-stack-launcher.sh`
2. Choose driver: wrk, h2load, k6, or Hyperfoil (see `drivers/`)
3. Load scenario config from `../scenarios/<name>/`
4. Execute via driver script
5. Results captured to `../results/raw/<scenario>/<timestamp>/`

## Scenario-to-driver mapping

| Scenario | Recommended Driver | Script |
|---|---|---|
| plaintext, json-* | wrk | `drivers/community/run-wrk.sh` |
| keepalive-steady | wrk2 | `drivers/community/run-wrk2.sh` |
| http/2 protocol | h2load | `drivers/community/run-h2load.sh` |
| scripted flows | k6 | `drivers/community/run-k6.sh` |
| session/fixed-rate | Hyperfoil | `drivers/community/run-hyperfoil.sh` *(Phase 6)* |
