# Protocol Comparison Matrix

This document defines how Exeris protocol benchmarking is reported to avoid
mixing protocol effects with tier effects.

---

## Axis A — Within-tier protocol comparison

### Community (open-core)

- `community-h1-*` vs `community-h2-*`

Question answered:

- What is the protocol/transport impact *within Community*?

### Enterprise

- `enterprise-h1-*` vs `enterprise-h2-*` vs `enterprise-h3-*`

Question answered:

- What is the protocol/transport impact *within Enterprise*?
- Does `H3` provide value over `H2` fallback?

---

## Axis B — Cross-tier same-protocol comparison

- `community-h1-*` vs `enterprise-h1-*`
- `community-h2-*` vs `enterprise-h2-*`

Question answered:

- What is the edition/tier implementation impact at the same protocol level?

Important:

- `H3` is Enterprise-only and must not be treated as direct cross-tier comparator.

---

## Required report sets

1. **Community-only protocol report** (`H1 vs H2`)
2. **Enterprise-only protocol report** (`H1 vs H2 vs H3`)
3. **Cross-tier same-protocol report** (`H1`, `H2`)

---

## Core scenarios (all protocol-capable targets)

- `plaintext-hello`
- `json-1kb`
- `json-10kb`
- `routing-404`
- `exception-mapping`
- `concurrent-32`
- `concurrent-256`
- `keepalive-steady`
- `cold-connect-single`

Additional:

- H2/H3: `multiplex-32`, `multiplex-mixed`
- H3: `handshake-cold`, `lossy-network`

---

## Mandatory metadata in normalized results

Each result JSON should contain:

- `target.tier`: `community` | `enterprise`
- `target.protocol`: `h1` | `h2` | `h3`
- `comparison_axis`: `within-tier` | `cross-tier-same-protocol` | `standalone`

---

## Top comparative reports

1. `community h1 vs h2` baseline
2. `enterprise h1 vs h2 vs h3` transport report
3. `community h1 vs enterprise h1`
4. `community h2 vs enterprise h2`
5. `enterprise h2 vs h3`
6. `json-1kb` and `plaintext-hello` cross-matrix summaries
