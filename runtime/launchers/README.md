# Launchers

Scripts to start and stop benchmark targets (Community Runtime, Enterprise Runtime, Exeris Spring Runtime).

## Available Launchers

| Script | Target | Start Method | Startup Time | Notes |
|---|---|---|---|---|
| `community-stack-launcher.sh` | Exeris Community Runtime | Direct JVM | ~2s | Single-node HTTP server |
| `start-target.sh` | Generic target | Docker or direct | Depends | Wrapper for selective startup |
| `stop-target.sh` | All targets | Signal | ~1s | Stops all running targets |
| `postgres-container.sh` | PostgreSQL | Docker | ~3s | Database fixture for integration scenarios |

## Quick Start

### Start Community Runtime
```bash
./launchers/community-stack-launcher.sh
# Listens on localhost:8080 (HTTP), localhost:8443 (HTTPS)
```

### Start with database fixture
```bash
./launchers/postgres-container.sh &
./launchers/community-stack-launcher.sh
```

### Stop all
```bash
./launchers/stop-target.sh
```

## Environment Variables

Standard environment variables for target startup:

| Var | Default | Example |
|---|---|---|
| `TARGET_PORT` | 8080 | 8888 |
| `TARGET_HOST` | 127.0.0.1 | 0.0.0.0 |
| `JVM_OPTS` | (none) | `-Xmx2g -XX:+UseZGC` |
| `LOG_LEVEL` | INFO | DEBUG |
