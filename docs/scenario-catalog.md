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

| Field | Value |
|---|---|
| Path | `GET /plaintext` |
| Response | `200 OK`, body `plaintext` (15 bytes) |
| Payload | none |
| Purpose | TechEmpower-equivalent baseline for RPS comparison |
| Tools | wrk, h2load |

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

- `community-h1-plaintext-hello`
- `community-h2-json-1kb`
- `enterprise-h1-plaintext-hello`
- `enterprise-h2-json-1kb`
- `enterprise-h3-json-1kb`
- `enterprise-h3-multiplex-32`
- `enterprise-h3-handshake-cold`

---

## Protocol coverage matrix

### Community matrix

| Protocol | Plaintext | JSON 1KB | JSON 10KB | 404 | Exception | Concurrency | Multiplex |
|---|---|---|---|---|---|---|---|
| H1 | yes | yes | yes | yes | yes | yes | no |
| H2 | yes | yes | yes | yes | yes | yes | yes |

### Enterprise matrix

| Protocol | Plaintext | JSON 1KB | JSON 10KB | 404 | Exception | Concurrency | Multiplex | Handshake | Loss/RTT |
|---|---|---|---|---|---|---|---|---|---|
| H1 | yes | yes | yes | yes | yes | yes | no | optional | no |
| H2 | yes | yes | yes | yes | yes | yes | yes | optional | no |
| H3 | yes | yes | yes | yes | yes | yes | yes | yes | yes |

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
