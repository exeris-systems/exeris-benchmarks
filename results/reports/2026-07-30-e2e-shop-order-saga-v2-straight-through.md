---
title: "Nothing parks, so nothing is orchestrated: three saga stacks under a straight-through workload"
date: 2026-07-30 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
summary: "First campaign under the corrected v2 saga contracts: three stacks (Exeris Community Flow, Quarkus+Axon, Spring Boot+Axon) × 3 repeats, 50 sessions/s constant-arrival-rate, 120 s warmup / 180 s measurement / 30 s cooldown, perf-box-amd64, 9/9 reps passing the exact-compensation gate at 497/497. Exeris shows the lowest saga latency on both outcome populations (COMPLETED p50 23 / 31 / 34 ms; COMPENSATED p50 23 / 35 / 38 ms) and the smallest target-JVM footprint by 1.9×/3.2×. Neither is a ranking: the three stacks do not execute the same work in this shape (sync-on-request-thread vs async-through-Axon vs flow scheduler), so latency is descriptive per stack — uniform terminal-outcome resolution is not execution equivalence, which is why the campaign's brief comparison_eligible label was reverted. The one cross-stack latency result that survives is a within-stack delta, each stack its own control: Exeris's compensation path costs nothing extra at the median (+0.0 %) where the Axon stacks pay +12.9 % and +11.8–14.7 %. Every cost comparison involving Exeris fails for a second, independent reason — a benchmark-app defect this report retracts an earlier attribution for. Exeris's recommendation step queries a `BOUGHT` edge type that the Neo4j seed never creates (probe: `db.relationshipTypes()` returns SIMILAR_TO, PURCHASED_BY, IN_CART — no BOUGHT) and keys nodes by UUID where the seed keys by integer, so hop 1 returns empty, the N+1 never executes, and a swallowed-exception fallback silently serves the answer from Postgres — a wholly non-functional graph path that looked like a slow-but-working one for an entire campaign. Its 7.9× Neo4j CPU is therefore NOT the SPI-forced N+1 the contract predicts; a PROFILE probe names the real mechanism, and it is cheaper to fix: the emitted traversal anchors on an unlabelled node, so the label-scoped index cannot be used — 35 742 db hits against 6 for the label-scoped equivalent, with the labels alone accounting for all of it. Whole-deployment CPU per saga (20.6 / 10.6 / 20.9 ms) is what this deployment cost as configured, not a runtime comparison; only the Quarkus-vs-Spring pair is clean. Also corrected: the harness understated every container's CPU by the docker-stats sampling interval (~3×), superseding the campaign README's 11.7 / 6.85 / 14.8 ms. The overriding caveat is structural: this workload is straight-through — nothing awaits an external system, nothing parks — so it measures a request path with compensation, not saga orchestration. It is workload A of a three-rung ladder; B (short park) and C (long park, N parked sagas) are unmeasured."
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

> # ⛔ RETIRED — 2026-07-31. Do not cite any figure from this report.
>
> This report is kept as a record of how the defects were found, **not as a source of
> results.** No number in it may be quoted forward — in a later report, a talk, a
> slide, or a summary — including the numbers this report itself presents as
> corrections.
>
> Five independent invalidators, any one of which would be sufficient on its own:
>
> 1. **Nothing parked.** No step awaited an external system, so the workload is a
>    transaction script with compensation, not saga orchestration — which is what the
>    title already says. Superseded by CONTRACT-v2 §2.1 shape A (minimal park).
> 2. **Exeris's recommendation traversal matched nothing** and was served from a
>    Postgres fallback. Recomputed from the committed footprints, Neo4j accounted for
>    **8.63 ms of Exeris's 20.33 ms** whole-deployment CPU per saga (42 %) and **76 % of
>    the Exeris-vs-Quarkus gap** — spent scanning for rows that could never match. Every
>    Exeris-vs-* cost row is void.
> 3. **Container CPU was understated ~3×** (sample rows read as seconds). Fixed in
>    `97999c4`; the correction changed the ordering, not just the magnitudes.
> 4. **Quarkus persists no saga state at all** — its saga does not survive a restart.
>    CONTRACT-v2 §8 already prohibited comparing across durability tiers, and this
>    campaign did it anyway. Every Quarkus-vs-* cost row is void.
> 5. **Provenance.** The run was taken while a third party held Postgres superuser on
>    the box (remediated in `56e3e95`).
>
> The graph path was subsequently repaired (`42fa5ef`) and then removed from this
> scenario altogether: it confounded the only comparison the scenario exists to make.
> The full disposition, the fairness axes that were violated, and the sequence of work
> before the next campaign are in
> [`scenarios/e2e-shop-order-saga/REMEDIATION-PLAN.md`](../../scenarios/e2e-shop-order-saga/REMEDIATION-PLAN.md).

# Nothing parks, so nothing is orchestrated: three saga stacks under a straight-through workload

*A shop-order saga — Exeris Community (Flow) vs Quarkus + Axon vs Spring Boot + Axon — at a fixed 50 sessions/s, under CONTRACT-v2's deterministic terminal-decline fault model.*

*By **Arkadiusz Przychocki** · 2026-07-30 · categories: performance, benchmarking, jvm*

**Track:** Community · **Benchmark family:** Runtime · **Scenario:** `e2e-shop-order-saga` · **Contract:** `CONTRACT-v2.md` v2.0 (DRAFT) · **Workload profile key:** `e2e-shop-order-saga-community-h1-loopback-runtime-k6-inline-r50-v2` · **Bench commit:** `30b677f` · **Hardware profile:** `perf-box-amd64` · **Campaign:** [`20260730T161215Z-campaign-v2-r50`](../raw/e2e-shop-order-saga/20260730T161215Z-campaign-v2-r50/)

> **Revision history — what this report claimed, and what measurement took away.**
>
> - **2026-07-30, first draft.** Attributed Exeris's 7.9× Neo4j CPU per saga to the **SPI-forced 1+N traversal** that CONTRACT-v2 §2 documents, called it "76 % of the gap to Quarkus", and named the `GraphSession` heterogeneous-edge-path gap as the highest-value fix. Called the cart-read deficit "not explained".
> - **2026-07-30, same day — retracted by code reading plus live probes** (recorded in [`graph-path-defect-probe.json`](../raw/e2e-shop-order-saga/20260730T161215Z-campaign-v2-r50/graph-path-defect-probe.json)). The N+1 **never executed**. Exeris's hop 1 traverses `User-[:BOUGHT]->Product`; the Neo4j seed creates `PURCHASED_BY` and `SIMILAR_TO` and no `BOUGHT` at all, and keys nodes by integer where the adapter keys by UUID — two independent mismatches, either sufficient on its own. Hop 1 returns empty, `GraphShopAdapter` returns `List.of()`, the N loop never starts, and `RepositoryBackedBenchmarkUseCaseService.getRecommendedProducts` silently falls back to Postgres. **The 7.9× figure is a real measurement whose stated cause was wrong**, and the SPI gap — while real — is **not** what this dataset priced, because this dataset never ran it.
> - **The mechanism that replaced it is cheaper to fix and is now measured, not hypothesised.** The traversal Exeris emits anchors on an *unlabelled* node, so Neo4j's label-scoped indexes (including the seed's own `user_id_unique` / `product_id_unique` constraints) cannot be used and the plan degrades to a scan. A `PROFILE` of the two shapes on the live graph: **35 742 db hits against 6**. Adding labels alone closes it completely; the redundant `MATCH p =` path binding costs **zero** db hits and is cosmetic.
> - **2026-07-30, third correction — the latency ranking goes too, for an unrelated reason.** The first draft read §3 as "Exeris < Quarkus < Spring on every percentile". The three stacks do not execute the same work in this shape — Quarkus runs the saga synchronously on the request thread, Spring asynchronously through Axon Server, Exeris through the flow scheduler — so the rows are **descriptive per stack**. The campaign was briefly labelled `comparison_eligible` on the grounds that terminal-outcome resolution had been made uniform; **uniform resolution is not equivalent execution**, and the label was reverted. What survives as cross-stack is the *within-stack* compensation delta, where each stack is its own control.
> - **And the graph steps were never a graph measurement for anyone.** `cart add` / `cart get` write an `IN_CART` edge and read it back only to discard the result, on **all three** stacks, with the answer served from Postgres. Only `recommend` feeds a real answer, and only on the two Axon stacks. So the scenario's graph surface is two synthetic touchpoints plus one real query that is broken on one stack — a second heterogeneous backend in the session, not a graph benchmark.
> - **Left visible on purpose**, because the failure mode is the point: a `catch (RuntimeException ignored)` plus an empty-result fallback made a completely non-functional graph path look like a slow-but-working one, and it survived a full campaign, a contract section written around it, and the first draft of this report.
>
> **Claim scope: `exploratory`** · **Reproducibility: `complete`** · **Comparison axis: within-tier, cross-framework**
>
> This is **not** a `comparison_eligible` dataset and no sentence in it may be quoted as one. There are no `stage7-*` artifacts, no `fairness-index.json`, no AB/BA order control; every leaf's `claim-status.json` reads `claim_scope: exploratory`. What it *is*: nine independently-run reps with complete reproducibility metadata (commit SHA, JDK, tool versions, hardware profile, contract id, durability tier, seed manifest hashes, per-target JVM command lines), a hard pass/fail correctness gate that passed 9/9, and internal consistency tight enough to read the medians as real (identical p50 across all three repeats of every stack; issued populations within 6 sessions of each other; error rates ≤ 0.007 %).
>
> **Four caveats have to travel with every number below**, and they are stated once here rather than repeated per section: (1) the workload is **straight-through** — see §2, this is the caveat that bounds what the whole report means; (2) **the three stacks do not execute the same work in this shape** (sync-on-request-thread vs async-through-Axon vs flow scheduler), so latency rows are descriptive per stack and not a ranking — see §3; (3) the campaign's own rollup reads `campaign_gate_status: not_evaluated` and that is correct output, not a stale file — see §1; (4) the target JVMs run on **default heap sizing**, not a matched budget, so every footprint figure is a default-configuration statement — see §6.
>
> Caveats (1) and (2) are the same underlying fact seen twice: because nothing parks, each stack is free to pick a different execution shape for the same observable contract, and they did. The parking workload is what forces the shapes to converge.

---

## TL;DR

Same three JVM stacks, same box, same seed data, same k6 script, same deterministic 3.0 % decline population. Load is a **fixed arrival rate**, so throughput is not a differentiator by construction — all three sustain ~49.7 sessions/s. What differs is latency, cost and footprint, and the three axes do not agree on a winner:

- **Saga latency — Exeris is lowest on both populations, but this is not a ranking.** `COMPLETED` p50 **23 / 31 / 34 ms**, p99 **39–41 / 52–55 / 86–91 ms**; `COMPENSATED` p50 **23 / 35 / 38–39 ms**. **The three stacks do not execute the same work in this shape**: Quarkus runs the whole saga synchronously on the request thread, Spring asynchronously through Axon Server, Exeris through the flow scheduler. All three return the terminal outcome inline, so they share an *observable* contract — resolution-model uniformity, which is what briefly made this look comparison-eligible — but that is not execution equivalence, and these rows must not be read as "Exeris is faster than Quarkus". They are descriptive per stack.
- **The one cross-stack thing the latency data does show is a within-stack delta**, which is immune to that objection because each stack is its own control: **Exeris is the only stack whose compensation path costs nothing extra at the median** (23 → 23 ms, **+0.0 %**), while the Axon stacks pay **+12.9 %** and **+11.8–14.7 %** and Spring's compensated p99 rises to 102–118 ms from 86–91. That is CONTRACT-v2 §8's "journaling stacks pay ~2× journal entries on compensation" showing up as a measurement.
- **Cost — no Exeris comparison is usable, and that is the largest finding here.** Whole-deployment CPU per saga is **20.6 / 10.6 / 20.9 ms** (Exeris / Quarkus / Spring): what these deployments cost as configured, but **not** a runtime comparison, because Exeris's recommendation step was not doing the same work as anyone else's — it was doing *broken* work (§4.1). **76 % of the gap to Quarkus does sit in one term** — Neo4j CPU, **8.74 vs 1.10 ms per saga, 7.9×** — and that term is now attributed to an unlabelled traversal anchor that forces a scan where the other stacks get an index seek (**35 742 vs 6 db hits**, §4.2), not to the SPI-forced N+1 the first draft named and the contract predicts. **Only the Quarkus-vs-Spring pair is a clean cost comparison in this dataset**, and there Quarkus wins ~2:1 while carrying an extra Axon Server process.
- **Footprint — Exeris leads, by a lot, but read the qualifier.** Target-JVM peak RSS **467 vs 888 vs 1 496 MB**; counting each stack's own required sidecar (Axon Server), stack-attributable RSS is **467 MB in one process vs 1 825 MB in two vs 2 634 MB in two** — **1/3.9** and **1/5.6**. All three JVMs ran with **no heap flags at all**, so this is a *default-configuration* footprint claim on a 62 GB box: Exeris's G1 settled at a 96 MB committed heap, Quarkus at 368–392 MB, Spring at 472–560 MB. It is not a matched-heap or matched-budget result, and it must not be quoted as one.
- **The saga step is not the session — and the rest of the session is where the defect lives.** The 23-vs-31 headline is the `POST /api/v1/orders` request, which **touches no graph in any of the three stacks**, so it is unaffected by everything above. Summing the medians of all five steps a session performs, Exeris and Quarkus are **level — 47.8 vs 48.3 ms** — because Exeris is 5.4× slower on the recommendation read (3.98 vs 0.74 ms) and 5.5× slower on the cart read (4.58 vs 0.82 ms). The first of those two is not a comparison at all; the second is the controlled one, and it is what names the mechanism.
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
3. **Domain writes are equal; graph access is not — and on the recommendation step it is not even equivalent.** Postgres is the shared domain datastore and every stack performs the same writes against the same schema. The Neo4j *dataset* is shared and identically seeded, but the **access pattern is not**. CONTRACT-v2 §2 records the intended asymmetry — the Axon stacks issue one Cypher query expressing the two-hop join server-side, while `exeris-community` must issue 1 + N traversals because `GraphTraversal` carries exactly one `GraphEdgeDescriptor` — and rules `recommend_latency_ms` platform-natural-only on that basis. **In this dataset the actual asymmetry is different and worse:** Exeris's recommendation traversal matches nothing, returns empty, and falls back to Postgres, so the step measures a failed lookup plus a SQL query against the other stacks' working graph recommendation. The two are not comparable in *any* sense, platform-natural included. §4.1 documents this; it is a benchmark-app defect, and it is the reason this campaign needs a re-run on that axis.
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

> **These rows are descriptive per stack, not a ranking — and the reason is not the usual one.** The three stacks do not execute the same work in this shape: `quarkus-hibernate` runs the whole saga **synchronously on the request thread**, `spring-hibernate` **asynchronously through Axon Server**, `exeris-community` **through the flow scheduler**. All three return the terminal outcome inline, so they share an observable contract — and that resolution-model uniformity is exactly what briefly got this campaign mislabelled `comparison_eligible`. **Uniform resolution does not imply equivalent execution**, and the label was reverted on those grounds. What restores equivalence is the parking shape (§2 rung B), where every stack must implement dispatch → park → external event → wake and therefore does the same *shape* of work. Until then, read the columns down, not across.

Three readings, in decreasing order of how firm they are:

1. **Each stack's numbers reproduce exactly, which is what makes them worth recording at all.** All three repeats of every stack land on an identical p50; p95 varies by at most 1 ms within a stack. With a fixed offered rate and 0.24–0.56 cores of utilization, these are service times rather than queueing artifacts — a clean per-stack characterisation, and the input a rung-B campaign will be compared against.
2. **The compensation penalty is the architectural finding, and it survives the equivalence objection** — it is a *within-stack* delta, each stack acting as its own control, so it does not depend on the three executing alike. Exeris compensates at the same median it completes at. Both Axon stacks pay a measurable median penalty and Spring pays a large tail penalty — its compensated p99 (102–118 ms) is ~1.2–1.3× its own completed p99, on top of already being the widest distribution. This is the §8 prediction ("journaling stacks pay ~2× journal entries on compensation") appearing as data. **It is not a durability claim in Exeris's favour**: per fairness note 4, the Axon saga stores are in-memory here, so the penalty is event-store round-trips, not fsync.
3. **One number is soft.** Exeris rep-3's compensated p99 reads **67 ms** against 37 and 42 in the other two reps. The compensated population is 497 samples, so p99 is the ~5th-worst observation and is a low-confidence statistic by construction. Do not quote a compensated p99 for Exeris more precisely than "37–67 ms across three reps". The p50 and p95 are stable and are the ones to cite.

---

## 4. The saga step is not the session

The headline above is the `POST /api/v1/orders` request. A session performs five requests, and the saga is one of them. Medians of each step, means across reps:

| step | graph? | Exeris | Quarkus + Axon | Spring + Axon | Exeris vs Quarkus |
|---|---|---|---|---|---|
| register (`POST /auth/register`) | no | 4.38 ms | 4.29 | 4.46 | +2.0 % |
| **recommend** | yes | **3.98** | **0.74** | **0.91** | **+440 %** ⚠ not comparable — §4.1 |
| cart add | yes (write) | 12.18 | 11.73 | 11.94 | +3.8 % |
| **cart get** | yes (read) | **4.58** | **0.82** | **1.00** | **+457 %** — §4.2 |
| **order create (the saga)** | **no** | **22.71** | 30.73 | 33.93 | **−26.1 %** |
| **sum of medians** | | **47.83** | **48.31** | **52.24** | −1.0 % ⚠ |
| pooled `http_req_duration` p99 | | **31.4** | 41.9 | 64.2 | −25.0 % ⚠ |

**Read the "graph?" column first.** The saga step — the one §3 is about — touches no graph in any of the three apps. All three call their graph adapter at exactly three sites: recommend, cart-add (upsert), cart-get (read). So §3 is clear of §4.1's defect (it has its own, separate limit — execution non-equivalence, stated there), while the two ⚠ rows are not, because they sum a step that measures different work in different stacks.

**And the graph steps do not measure the graph, for anyone.** `cart add` and `cart get` are **decorative on all three stacks**: each writes an `IN_CART` edge and reads it back only to **discard the result**, then serves the view from Postgres (§4.2). Only `recommend` feeds a real answer — and only on Quarkus and Spring, where `recommendedProducts` uses the returned ids and falls back to SQL solely when they are empty. So of the three graph touchpoints, **two are synthetic load on every stack and the third is broken on one of them**. No graph-performance claim is available from this scenario for any stack; what the graph provides here is a second heterogeneous backend in the session, which is a fair thing to want and a different thing from a graph benchmark.

On the pooled request distribution Exeris wins — its p99 across all requests is 25 % below Quarkus's — because the saga step dominates the tail. On the sum of per-step medians the two are level. Both statements are arithmetic; neither is a fair comparison until §4.1 is fixed.

### 4.1 The recommendation step is not a comparison — it is a defect

Exeris's recommendation traversal **matches nothing**, and it has done so for the whole campaign.

`GraphShopAdapter` declares hop 1 as `GraphEdgeDescriptor.create("User", "BOUGHT", "Product")` ([`GraphShopAdapter.java:15-16`](../../targets/exeris-community-app/src/main/java/eu/exeris/benchmarks/targets/exeriscommunity/infrastructure/graph/GraphShopAdapter.java)). The Neo4j seed creates no such relationship. Probed on the live box:

```
CALL db.relationshipTypes()  →  "SIMILAR_TO", "PURCHASED_BY", "IN_CART"
MATCH ()-[r:BOUGHT]->() RETURN count(r)  →  0
```

`BOUGHT` exists only in [`runtime/db/seed/v4_pgq_graph.sql`](../../runtime/db/seed/v4_pgq_graph.sql) — the **PGQ** backend, not the Neo4j track this campaign pinned. And the direction differs anyway: the seed writes `(:Product)-[:PURCHASED_BY]->(:User)`, the adapter asks for `User→Product`.

A **second, independent** mismatch would break it even if the edge type matched: the seed keys nodes by integer (`MERGE (u:User {id: toInteger(row.id)})`, [`seed-neo4j-from-postgres.sh:240`](../../scenarios/e2e-shop-order-saga/seed/seed-neo4j-from-postgres.sh)), while the adapter keys by `UUID.nameUUIDFromBytes("user-N")`. Probed: `MATCH (n) WHERE toString(n.id) CONTAINS "-" RETURN count(n)` → **0**. No node in the graph carries a UUID-shaped id.

The consequence is straight-line code, not inference — hop 1 returns empty, so [`GraphShopAdapter.java:48-50`](../../targets/exeris-community-app/src/main/java/eu/exeris/benchmarks/targets/exeriscommunity/infrastructure/graph/GraphShopAdapter.java) returns `List.of()` and the N loop never starts, and then:

```java
try {
    List<UUID> graphNodeIds = graphShopAdapter.recommendProductNodeIdsFromGraph(userId, boundedLimit);
    List<Long> ids = productRepository.resolveProductIdsFromGraphNodeIds(graphNodeIds, boundedLimit);
    if (!ids.isEmpty()) { return productRepository.findByIdsPreserveOrder(ids, boundedLimit); }
} catch (RuntimeException ignored) {
}
return productRepository.findRecommendedForUser(userId, boundedLimit);
```

The fallback fires on the empty result *and* on any exception, so **`recommend_latency_ms` for Exeris measures one fruitless Neo4j scan plus a Postgres recommendation query**, while for Quarkus and Spring it measures a working two-hop graph recommendation. Different work, different result content, different datastore. Not slow-versus-fast.

Three consequences, all of which this report has to carry rather than resolve:

1. **The `recommend` row above is void**, and so is the SPI-forced-N+1 attribution the first draft built on it. **The SPI gap is real** — `GraphTraversal` genuinely carries one `GraphEdgeDescriptor` and no `GraphSession` method accepts a heterogeneous edge path, so the two-hop join genuinely cannot be expressed in one call — but **this dataset never executed the 1+N it would have forced**, and so prices nothing about it. A change of that size wants a measurement that actually runs the path.
2. **Part of Exeris's +1.4 ms Postgres CPU per saga (§5) is this fallback**, running a recommendation query the other two stacks never issue. Previously that delta was reported as undecomposed with saga-state checkpointing as the leading candidate; it now has a second, more mundane contributor.
3. **The defect survived a whole campaign because it was designed to be invisible.** `catch (RuntimeException ignored)` plus an empty-result fallback means a completely disconnected graph path returns correct-looking data at plausible-looking latency. Nothing in the harness, the correctness gate, the contract or the first draft of this report caught it. The check that would have — *assert the graph path returned a non-empty result at least once* — costs nothing and does not exist.

### 4.2 The cart read is the controlled experiment, and it names the mechanism

`GET /api/v1/cart` is where the comparison is clean, and it is clean by construction:

- **Both stacks do the same shape**: traverse `IN_CART`, **discard the result**, then serve the view from Postgres. Exeris: `graphShopAdapter.readCartProductNodeIds(userId)` inside `try { } catch (RuntimeException ignored) { }`, return `cartRepository.getCart(userId)`. Quarkus: `graphShopService.cartProductIds(uid)`, return `buildCartView(conn, uid)`. Identical instrumentation of the same wasted traversal.
- **Both do one round-trip.** No N+1 on either side — Exeris's cart traversal is single-hop over one edge type, which is exactly what the SPI expresses well.
- **Exeris's cart path is self-consistent**: writer and reader both key by UUID, so unlike the recommendation path it does find its own edges.

Same query count, same discard-and-fall-back-to-Postgres shape, and Exeris is still **5.5× slower than Quarkus and 4.6× slower than Spring**. Query count cannot explain it.

**A `PROFILE` probe on the live graph does.** Per a reading of `CommunityGraphDialect.buildMultiHopQuery` (kernel source, not in this repository — attributed, not verified here), the dialect emits `MATCH p = (source)-[:X*1..N]->(target) WHERE source.id = $sourceId RETURN DISTINCT target.id` — an **unlabelled** anchor, with the `sourceNode()`/`targetNode()` labels present in the descriptor and dropped. Neo4j's indexes are label-scoped, including the seed's own `user_id_unique` and `product_id_unique` constraints, so an unlabelled anchor cannot seek. Both shapes, same graph, same single-row answer:

| shape | db hits | vs seek |
|---|---|---|
| A — unlabelled anchor + `MATCH p =` (as emitted) | **35 742** | **5 957×** |
| A2 — unlabelled anchor, no path binding | 35 742 | 5 957× |
| A3 — **labelled** anchor, `MATCH p =` retained | **6** | 1× |
| B — `MATCH (u:User {id: $uid})-[:IN_CART]->(p:Product)` (Quarkus) | **6** | 1× |

The decomposition is unusually clean: **the missing labels are the entire cost, and the redundant `MATCH p =` path binding costs exactly zero db hits.** A3 — same variable-length traversal, same path binding, labels restored — lands on the seek's number precisely. So the fix is "emit the labels the descriptor already carries"; dropping `MATCH p =` is worth doing for allocation but is not the lever.

Two caveats on this subsection. The db-hit figures are **not** a wall-clock model — a 5 957× db-hit ratio produced a 5.5× latency ratio, because the traversal is a small part of a request that also does HTTP, JSON and a Postgres cart read. And the scan cost is **not constant during a run**: the graph grew by ~16 400 `User` nodes and ~16 400 `IN_CART` edges over each rep (probed post-run: 17 369 `User` nodes against a 1 000-user seed), so a scanning plan gets steadily worse while a seek does not.

### 4.3 The contract's own graph figures do not hold here — and the reason is now open

CONTRACT-v2 §2 states "2.6× the Neo4j CPU per iteration and 2.5× the recommendation latency" for `exeris-community`. This dataset reads **7.9× the Neo4j CPU per saga** (§5) and **5.4× the recommendation latency**. The first draft attributed the divergence to the 3/s → 50/s load-model amendment compressing ratios through idle overhead. That remains plausible and it is **not** established — it now has at least two competitors that this dataset cannot separate: the query shapes and the graph contents both changed between the campaigns, and §4.1 means the contract's sentence describes a mechanism that was not running. **None of the three should be recorded as the cause.** What is firm: **§2's numbers must not be quoted against this dataset**, and §2's description of *why* Exeris is slower on the graph is wrong for this campaign regardless of which explanation wins.

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

**Before reading any row: every Exeris column here is contaminated by §4.1.** Exeris spent Neo4j CPU on a traversal that matched nothing and Postgres CPU on a fallback query the others never issue, and both land inside this table. The totals are a faithful record of **what these deployments cost as configured**; they are **not** a runtime cost comparison, and no ranking involving Exeris survives from them. **The Quarkus-vs-Spring pair is unaffected** — both run the working graph path — and is the only clean comparison in the table.

Four readings:

1. **Quarkus beats Spring on this axis by ~2:1, cleanly** — despite carrying an Axon Server process Spring also carries. Its target JVM is less than half of Spring's (4.98 vs 11.77 ms) and its Axon Server overhead is a quarter (1.18 vs 4.45 ms), for the same workload and the same event-sourcing framework. That is a framework-hosting result, and §2 bounds it: a transaction script is cheap precisely because it is a transaction script.
2. **Composition differs far more than the totals.** Exeris spends 42 % of its budget in Neo4j and 35 % in its own JVM; Spring spends 56 % in its JVM and 21 % in Axon Server. Even setting §4.1 aside, "20.6 vs 20.9" would be two different bills that happen to add up alike.
3. **76 % of Exeris's gap to Quarkus is the Neo4j term — and the cause is §4.2, not the SPI.** Exeris pays **8.74 vs 1.10 ms** of Neo4j CPU per saga (**7.9×**), which is 7.64 ms of a 10.05 ms total gap. Substitute Quarkus's Neo4j cost and Exeris lands at 12.99 ms — +23 % against Quarkus, −38 % against Spring. **Treat that counterfactual as an upper bound on the fix's value, not as a corrected result**: it is arithmetic on a contaminated run, it assumes only the graph term moves, and the recommendation step would have to start *doing more work* (an actual traversal instead of an immediate empty return) before it can start doing it faster. The first draft attributed this term to the SPI-forced N+1 and named the `GraphSession` heterogeneous-path gap as the top fix; **that attribution is retracted** — the N+1 never ran (§4.1), and the measured mechanism is the unlabelled traversal anchor (§4.2), which is a dialect fix rather than an SPI change.
4. **Exeris's Postgres cost is the highest (4.74 vs 3.31/3.41 ms), and it now has two candidate causes rather than one.** Exeris checkpoints flow state to Postgres where the Axon stacks' saga stores are in-memory (fairness note 4) — that was the first draft's reading, and it is still live. But §4.1's fallback issues a `findRecommendedForUser` query per session that neither Axon stack runs, and that lands in the same +1.4 ms. The delta stays **reported, not attributed**, and it is now explicitly *not* usable as a durability-cost figure.

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

In the order I would run them. **The first two are prerequisites, not follow-ups: until they land, this campaign's cost numbers cannot be re-quoted for anything involving Exeris.**

0. **Fix `GraphShopAdapter`'s edge model and node keying, then re-run.** Hop 1 must traverse the relationship the Neo4j seed actually creates (`PURCHASED_BY`, `Product→User`, so the two-hop shape is `User ← PURCHASED_BY ─ Product → SIMILAR_TO → Product`), and node identity must match the seed's integers rather than `nameUUIDFromBytes`. Then **delete the silent fallback** — or at minimum assert once per run that the graph path returned a non-empty result — because the fallback is what made this survivable for a whole campaign. Only after that does a §5 cost comparison involving Exeris mean anything, and only then does the SPI's 1+N actually execute and become measurable.
0b. **Emit labels in `CommunityGraphDialect.buildMultiHopQuery`** (kernel). The descriptor already carries `sourceNode()`/`targetNode()`; emitting them takes 35 742 db hits to 6 (§4.2). The query text is observable, so it travels with an `AbstractGraphDialectTck` update. Dropping the redundant `MATCH p =` binding is worth doing alongside but is measurably not the lever.

1. **Rung B — the parking workload** ([`PROPOSAL-parking-payment-step.md`](../../scenarios/e2e-shop-order-saga/PROPOSAL-parking-payment-step.md), decisions resolved, nothing implemented). It is the change that makes the scenario measure saga orchestration instead of a sequence of HTTP calls, and it fixes the crash-injection power problem for free: at 50/s with a 100 ms callback, ~5 sagas are parked at any instant against today's ~1.2 in-flight. Note in advance what the proposal already warns: **with a park, end-to-end latency is dominated by the stub and loses most of its discriminating power** — a rung-B report must lead with CPU per saga, RSS, throughput at a given parked concurrency and recovery behaviour, not with saga duration.
2. **The `GraphSession` heterogeneous-edge-path gap — still real, but demoted and unpriced.** `GraphTraversal` carries one `GraphEdgeDescriptor` and no `GraphSession` method accepts a heterogeneous edge path, so the two-hop recommendation genuinely cannot be expressed in one call. That is an ADR/v0.11-scale change, and it should be justified by a measurement that **executes** the 1+N it would remove. This dataset does not: §4.1 means the 7.64 ms it appeared to price is the unlabelled-anchor scan, not the N+1. Re-measure after item 0.
3. **A Neo4j query log for one rep of each stack**, giving Bolt round-trips per `GET /recommend` and per `GET /cart`. It confirms §4.1 and §4.2 from the server side in a single artifact, and it is the check that should have existed before the campaign ran.
4. **The harness fix in §5.1**, plus a re-emit of `deployment-footprint.json` for this campaign so the committed artifacts agree with this report.
5. **A matched-heap footprint run**, to separate default heap policy from footprint (§6).
6. **Correct CONTRACT-v2 §2.** Its 2.6× / 2.5× figures do not hold here and its stated mechanism did not run (§4.3). Both the numbers and the causal sentence need revising, with the load-model dependence stated rather than assumed.

---

## Limitations

- **The recommendation path is broken in the Exeris target (§4.1), and this bounds the dataset more than any other limitation here.** Every cost figure involving Exeris — target-JVM CPU, Postgres CPU, Neo4j CPU, whole-deployment total — includes work that is wasted, missing, or in the wrong datastore. **Quarkus vs Spring is unaffected. Exeris vs anything, on cost, is not usable and is published as a record of the run rather than as a comparison.** §3 (saga latency) and §6 (footprint) are clear of it: the saga step touches no graph in any stack, and the defect costs CPU and latency, not resident memory.
- **Not `comparison_eligible`.** No strict-gate artifacts, no fairness index, no AB/BA order control. The 9/9 correctness gate is a *correctness* gate, not a comparative-eligibility gate, and `campaign_gate_status` reads `not_evaluated` for the reason in §1. Note that the gate passing 9/9 while §4.1's defect ran undetected is itself a finding about gate coverage: the oracle checks compensation counts, and nothing checks that a stack's declared data path executed.
- **Rung A only.** Nothing parks. No claim here transfers to a workload where a saga awaits an external event, survives a restart, or holds durable state across a park. That is not a caveat on the numbers; it is a bound on the question they answer.
- **Execution is not equivalent across the three stacks** (§3): sync-on-request-thread vs async-through-Axon vs flow scheduler. Latency and cost rows are per-stack descriptions; only within-stack deltas (the compensation penalty) are cross-stack readable. Rung B is what forces the shapes to converge, and it is the reason a rung-B campaign is a prerequisite for any ranking rather than an enrichment of this one.
- **The graph steps do not measure the graph** (§4). Two of the three graph touchpoints — cart add and cart get — write and read an edge whose result is discarded on **every** stack, with the answer served from Postgres. The third is broken on Exeris. Nothing here supports a graph-performance claim for any stack, and `recommend_latency_ms` / `cart_get_latency_ms` should not appear in a comparison table at all until that changes.
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
