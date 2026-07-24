# Heap counterfactual + lean-optimum — targeted single runs (2026-07-24)

Three constrained single-target runs (exeris-community, pinned target 0-1,8-9 / loadgen 2-3,10-11 / DB 4-7,12-15, tuned-PG reused) to convert two **inferred** claims into **measured** ones. n=1 each (directional single-variable tests, not publishable curves).

## (2-open) Balanced-heap counterfactual — exeris HEAVY tail is NOT GC-from-heap

`exp2open-256heap` and `exp2open-768heap`: exeris heavy aggregate, **open-loop wrk2 @10k** (so p99 = service time), 1024m budget, pool 16, admission ratio 32. **Only the heap differs** (256m = 0.25× vs 768m = 0.75×).

| heap | rps | p99 | RSS (smaps) |
|---|---:|---:|---:|
| 256m | 9,997 | **2.94 ms** | 247 MB |
| 768m | 9,997 | **2.90 ms** | 421 MB |

**p99 is heap-INDEPENDENT** (2.94 ≈ 2.90 ms) → exeris's heavy tail is **not** a GC-tail from the lean heap. The isolated open-loop tail is **~2.9 ms** — nothing like the 16 ms (pinned curve, measured *in a pair*) or 184 ms (mem-cpu sweep, *closed-loop*). Those were artifacts: co-residence/harness inflation and closed-loop queue-depth (Little's law + admission queueing), respectively — **neither was GC**. Heap moves **RSS only** (247→421 MB); exeris's RSS edge is the lean heap it can afford (off-heap; quarkus OOMs at 0.25×). Retracts the earlier "exeris GC-tail from 0.25× heap" framing.

## (3b) Lean-optimum stack — holds full speed, clean

`exp3b-lean-optimum-ratio32`: exeris light single-read, **128m budget / 16m heap / pool 8 / admission ratio 32**, closed-loop.

- rps **53,883**, err **0%**, cgroup **117 MiB** (< 128 budget, < matrix ~124), **rc=0, no post-measurement SIGTERM, no OOM**.
- Confirms the leanest sensible config holds ~full speed cleanly. Upgrades the 128m headline from "works, on the edge (one SIGTERM)" to "full speed, clean." Caveat: n=1; cgroup headroom modest (~7 MiB vs matrix, not the predicted 16).
- NOTE: an earlier run WITHOUT the admission ratio hit 88% error (ADR-035 shedding at pool 8 / 128 conns) — that was a harness-config miss, not a config failure; `ratio=32` fixes it (matches the connpool sweep).
