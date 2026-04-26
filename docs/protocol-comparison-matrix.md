# Protocol Comparison Matrix

This document defines how Exeris protocol benchmarking is reported to avoid
mixing protocol effects with tier effects.

---

## Axis A — Within-target protocol comparison

### Community (open-core)

- `community-h1-*` vs `community-h2-*`

Question answered:

- What is the protocol/transport impact *within Community*?

---

## Axis B — Cross-runtime same-protocol comparison

- `exeris-community-h1-*` vs `spring-h1-*`
- `exeris-community-h1-*` vs `quarkus-h1-*`
- `spring-h1-*` vs `quarkus-h1-*`
- `exeris-community-h2-*` vs `spring-h2-*`
- `exeris-community-h2-*` vs `quarkus-h2-*`
- `spring-h2-*` vs `quarkus-h2-*`

Question answered:

- What is the implementation/runtime impact at the same protocol level?

---

## Required report sets

1. **Community-only protocol report** (`H1 vs H2`)
2. **Cross-runtime same-protocol report** (`H1`, `H2`)

---

## Core scenarios (all protocol-capable targets)

- `plaintext`
- `json-1kb`
- `json-10kb`
- `routing-404`
- `exception-mapping`
- `concurrent-32`
- `concurrent-256`
- `keepalive-steady`
- `cold-connect-single`
- `entity-read-by-id` (transaction-oriented DB read path)
- `e2e-shop-order-saga` (stateful E2E order+saga path; claim-scope caveats apply)

Additional:

- H2: `multiplex-32`, `multiplex-mixed`
- Compatibility mode (when exposed by target): `tx-commit`, `tx-rollback`

---

## Mandatory metadata in normalized results

Each result JSON should contain:

- `target.tier`: `community`
- `target.protocol`: `h1` | `h2`
- `comparison_axis`: `within-target` | `cross-runtime-same-protocol` | `standalone`

---

## Top comparative reports

1. `community h1 vs h2` baseline
2. `community h1 cross-runtime` (Exeris/Spring/Quarkus)
3. `community h2 cross-runtime` (Exeris/Spring/Quarkus)
4. `json-1kb` and `plaintext` cross-matrix summaries
5. `e2e-shop-order-saga` protocol/cross-runtime summary with explicit claim-scope labels
6. Transaction compatibility summary (`tx-commit`/`tx-rollback`) when compatibility endpoints are enabled
