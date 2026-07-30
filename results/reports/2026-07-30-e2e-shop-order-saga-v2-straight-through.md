---
title: "Nothing parks, so nothing is orchestrated: three saga stacks under a straight-through workload"
date: 2026-07-30 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
summary: "First campaign under the corrected v2 saga contracts: three stacks (Exeris Community Flow, Quarkus+Axon, Spring Boot+Axon) × 3 repeats, 50 sessions/s constant-arrival-rate, 120 s warmup / 180 s measurement / 30 s cooldown, perf-box-amd64, 9/9 reps passing the exact-compensation gate at 497/497. Exeris leads saga latency on both outcome populations (COMPLETED p50 23 vs 31 vs 34 ms; COMPENSATED p50 23 vs 35 vs 38 ms — and it is the only stack whose compensation path costs nothing extra at the median) and leads target-JVM footprint by 1.9×/3.2×. It does NOT lead cost: whole-deployment CPU per saga is 20.6 / 10.6 / 20.9 ms, i.e. Exeris is ~2× Quarkus and level with Spring — and 76 % of the gap to Quarkus is a Neo4j N+1 traversal forced by the graph SPI, measured here at 7.9× the Neo4j CPU per saga, not the 2.6× the contract records. Two corrections travel with this dataset: the harness understated every container's CPU by the docker-stats sampling interval (~3×), so the campaign README's 11.7 / 6.85 / 14.8 ms figures are superseded by the ones here; and the whole session, not just the saga step, ties Exeris with Quarkus (47.6 vs 48.4 ms of summed step medians) because Exeris is 4–5× slower on the two graph reads that precede the order. The overriding caveat is structural: this workload is straight-through — nothing awaits an external system, nothing parks — so it measures a request path with compensation, not saga orchestration. It is workload A of a three-rung ladder; B (short park) and C (long park, N parked sagas) are unmeasured."
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: e2e-shop-order-saga
claim_scope: exploratory
reproducibility_status: complete
comparison_axis: within-tier-cross-framework
hardware_profile: perf-box-amd64
---

# Nothing parks, so nothing is orchestrated: three saga stacks under a straight-through workload

*A shop-order saga — Exeris Community (Flow) vs Quarkus + Axon vs Spring Boot + Axon — at a fixed 50 sessions/s, under CONTRACT-v2's deterministic terminal-decline fault model.*

*By **Arkadiusz Przychocki** · 2026-07-30 · categories: performance, benchmarking, jvm*

**Track:** Community · **Benchmark family:** Runtime · **Scenario:** `e2e-shop-order-saga` · **Contract:** `CONTRACT-v2.md` v2.0 (DRAFT) · **Workload profile key:** `e2e-shop-order-saga-community-h1-loopback-runtime-k6-inline-r50-v2` · **Bench commit:** `30b677f` · **Hardware profile:** `perf-box-amd64` · **Campaign:** [`20260730T161215Z-campaign-v2-r50`](../raw/e2e-shop-order-saga/20260730T161215Z-campaign-v2-r50/)

> **Claim scope: `exploratory`** · **Reproducibility: `complete`** · **Comparison axis: within-tier, cross-framework**
>
> This is **not** a `comparison_eligible` dataset and no sentence in it may be quoted as one. There are no `stage7-*` artifacts, no `fairness-index.json`, no AB/BA order control; every leaf's `claim-status.json` reads `claim_scope: exploratory`. What it *is*: nine independently-run reps with complete reproducibility metadata (commit SHA, JDK, tool versions, hardware profile, contract id, durability tier, seed manifest hashes, per-target JVM command lines), a hard pass/fail correctness gate that passed 9/9, and internal consistency tight enough to read the medians as real (identical p50 across all three repeats of every stack; issued populations within 6 sessions of each other; error rates ≤ 0.007 %).
>
> **Three caveats have to travel with every number below**, and they are stated once here rather than repeated per section: (1) the workload is **straight-through** — see §2, this is the caveat that bounds what the whole report means; (2) the campaign's own rollup reads `campaign_gate_status: not_evaluated` and that is correct output, not a stale file — see §1; (3) the target JVMs run on **default heap sizing**, not a matched budget, so every footprint figure is a default-configuration statement — see §6.

---

## TL;DR

Same three JVM stacks, same box, same seed data, same k6 script, same deterministic 3.0 % decline population. Load is a **fixed arrival rate**, so throughput is not a differentiator by construction — all three sustain ~49.7 sessions/s. What differs is latency, cost and footprint, and the three axes do not agree on a winner:

- **Saga latency — Exeris leads, on both populations.** `COMPLETED` p50 **23 vs 31 vs 34 ms** (Exeris **−25.8 %** vs Quarkus, **−32.4 %** vs Spring), p99 **39–41 vs 52–55 vs 86–91 ms**. On the `COMPENSATED` population the gap widens: p50 **23 vs 35 vs 38–39 ms**. Exeris is the only stack whose **compensation path costs nothing extra at the median** (23 → 23 ms); the Axon stacks pay **+12.9 %** and **+11.8–14.7 %** and Spring's compensated p99 nearly doubles (86–91 → 102–118 ms). That is CONTRACT-v2 §8's "journaling stacks pay ~2× journal entries on compensation" showing up as a measurement.
- **Cost — Exeris does not lead, and against Quarkus it loses roughly 2:1.** Whole-deployment CPU per saga is **20.6 / 10.6 / 20.9 ms** (Exeris / Quarkus / Spring). Exeris is **+95 %** against Quarkus and **level with Spring** (−1.5 %, inside the rep spread). **76 % of the gap to Quarkus is one thing**: the Neo4j N+1 traversal that `GraphTraversal` (exeris-kernel-spi) forces on the recommendation step — **8.74 vs 1.10 ms of Neo4j CPU per saga, 7.9×**. Net that out and Exeris is +23 % against Quarkus and −38 % against Spring. This is API expressiveness, not runtime efficiency, and it is the single largest actionable finding in the dataset.
- **Footprint — Exeris leads, by a lot, but read the qualifier.** Target-JVM peak RSS **467 vs 888 vs 1 496 MB**; counting each stack's own required sidecar (Axon Server), stack-attributable RSS is **467 MB in one process vs 1 825 MB in two vs 2 634 MB in two** — **1/3.9** and **1/5.6**. All three JVMs ran with **no heap flags at all**, so this is a *default-configuration* footprint claim on a 62 GB box: Exeris's G1 settled at a 96 MB committed heap, Quarkus at 368–392 MB, Spring at 472–560 MB. It is not a matched-heap or matched-budget result, and it must not be quoted as one.
- **The saga step is not the session.** The 23-vs-31 headline is the `POST /api/v1/orders` request. Summing the medians of all five steps a session performs, Exeris and Quarkus are **level — 47.6 vs 48.4 ms** — because Exeris is **5.4× slower on the recommendation read** (3.98 vs 0.74 ms) and **5.5× slower on the cart read** (4.58 vs 0.82 ms). The saga win is real and so is the read-path deficit; only one of them is in the headline.
- **Correctness: 9/9, exactly.** Every rep issued ~16 370 orders and observed **497 compensations against exactly 497 expected** — the FNV-1a-64 oracle over the exactly-issued orderId population, hard pass/fail. Zero `FAILED_UNRECOVERED`, zero unresolved sagas, error rate ≤ 0.007 %.

**And the caveat that outranks all five:** every step in this saga returns `CONTINUE`/`COMPLETE`/`FAIL`. Nothing awaits an external system; nothing parks. Structurally this is a transaction script with compensation — which is precisely what `quarkus-hibernate` implements, and the most likely reason it is competitive. These numbers are a valid measurement of a **request path**; they do not support a claim about **saga orchestration**. See §2.

---

## Setup

| | |
|---|---|
| **Hardware** | AMD Ryzen 7 **7700 (8C/16T)**, 62 GB RAM, governor `performance`, **turbo/boost OFF**, dedicated bare metal, no other workloads |
| **OS / kernel** | Linux `6.8.0-134-generic`, scheduler EEVDF |
| **JDK** | Eclipse Temurin **26.0.1** (`openjdk 26.0.1 2026-04-21`), identical on all three targets |
| **Driver** | **k6 `v2.0.0`**, `constant-arrival-rate` executor, **50 sessions/s** in all three phases, think time 800–2500 ms random, identical script and identical seeded orderId population on every stack |
| **Windows** | **120 s warmup + 180 s measurement + 30 s cooldown**, fail-closed fixed contracts |
| **Repeats** | **3 per stack**, run sequentially, infra torn down between reps |
| **Transport** | **HTTP/1.1 cleartext over loopback** (`transport_mode=loopback-h1`), protocol observed and asserted per rep — no TLS |
| **Fault model** | CONTRACT-v2 §4.1 business-terminal decline: `fnv1a64(orderId) mod 1000 < 30`, **exactly 3.0 %** of a deterministic, identical-across-stacks population; zero retries; routes to LIFO compensation |
| **Durability tier** | `T2-fsync-node-durable-postgres` on all nine reps — **label-only**, sourced from `default:postgres-synchronous-commit-on`, not independently verified |
| **DB pool** | max 32 per target, identical; peak observed backends 16–32, never capped |
| **Shared backends** | PostgreSQL 16.2 (domain datastore, all stacks, identical schema and writes) + Neo4j (read-side recommendation graph, seeded identically, never written by a saga step), both in containers on a bridge network |
| **Targets** | `exeris-community` (Exeris kernel Flow, in-process) · `quarkus-hibernate` (Quarkus 3 + Axon + Hibernate, `quarkus_axon_neo4j_h1_v2`) · `spring-hibernate` (Spring Boot 3 + Axon + Hibernate, `spring_boot_axon_neo4j_h1_v2`) — all JVM mode |
| **Deployment unit** | per CONTRACT-v2 §1, the *minimal production-plausible deployment*: Exeris = **1 JVM** + shared backends; both Axon stacks = **1 JVM + Axon Server** + shared backends |

**Fairness posture — read before the numbers:**

1. **Load is offered, not extracted.** `constant-arrival-rate` at 50/s means all three stacks are given the same work and none is driven to saturation — target JVMs sit at **0.24–0.56 of one core** on a 16-thread box. Nothing here is a capacity or throughput result, and the latency percentiles are consequently **not** coordinated-omission-affected in the closed-loop sense. The 3 % shortfall against nominal (49.7 achieved vs 50.0 offered, ~134 dropped iterations per rep) is uniform across stacks and comes from the k6 VU-pool ceiling, not from any target.
2. **Heaps are not matched — nothing is.** No target received a single heap or GC flag; the only JVM arguments present are NMT and the module opens Exeris requires. Every RSS number is therefore "what this stack does when you don't tell it anything", which is a legitimate and interesting posture but a *different* one from the entity-read triad's equal-budget model. §6 states it again where the numbers are.
3. **Domain writes are equal; graph access is not.** Postgres is the shared domain datastore and every stack performs the same writes against the same schema. The Neo4j *dataset* is shared and identically seeded, but the **access pattern is not**: the Axon stacks issue one Cypher query expressing the two-hop join server-side, while `exeris-community` issues **1 + N traversals**, because `GraphTraversal` carries exactly one `GraphEdgeDescriptor` and no `GraphSession` method accepts a heterogeneous edge path. The N+1 is **forced by the SPI, not chosen by the adapter** (CONTRACT-v2 §2). Consequently `recommend_latency_ms` is comparable only in the platform-natural sense and **must not** be read as a runtime-speed comparison.
4. **Saga-state durability is asymmetric, and it is not priced.** Exeris persists flow state to Postgres. The Axon stacks' saga and token stores were verified **in-memory** as wired (`n_tup_ins = 0` on `saga_entry`, `association_value_entry`, `token_entry`); their durable surface is Axon Server's event store. Both satisfy the contract's guarantees for fault-only runs, but Exeris is paying Postgres CPU for a checkpoint the Axon stacks do not write, and the Axon stacks are paying Axon Server CPU for an event store Exeris does not run. The CPU comparison in §5 includes both; neither is normalized away, and this asymmetry is the honest reason the whole-deployment figure is the right one to quote and the target-JVM figure is not.
5. **Latency figures are whole-run.** The outcome-split trends come from the k6 end-of-run summary, i.e. aggregated over warmup + measurement + cooldown, not filtered to the measurement window (CONTRACT-v2-IMPLEMENTATION §8). All three stacks reach steady state within 8–11 s of a 120 s warmup, so the contamination is small — but it is present, uniformly, and the numbers are labelled whole-run for that reason.
6. **All three comparison-eligible stacks return the terminal outcome inline.** The v1-era polling model — which quantized saga duration to a client poll sleep and was large enough to *reverse* the apparent ordering — is gone for these three. `spring-on-exeris` remains polled and is excluded from this campaign entirely.

**Reading the percentages.** Every delta is written **"A vs B"** and is **A relative to B**, with **Exeris always in the A position**, including where that means reporting a deficit.

---

## 1. What this campaign is, and the two things its own artifacts say against it

**The rollup says `not_evaluated`, and that is the correct output.** `campaign-gate-summary.json` records 8 pass + 1 absent and refuses to certify the campaign. It was written when `spring-hibernate-rep-3` had failed at the DB seed and produced no gate. That rep was subsequently re-run standalone and its artifacts in the directory are from that clean re-run — so the *final state on disk* is 9/9 pass, while the *runner's verdict* is `not_evaluated`. The artifact was deliberately **not** overwritten: rewriting it to say `pass` would erase the fact that a rep failed. The full sequence, including that the first re-run of rep 3 overlapped a Maven build on the same box and was **discarded as uncontrolled despite matching the clean reps exactly**, is recorded in `campaign-completion-note.json`. Anyone auditing this dataset should read the note before the summary. (`durability_tier_uniform: false` in the same file is an artifact of the absent rep reporting `unknown`; all nine reps are T2.)

**The rep-3 failure was a security incident, not flakiness.** The seed failed because the box's Postgres was internet-exposed and had been accessed, with the `postgres` role password altered. Remediated in `56e3e95` (ports bound to `127.0.0.1`, rogue superuser roles dropped, connection logging enabled). Results taken while a third party held superuser access are not above suspicion. What argues the workload data was intact is internal consistency rather than assertion: **identical p50 across all three repeats of every stack**, exact 497/497 gate matches in all nine, issued populations within 6 sessions, and per-rep CPU and RSS figures agreeing within a few percent. That is evidence, not proof, and it is offered as such.

**Gate scope.** The correctness gate is CONTRACT-v2 §7's **interim** substitute, not the specified external oracle: a **count-granularity O2 approximation**. It verifies `observed_compensations == expected_declines` exactly, over the exactly-issued population reconstructed from `oidx`-tagged k6 samples. It does **not** verify per-`(orderId, stepId, direction)` ledgers, **LIFO ordering**, **O1** duplicate execution, or **O3** orphaned effects. A stack could pass this gate while violating O1 or O3. No claim below depends on more than the count.

---

## 2. The workload taxonomy — and why this is only rung A

Every step of this saga returns `CONTINUE`/`COMPLETE`/`FAIL`. Nothing awaits an external system, so nothing parks, so no `FlowSnapshotStore.save()` fires and no durable saga state is exercised. Structurally the workload is a **transaction script with compensation** — which is exactly what the Quarkus target implements (Axon as a command bus with the saga inlined), and the most plausible reason it is competitive here rather than paying for orchestration it never uses.

The consequences are specific, and were established alongside this campaign:

- **The orchestration engines never earn their keep.** Durable saga machinery pays off when a step awaits an external event, or when the process can die mid-flight and resume. This workload exercises neither, so §5's cost comparison is a comparison of transport, ORM, graph access and event plumbing — **not of durability, because nobody is buying durability here.**
- **Crash injection cannot discriminate on this workload.** The kernel's recovery guarantee is scoped to *parked* flows; a saga that never parks has no snapshot and nothing to resume. Asking any stack to recover one is asking for a guarantee none of them makes.

That is why this report is explicitly rung **A** of a three-rung ladder, and why the rungs answer different questions with different metrics:

| workload | question it answers | key metrics | is latency meaningful? |
|---|---|---|---|
| **A — straight-through** (this report) | what does the request path cost when the saga completes inline? | latency, CPU/saga, RSS | **yes** — the only rung where it is |
| **B — short park (~100 ms)** | what does an async hop cost, and does the engine handle it without holding resources? | wake throughput, CPU/saga, resources held while parked | partly — dominated by the stub |
| **C — long park (N = 10–50 k / 100 k / 100 k+)** | can you hold N parked sagas at all, at what cost, and do they survive a restart? | bytes per parked saga, idle CPU at N, parked-capacity ceiling, restart survival + recovery time | **no** — park duration is business time |

The design for rung B — park `charge-payment` on an external payment-gateway stub with a 100 ms callback (1 s for crash runs) — is written up in [`PROPOSAL-parking-payment-step.md`](../../scenarios/e2e-shop-order-saga/PROPOSAL-parking-payment-step.md) and its decisions were resolved on 2026-07-30. It requires new contract ids and a new `workload_profile_key`: **straight-through results must never be aggregated with parking results.** Everything in §3–§6 is therefore bounded to rung A, permanently.

---

## 3. Saga latency, split by outcome population

CONTRACT-v2 §8 forbids mixing `COMPLETED` and `COMPENSATED` — they are structurally different code paths, and blending them buries exactly the architectural difference under test. Both populations, all nine reps, whole-run:

**`COMPLETED` (~15 870 per rep, 97.0 %):**

| | Exeris | Quarkus + Axon | Spring + Axon |
|---|---|---|---|
| p50 | **23 / 23 / 23 ms** | 31 / 31 / 31 | 34 / 34 / 34 |
| p95 | **31 / 31 / 31** | 42 / 42 / 41 | 64 / 64 / 64 |
| p99 | **39 / 41 / 40** | 53 / 55 / 52 | 90 / 91 / 86 |
| max | 109 / 94 / 103 | 143 / 128 / 128 | 260 / 302 / 309 |
| mean | **23.4** | 31.4 | 37.5 |

**`COMPENSATED` (exactly 497 per rep, 3.04 %):**

| | Exeris | Quarkus + Axon | Spring + Axon |
|---|---|---|---|
| p50 | **23 / 23 / 23 ms** | 35 / 35 / 35 | 39 / 38 / 38 |
| p95 | **30 / 33 / 32** | 46 / 46 / 46 | 70 / 76 / 74 |
| p99 | **37 / 42 / 67** | 57 / 58 / 55 | 118 / 107 / 102 |
| max | 76 / 68 / 83 | 146 / 151 / 88 | 166 / 205 / 200 |
| **p50 penalty vs its own COMPLETED** | **0.0 %** | **+12.9 %** | **+11.8 – 14.7 %** |

Three readings, in decreasing order of how firm they are:

1. **The ordering is Exeris < Quarkus < Spring on every percentile of both populations, and it reproduces exactly.** All three repeats of every stack land on an identical p50; p95 varies by at most 1 ms within a stack. With a fixed offered rate and 0.24–0.56 cores of utilization, this is service time, not queueing.
2. **The compensation penalty is the architectural finding.** Exeris compensates at the same median it completes at. Both Axon stacks pay a measurable median penalty and Spring pays a large tail penalty — its compensated p99 (102–118 ms) is ~1.2–1.3× its own completed p99, on top of already being the widest distribution. This is the §8 prediction ("journaling stacks pay ~2× journal entries on compensation") appearing as data. **It is not a durability claim in Exeris's favour**: per fairness note 4, the Axon saga stores are in-memory here, so the penalty is event-store round-trips, not fsync.
3. **One number is soft.** Exeris rep-3's compensated p99 reads **67 ms** against 37 and 42 in the other two reps. The compensated population is 497 samples, so p99 is the ~5th-worst observation and is a low-confidence statistic by construction. Do not quote a compensated p99 for Exeris more precisely than "37–67 ms across three reps". The p50 and p95 are stable and are the ones to cite.

---

## 4. The saga step is not the session

The headline above is the `POST /api/v1/orders` request. A session performs five requests, and the saga is one of them. Medians of each step, means across reps:

| step | Exeris | Quarkus + Axon | Spring + Axon | Exeris vs Quarkus |
|---|---|---|---|---|
| register (`POST /auth/register`) | 4.38 ms | 4.29 | 4.46 | +2.0 % |
| **recommend** (graph, 2-hop) | **3.98** | **0.74** | **0.91** | **+440 %** |
| cart add | 12.18 | 11.73 | 11.94 | +3.8 % |
| **cart get** (graph traversal) | **4.58** | **0.82** | **1.00** | **+457 %** |
| **order create (the saga)** | **22.71** | 30.73 | 33.93 | **−26.1 %** |
| **sum of medians** | **47.83** | **48.31** | **52.24** | **−1.0 %** |
| pooled `http_req_duration` p99 | **31.4** | 41.9 | 64.2 | −25.0 % |

Read the last two rows together. **On the pooled request distribution Exeris wins** — its p99 across all requests is 25 % below Quarkus's — because the saga step dominates the tail. **On the sum of per-step medians the two are level**, because Exeris gives back on the two graph reads almost exactly what it wins on the order.

The recommendation deficit is explained and expected: it is the SPI-forced N+1 of fairness note 3, and CONTRACT-v2 §2 already rules `recommend_latency_ms` platform-natural-only. **The cart-get deficit is not explained.** `GET /api/v1/cart` is a traversal of a much smaller subgraph, and Exeris is 5.5× slower on it than Quarkus and 4.6× slower than Spring — a ratio close enough to the recommendation step's to suggest the same 1+N mechanism, but that is a hypothesis this dataset does not test. **Open item**, recorded rather than resolved.

The measured Neo4j-access ratios also **do not match what the contract records**. CONTRACT-v2 §2 states "2.6× the Neo4j CPU per iteration and 2.5× the recommendation latency" for `exeris-community`. Under this load model the same measurements read **7.9× the Neo4j CPU per saga** (§5) and **5.4× the recommendation latency**. The contract's figures predate the 3/s → 50/s load-model amendment, under which idle overhead dominated and would compress exactly this kind of ratio; that is the likely cause but it is an inference, not a measurement. Either way **the contract's numbers should not be quoted against this dataset**, and §2 needs updating.

---

## 5. Cost per saga — and a harness correction that changes the answer

### 5.1 The correction

The campaign README quotes whole-deployment CPU per saga as **quarkus 6.85 ms, exeris 11.7 ms, spring 14.8 ms**. Those figures are wrong, in a way that understates every *container's* contribution and therefore distorts the ranking, because container CPU is a different share of the total for each stack.

`deployment-footprint.json` computes `cpu_core_seconds = (cpu_pct_avg / 100) × sample_seconds`, and `sample_seconds` comes from `_csv_rows()` in `scripts/run-e2e-shop-order-saga-baseline.sh:1554`, whose comment reads *"sample count == seconds, sampler ticks at 1 Hz"*. The sampler loop does `sleep 1` — but each iteration also runs `docker stats --no-stream`, which blocks ~2 s because it needs two CPU samples. The measured cadence in every rep is **3.006 s**: 113 rows spanning 336.7 s of wall clock, against a run whose own iteration count and rate put it at 338.9 s. So every container's `cpu_core_seconds`, and `container_cpu_core_seconds_per_iteration` with it, is understated by ~3×. The target-JVM figures are unaffected — they come from the per-process sampler, which really does tick at ~1 Hz (338 samples over 343 s) and reports cumulative CPU time rather than an integrated rate.

The figures below are recomputed directly from the `epoch_ms` column of the per-container `*-docker-stats.csv` files committed with each rep, integrating `cpu_pct` over the actual sampled window. **The fix in the harness is to derive the window from `epoch_ms` (last − first + one interval) rather than from the row count** — the CSV already carries everything needed.

### 5.2 Whole-deployment CPU per saga

Per CONTRACT-v2 §1 the unit of comparison is the whole deployment, so this table sums the target JVM and every process the stack requires. Means of 3 reps; per-rep spread in the appendix.

| CPU per saga (ms) | Exeris | Quarkus + Axon | Spring + Axon |
|---|---|---|---|
| target JVM | 7.14 | **4.98** | 11.77 |
| Postgres (shared, domain) | 4.74 | **3.31** | 3.41 |
| Neo4j (shared, read-side) | **8.74** | **1.10** | 1.31 |
| Axon Server (stack-specific) | — | 1.18 | 4.45 |
| **whole deployment** | **20.62** | **10.57** | **20.93** |
| processes in the unit | **3** | 4 | 4 |
| target JVM, cores used (avg) | 0.340 | **0.238** | 0.561 |

Four readings:

1. **Quarkus wins this axis outright, by ~2:1 against both others** — despite carrying an Axon Server process neither of the other units' costs can hide. Its target JVM is the cheapest (4.98 ms), its Postgres cost is the lowest, and its Axon Server overhead is small (1.18 ms). This is the strongest single result in the dataset against Exeris, and §2 is why it is fair to say it does not settle much: a transaction script is cheap precisely because it is a transaction script.
2. **Exeris and Spring are level on the total and completely different in composition.** Exeris spends 42 % of its budget in Neo4j and only 35 % in its own JVM; Spring spends 56 % in its JVM and 21 % in Axon Server. Same bill, different vendors.
3. **76 % of Exeris's gap to Quarkus is the graph N+1.** Exeris pays **8.74 vs 1.10 ms** of Neo4j CPU per saga — **7.9×**, and 7.64 ms of a 10.05 ms total gap. Substitute Quarkus's Neo4j cost and Exeris lands at **12.99 ms**: still **+23 %** against Quarkus, but **−38 %** against Spring. That counterfactual is arithmetic, not a measurement — it assumes only the graph term changes — but it bounds how much of the deficit is attributable to an SPI limitation rather than to the runtime. **Making `GraphSession` express a heterogeneous edge path is the highest-value change this dataset points at.**
4. **Exeris's Postgres cost is the highest (4.74 vs 3.31/3.41 ms), and part of that is bought durability.** Exeris checkpoints flow state to Postgres; the Axon stacks' saga stores are in-memory (fairness note 4). The +1.4 ms is not decomposed here — it mixes flow-state writes with whatever else differs in the domain-write path — so it is reported, not attributed.

---

## 6. Footprint

Per-process RSS under load, 1 Hz sampling over the whole run; NMT `summary` cross-checks committed memory. Means of 3 reps.

| | Exeris | Quarkus + Axon | Spring + Axon |
|---|---|---|---|
| target JVM, peak RSS | **467 MB** | 888 MB | 1 496 MB |
| target JVM, avg RSS | **428 MB** | 847 MB | 1 367 MB |
| NMT total committed | **297 MB** | 728 MB | 950 MB |
| — committed heap | **96 MB** | 384 MB | 528 MB |
| — non-heap (NMT − heap) | **201 MB** | 344 MB | 422 MB |
| threads (avg / peak) | **81 / 88** | 88 / 94 | 119 / 125 |
| stack-specific sidecar RSS | — (none) | 937 MB (Axon Server) | 1 138 MB (Axon Server) |
| **stack-attributable RSS** | **467 MB, 1 process** | **1 825 MB, 2 processes** | **2 634 MB, 2 processes** |

**The qualifier comes first this time.** None of the three JVMs received a heap or GC flag — the entire JVM argument list is `-XX:NativeMemoryTracking=summary` plus, for Exeris, the module opens and `--enable-preview` it requires. On a 62 GB box that means each JVM chose its own heap under G1's defaults, and it chose very differently: 96 vs 384 vs 528 MB committed. **So this is a default-configuration footprint result.** It says what these stacks do when you deploy them as they ship, which is a real and defensible question; it says nothing about per-object efficiency, and it is not the entity-read triad's equal-budget model. A matched-heap run would be the way to separate policy from footprint, and none was made here.

With that stated, two things are worth noting. Exeris's advantage is **not only heap** — its non-heap committed (201 MB) is the smallest of the three as well, by 1.7× and 2.1×. And the number that actually matters for a deployment is the last row: the Exeris unit is **one process at 467 MB**; both Axon units are **two processes**, at 1 825 and 2 634 MB — **3.9× and 5.6×**.

**Σ RSS of the whole deployment is reported in the artifacts (2.3–4.3 GB per rep) and is deliberately not the headline.** It is dominated by Neo4j's page cache (~2.1–2.9 GB, essentially identical on every stack) and Postgres's fixed `shared_buffers`, both of which are shared backends whose raw RSS **compresses** real between-stack differences rather than showing them. The per-rep `backend_idle_baseline` block is there for anyone wanting the delta-over-idle form; the sidecar-inclusive row above is the honest whole-deployment footprint statement.

---

## 7. Correctness

| | Exeris | Quarkus + Axon | Spring + Axon |
|---|---|---|---|
| expected declines (FNV-1a 64 oracle) | 497 | 497 | 497 |
| **observed compensations** | **497 / 497 / 497** | **497 / 497 / 497** | **497 / 497 / 497** |
| orders issued | 16 367 / 16 371 / 16 365 | 16 367 / 16 365 / 16 368 | 16 371 / 16 369 / 16 369 |
| `saga_status_resolved` | 1.000 | 1.000 | 1.000 |
| `FAILED_UNRECOVERED` | 0 | 0 | 0 |
| error rate | 0.0012 – 0.0061 % | 0.0037 – 0.0061 % | 0.0049 – 0.0073 % |
| `admission_rejected` | 0 | 0 | 0 |

**9/9 exact.** The v1-era "Axon zero compensations" defect class does not reproduce: both Axon stacks route the deterministic decline to compensation on every one of the 497 declined orderIds, in every rep. Because the declined subset is deterministic and known a priori, this is an exact-integer assertion, not a statistical one.

What it does **not** establish, restating §1: no LIFO ordering check, no per-step compensation ledger, no duplicate-execution detection, no orphaned-effect detection. The count is right; the shape of what produced it is unverified.

---

## 8. What this dataset points at next

In the order I would run them:

1. **Rung B — the parking workload** ([`PROPOSAL-parking-payment-step.md`](../../scenarios/e2e-shop-order-saga/PROPOSAL-parking-payment-step.md), decisions resolved, nothing implemented). It is the change that makes the scenario measure saga orchestration instead of a sequence of HTTP calls, and it fixes the crash-injection power problem for free: at 50/s with a 100 ms callback, ~5 sagas are parked at any instant against today's ~1.2 in-flight. Note in advance what the proposal already warns: **with a park, end-to-end latency is dominated by the stub and loses most of its discriminating power** — a rung-B report must lead with CPU per saga, RSS, throughput at a given parked concurrency and recovery behaviour, not with saga duration.
2. **The `GraphSession` heterogeneous-edge-path gap.** §5 puts a number on it: 7.64 ms of the 10.05 ms whole-deployment gap to Quarkus. It is the single largest actionable item here, and it is an API-expressiveness fix, not a performance one.
3. **The cart-get deficit (§4).** 5.5× on a small traversal, unexplained. Cheapest possible probe: count Bolt round-trips per `GET /api/v1/cart` on each stack.
4. **The harness fix in §5.1**, plus a re-emit of `deployment-footprint.json` for this campaign so the committed artifacts agree with this report.
5. **A matched-heap footprint run**, to separate default heap policy from footprint (§6).
6. **Contract §2's 2.6× / 2.5× figures**, which this dataset contradicts (§4) and which are load-model-dependent.

---

## Limitations

- **Not `comparison_eligible`.** No strict-gate artifacts, no fairness index, no AB/BA order control. The 9/9 correctness gate is a *correctness* gate, not a comparative-eligibility gate, and `campaign_gate_status` reads `not_evaluated` for the reason in §1.
- **Rung A only.** Nothing parks. No claim here transfers to a workload where a saga awaits an external event, survives a restart, or holds durable state across a park. That is not a caveat on the numbers; it is a bound on the question they answer.
- **n = 3 per stack, sequential, no order counterbalancing.** The reps agree tightly, but a systematic order effect would be invisible to this design.
- **Latency is whole-run**, not measurement-window-filtered (fairness note 5).
- **Fixed arrival rate.** No capacity, saturation or throughput-ceiling claim is available from this dataset. CONTRACT-v2 records that at 100/s `exeris-community` loses its measurement phase to connection resets; 50/s is the highest rate clean on every stack, and that limit is itself an unexplored finding.
- **Durability tier is a label.** `T2-fsync-node-durable-postgres` is stamped from a default, not verified per run. Cross-tier comparison is forbidden by §8 and none is attempted.
- **Default heap sizing** (§6) — the footprint result is a default-configuration statement.
- **The security incident** (§1). Internal consistency argues the data is intact; it does not prove it.
- **Loopback, single box.** Kernel and softirq work for the HTTP path lands on the target's cores and is part of what CPU-per-saga buys. Nothing here transfers to a real-network deployment.
- **Whole-deployment CPU is summed without correction** — a shared backend's CPU under load is attributed to the stack that drove it. Combined with fairness note 4's durability asymmetry, this means §5's total is a *deployment* cost, not a normalized runtime cost, and it is quoted only as the former.

---

## Appendix — per-rep figures

**Saga `COMPLETED` p50 / p95 / p99 (ms), by rep:**

| stack | rep 1 | rep 2 | rep 3 |
|---|---|---|---|
| exeris-community | 23 / 31 / 39 | 23 / 31 / 41 | 23 / 31 / 40 |
| quarkus-hibernate | 31 / 42 / 53 | 31 / 42 / 55 | 31 / 41 / 52 |
| spring-hibernate | 34 / 64 / 90 | 34 / 64 / 91 | 34 / 64 / 86 |

**Whole-deployment CPU per saga (ms), recomputed per §5.1, by rep:**

| stack | rep 1 | rep 2 | rep 3 | mean |
|---|---|---|---|---|
| exeris-community | 20.19 | 21.73 | 19.94 | 20.62 |
| quarkus-hibernate | 10.59 | 10.61 | 10.50 | 10.57 |
| spring-hibernate | 20.77 | 20.98 | 21.05 | 20.93 |

**Target-JVM peak RSS (MB), by rep:**

| stack | rep 1 | rep 2 | rep 3 | mean |
|---|---|---|---|---|
| exeris-community | 455 | 476 | 470 | 467 |
| quarkus-hibernate | 913 | 878 | 872 | 888 |
| spring-hibernate | 1 404 | 1 523 | 1 562 | 1 496 |

**Source artifacts** for all nine reps — `result.json`, `k6-summary.json`, `k6-throughput-series.json`, `correctness-gate.json`, `claim-status.json`, `resource-metrics.json` (with NMT), `deployment-footprint.json`, `run-metadata.json`, `env.json`, per-container docker-stats CSVs, Postgres connection samples, JVM command lines and NMT dumps — are committed under [`results/raw/e2e-shop-order-saga/20260730T161215Z-campaign-v2-r50/`](../raw/e2e-shop-order-saga/20260730T161215Z-campaign-v2-r50/). Raw k6 NDJSON streams (~296 MB per rep, ~2.7 GB total), `.jfr` recordings and the 1 Hz resource-sample CSVs stay on the perf box — excluded for size. These are Community recordings, so the exclusion is logistics, not the Enterprise `.jfr` confidentiality rule.
