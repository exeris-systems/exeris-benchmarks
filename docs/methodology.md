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

#### GC churn and pause metrics (captured with `-prof gc`)

For benchmarks where allocation pressure and GC behavior are relevant (not only zero-alloc paths):

| Metric | Description |
|---|---|
| `gc.churn.Eden_Space` | Eden Space churn rate (MB/sec) — G1GC only |
| `gc.churn.Eden_Space.norm` | Normalized Eden churn (bytes/op) |
| `gc.churn.Survivor_Space` | Survivor Space churn rate |
| `gc.time` | Total GC pause time (ms) in measurement window |
| `gc.count` | Total GC events in measurement window |

High `gc.churn.Eden_Space.norm` indicates excessive short-lived object creation. Reduce before E2E testing — eden fragmentation degrades TLAB efficiency and introduces non-deterministic Minor GC jitter.

### CPU hardware counter profiling (Linux only)

For cache-miss and branch-misprediction analysis (requires `perf_event_paranoid ≤ 1`):
- `-prof perf` — raw Linux perf events
- `-prof perfnorm` — normalized per-operation: `instructions/op`, `cycles/op`, `cache-misses/op`

For safepoint-bias-free CPU profiling, prefer `-prof async` (async-profiler via `AsyncGetCallTrace` + `perf_events`). Requires `libasyncProfiler.so` and `-XX:+PreserveFramePointer` on the fork JVM.

### JVM flags for benchmarks

```
-XX:+UseG1GC
-XX:+AlwaysPreTouch
-Xms512m -Xmx512m          # fixed heap to avoid GC mode variation
-XX:-TieredCompilation     # optional for profiling only, not for baseline results
```

### ZGC configuration (Enterprise tier, Java 21)

For Enterprise TLS benchmarks using ZGC:
- Set `-Xms` and `-Xmx` to the same value (heap parity) to prevent resize pauses.
- Set `-XX:SoftMaxHeapSize` to ~90% of `-Xmx` for ZGC allocation stall headroom.
  Example: `-Xms256m -Xmx256m -XX:SoftMaxHeapSize=230m`
- `-XX:+ZGenerational` required for Java 21 (present in AbstractEnterpriseTlsBenchmark).
- Monitor gc.log for `ZAllocationStall` events — any stall invalidates the affected window.

### Baseline configuration boundaries

Any change to JVM flags constitutes a configuration change that invalidates direct numeric comparison with prior baselines. After adding `-XX:+PreserveFramePointer` (consistent ~1–3% throughput overhead on x86_64):
- Archive pre-change baselines under a config-labeled path (e.g., `baselines/.../without-fp/`)
- Take a fresh full baseline run under the new configuration
- Do not compare regression thresholds across configuration boundaries

### JFR ring-buffer early-phase loss

JFR with `dumponexit=true` and `maxsize=256m` uses a ring buffer retaining only the **last 256 MB** of events. Early GC events (warmup/establishment phase) may be evicted. For early-phase GC analysis, use chunk-rotation mode: `maxchunksize=64m`.

### NMT incompleteness for JNI-native paths

`-XX:NativeMemoryTracking=summary` tracks JVM-internal memory only (Heap, Metaspace, CodeCache, Thread Stacks). It does **not** track allocations by native libraries via JNI:

- **BoringSSL / OpenSSL via netty-tcnative**: TLS record buffers and handshake state are allocated outside JVM visibility.
- JNI-native allocations appear in process RSS (`/proc/PID/status` VmRSS) but not in NMT output.

**For all TLS benchmark rows (B4/B5/B6/B7), treat NMT output as JVM-heap-only.** Use RSS from `/usr/bin/time -v` or cgroup `memory.current` as the authoritative total memory figure. NMT result JSON from TLS benchmarks must carry `nmt_incomplete: true`.

### TLS engine lifecycle and reuse policy

There are two distinct TLS benchmark patterns. Use the appropriate lifecycle
based on what you're measuring:

> **Framing note:** The B3/B4/B5/B6/B7 comparative set is a _natural implementation
> benchmark_, not a pure crypto-engine comparison. Each row measures TLS record-path
> cost under the transport model and memory allocator that the implementation
> deploys in production. Observed differences represent the combined cost of the
> record-path stack (crypto + transport boundary + allocator lifecycle), not the
> isolated crypto algorithm cost.

### Engine-level vs integration-level TLS comparison

- `B3`/`B4`/`B5` isolate the TLS engine boundary via their harness models
  (JDK `SSLEngine`, Netty in-memory pipeline, neutral in-process Memory-BIO engine lens).
- `B6`/`B7` include transport wiring and therefore capture integration-level costs.
- Claims must preserve this distinction. Do not present `B3`/`B4`/`B5` and `B6`/`B7`
  results as a single equivalence class without explicit caveats.

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

### Latency claim scope: JMH SampleTime vs E2E

`Mode.SampleTime` measures the **distribution of individual operation cost** at maximum drive rate. Valid claims:
- "p99 individual call cost: 99% of encode/decode operations complete in < X µs"

NOT valid for:
- E2E p99 latency claims under realistic arrival rates or concurrent load

E2E p99 requires arrival-rate tooling: wrk2 (`-R <rps>`) or k6 with `constant-arrival-rate` executor.

### Coordinated Omission (CO) — tool classification

| Tool / Mode | CO Risk | Claim scope |
|---|---|---|
| wrk (default, closed-loop) | ❌ YES | Throughput / saturation probes only |
| wrk2 with `-R` | ✅ NO | p99/p99.9 latency at declared load fraction |
| k6 `shared-iterations` / `ramping-vus` | ❌ YES | Throughput probes only |
| k6 `constant-arrival-rate` | ✅ NO | p99/p99.9 latency at declared arrival rate |
| JMH `Mode.SampleTime` | N/A (Micro) | Per-call cost distribution |

`co_corrected: true` in a result JSON is only meaningful alongside `r_value`, `observed_saturation_rps`, and `load_fraction`. A `load_fraction ≥ 0.95` means the measurement was at saturation — queuing delays are real, not CO artifacts, but do not represent nominal operating conditions.

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
- [ ] cgroup / CPU limits captured (version, quota, cpuset)
- [ ] Result schema validates against `schemas/benchmark-result.schema.json`

---

## Guard vs Exploratory Metadata Contract

| Field | guard | exploratory |
|---|---|---|
| commit SHA | required | required |
| JDK vendor + version | required | required |
| JVM flags | required | required |
| hardware profile | required | required |
| forks | >= 2 (default 3) | >= 1; document if single-fork |
| warmup / measurement config | full (wi, i, w, r) | full (wi, i, w, r) |
| cgroup / cpu limits | required | best-effort |
| claim_scope | comparison_eligible | exploratory_only |
| baseline storage | permitted when all axes match | disallowed |
| comparative claims | permitted when axes and equivalence match | disallowed |

## Report Intake: Hypothesis-to-Scenario Mapping (Java 25+)

Use this mapping to translate external performance hypotheses into Exeris benchmark work without overclaiming: select the matching family and scenarios, capture the listed metadata, and keep conclusions bounded to the declared comparison axis.

| Report hypothesis | Exeris benchmark family | Scenario(s) | Primary metrics | Required metadata | Allowed conclusion type |
|---|---|---|---|---|---|
| JMH correctness (DCE, constant folding, warmup, forks) | MICRO | `micro/jmh` existing suites (`src/main/java/**`) | ops/time, alloc rate, CI | JDK version, JVM flags, fork/warmup config | Descriptive or method-only |
| Virtual threads improve I/O workloads | RUNTIME | `scenarios/keepalive-steady`, `scenarios/concurrent-32`, `scenarios/concurrent-256` | throughput, p99 latency | thread model, concurrency, protocol mode | Within-target comparative only |
| Virtual threads can regress CPU-bound workloads | RUNTIME | `scenarios/plaintext`, `scenarios/json-1kb` | throughput, CPU usage | workload classification, core count | Conditional comparative only |
| GC mode impact (G1 vs Gen ZGC) | RUNTIME/MICRO | runtime scenarios plus JMH with `-prof gc` | p99 tails, pause behavior, allocation rate | exact GC flags, heap sizing, `MaxRAMPercentage` | Within same target/protocol only |
| cgroup/CFS throttling risks | RUNTIME | long-run runtime scenarios (for example `scenarios/keepalive-steady`) | throughput variance, latency spikes | cgroups version, CPU limits, `ActiveProcessorCount` | Diagnostic only, not product claim |
| startup/footprint vs peak throughput trade-off | RUNTIME | `scenarios/cold-connect-single` plus steady scenarios | startup time, RSS, throughput | launch mode, warmup window, measurement duration | Trade-off statement only |
| protocol differences H1/H2/H3 | COMPAT/RUNTIME | `scenarios/multiplex-32`, `scenarios/health-probe`, protocol matrix scripts (`scripts/run-h2load.sh`, `scripts/run-tls-matrix.sh`, `scripts/report-protocol-matrix.sh`) | req/s, tail latency | explicit protocol label, ALPN/TLS mode | Mode-comparison only |
| cross-tier claims Community vs Enterprise | RESULTS/DOCS | results and baselines reporting path (`results/**`, `baselines/**`) | normalized deltas, confidence bounds | tier label, target classification | Cross-tier same protocol only with caveats |

### Intake rules

- Every mapped run must preserve one primary comparison axis.
- Match payload/concurrency/protocol before comparative claims.
- Capture commit SHA, JDK/tool versions, JVM flags, hardware profile.
- Label tier/protocol/family in every artifact.
- If equivalence missing, publish as exploratory only.
- Avoid enterprise-sensitive raw traces in public artifacts.
