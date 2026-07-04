---
name: exeris-benchmarks-tls-label-discipline-review
description: TLS comparator label discipline review for exeris-benchmarks. Use on every TLS JMH benchmark / TLS row / TLS report change.
---

# Exeris Benchmarks TLS Label Discipline Review

## Purpose
Enforce: TLS rows labelled unambiguously across B3/B4/B5/B6/B7; per-row buffer/transport/allocator model labels populated; cross-row claims carry the full required metric set; tier-then-global config precedence respected.

## When to Use
- Any PR adding / modifying TLS JMH benchmarks under `micro/jmh/`.
- Any PR producing a TLS row in a report.
- Any PR making a cross-row TLS claim.
- Any PR touching TLS provider/memory/cert config keys.

## Required Inputs
- PR diff scoped to TLS code / artefacts.
- Row → comparator label mapping.
- Cross-row claim metrics.

## Review Procedure
1. **Comparator label** — every row labelled B3 / B4 / B5 / B6 / B7 unambiguously:
   - `B3`: JDK `SSLEngine` baseline (direct)
   - `B4`: Netty `SslHandler` + `EmbeddedChannel` over netty-tcnative
   - `B5`: Exeris `OffHeapTlsEngine` Memory-BIO engine-level lens
   - `B6`: Exeris SPI-native `TlsEngine` real loopback socket (kernel I/O included)
   - `B7`: Exeris Memory-BIO path (in-process)
2. **Per-row labels** — buffer model, transport model, allocator model (GC-managed / pooled-direct / off-heap) populated.
3. **Cross-row metric set** — for cross-row claims:
   - ops/s
   - sample-time latency (p50/p95/p99)
   - `gc.alloc.rate.norm`
   - JFR `ObjectAllocationSample` stacks
   - CPU hotspot profile
   - RSS + native footprint snapshot
   - RSS@`@Setup`-end vs RSS@measurement-end delta
4. **B3 vs B4 framing** — not handler-free apples-to-apples; B4 is pipeline path. Caveat present.
5. **B3/B4 vs B5/B6 framing** — differences (Memory-BIO vs real socket; off-heap engine vs JDK on-heap; integration-level vs engine-level) stated.
6. **B6 transport-wiring caveat** — loopback socket, includes kernel I/O — present.
7. **TLS config precedence** — `exeris.tls.<tier>.X` → `exeris.tls.X` with backward-compatible alias chain; see `micro/jmh/README.md`.
8. **Decision and report** — `APPROVE` / `CONDITIONAL` / `REJECT`.

## Decision Logic
- **APPROVE**: All rows labelled; per-row labels present; cross-row metric set complete; caveats present; config precedence respected.
- **CONDITIONAL**: Sound but one specific metric missing or one caveat phrasing weak — propose the specific addition.
- **REJECT**: Unlabelled row; missing per-row labels; incomplete cross-row metric set; B3 vs B4 framed as apples-to-apples; B6 missing transport-wiring caveat.

## Completion Criteria
- Comparator labels checked.
- Per-row labels checked.
- Cross-row metric set checked.
- Caveats checked.
- Config precedence checked.
- Verdict and remediation recorded.

## Review Output Template
1. **Scope analysed** (TLS rows / claims / config touched)
2. **Comparator labels** (per row)
3. **Per-row labels** (buffer / transport / allocator)
4. **Cross-row metric set** (per metric present / missing)
5. **Framing caveats** (B3 vs B4, B3/B4 vs B5/B6, B6 transport-wiring)
6. **Config precedence**
7. **Verdict** (`APPROVE` / `CONDITIONAL` / `REJECT`)
8. **Required actions** (precise and minimal)

## Non-Negotiable Rules
- Never approve an unlabelled TLS row.
- Never approve B3 vs B4 framed as apples-to-apples.
- Never approve B6 claims without the transport-wiring caveat.
- Never approve a cross-row claim with incomplete metric set.
