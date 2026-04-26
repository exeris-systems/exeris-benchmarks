# Targets

Benchmark targets under test. Each target is a standalone runnable application launched externally
before scenario drivers execute.

## Target Platforms

| Directory | Platform | Tier | Protocols |
| --- | --- | --- | --- |
| `exeris-community-app/` | Exeris Community Runtime | community | H1, H2 |
| `spring-benchmark-app/` | Spring Boot | comparison | H1 |
| `quarkus-benchmark-app/` | Quarkus | comparison | H1 |

## Launcher Utility

`launcher-sync-wrapper.sh` coordinates readiness synchronization for two pre-launched targets.
It does **not** start processes — targets must be launched externally. It issues health probes,
records readiness timestamps, and marks the measurement window start.

```text
targets/launcher-sync-wrapper.sh \
  --target-a-id  <id>    \
  --target-a-port <port>  \
  --target-b-id  <id>    \
  --target-b-port <port>  \
  --output-dir   <path>   \
  [--health-path /health] \
  [--sync-timeout-seconds 30]
```

Output files written to `--output-dir`:
- `measurement-start-timestamp.txt`
- `target-a-ready-timestamp.txt`
- `target-b-ready-timestamp.txt`
- `sync-log.txt`

## Common Launch Pattern

All targets share the same environment variable contract:

```bash
EXERIS_DB_JDBC_URL=jdbc:postgresql://localhost:5432/benchmark \
EXERIS_DB_USERNAME=benchmark \
EXERIS_DB_PASSWORD=benchmark \
EXERIS_PORT=8080 \
EXERIS_DB_POOL_MIN_SIZE=4 \
EXERIS_DB_POOL_MAX_SIZE=16 \
java -jar target/<artifact>.jar
```

See each target's `README.md` for full environment variable reference,
TLS/H2 options, and graph backend selection.

## Target Contract Schema

See [schemas/enterprise-target-contract.schema.json](../schemas/enterprise-target-contract.schema.json)
for the contract definition used by external target specifications.
