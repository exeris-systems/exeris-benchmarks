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

## Honesty flag on the headline +39 %

At this operating point I measure a **kernel-CPU/req** gap of ~7–14 % (exeris lowest) and a **total CPU/req**
gap of ~21–35 % vs quarkus. The report's headline **+39 %** is **not reproduced here** — it is closest to
the total-CPU/req gap vs hibernate (+35 %), not the pure kernel gap. Likely a different operating point
(the promotion light ran ~79 k rps vs 54 k here). **Recommend restating §2 as an absolute per-request figure
with its exact config**, since (a) the %sys+%soft fraction alone favours quarkus, and (b) the kernel-only gap
is ~10 %, not 39 %.

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
