# Entity-read-by-id (LIGHT single-read) — three-way kernel-attribution profile

**Track:** Community / cross-runtime · **Protocol:** H1 · **Family:** Runtime · **Mode:** pure
**Scope:** `exploratory` (contract `claim_scope=descriptive_only`, `comparison_policy=forbidden`) — CPU
attribution, not a gated throughput claim. **Date:** 2026-07-24 · **Host:** Hetzner perf-box (AMD, 16L/8P)

## Why this exists — closes §2's blind spot on the RIGHT contract

The heavy profile (`../20260724-entity-read-by-id-3way-kernel-profile/`) closed §4 for **heavy**. But the
report's §2 kernel-time claim is a **light** (single-read, 125 B, high-rps) claim, and the denominators did
not line up: sar's 49–60 % is **%sys+%soft over the cpuset (wall-clock)**; the heavy per-PID 38 % is
**kernel share of process CPU-time**, at a 5.4× lower packet rate. This run profiles the light contract
(`GET /api/v1/user?id=1`) directly and adds an **mpstat cpuset probe** so both denominators sit together.

Config identical to heavy except the endpoint: `-Xms256m -Xmx256m`, pool 32, cpuset 0-1,8-9, load 2-3,10-11,
120 s warmup + 300 s measure, 128 conns, ParallelGC, 1024 MB MaxRAM, same tuned PostgreSQL.

## Results

| stack | rps | CPU/req | RSS avg | kernel% (per-PID) | %sys+%soft (mpstat = sar) | kernel-CPU/req | syscalls/req |
|---|---:|---:|---:|---:|---:|---:|---:|
| **exeris** | 54234 | **57.0 µs** | **284 MiB** | 65.1 % | **54.1 %** | **~38–40 µs** | 12.44 |
| quarkus-tuned | 47220 | 69.2 µs (+21 %) | 346 MiB (+22 %) | 59.6 % | 50.6 % | ~41–43 µs | 12.43 |
| quarkus-hibernate | 43206 | 76.9 µs (+35 %) | 430 MiB (+52 %) | 55.0 % | 47.9 % | ~42–44 µs | 12.46 |

mpstat cpuset split (4-CPU avg): exeris `%usr 24.2 / %sys 41.7 / %soft 12.5` (busy 78 %);
qtuned `32.0 / 34.1 / 16.5` (83 %); qhib `36.0 / 32.7 / 15.2` (84 %).
kernel-CPU/req computed two independent ways — mpstat `4·(%sys+%soft)·1e6/rps` = 39.9 / 42.9 / 44.3 µs, and
per-PID `CPU/req·kernel%` = 37.1 / 41.2 / 42.3 µs — **agree**: exeris lowest.

## Findings

1. **§2's regime reproduced.** mpstat %sys+%soft = 54.1 / 50.6 / 47.9 % — squarely in the report's 49–60 %
   band. This is the same measurement, same denominator (cpuset wall-clock, /proc/stat, like sar).

2. **Fraction vs absolute — the denominator trap, resolved.** Exeris has the **highest kernel fraction**
   (54.1 % mpstat, 65.1 % per-PID) yet the **lowest absolute kernel-CPU/req** (~38–40 µs) and lowest total
   CPU/req (57 µs). Its user-space is lean (light serialization 0.8 %, no ORM), so kernel is a larger slice
   of a smaller total. **A %sys+%soft *fraction* reading of §2 reads backwards** — exeris's fraction is the
   highest. The kernel-time claim must be stated **per request (absolute)**, where exeris does lead.

3. **Blind spot closed for light.** Kernel time is fully attributed: per-PID kernel% (65 %) + mpstat
   %sys+%soft (54 %) + inline softirq all measured; nothing hidden. Top kernel frames are the TCP path
   (`__tcp_transmit_skb`, `tcp_recvmsg_locked`, `tcp_sendmsg_locked`, `tcp_clean_rtx_queue`) + spinlocks +
   memcg + SRSO mitigation. At light, serialization is negligible (0.8 %) — the Jackson question is a
   heavy-only concern; here it does not arise.

4. **syscalls/req is identical (~12.4) across all three** — single-read = one DB round-trip + HTTP + epoll,
   the same for every stack. Unlike heavy (37 / 36 / 26), syscall *count* is not a differentiator at light;
   the per-request kernel-CPU difference comes from per-syscall cost, not count.

## Headline +39 % — reconciled on clean (profiler-free) numbers

The profiled CPU/req above is inflated by async-profiler overhead. A **clean re-run** (no agent, `mpstat -P
ALL`; see `bottleneck-diagnostic/`) gives total CPU/req **52.8 / 66.9 / 74.6 µs** (exeris / qtuned / qhib):

- **Clean total-CPU/req gap exeris → hibernate = +41 %** — this *reproduces* §2's **+39 %**. The headline is a
  **total-CPU/req** advantage over hibernate, **not** a kernel-time figure.
- **Clean kernel-CPU/req gap is only ~15–16 %** (mpstat: 35.3 / 40.7 / 41.0 µs). The %sys+%soft *fraction* is
  highest for exeris (51 %). §2 should therefore read "exeris uses ~41 % less **total** CPU/req than hibernate",
  not "less kernel time".
- **Profiler overhead:** +4.2 µs on exeris (~8 %), +2.3 µs on quarkus (~3 %) — it slightly *under*-stated
  exeris's lead, so the clean gap is larger than the profiled one. The profiled table is directionally correct;
  the clean numbers are the honest absolutes.

## Bottleneck: target-CPU-bound (load-gen and DB have headroom)

Clean `mpstat -P ALL` during measurement (`bottleneck-diagnostic/`), busy per cpuset:

| cpuset (phys cores) | exeris | quarkus-tuned | quarkus-hibernate |
|---|---|---|---|
| **target** (0,1 = 4 SMT thr) | 76.7 % / 3.07c | 81.6 % / 3.26c | 83.1 % / 3.32c |
| **load-gen** (2,3) | 21.1 % / 0.84c | 16.3 % / 0.65c | 14.6 % / 0.58c |
| **DB** (postgres, 4-7,12-15) | 29.6 % / 2.37c | 31.6 % / 2.53c | 28.1 % / 2.25c |

- **Target** = 2 physical cores (topology: cpu 0&8→core0, 1&9→core1), SMT-saturated at 77–83 % logical — the limiter.
- **Load-gen** 15–21 % (0.6–0.8 c): wrk is *not* the cap (if it were, all three would share one rps ceiling).
- **DB** 28–32 % (2.2–2.5 c of 4 physical): headroom; not the cap.
- **Clean identity holds:** `rps × CPU/req` = 3.05 / 3.24 / 3.31 cores ≈ target busy ⇒ **rps = target_cores /
  CPU_per_req**. The rps ranking is pure target-CPU efficiency, not a load-gen/DB artefact.
- **"Slower but not heavier" resolved:** quarkus's lower rps is its higher CPU/req on the fixed 2 cores; the rps
  *level* (vs the ~79 k promotion light) is the 4-vCPU pin, not extra per-request work. wrk latency corroborates
  (closed-loop, 128 conns): exeris mean 5.59 ms with a fat tail (max 163 ms) vs qhib 3.62 ms (max 32 ms) — exeris's
  bulk is faster (higher throughput) with an occasional tail, not a uniformly slower pipeline.
  **That closed-loop tail is resolved in `../20260724-entity-read-light-tail-diagnostic/`:** it is coordinated-omission
  amplification, not a real stall — CO-free (open-loop) exeris has the *tightest* tail of the three (p99.9 2.36 ms,
  max 25.6 ms) and its ~22 ms extreme is just the occasional young-GC pause (heap-independent). Cross-validated
  against §7 (`20260723-155158-latency-curve-triad`), whose unpublished p99.9 axis shows exeris flat 1.94–2.60 ms
  vs both quarkus arms 3–8× higher across the whole ladder. (A one-off ~1 s quarkus-tuned stall in that run is a
  single-event outlier — §7 measures 12.22 ms at the same rung — not a quarkus tail claim.)

## Loopback (one sentence, as required)

**Inline softirq attribution is a property of loopback, not Linux in general:** here `__do_softirq` /
`net_rx_action` / `__napi_poll` run in the worker/vert.x thread's syscall context (3.1–3.7 % each, higher
than heavy's ~2 %) with no `ksoftirqd` consumer — on a real NIC the RX softirq moves to `ksoftirqd` and a
per-PID profile would miss it, requiring the system-wide complement.

## Heavy ↔ light contrast (same stacks, same infra)
- kernel% (exeris): heavy 38 % → light **65 %** — light IS the kernel-dominated regime (5.4× packet rate).
- syscalls/req (exeris): heavy 37.4 → light 12.4 (aggregate multi-query vs single round-trip).
- serializer share (exeris): heavy 9.1 % → light 0.8 % (9.2 KB vs 125 B payload).

## Files
`three-way-light-analysis.txt`; per-stack `resource-metrics.json` / `result.json` / `syscalls-30s.txt` /
`mpstat-cpuset-30s.txt` / `rps.txt`; `prof-3wayL-{bench,root,analyze}.sh`.
