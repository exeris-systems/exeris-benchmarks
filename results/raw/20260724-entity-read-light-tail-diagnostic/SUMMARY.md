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
- **quarkus-tuned showed a single ~1 s stall — RARE, not systematic (see §7 cross-check below).** This run
  measured p99.9 = 913 ms, p99.99–max ≈ 1.0 s. §7's independent campaign at the *same* 30k rung (lean-co-resident
  pair-1, n=2) measured **p99.9 = 12.22 ms**, so this is **not** a reproducible per-run property. Arithmetic
  explains the shape: at 30k × 300 s = 9 M requests, one ~1 s stall delays every request scheduled during it
  (~30 k = 0.33 % > 0.1 %), which alone drives p99.9 → ~913 ms and p99.99/max → ~1.0 s. **One event in one
  window.** §7's 120 s windows are less likely to catch it. Frequency is unestablished (n=1); needs repeats.
- **quarkus-hibernate** here is comparable to exeris (p99.9 4.38 ms, max 35.7 ms) — notably better than §7's
  co-resident 19.91 ms at the same rung, consistent with §7's own co-residence thesis.

## Cross-validation against §7 (`20260723-155158-latency-curve-triad`)

§7's campaign **recorded `latency_p999_us` in every leaf but published p99 only**. Mining it gives an independent
check of this run — and an unpublished axis that strengthens §7's own light conclusion.

**§7 light p99.9 (ms), clean pairs (exeris & quarkus-tuned pair-1, hibernate pair-2; n=2 each):**

| offered rps | exeris | quarkus-tuned | quarkus-hibernate |
|---|---:|---:|---:|
| 6 k | 1.96 | 6.38 | 5.81 |
| 12 k | 1.98 | 8.34 | 9.86 |
| 18 k | 1.94 | 10.96 | 9.93 |
| 24 k | 2.52 | 10.61 | 11.05 |
| 30 k | 2.60 | 12.22 | 19.91 |

1. **Exeris: fully consistent.** §7 @30k p99 2.16 / p99.9 2.60 vs this run's p99 2.03 / p99.9 2.36 — agreement
   across different campaigns, windows (120 s vs 300 s) and heap configs, with this single-target run marginally
   tighter (no co-resident neighbor), exactly as §7's co-residence thesis predicts. This run also **extends the
   ladder past §7's 30 k top**: at 48 k (84 % of exeris's ceiling) p99.9 is still 4.12 ms — the flatness holds.
2. **Saturation reproduced near-exactly.** §7 probed Hibernate 44.3 k / Quarkus-tuned ~48 k / Exeris ~57 k; the
   clean diagnostic in the sibling bundle measured 44 334 / 48 492 / 57 830. Independent campaigns, ~1 % apart.
3. **p99.9 strengthens §7's headline.** §7's published p99 shows separation only emerging at 24–30 k
   (2.16 vs 5.21 vs 7.31). At p99.9 exeris is **flat 1.94–2.60 ms while both quarkus arms run 3–8× higher across
   the entire ladder, from 6 k up**. §7 under-states its own result by publishing p99 alone.
4. **This run's quarkus-tuned 913 ms is NOT corroborated** — §7 measures 12.22 ms at the same rung (see above).
   Treated as a rare single-event outlier, not a property.
5. **Heavy (context):** §7's heavy p99.9 at 10 k is exeris 37.3 (pair-1) / 40.4 (pair-2) vs quarkus-tuned 13.8 —
   exeris's near-ceiling heavy tail is worse at p99.9 in *both* pairs, and hibernate's pair-3 99.7 ms vs pair-2
   31.3 ms reproduces §7's "heavier neighbor → fatter tail" signature. Nothing here contradicts §7's reading that
   the 10 k column is co-residence-contaminated (its isolated counterfactual, p99 ~2.9 ms, remains the clean ref).

## Bottom line

The tail investigation **removes an exeris concern** and does **not** establish a quarkus one. Exeris's light tail
is the tightest measured — flat p99.9 ≈ 2–4 ms from 6 k to 48 k — driven only by benign young-GC pauses that a
larger heap does not improve; the alarming 148 ms closed-loop max was pure coordinated-omission amplification.
The quarkus-tuned ~1 s event seen here is a **single unreproduced outlier** that §7's independent data contradicts
at the same rung; it is logged as an open question, not a finding. The durable, cross-validated result is that
**exeris owns the light service-time tail at p99.9 by 3–8× across the whole ladder** — a stronger statement than
§7 published, and it comes from §7's own gated data.

## Caveats
- **Loopback** (no NIC/GSO/TSO/IRQ-coalescing); fair across stacks, doesn't transfer to real network.
- **Exploratory**, not gated. Open-loop rungs are sub-saturation (attained ≈ offered) so percentiles are true
  service time. Closed-loop maxes are CO-inflated and used only as the smoke alarm that started this.
- **quarkus-tuned 1.02 s is n=1 and contradicted by §7** (12.22 ms at the same rung, n=2). The measurement is
  valid (rate sustained, CO-free) but is a **single-event outlier, not a property** — one ~1 s stall in a 300 s
  window fully explains the percentile shape. Do not publish it as a quarkus tail claim. To settle frequency:
  repeat quarkus-tuned @30 k ×3 with longer windows + `-Xlog:gc,safepoint` and pool/timeout logging.
- **This run is truly single-target** (verified: one target-app per run, no co-locator) — the isolated reference
  §7 noted its pairwise harness could not provide. Levels are therefore not directly comparable to §7's
  co-resident leaves; the *ordering* and exeris's absolute values agree.

## Files
`STEP1-gc-classifier.txt`, `STEP2-openloop.txt`, `openloop-percentiles.txt`; per-rung `wrk2.log` + `result.json`
(c30/qt30/qh30/c48); `gc-*-head.log` + `gc-linecounts.txt`; `tail-classify.sh`, `tail-openloop.sh`.
