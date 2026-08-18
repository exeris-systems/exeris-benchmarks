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

### ZGC configuration (TLS, Java 21)

For TLS benchmarks using ZGC:
- Set `-Xms` and `-Xmx` to the same value (heap parity) to prevent resize pauses.
- Set `-XX:SoftMaxHeapSize` to ~90% of `-Xmx` for ZGC allocation stall headroom.
  Example: `-Xms256m -Xmx256m -XX:SoftMaxHeapSize=230m`
- `-XX:+ZGenerational` required for Java 21 when using generational ZGC mode.
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

**For all TLS benchmark rows (B4/B5/B6), treat NMT output as JVM-heap-only.** Use RSS from `/usr/bin/time -v` or cgroup `memory.current` as the authoritative total memory figure. NMT result JSON from TLS benchmarks must carry `nmt_incomplete: true`.

### TLS engine lifecycle and reuse policy

There are two distinct TLS benchmark patterns. Use the appropriate lifecycle
based on what you're measuring:

> **Framing note:** The B3/B4/B5/B6 comparative set is a _natural implementation
> benchmark_, not a pure crypto-engine comparison. Each row measures TLS record-path
> cost under the transport model and memory allocator that the implementation
> deploys in production. Observed differences represent the combined cost of the
> record-path stack (crypto + transport boundary + allocator lifecycle), not the
> isolated crypto algorithm cost.

### Engine-level vs integration-level TLS comparison

- `B3`/`B4`/`B5` isolate the TLS engine boundary via their harness models
  (JDK `SSLEngine`, Netty in-memory pipeline, neutral in-process Memory-BIO engine lens).
- `B6` includes transport wiring and therefore captures integration-level costs.
- Claims must preserve this distinction. Do not present `B3`/`B4`/`B5` and `B6`
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
  in Community/Memory-BIO benchmark harnesses, B1–B6 rows in this repository TLS matrix

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

### Warmup vs steady-state, and the explicit measurement window

Throughput is reported as **steady-state**, computed **only** from an explicit
measurement window that opens after a defined warmup. Time-to-peak (how long the
system took to *reach* steady state) is a separate, separately-reported metric — it
characterizes warmup, not steady-state, and must never be averaged into the
steady-state throughput.

The canonical split is **warmup → measurement → cooldown**. The default for the
saga scenario is **120s warmup / 180s measurement / 30s cooldown** (tunable via
`K6_WARMUP_DURATION` / `K6_MEASURE_DURATION` / `K6_COOLDOWN_DURATION`). Phases are
separate k6 `constant-arrival-rate` scenarios tagged `phase=warmup|measurement|cooldown`;
the cooldown drains in-flight work so the measurement tail is not contaminated by
shutdown effects. The split is recorded in `result.json`
(`run_config.{warmup,measurement,cooldown}_window_s`).

A flat, single-window run reports the average over warmup + steady-state and so
**reads warmup noise as steady-state** — the failure this split exists to prevent.

**Reconstruct the warmup curve, don't trust the summary.** A `--summary-export`
number is a single window average and cannot distinguish warmup from steady-state.
Stream the per-sample CSV (`k6 run --out csv=...`; the `scenario` column carries the
phase) and aggregate per-second with `tools/aggregate-k6-throughput.sh`. It emits
`throughput_series` (per-second, phase-tagged), `steady_state_throughput_rps`
(mean over measurement buckets, dropping the partial final second), and
`time_to_peak_s` — all merged into `result.json` `metrics`.

### Proving steady-state: C2 compiler diagnostics

You cannot defend "this is steady-state" without showing the JIT has stopped
working inside the measurement window. Enable the additive JFR overlay
(`BENCH_JFR_STEADY_STATE=1` → merges `env/jfr-steady-state.jfc` on top of
`profile`; symmetric across all targets — an asymmetric overlay would bias one
runtime's profile) and read these signals:

| Signal | Source | Steady-state reading | Warmup-still-running reading |
|---|---|---|---|
| `jdk.CompilerStatistics` (period 1s) | JFR overlay | `nmethodCodeSize` / `compileCount` flat in the window | still rising ⇒ warmup not done |
| `jdk.CompilerQueueUtilization` (period 1s) | JFR overlay | `queueSize` ≈ 0 | `queueSize > 0` ⇒ methods still waiting to compile |
| `jdk.Compilation` (threshold 100ms) | JFR overlay | no individual compile > ~10s | a compile > ~10s ⇒ C2 thread is being preempted |
| `%wait` per thread | `pidstat -t -u -w` sidecar | low on worker/compiler threads | high ⇒ CPU starvation (often C2 preemption) |
| `%sys` / `%soft` per CPU | `mpstat -P ALL` sidecar | CPU spent in `%usr` (the app) | high `%soft` (softirq/packet processing) or `%sys` ⇒ CPU burned on network/kernel, not the app |

Enable the OS sidecars with `BENCH_OS_SIDECARS=1` (saga baseline); they write
`logs/target-*-pidstat.csv` and `logs/host-mpstat.csv`. High `%soft`/`%sys` is also
the first detector for the backend-networking fairness hole below.

### Differential flamegraph (on-demand, not always-on)

This is a diagnostic step, not a per-run metadata field. When `mpstat` shows high
`%sys`/`%soft`, or the numbers simply do not add up, capture an
[async-profiler](https://github.com/async-profiler/async-profiler) CPU profile and
**diff it against a known-clean run**. That is how you attribute the cost to a
specific cause (spin locks, `nft_do_chain`, `tcp_clean_rtx_queue`, …) rather than
guessing. Run it only when a signal above points at a problem; do not attach a
flamegraph to every run.

### Backend container networking is a fairness gate

When stateful backends (Postgres / Neo4j / Axon Server) run in containers, their
network mode is a **comparison fairness gate**, not hygiene. By default the target
JVM runs on the host network but the backends run bridged with published ports, so
every target↔backend packet crosses `docker-proxy`/NAT. That tax is **asymmetric**:
stacks differ in DB round-trips per request, so bridge/NAT lands unequally — and
proxy latency further reshapes connection-pool behaviour (waiters pile up, futex
churn). A bridged cross-stack comparison can therefore measure container networking
rather than the runtime.

Pin the mode explicitly with `DB_HOST_NETWORK=1` (or `BENCH_BACKEND_NETWORK=host`).
It layers the matching host-net compose override and the chosen mode is recorded in
`result.json` (`run_metadata.backend_network_mode` for the saga;
`run_config.backend_network_mode` for entity-read-by-id).

**Audit note (2026-06):** both cross-stack stacks support the toggle.
- `e2e-shop-order-saga` → `runtime/compose/e2e-shop-order-saga.host-net.yml`
  (Postgres + Neo4j + Axon). Cross-stack: exeris-community vs spring vs quarkus.
- `entity-read-by-id` → `runtime/compose/entity-read-by-id-db.host-net.yml`
  (Postgres). Also cross-stack — the campaign runs exeris-community vs spring vs
  quarkus against the same Postgres (`fixed_contract_cross_runtime_h1_v1`), so the
  bridge/NAT tax is asymmetric here too; default `bridge` must be switched to `host`
  for any published cross-stack comparison.

Default remains `bridge` (back-compatible); host mode is opt-in but **required** for
cross-stack claims.

### Ceilings that bound a result vs ceilings that replace it

Every rig has resources that can run out. They are not equivalent, and the distinction decides
what you may do with the run:

- A **bounding ceiling** limits the number. The database is the standard case: when Postgres
  saturates, throughput stops describing the stack and starts describing the database — but
  `cpu/req` still describes the stack, the run is still evidence, and the correct response is
  to declare the ceiling and switch comparator.
- An **invalidating ceiling** replaces the measured object. The **load generator** is the case
  that matters: a saturated driver means the number describes how fast the driver can *offer*
  requests, not how fast the target can *serve* them. No comparator survives this. There is no
  metric to fall back to, because the subject of the measurement changed. Discard the leaf.

This is why `tools/aggregate-db-cpuset-mpstat.sh` emits `loadgen_saturated_RESULT_INVALID`
rather than a descriptive label: the verdict is categorical, not a severity.

**Sample the generator, do not assume it.** Until 2026-08-07 nothing in this lab sampled the
load generator's own CPU, so "wrk was not the bottleneck" was an assumption underneath every
result rather than a measurement — and no earlier campaign can be retro-checked, because the
data was never captured. The first campaign that did sample it
(`20260808T065528Z-purenative-vs-quarkustuned-n3`) measured a median of **7.0 %** busy with a
maximum of **19.0 %** across 24 arm-windows, 24/24 with headroom. That closes the assumption
for that campaign only.

Rule: a runtime campaign records the load generator's cpuset utilisation alongside the target's
and the database's, and any window at or above 95 % is discarded rather than caveated.

### A confound excuses nothing until its SIGN is known

Magnitude alone never licenses setting a result aside. A confound larger than the effect but
pointing the *other way* does not obscure the effect — it **understates** it, and dismissing the
result on size is then exactly backwards.

The case that produced this rule: the Exeris arm was measured 3.7 % more expensive per request
than Quarkus, and the write-up declined to attribute that because serialisation differs
(Jackson 3 vs Jackson 2) and is roughly a fifth of on-CPU time — comfortably larger than 3.7 %.
Correct arithmetic, wrong method: nobody checked the direction. This lab's own
`JacksonVersionSerializationBenchmark` measures Jackson 3 at **15.77 µs/op against Jackson 2 at
17.78** on the identical payload — Jackson 3 is ~11 % *faster*. The arm with the faster
serialiser was still more expensive, so removing the confound **widens** the gap to ~6 %.

Rule: before a confound is used to qualify, weaken or set aside a result, state its **direction**
and the evidence for that direction. "Large enough to explain it" is not a finding; "large
enough and pointing the right way" is. When the direction is genuinely unknown, say that — an
unsigned confound bounds nothing in either direction, and it is not a licence to assume it
favours the reading you prefer.

This is the companion to *sample the generator, do not assume it*: both say do not assume what
you have not measured, in either direction.

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
| h2load (closed-loop, incl. `--log-file` percentiles) | ❌ YES | Throughput / saturation probes only; percentiles are queueing, not service-time tail |
| wrk2 with `-R` | ✅ NO | p99/p99.9 latency at declared load fraction |
| k6 `shared-iterations` / `ramping-vus` | ❌ YES | Throughput probes only |
| k6 `constant-arrival-rate` | ✅ NO | p99/p99.9 latency at declared arrival rate |
| JMH `Mode.SampleTime` | N/A (Micro) | Per-call cost distribution |

`co_corrected: true` in a result JSON is only meaningful alongside `r_value`, `observed_saturation_rps`, and `load_fraction`. A `load_fraction ≥ 0.95` means the measurement was at saturation — queuing delays are real, not CO artifacts, but do not represent nominal operating conditions.

### Latency on the h2c axis needs two experiments

h2load is the only driver here that speaks cleartext HTTP/2 (h2c), but it is
closed-loop and emits no percentiles. We therefore split latency from throughput:

1. **Throughput / CPU-efficiency (h2c, at saturation).** `run-entity-read-by-id.sh
   --driver h2load` runs h2load with `--log-file`; `tools/aggregate-h2load-latency.sh`
   reconstructs p50/p75/p90/p99/p99.9 from the per-request log into
   `h2load-latency.json` and into `result.json` metrics. **These percentiles carry a
   coordinated-omission caveat** (stamped `co_caveat` in the sidecar): under
   saturation they track queueing (≈ concurrency ÷ throughput, Little's law), not the
   service-time tail. Use them to rank-order, not as nominal latency.
2. **CO-free tail latency (H1, below saturation).** `scripts/run-wrk2.sh` drives a
   fixed arrival rate (`-R`) with HdrHistogram percentiles. This is the trustworthy
   p99/p99.9 source — but on the HTTP/1.1 axis (wrk2 has no h2c). State the protocol
   difference when placing wrk2 latency next to h2load throughput.

The primary Exeris differentiator on these runs is **resource usage per request
(CPU/req, RSS), not rps or latency** — at saturation both are bottleneck-shaped and
warmup-sensitive, while CPU/req is stable across warmup and the cleaner signal.

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

### An error budget needs a scope, or it misleads in both directions

A tolerance you cannot re-derive is the same defect as a result you cannot re-derive — it just
hides one level down, in the yardstick instead of in the measurement. Two rules follow.

**1. A fence is not a budget row.** A *fence* says a comparison is invalid; a *budget* says a
valid comparison is not resolving anything. Crossing a fence does not widen an error bar, it voids
the result, so a fence must never appear as a budget line where it reads as absorbable.
`scripts/compare-results.sh` enforces two — `backend_network_mode` and `db_cpuset` — by refusing
the comparison outright.

**2. State the layer the budget belongs to.** Run-to-run variance is layered, and the layers
differ by more than an order of magnitude in what they admit:

| layer | what varies | typical error if misapplied |
|---|---|---|
| ab vs ba inside one repeat | position in a counterbalanced sequence — **same JVM instances**, one warmup, one JIT state | **under-states**: omits restart variance entirely |
| repeat | a full teardown and relaunch, direction held fixed | the applicable layer for "would this recur from scratch" |
| an incomplete repeat | a smaller sample wearing a repeat's label | **over-states** |
| a cross-campaign envelope imported from another configuration | conditions that are not present | **over-states**: can declare a resolvable effect unresolvable |

Combine independent layers **in quadrature, not by summing**, and report the combination per
contract — variance is not contract-independent, and a single pooled number will typically
over-state the heavy contract while under-stating the light one.

**Resolving power is arithmetic, not preference.** Whether a contract can measure an effect is the
ratio of the effect to *that layer's* variance, not the repeat count. An effect that is 1 % of a
heavy baseline and 20 % of a light one is unresolvable on heavy at any n, and settled on light at
n=3.

**A bound must be the one measured on the axis being claimed.** A cpu/req budget does not transfer
to throughput (which a DB ceiling can bound independently) and emphatically not to percentiles.
Measured on one runtime-snapshot pair in the `entity-read-by-id` series: cpu/req moved 0.20 % while
p99 moved 16.9 % — an 83× sensitivity gap — on the light contract, against 2.1× on heavy.

`tools/derive-error-budget.sh` computes both layers per contract from committed campaign
artefacts; run it rather than quoting a budget forward. Worked example and the full
retired-vs-derived comparison:
[`results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md` §2](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md).

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

---

## Comparative Hard Gates (Phase 1)

Comparative runtime runs are now fail-closed. Comparative math and claim artifacts are blocked unless all strict gates pass.

Required gates:

1. `G1 track_isolation`: `run_config.track_id` must be present on both sides and identical. Track R and Track N cannot mix.
2. `G2 eligibility`: only rows with `claim_scope=comparison_eligible`, `runner_status=success`, `reproducibility_status=complete`, `final_reason=ok` are eligible.
3. `G3 equivalence_strict`: hard-equal checks on scenario, contract, tier, protocol, mode, payload descriptor, concurrency, warmup/measurement windows, and JVM class.
4. `G4 ab_ba_required`: directional completion evidence is mandatory (`run_config.pair_completion_evidence.*` must match `pair_order` and include completion marker), and `run_config.ab_ba_orders_completed` must include the invocation order for the same `pair_id`.
5. `G5 drift_placeholder`: drift snapshot metadata is mandatory and fails if observed drift
   exceeds configured thresholds. **Vacuous as currently wired — do not count it as a
   load-bearing gate (verified 2026-08-11).** The comparison is real code, but the *observed*
   values come from `BENCHMARK_DRIFT_OBS_LATENCY_PCT` / `BENCHMARK_DRIFT_OBS_THROUGHPUT_PCT`,
   which nothing in the harness populates, and the thresholds from
   `BENCHMARK_DRIFT_MAX_*_PCT`; all four default to `0`. Every leaf of every campaign therefore
   evaluates `0 ≤ 0` and passes. The gate proves the field is present, not that drift is bounded.
   A "10/10 gates passed" summary is really nine. Either wire an observed value or retire the
   gate — leaving it passing is worse than either, because it inflates the count.
6. `G6 metadata_completeness`: commit SHA, JDK/tool versions, JVM flags, hardware profile, scenario id, and target classification are mandatory.
7. `G7 pin_verification`: pinned versions in run config must be present and match actual versions exactly.
8. `G8 schema_validation`: artifact schema validation is required and fail-closed if validator support is unavailable.
9. `G9 quarantine_transparency`: rejected runs must emit machine-readable rejection codes.
10. `G10 reporting_guard`: report must include explicit axis labels and `track_id`, and must not contain cross-track claim text.

Operational behavior:

- If strict gates fail, run is marked `claim_status=non_eligible` and comparative claim artifact generation is blocked.
- Rejection reason codes are emitted for machine processing in gate summary / rejection-code artifacts.
- No comparisons are interpreted across track boundaries.
| comparative claims | permitted when axes and equivalence match | disallowed |

## Report Intake: Hypothesis-to-Scenario Mapping (Java 26+)

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

### Intake rules

- Every mapped run must preserve one primary comparison axis.
- Match payload/concurrency/protocol before comparative claims.
- Capture commit SHA, JDK/tool versions, JVM flags, hardware profile.
- Label protocol/family (and target classification when applicable) in every artifact.
- If equivalence missing, publish as exploratory only.
- Avoid enterprise-sensitive raw traces in public artifacts.
- Community-vs-enterprise comparative claims are out of scope for this repository publication track.
