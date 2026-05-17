# Scenario Catalog

Complete list of benchmark scenarios maintained in this repository.
Each scenario lives under `scenarios/<name>/` or is exercised by a tool-specific
script in `runtime/<tool>/`.

---

## Scenario definitions

### hello-world

| Field | Value |
|---|---|
| Path | `GET /hello` |
| Response | `200 OK`, body `Hello, World!` (plain text) |
| Payload | none |
| Purpose | Absolute minimum routing overhead |
| Tools | wrk, h2load, k6 |

---

### plaintext

| Field | Value                                              |
|---|----------------------------------------------------|
| Path | `GET /plaintext`                                   |
| Response | `200 OK`, body `plaintext` (9 bytes)               |
| Payload | none                                               |
| Purpose | TechEmpower-equivalent baseline for RPS comparison |
| Tools | wrk, h2load, k6                                    |

---

### json-1kb

| Field | Value |
|---|---|
| Path | `POST /echo` |
| Request | `Content-Type: application/json`, ~1 KB JSON body |
| Response | Echo of the same body |
| Purpose | JSON parse + serialize cost at small payload |
| Tools | wrk (with Lua script), k6 |
| Payload file | `scenarios/json-1kb/payload.json` |

---

### json-10kb

| Field | Value |
|---|---|
| Path | `POST /echo` |
| Request | `Content-Type: application/json`, ~10 KB JSON body |
| Response | Echo of the same body |
| Purpose | JSON cost at medium payload; buffer strategy sensitivity |
| Tools | wrk (with Lua script), k6 |
| Payload file | `scenarios/json-10kb/payload.json` |

---

### routing-404

| Field | Value |
|---|---|
| Path | `GET /does-not-exist` |
| Response | `404 Not Found` |
| Purpose | Fast-path negative routing cost |
| Tools | wrk, k6 |

---

### exception-mapping

| Field | Value |
|---|---|
| Path | `GET /throw` |
| Behaviour | Handler throws a mapped exception |
| Response | `422 Unprocessable Entity`, JSON error body |
| Purpose | Exception-to-response mapping overhead |
| Tools | k6 |

---

### concurrent-reads

| Field | Value |
|---|---|
| Path | `GET /data/{id}` |
| Concurrency | 100–500 connections |
| Purpose | Thread/dispatcher contention under mixed-key read load |
| Tools | wrk2 (steady rate), k6 (variable ramp) |

---

### backpressure

| Field | Value |
|---|---|
| Behaviour | Overload target beyond capacity |
| Purpose | Measure shed-rate, error ratio, graceful degradation |
| Tools | wrk2, k6 |
| Notes | Target must not OOM or deadlock; latency tail is the metric |

---

### tx-commit

| Field | Value |
|---|---|
| Path | `POST /tx/commit` |
| Behaviour | Single-entity write transaction, commit |
| Purpose | Transaction bridge overhead (Spring Runtime Phase 2) |
| Tools | k6 |
| Mode | compatibility mode only |

---

### tx-rollback

| Field | Value |
|---|---|
| Path | `POST /tx/rollback` |
| Behaviour | Single-entity write, explicit rollback |
| Purpose | Rollback path cost vs commit path |
| Tools | k6 |
| Mode | compatibility mode only |

---

## JMH micro scenarios

| Scenario | Class | What it measures |
|---|---|---|
| `route-registry` | `RouteRegistryBenchmark` | Route lookup by method + path |
| `json-codec` | `JsonCodecBenchmark` | Jackson / Exeris codec encode + decode |
| `request-wrapper` | `RequestWrapperBenchmark` | Wrapper object construction overhead |
| `response-builder` | `ResponseBuilderBenchmark` | Response builder chain cost |
| `scheduler` | `SchedulerBenchmark` | Task dispatch / queue submit cost |

---

## Compatibility scenarios (compat/)

| Scenario | Compares |
|---|---|
| `spring-runtime/pure-vs-compat` | Phase 1 pure mode vs Phase 2 compat mode |
| `spring-runtime/handler-overhead` | Exeris handler vs `@RestController` dispatch |
| `persistence/native-vs-jdbc` | Native repository path vs JDBC bridge |

---

## Destructive / fuzz / chaos scenarios

All entries below emit `claim_scope=exploratory`, `comparison_axis=standalone`, and a `destructive-findings.json` sidecar conforming to `schemas/destructive-findings.schema.json`. Methodology, boundary, confidentiality rules: `docs/destructive-fuzz-methodology.md`.

| Scenario | Tier / Family | Driver | What it stresses |
|---|---|---|---|
| `fuzz-http1-parser` | community / micro | Jazzer + JUnit 5 | `Http1RequestParser.parseRequestLine` / `parseHeaders` |
| `fuzz-http2-parser` | community / micro | Jazzer + JUnit 5 | `Http2FrameParser.parseHeader` |
| `destructive-slowloris-h1` | community / runtime | `runtime/drivers/slowloris.py` | Half-open connection eviction; RSS leak under sustained slow-headers |
| `destructive-radamsa-h1` | community / runtime | `runtime/drivers/radamsa-h1-attacker.py` | HTTP/1.1 parser robustness against radamsa-mutated requests |
| `destructive-radamsa-h2` | community / runtime | `runtime/drivers/radamsa-h2-attacker.py` | HTTP/2 frame parser + HPACK decoder robustness (H2C, no TLS) |
| `arena-lifecycle-leak` | community / runtime | radamsa H1 + jcmd | Arena lifecycle leaks under sustained malformed-input load; RSS / NMT / `MemoryStats.leakCount` delta |

Drivers:

- `scripts/run-fuzz-campaign.sh <scenario-dir>` — Jazzer
- `scripts/run-destructive-slowloris.sh --base-url ...`
- `scripts/run-destructive-radamsa.sh --base-url ... --protocol h1|h2 --radamsa-seed ...`
- `scripts/run-arena-lifecycle-leak.sh --base-url ... --target-pid ... --radamsa-seed ...`

Cross-stack destructive comparisons require explicit timeout / connection-limit / radamsa-seed normalization — see methodology doc.

---

## Adding a new scenario

1. Create `scenarios/<name>/` directory.
2. Add a `README.md` describing path, payload, purpose, expected outcome.
3. Add tool scripts (k6 script, Lua script, or h2load flags file).
4. Add a payload file if needed.
5. Run the scenario and store the initial result under `baselines/<repo>/<mode>/`.
6. Add an entry to this catalog.

---

## Scenario naming convention (tier + protocol + scenario)

Canonical run-id naming should encode:

`<tier>-<protocol>-<scenario>`

Examples:

- `community-h1-plaintext`
- `community-h2-json-1kb`
- `spring-h1-plaintext`
- `quarkus-h1-plaintext`

---

## Protocol coverage matrix

### Community matrix

| Protocol | Plaintext | JSON 1KB | JSON 10KB | 404 | Exception | Concurrency | Multiplex |
|---|---|---|---|---|---|---|---|
| H1 | yes | yes | yes | yes | yes | yes | no |
| H2 | yes | yes | yes | yes | yes | yes | yes |

---

### entity-read-by-id

| Field | Value |
|---|---|
| Scenario ID | `entity-read-by-id` |
| Endpoint | `GET /api/v1/entities/{id}` |
| Mode | `baseline-db` |
| Tier | Community (first) |
| Driver | wrk |
| Transport | H1 (loopback) |

> **LOOPBACK CAVEAT:** `transport_mode=loopback-h1`. Results are not equivalent to network-path measurements. All result artifacts must carry `transport_mode=loopback-h1`.

#### Claim scope

| Scope | Min duration | Required profile | Allowed claims | CO risk |
|---|---|---|---|---|
| `exploratory` | 30 s | dev-laptop, ci-runner | descriptive only | yes |
| `comparison-eligible` | 60 s | **perf-box-amd64** | throughput, p50 (indicative) | yes |
| `p99-stable` | 120 s | **perf-box-amd64**, wrk2 only | P99 | yes |

wrk is **INELIGIBLE** for `p99-stable`. Use `run-wrk2.sh` for P99 claims.

#### Seed

Requires PostgreSQL (postgres:16.2) seeded with 1000 entities (IDs 1–1000, schema V1).
Pre-run verification via `scenarios/entity-read-by-id/seed/verify-seed.sh` is mandatory.
Results without a passing verification are invalid.

#### Cross-runtime status

Comparative execution remains constrained to Community/H1/loopback cross-runtime pairs declared in `scenarios/entity-read-by-id/comparative-pair-manifest.json`. This is structural readiness only, not a completed or published comparative result.

#### Maturity promotion workflow

Use the fixed contract campaign path when promoting this scenario from exploratory to repeatable guard evidence:

1. Run `scripts/run-entity-read-by-id-campaign.sh` to execute repeats under `--contract fixed_contract_v1`.
2. Check `status.csv` in the campaign directory. Promotion candidates require all rows `final_reason=ok` and `claim_scope=comparison_eligible`.
3. Run `scripts/summarize-entity-read-by-id-campaign.sh <campaign-dir>`.
4. Review `repeatability-summary.json` and `repeatability-summary.md`; gate is pass only when throughput CV <= 0.15 and all repeats report `total_errors==0`.
5. Keep `result.json`, `reproducibility-metadata.json`, and `steady-state-evidence.json` for each repeat as evidence artifacts.

#### Comparative execution path

For cross-runtime pairwise comparisons (Community/H1/loopback only), use `fixed_contract_cross_runtime_h1_v1` and only allowed pairs from `scenarios/entity-read-by-id/comparative-pair-manifest.json`:

- `exeris-benchmark-app-community-h1` vs `spring-jvm-vt-tuned`
- `exeris-benchmark-app-community-h1` vs `quarkus-jvm-vt-tuned`
- `spring-jvm-vt-tuned` vs `quarkus-jvm-vt-tuned`

1. Run `scripts/run-comparative.sh` with `--scenario-id entity-read-by-id` and `--contract-id fixed_contract_cross_runtime_h1_v1`.
2. Validate both result bundles with `scripts/validate-comparative-readiness.sh`.
3. Generate or confirm the fairness artifact with `tools/compute-fairness-index.sh`.
4. Aggregate only repeated comparative runs with `scripts/aggregate-comparative-results.sh`.

Backend-mode intra-target runs tied to locality variants are outside the active/public scenario catalog scope.

First dual-target comparative execution for this path, and any publishable cross-runtime comparison derived from it, remain pending until complete, claim-eligible run artifacts are captured and reviewed.

---

## Scaffolded matrix scenarios (layout-ready)

The following directories are scaffolded and ready for tool-specific scripts:

- `scenarios/json-10kb/`
- `scenarios/exception-mapping/`
- `scenarios/concurrent-32/`
- `scenarios/concurrent-256/`
- `scenarios/multiplex-32/`
- `scenarios/keepalive-steady/`
- `scenarios/cold-connect-single/`
- `scenarios/handshake-cold/`
- `scenarios/lossy-network/`

---

## TLS Article

For TLS zero-copy matrix runs, use:

- Runner script: `scripts/run-tls-matrix.sh`
- Matrix document: `docs/tls-zero-copy-benchmark-matrix.md`

This keeps matrix IDs, tier/protocol labels, and reproducibility metadata aligned.
