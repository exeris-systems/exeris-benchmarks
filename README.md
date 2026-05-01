# Exeris Benchmarks

Reproducible benchmark and performance-validation lab for Exeris runtime repositories.
Includes JMH microbenchmarks, HTTP load scenarios (wrk, h2load, k6), compatibility-cost
reports, reproducible environment capture, and regression baselines.

---

## Principles

- **Methodology before claims.** Every result ships with full environment metadata.
- **No apples-to-oranges** comparisons without explicit labeling.
- **Pure mode and compatibility mode reported separately.**
- **Community and cross-runtime tracks reported separately.**
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

## Scope for this repository

Operational documentation in this repository covers Community and cross-runtime tracks.
Enterprise and locality variants are excluded from the runnable/public docs path.

---

## Repository Layout

```
exeris-benchmarks/
├── docs/                        # methodology, philosophy, regression policy
├── targets/                     # benchmark target apps and launch utilities
│   ├── exeris-community-app/
│   ├── spring-benchmark-app/
│   ├── quarkus-benchmark-app/
│   └── launcher-sync-wrapper.sh
├── micro/                       # JMH microbenchmarks
│   └── jmh/                     # standalone Maven module
├── runtime/                     # server-level HTTP load benchmarks
│   ├── compose/
│   ├── db/
│   ├── drivers/
│   ├── env/
│   └── profiles/
├── compat/                      # compatibility-cost reports
│   ├── spring-runtime/
│   └── persistence/
├── scenarios/                   # end-to-end scripted scenarios
├── baselines/                   # baseline placeholder and policy docs
├── results/                     # run outputs (raw, reports, history, constrained)
├── scripts/                     # capture-env, run-*, compare-results, publish-report
├── schemas/                     # JSON schemas for result and env artifacts
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

Benchmark reports in this repository are split across these explicit axes:

- **Within-target protocol comparison (Community/cross-runtime only)**
	- Community: `H1 vs H2`
- **Cross-runtime same-protocol comparison**
	- `Community app vs Spring`
	- `Community app vs Quarkus`
	- `Spring vs Quarkus`

This separation prevents mixing protocol effects with implementation effects.

---

## Target Matrix

### Exeris Community App
- HTTP/1.1 pure kernel path (`H1`)
- HTTP/2 pure kernel path (`H2`)
- Route dispatch
- JSON serialization path
- PAQS under load

### Spring Runtime
- Phase 0 bootstrap timing
- Phase 1 pure mode ingress
- Phase 2 compatibility mode
- Pure vs compat request overhead
- Transaction bridge overhead

### Quarkus Runtime
- HTTP endpoint throughput and latency on the same scenario contracts
- Cross-runtime comparator track for Community H1/H2 contracts

---

## Quick Start

### JMH microbenchmarks
```bash
cd micro/jmh
mvn clean package -DskipTests
java -jar target/benchmarks.jar -wi 3 -i 5 -f 1
```

#### GitHub Packages auth for Exeris snapshots

`eu.exeris:*` snapshot dependencies are resolved from GitHub Packages (from
`exeris-kernel` and `exeris-spring-runtime`), not Maven Central.

Minimal `~/.m2/settings.xml` server entries:

```xml
<servers>
	<server>
		<id>github-exeris-kernel</id>
		<username>${env.GITHUB_ACTOR}</username>
		<password>${env.GITHUB_TOKEN}</password>
	</server>
	<server>
		<id>github-exeris-spring-runtime</id>
		<username>${env.GITHUB_ACTOR}</username>
		<password>${env.GITHUB_TOKEN}</password>
	</server>
</servers>
```

Local build example:

```bash
export GITHUB_ACTOR="your-github-username"
export GITHUB_TOKEN="ghp_xxx"
mvn -s .github/maven-settings-gpr.xml -f micro/jmh/pom.xml clean package -DskipTests
```

Token requirement: use a PAT with package read access (and repository read access if package visibility requires it).

### Runtime benchmarks (wrk)
```bash
./scripts/run-wrk.sh targets/exeris-community-app scenarios/plaintext
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
| [docs/result-interpretation.md](docs/result-interpretation.md) | How to read and compare benchmark output |
| [docs/regression-policy.md](docs/regression-policy.md) | What triggers a regression alert and how to handle it |

---

## Versioning

This repo tracks Exeris product releases via Git tags: `kernel-community-v{X.Y.Z}`,
`spring-runtime-v{X.Y.Z}`, etc. Use `scripts/compare-results.sh` to diff any two
result sets.
