# Scenario Contract: e2e-shop-order-saga — v2.0

| Field | Value |
|---|---|
| Scenario ID | `e2e-shop-order-saga` |
| Contract version | 2.0 (supersedes v1) |
| Status | DRAFT — pending claims-audit |
| Applies to stacks | Exeris Flow · Spring Boot 3 + Axon + Neo4j · Quarkus 3 + Axon + Neo4j · Restate (server + JVM SDK service) |
| Retroactivity | v2 fault-injection and metric-split rules apply retroactively; see §10 for which v1 results remain valid |

---

## 1. Purpose and unit of comparison

This contract defines the semantic scenario, fault model, guarantees, and
measurement rules for the shop-order saga benchmark. Any stack added to the
matrix MUST implement this contract exactly; deviations are documented per
stack in §9.

**Unit of comparison:** the *minimal production-plausible deployment* that
delivers the saga contract to application code — i.e. the system as a user
would actually run it, including every required process. Component-level
comparisons (engine-only, journal-only) are out of scope.

| Stack | Deployment unit |
|---|---|
| Exeris | single JVM process (kernel in-process), scaffolded via Exeris SDK/tooling |
| Spring/Quarkus + Axon | app JVM + Axon Server process + Neo4j |
| Restate | service JVM (Restate JVM SDK) + `restate-server` (single binary) |

## 2. Scenario definition

> **CARRY-OVER from v1.** The business step sequence, payload schema, VU
> count, and think time are unchanged from contract v1 and are normative as
> defined there. They are referenced here as S1…Sn with the payment step
> designated **S_pay**. Do not redefine them in this document — link, don't
> duplicate.

Structural requirements (normative in v2):

- The saga consists of ≥ 2 compensatable steps *preceding* S_pay, S_pay
  itself, and ≥ 0 steps after S_pay. S_pay is the **pivot**: a terminal
  failure at S_pay triggers backward recovery (compensation) of all
  previously completed compensatable steps in **LIFO order**.
- Every forward step that mutates external state has a defined compensation.
  Compensations are semantic inverses at the domain level (e.g. release
  reservation), not journal rollbacks.
- Domain persistence performed by steps MUST be identical across stacks
  (same writes, same datastore, same schema). A stack may not skip domain
  writes that another stack performs. **Resolved in v2.0 (amended
  2026-07-17, maintainer-approved):** Postgres is the shared DOMAIN
  datastore for all stacks; every stack (including Restate, inside
  `ctx.run`, and Exeris) performs the same domain writes (orders/
  order_items, inventory reserve/restore, outbox, compensation updates)
  against the same Postgres instance class and schema. Neo4j is the shared
  READ-SIDE recommendation graph: it serves the recommendation step
  identically on every stack, is seeded identically from the Postgres seed
  baseline before each run, and is never written to by any saga step.
- **Graph driver pinned:** all cross-stack comparison runs use the Neo4j
  driver for the read-side recommendation path. The Exeris graph
  capability's driver swap (pgq ↔ neo4j) is explicitly OUT OF SCOPE for
  comparison tables; it may be reported as a separate Exeris-only
  experiment under this contract's workload, clearly labeled as such.

## 3. Order identity and request model

- Client: k6, identical script for all stacks, HTTP/1.1 (negotiated
  identically), loopback or fixed network path identical across stacks.
- Each request carries a client-generated `orderId`.
- **`orderId` generation is seeded and deterministic**: a fixed-seed
  sequence defined in the harness, so that the *same set* of orderIds is
  issued in every run against every stack. This is a prerequisite for §4.
- `orderId` is the idempotency key where the stack supports one
  (Restate: idempotency key header; Exeris: flow instance key; Axon: saga
  association value).
- The saga executes request-response: the HTTP response returns the final
  saga outcome (`COMPLETED` | `COMPENSATED` | `FAILED_UNRECOVERED`).

## 4. Fault model (breaking change vs v1)

v1 injected `payment_fail_rate = 3%` without pinning *where* the randomness
lives or *what kind* of failure it is. v2 replaces this with two explicitly
separated fault classes:

### 4.1 Business-terminal fault (primary, always on)

- **Semantics:** payment *declined* — a business outcome, not an
  infrastructure error. Deterministic, permanent, non-retryable.
- **Selection:** per-`orderId`, not per-attempt.
  Normative rule: `decline(orderId) := (stableHash64(orderId) mod 1000) < 30`
  → exactly 3.0% of the deterministic orderId population, identical subset
  in every stack and every run.

> **Implementation note (normative — v2.0 pinned algorithm).**
> `stableHash64` is pinned to **FNV-1a 64-bit**: offset basis
> `0xcbf29ce484222325`, prime `0x100000001b3`, applied to the **UTF-8
> bytes** of the `orderId` string
> (`h = offset_basis; for each byte b: h = (h XOR b) * prime`, all
> arithmetic in unsigned 64-bit with wrap-around multiplication), and
> `mod 1000` evaluated on the **unsigned** 64-bit result. Every stack and
> every harness/verifier component (k6 generator, gate tooling) MUST use
> this exact function; a signed interpretation of the hash or of the
> modulo is non-conformant.

- **Required behavior:** the stack MUST route this outcome to backward
  recovery (compensation), never to retry.
- **Per-stack mapping:**

| Stack | Terminal-decline mapping |
|---|---|
| Exeris Flow | step returns compensation-triggering outcome (per Flow API) |
| Axon stacks | the path that (per v1 findings) failed to fire — v2 requires an explicitly modeled decline event routed to saga compensation; if the framework cannot express it, that is a reportable correctness finding, not a config detail |
| Restate | step throws `TerminalException`; caught by the saga handler, which runs the compensation list in reverse, each compensation inside `ctx.run` |

- **Consequence — exact oracle:** because the declined subset is
  deterministic and known a priori, the expected compensation count per run
  is an *exact integer*, not a statistical estimate.
  `observed_compensations == |declined ∩ issued|` is a hard pass/fail
  assertion. The v1 Axon "zero compensations" class of defect becomes a
  deterministic assertion failure, not an anomaly to notice.

### 4.2 Transient infrastructure fault (secondary, separate runs only)

- **Semantics:** step fails with a retryable error (e.g. injected timeout),
  succeeds on a later attempt.
- Selection per-attempt, seeded RNG, rate defined per experiment.
- MUST NOT be mixed with §4.1 in the same run. Runs are labeled
  `fault=terminal` or `fault=transient`; headline latency/throughput claims
  come from `fault=terminal` runs only.
- Purpose: measures retry machinery cost and verifies that transient faults
  do NOT produce compensations (the inverse assertion of §4.1).

## 5. Retry policy (pinned)

Unbounded default retries (Restate's default for non-terminal errors) mask
failures and destroy cross-stack comparability. v2 pins:

- **Terminal-decline (§4.1): zero retries.** Any stack observed retrying a
  declined payment fails the correctness gate.
- **Transient faults (§4.2): max 3 attempts total** (1 initial + 2 retries),
  exponential backoff, initial 50 ms, factor 2, no jitter (determinism).
  Configured explicitly in every stack; defaults are not trusted.
- Retry budget exhaustion on a *forward* step routes to backward recovery.
- Retry budget exhaustion on a *compensation* step routes to
  `FAILED_UNRECOVERED` and is counted separately (see §7 oracle O3).

## 6. The three guarantees — operational definitions

| Guarantee | Definition | Verified by |
|---|---|---|
| **G1 Forward progress** | Every issued, non-declined orderId reaches `COMPLETED` within the run window despite injected faults and crash injection (W3) | response ledger vs issued set |
| **G2 Compensation under failure** | Every declined orderId reaches `COMPENSATED` with all previously completed steps compensated exactly once, in LIFO order | exact oracle §7 |
| **G3 Termination** | Every issued orderId reaches a terminal state (`COMPLETED`/`COMPENSATED`/`FAILED_UNRECOVERED`); no saga remains in-flight after drain timeout | drain scan |

**G3 asterisk (normative disclosure):** administrative termination paths
that bypass compensation (Restate `kill` vs `cancel`; any Exeris hard-abort;
Axon equivalent) are documented per stack in §9 but are NOT exercised in
benchmark runs. Crash injection (W3) uses `kill -9` of the *service/app
process* (and, in a separate variant, of the orchestrating server process
where one exists) — never administrative cancellation APIs.

## 7. Oracles (external, shared)

All stacks report side effects to the same external oracle service
(out-of-process counter store, itself durable), keyed by
`(orderId, stepId, direction)` where direction ∈ {forward, compensation}.

- **O1 — exactly-once effect (statistical):** duplicate forward executions
  per key are counted; at-least-once execution with exactly-once *recording*
  means duplicates may legitimately occur only in crash-injection (W3)
  variants; in fault-only runs the expected duplicate count is 0.
- **O2 — exact compensation ledger:** for every declined orderId, the
  compensation set equals the set of its completed forward steps, order
  verified LIFO via oracle sequence numbers. Expected total is the exact
  integer from §4.1.
- **O3 — no orphaned effects:** for every `FAILED_UNRECOVERED` (expected 0
  in fault-only runs), the orphaned effect set is reported, not hidden.

A stack failing O1–O3 gates has its performance numbers **excluded** from
headline tables (reported in an appendix, flagged non-compliant). Fast and
wrong is not a result.

## 8. Metrics and reporting split (breaking change vs v1)

- Latency is reported **separately** for `COMPLETED` and `COMPENSATED`
  populations. Mixing them (v1 style) blends two structurally different
  code paths — compensated sagas in journaling stacks pay ~2× journal
  entries — and buries exactly the architectural difference under test.
- Per population: p50 / p99 / p999 / max, full HdrHistogram artifacts in the
  repo. Coordinated omission handled by the generator.
- Throughput reported as ops/s **and** ops/s/core.
- Whole-deployment footprint (per §1 unit): Σ RSS of all required
  processes, process count, allocations/op (JFR, JVM sides only), GC pause
  totals.
- Setup-time metric: wall-clock `git clone` → first successful contract
  run, scripted, per stack. For Exeris this is the **SDK/tooling scaffold
  path** (the supported route), not manual assembly; the measured path is
  named in the report for every stack.
- Durability tier (T1 process-durable / T2 fsync node-durable) is declared
  per run; **cross-tier comparisons are forbidden** in all tables and prose.
  T3 (replicated) is planned but explicitly decoupled from v2: it enters as
  a separate contract revision only after passing its own correctness gates
  (replica crash injection, partition behavior, quorum-before-ack
  verification — DST-validated first), independent of this benchmark's
  timeline. Until then, no Exeris result may be juxtaposed with published
  replicated-cluster numbers of any other stack.
- ≥ 5 measured runs after discarded warm-up; variance reported.

## 9. Per-stack deviation register

Every stack entry in the report carries a mandatory section listing: (a)
where its native idiom differs from the contract wording (e.g. Restate
compensations as user-space pattern vs Exeris kernel-level unwind — both
satisfy G2; the difference is the finding, not a violation), (b) its
administrative-termination semantics (§6 G3 asterisk), (c) its retry
configuration proving §5 compliance, (d) adversarial tuning applied in the
stack's favor.

## 10. Retroactive validity of v1 results

| v1 result class | Status under v2 |
|---|---|
| Environment/client symmetry, protocol notes | valid, carried over |
| Happy-path latency/throughput (Exeris, Axon×2) | conditionally valid — must be re-labeled as `COMPLETED`-population metrics; re-run recommended for the §8 split |
| Compensation correctness findings (Axon zero-compensation) | superseded — must be re-tested under §4.1 deterministic terminal fault; v2 turns the anomaly into a pass/fail assertion |
| Any mixed-population latency table | invalid under v2, do not cite |

## 11. Change log

- **2.0** — deterministic per-orderId terminal fault (§4.1) replacing
  per-attempt probabilistic injection; `stableHash64` pinned to FNV-1a
  64-bit (§4.1 implementation note); transient faults separated (§4.2);
  pinned retry policy (§5); exact compensation oracle (§7 O2); latency
  split by outcome population (§8); deployment-unit definition and
  setup-time metric (§1, §8); G3 cancel/kill disclosure (§6); durability
  tier declaration with cross-tier prohibition (§8); per-stack deviation
  register (§9).
- **1.x** — original contract (three stacks, probabilistic 3%
  `payment_fail_rate`, JDK 26, HTTP/1.1 loopback, k6).
