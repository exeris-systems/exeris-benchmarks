# Targets

Benchmark targets under test. Each target platform (Community Runtime, Enterprise Runtime, Spring Runtime)
has a directory with startup configurations and runtime profiles.

## Target Platforms

| Directory | Platform | Tiers | Protocols |
|---|---|---|---|
| `exeris-kernel/` | Exeris Kernel | community, enterprise | H1, H2, H3 |
| `exeris-spring-runtime/` | Exeris Spring Runtime | community, spring | H1, H2 |

## Target Contract

Each target directory contains:

```
targets/<target-name>/
  README.md                      ← Target documentation
  target-contract.example.json   ← Benchmark start/stop/warmup contract
  community/ or enterprise/
    runtime/
      h1/
        startup.sh
        target-config.json
      h2/
      h3/
```

### Target Contract Schema

See [schemas/enterprise-target-contract.schema.json](../schemas/enterprise-target-contract.schema.json)
for authoritative definition.

Minimum fields:
- `startCommand`: shell command to launch target
- `stopCommand`: shell command to stop target
- `warmupDuration`: minimum duration before measurement (seconds)
- `healthCheckUrl`: endpoint to wait for readiness
- `port`: listening port
- `tls`: boolean (HTTPS support)
