# Benchmark Philosophy

## Why a dedicated benchmark repository?

Performance is part of the Exeris identity, not a footnote. Exeris makes specific
claims:

- zero-copy request paths
- zero-allocation hot paths on telemetry
- microsecond-range dispatch latency
- host-runtime ownership

These claims need to be:

1. **Verifiable** — reproducible by anyone with the appropriate hardware.
2. **Documented** — methodology, environment, and caveats explicitly stated.
3. **Historicized** — tracked across releases so regressions are caught early.

A dedicated benchmark repository separates performance validation from product
code. This keeps the product repositories clean and makes the benchmark harnesses
first-class artifacts rather than an afterthought.

---

## What this repo is not

- It is **not marketing material.** Results are raw numbers with methodology notes.
- It is **not a showcase of best-case numbers.** Worst-case and steady-state paths
  matter as much as peak throughput.
- It is **not a comparison tool** for making unfair apples-to-oranges claims.
  Any comparison against other frameworks must document the setup of both sides
  with equal rigor.

---

## Layers of truth

Benchmarks in this repo are organized in six layers of increasing scope and integration:

| Layer | What it proves | Tooling | Examples |
|---|---|---|---|
| **contract** | Invariant/merge safety, guard gates | JUnit, JFR gates, TCK | Zero-alloc path guards, SLO sentinel probes |
| **micro** | Isolated hot path in isolation | JMH | CoreOffHeapTlsEngineBenchmark, phase reads |
| **integration** | Loopback/lifecycle viability | JUnit IT, harness probes | OffHeapTlsEngineLoopbackIT, handshake sequence |
| **runtime** | Full server under realistic HTTP load | wrk / h2load / k6 / Hyperfoil | plaintext, json-1kb, keepalive-steady scenarios |
| **compat** | Compatibility mode overhead + correctness | wrk + k6 | compat suite comparisons |
| **scenarios** | End-to-end user flows under load | k6 / Hyperfoil | exception-mapping, routing-404, multi-step journeys |

No single layer tells the whole story. A fast microbench and slow runtime number means 
the integration path is the bottleneck. A fast runtime number and slow compat number 
means the compatibility layer is the cost center. **Read all layers together.**

### Key distinctions among layers

- **Contract** layer ("Is the contract still satisfied?") lives in product repos as merge gates
- **Micro → Integration** layers verify isolation and lifecycle correctness separately
- **Runtime → Scenarios** layers measure full-stack behavior under realistic load
- **Canonical aggregate outputs** (trend reports, baselines, comparative analyses) live here

---

## Hybrid benchmark model: repo + product repos

This repo follows a **hybrid model** where:

### Canonical benchmark taxonomy and reporting
- Benchmark definitions, scenarios, schemas: **here in exeris-benchmarks**
- Normalized result contracts: **here**
- Baselines and trend tracking: **here**
- Comparative/release reports: **here**

### Benchmark implementations
- **Contract/guard tests** (merge-gate, TCK, invariants): may live in product repos
- **Micro benchmarks** (isolated hot paths): may live in either location
- **Integration probes** (loopback, lifecycle): may live in either location  
- **Runtime scenarios**: primarily here in exeris-benchmarks
- **Harnesses and drivers**: primarily here

### How it works in practice

This repo depends on product repos as Maven/Gradle artifacts or Docker images for testing,
but does **not** embed product source. Benchmarks run against tagged, published builds — 
not in-development snapshots. A benchmark run can be reproduced by specifying a version 
tag and a hardware profile.

A benchmark implementation may reside in a product repo (e.g., `CoreOffHeapTlsEngineBenchmark` 
in `exeris-kernel-core`) and still be canonical when orchestrated through:
- Registry in [tls-zero-copy-benchmark-matrix.md](tls-zero-copy-benchmark-matrix.md)
- Normalized result contracts in [schemas/](schemas/)
- Baseline tracking in [baselines/](baselines/)

The TLS matrix exemplifies this: benchmark *artifacts* are distributed across repos,
but benchmark *truth* (taxonomy, comparability rules, result contracts) is canonical here.

### Independence and regression detection

Product teams can introduce regressions; this repo surfaces them by:
1. Running canonical scenarios against each product build
2. Comparing results to established baselines
3. Flagging outliers per the [regression policy](regression-policy.md)

---

## Formal classification rule: guard test vs benchmark

Not every performance test should be moved here.

### Keep in product/test repositories (guard tests)

Performance/architecture guards that are part of correctness and merge safety:

- defensive latency thresholds used as merge gates
- allocation/ref-count invariants (e.g. bounded alloc/op)
- classpath and architecture invariants
- fast deterministic checks required in CI for every PR

These tests answer: **"Is the contract still satisfied?"**

### Keep in `exeris-benchmarks` (benchmark lab)

Exploratory, comparative, historical, release-validation benchmark suites:

- cross-repo and cross-mode comparisons
- deeper JMH profiling beyond merge-gate constraints
- runtime scenario studies (wrk/wrk2/h2load/k6)
- trend/history reporting and baseline evolution analysis

These tests answer: **"How fast is it and how it changes over time?"**

---

## Enterprise without proprietary leakage

Preferred model:

- **public benchmark repo** for methodology/scenarios/schemas
- **private enterprise executor** for startup adapters and proprietary wiring

This repo defines scenario + launch/result contracts and can invoke an external
private runner via `runtime/drivers`.

Public outputs should be limited to normalized metrics and summaries. Avoid
publishing private implementation details such as internal startup wiring,
raw JFR/async-profiler symbol trees, or stack traces containing private package names.

---

## Claim lifecycle

When a performance claim is made for Exeris:

1. A scenario is added to this repo covering that claim.
2. A baseline result is recorded under `baselines/`.
3. The claim is referenced from the scenario README, pointing to the baseline file.
4. CI runs the scenario on every commit to the referenced product repo.
5. Regressions block release per the [regression policy](regression-policy.md).
