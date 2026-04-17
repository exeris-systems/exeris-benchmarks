# TLS Zero-Copy Benchmark Matrix

This document defines a scoped TLS matrix for zero-copy and lifecycle coverage.
It uses explicit labels and bounded claims across four families: A/B/C/D.

> **Scope and governance.** This matrix is governed by the general rules in
> [benchmark-philosophy.md](benchmark-philosophy.md),
> [methodology.md](methodology.md),
> [result-interpretation.md](result-interpretation.md), and
> [comparative-readiness-checklist.md](comparative-readiness-checklist.md).
> General benchmark program rules (fairness, reproducibility, claim-eligibility)
> are not repeated here; consult those documents.
>
> **Architecture disclaimer.** Labels in this matrix describe benchmark harness
> contracts and measurement lenses only. They do not describe or imply complete
> product implementation architecture. The presence of a benchmark artifact does
> not constitute a statement about internal product design.
>
> **Active publication scope.** Public/claim documentation in this repository
> is limited to benchmarks implemented and runnable in this repository scope.
> External tracks may remain as runner-compatibility placeholders but are
> excluded from public claim interpretation.

## Required Labels

Every matrix row and output status row must carry:

- `harness_model`: `external-baseline`, `core-engine`, `fd-owner`, `memory-bio`, or `runtime-harness`
  - `external-baseline` — third-party reference implementation (JDK SSLEngine, Netty tcnative)
  - `core-engine` — engine-level benchmark with no full transport wiring (guard paths, state-machine, core JMH)
  - `fd-owner` — real loopback socket with kernel I/O crossing
  - `memory-bio` — in-process inject/drain, no socket, no syscall
  - `runtime-harness` — full runtime harness integration probe
- `protocol_mode`: `tcp-tls-1.3`
- `benchmark_family`: `A`, `B`, `C`, or `D`
- `comparison_axis`: `within-tier`, `cross-transport-model`, or `implementation-variant`

> **Note on `tier`.** The standard `target.tier` field is optional
> from the TLS micro matrix because `OffHeapTlsEngine` is a tier-agnostic engine —
> its harness configuration (transport model + allocator behavior) is the meaningful
> separation axis here, not the product edition. `tier` may be retained as an optional
> secondary annotation only for artifacts unambiguously scoped to a single product
> module.

## Primary Comparative Set (Publication / Decision-Making)

For TCP TLS 1.3 record-path analysis, the primary engine-level comparator set is B3/B4/B5.
Use B6 as an integration-level lens. Keep these layers separated in reporting and
carry explicit transport and wiring labels for every row.

| Matrix ID | Benchmark | Transport Model | Buffer Model | Allocator Model | Primary Use |
|---|---|---|---|---|---|
| B3 | `SslEngineTlsBenchmark` | in-memory `ByteBuffer` (no socket, no syscall) | JVM heap `ByteBuffer` | JVM GC-managed heap | external baseline — pure crypto cost, no I/O |
| B4 | `NettyTcNativeTlsBenchmark` | `EmbeddedChannel` in-memory pipeline (no socket, no syscall) | Netty pooled direct `ByteBuf` | `PooledByteBufAllocator` (Netty) | external baseline — pipeline + pooling cost |
| B5 | `OffHeapTlsEngineMemoryBioBenchmark` | neutral in-process Memory-BIO engine-level lens, no socket, no syscall | off-heap `LoanedBuffer` | off-heap allocator (Memory-BIO lens) | Exeris OffHeapTlsEngine in-process Memory-BIO lens — not equivalent to FD-owner integration path |
| B6 | `ExerisCommunityTlsBenchmark` | FD-owner real loopback socket, `write(2)` kernel crossing per record | off-heap `LoanedBuffer` | off-heap allocator (FD-owner harness) | FD-owner integration lens — real loopback socket with kernel crossing |

Cross-row conclusions in this set must preserve transport-model differences and
must not flatten FD-owner socket and Memory-BIO paths into a single equivalence claim.

### Memory and Allocator Model Differences

Each benchmark in the B3/B4/B5/B6 set operates under a distinct memory and
allocator contract. These differences are structural, not incidental, and must
be preserved in all cross-row comparisons.

| Matrix ID | Buffer type | Allocator lifecycle |
|---|---|---|
| B3 | JVM heap `ByteBuffer` | GC-managed; allocation/reclaim is implicit |
| B4 | Netty pooled direct `ByteBuf` | `PooledByteBufAllocator`; thread-local arenas, ref-counted reclaim |
| B5 | off-heap `LoanedBuffer` | off-heap allocator; in-process Memory-BIO benchmark harness |
| B6 | off-heap `LoanedBuffer` | off-heap allocator; FD-owner benchmark harness |

**What these differences mean for interpretation:**

- B3 includes GC pressure from heap `ByteBuffer` churn. A lower `gc.alloc.rate.norm` in B6 vs B3 reflects allocator strategy, not only crypto engine efficiency.
- B4 pool overhead (arena management, ref-count paths) contributes to its CPU profile. Differences vs B3 are pipeline + pooling cost, not crypto cost alone.
- B5 is an in-process Memory-BIO engine-level lens. It is useful for scoped engine analysis but is not directly equivalent to B6's FD-owner/socket integration path.
- B6 vs B5 differs in transport boundary (FD-owner socket vs Memory-BIO). The delta cannot be attributed solely to engine cost and includes harness-level effects.

**Valid claims from this set:**
- Each benchmark row measures the TLS record-path cost under its full native implementation contract (transport + allocator combined).
- Cross-row throughput differences represent combined transport and allocator model effects, not isolated crypto engine speed.
- Within-row comparisons across payload sizes are valid as single-implementation scaling measurements.

**Invalid claims without additional isolation evidence:**
- "B6 vs B5 isolates the Memory-BIO benefit."
- "B3 vs B6 isolates the JDK SSLEngine vs community OpenSSL crypto performance."
- "B5 is a drop-in equivalent replacement for B6 FD-owner integration measurements."

> **B6 vs B5 direct comparison is confounded.**
> Transport model (FD-owner socket vs Memory-BIO) and other harness-level effects
> vary simultaneously in the benchmark contracts.
> Any claim about B6-vs-B5 performance difference must explicitly acknowledge
> both axes. Attribution to either axis alone is not supported by this benchmark design.

## Comparative Reporting Metrics (Mandatory for B3/B4/B5/B6)

- JMH throughput (ops/s)
- JMH sample-time latency (us/op with p50/p95/p99 where available)
- heap allocation (`gc.alloc.rate.norm`)
- JFR allocation evidence (`ObjectAllocationSample` stacks)
- CPU hotspot profile (top methods / percent)
- RSS and native footprint snapshot
- native footprint setup delta: RSS at trial @Setup completion vs RSS at measurement end
- allocator model label per row (GC-managed / pooled-direct / off-heap)
- explicit buffer model, transport model, and allocator model labels (all three required per row)

Publication-grade conclusions require all dimensions above, or an explicit
missing-data caveat for each absent dimension.

## MUST / SHOULD / STRETCH Matrix

| Matrix ID | Priority | Harness Model | Protocol Mode | Benchmark Family | Comparison Axis | Intent | Artifact Type | Status | Publication Ready |
|---|---|---|---|---|---|---|---|---|---|
| B1 | MUST | core-engine | tcp-tls-1.3 | B | within-tier | Core off-heap TLS engine micro benchmark | jmh_micro | implemented | publishable |
| B2 | MUST | core-engine | tcp-tls-1.3 | B | within-tier | Core TLS state-machine micro benchmark | jmh_micro | implemented | publishable |
| B3 | SHOULD | external-baseline | tcp-tls-1.3 | B | implementation-variant | Comparative record-path benchmark vs JDK SSLEngine | jmh_comparative | implemented | publishable |
| B4 | SHOULD | external-baseline | tcp-tls-1.3 | B | implementation-variant | Comparative Netty TLS pipeline benchmark via netty-tcnative `SslHandler` + `EmbeddedChannel` | jmh_comparative | implemented | needs-validation |
| B5g | SHOULD | core-engine | tcp-tls-1.3 | B | within-tier | TLS wrapper guard micro benchmark (Community scope) | jmh_micro | implemented | partial |
| B6 | SHOULD | fd-owner | tcp-tls-1.3 | B | implementation-variant | Comparative record-path benchmark via Exeris SPI-native `TlsEngine` — FD-owner/socket harness (`SSL_set_fd`, real loopback socket; `wrapThroughput` only) | jmh_comparative | implemented | needs-validation |
| B5 | SHOULD | memory-bio | tcp-tls-1.3 | B | implementation-variant | OffHeapTlsEngine engine-level lens via neutral in-process Memory-BIO harness; not equivalent to FD-owner integration path | jmh_comparative | implemented | needs-validation |
| D3 | SHOULD | fd-owner | tcp-tls-1.3 | D | implementation-variant | FD-owner loopback handshake comparative benchmark | jmh_comparative | planned | blocked-pr-60 |
| D4 | STRETCH | runtime-harness | tcp-tls-1.3 | D | cross-transport-model | Lifecycle probes integrated under `exeris-benchmarks` runtime harness | runtime_probe | stretch | blocked |

## Mapping IDs to Existing Implemented Artifacts

| Matrix ID | Implemented Artifact | Workspace Path |
|---|---|---|
| B1 | `CoreOffHeapTlsEngineBenchmark` | `exeris-kernel/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/CoreOffHeapTlsEngineBenchmark.java` |
| B2 | `CoreTlsStateMachineBenchmark` | `exeris-kernel/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/CoreTlsStateMachineBenchmark.java` |
| B3 | `SslEngineTlsBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/SslEngineTlsBenchmark.java` |
| B4 | `NettyTcNativeTlsBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/NettyTcNativeTlsBenchmark.java` |
| B5g | `CommunityTlsEngineGuardBenchmark` | `exeris-kernel/exeris-kernel-community/src/test/java/eu/exeris/kernel/community/crypto/CommunityTlsEngineGuardBenchmark.java` |
| B6 | `ExerisCommunityTlsBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/ExerisCommunityTlsBenchmark.java` |
| B5 | `OffHeapTlsEngineMemoryBioBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/OffHeapTlsEngineMemoryBioBenchmark.java` |

## Artifact Type Reference

Every matrix entry is classified by the type of artifact it tests:

| Type | Definition | Merge-Gate Use | Baseline Use | Notes |
|---|---|---|---|---|
| **guard_tck** | Contract/invariant test (TCK, merge-gate assertion) | ✓ Always | ✗ Not publishable | Lives in product repos as pre-commit gate; measures guard correctness, not speed |
| **jmh_micro** | Isolated hot-path microbenchmark via JMH | ✗ (Indirect) | ✓ Yes | Central artifact for trend tracking; runs in isolation; steady-state only |
| **jmh_comparative** | Comparative microbench (Exeris vs third-party baseline) | ✗ | ✓ Yes | Establishes relative performance; requires equivalent configuration fairness |
| **integration_probe** | Loopback or in-process lifecycle sequence | ✗ (Diagnostic) | ✗ Not publishable | Validates integration paths; diagnosable only; not steady-state baseline material |
| **loopback_it** | JUnit integration test with loopback sockets | ✗ (Correctness) | ✗ Not publishable | Correctness focus; may capture latency distribution for monitoring only |
| **runtime_probe** | Runtime harness scenario probe (wrk/k6/Hyperfoil) | ✗ | ✗ Depends | Measures full-stack; not publishable until harness stabilizes |

---

## Publication Eligibility Guidance

### Publishable (ready for baselines, articles, comparative claims)
- ✅ `jmh_micro` (B1, B2)
- ✅ `jmh_comparative` (B3)
- ✅ Artifacts marked `status: implemented` AND `publication_ready: publishable`
- Require: ≥3 forks, 99% CI on perf-box-amd64, methodology compliance

### Internal-Only (merge-gate, diagnostics, not for public claims)
- 🔒 `guard_tck` entries are out of scope for this repository publication track
- 🔒 `integration_probe` and `loopback_it` entries are out of scope for this repository publication track
- May be referenced internally; no absolute numbers in public docs

### Needs Validation Before Publication
- ⚠️ `B4` (tcnative/Netty pipeline): publication needs explicit caveats for pooled `ByteBuf` policy and handler/channel wiring vs B3's direct `SSLEngine` harness
 - ⚠️ `B5`/`B6`: publication requires all mandatory comparative evidence dimensions (see Comparative Reporting Metrics) plus explicit caveats:
  - **Transport model difference:** B6 uses FD-owner real loopback socket with `write(2)` kernel crossing per TLS record. B5 uses in-process Memory-BIO with no socket and no syscall.
  - **B5 scope caveat:** B5 is an engine-level in-process Memory-BIO lens and is not equivalent to B6 FD-owner/socket integration path.
  - **Harness-model caveat:** B6 and B5 use different harness boundaries and wiring contracts. Any published comparison must carry explicit caveats for these boundary differences.
  - **Publication guard:** B5 results published using functional measurement labels only. No internal class names, allocation strategy parameters, or native implementation details in public artifacts.
- ⚠️ `B5` (partial): Methods `guardCost`, `wrapThroughput` are publishable; 
  `fullRoundTripWrapUnwrapCost` needs semantic validation

### Blocked or Deferred
- ❌ `D3`: Blocked on exeris-kernel PR #60
- ❌ `D4`: Awaiting runtime harness integration in exeris-benchmarks

---

## Appendix B: B5g (CommunityTlsEngineGuardBenchmark) — Method-Level Breakdown

This benchmark class contains multiple methods with different publication status:

| Method | Pattern | Status | Publishable |
|---|---|---|---|
| `guardCheckWrapCost` | Pattern A (guard-path check) | implemented | ✓ internal-only |
| `guardCheckUnwrapCost` | Pattern A (guard-path check) | implemented | ✓ internal-only |
| `beginHandshakeWithoutBindGuardCost` | Pattern A (guard gate) | implemented | ✓ internal-only |
| `wrapWithoutBindGuardCost` | Pattern A (guard gate) | implemented | ✓ internal-only |
| `unwrapWithoutBindGuardCost` | Pattern A (guard gate) | implemented | ✓ internal-only |

All methods in B5g measure **guard-path sentinels and error checks**, not steady-state throughput.
They are suitable only for merge-gate invariants and internal diagnostic reports, not for 
comparative baseline claims against other libraries.

For Community steady-state wrap/unwrap throughput comparable to B1/B5, use `B3` (JDK reference)
or dedicated Community record-path benchmarks when implemented.

## Appendix A: B5/B6 Benchmark Harness Contract Notes

> These notes describe observable benchmark harness contracts and measurement
> scope boundaries. They do not disclose or imply internal product architecture.

- B6 benchmark harness contract: FD-owner transport — real loopback socket,
  fd bound before handshake, virtual-thread-driven handshake, persistent drain
  thread during `wrapThroughput` measurement. Exposed method: `wrapThroughput`.
- B5 benchmark harness contract: in-process Memory-BIO transport — in-process
  inject/drain loops, no socket, no syscall. Exposed methods are benchmark-specific
  to the engine-level lens.
- Off-heap buffer allocation in both harnesses occurs through `MemoryProvider` +
  `MemoryAllocator`. The key reporting distinction is harness boundary
  (FD-owner/socket vs in-process Memory-BIO).
- Cross-transport caveat (mandatory): B6 `wrapThroughput` includes kernel
  `write(2)` crossing; B5 memory-bio measurements do not. Report cross-transport TLS
  numbers only with explicit transport-model labels: "including kernel I/O"
  vs "excluding kernel I/O".
- If required classes or cert/key inputs are missing, matrix execution must emit
  `SKIPPED_MISSING_IMPLEMENTATION` for B6/B5.

---

## TLS Benchmark Methodology Notes

This section documents TLS-specific patterns and fairness rules that apply across the matrix.

### Handshake vs Steady-State Record-Path

TLS benchmarks measure two distinct cost centers:

#### Handshake / Session Initialization (D3 planned, D4 stretch)
- **Pattern**: Fresh engine per invocation (`@Setup(Level.Invocation)`)
- **Scope**: Full TLS session establishment from initial connection through ACTIVE state
- **Cost centers**: SSL_connect / SSL_accept FFM calls, phase state transitions, BIO setup
- **Typical window**: 1–10 ms per handshake (platform/hardware dependent)
- **Metric**: Throughput (sessions/s) or SampleTime (p50/p99 latency)
- **Use case**: Connection pool overhead, load-balancer acceptance rate, proxy throughput

#### Steady-State Record Path (B1, B2, B3, B4, B5)
- **Pattern**: Engine reuse per trial (`@Setup(Level.Trial)`) after handshake completion
- **Scope**: Repeated wrap (encrypt) and unwrap (decrypt) on ACTIVE engines
- **Cost centers**: SSL_write / SSL_read FFM calls only, no state transitions
- **Typical window**: 1–10 µs per operation (platform/hardware dependent)
- **Metric**: Throughput (ops/s) or SampleTime (µs latency)
- **Use case**: Steady-state request/response throughput, encryption latency tail

For B4 specifically, the ACTIVE path is exercised through Netty `SslHandler` and `EmbeddedChannel` with pooled `ByteBuf`s rather than through raw `SSLEngine.wrap/unwrap` calls.

### SSLEngine Reuse and State Management

**Rule: Do not mix lifecycle phases within a single benchmark method.**

- **Pattern A (Handshake)**: Create engine, drive handshake, measure setup cost → destroy
- **Pattern B (Steady-State)**: Create engine once per trial, drive handshake in @Setup, 
  measure multiple wrap/unwrap calls in each method invocation on ACTIVE engine → destroy at trial end

Mixing patterns (e.g., reusing an engine that's still in HANDSHAKE_IN_PROGRESS) introduces:
- Measurement noise (setup cost leaks into measurement)
- State machine unpredictability (incomplete transitions)
- JFR/profiler signal degradation

### Buffer Allocation Fairness

When comparing implementations (B3 vs B4, or future B1 vs competing libraries):

#### Heap vs Direct ByteBuffer
- Document buffer allocation strategy: heap, direct, pooled direct, or mixed
- Normalize comparisons: if B3 uses heap/direct `ByteBuffer` and B4 uses pooled direct `ByteBuf`, report the wiring difference explicitly rather than flattening the numbers into a single claim
- JVM flag impact: `-XX:+UseZGC` vs G1GC affects buffer pooling; note in metadata

#### Off-Heap vs On-Heap Allocation
- Exeris engines (B5/B6): operate on MemorySegment (off-heap, zero heap allocation in steady state under benchmark harness contract)
- JDK SSLEngine (B3): operates on ByteBuffer (may allocate on heap during wrap/unwrap)
- Tcnative/Netty pipeline (B4): operates on pooled direct `ByteBuf` and handler/channel glue backed by JNI/native OpenSSL state
- **Claim rule**: If claiming "zero-allocation" on wrap/unwrap, must measure steady-state heap allocation 
  via `-prof gc` and confirm `gc.alloc.rate.norm ≈ 0 B/op`; JFR allocation stacks must show no 
  heap allocation in success path (guard-path evidence is outside this repository scope)

### Zero-Allocation Evidence Layers

Zero-allocation claims in Exeris require three separate evidence types:

1. **Guard path (external tests)**: JFR allocation gates, sentinel probes, TCK invariants
  - Measures: Throw-and-catch cost of pre-allocated sentinels when engine is in HANDSHAKE_IN_PROGRESS
  - Evidence: `jdk.ObjectAllocationSample` events (should be ≈0)
  - Use: Merge-gate internal-only check

2. **Steady-state path (B1/B5)**: JMH `-prof gc` allocation tracking
   - Measures: wrap/unwrap on ACTIVE engine, post-handshake
   - Evidence: `gc.alloc.rate.norm` in microseconds-per-operation baseline
   - Use: Publication-grade claim with `-prof gc` profiler

3. **Integration path (external probes)**: Loopback lifetime allocation
   - Measures: Complete handshake + multiple record exchanges
   - Evidence: JFR allocation events across full session lifecycle
   - Use: Diagnostic, not publication-grade

**Do not claim zero-allocation from any single layer alone.** 
All three must pass for a complete zero-allocation story.

### Fairness Rules for Comparative Benchmarks (B3, B4, D3)

When establishing performance comparisons:

#### Protocol and Handshake Equivalence
- ✅ All implementations tested must use **identical TLS version** (1.3 for matrix rows)
- ✅ Cipher suite must be equivalent (e.g., TLS_AES_256_GCM_SHA384)
- ✅ All implementations must complete handshake before measurement window
- ❌ Do not compare pre-handshake and post-handshake costs in the same row

#### Payload and Concurrency
- ✅ Payload sizes swept: 128 B, 1 KB, 4 KB, 16 KB (TLS record max)
- ✅ Concurrency kept constant: typically 1 (single thread per benchmark) for micro, 
  or explicit thread count for runtime
- ✅ If comparing via runtime harness (future D3/D4), match concurrency/RPS targets across implementations

#### Profiling and Environment
- ✅ Same JVM flags (`-XX:+UseZGC`, heap size, etc.) for all implementations in a row
- ✅ Same warmup (5 × 2s) and measurement (10 × 2s / or benchmark-specific) windows
- ✅ Same JVM process isolation (forks) parameter; baseline requires ≥2 forks
- ✅ Hardware profile must be named and consistent (perf-box-amd64 for published baselines)

#### Caveats in Results
Mark comparative results with:
- Implementation names (JDK SSLEngine, tcnative BoringSSL, Exeris OffHeapTlsEngine)
- Wiring model (direct engine harness vs Netty `SslHandler`/`EmbeddedChannel` pipeline)
- Buffer types (heap ByteBuffer, direct ByteBuffer, MemorySegment)
- TLS version, cipher suite
- JVM version, target JDK flags
- Hardware profile

---

## MISSING_IMPLEMENTATION

The following IDs must be emitted as `SKIPPED_MISSING_IMPLEMENTATION` when not available:

- `D3`: Community loopback handshake comparative benchmark — blocked on PR #60 (`33-featcommunity-crypto-tls-engine`).
- `D4`: Lifecycle probes not yet implemented inside `exeris-benchmarks` runtime scenarios/harness.

## Repro Metadata Checklist

Every run must capture:

- commit SHA for active scope repos: `exeris-benchmarks`, `exeris-kernel`
- JDK/tool versions
- JVM flags
- hardware profile
- scenario id / target classification for each matrix row

## Output Artifact Layout

Write outputs under:

`results/raw/tls-matrix/<timestamp>/`

Expected structure:

```text
results/raw/tls-matrix/<timestamp>/
  env.json
  metadata.json
  status.csv
  commands.log
  logs/
    B1.log
    B2.log
    B5.log
```

JFR recordings (when `JFR_PROF=1`):

```text
results/raw/tls-matrix/<timestamp>/
  jfr/
    B1/   ← CoreOffHeapTlsEngineBenchmark JFR recording (-Dbenchmark.jvmArgs)
    B2/   ← CoreTlsStateMachineBenchmark JFR recording (-Dbenchmark.jvmArgs)
    B3/   ← SslEngineTlsBenchmark JFR recording (JMH -prof jfr)
    B4/   ← NettyTcNativeTlsBenchmark JFR recording (JMH -prof jfr)
```

- B3, B4: recorded via JMH `-prof jfr` profiler plugin.
- B1, B2, B5: recorded via Maven benchmark profile `-Dbenchmark.jvmArgs=-XX:StartFlightRecording=...`.

JFR files contain `jdk.ObjectAllocationSample` + `jdk.ObjectAllocationInNewTLAB` events.
Use `jfr print --events jdk.ObjectAllocationSample <file>.jfr` to extract allocation stacks per benchmark.

`status.csv` must include labels: `tier`, `protocol_mode`, `benchmark_family`, `comparison_axis`.
