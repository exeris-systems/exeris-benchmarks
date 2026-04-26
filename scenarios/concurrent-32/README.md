# concurrent-32

**Scenario ID:** `concurrent-32`  
**Endpoint:** `GET /plaintext`  
**Mode:** `concurrent-load`  
**Tier:** Community (first)  
**Driver:** wrk (H1), h2load (H2), k6  
**Transport:** H1, H2

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario runs client and server on the same host.
> Loopback results are **not equivalent** to network-path measurements.
> Loopback saturates before a real network path at this concurrency level.
> All result artifacts **must** carry `transport_mode=loopback-h1` (H1) or `transport_mode=loopback-h2c` (H2).
> Do not compare loopback results to network-path results without explicit caveats.

---

## Claim scope

| Scope | Min duration | Required profile | Allowed claims | CO risk |
|---|---|---|---|---------|
| `exploratory` | 30 s | dev-isolated, dev-laptop, ci-runner | descriptive only | yes |
| `comparison-eligible` | 60 s | **perf-box-amd64** | throughput, p50 (indicative) | yes |

---

## Seed requirement

No seed requirement. All endpoints are stateless.

---

## Cross-tier status

**Not yet assessed.** Cross-tier comparison (Community vs Enterprise) has not been evaluated for this scenario.

---

## Protocol support

| Protocol | Status | Driver | Notes |
|---|---|---|---|
| H1 | runnable | wrk | 4 threads, 32 connections |
| H2 | runnable | h2load | `-c 32 -m 1` — 32 connections, 1 stream each |
| H3 | not-runnable | — | No confirmed H3 driver in `runtime/drivers`. Backlog: **P2-02** |

> **Concurrency axis caveat:** Do **not** compare `concurrent-32` results to `concurrent-256` results without an explicit concurrency-axis caveat. Different concurrency levels are separate experimental axes.

---

## Key metrics

| Metric | Role |
|---|---|
| Throughput (RPS) | Primary |
| `http_req_duration` p50, p99 | Latency tail at moderate load |
| Thread/connection contention | Observed via latency distribution shape |

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 32 (fixed — do not scale up, see `concurrent-256`) |
| Threads | 4 |

---

## Driver notes

wrk is the primary driver for H1 (`-t 4 -c 32`). h2load is authoritative for H2 (`-c 32 -m 1`, streams_per_connection=1 to isolate per-connection throughput from multiplexing effects). k6 may be used as a secondary driver for status-code validation.
