# keepalive-steady

**Scenario ID:** `keepalive-steady`  
**Endpoint:** `GET /plaintext`  
**Mode:** `keepalive-steady`  
**Tier:** Community (first)  
**Driver:** wrk (H1), h2load (H2), k6  
**Transport:** H1, H2

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario runs client and server on the same host.
> Loopback results are **not equivalent** to network-path measurements.
> All result artifacts **must** carry `transport_mode=loopback-h1` (H1) or `transport_mode=loopback-h2c` (H2).
> Do not compare loopback results to network-path results without explicit caveats.

> **TEST CONDITION:** Keepalive is the test condition. **Do NOT set `Connection: close`.**
> Drivers use keepalive by default; override only if debugging a specific connection-teardown path.

---

## Claim scope

| Scope | Min duration | Required profile | Allowed claims | CO risk |
|---|---|---|---|---------|
| `exploratory` | 30 s | dev-isolated, dev-laptop, ci-runner | descriptive only | yes |
| `comparison-eligible` | 60 s | **perf-box-amd64** | throughput, p50 (indicative) | yes |

Recommended measurement window: **120 s** — connection stability often takes 30–60 s to settle. Shorter runs may not represent steady-state behaviour.

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
| H1 | runnable | wrk | Keepalive by default. 4 threads, 100 connections. |
| H2 | runnable | h2load | `-c 100 -m 10` — 100 connections, 10 streams each (multiplexed keepalive) |
| H3 | not-runnable | — | No confirmed H3 driver in `runtime/drivers`. Backlog: **P2-02** |

---

## Key metrics

| Metric | Role |
|---|---|
| Throughput (RPS) | Primary — stable steady-state reuse efficiency |
| `http_req_duration` p50, p99 | Latency under long-lived connections |
| Connection reuse rate | Indicator of keepalive effectiveness |

---

## Concurrency

| Parameter | Value |
|---|---|
| Connections | 100 |
| Threads | 4 |
| Streams per connection (H2) | 10 (`h2load -c 100 -m 10`) |
| Warmup | 60 s |
| Measurement | 120 s (minimum for connection stability) |

---

## Driver notes

wrk holds connections open by default — no additional configuration needed. h2load uses `-c 100 -m 10` to simulate multiplexed keepalive on H2. k6 must not have per-iteration connection teardown; use shared connections in the k6 script. Do not set `Connection: close` in any driver script for this scenario.
