# Heavy (aggregate) memory×CPU sweep — provenance & caveats

**Campaign:** `20260723T045841Z-memory-cpu-matrix`
**Harness:** commit `1e6255a` (`MATRIX_WORKLOAD=aggregate`)
**Endpoint:** `GET /api/v1/users` — 3-query 10×10×10 aggregate (top-users + friends window + interests window)
**Track:** Community, H1 plaintext, Runtime family, constrained. Not a merge gate.

## Setup (fairness-controlled)

- **Constrained, per-point PINNED:** target `0-1,8-9` / loadgen `2-3,10-11` for vCPU≤4; target `0-3,8-11` / loadgen `4-7,12-15` for vCPU=8. DB (tuned-PG) `4-7,12-15` host-net, role/db `benchmark`/`benchmark_db`.
- **Identical pgjdbc params on both arms** (logged by the harness): `preferQueryMode=extended&prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false`.
- **Heap fraction (deliberately asymmetric):** exeris `0.25×budget`, quarkus `0.75×budget`. This asymmetry is the reason the closed-loop p99 tails differ — see caveat below.
- Pool 16 (min=max), wrk closed-loop max-throughput, 120s warmup + measure, **n=3 interleaved** per (point,arm).
- Arms: `exeris-community` + `quarkus-tuned` at every viable point; `quarkus-hibernate` at 1024m/4vCPU only.

## Points & failures

- Memory axis @4vCPU: 256/512/1024/2048m. **128m fails both arms** (heap too tight) — `point-128m-4vcpu` retains the failed-attempt evidence, no `result.json`. **256m quarkus-tuned fails** (0.75×=192m heap too tight); exeris OK at 256m (64m heap).
- CPU axis @1024m: 2 / 8 vCPU.
- 12 viable (point,arm) cells × 3 = **36 `result.json`**.

## CAVEAT 1 — pg_stat_statements aggregate diagnostics are CORRUPT in this run

`db-diagnostics/pg_stat_statements-*.json` under the aggregate leaves are **corrupt** (empty `calls`/`total_time_ms`, split `"queryid":"FROM ("`). Root cause: the pre-fix line-split parser could not handle the multi-line aggregate SQL. **Fixed in commit `1727706`** (server-side `json_agg(row_to_json)`), deployed to the box **after** this run — so these files are retained as-is for provenance and are NOT usable for DB attribution.

Per-query DB attribution was instead obtained by a **post-sweep read-only probe** of the live PG: the two window-function joins dominate DB exec time — friends `queryid 5642500616955608682` ≈ 61.8k calls / 16.9 s, interests `queryid 5411875004500411312` ≈ 61.8k calls / 10.8 s.

## CAVEAT 2 — "DB-bound" is INFERRED, not measured here

No PG-cpuset CPU sampling in this sweep. The ~13.5k ceiling is **consistent with DB-bound**, supported by four independent signals — (a) app-CPU headroom on every arm (exeris ~2.9/4, quarkus-tuned ~3.15/4 cores), (b) the triad's sar-measured PG 92–99.5% on the same aggregate, (c) **8 vCPU yields no throughput gain over 4 vCPU** (13.3k vs 13.8k, 0% throttle, cores free), (d) the probe's measured DB hot-spots. State it as "consistent with DB-bound", never "DB-bound ceiling has risen".

## CAVEAT 3 — closed-loop p99 is a GC-under-constraint artifact, not inherent latency

Under closed-loop max-rate wrk, exeris p99 tracks *inversely* with available CPU (1533ms@2vCPU → 184ms@4vCPU → 67ms@8vCPU) while quarkus stays ~11ms. This is the deliberate heap asymmetry (exeris 0.25× = 256m heap vs quarkus 0.75× = 768m heap) interacting with the heavy-allocating aggregate + ParallelGC, worst when CPU-starved. It is **not** a CO-free service-time latency — the pinned wrk2 curve (below saturation, matched heap) is the proper latency instrument.

## Durable findings (RSS + CPU/req; throughput is DB-gated/context-dependent)

- **RSS: exeris ≈ half of quarkus**, gap widens with budget. @2048m/4vCPU exeris 321 MB vs quarkus-tuned 727 MB; @1024m/4vCPU exeris 258 vs quarkus-tuned 461 vs quarkus-hibernate 564.
- **CPU/req (unthrottled, @4vCPU): exeris ~210 µs vs quarkus-tuned ~236 (+12%) vs quarkus-hibernate ~317 (+51%).**
- **Throughput: exeris ≈ quarkus-tuned ~13.4–13.8k** (exeris +3–4%); quarkus-hibernate ~11.4k. Memory-insensitive above the floor.
- At **2 vCPU** (CPU-bound, ~98.5% throttle both) exeris leads +15% (11.2k vs 9.8k) — efficiency shows under CPU pressure.

See `memory-cpu-curve.json` for the machine-readable per-point rollup and each `point-*/<arm>/repeat-*/` for raw `result.json` + `resource-metrics.json` + `constrained-execution-evidence.json`.
