# Spring Benchmark App — Spring-on-Exeris (Compatibility Mode)

Benchmark target for the `e2e-shop-order-saga` workload, hosted on
`exeris-spring-runtime` in **compatibility mode** with the saga driven by
`exeris-spring-runtime-flow`.

This README is the **only documentation surface** for the target. The runtime
swap is in-place (no parallel sibling target was added); the prior shape was
Spring-Boot-on-Tomcat + Axon Framework.

## Track classification

- **Tier**: Community.
- **Track**: benchmark target, not a host-runtime contract surface.
- **Public docs path**: this target is **excluded** from the public docs path
  per the repository's CLAUDE.md confidentiality / Enterprise-vs-public scoping
  rule (alongside `targets/exeris-community-app-locality/`, the `enterprise/`
  tree, and H3 behavior). Reports that surface measurements from this target
  must be tagged Community + Compatibility + H1 — see "Reporting checklist"
  below.

## Runtime modes

| Axis | Value | Source / rationale |
|---|---|---|
| Web mode | `compatibility` | `exeris.runtime.web.mode=compatibility` activates `ExerisCompatAutoConfiguration` (ADR-011). Spring MVC `@RestController` dispatch is overlaid on the Exeris ingress so the existing controller code keeps working. |
| Protocol | **H1 plaintext only** | Phase 1 M1: H1-only. H2 / H3 / TLS are explicitly out of scope. The Tomcat `server.http2.*` / `server.ssl.*` properties from the pre-migration `application.properties` have been removed. |
| Pure-vs-Compat | **Compatibility** | This target measures the cost of running Spring MVC + JPA *on top of* the Exeris ingress. Pure-mode for the same workload would require rewriting controllers to `ExerisRequestHandler`; that is a different target. |
| Saga engine | `exeris-spring-runtime-flow` | The flow definition is `ShopOrderFlowDefinition` (4 forward steps + 2 compensations). Implementation under `application.flow/`. |

## Axon-dropped posture

`org.axonframework:axon-spring-boot-starter` is **removed** from the POM. The
entire `application.axon/` package (~25 files: `OrderAggregate`,
`AxonOrderSagaService`, `AxonOrderSagaProjection`, `AxonOrderSagaCommandHandler`,
the command + event records, `OrderFulfillmentSaga`, `InventoryService`,
`PaymentService`, `OrderCreationService`, `OrderConfirmationService`,
`AxonBusConfig`) has been **deleted**. The SQL bodies are preserved verbatim
inside `ShopOrderSqlSteps` so the workload remains structurally comparable.

The architectural rationale lives in `exeris-spring-runtime` ADR-027 (event-bus
separation): Axon's saga / event-store / projection abstractions assume an
event-bus the runtime owns end-to-end, which is the opposite of the
event-bus-separation principle ADR-027 codifies. Carrying Axon on top of the
Exeris runtime would surface a stack the host-runtime cannot reasonably
support — so Axon is replaced rather than wedged in.

## Flow topology (synchronous-insert variant)

```
POST /api/v1/orders
  ├─ ShopSagaStateService.hasCartForUser(...)
  ├─ idempotency key = userId + ":" + cartId
  ├─ if prior view bound → return prior view (no re-schedule)
  ├─ insert orders + order_items row (synchronous, on the request thread)
  ├─ inputRegistry.recordStatus(orderId, "SAGA_INITIATED", ...)
  ├─ ExerisFlowTemplate.schedule("shop-order-fulfillment", seed)
  └─ return 202 ACCEPTED + OrderAcceptedView(orderId, "ACCEPTED", sagaId)

Flow "shop-order-fulfillment":
  step 0: reserve-inventory   (compensation: restore-inventory)
  step 1: charge-payment      (compensation: refund-payment)
  step 2: confirm-order       (no compensation)
  step 3: complete-order      (no compensation; returns FlowOutcome.COMPLETE)
```

The synchronous-insert variant was selected (over moving the insert into a
flow step) because it preserves the pre-migration API contract: the
`orderId` returned in the 202 response is durably persisted before the
client receives the response. The four-step + two-compensation shape is the
direct topological equivalent of the Axon saga's
`OrderSagaInitiated → InventoryReserved → PaymentProcessed → OrderConfirmed → OrderSagaCompleted`
chain with `PaymentFailed → PaymentCompensated → ReservationCompensated`
compensation, minus the saga-initiated step (which is folded into the
synchronous insert).

## JPA telemetry bypass disclosure

`exeris.runtime.data.compat-datasource.enabled=true` activates the
`ExerisDataSource` adapter from `exeris-spring-runtime-data`. JPA / Hibernate
continue to acquire connections via the JPA `DataSource` API, but every
acquisition flows through the Exeris compatibility seam. Two JFR events fire
on the seam (see `exeris-spring-runtime` ADR-017 §6.4):

- `eu.exeris.spring.runtime.data.compat.JpaConnectionAcquired`
- `eu.exeris.spring.runtime.data.compat.JpaConnectionBound`

These are the canonical signal that JPA queries have entered the Exeris
adapter rather than the kernel-native QueryExecutor. Reports that compare
this target's JPA call-paths to a kernel-native target **must** disclose this
seam; cross-target latency / allocation deltas have to be split between
"compatibility overhead" and "engine cost" for the comparison to be honest.

## Spring Boot matrix alignment

This target builds against Java **26** and Spring Boot **3.5.14**. The
architect's blueprint cited ADR-028 `matrix-sb4` (Spring Boot 4.0.x), but
the host-runtime artifact `eu.exeris:exeris-spring-runtime-*:0.5.0-SNAPSHOT`
was compiled against the 3.5.14 line (see
`exeris-spring-runtime/pom.xml` — `<spring.boot.version>3.5.14</spring.boot.version>`).
Pinning to 4.0.4 would mismatch the host-runtime artifact's compiled API.
This target follows the host-runtime's actual line and inherits the SB4
matrix automatically once a 4.0-line of `exeris-spring-runtime` is
published.

POM pins:

- `spring-boot-dependencies:3.5.14` (BOM)
- `exeris-spring-runtime-bom:0.5.0-SNAPSHOT` (BOM)
- `neo4j-bolt-connection-bom:6.0.2` declared **first** so it wins the
  resolution against Spring Boot's transitive
  `neo4j-bolt-connection-bom:10.1.1` import (MetricsListener was removed
  between 6.0.2 and 10.1.1; without this pin the Neo4j driver throws
  `NoClassDefFoundError` at runtime).

A Maven Enforcer rule bans `org.axonframework:*` and `org.apache.tomcat.embed:*`
on the runtime classpath (Axon is replaced by `exeris-spring-runtime-flow`; the
servlet container is replaced by the Exeris HTTP server).

`com.zaxxer:HikariCP` is **not** banned. The Exeris kernel persistence subsystem
(`exeris-kernel-community`) owns a HikariCP pool — sized by
`exeris.runtime.persistence.max-pool-size` and hard-referencing `HikariPool` at
init — exactly like `exeris-community-app`, which provides HikariCP at runtime
scope. It reaches the classpath as a load-bearing transitive of
`exeris-spring-runtime-data → exeris-kernel-community`. HikariCP is still locally
excluded from `spring-boot-starter-jdbc` so the JPA/Hibernate **DataSource**
surface stays on the `ExerisDataSource` compat seam (JdbcTemplate /
DataSourceUtils remain available) — i.e. Hikari is the kernel's own pool, not the
Spring application pool.

Netty and Reactor are intentionally **not** in the ban list — they reach
the classpath as load-bearing transitives of `neo4j-java-driver` (Bolt is
implemented on top of Netty; the async surface uses Reactor). Excluding
them would break the Neo4j graph backend. The architect's "no Netty /
Reactor as Community capability" directive is about publication claims,
not driver internals; the next paragraph documents the disclosure
expectation.

Any report that surfaces measurements from this target must run
`mvn -q dependency:tree -f targets/exeris-spring-runtime-app-comp/pom.xml`
and attach the listing whenever the comparison crosses tracks. That way
the Netty/Reactor transitive footprint is visible and reviewers can scope
their claims accordingly.

## Baseline supersession

The pre-migration results at
`results/raw/e2e-shop-order-saga/20260505T114501Z-baseline/` were captured
against the Axon-on-Tomcat shape of this target. After this migration the
binary produced by `mvn package` is Flow-on-Exeris-on-`exeris-spring-runtime`,
which is a different runtime stack on every axis except the SQL bodies.

Consequently:

- **The next saga run against this target cannot be regression-checked
  against the pre-migration baseline.** Doing so would compare apples to
  oranges across (a) the saga engine (Axon → Flow), (b) the web ingress
  (Tomcat → Exeris compat), (c) the connection pool surface (Hikari →
  `ExerisDataSource` adapter).
- Per `docs/regression-policy.md`, the pre-migration baseline must **not**
  be silently overwritten by a post-migration run. The next post-migration
  campaign needs a freshly captured baseline filed under a clearly-labelled
  path (e.g. `results/raw/e2e-shop-order-saga/<date>T<time>Z-post-flow-migration-baseline/`).
- Any cross-baseline narrative in reports needs explicit "Axon-on-Tomcat" vs
  "Flow-on-Exeris-compat" axis labels.

## Build

GitHub Packages auth is required because `eu.exeris:exeris-spring-runtime-*`
artifacts resolve from GitHub Packages, not Maven Central:

```bash
export GITHUB_ACTOR="<github-username>"
export GITHUB_TOKEN="ghp_..."        # PAT with package read scope

mvn -q -DskipTests \
    -s .github/maven-settings-gpr.xml \
    -f targets/exeris-spring-runtime-app-comp/pom.xml \
    package
```

(The repo-level `.github/maven-settings-gpr.xml` references server IDs
`github-exeris-kernel` and `github-exeris-spring-runtime`; both must be
populated with the same PAT.)

## Run

```bash
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark \
EXERIS_DB_USERNAME=benchmark \
EXERIS_DB_PASSWORD=benchmark \
EXERIS_PORT=8080 \
EXERIS_DB_POOL_MIN_SIZE=4 \
EXERIS_DB_POOL_MAX_SIZE=16 \
java -jar target/spring-benchmark-app-1.0.0-SNAPSHOT.jar
```

Targets are launched externally; the harness only synchronizes readiness via
`targets/launcher-sync-wrapper.sh`. Do not start this target from inside the
harness scripts.

## Environment variables

### Runtime + DB (unchanged across the swap)

- `EXERIS_DB_JDBC_URL` — required, JDBC URL.
- `EXERIS_DB_USERNAME` — required, DB username.
- `EXERIS_DB_PASSWORD` — required, DB password.
- `EXERIS_PORT` — optional HTTP port, default `8080`.
- `EXERIS_DB_POOL_MAX_SIZE` (alias: `EXERIS_DB_POOL_MAX`) — kernel persistence
  max-pool-size, bound via `exeris.runtime.persistence.max-pool-size`.
- `EXERIS_DB_POOL_MIN_SIZE` (alias: `EXERIS_DB_POOL_MIN`) — kernel persistence
  min-pool-size, bound via `exeris.runtime.persistence.min-pool-size`. Warms the
  kernel-owned HikariCP pool at boot so the compat target starts with the same
  hot pool as the spring/quarkus targets (Hikari `minimum-idle` / Agroal
  `min-size`). Default `0` (Hikari's lazy default) when unset.
- `EXERIS_DB_POOL_WARMUP_ENABLED` / `EXERIS_DB_POOL_WARMUP_CONNECTIONS` — bound
  via `exeris.runtime.persistence.pool-warmup-enabled` / `-connections`. Forces
  parallel pre-creation of N connections before the HTTP port opens (kernel
  SERVICES-before-RUNTIME ordering). Default depth in the kernel is 2 (a
  reachability probe, clamped 1–8); this target sets `8` so the t=0 connection
  burst (h2load/wrk, 128 conns) hits a partly-hot pool instead of a cold one.
- `EXERIS_DB_CONNECTION_TIMEOUT_MS` — bound via
  `exeris.runtime.persistence.connection-timeout-ms` (runtime commit `8722631`
  added the `connection-timeout-ms` alias to `ExerisSpringConfigProvider`'s
  `getLong` path). Gives the kernel-owned pool a **blocking** acquire that
  levels the field with Spring Hikari (~30 s) and Quarkus Agroal: cold-start /
  latency-spike contention surfaces as latency, not as thrown
  `connectionExhausted` → HTTP 500. The launcher exports `30000`; the property
  defaults to `30000` ms when the env is unset.

### Graph backend (unchanged)

- `EXERIS_GRAPH_BACKEND_TYPE` — `pgq` (default) or `neo4j`.
- `EXERIS_GRAPH_NEO4J_URI` / `EXERIS_GRAPH_NEO4J_USER` /
  `EXERIS_GRAPH_NEO4J_PASSWORD` / `EXERIS_GRAPH_NEO4J_DATABASE` /
  `EXERIS_GRAPH_NEO4J_POOL_MAX_SIZE` — Neo4j-backend tunables.

### Saga simulation (preserved from PaymentService)

- `EXERIS_SAGA_FAILURE_MODE` — `RANDOM_SEEDED` (default), `ALWAYS_FAIL`, or
  `NEVER_FAIL`. Drives the compensation path of the flow.
- `EXERIS_SAGA_PAYMENT_FAIL_RATE` — double in `[0, 1]`, default `0.03`. Only
  consulted when `FAILURE_MODE=RANDOM_SEEDED`.

### Status label (replaces the dropped axon mode)

- `EXERIS_SAGA_ENGINE_MODE` — surfaced via `GET /graph/ping` under the
  `event_backend` key. Default `exeris-flow`.

### Removed (no longer honored)

The following variables from the pre-migration env contract are **gone**;
runners that still set them are silently ignored:

- `EXERIS_AXON_MODE` — replaced by `EXERIS_SAGA_ENGINE_MODE`.
- `EXERIS_AXONSERVER_HOST`, `EXERIS_AXONSERVER_PORT` — Axon Server is no
  longer a dependency.
- `EXERIS_HTTP2_ENABLED`, `EXERIS_SSL_ENABLED`,
  `EXERIS_TRANSPORT_CERT_PATH`, `EXERIS_TRANSPORT_KEY_PATH` — Tomcat-only
  properties; H1 plaintext is the only protocol mode (see "Runtime modes"
  above).

## Endpoints

- `GET  /api/v1/users` — 10 users, each with 10 friends + 10 interests.
- `GET  /health` — liveness probe.
- `GET  /db/ping` — JDBC health probe.
- `GET  /graph/ping` — graph-backend probe; payload now reports
  `saga_framework: exeris-spring-runtime-flow` and
  `event_backend: <EXERIS_SAGA_ENGINE_MODE>`.

### e2e-shop-order-saga flow

- `POST /api/v1/auth/register` — no Bearer token required.
- `GET  /api/v1/products/recommended` — Bearer token required.
- `POST /api/v1/cart/add` — Bearer token required.
- `GET  /api/v1/cart` — Bearer token required.
- `POST /api/v1/orders` — Bearer token required. 202 ACCEPTED on success.
  Idempotent under `userId + ":" + cartId`: a repeated POST returns the
  prior `OrderAcceptedView`.
- `GET  /api/v1/orders/{orderId}/status` — Bearer token required. Returns
  the latest step-transition status from the in-process projection
  (`SAGA_INITIATED`, `INVENTORY_RESERVED`, `PAYMENT_PROCESSING`,
  `CONFIRMED`, `COMPLETED`, `PAYMENT_REFUNDED`, `CANCELLED`).

## Runtime eligibility — request-path resolved, saga-async still blocked

Two distinct compat-seam scope defects have been observed on this target. They
are **separate issues** and have diverged in status; do not collapse them.

### 1. Request-path compat scope — RESOLVED (`exeris-spring-runtime-web` PR #48, 2026-06-09)

Originally (verified 2026-06-07 against `exeris-kernel 0.8.0-SNAPSHOT` +
`exeris-spring-runtime 0.5.0-SNAPSHOT`) the app **booted fully** but JPA-backed
endpoints failed at request time with `PersistenceEngine is not bound in the
current scope` — the compat dispatch invoked the `@RestController` handler (and
the security filter's per-request DB lookup) **without** establishing the kernel
`ScopedValue` scope.

PR #48 moves `populateContext`/`clearContext` and handler dispatch **inside**
`KernelProviderBinder.bind(...)`, so every request-path DB access now has
`PERSISTENCE_ENGINE` bound. Verified resolved by guided runs
`results/raw/guided/20260610T140300Z` and `…T160359Z` (commit `cfc1655`,
snapshot `0.5.0-SNAPSHOT`): `http_reqs_total ≈ 19.5k`, `error_rate_pct = 0`,
`orders_initiated = 460` — i.e. `/api/v1/users`, the authed cart/product reads,
**and the synchronous `orders` + `order_items` insert on `POST /api/v1/orders`
all serve 2xx with real DB data**. The request path is benchmark-eligible.

### 2. Saga-async (flow-worker VT) scope — STILL BLOCKED (host-runtime defect)

The kernel Flow engine schedules saga steps on its **own** worker virtual threads
(`CoreFlowRuntime.launch` → `Thread.ofVirtual().start()`). `ScopedValue` bindings
do **not** propagate across that boundary and `exeris-spring-runtime-flow` does
not re-establish the compat kernel-provider scope on the worker VT. The step
bodies in `ShopOrderSqlSteps` acquire connections through the request-scoped
compat `ExerisDataSource`, whose strict `PERSISTENCE_ENGINE.get()` throws on the
worker VT — and the throw is logged via `System.Logger` (no SLF4J bridge), so it
is **silent** in `target-runtime.log`.

Observable effect (same guided runs above): `POST /orders` returns 202 and the
HTTP error rate is 0, **but the saga never resolves** — `saga_success_rate = 0`,
`saga_compensated_rate = 0`, `runner_status = threshold_failure`. DB confirmation:
`orders.status` frozen at `SAGA_INITIATED` (step 0's `recordStatus` never reached);
`exeris_saga_state` rows at `current_step=0, state=FAILED_ROLLEDBACK`. The kernel's
own `FLOW_SNAPSHOT_STORE` works on the worker VT (wired directly into the engine);
only the app's request-scoped compat adapter is unavailable there.

This is a host-runtime (`exeris-spring-runtime-flow`) defect in the same family as
#48 — the rule generalizes: *any* DB access on *any* execution path (handler,
security filter, **or flow-worker step body**) must run inside
`KernelProviderBinder.bind`. It must be fixed upstream (decorate `FlowStepAction`s
to run inside the compat provider scope, or have `ExerisDataSource` resolve the
engine via a flow-VT-available fallback). Do **not** work around it in the
benchmark harness — synthesizing saga completion would produce invalid, unfair
data. Community is unaffected because its saga step bodies use the kernel-native
`TransactionalExecutor`, not the compat `ExerisDataSource`.

### Eligibility consequence

- **Request-path / read + synchronous-insert endpoints**: benchmark-eligible
  (descriptive; see the cross-track fairness caveats above).
- **Saga terminal-state metrics** (`saga_success_rate`, compensation rate,
  end-to-end order completion): **not** benchmark-eligible until the flow-worker
  VT scope fix lands. This is precisely why `spring-on-exeris` (formerly
  `spring-runtime-on-exeris-flow`) is
  **excluded from `scenarios/e2e-shop-order-saga/comparative-pair-manifest.json`**
  (compatible targets are `exeris-community` + the Axon spring/quarkus targets) and
  is flagged baseline-only in `tools/verify-target-asset-matrix.sh`. Saga runs
  against this target are emitted as `claim_scope: descriptive_only` /
  `exploratory`, never `comparison_eligible`.

## Reporting checklist (post-migration)

- Report tag: **Community / Compatibility / H1 / Flow-on-Exeris**.
- Pre-migration baseline (Axon-on-Tomcat) is **not** comparable — see
  baseline-supersession note.
- JPA telemetry bypass is in play; cross-target JPA latency comparisons
  must call out the seam (ADR-017 §6.4).
- The Maven Enforcer rule guarantees no Axon / Tomcat on the runtime
  classpath. HikariCP **is** present (the kernel persistence pool), as are
  Netty / Reactor (load-bearing Neo4j-driver transitives). If a future report
  wants to characterize the classpath, run `mvn -q dependency:tree` and attach
  the listing.
