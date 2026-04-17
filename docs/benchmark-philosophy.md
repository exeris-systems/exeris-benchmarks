# Benchmark Philosophy

## Why a dedicated benchmark repository?

Efficiency is part of the Exeris identity, not an afterthought.

Exeris is not built solely to chase isolated headline performance numbers. It is built
to operate with a disciplined runtime footprint, predictable resource usage, and a
high density-per-host profile that matters for real FinOps outcomes.

This benchmark repository exists because Exeris makes concrete engineering claims about:

- low CPU cost per useful unit of work
- low memory overhead under realistic service loads
- bounded runtime footprint under constrained environments
- operational density and deployment efficiency
- clear separation between contract-level costs and representative end-to-end behavior
- strict claim hygiene for comparative benchmarking

The goal is not to publish synthetic numbers without context.

The goal is to measure, document, and defend:
- what Exeris costs to run,
- how efficiently it converts resources into useful work,
- where its architecture pays off,
- and where a claim is exploratory, bounded, or unsupported.

This is especially important because different Exeris tiers make different promises.

For example:
- Community focuses on lightweight runtime operation, practical efficiency, and operational accessibility
- Enterprise may justify stronger transport, scheduling, and latency-oriented claims where the architecture is materially different

As a result, this repository carefully distinguishes between:
- contract/component benchmarks,
- regression benchmarks,
- representative E2E scenarios,
- and comparative claims that are eligible only under explicitly controlled conditions.

---

## What this repo is not

- It is **not marketing material.** Results are presented as raw numbers with methodology notes.
- It is **not a showcase of best-case numbers.** Worst-case and steady-state paths
  matter as much as peak throughput.
- It is **not a comparison tool** for making unfair apples-to-oranges claims.
  Any comparison against other frameworks must document the setup of both sides
  with equal rigor.

---

## Layers of truth

Benchmarks in this repo are organized into six layers of increasing scope and integration:

| Layer | What it proves | Tooling | Examples |
|---|---|---|---|
| **contract** | Invariant safety, merge gates, architectural guards | JUnit, JFR gates, TCK | Zero-alloc path guards, SLO sentinel probes |
| **micro** | Isolated hot-path cost in isolation | JMH | CoreOffHeapTlsEngineBenchmark, phase reads |
| **integration** | Loopback and lifecycle viability | JUnit IT, harness probes | OffHeapTlsEngineLoopbackIT, handshake sequence |
| **runtime** | Full server behavior under realistic HTTP load | wrk / h2load / k6 / Hyperfoil | plaintext, json-1kb, keepalive-steady scenarios |
| **compat** | Compatibility-mode overhead and correctness | wrk + k6 | compat suite comparisons |
| **scenarios** | End-to-end user flows under load | k6 / Hyperfoil | exception-mapping, routing-404, multi-step journeys |

No single layer tells the whole story. A fast microbenchmark and a slow runtime result
usually mean the integration path is the bottleneck. A fast runtime result and a slow
compat result usually mean the compatibility layer is the cost center. **Read all layers together.**

### Key distinctions among layers

- The **contract** layer ("Is the contract still satisfied?") lives in product repos as merge gates
- The **micro → integration** layers verify isolation and lifecycle correctness separately
- The **runtime → scenarios** layers measure full-stack behavior under realistic load
- **Canonical aggregate outputs** (trend reports, baselines, comparative analyses) live here

---

## Hybrid benchmark model: repo + product repos

This repo follows a **hybrid model** in which:

### Canonical benchmark taxonomy and reporting
- Benchmark definitions, scenarios, and schemas: **here in exeris-benchmarks**
- Normalized result contracts: **here**
- Baselines and trend tracking: **here**
- Comparative and release reports: **here**

### Benchmark implementations
- **Contract/guard tests** (merge-gate, TCK, invariants): may live in product repos
- **Micro benchmarks** (isolated hot paths): may live in either location
- **Integration probes** (loopback, lifecycle): may live in either location  
- **Runtime scenarios**: primarily here in exeris-benchmarks
- **Harnesses and drivers**: primarily here

### How it works in practice

This repo depends on product repos as Maven/Gradle artifacts or Docker images for testing,
but it does **not** embed product source. Benchmarks run against tagged, published builds — 
not in-development snapshots. A benchmark run can be reproduced by specifying a version tag
and a hardware profile.

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
2. Comparing results against established baselines
3. Flagging outliers according to the [regression policy](regression-policy.md)

---

## Formal classification rule: guard test vs benchmark

Not every performance test should be moved here.

### Keep in product/test repositories (guard tests)

Performance and architecture guards that are part of correctness and merge safety:

- defensive latency thresholds used as merge gates
- allocation/ref-count invariants (e.g. bounded alloc/op)
- classpath and architecture invariants
- fast deterministic checks required in CI for every PR

These tests answer: **"Is the contract still satisfied?"**

### Keep in `exeris-benchmarks` (benchmark lab)

Exploratory, comparative, historical, and release-validation benchmark suites:

- cross-repo and cross-mode comparisons
- deeper JMH profiling beyond merge-gate constraints
- runtime scenario studies (wrk/wrk2/h2load/k6)
- trend/history reporting and baseline evolution analysis

These tests answer: **"How fast is it, and how does it change over time?"**

---

## Enterprise without proprietary leakage

Preferred model:

- **public benchmark repo** for methodology, scenarios, and schemas
- **private enterprise executor** for startup adapters and proprietary wiring

This repo defines scenario, launch, and result contracts and can invoke an external
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
5. Regressions block release according to the [regression policy](regression-policy.md).