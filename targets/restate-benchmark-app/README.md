# Restate Benchmark App

Standalone Restate (JVM SDK) benchmark target implementing the
`e2e-shop-order-saga` CONTRACT-v2 (`scenarios/e2e-shop-order-saga/CONTRACT-v2.md`).

Deployment unit (CONTRACT-v2 §1): **this service JVM + `restate-server`**
(single binary or Docker). This one JVM hosts both:

- the k6-facing HTTP facade (HTTP/1.1, JDK `com.sun.net.httpserver` on virtual
  threads) on `EXERIS_PORT` (default **9004** — next free slot in the 9000-series
  target block), and
- the Restate SDK service endpoint (`OrderSaga`) on `RESTATE_SDK_PORT`
  (default **9084**), which `restate-server` invokes.

`POST /api/v1/orders` submits `OrderSaga/run` to the restate-server ingress
(`POST {RESTATE_INGRESS_URL}/restate/call/OrderSaga/run`) with the
client-generated orderId as the `idempotency-key` header (CONTRACT-v2 §3) and
**returns the terminal saga outcome in the 200 response body**
(`status` ∈ `COMPLETED | COMPENSATED | FAILED_UNRECOVERED`). This is the v2
request-response model — k6 (`extractTerminalStatus`) sees a terminal status
and skips polling entirely. `GET /api/v1/orders/{orderId}/status` is still
served (in-memory sticky-terminal projection, same class of read path as the
Axon stacks' `AxonOrderSagaProjection`; `status_poll_comparison_excluded`).

## Build

```bash
mvn -q -DskipTests package
```

Requires JDK >= 17 (JDK 26 used by this repo; the Restate SDK recommends
JDK >= 23 and wants `--enable-native-access=ALL-UNNAMED` there).

## Run

1. Start `restate-server` v1.7.x (pick one):

```bash
# single binary
restate-server

# docker (remap ingress off 8080 if the port is taken locally)
docker run --name restate_dev --rm \
  -p 8080:8080 -p 9070:9070 -p 9071:9071 \
  --add-host=host.docker.internal:host-gateway \
  docker.restate.dev/restatedev/restate:1.7.2
```

2. Start the app (it self-registers its SDK endpoint against the admin API):

```bash
EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/postgres?prepareThreshold=1' \
EXERIS_DB_USERNAME=postgres \
EXERIS_DB_PASSWORD=postgres \
EXERIS_PORT=9004 \
java --enable-native-access=ALL-UNNAMED -jar target/restate-benchmark-app-1.0.0-SNAPSHOT.jar
```

When restate-server runs in Docker, the server must reach the SDK endpoint on
the host — set `RESTATE_SDK_ADVERTISED_URL=http://host.docker.internal:9084`.

Manual registration (if `RESTATE_AUTO_REGISTER=false`):

```bash
restate deployments register http://localhost:9084
# or: curl localhost:9070/deployments --json '{"uri":"http://localhost:9084","force":true}'
```

## Environment Variables

- `EXERIS_PORT` facade HTTP port, default `9004`.
- `EXERIS_DB_JDBC_URL` / `EXERIS_DB_USERNAME` / `EXERIS_DB_PASSWORD` Postgres
  connection (defaults: local `postgres/postgres`).
- `EXERIS_DB_POOL_MIN_SIZE` / `EXERIS_DB_POOL_MAX_SIZE` Hikari pool bounds,
  defaults `16` / `256`.
- `RESTATE_SDK_PORT` Restate SDK endpoint port, default `9084` (the +10000
  h2-offset convention reserves 19004 for the facade; 9084 stays clear of it).
- `RESTATE_INGRESS_URL` restate-server ingress, default `http://localhost:8080`.
- `RESTATE_ADMIN_URL` restate-server admin API, default `http://localhost:9070`.
- `RESTATE_SDK_ADVERTISED_URL` URL the *server* uses to call the SDK endpoint,
  default `http://localhost:{RESTATE_SDK_PORT}`.
- `RESTATE_AUTO_REGISTER` default `true`: POST the deployment to the admin API
  at startup (force=true, retried in the background; non-fatal on failure).
- `EXERIS_GRAPH_BACKEND_TYPE` graph backend selector: `pgq` (default, SQL
  against `in_cart_edges`/`bought_edges`/`similar_to_edges`) or `neo4j`.
- `EXERIS_GRAPH_NEO4J_URI` / `EXERIS_GRAPH_NEO4J_USER` /
  `EXERIS_GRAPH_NEO4J_PASSWORD` Neo4j Bolt connection when backend is `neo4j`.
- `EXERIS_SAGA_FAULT_MODE` `terminal` (default) applies the CONTRACT-v2 §4.1
  deterministic payment decline — FNV-1a 64 over the UTF-8 bytes of the
  orderId, declined when `Long.remainderUnsigned(hash, 1000) < 30` (exactly
  3.0% of a deterministic orderId population); `off` disables business-fault
  injection.
- `EXERIS_SAGA_PAYMENT_FAIL_RATE` / `EXERIS_SAGA_FAILURE_MODE` — v1
  probabilistic knobs, IGNORED since CONTRACT-v2 (a WARN is logged when set).
- `EXERIS_SAGA_RETRY_MAX_ATTEMPTS` / `EXERIS_SAGA_RETRY_INITIAL_BACKOFF_MS` /
  `EXERIS_SAGA_RETRY_BACKOFF_FACTOR` CONTRACT-v2 §5 transient retry knobs,
  defaults `3` / `50` / `2`.
- `EXERIS_SAGA_RETRY_JITTER` accepted but warn-and-ignored: Restate backoff is
  deterministic exponential with no jitter knob, which is the §5 requirement.
- `EXERIS_AUTH_TOKEN_SECRET` optional HMAC secret for the bearer tokens
  (random per process start when unset).

## Retry policy (CONTRACT-v2 §5)

Pinned at two layers, defaults not trusted:

- **Per step**: every forward step and every compensation runs inside a
  journaled `Restate.run` block with
  `RetryPolicy.exponential(50ms, 2).setMaxAttempts(3)`.
- **Per invocation**: the service is bound with an SDK-declared invocation
  retry policy (`initialInterval=50ms, exponentiationFactor=2, maxAttempts=3,
  onMaxAttempts=KILL`), overriding the server default (`max-attempts=70`,
  `on-max-attempts=pause`).

**Zero retries on decline**: the §4.1 decline is thrown as a
`TerminalException`, which Restate never retries at either layer — it
propagates straight to the saga handler's catch block, which runs the
compensation list in reverse (LIFO: `refund-payment`, then
`restore-inventory`), each inside `Restate.run`. Compensation retry-budget
exhaustion terminates the saga `FAILED_UNRECOVERED` (§7 O3).

## Saga steps and domain writes

Postgres writes are SQL-shape-identical to the reference Axon stacks
(spring-benchmark-app): `create-order` (orders + order_items) →
`reserve-inventory` (+compensation `restore-inventory`) → `charge-payment`
(pivot: outbox `PAYMENT_REQUESTED` + `PAYMENT_PROCESSING`, then the §4.1
decline check; compensation `refund-payment` = `PAYMENT_REFUNDED` + outbox
`ORDER_COMPENSATED`) → `confirm-order` (`CONFIRMED` + outbox
`ORDER_CONFIRMED`) → `complete-order` (`COMPLETED`).

## Durability tier (CONTRACT-v2 §8)

Out of the box, restate-server v1.7 runs the replicated loglet (even
single-node) with **RocksDB WAL fsync per commit batch ON**
(`log-server.rocksdb-disable-wal-fsync=false`) — declare such runs
**T2 (fsync node-durable)**, comparable with a Postgres-backed saga at
`synchronous_commit=on`. For a T1 (process-durable) run set
`RESTATE_LOG_SERVER__ROCKSDB_DISABLE_WAL_FSYNC=true` on the *server* and label
the run accordingly. Cross-tier comparisons are forbidden (§8).

## Endpoints

- `GET /health`
- `POST /api/v1/auth/register` (no Bearer token required)
- `GET /api/v1/products/recommended?limit=10` (Bearer)
- `POST /api/v1/cart/add` (Bearer)
- `GET /api/v1/cart` (Bearer)
- `POST /api/v1/orders` (Bearer; `Idempotency-Key` request header is accepted;
  the body `order_id` drives the §4.1 decline oracle) → `200` with terminal
  `{order_id, status, saga_id}`
- `GET /api/v1/orders/{orderId}/status` (Bearer) → `200` or `404`

## Tests

```bash
mvn test
```

Covers the CONTRACT-v2 §4.1 FNV-1a canonical vectors + decline threshold
(mirrors spring-benchmark-app `PaymentDeclineRuleTest`, including the k6
population oracle `exeris-saga-v2-measurement-i0..9999 → 312 declines`),
§5 retry-policy pinning, `EXERIS_SAGA_FAULT_MODE` parsing, the sticky-terminal
status projection, and bearer-token round-trips.

## Deviation register notes (CONTRACT-v2 §9)

- Compensations are a user-space pattern (sagas guide: compensation list +
  `TerminalException` + LIFO unwind in the handler), not a framework-level
  unwind — satisfies G2; the difference is a finding, not a violation.
- Administrative termination (§6 G3 asterisk): restate-server exposes
  `restate invocations cancel` (compensating cancellation) and `kill`
  (no compensation). Neither is exercised in benchmark runs.
- `EXERIS_SAGA_RETRY_JITTER` cannot be honored (no jitter knob); Restate's
  deterministic exponential backoff matches the §5 no-jitter requirement.
- Like the Axon stacks, the client `order_id` is echoed on the wire while the
  DB row is keyed by a separate BIGSERIAL id (fairness hazard already
  documented for the reference stacks).
- Saga domain writes go to Postgres (identical to every implemented stack),
  not Neo4j — same §2 carve-out as the reference stacks.
