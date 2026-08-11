---
title: "DRAFT — Where the request actually goes: a Spring hosting ladder and the ORM axis, measured on both hosts"
date: 2026-08-11 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
summary: "TODO — write LAST, after every section is final. Must not strengthen any quantifier the body uses, and every bound must be the one measured on the axis being claimed. See the four-surface sweep note at the bottom."
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: entity-read-by-id
claim_scope: comparison_eligible
reproducibility_status: complete
comparison_axis: within-tier
hardware_profile: perf-box-amd64
---

# DRAFT — Where the request actually goes: a Spring hosting ladder and the ORM axis, measured on both hosts

*One Spring application served five ways, plus a native baseline, under two fixed contracts on dedicated bare metal.*

> **DRAFT STATUS.** Sections marked **[PENDING wrk2]** are waiting on the open-loop campaign
> launched 2026-08-11 (`20260811T063920Z-l5-curve-orm`, `…-l5-curve-tail`). Every number already
> present is from a committed, gate-passing campaign and is cited to it. **No number in this file
> is provisional or estimated** — a slot is either filled from artefacts or explicitly empty.

---

## What this report adds over [the 2026-07-21 triad](2026-07-21-entity-read-by-id-tuned-pg-triad-comparison-eligible.md)

That report compared **runtimes** (Exeris vs Quarkus vs Quarkus+Hibernate). This one holds the
*application* fixed and moves the layers underneath it one at a time:

| # | arm | web layer | persistence | mode |
|---|---|---|---|---|
| 1 | `spring-hibernate` | Tomcat + Spring MVC | Spring Data JPA + Hibernate | pure |
| 2 | `spring-jdbc` | Tomcat + Spring MVC | `JdbcTemplate` + `RowMapper` | pure |
| 3 | `spring-on-exeris` | Exeris **compat** dispatcher | Spring Data JPA + Hibernate | **compat** |
| 4 | `spring-on-exeris-pure` | Exeris native (`@ExerisRoute`) | Spring Data JPA + Hibernate | pure |
| 5 | `spring-on-exeris-pure-native` | Exeris native | kernel-native `TransactionalExecutor` | pure |
| — | `exeris-community` | kernel `HttpRouter`, hand-written handlers | kernel-native | pure (reference) |

Three things are new and none of them existed on 2026-07-21:

1. **Arm 2 turns an assumption into a measurement.** The migration-order conclusion in
   [`docs/CLAIMS.md` L3](../../docs/CLAIMS.md) rested on measuring the ORM's cost on the
   *Exeris-hosted* arm and applying it to Tomcat, because no ORM-free Tomcat arm existed.
   It does now.
2. **The attribution of that cost is corrected** (§5). It is not simply "Hibernate".
3. **Service-time latency for the Spring family** — the series has never had any. **[PENDING wrk2]**

---

## TL;DR

<!-- Write this AFTER the body. It is one of the four summarizing surfaces; see the sweep note. -->

- **The repository layer accounts for ×3.95 of cpu/req on the DB-bound aggregate and ×1.17 on the
  single-row read — and it is not simply Hibernate (§5).** The contract dependence *is* the
  finding, not a detail: the cost scales with rows materialised, so quoting either number alone
  misstates it. Measured on Tomcat with everything else held fixed — same host, same Boot 4.1.0,
  same security config, same SQL shapes, only the repository layer differs: 1074.7 → 271.8 µs/req
  heavy, 143.6 → 122.5 µs light, n=6 per arm, 12/12 leaves `comparison_eligible` (§4).
- **Until this campaign that was an assumption.** The migration-order conclusion rested on
  measuring the repository cost on the *Exeris-hosted* arm and applying it to Tomcat, because no
  ORM-free Tomcat arm existed (L3). It does now, and the direction holds.
- **The hosting swap is the smaller effect, and its size is bounded from below, not pinned.**
  Moving one identical Spring+JPA application from Tomcat to the Exeris native web layer buys
  **121.52 µs/req (×1.127)** against a repository layer worth **723.97 µs/req — 67.2 % of the
  request** (L3, L4). So runtime work is optimising the smaller third. **Qualifier that must
  travel with ×1.127:** the two arms differ in per-request security work as well as in hosting —
  the Tomcat arm runs a servlet `SecurityFilterChain`, the Exeris arm carries no Spring Security
  at all — and that difference has never been measured on the Tomcat side. It is not a rounding
  error against a 121.52 µs step: a filter chain costing 10 / 20 / 30 µs per request would be
  **8.2 % / 16.5 % / 24.7 %** of the entire hosting gain. Unbounded because unmeasured (§6 — the hosting ladder).
- **The cost is the Spring Data repository layer, not Hibernate — and this report retracts the
  plain-"ORM" label for it.** JFR puts Spring AOP and reflection *above* Hibernate's own tuple
  materialisation in that arm. The two arms differ by **two** things: Hibernate **and** Spring
  Data interface projections, which proxy one object per returned row. The mechanism is what
  produces the contract dependence — heavy returns ~200 rows and pays ~200 proxy constructions,
  light calls `findById`, gets a managed entity, and pays none (§5). **Practical consequence:**
  the cheapest fix for a Spring team is therefore not `JdbcTemplate` but dropping interface
  projections for DTO constructor expressions, staying on JPA — a change of return types, and
  an unmeasured first rung of the migration order L3 recommends.
- **Which numbers may be quoted at all depends on where the ceiling is.** On heavy the fast arms
  saturate the Postgres cpuset and the slow ones do not, so a heavy *throughput* ratio between a
  fast and a slow arm reads the database, not the stack. cpu/req survives it; throughput does not
  (§3).
- **Footprint and idle cost** — §6. **[PENDING: consolidate L8 + RSS across the ladder]**
- **Latency** — **[PENDING wrk2]**. Until that campaign lands, this report makes **no
  service-time claim whatsoever**: every percentile in the series so far comes from a closed-loop
  driver at saturation and measures queue occupancy (§7).

**What this report will not claim:** any service-time comparison from the closed-loop campaigns;
any transfer of the heavy ranking to a setup where the database is not the bottleneck; any
attribution of the repository-layer cost to Hibernate specifically (§5).

---

## Setup

| | |
|---|---|
| **Hardware** | AMD Ryzen 7 7700 (8C/16T), 62 GB RAM, governor `performance`, turbo **off**, dedicated bare metal |
| **JDK** | Eclipse Temurin 26.0.1 |
| **Driver** | wrk 4.1.0 closed-loop, 4 threads / 128 connections (`driver.mode=closed`) — throughput and resource metrics only. wrk2 open-loop for §7 **[PENDING]** |
| **Transport** | HTTP/1.1 cleartext over loopback (`transport_mode=loopback-h1`) |
| **CPU pinning** | targets `0-1,8-9` · loadgen `2-3,10-11` · Postgres `4-7,12-15`, disjoint, SMT siblings pinned as units |
| **Backend** | PostgreSQL 16.2 + cpuset isolation (`BENCH_DB_TUNED=1`). **Container network mode differs by campaign and is not a report-wide property — see the table below.** |
| **Memory** | equal 2048 MB budget per target; **iso-heap 1280 MB** on every arm including `exeris-community`, whose harness default is 256 |
| **DB pool** | min 16 / max 256, identical on all arms |
| **Windows** | 300 s warmup + 900 s measurement per arm (wrk2 phase: 60 s + 120 s) |
| **Contracts** | heavy `fixed_contract_cross_runtime_h1_v2` (3 queries, ~9.2 KB) · light `fixed_contract_cross_runtime_h1_single_read_v1` (1 PK row, ~125 B) |

**Campaigns behind this report** (all committed under `results/raw/entity-read-by-id/`):

| campaign | arms | n | DB network | status |
|---|---|---|---|---|
| `20260806T183034Z-spring-ladder-n3` | the four-arm ladder | 3 × ab/ba × 2 contracts | **bridge** | 48 leaves |
| `20260810T131208Z-hibernate-vs-jdbc-n3` | ORM axis on Tomcat | 3 × ab/ba × 2 contracts | **host** | **12/12 `comparison_eligible`** |
| `20260811T0639…-l5-curve-orm` / `-tail` | open-loop wrk2 | 6 rungs × ab/ba | host | **[PENDING]** |

**The bridge/host split is load-bearing and is not cosmetic.** Under bridge the DB-cpuset figure
is Postgres *plus* container networking plus a userspace `docker-proxy` relay, so it is an **upper
bound on Postgres, not a measurement of it**. The size of the deformation is measured: on the
light contract the same arm at the same delivered throughput read **87.36 % busy under bridge and
37.34 % under host** — ~50 points, of which 55 of the 87 were `sys`+`soft`, i.e. kernel networking
(the 2026-08-08 correction in `docs/CLAIMS.md` L2). Heavy is unaffected to within noise
(99.80 → 99.84 %), because heavy's wall is genuine query execution. **Never compare a bridge
DB-busy figure with a host one**, and never read a bridge one as Postgres utilisation.

### Fairness posture — read before the numbers

1. **Pure and compat are never blended.** Arm 3 is compat; the two pairs that cross the axis are
   `non_eligible` by design (`EQUIVALENCE_MISMATCH`) and their numbers are reported as
   *compatibility overhead* in the `compat/` track, never as a comparative claim. This is a
   labelling and aggregation rule, **not** a confidentiality one — see the 2026-08-11 correction
   in `docs/CLAIMS.md`.
2. **The SQL is equalised across every arm; the mechanism is not.** Every statement is
   shape-identical (same predicates, same `row_number() OVER (PARTITION BY …)` windowing, three
   queries per heavy request). What differs is how each stack issues and maps it — which is the
   axis under test, not a defect.
3. **pgjdbc fetch configuration is normalised** on every arm (`defaultRowFetchSize=0`,
   `adaptiveFetch=false`), the 2026-07-24 equalisation. Without it the DB-bound contract measures
   the fetch config; the 2026-07-21 report's inverted aggregate verdict is the precedent.
4. **The auth axis is NOT equal across all arms.** Arms 1–3 carry `spring-boot-starter-security`;
   arms 4–5 and the native baseline do not. Traffic is unauthenticated and the read endpoints are
   `permitAll`, so no *authentication* work is measured — but a servlet `SecurityFilterChain`
   still reaches an authorization decision per request. Measured on the Exeris side and
   negligible there (+0.14 % against 1.48 % run-to-run spread); **not** measured for the Tomcat
   filter chain, so no bound may be borrowed. Within §4's ORM pair the two arms carry the
   *identical* config, so that pair is unaffected.
5. **Version alignment.** Arms 1, 2, 5 and the ladder run Boot 4.1.0 / Jackson 3 / kernel 0.10.2.
   **Arm 3 (`spring-on-exeris`) is still on Boot 3.5.14 / Jackson 2** — a Boot major and a Jackson
   major inside the request path. Any number from arm 3 carries that fence explicitly. **[TODO:
   decide whether to align arm 3 before publishing, which retires every pre-alignment compat
   number, or to publish arm 3 with the fence stated.]**
6. **Closed-loop driver.** Percentiles from the wrk campaigns are queue occupancy, not service
   time; the artefacts stamp `latency_percentile_eligibility.publishable=false` saying so. §7 is
   the service-time axis. **[PENDING]**

---

## 1. The strict gate, and what the load generator finally proved

**[SECTION SKELETON]**

- 12/12 leaves `comparison_eligible` / `all_gates_passed` for the ORM campaign, zero rejection
  codes, zero errors.
- **The load-generator ceiling was checked for the first time on this data and passed:** 24/24
  windows `loadgen_headroom_available`, max 16.3 % busy. A saturated load generator does not
  bound a result, it *invalidates* it — the number would describe how fast wrk can offer
  requests. That check had never run on this campaign because the aggregation step was manual
  and nothing in the harness called it; it is now derived at window close (`879ac63f`).
- **[TODO]** state the four fail-closed artefacts and the `track_id` isolation.

---

## 2. The error budget — what counts as a difference

**[SECTION SKELETON — numbers carried from the prior error-budget analysis. PROVENANCE TODO
before publish: each row must cite the campaign it was derived from. These were computed in
earlier work and are NOT re-derived from artefacts in this draft; a report may not carry an
error budget without a citation, so this section blocks publication until the sources are
attached.]**

Several claims in this report currently argue tolerance ad hoc ("+2.0 % closure, inside the
≤ 2 % control"). Stated once, as a budget on **cpu/req**:

| source | cpu/req |
|---|---:|
| harness noise | ± 0.30 % |
| arm order (ab vs ba) | ± 2.00 % |
| DB network mode | ± 0.30 % |
| runtime snapshot | ± 0.20 % |
| **total** | **± 2.80 %** |

This turns §3's reading rule from prose into arithmetic: a cpu/req difference below **±2.80 %** is
not a difference. Both ORM-axis results clear it by a wide margin (×3.95 and ×1.17 are
+295 % and +17 %), and so does the ladder closure (+2.0 %, inside the budget — which is what makes
the decomposition an attribution instrument rather than a coincidence).

**The budget does not transfer across metrics, and that is the point of stating it.** On the same
snapshot pair, **p99 moved 16.9 % where cpu/req moved 0.20 % — roughly 85× the sensitivity to an
identical fence.** That is the strongest available argument for why §7 waits for wrk2 instead of
recycling closed-loop percentiles: a tail metric that reacts 85× harder to a change the throughput
metric barely registers cannot be quoted from a run that was not designed to isolate it.

**[TODO]** promote this table to `docs/methodology.md` once sourced, so it stops being
report-local.

---

## 3. Which ceiling is binding — and therefore which numbers are quotable

**[SECTION SKELETON — data present, prose to write]**

Mean DB-cpuset utilisation over each arm's own measurement window, heavy contract.
**The DB-busy column is not homogeneous — read the network-mode column first.**

| arm | rps | own pin | DB busy | network | reading | bounded by |
|---|---:|---:|---:|---|---|---|
| `spring-hibernate` | 3 664 | 98.7 % | 30.5 % | bridge | **upper bound** | its own CPU |
| `spring-on-exeris-pure` | 4 131 | 98.7 % | 34.9 % | bridge | **upper bound** | its own CPU |
| `spring-on-exeris-pure-native` | 12 645 | 73.3 % | 99.8 % | bridge | upper bound, but *at the ceiling either way* | **the database** |
| `exeris-community` | 13 107 | 69.1 % | 99.8 % | bridge | upper bound, but *at the ceiling either way* | **the database** |
| `spring-jdbc` | 12 664 | — | **97.4 %** | **host** | **Postgres utilisation** | **the database** |

Sources: rows 1–4 `20260806T183034Z-spring-ladder-n3` (n=12, bridge); row 5
`20260810T131208Z-hibernate-vs-jdbc-n3` (n=6, host). **A bridge figure and a host figure are not
comparable** (see Setup). The two saturated bridge rows survive the caveat only because an upper
bound pinned at 99.8 % still establishes saturation; the two low bridge rows establish *headroom
exists*, not how much.

The consequence is the reading rule for this whole report: **a heavy throughput ratio between a
fast arm and a slow arm is a lower bound with one side capped**, so quote cpu/req there. On light
every arm leaves the database with substantial headroom (37 % measured on host) and throughput is
meaningful.

- **[TODO]** the "≤ 1.3 % / +36 % / +45 %" headroom bounds from L2, restated with the bridge
  caveat attached to whichever of them derive from bridge rows.

---

## 4. The ORM axis, measured on Tomcat

**[SECTION SKELETON — data final, prose to write]**

`spring-hibernate` vs `spring-jdbc`. Same Tomcat, same Boot 4.1.0, same `SecurityConfig`, same
HikariCP, same normalised pgjdbc URL, same three-query SQL shapes, byte-identical response
contracts. The only application-level difference is the repository layer.
n=6 per arm (3 repeats × ab/ba), 12/12 `comparison_eligible`, 0 errors.

| | `spring-hibernate` | `spring-jdbc` | ratio |
|---|---:|---:|---:|
| **heavy** cpu/req | 1074.7 µs (±12.0) | 271.8 µs (±2.8) | **×3.95** |
| heavy RSS (avg) | 1668 MB | 1168 MB | ×1.43 |
| heavy rps | 3 681 | 12 664 | *not quotable — see §3* |
| heavy DB busy | 26.4 % | **97.4 %** | — |
| **light** cpu/req | 143.6 µs (±2.2) | 122.5 µs (±1.3) | **×1.17** |
| light RSS (avg) | 1247 MB | 1167 MB | ×1.07 |
| light rps | 27 571 | 32 190 | **quotable** — DB at 19–22 % both arms |

The heavy/light asymmetry is the finding, not a curiosity: **the cost is not a fixed per-request
tax.** §5 explains it.

> **Two figures for `spring-hibernate` throughput appear in this report, on purpose.** The table
> above quotes the **arm mean** over all six leaves (heavy 3 681, light 27 571). §7 quotes the
> **worst-observed single leaf** (heavy 3 628, light 27 108) because a rate ladder must clear the
> slowest leaf the arm actually produced, not its average — sizing an offered rate off a mean puts
> half the leaves above it. Leaf-to-leaf spread within the arm is 2.8 % heavy / 3.5 % light, which
> is itself inside the error budget below.

- **[TODO]** relate to L3's ×1.488 Amdahl ceiling: this measurement is what L3 assumed.
- **[TODO]** the honest commercial framing — this is the cheapest change a Spring team can make,
  and it involves no Exeris at all. State the runtime's gain as the increment on top of it.

---

## 5. What the ×3.95 actually is — and why "the ORM" is the wrong name for it

**[SECTION SKELETON — data final, prose to write. This is the report's most important correction.]**

JFR `hot-methods` and `allocation-by-class` on the heavy leaves. repeat01 and repeat03 agree to
0.05 pp on the top frame, so this is not profiler noise. Derived views committed under
[`jfr-views/`](../raw/entity-read-by-id/20260810T131208Z-hibernate-vs-jdbc-n3/jfr-views/).

| | `spring-hibernate` | `spring-jdbc` |
|---|---|---|
| top CPU frame | `DefaultAdvisorAdapterRegistry.getInterceptors` **9.6 %** | pgjdbc `ensureBytes` 5.3 % |
| next | `ResolvableType.calculateHashCode` 4.5 %, `Class.copyMethods` 4.4 % | `Invokers.checkCustomized` 5.2 %, Jackson `_verifyValueWrite` 4.9 % |
| top allocations | `Object[]` 14.6 %, **`java.lang.reflect.Method` 11.2 %**, `ResolvableType` 7.0 % | pgjdbc + Jackson + DTOs |
| AOP-specific | `ReflectiveMethodInvocation` 3.2 %, `MethodInterceptor[]` 2.8 %, `PropertyDescriptor[]` 2.0 %, **`ProxyFactory` 1.5 %**, `Advisor[]` 1.4 % | none in top 25 |
| Hibernate's own row mapping | `LinkedHashMap$Entry` 5.0 %, `NativeTupleElementImpl` 1.5 % | n/a |

**Mechanism.** `spring-hibernate`'s repositories return Spring Data **interface projections**;
Spring Data proxies one object **per returned row** and routes every getter through the AOP
interceptor chain. Heavy returns ~200 rows and reads 3–4 getters each → ~200 proxy constructions
and ~700 proxied invocations per request. Light calls `findById` and gets a managed **entity** —
no projection, no proxy. `spring-jdbc` maps rows with a lambda `RowMapper` straight into records
on both contracts. `ProxyFactory` being allocated at steady state means each row's proxy carries
a cold `AdvisedSupport` `methodCache`, which is why the *cache-miss* frame tops the arm.

**Consequences, both of which must travel with any number from §4:**

1. The pair moves **two** things. Label it *"Spring Data JPA + Hibernate vs JdbcTemplate +
   RowMapper"* — a real and idiomatic stack choice — never *"the cost of the ORM"*.
2. **L3 inherits this.** Its ORM component is `spring-on-exeris-pure − spring-on-exeris-pure-native`,
   and (verified 2026-08-11) the first declares the same four projection interfaces while the
   second declares none. The 723.97 µs pool, the ×1.488 ceiling and the migration-order
   conclusion are unaffected in direction — that cost is real and does leave with the
   repositories — but the attribution to Hibernate specifically is not established by these arms.

### The consequence nobody has priced — and it changes the migration order

If the cost sits in Spring Data's projection proxies rather than in Hibernate, then **the cheapest
fix available to a Spring team is not moving to `JdbcTemplate`.** It is dropping interface
projections and returning DTOs through constructor expressions — *staying on JPA*. That is a
change of return types, not a rewrite of the persistence layer.

This matters beyond tidiness, because L3's migration-order conclusion ("on a DB-bound workload the
repositories go first") is currently priced as one large step. If a change of return types
captures a substantial share of the ×3.95, that step has a **much cheaper first rung that nobody
has measured** — and the ordering advice changes with it.

**So the missing arm has two jobs, not one.** The same experiment §5 names as decisive for
attribution — JPA through `EntityManager` or DTO/constructor-expression queries, no Spring Data
proxy — also prices the cheapest path a customer can take. That moves it off the "nice to have"
list: it is the difference between telling a team "rewrite your repositories" and telling them
"change your return types first, then measure again."

**What would settle it:** that one arm, against the existing `spring-hibernate`, same contract.
Not built; no campaign pending. **[TODO: propose it as the next campaign after the wrk2 curve.]**

**Instrumentation caveats.** JFR `ExecutionSample` is Java-frames-only and says nothing about the
`%sys`+`%soft` half of the budget. The two arms' recordings have different denominators — 874 s
(hibernate, ≈ its own window) vs 1213 s (jdbc, resident and idle during its partner's leg) — so
jdbc's shares are diluted. Dilution shrinks its percentages uniformly and cannot manufacture the
asymmetry, but no cross-arm share is quoted here as like-for-like. Exploratory: no
`claim-status.json` rides on these views.

---

## 6. The hosting ladder, and where each rung's cost lives

**[SECTION SKELETON — data present in L3/L4, prose to write]**

Heavy cpu/req arm-means, ladder campaign (n=12):

| rung | step | µs/req | × | clean? |
|---|---|---:|---:|---|
| Tomcat → Exeris compat | web dispatch | **[TODO from L-data]** | | |
| Tomcat → Exeris native web | hosting | 121.52 | ×1.127 | **no — see below** |
| JPA → kernel-native persistence | repository layer | 723.97 | — | attribution corrected in §5 |
| **whole stack** | Tomcat+JPA → native+native | — | ×5.118 direct | |

> **×1.127 IS NOT A CLEAN HOSTING NUMBER, AND THE CONFOUND IS UNBOUNDED.** The rung is
> `spring-hibernate` → `spring-on-exeris-pure` (1077.40 − 955.88 = 121.52 µs). Those two arms
> differ in more than hosting: the Tomcat arm carries `spring-boot-starter-security` and runs a
> servlet `SecurityFilterChain` that reaches an authorization decision on every request even when
> the match is `permitAll`; the Exeris arm carries no Spring Security at all and runs no
> per-request security code. **That difference has never been measured on the Tomcat side**, and
> fairness posture 4 forbids borrowing the Exeris-side bound (+0.14 %) for it — a
> `FilterChainProxy` dispatch with `SecurityContextHolder` lifecycle and `AuthorizationManager`
> evaluation is a different and heavier mechanism.
>
> Against a 121.52 µs step this is not a rounding error. It is the smallest effect in the report,
> so it is the one an unmeasured term can most easily dominate:
>
> | hypothetical filter-chain cost | share of the entire hosting gain |
> |---:|---:|
> | 10 µs/req | 8.2 % |
> | 20 µs/req | 16.5 % |
> | 30 µs/req | 24.7 % |
>
> **One leaf bounds it**: `spring-hibernate` rebuilt without `spring-boot-starter-security`, same
> contract, against the stock arm. Until then, ×1.127 is quoted **as an upper bound on the hosting
> gain**, never as the hosting gain itself, and the qualifier travels with it on every surface.

- The decomposition **closes**: product of the rungs vs the directly-measured end-to-end pair is
  **+2.0 % on heavy cpu/req**, inside the ±2.80 % budget of §2 (and inside the ≤ 2 %
  counterbalanced arm-order term specifically). It is an attribution instrument, not a heuristic —
  and it closes on cpu/req, not on rps (+3.8 %), which is the DB ceiling seen a third way (L4).
  Note the closure does **not** clear the security confound above: a term present in one rung and
  in the end-to-end pair alike cancels in the closure check while remaining in both numbers.
- **Amdahl consequence:** with the repository layer in the path, no amount of runtime work can
  exceed **×1.488** on this contract. **[TODO]** restate with §5's corrected label.
- **[TODO]** §6b footprint: RSS across the ladder, and L8's idle-cost finding (an idle
  Spring-on-Exeris process is ~18× less idle than Tomcat or the native runtime) with its
  threshold and the directional-only caveat on instances-per-core.

---

## 7. Service-time latency **[PENDING wrk2]**

**[SECTION SKELETON — no data yet. Do not fill from closed-loop runs.]**

The series has **no service-time evidence**. Every percentile measured so far came from wrk at
saturation with 128 connections in flight, which reports queue occupancy; the artefacts stamp
`driver.mode=closed` and `latency_percentile_eligibility.publishable=false`.

The open-loop campaign launched 2026-08-11 supplies it, at rates derived from each pair's slower
arm rather than chosen:

| phase | pair | contract | rungs (rps) | bound |
|---|---|---|---|---|
| `orm` | `spring-hibernate` × `spring-jdbc` | heavy | 600 … 3400 | hibernate 3 628 |
| `orm` | " | light | 4 000 … 24 000 | hibernate 27 108 |
| `tail` | `exeris-community` × `spring-on-exeris-pure-native` | light | 10 000 … 50 000 | pure-native 54 651 |

Two things this phase is for:

1. **The first fair heavy comparison of the ORM pair.** At a matched offered rate below both arms,
   both do identical work per second and so present identical load to Postgres — dissolving the
   §3 asymmetry that makes heavy throughput unquotable today.
2. **L5.** `spring-on-exeris-pure-native` has the second-best median and the worst p99 of the four
   ladder arms on light (2.00 / 12.49 ms against `exeris-community`'s 1.48 / 7.46), reproduced
   against a different comparator on different networking. If the tail is a service-time property
   it persists at every sub-saturation rung; if it is queueing it collapses away from the knee.

**[TODO]** fill from `20260811T0639…`; report `rate_attainment_pct` per rung and mark any rung
that entered the knee.

---

## 8. Open questions carried forward

- **L5** — the pure-native light tail. §7 is the test. *(open)*
- **L9** — inter-pair drift is a per-request cost increase, not CPU starvation; CPU theft and
  idle-neighbour CPU are both eliminated. Needs per-core counters (LLC / memory bandwidth, SMT
  siblings) the rig does not sample. *(open, not addressable from current artefacts)*
- **L10** — the repository-layer cost attribution (§5). *(open, needs an `EntityManager` /
  constructor-expression arm — which would also price the cheapest customer path and therefore
  test L3's migration order, see §5)*
- **The hosting step's security confound** — ×1.127 contains an unmeasured servlet
  `SecurityFilterChain` difference worth an unbounded share of a 121.52 µs step. One leaf
  (`spring-hibernate` without `spring-boot-starter-security`, same contract) bounds it.
  *(open, cheap, and it gates a headline number)*
- **Arm 3 version alignment** — Boot 3.5.14 / Jackson 2 against everything else on 4.1.0 /
  Jackson 3. *(decision pending, see fairness posture 5)*

---

## Revision history

<!-- One of the four summarizing surfaces. Every retraction stays visible, per house style. -->

- **2026-08-11 — draft opened.** Skeleton with §2–§6 data from committed campaigns; §7 pending.
- **[TODO on publish]** record that this report retracts the plain-"ORM" label used for the
  L3 pool, and why.

---

<!--
FOUR-SURFACE SWEEP — required before publishing, per CLAUDE.md.
Three consecutive review rounds on the triad report found every remaining defect living ONLY here:
  1. frontmatter `summary:`
  2. TL;DR
  3. revision history
  4. conclusions
Two specific traps:
  - a summary must not strengthen the body's quantifier ("rises to 39-59%" is not "dominates");
  - a bound must be the one measured on the axis being claimed (a <=2% throughput order-effect
    says nothing about RSS, where the same control read +13.5%).
Cross-cutting facts belong on this sweep too: the pgjdbc fetch normalisation, the auth-axis
asymmetry, and the §5 attribution correction.

PRE-PUBLISH CHECKLIST
  [ ] tier / protocol mode / benchmark family / comparison axis labelled on every table
  [ ] pure and compat separated; arm 3 never blended into a pure row
  [ ] claim-status.json = comparison_eligible and strict gates pass for every comparative row
  [ ] reproducibility metadata cited (SHA, JDK, tool versions, flags, hardware profile, scenario)
  [ ] confidentiality: raw .jfr NOT in the publish set (derived views only); note that
      spring-on-exeris* is publishable as of the 2026-08-11 correction
  [ ] publish-report.sh --publication-mode public
-->
