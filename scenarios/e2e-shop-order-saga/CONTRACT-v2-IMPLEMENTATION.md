# CONTRACT-v2 Implementation Status — e2e-shop-order-saga

| Field | Value |
|---|---|
| Contract | `CONTRACT-v2.md` v2.0 (DRAFT) |
| Scope of this ledger | The current change set only (branch `claude/exeris-benchmarks-droplets-5fd00e`), not overall contract compliance |
| Purpose | Anti-overclaim ledger: what of v2 is actually implemented right now, what is partial, what is deferred. Any claim in a report that relies on a `partial` or `deferred` row MUST carry the corresponding caveat |
| Last updated | 2026-07-16 (statuses verified against the change-set source, not against run evidence) |

Status enum: **implemented-now** (in this change set, exercisable end-to-end) ·
**partial** (some normative requirements of the section met, others not) ·
**deferred** (not in this change set; no claims may depend on it).

Stack labels used below map to targets as follows:
`exeris-community` → `targets/exeris-community-app`;
`spring-axon` → `targets/spring-benchmark-app`;
`quarkus` ×2 → `targets/quarkus-benchmark-app` and
`targets/quarkus-benchmark-app-tuned`;
`spring-on-exeris` → `targets/exeris-spring-runtime-app-comp`.
The Restate stack has no target directory yet (see its row).

## Status matrix

| Contract section | Status | Implemented in this change set | Honest gap / what is NOT done |
|---|---|---|---|
| §1 Unit of comparison | partial | Deployment units exercised for exeris-community, spring-axon, quarkus ×2, spring-on-exeris | Restate deployment unit absent (see Restate row). Whole-deployment footprint *measurement* is a §8 gap, not a §1 gap |
| §2 Scenario definition | partial | v1 carry-over workload unchanged (step sequence, payload, VU/think-time per `k6.env`); Neo4j pinned as graph track in the campaign runner | Cross-stack identical-domain-write parity is asserted by construction; it was not independently re-audited in this change set |
| §3 Order identity / request model | implemented-now | k6 orderId derivation is seeded and deterministic: `${K6_ORDER_SEED}-${scenario}-i${iterationInTest}` with the fixed seed `exeris-saga-v2` pinned in `k6.env`, so a given (scenario, iteration index) maps to the same orderId in every run against every stack. orderId doubles as the idempotency key (`Idempotency-Key` header sent; Exeris flow key / Axon association value on the server side) | The *issued* set equals the full deterministic set only when every VU session reaches order creation; sessions that abort earlier (register/cart failures) shrink the issued set run-to-run. Expected-count tooling must therefore work from the actually-issued population — see the §7 gate-wiring caveat |
| §4.1 Business-terminal fault | implemented-now | `stableHash64` pinned normatively to FNV-1a 64-bit (§4.1 implementation note in the contract). Deterministic per-orderId decline predicate implemented server-side with bit-identical constants in exeris-community, spring-axon, quarkus (baseline + tuned), and spring-on-exeris; constants locked by `OrderSagaFaultModelTest` (exeris-community) and `fnv1a64.py --self-test` (canonical FNV vectors); pre-v2 probabilistic knobs are accepted-but-ignored with startup warnings | Restate mapping (`TerminalException` path) not implemented (stack deferred). Cross-stack bit-identity is enforced by a unit test in only one stack; the other four rely on code review. "Never retried" is corroborated only by §5 configuration plus the interim §7 count gate, not by a per-attempt oracle |
| §4.2 Transient infrastructure fault | deferred | Policy configuration only: the §5 retry settings a transient run would use, plus runner plumbing (`--fault-mode transient` labels the run and flips the §7 gate to the inverse assertion expected-compensations = 0) | No transient-fault injector exists in any stack; no `fault=transient` runs are meaningful yet; the inverse assertion (transient faults produce zero compensations) is plumbed but exercises nothing |
| §5 Retry policy | partial (pinned as config where expressible) | Terminal decline = zero retries on all five targets by construction: the decline is modeled as a value/event (`FlowOutcome.FAIL`, `PaymentDeclinedEvent`), never as an exception, so it cannot reach any retry machinery. Transient-retry policy pinned explicitly per stack: spring-axon — Axon `ExponentialBackOffIntervalRetryScheduler` on the CommandGateway, 50 ms initial, factor 2, maxRetryCount 2 (`AxonBusConfig`); quarkus ×2 — deliberately NO Axon RetryScheduler; in-service `OrderSagaRetryPolicy` (3 attempts total, 50 ms initial, factor 2, no jitter), exhaustion routes to backward recovery / `FAILED_UNRECOVERED`; exeris-community and spring-on-exeris — retry *budget* pinned via `maxRetries(2)` in the flow definition | On the two Exeris-flow stacks the pinned backoff shape (exponential, 50 ms initial, factor 2, no jitter) is NOT expressible in exeris-kernel-spi 0.10.0 — the builder exposes only `maxRetries`/`timeoutDuration`, recorded as in-code TODOs — and no consumer of `FlowDefinition.maxRetries` was found in the kernel 0.10.0 flow runtime, so even budget *enforcement* is unverified there. Everything is config-level: no transient injector exists (§4.2), so retry behavior (budget, backoff timing, exhaustion routing) is unexercised on every stack |
| §6 Three guarantees | partial | G2 verified at *count* level via the interim §7 gate; G3 approximated client-side: terminal-outcome resolution is threshold-enforced (`saga_status_resolved > 0.98`, `saga_unresolved < 0.01`, poll budget 25 × 1 s), not guaranteed per-orderId | No per-orderId compensation ledger, no LIFO-order verification (G2 set/order semantics unverified); no post-run drain scan (G3 as specified — a thresholded client-side approximation is weaker than "every issued orderId"); no crash injection (W3), so G1 "despite crash injection" is not exercised |
| §7 Oracles (external, shared) | deferred | **Interim substitute:** exact compensation-count gate in `run-e2e-shop-order-saga-baseline.sh` — expected count computed from the seeded population with `fnv1a64.py` (same pinned FNV-1a 64-bit function) and compared for exact-integer equality against `saga_compensated_total` from the k6 summary; hard pass/fail, emitted as a correctness-gate JSON; zero observed compensations counts as 0, not as "skip" (the v1 Axon defect class fails the gate) | No external oracle service exists. The interim gate is a count-granularity approximation of O2 only and is **strictly weaker** than the full oracle: no per-`(orderId, stepId, direction)` ledger, no LIFO sequence check, no O1 duplicate-execution detection, no O3 orphaned-effect detection — a stack could pass the count gate while violating O1/O3. **Known wiring gap:** the gate regenerates the expected population via `fnv1a64.py --seed/--count` using the helper's default `order-{seed}-{index}` template and a single dense 0..N−1 index sequence, but k6 derives ids as `${seed}-${scenario}-i${index}` across three scenarios (warmup/measurement/cooldown) and aborted sessions make issuance non-dense. Until the invocation passes the matching format and per-scenario counts (or `--ids-file` with the actually-issued ids), the regenerated population is not the issued population and a gate PASS/FAIL is not yet evidence about §4.1 |
| §8 Metrics and reporting split | partial | Implemented: latency split by outcome population (`COMPLETED` vs `COMPENSATED`) at p50/p99 via dedicated k6 Trends (`saga_completed_duration` / `saga_compensated_duration`) consumed by the baseline runner and `run-summary.sh`; throughput as ops/s and ops/s/core (effective-core detection: cgroup quota > explicit override > nproc); run labeling `fault=terminal` \| `fault=transient` stamped into gate and result JSON | Deferred: full HdrHistogram artifacts; p999/max per population; Σ RSS whole-deployment footprint rollup (incl. Axon Server / Neo4j processes); setup-time (`git clone` → first contract run) metric. Caveat on what IS implemented: outcome-split p50/p99 come from the k6 end-of-run summary, i.e. aggregated over warmup+measurement+cooldown, not filtered to the measurement phase — label them whole-run. Not addressed by this change set (unchanged, not re-audited here): durability-tier declaration per run; ≥ 5 measured-run variance reporting; allocations/op and GC pause totals |
| §9 Per-stack deviation register | partial | Stub register per stack added in **Appendix A of this file** (headings (a)–(d) per contract §9); only (c) retry-configuration entries carry code-verified content | (a) idiom deviations, (b) administrative-termination semantics, and (d) adversarial tuning are unpopulated/unaudited for every stack, and the register lives in this ledger rather than in the per-stack report sections the contract requires. Reports must not cite §9 compliance until entries are filled and moved into the report |
| §10 Retroactive validity of v1 results | deferred | None (policy text only, in the contract) | No v1 results re-labeled as `COMPLETED`-population metrics; no §4.1 re-tests of the v1 Axon compensation finding performed here. v1 mixed-population tables remain non-citable |
| Restate stack (all sections) | deferred | Nothing — no service implementation, no `restate-server` deployment, no k6 target wiring | All Restate rows in the contract (deployment unit, §4.1 `TerminalException` mapping, §5 retry pinning, G3 `kill`/`cancel` disclosure) are normative-only. No comparative table may include Restate |

§11 (change log) is contract bookkeeping, not an implementable section; it is
excluded from the matrix.

## Claim guardrails implied by this matrix

Until the corresponding rows move to `implemented-now`:

1. Compensation-correctness claims must be phrased as **count-level** ("observed
   compensation count equals the exact expected integer"), never as O1/O2/O3
   compliance, exactly-once verification, or LIFO-order verification — and only
   from a gate invocation whose regenerated population provably matches the
   issued orderId population (matching format + per-scenario counts, or
   `--ids-file`); see the §7 wiring gap.
2. No headline latency claims beyond p50/p99 per outcome population; no
   p999/max/tail-artifact claims. Outcome-split percentiles from the end-of-run
   k6 summary must be labeled whole-run unless phase-filtered.
3. No whole-deployment footprint, setup-time, or `fault=transient` claims.
4. No Restate comparisons, in tables or prose.
5. §5 compliance may be claimed only as "pinned by configuration"; on the
   Exeris-flow stacks (exeris-community, spring-on-exeris) only the retry
   *budget* is pinned — the backoff shape is not currently expressible in the
   kernel SPI and budget enforcement is unverified. Retry *behavior* under
   transient faults is unverified on every stack.

## Appendix A — §9 per-stack deviation register (stubs)

Pre-report scaffolding for contract §9. Every entry marked TODO is
**unpopulated and unaudited**; only the (c) entries reflect code verified in
this change set. Contract §9 requires this register to appear in the report
per stack; these stubs do not satisfy that requirement by themselves.

### exeris-community (`targets/exeris-community-app`)

- (a) Idiom deviations from contract wording: TODO — not audited. Candidate to
  document: kernel-level flow compensation (engine-native unwind) vs the
  contract's step/compensation wording.
- (b) Administrative-termination semantics (G3 asterisk): TODO — hard-abort
  path not documented or audited.
- (c) §5 retry configuration (code-verified): `OrderSagaOrchestrator` flow
  definition pins `maxRetries(2)`; terminal decline returns `FlowOutcome.FAIL`
  → compensation, exempt from retries. Pinned backoff shape not expressible in
  exeris-kernel-spi 0.10.0 (in-code TODO); `maxRetries` enforcement unverified.
- (d) Adversarial tuning applied in the stack's favor: TODO — none recorded.

### spring-axon (`targets/spring-benchmark-app`)

- (a) TODO. Candidate: decline explicitly modeled as `PaymentDeclinedEvent`
  routed to saga compensation (the §4.1 per-stack mapping requirement).
- (b) TODO.
- (c) §5 retry configuration (code-verified): `AxonBusConfig` registers an
  `ExponentialBackOffIntervalRetryScheduler` (initial 50 ms, factor 2,
  maxRetryCount 2) on an explicitly built CommandGateway; declines are events,
  not exceptions, so they cannot reach the scheduler.
- (d) TODO.

### quarkus (`targets/quarkus-benchmark-app`)

- (a) TODO.
- (b) TODO.
- (c) §5 retry configuration (code-verified): deliberately NO Axon
  RetryScheduler (`AxonBusConfig`); retries are in-service via
  `OrderSagaRetryPolicy` (3 attempts total, 50 ms initial, factor 2, no
  jitter); exhaustion raises `RetryExhaustedException`, routed to backward
  recovery / `FAILED_UNRECOVERED` by the command handler.
- (d) TODO.

### quarkus-tuned (`targets/quarkus-benchmark-app-tuned`)

- (a) TODO.
- (b) TODO.
- (c) §5 retry configuration (code-verified): same mechanism as quarkus
  baseline (`OrderSagaRetryPolicy`, no Axon RetryScheduler).
- (d) TODO — **required before any tuned-row claim**: the full tuning delta vs
  the quarkus baseline target must be enumerated here.

### spring-on-exeris (`targets/exeris-spring-runtime-app-comp`)

- (a) TODO.
- (b) TODO.
- (c) §5 retry configuration (code-verified): `ShopOrderFlowDefinition` pins
  `maxRetries(2)`; same exeris-kernel-spi 0.10.0 limitation as
  exeris-community (backoff shape not expressible, enforcement unverified;
  in-code TODO). Timeout stays at the kernel default — §5 pins retry policy
  only.
- (d) TODO.

### Restate

No stub — no target exists in this repository; a register entry is
impossible until the stack lands. This absence is itself the §9 record.
