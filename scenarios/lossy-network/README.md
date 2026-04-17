# lossy-network

**Scenario ID:** `lossy-network`  
**Endpoint:** `GET /plaintext`  
**Mode:** `lossy-network`  
**Tier:** Community (first)  
**Driver:** k6  
**Transport:** H1, H2

---

> **IMPORTANT — LOOPBACK + NETEM CAVEAT**
>
> Impairment is applied to the loopback interface via `tc netem`.
> This provides **reproducible controlled impairment**, not a real network model.
> Results are **not comparable** to measurements on a real network path.
> All result artifacts **must** carry `transport_mode=loopback-h1-netem` and capture
> `netem_delay_ms`, `netem_loss_pct`, and `netem_jitter_ms`.
> **A run without captured netem parameters is invalid for comparison purposes.**

---

## REQUIRED: netem setup

Apply impairment to loopback **before** starting the benchmark.

```bash
# Apply impairment
sudo tc qdisc add dev lo root netem \
  delay ${NETEM_DELAY_MS}ms ${NETEM_JITTER_MS}ms \
  loss ${NETEM_LOSS_PCT}%

# Remove impairment after run
sudo tc qdisc del dev lo root
```

Required environment variables: `NETEM_DELAY_MS`, `NETEM_LOSS_PCT`  
Optional: `NETEM_JITTER_MS`

---

## Reference impairment profiles

| Profile | Delay | Jitter | Loss |
|---|---|---|---|
| `mild` | 5 ms | 1 ms | 0.1% |
| `moderate` | 20 ms | 5 ms | 1.0% |
| `severe` | 100 ms | 20 ms | 5.0% |

The fixed contract uses the `moderate` profile (`netem_delay_ms=20`, `netem_loss_pct=1.0`, `netem_jitter_ms=5`).

---

## Claim scope

| Scope | Min duration | Required profile | Allowed claims | CO risk |
|---|---|---|---|---------|
| `exploratory` | 30 s | dev-isolated, dev-laptop, ci-runner | descriptive only | yes |
| `comparison-eligible` | 60 s | **perf-box-amd64** | throughput, p50 (indicative) | yes |

> **Do NOT compare results across different netem profiles without explicit impairment-profile labelling.**
> Mild, moderate, and severe profiles are separate experimental conditions.

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
| H1 | runnable | k6 | TCP retransmission cost under loss. Baseline for comparison. |
| H2 | runnable | k6 | TCP HOL-blocking becomes visible under loss. |
| H3 | not-runnable | — | H3/QUIC is the **primary research target** for lossy-network (QUIC designed for lossy paths). Driver not yet confirmed. Backlog: **P2-02** |

---

## Key metrics

| Metric | Role |
|---|---|
| `http_req_duration` p50, p90, p99 | Latency under impairment — primary |
| `http_req_failed` rate | Error ratio under packet loss |
| Throughput (RPS) degradation | vs clean baseline — protocol comparison signal |

---

## Concurrency

| Parameter | Value |
|---|---|
| VUs (k6) | 50 (fixed contract, moderate profile) |
| Warmup | 60 s |
| Measurement | 120 s |

---

## Driver notes

k6 is the sole confirmed driver for this scenario. Impairment parameters must appear in result metadata. Never mix results from different netem profiles in the same comparison table without clear labelling. H3 is the primary protocol of interest — H1/H2 establish the degradation baseline.
