# Runtime Layer

The runtime layer provides execution harnesses for runtime-scale benchmark scenarios
(see [docs/scenario-catalog.md](../docs/scenario-catalog.md)).

## Organization

| Directory | Purpose |
|---|---|
| `drivers/` | Load testing and harness executors (wrk, h2load, k6, Hyperfoil, custom probes) |
| `compose/` | Docker Compose configurations and container setup |
| `env/` | Environment configuration files and templates |
| `profiles/` | Runtime execution profile matrix and presets |

## What is measured here

Runtime scenarios measure **full server under realistic HTTP load**:
- Request/response throughput (req/s)
- Latency under load (p50, p90, p99, p999)
- Connection lifecycle stress
- Protocol modes (H1, H2)
- Concurrent connection count and keep-alive behavior

See [docs/methodology.md](../docs/methodology.md#http-load-benchmarks) for standard configurations.

## How to run a scenario

1. Start target: `./runtime/drivers/community-stack-launcher.sh`
2. Choose driver/tool: wrk, h2load, k6, or Hyperfoil (see `drivers/` + root `scripts/`)
3. Load scenario config from `../scenarios/<name>/`
4. Execute via driver script
5. Results captured to `../results/raw/<scenario>/<timestamp>/`

## Scenario-to-driver mapping

| Scenario | Recommended Driver | Script |
|---|---|---|
| health-probe (H1) | h2load | `runtime/drivers/h2load-health-h1.sh` |
| scripted flows | k6 | `scripts/run-scenario.sh` |
| comparative/campaign flows | mixed | `scripts/run-comparative.sh`, `scripts/run-entity-read-by-id-campaign.sh` |
