# Exeris Benchmarks

Reproducible benchmark and performance-validation lab for Exeris runtime repositories.
Includes JMH microbenchmarks, HTTP load scenarios (wrk, h2load, k6), compatibility-cost
reports, reproducible environment capture, and regression baselines.

---

## Principles

- **Methodology before claims.** Every result ships with full environment metadata.
- **No apples-to-oranges** comparisons without explicit labeling.
- **Pure mode and compatibility mode reported separately.**
- **Community and Enterprise reported separately.**
- **Reproducible by design** — every run is tagged with repo SHA, JDK, OS, and hardware profile.

### Repository boundary rule

- **Guard/perf-contract tests stay in product repos** (`exeris-kernel`, `exeris-spring-runtime`, enterprise repos).
- **Exploratory/comparison/history benchmarks live here** (`exeris-benchmarks`).

Quick decision:

- If it answers **"can this be merged safely?"** → product repo guard test.
- If it answers **"how fast is it and how it changes over time?"** → benchmark repo.

Examples that stay in product repos:

- allocation guard tests (`alloc/op <= threshold`)
- latency defensive merge gates
- architecture/classpath invariants

Examples that belong here:

- cross-repo comparisons (kernel vs spring-runtime)
- pure vs compat overhead reports
- release/history trend benchmarking
- richer JMH/wrk/h2load/k6 exploratory suites

---

## Enterprise Model (No Proprietary Leak)

This repository follows a **public harness + private executor** model:

- Public (`exeris-benchmarks`): scenarios, methodology, schemas, comparison/reporting logic.
- Private (enterprise repo/extension): enterprise startup adapters, proprietary wiring, private hooks.

The public repository defines **execution contracts**, not proprietary implementation.
Enterprise runs should publish only normalized outputs (schema-compliant metrics and summaries),
not private source wiring or raw symbol-rich traces.

---

## Repository Layout

```
exeris-benchmarks/
├── docs/                        # methodology, philosophy, regression policy
├── targets/                     # per-product launch profiles and sample apps
│   ├── exeris-kernel/
│   │   ├── community/
│   │   └── enterprise/
│   ├── exeris-spring-runtime/
│   ├── exeris-sdk/              # future
│   └── exeris-studio/           # future
├── micro/                       # JMH microbenchmarks
│   └── jmh/                     # standalone Maven module
├── runtime/                     # server-level HTTP load benchmarks
│   ├── wrk/
│   ├── wrk2/
│   ├── h2load/
│   ├── k6/
│   └── drivers/                 # docker-compose, start/stop scripts
├── compat/                      # compatibility-cost reports
│   ├── spring-runtime/
│   └── persistence/
├── scenarios/                   # end-to-end scripted scenarios
├── baselines/                   # reference results per version / hardware
├── results/                     # run outputs (raw, normalized, summaries, history)
├── scripts/                     # capture-env, run-*, compare-results, publish-report
├── schemas/                     # JSON schemas for result and env artifacts
├── .github/workflows/           # CI: microbench, runtime-bench, compare-baseline
└── tools/                       # result-parser, dashboard-export
```

---

## Benchmark Taxonomy

| Layer | Tooling | What it measures |
|---|---|---|
| `micro/` | JMH | hot paths — codec, routing, wrapper, scheduler |
| `runtime/` | wrk / wrk2 / h2load / k6 | HTTP RPS, latency, concurrency |
| `compat/` | wrk + k6 | pure mode vs compatibility overhead |
| `scenarios/` | k6 | scripted end-to-end flows |

---

## Comparison Axes

Benchmark reports are split across two explicit axes:

- **Within-tier protocol comparison**
	- Community: `H1 vs H2`
	- Enterprise: `H1 vs H2 vs H3`
- **Cross-tier same-protocol comparison**
	- `Community H1 vs Enterprise H1`
	- `Community H2 vs Enterprise H2`
	- `H3` is Enterprise-only and never used as direct cross-tier comparator.

This separation prevents mixing protocol effects with tier/transport implementation effects.

---

## Target Matrix

### Kernel / Community
- HTTP/1.1 pure kernel path (`H1`)
- HTTP/2 pure kernel path (`H2`)
- Route dispatch
- JSON serialization path
- PAQS under load

### Kernel / Enterprise
- HTTP/1.1 fallback (`H1`)
- HTTP/2 fallback (`H2`)
- QUIC / HTTP/3 path (`H3`)
- io_uring ingress
- TLS wrap/unwrap
- Slab allocation/release
- Native persistence handoff

### Spring Runtime
- Phase 0 bootstrap timing
- Phase 1 pure mode ingress
- Phase 2 compatibility mode
- Pure vs compat request overhead
- Transaction bridge overhead

---

## Quick Start

### JMH microbenchmarks
```bash
cd micro/jmh
mvn clean package -DskipTests
java -jar target/benchmarks.jar -wi 3 -i 5 -f 1
```

### Runtime benchmarks (wrk)
```bash
./scripts/run-wrk.sh targets/exeris-kernel/community scenarios/plaintext
```

### Capture environment
```bash
./scripts/capture-env.sh > results/raw/$(date +%Y%m%d-%H%M%S)-env.json
```

### Compare against baseline
```bash
./scripts/compare-results.sh baselines/community/laptop.json results/raw/latest.json
```

---

## Result Storage Model

```
results/history/<repo>/<mode>/<YYYY-MM-DD>-<sha>.json
baselines/<repo>/<mode>/<hardware-profile>.json
```

All result files conform to [`schemas/benchmark-result.schema.json`](schemas/benchmark-result.schema.json).
All environment captures conform to [`schemas/benchmark-env.schema.json`](schemas/benchmark-env.schema.json).

---

## Documentation

| File | Description |
|---|---|
| [docs/benchmark-philosophy.md](docs/benchmark-philosophy.md) | Why this repo exists and how results should be read |
| [docs/methodology.md](docs/methodology.md) | Warmup, measurement, and statistical methodology |
| [docs/hardware-profiles.md](docs/hardware-profiles.md) | Canonical hardware class definitions |
| [docs/scenario-catalog.md](docs/scenario-catalog.md) | All scenarios with payloads and conditions |
| [docs/protocol-comparison-matrix.md](docs/protocol-comparison-matrix.md) | Formal within-tier and cross-tier protocol matrix |
| [docs/tls-zero-copy-benchmark-matrix.md](docs/tls-zero-copy-benchmark-matrix.md) | TLS A/B/C/D MUST-SHOULD-STRETCH matrix with labels, missing IDs, and `scripts/run-tls-matrix.sh` mapping |
| [docs/community-runtime-integration.md](docs/community-runtime-integration.md) | Community runtime probes integrated in canonical paths |
| [docs/result-interpretation.md](docs/result-interpretation.md) | How to read and compare benchmark output |
| [docs/regression-policy.md](docs/regression-policy.md) | What triggers a regression alert and how to handle it |
| [schemas/enterprise-target-contract.schema.json](schemas/enterprise-target-contract.schema.json) | Public contract for private/external target execution |

---

## Versioning

This repo tracks Exeris product releases via Git tags: `kernel-community-v{X.Y.Z}`,
`spring-runtime-v{X.Y.Z}`, etc. Use `scripts/compare-results.sh` to diff any two
result sets.
