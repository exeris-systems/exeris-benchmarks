# Syscall mix & futex — the mechanism behind §4's "cheaper syscalls, not fewer"

**Scope:** `exploratory` · **Date:** 2026-07-28 · HEAVY aggregate, matched config (1024 MB budget / 256 m
heap / pool 32 / cpuset 0-1,8-9). `perf trace -s -p <target> -- sleep 20` during the measurement window,
all three stacks. Root-side probe (the `raw_syscalls` tracepoints are root-only); target runs as bench.

§4 established that exeris issues the **most** syscalls/req (37.4 vs 36.0 vs 25.7) yet spends the **least**
kernel-CPU/req (~82 vs 99 vs 87 µs) — a statement about per-syscall *cost*, derived as a quotient of two
separately-measured quantities. This probe measures the syscall **mix and per-call duration directly**, and
tests the obvious mechanism hypothesis: that quarkus pays more in **futex** (thread coordination / lock
contention).

## Aggregate over all threads (20 s window)

| stack | total syscalls | ratio | futex calls | futex % | `read` µs/call | `write` µs/call | **non-blocking µs/req** |
|---|---:|---:|---:|---:|---:|---:|---:|
| exeris | 6,960,236 | 1.48 | 1,151,692 | 16.5 % | **3.13** | 10.56 | **85.7** |
| quarkus-tuned | 6,454,603 | 1.37 | 786,799 | 12.2 % | 3.68 | 9.90 | 95.2 |
| quarkus-hibernate | 4,714,722 | 1.00 | 663,574 | 14.1 % | 3.66 | 10.36 | 91.2 |

## Findings

1. **§4's syscall-volume ranking is independently reproduced.** perf trace gives a volume ratio of
   **1.48 / 1.37 / 1.00**; §4's `perf stat raw_syscalls` gave **1.46 / 1.40 / 1.00**. Two different tools,
   two different runs, the same answer — exeris issues the most syscalls, hibernate the fewest.

2. **§4's derived kernel-CPU/req is confirmed by direct measurement.** Summing the durations of the
   *non-blocking* syscalls per request gives **85.7 / 95.2 / 91.2 µs** (exeris / quarkus-tuned /
   quarkus-hibernate), against §4's derived **82 / 99 / 87 µs**. Same ordering (exeris < hibernate <
   quarkus-tuned), same magnitude — but arrived at by summing measured syscall durations rather than by
   multiplying a profiler fraction against CPU/req. **The "cheaper syscalls, not fewer" thesis now rests on
   two independent methods.**

3. **The futex hypothesis is REFUTED.** exeris makes the **most** futex calls in absolute terms
   (1.15 M vs 787 k vs 664 k) and has the highest futex share (16.5 %). Futex is not what makes quarkus's
   syscalls more expensive — if anything exeris coordinates threads more often, and still costs less overall.
   (futex *errors* — mostly `EAGAIN`/`ETIMEDOUT` — do rise across the stacks: 20.7 k / 30.8 k / 41.3 k.)

4. **The mechanism is the per-call cost of `read`, the dominant syscall.** `read` is 30–37 % of all calls,
   and exeris pays **3.13 µs** against quarkus's **3.66–3.68 µs** — ~15 % cheaper on the single largest
   category. The advantage is *not* uniform: exeris's `write` is slightly **more** expensive
   (10.56 vs 9.90 µs for quarkus-tuned). So §4's claim is better stated as "cheaper on the dominant syscall",
   not "cheaper on every syscall".

5. **Half of all `read` calls return `EAGAIN`** (exeris 50 %, quarkus-tuned 49 %, hibernate 43 %) —
   speculative non-blocking reads that find nothing, normal for NIO event loops but a large share of total
   syscall volume in every stack.

## Methodological caveat that governs how this table may be read

**`futex` and `epoll_wait` "total" time is wall-clock BLOCKED time, not kernel CPU.** Each stack shows
~266–282 s of futex time inside a 20 s window — impossible as CPU, and simply the sum of ~20 threads parked
waiting for work. Treating it as cost would invert every conclusion here. Only the non-blocking syscalls
(`read` / `write` / `epoll_ctl` / `sendto` / `recvfrom` / `writev`) have duration ≈ CPU, which is why the
per-request figure in the table is built from those alone.

## Caveats
- **Absolute syscalls/req from this probe are not comparable to §4's.** `perf trace` traces every syscall
  (~350 k/s here), which both depresses throughput during its window and can drop events; and requests-in-
  window is estimated as `rps × 20 s`, an upper bound. **Ratios and mix are reliable; absolute counts are not.**
  The measured rps (14293 / 13736 / 11549) is likewise depressed relative to clean runs.
- n=1 per stack, 20 s window. Loopback; exploratory scope, not gated.
- An earlier extraction of this same data was truncated by a `head -25` and showed only JVM housekeeping
  threads (`VM Thread` is 0.1 % of events). The tables above are re-derived from the complete saved traces
  across all 20–24 thread blocks; no re-run was needed.

## Files
`perf-trace-{exeris,qtuned,qhib}.txt` (complete raw summaries, all thread blocks), `result-*.json`,
`futex-bench.sh`, `futex-root.sh`.
