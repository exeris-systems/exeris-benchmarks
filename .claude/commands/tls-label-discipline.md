---
description: Enforce TLS comparator labels (B3/B4/B5/B6/B7) and per-row buffer/transport/allocator model labelling per `docs/tls-zero-copy-benchmark-matrix.md`.
argument-hint: TLS JMH benchmark / TLS row / TLS report change to audit
---

Audit this TLS work against the comparator label discipline.

TLS labels (per repo `CLAUDE.md`):
- `B3`: JDK `SSLEngine` baseline (direct).
- `B4`: Netty `SslHandler` + `EmbeddedChannel` over netty-tcnative (pipeline path; not split into B4a/B4b).
- `B5`: Exeris `OffHeapTlsEngine` engine-level lens via neutral in-process Memory-BIO harness.
- `B6`: Exeris SPI-native `TlsEngine` under FD-owner ownership model — real loopback socket (includes kernel I/O).
- `B7`: Exeris Memory-BIO path (in-process).

Primary engine-level comparator set is **B3/B4/B5**; `B6` is integration-level with explicit transport-wiring caveats.

Per-row required labels:
- buffer model, transport model, allocator model (GC-managed / pooled-direct / off-heap).

Cross-row claims require: ops/s, sample-time latency (p50/p95/p99), `gc.alloc.rate.norm`, JFR `ObjectAllocationSample` stacks, CPU hotspot profile, RSS + native footprint snapshot, and RSS@`@Setup`-end vs RSS@measurement-end delta.

TLS provider/memory/cert config uses tier-specific-then-global precedence (`exeris.tls.<tier>.X` → `exeris.tls.X`, with a backward-compatible alias chain — see `micro/jmh/README.md`).

Change:
$ARGUMENTS

Please review:
1. Are all rows labelled B3/B4/B5/B6/B7 unambiguously?
2. Does each row carry buffer / transport / allocator model labels?
3. For cross-row claims: are ALL required metrics present (ops/s, p50/p95/p99, alloc rate, JFR stacks, CPU hotspot, RSS delta)?
4. Is B6 transport-wiring caveat explicit (loopback socket, includes kernel I/O)?
5. Is B3 vs B4 NOT framed as handler-free apples-to-apples? Is B3/B4 vs B5/B6 difference stated?
6. Are TLS config keys aligned with the tier-then-global precedence?
7. Minimal correction if label discipline is at risk.

Don't collapse rows across these labels without stating wiring differences.
