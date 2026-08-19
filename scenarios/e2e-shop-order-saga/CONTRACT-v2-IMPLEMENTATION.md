# CONTRACT-v2 Implementation Status — e2e-shop-order-saga

| Field | Value |
|---|---|
| Contract | `CONTRACT-v2.md` v2.0 (DRAFT) |
| Scope of this ledger | The current change set only (branch `claude/exeris-benchmarks-droplets-5fd00e`), not overall contract compliance |
| Purpose | Anti-overclaim ledger: what of v2 is actually implemented right now, what is partial, what is deferred. Any claim in a report that relies on a `partial` or `deferred` row MUST carry the corresponding caveat |
| Last updated | 2026-07-30 — (a) surface reconciliation (README v2.0 banner + stack roster, `docs/scenario-catalog.md` entry, `docs/benchmark-target-labels-and-scenario-contracts.md` restate + saga-v2 fields, §10 v1 raw-run re-classification, caveated `contract_revision:2.0` pointers in `scenario.json`/manifest); (b) **campaign-enablement hardening** — §7 exact-population wiring (`oidx` tag + `--ids-file`), campaign-runner fail-closed contract-id derivation, and a campaign-level §4.1 gate rollup (see the pre-campaign hardening note below). No target/stack code changed; §1–§6 and §8–§10 statuses are unchanged since 2026-07-17 and were verified against source, not against run evidence |

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
| §3 Order identity / request model | implemented-now | k6 orderId derivation is seeded and deterministic: `${K6_ORDER_SEED}-${scenario}-i${iterationInTest}` with the fixed seed `exeris-saga-v2` pinned in `k6.env`, so a given (scenario, iteration index) maps to the same orderId in every run against every stack. orderId doubles as the idempotency key (`Idempotency-Key` header sent; Exeris flow key / Axon association value on the server side) | **RESOLVED 2026-07-30 for the three comparison-eligible stacks** (was: resolution-model asymmetry). exeris-community and spring-hibernate now return the terminal outcome in the `POST /api/v1/orders` body, as quarkus ×2 and restate already did, so every comparison-eligible stack is measured under one model and the poll loop is not exercised. Measured effect of the change, perf-box, same windows: exeris-community `saga_completed_duration` median 1010.5 ms → 21 ms and spring-hibernate 1007 ms → 37 ms, against quarkus 28 ms — i.e. the polled distributions were flat at one client poll sleep, an artifact large enough to REVERSE the apparent ordering between stacks. Implementation and the §9(a) idiom deviations it required are recorded below. **Still asymmetric: spring-on-exeris** remains polled and is exploratory-only, so any row including it must still name the per-stack resolution model. Separately: the *issued* set equals the full deterministic set only when every VU session reaches order creation; sessions that abort earlier (register/cart failures) shrink the issued set run-to-run. Expected-count tooling must therefore work from the actually-issued population — see §7 (the gate now fails closed on non-dense populations) |
| §4.1 Business-terminal fault | implemented-now | `stableHash64` pinned normatively to FNV-1a 64-bit (§4.1 implementation note in the contract). Deterministic per-orderId decline predicate implemented server-side with bit-identical constants in exeris-community, spring-axon, quarkus (baseline + tuned), and spring-on-exeris; constants locked by `OrderSagaFaultModelTest` (exeris-community) and `fnv1a64.py --self-test` (canonical FNV vectors); pre-v2 probabilistic knobs are accepted-but-ignored with startup warnings. Restate mapping implemented: own bit-identical FNV-1a 64 decline rule, decline thrown as `TerminalException` (never retried at either Restate layer), constants + k6 population oracle locked by the target's unit tests (mirrors `PaymentDeclineRuleTest`, incl. `exeris-saga-v2-measurement-i0..9999 → 312 declines`) | Cross-stack bit-identity is enforced by unit tests in two stacks (exeris-community, restate); the other four rely on code review. "Never retried" is corroborated only by §5 configuration plus the interim §7 count gate, not by a per-attempt oracle |
| §4.2 Transient infrastructure fault | deferred | Policy configuration only: the §5 retry settings a transient run would use, plus runner plumbing (`--fault-mode transient` labels the run and flips the §7 gate to the inverse assertion expected-compensations = 0) | No transient-fault injector exists in any stack; no `fault=transient` runs are meaningful yet; the inverse assertion (transient faults produce zero compensations) is plumbed but exercises nothing |
| §5 Retry policy | partial (pinned as config where expressible) | Terminal decline = zero retries on all six targets: on five by construction — the decline is modeled as a value/event (`FlowOutcome.FAIL`, `PaymentDeclinedEvent`), never as an exception, so it cannot reach any retry machinery; on restate the decline IS an exception (`TerminalException`), which Restate by documented semantics never retries at either layer. restate transient retry pinned at BOTH layers: per-step `RetryPolicy.exponential(50 ms, 2).setMaxAttempts(3)` on every journaled `Restate.run` block (forward steps AND compensations) plus an SDK-declared service-level invocation retry policy (initial 50 ms, factor 2, maxAttempts 3, onMaxAttempts=KILL) so server defaults (max-attempts=70, on-max-attempts=pause) are never trusted; no jitter knob exists in Restate — deterministic exponential backoff is exactly the §5 no-jitter requirement. Transient-retry policy pinned explicitly per stack: spring-axon — Axon `ExponentialBackOffIntervalRetryScheduler` on the CommandGateway, 50 ms initial, factor 2, maxRetryCount 2 (`AxonBusConfig`); quarkus ×2 — deliberately NO Axon RetryScheduler; in-service `OrderSagaRetryPolicy` (3 attempts total, 50 ms initial, factor 2, no jitter), exhaustion routes to backward recovery / `FAILED_UNRECOVERED`; exeris-community and spring-on-exeris — retry *budget* pinned via `maxRetries(2)` in the flow definition | On the two Exeris-flow stacks the pinned backoff shape (exponential, 50 ms initial, factor 2, no jitter) is NOT expressible in exeris-kernel-spi 0.10.0 — the builder exposes only `maxRetries`/`timeoutDuration`, recorded as in-code TODOs — and no consumer of `FlowDefinition.maxRetries` was found in the kernel 0.10.0 flow runtime, so even budget *enforcement* is unverified there. Everything is config-level: no transient injector exists (§4.2), so retry behavior (budget, backoff timing, exhaustion routing) is unexercised on every stack |
| §6 Three guarantees | partial | G2 verified at *count* level via the interim §7 gate; G3 approximated client-side: terminal-outcome resolution is threshold-enforced (`saga_status_resolved > 0.98`, `saga_unresolved < 0.01`, poll budget 25 × 1 s), not guaranteed per-orderId | No per-orderId compensation ledger, no LIFO-order verification (G2 set/order semantics unverified); no post-run drain scan (G3 as specified — a thresholded client-side approximation is weaker than "every issued orderId"); no crash injection (W3), so G1 "despite crash injection" is not exercised |
| §7 Oracles (external, shared) | deferred | **Interim substitute:** exact compensation-count gate in `run-e2e-shop-order-saga-baseline.sh` — expected count computed from the seeded population with `fnv1a64.py` (same pinned FNV-1a 64-bit function) and compared for exact-integer equality against `saga_compensated_total` from the k6 summary; hard pass/fail, emitted as a correctness-gate JSON; zero observed compensations counts as 0, not as "skip" (the v1 Axon defect class fails the gate) | No external oracle service exists. The interim gate is a count-granularity approximation of O2 only and is **strictly weaker** than the full oracle: no per-`(orderId, stepId, direction)` ledger, no LIFO sequence check, no O1 duplicate-execution detection, no O3 orphaned-effect detection — a stack could pass the count gate while violating O1/O3. **Population wiring is matched and no longer assumes density** (both prior gaps closed): k6.js tags every `saga_issued_total` sample with `oidx` = that issuance's `exec.scenario.iterationInTest`, so the runner reconstructs the **exactly-issued** orderId list (`{seed}-{scenario}-i{oidx}`) from the NDJSON stream and runs the oracle over it via `fnv1a64.py --ids-file`; the emitted `correctness-gate.json` records which population source was used (`population_source: ids_file`). An iteration that aborts before order creation simply contributes no sample, so the previous non-dense `error` outcome no longer occurs and the verdict is exact. The count-based `--seed/--counts` path is retained as the fallback for pre-tag artifacts (`population_source: regenerated`) and keeps its per-scenario density check. The gate still fails closed to `error` — never PASS — on untrusted inputs: duplicate `(scenario, index)` pairs, an id-list size that disagrees with the summary's `saga_issued_total`, missing per-scenario samples, or a helper that returns a non-integer. The `{seed}-{scenario}-i{index}` template stays lockstep-guarded against `generateOrderId()` by `--self-test` |
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

## Pre-campaign hardening — 2026-07-30 (harness only; no run evidence)

Three changes made to let a v2 campaign be switched on without silently
producing unusable or mislabelled artifacts. All three are source-verified;
none of them is evidence about any stack's behavior.

1. **§7 exact population (`oidx` → `--ids-file`).** `scenarios/e2e-shop-order-saga/k6.js`
   now tags each `saga_issued_total` sample with the issuance's
   `exec.scenario.iterationInTest`; `run-e2e-shop-order-saga-baseline.sh`
   reconstructs the issued id list from those tags and evaluates the oracle
   over it. This removes the density assumption rather than working around it:
   verified on a synthetic 10 000-id population where dropping one *declined*
   index makes the exact answer 311 while dense regeneration returns 312 — i.e.
   the fallback path would have produced a false `fail`, and the pre-change
   runner a wasted `error`. The tag is identical in every stack (same script),
   so it introduces no cross-stack asymmetry; live-verified against k6 that the
   tag co-exists with the `scenario` system tag and does not alter the summary
   counter.
2. **Campaign contract-id derivation fails closed.**
   `run-e2e-shop-order-saga-campaign.sh` previously warned and fell back to the
   hard-coded `exeris_community_h2c_v1` when no `fixed_contracts` row matched a
   target label. Because the campaign always passes `--contract-id` down, that
   fallback also satisfied the baseline's own "was a contract id supplied"
   check — so a mistyped or aliased target label (e.g. `spring-app-axon`) would
   have stamped an Exeris h2c contract id and protocol axis onto a Spring run.
   All contract ids are now resolved in a preflight pass that aborts the
   campaign before any target starts, listing the valid `target_app` values for
   the requested graph track.
3. **Campaign-level §4.1 rollup.** `status.csv` gains `contract_id`,
   `graph_track`, `baseline_exit_code` and `durability_tier` columns, and the
   campaign emits `campaign-gate-summary.json` (per-rep verdicts, verdict
   counts, durability-tier uniformity check, `campaign_gate_status`).

4. **Restate is drivable without becoming comparable.** `scenario.json` gains a
   `baseline_only_contracts` namespace holding `restate_saga_h1_v1`,
   deliberately kept OUT of `fixed_contracts` and OUT of
   `graph_tracks.*.required_contracts` so nothing that walks those two
   structures can pick it up, and with no `comparative-pair-manifest.json` row.
   The campaign resolves it, prints `[BASELINE-ONLY]` at preflight, and stamps
   `baseline_only: true` into `status.csv` and `campaign-gate-summary.json`.
   The contract records its four comparison disqualifiers explicitly (h1 facade,
   inline resolution model, external `restate-server` outside the per-process
   sampler, in-memory status projection). Guardrail 4 below is unchanged: a
   Restate *run* is now easy; a Restate *comparison* remains forbidden.

**Open finding — per-step claim scope is not gate-enforceable.**
`comparative-pair-manifest.json` labels exeris-community, quarkus-hibernate and
spring-hibernate `claim_scope: comparison_eligible`, while `scenario.json` sets
`coverage_limited_saga_engine_not_equivalent` on all three contracts *and* on
`graph_tracks.neo4j`, with a per-step split: `auth`/`recommend`/`cart` eligible,
`order_create_latency_ms` and `order_poll_latency_ms` **not** — the Axon stacks
perform no synchronous DB writes in the HTTP request path where exeris-community
performs three, and their status poll is an in-memory projection
(`status_poll_comparison_excluded`). `scenario.json` is the stricter and
therefore governing source. The manifest now carries
`per_step_metric_claim_scope` and a `claim_scope_enforcement_gap` block, but the
restriction is **not enforced**: `claim_scope_for_target()` in
`scripts/run-comparative.sh` recognises only the literal strings
`comparison_eligible` and `descriptive_only` and otherwise falls through to
`maturity`, so a saga-step comparison would pass the strict gate while violating
the contract. Until that is fixed, a strict-gate PASS on this scenario attests
protocol/payload/concurrency fairness only — **the headline
Exeris-Flow-vs-Axon saga-latency comparison is not available from track A at
all**, and the two saga-step metrics must be excluded from every comparative row.
The fix is a design decision (per-metric scope in the gate, vs. demoting the
whole scenario to `descriptive_only`) and is deliberately left open here rather
than resolved by silently flipping a flag.

**What this explicitly does NOT add.** The saga runners still emit only
`claim-status.json`; they do not emit `stage7-gate-report.csv`,
`stage7-gate-summary.json` or `rejection-codes.json`. A saga campaign therefore
produces per-run v2 evidence, **not** a comparative strict-gate verdict, and no
cross-target comparative math may be published from a campaign directory alone —
that requires a separate promotion step (as was done for `entity-read-by-id`).
`campaign-gate-summary.json` is a §4.1 count rollup and must never be cited as
comparative eligibility.

## Open finding — exeris-community loses the whole measurement phase at rate 100 (TARGET-side)

Surfaced by the 2026-07-30 arrival-rate sweep (single target, exeris-community,
perf-box, h1, 20/30/10 s windows). Recorded because it is unfavourable to
Exeris and must not be lost; it does **not** affect the chosen operating point.

| arrival rate | peak concurrency | req/s | saga med | err rate | cores (of 16) |
|---|---|---|---|---|---|
| 3 | 22 | 13.4 | 20 ms | 0 | 0.113 |
| 25 | 176 | 110.6 | 20 ms | 0 | 0.323 |
| 50 | 342 | 222.5 | 23 ms | 0 | 0.505 |
| 100 | 675 | 261.8 | 26 ms | 0.166 | 0.525 |
| 200 | 986 | 340.4 | 24 ms | 0.393 | 0.517 |

CPU plateaus at ~0.52 of 16 cores from 50/s onward and never rises, while the
error rate climbs to 39 %. Latency does *not* degrade (median stays 20–26 ms),
so this is not queueing — served requests stay fast and the rest are dropped.

**ATTRIBUTION (final): target-side and exeris-specific.** Established by a
cross-stack control at rate 100 — identical harness config, phases, rates and VU
pools, run back to back:

| | `status=0` | register 201 by phase | err_rate |
|---|---|---|---|
| exeris-community | 3001, **all** in measurement | warmup 2001, cooldown 1001, measurement **0** | 0.167 |
| quarkus-hibernate | **none** | warmup 2001, measurement 3001, cooldown 1001 | 0.000033 |

quarkus-hibernate is clean; exeris-community loses the entire measurement phase
and then recovers in cooldown. A k6 phase artifact would hit both stacks
identically, so it is not one.

**Correction history — this row was wrong twice before.** Recorded because the
sequence is the point: (1) attributed to ADR-035 admission control — refuted by
arithmetic (pool 256 x default ratio 8 = 2048 allowance >> ~675 concurrent);
(2) attributed to the §3 blocking await — refuted by A/B on the same binary
(`EXERIS_SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS` 25000 vs 0 gave `status=0` 3001 in
BOTH arms); (3) attributed to a k6 phase artifact on the strength of the
measurement-only confinement — refuted by the cross-stack control above, which
should have been run before that claim was written. Duplicate usernames were
also ruled out (a duplicate registration returns a clean 409; the run recorded
exactly one real 409 against 3001 `status=0`).

**What is established.** Every failure is on the session's first request
(`POST /api/v1/auth/register`) with `connection reset by peer` or bare `EOF`, so
the TCP connection was accepted and then dropped. Nothing is logged by the
target. `net.core.somaxconn` is 4096 and the client has 262144 fds, so neither
backlog overflow nor client exhaustion. Peak Postgres backends were 37
(exeris) vs 24 (quarkus) against a 256 pool, so the DB pool is not involved.
The failure is confined to the measurement phase — the phase that begins while
warmup is still draining (`MEASURE_START` equals the warmup duration, but warmup
carries `gracefulStop: '10s'`), which transiently doubles offered load and open
connections. Warmup and cooldown, either side, are clean.

**Persistence admission control is excluded on two independent grounds.**

- *Direct A/B* (maintainer-requested): `queueDepthAllowanceRatio` default vs 32
  at rate 100 — `status0` 3000 in BOTH arms, zero measurement registrations in
  both, err_rate 0.16657 vs 0.16676. No effect. Caveat: the jar string is
  `.persistence.admission.queueDepthAllowanceRatio` with a LEADING DOT, i.e. the
  prefix is applied at runtime, so the two `-D` forms passed were candidates and
  the knob taking effect was not independently verified.
- *The target's own JFR*, sampled INSIDE the failing measurement window
  (`ConnectionEstablished` spans 17:05:56–17:06:06; warmup ended ~17:05:50):
  **15012 `AdmissionDecision` events, every one `accepted = true` /
  `decisionReason = "ACCEPT"`, peak `queueDepth` 10, `saturation 0.0`.** The
  controller is nowhere near any threshold, so the ratio is irrelevant whatever
  value it held. This is what makes the null A/B result unambiguous.

Requests are failing before they reach persistence at all — consistent with a
drop between accept and response.

**Transport instrumentation is silent, which itself needs explaining.**
`eu.exeris.kernel.core.transport.QueueBackpressureAlert` and
`IngressQueueDepth` recorded **zero** events during a run in which every
measurement-phase session failed. Either they are not wired into this path or
nothing tripped them while connections were being dropped; both are worth
knowing. `ConnectionEstablished` shows exactly 1000 events, but the recording
spans only ~10 s of a 60 s run (size-capped JFR keeping a tail), so that number
is NOT evidence of a 1000-connection cap and must not be read as one.

**What is NOT established.** The mechanism inside the target. This needs
product-side investigation of exeris-community's HTTP/transport connection
handling; it is not benchmark work and no further benchmark-side hypothesis
should be recorded here without a controlled experiment behind it.

Phase breakdown at rate 100 (`k6-output.json`, tagged by scenario):

| phase | successful registers | `status=0` |
|---|---|---|
| warmup | 2001 | 0 |
| measurement | **0** | **3001** |
| cooldown | 1001 | 0 |

The failures are entirely confined to the `measurement` scenario: every
measurement session fails at its first request and none succeed, while warmup
and cooldown — same target process, same connection counts, same offered load,
20 s either side — are perfectly clean. A server shedding under concurrency
cannot switch off for exactly one scenario and back on for the next. Root cause
is in the k6 scenario/phase configuration and is **still open**; the sweep used
`preAllocatedVUs` per phase far above the concurrency actually required
(`rate x 5 s`), which is the leading suspect.

**Retracted hypothesis 1 — ADR-035 admission control.** Fails arithmetic: pool
256 x default `queueDepthAllowanceRatio` 8 = 2048 allowance, far above the ~675
concurrent connections at which failures appear.

**Retracted hypothesis 2 — the §3 blocking await.** A/B on the same binary,
`EXERIS_SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS` 25000 vs 0 (0 returns immediately
and reproduces exact pre-§3 behaviour): `status=0` was **3001 in both arms**,
with the non-blocking arm showing *higher* throughput (346.6 vs 259.2 req/s) and
*higher* concurrency (779 vs 678). The blocking change is not implicated.

Also ruled out: duplicate usernames. A duplicate registration returns a clean
`409` (verified directly), and the rate-100 run recorded exactly **one** real
409 against 3001 `status=0`.

**Consequence for measurement validity:** at rate 100 the measurement window —
the only window from which throughput and latency claims may be computed —
contained **zero successful sessions**. The `saga med 26 ms` in the table above
for that row therefore comes from warmup/cooldown only and must not be cited.
The §4.1 gate still passed because the `ids-file` population reconstruction
evaluated the oracle over exactly the ids actually issued; that is the
fail-safe working as intended, not a green light for the row.

**Consequence for the campaign:** rates >= 100 are unusable until the phase
artifact is understood. 50 sessions/s (342 concurrent) is clean on all three
comparison-eligible stacks and is the operating point.

## Load level at the chosen operating point — 2026-08-19 (pinned, host-networked)

Measured to answer a direct question: is 50 sessions/s actually loading anything?
Conditions are new — target on cores 0-3,8-11, load generator on 4,5,12,13, backends on
6,7,14,15 (SMT siblings kept together), and the compose stack moved from the docker
bridge to host networking so the callback path no longer crosses NAT.

Per-core utilisation sampled ONLY while k6 was alive (mpstat 5 s, whole-run sampling would
dilute with seeding and JVM startup):

| declared rate | target (of 4 phys cores) | load gen (of 2) | backends (of 2) |
|---|---|---|---|
| 50 | 0.34 cores (4.2 %) | 0.14 cores (3.5 %) | 0.26 cores (6.5 %) |
| 100 | 0.50 cores (6.2 %) | 0.14 cores (3.5 %) | 0.46 cores (11.4 %) |
| 200 | 0.38 cores (4.7 %) | 0.18 cores (4.4 %) | 0.28 cores (7.1 %) |

**The deployment is ~10 % busy at the operating point, and raising the arrival rate does
not raise the load — it raises connections, and delivery collapses instead.** HTTP failure
fraction goes 1 % (50/s) → 27 % (100/s) → 58 % (200/s), issuance goes 7990 → 3715 → 1335.
This is the same target-side drop recorded in the rate-100 finding above, unchanged.

**Two consequences for how these runs may be read.** The saga numbers describe per-session
cost with the stack near idle; they are NOT a saturation throughput and must never be
quoted as one. And k6 is not the constraint: it uses 0.14–0.18 of the two physical cores it
owns while failing to load the target, so replacing it with a lighter driver would move
nothing. That closes the "k6 is heavy" question with a measurement rather than an
impression.

### ADR-035 admission equalization applied — and it fixes the operating point, not the ceiling

The entity-read report had already settled this axis and this scenario had never applied
it: `queueDepthAllowanceRatio` defaults to 8, under connection pressure Exeris **sheds**
while HikariCP and Tomcat **block**, and comparing a shedding stack against blocking ones
measures the policy. Raising it to 32 took that report's pool campaign from an 84 % error
rate to 0 errors across all 24 runs (build fence `1bf4767`). Applied here via
`-Dexeris.persistence.admission.queueDepthAllowanceRatio=32`, in the exact form those
campaigns ran with — the ledger's earlier A/B of this knob is caveated as unverified,
because the constant carries a leading dot and a wrong `-D` form is silently ignored.

Same sweep, equalized:

| rate | issued | O0 gate | HTTP failure | submit-rejected | unclassified |
|---|---|---|---|---|---|
| 50 | 7002 | **pass** | 0.006 % | 0 | 0 |
| 100 | 3724 | detector_fault | 26 % | 496 | 350 |
| 200 | 1138 | detector_fault | 58 % | 562 | 393 |

**At the operating point it matters**: 50/s goes from ~1 % failures with 131 rejected
submissions to 0.006 % with none, and the O0 identity closes for the first time. Every
comparative run must carry it, and it is disclosed as a §9(d) fairness control rather than
tuning — the arms it equalizes were never on the same policy.

**Above the operating point it changes nothing**: 26 % and 58 % are within noise of the
unequalized 27 % and 58 %. So admission control is now excluded on a *verified* knob rather
than an unverified one, and with the DB pool excluded above, the remaining candidate for
the rate-100 drop is the offered-connection model of the driver itself — k6 holds one
connection per in-flight VU (~340 at 50/s, ~680 at 100/s), where an event-loop driver would
offer the same arrival rate over a bounded shared pool. That is the next controlled
experiment, and it is the one axis the earlier "k6 is not the bottleneck" reading did not
test: it measured the driver's CPU, which is not how a load generator becomes the
constraint here.

### Fourth refuted hypothesis for the rate-100 drop: DB pool sizing

Today's first reading looked like a mechanism at last — the 200/s run logged 111
`PersistenceProviderException` / `connectionExhausted`, peak Postgres backends 273 against
`max_connections=300`, and `EXERIS_DB_POOL_MAX_SIZE` defaults to 256 while peak ACTIVE
connections was 9. An oversized pool exhausting the server it depends on.

Controlled A/B, everything else identical:

| rate | pool max | HTTP failure | issued | peak backends | peak active |
|---|---|---|---|---|---|
| 100 | 256 | 27 % | 3715 | 273 | 9 |
| 100 | 32 | **65 %** | 819 | 48 | 5 |
| 200 | 256 | 58 % | 1335 | 273 | 9 |
| 200 | 32 | **81 %** | 507 | 48 | 2 |
| 200 | 64 | **78 %** | 551 | 80 | 3 |

**Refuted.** Shrinking the pool made it worse at every rate while backends fell to 48 and
active connections to 2–5, so exhaustion is a symptom downstream of the drop, not its
cause. This agrees with what the finding above already established from JFR — requests fail
before they reach persistence. Recorded because this row has now been wrong four times, and
the pattern in every one of them was a plausible mechanism adopted without a controlled
experiment; the experiment is cheap and it keeps refuting them.

## Open finding — §2 "identical recommendation step" is FALSE (graph SPI expressiveness)

§2 states Neo4j "serves the recommendation step identically on every stack".
Code and measurement both say otherwise.

**Measured**, throughput-matched (2026-07-30 footprint check, 50/s, same windows):

| | iterations | Neo4j core-seconds | Neo4j core-s / iteration | recommend p50 |
|---|---|---|---|---|
| exeris-community | 2414 | 3.03 | **0.00126** | **2.215 ms** |
| quarkus-hibernate | 2426 | 1.17 | 0.00048 | 0.888 ms |

Volumes are within 0.5 % of each other, so this is not a throughput artifact:
exeris drives **2.6x the Neo4j CPU** and **2.5x the recommendation latency**.

**Cause — different work, forced by the SPI.** quarkus and spring issue ONE
Cypher query that expresses the whole two-hop join server-side:

    MATCH (u:User {id: $uid})<-[:PURCHASED_BY]-(bought:Product)-[:SIMILAR_TO]->(rec:Product)

`GraphShopAdapter` (exeris-community) instead issues **1 + N traversals**: one
`traverseBreadthFirst` for the user's purchased products, then one more per
purchased product inside a loop. This is not an adapter oversight —
`GraphTraversal` (exeris-kernel-spi 0.8.1) is
`(startNodeId, edgeDescriptor, maxDepth, ...)` with exactly ONE
`GraphEdgeDescriptor`, and `GraphSession` exposes only `traverseBreadthFirst`,
`streamBfsJson` and `findShortestPath`. No API accepts a heterogeneous edge
path, and the recommendation requires two distinct edge types
(`PURCHASED_BY` then `SIMILAR_TO`), so the N+1 is unavoidable through this SPI.
Same class of finding as the `FlowScheduler` gap recorded under §9(a).

**Consequences.**

1. §2's "identical recommendation step" claim must be corrected — the datastore
   and dataset are shared, the *access pattern* is not.
2. `recommend_latency_ms` is currently marked `comparison_eligible` in all three
   contracts. That is defensible only under the platform-natural reading (each
   stack's own idiomatic access); it must NOT be read as a runtime-speed
   comparison, because the stacks issue a different number of round-trips by
   construction. Label it, or demote it.
3. Any whole-deployment footprint row must attribute this: a meaningful share of
   exeris-community's Neo4j cost is API expressiveness, not runtime efficiency.

## Claim guardrails implied by this matrix

Until the corresponding rows move to `implemented-now`:

1. Compensation-correctness claims must be phrased as **count-level** ("observed
   compensation count equals the exact expected integer"), never as O1/O2/O3
   compliance, exactly-once verification, or LIFO-order verification — and only
   from a run whose correctness-gate JSON reports `status: pass`. The gate
   evaluates the exactly-issued orderId population read back from the k6 stream
   (`population_source: ids_file`) or, for pre-tag artifacts, a density-checked
   regeneration (`population_source: regenerated`), and fails closed (`error`)
   on any untrusted input, so `error`/`skipped` gate runs support no §4.1 claim
   in either direction; see §7. For a campaign, `campaign-gate-summary.json`
   rolls the per-rep verdicts up — cite it only when
   `campaign_gate_status: pass`, and never as a comparative-eligibility verdict.
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

## Shape A (minimal park) implemented across all five targets — 2026-07-30

CONTRACT-v2 §2.1 shape A requires every stack to implement
**dispatch → park → external event → wake**. Before this change only
`exeris-community` did; the other four still decided the payment inline, which is
exactly why shape A0 was not comparison-eligible. Code, not run evidence — no
shape-A campaign has been executed yet.

**The §4.1 decline rule now lives in exactly one place.** It moved out of every
target and into `targets/payment-gateway-stub/payment_stub.py`, bit-identical
(same FNV-1a constants, modulus 1000, threshold 30, orderId key), so the
deterministic declined subset and the §7 exact-compensation oracle are unchanged.
The former in-process implementations are retained **only** as reference
oracles — their unit tests pin the normative constants the gateway must agree
with — and each is now marked in-source as off the saga path. No target evaluates
the rule at runtime.

**Consequence that had to be repaired: `EXERIS_SAGA_FAULT_MODE` stopped working.**
With the decline decided externally, that per-target env var could no longer
switch faults off, while still looking wired — the exact failure mode this
scenario has hit repeatedly. Fixed on both sides: the stub gained
`PAYMENT_STUB_FAULT_MODE=terminal|off` and advertises it on `/health`, and every
target logs a WARN when `EXERIS_SAGA_FAULT_MODE=off` is set under a parking shape.
The baseline reads `/health` back before load and **fails closed (exit 74)** when
the gateway's live `delay_ms` or `fault_mode` disagrees with what the run declares,
because both are workload parameters that get stamped into metadata: the delay sets
parked concurrency, the fault mode sets the expected compensation count.

Per-stack park mechanism:

| stack | how it parks | what holds the saga while parked |
|---|---|---|
| exeris-community | `request-payment` (CONTINUE) → `await-payment` (PARK) → `settle-payment` | kernel flow instance + `FlowSnapshotStore` (v5 tables) |
| spring-axon | publishes no event; the Axon saga has nothing to advance on | Axon saga store (persisted saga instance) |
| spring-on-exeris | same three-step split as exeris-community | same kernel flow instance as exeris-community |
| quarkus | handler split at the pivot; LRA open across the park | **MicroProfile LRA coordinator** (persisted LRA + enrolment) |
| restate | `Restate.awakeable(..)` + `await()`; the gateway resolves it directly at the Restate ingress | Restate journal (invocation suspended) |

**quarkus-hibernate was restructured** (PROPOSAL decision 4). It was a
transaction script with compensation running the whole saga inline on the request
thread; that shape cannot satisfy shape A. `AxonOrderSagaCommandHandler` is now
split at the pivot: the forward half commits through the payment-requested writes,
dispatches, and returns `PARKED`; the callback drives the continuation. The two
halves are joined by the `orders` row alone — the callback's compare-and-set
returns the db order id — so nothing about an in-flight saga is held in heap.
**It now HAS a saga engine** (added 2026-08-18, P4): `quarkus-narayana-lra` — a
first-party `io.quarkus` extension, support level **preview**, with the saga enrolled
as a SINGLE participant. The coordinator persists open LRAs and enrolments and drives
compensate/complete afterwards, including after a restart. Until this landed the arm
persisted nothing about a saga, and CONTRACT-v2 §8 forbids comparing across durability
tiers — so its CPU and RSS were never comparable with the durable arms, and were
tabulated against them anyway in the retired campaign.

One participant, not one per step, because the LRA spec guarantees no ordering across
participants and §2 requires LIFO; the unwind therefore lives in application code. It
is a durable saga **envelope**, never "full LRA". Compensation is driven ONLY by the
coordinator — keeping the inline unwind as well would run every compensation twice,
which is what the O1 duplicate-effect oracle exists to catch.

**Precision this table originally got wrong.** "No saga engine" was first written
as if it were a platform limitation. It is not: `axon-modelling:4.10.3` — `@Saga`,
`SagaStore`, `AnnotatedSagaManager` — *is* on this target's classpath. It is
simply never instantiated, because `AxonBusConfig` produces only
`CommandBus`/`CommandGateway`/`Serializer` and deliberately no `EventBus`, and
Quarkus has no equivalent of `axon-spring-boot-starter`'s autoconfiguration. So
this is a wiring gap, not a capability gap, and PROPOSAL decision 4 is therefore
only **half** satisfied: the handler is now genuinely asynchronous, but it is
still Axon-as-command-bus with a hand-rolled saga.

Consequence for labelling, now applied: this target was never "Quarkus + Axon" —
Axon is present only as a command bus and has never run an Axon saga here. Under
v2.1 it is **Quarkus + MicroProfile LRA**, contract id `quarkus_lra_h1_park1_v3`.

**LRA was first rejected, then adopted — the rejection was wrong and the record is in
`LRA-SPIKE.md`.** The ordering objection stands (the spec guarantees none, which is why
the arm enrols one participant), but the follow-up conclusion that the extension needs
RESTEasy Classic did not: it works on the reactive stack with Quarkus **3.38.2** and
`quarkus-rest-client` + `quarkus-rest-client-jackson`. That version bump is a change to
the runtime under measurement and is stamped on the contract; `quarkus-benchmark-app-tuned`
needs the same bump before the two Quarkus arms are comparable with each other.

## Shape-A campaign readiness — 2026-08-18

Four arms verified under the §3.1 forced-decline/forced-success preflight before the
campaign was allowed to start. This is the gate, not a formality: **it stopped five
things in this series**, every one of which would otherwise have entered a campaign as
a number.

| arm | contract id | preflight | gate |
|---|---|---|---|
| exeris-community | `exeris_community_h1_park1_v3` | decline→COMPENSATED, success→COMPLETED | pass, 13 == 13 of 566 |
| quarkus + LRA | `quarkus_lra_h1_park1_v3` | as declared | pass, 568 issued |
| spring-axon | `spring_axon_h1_park1_v3` | as declared | pass, 567 issued |
| restate | `restate_saga_h1_park1_v3` | as declared | pass, 72 issued |

NOT in the campaign, and why: **spring-on-exeris** (park fix made by inspection, never
run) and **quarkus-tuned** (still pre-parking, still on 3.34.3).

What the preflight caught, in order:

1. **exeris-community / spring-on-exeris** — the parked step was never re-entered on
   wake, so a DECLINED payment completed successfully.
2. **the negative control itself** — falsified declaration rejected before the window
   (`preflight` mode), and a blind detector caught as `detector_fault` rather than a
   compensation figure (`detector` mode).
3. **quarkus LRA** — coordinator URL set under a property the extension does not read,
   so it dialled the built-in default and failed with `Connection refused`.
4. **restate packaging** — uber-jar missing `Multi-Release: true`.
5. **restate callback address** — ingress dialled through the host loopback,
   unreachable from the gateway container.

Windows are 300 s warmup / 900 s measurement / 30 s cooldown, aligned with the
entity-read fixed contracts. The previous 120/180 gave ~270 compensations per window —
a thin denominator for an oracle whose whole claim is an exact integer.

## The embedded Axon arm — what it took to reach a terminal outcome, 2026-08-19

CONTRACT-v2 §9(e)'s second Axon shape (`spring-axon-embedded`, contract
`spring_axon_embedded_h1_park1_v3`) runs the same jar as the Axon Server arm with
`EXERIS_AXON_SERVER_ENABLED=false`. Turning Axon Server off does not by itself produce a
working arm, and each of the four defects below stranded every session at exactly the same
observable symptom — status `INVENTORY_RESERVED`, no exception, no WARN. They are recorded
individually because three plausible explanations were refuted by measurement along the way,
and the symptom alone never discriminated between them.

| # | Defect | How it was refuted/confirmed |
|---|---|---|
| 1 | No event store at all: the starter has nothing to fall back on and the context dies building the aggregate repository | Startup failure, `Default configuration requires the use of event sourcing` |
| 2 | Stores declared on JPA, so Hibernate mapped Axon's `@Lob byte[]` to PostgreSQL large-object OIDs | `column "token" is of type bytea but expression is of type oid`; rewritten onto Axon's JDBC engines per the all-arms-JDBC rule |
| 3 | Axon's JDBC schemas default to entity-style identifiers, emitted unquoted, so PostgreSQL folded `TokenEntry` to `tokenentry` | `relation "tokenentry" does not exist`; fixed by naming every table and column to match the seed |
| 4 | The saga serialized to the empty document | `JdbcSagaStore : Storing saga id … as {}` under DEBUG |

Two hypotheses were **refuted**, and both had looked convincing:

- **Segment routing.** Every step of this saga after the first is published as a plain event
  (`eventBus.publish(GenericEventMessage.asEventMessage(...))`), so Axon's default
  `SequentialPerAggregatePolicy` falls back to the event's own message identifier and sprays
  one saga's events across all 16 segments. That is a real race and it was fixed
  (`SagaSequencingConfiguration`), but it was **not this failure**: forcing
  `initial-segment-count=1`/`thread-count=1` — verified in the log as only `Segment[0/0]`
  with 2 workers — failed identically.
- **A broken gateway callback URL.** `PaymentGatewayClient` derives its default from
  `EXERIS_PORT`, which the arm sets to 9014, so the callback address was correct all along.

The defect that actually mattered is #4. With `axon.serializer.general=jackson` and no public
accessors on the saga, Jackson wrote every saga as `{}`. The saga was found and its
`InventoryReserved` handler ran — on an instance with `sagaId=null` and `dbOrderId=0` — so it
dispatched a payment naming no saga, and the callback's compare-and-set on
`(saga_id, status='PAYMENT_PROCESSING')` matched no row.

### The finding this exposed, which is NOT an embedded-arm defect

The Axon Server arm never showed defect #4 because **it does not persist saga state at all**.
Its log carries `WARN InMemoryTokenStore: An in memory token store is being created`, and the
2026-07-17 probe recorded zero JPA writes to `saga_entry`/`association_value_entry` across two
completed sagas. Axon Server supplies an event store but neither a token store nor a saga
store, and Axon's starter falls back to in-memory when no store bean is declared.

That is a **§8 durability-tier asymmetry between the two Axon arms**, and it must not be
collapsed:

- `spring-axon` (Axon Server): events durable in Axon Server; **tracking tokens and saga state
  in memory** — a restart loses in-flight saga state and replays from wherever the in-memory
  token happens to be.
- `spring-axon-embedded`: events, tokens and saga state all durable in the shared Postgres.

The embedded arm therefore pays per-session write traffic the Axon Server arm does not pay,
and a footprint or throughput comparison between the two that does not state this reads a
durability difference as an efficiency difference. **Open decision:** whether to leave the
asymmetry and disclose it, or declare JDBC token and saga stores for the Axon Server arm too
(which is the ordinary production shape — in-memory tokens are Axon's no-store fallback, not a
deployment choice) and re-measure. Not resolved here; nothing in this change set alters the
Axon Server arm's stores.

### Verified terminal — 2026-08-19, perf box (exploratory profile, not a citable number)

First clean run of this arm end to end, 50 sessions/s, 20 s warmup / 60 s measurement /
20 s cooldown, pinned and host-networked:

- §3.1 vocabulary preflight PASSES on both cases — `COMPENSATED` on the forced decline and
  `COMPLETED` on the forced success.
- Correctness gate **pass**: expected 145 compensations, observed 145, over the exactly-issued
  population (`population_source: ids_file`).
- O0 accounting closes exactly: 4625 completed + 145 compensated = **4770 issued**, 0
  unresolved, `http_req_failed` 0.008 %.
- 24 006 rows in `domain_event_entry`, and `saga_entry` / `association_value_entry` are back to
  **0** after the run — `@EndSaga` deletes a saga on termination, so an empty saga table is
  positive evidence that nothing stranded.
- 232 `dropped_iterations`, i.e. the VU pool ceiling was reached (measurement phase peaked at
  608/612 VUs). This is the driver-side offered-connection question, not a target failure, and
  it is why the issued population is 4770 rather than 5000. It belongs to the open k6-vs-
  Hyperfoil control, not to this arm.

These numbers are **exploratory** — the run stamps `claim_scope=exploratory` — and are recorded
here as evidence the arm reaches terminal outcomes, not as a performance result.

### Fairness ledger for this arm

- Every arm is measured on JDBC because Exeris is; the embedded arm uses Axon's own
  `JdbcEventStorageEngine` / `JdbcTokenStore` / `JdbcSagaStore`, not Hibernate.
- The saga is annotated for Jackson rather than moved to XStream (Axon's own advice for
  sagas), because a per-arm serializer would add a second variable to a comparison whose
  subject is where saga state lives.
- `SagaSequencingConfiguration` is registered for **both** Axon arms. The Axon Server arm has
  the same race and wins it only because events stream back from the server after the local
  transaction commits; leaving the arms on different sequencing policies would make them
  incomparable.

## Appendix A — §9 per-stack deviation register (stubs)

Pre-report scaffolding for contract §9. Every entry marked TODO is
**unpopulated and unaudited**; only the (c) entries reflect code verified in
this change set. Contract §9 requires this register to appear in the report
per stack; these stubs do not satisfy that requirement by themselves.

### exeris-community (`targets/exeris-community-app`)

- (a) Idiom deviations from contract wording (code-verified 2026-07-30):
  **the request thread blocks for the saga's duration.** §3 requires the HTTP
  response to carry the final outcome; `FlowScheduler` (exeris-kernel-spi,
  identical in 0.8.1 and 0.10.2) exposes only
  `schedule`/`park`/`wake`/`lookupParked` — no synchronous execute and no
  completion handle — so the outcome is not awaitable through the SPI.
  `OrderSagaOrchestrator` therefore registers a `CompletableFuture` per saga
  and completes it from the flow's terminal steps (`send-email` forward;
  `reserve-inventory`'s compensation backward, always last under LIFO unwind),
  and `placeOrder` awaits it. Rejected alternative: polling `getSagaStatus`,
  which loads the `FlowSnapshotStore` — this target persists flow state to the
  v5 tables, so a tight poll is a DB `SELECT` per iteration, i.e. load added to
  this stack alone, biasing the comparison. Falls back to the pre-v2 async
  response after `EXERIS_SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS` (default 25 s,
  matched to the client's 25 × 1 s poll budget). Still to document: kernel-level
  flow compensation (engine-native unwind) vs the contract's step/compensation
  wording.
- (b) Administrative-termination semantics (G3 asterisk): TODO — hard-abort
  path not documented or audited.
- (c) §5 retry configuration (code-verified): `OrderSagaOrchestrator` flow
  definition pins `maxRetries(2)`; terminal decline returns `FlowOutcome.FAIL`
  → compensation, exempt from retries. Pinned backoff shape not expressible in
  exeris-kernel-spi 0.10.0 (in-code TODO); `maxRetries` enforcement unverified.
- (d) Adversarial tuning applied in the stack's favor: TODO — none recorded.

### spring-axon (`targets/spring-benchmark-app`)

- (a) Idiom deviations from contract wording (code-verified 2026-07-30):
  **the request thread blocks until the saga settles, which is NOT idiomatic
  Axon.** A production Axon service returns 202 and lets the client subscribe
  or poll; `sendAndWait` returns once `OrderAggregate` has handled
  `CreateOrderCommand`, long before the saga completes. §3 nonetheless requires
  the response to carry the final outcome, so `AxonOrderSagaProjection` — the
  first component that observes a terminal status — completes a per-`orderId`
  future from its existing terminal transition, and `AxonOrderSagaService`
  awaits it (registering *before* dispatch, since a fast saga can settle while
  `sendAndWait` is still returning). Maintainer-approved on 2026-07-30 in
  preference to leaving the stack comparison-ineligible.
  **Why the deviation is the lesser distortion:** under the previous polled
  model this stack's measured `saga_completed_duration` was flat at ~1007 ms —
  one client poll sleep, not saga time — against ~28 ms for the inline stacks,
  an artifact large enough to reverse the apparent ordering between stacks.
  Note also that quarkus-hibernate already runs its entire saga on the request
  thread, so this brings the two Axon stacks into the same shape. Falls back to
  the pre-v2 async `ACCEPTED` after
  `EXERIS_SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS` (default 25 s). Still to
  document: decline explicitly modeled as `PaymentDeclinedEvent` routed to saga
  compensation (the §4.1 per-stack mapping requirement).
- (b) TODO.
- (c) §5 retry configuration (code-verified): `AxonBusConfig` registers an
  `ExponentialBackOffIntervalRetryScheduler` (initial 50 ms, factor 2,
  maxRetryCount 2) on an explicitly built CommandGateway; declines are events,
  not exceptions, so they cannot reach the scheduler.
- (d) TODO.

### quarkus (`targets/quarkus-benchmark-app`)

- (a) Idiom deviations from contract wording (code-verified 2026-07-30):
  **the entire saga runs synchronously on the request thread.**
  `AxonOrderSagaCommandHandler.handle(CreateOrderCommand)` executes
  insert-order → reserve-inventory → charge-payment → confirm-order — or the
  LIFO compensation pair — and returns the terminal outcome
  (`COMPLETED`/`COMPENSATED`) in the POST body, so this stack already satisfied
  §3 before the 2026-07-30 change to its two peers. Like them, this is not
  idiomatic Axon (no async event-driven saga progression).
  **This invalidates the shared `claim_scope_note`** carried by both Axon
  contracts, which asserts "no synchronous DB writes in HTTP request path" and
  that "inventory reservation, multi-step saga state transitions, and
  compensation are not executed in the request path under Axon". That is true
  of spring-hibernate as it was, and flatly false of this stack — every domain
  write happens in the request path here. The note is the stated justification
  for excluding `order_create_latency_ms` from comparison, so it must be
  corrected per-stack rather than shared.
- (b) TODO.
- (c) §5 retry configuration (code-verified): deliberately NO Axon
  RetryScheduler (`AxonBusConfig`); retries are in-service via
  `OrderSagaRetryPolicy` (3 attempts total, 50 ms initial, factor 2, no
  jitter); exhaustion raises `RetryExhaustedException`, routed to backward
  recovery / `FAILED_UNRECOVERED` by the command handler.
- (d) TODO.

### quarkus-tuned (`targets/quarkus-benchmark-app-tuned`)

- (a) **NOT shape-A capable yet.** This target still carries the pre-parking saga: no
  `PaymentGatewayClient`, no callback resource, and its `PaymentService` decides the
  §4.1 decline inline. It is also still on Quarkus 3.34.3 while the measured quarkus arm
  moved to 3.38.2 for LRA, so the two Quarkus arms are NOT comparable with each other
  until both are ported (P5). Not in the shape-A campaign.
- (b) TODO.
- (c) §5 retry configuration (code-verified): same mechanism as quarkus
  baseline (`OrderSagaRetryPolicy`, no Axon RetryScheduler).
- (d) TODO — **required before any tuned-row claim**: the full tuning delta vs
  the quarkus baseline target must be enumerated here.

### spring-on-exeris (`targets/exeris-spring-runtime-app-comp`)

- (a) Idiom deviations (2026-08-18): same three-step park as exeris-community —
  `request-payment` (CONTINUE) → `await-payment` (PARK) → `settle-payment`. The split
  is forced by the engine: `beginScheduleAfterWake()` returns `currentStep + 1`, so a
  woken flow resumes at the step AFTER the parked one and never re-enters it. The
  dispatch step must return CONTINUE rather than PARK because `applyParkOutcome` pushes
  no compensation, so parking there would drop `refund-payment` from the LIFO unwind.
  Also brought to §3 (was returning 202 ACCEPTED) and its saga id is now derived from
  the flow instance id so a callback carrying only the saga id can find the parked flow.
  **NOT YET RUN under shape A** — the fix was made by inspection after the same defect
  was measured on exeris-community, so this arm's park is unverified and it is NOT in
  the shape-A campaign.
  Corrected while there: its status mapping reported `CONFIRMED → COMPLETED` and
  `PAYMENT_REFUNDED → COMPENSATED`, both mid-path, so a poller could observe a terminal
  outcome that later regresses. Now `COMPLETING`/`COMPENSATING`, matching the others.
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
  finding, not a violation.
  **Park (2026-08-18):** `Restate.awakeable(..)` created OUTSIDE the journaled run
  block (creating it is itself journaled, so replay yields the same id) with the
  dispatch INSIDE it (so it happens exactly once across replays). The gateway resolves
  the awakeable at the Restate INGRESS — the callback never enters the target JVM,
  which is platform-natural since Restate owns durable execution, but means this arm's
  per-callback cost lands in restate-server. The whole-deployment footprint captures
  it; a target-JVM-only comparison would not.
  **Two defects found by the §3.1 preflight before this arm could run at all:**
  (1) the shaded uber-jar lacked `Multi-Release: true`, so the SDK's FFM classes under
  `META-INF/versions/23/` were present in the jar but invisible to the classloader —
  every saga submission failed at runtime, which read as a broken target rather than a
  packaging defect; (2) the gateway dialled the ingress via `host.docker.internal:8080`,
  which compose publishes on the host loopback only, so from the gateway container it
  was `Connection refused` — the awakeable was never resolved, the workflow stayed
  parked, and the ingress call failed with `HttpTimeoutException`. Every visible symptom
  pointed at a slow target; none pointed at an address. Now dialled by compose service
  name. The §4.1 decline is an *exception*
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
