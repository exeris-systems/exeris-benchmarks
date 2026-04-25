# Docker Compose

Docker Compose configurations for containerized benchmark targets and support services.

## Fixtures

| Service | Image | Purpose |
|---|---|---|
| exeris-runtime | local/exeris-community-runtime:latest | Exeris Community Runtime container |
| postgres | postgres:16.2 | Database for integration scenarios |
| redis | redis:7-alpine | Cache fixture (optional) |

## Running Compose Stack

```bash
docker compose up -d
# Services available at:
#   exeris-runtime: http://localhost:8080
#   postgres: localhost:5432
```

## Profile: baseline

```bash
docker compose --profile baseline up -d
# Includes: exeris-runtime, postgres
```

Enterprise and locality compose profiles are excluded from the active/public documentation path.
