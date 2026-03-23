# entity-read-by-id

**Scenario ID:** `entity-read-by-id`  
**Endpoint:** `GET /api/v1/entities/{id}`  
**Mode:** `baseline-db`  
**Tier:** Community (first)  
**Driver:** wrk  
**Transport:** H1

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario runs client and server on the same host (`transport_mode=loopback-h1`).
> Loopback results are **not equivalent** to network-path measurements.
> All result artifacts **must** carry `transport_mode=loopback-h1`.
> Do not compare loopback results to network-path results without explicit caveats.

---

## Claim scope

| Scope | Min duration | Required profile | Allowed claims | CO risk |
|---|---|---|---|---|
| `exploratory` | 30 s | dev-isolated, dev-laptop, ci-runner | descriptive only | yes |
| `comparison-eligible` | 60 s | **perf-box-amd64** | throughput, p50 (indicative) | yes |
| `p99-stable` | 120 s | **perf-box-amd64** | P99 (wrk2 only) | yes |

> **wrk is INELIGIBLE for `p99-stable`.** P99 requires `wrk2` on `perf-box-amd64`.  
> No P99 claims from wrk output at any scope level.

---

## Seed requirement

The scenario requires a PostgreSQL database seeded with 1000 entity rows before each run.

| Field | Value |
|---|---|
| DB image | `postgres:16.2` |
| Schema migration | V1 |
| Entity count | 1000 |
| ID range | 1–1000 |
| Idempotency | `INSERT ... ON CONFLICT (id) DO UPDATE` |
| Seed file | `scenarios/entity-read-by-id/seed/entities.sql` |
| Manifest | `scenarios/entity-read-by-id/seed/seed-manifest.json` |

**Pre-run verification is mandatory.** Results produced without a passing `verify-seed.sh` exit 0 are invalid.

```bash
PGPASSWORD=benchmark bash scenarios/entity-read-by-id/seed/verify-seed.sh
```

---

## Cross-tier status

**Deferred.** Cross-tier comparison (Community vs Enterprise) is not active for this scenario.
Equivalence constraints are captured in `scenario.json#cross_tier_equivalence_constraints`
to prevent schema drift. Required fields for future eligibility: db_backend, db_image,
connection_pool_size, protocol, seed_manifest_version, transport, concurrency.

---

## Quick start (exploratory)

```bash
# 1. Start the database
docker compose -f runtime/compose/entity-read-by-id-db.yml up -d

# 2. Apply seed
PGPASSWORD=benchmark psql -h localhost -p 5432 -U benchmark -d benchmark_db \
  -f scenarios/entity-read-by-id/seed/entities.sql

# 3. Verify seed (mandatory)
PGPASSWORD=benchmark bash scenarios/entity-read-by-id/seed/verify-seed.sh

# 4. Start the application under test (e.g. exeris-benchmark-app on port 8080)

# 5. Run the benchmark (exploratory, 30s)
bash scripts/run-entity-read-by-id.sh --claim-scope exploratory --profile dev-laptop
```

Results will be written to `results/raw/entity-read-by-id/<timestamp>/`.

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 32 |
| Threads | 4 |
| Connection pool size | 10 (declared fixed variable) |

> Note: 32 connections may undersaturate the DB connection pool.
> `connection_pool_size` is a declared fixed variable — do not vary without a new scenario version.
