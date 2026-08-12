---
title: "DRAFT — Where the request actually goes: a Spring hosting ladder and the ORM axis, measured on both hosts"
date: 2026-08-11 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
summary: "One Spring application served five ways on dedicated bare metal, under two fixed contracts and two instruments. The repository layer costs headroom, not per-request latency: at 600 rps the heavy median gap is x1.43 and on the single-row contract the arms are indistinguishable up to 20 000 rps, but the Hibernate arm reaches 94 % of its capacity while the JDBC one stays flat. The cost is Spring Data interface projections rather than Hibernate itself, and the hosting swap is smaller than either — 23 % of it turned out to be Spring Security."
# Written from 7.1 (service time), deliberately NOT from 4 (cost). x3.95 is the most quotable
# number in this report and the body says it holds on neither contract, so it must not appear
# here: this is the only surface that travels to aggregators, RSS and search without its fences.
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: entity-read-by-id
claim_scope: draft_not_for_publication
reproducibility_status: incomplete
claim_scope_note: >
  Deliberately NOT comparison_eligible while this is a draft, even though the underlying
  campaigns are. §2's error budget is now derived from this report's own campaigns
  (tools/derive-error-budget.sh, 220 observations) and no longer blocks; the remaining
  TODOs are prose in sections 1, 3, 4 and 6. A file-level
  comparison_eligible would also over-claim across the whole report: the ladder campaign's
  48 leaves are not declared all-eligible anywhere, and the two pairs that cross the
  Pure-vs-Compat axis are non_eligible BY DESIGN. Eligibility is a per-campaign, per-pair
  property in this repo and is stated at each table; it is not a document attribute.
  Flip both fields only when every TODO is closed and each table states its own gate status.
comparison_axis: within-tier
hardware_profile: perf-box-amd64
---

# DRAFT — Where the request actually goes: a Spring hosting ladder and the ORM axis, measured on both hosts

*One Spring application served five ways, plus a native baseline, under two fixed contracts on dedicated bare metal.*

> **DRAFT STATUS.** The open-loop wrk2 campaign has **landed** (§7, 36/36 leaves
> `comparison_eligible`), so no section is waiting on data any more, and **the last hard blocker is
> closed**: §2's error budget is derived from this report's own six campaigns rather than quoted
> forward (§2.2, `tools/derive-error-budget.sh`). What remains is prose. §6's security confound was
> the last open experiment and it closed on 2026-08-11 at
> +28.31 ± 3.25 µs/req. Two editorial questions are decided: the compat rung stays out of §6's pure
> ladder and goes to the `compat/` track, and arm 3 publishes with its version-skew fence rather
> than holding the report for an alignment campaign. Every number here is from a committed, gate-passing campaign
> and was re-derived from its artefacts before being written down. **No number in this file is
> provisional or estimated.**

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
3. **Service-time latency for the Spring family** — the series has never had any, on any arm.
   §7 is the first coordinated-omission-free measurement in it, and it resolves CLAIMS L5.

---

## TL;DR

<!-- Written after the body. One of the four summarizing surfaces; see the sweep note. -->

**The repository layer does not make a request slower — it makes the arm run out of headroom
sooner.** Everything below is that sentence, qualified.

- **Cost and service time say it together.** Cost: **×3.95 cpu/req on the DB-bound aggregate,
  ×1.17 on the single-row read** (n=6 per arm, 12/12 eligible, §4). Service time: the heavy median
  gap at 600 rps is **×1.43**, and `spring-jdbc` stays flat to 3400 rps while `spring-hibernate`
  reaches 94 % of capacity with p99.9 going ~4 → 15–22 ms; on light the arms are
  indistinguishable to 20 000 rps (§7). **"×3.95 slower" holds on neither contract.**
- **It is Spring Data interface projections, not Hibernate — the plain "ORM" label is retracted.**
  JFR puts Spring AOP and reflection *above* Hibernate's tuple materialisation, and one proxy per
  returned row explains the contract dependence (heavy ~200 rows, light none) (§5). Cheapest fix
  is therefore DTO constructor expressions on JPA, not `JdbcTemplate`. This also **replaces an
  assumption**: L3 measured the cost on the Exeris-hosted arm and carried it to Tomcat because no
  ORM-free Tomcat arm existed. Arm 2 is that arm; the direction holds.
- **Hosting is the smaller effect, and 23.3 % of it was security.** The rung buys
  **121.52 µs/req (×1.127)** against a repository layer worth **723.97 µs/req — 67.2 % of the
  request** (L3, L4). The security term is now measured rather than feared — **+28.31 ± 3.25 µs**,
  one jar with the filter chain off, 12/12 eligible — correcting the rung to **≈ 89–96 µs,
  ×1.09–1.10** (§6). Two fences: the cross-contract subtraction is a supported *assumption*, and
  170 bytes of response headers sit inside the figure rather than authorization work.
- **L5 resolved — against both of its own hypotheses.** The light tail is neither a closed-loop
  artefact nor a flat service-time property: absent below ~30 000 rps, sharp above ~80 % of
  capacity (p99.9 1.34× → 2.85×), with the closed-loop figure overstating it ~2.5× (§7.3).
- **Two reading rules.** On heavy a fast-vs-slow *throughput* ratio reads the database, not the
  stack — quote cpu/req (§3). Percentiles are **ab–ba ranges, never points**, because tails here
  are far more order-sensitive than throughput (5.25 vs 15.07 ms p99 in one cell at the same
  offered rate) — and those ranges still carry **no restart variance**, making them a lower bound
  on uncertainty rather than an envelope (§2.4, §7).
- **Footprint and idle cost** — §6. **[PENDING: consolidate L8 + RSS across the ladder]**

**What this report will not claim:** any service-time comparison from the closed-loop campaigns;
any transfer of the heavy ranking to a setup where the database is not the bottleneck; any
attribution of the repository-layer cost to Hibernate specifically (§5).

---

## Setup

| | |
|---|---|
| **Hardware** | AMD Ryzen 7 7700 (8C/16T), 62 GB RAM, governor `performance`, turbo **off**, dedicated bare metal |
| **JDK** | Eclipse Temurin 26.0.1 |
| **Driver** | wrk 4.1.0 closed-loop, 4 threads / 128 connections (`driver.mode=closed`) — throughput and resource metrics only; its percentiles are queue occupancy. **wrk2 open loop at a fixed offered rate** (`driver.mode=open`) for §7 — the service-time axis |
| **Transport** | HTTP/1.1 cleartext over loopback (`transport_mode=loopback-h1`) |
| **CPU pinning** | targets `0-1,8-9` · loadgen `2-3,10-11` · Postgres `4-7,12-15`, disjoint, SMT siblings pinned as units |
| **Backend** | PostgreSQL 16.2 + cpuset isolation (`BENCH_DB_TUNED=1`). **Container network mode differs by campaign and is not a report-wide property — see the table below.** |
| **Memory** | equal 2048 MB budget per target; **iso-heap 1280 MB** on every arm including `exeris-community`, whose harness default is 256 |
| **DB pool** | min 16 / max 256, identical on all arms |
| **Windows** | 300 s warmup + 900 s measurement per arm (wrk2 phase: 60 s + 120 s) |
| **Notation** | `±` on a mean is the **sample standard deviation** across that arm's leaves (n stated per table), never standard error or min–max spread. For n=6, SE is ~0.41× the quoted SD and the min–max spread ~2.5× it, so the choice changes the apparent tightness by a factor of six — which is why it is named rather than assumed. Percentiles are **not** given as mean ± anything: they appear as ab–ba ranges (§7) |
| **Contracts** | heavy `fixed_contract_cross_runtime_h1_v2` (3 queries, ~9.2 KB) · light `fixed_contract_cross_runtime_h1_single_read_v1` (1 PK row, ~125 B) |

**Campaigns behind this report** (all committed under `results/raw/entity-read-by-id/`):

| campaign | arms | n | DB network | status |
|---|---|---|---|---|
| `20260806T183034Z-spring-ladder-n3` | the four-arm ladder | 3 × ab/ba × 2 contracts | **bridge** | 48 leaves |
| `20260810T131208Z-hibernate-vs-jdbc-n3` | ORM axis on Tomcat | 3 × ab/ba × 2 contracts | **host** | **12/12 `comparison_eligible`** |
| `20260811T063920Z-l5-curve-orm` / `-tail` | open-loop wrk2 service time | 6 rungs × ab/ba × 3 ladders | host | **36/36 `comparison_eligible`** |

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
   major inside the request path. Any number from arm 3 carries that fence explicitly.
   **DECIDED 2026-08-11: publish with the fence, do not hold the report.** Aligning arm 3 to
   Boot 4.1.0 / Jackson 3 / kernel 0.10.2 retires every compat number measured before it,
   including the 2026-08-05 triad — that is a real cost and it deserves its own campaign, not a
   blocking dependency on a report whose other five arms are aligned and whose one skewed arm is
   measured, disclosed and fenced. The alignment runs separately as a compat-track campaign.
6. **Closed-loop driver.** Percentiles from the wrk campaigns are queue occupancy, not service
   time; the artefacts stamp `latency_percentile_eligibility.publishable=false` saying so. §7 is
   the service-time axis and carries `publishable=true` on all 36 of its leaves.

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

Several claims in this report would otherwise argue tolerance ad hoc ("+2.0 % closure, inside the
≤ 2 % control"). Stated once, as a budget on **cpu/req** — and derived from this report's own
campaigns rather than quoted forward from memory.

**Two things are being separated here, and the earlier version of this table conflated them.** A
**fence** says a comparison is *invalid*; a **budget** says a valid comparison is *not resolving*
anything. Crossing a fence does not widen an error bar, it voids the result — so a fence must
never appear as a budget row, where it reads as something you can absorb.

### 2.1 Fences — conditions under which no budget applies

Both are enforced by `scripts/compare-results.sh`, which refuses the comparison outright; a
difference is never overridable.

| fence | measured magnitude, **from this report's own campaigns** | source |
|---|---|---|
| `backend_network_mode` (bridge vs host) | **DB-cpuset busy 87.36 % → 37.34 %** on the light contract, *same arm, same delivered throughput* — ~50 points, 55 of the 87 being `sys`+`soft`, i.e. kernel networking. Heavy unaffected to within noise (99.80 → 99.84 %). | Setup above; `docs/CLAIMS.md` L2 (2026-08-08 correction) |
| `db_cpuset` (pinned vs unpinned) | unpinned Postgres shares all 16 cores with a target pinned to 0-1,8-9 — contends with the arm *and* makes DB CPU unattributable | verified 2026-08-06 (`postmaster Cpus_allowed_list`) |

The network-mode row is deliberately quoted from **this** campaign set rather than from the
historical figure, because the historical one cannot be re-derived — see below. A fence stated in
a section about what may be trusted should lead with its strongest evidence.

> **Historical origin of the network-mode fence, and why it is a footnote rather than the row.**
> The fence entered the harness on a June measurement — `+20.5 %` throughput at unchanged
> application cpu/req (0.357 → 0.358 ms), target-thread `%wait` 265 % → 57 %
> ([2026-06-20 report §2](2026-06-20-entity-read-by-id-steady-state-and-cost-per-request.md)).
> Those figures exist in that report's prose and nowhere else: every committed
> `results/raw/guided/*/result.json` records `backend_network_mode: host`, so **the bridge leg is
> not in the repository** and the run does not appear in that report's own run index. Cite it as
> the origin of the rule, never as a reproducible measurement. Nothing rests on it — the row above
> measures the same effect on committed artefacts, on a different axis (DB-cpuset occupancy rather
> than throughput), and in the same direction. And the fence is satisfied by construction here
> anyway: `scripts/compare-results.sh` refuses a mode-crossing comparison outright, and the
> bridge/host split across this report's campaigns is stated per campaign in Setup.

### 2.2 The budget — two variance layers, per contract

Derived by `tools/derive-error-budget.sh` over the **six `-n3` campaigns** under
`results/raw/entity-read-by-id/` (2026-08-05 … 2026-08-11), 220 observations, output committed at
[`assets/2026-08-11-error-budget-derivation.csv`](assets/2026-08-11-error-budget-derivation.csv).
`cpu/req = cpu_time_seconds / total_requests`, the formula the campaign runners and
`tools/aggregate-matrix.sh` use.

| layer | what varies | n | heavy p95 | light p95 |
|---|---|---:|---:|---:|
| arm order (ab vs ba) | position in the counterbalanced sequence — **same JVM instances**, one warmup, one JIT state | 66 + 66 | 1.00 % | 2.71 % |
| repeat | a full teardown and relaunch, direction held fixed | 44 + 44 | 2.31 % | 2.54 % |
| **combined** (quadrature) | **a single leaf-to-leaf comparison** | — | **± 2.52 %** | **± 3.71 %** |

This turns §3's reading rule from prose into arithmetic: **a cpu/req difference below ±2.52 %
(heavy) or ±3.71 % (light) is not a difference.** Both ORM-axis results clear it by a wide margin
(×3.95 and ×1.17 are +295 % and +17 %), and so does the ladder closure (+2.0 % on heavy, inside
the budget — which is what makes the decomposition an attribution instrument rather than a
coincidence). Claims built on the mean of n=3 repeats resolve finer than this; the table is the
conservative single-comparison envelope, not the precision of an averaged result.

> **What the previous version of this table got wrong**, recorded because the failure mode is
> reusable. It read: harness noise ±0.30 %, arm order ±2.00 %, DB network mode ±0.30 %, runtime
> snapshot ±0.20 %, total ±2.80 %. Four defects. (1) Three of the four rows traced to a **single
> n=1 exploratory cell** (`results/raw/20260724-entity-read-by-id-3way-kernel-profile-LIGHT/counterbalanced-cell/`)
> on an older heap/GC/pool configuration — not to any campaign in this report. (2) The arm-order
> row **under-stated its own source**: that cell's largest measured cpu/req move was +2.14 %, and
> its text says "≈2 %", not "±2.00 %". (3) The DB-network row was a fence miscast as a budget line
> (§2.1). (4) The rows were **summed**, which both mixes terms that do not apply simultaneously
> and is the wrong combination rule for independent ones. The replacement is measured on the arms
> this report actually compares.

### 2.3 The budget does not transfer across metrics

On one snapshot pair — the same `spring-on-exeris-pure-native` arm measured under two consecutive
runtime-web snapshots, `-29` in `20260808T065528Z-purenative-vs-quarkustuned-n3` and `-31` in
`20260808T151608Z-purenative-vs-compnative-n3`, identical pins, heap, DB mode and contracts, n=6
leaves each — **cpu/req moved +0.20 % while p99 moved +16.9 %: roughly 83× the sensitivity to an
identical change.**

**That figure is light-contract only, and it is a closed-loop percentile.** Two fences on it, both
of which the earlier one-line version of this claim omitted:

| contract | Δ cpu/req | Δ p99 | magnitude ratio |
|---|---:|---:|---:|
| **light** | +0.20 % | **+16.9 %** | **83×** |
| heavy | −0.15 % | +0.30 % | 2.1× |

The heavy arm shows no such amplification, so "tails are ~85× more sensitive" is **not** a general
property of this harness — it is what the light contract did on this pair. And both p99 values come
from `wrk` leaves carrying `run_config.driver.mode: closed`, whose own recorded note reads
*"closed = wrk at saturation: throughput and resource metrics valid, percentiles are
queue-depth/throughput"* — so the 16.9 % is a move in **queue occupancy, not service time**.

> **Harness gap found while sourcing this.** The `-29` campaign stamps
> `latency_percentile_eligibility: {publishable: false, reason: closed_loop_driver_at_saturation}`
> in every `claim-status.json`; the `-31` campaign **emits no such block at all** — 0 files against
> 12, the only one of the six `-n3` campaigns missing it. The percentiles are equally unpublishable
> in both; only the stamp is absent. `run_config.driver.mode` is present on both and is what the
> classification above rests on. Worth fixing so the gate does not depend on which runner version
> wrote the campaign.

Both caveats *strengthen* the reason §7 waits for wrk2 rather than recycling closed-loop
percentiles: a metric that can move 83× harder than cpu/req on a change neither arm intended, and
that is not even measuring service time when it does, cannot be quoted from a run that was not
designed to isolate it.

### 2.4 A budget needs a scope, or it misleads in both directions

**The §2.2 table is the envelope for a single leaf-to-leaf comparison. Applying it to a tighter
comparison over-states uncertainty; substituting a looser proxy under-states it.** A same-jar A/B
run inside one campaign is tighter on every axis at once: no snapshot term (both arms launch a
byte-identical artefact), no network-mode term (one campaign, one mode), and an arm-order term
that is *measured on that pair* rather than taken from the pooled p95.

This is not an abstract worry — it is how the retired table went wrong. Its rows came from a
different configuration than the arms it was being applied to, and nothing in the number said so.

The security-confound campaign (`20260811T114140Z-security-confound-n3`, §6) supplied three
counter-examples in a single run, and they point in opposite directions — which is why the rule is
worth stating as scope rather than as a number:

| candidate yardstick | what it actually measures | on this pair | error |
|---|---|---|---|
| the retired ±2.80 % budget | an envelope imported from an n=1 cell on another configuration | ±29 µs on a heavy arm | **over-states** — declared a resolvable effect unresolvable |
| ab vs ba inside one repeat | stability *within* one JVM lifetime — both directions share the same instances, warmup and JIT state | 0.02–0.11 % | **under-states** — omits the restart variance entirely |
| an incomplete repeat | a smaller sample wearing a repeat's label | inflated the light spread ~10× | **over-states** |
| **repeat-to-repeat, complete repeats only** | **would this difference recur if I ran it again from scratch** | see §6 | the applicable one |

Each of those three was calculated correctly. Each answered a different question from the one
being asked. **The applicable layer is the repeat: a full JVM restart, both directions, counted
only when complete.** Anything narrower measures a sub-layer; anything broader imports conditions
that are not present.

This also explains why the same pair can be measurable on one contract and not on another. It is
not the repeat count that decides — it is the ratio of the effect to the layer's own variance. On
the light contract that ratio is large and n=3 settles it; on heavy the arms' restart variance is
comparable to the effect itself, so no number of repeats would settle it (§6).

Both the layering rule and the fence-is-not-a-budget-row rule are now in
[`docs/methodology.md` → *An error budget needs a scope*](../../docs/methodology.md), so they stop
being report-local; this section is the worked example they point back to.

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
| Tomcat → Exeris native web | hosting | 121.52 | ×1.127 | **no — see below** |
| JPA → kernel-native persistence | repository layer | 723.97 | — | attribution corrected in §5 |
| **whole stack** | Tomcat+JPA → native+native | — | ×5.118 direct | |

> **The compat rung is deliberately absent from this table.** An earlier draft carried a
> `Tomcat → Exeris compat` row here, which would have put arm 3 — the only compat arm — inside a
> ladder whose other rungs are all pure. That breaks fairness posture 1 and the pre-publish
> checklist item "arm 3 never blended into a pure row", and the strict gate agrees: every pair
> crossing the Pure-vs-Compat axis is `non_eligible` with `EQUIVALENCE_MISMATCH` by design. The
> compat seam is a **compatibility-overhead** measurement, not a rung of a pure ladder; it is
> reported separately in the `compat/` track with both modes stored apart and labelled. Removing
> the row costs this table nothing it was entitled to show.

> **×1.127 CONTAINED A SECURITY TERM, NOW MEASURED: ~23 % OF IT.** The rung is
> `spring-hibernate` → `spring-on-exeris-pure` (1077.40 − 955.88 = 121.52 µs). Those arms differ
> in more than hosting: the Tomcat arm carries `spring-boot-starter-security` and runs a servlet
> `SecurityFilterChain` that reaches an authorization decision on every request even when the
> match is `permitAll`; the Exeris arm carries no Spring Security at all. That term was unbounded
> until 2026-08-11 and is now measured.
>
> **Campaign `20260811T114140Z-security-confound-n3`**, 12/12 leaves `comparison_eligible`:
> `spring-hibernate` against `spring-hibernate-nosec` — **one jar, byte-identical
> `artifact_sha256`**, the arms separated only by the launch properties that disable the filter
> chain, so classpath, loaded classes and metaspace stay constant. Complete repeats only (full JVM
> restart, both directions):
>
> | contract | repeat01 | repeat02 | repeat03 | mean | sd | share of the 121.52 µs step |
> |---|---:|---:|---:|---:|---:|---:|
> | **light** (the measurement) | +26.23 | +26.64 | +32.06 | **+28.31 µs** | 3.25 (11 %) | **23.3 %** |
> | heavy (transferability check) | +40.40 | +21.99 | +35.35 | +32.58 µs | 9.52 (29 %) | 26.8 % |
>
> **Light is the measurement by design, not by preference.** Against the per-contract budget of
> §2.2 a 10–30 µs effect is **0.93–2.78 % of heavy's 1077 µs baseline against a ±2.52 % heavy
> envelope** — straddling the floor, i.e. unresolvable — and **6.8–20.5 % of light's 147 µs against
> ±3.71 %**, clear of it across almost the whole range. Heavy could never have resolved this, and
> its 29 % relative uncertainty confirms it: the limit is not repeat count but the ratio of the
> effect to that layer's own variance (§2.4).
>
> **Contract-dependence is NOT established.** The two intervals overlap ([25.1, 31.6] against
> [23.1, 42.1]), so the data are consistent with a constant absolute per-request cost but do not
> prove one. Subtracting the light figure from a heavy rung therefore remains a stated
> **assumption**, supported by heavy's agreement and not demonstrated by it.
>
> **Corrected reading of the rung, under that assumption:** removing the security term leaves a
> hosting step of **≈ 89–96 µs, ×1.09–1.10** (light-derived 93.21 µs / ×1.098; heavy-derived
> 88.94 µs / ×1.093; the light error bar spans 89.96–96.46 µs). The hosting gain is therefore
> **~9.5 % rather than 12.7 %** — the direction is unchanged and the magnitude drops by about a
> quarter. Quote ×1.127 only as the *un-corrected* step, always with this correction attached.
>
> **FENCE — part of that 28.31 µs is bytes, not authorization.** Spring Security's
> `HeaderWriterFilter` adds six response headers the nosec arm does not send
> (`X-Content-Type-Options`, `X-XSS-Protection`, `Cache-Control`, `Pragma`, `Expires`,
> `X-Frame-Options`): **170 bytes**, against a light response body of **30 bytes**. The stock arm
> writes 314 bytes per light response where the nosec arm writes 144 — **2.18×**. The share of the
> 28.31 µs attributable to those bytes is **not quantified** and is deliberately not estimated
> here. For the question this rung asks — *what does removing Spring Security save* — the full
> figure is correct, because `spring-on-exeris-pure` does not emit those headers either. For the
> narrower question *what does the authorization decision cost*, 28.31 µs is an over-estimate by an
> unmeasured amount.
>
> **The correction is wider than this pair, so state its real scope.** The response-checksum
> control in this series (heavy `sha256/16 82f9bcdf2852bd5e`, 9105 bytes, reported as matching
> across **all four ladder arms plus `comp-native`**) was used as a fairness control — evidence
> that a cross-arm comparison is not a serialisation-volume comparison. That control was computed
> on **response bodies only**. Ladder arms 1–3 carry Spring Security and emit the six headers
> above; arms 4–5 do not. So the checksum **never covered full responses across the auth boundary
> — for any pair that crosses it**, not merely for the `spring-hibernate` / `-nosec` pair. What it
> establishes is unchanged and still load-bearing: the arms return **the same content**. What it
> does **not** establish, and was previously read as establishing, is equal **bytes on the wire**
> on any auth-crossing pair.
>
> **§4 is unaffected and this correction must not be stretched to it.** The ORM pair
> (`spring-hibernate` × `spring-jdbc`) shares one `SecurityConfig`, so both arms emit the same six
> headers; there the responses match on bodies *and* headers, and "byte-identical response
> contracts" stands as written.
>
> **Also observed, unexplained:** on heavy the stock arm is far more reproducible across repeats
> (sd 0.21 %) than the nosec arm (0.82 %, range 15 µs). The arm with *fewer* layers is the less
> stable one. n=3, no mechanism proposed.

- The decomposition **closes**: product of the rungs vs the directly-measured end-to-end pair is
  **+2.0 % on heavy cpu/req**, inside the **±2.52 %** heavy envelope of §2.2. Note it is *not*
  inside the heavy arm-order term alone (1.00 %) — closure at this size needs the restart layer,
  which is the honest reading: the residual is the size of a relaunch, not of a reordering. It is
  an attribution instrument, not a heuristic —
  and it closes on cpu/req, not on rps (+3.8 %), which is the DB ceiling seen a third way (L4).
  Note the closure does **not** clear the security confound above: a term present in one rung and
  in the end-to-end pair alike cancels in the closure check while remaining in both numbers.
- **Amdahl consequence:** with the repository layer in the path, no amount of runtime work can
  exceed **×1.488** on this contract. **[TODO]** restate with §5's corrected label.
- **[TODO]** §6b footprint: RSS across the ladder, and L8's idle-cost finding (an idle
  Spring-on-Exeris process is ~18× less idle than Tomcat or the native runtime) with its
  threshold and the directional-only caveat on instances-per-core.

---

## 7. Service-time latency — the first CO-free measurement in this series

Every percentile this series has ever published came from wrk at saturation with 128 connections
in flight, which reports queue occupancy; the artefacts stamp `driver.mode=closed` and
`latency_percentile_eligibility.publishable=false` saying exactly that. This section is the first
that is not built that way.

**Campaign `20260811T063920Z-l5-curve-{orm,tail}`**: wrk2 open loop at a fixed offered rate,
36 leaves, **36/36 `comparison_eligible`**, 60 s warmup + 120 s measurement per arm per rung.
Rungs were **derived from each pair's slower arm, not chosen** — the ceiling is set by whichever
arm runs out of capacity first:

| phase | pair | contract | rungs (rps) | bound (worst-observed saturation of the slower arm) |
|---|---|---|---|---|
| `orm` | `spring-hibernate` × `spring-jdbc` | heavy | 600 … 3400 | hibernate 3 628 (top rung = 94 %) |
| `orm` | " | light | 4 000 … 24 000 | hibernate 27 108 (88 %) |
| `tail` | `exeris-community` × `spring-on-exeris-pure-native` | light | 10 000 … 50 000 | pure-native 54 651 (91 %) |

**Every rung sustained its offered rate** — minimum `rate_attainment_pct` 99.55 % across all 36
leaves — so **no rung entered the knee and every percentile below is service time**, including the
top rungs. That is the precondition for the whole section and it is met, not assumed.

> **Percentiles are given as an ab–ba range, never as a point.** Tail metrics in this campaign are
> far more order-sensitive than throughput: at heavy 3000 rps `spring-hibernate` read p99 5.25 in
> one direction and 15.07 in the other, at the same offered rate. §2.2's arm-order term (1.00 %
> heavy, 2.71 % light) is **measured on cpu/req and does not transfer here** — that is the same "a
> bound must be the one measured on the axis being claimed" trap the report warns about elsewhere,
> and this is where it bites hardest. §2.3 puts a number on the gap: on one snapshot pair the tail
> moved 83× harder than cpu/req. With n=2 per cell, medians are solid and tails are indicative.
>
> **And the range itself is the layer §2.4 calls under-stating.** The 36 leaves are 6 rungs × two
> directions × three ladders: **n=2 per cell is two directions, not two repeats**, so both leaves
> share one JVM lifetime, one warmup and one JIT state. By this report's own scope rule an ab–ba
> spread carries **no restart variance at all** — it is therefore a **lower bound on the
> uncertainty, not an envelope of it**. Every conclusion in §7 is read off the *shape across six
> rungs*, which is robust to that gap; no conclusion is read off a single cell. Where a single cell
> does something unexpected (§7.1), the missing layer is the first explanation to reach for, not
> the last.

### 7.1 The ORM axis, heavy: the arms do not diverge in cost, they diverge in *headroom*

**p50 mean, p99 and p99.9 as ab–ba range (n=2 per cell), ms**

| offered rps | hibernate p50 | p99 | p99.9 | jdbc p50 | p99 | p99.9 |
|---:|---:|---:|---:|---:|---:|---:|
| 600 | 2.04 | 3.07–3.10 | 3.92–4.04 | 1.43 | 2.30–4.04 | 2.52–4.61 |
| 1200 | 2.09 | 3.09–11.52 | 3.95–13.92 | 1.33 | 2.33 | 2.59–2.60 |
| 1800 | 2.18 | 3.60–3.68 | 4.75–5.20 | 1.43 | 2.36–4.09 | 2.61–4.81 |
| 2400 | 2.09 | 3.56–3.66 | 5.41–6.39 | 1.33 | 2.35 | 2.61–2.66 |
| 3000 | 3.49 | 5.25–15.07 | 10.69–19.31 | 1.33 | 2.38 | 2.66–2.67 |
| 3400 | 3.34 | 8.50–9.01 | 15.30–21.97 | 1.34 | 2.38–2.40 | 2.67–2.69 |

**`spring-jdbc` is flat across the entire range.** From 600 to 3400 rps — 5.7× the load — its p50
moves between 1.33 and 1.43 ms and its p99 sits at ~2.35 ms apart from two single-leaf excursions.

> **Those two excursions have no assigned cause — and that is what the design predicts, not a
> surprise.** `spring-jdbc` reads p99 4.04 at 600 rps (`ba`) and 4.09 at 1800 rps (`ab`) against
> ~2.35 everywhere else — a *worse* tail at *lower* load, which is the opposite of the pattern the
> rest of the section describes.
>
> What was checked and ruled out: they are **not the same direction** (one `ba`, one `ab`), **not
> the first leaf** of the campaign, and not a warmup-volume effect (the 1800 leaf saw 108 k warmup
> requests, more than the clean 1200 leaf's 72 k). What they do share is a signature: p50 +12 % and
> p99 +73 % against the arm's own baseline **with cpu/req, RSS and thread count unchanged**
> (333/306 µs against 325/315 µs in clean leaves) — the arm was not doing more work, so this looks
> like a transient stall from outside the process rather than anything about load.
>
> **That signature is exactly what the missing restart layer would produce.** A per-leaf disturbance
> with no work attached to it is a relaunch-scale event, and this campaign has **no repeat to
> compare against** — n=2 is two directions inside one JVM lifetime (see the note above). A single
> outlying leaf with nothing to hold it against is the predicted symptom of a layer this campaign
> does not sample, so "unexplained" over-states the mystery: the instrument that would name it was
> not run. Resolving it needs repeats at these rungs, not a mechanism.
>
> Neither reproduced in the other direction at the same rung. Magnitude is 1.7×, well below the
> near-capacity excursions in §7.3, and in the opposite load regime. **No claim in this report
> rests on those two cells**, and the ranges are printed unsmoothed so a reader sees them.
`spring-hibernate` rises: p50 +64 %, p99 roughly ×2.8, p99.9 from ~4 ms to 15–22 ms.

**This is the result that makes §4's ×3.95 legible.** At 600 rps the median gap is 1.43× — nothing
like ×3.95. The cpu/req ratio does **not** appear as a proportional latency penalty, because at low
load there is spare capacity to absorb the extra work. What it buys instead is the point at which
the arm stops absorbing it: at 3400 rps — a load `spring-jdbc` does not notice, being at 27 % of
its own capacity — `spring-hibernate` is at 94 % of its and its tail has left the building.

**The honest one-line reading of both contracts: the repository layer does not make a request
slower, it makes the arm run out of headroom sooner.** That statement holds on heavy and on light;
"×3.95 slower" holds on neither.

### 7.2 The ORM axis, light: indistinguishable until the ceiling

| offered rps | hibernate p50 | p99 | p99.9 | jdbc p50 | p99 | p99.9 |
|---:|---:|---:|---:|---:|---:|---:|
| 4000 | 0.98 | 1.89–2.41 | 2.19–2.83 | 0.89 | 1.87–1.88 | 2.09–2.10 |
| 8000 | 0.95 | 1.94–1.95 | 2.30–2.42 | 0.93 | 1.89–1.94 | 2.24–2.28 |
| 12000 | 1.18 | 2.24–2.81 | 3.69–4.59 | 1.02 | 2.05–2.07 | 2.50–2.64 |
| 16000 | 1.23 | 2.64–2.69 | 3.64–5.21 | 1.12 | 2.42–2.44 | 2.99–3.68 |
| 20000 | 1.35 | 3.00–3.07 | 4.58–4.70 | 1.31 | 2.79–2.92 | 3.87–4.14 |
| 24000 | 1.57 | 4.03–4.04 | 11.16–20.06 | 1.31 | 3.03–3.07 | 4.38–5.85 |

On the single-row read the two arms are **within a few percent of each other up to 20 000 rps**
(1.35 vs 1.31 p50; 3.00–3.07 vs 2.79–2.92 p99). The ×1.17 cpu/req difference of §4 buys
*no measurable latency difference at all* until the load approaches hibernate's ceiling. At
24 000 rps (88 % of it) the medians separate modestly (1.57 vs 1.31) and the far tail separates
sharply: p99.9 11.16–20.06 against 4.38–5.85.

Same shape as heavy, at a different scale — which is what "loss of headroom, not slower requests"
predicts and what a fixed per-request tax would not.

### 7.3 L5 — resolved, and neither of the two hypotheses was right

L5 asked whether `spring-on-exeris-pure-native`'s light-contract tail is a real property or a
closed-loop artefact. The closed-loop measurement had it at **p50 2.00 / p99 12.49 ms** against
`exeris-community`'s 1.48 / 7.46 — the worst p99 of the four ladder arms, worse than Tomcat, with
a p99/p50 ratio of 6.26 against community's 5.05.

**Open loop, matched offered rate** (p50 mean; p99 / p99.9 as ab–ba range, ms):

| offered rps | community p50 | p99 | p99.9 | pure-native p50 | p99 | p99.9 | p99 ratio | p99.9 ratio |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 000 | 0.87 | 1.86–1.88 | 2.04 | 0.89 | 1.97 | 2.27 | 1.05× | 1.11× |
| 20 000 | 0.83 | 1.73–1.91 | 2.10–2.22 | 0.95 | 2.00–2.01 | 2.37–2.39 | 1.10× | 1.10× |
| 30 000 | 0.97 | 2.17–2.18 | 2.55–2.57 | 1.19 | 2.57–2.73 | 3.21–3.25 | 1.22× | 1.26× |
| 40 000 | 1.21 | 2.71–2.73 | 3.12–3.14 | 1.35 | 3.24–3.26 | 4.19–4.22 | 1.19× | 1.34× |
| 45 000 | 1.21 | 2.69–2.83 | 3.20–3.33 | 1.44 | 3.96–4.02 | 6.85–7.38 | 1.45× | **2.18×** |
| 50 000 | 1.33 | 3.12–3.14 | 3.74–3.76 | 1.54 | 4.51–5.00 | 9.81–11.56 | 1.52× | **2.85×** |

**What does not survive:**

- *"The worst p99 of all four arms, worse than Tomcat."* At matched sub-saturation load pure-native
  tracks community closely — p99 within 5–22 % up to 40 000 rps.
- *The p99/p50 = 6.26× shape.* Open loop at the top rung gives 5.00/1.54 = 3.2× for pure-native and
  3.14/1.33 = 2.4× for community. The shape difference is far smaller than closed loop implied.
- *The absolute magnitude.* 12.49 ms becomes 4.51–5.00 ms at the highest sustainable rate — the
  closed-loop figure was inflated ~2.5× by queueing.

**What survives, restated:** the excess is **real but load-dependent**. It is absent below
~30 000 rps, appears as a widening p99, and turns sharp in the far tail above ~80 % of capacity —
p99.9 goes 1.34× → 2.18× → 2.85× over the last three rungs. The defensible claim is not
*"pure-native has a pathological tail"* but **"pure-native's tail degrades earlier and faster than
the native baseline's as either approaches capacity"**, with the divergence beginning around
30 000 rps on this contract and this box.

**Why both original hypotheses were wrong.** "Queueing artefact" is wrong because the effect
reproduces open-loop. "Service-time property" is wrong because it is not present at moderate load,
which a per-request property would be. It is a *capacity-approach* behaviour, and only a rate
ladder can see it — a saturating driver reports the endpoint and a single sub-saturation point
reports nothing.

L5's own localisation still stands and is now the open part: the excess appears where Spring and
native persistence are both in the path, and neither alone shows it. What changed is that the
question is no longer "is it real" but "what makes it start at ~30 k".

---

## 8. Open questions — answered, carried, and why the rest do not block

This report answered two of its own open questions while it was being written, and both were worth
chasing by the same test: **could the answer overturn a headline?**

- **L5 — the pure-native light tail. ANSWERED (§7.3), and it overturned both hypotheses.** Not a
  closed-loop artefact (it reproduces open-loop) and not a flat service-time property (absent
  below ~30 000 rps). It is a capacity-approach behaviour, and the closed-loop figure had
  overstated it ~2.5×. CLAIMS L5 rewritten.
- **The hosting step's security confound. ANSWERED (§6), and it cost the rung a quarter of its
  size.** +28.31 ± 3.25 µs/req, 23.3 % of the 121.52 µs step, correcting it to ×1.09–1.10. The
  term had been carried as *unbounded*; ×1.127 is now retired from the citation canon rather than
  merely qualified.

**Nothing remaining passes that test, which is why this report ships with the rest open.** Each is
stated where it belongs and none of them can move a claim made here:

| carried forward | what an answer would change | why it does not block |
|---|---|---|
| **L10** — how much of the repository-layer cost is Spring Data projection proxies rather than Hibernate | splits the pool | The report has already **retracted** the plain-"ORM" label and attributes the cost to the Spring Data repository layer (§5). An answer refines the split; it cannot restore the label. |
| **L9** — inter-pair drift is a per-request cost increase, not CPU starvation | explains a 1–3 % drift | No claim rests on it, and it is not addressable from any campaign: it needs per-core counters (LLC / memory bandwidth, SMT siblings) the rig does not sample. That is new instrumentation, not a new run. |
| the split of L11's 28.31 µs between authorization work and 170 bytes of security headers | refines L11 | The full figure is correct for the question the rung asks (*what does removing Spring Security save*); the split only matters for a narrower question this report does not ask. |
| the mechanism behind L5's ~30 000 rps onset | explains L5 | L5's claim is stated as a behaviour with a measured onset, not as a mechanism. |

**The one thing that did block publication was not an open question, and it is now closed.** §2's
error budget carried numbers with no cited source; it is now derived from this report's own six
campaigns by `tools/derive-error-budget.sh` (§2.2). That was bookkeeping, not research — but the
bookkeeping found three real defects, which is the argument for doing it rather than attaching
citations to the numbers that were already there (§2.2, retired-table note).

*(Arm 3's version skew is no longer listed here — it is a decision, taken on 2026-08-11 to publish
with the fence rather than hold the report, and it lives in fairness posture 5.)*

---

## Revision history

<!-- One of the four summarizing surfaces. Every retraction stays visible, per house style. -->

- **2026-08-11 — draft opened.** Skeleton with §2–§6 data from committed campaigns; §7 pending.
- **2026-08-11 — the security confound closed, and it cost the hosting rung a quarter of its
  size.** `spring-hibernate` against the same jar with the servlet filter chain disabled measured
  **+28.31 ± 3.25 µs/req** (light, n=3 complete repeats, 12/12 leaves eligible) — **23.3 % of the
  121.52 µs hosting step**, which corrects the rung to **≈ 89–96 µs, ×1.09–1.10**. The term had
  been carried as *unbounded* since the ladder was published; it is now a number, and the audit
  instinct that demanded the qualifier was right about the magnitude. Two fences came with it: the
  cross-contract subtraction remains an assumption (heavy agrees at +32.58 µs but with 29 %
  uncertainty, so it cannot prove constancy), and 170 bytes of security response headers — 567 %
  of the 30-byte light body — are inside the 28.31 µs and are not separated from authorization
  work. **The byte-identical claim is corrected at its real scope**, which is wider than this pair:
  the response-checksum control (`82f9bcdf2852bd5e`, 9105 bytes, reported across **all four ladder
  arms plus `comp-native`** and used as a fairness control against serialisation-volume effects)
  was computed on **bodies only**. Arms 1–3 carry Spring Security and arms 4–5 do not, so it never
  covered full responses on **any auth-crossing pair**. It remains valid as a *content* control.
  §4's ORM pair is unaffected — one shared `SecurityConfig`, identical headers — and the correction
  must not be stretched to it.
- **2026-08-11 — §7 landed, and it changed two headline framings.** The open-loop campaign
  (36/36 eligible) replaced "the ORM costs ×3.95" with "the repository layer costs headroom, not
  per-request latency", which is the only form that holds on both contracts. And it **resolved
  L5 against both of its own hypotheses** — the tail is neither artefact nor flat property but a
  capacity-approach behaviour, with the closed-loop magnitude overstated ~2.5×. Percentile
  reporting switched to ab–ba ranges after tail metrics proved far more order-sensitive than the
  cpu/req arm-order term covers.
- **2026-08-11 — the error budget was re-derived, and the old one turned out to be wrong in four
  ways.** §2's table had been quoted forward from earlier work with no citation. Tracing it found
  every row: harness noise and arm order came from **one n=1 exploratory cell**
  (`20260724-…-3way-kernel-profile-LIGHT/counterbalanced-cell/`) on a different heap/GC/pool
  configuration; DB network mode came from the 2026-06-20 report's prose, whose **bridge leg is not
  committed anywhere**; runtime snapshot had no written derivation at all. Rather than attach
  citations to numbers measured on other arms, the budget is now **derived from this report's own
  six campaigns** — `tools/derive-error-budget.sh`, 220 observations,
  [CSV committed](assets/2026-08-11-error-budget-derivation.csv). Consequences: the single
  ±2.00 % arm-order row **split by contract** (1.00 % heavy / 2.71 % light — the old figure
  over-stated heavy ~2× and under-stated light); the total **±2.80 % became ±2.52 % heavy /
  ±3.71 % light**, combined in quadrature rather than summed; the DB-network row was **removed from
  the budget entirely** because it is a fence, not a tolerance (§2.1). Two claims changed: the
  ladder closure's +2.0 % is inside the heavy envelope but **not** inside the arm-order term alone,
  as previously written; and the "p99 is ~85× more sensitive than cpu/req" figure is fenced to
  **the light contract only** (heavy: 2.1×) and to **closed-loop percentiles**, i.e. queue
  occupancy rather than service time (§2.3). No conclusion in the report is overturned; three are
  now stated more tightly.
- **2026-08-11 — §7's own uncertainty measure was the one §2.4 disqualifies, and the fence for it
  was already in the document.** §7's 36 leaves are 6 rungs × two *directions* × three ladders:
  **n=2 per cell is two directions, not two repeats**, so both leaves share one JVM lifetime,
  warmup and JIT state — precisely the layer §2.4 calls under-stating because it omits restart
  variance. The ab–ba spread is therefore a **lower bound on uncertainty, not an envelope**, and
  §7 now says so. Consequence for §7.1: the two `spring-jdbc` excursions (p99 4.04 at 600 rps,
  4.09 at 1800, at unchanged cpu/req, RSS and thread count) are **no longer described as
  unexplained anomalies** but as the predicted symptom of the missing layer — a relaunch-scale
  disturbance in a campaign with no repeat to compare against. Resolving them needs repeats at
  those rungs, not a mechanism. No conclusion moves: every §7 result is read off the shape across
  six rungs, and none off a single cell.
- **2026-08-11 — §2.1 was leading with its weakest evidence.** The network-mode fence row quoted
  the June `+20.5 %` / 0.357 → 0.358 ms figures, whose own caveat concedes the bridge leg is not in
  the repository — inside the section whose job is to establish what may be trusted. The row now
  leads with the measurement from **this** report's campaigns (DB-cpuset busy **87.36 % → 37.34 %**
  at identical delivered throughput, 55 of the 87 points `sys`+`soft`), and the June figure drops
  to a footnote as the fence's historical origin. Same content, reversed weight.
- **2026-08-11 — the byte-identical correction was scoped to half of what it affects.** It read
  "the two arms' responses", meaning the security-confound pair. The underlying control — response
  checksum `82f9bcdf2852bd5e`, 9105 bytes, reported across **all four ladder arms plus
  `comp-native`** and used as a fairness control against serialisation-volume effects — was
  computed on **bodies only**, and ladder arms 1–3 carry Spring Security where 4–5 do not. It
  therefore never covered full responses on **any auth-crossing pair**. It stands as a *content*
  control. §4's ORM pair is explicitly excluded from the correction: one shared `SecurityConfig`,
  identical headers.
- **2026-08-11 — TL;DR compressed and the frontmatter `summary:` written.** The TL;DR had grown to
  seven bullets with a ~90-word opener; a summary that reads as long as a section stops
  summarising, and every extra word is somewhere a quantifier can slip. Now a one-line lede plus
  six bullets, same numbers. The `summary:` is written **from §7.1, deliberately not from §4** —
  it is the only surface that reaches aggregators, RSS and search stripped of its fences, and
  ×3.95 is both the most quotable number in the report and one the body says holds on neither
  contract. It does not appear there.
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
