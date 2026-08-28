# CONTRACT-v2 Implementation Status — e2e-shop-order-saga

| Field | Value |
|---|---|
| Contract | `CONTRACT-v2.md` v2.0 (DRAFT) |
| Scope of this ledger | The current change set only (branch `claude/exeris-benchmarks-droplets-5fd00e`), not overall contract compliance |
| Purpose | Anti-overclaim ledger: what of v2 is actually implemented right now, what is partial, what is deferred. Any claim in a report that relies on a `partial` or `deferred` row MUST carry the corresponding caveat |
| Last updated | 2026-07-30 — surface reconciliation only (README v2.0 banner + stack roster, `docs/scenario-catalog.md` entry, `docs/benchmark-target-labels-and-scenario-contracts.md` restate + saga-v2 fields, §10 v1 raw-run re-classification, caveated `contract_revision:2.0` pointers in `scenario.json`/manifest). No harness/target/oracle code changed; the §1–§9 statuses below are unchanged since 2026-07-17 and were verified against the change-set source, not against run evidence |

Status enum: **implemented-now** (in this change set, exercisable end-to-end) ·
**partial** (some normative requirements of the section met, others not) ·
**deferred** (not in this change set; no claims may depend on it).

Stack labels used below map to targets as follows:
`exeris-community` → `targets/exeris-community-app`;
`spring-axon` → `targets/spring-benchmark-app`;
`quarkus` ×2 → `targets/quarkus-benchmark-app` and
`targets/quarkus-benchmark-app-tuned`;
`spring-on-exeris` → `targets/exeris-spring-runtime-app-comp`;
`restate` → `targets/restate-benchmark-app`.

## Status matrix

| Contract section | Status | Implemented in this change set | Honest gap / what is NOT done |
|---|---|---|---|
| §1 Unit of comparison | partial | Deployment units exercised for exeris-community, spring-axon, quarkus ×2, spring-on-exeris, restate (restate = target JVM + external `restate-server`, started by the baseline as compose service `benchmark-restate-server` with per-container docker-stats attribution, same policy as Axon Server) | Whole-deployment footprint *measurement* is a §8 gap, not a §1 gap |
| §2 Scenario definition | partial | v1 carry-over workload unchanged (step sequence, payload, VU/think-time per `k6.env`); Neo4j pinned as graph track in the campaign runner | Cross-stack identical-domain-write parity is asserted by construction; it was not independently re-audited in this change set |
| §3 Order identity / request model | implemented-now | k6 orderId derivation is seeded and deterministic: `${K6_ORDER_SEED}-${scenario}-i${iterationInTest}` with the fixed seed `exeris-saga-v2` pinned in `k6.env`, so a given (scenario, iteration index) maps to the same orderId in every run against every stack. orderId doubles as the idempotency key (`Idempotency-Key` header sent; Exeris flow key / Axon association value on the server side) | **Terminal-outcome resolution model is NOT uniform across stacks** (measurement-model asymmetry): restate and quarkus ×2 return the terminal outcome inline in the `POST /api/v1/orders` 200 body (v2 request-response model — k6 skips the poll loop), while spring-axon, exeris-community and spring-on-exeris resolve via `GET /api/v1/orders/:id/status` polling with a 1 s sleep between attempts, so their end-to-end saga durations include up-to-1 s poll quantization the inline stacks never pay. Any cross-stack latency comparison spanning the two models is FORBIDDEN unless it carries a caveat naming each stack's resolution model (inline vs polled); prefer same-model comparisons or per-row resolution-model labels — see the §8 caveat. Separately: the *issued* set equals the full deterministic set only when every VU session reaches order creation; sessions that abort earlier (register/cart failures) shrink the issued set run-to-run. Expected-count tooling must therefore work from the actually-issued population — see §7 (the gate now fails closed on non-dense populations) |
| §4.1 Business-terminal fault | implemented-now | `stableHash64` pinned normatively to FNV-1a 64-bit (§4.1 implementation note in the contract). Deterministic per-orderId decline predicate implemented server-side with bit-identical constants in exeris-community, spring-axon, quarkus (baseline + tuned), and spring-on-exeris; constants locked by `OrderSagaFaultModelTest` (exeris-community) and `fnv1a64.py --self-test` (canonical FNV vectors); pre-v2 probabilistic knobs are accepted-but-ignored with startup warnings. Restate mapping implemented: own bit-identical FNV-1a 64 decline rule, decline thrown as `TerminalException` (never retried at either Restate layer), constants + k6 population oracle locked by the target's unit tests (mirrors `PaymentDeclineRuleTest`, incl. `exeris-saga-v2-measurement-i0..9999 → 312 declines`) | Cross-stack bit-identity is enforced by unit tests in two stacks (exeris-community, restate); the other four rely on code review. "Never retried" is corroborated only by §5 configuration plus the interim §7 count gate, not by a per-attempt oracle |
| §4.2 Transient infrastructure fault | deferred | Policy configuration only: the §5 retry settings a transient run would use, plus runner plumbing (`--fault-mode transient` labels the run and flips the §7 gate to the inverse assertion expected-compensations = 0) | No transient-fault injector exists in any stack; no `fault=transient` runs are meaningful yet; the inverse assertion (transient faults produce zero compensations) is plumbed but exercises nothing |
| §5 Retry policy | partial (pinned as config where expressible) | Terminal decline = zero retries on all six targets: on five by construction — the decline is modeled as a value/event (`FlowOutcome.FAIL`, `PaymentDeclinedEvent`), never as an exception, so it cannot reach any retry machinery; on restate the decline IS an exception (`TerminalException`), which Restate by documented semantics never retries at either layer. restate transient retry pinned at BOTH layers: per-step `RetryPolicy.exponential(50 ms, 2).setMaxAttempts(3)` on every journaled `Restate.run` block (forward steps AND compensations) plus an SDK-declared service-level invocation retry policy (initial 50 ms, factor 2, maxAttempts 3, onMaxAttempts=KILL) so server defaults (max-attempts=70, on-max-attempts=pause) are never trusted; no jitter knob exists in Restate — deterministic exponential backoff is exactly the §5 no-jitter requirement. Transient-retry policy pinned explicitly per stack: spring-axon — Axon `ExponentialBackOffIntervalRetryScheduler` on the CommandGateway, 50 ms initial, factor 2, maxRetryCount 2 (`AxonBusConfig`); quarkus ×2 — deliberately NO Axon RetryScheduler; in-service `OrderSagaRetryPolicy` (3 attempts total, 50 ms initial, factor 2, no jitter), exhaustion routes to backward recovery / `FAILED_UNRECOVERED`; exeris-community and spring-on-exeris — retry *budget* pinned via `maxRetries(2)` in the flow definition | On the two Exeris-flow stacks the pinned backoff shape (exponential, 50 ms initial, factor 2, no jitter) is NOT expressible in exeris-kernel-spi 0.10.0 — the builder exposes only `maxRetries`/`timeoutDuration`, recorded as in-code TODOs — and no consumer of `FlowDefinition.maxRetries` was found in the kernel 0.10.0 flow runtime, so even budget *enforcement* is unverified there. Everything is config-level: no transient injector exists (§4.2), so retry behavior (budget, backoff timing, exhaustion routing) is unexercised on every stack |
| §6 Three guarantees | partial | G2 verified at *count* level via the interim §7 gate; G3 approximated client-side: terminal-outcome resolution is threshold-enforced (`saga_status_resolved > 0.98`, `saga_unresolved < 0.01`, poll budget 25 × 1 s), not guaranteed per-orderId | No per-orderId compensation ledger, no LIFO-order verification (G2 set/order semantics unverified); no post-run drain scan (G3 as specified — a thresholded client-side approximation is weaker than "every issued orderId"); no crash injection (W3), so G1 "despite crash injection" is not exercised |
| §7 Oracles (external, shared) | deferred | **Interim substitute:** exact compensation-count gate in `run-e2e-shop-order-saga-baseline.sh` — expected count computed from the seeded population with `fnv1a64.py` (same pinned FNV-1a 64-bit function) and compared for exact-integer equality against `saga_compensated_total` from the k6 summary; hard pass/fail, emitted as a correctness-gate JSON; zero observed compensations counts as 0, not as "skip" (the v1 Axon defect class fails the gate) | No external oracle service exists. The interim gate is a count-granularity approximation of O2 only and is **strictly weaker** than the full oracle: no per-`(orderId, stepId, direction)` ledger, no LIFO sequence check, no O1 duplicate-execution detection, no O3 orphaned-effect detection — a stack could pass the count gate while violating O1/O3. **Population wiring is now matched** (previous gap closed): the gate derives per-scenario issued counts from the k6 NDJSON stream and invokes `fnv1a64.py --seed/--counts` with the helper's default template `{seed}-{scenario}-i{index}`, which is lockstep-guarded against `generateOrderId()` in k6.js by `--self-test`; density is checked per scenario (completed iterations vs `saga_issued_total`) and the gate fails closed to `error` — never PASS — when the issued index set is non-dense, per-scenario samples are missing, or the k6 artifacts are inconsistent. **Remaining wiring gap:** the non-dense case is detected but not recovered — the helper's `--ids-file` mode (evaluate over the actually-issued id list) is not wired into the runner, so a run with pre-order-creation aborts yields gate `error` (no §4.1 evidence either way) instead of an exact verdict over the true population |
| §8 Metrics and reporting split | partial | Implemented: latency split by outcome population (`COMPLETED` vs `COMPENSATED`) at p50/p99 via dedicated k6 Trends (`saga_completed_duration` / `saga_compensated_duration`) consumed by the baseline runner and `run-summary.sh`; throughput as ops/s and ops/s/core (effective-core detection: cgroup quota > explicit override > nproc); run labeling `fault=terminal` \| `fault=transient` stamped into gate and result JSON | Deferred: full HdrHistogram artifacts; p999/max per population; Σ RSS whole-deployment footprint rollup (incl. Axon Server / Neo4j processes); setup-time (`git clone` → first contract run) metric. Caveat on what IS implemented: outcome-split p50/p99 come from the k6 end-of-run summary, i.e. aggregated over warmup+measurement+cooldown, not filtered to the measurement phase — label them whole-run. Additionally the saga-duration Trends embed the per-stack terminal-outcome resolution model (§3): on the polled stacks (spring-axon, exeris-community, spring-on-exeris) they include up-to-1 s poll quantization per attempt; on the inline stacks (restate, quarkus ×2) they do not — cross-model latency rows MUST name each stack's resolution model. Durability tier IS now declared per run: the baseline stamps `durability_tier` + `durability_tier_source` (label-only, env-overridable) into run-metadata/result/correctness-gate JSON. Not addressed by this change set (unchanged, not re-audited here): ≥ 5 measured-run variance reporting; allocations/op and GC pause totals |
| §9 Per-stack deviation register | partial | Stub register per stack added in **Appendix A of this file** (headings (a)–(d) per contract §9); (c) retry-configuration entries carry code-verified content on every stack; the restate entry additionally has (a), (b) and (d) populated from code/README review | (a) idiom deviations, (b) administrative-termination semantics, and (d) adversarial tuning remain unpopulated/unaudited for the five pre-existing stacks, and the register lives in this ledger rather than in the per-stack report sections the contract requires. Reports must not cite §9 compliance until entries are filled and moved into the report |
| §10 Retroactive validity of v1 results | partial | v1 raw runs re-classified: `results/raw/e2e-shop-order-saga/README-v1-retroactive-status.md` applies the §10 table to all 23 v1 run dirs (15 baseline + 8 campaign), evidence-classified by the **absence** of v2 gate artifacts (no `fault_class`, `durability_tier`, correctness-gate, FNV oracle, or outcome-split trend in any dir), with a hard no-cross-version-aggregation rule. Shared surfaces reconciled to CONTRACT-v2: README v2.0 banner + stack roster, `docs/scenario-catalog.md` entry, `docs/benchmark-target-labels-and-scenario-contracts.md` (restate baseline-only note + saga-v2 required fields), and a caveated `contract_revision:2.0` pointer in `scenario.json` / `comparative-pair-manifest.json` (machine rows stay v1-active, no v2-compliance claim) | Still deferred: the actual per-run re-labelling of happy-path numbers to `COMPLETED`-population, the recommended §8 outcome-split re-runs, and any §4.1 re-test of the v1 Axon compensation finding. v1 mixed-population latency tables remain non-citable |
| Restate stack (all sections) | implemented-now (baseline-only; NOT comparison-eligible) | `targets/restate-benchmark-app` (Restate JVM SDK 2.9.3 + restate-server 1.7.2): full endpoint/DTO surface of the reference stacks; v2 request-response model (terminal outcome in the `POST /api/v1/orders` 200 body — k6 skips polling); §4.1 `TerminalException` mapping with bit-identical FNV constants (unit-tested, 23/23 pass, incl. the k6 population oracle); §5 retry pinned at both layers; Postgres domain writes SQL-shape-identical to the Axon reference (orders/order_items, inventory reserve/restore, outbox, LIFO compensations refund-payment → restore-inventory); harness wiring: `target-asset-matrix.json` row `restate` (port 9004, h1), `runtime/drivers/env/restate-runtime.env`, compose service `benchmark-restate-server` + admin-API readiness poll + post-readiness force registration + per-container docker-stats sampler in `run-e2e-shop-order-saga-baseline.sh`; live-verified end-to-end (COMPLETED + COMPENSATED + idempotent replay with byte-parity DB effects) | **Not comparison-eligible**: no `fixed_contracts` entry in `scenario.json` and no `comparative-pair-manifest.json` row (it IS whitelisted in `tools/verify-target-asset-matrix.sh` `JUSTIFIED_UNUSED_RUNNABLE_TARGETS` as baseline-only); the baseline runner now FAILS CLOSED if `--target-app restate` is passed without an explicit restate `--contract-id` (the h2c default is never stamped). Facade is HTTP/1.1 → h1-vs-h2c protocol mismatch against canonical contracts (strict-gate disqualifier, same class as spring-on-exeris). Status poll = in-memory sticky-terminal projection (`status_poll_comparison_excluded`, like Axon). Durability: restate-server default = T2 fsync node-durable; §8 forbids cross-tier comparison — declare the tier per run. No `fault=transient` injector (same as every stack) |

§11 (change log) is contract bookkeeping, not an implementable section; it is
excluded from the matrix.

## Live probe evidence — 2026-07-17 (local, dev-laptop class; correctness only, no perf claims)

Environment: Windows 11 + JDK 26.0.1, Docker Desktop; `benchmark-postgres` 16.2 with
v0–v5 seed, `benchmark-axonserver` 2024.2.22 (devmode). Probes drove the k6 request
shapes via curl; ids chosen from the normative decline rule (`"5"` declined, `"1"` not).

- **spring-axon (real Axon Server): §4.1 path confirmed.** Non-declined order →
  `COMPLETED`; declined `"5"` → `COMPENSATED`, `orders` row `CANCELLED`, outbox rows
  exactly `PAYMENT_REQUESTED×2 + ORDER_CONFIRMED×1 + ORDER_COMPENSATED×1`. The v1
  "zero compensations" defect class did not reproduce.
- **quarkus (baseline app, real Axon Server): §4.1 + §3 confirmed.** First request
  after boot dispatched cleanly (the `@Startup` eager-registration fix holds);
  terminal outcome returned **synchronously in the POST body**
  (`{"order_id":"5","status":"COMPENSATED","saga_id":"saga-5"}`) — the v2
  request-response model; client `order_id` honored end-to-end.
- **Axon Server 2024.2 requires explicit cluster init** (`POST
  /v2/cluster/init?initialContext=default`, as the baseline already does) — until
  then apps loop on `AXONIQ-1302 default: not found in any replication group`.
  Container "healthy" ≠ context exists; keep the baseline's init step.
- **spring-axon saga/token stores are IN-MEMORY** as wired today: across two
  completed sagas, `pg_stat_user_tables.n_tup_ins = 0` for `saga_entry`,
  `association_value_entry`, `token_entry` (and `domain_event_entry` — events live
  in Axon Server). The audit-flagged "missing JpaSagaStore DDL" therefore does not
  bite at runtime; the v3 seed now provisions those tables as schema-completeness
  insurance only (see comment in `runtime/db/seed/v3_outbox_axon.sql`).
  **Deviation-register / durability consequence:** spring-axon saga *state* is
  process-volatile (in-memory store + in-memory tracking tokens), while
  exeris-community persists flow state (v5 tables) and restate journals durably —
  a G-guarantee asymmetry that MUST be declared in any future crash-injection (W3)
  work; irrelevant for fault-only runs.

## Claim guardrails implied by this matrix

Until the corresponding rows move to `implemented-now`:

1. Compensation-correctness claims must be phrased as **count-level** ("observed
   compensation count equals the exact expected integer"), never as O1/O2/O3
   compliance, exactly-once verification, or LIFO-order verification — and only
   from a run whose correctness-gate JSON reports `status: pass`. The gate now
   regenerates the population with the matched orderId format and per-scenario
   counts and fails closed (`error`) on non-dense issuance, so `error`/`skipped`
   gate runs support no §4.1 claim in either direction; see §7.
2. No headline latency claims beyond p50/p99 per outcome population; no
   p999/max/tail-artifact claims. Outcome-split percentiles from the end-of-run
   k6 summary must be labeled whole-run unless phase-filtered. Any latency row
   spanning inline-resolution stacks (restate, quarkus ×2) and polled stacks
   (spring-axon, exeris-community, spring-on-exeris) must name the resolution
   model per stack (§3 measurement-model asymmetry; 1 s poll quantization).
3. No whole-deployment footprint, setup-time, or `fault=transient` claims.
4. No Restate *comparisons*, in tables or prose, until the stack is wired as a
   `scenario.json` fixed contract + comparative-pair-manifest row and the
   protocol mismatch (h1 facade vs h2c canonical contracts) is either resolved
   or the comparison is explicitly scoped h1-vs-h1. Descriptive single-stack
   Restate baseline runs are permitted with the durability tier declared.
5. §5 compliance may be claimed only as "pinned by configuration"; on the
   Exeris-flow stacks (exeris-community, spring-on-exeris) only the retry
   *budget* is pinned — the backoff shape is not currently expressible in the
   kernel SPI and budget enforcement is unverified. Retry *behavior* under
   transient faults is unverified on every stack.

## AMENDMENT APPLIED — CONTRACT-v2.md §2 domain-datastore wording

**Status: maintainer-approved and APPLIED to `CONTRACT-v2.md` §2 on
2026-07-17. The record below is kept for provenance; the contract text is
now the normative source.**

Contradiction found in review: contract §2 states *"Neo4j is the shared domain
datastore for all stacks; every stack ... performs the same domain writes
against the same Neo4j instance class and schema."* Every implementation
(exeris-community, spring-axon, quarkus ×2, spring-on-exeris, restate) actually
performs its domain writes (orders/order_items, inventory reserve/restore,
outbox, compensation updates) in **Postgres**; Neo4j serves only the read-side
recommendation step (`GET /api/v1/products/recommended`) and is seeded from the
Postgres seed baseline (`scenarios/e2e-shop-order-saga/seed/seed-neo4j-from-postgres.sh`)
identically for every stack. The contract text and the implemented reality
disagree; until resolved, no report may cite §2 "same writes, same datastore"
compliance with Neo4j named as the domain datastore.

Proposed replacement for the §2 "Resolved in v2.0" sentence:

> **Resolved in v2.0 (amended):** Postgres is the shared DOMAIN datastore for
> all stacks; every stack (including Restate, inside `ctx.run`, and Exeris)
> performs the same domain writes (orders/order_items, inventory
> reserve/restore, outbox, compensation updates) against the same Postgres
> instance class and schema. Neo4j is the shared READ-SIDE recommendation
> graph: it serves the recommendation step identically on every stack, is
> seeded identically from the Postgres seed baseline before each run, and is
> never written to by any saga step.

The adjacent "Graph driver pinned" bullet remains valid as written (it governs
the read-side graph track), but its scope should be understood as the
recommendation read path, not domain writes.

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

### restate (`targets/restate-benchmark-app`)

- (a) Idiom deviations from contract wording (code-verified): compensations
  are a user-space pattern per the official Restate sagas guide — a
  compensation list unwound LIFO in the handler's `TerminalException` catch
  block, not a framework-level unwind; satisfies G2, difference recorded as a
  finding, not a violation. The §4.1 decline is an *exception*
  (`TerminalException`) rather than a value/event as on the other five stacks;
  equivalent because Restate never retries terminal exceptions at either
  layer. v2 request-response model: terminal outcome returned in the order
  POST response body, so k6 normally never exercises the poll path; the status
  endpoint is served from an in-memory sticky-terminal projection (same read
  path class as the Axon stacks; `status_poll_comparison_excluded`). Like the
  Axon stacks, the client `order_id` is echoed on the wire while the DB row is
  keyed by a separate BIGSERIAL id (fairness hazard already documented for the
  reference stacks). Facade protocol is HTTP/1.1 (h1) vs h2c on the canonical
  contracts — strict-gate disqualifier for cross-stack comparisons.
- (b) Administrative-termination semantics (G3 asterisk, documented):
  restate-server exposes `restate invocations cancel` (compensating
  cancellation) and `kill` (no compensation). Neither is exercised in
  benchmark runs.
- (c) §5 retry configuration (code-verified): pinned at BOTH layers — per-step
  `RetryPolicy.exponential(50 ms, 2).setMaxAttempts(3)` on every journaled
  `Restate.run` block (forward steps and compensations), plus an SDK-declared
  service-level invocation retry policy (initial 50 ms, factor 2,
  maxAttempts 3, onMaxAttempts=KILL) overriding the server defaults
  (max-attempts=70, on-max-attempts=pause). `EXERIS_SAGA_RETRY_JITTER` is
  accepted-but-ignored with a warning: Restate has no jitter knob; its
  deterministic exponential backoff is the §5 no-jitter requirement.
  Compensation retry-budget exhaustion terminates the saga
  `FAILED_UNRECOVERED` (§7 O3). Registration of the pinned policy was
  live-verified via the admin API.
- (d) Adversarial tuning applied in the stack's favor: none recorded.
  Deployment-unit caveat the other direction: restate-server 1.7 runs its
  default durability (replicated loglet, RocksDB WAL fsync per commit batch =
  T2 fsync node-durable, comparable to Postgres `synchronous_commit=on`);
  setting `RESTATE_LOG_SERVER__ROCKSDB_DISABLE_WAL_FSYNC=true` would be
  favorable tuning and MUST relabel the run's durability tier (cross-tier
  comparison forbidden, contract §8). restate-server CPU/RSS runs in a
  separate container outside the per-process sampler — captured separately in
  `logs/restate-server-docker-stats.csv` (same attribution policy as Axon
  Server).
