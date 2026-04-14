# Spring Benchmark App

Standalone Spring Boot benchmark target app.

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
java -jar target/spring-benchmark-app-1.0.0-SNAPSHOT.jar
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

## Graph Backend Selection (Axon)

Use PostgreSQL/PGQ (default):

```bash
EXERIS_GRAPH_BACKEND_TYPE=pgq
```

Use Neo4j Bolt:

```bash
EXERIS_GRAPH_BACKEND_TYPE=neo4j \
EXERIS_GRAPH_NEO4J_URI=bolt://localhost:7687 \
EXERIS_GRAPH_NEO4J_USER=neo4j \
EXERIS_GRAPH_NEO4J_PASSWORD=secret \
EXERIS_GRAPH_NEO4J_DATABASE=neo4j
```

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
