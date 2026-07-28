# Counterbalanced cell (quarkus first) — order-confound check

**Scope:** `exploratory` · **Date:** 2026-07-25 · Light single-read, clean (no profiler), `mpstat -P ALL`.
Identical in every respect to `../bottleneck-diagnostic/` (256 m heap, pool 32, cpuset 0-1,8-9 / 2-3,10-11,
120 s warmup + 300 s measure, 128 conns, ParallelGC) **except the execution order**.

Every prior 3-way ran `community → quarkus-tuned → quarkus-hibernate`, so target identity was confounded
with slot position (DB page-cache warmth, PG stats, thermal drift across the ~21 min sequence). This cell
runs the reverse, `quarkus-hibernate → quarkus-tuned → community`, to get the **direction and magnitude**
of that confound.

## Result

| stack | forward cell (slot) | reverse cell (slot) | Δ rps | Δ CPU/req | Δ RSS |
|---|---|---|---:|---:|---:|
| **exeris** | (1) 57830 rps / 52.8 µs / 229232 KB | (3) 57058 / 53.7 / 229288 | −1.33 % | +1.70 % | **+0.02 %** |
| **quarkus-tuned** *(control)* | (2) 48492 / 66.9 / 286881 | (2) 48425 / 67.1 / 277676 | **−0.14 %** | **+0.30 %** | −3.2 % |
| **quarkus-hibernate** | (3) 44334 / 74.6 / 328340 | (1) 43547 / 76.2 / 372654 | −1.78 % | +2.14 % | +13.5 % |

## Findings

1. **Order is not the confound — and the design proves it rather than assuming it.** All three stacks moved
   in the *same* direction in the reverse cell (rps slightly down, CPU/req slightly up), **including
   quarkus-tuned, which held slot 2 in both cells**. If slot position drove the numbers, the control would be
   unchanged and the two stacks that swapped slots (exeris 1→3, hibernate 3→1) would move in *opposite*
   directions. They did not: both got slightly worse regardless of which way they moved. The observed delta
   is therefore a small global cell-to-cell offset, not an order effect.

2. **quarkus-tuned is an unintended internal control** — same slot, same config, different cell — and it
   reproduces to **0.14 % rps / 0.30 % CPU/req**. That is the run-to-run reproducibility of this harness.

3. **Ranking fully preserved** on every axis, in both orders: rps exeris > quarkus-tuned > hibernate;
   CPU/req and RSS exeris < quarkus-tuned < hibernate.

4. **Headline magnitudes reproduce.** exeris-vs-hibernate CPU/req: **+41.3 % forward → +41.9 % reverse**
   (the reconciled "+39 %/+41 %" total-CPU claim holds under counterbalancing). exeris-vs-quarkus-tuned:
   +26.7 % → +25.0 %.

5. **Order-attributable effect is bounded at ≈2 %**, against the 25–42 % effects being claimed — an order of
   magnitude smaller, and partly noise (the control moved 0.3 % on its own).

6. **RSS stability differs by stack:** exeris is essentially identical across cells (229232 → 229288 KB,
   +0.02 %); hibernate is the most variable (+13.5 %), consistent with JIT/metaspace warmup sensitivity.
   The RSS ordering is unaffected.

## Caveat

n=1 per stack per cell; the control bounds noise at ~0.2–0.3 %, so per-stack deltas of 1–2 % are near but
not below that floor — they are *small*, not *zero*. The claim supported is "order does not change the
ranking or the magnitude of the effects", not "the two cells are bit-identical". Loopback caveat as elsewhere.

## Files
`counterbalanced-cell.txt` (raw), per-stack `resource-metrics.json` / `result.json` / `mpstat-ALL-30s.txt`,
`counterbalance.sh` (exact script). Forward cell for comparison: `../bottleneck-diagnostic/`.
