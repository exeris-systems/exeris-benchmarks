---
title: "Valhalla optimises the heap. This runtime does not have one."
date: 2026-08-26 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
summary: "A 6-to-155 JEP 401 value-class sweep across an HTTP kernel whose entire memory model is Panama MemorySegment, measured on JDK 28 EA against its own immediately-preceding tag. Throughput, CPU per request and p99 do not move outside +/-2.4 %. Allocation per request falls 1.0 % over a full 900 s window, with a confidence interval that crosses zero; a first attempt read a rotated 2 % tail and overstated that threefold. What moves is the non-heap footprint, and it moves as a cost. Adapters lead it: +150, the difference between each arm's fullest observed state and one more than the +149 carriers measured from the two jars -- not an interval estimate at all, because the counts are bimodal and a mean of them is a value the JVM never produces, and not portable between campaigns: the same two arms read 828 and 972 under a different JFR configuration, so the figure has to be quoted with its campaign named. The recording configuration is the obvious explanation but is not established as the mechanism -- the direction is not uniform, and the 7-step survives in a campaign with no eu.exeris.* events at all. Metaspace adds +0.18 MB at an unchanged loaded-class count, this one in 6 of 6 pairs with an interval excluding zero. Code cache grows +1.15 MB on the same 6-of-6 evidence, but roughly half its new entries are compiled methods the release step's non-carrier changes could also produce, so that item carries weaker attribution. Around 1.3 MB of permanent cost against a transient 43 B/req allocation saving. Measured by type, byte arrays and Strings are 28 % of what the request path allocates and the converted carriers about 6 %. The mechanism was named on panama-dev in 2020 and explained in 2022; this report measures it."
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: entity-read-by-id
comparison_axis: within-tier
hardware_profile: perf-box-amd64
reproducibility_status: partial
---

# Valhalla optimises the heap. This runtime does not have one.

*A JEP 401 value-class sweep measured against its own previous tag, on a kernel whose entire
memory model is `MemorySegment`.*

> **What this is.** A single-variable, within-tier version comparison on the Exeris kernel's
> `preview` line: the same application, the same JDK build, the same fixed heap, differing in
> one release step that converted **6 carriers to 155**. It is not a Valhalla evaluation. It
> answers one question — *does declaring your carriers `value` pay, on a runtime that keeps its
> data off-heap?* — and the answer generalises only to that class of runtime.
>
> **Axis labels.** Tier **Community**. Protocol **H1 cleartext**. Family **Runtime**. Mode
> **pure** (native `@ExerisRoute` dispatch; persistence is JDBC + HikariCP, not the Enterprise
> native engine). Comparison axis: **kernel version within the preview line**. All 12 units of
> the campaign are `comparison_eligible`.
>
> **`reproducibility_status: partial`.** Sections 2–4 were re-derived from the raw artefacts by
> a pass that did not read a prior analysis. Section 3 was re-measured entirely on a second
> campaign after the first proved to be a rotated tail, and says so at the point of use. No third party has re-derived anything.

---

## TL;DR

1. **The sweep does not move the workload.** Across both legs, throughput, CPU per request, p99
   and RSS all sit inside ±2.4 %, and every RSS interval crosses zero. On the headline leg
   (distributed 0.11.0 → full-preview 0.11.1) *every* interval crosses zero.
2. **Allocation per request falls ~1.0 % (≈43 B)** over a full 900 s window. Direction is
   consistent with header elimination on the request-path carriers; the interval crosses zero.
   A first attempt on a rotated 2 % tail reported −2.8 % and was wrong by roughly threefold —
   which is itself the lesson. Treated as a signal, not a finding.
3. **The measurable, repeatable effect is a cost, not a saving.** The sweep adds **+150
   calling-convention adapters** (the difference between each arm's fullest observed state, one
   more than the +149 carriers measured from the two jars; 144 in the telemetry-silenced campaign,
   so the figure is campaign-specific and the two are not comparable — the recording configuration
   is the obvious candidate, but the direction is not uniform, E rising by 1 while F falls by 5,
   and the −7 step survives in a campaign with no `eu.exeris.*` events at all, so that this is the
   same mechanism the probe identified is **not shown**, §4.1) and **+0.18 MB Metaspace at an
   unchanged loaded-class count** — the one item here portable enough to quote on its own, 6 of 6
   with an interval excluding zero. Code cache grows **+1.15 MB** on the same 6-of-6 evidence, but
   ~147 of its +297 new entries are compiled methods that the
   release step's non-carrier changes could also produce, so that one item carries **weaker
   attribution** (§4.1). Total ≈1.3 MB of permanent non-heap footprint, bought with a transient
   43 B/req allocation saving.
4. **The reason is structural and was documented six years ago.** `MemorySegment` is a sealed
   interface with **9 concrete leaves**; on the exact JDK 28 build these arms ran,
   **265 classes in `java.lang.foreign` + `jdk.internal.foreign` and 0 of them are value
   classes**. Maurizio Cimadamore predicted this in 2020 and explained the mechanism in 2022.
5. **What would have to change** is not more `value` keywords — the kernel has none left to add
   — but representations that put primitives in *arrays*, plus the C2 monomorphisation
   Cimadamore names as missing.

---

## 1. Setup

**Campaign** `results/raw/kernel-version-axis/20260818T062534Z-light-valhalla-carriers`.
12/12 units `comparison_eligible`; strict gate passed on every pair.

| arm | id | kernel | line | JDK | value classes (shaded) |
|---|---|---|---|---|---|
| D″ | `exeris-k0110-j28p` | 0.11.0 | mainline | 28 EA, `--enable-preview` | 6 |
| E | `exeris-k0110pv-j28p` | 0.11.0 | preview | 28 EA, `--enable-preview` | 6 |
| F | `exeris-k0111pv-j28p` | 0.11.1 | preview | 28 EA, `--enable-preview` | **155** |

Two legs, each **n = 6** (3 runs × A/B and B/A counterbalanced):

- **E → F** — the carrier sweep proper. Same line, same JDK, one release step.
- **D″ → F** — distributed line to full preview. The headline the ladder exists to produce.

**Conditions.** `-Xms256m -Xmx256m` on both arms (RSS is meaningless without a matched fixed
heap). Server pinned `0-1,8-9`; load generator `2-3,10-11`; Postgres `4-7,12-15`
(`db_cpuset_source: docker-hostconfig`). Contract
`fixed_contract_cross_runtime_h1_single_read_v1`, warm 300 s / measure 900 s, wrk at saturation.
JDK build **28-ea+10-569** on all arms.

**Fences.** `db_cpuset` recorded and pinned. `backend_network_mode` is identical across arms
*within* this campaign, which is what the leg claims require; it is **not** comparable to the
July host-network triad, and no figure here is read against that family.

**What the sweep actually changed.** `preview/v0.11.0 → preview/v0.11.1` is not a pure modifier
delta — it also carries a `FileSink` change and `CommunityRotatingKeySet`. The leg is reported as
*"preview 0.11.0 → preview 0.11.1"*, never as *"value classes alone"*. Section 4 is the one place
where the confound is controllable, because the loaded-class count is flat while the metadata
grows.

---

## 2. The workload does not move

Re-derived from `result.json` per leaf. RSS is `rss_kb_avg` over the measurement window; CPU per
request is `cpu_time_seconds × 10⁶ / total_requests`. Paired t, `tcrit = 2.571` at n = 6.

### 2.1 E → F — the carrier sweep (6 → 155)

| metric | E | F | Δ | 95 % CI | signs |
|---|---|---|---|---|---|
| throughput | 78 808 rps | 77 851 rps | −1.21 % | [−2.34, −0.09] | −5 / +1 |
| CPU / request | 50.51 µs | 51.10 µs | +1.19 % | [+0.07, +2.31] | −1 / +5 |
| RSS (avg) | 368.53 MB | 372.78 MB | +1.17 % | [−3.43, +5.77] | −3 / +3 |
| p99 latency | 11 333 µs | 11 228 µs | −0.90 % | [−2.39, +0.59] | −4 / +2 |

### 2.2 D″ → F — distributed line to full preview (the headline)

| metric | D″ | F | Δ | 95 % CI | signs |
|---|---|---|---|---|---|
| throughput | 78 479 rps | 78 037 rps | −0.56 % | [−2.03, +0.91] | −3 / +3 |
| CPU / request | 50.71 µs | 50.99 µs | +0.56 % | [−0.93, +2.04] | −3 / +3 |
| RSS (avg) | 369.32 MB | 369.98 MB | +0.24 % | [−4.27, +4.75] | −3 / +3 |
| p99 latency | 11 200 µs | 11 390 µs | +1.71 % | [−0.73, +4.15] | −2 / +4 |

**On the headline leg every interval crosses zero.** That is the result: a 26-fold increase in
declared value carriers is invisible in throughput, service time, tail and resident footprint.

### 2.3 How much the two run-sets drift, measured from these same tables

Arm F appears in both legs, on different runs. Its own values therefore differ by nothing but
run-set — same artefact, same JDK, same pin, same heap:

| metric | F in leg E→F | F in leg D″→F | drift |
|---|---|---|---|
| throughput | 77 851 rps | 78 037 rps | 0.24 % |
| RSS | 372.78 MB | 369.98 MB | 0.75 % |
| **p99 latency** | 11 228 µs | 11 390 µs | **1.44 %** |

**The p99 drift between two run-sets of the same arm (1.44 %) is larger than the p99 delta either
leg reports** (−0.90 % and +1.71 %). This is internal evidence, from the two tables directly above,
that a difference of that size is within what run-set placement alone produces on this box — and it
is the strongest reason not to promote §2.1's two marginal exclusions.

**Why the two E → F intervals that exclude zero are not promoted.** Four metrics were tested on
the same six pairs; throughput clears zero by 0.09 pp and CPU/request by 0.07 pp, and on a
saturated server `cpu/req ≈ cores/rps` makes those two one fact, not two. A slot/neighbour effect
of 2.3–3.9 % is known on this box and is *systematic* — counterbalancing cancels it in the pooled
mean but does not shrink its variance contribution. One marginal exclusion out of four dependent
tests is not a finding, and the ladder's own coherence check agrees: D″→E measured **+0.70 %** in
an earlier campaign, which chained with E→F (−1.21 %) predicts **−0.52 %** for D″→F; the
directly measured value is **−0.56 %**, across two campaigns two days apart.

---

## 3. Allocation and GC

### 3.1 The first attempt measured a 2 % tail, and overstated the effect threefold

The 20260818 campaign's recordings retained **17–18 s of a 900 s window**. They rotated: the
kernel's own `eu.exeris.persistence.*` events are ~5–6 commits per request and filled 240 MB of
JFR's 250 MB default budget. Every allocation rate read off them was a tail sample.

A second campaign was run specifically to remove that limit —
`results/raw/kernel-version-axis/20260826T070108Z-light-alloc-untruncated`, **6/6 pairs
`comparison_eligible`**, same arms, same fixed heap, same core partition, same bridge DB fence.
Two instrument changes, applied identically to both arms:

| change | effect |
|---|---|
| `BENCH_JFR_EXTRA_SETTINGS=env/jfr-no-exeris-telemetry.jfc` | all `eu.exeris.*` event types at **zero** events — verified per recording |
| `BENCH_JFR_MAXSIZE=2g` | no rotation: 48 MB recordings, **spans 1200.0–1200.4 s** across all 12 |

**This is not poolable with 20260818.** Silencing the telemetry removes 5–6 event commits per
request of real CPU and allocation from both arms, so absolute allocation per request differs
between the two campaigns by construction. The E-vs-F *delta* is the deliverable.

**A harness defect had to be fixed first, and it is worth recording.**
`scripts/run-comparative.sh` carried a **second, duplicated implementation** of the JFR start with
`settings=profile` hard-coded, which never sourced `tools/bench/lib/jfr.sh`. A campaign exporting
both knobs got neither, silently. The first launch was discarded once `jfr-start.txt` still read
*"No limit specified, using maxsize=250MB as default"*; both call sites now honour the same two
variables.

### 3.2 What the full window shows

n = 6 pairs, paired t, `tcrit = 2.571`:

| metric | E | F | Δ | 95 % CI | signs |
|---|---|---|---|---|---|
| **allocation / request** | 4392.8 B | 4350.0 B | **−0.96 %** | [−2.39, +0.46] | −5 / +1 |
| allocation / second | 356.9 MB/s | 353.2 MB/s | −1.01 % | [−3.01, +0.99] | −5 / +1 |
| GC / second | 2.25 | 2.23 | −1.01 % | [−3.00, +0.98] | −5 / +1 |
| GC pause ms / second | 1.92 | 1.93 | +0.54 % | [−1.36, +2.44] | −4 / +2 |

**The tail overstated the effect by roughly three times.** It reported −2.76 % / ≈134 B per
request; the full window reports **−0.96 % / ≈43 B**, on a *tighter* interval that still crosses
zero. Both differences between the campaigns — window and telemetry — moved at once, so the
shrinkage cannot be attributed to either alone; the full-window figure is simply the better
estimate of the steady-state application delta, and it is the one this report now carries.

At 8-byte compact object headers (§3.4), 43 B/req is about **five objects' worth of headers per
request** — *fewer* than the number of carriers the H1 path constructs, which suggests most of
them were already being scalarised and never reached the heap at all.

### 3.3 Where the 4.4 kB per request actually goes

`jdk.ObjectAllocationSample` over the full window gives an allocation breakdown by type — 348 k
samples per recording instead of the 5 k the old tail held. Aggregated across all 6 recordings per
arm. Two independent estimators agree closely: the sampler totals **356 MB/s**, the
`GCHeapSummary` transitions **356.94 MB/s**.

| type | E share | F share | Δ pp |
|---|---|---|---|
| `[B` (byte arrays) | 16.95 % | 16.99 % | +0.04 |
| `java.lang.String` | 10.69 % | 10.92 % | +0.23 |
| `CommunityLoanedBuffer` | 5.78 % | 5.83 % | +0.05 |
| `Object[]` | 3.23 % | 3.28 % | +0.05 |
| pgjdbc (`PgResultSet` + `ExecuteRequest` + `PgPreparedStatement`) | 8.50 % | 8.60 % | +0.10 |
| Jackson (`UTF8JsonGenerator` + `JsonWriteContext` + `SerializationContextExt` + `IOContext`) | 7.34 % | 7.48 % | +0.14 |
| `InetSocketAddress` + its holder | 4.01 % | 4.05 % | +0.04 |
| `java.lang.Integer` | 1.97 % | 2.07 % | +0.11 |
| `jdk.internal.foreign.NativeMemorySegmentImpl` | 1.45 % | 1.47 % | +0.02 |

**`byte[]` plus `String` is 27.6–27.9 % of everything the request path allocates**, on both arms.
That is the `readAscii` pattern named in §6 — `new byte[len]` followed by `new String(...)`, three
objects per token, called three times for the request line and twice per header. The §6
recommendation is therefore measured, not derived from header arithmetic.

**The converted carriers are present but small.** Fifteen carrier types appear in the sample; the
ten largest sum to **5.96 % on E and 5.56 % on F**, a net shift of **−0.40 pp**:

| carrier | E | F |
|---|---|---|
| `ReadResult` | 1.118 % | 1.051 % |
| `CommunityHttpExchange` | 0.898 % | 0.929 % |
| `HttpRequest` | 0.739 % | 0.981 % |
| `Http1Codec$HeaderParseState` | 0.705 % | 0.733 % |
| `RequestPersistenceSession` | 0.546 % | 0.542 % |
| `HttpHeader` | 0.357 % | 0.554 % |
| `HttpResponse` | 0.539 % | 0.199 % |
| `HttpTypedResponse` | 0.398 % | 0.111 % |
| `Http1Codec$H2cDetectionContext` | 0.341 % | 0.370 % |
| `Http1RequestParser$RequestLine` | 0.321 % | 0.094 % |
| **sum of these ten** | **5.962 %** | **5.564 %** |

Individual carriers move in **both** directions — `HttpResponse`, `HttpTypedResponse` and
`RequestLine` fall by more than half while `HttpRequest` and `HttpHeader` rise — and the net is
the −0.40 pp shift above. `ObjectAllocationSample` is a sampling estimator and these shares sit
near 0.1–1 %, so **no individual carrier's delta is quoted as a finding here**; only the aggregate
direction is, and it agrees with §3.2.

**And this is the place to concede what the title compresses.** This runtime allocates 4.4 kB per
request, 356 MB/s, at 2.25 collections per second — it has a heap and it works it hard. What it
does not put there is the **payload**: request and response bytes live in `MemorySegment`s behind
`LoanedBuffer`. Everything in the table above is machinery around that payload — parser scratch,
driver objects, serializer state. The report's claim is about where the *data* lives, which is what
determines whether Valhalla has anything to flatten; it is not a claim that the heap is idle.

One row is worth naming for §5: `NativeMemorySegmentImpl` is itself ~1.5 % of allocation. The
Panama segment wrapper objects are allocated per request and are exactly the thing that cannot be
flattened. `java.lang.Integer` at ~2 % is a second reminder — it *is* a value class on JDK 28 and
still shows up, because a value that escapes into a reference context is still buffered.

### 3.4 Why 43 B/req is the right order of magnitude

`UseCompactObjectHeaders = true` by default on this build (measured, §5.3), so an object header is
**8 bytes**, not 12 or 16 — Valhalla's header saving on JDK 28 is partly pre-taken. A 43 B/req
reduction is ~5 headers.

The mechanism is real and correctly sized. It is also, at ~1 % of a 4.4 kB/req allocation budget,
**structurally incapable of moving RSS at a fixed 256 MB heap.**

---

## 4. The measurable effect is a cost

This is the section this report exists for. Read from `jdk.MetaspaceSummary` (last *After GC*
sample), `jdk.ClassLoadingStatistics` and `jdk.CodeCacheStatistics` per recording. Code-cache
usage is derived as `(reservedTopAddress − startAddress) − unallocatedCapacity`, summed across
heaps. Unlike §3, these are **gauges, not rates** — by the retained tail, class loading and
adapter generation are finished, so the tail sample is the correct instrument here.

### 4.1 E → F — same classes, more metadata

| metric | E | F | absolute Δ | Δ % | 95 % CI | signs |
|---|---|---|---|---|---|---|
| loaded classes | 4691.8 | 4692.7 | +0.8 | +0.018 % | [−0.048, +0.083] | −2 / +4 |
| **code cache used** | 16 961 kB | 18 111 kB | **+1149.6 kB** | +6.777 % | [+5.928, +7.627] | **−0 / +6** |
| code cache entries | 7413.0 | 7709.7 | +296.7 | +4.003 % | [+3.638, +4.368] | −0 / +6 |
| **Metaspace used** | 20 279 kB | 20 468 kB | **+188.9 kB** | +0.932 % | [+0.822, +1.041] | **−0 / +6** |
| Metaspace committed | 20 875 kB | 21 035 kB | +160.0 kB | +0.767 % | [+0.496, +1.038] | −0 / +6 |
| non-class metadata (`dataSpace`) | 16 367 kB | 16 560 kB | +192.4 kB | +1.176 % | [+1.047, +1.304] | −0 / +6 |
| compressed class space | 3911.6 kB | 3908.1 kB | **−3.5 kB** | −0.089 % | [−0.135, −0.043] | −6 / +0 |

Every cell above is an arithmetic mean over the six pairs — the right summary for kilobytes, and
the reason **adapters are deliberately absent from that table**.

Adapter counts are bimodal: each arm takes one of two values, 7 apart, so a mean lands between
them at a value the system never produces, and a confidence interval on such a mean bounds **how
often the anomaly occurred, not how many adapters there are** — a mixture proportion wearing the
notation of a magnitude. §7 states that the adapter result is not an inference at all; a row
carrying `±CI` beside the kilobyte rows would say the opposite while looking like the rest of the
table.

The honest shape is the observations themselves, over all 12 runs:

| arm | observed values | counts | modal value |
|---|---|---|---|
| D″ | 805, 812 | 2 × 805, 4 × 812 | **812** |
| E | 820, 827 | 1 × 820, 5 × 827 | **827** |
| F (leg E→F) | 977 | 6 × 977 | **977** |
| F (leg D″→F) | 970, 977 | 1 × 970, 5 × 977 | **977** |

**Deltas: E→F = 150, D″→F = 165.** No percentage, no interval — these are counts of a thing the
JVM either emits or does not.

Those are the **fullest observed states**, not modes chosen for being common. Once the mechanism is
known (below), the right comparison is between the runs where the conditionally-loaded classes were
all reached, and in all four arms that state happens also to be the modal one. "Fullest observed"
rather than "full" is deliberate: the probe below never reached D″'s 812 in six consecutive runs,
so a saturation ceiling is not something these data establish.

The modal arithmetic also closes on itself where the mean does not:

| | modal | mean |
|---|---|---|
| E→F delta | 977 − 827 = **150** | 151.2 |
| D″→F delta | 977 − 812 = **165** | 166.2 |
| difference of the two deltas | **15** | 15.0 |
| difference of the two arm values | 827 − 812 = **15** | 825.8 − 809.7 = 16.1 |

The last two rows must agree, and modally they do. The mean route reports the same quantity as
15.0 one way and 16.1 the other — noise where the data has structure.

What follows takes the two tables apart in turn: what the kilobyte figures show, what the adapter
figures show, what explains the adapter anomaly, and why the two cost items are not attributed
equally well.

**The class count does not change.** +0.8 classes with signs split −2/+4 is noise. The two arms
load the same classes; only what the JVM stores *about* them differs.

**Compressed class space shrinks slightly while non-class metadata grows.** `classSpace` holds
`Klass` structures and moves −3.5 kB (6/6 negative, interval excluding zero); `dataSpace` — which
holds everything else, including value-class layout information and calling-convention adapters —
grows +192.4 kB. That split is the signature of the effect, not a rounding artefact.

**The anomaly has a fixed size and no fixed home.** Nothing here is deterministic, F included:
it reads 977 six times on this leg and 970 once on the other, so "the adapter count is
deterministic" was only ever a statement about one leg. The low value appears four times in four
different arm/slot combinations — E at `run03/ab`, D″ at `run02/ab` *and* `run03/ba`, F at
`run03/ab` of the other leg — so it is not a slot effect either. What is fixed is the **step**: 7,
every time. It reads as one code path carrying seven adapter boundaries, reached or not,
independently of arm and position.

Code-cache **entries** do not track it: E's 820-adapter run has the *highest* entry count of E's
six (7458 against a 7413 mean) while D″'s two 805-adapter runs have its two lowest. So seven
missing adapters is not "seven fewer things compiled".

**Loaded-class *counts* explain nothing, and a set difference explains it exactly.** A dedicated
probe settled this: arm D″ booted with `-Xlog:class+load=info`, driven for 90 s, repeated. Adapter
counts came out 805 five times and 803 once, so two runs of one binary under one configuration
differed by 2 adapters — a clean, small case to diff.

Comparing the raw class-load sets of those two runs:

| | classes | only here | net |
|---|---|---|---|
| 805-run | 4966 | 932 | |
| 803-run | 4965 | 931 | **−1** |

**A net of −1 hides 932 absent and 931 extra.** The churn is overwhelmingly `java.lang.invoke`
(392 vs 390) — `LambdaForm` and hidden classes, whose names carry a per-JVM-run address and
therefore differ between *any* two runs of the same binary. Every class-count delta in this
report's tables is measuring that churn. It cannot support an inference, and the earlier reading
of −4.6 / −6.5 / −5.4 classes as a mechanism is **withdrawn**.

Excluding generated and hidden classes, the same two runs give a different picture entirely:

| | stable classes | only here |
|---|---|---|
| 805-run | 3990 | **2** |
| 803-run | 3988 | **0** |

Two classes absent, none extra, and they are a coherent cluster in one package:

```
eu.exeris.kernel.core.http.jfr.HttpAggregateBufferForcedReleaseEvent
eu.exeris.kernel.core.http.jfr.HttpAggregateBufferHeldEvent
```

**Two fewer adapters, exactly two fewer classes.** And the controls are exact: two independent
pairs of runs that *agree* on the adapter count have **byte-identical** stable class sets, 3990
each, zero difference in either direction. Equal adapter count implies equal class set; unequal
implies a difference of precisely the same size.

**This establishes "these two classes carry two adapters", not "one adapter per class."** The
distinction matters for the 7-step: seven adapters could equally be three classes contributing
three, two and two boundaries. Nothing here measures a per-class rate.

**And the unit is not the class at all.** `adaptorCount` — the JFR field, sitting beside
`entryCount` and `methodCount` in `jdk.CodeCacheStatistics` — counts adapter *blocks*, which
HotSpot's `AdapterHandlerLibrary` caches keyed on a method's basic-type signature fingerprint, not
on its declaring class. Any number of classes sharing a signature share one block. Measured
directly on the same JDK 28 build these arms ran (`28-ea+10-569`), three runs per condition,
identical every time:

| program | classes loaded and called | distinct signatures | adapters | Δ vs baseline |
|---|---|---|---|---|
| baseline | 0 | — | 375 | — |
| 60 classes, one shared signature `(int)int` | 60 | 1 | 376 | **+1** |
| 60 classes, arities 1–60 | 60 | 60 | 429 | **+54** |
| 60 classes, arities 81–140 | 60 | 60 | 436 | **+61** |

Sixty classes cost **one** adapter when their signatures agree. When the signatures differ and are
ones the JVM has certainly not already cached — arities far above anything reached during
bootstrap — the same sixty classes cost **+61**, essentially one apiece; the low-arity set's +54
is the same result with roughly seven of its signatures already resident, which is why the third
row is the cleaner measurement of the rate.

So a per-class rate is not merely unmeasured here; it is the wrong shape for the quantity. The two
JFR event classes above cost two adapters because they contributed two signatures the JVM had not
already cached, and the 7-step is seven such signatures, whatever number of classes carries them.

So the answer to "how many classes" was never available from a counter — it is **which** classes,
and here they are conditionally-loaded JFR *event* classes for the HTTP aggregate-buffer path,
which load only when a buffer is actually held or forcibly released. Part of the adapter count is
therefore instrumentation reaching a state, not application work.

**A confirmatory control on a second, independent dataset — and it carries a warning.** §3's
untruncated campaign silenced every `eu.exeris.*` JFR event type to zero, verified per recording.
If the mechanism is conditional class loading, its adapter counts should differ. They do:

| | 20260818 (telemetry on) | 20260826 (telemetry silenced) |
|---|---|---|
| E, fullest observed | 827 | **828** |
| F, fullest observed | 977 | **972** |
| delta | **150** | **144** |

Both saturation values moved, so **`adaptorCount` depends on the JFR configuration, not only on
the code**. The instrument entered the quantity it measures: the same recording that collects
`adaptorCount` contributes classes that the counter counts. **Adapter numbers are therefore not
comparable across the two campaigns**, exactly as §3.1 says of allocation, and the +150 headline is
specific to 20260818's configuration.

The direction is not uniform — F falls by 5 while E *rises* by 1 — so this is not "telemetry adds
adapters". What survives unchanged is the **step**: 828 → 821 and 972 → 965 are both −7, in a
campaign with no `eu.exeris.*` events at all. So the cluster behind the seven is **not** the JFR
event classes the probe identified; those account for a different 2.

Two limits remain. The probe is a different configuration again — one JVM, unpinned, 90–300 s — and
**never reached 812** at either duration, so the 7-step is not reproduced there. And it produced a
third value, 803, which is worth reading as a **promotion of the model rather than a retraction**:
"one of two values, always 7 apart" described twelve observations while sounding like a property of
the runtime, whereas "additive over the distinct signatures a conditionally-loaded cluster contributes" *is* a property of the
runtime, and it predicts a third value instead of being refuted by one.

The mechanism behind the adapters themselves is named, and that part is not a hypothesis: `InlineTypePassFieldsAsArgs = true` and
`InlineTypeReturnedAsFields = true` are both on by default on this build (§5.3), so every value
class gets a scalarised calling convention — and every *signature* that crosses between a
scalarised and a non-scalarised call site needs one of the blocks above. That is where a value
class becomes an adapter: not by existing, but by contributing a calling convention that has to be
translated between scalarised and buffered form at the boundary. **This is the same machinery that produces the 43 B/req
allocation saving, billed on the other side of the ledger.**

**The two cost items do not have equal attribution, and the flat class count does not cover both.**
That argument — same classes, different metadata — settles Metaspace: `Klass` structures are
per-class, the count is flat, so the +188.9 kB is metadata about unchanged classes.

It does **not** settle the code cache. Code cache gained **+296.7 entries**, of which adapters
explain ~150; the remaining ~147 are compiled methods. A method-body change in an already-loaded
class moves the code cache without moving the class count — and §1 states that this release step
also carries a `FileSink` change and `CommunityRotatingKeySet`. So the flat class count does not
rule out a confound on this line item. Ranked by attribution strength:

| item | size | attribution |
|---|---|---|
| **+150 adapters** | — | **strongest**: the difference between each arm's fullest observed state, named mechanism, one more than the +149 carriers measured from the two jars. Not a fixed count — within the campaign each arm sits at one of two states 7 apart, F included, and the probe found a third — and campaign-specific: the telemetry-silenced campaign gives 144 (§4.1) |
| +188.9 kB Metaspace | 0.18 MB | strong: flat class count settles it |
| +1149.6 kB code cache | 1.15 MB | **weaker**: 6/6 with an interval excluding zero, but ~147 of the +297 entries are compiled methods that the release step's non-carrier changes could also produce |

**The total.** ≈1.31 MB of permanent non-heap footprint, against 43 B/req of allocation that never
becomes resident memory at a fixed heap. The RSS point estimate on this leg moved +4.25 MB
(interval crossing zero), so ≈31 % of it is now attributed to a repeatable mechanism — but read
that total knowing its largest component carries the weakest attribution.

**When one number has to travel alone, quote the +0.18 MB of Metaspace at an unchanged
loaded-class count.** 6 of 6 pairs, CI [+0.822 %, +1.041 %], and the flat class count closes its
attribution — it is the one item here whose meaning does not depend on how the run was recorded,
and §7 promotes it for the same reason. Not the megabyte of code cache, whose attribution is the
weakest of the three. And *not the adapter count*, despite it being the best-attributed item
**inside** campaign 20260818: this section has just shown that the same two arms read 828 and 972
under a different JFR configuration, so +150 is the one figure in this table that cannot be
quoted without naming its campaign. Best-attributed and most portable are different properties,
and here they point at different rows.

### 4.2 D″ → F, for completeness

| metric | D″ | F | absolute Δ | Δ % | 95 % CI | signs |
|---|---|---|---|---|---|---|
| loaded classes | 4667.8 | 4692.5 | +24.7 | +0.528 % | [+0.445, +0.612] | −0 / +6 |
| code cache used | 17 030 kB | 18 181 kB | +1151.2 kB | +6.771 % | [+5.483, +8.060] | −0 / +6 |
| Metaspace used | 20 186 kB | 20 465 kB | +279.0 kB | +1.382 % | [+1.308, +1.456] | −0 / +6 |

This leg loads **25 more classes**, so its Metaspace delta is not attributable to the value
modifier alone — which is exactly why §4.1 is the section that carries the finding.

---

## 5. Why: the structure underneath

### 5.1 The carrier count, reconciled — and there is nothing left to convert

Three counts appear in this report and they measure three different things. **The leading number
is 155**: value classes in arm F's shaded runtime jar, counted from bytecode by the absence of
`ACC_IDENTITY`. That is what the JVM sees, and it is the number §4.1's adapter argument uses.

Source-side, over 699 main-source files at tag `preview/v0.11.1` (declarations, excluding the 59
javadoc mentions of `{@code value record}`):

| module | `value record` | `value class` | identity records | in arm F's jar |
|---|---|---|---|---|
| `exeris-kernel-spi` | 78 | 1 | **0** | yes |
| `exeris-kernel-core` | 40 | 1 | **1** (excused) | yes |
| `exeris-kernel-community` | 35 | 0 | **0** | yes |
| `exeris-kernel-community-kafka` | 3 | 0 | **0** | no — not on the app's path |
| `exeris-kernel-community-testkit` | 1 | 0 | **0** | no — test scope |
| **declared total** | **157** | **2** | **1** | |

**Both ends of the reconciliation are measured, not subtracted.** A bytecode walk over the two
shaded jars — counting classes that lack `ACC_IDENTITY`, excluding interfaces, which never carry
it — reports **6** kernel value classes in arm E's jar and **155** in arm F's, out of 13 514 class
files each. The 155 split as spi 79 / core 41 / community 35, matching the per-module source census
exactly, and **nothing from `kafka` or `testkit` appears**: those four carriers are precisely the
159 − 155 difference. So the sweep converted **149**, and that is the figure §4.1 compares against.

The one remaining number, §5.2's **156**, is those 157 records minus `ChoreographyDecision.Ignore`,
the single component-less record — §5.2 classifies carriers *by their components*, so a record with
none is not classifiable. Note also that a bytecode census counts *class files* (904 across the five
modules, nested classes included) while the table above counts *declarations* in 699 source files:
different populations, not a discrepancy.

**Three identity records remain in `src/main` repo-wide, and one of them is kernel runtime.**
`SubsystemTopologicalSorter$DependencyGraph` in `exeris-kernel-core` — excused in
`IDENTITY_BY_DESIGN` because its `Map` components are mutated in place by `runKahnBfs`;
`RequiresRoleProcessor$MethodDescriptor` in `exeris-kernel-build-config`, a build-time annotation
processor; and `AllocEvent` in `tools/jfr-reporter`, outside the reactor. So `IDENTITY_BY_DESIGN`
is empty in SPI, community, kafka and testkit, and carries exactly one entry in core.

That is a documented boundary rather than a gap, because `ValhallaValueCarrierRegistryTest` asserts
in **both** directions: every discovered record must be a value class unless excused by name, *and*
every excused record must still be an identity class — so the exclusion map cannot rot into stale
to-dos, and converting `DependencyGraph` without removing its entry would redden.

**And the reason it is excused is the same reason `LoanedBuffer` cannot be one.** `DependencyGraph`
holds a `Map` mutated in place; `LoanedBuffer` (§5.2) is an `AutoCloseable` with a hand-rolled
reference count. Two unrelated subsystems — bootstrap ordering and buffer lifetime — hit the same
wall from opposite directions: **mutable state requires identity**. One such case reads as an
exception; two independent ones read as a property of what the model can express.

**So the sweep is complete up to that documented boundary, and it bought what §2 and §4 measured.**

### 5.2 Classified by what Valhalla can actually do with them

The 156 classifiable `value record` declarations — 157 declared, less the one with no components
(§5.1) — break down as follows. This is a **different population** from the jar's 155, not an
off-by-one: it counts the 4 carriers `kafka` and `testkit` declare but this app never ships, and
excludes the 2 hand-written `value class`es, which the jar does contain.

| component shape | count | share | what flattening can do |
|---|---|---|---|
| all components primitive | **28** | 18 % | full flattening — **in an array or a field** |
| mixed | 71 | 46 % | partial; one header saved |
| **zero primitive components** | **57** | 37 % | one header saved; nothing to flatten |

Two structural facts close the question:

**There is not one array of a value carrier anywhere in `src/main`.** `HttpHeader[]`,
`EventDescriptor[]`, `HttpStatus[]`, `FlowKey[]`, `StreamId[]` — zero occurrences. Every
aggregate is a `List<T>`, i.e. an `Object[]` of boxes. Flattening needs an array or an embedded
field; generics erase to references, so `List<HttpHeader>` boxes every element no matter what
`HttpHeader` is declared to be.

But moving to an array is **not sufficient either**, and §5.4 measures why: a plain `HttpHeader[]`
does not flatten on this build. The container is a blocker; it is not the only one.

**The hot-path carriers are all-reference, and one of them cannot ever be a value class.**

```java
public value record HttpRequest(
        HttpMethod method, String path, HttpVersion version,
        List<HttpHeader> headers, LoanedBuffer body) { }
```

Five components, five references. And `LoanedBuffer` is an `AutoCloseable` with hand-rolled
reference counting (`retain()` / `close()`, a `VarHandle` over the count, a `volatile long size`)
— **identity-bound by design.** It is a component of both `HttpRequest` and `HttpResponse`.

The one carrier in the codebase built precisely for Valhalla — `EventDescriptor`, seven primitive
components, 44 bytes, whose primitive-only shape the kernel's own roadmap defends explicitly — is
in the **events** subsystem, which these arms never initialise.

### 5.3 What the JDK itself does, measured on the build that ran the arms

Probed on `/opt/jdk28` (28-ea+10-569), the same build as every arm:

| fact | measured |
|---|---|
| `MemorySegment` | sealed interface, permits `jdk.internal.foreign.AbstractMemorySegmentImpl` |
| concrete leaves | **9** — `HeapMemorySegmentImpl$Of{Byte,Char,Short,Int,Long,Float,Double}`, `NativeMemorySegmentImpl`, `MappedMemorySegmentImpl` |
| `java.base` classes scanned | 7502 |
| value classes in `java.base` | 31 — the `java.lang` boxes, `Number`, `Record`, `java.time.*`, `Optional*` |
| classes in `java.lang.foreign` + `jdk.internal.foreign` | 265 |
| **…of which value classes** | **0** |
| `isValue()` on all 9 segment leaves | `false` |

Relevant VM flags, all default on this build:

```
UseCompactObjectHeaders              = true
UseNullFreeAtomicValueFlattening     = true
UseNullFreeNonAtomicValueFlattening  = true
UseNullableAtomicValueFlattening     = true
UseNullableNonAtomicValueFlattening  = true
InlineTypePassFieldsAsArgs           = true
InlineTypeReturnedAsFields           = true
FlatArrayElementMaxOops              = 4
```

Flattening is not switched off. It has nothing here to flatten.

### 5.4 Where flattening actually happens, measured with `-XX:+PrintFieldLayout`

HotSpot prints all four candidate layouts per value class. Probed on the same JDK 28 build with
`-XX:+UnlockDiagnosticVMOptions -XX:+PrintFieldLayout -XX:+PrintFlatArrayLayout`, on synthetic
carriers shaped like the kernel's. **The blank cells do not all mean the same thing**, so they
carry two glyphs rather than one:

- **`✗`** — no valid layout of this kind: the payload plus any null marker exceeds what the kind
  can express. Every atomic kind needs to fit one atomically-writable word.
- **`opt-in`** — HotSpot emitted no layout of this kind because the carrier never asked for one.
  Non-atomic flattening is opt-in, and none of these carriers declares the opt-in. See below: this
  column carried `?` until 2026-08-27 and was the report's one open question.

| carrier | payload | NULL_FREE_NON_ATOMIC | NULL_FREE_ATOMIC | NULLABLE_ATOMIC | NULLABLE_NON_ATOMIC |
|---|---|---|---|---|---|
| `V4(int)` | 4 B | 4/4 | 4/4 | 8/8 | 5/4 |
| `V8(int,int)` | 8 B | **opt-in** | 8/8 | ✗ | 9/4 |
| `V12(int,long)` | 12 B | **opt-in** | ✗ | ✗ | 13/8 |
| `V16(long,long)` | 16 B | **opt-in** | ✗ | ✗ | 17/8 |
| `V32(4×long)` | 32 B | **opt-in** | ✗ | ✗ | 33/8 |
| `HttpHeader(String,String)` | 8 B | **opt-in** | 8/8 | ✗ | 9/4 |
| `EventDescriptor(4×long,2×int,long)` | 44 B | **opt-in** | ✗ | ✗ | 49/8 |

**Why the `NULL_FREE_NON_ATOMIC` column is empty — answered.** This was the report's one open
question. Put to `valhalla-dev` as a yes/no — *for a value class whose payload fits one word, is
the absence of a `NULL_FREE_NON_ATOMIC` field layout because no valid layout exists, or because
the atomic layout supersedes it?* — it turned out to be neither. Frederic Parain, Oracle,
**27 August 2026**, *"adaptorCount is coverage-dependent; and a PrintFieldLayout question"*:

> "Non-atomicity requires an explicit opt-in at the declaration site. The author of a value class
> must indicate that the class supports non-atomic accesses by annotating it with
> `@jdk.internal.vm.annotation.LooselyConsistentValue`. **Without this annotation, the JVM will
> not generate a `NULL_FREE_NON_ATOMIC` layout for the class.**"

None of the carriers above carries that annotation, so the column is empty because the layout was
never requested. Both readings this report had offered are retired: it is not "no valid layout
exists", and it is not supersession.

**The indirect array evidence is explained exactly, and it was not supersession either.** Asking
`ValueClass.newNullRestrictedNonAtomicArray` for an 8-byte two-`String` carrier returns an array
whose layout kind is `NULL_FREE_ATOMIC_FLAT` — which this report read as a non-atomic request
served by an atomic layout, and offered as making supersession plausible. It is specified
behaviour with two conditions, of which the probe met only the second:

> "A non-atomic array is created only when both of the following conditions are met: 1. The
> element class is declared `LooselyConsistent`. 2. The array factory explicitly requests a
> non-atomic array. **If the first condition is not met, the factory may still return an atomic
> array. This remains compliant with the requested semantics because it provides stronger
> guarantees.**"

**And `NULLABLE_NON_ATOMIC`'s missing size limit has a mechanism — a different one.** The report
recorded that this kind alone has no size ceiling (33/8 for a 32-byte payload) and could not say
why. It is not the opt-in above:

> "`NULLABLE_NON_ATOMIC` is a special layout used only for non-static strict final fields
> (JEP 539). Such fields have two distinct phases: during the early larval phase of their
> declaring class (before 'this' can escape) they may be written but not read. After this phase,
> they may be read but may no longer be written. Consequently, the write and read phases do not
> overlap (a memory barrier separates them to ensure consistent global vision of the value).
> **Because concurrent writes and concurrent read/write operations are impossible for these
> fields, atomicity is not an issue. They can therefore be flattened without hardware-imposed size
> limitations**, and C2 can generate code that accesses individual components of the flattened
> value without first reading the entire value."

That also supplies the mechanism behind the first of the three consequences below, which this
report could only state as an observed rule: a field flattens only inside a value class because
that is where strict-final fields, and therefore this layout kind, exist.

One further opt-in, not probed here: *"For fields, `@NullRestricted` also serves as an opt-in to
non-atomicity. If atomicity is required for a field, declaring it `volatile` opts out of
flattening and restores atomicity guarantees."*

**And the status of the whole mechanism, which is what §6 turns on:**

> "Just a reminder, non-atomicity is not part of JEP 401 and is not yet a supported feature, even
> if the Valhalla team is working on incorporating non-atomicity into the Java language."

All quotes verified verbatim against the archive
([thread](https://mail.openjdk.org/archives/list/valhalla-dev@openjdk.org/thread/XSZUWODG6HMFRFGOKGOUXADD6PC7FTSP/)).

**`NULLABLE_NON_ATOMIC_FLAT` has no size limit** — even a 32-byte payload gets a valid layout,
for the strict-final reason quoted above. Both *atomic* kinds stop at one word. Three consequences
follow, and all three were measured, not inferred:

**A field flattens only when the *enclosing* class is itself a value class.** A holder declared as
an ordinary identity class with six `final` value-typed fields laid out as six plain 4-byte
references — `REGULAR 4/4`, nothing flat. The same fields inside a `value class` holder laid out
as `FLAT … NULLABLE_NON_ATOMIC_FLAT`, including the two-`String` carrier. That is the practical
form of the "strict final fields only" rule: in current preview syntax, strict-final means *inside
a value class*.

**Arrays are bound by the 8-byte atomic rule, not by the unlimited one.** Of every carrier above,
exactly one produced a flat array — `V4`, as `NULLABLE_ATOMIC_FLAT`, element size 8. A plain
`HttpHeader[]`, `V16[]` or `EventDescriptor[]` is an ordinary reference array.

**Null restriction lifts arrays to the 8-byte payload limit, and no further.** Allocated through
`jdk.internal.value.ValueClass.newNullRestrictedNonAtomicArray`, the two-`String` carrier *does*
flatten — `NULL_FREE_ATOMIC_FLAT`, `NULL_RESTRICTED ATOMIC`, element size 8. The 16-byte carrier
still does not, in any array mode.

So `FlatArrayElementMaxOops = 4` is a necessary condition on flat array elements, not a sufficient
one: the binding constraint is total element size ≤ 8 bytes — **in the default case, which is the
one every carrier here is in: no `@LooselyConsistentValue` opt-in**. That bound is a consequence
of atomicity, so it is exactly the bound the opt-in is there to lift. What an opted-in carrier
actually gets is unmeasured (§7).

**The repeat this earns.** One probe answers it, and it is small: re-run
`-XX:+PrintFieldLayout -XX:+PrintFlatArrayLayout` over the same carriers annotated
`@jdk.internal.vm.annotation.LooselyConsistentValue` — `V16(long,long)` and
`HeaderSpan(int,int,int,int)` are the two that decide §6's recommendation — and allocate each
through `ValueClass.newNullRestrictedNonAtomicArray`, which under Fred's two conditions should now
meet both rather than one. Two questions it settles: whether the `NULL_FREE_NON_ATOMIC` column
populates at all, and whether a 16-byte element flattens in an array once atomicity is off. Note
before running it that the annotation is `jdk.internal.vm.annotation`, so the probe needs
`--add-exports`, and that a positive result would be a measurement of an unsupported feature — see
§6 for why that does not change the recommendation.

---

### 5.5 The mechanism was named in 2020 and explained in 2022

Maurizio Cimadamore, panama-dev, **17 July 2020**, *"rethinking the role of MemorySegment vs.
MemoryAddress"*:

> "While we can hope that Valhalla might be able, down the road, to reduce (or completely
> eliminate) the cost associated with allocation of new MemoryAddress instances, **it is far less
> obvious to predict whether we will be able to do the same for MemorySegment** (we certainly
> won't be able to do get any help for MemoryScope, which is mutable)."

Same author, **29 September 2022**, *"Unifying memory addresses and memory segments"*:

> "Lastly, I don't think there's anything preventing us from turning MemorySegment into value
> classes, on paper. The tricky thing of doing that move is to make sure that C2 can see 'what
> kind of segment are you dealing with' […] **C2 needs to know if the segment has an associated
> 'heap base'** (and, if yes, what's the type of the base object) or not. Otherwise you end up
> with the so called 'mixed access', where C2 wasn't able to prove that access was off-heap and
> extra barriers are inserted.
>
> **That is why, at the moment, we have different memory segment implementations, one per 'kind'.
> We have an abstract class, and many leaves.** […]
>
> But I think the biggest gains would come from having a truly monomorphic memory segment
> implementation, although **that requires some C2 optimizations … which we do not have yet**."

Both quotes verified verbatim against the archive. The "many leaves" are the nine this report
counted on JDK 28, four years later, still carrying `ACC_IDENTITY`.

**The contribution here is not the diagnosis. It is that nobody had measured what it costs.**

---

## 6. What would have to change

**Not more `value` keywords.** The kernel has none left to add, and §4 shows the marginal one is
net-negative on footprint.

1. **Stop materialising Strings, and keep the replacement carrier at 8 bytes or less.** The
   kernel's H1 parser materialises a `byte[]` and a `String` per token (`readAscii`), called
   three times for the request line and twice per header — data that is *already* in the receive
   `MemorySegment`. Replacing that with a span carrier removes the allocation outright, which is
   worth doing on its own merits.
   **But the obvious span shape does not flatten.** `value record HeaderSpan(int nameOff, int
   nameLen, int valOff, int valLen)` is 16 bytes, and §5.4 measures that a 16-byte carrier has no
   valid flat array layout in any mode — nullable or null-restricted. To flatten in an array the
   payload must fit in 8 bytes.

   **And the way out of that bound is not one this recommendation can take.** The 8-byte ceiling
   is a consequence of atomicity, which §5.4 now records is opt-out-able: annotate the carrier
   `@jdk.internal.vm.annotation.LooselyConsistentValue` and the JVM will consider non-atomic
   layouts, which carry no hardware size limit. A 16-byte `HeaderSpan` might well flatten that
   way. It would also be built on an internal annotation for a feature Parain states plainly is
   outside the preview — *"non-atomicity is not part of JEP 401 and is not yet a supported
   feature, even if the Valhalla team is working on incorporating non-atomicity into the Java
   language"* (§5.4). So the packed-`long` below is not a workaround for a limit that might lift;
   it is **the shape that works against what is actually shipped**, and it stays correct whether
   or not non-atomicity lands. That is the reason to prefer it, and it is worth stating outright
   because the fit was arrived at by measurement before the mechanism was known.

   **That is not a compromise here; it is sufficient — but the obvious packing is wrong.** The
   parser's limits are `DEFAULT_MAX_HEADER_SIZE = 8_192` and `DEFAULT_MAX_HEADERS = 100`, so a
   length never exceeds 8 192 while an offset can reach 819 200 — well past 16 bits. And the
   value's offset cannot simply be derived from the name's: RFC 9110 permits arbitrary optional
   whitespace after the colon, which the parser must accept, so `nameOff + nameLen + 2` holds only
   for exactly one space. Normalising at parse time does not rescue the derivation — skipping a
   variable number of spaces is precisely what makes the offset unrecoverable from the other
   fields.

   Both problems fit inside 64 bits by spending the length headroom instead:

   ```
   nameOff:32 | nameLen:14 | valLen:14 | ows:4     = 64 bits
   ```

   14 bits carries 0–16 383, twice the 8 192 limit; the 4 OWS bits carry 0–15 spaces, and a longer
   run — pathological, not seen in practice — takes a slow path or is rejected. A `HeaderSpan[]` of
   that shape flattens, addresses a 4 GB buffer, and covers every request this parser accepts.

   Notably `HttpHeader(String, String)` itself is exactly 8 bytes under compressed oops and *does*
   flatten — but only in a **null-restricted** array, which today is reachable only through the
   internal `jdk.internal.value.ValueClass` API and awaits the JEP in item 2. The packed-`long`
   span has no such dependency.
2. **Null-restricted value class types** — [JEP draft 8316779](https://openjdk.org/jeps/8316779),
   confirmed **Draft**, not in JDK 28. Without it a nullable value field needs a null channel,
   which is where the flat-layout size limits bite.
3. **C2 monomorphisation of `MemorySegment`** — the optimisation Cimadamore names as "which we do
   not have yet". Until it exists, a field of type `MemorySegment` is a reference regardless of
   what its nine implementations are declared to be.

Two adjacent surfaces are unused rather than blocked, and are worth naming because they are the
*other* half of the Valhalla × Panama pairing: `StructLayout` and `SequenceLayout` have **zero
occurrences** in the kernel (native structs are hand-offset — `NativeTcpSocketProbe` writes
`sockaddr_in` byte by byte against a literal `SOCKADDR_IN_SIZE = 16`), and `jdk.incubator.vector`
has **zero occurrences** against byte-at-a-time scan loops in `Http1RequestParser`, `Huffman` and
`HpackUtf8`. Neither is a footprint lever; both are correctness and CPU levers, and the second is
bounded by how few bytes per request are actually scanned.

---

## 7. What was measured, and what was not

**Measured.** Throughput, CPU/request, p99 and RSS on two legs, n = 6 each, all units
`comparison_eligible` (§2). Allocation, GC frequency, GC pause and allocation-by-type from JFR
over a full, unrotated 900 s window on a second campaign, 6/6 `comparison_eligible` (§3).
Metaspace, class count, code-cache usage and adapter count from JFR (§4). The kernel's carrier
census from the `preview/v0.11.1` tag (§5.1–5.2). `MemorySegment`'s sealing, its nine leaves, the
`java.base` value-class census and the VM flag state, on the same JDK build the arms ran (§5.3).
Field and array flat-layout behaviour under `-XX:+PrintFieldLayout` and
`-XX:+PrintFlatArrayLayout`, including null-restricted arrays allocated through
`jdk.internal.value.ValueClass` (§5.4). The two panama-dev quotes, verbatim against the
archive (§5.5).

**On multiplicity.** Sections 2–4 run on the order of twenty paired t-tests at α = 0.05, and this
report promotes a finding from exactly one: **§4.1's Metaspace growth**, +188.9 kB at an unchanged
loaded-class count, 6 of 6 pairs, CI [+0.822 %, +1.041 %]. §2.1's two marginal exclusions clear zero by
0.09 pp and 0.07 pp and would not survive the mildest correction, which is why §2.1 declines to
promote them and §2.3 shows the run-set drift that explains them.

§4's adapter result does not rest on an interval at all, and deliberately so: the counts are
bimodal, so a t-interval on their mean bounds a mixture proportion rather than a magnitude (§4.1).
What carries it is that **every one of campaign 20260818's twelve observations is one of two values
7 apart**, and that the arithmetic of the fullest observed states closes on itself. Being a count
rather than an inference, it is immune to multiplicity: there is no test here, so there is nothing
to correct.

Immunity to multiplicity is not generality, though, and the two must not be run together. §4.1's
cross-campaign control puts these same two arms at 828 and 972 under a different JFR configuration.
So what the twelve observations establish firmly is a property of **that campaign** — and the
runtime-level claim is the weaker, more portable one: that the count is additive over the distinct
signatures a conditionally-loaded cluster contributes — a unit §4.1 now measures rather than infers.

**Not measured, and therefore not claimed.**

- **Heap-resident workloads.** These arms say nothing about applications that keep their data on
  the Java heap. The finding is scoped to runtimes whose payload lives behind a `MemorySegment`.
- **The value modifier in isolation.** `preview/v0.11.0 → v0.11.1` carries two non-carrier
  changes. §4.1's flat class count makes the metadata attribution defensible; §2's throughput
  figures are attributed to the *release step*, not to `value`.
- **Whether the minimum viable heap changed.** RSS at a fixed `-Xms = -Xmx` is structurally blind
  to per-object shrinkage. The instrument that would see it — a minimum-heap sweep against the
  established 128 MB (light) / 256 MB (heavy) floors — has not been run.
- **The allocation delta on a second, independent campaign.** §3 rests on one campaign
  (20260826T070108Z). It is not poolable with 20260818 because silencing the kernel's own JFR
  telemetry to stop the rotation also removes 5-6 event commits per request from the workload.
- **Why `adaptorCount` differs between the two campaigns.** §4.1 establishes *that* it does — the
  same two arms read 827/977 and 828/972 — and the recording configuration is the obvious
  candidate, since the probe showed conditionally-loaded JFR event classes contributing adapters.
  But the direction is not uniform (E +1, F −5) and the 7-step survives in a campaign with no
  `eu.exeris.*` events at all, so the cluster behind the seven is demonstrably not the classes the
  probe found. That the cross-campaign difference is the *same* mechanism is not shown, and the
  report does not claim it.
- **Any individual carrier's allocation delta.** §3.3 shows carriers moving in both directions at
  0.1-1 % shares of a sampling estimator; only the aggregate direction is claimed.
- **Equal instrumentation coverage between the two arms.** The +150 adapter delta compares each
  arm's fullest observed state, which assumes both reached the same conditional-class loading
  state. That holds across the campaign's runs but is neither enforced nor gated, and §4.1's probe
  shows the fullest state can stay out of reach for six consecutive runs. A leg where one arm
  saturates and the other does not would produce a delta that looks like a carrier effect.
- **What a `@LooselyConsistentValue` carrier actually lays out.** §5.4's ≤ 8-byte array bound is
  measured on carriers in the default, atomic case — none of them declares the opt-in that turns
  non-atomic layouts on, and that opt-in is precisely what lifts the hardware size limit. Whether
  the `NULL_FREE_NON_ATOMIC` column populates, and whether a 16-byte element flattens in an array
  once atomicity is off, are unmeasured. §5.4 records the probe that would settle it. It would be
  a measurement of a feature that is not part of JEP 401 and not supported, which is why §6's
  recommendation does not wait on it.
- **Whether flattening changes anything when it *does* engage.** §5.4 establishes where the JVM
  will flatten; no arm in this campaign was built to exploit it, so the performance value of a
  flattened layout on this workload is unmeasured.
- **Anything about H2, H3, TLS, Enterprise or the locality tier.** Out of scope for these arms.

---

## Revision history

**Every entry below marked "review pass" happened *before* this report was published.** No version
carrying the figures they correct was ever distributed; the list records what was caught while the
document was still private, in the order each fix exposed the next. Read it as the audit trail of
a single pre-publication review, not as corrections to a circulated text. Entries marked **post-merge**
are the exception: they were made after the report landed on `main`, and are labelled as such.

Editor-facing notes for this report — the scope of its conclusion, which figures are not
promotable, and which single number is safe to quote on its own — live in
[`docs/REPORT-EDITORIAL-NOTES.md`](../../docs/REPORT-EDITORIAL-NOTES.md). Read them before
touching the summary or the TL;DR, and correct them in the same pass that corrects the body: one
of them went stale while the body moved on, and a stale note argues against the text it was
written to protect.

| date | change |
|---|---|
| 2026-08-27 | **Post-merge**, twelfth pass — **§5.4's open question is answered, by its author's reply on `valhalla-dev`**, and the answer promotes three separate observations from rule to mechanism. Frederic Parain (Oracle, HotSpot runtime), quoted verbatim against the [archive](https://mail.openjdk.org/archives/list/valhalla-dev@openjdk.org/thread/XSZUWODG6HMFRFGOKGOUXADD6PC7FTSP/): non-atomicity requires an explicit opt-in at the declaration site, `@jdk.internal.vm.annotation.LooselyConsistentValue`, and *"without this annotation, the JVM will not generate a `NULL_FREE_NON_ATOMIC` layout for the class."* So the empty column is a layout never requested — **neither of the two readings this report offered**, "no valid layout exists" and supersession, and both are retired. The `?` glyph, which meant "undecidable here" since the fifth pass, becomes `opt-in`. (1) The indirect array evidence is explained exactly and was also not supersession: a non-atomic array needs the element class declared `LooselyConsistent` **and** the factory to request one, and *"if the first condition is not met, the factory may still return an atomic array"* — the probe met only the second. (2) `NULLABLE_NON_ATOMIC`'s missing size ceiling, recorded with no mechanism, has a different one: it is the layout for non-static strict final fields (JEP 539), whose write and read phases cannot overlap, so *"atomicity is not an issue"* and they flatten *"without hardware-imposed size limitations"*. That also supplies the mechanism behind "a field flattens only inside a value class", which had been an observed rule. (3) §5.4's `≤ 8 bytes` array bound stays true but gains its scope — it is the **default, no-opt-in** case, and that bound is a consequence of the atomicity the opt-in exists to lift. §7 gains what an opted-in carrier lays out as an explicit "not measured", and §5.4 parks the probe that would settle it: the same carriers annotated, `V16(long,long)` and `HeaderSpan(int,int,int,int)` being the two that decide §6, plus null-restricted non-atomic arrays. **§6 gains rather than loses.** Its packed-`long` span was chosen by measurement before the mechanism was known; the 16-byte shape it rejected might flatten under the opt-in, but only on an internal annotation for something Parain states is *"not part of JEP 401 and is not yet a supported feature"*. So the recommendation is the portable one against what is shipped, and §6 now says so outright instead of arriving there by accident. Editorial only — no figure and no measurement changes. |
| 2026-08-27 | **Post-merge**, eleventh pass — **the editor notes leave the frontmatter**. Thirty-seven commented lines sat inside the YAML block, and a report's raw view is one click from any link to it, so they were published whether or not they rendered. Two of them were phrased as instructions about the summary — *"the summary must not say 'Valhalla does not work' or 'Valhalla failed'"* and, of the −1.21 % throughput result, *"the summary must not carry it as a finding … keep it that way"*. In context both mean "do not outrun the arms"; quoted alone, both read as message discipline rather than accuracy, and are usable against the work by anyone arguing that its tone is managed. They now live in [`docs/REPORT-EDITORIAL-NOTES.md`](../../docs/REPORT-EDITORIAL-NOTES.md), restated as what the evidence supports: the arms cannot support a claim about Valhalla in general, so the summary stays scoped to this class of runtime; and a 0.09 pp exclusion out of four tests on the same six pairs does not support promotion. Same constraint, phrased to survive being quoted. Size was the second reason — the block had grown an argument about `adaptorCount` with a probe path attached, which is a section, not a field annotation. The `reproducibility_status` note moved with them; its content is already stated in the rendered blockquote under the title, so nothing left the document that a reader could see. Linked from this history, because these notes earn their keep by being close enough to the body to argue with it, and one of them had gone stale while the body moved on. No figure and no body text changes. |
| 2026-08-27 | **Post-merge**, tenth pass — **the unit of `adaptorCount`, measured**, and three surfaces that disagreed with each other. §4.1 named the mechanism behind the adapters but never the unit of the counter, so its careful "not one adapter per class" rested on caution rather than on what the counter is. It now rests on a measurement: `adaptorCount` counts adapter *blocks*, which `AdapterHandlerLibrary` caches keyed on a method's basic-type signature fingerprint rather than on its declaring class. On the same JDK 28 build the arms ran (`28-ea+10-569`), 3 of 3 runs per condition and identical every time: **60 classes sharing one signature cost 1 adapter; 60 classes with 60 signatures the JVM had certainly not cached (arities 81–140) cost 61, essentially one apiece**. The probe is archived at `tools/probes/adapter-signature-unit/`. That is also where Valhalla's scalarised ↔ buffered translation materialises, which is why §5.3's two flags produce this cost at all. Consequences: (1) the **seventh entry's rule is retired, not narrowed** — it announced "one adapter per conditionally-loaded class" while the body already denied it, and a per-class rate is now shown to be the wrong shape for the quantity; the entry says so and points here. (2) The **"additive over conditional-loading clusters" model is sharpened to the distinct signatures such a cluster contributes**, in the frontmatter trap, §4.1 and §7. (3) §4.1 ended by telling a lone number to travel as the adapter count, two paragraphs after establishing that adapters are not comparable across campaigns — the one figure in that table that *cannot* travel alone. Both §4.1 and the frontmatter's third trap now send **+0.18 MB of Metaspace at an unchanged loaded-class count**: 6/6, interval excluding zero, attribution closed by the flat class count, and already the only finding §7 promotes. Best-attributed and most portable were pointing at different rows, and only one of them can be the number that travels. (4) TL;DR and the frontmatter `summary` both explained the cross-campaign 144 as "the recording configuration changes which classes load" — an explanation §4.1 partly disowns, since the −7 step survives with zero `eu.exeris.*` events and the direction is not uniform (E +1, F −5). Both now state the non-comparability as the finding and the mechanism as unshown, and §7 gains it as an explicit "not measured" bullet. |
| 2026-08-26 | **Post-merge**, editorial-scope only — no figure changes. Two surfaces the eighth pass left behind, both saying more about `adaptorCount` than §4.1 now allows. The frontmatter's own trap note still read "every arm takes one of exactly two values 7 apart" and "the claim that survives is a RATIO in 5 of 6 pairs"; the probe's third value (803) and the telemetry-silenced campaign's 828/972 had already retired both, and since that note is an instruction to the next editor, the stale version would have argued against the body. It now carries the two live bounds — the pair is a campaign condition, not a runtime property, and the figure is campaign-specific — and names the additive-over-clusters model as the part that is a runtime property. §7's multiplicity paragraph closed on "a stronger form of evidence than a p-value", which no longer fits a quantity the same report says depends on the recording configuration; the immunity-to-multiplicity argument is kept intact and unchanged, but the strength is now scoped to campaign 20260818, with the additive-over-clusters reading named as the weaker, portable claim. Without this, §7 and the eighth revision entry asserted different things about one number. |
| 2026-08-26 | Eighth pass — **confirmatory control across campaigns, and a comparability warning**. §3's telemetry-silenced campaign was queried for adapter counts as an independent test of the conditional-loading mechanism. Both saturation values moved: E 827→**828**, F 977→**972**, delta 150→**144**. So **`adaptorCount` depends on the JFR configuration, not only on the code** — the instrument entered the quantity it measures, and adapter numbers are not comparable across campaigns, exactly as §3.1 says of allocation. The direction is not uniform (F −5, E +1), so this is not "telemetry adds adapters"; what survives unchanged is the **step**, −7 in both arms of a campaign with no `eu.exeris.*` events, which means the cluster behind the seven is *not* the JFR event classes the probe identified. Three consequences recorded: adapter figures are now framed as each arm's **fullest observed state** rather than its mode (numerically identical, physically justified, and "observed" because the probe never reached D″'s 812 in six runs); the 1:1 reading is **narrowed** to "these two classes carry two adapters", since seven could be three classes contributing 3+2+2; and the third value 803 is recorded as a **promotion** of the model — "additive over conditional-loading clusters" is a runtime property that predicts a third value, where "one of two values 7 apart" merely described twelve observations. §7 gains **equal instrumentation coverage between arms** as an unmeasured assumption. |
| 2026-08-26 | Editorial pass over §4.1, which had accumulated six revisions and started contradicting itself. Its opening sentence ended in an edit fragment and pointed at an adapter row that no longer exists in that table; the adapter values were restated three times over; and the paragraph announcing "three things" was followed by eight. Counted announcements have now been replaced with an uncounted one, since that number had drifted three times. The frontmatter `summary` opened with "in 6 of 6 pairs with intervals that exclude zero" and then led with adapters, which are 5 of 6 and carry no interval — the two clauses are now attached to the items they actually describe. Minor: `~146` unified to **147** across four places (296.7 entries less 150 adapters); §7 now names the single promoted test (§4.1's Metaspace growth) rather than leaving it to inference; §5.2's lead sentence had lost its predicate to an earlier insertion; a triple em-dash in TL;DR item 3. **The revision history now states plainly that every "review pass" entry is pre-publication** — no version carrying the corrected figures was ever distributed, and without that line the list reads as corrections to a circulated text. |
| 2026-08-26 | Seventh pass — **the set difference, measured**. A dedicated probe (arm D″, `-Xlog:class+load=info`, 90 s, repeated) produced two runs of one binary differing by 2 adapters, and diffing their class-load sets settles the question the counters could not. Raw: **a net of −1 class hides 932 absent and 931 extra**, overwhelmingly `java.lang.invoke` `LambdaForm` and hidden classes whose names carry a per-run address — so every class-count delta in this report measures that churn, and the earlier −4.6 / −6.5 / −5.4 mechanism reading is **withdrawn**. Excluding generated classes, the same two runs differ by **exactly 2 classes, none extra**, and they are a coherent cluster: `HttpAggregateBufferForcedReleaseEvent` and `HttpAggregateBufferHeldEvent` in `eu.exeris.kernel.core.http.jfr`. Controls are exact — two independent pairs agreeing on the adapter count have **byte-identical** stable sets (3990, zero difference either way). The rule was read at this pass as **one adapter per conditionally-loaded class**, established at the 2-adapter scale, with the 7-step predicting seven such classes and remaining unobserved because the probe never reached 812 at any duration. **That reading did not survive**: the eighth pass narrowed it to "these two classes carry two adapters", and the tenth retired it by measuring the unit — adapter blocks are cached per *signature*, not per class, so a per-class rate was never the right shape for this counter (§4.1). The probe also produced a third value, 803, so "one of exactly two values 7 apart" is now scoped to the campaign's conditions rather than stated as a property of the runtime. |
| 2026-08-26 | Sixth review pass. **The adapter row is out of §4.1's and §4.2's mean-tables entirely.** §7 already stated the adapter result is not an inference, yet the row still carried a 95 % CI beside the kilobyte rows — the same over-claim as the retracted mean, harder to spot because it looked like the rest of the table. Adapters now get their own table: observed values, their counts across all 12 runs, and the modal deltas 150 and 165, with no percentage and no interval. **The class-count correlation is downgraded from mechanism to counter artefact**, on this report's own control: −4.6 / −6.5 / −5.4 are averages of integer counts, and a noisy continuous quantity cannot explain a step that is exactly 7 three times over — while F's class count spans 3 in leg E→F with the adapter count never moving, so a dose–response reading predicts ~4 adapters where zero are observed. It is not how many classes load but *which*, and a net −5 is equally consistent with "five absent" and "nine absent, four extra". That needs a **set difference, not a delta** — the same move §5.1 required — and it is unavailable here: `jdk.ClassLoad` and `jdk.ClassDefine` carry zero events in every recording. Recorded as a `-Xlog:class+load=info` follow-up, with the sampling cost noted (the anomaly appears in 1 of 6 runs). |
| 2026-08-26 | Fifth review pass, two structural corrections. **Every adapter figure is now the mode, not the mean.** The counts are bimodal with a quantum of 7 — E {820,**827**}, D″ {805,**812**}, F {970,**977**} — so the reported means (825.8, 809.7, 975.8) were values the system never produces, and a t-interval on such a mean bounds a **mixture proportion, not a magnitude**: `[+17.874, +18.738] %` says how often the anomaly occurred. §7's multiplicity paragraph no longer leans on that interval; the adapter result rests on all twelve observations being one of two values, which is not a test and so is immune to multiplicity. The modal arithmetic also closes on itself where the mean does not: modal deltas 150 and 165 differ by 15, exactly the difference of the arm modes, while the mean route gives 15.0 one way and 16.1 the other. **New measurement:** loaded-class count tracks the anomaly in every column that has one (−4.6, −6.5, −5.4 classes for −7 adapters) while F's constant 977 spans a 3-class range — so seven adapters travel with five to six classes, not one, and not with class-count noise. §5.4's caption contradicted its own footnote about what `−` meant; the blank cells are now split into `✗` (no valid layout — size) and `?` (not emitted, undecidable here), with the whole `NULL_FREE_NON_ATOMIC` column marked `?` because the supporting probe measures **array allocation, a different path from field-layout emission**. Restated as a yes/no question for `valhalla-dev`. **Asked, and answered on 2026-08-27** — the answer was neither of the two readings, and the `?` cells are now `opt-in`; see the twelfth entry. |
| 2026-08-26 | Fourth review pass. §5.1 **corrected on a matter of fact**: it claimed two identity records in `src/main` and none in kernel runtime. There are **three**, and `SubsystemTopologicalSorter$DependencyGraph` (`exeris-kernel-core`) is kernel runtime — excused in `IDENTITY_BY_DESIGN` because its `Map` is mutated in place, so that map is empty in four modules and holds one entry in core. The section now also states the mutability→identity property directly: `DependencyGraph` and `LoanedBuffer` are unrelated subsystems refused for the same reason. Both ends of the 159/155 reconciliation are now **measured** — a bytecode walk over the two shaded jars reports 6 value classes in arm E and 155 in arm F, with nothing from `kafka`/`testkit`, so 149 is measured rather than subtracted. §4.1's "the adapter count is deterministic" is **withdrawn**: every arm takes one of two values exactly 7 apart (E {820,827}, D″ {805,812}, F {970,977}), the low value appears in four different arm/slot combinations, and code-cache entries do not track it — E's 820-adapter run has its *highest* entry count. What survives is a modal ratio in 5 of 6 pairs. §4.2's own numbers are promoted to a point: D″ and E carry 6 value classes each yet differ by ~15 adapters, so `adaptorCount` is not a function of carrier count. |
| 2026-08-26 | Third review pass, adapter arithmetic. The headline adapter delta was quoted as **+151.2 — a mean of `[150,150,150,150,157,150]` that matches no observation**; it is now **150**, the modal and median per-pair value, and the excess over the 149 converted carriers is **one, not two**. The variance was also mis-attributed: F is stable at 977 across this leg, and the outlier is a *baseline* run generating 7 fewer adapters. §4.1 now says F's count is stable while the delta is not, and records the lazy-adapter-materialisation reading as an explicit hypothesis rather than a finding — with the D″→F leg's own F=970 outlier noted as consistent with it. Corrected in §4.1 body, the attribution table, TL;DR and the frontmatter `summary`; the frontmatter trap note now scopes "977 in all six" to the E→F leg. |
| 2026-08-26 | Second review pass. §4.1's attribution ranking **propagated to the two surfaces that had not carried it** — the frontmatter `summary` and TL;DR still said "at an unchanged loaded-class count" over all three cost items, which is the claim §4.1 had already withdrawn for the code cache; both now lead with the adapter count. §6's packing **corrected**: deriving the value offset from the name's is invalid because RFC 9110 permits arbitrary optional whitespace after the colon, and 16-bit offsets cannot reach the parser's 819 200-byte worst case either — replaced with `nameOff:32 \| nameLen:14 \| valLen:14 \| ows:4`, which spends length headroom (2× rather than 8×) to buy an explicit OWS field. §5.2 now says why its 156 is a different population from the jar's 155 rather than an off-by-one. |
| 2026-08-26 | Review pass. Carrier counts reconciled in a new §5.1 — 159 declared in source, 4 not shipped in this app, **155 in arm F's jar**, which is now the stated leading number; the earlier per-module table (72/35/19) came from a grep that dropped `/* default */`-prefixed declarations. §4.1 now **ranks its two cost items by attribution strength**: the flat class count settles Metaspace but does not cover the code cache, ~147 of whose +297 entries are compiled methods the release step's non-carrier changes could also produce. §2.3 added: arm F's own values differ between the two legs by 1.44 % on p99 — more than either leg's p99 delta — which is internal evidence for §2.1's refusal. §3.3's carrier table was missing its tenth row. §5.4 gained a note on what `−` means. §6 finishes the packing arithmetic: `nameOff:32 \| nameLen:16 \| valLen:16` is exactly 64 bits and covers the parser's own 8 192-byte limit with 8× margin. §7 gained a multiplicity paragraph. |
| 2026-08-26 | §3 **re-measured and replaced**. The original allocation table came from recordings that had rotated to a 17-18 s tail of a 900 s window; it reported −2.76 % / ≈134 B per request. A second campaign (`20260826T070108Z-light-alloc-untruncated`, 6/6 `comparison_eligible`) with the kernel's own JFR telemetry silenced and `maxsize=2g` retained the full 1200 s and reports **−0.96 % / ≈43 B**. The tail overstated the effect threefold. §3.3 (allocation by type) is new and makes §6's `readAscii` claim measured rather than derived. Finding the defect that blocked the first attempt — a duplicated JFR start in `run-comparative.sh` that ignored `tools/bench/lib/jfr.sh`'s knobs — cost one discarded campaign launch. |
| 2026-08-26 | §5.4 added: flat-layout behaviour measured directly with `-XX:+PrintFieldLayout` / `-XX:+PrintFlatArrayLayout`. It **corrected two claims** in the first draft (§5.2, §6): `FlatArrayElementMaxOops = 4` is necessary but not sufficient, a plain `HttpHeader[]` does **not** flatten, and the proposed 16-byte `HeaderSpan` has no valid flat array layout in any mode. The binding constraint for arrays is total element size ≤ 8 bytes. |
| 2026-08-26 | First publication. Campaign `20260818T062534Z-light-valhalla-carriers` (12/12 `comparison_eligible`). §4 (non-heap cost) and §5.3 (JDK-level census) are new measurements taken for this report, not re-analysis of the campaign's headline metrics. |

**Updated:** 2026-08-27
*By Arkadiusz Przychocki (updated 2026-08-27)*
