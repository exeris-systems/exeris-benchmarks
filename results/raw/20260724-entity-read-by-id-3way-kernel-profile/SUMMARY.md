# Entity-read-by-id (heavy aggregate) — three-way CPU-attribution profile

**Track:** Community / cross-runtime · **Protocol:** H1 · **Family:** Runtime · **Mode:** pure
**Scope:** `exploratory` (NOT run through the comparative strict gate — no gated throughput claim; this is a
CPU-attribution profile). Durable metrics (RSS, CPU/req) and the CPU breakdown are the deliverable.
**Date:** 2026-07-24 · **Host:** Hetzner perf-box (AMD, 16 logical / 8 physical) · **Commit fence:** post-`9f2b182`

## Why this exists

Closes two review findings on the entity-read heavy report:

- **§3 "Jackson-3 serialization dispatch tax"** — attributed exeris's heavy CPU deficit to its bundled
  serializer without equalizing the serializer layer.
- **§4 kernel blind spot** — the user-space method sampler saw "no frame > 7%" and missed the ~half of CPU
  that is `%sys`+`%soft`.

> **Scope note:** this profile closes **§4 for the HEAVY contract only**. §2's kernel-time claim is a **LIGHT**
> (single-read, 125 B, high-rps) claim with a different denominator (sar %sys+%soft of the cpuset, not per-PID
> process kernel%) and a ~5.4× higher packet rate. It is closed separately in the companion run
> `../20260724-entity-read-by-id-3way-kernel-profile-LIGHT/`, which reproduces §2's 49–60 % band and reconciles
> both denominators. Do not read this heavy 38.4 % as evidence for the light §2 claim.

## Matched configuration (fairness)

All three stacks, identical: heap `-Xms256m -Xmx256m` (verified in each `constrained-launch-overlay`),
DB pool 32/32, target cpuset `0-1,8-9`, load cpuset `2-3,10-11`, 120 s warmup + 300 s measurement,
4 wrk threads / 128 conns, ParallelGC, 1024 MB `-XX:MaxRAM` budget, same pre-launched tuned PostgreSQL,
same `GET /api/v1/users` aggregate (10×10×10). Stacks: `community` = exeris-community-app;
`quarkus-tuned` = quarkus-benchmark-app-tuned (reactive vertx-pg); `quarkus` = quarkus-benchmark-app
(Hibernate + Agroal/pgjdbc) = "quarkus-hibernate".

## Durable metrics (measurement-window, warmup-free — `resource-metrics.json`)

| stack | rps | CPU/req | avg cores | RSS avg | RSS peak |
|---|---:|---:|---:|---:|---:|
| **exeris** | **14351** | **213 µs** | 3.06 | **301 MiB** | 306 MiB |
| quarkus-tuned | 14010 | 238 µs (+12%) | 3.34 | 359 MiB (+19%) | 376 MiB |
| quarkus-hibernate | 11528 | 322 µs (+51%) | 3.72 | 497 MiB (+65%) | 526 MiB |

Exeris leads all three durable axes: highest throughput, lowest CPU/req, lowest RSS. At matched 256 MB heap
the RSS gap is non-heap footprint: exeris ≈45 MiB non-heap vs qtuned ≈103 vs qhib ≈241 (Hibernate metamodel
/ class load / direct buffers).

## CPU breakdown (async-profiler `event=cpu`, kernel-inclusive; fractions are steady-state-dominated)

| stack | kernel% | user% | serializer (Jackson, incl) | db-client (incl) | syscalls/req |
|---|---:|---:|---:|---:|---:|
| exeris | 38.4% | 61.6% | **9.1%** | 48.7% | **37.4** |
| quarkus-tuned | 41.7% | 58.3% | 11.8% | 49.6% | 36.0 |
| quarkus-hibernate | 26.9% | 73.1% | 9.0% | 62.4% | 25.7 |

Derived (CPU/req × fraction — approximate, since fractions are warmup-inclusive):

| stack | kernel-CPU/req | user-CPU/req | µs per syscall |
|---|---:|---:|---:|
| exeris | **82 µs** | 131 µs | **2.19** |
| quarkus-tuned | 99 µs | 139 µs | 2.76 |
| quarkus-hibernate | 87 µs | 235 µs | 3.37 |

## Findings

1. **The "Jackson-3 tax" is refuted three ways.** (a) In-profile, exeris's serializer share is **9.1%**,
   *lower* than quarkus-tuned's Jackson-2 share (11.8%). (b) The `JacksonVersionSerializationBenchmark` JMH
   micro on the exact 10×10×10 payload: **Jackson 3 = 15.77 µs/op vs Jackson 2 = 17.78 µs/op (J3 ~11% faster)**
   at **identical** allocation (18005 vs 17998 B/op), byte-identical output (setup fail-closed). (c) Post
   DB-normalization exeris already leads heavy CPU/req. The serializer exeris bundles is faster, not a tax.

2. **The kernel blind spot is closed — and the mechanism is not "fewer syscalls".** Exeris does the *most*
   syscalls/req (37.4) yet spends the *least* absolute kernel-CPU/req (82 µs). Its syscalls are **cheaper**
   (2.19 µs each vs 2.76 / 3.37). Quarkus-hibernate does the *fewest* syscalls (25.7 — Hibernate batches
   round-trips) but pays it back in user-space ORM (73% user; top frames `StringLatin1.toLowerCase`,
   `String.equals`, `HashMap.getNode`, `StandardRowReader`) → worst CPU/req.

3. **On loopback, NET_RX softirq is inline in the worker's syscall context, not `ksoftirqd`.**
   System-wide `perf -a` attributes `__do_softirq` / `net_rx_action` / `__napi_poll` to the ForkJoinPool
   worker threads (~2% each × 4 ≈ 8% of one core); no `ksoftirqd` consumer appears. So the per-PID profile
   **already captured** the softirq — the "missing ~50%" was `%sys` the *user-space-only* sampler couldn't
   see, now resolved (syscall-entry path + `inet6_sendmsg` loopback TX + spinlocks + memcg + SRSO mitigation).

## Caveats (state up front)

- **Loopback kernel.** No NIC, no GSO/TSO, no IRQ coalescing; softirq runs inline (see finding 3). The
  three-way is fair (all identical loopback) but does **not** transfer to a real-network deployment — on a
  real NIC the RX softirq shifts to `ksoftirqd` and a per-PID profile would need the system-wide complement.
- **Exploratory, not gated.** `claim_scope=exploratory`; no `claim-status.json`/strict-gate artifacts, so no
  comparative *throughput* claim is made here. The rps values are context (they match prior aggregate runs).
- **Profiler fractions are warmup-inclusive** (agent from launch); the *durable* metrics are measurement-only.
  Derived kernel-/user-CPU/req multiply the two and are therefore approximate.
- **Per-stack DB drivers differ** (exeris pgjdbc / qtuned vertx-pg reactive / qhib Hibernate+pgjdbc). The
  syscalls/req and db-client% therefore reflect transport *and* query-plan strategy, not transport alone.
- **Durable CPU/req is measured under the profiler** (async-profiler agent attached). The light companion's
  `bottleneck-diagnostic/` quantifies the overhead as ~+3–8 µs/req (exeris-heavier), so these absolutes are
  slightly inflated and *under*-state exeris's lead; the clean gap is larger. The comparison is unaffected.
- **Throughput is target-CPU-bound** (2 physical cores, SMT-saturated; load-gen ~15–21 %, DB ~28–32 % — both
  have headroom). Confirmed in the light `bottleneck-diagnostic/`: `rps × CPU/req ≈ target cores`.

## Files
- `three-way-analysis.txt` — raw analyzer output (kernel%, syscalls/req, top kernel+user frames, system-wide).
- `<stack>/resource-metrics.json`, `result.json`, `syscalls-30s.txt`, `rps.txt` — per-stack evidence.
- `prof-3way-{bench,root,analyze}.sh` — exact orchestration + analysis scripts (reproducibility).
- JMH micro: `micro/jmh/src/main/java/eu/exeris/benchmarks/micro/json/JacksonVersionSerializationBenchmark.java`.
