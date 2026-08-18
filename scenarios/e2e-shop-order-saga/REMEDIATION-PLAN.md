# e2e-shop-order-saga — comprehensive remediation plan

Status: **plan, not agreed.** Written 2026-07-31 after the v2.1 contract review, the
LRA spike, the graph-path defect probe, and the kernel 0.11.0 re-check. Nothing
below is implemented except where marked DONE. Implementation waits on the
decisions in §9.

The organising fact: **the 20260730 campaign measured a scenario that was not
doing what the contract said it was doing**, in four independent ways at once. This
plan is the list of everything that has to be true before the next campaign, and
the order it has to become true in.

---

## 1. Disposition of the existing results — retire them

`results/raw/e2e-shop-order-saga/20260730T161215Z-campaign-v2-r50/` and
`results/reports/2026-07-30-e2e-shop-order-saga-v2-straight-through.md`.

Four independent invalidators, any one of which would be sufficient:

| # | what | scope of damage |
|---|---|---|
| 1 | no step ever parked — a transaction script with compensation, not a saga | the whole premise; shape A0 already `descriptive_per_stack_only` |
| 2 | exeris's recommendation traversal matched nothing and fell back to Postgres | every exeris-vs-* cost row |
| 3 | container CPU understated ~3× (row count read as seconds) | every CPU figure; ordering changed when fixed |
| 4 | quarkus persists no saga state at all — cross-tier comparison §8 forbids | every quarkus-vs-* cost row |
| 5 | run taken while a third party held Postgres superuser | provenance |

**Decision: retire, do not amend.** Keep the directory and the report in place with a
retirement banner, because the defect trail is the most valuable thing in them and
several findings in this plan are only legible against it. But no figure from that
campaign may be cited forward, including in talks.

The one exception worth stating precisely, because it cuts in our favour and
therefore needs the stricter treatment: recomputed from the committed footprints
with the corrected sampling interval, **Neo4j was 8.63 ms of exeris's 20.33 ms
whole-deployment CPU per saga (42%), and 76% of the exeris-vs-quarkus gap** — on a
traversal that returned nothing. That is arithmetic on retired artifacts, not a new
measurement, and it is an upper bound (removing the graph also removes the target
JVM's graph I/O). It is recorded here to explain why the gap will move, not as a
result.

---

## 2. Fairness axes that are currently violated

### 2.1 Durability tier — the sharpest one

CONTRACT-v2 §8 already requires a declared durability tier and **prohibits
cross-tier comparison**. The campaign compared across tiers anyway.

| stack | saga state persisted where | tier |
|---|---|---|
| exeris-community | `FlowSnapshotStore` → v5 tables (Postgres) | durable |
| spring-on-exeris | same kernel flow store | durable |
| spring-axon | Axon Server saga store | durable |
| restate | invocation journal (RocksDB WAL) | durable |
| **quarkus-hibernate** | **nothing — an `orders` row in `PAYMENT_PROCESSING`** | **none** |

Quarkus's lower CPU is in part the cost of work it does not do. Its saga does not
survive a restart; there is no scheduler that will ever reconsider a park. Two
honest resolutions, and only these two:

- **give it a durable engine** (§3.2), then it is comparable; or
- **keep it as-is and label the tier**, in which case its CPU and RSS may not appear
  in the same table as the durable stacks — it becomes a separate, clearly-named
  "no orchestration engine" reference point.

Either is defensible. Silently tabulating it against durable stacks is not, and is
what we did.

### 2.2 ORM parity — real, but not where it was assumed

Checked rather than assumed: **the saga path is already raw JDBC on every stack.**
`OrderSagaStepService` (quarkus) and `PaymentService` (spring) use
`DataSource` + `PreparedStatement` throughout. Hibernate/JPA covers only the
user/friendship/interest entities — the `entity-read-by-id` surface — plus
`register`.

So swapping to JDBC variants does **not** change the saga writes. It changes:

- **RSS and boot footprint** (Hibernate metaspace, entity manager, proxies) — and RSS
  is one of our two durable headline metrics, so this matters;
- the `register` step, which is per-iteration in the current k6 flow.

Available today: `quarkus-benchmark-app-tuned` is already JDBC-only (Agroal, no
Panache).

**Updated 2026-07-31 after merging `origin/main` (`77f17ef0`).** The estimate above
("there is no Spring JDBC variant — it would have to be built") is **withdrawn**:
`targets/spring-benchmark-app-jdbc` already exists **and already carries the saga**
(28 files under `axon/`). What it does not carry is the parking work — its
`PaymentService` still decides the decline inline via `PaymentDeclineRule` and it has
no `PaymentGatewayClient` / `PaymentCallbackController`. So D2 is no longer "build a
target", it is "port the same three-file change already made to
`spring-benchmark-app`".

Upstream also **measured the ORM axis** on entity-read
(`results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md`,
12/12 units `comparison_eligible`), and its findings constrain what we should expect
here:

- the repository layer costs **headroom, not per-request latency** — heavy median gap
  ×1.43 at 600 rps, the arms indistinguishable on the single-row contract up to
  20 000 rps, but the Hibernate arm reaches 94 % of capacity while the JDBC one stays
  flat;
- the largest identified contributor is **Spring Data's projection proxies rather
  than Hibernate's own row mapping** — the pair moves both and the split is unmeasured;
- **23 % of the hosting swap turned out to be Spring Security**, which is why the
  filter chain is now switchable (`SecurityFilterChainConfig`).

That third point applies directly to this scenario: the saga arms run a filter chain
that reaches an authorization decision on every request, and the Exeris arm carries no
Spring Security at all. It is the same confound, on the same rung, and it should be
handled the same way rather than rediscovered.

Also arrived and relevant to the roster: `exeris-spring-runtime-app-pure`,
`-comp-native`, `-pure-native`. None carries flow/saga code — they are entity-read
variants, so they do not join this scenario without the same porting work.

### 2.3 Saga-engine parity

| stack | engine | provenance |
|---|---|---|
| exeris-community / spring-on-exeris | kernel Flow SPI | first-party |
| spring-axon | Axon saga via `axon-spring-boot-starter` | official |
| restate | Restate durable execution | official |
| quarkus | **none wired** | — |

Quarkus's options, both established by the LRA spike (`LRA-SPIKE.md`):

- **MicroProfile LRA** (`quarkus-narayana-lra`, in the 3.34.3 BOM): native, but the
  spec **guarantees no compensation ordering**, which conflicts with §2's LIFO
  requirement. Camel is not an alternative — `camel-quarkus-lra` depends on
  `camel-lra` *and* `camel-quarkus-saga`, so Camel's durable saga on Quarkus *is*
  LRA with a routing DSL over it, and it pins a Quarkus version we do not run.
- **Axon via the community extension** (`at.meks.quarkiverse.axonframework-extension`,
  `0.1.0-RC29`, targets Quarkus 3.34.3 exactly, has a JDBC saga store): gives real
  LIFO because the unwind chain is hand-coded as in spring — but it is pre-1.0 and
  single-maintainer.

**This asymmetry is itself the most interesting result the scenario has produced**
and should be reported as such rather than buried: Quarkus has no idiomatic durable
saga engine that satisfies this contract, where Spring gets one from an official
starter.

---

## 3. Scenario changes

### 3.1 Remove the graph from the saga scenario — AGREED 2026-07-31

Two of the three graph touchpoints were decorative on **every** stack (`cart add` /
`cart get` write an `IN_CART` edge and discard the read), and the third was broken on
exeris. The graph confounded the only comparison the scenario exists to make.

- The three call sites per target are removed. `recommend`, `cart add`, `cart get`
  **remain as HTTP steps**, served from Postgres — which is already what every stack
  actually does (cart was always Postgres-backed; recommend's Postgres path is the
  existing fallback). Keeping them preserves a realistic request mix; a bare
  `POST /orders` would measure less.
- Neo4j leaves the §1 deployment unit: compose, footprint sampler, seed, §1 table.
- **The graph code is not deleted.** It moves to a dedicated endpoint for a separate
  graph benchmark. The work in `42fa5ef` (uniform UUID node identity, `BOUGHT` edge,
  fail-closed seed assertions) is exactly what that benchmark needs.
- New contract ids and profile key: this is another workload change.

### 3.2 Workload shapes

Per CONTRACT-v2 §2.1. Shape A (minimal park) is implemented across all five targets
(`35afd73`) but **has never been run**. Shapes B and C follow. Shape C additionally
needs a durable engine on quarkus, or it has nothing to recover.

### 3.3 Separate graph benchmark — after kernel 0.12

Blocked on the product-side items in §5. Measuring the current graph path would
measure a known defect.

---

## 4. Harness and contract work

From the v2.1 review, in its order.

| # | item | status |
|---|---|---|
| 1 | `else` branch + O0 accounting identity as gate precondition | **DONE** `1332a131` |
| 2 | declared per-arm terminal vocabulary (§3.1), consumed by both resolution paths | todo |
| 3 | negative control — falsify one arm's declaration, prove `detector_fault` fires | todo |
| 4 | §1 deployment-unit table reconciled with §2; Axon Server as measured config not requirement; stack list matched to implementation | todo — **simplified by §3.1**, since Neo4j leaves the unit |
| 5 | G2 → G2a (verified, client-observed) / G2b (not built, not claimed), **or** build O2 | todo — downgrade before any talk; O2 is post-talk work |
| 6 | §4.1 prose: exactness scoped to the actually-issued population; the "deterministic assertion failure" sentence is a promise until the negative control exists | todo |

Contract deltas A–I from the review are accepted as drafted, with one correction
already applied in `1332a131`: **O0's identity must not include `NOT_SUBMITTED`**,
because those iterations abort before issuance and never increment
`saga_issued_total`; including them would break the check O0 exists to make.

---

## 5. Product-side (exeris-kernel) — needed for 0.12

Re-checked against **released 0.11.0** (not the local snapshot — that mistake was
made and corrected). All three survive unchanged:

| # | defect | effect |
|---|---|---|
| 1 | `CommunityGraphDialect` emits an **unlabelled traversal anchor** — `MATCH p = (source)-[:T*1..n]->(target) WHERE source.id = $sourceId` | Neo4j indexes are label-scoped, so the plan degrades to a scan: **35 742 db hits vs 6**. The descriptor already carries the labels; they are used only for the SQL/PGQ table name. |
| 2 | `GraphEdgeDescriptor.direction()` is **accepted and silently ignored** — every Cypher template hardcodes `->` | an incoming traversal is inexpressible; forced the seed to carry a `BOUGHT` edge instead |
| 3 | one `GraphEdgeDescriptor` per `GraphTraversal`; no heterogeneous edge path | the recommendation is 1+N calls where one Cypher query suffices |

Item 2 is the same family as the JFR events that logged zero: an API surface that
compiles, is accepted, and does nothing.

Not a kernel defect but a constraint that shaped the fixture: the graph SPI is
UUID-typed end to end and parses returned ids with `UUID.fromString`, so an
integer-keyed graph is unreadable from it.

---

## 6. Proposed target roster

Ordered by how much has to be built.

| target | runtime | ORM | saga engine | durable | build cost |
|---|---|---|---|---|---|
| exeris-community | Exeris kernel | JDBC | Flow SPI | yes | ready |
| spring-on-exeris | Spring + Exeris compat | **JPA today** | Flow SPI | yes | JDBC variant needed |
| restate | plain JVM | JDBC | Restate journal | yes | ready |
| spring-axon-**jdbc** | Spring Boot | **JDBC** | Axon starter | yes | target exists with saga; needs the parking port only |
| spring-axon (JPA) | Spring Boot | JPA | Axon starter | yes | ready, but retire as a peer — ORM axis, not saga axis |
| quarkus-tuned | Quarkus | **JDBC already** | **none** | **no** | needs an engine (§2.3) |

`quarkus-hibernate` and `spring-hibernate` are retired from the comparison set as
peers; if kept at all they become a separate, labelled ORM axis rather than the
saga-orchestration axis.

---

## 7. Sequencing

Blockers first; each row is startable only when its predecessors are true.

| phase | work | blocks |
|---|---|---|
| **P0** | retire the old campaign + report (banner, no citations) | nothing — do first, it is a claim currently outstanding |
| **P1** | remove graph from saga scenario (§3.1); Neo4j out of the deployment unit | §1 table, footprint, contract ids |
| **P2** | review items 2 + 3 — declared vocabulary and the negative control | **any campaign at all**; without 3, "fixed" is unmeasured |
| **P3** | contract v2.1 deltas A–I incl. §1 table (item 4), G2 downgrade (item 5), §4.1 prose (item 6) | publishing anything |
| **P4** | decide quarkus's engine (§9 D1) and build it | shape A comparison-eligibility, all of shape C |
| **P5** | JDBC variants for spring-axon and spring-on-exeris (§2.2) | footprint/RSS comparability |
| **P6** | mint shape A contract ids + profile key; wire parking through the campaign runner | the run |
| **P7** | smoke: 1 rep, 1 stack, then 1 rep × all — assert gateway `callbacks_ok` == issued, zero stranded | the campaign |
| **P8** | shape A campaign | the report |
| **P9** | shape C (needs P4 durable engine); separate graph benchmark (needs kernel 0.12) | — |

P0–P3 are independent of every build decision and can start immediately.

---

## 8. What must appear in the next report regardless of numbers

- Durability tier per stack, and the §8 prohibition honoured in every table.
- Quarkus's saga-engine gap stated as a finding, not a footnote.
- The retirement of the previous campaign and why, including the 42% graph share.
- The kernel graph defects, attributed to the product, not to "Neo4j being slow".
- `resolution_model` per stack, since it drives both the detector and the latency caveat.

---

## 9. Decisions — RESOLVED 2026-07-31

- **D1 — quarkus's saga engine: `quarkus-narayana-lra`, saga enrolled as a SINGLE
  participant.** RESOLVED.

  Premise corrected first: `quarkus-narayana-lra` is a **first-party** extension —
  groupId `io.quarkus`, in the platform BOM, maintained by Red Hat & IBM, support
  level **preview**. It is available directly; Camel only layers a routing DSL over
  the same coordinator. So the choice was never "unofficial Axon vs Camel", it was
  "official LRA vs a community extension", and the official one wins.

  The single-participant shape is what makes it work despite the spec guaranteeing no
  compensation ordering (`LRA-SPIKE.md`): one participant is enrolled and its
  `@Compensate` unwinds the steps LIFO **in application code**, so §2 is satisfied by
  construction rather than by trusting coordinator behaviour that the spec does not
  promise and that we did not measure.

  | property | outcome |
  |---|---|
  | provenance | first-party, `io.quarkus`, RH/IBM — not a pre-1.0 single-maintainer repo |
  | durability | the coordinator persists open LRAs and enrolments and drives compensate/complete after a restart — a real engine where there is none today |
  | §2 LIFO | preserved, unwound by our code |
  | park | natural: the LRA stays open across the gateway wait |

  **Must be declared, §9(a):** this uses LRA as a durable saga *envelope*, not as
  multi-participant choreography. It must never be presented as "full LRA". The
  `preview` support level goes into the reproducibility metadata.

  Rejected with reason: multi-participant LRA reporting whatever order Narayana
  happens to produce. More faithful to the spec, but it either violates §2 or forces a
  per-stack deviation on exactly the axis §7 measures. Viable later only as a
  separate, labelled target.

- **D2 — Spring JDBC variants: do it.** RESOLVED. Cost is the three-file parking port
  into the existing `spring-benchmark-app-jdbc`, plus a JDBC variant of
  `spring-on-exeris`. The Hibernate arms leave the saga roster and survive only as a
  separate ORM axis if anyone wants one.

- **D2b — Spring Security filter chain.** Still open; see §2.2. Upstream measured it at
  23 % of the hosting rung and made it switchable, and the Exeris arm carries none.

- **D3 — `register` moves out of the per-iteration path.** RESOLVED, and the reasoning
  changed on the way. The ORM half is indeed moot once no arm runs Hibernate. What
  remains is independent of ORM: `registerWithRetry` is called inside the default
  function, so **the `users` table grows by ~16 400 rows during the measurement
  window** — iteration 1 and iteration 16 000 do not measure the same dataset.

  The stronger argument is not stationarity but relevance: **registration is not part
  of an order flow.** `recommend` and `cart` were kept because a customer browses and
  fills a cart before ordering; a returning customer does not register. Registering
  once per order is both unrealistic and non-stationary, so this is the same principle
  that kept the other two, not an exception to it.

  Shape: `setup()` registers a pool of K users once and hands the tokens to the
  iterations; **K = maxVUs and the user is picked by `__VU`**, so no two concurrent
  iterations share a cart — the current per-iteration registration is what guarantees
  cart isolation today, and a naive shared pool would silently introduce cart
  collisions. No target change required: `register` already returns the token, and
  there is no login endpoint to build.

- **D4 — G2: downgrade now, build O2 last.** RESOLVED. Split G2 into G2a (compensation
  occurrence, exact-count gate, **client-observed at the HTTP boundary**, verified) and
  G2b (compensation set and LIFO order via an out-of-process ledger keyed
  `(orderId, stepId, direction)` — **not built, not claimed**). O2 is the final item of
  the programme, after the campaign.

  Worth carrying in the v2.1 changelog as a sentence rather than a line item: the
  oracle §7 already describes **would have been immune to the defect that started all
  of this**, because a ledger fed by the stacks does not parse a status string and so
  cannot be blinded by a field name. The fix was specified in July and not built; what
  was built instead had exactly the failure the spec existed to remove.
