# Quarkus Benchmark App (tuned transport, pure JDBC)

Standalone Quarkus benchmark target app — **"tuned" archetype** (canonical target id
`quarkus-tuned`, legacy `quarkus-jdbc`).

This is the tuned-transport counterpart of `quarkus-benchmark-app`, which runs
**default Quarkus** (Hibernate ORM, JDK NIO transport + JSSE TLS). This target
differs on two axes at once:

1. **Network stack** — native by default: native epoll transport + native BoringSSL
   TLS (see "Netty transport & TLS engine axes" below). Default Quarkus is JDK NIO + JSSE.
2. **Persistence** — **all relational persistence uses raw JDBC** (Agroal `DataSource`
   + `PreparedStatement`/`ResultSet`), with **no Hibernate/ORM/Panache**, isolating ORM cost:

- `entity-read-by-id` (`GET /api/v1/users`) — raw JDBC; SQL query shapes kept
  identical to the ORM variant's native queries, so the data-access layer is the
  only intended difference on this path.
- `e2e-shop-order-saga` (cart/order/inventory/auth/catalog) — already raw JDBC.

Execution stays on virtual threads (`@RunOnVirtualThread`). The Axon saga substrate
and the Neo4j/PGQ graph backend are unchanged from the ORM variant — they are
orthogonal axes, not part of the Hibernate-vs-JDBC contrast. Exeris is **not**
mirrored: it runs its own persistence runtime as a separate target.

## Build

```bash
mvn -q -DskipTests package
```

## Run

```bash
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark \
EXERIS_DB_USERNAME=benchmark \
EXERIS_DB_PASSWORD=benchmark \
EXERIS_PORT=8080 \
EXERIS_DB_POOL_MIN_SIZE=4 \
EXERIS_DB_POOL_MAX_SIZE=16 \
java -jar target/quarkus-benchmark-app-tuned-1.0.0-SNAPSHOT-runner.jar
```

## Environment Variables

- `EXERIS_DB_JDBC_URL` required JDBC URL.
- `EXERIS_DB_USERNAME` required DB username.
- `EXERIS_DB_PASSWORD` required DB password.
- `EXERIS_PORT` optional HTTP port, default `8080`.
- Pool min resolution: `EXERIS_DB_POOL_MIN_SIZE` -> `EXERIS_DB_POOL_MIN` -> `4`.
- Pool max resolution: `EXERIS_DB_POOL_MAX_SIZE` -> `EXERIS_DB_POOL_MAX` -> `16`.
- `EXERIS_GRAPH_BACKEND_TYPE` optional graph backend selector: `pgq` (default) or `neo4j`.
- `EXERIS_GRAPH_NEO4J_URI` optional Neo4j Bolt URI when backend is `neo4j`.
- `EXERIS_GRAPH_NEO4J_USER` optional Neo4j username when backend is `neo4j`.
- `EXERIS_GRAPH_NEO4J_PASSWORD` optional Neo4j password when backend is `neo4j`.
- `EXERIS_GRAPH_NEO4J_DATABASE` optional Neo4j database, default `neo4j`.
- `EXERIS_AXON_MODE` optional event backend mode label, default `event-sourcing-outbox`.
- `EXERIS_NETTY_NATIVE_TRANSPORT` optional Netty transport selector, default `true` (native epoll). See below.
- `EXERIS_TLS_NATIVE` optional TLS engine selector, default `true` (native BoringSSL). See below.

## Netty transport & TLS engine axes

Two orthogonal axes control the network stack. **Defaults are native on both axes
(native epoll transport + native BoringSSL TLS engine).** Both native libs are
always on the classpath (declared in the main `<dependencies>`), so the pure-Java
paths (JDK NIO / JSSE) are reachable purely by flipping the runtime toggles — no
rebuild needed. Linux x86_64 only.

### Transport: native epoll (default) vs JDK NIO

- **native epoll** (default) — Linux-native transport via `netty-transport-native-epoll`,
  selected by `quarkus.vertx.prefer-native-transport=true`.
- **JDK NIO** — pure-Java `java.nio` selectors. Opt out at runtime:
  ```bash
  EXERIS_NETTY_NATIVE_TRANSPORT=false java -jar target/quarkus-benchmark-app-tuned-1.0.0-SNAPSHOT-runner.jar
  ```

### TLS engine: native BoringSSL (default) vs JSSE

- **native BoringSSL** (default) — native engine via `netty-tcnative-boringssl-static`,
  installed on the HTTPS listener by `NativeTlsEngineCustomizer`.
- **JSSE** — JDK `SSLEngine`, pure Java (allocates large heap `byte[]`). Opt out at runtime:
  ```bash
  EXERIS_TLS_NATIVE=false EXERIS_TRANSPORT_CERT_PATH=... EXERIS_TRANSPORT_KEY_PATH=... \
    java -jar target/quarkus-benchmark-app-tuned-1.0.0-SNAPSHOT-runner.jar
  ```
  Quarkus exposes no built-in property to pick the HTTP server's SSL engine
  (`HttpServerOptionsUtils` only ever installs `JdkSSLEngineOptions`), so the
  switch is done by `NativeTlsEngineCustomizer` (an `HttpServerOptionsCustomizer`
  bean) reading `exeris.transport.tls.native`. If `EXERIS_TLS_NATIVE=true` but the
  native provider cannot be loaded the server **fails fast** rather than silently
  running JSSE under a "native TLS" label.

All four transport×engine combinations come from the one default build, selected
at runtime by the two env toggles.

## Endpoints

- `GET /api/v1/users` returns 10 users (ordered by id), each with 10 friends and 10 interests.
- `GET /health`
- `GET /db/ping`
- `GET /graph/ping`

### e2e-shop-order-saga Flow

- `POST /api/v1/auth/register` (no Bearer token required).
- `GET /api/v1/products/recommended` (Bearer token required).
- `POST /api/v1/cart/add` (Bearer token required).
- `GET /api/v1/cart` (Bearer token required).
- `POST /api/v1/orders` (Bearer token required).
- `GET /api/v1/orders/{orderId}/status` (Bearer token required).

Auth behavior: Bearer token is required for all flow endpoints except register.
