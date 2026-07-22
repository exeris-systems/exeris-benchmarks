# entity-read-by-id — memory × CPU constrained sweep (exeris-community vs quarkus)

**Classification (separation axes, from campaign manifest):**
Tier **community** · protocol **H1** (transport `loopback-h1`) · family **runtime-wrk** · mode **baseline-db** · purity **pure** · `execution_class` **exploratory-constrained** · `track_id` **track-c** · `claim_scope` **descriptive_only** · `comparison_policy` **forbidden** · comparison axis **within-tier**.

> **What this is / is not.** This is a cgroup-constrained sweep measuring each runtime's steady-state footprint and per-request cost under fixed memory/CPU budgets. It is **exploratory-descriptive**, *not* the strict-gated comparative path: there is no `stage7-gate-report.csv` / `claim-status.json=comparison_eligible`. Therefore the **durable per-arm metrics (RSS, cpu/req) are valid measured facts**, while **cross-arm throughput deltas are directional only** — read them as "which is in front and roughly by how much", not a certified throughput claim. For a certified throughput comparison, route to a perf-box comparison-eligible run. This matches the standing view that RSS and cpu/req are the durable signals and throughput is context-dependent.

Campaign: `results/constrained/entity-read-by-id/20260722T015708Z-memory-cpu-matrix/` · 45 runs (3 repeats × 7 points × arms) · hardware `perf-box-amd64` (16 logical / 8 physical) · JDK 26 · generated 2026-07-22.

---

## Methodology (fairness controls)

- **Backend: tuned-PG isolation.** Postgres host-networked, pinned to cpuset `4-7,12-15` (4 physical cores), external + reused across every run (never recreated mid-sweep). PG RSS ≈ **44 MB** throughout, **outside** the app budget (never counted against it).
- **Per-point disjoint CPU partition.** vCPU ≤ 4: target `0-1,8-9` / loadgen `2-3,10-11` (fully disjoint from each other and the DB — the same partition as the 2026-07 tuned-PG triad). vCPU = 8: target `0-3,8-11`; on an 8-physical box no fourth disjoint slice remains, so the loadgen co-locates on the DB cpuset `4-7,12-15` — **target cores stay isolated (RSS + cpu/req clean); throughput is DB+loadgen-bound at the 8-vCPU point only**, for both arms equally.
- **Constraint:** `systemd-run --scope MemoryMax=<budget> MemorySwapMax=0 CPUQuota=<vCPU×100%>`, ParallelGC.
- **Heap policy — per-arm, architecture-appropriate (declared, NOT identical knobs).** exeris-community `Xmx = 0.25 × budget`; quarkus-tuned / quarkus-hibernate `Xmx = 0.75 × budget`; `Xms = Xmx` (fixed heap, no resize → well-defined steady-state RSS). Rationale: exeris is off-heap by design (crypto off, ~16 MB heap need); quarkus uses JVM-heap-standard sizing. This is intentional and must be stated when reading the curve.
- **Subsystem fairness (exeris only):** `EXERIS_SUBSYSTEMS=http,persistence` (crypto **off** — unused native memory in a plaintext H1 path that quarkus never allocates), telemetry off, JFR off. Quarkus ignores these vars.
- **Workload:** `GET /api/v1/user?id=1` (single-row read) · warmup 120 s · measure 300 s · 128 connections / 4 threads (wrk, closed-loop) · DB pool `min=max=16`.
- **Repeats:** 3, interleaved (repeat is the outer loop, so each (point,arm) sample is spread in time).

---

## Results — memory curve (fixed 4 vCPU), n=3 medians

| budget | exeris rps | exeris RSS | exeris cpu/req | quarkus-tuned rps | quarkus-tuned RSS | quarkus-tuned cpu/req |
|---|---|---|---|---|---|---|
| 128 MB | 56,387 | **136 MB** | 0.0545 ms | **OOM at readiness (3/3)** | — | — |
| 256 MB | 56,250 | 147 MB | 0.0545 ms | 46,403 | 240 MB | 0.0706 ms |
| 512 MB | 56,126 | 175 MB | 0.0546 ms | 46,855 | 305 MB | 0.0698 ms |
| 1024 MB | 56,314 | 229 MB | 0.0544 ms | 46,311 | 454 MB | 0.0707 ms |
| 2048 MB | 55,443 | 325 MB | 0.0554 ms | 47,457 | 712 MB | 0.0686 ms |

**quarkus-hibernate** (reference, 1024 MB / 4 vCPU only): 42,135 rps · 519 MB · 0.0786 ms/req.

## Results — CPU cut (fixed 1024 MB), n=3 medians

| vCPU | exeris rps | exeris cpu/req | exeris cores | quarkus-tuned rps | quarkus-tuned cpu/req | quarkus-tuned cores |
|---|---|---|---|---|---|---|
| 2 | 31,427 | 0.0480 ms | 1.51 | 24,542 | 0.0651 ms | 1.60 |
| 4 | 56,314 | 0.0544 ms | 3.07 | 46,311 | 0.0707 ms | 3.28 |
| 8 | 94,312 | 0.0669 ms | 6.32 | 69,777 | 0.0913 ms | 6.40 |

---

## Findings

**Durable (per-arm facts):**
1. **Memory floor.** exeris runs full-speed (56 k rps) in a **128 MB** budget; quarkus at its 0.75 heap **deterministically fails to reach readiness at 128 MB** (3/3 oomd SIGTERM during boot). Note this is a function of the declared heap policy — a smaller quarkus heap is a different configuration.
2. **RSS.** exeris's steady-state footprint is **46–61 % of quarkus-tuned's** at matched budgets, and the ratio falls as budget grows (325 vs 712 MB at 2048 MB) — the off-heap design stays lean while quarkus's large heap fraction expands to fill the budget.
3. **cpu/req.** exeris ≈ **0.0545 ms/req, flat across the entire budget range** (memory-insensitive); quarkus-tuned ≈ 0.070 ms/req (~30 % higher). quarkus-hibernate ≈ 0.0786 ms/req (+11 % over tuned — consistent with the known offset).

**Directional (throughput — not gate-certified):**
4. At 4 vCPU exeris leads quarkus-tuned by **~17–22 %** rps; the lead is roughly flat across budgets.
5. **CPU scaling** (1024 MB): exeris 31 k → 56 k → 94 k across 2 → 4 → 8 vCPU; quarkus-tuned 24.5 k → 46 k → 70 k. exeris reaches **~35 % more at 8 vCPU**, and its cpu/req rises far less under contention (0.048 → 0.067) than quarkus-tuned (0.065 → 0.091).

---

## Caveats

- **Not comparison-eligible.** `track-c` / `descriptive_only`; cross-arm throughput is directional. Certified throughput claims require a perf-box comparison-eligible run with the stage-7 strict gate.
- **Per-arm heaps, not identical knobs.** community 0.25 vs quarkus 0.75 of budget — declared per row; the quarkus-128 MB OOM and the RSS gap both partly reflect this deliberate choice.
- **8-vCPU point is DB-bound.** loadgen co-located on the DB cpuset there (both arms); absolute 8-vCPU throughput is understated, cpu/req still clean.
- **Latency is coordinated-omission.** wrk closed-loop; recorded p50/p99 are for rank-ordering only, not a service-time tail (needs wrk2 for CO-free tails).
- **PG RSS (~44 MB) is outside the app budget** — a best-effort docker-stats snapshot, never counted against the cgroup budget.
- **128 MB memory-edge recovery.** At 128 MB the app's working set leaves almost no cgroup headroom, so the harness's own post-measurement child processes occasionally tip the cgroup → oomd SIGTERM (rc 143) after a *complete* measurement but before `result.json`. 6/45 runs hit this (3 exeris = recovered from `driver-wrk.log` + `resource-metrics.json`, validated identical to clean runs; 3 quarkus = genuine boot OOM, no measurement). `oom_is_a_result`.

## Provenance

- Targets (SHA-256): exeris-community `ae822c31…` (20,569,065 B); quarkus-tuned `7b2c0a6e…` (55,463,153 B); quarkus-hibernate — see `campaign-manifest.json` `target_provenance`.
- Harness commits this campaign ran with: `a2a52c6` (external-DB reuse → cpuset preserved), `87b0273` (skip jcmd augment under constrained scope → result.json survives), `158eeb7`/`f36f7fd` (per-point disjoint pins; `</dev/null` so the arm loop runs both arms). JDK 26, ParallelGC, `-Xms=-Xmx` per arm.
- Aggregation: recovery-aware `aggregate-matrix.sh` (uses `result.json` for rc=0, reconstructs rc≠0 runs from raw artifacts). Normalized per-run data: `normalized-runs.jsonl`; medians: `aggregated-tables.txt`.
