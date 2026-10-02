# Loom carrier scheduler — pilot, 2026-09-27

**Status: pilot. Not evidence.** Nothing in this directory is claim-eligible under
[`docs/status-and-claim-eligibility.md`](../../../docs/status-and-claim-eligibility.md), and no
number from it may be quoted as a result. It is kept because it shaped the methodology of the
`research/loom-carrier-scheduler` track, and because a later campaign should be able to show what
changed relative to it.

Track: Community. Protocol: H1 cleartext. Family: Runtime. Mode: exploratory.

## What was run

A custom `java.lang.Thread.VirtualThreadScheduler` (`ExerisCarrierScheduler`, per-carrier MPSC
queues, no work-stealing) against the stock `ForkJoinPool` scheduler, on a Loom EA build
(`28-testing`, branch `fibers`), on a 6-core desktop host (AMD Ryzen 5 5600, single CCX).

| Run | Configs | Shape |
|:----|:--------|:------|
| `run-20260927-121644` … `run-20260927-152345` | A, B, C, D, E | Earlier arm set, before the GC/JIT threads were pinned off the carrier CPUs. |
| `run-20260927-184543`, `run-20260927-185018` | A, A_iso, C_iso, D | Saturation only, partial. |
| `run-20260927-185119` | A, A_iso, C_iso, D | Closed-loop saturation (`wrk`) + open-loop sweep (`wrk2`) at 50/70/85/90/95 % of A's median saturation, 3 reps each: 72 trials. This is the run the loom-dev draft report quotes. |
| `loomdev-cache-sweep/run-20260927-194947` | A, A_iso, C_iso, D | `/delayed` (20 ms, 8 KB touched per request) at a fixed 3,000 req/s, 100 / 1,000 / 10,000 connections. |

Arms: **A** stock FJP, unconstrained; **A_iso** stock FJP on CPUs {2,3}, JVM auxiliary threads on
{0,1,6,7}; **C_iso** custom scheduler, carriers floating on {2,3}; **D** custom scheduler, carrier 0
pinned to CPU 2 and carrier 1 to CPU 3. All arms use 2 carriers. Load generator on {4,5,10,11}.

Each `REPORT-*.md` / `REPORT-*.json` was generated from the per-trial logs of the run with the same
timestamp. The per-trial logs (`*-server.log`, `*-loadgen.log`, `*-pidstat.log`,
`*-affinity.log`) are not committed (`*.log` is ignored repository-wide) and exist only on the
host that produced them.

## Why it is not evidence

1. **The code under test is not identified.** The scripts put
   `exeris-kernel/*/target/classes` of a local working tree on the classpath. No run records a
   kernel commit SHA, whether that tree was clean, or the JDK build string. That is
   `reproducibility_status: incomplete_metadata`.
2. **n = 3 per cell, with one failed trial.** At 70 % load one A trial delivered 126,825 of
   141,796 req/s, and its p99 (3,100 ms) is the headline "worst p99" for A. A failed trial is a
   failed trial, not a latency observation.
3. **The cache sweep at 10,000 connections did not run at its target rate.** It delivered about
   272 of 3,000 req/s: `wrk2` opens connections 5 ms apart per thread, so 10,000 connections on 2
   threads take about 25 s to establish. At 1,000 connections the deficit is about 11 %. Those
   cells measure the ramp, not the scheduler.
4. **The cache sweep could not exercise the cache hierarchy at any connection count.** At a fixed
   3,000 req/s and 20 ms delay, about 60 requests are in flight regardless of the connection count
   (Little's law), about 480 KB of touched state, which fits in one core's L2.
5. **The host was not partitioned.** No `isolcpus`; the reactor CPUs saw 17–31 % run-queue wait
   from processes outside the JVM.
6. **The carrier idle path is suspect.** The carrier loop shares one state word between its own
   park handshake and the poller's, and a state left `PARKED` by the poller stops the carrier from
   parking at all. The high carrier `%usr` at low load is consistent with that, not yet measured
   against it.

## What it is useful for

- The arm set (A / A_iso / C_iso / D) separates CPU isolation from scheduler design from carrier
  pinning, and the re-run keeps it.
- Carrier run-queue wait from `pidstat -t` was 12–25 % for floating carriers and 0.3–0.5 % for
  pinned carriers. That is a mechanism to confirm with `perf sched`, not a finding.
- The apparent latency cliff at 90–95 % load in the A–E runs disappeared once JVM auxiliary
  threads were kept off the carrier CPUs. Any re-run has to verify thread placement per trial.

## Files

- `scripts/run-loom-community-loomdev-matrix.sh`, `scripts/run-loom-cache-locality-sweep.sh`:
  the harness as it ran. Both build a classpath from a sibling `exeris-kernel` checkout.
- `app/exeris-h1-locality-app/`: the H1 target application as it ran.
