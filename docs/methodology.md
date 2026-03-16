# Benchmark Methodology

## JMH microbenchmarks

All JMH benchmarks are located in `micro/jmh/` as a standalone Maven module.
They depend on Exeris artifacts via normal Maven coordinates and do not contain
product source.

### Standard configuration

| Parameter | Value | Rationale |
|---|---|---|
| Warmup iterations | 5 | Allow JIT to reach steady state |
| Warmup time | 2 s each | Short methods need enough invocations |
| Measurement iterations | 10 | Statistically meaningful sample |
| Measurement time | 2 s each | — |
| Forks | 3 | Different JVM process initializations |
| GC between iterations | `@Setup(Level.Iteration)` | Avoid GC interference |
| Time unit | NANOSECONDS / MICROSECONDS | Appropriate for hot-path work |

Forks are always ≥ 2 for results published to `baselines/`. Single-fork runs
(`-f 1`) are acceptable for development iteration but must not be stored as
baselines.

### Mode selection

| Benchmark mode | When to use |
|---|---|
| `Throughput` | Codec, serialization, route lookup |
| `AverageTime` | Request wrapper construction, scheduler |
| `SampleTime` | Latency distribution for any path claiming microsecond targets |
| `SingleShotTime` | Cold-start, first-request, JVM init probes |

### Allocation tracking

For methods claiming zero-allocation:

1. Run with `-prof gc` to capture allocation rate.
2. On Linux, additionally run with `-prof perf` or `-prof async` (async-profiler)
   to validate at the native level.
3. Expected result: `·gc.alloc.rate.norm ≈ 0 B/op`.

### JVM flags for benchmarks

```
-XX:+UseG1GC
-XX:+AlwaysPreTouch
-Xms512m -Xmx512m          # fixed heap to avoid GC mode variation
-XX:-TieredCompilation     # optional for profiling only, not for baseline results
```

### TLS engine lifecycle and reuse policy

There are two distinct TLS benchmark patterns. Use the appropriate lifecycle
based on what you're measuring:

#### Pattern A: Handshake / Lifecycle Benchmarks

For benchmarks measuring handshake cost, session setup, connection initialization, 
or cold-start overhead:

- Use fresh engine instances per invocation via `@Setup(Level.Invocation)`
- Each measurement captures the full handshake FFM cost
- No steady-state optimization — the setup cost IS the measurement
- Examples: `beginHandshakeNoFdCost`, TLS handshake-cold scenarios

#### Pattern B: Steady-State Record-Path Benchmarks (wrap/unwrap)

For benchmarks measuring post-handshake encryption/decryption throughput:

- Use engine reuse per trial (`@Setup(Level.Trial)`) **after handshake completion**
- Handshake is performed once during trial setup; engines remain in ACTIVE state
- Each measurement captures only the wrap/unwrap hot path, NOT session setup
- This is the correct and required model for production performance claims
- Examples: `wrapThroughput`, `unwrapThroughput`, `wrapUnwrapRoundTrip` 
  in Community/Enterprise engines, B1–C4 in TLS matrix

**Key correctness rule:** Do not reuse engines that are still in `HANDSHAKE_IN_PROGRESS` 
state across method invocations if you're measuring handshake progress. Once engines 
reach ACTIVE, reuse is required and preferred (to avoid measuring setup overhead).

---

## HTTP load benchmarks

### Tool responsibilities

| Tool | Use case |
|---|---|
| **wrk** | Raw HTTP/1.1 RPS and latency, simple payloads |
| **wrk2** | Steady-rate load (controlled RPS), latency-under-load |
| **h2load** | HTTP/2 multiplexed load, ALPN negotiation |
| **k6** | Scripted scenarios, CI smoke, mixed flows |

### Standard HTTP/1.1 baseline run (wrk)

```bash
wrk -t 4 -c 100 -d 30s --latency http://localhost:8080/path
```

Parameters stored in result JSON:
- threads (`-t`)
- connections (`-c`)
- duration (`-d`)
- script path if any (`--script`)
- payload file if any

### Standard HTTP/2 run (h2load)

```bash
h2load -n 100000 -c 100 -m 10 https://localhost:8443/path
```

Parameters stored: `-n` (total requests), `-c` (clients), `-m` (max concurrent
streams per client).

### Warmup

All runtime benchmarks require a warmup phase before measurement begins.
Minimum warmup: **60 seconds** of sustained load at target concurrency before
the measurement window opens.

For k6 scenarios use the `stages` array with a ramp-up segment followed by
the measurement segment. Never include the ramp-up portion in reported numbers.

---

## Statistical reporting

For every benchmark result the following must be present:

- mean
- p50, p90, p99, p999 latency (runtime benchmarks)
- standard deviation (JMH)
- confidence interval (JMH, 99%)
- min / max (for sanity checks)
- number of samples / operations

Outlier runs (stddev > 15% of mean across forks) should be flagged and
investigated before being stored as baselines.

---

## Reproducibility checklist

Before storing a result as a baseline:

- [ ] `capture-env.sh` output included alongside result JSON
- [ ] Hardware profile matches a named profile in `docs/hardware-profiles.md`
- [ ] JVM flags recorded
- [ ] Warmup completed
- [ ] ≥ 3 forks (JMH) or ≥ 3 independent runs (runtime)
- [ ] No other significant processes on the benchmark machine
- [ ] Turbo Boost / frequency scaling policy noted
- [ ] Result schema validates against `schemas/benchmark-result.schema.json`
