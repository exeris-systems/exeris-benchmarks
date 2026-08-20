# Scenario Contract: e2e-shop-order-saga — v2.2

| Field | Value |
|---|---|
| Scenario ID | `e2e-shop-order-saga` |
| Contract version | 2.2 (supersedes v2.1, which supersedes v2.0, which supersedes v1) |
| Status | DRAFT — pending claims-audit |
| Applies to stacks | exeris-community · spring-on-exeris · Spring Boot + Axon · Quarkus + MicroProfile LRA · Restate (server + JVM SDK service) |
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

**Corrected 2026-07-31 (v2.1).** The previous table listed Neo4j on one row only
and omitted Postgres from every row, while §2 makes Postgres the shared domain
datastore for **every** stack. Three rows, three different levels of completeness,
and the shortest was Exeris's — a flattering count that §2 did not support. Every
required process is now listed on every row so the counts are comparable. Neo4j is
absent because the graph was removed from this scenario entirely (§2).

| Stack | Deployment unit (every required process) | Processes |
|---|---|---:|
| exeris-community | app JVM (kernel in-process) + Postgres | **2** |
| spring-on-exeris | app JVM (kernel in-process) + Postgres | **2** |
| spring + Axon *(Axon Server)* | app JVM + Axon Server + Postgres | 3 |
| spring + Axon *(embedded)* | app JVM (`EmbeddedEventStore` + JPA) + Postgres | **2** |
| quarkus + MicroProfile LRA | app JVM + LRA coordinator + Postgres | 3 |
| Restate | service JVM (Restate JVM SDK) + `restate-server` + Postgres | 3 |

The external payment gateway (§4) is part of the deployment unit for every stack
and is sampled by the whole-deployment footprint; it is omitted from the counts
above only because it is identical on every row and differentiates nothing.

**Axon Server is the framework's default deployment path, not a requirement of the
framework.** Axon Framework also runs entirely in the application JVM against a
JPA/JDBC event store with a `SimpleCommandBus`. The two are distinct deployment units
with distinct process counts, so they are distinct rows — never one "Axon" row.

**Promoted to measured, 2026-08-20 (v2.2).** v2.1 recorded the embedded configuration
in §9(e) as available-but-not-measured. It is now measured, as
`spring_axon_embedded_jdbc_h1_park100_v3`, for a reason that only appeared once the
number existed: naming a cheaper configuration without measuring it protects a stack
from being *misrepresented*, but it cannot say whether the cheaper configuration is
actually usable. Measured, it is — and it is not free. Embedded halves the process
count and cuts whole-deployment RSS from ~2.2–2.4 GB to ~1.0–1.3 GB, exactly as §9(e)
predicted, while its p99 ranged 608 → 11 802 ms across three otherwise identical reps
against 588–610 ms for the Axon Server configuration. That is a trade-off a reader can
act on; "available but not measured" is not. An §9(e) entry discharged by measurement
is the strongest outcome available to that register, not a weakening of it.

**Consequence for reporting.** The two Axon rows must not be collapsed, averaged, or
described as "Axon" in prose. They differ in process count (§1), in footprint, and in
tail stability, and each of those differences is a finding.

**Stack list.** The measured arms are `exeris-community`, `spring-on-exeris`,
`spring + Axon (Axon Server)`, `spring + Axon (embedded)`, `quarkus`, `restate` — six
rows, added to in v2.2 (embedded promoted from §9(e); see above).

Two roster corrections carried from earlier revisions. "Quarkus + Axon" was wrong in
v2.0: the Quarkus arm has never run an Axon saga — Axon was present only as a command
bus, with the saga hand-rolled. Its saga engine from v2.1 on is MicroProfile LRA (§9).
And `spring-on-exeris` has been listed here since v2.1 while no contract id existed for
it, so it could not be run; v2.2 adds `spring_on_exeris_h1_park100_v3` and the roster
entry, against `exeris-spring-runtime` 0.7.0. Until a run under that id exists, the arm
is **listed and pending**, which is a third state and must be labelled as such — not
silently absent from a table whose header claims to cover the roster.

## 2. Scenario definition

> **CARRY-OVER from v1, AMENDED 2026-07-30.** The business step sequence and
> payload schema are unchanged from contract v1 and are normative as defined
> there. They are referenced here as S1…Sn with the payment step designated
> **S_pay**. Do not redefine them in this document — link, don't duplicate.
>
> **The load model is NOT carried over.** v1's "VU count" wording described a
> closed-loop model this scenario has never actually run: the k6 script uses
> `constant-arrival-rate` executors, under which the VU numbers are a *pool
> ceiling*, not concurrency. The normative load model in v2.1 is:
>
> - `constant-arrival-rate`, **50 sessions/s** in the measurement window,
>   identical on every stack (measured peak concurrency ~342);
> - think time unchanged at 800–2500 ms random.
>
> 50/s was chosen from a measured sweep (3 / 25 / 50 / 200 sessions/s). It is
> the highest rate clean on every stack: at 100/s exeris-community loses its
> entire measurement phase to connection resets (§ open findings in
> `CONTRACT-v2-IMPLEMENTATION.md`). The previous default of 3/s left the target
> at 0.7 % of a 16-core box and inflated CPU-per-request roughly threefold with
> idle overhead, so results under it are not comparable with results under this
> model.
>
> **Runs under the pre-amendment load model MUST NOT be aggregated with runs
> under this one.** The change is carried by a new `workload_profile_key`
> (`…-h1-loopback-runtime-k6-inline-r50-v2`) and by new contract ids; the
> h2c-named contracts are marked `superseded`.

> **RE-RATED to 38 sessions/s, 2026-08-19.** The 50/s above is superseded for the
> parking shapes. Two things were wrong with it, and the second is the reason this
> paragraph exists rather than a one-line edit.
>
> *It was never validated for this workload.* The sweep that produced it
> (3 / 25 / 50 / 200) was run under shape A0, straight-through, where nothing parks.
> When parking was introduced the load model was carried across the shape boundary
> unchanged — the one thing §2.1 says must never happen. "Highest rate clean on every
> stack" was true of a workload this scenario no longer runs.
>
> *It is not sustainable.* A capacity ladder on 2026-08-19 measured, per arm:
>
> | arm | rungs | capacity | failure mode at the ceiling |
> |---|---|---|---|
> | `spring-axon-jdbc` | 30 ✓ 38 ✓ 46 ✗ | ~45.6/s | soft — queue grows without bound |
> | `spring-axon-embedded-jdbc` | 30 ✓ 38 ✓ 46 ✗ | ~45.7/s | soft — queue grows without bound |
> | `quarkus-lra-jdbc` | 38 ✓ 46 ✓ 54 ✓ | >54/s | not reached |
> | `exeris-community` | 50 ✓ 65 ✗ 80 ✗ | ≥50/s, **not bounded** | admission shedding at default config — see below |
>
> At 50/s both Axon arms were therefore in permanent overload: in-flight work climbed
> monotonically for an entire 11-minute window (545 → 2882 concurrent) and never reached
> steady state, with nothing CPU-saturated anywhere in the deployment.
>
> **What overload does to a percentile is why this is normative.** In overload a
> percentile measures how far the queue grew before the window closed, so it scales with
> *window length* rather than with the system: the same jar reported a saga p95 of 10.5 s
> at a 100 s window, 52 s at a 690 s one, and 401 ms at a sustainable rate. All three are
> "the p95"; only the last is a property of the stack. Every parking-shape latency figure
> recorded before this amendment is a queue-growth artifact and MUST NOT be published as
> latency.
>
> 38/s is a measured clean plateau on every arm tested at it, leaving ~17 % headroom under
> the binding arm. The headroom is deliberate: running any arm near its ceiling makes the
> campaign hostage to small capacity changes — which is how a stack that drifted a few per
> cent produced a 5× latency swing.
>
> **`exeris-community`'s upper rungs measured ADMISSION, not capacity.** The ladder varied
> only the arrival rate and left queue depth at its default, so what the 65/s and 80/s rungs
> found is where the default admission policy begins shedding, not where the runtime runs
> out of work capacity. The error mix says so directly: at 80/s, 11 232 responses were
> **503** and 13 692 were **409** — the stack deliberately refusing load — alongside 4 450
> connection-level refusals. No OOM, no crash. ADR-035's `queueDepthAllowanceRatio`
> (default 8) sheds under high connection count, and the ladder ran several hundred
> connections against it unchanged.
>
> **The arms are not running the same policy, and only one of them has a policy at all.**
> Measured at each arm's own ceiling rung, out of tens of thousands of requests:
>
> | arm | rung | 503 | connection refusals | requests |
> |---|---|---|---|---|
> | `spring-axon-jdbc` | 46/s | **0** | 0 | ~56 000 |
> | `spring-axon-embedded-jdbc` | 46/s | **0** | 0 | ~56 000 |
> | `quarkus-lra-jdbc` | 54/s | 21 (0.03 %) | 0 | ~65 000 |
> | `exeris-community` | 65/s | 216 | 14 395 | — |
>
> Neither Spring nor Quarkus applies request-level admission by default — that is an
> add-on, frequently an experimental one — so they accept everything offered and let the
> queue grow. `exeris-community` sheds by design. The measurements above are the direct
> evidence: the arms that "degraded gracefully" shed *nothing*.
>
> So the two ceilings are **not the same quantity**. For the queueing arms it is a
> service-rate limit — the rate above which work arrives faster than it is retired. For
> `exeris-community` it is the threshold at which a deliberate policy starts refusing.
> Putting them in one column and calling it capacity compares a measurement with a
> configuration setting.
>
> Two earlier readings in this repo were wrong, in opposite directions, and both are
> withdrawn. Quoting 50–65/s as an `exeris-community` capacity ceiling understates it,
> because admission was never equalised. Calling the shedding a "hard failure" while
> calling unbounded queue growth "graceful" inverts the engineering: an unbounded queue is
> not a gentler failure mode, it is the absence of backpressure, and it ends in a
> multi-second response or a timeout rather than a fast, honest refusal.
>
> **Required before any ceiling is quoted as capacity:** an admission-equalised sweep —
> either with `exeris-community`'s shedding raised out of the way so every arm is measured
> on the same accept-everything policy, or with each arm's ceiling reported under an
> explicit policy label and never summed into one comparison.
>
> The re-rate is unaffected: 38/s sits below every arm's shedding point, and the Axon
> capacity figures stand — those were measured with the O0 identity closing and zero
> errors, by queue growth rather than by refusal.
>
> **Runs at 50/s MUST NOT be aggregated with runs at 38/s.** The boundary is carried by
> the `r38` token in `workload_profile_key`
> (`e2e-shop-order-saga-community-h1-loopback-runtime-k6-r38-park100-v3`).
>
> **Capacity is promoted to a first-class reported metric.** For a saga workload under
> shape B — where §2.1 already says end-to-end latency "loses most of its discriminating
> power" because the gateway delay dominates it — the maximum sustainable arrival rate and
> the CPU cost per saga discriminate where latency does not. A capacity figure must state
> its failure mode: an arm that queues and an arm that errors have not demonstrated the
> same thing.
>
> **A capacity claim requires a correctness gate, not just a flat queue.** A failing
> iteration returns its loadgen slot immediately, so a stack collapsing into errors
> produces the same flat concurrency curve as a stack coping. `exeris-community` at 65/s
> showed a textbook plateau (slope +0.087) while 36 % of its requests were failing and
> 14 566 iterations never reached order submission. A rung counts as sustained only if the
> queue is flat **and** the O0 identity closes with no unsubmitted iterations.

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
  READ-SIDE recommendation graph: it is seeded identically from the Postgres
  seed baseline before each run and is never written to by any saga step.
  **CORRECTED 2026-07-30 — it does NOT serve the recommendation step
  identically.** The datastore and dataset are shared; the *access pattern* is
  not. quarkus and spring issue ONE Cypher query expressing the two-hop join
  (`User -PURCHASED_BY-> Product -SIMILAR_TO-> Product`) server-side.
  exeris-community issues **1 + N traversals**, because `GraphTraversal`
  (exeris-kernel-spi) carries exactly one `GraphEdgeDescriptor` and no
  `GraphSession` method accepts a heterogeneous edge path — a two-edge-type
  path is not expressible in a single call, so the N+1 is forced by the SPI
  rather than chosen by the adapter. Consequently `recommend_latency_ms` is
  comparable only in the platform-natural sense (each stack's own idiomatic
  access) and MUST NOT be read as a runtime-speed comparison.

  **CORRECTED AGAIN 2026-07-31 — the N+1 above never executed, and the 2.6× /
  2.5× figures this paragraph used to quote are withdrawn.** Evidence:
  `results/raw/e2e-shop-order-saga/20260730T161215Z-campaign-v2-r50/graph-path-defect-probe.json`.
  Three independent defects, each sufficient on its own to make
  exeris-community's hop 1 return empty:

  1. **Edge type.** The adapter traverses `BOUGHT`; the Neo4j seed created
     `SIMILAR_TO`, `PURCHASED_BY`, `IN_CART` and zero `BOUGHT` edges.
  2. **Direction.** The seed wrote `Product-[:PURCHASED_BY]->User`; the adapter
     asks User→Product. `GraphEdgeDescriptor` carries a `Direction`, but
     `CommunityGraphDialect` **ignores it entirely** — every Cypher template
     hardcodes `->`. An incoming traversal is not expressible.
  3. **Node identity.** The adapter keys nodes by
     `UUID.nameUUIDFromBytes("user-"/"product-" + id)`; the seed keyed by the
     Postgres integer. The dialect parses every returned id with
     `UUID.fromString`, so an integer-keyed graph is not merely unmatched, it is
     unreadable.

  An empty hop 1 returned `List.of()`, which the use-case service absorbed
  (`catch (RuntimeException ignored)` plus an empty-ids fall-through) and served
  the recommendation from Postgres. So `recommend_latency_ms` for
  exeris-community measured one fruitless Neo4j lookup plus a Postgres query —
  **not comparable in any sense, platform-natural included** — and part of its
  Postgres CPU was a fallback query neither Axon stack issues.

  The measured mechanism behind exeris's Neo4j cost is also not the N+1: it is an
  **unlabelled traversal anchor**. `CommunityGraphDialect` emits
  `MATCH p = (source)-[:TYPE*1..n]->(target) WHERE source.id = $sourceId` with no
  label on `source`, and Neo4j indexes — including the seed's own
  `user_id_unique` / `product_id_unique` constraints — are label-scoped. The plan
  degrades to a scan: **35 742 db hits versus 6** for the label-scoped
  equivalent, with the redundant `MATCH p=` binding accounting for none of it.
  The descriptor already carries `sourceNode()`/`targetNode()`; the dialect uses
  them only for the SQL/PGQ table name.

  **Fixture change, 2026-07-31 — declared because it accommodates one stack.**
  The Neo4j seed now keys nodes by the UUID (`id`) and carries the domain key
  alongside (`pg_id`), and the purchase edge is `(:User)-[:BOUGHT]->(:Product)`.
  Defects 1 and 3 could only be repaired on the fixture side, because defect 2
  makes the reverse direction inexpressible from the SPI. Mitigating context: the
  PGQ graph track *already* used this exact identity and the `bought_edges` name,
  so this converges two fixtures that should never have diverged rather than
  inventing one for Exeris. The Cypher stacks read `rec.pg_id` directly;
  exeris-community cannot — its SPI returns only the node UUID, so it pays an
  extra Postgres resolve per recommendation, and that cost is deliberately left
  visible rather than equalised away.

  **Still product-side and NOT fixed here** (they belong in `exeris-kernel`, per
  the repository boundary rule) and therefore expected to appear in shape-A
  numbers as genuine Exeris properties: the ignored `Direction`, the unlabelled
  anchor, and the one-descriptor-per-traversal N+1.

  The seed now **fails closed** if the workload's own queries return nothing
  (exits 91–94), because an empty graph result is indistinguishable from a graph
  result at every layer above it — which is how this survived a full campaign.
- **Graph driver pinned:** all cross-stack comparison runs use the Neo4j
  driver for the read-side recommendation path. The Exeris graph
  capability's driver swap (pgq ↔ neo4j) is explicitly OUT OF SCOPE for
  comparison tables; it may be reported as a separate Exeris-only
  experiment under this contract's workload, clearly labeled as such.

## 2.1 Workload shapes (added 2026-07-30)

The scenario defines **three workload shapes**. They exercise different
capabilities, they make different metrics meaningful, and results under them
**MUST NEVER be aggregated or compared across shapes**. Each carries its own
`workload_profile_key` and its own contract ids.

Why three rather than one: until 2026-07-30 this scenario had only shape A and
called it a saga benchmark. It is not one. A saga in which no step ever waits
for the outside world is a transaction script with compensation — and a
transaction script is exactly what one of the compared stacks implements, which
is why its approach looked competitive. A saga engine earns its keep when a step
must wait, possibly for a long time, and when the process may die while it
waits. Shapes B and C exist to measure that.

### Shape A0 — straight-through (`…-inline-r50-v2`) — SUPERSEDED, NOT comparison-eligible

Every step completes inline; nothing parks. All results before 2026-07-30 were
taken under this shape.

**A0 is not a valid cross-stack comparison and is retained only as historical
record.** The stacks do not execute the same work in it: quarkus-hibernate runs
the entire saga synchronously on the request thread (a transaction script with
compensation), spring-hibernate runs it asynchronously through Axon Server, and
exeris-community runs it through the flow scheduler. All three return the
terminal outcome inline, so they share an observable contract — but a shared
observable contract is not equivalent execution.

This was briefly mislabelled: on 2026-07-30 `order_create_latency_ms` was lifted
to `comparison_eligible` on the grounds that the *resolution model* had been made
uniform. Resolution uniformity does not imply execution equivalence, and lifting
it discarded the original `coverage_limited_saga_engine_not_equivalent` label
that existed for exactly this reason. Corrected: A0 results are **descriptive per
stack**, and no cross-stack row may be built from them.

Superseded by shape A.

### Shape A — minimal park (`…-park1-v3`)

`S_pay` dispatches to the external payment gateway and parks; the gateway answers
as fast as it can (~1 ms configured; loopback round-trip dominates).

The point is **structural**, not temporal: every stack must implement
dispatch → park → external event → wake. No stack can satisfy this shape with a
synchronous transaction script, so for the first time all stacks execute the same
shape of work and the comparison is about the machinery rather than about three
different machines wearing the same interface.

- **Answers:** what does the orchestration machinery itself cost — one park/wake
  cycle plus the request path — when the external wait is negligible?
- **Meaningful:** end-to-end latency, CPU per saga, RSS, throughput. This is the
  only shape in which saga latency is a legitimate headline, because it is the
  only one where the external wait does not dominate it.
- **Note:** parked concurrency is ~0 by construction (rate × ~2 ms), so this
  shape says nothing about parked capacity. That is shape C's job.

### Shape B — short park (`…-park100-v3`)

`S_pay` dispatches to the external payment gateway and parks; the gateway
answers after ~100 ms.

- **Answers:** what does one asynchronous hop cost, and does the engine handle
  it without pinning a resource per in-flight saga?
- **Meaningful:** CPU per saga, resources held while parked (threads, DB
  connections, sockets), wake throughput.
- **Read with care:** end-to-end latency is dominated by the gateway delay,
  which is identical for every stack, so it loses most of its discriminating
  power. Report it only alongside the delay.

### Shape C — long park (`…-parkN-v3`)

`S_pay` parks and is **not** released until the harness decides. Sagas
accumulate. This is the corporate-approval shape: a park may last days.

Phase structure (normative):

| phase | what happens | measured |
|---|---|---|
| A accumulate | orders arrive, **no callbacks issued** | parked count reached; the point at which a stack stops accepting |
| B hold | N parked, system otherwise idle | **bytes of RSS per parked saga**, idle CPU at N, threads, DB connections held |
| C restart | target killed and restarted | parked sagas surviving; wall-clock to recover N |
| D release | callbacks flood in | wake throughput, wake latency |

**N tiers** (run as a ladder, each a separate run):
`N = 10 000–50 000` · `N = 100 000` · `N = 100 000+ to failure`.

- **Answers:** can a stack hold N parked sagas at all; what does one cost; do
  they survive a restart; how fast can they be woken.
- **Meaningful:** parked capacity ceiling, bytes per parked saga, idle CPU at N,
  restart survival ratio, recovery time, wake throughput.
- **FORBIDDEN:** end-to-end saga duration. In shape C the park duration is
  business time chosen by the harness, not system time. Reporting it as latency
  would be meaningless.

**Expected discriminator, stated in advance so the run can falsify it:** a stack
that parks by blocking a request thread has a capacity ceiling at its thread
pool — a few hundred — and cannot express a days-long park at all. A stack that
parks by persisting state is bounded by its state store. If that is what the
ladder shows, it is a categorical difference, not a percentage one, and it
should be reported as such.

Shape C is also the only shape in which **§6 G1 is measurable**. The first crash
injection (W3a, 2026-07-30) stranded 1–3 sagas per stack because shape A keeps
only ~1.2 sagas in flight at any instant; at N = 10 000 parked, crash recovery
has a denominator worth reporting.

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

### 3.1 Declared terminal vocabulary (normative, added 2026-07-31)

Each stack MUST declare, as data in `scenario.json` under its contract id, three
things:

| field | meaning |
|---|---|
| `resolution_model` | `inline`, `polled`, or `inline_with_polled_fallback` |
| `terminal_field` | the exact response field carrying the terminal outcome |
| `terminal_tokens` | the exact token this stack emits for each of the three §3 terminal states |

The harness MUST read this declaration and MUST NOT infer either the field or the
tokens. A stack whose declaration is absent, incomplete, or contradicted at preflight
**does not run**.

**Preflight (normative).** Before the measurement window opens, every stack is driven
through one forced-decline and one forced-success transaction, and the harness MUST
observe the declared `COMPENSATED` and `COMPLETED` tokens on that stack's declared
field. Failure to observe either is a **launch failure, not a result**.

**Why a declaration rather than broader matching.** Accepting a second field name
raises tolerance without removing the class — the next stack brings a third. A
declaration turns a silent non-match into a loud missing declaration. Two live
examples found on 2026-07-31, both in the same file: the inline path accepted
`body.saga_status`, which no stack emits (dead tolerance, protecting nothing today and
hiding the real mismatch tomorrow); and `FAILED` was accepted though §3 never defines
it, and was bucketed as unrecovered — so a stack emitting it on a declined payment
would have turned a **missing compensation (a G2a violation) into an O3 line item**.

**Scope note.** `resolution_model` is already load-bearing for §8 (inline stacks do
not pay the polled stacks' up-to-1 s quantization). Declaring it here makes one
property serve both the detector and the latency caveat.

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
| **G2a Compensation occurrence** | Every declined orderId reaches `COMPENSATED` | exact-count gate against the seeded population, **client-observed at the HTTP boundary** — VERIFIED |
| **G2b Compensation set and order** | the compensation set equals the completed forward-step set, exactly once per step, in LIFO order | out-of-process effect ledger keyed `(orderId, stepId, direction)` — §7 O2. **NOT BUILT, NOT CLAIMED** |
| **G3 Termination** | Every issued orderId reaches a terminal state (`COMPLETED`/`COMPENSATED`/`FAILED_UNRECOVERED`); no saga remains in-flight after drain timeout | drain scan |

**G2 split, 2026-07-31 (v2.1) — normative.** v2.0 stated G2 as one guarantee
verified by "exact oracle §7". That oracle does not exist. What exists is a count
of status strings observed by the k6 client at the HTTP boundary, which can show
that a declined order reached `COMPENSATED` but can say nothing about *which* steps
were compensated or in what order. Splitting it is not a weakening of the contract:
it is the contract finally describing what the harness measures. G2b returns in full
when O2 is built.

**G3 asterisk (normative disclosure):** administrative termination paths
that bypass compensation (Restate `kill` vs `cancel`; any Exeris hard-abort;
Axon equivalent) are documented per stack in §9 but are NOT exercised in
benchmark runs. Crash injection (W3) uses `kill -9` of the *service/app
process* (and, in a separate variant, of the orchestrating server process
where one exists) — never administrative cancellation APIs.

## 7. Oracles (external, shared)

> **Status, 2026-07-31 (v2.1) — read before citing anything from this section.**
> The external oracle service described below **has not been built.** What the
> harness has is a count of status strings observed by the k6 client at the HTTP
> boundary. O2 in particular is therefore *specified, not implemented*, and
> `saga_compensated_total` is **not** O2 — it is "how many clients saw the word
> COMPENSATED". §6 now carries that split as G2a/G2b.
>
> This is worth stating plainly rather than burying: **the oracle specified here
> would have been immune to the defect that produced the v1 zero-compensation
> figure.** A ledger fed by the stacks reporting `(orderId, stepId, direction)` does
> not parse a status string, so it cannot be blinded by a field name. The fix was
> written into v2 in July and not built; what was built instead had exactly the
> failure the spec existed to remove. O0 and §3.1 are the compensating controls.

All stacks report side effects to the same external oracle service
(out-of-process counter store, itself durable), keyed by
`(orderId, stepId, direction)` where direction ∈ {forward, compensation}.

- **O0 — outcome accounting (PRECONDITION for O1–O3).** Every issued `orderId`
  MUST be accounted for in exactly one terminal bucket: `COMPLETED`,
  `COMPENSATED`, `FAILED_UNRECOVERED`, `UNRESOLVED`, or `SUBMIT_REJECTED`. The
  harness MUST emit all five as counters, and the identity

  ```
  completed + compensated + unrecovered + unresolved + submit_rejected == issued
  ```

  MUST hold exactly. A run in which it does not emits `detector_fault` and supports
  **no correctness claim in either direction** — the same standing as `error` and
  `skipped`. Sessions that abort *before* issuance are counted separately
  (`not_submitted`) and are deliberately OUTSIDE the identity: they never increment
  `issued`, so including them would break the very check O0 exists to make.

  **Rationale (normative, do not drop when quoting).** A single compensation counter
  cannot distinguish *"the system did not compensate"* from *"the observer did not
  see it"*: both read zero. A balanced set can, because a blind observer cannot
  satisfy the identity — the sagas it failed to classify have to land somewhere. O0
  exists because the v1 zero-compensation defect was a failure of the second kind and
  was reported as the first.

  **The identity alone is not sufficient, measured 2026-08-18.** A detector that
  cannot recognise a stack's `COMPENSATED` token classifies those sagas as
  `UNRESOLVED` and the sum still balances. Two further conditions therefore also emit
  `detector_fault`:
  1. `unresolved` above 2 % of issued — an unresolved saga is an observation failure,
     not an outcome. Bound matches the existing `saga_status_resolved` threshold.
  2. **zero compensations observed where §4.1 expects a non-zero count** — the v1
     signature exactly. Reported as `detector_fault` rather than gate FAIL because the
     run cannot distinguish "did not compensate" from "could not see it", and either
     verdict would be a guess. Condition 2 exists because condition 1 was measured to
     have thin margin: a fully blind detector yields `unresolved ≈ the decline rate`,
     so at 3 % it landed at 2.29 %, and at a 1 % decline rate it would slip under.

- **Negative control (normative, per contract revision).** The `detector_fault`
  mechanism MUST itself be demonstrated, not asserted: at least once per contract
  revision, a run is executed with a deliberately falsified `terminal_tokens`
  declaration on one stack, and the harness MUST emit `detector_fault` rather than a
  compensation figure. The control run and its verdict are committed alongside the
  campaign. **A check that has never been observed to fire is not evidence that it
  would.** First execution: `results/raw/e2e-shop-order-saga/negative-control-20260818/`.

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

**Which metrics are legitimate depends on the §2.1 workload shape.** A metric
that is a headline in one shape is meaningless in another, so every reported
figure MUST name its shape.

| metric | shape A (straight-through) | shape B (short park) | shape C (long park) |
|---|---|---|---|
| end-to-end saga latency | **headline** | secondary — dominated by the gateway delay; always state the delay | **FORBIDDEN** — park duration is business time chosen by the harness |
| CPU per saga | yes | yes | yes (per completed saga; exclude the hold phase) |
| RSS | yes | yes | **as bytes per parked saga** — the headline for C |
| throughput | yes | yes | as **wake throughput** in the release phase |
| resources held per in-flight saga (threads, DB connections) | n/a | **headline** | **headline** |
| parked capacity ceiling | n/a | n/a | **headline** |
| restart survival + recovery time | n/a | n/a | **headline** (the only place §6 G1 is measurable) |

The remaining rules apply to every shape:

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
  **Strengthened 2026-08-20 (v2.2): the tier MUST be rendered as a column in every
  comparative table, together with its source**, and the source MUST distinguish
  *verified from live configuration* from *declared from a product default*. The
  2026-08-20 shape-B campaign was uniformly T2 and so was never at risk of a cross-tier
  claim — but its first draft table carried no tier column at all, which means the
  reader had to take that on trust. A rule that is satisfied invisibly is indistinguishable
  from a rule that was ignored. Worked example from that campaign: the four
  Postgres-backed arms are `T2-fsync-node-durable-postgres` verified from
  `synchronous_commit=on` / `fsync=on` read off the running server, while Restate is
  `T2-fsync-node-durable` declared from `restate-server-1.7-wal-fsync`, a documented
  product default we did not independently verify. Same tier, different evidential
  standing, and the column must show both.
  T3 (replicated) is planned but explicitly decoupled from v2: it enters as
  a separate contract revision only after passing its own correctness gates
  (replica crash injection, partition behavior, quorum-before-ack
  verification — DST-validated first), independent of this benchmark's
  timeline. Until then, no Exeris result may be juxtaposed with published
  replicated-cluster numbers of any other stack.
- ≥ 5 measured runs after discarded warm-up; variance reported.
- **Apparatus-limitation labels (added 2026-08-20, v2.2).** A known limitation of the
  measuring apparatus is carried by the **metric**, not by the run, and never by silence.
  A run whose numbers stand under a bounded, direction-known limitation is not a retraction
  and must not read like one; conversely a metric that inherits a limitation must not be
  quotable as if it did not. This is the same device as the `coverage_limited_*` labels
  already in this contract, applied to the instrument rather than to the scope.

  First label: **`apparatus_limited_shared_cpuset`**, on every container-derived CPU figure
  from the 2026-08-20 campaigns (1024m and 256m tiers). Verified at the cgroup level, not
  inferred: `postgres`, `payment-gateway`, `restate-server` and `lra-coordinator` all report
  `cpuset.cpus.effective = 6-7,14-15` — one four-thread set, two physical cores with SMT.
  So a three-process arm crowds its coordinator onto the same two physical cores its Postgres
  already occupies, and a two-process arm has nothing to crowd. Backend-set utilisation runs
  5.8 % (exeris-community) to 21.7 % (spring-axon-jdbc) while the eight-thread target set runs
  2.4 % to 8.5 %, i.e. the wide set carries the light load.

  **Direction is known and runs toward the thesis**, which is why it is labelled rather than
  quietly carried: process count drives the crowding, and process count is what §1 makes the
  unit of comparison, so the apparatus penalises the architecture under test in the same
  direction as the claim. The payment gateway — identical work on every arm by construction —
  fits `gateway_s = 51.80 + 0.01466 x backend_set_s` with R² = 0.943 across five arms.

  **The coefficient does NOT license a correction**, and no such correction is applied. It was
  fitted on a 52 s container and would be extrapolated across a 17x range to a 165-900 s one,
  on n = 5, with SMT as the mechanism — under which interference depends on how much the victim
  itself computes, making the smallest container in the set the worst possible calibrator for
  the largest. Neighbour load is also not monotonic with the set total (exeris-community's
  Postgres has the sparsest neighbourhood at 54 s; the three coordinator-bearing arms cluster
  at 260-290 s), so a coefficient correction would not move rows in parallel. The fix is
  topological, not statistical: disjoint pin sets per measured container.

  **A third outcome the repin control cannot rule out on this host.** `dockerd`, `containerd`
  and `rsyslogd` run with affinity `0-15` (verified; `taskset` on them fails EPERM, this account
  has no passwordless sudo, and the kernel cmdline carries no `isolcpus`), and their load is not
  constant across arms. So the planned control — gateway spread must fall below the ~2 %
  within-arm spread — has three possible outcomes, not two, and an unpinned-housekeeping term
  can hold the spread up and be misread as a genuine load difference. Until housekeeping can be
  confined, that term is measured and bounded rather than removed
  (`tools/saga/host-housekeeping.sh`), and the control's verdict is reported with it.


## 9. Per-stack deviation register

Every stack entry in the report carries a mandatory section listing: (a)
where its native idiom differs from the contract wording (e.g. Restate
compensations as user-space pattern vs Exeris kernel-level unwind — both
satisfy G2; the difference is the finding, not a violation), (b) its
administrative-termination semantics (§6 G3 asterisk), (c) its retry
configuration proving §5 compliance, (d) adversarial tuning applied in the
stack's favor, **(e) configurations available but not measured**.

**(e) — added 2026-07-31 (v2.1).** Any deployment configuration of this stack that is
materially cheaper, smaller, or simpler than the one measured, and was not measured.
Named so the measured configuration is never read as the framework's requirement.
(d) guards against being too generous to another stack; (e) guards against being too
harsh — it is the only part of this register that protects a stack from us.

**First entry, discharged 2026-08-20 (v2.2).** Axon embedded (`EmbeddedEventStore` +
JPA stores + `SimpleCommandBus`), a 2-process deployment unit against the measured 3,
was the register's first entry. It is now a measured arm (§1). Discharge by measurement
is the intended terminal state of an (e) entry: the register exists to stop a cheaper
configuration from going unmentioned, and the strongest form of mentioning it is a row
in the table. An entry is discharged only by measuring it, never by deciding it does
not matter.

**Standing entries.**

- *spring-on-exeris* is measured in its **compatibility** configuration
  (`exeris-spring-runtime-app-comp`). The **pure** configuration
  (`exeris-spring-runtime-app-pure`) is available and cheaper, and is not measured
  here. Note the direction: this entry is (e) applied against our own stack, and the
  measured configuration is the more expensive of the two.
- Native-image builds exist for both spring-on-exeris configurations
  (`…-comp-native`, `…-pure-native`) and are not measured under this contract.
- The Axon Server heap ceiling applied in this harness is **(d)**, not (e) — it is
  tuning we imposed, not a configuration the framework offers.

Adding an arm to §1 does not empty this register; it moves one entry out of it. New
entries are added whenever a cheaper configuration of a measured stack is identified,
including our own.

## 10. Retroactive validity of v1 results

| v1 result class | Status under v2 |
|---|---|
| Environment/client symmetry, protocol notes | valid, carried over |
| Happy-path latency/throughput (Exeris, Axon×2) | conditionally valid — must be re-labeled as `COMPLETED`-population metrics; re-run recommended for the §8 split |
| Compensation correctness findings (Axon zero-compensation) | superseded — must be re-tested under §4.1 deterministic terminal fault; v2 turns the anomaly into a pass/fail assertion |
| Any mixed-population latency table | invalid under v2, do not cite |

## 11. Change log

- **2.2** — Axon embedded promoted from §9(e) to a measured arm, as a distinct
  2-process deployment unit that must never be collapsed with the Axon Server row
  (§1, §9e); `spring-on-exeris` added to the measured roster, closing a gap where
  §1 named it and no contract id existed for it; §9(e) reworked around
  *discharge by measurement* and given standing entries, two of which apply against
  our own stack (§9e); durability tier required as a **column with its source**, and
  the source required to separate verified-from-config from declared-from-default (§8).

  **Origin.** A review of the 2026-08-20 shape-B campaign against this document, and
  every delta traces to the same failure mode: **the contract and the measured roster
  had drifted apart, in both directions at once.** The campaign measured an arm §1
  declared unmeasured, and omitted an arm §1 listed. Neither was caught by any gate,
  because every gate in §7 validates a run against its own contract id and nothing
  validates the set of contract ids against §1.

  Two further findings from that review are compliance failures against rules that
  already existed, and so change no wording here — recorded because a rule that is
  broken silently is worth as much as a rule that is absent. First, the campaign led
  its headline with end-to-end latency in shape B, which §2.1 says "loses most of its
  discriminating power" and §8 lists as *secondary*; the shape-B headline metrics are
  CPU per saga and resources held per in-flight saga. Second, §8 requires ≥ 5 measured
  runs and the campaign ran 3.

  A third is a limitation rather than a failure, and belongs in the reader's hands:
  at the §2 normative rate the measured in-flight saga population is 4.7–16.7, at which
  "resources held per in-flight saga" cannot discriminate between a thread-per-saga and
  a state-per-saga engine — measured thread counts are dominated by fixed framework
  pools and the ratio inverts, ranking the arm with the fewest in-flight sagas worst.
  Shape B can state the metric; only shape C can make it mean anything.

- **2.1** — O0 outcome-accounting identity as precondition for O1–O3, with
  `detector_fault` added to the verdict enum, plus the unresolved-rate and
  zero-against-nonzero conditions the negative control showed were needed (§7);
  declared per-stack terminal vocabulary and mandatory preflight (§3.1); negative
  control required per contract revision and executed (§7); deployment-unit table
  reconciled with §2 and process counts made comparable (§1); Axon Server restated as
  the measured configuration rather than a framework requirement (§1, §9e); stack list
  reconciled with implementation, including that the Quarkus arm never ran an Axon
  saga (§1); G2 split into G2a (verified, client-observed) and G2b (out-of-process
  ledger, not built, not claimed) (§6, §7); §4.1 exactness scoped to the
  actually-issued population; graph removed from the scenario entirely (§2).

  **Origin.** Every delta in 2.1 traces to one defect: the v1 zero-compensation figure
  was a detector fault reported as a measurement, and neither the gates nor any reader
  caught it. O0, §3.1 and the negative control are the three independent places that
  failure is now blocked.

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
