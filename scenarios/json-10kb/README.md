# json-10kb

**Scenario ID:** `json-10kb`  
**Endpoint:** `POST /echo`  
**Mode:** `json-echo`  
**Tier:** Community (first)  
**Driver:** wrk (primary), k6  
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
| H1 | runnable | wrk, k6 | Fixed contract defined. Payload file: `scenarios/json-10kb/payload.json` |
| H2 | not-runnable | — | No fixed H2 contract for this scenario. |
| H3 | not-runnable | — | No confirmed H3 driver in `runtime/drivers`. Backlog: **P2-02** |

> **Payload-size caveat:** Do **not** compare `json-10kb` results directly to `json-1kb` results without an explicit payload-size caveat.
> The ~10x payload difference alters buffer strategy, serialization cost, and kernel copy paths.
> Claims must be labelled by payload size.

---

## Key metrics

| Metric | Role |
|---|---|
| Throughput (RPS) | Primary — buffer strategy sensitivity at medium payload |
| `http_req_duration` p50, p99 | Parse + serialize + network copy latency |
| `http_req_sending` | Upload cost (client → server) |
| `http_req_receiving` | Download cost (server → client) |

---

## Payload

| Parameter | Value |
|---|---|
| Size (approx) | ~10 KB (10 240 bytes) |
| Content-Type | `application/json` |
| Payload file | `scenarios/json-10kb/payload.json` |

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 100 |
| Threads | 4 |

---

## Driver notes

wrk is the primary driver for throughput. k6 is used as secondary for status-code and body-content validation. The payload file must be pre-loaded into the wrk script via a Lua script. Ensure `payload.json` is committed and immutable — changing the payload file invalidates cross-run comparisons.
