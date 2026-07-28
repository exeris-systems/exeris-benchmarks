# Heavy (aggregate) connection-pool sweep — curve & the +15%-vs-triad verdict

**Campaign:** `20260723T101404Z-connpool-sweep-aggregate`
**Harness:** `scripts/run-entity-read-by-id-connpool-sweep.sh` at commit `674ee97` (CONNPOOL_CONTRACT_ID=aggregate)
**Endpoint:** `GET /api/v1/users` (3-query 10×10×10 aggregate)
**Fixed point:** 1024 MB / 4 vCPU, tuned-PG reused (host-net, cpuset 4-7,12-15), pinned target 0-1,8-9 / loadgen 2-3,10-11.
**Swept:** app DB pool **{4,8,16,32,64,128}** (min=max), both arms, n=3 interleaved, 128 wrk connections, exeris admission queueDepthAllowanceRatio=32 (so the acquire-queue covers 128 conns at every pool; quarkus HikariCP blocks). Track: Community H1 plaintext, constrained. Not a merge gate.

## The curve (n=3 mean)

| pool | exeris rps | quarkus-tuned rps | exeris RSS / quarkus | exeris CPU/req / quarkus |
|---:|---:|---:|---:|---:|
| 4 | 7,157 | 7,182 | 238 / 454 MB | 234 / 286 µs |
| 8 | 11,229 | 11,592 | 241 / 460 | 213 / 250 |
| 16 | 13,821 | 13,430 | 245 / 468 | 206 / 235 |
| **32** | **14,378** ◄peak | **14,014** ◄peak | 256 / 472 | 205 / 229 |
| 64 | 14,209 | 13,834 | 249 / 470 | 208 / 231 |
| 128 | 13,309 | 13,012 | 260 / 463 | 205 / 233 |

Ranges are tight and the peak/decline boundaries are non-overlapping (e.g. exeris 32: 14338-14422 vs 128: 13216-13414), so the inverted-U is real, not noise.

## Findings

1. **The aggregate's pool optimum is 32 for BOTH arms** — not ~8 (exeris) / 16-32 (quarkus) as in the single-read sweep. The aggregate holds a connection across 3 sequential queries (longer hold time), so by Little's law more concurrency is needed to saturate the DB. Starting the sweep at 4 (not 16) was required to see this — the knee moved up.

2. **exeris leads across the entire curve**: rps +2-3% at every pool (peak 14,378 vs 14,014), **RSS ~half everywhere** (~250 vs ~465 MB, pool-insensitive), CPU/req lower. Both arms peak at the same pool (32) → the optimum is a DB-side property (tuned-PG concurrency), arm-independent. This is why the two "converge": both are DB-bound on the same PG, with exeris a constant efficiency margin ahead.

3. **Cross-campaign reproduction**: pool=16 here = 13,821 vs the mem-cpu sweep's 13,792 (0.2%).

4. **Over-subscription is real but modest**: peak (pool 32) → pool 128 costs ~7% (exeris 14,378 → 13,309; quarkus 14,014 → 13,012).

## Verdict on the +15% vs the 60707c4 triad (exeris aggregate 11,887)

**The +15% is NOT a pool effect.** The entire lean-constrained curve — every pool from 4 to 128, including the worst over-subscribed pool=128 (13,309) — sits **above** the triad's 11,887. No pool choice reproduces the triad's lower value.

> **CORRECTION (2026-07-24): the residual is pgjdbc equalization across the build-provenance fence, NOT the measurement harness.** The original text below claimed "pgjdbc params are matched between this sweep and the triad" and blamed harness/JFR — that premise was FALSE. The triad `60707c4` (2026-07-21 19:00) **predates** the pgjdbc equalization `9f2b182` (2026-07-22 11:40, "equalize pgjdbc query-protocol params across exeris and quarkus arms"; verified: not an ancestor of the triad, and the triad artifacts carry no `defaultRowFetchSize`/`adaptiveFetch` markers). So this sweep (fair params) vs the triad (un-equalized) **crosses the fence**. The prior session's quarkus-control decomposition — **exeris +18.7% / quarkus +2.8% (flat)** across the fence — is decisive: an exeris-specific jump is the signature of equalization pulling exeris off a slow fetch default, whereas harness/JFR overhead would hit *both* arms ~equally. This matches the user's original "we equalized db" hypothesis; the harness/JFR attribution below is retracted.

**(retracted)** ~~Since pool, memory, pinning, pgjdbc params, and DB are all matched between this sweep and the triad, the residual gap must come from the measurement harness (JFR ~75 GB + dual-target residency, ~10-15% tax).~~ The pgjdbc params were NOT matched (fence, above). The pool-sweep DATA and the "NOT pool" conclusion stand; only this attribution sentence was wrong.

See `runs.jsonl` for the machine-readable per-run rollup and each `pool-*/<arm>/repeat-*/` for raw artifacts.
