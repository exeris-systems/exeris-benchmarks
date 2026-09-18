# e2e-shop-order-saga

**Scenario ID:** `e2e-shop-order-saga`  
**Endpoint(s):** POST /api/v1/auth/register, GET /api/v1/products/recommended, POST /api/v1/cart/add, GET /api/v1/cart, POST /api/v1/orders  
**Mode:** `stateful-e2e-saga`  
**Tier:** Community (first)  
**Driver:** k6  
**Transport:** H2C (HTTP/2 Cleartext)

---

> ## ⚠️ CONTRACT v2.0 — read `CONTRACT-v2.md` first
>
> The **authoritative** specification for this scenario is
> [`CONTRACT-v2.md`](./CONTRACT-v2.md) (v2.0, status *DRAFT — pending
> claims-audit*). v2.0 **supersedes v1** with breaking changes: deterministic
> per-`orderId` terminal payment decline (`stableHash64` pinned to FNV-1a
> 64-bit, `mod 1000 < 30` = **exactly 3.0 %**), separated
> `fault=terminal|transient` classes, a pinned retry policy (terminal = 0
> retries; transient = max 3, 50 ms × 2, no jitter), an exact compensation
> oracle, latency reported **separately** for `COMPLETED` vs `COMPENSATED`
> populations, whole-deployment Σ RSS / ops·s⁻¹·core⁻¹ / setup-time, and a
> per-run **durability-tier** declaration (T1/T2) with **cross-tier
> comparison forbidden** (§8).
>
> **What is actually enforced right now** is tracked section-by-section in
> [`CONTRACT-v2-IMPLEMENTATION.md`](./CONTRACT-v2-IMPLEMENTATION.md)
> (`implemented-now` / `partial` / `deferred`). No claim may rely on a
> `partial` or `deferred` row without its caveat. The prose below this banner
> is **v1-era carry-over**, kept for the workload/seed/step detail it still
> describes correctly; **on any conflict, `CONTRACT-v2.md` wins.**

## Purpose

This scenario measures an end-to-end e-commerce order **saga** across runtimes
whose saga substrate is the axis under test:

- **Exeris Community** — native **Flow** (L4 saga) + Events (L3 transactional
  outbox). Postgres domain datastore, Neo4j read-side recommendation graph.
  *comparison-eligible.*
- **Quarkus 3 + Axon Framework** — Axon saga substrate; identical Postgres
  domain writes, Neo4j Bolt read-side. *comparison-eligible.*
- **Spring Boot + Axon Framework** — Axon saga substrate; identical Postgres
  domain writes, Neo4j Bolt read-side. *comparison-eligible.*
- **Spring-on-Exeris (compat)** — Spring MVC hosted on the Exeris runtime, saga
  via `exeris-spring-runtime-flow` (the same Flow engine as Exeris Community). A
  **separate category** from pure Spring; H1 facade → protocol-mismatch,
  *exploratory only.*
- **Restate** (server + JVM SDK) — the 4th `CONTRACT-v2` stack. Present and
  live-verified as a **baseline-only** target; **NOT comparison-eligible** (no
  `scenario.json` fixed_contract / manifest row; H1 facade). See the Restate
  note below.

**Flow-vs-Axon is the axis under test** — Axon remains the first-class saga
substrate for the pure Spring and Quarkus stacks and was never withdrawn from
the benchmark.

**Workload:** Realistic e-commerce workflow with a payment pivot, multi-step
saga validation, and LIFO compensation paths.

---

## Important Caveats

### LOOPBACK CAVEAT
This scenario runs client and server on the same host (`transport_mode=loopback-h2c`).
Loopback results are **NOT equivalent** to network-path measurements.
All result artifacts **MUST** carry `transport_mode=loopback-h2c`.
Do NOT compare loopback results to network-path results without explicit caveats.

### GRAPH BACKEND DEPENDENCY
This scenario requires an operational Neo4j instance for product recommendations.
Ensure Neo4j is initialized and seeded before benchmark execution.
All three targets use identical Neo4j Bolt driver (Community tier).

### SAGA COMPLEXITY
Multi-step saga orchestration adds distributed state machine overhead.
Success is measured not only by throughput but also by saga completion rate and compensation invocation.

---

## Claim Scope

| Scope | VUs | Duration | Required Profile | Allowed Claims | Risk |
|---|---|---|---|---|---|
| `exploratory` | 100 | 60s warmup only | dev-laptop, ci-runner | descriptive; RPS trends | HIGH |
| `comparison-eligible` | 100 | 180s measurement | **perf-box-amd64** | throughput, p50, saga success rate | MEDIUM |
| `saga-complete` | 100 | 180s + 60s compensation polling | **perf-box-amd64** | P99, compensation rates, full state machine | LOW |

---

## Seed Requirement

### PostgreSQL User-Provided Schema
| Table | Rows | Purpose |
|---|---|---|
| users | 1000 | User account data for registration |
| products | 500 | Product catalog with price and category |
| inventory | 500 | Stock levels per product |
| product_relationships | >1000 | Product similarity edges for recommendations |
| user_purchase_history | >1000 | Past user purchases for recommendation engine |

### Schema Specification

**users**
```sql
CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  username VARCHAR(255) UNIQUE NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
)
```

**products**
```sql
CREATE TABLE products (
  id BIGSERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  price DECIMAL(10, 2) NOT NULL,
  category VARCHAR(100) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
)
```

**inventory**
```sql
CREATE TABLE inventory (
  product_id BIGINT PRIMARY KEY REFERENCES products(id),
  quantity_available INT NOT NULL,
  reserved INT NOT NULL DEFAULT 0
)
```

**product_relationships**
```sql
CREATE TABLE product_relationships (
  source_product_id BIGINT NOT NULL REFERENCES products(id),
  target_product_id BIGINT NOT NULL REFERENCES products(id),
  similarity_score DECIMAL(3, 2) NOT NULL,
  PRIMARY KEY (source_product_id, target_product_id)
)
```

**user_purchase_history**
```sql
CREATE TABLE user_purchase_history (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  product_id BIGINT NOT NULL REFERENCES products(id),
  purchased_at TIMESTAMP NOT NULL
)
```

### Neo4j Graph Schema
| Component | Count | Properties |
|---|---|---|
| Product nodes | 500 | id, name, price, category |
| SIMILAR_TO edges | >1000 | similarity_score |
| PURCHASED_BY edges | >1000 | purchase_date |

### Pre-run Verification (MANDATORY)
Results produced without a passing `verify-seed.sh` exit 0 are INVALID.

```bash
bash scenarios/e2e-shop-order-saga/seed/verify-seed.sh
```

---

## Workflow Steps

Each virtual user executes this multi-step journey:

### Step 1: Register
```
POST /api/v1/auth/register
{
  "username": "user_{VU_ID}_{TIMESTAMP}",
  "email": "user_{VU_ID}@shop.local",
  "password": "BenchPass123!"
}
→ 201 Created, returns JWT token
```

### Step 2: Think time
Random sleep: 800–2500 ms (user pacing simulation)

### Step 3: Get Recommendations (Graph Traversal)
```
GET /api/v1/products/recommended?limit=10
(Uses Graph to traverse: User → PurchaseHistory → Product → SIMILAR_TO → Recommendations)
→ 200 OK, returns [Product, Product, ...]
```

### Step 4: Think time
Random sleep: 800–2500 ms

### Step 5: Add to Cart (Graph Edge Creation)
```
POST /api/v1/cart/add
{
  "product_id": <random from recommendations>,
  "quantity": 1
}
→ 201 Created, cart edge created in Graph
```

### Step 6: Think time
Random sleep: 800–2500 ms

### Step 7: Retrieve Cart (Graph Traversal)
```
GET /api/v1/cart
(Traverses: User → CART_FOR → CartItems → HAS_PRODUCT → Product names/prices)
→ 200 OK, returns cart contents
```

### Step 8: Think time
Random sleep: 800–2500 ms

### Step 9: Place Order (Triggers Saga)
```
POST /api/v1/orders
{
  "cart_id": <from step 7>,
  "payment_method": "CARD"
}
→ 202 Accepted, returns { order_id, saga_id, status: "SAGA_INITIATED" }
```

### Step 10: Poll Saga Status (Compensation Tracking)
```
GET /api/v1/orders/{order_id}/status
(Poll up to 10 seconds for saga completion)

Expected final states:
  - COMPLETED (happy path)
  - COMPENSATED (payment failed, inventory rolled back)
  - FAILED (unrecoverable error)

Saga steps internally:
  1. RESERVE_INVENTORY (Graph edge + Persistence write)
  2. CHARGE_PAYMENT (Events → Outbox → External Provider; compensates on failure)
  3. CONFIRM_ORDER (Events publication)
  4. SEND_CONFIRMATION_EMAIL (async Events)
```

---

## Cross-Runtime Support

| Target | Saga Framework | Graph Backend | Event Backend | Status |
|---|---|---|---|---|
| Exeris Community | Flow (L4 native) | Graph (L2 native) | Events (L3 with transactional outbox) | ✅ Ready |
| Quarkus | Axon Framework | Neo4j Bolt | Outbox Pattern + Kafka | ✅ Ready (requires Axon setup) |
| Spring Boot | Axon Framework — **embedded handler path** | Neo4j Bolt | EventBus (SubscribingEventProcessor, embedded) | ✅ Ready — see pre-flight note below |
| Restate (`--target-app restate`) | Restate durable execution (JVM SDK 2.9, journaled `Restate.run` steps + LIFO compensations) | Neo4j Bolt (or PGQ track) | restate-server journal (replicated loglet) + transactional outbox rows | ✅ Ready — baseline-only, see note below |

### Restate Target — Deployment-Unit and Protocol Note

Target app: `targets/restate-benchmark-app` (facade port **9004**, HTTP/1.1).
The deployment unit is the target JVM **plus** an external `restate-server`
v1.7 (compose service `benchmark-restate-server`: ingress :8080, admin :9070),
started by `run-e2e-shop-order-saga-baseline.sh` only for restate runs — the
same gating pattern as Axon Server for the Spring/Quarkus targets. The
baseline polls the admin API for readiness and force-registers the SDK
deployment post-readiness. `restate-server` CPU/RSS is a separate container,
sampled to `logs/restate-server-docker-stats.csv` (not in
`resource-metrics.json`).

Caveats for any claim:
- **h1 facade** vs h2c canonical contracts → protocol-mismatch strict-gate
  disqualifier (same class as spring-on-exeris); baseline/descriptive runs only
  until an h1-scoped or protocol-matched comparison is defined.
- v2 request-response model: `POST /api/v1/orders` returns the **terminal**
  saga outcome in the 200 body, so k6 skips status polling; the poll endpoint
  is an in-memory sticky-terminal projection (`status_poll_comparison_excluded`).
- Durability tier: restate-server default = fsync node-durable (T2, RocksDB WAL
  fsync per commit batch). Declare the tier per run; cross-tier comparisons are
  forbidden (CONTRACT-v2 §8).
- Not yet wired as a `scenario.json` fixed contract / comparative-pair-manifest
  row — the campaign runner cannot derive a restate contract id; invoke the
  baseline directly with `--target-app restate`.

### Spring Boot Target — Embedded Handler Path (Pre-flight Note)

The Spring Boot target uses `AxonOrderSagaCommandHandler` (EventBus-direct) and does **NOT** require Axon Server.

| Check | Expected value |
|---|---|
| `axon.axonserver.enabled` | `false` (set in `application.properties`) |
| `exeris.axon.mode` | `event-sourcing-outbox` (NOT `axon-server-dispatch`) |
| Axon Server at `localhost:8124` | **unreachable / disabled** |
| Spring app JAR build commit | **post-fix commit only** — pre-fix JAR measured error path (AxonServerException + HTTP 500); all data from pre-fix JAR must be discarded |

Required metadata to capture at benchmark start:
- `exeris.axon.mode` from running Spring app
- `axon.axonserver.enabled` from running Spring app
- Axon Server health gate at `localhost:8124` (confirm unreachable)
- Spring app JAR build commit SHA
- Hardware profile + JDK version (Spring Boot 4.0.4 / Java 26)
- k6 script version / commit SHA

---

## Fairness Constraints

**Protocol Equivalence:** All targets use HTTP/2 Cleartext (no TLS cost)  
**Payload Equivalence:** Identical JSON order schema across all targets  
**Concurrency:** 100 VUs, identical think-time pattern  
**Database/Graph Backend:** identical within each declared backend track (Track A: PostgreSQL + Neo4j, Track B: PostgreSQL + PGQ).  
**Known Differences (acceptable):**
- Exeris: Flow orchestration is kernel-built; zero additional framework overhead
- Quarkus/Spring: saga behavior is provided through Axon Framework. The cost of Axon, event dispatching, saga state management, and related operational machinery is treated as part of the workflow stack cost for this scenario. No fixed overhead percentage is assumed.
- Graph: All use Neo4j Bolt (Community driver with heap allocation tax)

Cross-track backend mixing (Neo4j vs PGQ) is non-equivalent by definition and allowed only for stack-level descriptive reporting with explicit caveats.

## Graph Backend Comparison Guardrail

In this scenario, graph_backend_family is a hard segmentation key.
Mixed-backend comparisons are stack-level only, not backend-engine ranking.
Claim scope: within-tier, within-protocol, scenario-bound, stack-level comparison only; backend superiority is out of scope unless backend-isolated A/B evidence is provided.

Forbidden wording:
- "Neo4j is faster than PG graph/PGQ."
- "PG graph/PGQ is slower than Neo4j."
- "Unqualified '% faster' backend claims across mixed backend families."

Allowed wording examples:
- "For e2e-shop-order-saga (community, h2c, loopback), stack A measured X and stack B measured Y."
- "Observed delta is descriptive for mixed backend families and includes integration overhead."

### Apache AGE Compatibility Path

- Quarkus/Spring may use Apache AGE as compatibility path on PostgreSQL.
- AGE (openCypher extension) and PGQ (native SQL graph query model) are NOT equivalent for engine-level performance claims.
- AGE results are compatibility-scope unless all targets run the same AGE track and claims stay within that track.
- AGE-to-PGQ deltas are mode-comparison only and MUST NOT be presented as pure backend superiority claims.

- Forbidden: "Apache AGE proves PGQ is slower/faster."
- Allowed: "Within age_compat track under identical workload/protocol, stack A measured X and stack B measured Y."

---

## Measurement & Compensation Windows

| Phase | Duration | Measured | Purpose |
|---|---|---|---|
| Ramp-up | 60s | NO | Reach steady state |
| Warmup | 60s | NO | JIT warm, GC stabilization |
| Measurement | 180s | YES | Collect throughput, latency, saga metrics |
| Ramp-down | 30s | NO | Graceful shutdown |
| (Post) Compensation polling | 60s | YES | Verify final saga states |

**Compensation Rate Definition:**
```
Compensation Rate = (Orders with final state COMPENSATED) / (Total Orders)
Expected: < 5% (realistic payment decline + inventory shortage rate)
Threshold: > 10% indicates unhealthy saga execution
```

---

### Saga machinery cost note

No fixed Axon overhead percentage is assumed.

Earlier planning notes treated saga-framework overhead as a small constant. Actual
measurements show that the cost is scenario-dependent and includes more than the
framework call overhead alone.

For Quarkus/Spring targets, the measured stack cost includes:
- Axon saga state management
- command/event dispatch
- handler execution path
- persistence/outbox interaction
- status resolution behavior
- operational footprint required to provide comparable saga semantics

Therefore, results from this scenario should describe the observed
workflow-stack cost, not a generic Axon overhead percentage.

---

## Example Fairness Gate

```json
"fairness_gates": {
  "min_completed_orders": 900,           // ~180 sec × 100 VUs at ~5–6 orders/user/min
  "error_rate_max": 0.02,                // <2% HTTP errors
  "saga_success_rate_min": 0.98,         // >98% reach COMPLETED state
  "compensation_invocation_rate_max": 0.05  // <5% COMPENSATED
}
```

If any gate is violated, the benchmark is considered **FAILED** and requires investigation.
