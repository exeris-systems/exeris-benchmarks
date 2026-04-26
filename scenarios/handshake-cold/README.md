# handshake-cold

**Scenario ID:** `handshake-cold`  
**Endpoint:** `GET /plaintext`  
**Mode:** `tls-handshake-cold`  
**Tier:** Community (first)  
**Driver:** k6, h2load  
**Transport:** H2-TLS

---

> **IMPORTANT — LOOPBACK CAVEAT**
>
> This scenario measures TLS crypto + kernel cost without network RTT.
> Results are **not equivalent** to measurements with a network path.
> All result artifacts **must** carry `transport_mode=loopback-h2-tls`.
> Do not compare loopback results to network-path results without explicit caveats.

> **SCOPE NOTE:** This scenario measures the **TLS crypto layer only**.
> It does **not** measure bare TCP connect cost — for that, use `cold-connect-single`.
> Session resumption **must be disabled** to ensure cold handshake measurement.

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
| H2-TLS | runnable | k6 + h2load | RSA-2048 self-signed cert via `tools/bench/lib/certs.sh`. k6: `insecureSkipTLSVerify=true` |
| H1-TLS | runnable | k6 | Optional baseline. Same cert and key type. |
| H3/QUIC | not-runnable | — | H3 0-RTT vs 1-RTT QUIC crypto is the primary research target. No confirmed driver. Backlog: **P2-02** |

> **Key-type caveat:** RSA-2048 is the default contract. EC P-256 is a **separate contract** with different crypto cost.
> Do not compare RSA-2048 results to EC P-256 results without explicit key-type labelling.

---

## Key metrics

| Metric | Role |
|---|---|
| `http_req_tls_handshaking` p50, p99 | TLS handshake duration — **primary** |
| `http_req_connecting` p50, p99 | TCP connect phase — secondary |
| `http_req_duration` p50, p99 | Total request duration |

---

## TLS configuration

| Parameter | Value |
|---|---|
| Key type | RSA-2048 (default contract) |
| Cert tool | `tools/bench/lib/certs.sh` |
| Session resumption | **Disabled** (mandatory) |

---

## Concurrency

| Parameter | Value |
|---|---|
| VUs (k6) | 20 (fixed contract) |
| Warmup | 60 s |
| Measurement | 120 s |

---

## Backlog reference

This scenario is linked to backlog item **P2-02** (D3 Community Loopback Handshake Benchmark). H3/QUIC handshake comparison is the primary research goal and unblocks once a confirmed QUIC driver is available in `runtime/drivers`.

---

## Driver notes

k6 (`insecureSkipTLSVerify=true`) is the primary driver. h2load is used as secondary for H2-TLS validation. Both drivers must have session cache/resumption disabled. Do not mix RSA-2048 and EC P-256 results in the same comparison run.
