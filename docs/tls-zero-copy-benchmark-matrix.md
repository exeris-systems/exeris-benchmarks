# TLS Zero-Copy Benchmark Matrix

This document defines a scoped TLS matrix for zero-copy and lifecycle coverage.
It uses explicit labels and bounded claims across four families: A/B/C/D.

## Required Labels

Every matrix row and output status row must carry:

- `tier`: `community` or `enterprise`
- `protocol_mode`: `tcp-tls-1.3`
- `benchmark_family`: `A`, `B`, `C`, or `D`
- `comparison_axis`: `within-tier`, `cross-tier-same-protocol`, or `implementation-variant`

Do not collapse conclusions across these labels without explicit caveats.

## Primary Comparative Set (Publication / Decision-Making)

For TCP TLS 1.3 record-path analysis, the primary engine-level comparator set is B3/B4/B5.
Use B6/B7 as integration-level lenses. Keep these layers separated in reporting and
carry explicit transport and wiring labels for every row.

| Matrix ID | Benchmark | Transport Model | Buffer Model | Allocator Model | Primary Use |
|---|---|---|---|---|---|
| B3 | `SslEngineTlsBenchmark` | in-memory `ByteBuffer` (no socket, no syscall) | JVM heap `ByteBuffer` | JVM GC-managed heap | external baseline — pure crypto cost, no I/O |
| B4 | `NettyTcNativeTlsBenchmark` | `EmbeddedChannel` in-memory pipeline (no socket, no syscall) | Netty pooled direct `ByteBuf` | `PooledByteBufAllocator` (Netty) | external baseline — pipeline + pooling cost |
| B5 | `OffHeapTlsEngineMemoryBioBenchmark` | neutral in-process Memory-BIO engine-level lens, no socket, no syscall | off-heap `LoanedBuffer` (enterprise allocator, pre-reservation model) | enterprise `MemoryAllocator` (pre-reservation) | Exeris OffHeapTlsEngine engine-level lens (not equivalent to FD-owner path) |
| B6 | `ExerisCommunityTlsBenchmark` | FD-owner real loopback socket, `write(2)` kernel crossing per record | off-heap `LoanedBuffer` (community allocator, on-demand) | community `MemoryAllocator` (on-demand) | Exeris Community natural transport + memory contract |
| B7 | `ExerisEnterpriseTlsBenchmark` | Memory-BIO in-process inject/drain, no socket, no syscall | off-heap `LoanedBuffer` (enterprise allocator, pre-reservation model) | enterprise `MemoryAllocator` (pre-reservation) | Exeris Enterprise natural transport + memory contract |

Cross-row conclusions in this set must preserve transport-model differences and
must not flatten FD-owner socket and Memory-BIO paths into a single equivalence claim.

### Memory and Allocator Model Differences

Each benchmark in the B3/B4/B5/B6/B7 set operates under a distinct memory and
allocator contract. These differences are structural, not incidental, and must
be preserved in all cross-row comparisons.

| Matrix ID | Buffer type | Allocator lifecycle |
|---|---|---|
| B3 | JVM heap `ByteBuffer` | GC-managed; allocation/reclaim is implicit |
| B4 | Netty pooled direct `ByteBuf` | `PooledByteBufAllocator`; thread-local arenas, ref-counted reclaim |
| B5 | off-heap `LoanedBuffer` | enterprise allocator; in-process Memory-BIO engine lens |
| B6 | off-heap `LoanedBuffer` | community allocator; buffers allocated on-demand per trial |
| B7 | off-heap `LoanedBuffer` | enterprise allocator; buffers provided under a pre-reservation model |

**What these differences mean for interpretation:**

- B3 includes GC pressure from heap `ByteBuffer` churn. A lower `gc.alloc.rate.norm` in B6 or B7 vs B3 reflects allocator strategy, not only crypto engine efficiency.
- B4 pool overhead (arena management, ref-count paths) contributes to its CPU profile. Differences vs B3 are pipeline + pooling cost, not crypto cost alone.
- B5 is an in-process Memory-BIO engine-level lens. It is useful for scoped engine analysis but is not directly equivalent to B6's FD-owner/socket integration path.
- B6 vs B7 differs in both transport model (FD-owner socket vs Memory-BIO) AND allocator model (on-demand vs pre-reservation). **The delta between B6 and B7 cannot be attributed solely to the transport boundary cost.**

**Valid claims from this set:**
- Each benchmark row measures the TLS record-path cost under its full native implementation contract (transport + allocator combined).
- Cross-row throughput differences represent combined transport and allocator model effects, not isolated crypto engine speed.
- Within-row comparisons across payload sizes are valid as single-implementation scaling measurements.

**Invalid claims without additional isolation evidence:**
- "Enterprise is faster than Community due to transport model alone."
- "B7 vs B6 isolates the Memory-BIO benefit."
- "B3 vs B6 isolates the JDK SSLEngine vs community OpenSSL crypto performance."
- "B5 is a drop-in equivalent replacement for B6 FD-owner integration measurements."

> **B6 vs B7 direct comparison is dual-axis confounded.**
> Transport model (FD-owner socket vs Memory-BIO) and allocator model
> (community on-demand vs enterprise pre-reservation) vary simultaneously.
> Any claim about B6-vs-B7 performance difference must explicitly acknowledge
> both axes. Attribution to either axis alone is not supported by this benchmark design.

## Comparative Reporting Metrics (Mandatory for B3/B4/B5/B6/B7)

- JMH throughput (ops/s)
- JMH sample-time latency (us/op with p50/p95/p99 where available)
- heap allocation (`gc.alloc.rate.norm`)
- JFR allocation evidence (`ObjectAllocationSample` stacks)
- CPU hotspot profile (top methods / percent)
- RSS and native footprint snapshot
- native footprint pre-reservation delta: RSS at trial @Setup completion vs RSS at measurement end
- allocator model label per row (GC-managed / pooled-direct / on-demand off-heap / pre-reservation off-heap)
- explicit buffer model, transport model, and allocator model labels (all three required per row)

Publication-grade conclusions require all dimensions above, or an explicit
missing-data caveat for each absent dimension.

## MUST / SHOULD / STRETCH Matrix

| Matrix ID | Priority | Tier | Protocol Mode | Benchmark Family | Comparison Axis | Intent | Artifact Type | Status | Publication Ready |
|---|---|---|---|---|---|---|---|---|---|
| A1 | MUST | community | tcp-tls-1.3 | A | within-tier | Zero-allocation guard contract check | guard_tck | implemented | internal-only |
| A2 | MUST | community | tcp-tls-1.3 | A | within-tier | Zero-allocation guard repeatability check | guard_tck | implemented | internal-only |
| B1 | MUST | community | tcp-tls-1.3 | B | within-tier | Core off-heap TLS engine micro benchmark | jmh_micro | implemented | publishable |
| B2 | MUST | community | tcp-tls-1.3 | B | within-tier | Core TLS state-machine micro benchmark | jmh_micro | implemented | publishable |
| B3 | SHOULD | community | tcp-tls-1.3 | B | implementation-variant | Comparative record-path benchmark vs JDK SSLEngine | jmh_comparative | implemented | publishable |
| B4 | SHOULD | community | tcp-tls-1.3 | B | implementation-variant | Comparative Netty TLS pipeline benchmark via netty-tcnative `SslHandler` + `EmbeddedChannel` | jmh_comparative | implemented | needs-validation |
| B5g | SHOULD | community | tcp-tls-1.3 | B | within-tier | Community TLS wrapper guard micro benchmark | jmh_micro | implemented | partial |
| B6 | SHOULD | community | tcp-tls-1.3 | B | implementation-variant | Comparative record-path benchmark via Exeris SPI-native `TlsEngine` using split Community FD-owner/socket harness (`SSL_set_fd`, real loopback socket; `wrapThroughput` only) | jmh_comparative | implemented | needs-validation |
| B7 | SHOULD | enterprise | tcp-tls-1.3 | B | implementation-variant | Comparative record-path benchmark via Exeris SPI-native `TlsEngine` using split Enterprise Memory-BIO harness (in-process inject/drain; `wrapThroughput` + `wrapUnwrapRoundTrip`) | jmh_comparative | implemented | needs-validation |
| B5 | SHOULD | enterprise | tcp-tls-1.3 | B | implementation-variant | OffHeapTlsEngine engine-level lens via neutral in-process Memory-BIO harness; not equivalent to FD-owner integration path | jmh_comparative | implemented | needs-validation |
| C4 | MUST | enterprise | tcp-tls-1.3 | C | within-tier | Enterprise TLS engine benchmark | jmh_micro | implemented | publishable |
| D1 | SHOULD | community | tcp-tls-1.3 | D | within-tier | Community loopback handshake/lifecycle probe | integration_probe | implemented | internal-only |
| D5 | SHOULD | community | tcp-tls-1.3 | D | within-tier | Community TLS loopback integration probe | loopback_it | implemented | internal-only |
| D2 | STRETCH | enterprise | tcp-tls-1.3 | D | within-tier | Enterprise loopback handshake/lifecycle probe | integration_probe | implemented | internal-only |
| D3 | SHOULD | community | tcp-tls-1.3 | D | implementation-variant | Community loopback handshake comparative benchmark | jmh_comparative | planned | blocked-pr-60 |
| D4 | STRETCH | community | tcp-tls-1.3 | D | cross-tier-same-protocol | Lifecycle probes integrated under `exeris-benchmarks` runtime harness | runtime_probe | stretch | blocked |

## Mapping IDs to Existing Implemented Artifacts

| Matrix ID | Implemented Artifact | Workspace Path |
|---|---|---|
| A1 | `CoreOffHeapTlsEngineZeroAllocTckTest` | `exeris-kernel/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/CoreOffHeapTlsEngineZeroAllocTckTest.java` |
| A2 | `CoreOffHeapTlsEngineZeroAllocTckTest` | `exeris-kernel/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/CoreOffHeapTlsEngineZeroAllocTckTest.java` |
| B1 | `CoreOffHeapTlsEngineBenchmark` | `exeris-kernel/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/CoreOffHeapTlsEngineBenchmark.java` |
| B2 | `CoreTlsStateMachineBenchmark` | `exeris-kernel/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/CoreTlsStateMachineBenchmark.java` |
| B3 | `SslEngineTlsBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/SslEngineTlsBenchmark.java` |
| B4 | `NettyTcNativeTlsBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/NettyTcNativeTlsBenchmark.java` |
| B5g | `CommunityTlsEngineGuardBenchmark` | `exeris-kernel/exeris-kernel-community/src/test/java/eu/exeris/kernel/community/crypto/CommunityTlsEngineGuardBenchmark.java` |
| B6 | `ExerisCommunityTlsBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/ExerisCommunityTlsBenchmark.java` |
| B7 | `ExerisEnterpriseTlsBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/ExerisEnterpriseTlsBenchmark.java` |
| B5 | `OffHeapTlsEngineMemoryBioBenchmark` | `exeris-benchmarks/micro/jmh/src/main/java/eu/exeris/benchmarks/micro/tls/OffHeapTlsEngineMemoryBioBenchmark.java` |
| C4 | `EnterpriseTlsEngineBenchmark` | `exeris-kernel-enterprise/exeris-kernel-enterprise/src/test/java/eu/exeris/kernel/enterprise/crypto/EnterpriseTlsEngineBenchmark.java` |
| D1 | `OffHeapTlsEngineLoopbackIT` | `exeris-kernel/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/OffHeapTlsEngineLoopbackIT.java` |
| D5 | `CommunityTlsEngineLoopbackIntegrationTest` | `exeris-kernel/exeris-kernel-community/src/test/java/eu/exeris/kernel/community/crypto/CommunityTlsEngineLoopbackIntegrationTest.java` |
| D2 | `OffHeapTlsEngineLoopbackIT` | `exeris-kernel-enterprise/exeris-kernel-enterprise/src/test/java/eu/exeris/kernel/enterprise/crypto/OffHeapTlsEngineLoopbackIT.java` |

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
- ✅ `jmh_micro` (B1, B2, C4)
- ✅ `jmh_comparative` (B3)
- ✅ Artifacts marked `status: implemented` AND `publication_ready: publishable`
- Require: ≥3 forks, 99% CI on perf-box-amd64, methodology compliance

### Internal-Only (merge-gate, diagnostics, not for public claims)
- 🔒 `guard_tck` (A1, A2)
- 🔒 `integration_probe` (D1, D2)
- 🔒 `loopback_it` (D5)
- May be referenced internally; no absolute numbers in public docs

### Needs Validation Before Publication
- ⚠️ `B4` (tcnative/Netty pipeline): publication needs explicit caveats for pooled `ByteBuf` policy and handler/channel wiring vs B3's direct `SSLEngine` harness
- ⚠️ `B5`/`B6`/`B7`: publication requires all mandatory comparative evidence dimensions (see Comparative Reporting Metrics) plus explicit caveats:
  - **Transport model difference:** B6 uses FD-owner real loopback socket with `write(2)` kernel crossing per TLS record. B5 and B7 use in-process Memory-BIO with no socket and no syscall.
  - **B5 scope caveat:** B5 is an engine-level in-process Memory-BIO lens and is not equivalent to B6 FD-owner/socket integration path.
  - **Allocator model difference:** B6 uses community on-demand allocator. B5/B7 use enterprise pre-reservation allocator model.
  - **Direct comparison constraint:** A B6 vs B5/B7 delta cannot be attributed solely to transport boundary differences. Transport and allocator axes contribute. Any published comparison must carry explicit caveats.
  - **Enterprise confidentiality:** B5/B7 results published using functional labels only. No internal class names, allocation strategy parameters, or native block configuration in public artifacts.
- ⚠️ `B5` (partial): Methods `guardCost`, `wrapThroughput` are publishable; 
  `fullRoundTripWrapUnwrapCost` needs semantic validation

### Blocked or Deferred
- ❌ `D3`: Blocked on exeris-kernel PR #60
- ❌ `D4`: Awaiting runtime harness integration in exeris-benchmarks

---

## B5g (CommunityTlsEngineGuardBenchmark) — Method-Level Breakdown

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

For Community steady-state wrap/unwrap throughput comparable to B1/C4, use `B3` (JDK reference)
or dedicated Community record-path benchmarks when implemented.

## B6/B7 SPI Contract Notes

- B6/B7 use SPI-native `TlsEngine` client/server pairs created via
  `KernelCryptoProvider#createTlsEngine(CryptoProviderConfig)` and shared helper
  support from `AbstractExerisTlsBenchmarkSupport`.
- B6 (Community) uses `AbstractCommunityTlsBenchmark` FD-owner transport:
  real loopback socket, fd bound before `notifyBound()`, handshake driven with
  virtual threads, plus a persistent drain thread for `wrapThroughput`.
- B7 (Enterprise) uses `AbstractEnterpriseTlsBenchmark` Memory-BIO transport:
  `beginHandshake(out)` with `bioConnector().inject()` / `drain()` loops,
  fully in-process.
- Setup resolves provider classes with tier-first precedence
  (`exeris.tls.<tier>.*`, then `exeris.tls.*`) and creates buffers through
  `MemoryProvider` + `MemoryAllocator`.
- Exposed methods differ by tier: B6 is `wrapThroughput`-only; B7 exposes
  `wrapThroughput` and `wrapUnwrapRoundTrip`.
- Cross-tier caveat (mandatory): B6 `wrapThroughput` includes kernel
  `write(2)` crossing and B7 `wrapThroughput` does not. Report cross-tier TLS
  numbers only with explicit transport-model labels (for example,
  "including kernel I/O" vs "excluding kernel I/O").
- If required provider classes or cert/key inputs are missing for a tier, matrix execution should emit `SKIPPED_MISSING_IMPLEMENTATION` for B6/B7.

---

## TLS Benchmark Methodology Notes

This section documents TLS-specific patterns and fairness rules that apply across the matrix.

### Handshake vs Steady-State Record-Path

TLS benchmarks measure two distinct cost centers:

#### Handshake / Session Initialization (D1, D3 planned, D4 stretch)
- **Pattern**: Fresh engine per invocation (`@Setup(Level.Invocation)`)
- **Scope**: Full TLS session establishment from initial connection through ACTIVE state
- **Cost centers**: SSL_connect / SSL_accept FFM calls, phase state transitions, BIO setup
- **Typical window**: 1–10 ms per handshake (platform/hardware dependent)
- **Metric**: Throughput (sessions/s) or SampleTime (p50/p99 latency)
- **Use case**: Connection pool overhead, load-balancer acceptance rate, proxy throughput

#### Steady-State Record Path (B1, B2, B3, B4, C4)
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
- Community/Enterprise engines: operate on MemorySegment (off-heap, zero heap allocation in steady state)
- JDK SSLEngine: operates on ByteBuffer (may allocate on heap during wrap/unwrap)
- Tcnative/Netty pipeline: operates on pooled direct `ByteBuf` and handler/channel glue backed by JNI/native OpenSSL state
- **Claim rule**: If claiming "zero-allocation" on wrap/unwrap, must measure steady-state heap allocation 
  via `-prof gc` and confirm `gc.alloc.rate.norm ≈ 0 B/op`; JFR allocation stacks must show no 
  heap allocation in success path (guard path zero-alloc is separate via A1/A2)

### Zero-Allocation Evidence Layers

Zero-allocation claims in Exeris require three separate evidence types:

1. **Guard path (A1/A2)**: JFR allocation gates, sentinel probes, TCK invariants
   - Measures: Throw-and-catch cost of pre-allocated sentinels when engine is in HANDSHAKE_IN_PROGRESS
   - Evidence: `jdk.ObjectAllocationSample` events (should be ≈0)
   - Use: Merge-gate internal-only check

2. **Steady-state path (B1/C4)**: JMH `-prof gc` allocation tracking
   - Measures: wrap/unwrap on ACTIVE engine, post-handshake
   - Evidence: `gc.alloc.rate.norm` in microseconds-per-operation baseline
   - Use: Publication-grade claim with `-prof gc` profiler

3. **Integration path (D1/D5)**: Loopback lifetime allocation
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

- commit SHA for all repos: `exeris-benchmarks`, `exeris-kernel`, `exeris-kernel-enterprise`, `exeris-spring-runtime`
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
    A1.log
    A2.log
    B1.log
    B2.log
    B5.log
    C4.log
    D1.log
    D5.log
    D2.log
```

JFR recordings (when `JFR_PROF=1`):

```text
results/raw/tls-matrix/<timestamp>/
  jfr/
    A1/   ← CoreOffHeapTlsEngineZeroAllocTckTest JFR recording (copied from target/jfr-reports)
    A2/   ← CoreOffHeapTlsEngineZeroAllocTckTest JFR recording (copied from target/jfr-reports)
    B1/   ← CoreOffHeapTlsEngineBenchmark JFR recording (-Dbenchmark.jvmArgs)
    B2/   ← CoreTlsStateMachineBenchmark JFR recording (-Dbenchmark.jvmArgs)
    B3/   ← SslEngineTlsBenchmark JFR recording (JMH -prof jfr)
    B4/   ← NettyTcNativeTlsBenchmark JFR recording (JMH -prof jfr)
    C4/   ← EnterpriseTlsEngineBenchmark JFR recording (-Dbenchmark.jvmArgs)
    D1/   ← OffHeapTlsEngineLoopbackIT JFR recording (failsafe, -DargLine)
    D2/   ← OffHeapTlsEngineLoopbackIT (enterprise) JFR recording (failsafe, -DargLine)
    D5/   ← CommunityTlsEngineLoopbackIntegrationTest JFR recording (surefire, -DargLine)
```

- B3, B4: recorded via JMH `-prof jfr` profiler plugin.
- A1, A2: test-managed JFR recordings copied from `target/jfr-reports` after the Maven test step succeeds.
- B1, B2, C4: recorded via Maven benchmark profile `-Dbenchmark.jvmArgs=-XX:StartFlightRecording=...`.
- D1, D2, D5: recorded via surefire/failsafe `-DargLine=-XX:StartFlightRecording=...`.
- A2/D2 emit only when included in the selected `--scope` (SHOULD/STRETCH respectively).
- A1/A2 copied files land under `jfr/<ID>/`; injected JFR steps write `jfr/<ID>/<ID>.jfr`.

JFR files contain `jdk.ObjectAllocationSample` + `jdk.ObjectAllocationInNewTLAB` events.
Use `jfr print --events jdk.ObjectAllocationSample <file>.jfr` to extract allocation stacks per benchmark.

`status.csv` must include labels: `tier`, `protocol_mode`, `benchmark_family`, `comparison_axis`.
