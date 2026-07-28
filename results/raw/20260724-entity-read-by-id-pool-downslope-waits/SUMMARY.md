# Pool-curve downslope — measured wait profile (removes "inferred")

**Track:** Community / cross-runtime · **Protocol:** H1 · **Workload:** HEAVY aggregate (`GET /api/v1/users`)
**Scope:** `exploratory` · **Date:** 2026-07-25 · Host: Hetzner perf-box (target = 2 physical cores)

The aggregate pool curve is an inverted-U peaking at pool 32; **why** it declines past the peak was
previously inferred, not measured. This samples `pg_stat_activity` at 10 Hz (600 samples / 60 s) during the
measurement window of every leg and classifies each client backend by `wait_event_type` and `state`.
Pools 32 (peak), 64 and 128 (downslope), both arms, matched config (256 m heap, cpuset 0-1,8-9, 120 s
warmup + 300 s measure, 128 conns).

## Downslope reproduced

| pool | exeris rps | quarkus-tuned rps |
|---:|---:|---:|
| 32 | 14358 | 13877 |
| 64 | 14194 (−1.1 %) | 13640 (−1.7 %) |
| 128 | 13439 (−6.4 %) | 12830 (−7.5 %) |

## Wait profile (share of backend-samples)

| leg | Client / ClientRead | running (no wait) | **Lock** | LWLock | active | idle-in-txn | idle |
|---|---:|---:|---:|---:|---:|---:|---:|
| exeris p32 | 70.8 % | 29.2 % | **0.00 %** | 0.00 % | 25.9 % | 64.1 % | 10.0 % |
| exeris p64 | 88.6 % | 11.3 % | **0.00 %** | 0.04 % | 10.2 % | 80.4 % | 9.4 % |
| exeris p128 | 94.3 % | 5.6 % | **0.00 %** | 0.15 % | 5.1 % | 85.8 % | 9.1 % |
| qtuned p32 | 71.5 % | 28.4 % | **0.00 %** | 0.00 % | 24.8 % | 63.2 % | 12.0 % |
| qtuned p64 | 89.8 % | 10.1 % | **0.00 %** | 0.04 % | 9.4 % | 76.4 % | 14.3 % |
| qtuned p128 | 94.2 % | 5.6 % | **0.00 %** | 0.18 % | 5.0 % | 72.6 % | 22.4 % |

The only LWLock observed is `pg_stat_statements` (≤0.18 %) — i.e. the measurement extension itself.

## Findings

1. **The downslope is NOT database lock contention.** `Lock` is **exactly zero** at every pool size in both
   arms, and `LWLock` never exceeds 0.18 % (and is entirely `pg_stat_statements`, our own instrumentation).
   Row locks, buffer-mapping and other internal contention are all ruled out as the mechanism — measured,
   not inferred.

2. **The downslope is client-side: backends park waiting for the application.** `Client`/`ClientRead` — the
   backend waiting for the app to send its next command — rises **70.8 % → 88.6 % → 94.3 %** as the pool
   grows, while backends actually running collapse **29.2 % → 11.3 % → 5.6 %**. The dominant *state* is
   `idle in transaction` (64 % → 86 %), so connections sit parked inside open transactions between
   round-trips.

3. **Effective DB parallelism FALLS as the pool grows** — the mechanism in one number. Multiplying the pool
   size by the running fraction gives the backends actually executing at any instant:

   | pool | exeris running backends | quarkus-tuned |
   |---:|---:|---:|
   | 32 | 9.3 | 9.1 |
   | 64 | 7.2 | 6.5 |
   | 128 | 7.1 | 7.1 |

   Quadrupling the pool from 32 to 128 **reduces** concurrent DB work from ~9.3 to ~7.1 backends. Extra
   connections add no DB throughput; they add parked backends, each holding a transaction and a snapshot,
   and the bookkeeping costs the 6–8 % throughput seen above. This is the same mechanism in both arms, so
   it is a property of the workload/driver interaction, not of either runtime.

4. **Both arms behave near-identically on this axis** (ClientRead within 1.2 pp at every rung), which is
   itself the point: the pool downslope is not a differentiator between exeris and quarkus-tuned.

5. Secondary behavioural difference: at pool 128 exeris keeps 85.8 % of backends `idle in transaction` vs
   quarkus-tuned's 72.6 % (which instead shows 22.4 % plain `idle`) — quarkus-tuned returns connections to
   out-of-transaction idle more readily. It does not change the throughput outcome here.

## Correction to the raw output

The `mean_backends_per_sample` line in `pool-downslope-waits.txt` (6.39 / 12.23 / 24.44 …) is **wrong** and
should be ignored: `clock_timestamp()` is evaluated per-row inside `INSERT … SELECT … GROUP BY`, so
`count(DISTINCT ts)` counted *rows*, not *samples*. Dividing `sum(cnt)` by the true sample count (600)
gives **exactly 32.0 / 64.0 / 128.0** — the configured pool size, to three significant figures, in all six
legs. That exact landing is a useful self-check: the pool was fully established and the sampler observed
every backend on every sample. All percentages above are `sum(cnt)` ratios and are unaffected by the bug.

## Method notes
- `pg_stat_activity` is cached per transaction; the sampler calls `pg_stat_clear_snapshot()` before every
  sample. Validated before the run: 20 samples produced 20 distinct snapshots (without the call they would
  all be one stale snapshot and the probe would be silently worthless).
- One *aggregated* row per sample into an UNLOGGED table (~80 rows/s rather than ~1300) so the sampler does
  not perturb the workload it measures.

## Caveats
- n=1 per (arm, pool); the counterbalanced cell puts harness run-to-run noise at ~0.2 %, and the 6–8 %
  downslope is well outside that.
- Loopback; `ClientRead` here includes loopback round-trip, so absolute ClientRead share would differ on a
  real network — the *ranking across pool sizes* is the result, not the absolute percentage.
- HEAVY aggregate only. The light single-read pool optimum sits lower (~8) and is not covered here.
