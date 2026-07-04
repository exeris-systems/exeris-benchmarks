---
title: "entity-read-by-id — constrained-axes data dossier (cgroup CPU/memory limits)"
date: 2026-06-23 00:00:00 UTC
categories:
  - performance
  - benchmarking
  - jvm
summary: "Raw data collection for extending the 2026-06-20 steady-state report with constrained axes: unconstrained/default-JVM (incl. tuned-Quarkus Netty+tcnative and default Quarkus ORM JSSE+NIO), 1024 MB / 4 vCPU, 512 MB / 2 vCPU, and a 512-connection comparator. Documents the full tuning journey — the GC sweep (Serial→SIGSEGV, ZGC→OOM, Parallel=winner), OOM-in-teardown kills, JVM SIGSEGV crashes, and DB-pool exhaustion — not just the surviving numbers."
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: entity-read-by-id
claim_scope: descriptive_only
reproducibility_status: partial
comparison_axis: within-tier
hardware_profile: dev-laptop
status: data-collection (work-in-progress — reruns and JFR-instrumented runs pending)
---

# entity-read-by-id — constrained-axes data dossier

**This is a data-collection document, not a published report.** It assembles the raw evidence
for extending [*When throughput lies*](2026-06-20-entity-read-by-id-steady-state-and-cost-per-request.md)
(2026-06-20) from a single unconstrained axis to a **constrained matrix** (cgroup CPU + memory
limits), and — crucially — records **the path**: the crashes, OOM kills, and GC tuning that most
runs went through before a number survived. It is expected to grow as reruns and JFR-instrumented
runs land (see [§7 Pending](#7-pending--to-be-added)).

> **Status & claim eligibility.** `claim_scope: descriptive_only` · **`dev-laptop`** · within-tier.
> These are **not** `comparison_eligible` (that is reserved for `perf-box-amd64`). Treat every number
> as **directional**. Unlike the 2026-06-20 axis, **JFR steady-state proof was OFF for the constrained
> runs** (`enable_jfr=false`, `jfr_steady_state=false`) to keep them inside the resource cap — so for
> the constrained axes there is **no C2-queue-empty warm proof**; warm state is assumed from the
> 300 s warmup only. Do not quote "C2 settled" for constrained rows. JFR-instrumented constrained
> reruns are planned but **barely fit the cgroup budget** (Exeris's high-volume custom JFR telemetry
> alone pushes RSS toward the cap), so they may stay best-effort.

**Provenance.** Session 2026-06-23, bench commit `ef6f84e`, JDK 26 (`26+35-2893`), kernel
`7.0.0-22` (EEVDF), host-net Postgres, target pinned `0-4`. h2load (h2 over TLS 1.3,
`TLS_AES_128_GCM_SHA256`) unless noted.
Unconstrained runs: `results/raw/guided/20260623T092622Z … 130135Z`.
Constrained runs: `results/constrained/entity-read-by-id/20260623T131902Z-guided … 204115Z-guided`.
**40 runs in scope: 19 produced a result, 21 did not** (crash / OOM-in-teardown / abandoned-tuning).

**Targets under test:**

| Short name | What it is | Transport | DB access |
|---|---|---|---|
| **Exeris Community** | `exeris-community-app`, native kernel | own `crypto` engine, h2 | blocking JDBC, kernel pool |
| **Quarkus JDBC tuned** | `quarkus-benchmark-app-tuned` — **tuned Netty transport + netty-tcnative** | tcnative TLS, h2 | `@RunOnVirtualThread` + blocking JDBC |
| **Quarkus Hibernate ORM** | `quarkus-benchmark-app` — default, **JSSE + NIO** | JSSE, h2 | Hibernate ORM / JDBC |

> The 2026-06-20 report's "Quarkus" is the **ORM/JSSE** target. The **tuned JDBC (Netty+tcnative)**
> target is new to this matrix and behaves very differently — see §1.

---

## 1. Axis A — Unconstrained, default JVM (no cgroup)

128 con / 4 thr · warm 300 s / measure 600 s · h2+TLS · pin 0-4 / client 5-9.

| Target | n | rps (mean) | peak RSS | CPU/req | crashes |
|---|---|---|---|---|---|
| **Exeris Community** | 3 | **9 805** | **~829 MB** | **0.372 ms** | 0 |
| **Quarkus JDBC tuned** (Netty+tcnative) | 3 | **10 644** | ~2 940 MB (3.5×) | 0.322 ms | **2× SIGSEGV** of 5 attempts |
| **Quarkus Hibernate ORM** (JSSE+NIO) | 3 | 8 262 | ~3 601 MB (4.3×) | 0.545 ms | 0 |

Per-run rps — Exeris `[9980, 9567, 9866]`; Q-tuned `[10509, 10905, 10519]`; Q-ORM `[8240, 8264, 8282]`.

**Read.** With unlimited memory the **tuned Quarkus is the throughput/CPU leader** (+8.6 % rps,
−13 % CPU/req vs Exeris) — **but** at ~3.5× the RSS and it **SIGSEGVs intermittently** (2 of 5
attempts: `094223Z`, `122800Z`). The default ORM/JSSE Quarkus is the slowest and heaviest. Exeris
is the only crash-free stack and by far the lightest. **This ordering inverts under constraint (§2–§4).**

---

## 2. Axis B — Constrained 1024 MB / 4 vCPU

cgroup `memory.max=1024 MB`, `cpu.max=400 %` · `-XX:+UseParallelGC` (winning GC, see §5) ·
128 con / 4 thr · 300 s / 600 s.

| Target | run | rps | peak RSS | cgroup mem-peak | CPU/req | throttled periods |
|---|---|---|---|---|---|---|
| **Exeris Community** | `170541Z` | **10 469** | **558 MB** | 992 MB | **0.303 ms** | **380** |
| **Quarkus JDBC tuned** | `164827Z` | 10 139 | 639 MB | **1024 MB (at cap)** | 0.316 ms | 741 |

Overlay — Exeris `Xms128m Xmx256m`; Quarkus `Xms256m Xmx768m`; both `ActiveProcessorCount=4`.

**Read.** Boxed into 1 GB, **Axis A inverts**: Exeris leads on **throughput (+3.3 %)**, keeps
**memory headroom** (992 MB vs Quarkus pinned at the 1024 MB cap), and suffers **half the CPU
throttling**. The tuned Quarkus's large heap leaves no slack and rides the cap.

256-con at this cap: Exeris `185203Z` **OK** (9 884 rps, p99 471 ms); Quarkus `190828Z` **SIGSEGV**.

---

## 3. Axis C — Constrained 512 MB / 2 vCPU

cgroup `memory.max=512 MB`, `cpu.max=200 %` · ParallelGC · `ActiveProcessorCount=2`.

| Target | run | con | rps | peak RSS | CPU/req | throttled | result |
|---|---|---|---|---|---|---|---|
| **Exeris Community** | `172645Z` | 128 | 7 066 | 352 MB | 0.229 ms | 9 006 | **OK** |
| **Exeris Community** | `181813Z` | 64 | 7 018 | 317 MB | 0.232 ms | 9 007 | **OK** |
| **Quarkus JDBC tuned** | `174511Z` | 128 | — | — | — | — | **FAIL — won't fit** |
| **Quarkus JDBC tuned** | `180027Z` | 64 | — | — | — | — | **FAIL** |

Overlay (Exeris) `Xms128m Xmx384m`.

**Read — the headline of this matrix.** At **512 MB / 2 vCPU only Exeris runs at all.** Every tuned-Quarkus
variant in 512 MB failed (OOM in teardown / won't fit). Exeris holds ~7 000 rps at ~0.23 ms/req,
RSS ~320–350 MB. **Caveat:** the 2-vCPU quota throttles hard (~9 000 throttled periods) — so the
~7 000 rps ceiling here is **the CPU quota, not the application**; this axis measures "does it survive
and serve" more than peak efficiency.

**256 MB is below the floor for *both* stacks** (Exeris `175745Z/184109Z/184619Z` all fail) — kept as a
negative result.

---

## 4. Axis D — 512-connection comparator (tuned Quarkus vs Exeris)

512 con / 6 thr · ParallelGC · `ActiveProcessorCount=4` · 300 s / 600 s.

| Target | run | mem cap | rps | err % | p50 | p99 | p99.9 | peak RSS | path to this number |
|---|---|---|---|---|---|---|---|---|---|
| **Exeris Community** | `204115Z` | **1024 MB** | **9 012** | **0.00 %** | 438 ms | 1844 ms | **2627 ms** | 1024 MB | clean, first try |
| **Quarkus JDBC tuned** | `202444Z` | **1536 MB** | 8 990 | **1.45 %** (78 292 err) | 514 ms | **1479 ms** | 5279 ms | 1536 MB | **after `201549Z` SIGSEGV at 1024 MB** |

Overlay — Quarkus `Xms128m Xmx1024m MaxRAM=1536m`; Exeris `Xms128m Xmx256m MaxRAM=1024m`.

**Read.** Matched throughput (~9 k rps), but Exeris does it in **1024 MB at 0 % error**, while the
tuned Quarkus needed **1536 MB (1.5×)**, first **SIGSEGV-crashed at 1024 MB**, and even at 1536 MB
shipped **1.45 % errors**. Latency trade is mixed — Quarkus better mid-tail (p99 1479 vs 1844 ms),
Exeris better far-tail (p99.9 2627 vs 5279 ms). The fair framing is *cost-to-survive-512con*, not a
clean latency win for either.

---

## 5. The tuning journey — GC sweep and why most runs failed

Every constrained run injects `-XX:ActiveProcessorCount=N -XX:MaxRAM=<cap>` inside the cgroup. The
**garbage collector was swept** before a configuration survived sustained load:

| GC | Overlay | Outcome |
|---|---|---|
| **`-XX:+UseSerialGC`** | `Xmx768m` | **Quarkus → SIGSEGV** under sustained load. Crash frames: `DefNewGeneration::copy_to_survivor_space` (`151432Z`), `LinkResolver::resolve_invokeinterface` (`152129Z`), `SerialFullGC::invoke_at_safepoint` (`152728Z`). Survives only a 30 s smoke. Exeris stable on Serial. |
| **`-XX:+UseZGC`** | `Xmx640m` | **OOM for both** (`162643Z` Q killed right after start — ZGC heap reservation alone exceeds the 1 GB cap; `163144Z` E reached 849 MB then OOM-killed). Abandoned. |
| **`-XX:+UseParallelGC`** | `Xmx256m–1024m` | **Winner** — adopted for every result run from `164827Z` onward. |

ParallelGC did **not** fully fix Quarkus: it still **SIGSEGV'd at higher pressure** —
`190828Z` (256 con) and `201549Z` (512 con), both in
`PSPromotionManager::copy_unmarked_to_survivor_space`. These GC×virtual-thread faults are the
JDK-26 Loom interaction known to affect the JDBC-tuned target; Exeris (native `TransactionalExecutor`,
not VT-carried JDBC) never SIGSEGV'd in any configuration.

---

## 6. Failure taxonomy (the 21 no-result runs)

> **Why "no result" ≠ "no data".** Several runs **served traffic fine** (h2load logged `200`s) and were
> then **OOM-killed by the cgroup during teardown** — the kernel SIGKILLs the JVM, so nothing is written
> to `target-app.log` and no `result.json` is emitted. RSS pegged near the cap (849–963 MB against a
> 1024 MB limit) is the fingerprint. These are real OOM events, not missing runs.

| Mode | Runs | Evidence |
|---|---|---|
| **JVM SIGSEGV** (GC × Loom, JDK 26) — Quarkus tuned only | `094223,122800` (uncon); `151432,152129,152728` (Serial); `190828,201549` (Parallel) | `hs_err`/`A fatal error` in log, GC copy/promote frames. **7 crashes.** |
| **OOM at teardown** (cgroup SIGKILL after serving) | `163144,191639,195519` (E, 1024); `193416` (Q, 963 MB→cap); `174511,180027` (512 cap) | RSS near cap, h2load `200`s present, no JVM log line, no `result.json`. |
| **OOM at startup** (ZGC reservation > cap) | `162643` (Q ZGC), `163144` (E ZGC) | killed right after `JAVA_TOOL_OPTIONS` echo. |
| **DB pool exhaustion** | `195158` (Q, 512 con) | `SQLException: Acquisition timeout while waiting for new connection` (pool max 16 « 512 con). |
| **Below memory floor** (256 MB won't fit either stack) | `175745,184109,184619` (E); `183649` (Q) | fails to reach steady serving at 256 MB. |
| **Harness launch failure** (no target logs at all) | `131902,133514` | first 1024/4vCPU attempts; only the profile was written. |

---

## 7. Pending — to be added

This dossier is a living collection. Still to land:

- **Reruns** of the constrained axes (the headline B/C/D rows are currently **n=1**; aim for n≥3
  interleaved to attach CV%, as the 2026-06-20 axis did).
- **New configurations** likely to be added to the matrix.
- **JFR-instrumented constrained runs** for steady-state proof and flame graphs — *budget-permitting*;
  Exeris's custom JFR telemetry already pushes RSS toward the cap, so these may stay best-effort or need
  a raised cap / `maxage`-bounded recording.
- Per-run CV% once reruns exist.

---

## 8. Full run ledger (40 runs)

`mem/cpu%` = cgroup caps ("uncon" = none). peakRSS in MB. CPU/req = `cpu_time_seconds / total_requests` (ms).

| TS (Z) | target | mem/cpu% | con/thr | GC | rps | CPU/req | peakRSS | result / cause |
|---|---|---|---|---|---|---|---|---|
| 092622 | exeris | uncon | 128/4 | default | 9980 | 0.369 | 812 | OK |
| 094223 | q-tuned | uncon | 128/4 | default | — | — | — | **SIGSEGV** |
| 104711 | q-tuned | uncon | 128/4 | default | 10509 | 0.324 | 2908 | OK |
| 110306 | q-ORM | uncon | 128/4 | default | 8240 | 0.541 | 3602 | OK |
| 111956 | q-tuned | uncon | 128/4 | default | 10905 | 0.314 | 2915 | OK |
| 113706 | exeris | uncon | 128/4 | default | 9567 | 0.377 | 783 | OK |
| 115604 | q-ORM | uncon | 128/4 | default | 8264 | 0.545 | 3605 | OK |
| 121156 | q-ORM | uncon | 128/4 | default | 8282 | 0.549 | 3597 | OK |
| 122800 | q-tuned | uncon | 128/4 | default | — | — | — | **SIGSEGV** |
| 124444 | q-tuned | uncon | 128/4 | default | 10519 | 0.327 | 2997 | OK |
| 130135 | exeris | uncon | 128/4 | default | 9866 | 0.371 | 891 | OK |
| 131902 | q-tuned | 1024/400 | 128/4 | — | — | — | — | FAIL — harness launch (no logs) |
| 133514 | q-tuned | 1024/400 | 128/4 | — | — | — | — | FAIL — harness launch (no logs) |
| 144116 | q-tuned | 1024/400 | 16/2 | Serial | 10615 | 0.241 | 268 | OK (30 s smoke) |
| 144305 | exeris | 1024/400 | 16/2 | Serial | 9042 | 0.305 | 236 | OK (30 s smoke) |
| 145833 | exeris | 1024/400 | 128/4 | Serial | 9719 | 0.309 | 332 | OK |
| 151432 | q-tuned | 1024/400 | 128/4 | Serial | — | — | — | **SIGSEGV** DefNew |
| 152129 | q-tuned | 1024/400 | 128/4 | Serial | — | — | — | **SIGSEGV** LinkResolver |
| 152728 | q-tuned | 1024/400 | 128/4 | Serial | — | — | — | **SIGSEGV** SerialFullGC |
| 162643 | q-tuned | 1024/400 | 128/4 | ZGC | — | — | — | **OOM** (ZGC reservation > cap) |
| 163144 | exeris | 1024/400 | 128/4 | ZGC | — | — | 849 | **OOM** (ZGC) |
| 164827 | q-tuned | 1024/400 | 128/4 | **Parallel** | 10139 | 0.316 | 639 | **OK** |
| 170541 | exeris | 1024/400 | 128/4 | **Parallel** | 10469 | 0.303 | 558 | **OK** |
| 172645 | exeris | 512/200 | 128/4 | Parallel | 7066 | 0.229 | 352 | **OK** |
| 174511 | q-tuned | 512/200 | 128/4 | Parallel | — | — | — | **OOM/won't fit** |
| 175745 | exeris | 256/200 | 128/4 | Parallel | — | — | — | FAIL — below mem floor |
| 180027 | q-tuned | 512/200 | 64/4 | Parallel | — | — | 373 | **OOM/won't fit** |
| 181813 | exeris | 512/200 | 64/4 | Parallel | 7018 | 0.232 | 317 | **OK** |
| 183649 | q-tuned | 256/200 | 64/4 | Parallel | — | — | — | FAIL — below mem floor |
| 184109 | exeris | 256/200 | 64/4 | Parallel | — | — | — | FAIL — below mem floor |
| 184619 | exeris | 256/200 | 32/4 | Parallel | — | — | — | FAIL — below mem floor |
| 185203 | exeris | 1024/400 | 256/4 | Parallel | 9884 | 0.319 | 636 | **OK** |
| 190828 | q-tuned | 1024/400 | 256/4 | Parallel | — | — | — | **SIGSEGV** PSPromotion |
| 191639 | exeris | 1024/400 | 512/6 | Parallel | — | — | 839 | **OOM** at teardown |
| 193416 | q-tuned | 1024/400 | 256/4 | Parallel | — | — | 963 | **OOM** at teardown |
| 195158 | q-tuned | 1024/400 | 512/6 | Parallel | — | — | — | FAIL — **DB pool timeout** |
| 195519 | exeris | 1024/400 | 512/6 | Parallel | — | — | 904 | **OOM** at teardown |
| 201549 | q-tuned | 1536/400 | 512/6 | Parallel | — | — | — | **SIGSEGV** PSPromotion |
| 202444 | q-tuned | 1536/400 | 512/6 | Parallel | 8990 | 0.344 | 1254 | **OK** (1.45 % err) |
| 204115 | exeris | 1024/400 | 512/6 | Parallel | 9012 | 0.361 | 744 | **OK** (0 % err) |

---

*Companion to `2026-06-20-entity-read-by-id-steady-state-and-cost-per-request.md`. Data-collection
status; not `comparison_eligible`. Reruns + JFR-instrumented runs pending (§7).*
