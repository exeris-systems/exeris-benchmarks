# multiplex-32

**Scenario ID:** `multiplex-32`  
**Endpoint:** `GET /plaintext`  
**Mode:** `stream-multiplex`  
**Tier:** Community (first)  
**Driver:** h2load (authoritative), k6 (supplementary)  
**Transport:** H2

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario runs client and server on the same host.
> Loopback results are **not equivalent** to network-path measurements.
> All result artifacts **must** carry `transport_mode=loopback-h2c`.
> Do not compare loopback results to network-path results without explicit caveats.

---

> **CRITICAL — DRIVER EQUIVALENCE WARNING**
>
> **h2load `-c 1 -m 32` and k6 with 32 VUs are NOT equivalent.**
>
> - **h2load** `-c 1 -m 32` measures **true single-connection stream multiplexing** (32 concurrent streams over 1 TCP connection). This is the authoritative driver for multiplexing claims.
> - **k6** with 32 VUs measures **multi-connection concurrent load**. It does not model stream multiplexing.
>
> All multiplexing claims must specify the driver. Do not mix h2load and k6 results in the same multiplexing comparison.

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
| H1 | **not-applicable** | — | H1 does not support stream multiplexing. This scenario is H2/H3 only by definition. |
| H2 | runnable | h2load | `-c 1 -m 32` — 1 connection, 32 streams. True stream multiplexing. |
| H3 | not-runnable | — | H3 eliminates H2 HOL-blocking at transport layer. Primary comparison target pending QUIC driver. Backlog: **P2-02** |

---

## Key metrics

| Metric | Role |
|---|---|
| Throughput (RPS) | Primary — single-connection stream throughput |
| `http_req_duration` p50, p99 | Latency tail under stream contention |
| HOL-blocking signals | Latency variance across concurrent streams |

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 1 |
| Streams per connection | 32 |
| Driver (authoritative) | h2load `-c 1 -m 32` |

---

## Driver notes

h2load is the **authoritative driver** for all stream-multiplexing claims in this scenario. k6 results are supplementary only and must be labelled as multi-connection concurrent load — not stream multiplexing. Do not conflate stream count (`-m 32`) with connection count (`-c`) in result labels or comparative tables. H3 vs H2 multiplexing comparison (QUIC independent streams vs TCP HOL) is the primary research value of this scenario — currently blocked on P2-02.
