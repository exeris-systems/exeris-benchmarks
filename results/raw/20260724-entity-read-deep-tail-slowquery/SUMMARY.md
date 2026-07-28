# Deep tail — `log_min_duration_statement=20ms` discriminator

**Scope:** `exploratory` · **Date:** 2026-07-28 · Light single-read, open-loop wrk2 (CO-free), matched 256 m
heap, pool 32, cpuset 0-1,8-9. PostgreSQL logged every statement slower than 20 ms for the whole run.

**Question:** are deep-tail events (p99.9+) database-side or runtime-side? The app-side CO-free percentiles
and the PG slow-statement census come from the same window, so they can be compared directly.

**Config hygiene:** `ALTER DATABASE` scope (never a global/system setting), applied before target start
(it only affects new connections), `RESET` trap on every exit path. **Verified reverted** after the run:
`log_min_duration_statement = -1 (source: default)`.

## Result

| | exeris @48 k | quarkus-tuned @30 k |
|---|---:|---:|
| attained rps | 47987 | 29969 |
| p50 | 1.25 ms | 1.28 ms |
| p99 | 2.90 ms | 3.87 ms |
| **p99.9** | **3.48 ms** | **903.17 ms** |
| p99.99 | 9.61 ms | 1.00 s |
| max | 26.06 ms | 1.01 s |
| **PG statements > 20 ms in the workload** | **0** | **0** |

## Findings

1. **The deep tail is NOT database-side — for either stack.** PostgreSQL logged **zero** workload statements
   above 20 ms in both runs. The only four slow lines per run are `INSERT`s into `friendships`,
   `user_interests` and `user_purchase_history` occurring ~1 s after launch — i.e. seeding, during setup,
   long before the measurement window. The measured endpoint (`GET /api/v1/user?id=1`) is **read-only and
   issues no INSERTs at all**, so those lines cannot belong to the workload regardless of timing.
   Meanwhile the app saw tail events of 26 ms (exeris) and 1.01 s (quarkus-tuned). Both tails are entirely
   runtime/app-side. This is the discriminator firing cleanly in the negative direction.

2. **The quarkus-tuned ~1 s stall REPRODUCED — the earlier "single-event outlier" retraction was wrong.**
   Two independent runs at this configuration now agree to within ~1 %:

   | run | p99.9 | p99.99 | max |
   |---|---:|---:|---:|
   | `../20260724-entity-read-light-tail-diagnostic/` | 913.41 ms | 1.00 s | 1.02 s |
   | this run | 903.17 ms | 1.00 s | 1.01 s |

   A random one-off would not land twice within 1 %. The stall is **reproducible at this configuration**
   (n=2). The earlier arithmetic — one ~1 s stall delays every request scheduled during it and by itself
   drives p99.9 to ~900 ms — still correctly describes the *shape*; what was wrong was concluding the event
   was random rather than systematic.

3. **exeris is clean at 84 % of its ceiling:** p99.9 = 3.48 ms, max 26 ms at 48 k, with zero DB contribution.

## Why §7 does not see this (and why that is not a contradiction)

§7 measures quarkus-tuned p99.9 = 12.22 ms at the same 30 k rung. Three configuration differences separate
the runs, and the first is the leading candidate:

- **Heap.** This series runs quarkus-tuned at **256 m, matched to exeris for fairness**; §7 retained the heap
  asymmetry (quarkus at 0.75× budget). A tighter heap is the obvious way to manufacture a ~1 s stall.
- **Window.** 300 s here vs §7's 120 s — a stall occurring roughly once per several minutes is much easier
  to miss in 120 s.
- **Co-residence.** §7 is pairwise; this is truly single-target.

**Fairness note that must travel with this result:** the matched-heap choice is *fair to exeris*, but it may
itself be what produces the quarkus-tuned stall. Stating "quarkus-tuned has a 1 s tail" without the heap
qualifier would be exactly the kind of un-equalized-layer claim this series has repeatedly corrected. The
supported statement is: **at matched 256 m heap, quarkus-tuned exhibits a reproducible ~1 s stall at 30 k
open-loop that is not database-side.**

## Open, and cheap to close

Cause is still unproven. The decisive test is one run: quarkus-tuned @30 k open-loop with
`-Xlog:gc,safepoint`, at 256 m and again at 768 m. If a ~1 s pause appears at 256 m and vanishes at 768 m,
the stall is heap-driven and the §7 discrepancy is fully explained; if it appears at both, it is a runtime
property independent of heap. (The earlier classifier ran `-Xlog` on *exeris* only — quarkus-tuned has never
been GC-logged.)

## Caveats
- Loopback; exploratory scope, not gated.
- n=2 for the stall's existence; its *frequency* per unit time is still unmeasured.
- The 20 ms threshold cannot see DB-side events shorter than 20 ms, but neither tail is explained by
  sub-20 ms database work (exeris's own max is 26 ms and quarkus-tuned's is 1.01 s).

## Files
`deep-tail-slowquery.txt` (raw, incl. the revert verification), per-arm `result.json` + `wrk2.log`,
`deeptail-slowquery.sh`.
