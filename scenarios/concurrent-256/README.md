# concurrent-256

**Scenario ID:** `concurrent-256`  
**Endpoint:** `GET /plaintext`  
**Mode:** `concurrent-load`  
**Tier:** Community (first)  
**Driver:** wrk (H1), h2load (H2), k6  
**Transport:** H1, H2

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario runs client and server on the same host.
> **256 connections on loopback will likely saturate the target.**
> Results are NOT equivalent to network-path benchmarks.
> All result artifacts **must** carry `transport_mode=loopback-h1` (H1) or `transport_mode=loopback-h2c` (H2).
> Results remain exploratory until verified on `perf-box-amd64`.

---

## Claim scope

| Scope | Min duration | Required profile | Allowed claims | CO risk |
|---|---|---|---|---------|
| `exploratory` | 30 s | dev-isolated, dev-laptop, ci-runner | descriptive only | yes |
| `comparison-eligible` | 60 s | **perf-box-amd64** | throughput, p50 (indicative) | yes |

Promote to `comparison-eligible` only after repeated runs on `perf-box-amd64`. Wider error/latency thresholds apply at this concurrency level (up to 5% error rate and p99 < 100 ms are expected at loopback saturation).

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
| H1 | runnable | wrk | 4 threads, 256 connections. Expect saturation on loopback. |
| H2 | runnable | h2load | `-c 256 -m 1` — 256 connections, 1 stream each |
| H3 | not-runnable | — | No confirmed H3 driver in `runtime/drivers`. Backlog: **P2-02** |

> **NEVER compare `concurrent-256` directly to `concurrent-32` without an explicit concurrency-axis caveat.**
> These are distinct experimental setups measuring different contention regimes.

---

## Key metrics

| Metric | Role |
|---|---|
| Throughput (RPS) | Primary — expected plateau under saturation |
| `http_req_duration` p50, p99 | Queueing and backpressure signals |
| Error rate | Up to 5% expected at loopback saturation |

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 256 (fixed — high-contention scenario) |
| Threads | 4 |

---

## Driver notes

wrk is the primary driver for H1 (`-t 4 -c 256`). h2load is authoritative for H2 (`-c 256 -m 1`). k6 may be used as a secondary driver for status-code validation. Saturation artifacts are expected and must be noted in result metadata.
