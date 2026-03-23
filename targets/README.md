# Targets

Benchmark targets under test. Each target platform (Community Runtime, Enterprise Runtime, Spring Runtime)
has a directory with startup configurations and runtime profiles.

## Target Platforms

| Directory | Platform | Tiers | Protocols |
| --- | --- | --- | --- |
| `exeris-kernel/` | Exeris Kernel | community | H1, H2, H3 |
| `enterprise/targets/exeris-kernel/` | Exeris Kernel (Enterprise) | enterprise | H1, H2, H3 |
| `exeris-spring-runtime/` | Exeris Spring Runtime | community, spring | H1, H2 |
| `exeris-benchmark-app/` | Benchmark target app scaffold | scaffold only | contract boundary only |

## Target Contract

Each target directory contains:

```text
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

`exeris-benchmark-app/` is different from runnable tier targets. It is a scaffold module and
contract boundary for a future extraction-ready benchmark app, not a runnable Community,
Enterprise, or Spring target implementation.
