# When throughput lies: steady-state, coordinated omission, and the real cost of a request

*An entity-read-by-id investigation — Exeris (Community) vs Quarkus, with Spring as a reference point.*

**Track:** Community · **Benchmark family:** Runtime · **Scenario:** `entity-read-by-id` · **Date:** 2026-06-20 · **Bench commit:** `7e7aeb8`

---

## TL;DR

We set out to compare three JVM HTTP stacks on a trivial DB-backed read (`GET /api/v1/users` → indexed Postgres lookup) and discovered that almost every number you would naively quote is wrong for a different reason:

- **Throughput depends on the network plumbing, not just the app.** Moving Postgres from a bridged container to host networking lifted Exeris throughput **+20%** with *zero* application change — the bridge/NAT tax was stealing the target's CPU as softirq.
- **Latency percentiles from a saturated closed-loop driver are not latency.** h2load reported a p50 of **146 ms**; the real service-time p50 was **~3–7 ms**. The 146 ms was queue depth ÷ throughput (Little's law), to the digit.
- **The JIT matters longer than your warmup.** Exeris reached steady state essentially instantly (C2 compile queue never backed up); Quarkus was *still* compiling hot methods **after 5 minutes** of warmup.
- **The one metric that stayed stable across all of this was CPU-per-request.** Exeris served comparable-or-higher throughput for **~29% less CPU per request** — the same edge whether the box was warm, cold, bridged, or host-networked.

What we will **not** claim: that Exeris has a better *median* latency (on this hardware that signal is buried in noise), or that any of these absolute numbers transfer off a developer workstation.

---

## Why this report exists

This is a benchmark *lab*, not a marketing exercise. The mandate is to measure fairly, reproducibly, and honestly — and explicitly **not** to make Exeris look fast. Several of the findings below are uncomfortable for a naive "Exeris wins" narrative (the median-latency result in particular), and they are reported as found.

The interesting output of this session is less "stack X beat stack Y" and more **a methodology for not fooling yourself**: how to prove steady state, how to make a loopback run actually measure the server, how to tell a latency number from a queueing artifact, and which metric survives all of it.

---

## Setup and honest disclaimers

| | |
|---|---|
| **Hardware** | AMD Ryzen 5 **5600 (6 cores / 12 threads, SMT)**, 60 GB RAM, `performance` governor |
| **OS / kernel** | Linux `7.0.0-22-generic`, scheduler **EEVDF** |
| **JDK** | Oracle JDK **26** (`java 26 2026-03-17`) |
| **Drivers** | h2load `nghttp2/1.68.0`, wrk2 (HdrHistogram), wrk `4.1.0` |
| **Backend** | PostgreSQL in a container (bridge **and** host-net tested) |
| **Targets** | `exeris-benchmark-app-community-h1`, `quarkus-jvm-vt-tuned`, Spring (reference) |
| **Profile class** | `dev-laptop` |

**Read these before any number below:**

1. **`dev-laptop`, not `perf-box-amd64`.** Turbo is on, it is a workstation, and absolute numbers are **not** publication-grade. Use them for *relative, same-box* comparison only.
2. **Single run per configuration** unless stated. Where we show two runs of the "same" thing they disagree by up to **2.3×** on median latency — see the variance section. Treat single-run latencies as *directional*.
3. **SMT pinning caveat.** The CPU is 6 physical cores / 12 SMT threads. We pin to *logical* threads (e.g. "target `0-4`"), so some pinned "cores" may be SMT siblings sharing a physical core. The target-bound conclusions hold directionally but the core math is approximate.
4. **Community track only.** No Enterprise targets, no H3, no locality. Nothing here speaks to those.

---

## Act 1 — The warmup trap: when 5 minutes isn't enough

The first thing we added was a way to *prove* steady state instead of assuming it. We overlay three JFR compiler events (`jdk.CompilerStatistics`, `jdk.CompilerQueueUtilization`, `jdk.Compilation`) on the recording and watch the **C2 compile queue** drain.

The rule we adopted: a run is only "warm" if the C2 queue is empty for the whole measurement window.

What we found, on identical 5-minute-warmup / 10-minute-measure runs:

| | Exeris | Quarkus |
|---|---|---|
| C2 queue peak (measurement window) | **0** | **97** |
| `jdk.Compilation` > 100 ms during measurement | ~2 | **107** |

**Exeris's C2 queue never backed up** — it was fully compiled almost immediately. **Quarkus was still doing >100 ms compilations 5+ minutes in.** Earlier runs made this even more visible: a 60 s warmup left Quarkus compiling through the *first ~57 s of its measurement window*, and Quarkus throughput climbed from 5 642 → 6 660 rps (+18%) just by extending warmup 120 s → 180 s, while Exeris was flat regardless.

**Consequence:** any Quarkus throughput number here is a mild *under*-estimate (it is still improving), and short-warmup latency for Quarkus is partly cold-JIT noise. This is also why we stopped trusting any run we couldn't confirm warm.

> Reference reading on exactly this failure mode: *"When the JIT can't keep up."* We hit the same wall from the other side — the harness, not the app.

---

## Act 2 — The bridge tax: your network plumbing is a benchmark variable

Naively, the database lives "in a container" and you stop thinking about it. That is a mistake when the app is chatty enough.

Same Exeris target, same workload, **only** the Postgres container network mode changed:

| | bridge (NAT) | host-net |
|---|---|---|
| Throughput | 6 894 rps | **8 310 rps (+20.5%)** |
| Target-thread `%wait` | **265%** | **57%** |
| App CPU / request | 0.357 ms | 0.358 ms |
| Target cores | 4 | 3 |

The application's CPU-per-request **did not change** (0.357 → 0.358 ms). What changed is that under bridge networking, every DB round-trip went through NAT / `docker-proxy`, burning the target's cores on **softirq and `%sys`** — so the JVM's own threads sat in the run queue waiting (`%wait` 265%). Remove the NAT and the threads stop waiting (`%wait` → 57%), and the same per-request cost converts into **+20% throughput** — even after *giving the target one fewer core*.

This is a **fairness gate, not hygiene**: bridge/NAT taxes a chattier stack asymmetrically. A higher-throughput target does *more* DB round-trips per second, so it pays *more* bridge tax — which means bridge networking can silently penalize exactly the stack that would otherwise look best. All cross-stack comparisons below use **host networking**.

---

## Act 3 — Coordinated omission: a p50 of 146 ms that was never real

h2load is the only driver in our kit that speaks cleartext HTTP/2 (h2c), so we taught it to emit percentiles (via `--log-file` + offline aggregation). On the warmed, host-net Exeris run it reported:

```
h2load (closed-loop, at saturation):  p50 = 146 ms,  p99 = 247 ms,  mean = 144 ms
```

146 ms for an indexed primary-key lookup is absurd — and it is **coordinated omission**, demonstrable to the digit. h2load is closed-loop: with `-c 128 -m 10` it keeps up to **1 280** streams in flight. By Little's law:

```
in-flight = throughput × latency = 8 844 rps × 0.1443 s ≈ 1 276  ≈  1 280 streams
```

So the "latency" was just **queue depth ÷ throughput**. It measured how full the pipe was, not how long the server took. Every closed-loop driver at saturation does this (wrk included).

The fix is a *different experiment*, not a different parser: **wrk2 at a fixed arrival rate below saturation** (open-loop, HdrHistogram, CO-free). Same Exeris target, sub-saturation:

```
wrk2 (open-loop, ~75% load):  p50 = 2.95 ms,  p99 = 8.19 ms
```

**p50: 2.95 ms vs 146 ms — a 49× gap between the real service time and the saturated-queue artifact.** This is the single most important methodological point in the report: *never quote a saturated closed-loop percentile as latency.* Our h2load percentiles ship with a `co_caveat` stamped into the artifact for exactly this reason.

---

## Act 4 — The metric that didn't lie: CPU per request

Throughput moved with the network. Latency moved with load and box noise. Warmup moved with time. Through all of it, **CPU consumed per request** stayed put — and it is the cleanest expression of "how much machine does this stack cost."

Matched, fully-warmed, host-net, target-bound (5 cores), 10-minute measurement:

| | Exeris | Quarkus | Spring (ref) |
|---|---|---|---|
| Throughput | **8 844 rps** | 7 836 rps | 3 052 rps |
| **CPU / request** | **0.390 ms** | 0.552 ms | 0.956 ms |
| App `%CPU` (of 500% avail.) | 344 (69%) | 432 (86%) | 292 |
| C2 settled? | yes (peak 0) | **no (peak 97)** | no (peak 72) |

- **Exeris serves +13% more throughput for −29% less CPU per request** than Quarkus. To deliver its *lower* 7 836 rps, Quarkus burned 432% CPU; Exeris delivered *more* (8 844) on 344%.
- Spring is a different era: **2.7× the CPU per request** of Exeris. (We are taking the operator's "archaic" characterization as a hypothesis; the data is consistent with it. No deeper Spring analysis was done.)
- **Exeris was not even CPU-bound on the app** (344 of 500% used) — its throughput ceiling here is *higher* than 8 844; the bottleneck had moved to the driver / DB / kernel. So **+13% is a lower bound.**

This `CPU/req` advantage reproduced in every configuration we measured (−26% to −32% across bridge, host-net, 3/4/5 cores, warm/short-warmup). It is the durable finding.

---

## Act 5 — Latency, honestly: tail yes, median no

Here the story gets uncomfortable, and we report it straight.

**Comparison A — each stack at 75% of its *own* saturation (good box state):**

| | Exeris | Quarkus |
|---|---|---|
| p50 | **2.95 ms** | 9.03 ms |
| p99 | **8.19 ms** | 14.73 ms |

**Comparison B — both at a *fixed* 6 000 rps (matched absolute load, comparable box state):**

| | Exeris | Quarkus |
|---|---|---|
| p50 | 6.73 ms | 6.48 ms |
| p90 | 11.29 ms | 11.18 ms |
| p99 | **18.05 ms** | 46.78 ms |
| p99.9 | **43.26 ms** | 142.46 ms |

These two comparisons **disagree about the median**. Comparison A says Exeris p50 is 3× better; Comparison B says the medians are identical. The tie-breaker is variance: between two Exeris runs minutes apart, with no config change, the saturation discovery swung **8 954 → 7 643 rps (−15%)** and p50 swung **2.95 → 6.73 ms (2.3×)** — pure box-state noise on a workstation.

So, honestly:

- **Median / typical latency: not distinguishable on this hardware.** The run-to-run noise (2.3×) is larger than any between-stack difference we saw. We do **not** claim a median-latency win for Exeris.
- **Tail latency (p99 and beyond): consistently favors Exeris** — 1.8× in Comparison A, 2.6–3.3× in Comparison B. This is robust across runs and is consistent with the rest of the picture (Quarkus's still-warming JIT and higher CPU/req → more GC/compilation jitter → fatter tail).

**Fairness caveat on Comparison B:** because the two runs discovered slightly different saturation points, the *load fraction* differed — Exeris ran at 0.785 of its ceiling, Quarkus at 0.808. Quarkus was pushed marginally closer to saturation, which inflates its tail somewhat. Part of the p99 gap is this asymmetry, not pure efficiency. A cleaner design fixes the rate as the same fraction of the *shared lower* saturation.

---

## What we had to fix before we could trust any of this

Three measurement bugs were found and fixed mid-investigation. They are worth listing because each one would have silently corrupted a result:

1. **pidstat per-thread CSV corruption.** JVM thread names contain spaces (`C2 CompilerThread0`, `G1 Young RemSet Sampling`). A naive whitespace→comma conversion split them into extra columns — corrupting exactly the C2-thread `%wait` row we cared about. Fixed by quoting the trailing command column.
2. **wrk2 lost a full run to a locale comma.** On a `pl_PL` locale, `awk`'s `printf "%.6f"` emitted `0,75`, which `jq --argjson` rejected as invalid JSON — *after* a complete 2-minute measurement. Fixed by forcing `LC_ALL=C`.
3. **CPU pinning wasn't being recorded.** The guided profile only persisted CPU affinity for *constrained* runs, so target-bound (unconstrained) runs dropped it from the reproducibility metadata. Fixed.

The meta-lesson: instrumentation needs the same skepticism as the system under test.

---

## Methodology (reproducibility)

Everything below is wired into `run-entity-read-by-id.sh` / `run-guided.sh` and recorded per run.

- **Steady-state proof:** JFR overlay `env/jfr-steady-state.jfc` (`BENCH_JFR_STEADY_STATE=1`) → C2 compile-queue timeline. A run is "warm" only if the queue is empty across the measurement window.
- **Target-bound measurement:** pin target and load driver to **disjoint** cpusets (`--cpu-affinity` / `--client-cpu-affinity`) so the *target* is the bottleneck and rps tracks target efficiency. Verify the target's cores are saturated and the driver has headroom — otherwise you measured the driver.
- **OS sidecars:** `pidstat -t` (per-thread `%wait`, context switches) + `mpstat -P ALL` (`%usr/%sys/%soft/%idle`) over the measurement window (`BENCH_OS_SIDECARS=1`). High `%soft`/`%sys` on the app cores = CPU burned on network/kernel, not the app.
- **Backend network mode:** `DB_HOST_NETWORK=1` to take the bridge/NAT tax off the path. Treated as a fairness gate; recorded as `backend_network_mode`.
- **Two-experiment latency:**
  - *Throughput / CPU-efficiency* — h2load (h2c) at saturation. Percentiles via `--log-file`, **explicitly CO-caveated**.
  - *Real tail latency* — wrk2 (`-R`, HdrHistogram) at a fixed sub-saturation rate (`WRK2_TARGET_RPS`), CO-free. Always check `at_saturation=false` in the artifact.
- **CPU per request:** `process %CPU / throughput` from the per-thread pidstat aggregate — the primary cross-stack signal.

---

## Conclusions

**What the data supports (this hardware, this scenario, directional):**

1. **Resource efficiency is Exeris's real differentiator.** ~29% less CPU per request than Quarkus, ~2.7× less than Spring — stable across every configuration tested.
2. **Exeris reaches steady state far faster.** Quarkus was still JIT-compiling after 5 minutes; Exeris was warm almost immediately.
3. **Exeris has a meaningfully better latency *tail*** (p99+), 1.8–3.3× depending on load.
4. **Throughput favors Exeris (+13%), and that is a lower bound** — Exeris was not app-CPU-bound at the point we measured.

**What the data does *not* support:**

- Any claim about **median latency** — it is noise-dominated on this box.
- Any **absolute** number as production capacity — `dev-laptop`, single runs, SMT-approximate pinning.
- Anything about **Enterprise / H3 / locality** — out of scope.

**To make this publication-grade:** move to `perf-box-amd64` (no turbo, pinned kernel/scheduler), run **interleaved repetitions** (A,B,A,B…) to average box drift, fix the wrk2 rate to the same fraction of the *shared lower* saturation, and confirm C2-settled for every stack before measuring.

---

## Appendix — run index

All runs: `entity-read-by-id`, host-net (unless noted), `dev-laptop`, JDK 26, kernel `7.0.0-22` (EEVDF). Raw artifacts under `results/raw/guided/<timestamp>/`.

| Timestamp (UTC) | Target | Driver | Notes |
|---|---|---|---|
| `…114151Z` | Exeris | h2load | 5/10, 5 cores — 8 844 rps, CPU/req 0.390 ms, C2=0 |
| `…121411Z` | Quarkus | h2load | 5/10, 5 cores — 7 836 rps, CPU/req 0.552 ms, C2 peak 97 |
| `…111404Z` | Spring | h2load | reference — 3 052 rps, CPU/req 0.956 ms |
| `…123114Z` | Exeris | wrk2 | 75%-own-sat — p50 2.95, p99 8.19 ms |
| `…123720Z` | Quarkus | wrk2 | 75%-own-sat — p50 9.03, p99 14.73 ms |
| `…125344Z` | Exeris | wrk2 | matched 6 000 rps — p50 6.73, p99 18.05 ms |
| `…130014Z` | Quarkus | wrk2 | matched 6 000 rps — p50 6.48, p99 46.78 ms |

*Bridge-vs-host-net (Act 2) and the short-warmup progression (Act 1) come from earlier runs in the same session; see `results/raw/guided/`.*

---

*Generated as part of the steady-state / fairness instrumentation work (branch `feat/steady-state-fairness-instrumentation`). Methodology lives in `docs/methodology.md`; hardware-profile constraints in `docs/hardware-profiles.md`.*
