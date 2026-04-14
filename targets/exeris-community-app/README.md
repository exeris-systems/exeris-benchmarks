# Exeris Community App

Standalone Exeris Community benchmark target app.

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
java -jar target/exeris-community-app-1.0.0-SNAPSHOT.jar
```

## Run with TLS (HTTPS/h2)

Use transport cert/key env vars so Community transport can serve HTTPS (including HTTP/2 over TLS):

```bash
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark \
EXERIS_DB_USERNAME=benchmark \
EXERIS_DB_PASSWORD=benchmark \
EXERIS_PORT=8080 \
EXERIS_HTTP_MAX_VERSION=HTTP_2 \
EXERIS_TRANSPORT_CERT_PATH=/absolute/path/to/server.crt \
EXERIS_TRANSPORT_KEY_PATH=/absolute/path/to/server.key \
java -jar target/exeris-community-app-1.0.0-SNAPSHOT.jar
```

For `scenarios/e2e-shop-order-saga/k6.js` over HTTPS/h2, set both `EXERIS_TRANSPORT_CERT_PATH` and `EXERIS_TRANSPORT_KEY_PATH` when launching the app.

## Run with JFR Telemetry Recording

JFR recording is enabled via JVM flags and works with the default `http,persistence` subsystem set.

```bash
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark \
EXERIS_DB_USERNAME=benchmark \
EXERIS_DB_PASSWORD=benchmark \
EXERIS_PORT=8080 \
EXERIS_DB_POOL_MIN_SIZE=4 \
EXERIS_DB_POOL_MAX_SIZE=16 \
EXERIS_JAVA_OPTS="-XX:StartFlightRecording=filename=results/raw/exeris-community-telemetry.jfr,settings=profile,dumponexit=true" \
java $EXERIS_JAVA_OPTS -jar target/exeris-community-app-1.0.0-SNAPSHOT.jar
```

## Graph Backend Selection

The application code path remains the same in both modes. Graph SPI routing selects the backend and dialect at runtime from bootstrap properties. Existing graph adapters already resolve through `KernelProviders.graphEngine`, so switching backend is runtime-only.

- PGQ/PostgreSQL mode (default):

```bash
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark \
EXERIS_DB_USERNAME=benchmark \
EXERIS_DB_PASSWORD=benchmark \
EXERIS_GRAPH_BACKEND_TYPE=postgresql \
java -jar target/exeris-community-app-1.0.0-SNAPSHOT.jar
```

- Neo4j mode:

```bash
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark \
EXERIS_DB_USERNAME=benchmark \
EXERIS_DB_PASSWORD=benchmark \
EXERIS_GRAPH_BACKEND_TYPE=neo4j \
EXERIS_GRAPH_NEO4J_URI=bolt://localhost:7687 \
EXERIS_GRAPH_NEO4J_USER=neo4j \
EXERIS_GRAPH_NEO4J_PASSWORD=secret \
EXERIS_GRAPH_NEO4J_DATABASE=neo4j \
java -jar target/exeris-community-app-1.0.0-SNAPSHOT.jar
```

## Optional Telemetry Subsystem Boot Attempt

Set `EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=true` to attempt startup with `http,persistence,telemetry`.

If telemetry is not provided on the classpath, the app prints a concise warning to stderr and automatically retries with `http,persistence`. Any other startup failure is not masked and is rethrown.

## Environment Variables

- `EXERIS_DB_JDBC_URL` required JDBC URL.
- `EXERIS_DB_USERNAME` required DB username.
- `EXERIS_DB_PASSWORD` required DB password.
- `EXERIS_ENABLE_TELEMETRY_SUBSYSTEM` optional, default `false`; when `true`, attempts `http,persistence,telemetry` before fallback.
- `EXERIS_PORT` optional HTTP port, default `8080`.
- `EXERIS_HTTP_MAX_VERSION` optional HTTP max protocol version, default `HTTP_2`.
- `EXERIS_HTTP_H2C_UPGRADE_ENABLED` optional HTTP/1.1 upgrade toggle, default `true`.
- `EXERIS_GRAPH_BACKEND_TYPE` optional graph backend selector (`postgresql` or `neo4j`), default `postgresql`.
- `EXERIS_GRAPH_GRAPH_NAME` optional graph name, default `exeris_graph`.
- `EXERIS_GRAPH_NEO4J_URI` optional Neo4j URI (required when backend is `neo4j`).
- `EXERIS_GRAPH_NEO4J_USER` optional Neo4j user (required when backend is `neo4j`).
- `EXERIS_GRAPH_NEO4J_PASSWORD` optional Neo4j password (required when backend is `neo4j`).
- `EXERIS_GRAPH_NEO4J_DATABASE` optional Neo4j database.
- `EXERIS_TRANSPORT_CERT_PATH` optional TLS certificate path forwarded to `exeris.transport.certPath`.
- `EXERIS_TRANSPORT_KEY_PATH` optional TLS private key path forwarded to `exeris.transport.keyPath`.
- Pool min resolution: `EXERIS_DB_POOL_MIN_SIZE` -> `EXERIS_DB_POOL_MIN` -> `4`.
- Pool max resolution: `EXERIS_DB_POOL_MAX_SIZE` -> `EXERIS_DB_POOL_MAX` -> `16`.

## Protocol Smoke Checks

- HTTP/1.1:

```bash
curl --http1.1 http://localhost:${EXERIS_PORT:-8080}/health
```

- HTTP/2 cleartext prior-knowledge (h2c):

```bash
curl --http2-prior-knowledge http://localhost:${EXERIS_PORT:-8080}/health
```

Benchmark HTTP/2 traffic is exercised via cleartext prior-knowledge h2c. It does not rely on HTTP/1.1 Upgrade negotiation.

## Endpoints

- `GET /api/v1/users` returns 10 users (ordered by id), each with 10 friends and 10 interests.
- `GET /health`
- `GET /db/ping`
