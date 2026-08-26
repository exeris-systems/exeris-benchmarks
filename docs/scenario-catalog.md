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
| `fuzz-http1-parser` | community / micro | Jazzer + JUnit 5 | `Http1RequestParser.parseRequestLine` |
| `fuzz-http1-headers` | community / micro | Jazzer + JUnit 5 | `Http1RequestParser.parseHeaders`, including the `String` materialisation the visitor does not avoid |
| `fuzz-http2-parser` | community / micro | Jazzer + JUnit 5 | `Http2FrameParser.parseHeader` |
| `destructive-slowloris-h1` | community / runtime | `runtime/drivers/slowloris.py` | Half-open connection eviction; RSS leak under sustained slow-headers |
| `destructive-radamsa-h1` | community / runtime | `runtime/drivers/radamsa-h1-attacker.py` | HTTP/1.1 parser robustness against radamsa-mutated requests |
| `destructive-radamsa-h2` | community / runtime | `runtime/drivers/radamsa-h2-attacker.py` | HTTP/2 frame parser + HPACK decoder robustness (H2C, no TLS) |
| `arena-lifecycle-leak` | community / runtime | radamsa H1 + jcmd | Arena lifecycle leaks under sustained malformed-input load; RSS / NMT / `MemoryStats.leakCount` delta |

Drivers:

- `scripts/run-fuzz-campaign.sh <scenario-dir> --kernel-version ... --kernel-commit ... --harness-sha ...` — Jazzer
- `scripts/run-destructive-slowloris.sh --base-url ... --target-repo ... --target-commit ... --target-mode ... --target-tier ...`
- `scripts/run-destructive-radamsa.sh --base-url ... --protocol h1|h2 --radamsa-seed ... --target-repo ... --target-commit ... --target-mode ... --target-tier ...`
- `scripts/run-arena-lifecycle-leak.sh --base-url ... --target-pid ... --radamsa-seed ... --target-repo ... --target-commit ... --target-mode ... --target-tier ...`

The runners require `--target-repo`/`--target-commit`/`--target-mode`/`--target-tier` because the harness cannot introspect which app is behind `BASE_URL`; silently labeling the wrong repo/mode/tier in `result.json` would corrupt reproducibility metadata and cross-stack comparability. `--target-commit` and the harness revision are **two separate identities** and neither is inferred from the other — `tools/bench/lib/identity.sh` owns both, after four copies of one `|| echo 'nogit'` fallback each wrote schema-valid results carrying no traceable revision.

**Campaign length is not a flag** for the Jazzer runner. It comes from `@FuzzTest(maxDuration = "...")` on the test class; `--duration` is refused because it could not be honoured. `JAZZER_FUZZ=1` is exported by the runner — without it Jazzer replays the seed corpus in regression mode and exits.

### Radamsa driver: rate, concurrency and the timeout split

The declared `requests_per_second` in these scenarios is a **requested** rate. Until 2026-08-26 the driver was single-threaded, so every read timeout blocked it for the full socket deadline: the first campaign requested 500 rps and achieved 3.4, with 60 timeouts x 2.0 s consuming the entire 120 s window. Mutant generation was **not** the cause — radamsa costs 3.1 ms per spawn, 1.1 % of that window. The driver now fires from a worker pool, generates mutants in batches on a background thread (1.13 ms/mutant), and reports `achieved_rps` and `backlog_skips` so a run that cannot reach its profile says so.

Concurrency is part of the stimulus, not a harness detail, so `concurrent_connections` is recorded in the scenario and the achieved figure travels with the result.

`hang_count` counts read timeouts only where the payload **completed a request** and the target therefore owed an answer. A timeout on a truncated mutant is `incomplete_wait_count`: the target is correctly waiting for the rest and the attacker gave up at its socket deadline. This is the timeout-side twin of the `rejected`-vs-`crash` correction — measured on the first campaign, 14.6 % of iterations timed out while ~10 % of that seed's mutants carry no terminated request, and the target answered `/health` in 8 ms throughout. `incomplete_wait_count` does **not** establish that a target is healthy: whether it ever times out an incomplete request is `destructive-slowloris-h1`'s question.

Mutant streams carry a `mutant_stream` id. Batched generation produces different bytes from the pre-2026-08-26 per-iteration seeding for the same seed, so `per-iteration-v1` and `batched-v2` runs are **not byte-comparable**.

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

- `exeris-community` vs `spring-hibernate`
- `exeris-community` vs `quarkus-hibernate`
- `spring-hibernate` vs `quarkus-hibernate`

1. Run `scripts/run-comparative.sh` with `--scenario-id entity-read-by-id` and `--contract-id fixed_contract_cross_runtime_h1_v1`.
2. Validate both result bundles with `scripts/validate-comparative-readiness.sh`.
3. Generate or confirm the fairness artifact with `tools/compute-fairness-index.sh`.
4. Aggregate only repeated comparative runs with `scripts/aggregate-comparative-results.sh`.

Backend-mode intra-target runs tied to locality variants are outside the active/public scenario catalog scope.

First dual-target comparative execution for this path, and any publishable cross-runtime comparison derived from it, remain pending until complete, claim-eligible run artifacts are captured and reviewed.

---

### cold-start-ttfr

| Field | Value |
|---|---|
| Scenario ID | `cold-start-ttfr` |
| Endpoint | `GET /api/v1/users?id=1` (first-request probe) + `/health` (readiness) |
| Mode | `baseline-db` |
| Tier | Community |
| Driver | `startup-probe` (custom; `scripts/run-cold-start-ttfr.sh`) |
| Transport | H1 (loopback) |

Measures application **cold start** and **time-to-first-request**, over N independent JVM launches:

| Metric | Definition |
|---|---|
| `startup_ms` | `t0` (process spawn) → first HTTP 200 from the health endpoint. Black-box cold start. |
| `ttfr_ms` | ready (health 200) → first HTTP 2xx from the business endpoint. First-call penalty: lazy init, cold JIT, pool fill, class loading. |
| `spawn_to_first_request_ms` | `t0` → first business 2xx (startup + TTFR end to end). |

`t0` is captured by the runner immediately before it invokes the target's launch contract (`EXTERNAL_START_CMD`), so it includes shell fork + JVM exec identically across targets — the fairest cross-runtime black-box definition. Each launch is stopped and the port confirmed free before the next spawn, so every iteration is a genuine cold process.

```bash
# DB + backend deps MUST already be running (this measures app cold start only).
./scripts/run-cold-start-ttfr.sh --target exeris-community --iterations 10
./scripts/run-cold-start-ttfr.sh --target quarkus-hibernate --iterations 10 \
  --first-request-path /api/v1/users/1
```

Artifacts (under `results/cold-start-ttfr/<target>/<ts>/`): `result.json` (aggregated `startup`/`ttfr_ms` stats — median/p90/p99 + per-iteration `samples`), `cold-start-timeline.json` (raw per-iteration), `env.json`.

> **CAVEATS.** (1) **`exploratory` / descriptive only** — not a guard or regression gate. (2) Cold start has high run-to-run variance; report the aggregate, never a single launch. (3) **`ready` semantics differ per framework** (Spring `Started`, Quarkus `started`, Exeris banner, native-image) — `startup_ms` is a uniform black-box spawn→health metric and cross-runtime rows must carry that caveat. (4) `artifact_kind` matters: never frame native-image vs JIT cold start as apples-to-apples without the label. (5) JVM flags (AppCDS, tiered stop level, `AlwaysPreTouch`) materially move `startup_ms` and are captured in `env.json`. (6) `transport_mode=loopback-h1`: TTFR includes only loopback network cost.

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
