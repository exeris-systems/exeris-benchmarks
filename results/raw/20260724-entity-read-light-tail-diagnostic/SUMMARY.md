# Entity-read-by-id (LIGHT) — tail diagnostic: classify, then measure CO-free

**Track:** Community / cross-runtime · **Protocol:** H1 · **Family:** Runtime · **Mode:** pure · **Scope:** `exploratory`
**Date:** 2026-07-24 · **Host:** Hetzner perf-box (AMD, 16L/8P; target = 2 physical cores 0,1 SMT)

## Why this exists

The light closed-loop run showed exeris with a **147–163 ms max** at a 125-byte single-row read — a 5× outlier
vs quarkus-hibernate's 32 ms. On a workload that trivial, a spike that large would be a runtime scheduling/
memory problem, not the work. Method (per review): **classify the cause first (GC vs stall), then measure the
real tail open-loop** — closed-loop max is coordinated-omission-inflated (one stall backs up the queue), a smoke
alarm, not a measurement.

## Step 1 — classifier (`-Xlog:gc,safepoint`, closed-loop, 256m vs 768m)

| heap | rps | closed-loop max | p99 (closed) | **max GC pause** | Full GCs |
|---|---:|---:|---:|---:|---:|
| 256m | 56929 | 147.7 ms | 37.2 ms | **23.1 ms** | 0 |
| 768m | 57454 | 127.4 ms | 38.5 ms | **27.9 ms** | 0 |

**Not GC, not heap.** Max GC pause (23–28 ms) ≪ closed-loop max (128–148 ms), 0 Full GCs, longest safepoint of
*any* kind ~28 ms. Tripling the heap left the tail unchanged (148→127 ms noise) and p99 identical (37→38 ms) —
only the minor-GC *count* dropped (1466→448). **"exeris lean-heap GC-tail" is falsified in a second, independent
regime** (light / closed-loop / SMT-saturated), alongside §7's heavy/open-loop. The RSS trade (§5) is clean.

## Step 2 — the real tail (open-loop wrk2, fixed `-R`, CO-free service time)

All rungs valid (attained ≈ offered: 29969 / 29992 / 29969 / 47987 rps).

| percentile | **exeris @30k** | quarkus-tuned @30k | quarkus-hibernate @30k | exeris @48k (near sat.) |
|---|---:|---:|---:|---:|
| p50 | 0.95 ms | 1.32 ms | 1.32 ms | 1.24 ms |
| p99 | 2.03 ms | 4.36 ms | 2.99 ms | 2.90 ms |
| **p99.9** | **2.36 ms** | **913 ms** | 4.38 ms | 4.12 ms |
| **p99.99** | **5.03 ms** | **1.00 s** | 21.5 ms | 22.7 ms |
| p99.999 | 22.4 ms | 1.01 s | 33.2 ms | 35.2 ms |
| max | 25.6 ms | 1.02 s | 35.7 ms | 45.4 ms |

**The closed-loop reading wasn't just inflated — it was backwards.** CO-free:

- **Exeris has the best tail of the three.** p99.9 = 2.36 ms, p99.99 = 5.03 ms at 30k; even at 48k (84 % of its
  ~57k ceiling) it stays tight (p99.9 4.12 ms, max 45 ms) — graceful degradation toward saturation. The closed-loop
  148 ms was pure coordinated-omission amplification of exeris's ~22 ms real extreme, which is itself just the
  occasional ~23 ms young-GC pause (matches Step 1) — benign and heap-independent. **No 3am problem in exeris.**
- **quarkus-tuned has the real tail problem:** p99.9 = **913 ms**, p99.99–max ≈ **1.0 s**, at the *same* sustained
  30k. ~390× exeris's p99.9. A ~1-second stall hitting ~0.1 % of requests — invisible to closed-loop wrk (CO
  scrambles it) and to the CPU/throughput metrics. The ~1 s roundness hints at a timeout (pool/retry/event-loop
  block in the reactive stack), but the **cause is a hypothesis** — n=1, warrants a repeat + its own probe.
- **quarkus-hibernate** is comparable to exeris (p99.9 4.38 ms, max 35.7 ms), slightly worse at the extreme.

## Bottom line

The tail investigation *removes* an exeris concern and *surfaces* a quarkus-tuned one. Exeris's light tail is the
tightest measured, driven only by benign young-GC pauses that a larger heap doesn't improve. The genuine
"engine does something bad under load" case is quarkus-tuned's ~1 s p99.9 — the one item in this series that
would cost at 3am — and it only shows up under CO-free open-loop measurement.

## Caveats
- **Loopback** (no NIC/GSO/TSO/IRQ-coalescing); fair across stacks, doesn't transfer to real network.
- **Exploratory**, not gated. Open-loop rungs are sub-saturation (attained ≈ offered) so percentiles are true
  service time. Closed-loop maxes are CO-inflated and used only as the smoke alarm that started this.
- **quarkus-tuned 1.02 s is n=1** — the measurement is valid (rate sustained) but the *cause* is unproven; needs a
  repeat + targeted probe (GC log / pool-timeout log / event-loop stall) before it's a claim.

## Files
`STEP1-gc-classifier.txt`, `STEP2-openloop.txt`, `openloop-percentiles.txt`; per-rung `wrk2.log` + `result.json`
(c30/qt30/qh30/c48); `gc-*-head.log` + `gc-linecounts.txt`; `tail-classify.sh`, `tail-openloop.sh`.
