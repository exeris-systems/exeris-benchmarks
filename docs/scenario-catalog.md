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

### RSS is a weak leak signal, and a cold baseline makes it weaker

Both `destructive-*` runners and `arena-lifecycle-leak` sampled `rss_bytes_before` on a target that had **never served a request**, so first-load JIT, metaspace fill and heap commit were charged to the attack. The first slowloris run recorded **+34.9 % RSS against a 5 % tolerance** and classified `leak-suspected` — while the same run's JFR put **live heap after the forced GC at 9.5 MB**. Whatever those bytes were, retained Java objects was not it.

The runners now drive a warm-up (`--warmup-seconds`, default 30) before the baseline and record `baseline_warmup_seconds` in `resource_delta`. **Two runs with different values there are not comparable on `rss_bytes_delta`.**

`arena-lifecycle-leak` states its FAIL condition as *"RSS delta correlates with attack duration"*, but the runner recorded two points, from which no correlation can be computed — a leak and a plateau fit a before/after pair equally well, and they are precisely the two hypotheses the scenario exists to separate. The runner now samples RSS across the window (`rss-series.txt`) and reports `rss_series_early_slope_bytes_per_s` / `rss_series_late_slope_bytes_per_s`: **a leak holds the late slope near the early one; first-load growth collapses it toward zero.**

Neither replaces NMT. Without `-XX:NativeMemoryTracking`, `native_heap_committed_bytes_delta` is null and the non-heap remainder is unattributed — quote it as a remainder, never decompose it by subtraction.

### `arena-lifecycle-leak` was blind to crashes until 2026-08-26

Its findings hardcoded `crash_count: 0`, `oom_count: 0`, `hang_count: 0` and called `destructive_classify` with three literal zeros, reading only `iterations_total` from the attacker. A run whose listener died in the first second would still have been classified on memory growth alone. On the first real run the attacker reported 46 112 complete-request timeouts that the artifact recorded as `hang_count: 0`. The counters are now read from the attacker summary and reach both the classifier and the artifact.

Mutant streams carry a `mutant_stream` id. Batched generation produces different bytes from the pre-2026-08-26 per-iteration seeding for the same seed, so `per-iteration-v1` and `batched-v2` runs are **not byte-comparable**.

### Finding: four malformed request lines park an Exeris H1 connection indefinitely

The first full-rate `destructive-radamsa-h1` campaign against kernel 0.11.0 (`5e29ae675020`, arm C, pure/community) reported **8 364 hangs in 59 486 iterations (14.1 %)** — mutants the target was obliged to answer and did not, inside a 2 s socket deadline. Four checks turned that from a number into a characterization.

1. **Not saturation.** The hang fraction is flat across a 10× concurrency range and *falls* slightly as load rises: 16.6 % at 50 rps / 32 workers, 12.1 % at 150/64, 11.5 % at 500/256. Queuing would move it the other way.
2. **Not the attacker's deadline.** Eight mutants that hang at 2 s were re-fired and held for 45 s. All eight were **still silent — no response and no close**.
3. **Not body framing.** All 2 000 owed mutants sampled were `no-body-framing`: plain CRLFCRLF-terminated requests with no `Content-Length` and no `Transfer-Encoding`. The predicate's conflicting/malformed-`Content-Length` branches never fired.
4. **Reducible to minimal cases.** Four handcrafted single-line requests reproduce it without radamsa. Each is held open with no response and no close; a fifth malformed shape shows the parser *does* have a rejection path.

| Request | Result |
|---|---|
| `GET /plaintext HTTP/1.1` + `Host` | 200 in 1 ms |
| `\r\n` before the request line | **held open, silent** |
| `BADMETHOD /plaintext HTTP/1.1` | **held open, silent** |
| `GET /plaintext` (no HTTP version) | **held open, silent** |
| bare-LF line endings | **held open, silent** |
| space inside a header name | closed cleanly, 0 ms |
| `HTTP/9.9` and `HTTP/11845539971726784.2` | **200 OK** — version not validated |

RFC 9112 §2.2 says a server should ignore at least one empty line before the request-line; RFC 9110 §9.1 makes an unrecognized method a 501. Whether the parser *ought* to answer each of these is arguable case by case. The consequence is not: **100 such connections opened against the target were still established after 20 s idle, and were released only when the attacker closed them.** The target stayed responsive throughout — `/health` answered 200 in well under a millisecond — so this is unbounded connection retention, not a crash.

It composes with `destructive-slowloris-h1`'s `connections_dropped: 0`: the target evicted no half-open connection in a 120 s window either. A request that parks a connection, on a server that never reclaims one, costs a connection slot permanently.

**It is the HTTP/1 request-line path, not malformed input in general.** Given the same seed, the same rate and the same mutation engine, `destructive-radamsa-h2` leaves **0** of 60 000 requests unanswered where H1 leaves 8 366 of 59 501. The H2 framing layer answers a mutant it cannot accept — 25 791 `GOAWAY:PROTOCOL_ERROR` and 4 139 `RST_STREAM:REFUSED_STREAM` — rather than parking the connection. Both arms are the same kernel build and the same process family; only the protocol path differs.

**Scope of the claim.** One kernel version, one arm, loopback, `claim_scope: exploratory`. It is a reproducible property of that build, not a measured availability impact — no attempt was made to find the connection ceiling or to drive the target to refuse service.

This is also why the classifier no longer calls hangs `graceful-shed`. That label reads as a target deliberately and correctly shedding load, and it was applied to all 8 364 of these.

### The H2 outcome taxonomy was an H1 taxonomy until 2026-08-26

`destructive-radamsa-h2` ran for the first time on 2026-08-26 and returned a perfect-looking `response_count: 60000` out of 60 000 iterations, with zero rejections. That was not robustness; it was a degenerate measurement, and the 100 % rate is the tell.

Two H1 assumptions had been carried into an H2 driver:

1. **"The first bytes back mean the target answered."** True on HTTP/1.x, where a server sends nothing until it has something to say. False on HTTP/2: RFC 9113 §3.4 makes the server's SETTINGS frame the mandatory first thing it sends after the connection preface, and this driver sends the preface intact by design. Measured against kernel 0.11.0, an intact preface followed by pure garbage, followed by a single zero byte, and followed by nothing at all each returned the identical 9-byte empty SETTINGS frame. The campaign counted the target's own handshake 60 000 times.
2. **"Ending on a frame boundary means a response is owed."** The H1 analogue — a terminating CRLFCRLF — really does complete a request. A lone well-formed SETTINGS frame is equally well aligned on H2 and obliges the server to say nothing, so such a mutant timed out at the attacker's socket deadline and scored `hang` against a scenario declaring `max_hang_count: 0`. A correctly idle server would have failed the run. It fired once in a 400-iteration validation campaign.

The classifier now reads past the frames a server sends unprompted (SETTINGS, WINDOW_UPDATE) and decides on the first frame that actually answers the mutant; the completeness predicate additionally requires a client-initiated stream to have been opened to END_HEADERS and half-closed by END_STREAM. On the same 400-iteration validation the counters separated into 177 rejected / 126 responses / 97 incomplete-wait, with every other counter unchanged.

The payoff is `findings.outcome_details`, which histograms the target's GOAWAY and RST_STREAM error codes. On an all-zero crash/hang campaign that histogram is the only positive evidence produced: it names the layer that rejected each mutant — `FRAME_SIZE_ERROR` and `PROTOCOL_ERROR` come from the framing layer, `COMPRESSION_ERROR` from HPACK. `response_count` is **not comparable** between the 20260826-192933 run and later ones.

**Generalization worth keeping:** both defects had the same shape — a concept that is sound on one protocol silently reinterpreted on another, producing a *clean* result rather than an error. The H1 driver's own `rejected` and `incomplete-wait` corrections (#29) were the same shape. A destructive scenario reporting an unblemished score is a reason to check the classifier, not to publish.

### `destructive-slowloris-h1` reported the target's defence as a failure

The runner mapped the attacker's `connections_dropped` onto `hang_count`, and passed the same value to `destructive_classify` as its hang argument. Those are opposite meanings. Evicting a half-open connection is precisely the **defence** against slowloris; a target that did it would have been recorded as having hung that many times and pushed toward a degraded classification for behaving correctly. The first run scored `connections_dropped: 0`, so the inversion produced `hang_count: 0` and never showed itself.

The scenario now reports `connections_opened` and `connections_dropped` as their own fields, and `hang_count` is 0 — this driver has no per-request deadline of its own, so it has nothing to report as a hang. What the scenario gates on is liveness and the RSS delta.

The measurement itself matters beyond this scenario: `connections_dropped: 0` over a 120 s window means the target never evicted a half-open connection, which is what licenses the `incomplete-wait` outcome in the radamsa drivers. A target with no half-open eviction inside 120 s cannot have been the source of a 2 s attacker-side timeout. That value had been read into a shell variable and discarded, so the artifact carried it nowhere and left `notes` null.

### `arena-lifecycle-leak`, run twice on the corrected harness: no leak, and a discriminator that does not discriminate at n = 2

Two 600 s windows, 500 rps, back to back against the same warm process, kernel 0.11.0 (`5e29ae675020`), seed 424242:

| window | iterations | RSS delta | per request | early slope | late slope | late / early |
|---|---|---|---|---|---|---|
| A | 299 480 | +4 059 136 B (+1.17 %) | 13.6 B | 5 590.8 B/s | 7 080.1 B/s | **1.27** |
| B | 299 496 | +2 990 080 B (+0.85 %) | 10.0 B | 7 475.3 B/s | 6 589.9 B/s | **0.88** |

Both sit well inside the scenario's 5 % bound, the second window is *smaller* than the first, and the target's own allocator diagnostic reports `leak_count_delta: 0`. Determinism is close to exact: the two windows agree to 16 iterations in 299 480 and to 2 in a hang count of 46 110, with `incomplete_wait_count` identical at 14 952.

These figures replace **+40.4 %** and **+3.3 %** from the same scenario on the pre-fix harness. Nothing about the target changed; the earlier first window charged first-load cost to the attack and compared an uncollected baseline against a collected final sample.

**The least-squares early/late slope is not a usable leak discriminator here.** It was added to separate "growing" from "plateaued", and on these two windows it points in opposite directions — A accelerating, B decelerating — on the same process, the same workload and the same seed. One window in isolation would have supported either verdict. Quote the delta and the per-request figure, which agree across windows; treat the slope pair as a single noisy observation, not as evidence of shape, unless several windows agree.

**The 46 110 hangs here are not 46 110 retained connections.** The radamsa driver closes every socket in its `finally` block, so a parked connection is released by the attacker at its socket deadline and never accumulates. Retention was demonstrated separately, by a probe that deliberately holds connections open — see the finding above. This scenario shows the parking *rate* (15.4 %, consistent with `destructive-radamsa-h1`'s 14.1 % over a 5× shorter window), not its cost.

### Two RSS samples, one forced GC

Until 2026-08-27 all three destructive runners forced a GC before the **final** RSS sample and not before the baseline. The reported `rss_bytes_delta` was therefore a collected heap measured against an uncollected one — biased toward understating growth, and capable of any sign at all. On `destructive-radamsa-h2` it read **−588 517 376 bytes**: the baseline held a full post-warm-up heap, the final sample had just been collected.

Both samples are now preceded by a forced GC, so the delta compares two post-collection states — memory the target *retained*, which is the question a leak scenario is asking. Artifacts written before the change are not comparable with ones written after it.

Note this compounds with the warm-up fix rather than replacing it: warm-up moves the baseline past first-load cost, GC symmetry makes the two endpoints the same kind of measurement. Both are needed, and `baseline_warmup_seconds` in the artifact identifies which generation a run belongs to.

### A pid taken on trust can make a run incapable of failing

`--target-pid` was accepted without checking it against the target. On 2026-08-27 the `destructive-radamsa-h2` campaign was pointed at a pidfile holding the `bash -c "… java …"` wrapper rather than the JVM it spawned. The artifact recorded `rss_bytes_before == rss_bytes_after == 2 170 880` — 2.07 MB, a shell — and classified the run `stable` on a delta of exactly zero. Every `resource_delta` field, and the `degradation_class` resting on them, described a process that allocates nothing.

`destructive_resolve_target_pid` now checks the supplied pid against the process holding the listening socket, walks the process tree to correct a wrapper to its server child (a legitimate launch shape) with a loud warning, and refuses a pid unrelated to the port. Verdicts that can only pass are worse than no verdict.

### A failing emitter left an artifact that looked like a result

The first H2 campaign fired all 60 000 mutants and then died on two undeclared `jq` variables. Because the runners used `jq ... > "$FINDINGS_FILE"`, the shell truncated the target *before* `jq` ran, so the run left a 0-byte `destructive-findings.json` and the attack data survived only in the raw attacker stdout. All runner JSON now goes through `destructive_emit_json`, which stages to a temp file, rejects empty or non-object output, and only then moves it into place.

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

### e2e-shop-order-saga

| Field | Value |
|---|---|
| Scenario ID | `e2e-shop-order-saga` |
| Endpoints | `POST /auth/register` → `GET /products/recommended` → `POST /cart/add` → `GET /cart` → `POST /orders` (saga pivot) |
| Mode | `stateful-e2e-saga` |
| Tier | Community (first) |
| Driver | k6 |
| Transport | H2C (loopback) for the canonical Axon/Exeris contracts; H1 for the spring-on-exeris and Restate stacks |
| Authoritative contract | **`scenarios/e2e-shop-order-saga/CONTRACT-v2.md` (v2.0, DRAFT)** — supersedes v1 |

> **CONTRACT v2.0.** The normative spec is `CONTRACT-v2.md`; what is actually enforced today (`implemented-now` / `partial` / `deferred`, per §) is in `CONTRACT-v2-IMPLEMENTATION.md`. Breaking changes vs v1: deterministic per-`orderId` terminal decline (`stableHash64` = FNV-1a 64, `mod 1000 < 30` = exactly 3.0 %); `fault=terminal|transient` run classes; pinned retry (terminal 0 / transient max-3, 50 ms×2, no jitter); exact compensation oracle; latency split by `COMPLETED` vs `COMPENSATED` population; per-run durability-tier (T1/T2) with **cross-tier comparison forbidden** (§8). No claim may rely on a `partial`/`deferred` row without its caveat.

> **LOOPBACK CAVEAT:** canonical contracts run `transport_mode=loopback-h2c`; all result artifacts must carry it. Loopback is not equivalent to network-path.

#### Saga substrate axis

Postgres is the shared **domain** datastore for every stack (identical order/inventory/outbox writes, same schema); Neo4j is the shared **read-side** recommendation graph, seeded identically and never written by a saga step (CONTRACT-v2 §2, Postgres-amended 2026-07-17). The Exeris pgq↔neo4j driver swap is an Exeris-only side experiment, out of scope for comparison tables.

| Stack | Saga substrate | Status |
|---|---|---|
| `exeris-community` | Exeris Flow (L4 native) | comparison-eligible (`exeris_community_h2c_v1`) |
| `quarkus-hibernate` | Axon Framework | comparison-eligible (`quarkus_axon_neo4j_v1`) |
| `spring-hibernate` | Axon Framework | comparison-eligible (`spring_boot_axon_neo4j_v1`) |
| `spring-on-exeris` | `exeris-spring-runtime-flow` (compat) | exploratory only — H1 vs H2C protocol mismatch; separate category (not a pure-Spring stack) |
| `restate` | Restate durable execution (server + JVM SDK) | **baseline-only, NOT comparison-eligible** — no fixed_contract / manifest row; H1 facade |

Flow-vs-Axon is the axis under test; Axon is first-class for pure Spring/Quarkus and was never withdrawn.

#### Claim scope

| Scope | VUs | Measurement | Required profile | Allowed claims |
|---|---|---|---|---|
| `exploratory` | 100 | warmup only | dev-laptop, ci-runner | descriptive; RPS trends |
| `comparison-eligible` | 100 | 180 s | **perf-box-amd64** | throughput, p50/p99 per outcome population, saga success rate |

#### Seed

PostgreSQL (postgres:16.2) + Neo4j (5.16-community) per `scenarios/e2e-shop-order-saga/seed/seed-manifest.json`; Neo4j is projected from the Postgres baseline via `seed-neo4j-from-postgres.sh`. Pre-run `verify-seed.sh` exit 0 is mandatory; results without it are invalid.

#### Cross-runtime status

Comparative execution is constrained to the H2C loopback Neo4j track (`track_a_neo4j`) pairs declared in `comparative-pair-manifest.json` (exeris-community / quarkus-hibernate / spring-hibernate). PGQ and AGE tracks are `planned` / `compatibility_only`. **Restate and spring-on-exeris are excluded from comparative tables** (baseline-only and protocol-mismatch respectively). This is structural readiness; no published comparative result exists. v1 raw runs under `results/raw/e2e-shop-order-saga/` are re-classified per CONTRACT-v2 §10 — see `README-v1-retroactive-status.md` there; do not aggregate them with v2 runs.

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
