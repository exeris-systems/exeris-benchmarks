---
title: "DRAFT — Where the request actually goes: a Spring hosting ladder and the ORM axis, measured on both hosts"
date: 2026-08-11 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
summary: "One Spring application served five ways on dedicated bare metal, under two fixed contracts and two instruments. The repository layer costs headroom, not per-request latency: at 600 rps the heavy median gap is x1.43 and on the single-row contract the arms are indistinguishable up to 20 000 rps, but the Hibernate arm reaches 94 % of its capacity while the JDBC one stays flat. The largest identified contributor is Spring Data's projection proxies rather than Hibernate's own row mapping — the pair moves both and the split is unmeasured. The hosting swap is smaller than either, and 23 % of it turned out to be Spring Security."
# Written from 7.1 (service time), deliberately NOT from 4 (cost). x3.95 is the most quotable
# number in this report and the body says it holds on neither contract, so it must not appear
# here: this is the only surface that travels to aggregators, RSS and search without its fences.
#
# Second trap, caught 2026-08-11: this line must not resolve L10. Section 5 says the attribution
# to Hibernate specifically "is not established by these arms" and section 8 carries the split as
# an open item. "Largest identified contributor ... split is unmeasured" is the strongest form the
# data supports; "it is X rather than Y" is not, however quotable it reads.
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: entity-read-by-id
reproducibility_status: incomplete
# NO claim_scope FIELD, DELIBERATELY — removed 2026-08-11.
#
# A whole-file claim scope is the wrong shape for a report, and for this one it would be false
# in every available value. The file mixes: 108 gated units that are comparison_eligible, two
# pairs that are non_eligible BY DESIGN because they cross the Pure-vs-Compat axis, an
# exploratory-class Amdahl derivation (L3), and descriptive footprint data. "comparison_eligible"
# would over-claim the compat pairs; "exploratory" would under-claim 108 gated units; any single
# value erases the axis separation the report exists to maintain.
#
# Eligibility in this repo is a per-campaign, per-pair property, and it is now stated at EVERY
# data table with its campaign id and unit count. That is where a reader should look, and a
# frontmatter field that contradicts or flattens those statements is worse than no field.
#
# Nothing consumes it either: publish-report.sh reads claim_scope from the RESULT JSON, not from
# report frontmatter, and 2026-06-20-entity-read-by-id-artifacts.md already carries none.
#
# reproducibility_status STAYS, because it is a genuine file-level property and it is honest:
# every number here was re-derived from committed artefacts exactly once, by the person who
# wrote it. Flip it when someone else re-derives the headline figures.
comparison_axis: within-tier
hardware_profile: perf-box-amd64
---

# DRAFT — Where the request actually goes: a Spring hosting ladder and the ORM axis, measured on both hosts

*One Spring application served five ways, plus a native baseline, under two fixed contracts on dedicated bare metal.*

> **DRAFT STATUS — content complete as of 2026-08-11.** Every section is written, every TODO is
> closed, and nothing is waiting on data or on a campaign. The last experiment (§6's security
> confound) closed at **+28.31 ± 3.25 µs/req**; the last hard blocker (§2's unsourced error budget)
> closed by deriving it from this report's own campaigns (§2.2, `tools/derive-error-budget.sh`);
> the last section-level gap (§6b footprint) closed with a finding of its own. Three editorial
> questions are decided: the compat rung stays out of §6's pure ladder and goes to the `compat/`
> track, arm 3 publishes with its version-skew fence rather than holding the report for an
> alignment campaign, and the open questions in §8 ship open with an argument for why none of them
> moves a headline.
>
> It still says DRAFT for one reason: **every number here was re-derived from its artefacts
> exactly once, by the person who wrote it.** That is enough to make the report honest and not
> enough to make it reviewed. `reproducibility_status` stays `incomplete` until someone else
> re-derives at least the headline figures. Every number is from a committed, gate-passing
> campaign; **none is provisional or estimated.**

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
- **The largest identified contributor is Spring Data's projection proxies, not Hibernate's own row
  mapping — and the plain "ORM" label is retracted.** JFR puts Spring AOP and reflection *above*
  Hibernate's tuple materialisation, and one proxy per returned row explains the contract
  dependence (heavy ~200 rows, light none) (§5). **The pair moves both, so the split is unmeasured**
  and stays open as L10 (§8) — what is retracted is the label, not the pool. Cheapest fix is
  therefore DTO constructor expressions on JPA, not `JdbcTemplate`. This also **replaces an
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
- **Footprint: the Exeris-hosted arms hold less memory under load, and only Tomcat's grows with the
  contract.** At an equal 1280 MB committed heap the loaded spread is **1.58×** — community
  1057 MB, pure-native 1102, pure 1233, Tomcat **1662** on heavy — and `spring-hibernate` is the
  only arm that responds to the contract (+31.8 % light→heavy against ≤ 2.7 % for the rest), which
  is §5's row materialisation showing up in memory. **Idle RSS, though, is not one number per
  arm:** it depends on whether the process has ever served, by **1.9× to 5.5×**, so L8's single
  idle figure averages two states — for `exeris-community` it reports 630 MB, the mean of 194 and
  1066, a value the process never holds. Idle *CPU* is unaffected by that and stands (§6b).

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

Comparative runs in this repo **fail closed**: a directory without the four required artefacts is
not a weak result, it is not a result. Across the five campaigns this report draws on — the
ladder, the ORM axis, both wrk2 curves and the security confound — that is **108 gated units**
(one per pair per direction), and every one of them carries all four:

| artefact | present | says |
|---|---:|---|
| `stage7-gate-report.csv` | 108/108 | per-gate verdict rows — **1080 rows, every one `PASS`** |
| `stage7-gate-summary.json` | 108/108 | the roll-up the runner writes at stage 7 |
| `claim-status.json` | 108/108 | final status — **108/108 `comparison_eligible`** |
| `rejection-codes.json` | 108/108 | **all 108 are empty arrays** |

- 12/12 units `comparison_eligible` for the ORM campaign specifically, zero rejection
  codes, zero errors.
- **`track_id` isolation holds by construction.** Every unit carries exactly one of two values —
  **54 `track-ab-01` and 54 `track-ba-01`** — so gate evaluation is per-direction and no verdict
  is ever borrowed across the counterbalancing axis. Where this report averages both directions
  (arm means, "n=6 per arm = 3 repeats × ab/ba") it says so at the table, and the spread between
  them is not smoothed away: it is the arm-order term of §2.2.
- **Ten gates run per unit**, and they are named rather than counted: `G1 track_isolation`,
  `G2 eligibility_only`, `G3 equivalence_strict`, `G4 ab_ba_required`, `G5 drift_placeholder`,
  `G6 metadata_completeness`, `G7 pin_verification`, `G8 schema_validation`,
  `G9 quarantine_transparency`, `G10 reporting_guard`.

> **One of those ten cannot fail on these campaigns, and "10/10 PASS" should not be read as if it
> could.** `G5 drift_placeholder` compares an *observed* drift against a *maximum* drift for
> latency and throughput, and the check is real code — but the observed values are read from
> `BENCHMARK_DRIFT_OBS_*_PCT`, which **nothing in the harness populates**, so they default to `0`;
> the thresholds default to `0` as well. On all **216 leaves** of these five campaigns the gate
> therefore evaluates `0.00 ≤ 0` and passes. It verifies that the field exists, not that drift is
> bounded. The gate's own name is honest; `docs/methodology.md` describing it as *"fails if
> observed drift exceeds configured thresholds"* is true of the code and vacuous in practice, and
> is corrected there. **Nine gates are load-bearing here, not ten** — this is the same
> silent-default family as the four defects in the revision history, caught by asking what a
> passing check actually compared.
- **The load-generator ceiling was checked for the first time on this data and passed:** 24/24
  windows `loadgen_headroom_available`, max 16.3 % busy. A saturated load generator does not
  bound a result, it *invalidates* it — the number would describe how fast wrk can offer
  requests. That check had never run on this campaign because the aggregation step was manual
  and nothing in the harness called it; it is now derived at window close (`879ac63f`).

**What this section is claiming, exactly.** Not that the numbers are right — that the runs were
*allowed to produce numbers at all*. Every comparative figure in this report comes from a unit
that cleared the four artefacts above with an empty rejection list, and the two checks that had
never actually run on this data (the load-generator ceiling, and `--role`-correct mpstat
aggregation) now do, and passed. What that does **not** cover is anything the gates do not
measure: G5 above, the error budget of §2, and every fence stated in §2.1 and the fairness
posture. **A passing gate is a floor, not a warrant.**

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

**Ladder campaign (bridge, n=12) and ORM campaign (host, n=6). Read the network-mode column first.**

Mean DB-cpuset utilisation over each arm's own measurement window, heavy contract.
**The DB-busy column is not homogeneous — read the network-mode column first.**

| arm | rps | own pin | DB busy | network | reading | bounded by |
|---|---:|---:|---:|---|---|---|
| `spring-hibernate` | 3 664 | 98.7 % | 30.5 % | bridge | **upper bound** | its own CPU |
| `spring-on-exeris-pure` | 4 131 | 98.7 % | 34.9 % | bridge | **upper bound** | its own CPU |
| `spring-on-exeris-pure-native` | 12 645 | 73.3 % | 99.8 % | bridge | upper bound, but *at the ceiling either way* | **the database** |
| `exeris-community` | 13 107 | 69.1 % | 99.8 % | bridge | upper bound, but *at the ceiling either way* | **the database** |
| `spring-jdbc` | 12 664 | — | **97.4 %** | **host** | **Postgres utilisation** | **the database** |

Sources: rows 1–4 `20260806T183034Z-spring-ladder-n3` (n=12, bridge, **48/48 units
`comparison_eligible`**); row 5 `20260810T131208Z-hibernate-vs-jdbc-n3` (n=6, host, **12/12
`comparison_eligible`**). **A bridge figure and a host figure are not comparable** (see Setup). The two saturated bridge rows survive the caveat only because an upper
bound pinned at 99.8 % still establishes saturation; the two low bridge rows establish *headroom
exists*, not how much.

The consequence is the reading rule for this whole report: **a heavy throughput ratio between a
fast arm and a slow arm is a lower bound with one side capped**, so quote cpu/req there. On light
every arm leaves the database with substantial headroom (37 % measured on host) and throughput is
meaningful.

### 3.1 What a faster database would be worth — and which of those bounds survive the bridge

L2 turns the table above into a forward-looking bound: *how much would a better database buy each
arm?* An arm pinned at 98.7 % of its own CPU cannot spend a faster database on anything, so its
upside is its own idle time; an arm sitting at 99.8 % DB-busy with a third of its own pin free has
upside equal to that free pin. Restated here with the network-mode provenance attached to each,
which L2 does not carry inline:

| arm | own-pin idle | DB busy | a faster DB is worth | measured on | does the bridge caveat bite? |
|---|---:|---:|---:|---|---|
| `spring-hibernate` | 1.3 % | 30.5 % | **≤ 1.3 %** | bridge | **no** — the bound comes from the *own-pin* column, which the bridge does not touch |
| `spring-on-exeris-pure` | 1.3 % | 34.9 % | **≤ 1.3 %** | bridge | **no** — same reason |
| `spring-on-exeris-pure-native` | 26.7 % | 99.8 % | **+36 %** | bridge | **partly** — see below |
| `exeris-community` | 30.9 % | 99.8 % | **+45 %** | bridge | **partly** — see below |

**The two `≤ 1.3 %` bounds are unaffected by the bridge, and this is not a technicality.** They
are computed from the arms' *own-pin idle*, not from the DB-busy column: an arm with 1.3 % of its
own CPU left has at most 1.3 % of upside no matter what the database does, and no matter whether
the DB-busy figure beside it is inflated by container networking. The bridge inflates the *DB*
reading; these two bounds never used it. **They are the strongest rows in this table** — a
`spring-hibernate` deployment gains essentially nothing on this contract from a faster database,
and that survives every caveat in this report.

**The `+36 %` and `+45 %` bounds are directionally safe but their precision is not established.**
They assume the arms are DB-bound, which the 99.8 % figure establishes — and here the bridge
caveat is *benign in direction*: a bridged DB-busy figure is Postgres **plus** container
networking, so it can only overstate database load. An overstated figure pinned at 99.8 % still
proves saturation, because the true value cannot be higher and the arm is demonstrably not
limited by its own pin (26.7 % / 30.9 % idle). What the bridge does undermine is the *quantity*:
the headroom released by removing the DB as the limit is being read off a cpuset whose occupancy
is partly the network stack, and §2.1 measures that deformation at ~50 points on the light
contract. **Quote them as "up to", not as forecasts**, and note that both are single-campaign,
bridge-mode, n=12.

> **One row in this table is host-measured and it changes the sharpest reading.** `spring-jdbc` at
> **97.4 % DB busy on host networking** is the only genuine Postgres-utilisation figure here —
> `docker-proxy` is off the path, so there is no networking component inside it. It says that an
> ORM-free Tomcat arm hits the same database wall the two fast Exeris arms hit, at almost the same
> throughput (12 664 vs 12 645 rps). **The database wall is a property of the contract, not of the
> stack that reaches it** — which is the cleanest available statement of L2's headline, and the
> only one in this table that needs no caveat at all.

---

## 4. The ORM axis, measured on Tomcat

**Host networking, n=6 per arm (3 repeats × ab/ba), 12/12 `comparison_eligible`, 0 errors.**

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

### 4.1 This is the arm L3 assumed, and the assumption was optimistic

L3 derives an Amdahl ceiling — *with the repository layer in the path, no runtime work can exceed
×1.488 on this contract* — and states its load-bearing assumption without hiding it: **the
repository component was measured on the Exeris-hosted arm and applied to Tomcat, because no
ORM-free Tomcat arm existed.** This campaign is that arm. The assumption is now testable rather
than assumed.

| | measured on | repository layer | as % of Tomcat's request | ceiling |
|---|---|---:|---:|---:|
| **L3, transferred** | Exeris-hosted (`pure` − `pure-native`, 955.88 − 231.91) | 723.97 µs | 67.2 % | **×1.488** |
| **§4, direct** | Tomcat (`spring-hibernate` − `spring-jdbc`, 1074.74 − 271.75) | **802.99 µs** | **74.7 %** | **×1.338** |
| | | **+10.9 %** | +7.5 pt | −10 % |

**The assumption holds in direction and misses in magnitude by about a tenth.** Hosted on Tomcat
the repository layer costs **10.9 % more** than the figure L3 carried over, so it is **74.7 % of
the request, not 67.2 %**, and the ceiling on runtime work is **×1.34, not ×1.49**.

**The correction moves against the runtime, and that is worth saying plainly.** A directly
measured ceiling that is *lower* than the assumed one means L3 overstated how much any runtime
work can win on this contract. What it strengthens is L3's own conclusion: if the repository layer
is three quarters of the request rather than two thirds, the migration-order advice — repositories
first, runtime second — is more strongly supported, not less.

> **Why a cross-campaign subtraction is legitimate here, with the control that makes it so.**
> The two rows come from different campaigns and different network modes (ladder: bridge, n=12;
> this campaign: host, n=6), which §2.2's budget does not cover. The join rests on the arm they
> share: `spring-hibernate` reads **1077.40 µs** on the ladder and **1074.74 µs** here — **0.25 %
> apart**, an order of magnitude inside even the heavy single-comparison envelope. That agreement
> is the control, and it independently reproduces the network fence's own claim (§2.1) that
> bridge-vs-host leaves application cpu/req alone. One caveat survives: both subtractions replace
> JPA with a different hand-written data layer (`JdbcTemplate` here, the kernel-native repository
> API there), and both keep pgjdbc and HikariCP in the path, so they measure the same *layer* but
> not the same *implementation of its replacement*.

**One interaction worth recording, because two corrections nearly cancel.** L3 tracks "share of
the addressable pool already captured by the hosting rung". Its original figure was
121.52 / 353.43 = **34.4 %**. L11's security correction cut the numerator to 93.21 µs, dropping it
to **26.4 %**. This section cuts the denominator to 271.75 µs, which puts it back at **34.3 %**.
Both terms fell by ~23 % independently and the ratio survived. Quote the ratio only with both
corrections applied — and with the standing caveat that the rung is measured **on** the ORM stack
while the remainder is measured **off** it, which is the same class of transfer L3 was doing.

### 4.2 The commercial reading, stated in the order a customer should execute it

**The largest single change available on this contract involves none of our software.** Measured
on the customer's own Tomcat, replacing the Spring Data JPA repository layer is worth
**802.99 µs of a 1074.74 µs request — ×3.95 cpu/req**. The runtime swap on top of it is worth
**×1.09–1.10** (§6, security term removed). Those two numbers belong in that order, because it is
the order the data supports and the order a team should execute in.

Three things keep this honest rather than modest:

- **×3.95 is the full rewrite, not the cheap rung.** It is `JdbcTemplate` — hand-written SQL,
  hand-mapped rows. §5's finding is that the *largest identified contributor* is Spring Data's
  projection proxies, which suggests a much cheaper first step (DTO constructor expressions,
  staying on JPA) capturing an **unmeasured** share of the 802.99 µs. Nobody has built that arm
  (L10, §8). A team should measure it before committing to either rewrite.
- **The ordering is not a concession we are forced into, it is the finding.** A benchmark that
  tells a customer *"do the cheap step first, the one that needs none of our software"* is the
  same discipline as the retractions in this report, applied at product level. The runtime's
  case does not rest on being the largest term; it rests on being the term that remains once
  the customer has done everything they can do themselves.
- **And after the repository layer goes, the hosting gap narrows sharply.** `spring-jdbc` on
  Tomcat reads 271.75 µs against `spring-on-exeris-pure-native`'s 231.91 — **39.84 µs apart**,
  of which the security term is an estimated 28.31 µs (§6, a light-contract figure applied to
  heavy, so an assumption). Net of it the two ORM-free stacks sit within roughly **5–15 %** of
  each other on cpu/req, against 12.4 % apart with the ORM in place. The runtime's advantage on
  this contract is **substantially an advantage at hosting a heavy repository layer**, not a
  uniform per-request edge. Stated as a range because the subtraction crosses campaigns, network
  modes and two different hand-written data layers; a `tomcat-jdbc` × `exeris-native` pair in one
  campaign would settle it and does not exist.

---

## 5. What the ×3.95 actually is — and why "the ORM" is the wrong name for it

**This is the report's most important correction. Heavy contract, JFR on the ORM pair.**

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
   second declares none. The 723.97 µs pool, the ceiling and the migration-order
   conclusion are unaffected in direction — that cost is real and does leave with the
   repositories — but the attribution to Hibernate specifically is not established by these arms.
   (The ceiling moved for a separate reason: measured on Tomcat rather than transferred it is
   **×1.338 against 74.7 %**, not ×1.488 against 67.2 % — §4.1. Both corrections point the same
   way, the layer matters *more* and is *less* exclusively Hibernate than the original claim.)

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
Not built; no campaign pending. It is carried as **L10 in §8**, with the reason it does not block
this report — the plain-"ORM" label is already retracted, and an answer refines the split rather
than restoring the label. The specification lives here; the decision not to wait for it lives
there. **Do not count this as a second open item.**

**Instrumentation caveats.** JFR `ExecutionSample` is Java-frames-only and says nothing about the
`%sys`+`%soft` half of the budget. The two arms' recordings have different denominators — 874 s
(hibernate, ≈ its own window) vs 1213 s (jdbc, resident and idle during its partner's leg) — so
jdbc's shares are diluted. Dilution shrinks its percentages uniformly and cannot manufacture the
asymmetry, but no cross-arm share is quoted here as like-for-like. Exploratory: no
`claim-status.json` rides on these views.

---

## 6. The hosting ladder, and where each rung's cost lives

**Ladder campaign, n=12 per arm per contract. Prose complete; see §6b for footprint.**

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
> **Where the control is cited, and what each carrier needs.** A fairness control used across a
> series leaves stale copies behind unless the propagation is named, so: `docs/CLAIMS.md` (L11)
> carries the correction as of 2026-08-11. `runtime/drivers/target-asset-matrix.json` and
> `scenarios/entity-read-by-id/comparative-pair-manifest.json` **need no change** — both already
> say *body* ("body byte-identical to all four ladder arms", "confirmed equal by response-body
> checksum"), and the manifest's pair (`pure-native` × `comp-native`) does not cross the auth axis
> at all, since neither arm carries Spring Security. The defect was never in the artefacts; it was
> in prose that dropped the word *body* when quoting them. Anyone citing
> `82f9bcdf2852bd5e` as evidence of wire-equal responses across an auth-crossing pair is
> over-reading it, and no committed artefact ever said that.
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
- **Amdahl consequence — and it is a softer ceiling than it first reads, in two different ways.**
  On *this* ladder, with the repository layer at **723.97 µs of a 1077.40 µs request (67.2 %)**,
  no amount of runtime work can exceed **×1.488**. Against it the hosting rung has actually
  delivered **×1.09–1.10** (§6 above, security term removed).

  **First softening: that figure is the transferred one, and §4.1 measures it directly.** The
  723.97 µs comes from the Exeris-hosted pair and is applied to Tomcat because this ladder has no
  ORM-free Tomcat arm. §4's campaign is that arm, and measured there the repository layer is
  **802.99 µs — 74.7 % of the request, ceiling ×1.338.** For a Tomcat deployment **quote ×1.34**;
  ×1.488 belongs to the Exeris-hosted derivation and should be named as such.

  **Second softening — restated with §5's corrected label, which changes what the ceiling *is*.**
  The denominator is not "the ORM" and not Hibernate — it is the **Spring Data repository layer**, whose largest
  identified component is projection proxies rather than row mapping (§5; the split is unmeasured,
  L10). That matters because **a ceiling set by a replaceable component is not a property of JPA.**
  A team that swaps interface projections for DTO constructor expressions shrinks the denominator
  without touching persistence or runtime, which *raises* the ceiling for any runtime work layered
  on top. So the ceiling — ×1.34 measured, ×1.49 transferred — bounds runtime work **given this
  repository implementation**, not given JPA, and the cheapest way to move it is the change that
  involves none of our software (§4.2). Both softenings point the same way: the number is smaller
  than L3 said *and* less fixed than it sounds.

### 6b. Footprint — and why "idle RSS" is not one number per arm

All four ladder arms ran a pinned **`-Xms1280m -Xmx1280m`** with `AlwaysPreTouch` off, so every
figure here is *pages actually touched at a common committed heap*, not memory required. Ladder
campaign, bridge (`20260806T183034Z-spring-ladder-n3`, **48/48 units `comparison_eligible`**),
n=12 per arm per contract. RSS is not
network-mode sensitive — `spring-hibernate` reads 1662 MB heavy on bridge here and 1668 MB heavy
on host in the ORM campaign, a 0.4 % difference — so this table transfers across the Setup split
that governs the throughput tables.

**Under load, in each arm's own measurement window:**

| arm | light | heavy | heavy vs light | heavy as % of committed heap |
|---|---:|---:|---:|---:|
| `exeris-community` | 1050 MB | 1057 MB | +0.7 % | 83 % |
| `spring-on-exeris-pure-native` | 1098 MB | 1102 MB | +0.4 % | 86 % |
| `spring-on-exeris-pure` | 1201 MB | 1233 MB | +2.7 % | 96 % |
| `spring-hibernate` | 1261 MB | **1662 MB** | **+31.8 %** | **130 %** |

Two things fall out. The loaded spread is **1.58×** at equal heap, ordered
community < pure-native < pure < Tomcat. And **only `spring-hibernate` responds to the contract**
— +31.8 % from light to heavy where the other three move ≤ 2.7 %, which is the same ~200-row
materialisation §5 attributes the cpu/req gap to, showing up in memory. Its 130 % of committed
heap is off-heap plus metaspace plus Tomcat's own buffers; the number is RSS, not heap occupancy.

**Resident and idle — and here the single number in L8 turns out to average two different
states.** The co-resident sampler records an arm that is launched but not driven. Whether that arm
has *ever served traffic* changes its RSS by up to 5.5×:

| idle arm | first touch (never served) | after serving | ratio |
|---|---:|---:|---:|
| `exeris-community` | **194 MB** | 1066 MB | **5.5×** |
| `spring-on-exeris-pure-native` | **312 MB** | 1100 MB | **3.5×** |
| `spring-on-exeris-pure` | **629 MB** | 1221 MB | **1.9×** |
| `spring-hibernate` | *not measured — see below* | 1248 (light) / 1679 (heavy) | — |

> **Why `spring-hibernate` has no first-touch reading, recorded as a harness note.** Warmup is
> per-target and runs immediately before that target's own window, and the two arms are *not*
> relaunched between `ab` and `ba` (§2.4). A never-served neighbour is therefore observable in
> exactly one position — during the **first** window of the `ab` direction — which samples
> whichever arm is `target-b`. `spring-hibernate` is `target-a` in both pairs it appears in
> (`1-tomcat-vs-pure`, `4-tomcat-vs-native`), so it never occupies that slot. Nothing is wrong
> with the data; the pair layout simply does not expose that state for it. Alternating `target-a`
> across repeats would fix it at no cost.

**L8's idle-RSS column is the mean of these two states, and for one arm it names a value the
process never holds.** L8 reports `exeris-community` at 630 MB — which is (194 + 1066) / 2. The
arm is at 194 MB before it serves and ~1066 MB after; it is never at 630. The same averaging
flattens `spring-hibernate`'s 1248/1679 contract split into a single 1464.

**Three consequences, in order of how much they matter:**

1. **The idle-CPU finding is untouched.** Idle cores are state-invariant to three decimal places —
   `spring-on-exeris-pure` reads 0.0286 first-touch against 0.0280 after serving, pure-native
   0.0274 / 0.0268, community 0.0020 / 0.0020. Whatever the Spring-hosted composition is doing
   when idle, it starts doing it before the first request and does not change afterwards. L8's
   **~0.027 cores** stands exactly as re-scoped in §6 above.
2. **Post-service idle RSS ≈ loaded RSS**, within ~1 % on every arm and both contracts (community
   1066 vs 1057, pure-native 1100 vs 1102, pure 1221 vs 1233, hibernate 1679 vs 1662 on heavy).
   **Memory is touched and kept, not released between windows.** A "what does an idle replica
   cost" figure is therefore a *history* question, not a steady-state one.
3. **Density remains legitimately an RSS claim, and instances-per-core remains directional only —
   but now with a mechanism rather than a caveat.** L8 computes the memory-per-core at which idle
   CPU would bind before RAM: 32.7 GB/core for the leanest Spring-on-Exeris arm against 953 for
   Tomcat. Commodity servers run 2–8 GB/core and memory-optimised shapes 8–16, so **RAM binds
   first by an order of magnitude on all four arms** and the reflex to say "quoting only RSS picks
   the flattering axis" is wrong on these numbers. What *is* not citable is instances-per-core,
   and the reason is now measured: the touch ratio is a function of traffic history spanning
   **1.9× to 5.5× depending on the arm**, so the arms are not ranked on the same basis at all.
   `exeris-community` sits at 194 MB before it serves and ~1066 MB after, against Tomcat's
   1248–1679 — so the community-vs-Tomcat idle gap reads **1.2–1.6× after serving** and would read
   **6.4–8.7× before**, *if* Tomcat's own first-touch matched its post-service figure. That
   condition is plausible (it is already at 114–130 % of committed heap) but **unmeasured**, for
   the layout reason above, so the wider ratio is not claimed. A per-rung floor campaign is what
   would settle it, and it does not exist.

**What §6's headline keeps.** The hosting ladder's memory story is the loaded table: at equal
committed heap the Exeris-hosted arms hold 1098–1233 MB against Tomcat's 1261–1662, and the gap
*widens with the contract* because only the Tomcat arm's footprint tracks row count. The idle
story is the CPU one (§6 above), not the RSS one — RSS at idle says more about what the process
has done than about what it is.

> **L8's bridge confound, checked and cleared — with a correction to how the finding should be
> quoted.** L8 (an idle Spring-on-Exeris process burns ~18× what Tomcat or the native runtime
> does) came from the **bridge** ladder, where an unpinned `docker-proxy` can land on either
> cpuset. The test that cleared `docker-proxy` for L9 — cycle-stealing predicts *fewer cores at
> constant cpu/req*, and we observed flat cores with higher cpu/req — **cannot** be run on an idle
> arm: it serves nothing, so there is no denominator, and stolen cycles would look exactly like
> signal. The co-resident sampler (`neighbour-resource-metrics.json`, `role: resident-idle`)
> however runs on **every** campaign, host-net ones included, so this was a read rather than a run.
> `tools/extract-idle-coresidence.sh`, **264 idle windows over seven campaigns and both network
> modes** (96 bridge, 168 host), avg cores while launched-but-not-driven against a 4-core pin:
>
> | idle arm | hosting model | bridge | host |
> |---|---|---:|---:|
> | `spring-on-exeris-pure` | Spring-on-Exeris | 0.0280 | — |
> | `spring-on-exeris-pure-native` | Spring-on-Exeris | 0.0270 | **0.0252 / 0.0271 / 0.0276** |
> | `spring-on-exeris-comp-native` | Spring-on-Exeris | — | 0.0267 |
> | `spring-hibernate` | Tomcat | 0.0015 | **0.0015** / 0.0053 / 0.0078 |
> | `spring-hibernate-nosec` | Tomcat | — | 0.0075 |
> | `spring-jdbc` | Tomcat | — | 0.0012 / 0.0048 |
> | `exeris-community` | native Exeris | 0.0020 | 0.0041 |
> | `quarkus-tuned` | Quarkus | — | **0.0009** |
>
> **The confound is ruled out.** A `docker-proxy` sitting next to the Spring-on-Exeris arm under
> bridge would have to inflate its **bridge** figure specifically. It does not move at all:
> 0.0270–0.0280 on bridge against 0.0252–0.0276 on host — a 5 % spread across seven campaigns and
> both modes, with the *lowest* value on host. On the matched `-n3` designs the ratio **reproduces
> on host-net**: 0.0271 against `spring-hibernate`'s 0.0015 is **18.1×**, 22.6× against
> `spring-jdbc`, and **29.6× against `quarkus-tuned`**, which is the quietest arm measured.
>
> **The correction matters more than the confirmation.** The *numerator* is invariant
> (0.0252–0.0280, 5 % spread, every campaign, both modes); the *denominator* is not — quiet arms
> read **0.0009–0.0078 depending on campaign design**, an 8.7× range, with the six-rung curve and
> the security campaign well above the `-n3` pairs. The **ratio therefore inherits a variability
> the finding itself does not have**. Quote the absolute figure — **~0.027 cores, ~0.67 % of a
> 4-core pin** — which is the reproducible quantity, and give a ratio only with the pair and
> campaign attached. **§6b must not print a bare "18×".**

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
moves between 1.33 and 1.43 ms and its p99 sits at ~2.35 ms apart from single-leaf excursions.

**`spring-hibernate` rises, and the rise is in the tail rather than the median.** Its p50 mean
holds between **2.04 and 2.18 ms through the first four rungs**, then steps to **3.49 at 3000 and
3.34 at 3400** — the peak is the fifth rung, not the last, and the series dips at 2400 and again
at 3400. End-to-end that ratio is +64 %, and it is deliberately *not* quoted that way here: a
quotient of two cells hides both dips, implies a smoothness the ladder does not show, and is
exactly the single-cell reading the note above forbids. The tail is the cleaner signal — on
excursion-free leaves **p99 goes 3.1 → 3.1 → 3.6 → 3.6 → 5.3 → 8.8 ms**: two flat pairs and then
a step, with no reversal larger than 0.03 ms — and p99.9 from ~3.9 to 15–22 ms. Both arms are
therefore described by range and trend, not by end-point quotients.

> **The excursions — all of them, on one measure.** Four cells in this table have an ab–ba spread
> far outside their neighbours', and they are **not confined to one arm**. Quoting them by the
> same within-cell p99 ratio, against each arm's own baseline:
>
> | cell | clean leaf | outlying leaf | p99 ratio | p50 | cpu/req | threads | load vs own ceiling |
> |---|---:|---:|---:|---|---|---|---:|
> | jdbc 600 | 2.30 (`ab`) | 4.04 (`ba`) | 1.76× | +9.6 % | 348.1 → 333.2 µs (**−4.3 %**) | 43.0 → 43.0 | 5 % |
> | jdbc 1800 | 2.36 (`ba`) | 4.09 (`ab`) | 1.73× | +14.3 % | 321.1 → 306.4 µs (**−4.6 %**) | 43.0 → 42.9 | 14 % |
> | **hibernate 1200** | 3.09 (`ab`) | **11.52** (`ba`) | **3.73×** | +11.1 % | 935.7 → 922.2 µs (**−1.4 %**) | 43.0 → 42.9 | 33 % |
> | hibernate 3000 | 5.25 (`ab`) | 15.07 (`ba`) | 2.87× | +75 % | 1000.3 → 1000.9 µs (+0.1 %) | 43.0 → 43.0 | 83 % |
>
> *Ceilings measured at saturation on the same arms, `20260810T131208Z-hibernate-vs-jdbc-n3`:
> `spring-jdbc` **12 664 rps**, `spring-hibernate` **3 680** (n=6 each); the curve campaign's own
> top-rung attainment gives 3 628 for hibernate. The paragraph after this note reads 3400 rps as
> 27 % of jdbc's capacity — 3400/12 664 = 26.8 % — from the same numbers.*
>
> **The largest excursion on this table is in the arm the section characterises as *rising*, at the
> second rung** — 11.52 ms against a ~3.1 ms neighbourhood. It damages the growth story more than
> anything on the `spring-jdbc` side, and an earlier draft of this section gave three paragraphs to
> the two 1.7× cells and none to it. That asymmetry was not intentional and it is not defensible:
> attention unevenly distributed across one table reads as selection whatever produced it.
>
> **Three of the four share one signature, and it is the predicted one.** jdbc 600, jdbc 1800 and
> hibernate 1200 all sit **at or below a third of their arm's ceiling**, all move p50 by ~10 % and
> the tail by 1.7–3.7×, and all do it with **cpu/req flat or slightly *lower* and thread count
> unchanged** — the arm was not doing more work. A per-leaf disturbance with no work attached to it
> is a
> **relaunch-scale event**, and this campaign has no repeat to hold it against: n=2 is two
> directions inside one JVM lifetime (see the note above). So these are the predicted symptom of a
> layer this campaign does not sample, not an anomaly — "unexplained" over-states the mystery,
> because the instrument that would name it was not run. Resolving them needs repeats at these
> rungs, not a mechanism. What was separately checked and ruled out: not the same direction (two
> `ba`, one `ab`), not the first leaf of the campaign, and not a warmup-volume effect (the 1800
> leaf saw 108 k warmup requests against the clean 1200 leaf's 72 k).
>
> **The fourth is probably a different thing and is not claimed as the same.** hibernate 3000 sits
> at **83 % of its own ceiling**, in the regime where §7.3 shows tails growing for real, and its p50
> moves **+75 %** against ~10 % for the other three. Capacity-approach behaviour is the more
> economical reading there. It is the cell quoted in §7's preamble as evidence of order-sensitivity.
>
> **No claim in this report rests on any of the four**, every conclusion here is read off the shape
> across six rungs, and the ranges are printed unsmoothed so a reader sees them.
>
> **One systematic effect visible in the same leaves, recorded because it is a fence not a finding:**
> idle RSS is higher in `ba` than in `ab` for *every* hibernate rung (1312/1365, 1328/1396,
> 1336/1423, 1346/1436, 1352/1456, 1345/1465 MB) and weakly for jdbc too. Both arms hold more
> memory in whichever direction runs them second — which is direct confirmation that ab and ba
> share one JVM lifetime (§2.4) rather than being independent samples, and a reason **RSS must
> never be read off an ab–ba range**.

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

<!-- One of the four summarizing surfaces. Every retraction stays visible, per house style.
     Split into two lists on 2026-08-11: at seven flat entries the two that actually moved a
     claim were sitting among five notes about paragraph order and TL;DR length, which is the
     opposite of what this section is for. -->

### Findings and retractions — each changed a number or a claim

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

- **2026-08-11 — L8's bridge confound cleared by reading, and the finding re-scoped.** L8 (idle
  Spring-on-Exeris ≈ 18× Tomcat) came from the **bridge** ladder, where an unpinned `docker-proxy`
  can sit on either cpuset — and the test that cleared `docker-proxy` for L9 cannot run on an idle
  arm, which has no denominator. The co-resident sampler runs on every campaign, so this needed no
  new run: **264 idle windows (96 bridge, 168 host), seven campaigns.** The confound is ruled out —
  the Spring-on-Exeris figure does not move (0.0252–0.0280 across both modes, 5 %
  spread) — and the ratio **reproduces on host-net at 18.1×** on matched `-n3` designs. But the
  *denominator* turns out to vary **8.7× by campaign design** (quiet arms 0.0009–0.0078) while the
  numerator does not, so **the reproducible quantity is the absolute figure — ~0.027 cores, ~0.67 %
  of a 4-core pin — and a bare "18×" is not citable.** The ratio ranges 18.1–29.6× depending
  on which quiet arm it is taken against. Mirrored into CLAIMS L8. §6b's TODO is
  now prose-only; the data question inside it is closed.

- **2026-08-11 — RETRACTION: the plain-"ORM" label on the L3 pool.** Recorded here as a standing
  retraction rather than as an edit, per house style. **What was said:** *"Hibernate is 67 % of
  the cost"* (L3), with the 723.97 µs pool called the ORM component. **Why it was wrong:** the
  subtraction that produces the pool is between an arm using Spring Data JPA repositories **with
  interface projections** and one using none, so it contains the Spring Data projection-proxy cost
  as well as Hibernate's — and JFR on the new `spring-hibernate` × `spring-jdbc` pair puts Spring
  AOP and reflection frames *above* Hibernate's own tuple materialisation (§5). The label named
  one of two things the arms move together. **What survives unchanged:** the pool is real, it is
  that large, and it does leave with the repositories — so the Amdahl ceiling and the
  migration-order conclusion stand. **What replaces it:** *"the Spring Data JPA + Hibernate
  repository layer"*, and where a contributor must be named, *"the largest identified contributor
  is Spring Data's projection proxies rather than Hibernate's own row mapping — the pair moves
  both and the split is unmeasured"* (L10, §8). **Consumers who copied the old form should
  restate it**; the number did not change, the attribution did. §4.1 additionally shows the pool
  is **larger** than L3 carried — 74.7 % of the request measured directly on Tomcat against the
  67.2 % transferred — so the retraction narrows what may be *named*, not what may be *claimed*.

### Editorial corrections — found in review, changed nothing in the data

*All four were defects living **only** on a summarizing surface or in the ordering of evidence, in
a report that carries a footer note warning about exactly that. Recorded together because the
pattern is the point: the footer rule is not folklore, it is this list.*

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
- **2026-08-11 — TL;DR compressed and the frontmatter `summary:` written.** The TL;DR had grown to
  seven bullets with a ~90-word opener; a summary that reads as long as a section stops
  summarising, and every extra word is somewhere a quantifier can slip. Now a one-line lede plus
  six bullets, same numbers. The `summary:` is written **from §7.1, deliberately not from §4** —
  it is the only surface that reaches aggregators, RSS and search stripped of its fences, and
  ×3.95 is both the most quotable number in the report and one the body says holds on neither
  contract. It does not appear there.
- **2026-08-11 — and the `summary:` promptly failed the other half of its own rule.** The first
  version read *"the cost is Spring Data interface projections rather than Hibernate itself"* —
  which **resolves L10**, an item §8 carries as open and §5 declines twice ("the attribution to
  Hibernate specifically is not established by these arms"). The guard comment above `summary:`
  had been written against ×3.95 and caught it; this walked past. Both `summary:` and TL;DR bullet
  2 now read *largest identified contributor … the pair moves both and the split is unmeasured*,
  and the guard comment carries the second trap explicitly. **What is retracted is the label, not
  the pool** — that distinction is the whole of the correction.
- **2026-08-11 — §7.1 described its two arms with two different measures, and gave its attention
  unevenly across one table.** `spring-jdbc` was quoted as a *range* ("p50 moves between 1.33 and
  1.43") and `spring-hibernate` as an *end-point quotient* ("+64 %") — and the hibernate series is
  not monotonic: 2.04, 2.09, 2.18, 2.09, 3.49, 3.34, peaking at the fifth rung with dips at 2400
  and 3400. A quotient of two cells hid both, implied a smoothness the ladder does not show, and
  was itself the single-cell reading §7's own note forbids. Both arms now use range and trend.
  Separately, three paragraphs went to `spring-jdbc`'s two 1.7× excursions while the **largest
  excursion on the table — hibernate 11.52 ms at 1200 rps, 3.73×** — got none, in the arm the
  section characterises as rising. Unintentional, but attention distributed unevenly across one
  table reads as selection. All four excursions are now tabulated on one measure. The payoff:
  **three of them share the low-load signature** (≤ ⅓ of ceiling, p50 +~10 %, tail 1.7–3.7×,
  cpu/req flat or *lower*, threads unchanged), so the phenomenon is **not a property of either
  arm**; the fourth (hibernate 3000, 83 % of ceiling, p50 +75 %) is more economically read as
  capacity-approach and is **not** claimed as the same thing. Also recorded from the same leaves:
  idle RSS is higher in `ba` than `ab` at every hibernate rung — direct confirmation that ab and
  ba share one JVM lifetime, and a reason RSS must never be read off an ab–ba range.
- **2026-08-11 — §6b written, and "idle RSS" turned out not to be one number per arm.** The
  footprint sub-section was the last section-level gap. Loaded RSS across the ladder at an equal
  1280 MB committed heap spans **1.58×** (community 1057 → Tomcat 1662 on heavy), and **only
  `spring-hibernate` responds to the contract** (+31.8 % light→heavy against ≤ 2.7 % for the other
  three) — §5's ~200-row materialisation appearing in memory. The finding, though, is on the idle
  side: **whether a resident arm has ever served traffic changes its RSS by 1.9× to 5.5×**
  (community 194 → 1066 MB). That means **L8's single idle-RSS column averages two states**, and
  for `exeris-community` it reports 630 MB — exactly (194 + 1066)/2, a value the process is never
  at. Two riders keep the damage contained: **idle CPU is state-invariant** to three decimals, so
  everything L8 claims about idle *CPU* stands untouched; and post-service idle RSS ≈ loaded RSS
  within ~1 %, i.e. memory is touched and kept. Also recorded as a harness note:
  `spring-hibernate` has **no** first-touch reading because a never-served neighbour is observable
  only in the first window of `ab`, which samples `target-b`, and hibernate is `target-a` in both
  its pairs — alternating `target-a` across repeats would close that at no cost. Mirrored into
  CLAIMS L8. TL;DR's `[PENDING]` footprint bullet is written.
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
