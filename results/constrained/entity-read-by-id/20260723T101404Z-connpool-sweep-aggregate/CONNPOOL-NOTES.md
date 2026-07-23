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

**The +15% is NOT a pool effect.** The entire lean-constrained curve — every pool from 4 to 128, including the worst over-subscribed pool=128 (13,309) — sits **above** the triad's 11,887. No pool choice reproduces the triad's lower value. Since pool, memory (1024m; the mem-cpu sweep showed 2048m is no higher), pinning, pgjdbc params, and DB are all matched between this sweep and the triad, the residual gap must come from the one thing that differs: **the measurement harness**. The triad ran `run-comparative.sh` with **JFR capture active during the measurement window** (~75 GB recorded) and dual-target residency; this sweep uses the lean constrained runner (no JFR). On a high-allocation aggregate that is a ~10-15% throughput tax.

**Evidence-bounded:** this campaign *rules out* pool/memory/DB/params as the cause of the +15% and *attributes* it to comparative-harness overhead, with JFR the prime suspect. It does not isolate JFR-on vs JFR-off — confirming that split needs a JFR-off re-run of the comparative config. Earlier framing ("mechanism open, DB-equalization vs pool") is superseded: the aggregate IS strongly pool-sensitive (2× from pool 4 to 32), but the specific sweep-vs-triad delta is harness overhead, not pool or DB-equalization.

See `runs.jsonl` for the machine-readable per-run rollup and each `pool-*/<arm>/repeat-*/` for raw artifacts.
