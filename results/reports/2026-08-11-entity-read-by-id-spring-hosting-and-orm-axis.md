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
2. **The attribution of that cost is corrected** (§4). It is not simply "Hibernate".
3. **Service-time latency for the Spring family** — the series has never had any. **[PENDING wrk2]**

---

## TL;DR

<!-- Write this AFTER the body. It is one of the four summarizing surfaces; see the sweep note. -->

- **The hosting swap is worth ×1.13. Removing the repository layer is worth ×4.** On the
  DB-bound aggregate, moving one identical Spring+JPA application from Tomcat to the Exeris
  native web layer buys **121.52 µs/req (×1.127)**, while the persistence layer under it accounts
  for **723.97 µs/req — 67.2 % of the whole request** (L3, L4). Runtime work is optimising the
  smaller third.
- **That now holds on Tomcat too, not just by assumption.** `spring-hibernate` → `spring-jdbc`,
  same host, same Boot 4.1.0, same security config, same SQL shapes, only the repository layer
  differs: **1074.7 → 271.8 µs/req on heavy (×3.95)** and **143.6 → 122.5 µs on light (×1.17)**,
  n=6 per arm, 12/12 leaves `comparison_eligible` (§3).
- **But "the ORM costs ×4" is the wrong label, and this report retracts it.** JFR puts Spring
  AOP and reflection *above* Hibernate's own tuple materialisation in the ORM arm. The arms
  differ by **two** things — Hibernate **and** Spring Data interface projections, which proxy
  one object per returned row. That is also what explains ×3.95 on heavy against ×1.17 on light:
  heavy returns ~200 rows, light returns a managed entity and no proxy at all (§4).
- **Which numbers may be quoted at all depends on where the ceiling is.** On heavy the fast arms
  saturate the Postgres cpuset and the slow ones do not, so a heavy *throughput* ratio between a
  fast and a slow arm reads the database, not the stack. cpu/req survives it; throughput does not
  (§2).
- **Footprint and idle cost** — §5. **[PENDING: consolidate L8 + RSS across the ladder]**
- **Latency** — **[PENDING wrk2]**. Until that campaign lands, this report makes **no
  service-time claim whatsoever**: every percentile in the series so far comes from a closed-loop
  driver at saturation and measures queue occupancy (§6).

**What this report will not claim:** any service-time comparison from the closed-loop campaigns;
any transfer of the heavy ranking to a setup where the database is not the bottleneck; any
attribution of the repository-layer cost to Hibernate specifically (§4).

---

## Setup

| | |
|---|---|
| **Hardware** | AMD Ryzen 7 7700 (8C/16T), 62 GB RAM, governor `performance`, turbo **off**, dedicated bare metal |
| **JDK** | Eclipse Temurin 26.0.1 |
| **Driver** | wrk 4.1.0 closed-loop, 4 threads / 128 connections (`driver.mode=closed`) — throughput and resource metrics only. wrk2 open-loop for §6 **[PENDING]** |
| **Transport** | HTTP/1.1 cleartext over loopback (`transport_mode=loopback-h1`) |
| **CPU pinning** | targets `0-1,8-9` · loadgen `2-3,10-11` · Postgres `4-7,12-15`, disjoint, SMT siblings pinned as units |
| **Backend** | PostgreSQL 16.2, **host networking** + cpuset isolation (`BENCH_DB_TUNED=1`) |
| **Memory** | equal 2048 MB budget per target; **iso-heap 1280 MB** on every arm including `exeris-community`, whose harness default is 256 |
| **DB pool** | min 16 / max 256, identical on all arms |
| **Windows** | 300 s warmup + 900 s measurement per arm (wrk2 phase: 60 s + 120 s) |
| **Contracts** | heavy `fixed_contract_cross_runtime_h1_v2` (3 queries, ~9.2 KB) · light `fixed_contract_cross_runtime_h1_single_read_v1` (1 PK row, ~125 B) |

**Campaigns behind this report** (all committed under `results/raw/entity-read-by-id/`):

| campaign | arms | n | status |
|---|---|---|---|
| `20260806T183034Z-spring-ladder-n3` | the four-arm ladder | 3 × ab/ba × 2 contracts | 48 leaves |
| `20260810T131208Z-hibernate-vs-jdbc-n3` | ORM axis on Tomcat | 3 × ab/ba × 2 contracts | **12/12 `comparison_eligible`** |
| `20260811T0639…-l5-curve-orm` / `-tail` | open-loop wrk2 | 6 rungs × ab/ba | **[PENDING]** |

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
   filter chain, so no bound may be borrowed. Within §3's ORM pair the two arms carry the
   *identical* config, so that pair is unaffected.
5. **Version alignment.** Arms 1, 2, 5 and the ladder run Boot 4.1.0 / Jackson 3 / kernel 0.10.2.
   **Arm 3 (`spring-on-exeris`) is still on Boot 3.5.14 / Jackson 2** — a Boot major and a Jackson
   major inside the request path. Any number from arm 3 carries that fence explicitly. **[TODO:
   decide whether to align arm 3 before publishing, which retires every pre-alignment compat
   number, or to publish arm 3 with the fence stated.]**
6. **Closed-loop driver.** Percentiles from the wrk campaigns are queue occupancy, not service
   time; the artefacts stamp `latency_percentile_eligibility.publishable=false` saying so. §6 is
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

## 2. Which ceiling is binding — and therefore which numbers are quotable

**[SECTION SKELETON — data present, prose to write]**

Mean DB-cpuset utilisation over each arm's own measurement window (L2, n=12; ORM campaign n=6):

| arm | contract | rps | own pin | DB busy | bounded by |
|---|---|---:|---:|---:|---|
| `spring-hibernate` | heavy | 3 664 | 98.7 % | 30.5 % | its own CPU |
| `spring-on-exeris-pure` | heavy | 4 131 | 98.7 % | 34.9 % | its own CPU |
| `spring-on-exeris-pure-native` | heavy | 12 645 | 73.3 % | 99.8 % | **the database** |
| `exeris-community` | heavy | 13 107 | 69.1 % | 99.8 % | **the database** |
| `spring-jdbc` | heavy | 12 664 | — | **97.4 %** | **the database** |

The consequence is the reading rule for this whole report: **a heavy throughput ratio between a
fast arm and a slow arm is a lower bound with one side capped**, so quote cpu/req there. On light
every arm leaves the database at 19–37 % and throughput is meaningful.

- **[TODO]** fold in the 2026-08-08 bridge-vs-host correction (light was 87 % under bridge; that
  was kernel networking, not Postgres — 37 % on host).
- **[TODO]** the "≤ 1.3 % / +36 % / +45 %" headroom bounds from L2.

---

## 3. The ORM axis, measured on Tomcat

**[SECTION SKELETON — data final, prose to write]**

`spring-hibernate` vs `spring-jdbc`. Same Tomcat, same Boot 4.1.0, same `SecurityConfig`, same
HikariCP, same normalised pgjdbc URL, same three-query SQL shapes, byte-identical response
contracts. The only application-level difference is the repository layer.
n=6 per arm (3 repeats × ab/ba), 12/12 `comparison_eligible`, 0 errors.

| | `spring-hibernate` | `spring-jdbc` | ratio |
|---|---:|---:|---:|
| **heavy** cpu/req | 1074.7 µs (±12.0) | 271.8 µs (±2.8) | **×3.95** |
| heavy RSS (avg) | 1668 MB | 1168 MB | ×1.43 |
| heavy rps | 3 681 | 12 664 | *not quotable — see §2* |
| heavy DB busy | 26.4 % | **97.4 %** | — |
| **light** cpu/req | 143.6 µs (±2.2) | 122.5 µs (±1.3) | **×1.17** |
| light RSS (avg) | 1247 MB | 1167 MB | ×1.07 |
| light rps | 27 571 | 32 190 | **quotable** — DB at 19–22 % both arms |

The heavy/light asymmetry is the finding, not a curiosity: **the cost is not a fixed per-request
tax.** §4 explains it.

- **[TODO]** relate to L3's ×1.488 Amdahl ceiling: this measurement is what L3 assumed.
- **[TODO]** the honest commercial framing — this is the cheapest change a Spring team can make,
  and it involves no Exeris at all. State the runtime's gain as the increment on top of it.

---

## 4. What the ×3.95 actually is — and why "the ORM" is the wrong name for it

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

**Consequences, both of which must travel with any number from §3:**

1. The pair moves **two** things. Label it *"Spring Data JPA + Hibernate vs JdbcTemplate +
   RowMapper"* — a real and idiomatic stack choice — never *"the cost of the ORM"*.
2. **L3 inherits this.** Its ORM component is `spring-on-exeris-pure − spring-on-exeris-pure-native`,
   and (verified 2026-08-11) the first declares the same four projection interfaces while the
   second declares none. The 723.97 µs pool, the ×1.488 ceiling and the migration-order
   conclusion are unaffected in direction — that cost is real and does leave with the
   repositories — but the attribution to Hibernate specifically is not established by these arms.

**What would settle it:** one arm running JPA through `EntityManager` or DTO/constructor-expression
queries with no Spring Data proxy. Not built; no campaign pending.

**Instrumentation caveats.** JFR `ExecutionSample` is Java-frames-only and says nothing about the
`%sys`+`%soft` half of the budget. The two arms' recordings have different denominators — 874 s
(hibernate, ≈ its own window) vs 1213 s (jdbc, resident and idle during its partner's leg) — so
jdbc's shares are diluted. Dilution shrinks its percentages uniformly and cannot manufacture the
asymmetry, but no cross-arm share is quoted here as like-for-like. Exploratory: no
`claim-status.json` rides on these views.

---

## 5. The hosting ladder, and where each rung's cost lives

**[SECTION SKELETON — data present in L3/L4, prose to write]**

Heavy cpu/req arm-means, ladder campaign (n=12):

| rung | step | µs/req | ×  |
|---|---|---:|---:|
| Tomcat → Exeris compat | web dispatch | **[TODO from L-data]** | |
| Tomcat → Exeris native web | hosting | 121.52 | ×1.127 |
| JPA → kernel-native persistence | repository layer | 723.97 | — |
| **whole stack** | Tomcat+JPA → native+native | — | ×5.118 direct |

- The decomposition **closes**: product of the rungs vs the directly-measured end-to-end pair is
  **+2.0 % on heavy cpu/req**, inside the ≤ 2 % counterbalanced arm-order control. It is an
  attribution instrument, not a heuristic — and it closes on cpu/req, not on rps (+3.8 %), which
  is the DB ceiling seen a third way (L4).
- **Amdahl consequence:** with the repository layer in the path, no amount of runtime work can
  exceed **×1.488** on this contract. **[TODO]** restate with §4's corrected label.
- **[TODO]** §5b footprint: RSS across the ladder, and L8's idle-cost finding (an idle
  Spring-on-Exeris process is ~18× less idle than Tomcat or the native runtime) with its
  threshold and the directional-only caveat on instances-per-core.

---

## 6. Service-time latency **[PENDING wrk2]**

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
   §2 asymmetry that makes heavy throughput unquotable today.
2. **L5.** `spring-on-exeris-pure-native` has the second-best median and the worst p99 of the four
   ladder arms on light (2.00 / 12.49 ms against `exeris-community`'s 1.48 / 7.46), reproduced
   against a different comparator on different networking. If the tail is a service-time property
   it persists at every sub-saturation rung; if it is queueing it collapses away from the knee.

**[TODO]** fill from `20260811T0639…`; report `rate_attainment_pct` per rung and mark any rung
that entered the knee.

---

## 7. Open questions carried forward

- **L5** — the pure-native light tail. §6 is the test. *(open)*
- **L9** — inter-pair drift is a per-request cost increase, not CPU starvation; CPU theft and
  idle-neighbour CPU are both eliminated. Needs per-core counters (LLC / memory bandwidth, SMT
  siblings) the rig does not sample. *(open, not addressable from current artefacts)*
- **L10** — the repository-layer cost attribution (§4). *(open, needs an `EntityManager` arm)*
- **Arm 3 version alignment** — Boot 3.5.14 / Jackson 2 against everything else on 4.1.0 /
  Jackson 3. *(decision pending, see fairness posture 5)*

---

## Revision history

<!-- One of the four summarizing surfaces. Every retraction stays visible, per house style. -->

- **2026-08-11 — draft opened.** Skeleton with §2–§5 data from committed campaigns; §6 pending.
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
asymmetry, and the §4 attribution correction.

PRE-PUBLISH CHECKLIST
  [ ] tier / protocol mode / benchmark family / comparison axis labelled on every table
  [ ] pure and compat separated; arm 3 never blended into a pure row
  [ ] claim-status.json = comparison_eligible and strict gates pass for every comparative row
  [ ] reproducibility metadata cited (SHA, JDK, tool versions, flags, hardware profile, scenario)
  [ ] confidentiality: raw .jfr NOT in the publish set (derived views only); note that
      spring-on-exeris* is publishable as of the 2026-08-11 correction
  [ ] publish-report.sh --publication-mode public
-->
