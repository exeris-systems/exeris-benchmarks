# exception-mapping

**Scenario ID:** `exception-mapping`  
**Endpoint:** `GET /throw`  
**Mode:** `exception-mapping`  
**Tier:** Community (first)  
**Driver:** k6 (primary), wrk (secondary)  
**Transport:** H1

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario runs client and server on the same host.
> Loopback results are **not equivalent** to network-path measurements.
> All result artifacts **must** carry `transport_mode=loopback-h1`.
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
| H1 | runnable | k6 (primary), wrk (secondary) | Fixed contract defined. See driver notes for wrk status-code caveat. |
| H2 | not-runnable | — | No fixed H2 contract for this scenario. |
| H3 | not-runnable | — | No confirmed H3 driver in `runtime/drivers`. Backlog: **P2-02** |

---

## Key metrics

| Metric | Role |
|---|---|
| Throughput (RPS) | Exception-path throughput (not business logic) |
| `http_req_duration` p50, p99 | Exception-to-response latency overhead |
| HTTP 422 response rate | Validates exception mapping is active — k6 only |

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 100 |
| Threads | 4 |

---

## Driver notes

> **wrk secondary — status code warning:** wrk does **not** validate HTTP status codes. wrk will count 422 responses as successful requests, making it unsuitable for correctness verification. Use k6 as the primary driver; k6 checks that the response status is 422 and the body is a JSON error object.
>
> Do not use wrk results to claim exception-mapping correctness. Use wrk only for throughput/latency characterisation with the understanding that error signal is absent.
