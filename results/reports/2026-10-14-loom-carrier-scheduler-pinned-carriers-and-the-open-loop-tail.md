---
title: "Pinned carriers hold the open-loop tail near capacity, and only there"
date: 2026-10-14 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
  - loom
summary: "A custom java.lang.Thread.VirtualThreadScheduler from the Loom fibers EA build (per-carrier MPSC queue, no work stealing), measured against the stock ForkJoinPool scheduler on the Exeris Community transport, open loop with wrk2, 10 fresh JVMs per cell, on a cpuset-shielded 6-core desktop. With each of its two carriers pinned to its own CPU (arm D), the p99 at 85 % of the stock scheduler's saturation rate separates completely from both floating arms in both regimes measured: 2.58 ms against 11.89 and 10.79 ms with a 1 ms backend, 52.6 ms against 181 and 240 ms with a 30 ms backend, exact Mann-Whitney p <= 2.2e-5 in each pair. At 90 % in the CPU-bound regime the same holds (2.58 against 21.4 and 13.5 ms). At 50 % no arm separates from another in either regime. At 70 % with the 30 ms backend the pinned arm is the worst of the three, bimodal across JVMs (median 96 ms, four trials 39-62 ms and six 94-129 ms), and that is not explained. Floating carriers spend 1-10 % of the window waiting for a CPU near capacity and pinned carriers none, which fits the pilot's stacking explanation without establishing it: no perf sched trace was taken. The custom scheduler costs no CPU: CPUs utilised at 50 % are equal or lower for D. Unpinned, the custom scheduler (C_iso) is no better than the stock one, and is the only arm that failed to sustain a target rate twice across both campaigns. Cache locality was not tested."
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: loom-carrier-scheduler
claim_scope: comparison_eligible
comparison_axis: within-tier
hardware_profile: dev-isolated
reproducibility_status: partial
---

# Pinned carriers hold the open-loop tail near capacity, and only there

*A custom Loom `VirtualThreadScheduler` against the stock `ForkJoinPool` scheduler, on a transport
whose readiness detection and continuation execution run on different threads.*

> **What this is.** A within-tier comparison of three virtual-thread scheduler arms on one kernel
> build, one JDK build and one host. It answers one question — *does a scheduler that keeps one
> queue per carrier, with each carrier pinned to its own CPU, bound the open-loop tail?* — for two
> backend latencies. It is the first result of the research track `research/loom-carrier-scheduler`
> (kernel `docs/research/loom-carrier-scheduler/research.md`) and replaces nothing: the
> 2026-09-27 pilot (`results/history/loom-carrier-scheduler-pilot-2026-09/`) is archived as
> non-evidence and no figure here is read against it.
>
> **Axis labels.** Tier **Community** (FFM POSIX socket transport, platform `Selector` reactors).
> Protocol **H1 cleartext**, as the load vehicle only: `wrk2` paces HTTP/1.1, and scheduling sits
> below the protocol, which is not a factor here. Family **Runtime**. Comparison axis: **scheduler
> arm, within one kernel commit**. Not a cross-runtime comparison and not a statement about the
> Enterprise `io_uring` transport.
>
> **`claim_scope: comparison_eligible`** is carried by exactly two campaigns, both under
> `results/raw/loom-carrier-scheduler/`: `20261009T040618Z-jdk-kbc26f9a0e8fc` (CPU-bound, 129 of 129
> trials valid) and `20261013T191957Z-jdk-kbc26f9a0e8fc` (I/O-bound, 99 of 99 valid). Every trial in
> both ran on a shielded host from committed harness files. §7 is exploratory and labelled at the
> point of use; no comparative claim rests on it.
>
> **`reproducibility_status: partial`.** Every figure was re-derived from the campaigns'
> `trial.json` and `load.txt` by a pass separate from the harness's own summary, and the two agree.
> Each regime rests on one campaign; neither has been repeated, and no second person has
> re-derived anything.

---

## TL;DR

1. **Near capacity, pinning separates completely.** At 85 % of the stock scheduler's saturation rate
   the pinned custom scheduler (`D`) has a lower p99 than both floating arms in every one of its
   10 trials, in both regimes: **2.58 ms** against 11.89 (`A_iso`) and 10.79 ms (`C_iso`) with a
   1 ms backend, **52.6 ms** against 181 and 240 ms with a 30 ms backend. Exact Mann–Whitney
   p ≤ 2.2 × 10⁻⁵ for each pair, which survives a Bonferroni correction over all 42 tests in this
   report. At 90 % (CPU-bound only) the same: 2.58 ms against 21.4 and 13.5 ms.
2. **Below capacity, it does not.** At 50 % no arm separates from another in either regime: p99
   medians within 0.05 ms of each other with a 1 ms backend, within ~4 ms with a 30 ms backend.
3. **At 70 % with the 30 ms backend, the pinned arm is the worst.** Median p99 96 ms against 66
   (`A_iso`) and 53 ms (`C_iso`), bimodal across JVMs — four trials at 39–62 ms, six at
   94–129 ms — with both carriers at ~58 % CPU and no run-queue wait. **Not explained** (§5.3). It
   is the reason the hypothesis's "at every rate" does not hold.
4. **The mechanism is consistent with carrier stacking, not established as it.** Floating carriers
   wait 1–10 % of the window for a CPU near capacity; pinned carriers wait 0.0–0.2 %. Within a
   cell, that wait tracks the p99 in some cells (Spearman ρ up to 0.88) and not in others
   (ρ = −0.22 in the worst one). No `perf sched` trace was taken, which the hypothesis names as its
   test.
5. **The custom scheduler costs no CPU.** At 50 %, CPUs utilised are 1.21 (`D`) against 1.22
   (`A_iso`) with a 1 ms backend and 1.25 against 1.32 with a 30 ms backend. The pilot's
   ~70 % CPU premium does not reproduce.
6. **Unpinned, the custom scheduler buys nothing.** `C_iso` matches or trails `A_iso` at every rate
   where they differ, and accounts for two of the three trials in both campaigns that did not
   sustain their target rate.
7. **Not tested:** cache locality (HYP-CACHE), the `kernel` backend (virtual threads woken by the
   transport's reactors rather than the JDK poller), and any rate above 85 % with a 30 ms backend.

---

## 1. Setup

### 1.1 Request path and arms

`wrk2` → server (`targets/exeris-loom-scheduler-app`, `/backend`) → the handler's virtual thread
makes one blocking request to a mock backend on its own CPUs → response. The backend client is
`java.net.Socket` on pooled keep-alive connections (`--backend jdk`), so a handler waiting for the
backend parks through the JDK poller (`sun.nio.ch.Poller`, `-Djdk.pollerMode=3` in every arm). The
transport's own reactors detect readiness on the client connections and wake handler virtual
threads with `LockSupport.unpark`.

All arms run two carriers.

| arm | scheduler | carrier placement |
|:--|:--|:--|
| `A_iso` | stock `ForkJoinPool` (`parallelism = maxPoolSize = 2`) | both workers allowed on CPUs 2, 3 |
| `C_iso` | `ExerisCarrierScheduler`: one MPSC queue per carrier, no work stealing | both carriers allowed on CPUs 2, 3 |
| `D` | `ExerisCarrierScheduler` | carrier 0 on CPU 2, carrier 1 on CPU 3 (`sched_setaffinity`) |

`A_iso` against `C_iso` isolates the scheduler design; `C_iso` against `D` isolates pinning.

### 1.2 Host and CPU layout

AMD Ryzen 5 5600 (Zen 3, 6 cores / 12 threads, one CCX, 32 MiB L3), Linux `7.0.0-38-generic`,
`performance` governor on all CPUs, boost off. Profile `dev-isolated`: no graphical session,
everything outside the benchmark confined by a cgroup cpuset (`host-shield.sh`: `system.slice`,
`user.slice` and `init.scope` on CPUs 0, 6; movable IRQs moved there), the benchmark in its own
slice. Not `isolcpus`, which would also stop the kernel balancing the floating arms' carriers —
the behaviour those arms measure.

| role | CPUs | physical core |
|:--|:--|:--|
| server auxiliary threads (GC, JIT, VM), transport reactors, JDK poller threads | 0, 6 | 0 |
| mock backend JVM | 1, 7 | 1 |
| carriers | 2, 3 (SMT siblings 8, 9 idle) | 2, 3 |
| load generator (`wrk` / `wrk2`, 4 threads) | 4, 5, 10, 11 | 4, 5 |

JDK `28-testing-builds.shipilev.net-openjdk-jdk-loom-b18-20260917-2133` (Loom `fibers` EA) for
server and mock, `-Xms1g -Xmx1g -XX:+UseParallelGC`. Kernel commit
`bc26f9a0e8fc56bf922aa7515b8f29cc2aac869d` (`research/loom-carrier-scheduler`, cut from `main`),
built by the harness from `git archive` of that commit; class files major 72. `wrk2` at
giltene `44a94c1`.

### 1.3 Regimes and campaigns

| | CPU-bound | I/O-bound |
|:--|--:|--:|
| campaign | `20261009T040618Z-jdk-kbc26f9a0e8fc` | `20261013T191957Z-jdk-kbc26f9a0e8fc` |
| harness commit | `84685a1c` | `e33e9595` |
| backend think time | 1 ms | 30 ms |
| connections (`wrk2`, 4 threads) | 100 | 5,000 |
| backend pool | 128 | 2,048 |
| warmup (open loop, at the trial's rate) / measurement | 30 s / 30 s | 30 s / 60 s |
| ladder base: `A_iso` median saturation, n = 3 | 75,998 req/s | 61,887 req/s |
| rates (fraction of base) | 38,000 / 53,200 / 64,600 / 68,400 (50 / 70 / 85 / 90 %) | 30,900 / 43,300 / 52,600 (50 / 70 / 85 %) |
| trials per (arm, rate) | 10 | 10 |
| trials | 129, all valid | 99, all valid |

One fresh server JVM and one fresh mock JVM per trial; arm order randomised per repetition from a
recorded seed. Saturation is closed-loop `wrk` and sets the ladder only (§6).

### 1.4 What makes a trial count

A trial is **valid** when every measurement gate holds:

- **transport** — the server reports `active=posix-hybrid, ffmArmed=true`: socket I/O went through
  the FFM path, not the NIO fallback;
- **errors** — no socket error, no non-2xx;
- **isolation** — at the end of the window, two carriers; floating arms allowed exactly CPUs 2, 3;
  `D`'s carriers on one CPU each; no other server thread allowed on a carrier CPU;
- **unperturbed** — no profiler or tracer attached.

**Sustained** is an outcome, not a gate: `wrk2` achieved ≥ 99 % of the rate it reports for a server
that keeps up, `rate × (1 − ramp / (2 × duration))` with `ramp = 5 ms × connections / threads`. A
valid trial that did not sustain its rate is a result about its arm: it is counted per cell and kept
out of the percentiles, which therefore describe runs that kept up. Every percentile is `wrk2`'s,
coordinated-omission corrected, with the histogram reset after the calibration period.

---

## 2. CPU-bound regime: 1 ms backend, 100 connections

p99 and p99.9 in ms, medians over the sustained trials with the trial range; CPUs is `perf stat`'s
CPUs utilised by the server process.

| rate | arm | sustained | p50 | p99 median [range] | p99.9 | CPUs | carrier wait (max of 2, median) |
|:--|:--|--:|--:|:--|--:|--:|--:|
| 50 % | `A_iso` | 10 / 10 | 1.91 | 2.63 [2.58–2.66] | 2.94 | 1.22 | 0.0 % |
| | `C_iso` | 10 / 10 | 1.92 | 2.68 [2.64–2.69] | 2.99 | 1.20 | 0.1 % |
| | `D` | 10 / 10 | 1.91 | 2.67 [2.64–2.68] | 2.92 | 1.21 | 0.0 % |
| 70 % | `A_iso` | 10 / 10 | 1.78 | 2.46 [2.45–11.35] | 3.35 | 1.72 | 0.1 % |
| | `C_iso` | 10 / 10 | 1.79 | 2.54 [2.50–2.68] | 3.69 | 1.68 | 0.85 % |
| | `D` | 10 / 10 | 1.78 | 2.47 [2.43–2.55] | 2.84 | 1.68 | 0.0 % |
| 85 % | `A_iso` | 10 / 10 | 1.77 | 11.89 [9.57–28.58] | 18.11 | 1.97 | 1.95 % |
| | `C_iso` | **9 / 10** | 1.80 | 10.79 [6.20–77.12] | 16.17 | 1.98 | 2.8 % |
| | `D` | 10 / 10 | 1.73 | **2.58 [2.55–2.83]** | **3.46** | 1.99 | 0.0 % |
| 90 % | `A_iso` | **9 / 10** | 1.78 | 21.39 [10.15–61.82] | 32.69 | 2.06 | 2.2 % |
| | `C_iso` | 10 / 10 | 1.82 | 13.46 [8.31–38.21] | 18.19 | 2.08 | 3.7 % |
| | `D` | 10 / 10 | 1.70 | **2.58 [2.53–8.66]** | **3.06** | 2.11 | 0.0 % |

The two unsustained trials: `A_iso` at 90 % reached 87.0 % of the expected rate (59,379 of
68,258 req/s); `C_iso` at 85 % reached 98.8 % (63,700 of 64,465).

**Tests.** Exact two-sided Mann–Whitney U on the per-trial p99, n = 10 against 10 (9 where a cell
lost an unsustained trial).

| rate | `D` vs `A_iso` | `D` vs `C_iso` | `C_iso` vs `A_iso` |
|:--|:--|:--|:--|
| 50 % | p = 0.0029, `D` +0.04 ms | p = 0.39 | p = 0.0021, `C_iso` +0.05 ms |
| 70 % | p = 0.74 | p = 2.1 × 10⁻⁴, `D` −0.07 ms | p = 0.0029, `C_iso` +0.08 ms |
| 85 % | **p = 1.1 × 10⁻⁵**, no overlap | **p = 2.2 × 10⁻⁵**, no overlap | p = 0.66 |
| 90 % | **p = 2.2 × 10⁻⁵** | **p = 2.2 × 10⁻⁵** | p = 0.18 |

At 85 % the separation is complete: `D`'s worst trial (2.83 ms) is below the best trial of either
floating arm (6.20 ms). At 90 % one `D` trial reached 8.66 ms, inside the floating arms' range,
and the rest sit at 2.53–3.35 ms.

At 50 % and 70 % the significant differences are 0.04–0.08 ms on a 2.5 ms p99, 2–3 %. They are
real in the sense that ten fresh JVMs order the same way, and too small to matter to this
question; only the 70 % `D` vs `C_iso` one survives the correction in §4.

---

## 3. I/O-bound regime: 30 ms backend, 5,000 connections

The backend's 30 ms sets a p50 floor of ~32 ms, so the tail above it is the scheduling
contribution.

| rate | arm | sustained | p50 | p99 median [range] | p99.9 | CPUs | carrier wait (max of 2, median) |
|:--|:--|--:|--:|:--|--:|--:|--:|
| 50 % | `A_iso` | 10 / 10 | 31.78 | 41.23 [33.85–51.58] | 61.16 | 1.32 | 0.1 % |
| | `C_iso` | 10 / 10 | 31.78 | 43.57 [37.95–51.97] | 72.12 | 1.26 | 0.1 % |
| | `D` | 10 / 10 | 31.73 | 39.49 [35.29–50.33] | 64.51 | 1.25 | 0.0 % |
| 70 % | `A_iso` | 10 / 10 | 32.13 | 65.81 [35.68–84.03] | 90.17 | 1.70 | 3.7 % |
| | `C_iso` | 10 / 10 | 32.21 | 52.91 [49.89–54.59] | 61.48 | 1.62 | 4.2 % |
| | `D` | 10 / 10 | 32.08 | 96.32 [39.33–128.70] | 112.32 | 1.65 | 0.0 % |
| 85 % | `A_iso` | 10 / 10 | 33.66 | 181.25 [141.57–382.98] | 248.00 | 2.02 | 9.05 % |
| | `C_iso` | **9 / 10** | **173.31** | 240.13 [93.18–492.03] | 251.65 | 2.29 | 1.5 % |
| | `D` | 10 / 10 | 32.57 | **52.61 [42.69–87.93]** | **58.03** | 2.02 | 0.0 % |

The unsustained trial: `C_iso` at 85 % reached 98.0 % of the expected rate (48,884 of 49,860).

| rate | `D` vs `A_iso` | `D` vs `C_iso` | `C_iso` vs `A_iso` |
|:--|:--|:--|:--|
| 50 % | p = 0.48 | p = 0.14 | p = 0.31 |
| 70 % | p = 0.19 | p = 0.019, `D` higher | p = 0.043, `C_iso` lower |
| 85 % | **p = 1.1 × 10⁻⁵**, no overlap | **p = 2.2 × 10⁻⁵** | p = 0.40 |

At 85 % `D`'s worst trial (87.9 ms) is below `A_iso`'s best (141.6 ms); one `C_iso` trial
(93.2 ms) reaches into `D`'s range. `C_iso` at 85 % is the one cell in either campaign whose
*median* latency left the floor — 173 ms, five times the backend's 30 ms — so most of its trials
carried a standing queue for the whole window while still meeting the rate. It also used more CPU
than the other two arms at the same rate (2.29 against 2.02).

At 70 % `D` is the highest of the three: §5.3.

---

## 4. Against the hypothesis

HYP-TAIL, as registered before these campaigns ran: *at 50–95 % of the stock scheduler's
saturation rate, the pinned custom scheduler has a lower worst-trial p99 than `A_iso` at every rate,
and the difference is explained by carrier run-queue wait.* Falsified if `D`'s worst-trial p99 is
not below `A_iso`'s at three or more rates over n ≥ 5, or if `perf sched` does not show floating
carriers sharing a CPU in the trials where their tail breaks down.

Worst sustained trial's p99, ms:

| regime | rate | `A_iso` | `C_iso` | `D` | `D` below `A_iso`? |
|:--|:--|--:|--:|--:|:--|
| CPU-bound | 50 % | 2.66 | 2.69 | 2.68 | no (equal) |
| | 70 % | 11.35 | 2.68 | 2.55 | yes |
| | 85 % | 28.58 | 77.12 | 2.83 | yes |
| | 90 % | 61.82 | 38.21 | 8.66 | yes |
| I/O-bound | 50 % | 51.58 | 51.97 | 50.33 | not distinguishably |
| | 70 % | 84.03 | 54.59 | **128.70** | **no — highest of the three** |
| | 85 % | 382.98 | 492.03 | 87.93 | yes |

- **The falsification criterion is not met:** `D` fails to be below `A_iso` at one rate per regime,
  not three.
- **The hypothesis as stated is not met either.** "At every rate" fails at 50 % in both regimes,
  where nothing separates, and at 70 % in the I/O-bound regime, where `D` is the worst arm.
- **The mechanism clause is untested.** No `perf sched` trace was taken in either campaign (§5).

What the two campaigns support is narrower than the hypothesis: **near capacity — 85 % in both
regimes, 90 % where measured — pinning the custom scheduler's carriers bounds the open-loop tail
against both the stock scheduler and the same scheduler unpinned.** Below that, the arms are
indistinguishable or, in one cell, ordered the other way.

**Multiplicity.** This report runs 42 tests (two campaigns, every rate, three pairs, p99 and
p99.9). At a Bonferroni threshold of 0.05 / 42 = 0.0012 the surviving separations are `D` against
both floating arms at 85 % in both regimes and at 90 %, on p99 and p99.9, and the 0.07 ms
`D` vs `C_iso` difference at CPU-bound 70 %. Neither 70 % I/O-bound difference survives, on p99
(0.019, 0.043) or on p99.9 (0.0015 each, just above the threshold). §5.3 therefore treats the
70 % I/O-bound ordering as observed, not established.

HYP-CPU and HYP-CACHE are in §5.4 and §8.

---

## 5. Mechanism: what the data shows and what it does not

### 5.1 Carrier run-queue wait

`pidstat -t` reports per-thread `%wait`, the share of the window a runnable thread waited for a
CPU. The tables in §2 and §3 carry the larger of the two carriers' values, medianed over the cell.

- **Pinned carriers do not wait.** `D` reads 0.0 % in every trial of every cell except four
  I/O-bound 85 % trials at 0.1–0.2 %.
- **Floating carriers wait, and more as load rises.** CPU-bound: ≤ 0.1 % at 50 %, 1.4–3.1 %
  (`A_iso`) and 2.2–5.2 % (`C_iso`) at 85 %. I/O-bound: 0.1 % at 50 %, up to 10.5 % for `A_iso` at
  85 %.
- **Within a cell, wait tracks the tail in some cells and not in others.** Spearman ρ between a
  trial's carrier wait and its p99: 0.80 (`A_iso`) and 0.88 (`C_iso`) at CPU-bound 90 %, 0.85 for
  `A_iso` at I/O-bound 85 %, 0.77 for `A_iso` at I/O-bound 70 % — but 0.45 / 0.63 at CPU-bound
  85 %, and −0.22 for `C_iso` at I/O-bound 85 %, the worst cell in either campaign, whose wait is
  among the lowest (1.3–2.3 %).

Two floating carriers allowed on two CPUs, with no other server thread allowed there, can only
wait for each other or for the kernel's own work on those CPUs. That fits the pilot's reading —
both carriers placed on one CPU, a queue with nobody to drain it — and a scheduler without work
stealing would suffer from it most. It is not established: the wait is small relative to the tails
it would have to explain, `C_iso`'s worst cell does not follow it, and the direct observation the
hypothesis names, a `perf sched` trace showing the two carriers on one CPU while the tail grows,
has not been taken. The harness records one with `--perf-sched` in diagnostic trials, which are not
latency results.

### 5.2 What pinning removes besides the wait

`D` differs from `C_iso` in more than run-queue wait. A pinned carrier never migrates, so its
queue, the virtual threads it last ran, and its share of the JDK poller's wake-ups stay on one
L2. Nothing here separates that from the run-queue wait: the two co-vary perfectly by
construction. HYP-CACHE (§8) is the test built for the locality half, and it has not run.

### 5.3 Not explained: `D` at 70 % with the 30 ms backend

Ten `D` trials at 43,300 req/s split into two groups across JVMs: four at p99 39–62 ms (comparable
to the other arms) and six at 94–129 ms. In every one of them both carriers run at 56–59 % CPU
with 0.0 % wait, so the carriers are neither saturated nor contended. The trials are spread through
the campaign's run order (positions 14–94 of 99), so this is not a drift of the host over time.

The latency spectrum of the slowest trial (`r8-D-43300`, p99 128.7 ms) has 95 % of requests at or
below 34.3 ms and the remaining 5 % rising smoothly to a maximum of 184.6 ms. That shape is what
repeated stalls of up to ~150 ms produce under coordinated-omission correction; a standing queue
would move the median instead, and the median is 32.0 ms.

The same ordering appears in the abandoned campaign `20261013T062036Z` (5,000-slot pool,
exploratory, isolation-valid trials only): at 70 % `D`'s median p99 was 260 ms against 147
(`A_iso`) and 167 ms (`C_iso`), while at 50 % and 85 % it was not the worst. Two campaigns with
different pool sizes agreeing on the one cell suggests the effect is not noise; it does not say
what it is.

What it is not, on this data: carrier saturation, carrier wait, or a mis-pinned thread (the
isolation gate passed in every trial). What it might be — a stall in the JDK poller path that only
a pinned carrier cannot route around, a backend-pool interaction, or something in the transport —
is untested. The same arm at 85 % in the same campaign is the best of the three, so the effect is
not monotone in load. A `perf sched` and wall-clock profile of `D` at this rate is the next
diagnostic.

### 5.4 Cost (HYP-CPU)

| regime, 50 % | `A_iso` | `C_iso` | `D` |
|:--|--:|--:|--:|
| CPUs utilised, CPU-bound | 1.22 | 1.20 | 1.21 |
| carrier CPU %, CPU-bound | 86.1 | 84.3 | 84.5 |
| CPUs utilised, I/O-bound | 1.32 | 1.26 | 1.25 |

At equal achieved rates, the custom scheduler spends no more CPU than the stock one; with the
30 ms backend it spends 5 % less. IPC is 0.71–0.77 in every cell of both campaigns. HYP-CPU —
*no carrier CPU premium from the scheduler itself* — is not falsified, and the profile it called for
to attribute an excess is moot because there is no excess.

---

## 6. Saturation, for the ladder only

Closed-loop `wrk`, n = 3 per arm, median req/s:

| regime | `A_iso` | `C_iso` | `D` |
|:--|--:|--:|--:|
| CPU-bound | 75,998 | 75,421 | 78,381 |
| I/O-bound | 61,887 | 52,413 | 55,704 |

These set the rate ladder (from `A_iso`) and are not a throughput result. With 5,000 connections
and 2,048 backend slots, I/O-bound saturation keeps ~3,000 requests queued for a slot, so its
ceiling includes the pool's hand-off, which is serviced in arrival order (§7.1); n = 3 on a desktop
host does not support ranking the arms on it.

---

## 7. Observations, not results

*Exploratory. Each was measured outside the two campaigns above, on fewer trials, or on an
unshielded host. No comparative claim in this report rests on them.*

### 7.1 An unfair lock in the application starves under the custom scheduler

The backend pool first used `LinkedBlockingDeque.takeFirst()`, which wakes the longest waiter but
lets a newly arriving caller take a returned slot before the woken one runs. At closed-loop
saturation with 5,000 connections and 2,048 slots (shielded host, one trial per arm, campaign
`20261013T131136Z-jdk-kbc26f9a0e8fc`, abandoned for this reason):

| arm | p50 | p99 | `wrk` timeouts (2 s) in 60 s |
|:--|--:|--:|--:|
| `A_iso` | 78.5 ms | 305 ms | 0 |
| `C_iso` | 37.0 ms | 1.41 s | 6,518 |
| `D` | 33.6 ms | 1.36 s | 5,294 |

Under the stock scheduler every caller waited about the same; under the custom one the
distribution split into callers that barged (no wait) and callers starved to the client's timeout.
A woken virtual thread on a per-carrier FIFO queue runs only after everything queued ahead of it on
that carrier, and a new arrival that reaches the lock first takes the slot. The pool now orders
waiters with a fair `Semaphore` (harness `e33e9595`), and the I/O-bound campaign ran on it.

This is a property of the application's lock interacting with the scheduler's wake ordering, not
of either alone, and it is one trial per arm. It is worth stating because a custom scheduler
inherits every unfair primitive in the code it runs, and the stock scheduler's work stealing hid
this one.

### 7.2 The backend pool's size sets the I/O-bound tail

Before the pool was sized to the requests in flight, it held one slot per client connection
(5,000). At 50 % load every arm then read a median p99 of 77–92 ms, against 39–44 ms in §3. On an
unshielded host, one trial each,
`A_iso` at 30,000 req/s: 2,000 connections with 2,000 slots, p99 ~38 ms; 5,000 with 5,000,
180–220 ms; 5,000 with 2,000, 36.9 ms. The tail follows the pool, not the connection count. The
pool opens sockets lazily and keeps them, so a 5,000-slot pool can end up holding thousands of idle
backend sockets registered with the JDK poller; whether that is the mechanism is unmeasured.

---

## 8. What was measured, and what was not

- **Cache locality (HYP-CACHE).** Not run. Both regimes keep the in-flight state far inside the
  32 MiB L3 (CPU-bound: at most one request per connection, ≤ 100 in flight; I/O-bound: ≤ ~1,700). Nothing here says whether
  resuming a virtual thread on the carrier that last ran it saves misses.
- **The mechanism behind the 85–90 % separation.** Consistent with carrier stacking (§5.1),
  confounded with locality (§5.2), and not traced.
- **`D` at 70 % with the 30 ms backend.** Observed, bimodal, unexplained (§5.3).
- **The `kernel` backend.** Every trial here woke handler virtual threads through the JDK poller.
  With the kernel's own HTTP client, the wake-up would come from the transport's reactors; that arm
  exists in the harness and has not run.
- **Rates above 85 % in the I/O-bound regime, and 95 % in either.**
- **More than two carriers, other CPU counts, or a dedicated machine.** Every figure is for two
  carriers on a 6-core desktop under a cgroup shield. `dev-isolated` results are not
  `perf-box-amd64` results.
- **Saturation throughput as a claim** (§6).
- **Anything about H2, H3, TLS, the Enterprise `io_uring` transport, or the stock JDK.** The
  custom scheduler exists only on the Loom `fibers` EA build.

### 8.1 Relation to the pilot

The pilot (2026-09-27) is not evidence, but three of its readings were what this track set out to
test, and they come out differently:

- **CPU premium.** The pilot measured ~222 % CPU for `D` against ~155 % for the stock scheduler at
  50 % load. Here the two are equal (§5.4). The carrier loop was measured to park correctly
  before these campaigns ran (kernel `docs/research/loom-carrier-scheduler/probes/`); what the
  pilot's premium was cannot be recovered, because the pilot cannot identify the kernel code it
  ran.
- **Floating-carrier wait.** The pilot read 12–25 %. On a shielded host it is 0.1–10 %, rising
  with load.
- **The pilot's worst-trial table** put `D` best at every rate. With ten trials per cell instead of
  three, that holds near capacity and does not hold at 70 % with a 30 ms backend.

---

## Revision history

| date | change |
|---|---|
| 2026-10-14 | First publication. Campaigns `20261009T040618Z-jdk-kbc26f9a0e8fc` (CPU-bound, 129 trials) and `20261013T191957Z-jdk-kbc26f9a0e8fc` (I/O-bound, 99 trials), both evidence-eligible under the scenario's gates. Three earlier I/O-bound campaigns did not qualify and are not used: `20261009T062839Z` ran under a 1,024-descriptor limit and connected 1,017 of 5,000 clients; `20261013T062036Z` had carriers moved off their CPUs by the harness in 25 of 99 trials (rejected by the isolation gate) and a 5,000-slot backend pool (§7.2); `20261013T131136Z` was stopped at saturation by the pool's unfair hand-off (§7.1). |

**Updated:** 2026-10-14
*By Arkadiusz Przychocki (updated 2026-10-14)*
