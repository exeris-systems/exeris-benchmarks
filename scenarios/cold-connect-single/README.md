# cold-connect-single

**Scenario ID:** `cold-connect-single`  
**Endpoint:** `GET /plaintext`  
**Mode:** `cold-connect`  
**Tier:** Community (first)  
**Driver:** k6 (H1), h2load (H2)  
**Transport:** H1, H2

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario runs client and server on the same host.
> Cold-connect loopback measurements reflect kernel TCP stack cost without network RTT.
> Results are **not equivalent** to measurements with a network path.
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
| H1 | runnable | k6 | `Connection: close` header forces fresh TCP connection per request |
| H2 | runnable | h2load | `-c 1 -m 1`: single connection reconnect pattern. True per-connection isolation requires external loop |
| H3 | not-runnable | — | Requires dedicated QUIC toolchain (xk6-quic or curl `--http3`). Backlog: **P2-02** |

> **Protocol comparison caveat:** H1 cold-connect ≠ H2 cold-connect.
> They measure different handshake stacks (TCP only vs TCP+ALPN negotiation).
> Do not compare H1 and H2 cold-connect results without an explicit protocol-overhead caveat.

---

## Key metrics

| Metric | Role |
|---|---|
| `http_req_connecting` p50, p99 | TCP connect latency — primary |
| `http_req_waiting` / TTFB p50, p99 | Time to first byte after connect |
| `http_req_duration` p50, p99 | Total request duration |

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 1 per iteration (by design) |
| VUs (k6) | 20 (fixed contract) |
| Connection model | close-per-request — each iteration opens a fresh TCP connection |

---

## Driver notes

k6 is the primary driver for H1. h2load is used for H2 (`-c 1 -m 1`). No H3 driver is confirmed in `runtime/drivers` — see backlog P2-02.
