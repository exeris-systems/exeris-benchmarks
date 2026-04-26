# Scenarios

Benchmark scenarios define workload characteristics (path, payload, concurrency model).
Each scenario is framework-agnostic: it can be executed via wrk, h2load, k6, or Hyperfoil.

## Adding a scenario

1. Create `scenarios/<name>/` directory
2. Add `README.md` with:
   - Path, method, payload description
   - Expected response (status, body pattern)
   - Purpose and use case
3. Add scenario configs per driver:
   - `wrk.lua` + `wrk.env` for wrk
   - `k6.js` for k6
   - `h2load.flags` for h2load
   - `hyperfoil.yaml` for Hyperfoil
4. Update [docs/scenario-catalog.md](../docs/scenario-catalog.md)

## Existing Scenarios

See [docs/scenario-catalog.md](../docs/scenario-catalog.md) for full list and semantics.
