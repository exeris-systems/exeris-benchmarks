# quarkus-tuned ~1 s stall — three-variant probe (GC / safepoint / blocking wait)

**Scope:** `exploratory` · **Date:** 2026-07-28 · quarkus-tuned @30 k open-loop wrk2 (CO-free), pool 32,
cpuset 0-1,8-9, 300 s window, single-target. One run per heap (**256 m** and **768 m**) with
`-Xlog:gc,safepoint` **and** JFR (`settings=default`, which thresholds `ThreadPark` / `JavaMonitorWait` /
`SocketRead|Write` at ~20 ms and always records GC) — so all three candidate mechanisms are observable in
the same run at ~1 % overhead. Agroal pool DEBUG logging was rejected: at 30 k rps it floods and perturbs
the stall being measured.

## Headline: the stall did NOT occur in either run

| | 256 m | 768 m |
|---|---:|---:|
| attained rps / errors | 29992 / 0 | 29969 / 0 |
| p99.9 | **4.69 ms** | **5.51 ms** |
| p99.99 | 17.71 ms | 8.64 ms |
| max | 29.42 ms | 19.50 ms |

Both runs are clean. There is no ~900 ms p99.9 and no ~1 s max at either heap.

## Mechanism exclusions (these hold regardless, and are the durable result)

| variant | 256 m | 768 m | verdict |
|---|---:|---:|---|
| **1. GC pause** | max **16.86 ms** (3652 pauses, 2 Full) | max **19.37 ms** (1159 pauses, 2 Full) | **EXCLUDED** |
| **2. Safepoint (non-GC)** | max total stop **18.58 ms** | max **27.24 ms** | **EXCLUDED** |
| **3a. Socket wait** | `SocketRead` max **20.0 ms**, `SocketWrite` **20.8 ms** | 29.5 ms / 20.8 ms | **EXCLUDED** |
| **3b. Pool / lock wait** | `ThreadPark` 1190 ms, `JavaMonitorWait` 2000 ms | 1200 ms / 2020 ms | **idle, not request-path** |

The only ~1 s-magnitude events are `ThreadPark`, and inspecting them shows they are **not** stalls: the
1.19 s event is `eventThread = "agroal-11"`, parked on an `AbstractQueuedSynchronizer$ConditionObject`
with `timeout = 2 m 0 s` — Agroal **pool housekeeping** idling between maintenance passes. The
`JavaMonitorWait` durations are exactly 2000 ms, i.e. fixed timed polls, likewise housekeeping. And
decisively: these runs produced a 4.69 ms p99.9, so by construction nothing in them caused a user-visible
stall.

So GC, safepoint, socket and DB (excluded separately in
`../20260724-entity-read-deep-tail-slowquery/`) are all ruled out, as is a hard pool timeout (all runs have
zero errors — a timeout throws).

## Honest status of the stall claim: INTERMITTENT, and I have moved on this three times

Tally at the *same* configuration (quarkus-tuned, 256 m, 30 k, open-loop, 300 s, single-target):

| run | p99.9 | outcome |
|---|---:|---|
| `../20260724-entity-read-light-tail-diagnostic/` (qt30) | 913 ms | **stall** |
| `../20260724-entity-read-deep-tail-slowquery/` (qtunedDT) | 903 ms | **stall** |
| this probe (h256) | 4.69 ms | clean |
| this probe (h768, 768 m) | 5.51 ms | clean |
| §7 (120 s window, 0.75× budget heap, co-resident) | 12.22 ms | clean |

**2 of 3 runs at 256 m stalled; 1 did not.** The event is therefore **intermittent**, not deterministic —
and *not* explained by heap (256 m ran clean once, 768 m ran clean).

The claim history is worth recording as a caution: I called it a real finding (n=1), then retracted it as an
outlier when §7 disagreed (n=1 vs n=2), then un-retracted it as "reproducible" when a second run matched to
within 1 % (n=2), and it now fails to appear twice more. Every one of those turns was an over-reading of a
sample too small to support a directional claim. The defensible statement is narrow:

> quarkus-tuned exhibits an **intermittent** ~1 s tail event at 30 k open-loop, observed in 2 of 3 runs at
> 256 m heap. It is **not** GC, **not** a safepoint, **not** database-side, **not** a socket wait, and **not**
> a pool timeout. Its trigger is unidentified and its frequency is unestablished.

**Nothing about this belongs in a report as a quarkus property** until the frequency is measured.

## Protocol to settle it

The question is *frequency*, not existence. Run **n ≥ 5** at 256 m with JFR armed on every run, then compare
the JFR of a stalling run against a clean one — the mechanism will be whatever differs. JFR is already proven
non-preventing at ~1 % overhead here (both probe runs recorded cleanly), so it can be left on permanently.

## Caveats
- n=1 per heap in this probe; the exclusions are strong (a 900 ms effect cannot hide behind a 19 ms max GC
  pause) but the *clean* outcome is a single observation per heap.
- Loopback; exploratory scope, not gated.
- Raw `.jfr` deliberately **not committed** — public track blocks raw JFR (CLAUDE.md); only derived summaries
  are stored here.

## Files
`qtuned-stall-probe.txt` (raw incl. JFR event summary), per-heap `result.json` + `gc-safepoint-tail.log`,
`qtuned-stall.sh`.
