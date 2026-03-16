# targets/exeris-kernel/enterprise

This directory contains configuration for running benchmarks against the
**Exeris Kernel Enterprise** target.

## Benchmark focus

- `io_uring` ingress path
- QUIC (HTTP/3) transport
- TLS wrap/unwrap throughput
- Slab allocation/release cycles
- Native persistence handoff

## Notes

- Requires `EXERIS_ENTERPRISE_IMAGE` env var or locally built image.
- TLS handshake benchmarks: use fresh engine instances per invocation.
  Do **not** reuse `SSLEngine` across benchmark iterations — see
  [methodology.md](../../../docs/methodology.md) and user memory note on
  TLS handshake probe stability.
- QUIC benchmarks require a QUIC-capable client (e.g., `msquic`, `quiche`).
  h2load does not support QUIC natively.

## Public/private execution boundary

This directory contains **public scenario contracts** only.

- Keep proprietary launch wiring in private enterprise repos/extensions.
- Use `START_MODE=external` with `EXTERNAL_START_CMD` / `EXTERNAL_STOP_CMD`
  in `runtime/drivers/env/<target>.env`.
- Publish only normalized results and summaries; avoid raw private traces.

Contract references:

- Schema: `schemas/enterprise-target-contract.schema.json`
- Example: `targets/exeris-kernel/enterprise/target-contract.example.json`
