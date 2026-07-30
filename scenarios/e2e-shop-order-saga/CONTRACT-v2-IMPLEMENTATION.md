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
| exeris-community | `FlowOutcome.PARK`, woken via `scheduler().wake(lookupParked(..))` | kernel flow instance + `FlowSnapshotStore` (v5 tables) |
| spring-axon | publishes no event; the Axon saga has nothing to advance on | Axon saga store (persisted saga instance) |
| spring-on-exeris | `FlowOutcome.PARK`, woken via `ExerisFlowTemplate.wake(lookupParked(..))` | same kernel flow instance as exeris-community |
| quarkus-hibernate | handler split in two halves that share no heap state | **the `orders` row only — no saga engine** |
| restate | `Restate.awakeable(..)` + `await()`; the gateway resolves it directly at the Restate ingress | Restate journal (invocation suspended) |

**quarkus-hibernate was restructured** (PROPOSAL decision 4). It was a
transaction script with compensation running the whole saga inline on the request
thread; that shape cannot satisfy shape A. `AxonOrderSagaCommandHandler` is now
split at the pivot: the forward half commits through the payment-requested writes,
dispatches, and returns `PARKED`; the callback drives the continuation. The two
halves are joined by the `orders` row alone — the callback's compare-and-set
returns the db order id — so nothing about an in-flight saga is held in heap.
**It still has no saga engine**: no persisted saga instance, no scheduler, no
resumption after restart. A park here is "a row in `PAYMENT_PROCESSING` that some
future callback may complete". That is a real architectural difference and shape C
is where it should become visible, not something to paper over.

**Idempotent settlement, all four callback-driven stacks.** Every settle is a
compare-and-set on `status = 'PAYMENT_PROCESSING'`, so a duplicate callback
updates no row and can never wake a saga twice. exeris-community previously wrote
the outcome unconditionally; that is now a CAS too.

**Ordering that is load-bearing:** the payment-requested writes commit *before*
the gateway dispatch in every stack. They establish the `PAYMENT_PROCESSING` state
the CAS matches on, and at shape A's ~1 ms delay a callback arriving before them
is not hypothetical — it would find no parked row and be dropped as a duplicate,
stranding the saga.

**Corrected while implementing this: spring-on-exeris reported terminal states
early.** Its status mapping sent `CONFIRMED → COMPLETED` and
`PAYMENT_REFUNDED → COMPENSATED`. Both are mid-path states (complete-order and
restore-inventory respectively still pending), so a poller could observe a
terminal outcome that later regresses to the opposite one — and the §7 oracles
count terminal observations. quarkus-hibernate already mapped them to the
non-terminal `COMPLETING`/`COMPENSATING` for this reason; the stacks now agree.
This target was never in a campaign, so no published number is affected.

**Also brought to §3 compliance: spring-on-exeris** now awaits the terminal
outcome instead of returning `202 ACCEPTED`, matching the other four. Its saga id
is now derived from the flow instance id (`saga-<instance-uuid>`), which is what
lets a callback carrying only the saga id find the parked flow through
`lookupParked` — the same coupling `exeris-community` already had.

Not yet done: shape-A contract ids and `workload_profile_key`s
(`…-park1-v3`), the scenario.json entries, and any shape-A run.

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
