# Destructive / Fuzz / Chaos Methodology

This document covers methodology for the destructive scenario family added in May 2026:

- `fuzz-http1-parser`, `fuzz-http2-parser` — Jazzer fuzz campaigns
- `destructive-slowloris-h1` — slow-headers attack
- `destructive-radamsa-h1`, `destructive-radamsa-h2` — mutated-input attacks
- `arena-lifecycle-leak` — sustained malformed load with RSS / NMT / leak-count delta

## Scope and boundary

These scenarios are **exploratory**. They surface bugs and regressions; they do not produce comparative performance claims. Every result emits `claim_scope=exploratory`, `comparison_axis=standalone`, and `execution_class=exploratory`. The result schema accepts these values (`schemas/benchmark-result.schema.json:107`) and `tools/verify-classification.sh:31` was patched to align with the schema.

Boundary against product repos (per `CLAUDE.md`):

| Question | Where it lives |
|---|---|
| "Does parser X handle byte sequence Y?" (unit-style regression) | `exeris-kernel/` |
| "Did this PR introduce a new crash?" (CI merge gate) | `exeris-kernel/` |
| "Are there *any* inputs that crash parser X over a 60-minute campaign?" | here |
| "Does the kernel evict half-open connections under sustained slowloris?" | here |
| "Does the request lifecycle leak Arenas on malformed input?" | here |

A single-input crash regression added here would let a kernel bug ship undetected; merge gates are owned by product repos, not by the benchmark lab.

## Tier and protocol scope

- **Tier**: Community only. Enterprise destructive equivalents (io_uring SQE chaos, H3/QUIC parser fuzz) belong under `enterprise/scenarios/` and are out of scope for this work.
- **Protocol**: H1 and H2 (cleartext for H2; H2C). HTTP/3 is Enterprise-only per ADR-006 and is not covered.
- **Pure vs Compat**: Destructive scenarios run against Pure-mode targets only. Compat-mode results would mix runtime semantics with parser semantics — comparison meaningless.

## Mandatory axes (per benchmark family)

| Scenario | tier | benchmark_family | transport | target_classification |
|---|---|---|---|---|
| `fuzz-http1-parser` | community | micro | none | micro-parser-robustness |
| `fuzz-http2-parser` | community | micro | none | micro-parser-robustness |
| `destructive-slowloris-h1` | community | runtime | h1 (loopback) | runtime-destructive-slow-resource-exhaustion |
| `destructive-radamsa-h1` | community | runtime | h1 (loopback) | runtime-destructive-malformed-input |
| `destructive-radamsa-h2` | community | runtime | h2 (loopback, H2C) | runtime-destructive-malformed-input |
| `arena-lifecycle-leak` | community | runtime | h1 (loopback) | runtime-resource-arena-lifecycle |

Cross-stack runtime destructive runs (e.g. Exeris vs Spring Boot vs Quarkus) are NOT comparable without explicit normalization of:

1. **Header-receive timeout** (for slowloris).
2. **Max concurrent connections / streams** (for slowloris and H2 radamsa).
3. **Radamsa seed** (for radamsa H1 and H2 — same seed produces the same byte sequence).
4. **Target heap size, GC config, NMT mode** (for arena-lifecycle-leak).

Every cross-stack report row MUST label these parameters. Without them the comparison is apples-to-oranges.

## Liveness probe contract

`destructive-slowloris-*`, `destructive-radamsa-*`, and `arena-lifecycle-leak` MUST end with a clean-traffic liveness probe:

```
GET ${BASE_URL}${HEALTH_PATH}   # default /health
```

The probe asserts:

- `status_code == 200`
- `duration_ms <= 1000`

A failed probe maps to `degradation_class=timeout-flood` (or `crash` if the connection refused). A passing probe with elevated `RSS_DELTA` maps to `degradation_class=leak-suspected`.

The probe is reusable: `tools/bench/lib/destructive.sh::destructive_liveness_probe`.

## Reproducibility requirements

| Scenario | Required for reproducibility |
|---|---|
| `fuzz-http1-parser`, `fuzz-http2-parser` | `jazzer.version` (pinned in pom.xml), `exeris.kernel.version` (pinned snapshot SHA, not `-SNAPSHOT`), seed corpus SHA-256 |
| `destructive-radamsa-*` | radamsa version, `--radamsa-seed`, seed-request bytes SHA-256 |
| `destructive-slowloris-h1` | slowloris.py SHA-256, `connection_count`, `header_delay_seconds`, `attack_duration_seconds` |
| `arena-lifecycle-leak` | All of the above + target JVM flags (especially `-XX:NativeMemoryTracking=*` mode) |

A campaign without these values is `descriptive_only`, not `exploratory` — it can describe what happened but cannot be re-bisected.

## Confidentiality

Destructive runs produce artifacts that may contain attacker-supplied bytes:

- `crash-<sha1>` (Jazzer)
- `hang-<sha1>` (Jazzer)
- `*.radamsa` (radamsa raw mutations)
- `*.fuzz-input` (other crash inputs)
- Raw JFR recordings covering attack windows

`scripts/publish-report.sh` blocks these by basename pattern in `public` and `redacted` modes (`is_destructive_crash_input()`). Destructive findings sidecars stamp `publication_mode: internal-only` in the schema; the publisher refuses to bundle them otherwise.

The two safety nets must agree: if you add new attack tooling, extend `is_destructive_crash_input` in `publish-report.sh` AND verify the sidecar locks `publication_mode` to `internal-only`. Either gate alone is fragile.

## Tolerance defaults

| Signal | Default tolerance |
|---|---|
| `rss_growth_pct_max` | 5% over the attack window |
| `native_heap_committed_growth_pct_max` | 10% (only when NMT enabled on target) |
| `max_unexpected_crashes` | 0 |
| `max_hang_count` | 0 (slowloris is special — `connections_dropped` is the equivalent signal) |
| `liveness_probe.expected_max_response_ms` | 1000 ms |

These are scenario defaults. Per-target overrides go in the scenario JSON's `tolerance` block, not in the scripts.

## What this work does NOT cover

- **TLS-level fuzz** — TLS handshake fuzzing is its own track; see `docs/tls-zero-copy-benchmark-matrix.md`. Mixing TLS bytes-on-the-wire with a radamsa mutator means mutations get rejected by the TLS record layer before reaching the H2 parser; the test stops testing what it claims.
- **Application-layer fuzz** — `/api/v1/users` JSON body fuzz is out of scope. Adding it would require a dedicated `application-fuzz` family with a different target_classification (`runtime-app-handler-robustness`).
- **Multi-target chaos** (kill -9 on one of two nodes) — Exeris is single-node in scope here; clustered chaos belongs to a future enterprise track.
- **Network-layer chaos** — `tc netem` already exists in `scenarios/lossy-network`. Destructive scenarios stack on TCP/HTTP, not IP/UDP.
