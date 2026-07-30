# Spike: MicroProfile LRA as the quarkus saga engine — 2026-07-30

**Outcome: LRA is rejected as the quarkus peer implementation.** The spike stopped
early because its first question came back decisive.

## Why the spike existed

`quarkus-hibernate` has no saga engine. It uses Axon only as a command bus
(`AxonBusConfig` produces `CommandBus`/`CommandGateway`/`Serializer` and
deliberately no `EventBus`), even though `axon-modelling:4.10.3` — `@Saga`,
`SagaStore`, `AnnotatedSagaManager` — is on its classpath. So the CONTRACT-v2
§2.1 shape A restructuring left it structurally correct (dispatch → park →
external event → wake) but hand-rolled.

Three candidate fixes were on the table, and PROPOSAL decision 4 ("restructure
into a genuine async saga … makes it MORE platform-natural") did not settle
*which* engine.

## Question 1 — does LRA compensate LIFO? **NO GUARANTEE. Decisive.**

CONTRACT-v2 §2 requires compensations to unwind LIFO. Every current stack
provides that: the Exeris kernel drives it, and the Axon and Restate stacks get
it because the unwind chain is hand-coded.

MicroProfile LRA does not provide it. From the specification's own `@Compensate`
javadoc (`microprofile-lra-api:2.0.2`, the version managed by the Quarkus 3.34.3
platform BOM):

> "The LRA specification makes no guarantees about when Compensate method will be
> invoked, just that it will eventually be called."

The API sources contain no other ordering statement. The only place ordering is
mentioned at all is nested-LRA callbacks, and there it is explicitly disclaimed:
"The order in which the two callbacks are invoked is undefined."

That is a direct conflict with §2 on **exactly the axis §4.1 and §7 measure** —
the compensation path and its exact-count oracle.

### What was NOT determined

Whether Narayana's coordinator happens to compensate in reverse enrolment order
**is unknown**. `io.narayana.lra.coordinator.domain.model.LongRunningAction` does
carry a `protected RecordList invert(RecordList)` called from `doEnd(boolean)`, so
participant ordering is deliberately manipulated somewhere in the close/cancel
paths — but determining which branch inverts requires following the bytecode's
control flow, and reading it linearly is how one reports a confident wrong answer.
An empirical run was not performed: the coordinator jar ships no `Main-Class` (it
is a JAX-RS application needing a container), and the local Docker engine is
unavailable (`com.docker.service` stopped; starting it needs administrator
rights).

**This does not change the conclusion, and that is the point.** Even if Narayana
happens to unwind LIFO today, building a contract requirement on unspecified
behaviour is precisely what this repo's fairness rules forbid — it would be
version-fragile and undetectable when it changed. Under the "prefer the stricter
interpretation" rule, an unguaranteed ordering is an absent ordering.

## Questions 2–4 — not investigated

`timeLimit = 0` for shape C's day-long parks, `@AfterLRA` as the §3
request-response hook, and the coordinator's durability tier for §8 were all left
open. Answering them would only have refined an option that question 1 already
removed.

## What this reverses

The recommendation before the spike was **LRA over Axon**, on the grounds that it
is Quarkus-native, needs no platform bump, and adds a genuinely different
orchestration paradigm. Question 1 removes it: the paradigm difference is real,
but part of that difference is the absence of a guarantee the contract requires.

## Camel — resolved on the way, and not a separate option

`camel-quarkus-saga` is a real extension, but on Central its dependencies are
exactly `camel-quarkus-core` + `camel-saga`: the Saga EIP only, with no durable
saga service. Durability comes from `camel-quarkus-lra`, which depends on
`camel-lra` **and on `camel-quarkus-saga`** — i.e. Camel's durable saga on Quarkus
*is* LRA with a routing DSL over it, and inherits this same ordering problem. The
alternative service, camel-core's in-memory one, is not durable and would fail §6
and shape C outright — while looking fast precisely because it does not do the
work.

Camel also pins an exact Quarkus version per release (camel-quarkus 3.35.0 →
Quarkus 3.35.0; 3.33.2 → 3.33.2.1). **There is no camel-quarkus release for
Quarkus 3.34.3**, which is what the target runs, so adopting it would mean
changing the runtime under measurement.

## Where this leaves quarkus

| option | LIFO | saga engine | cost |
|---|---|---|---|
| **A. keep hand-rolled** (current, committed) | explicit in our code | none — a row in `PAYMENT_PROCESSING` | zero, already done |
| B. wire Axon saga via `Configurer` | explicit (hand-coded chain, as spring) | yes: persisted saga instances, restart resumption | ~150–250 lines CDI |
| C. LRA | **no guarantee** | yes, coordinator-driven | rewrite + §2 deviation |

**Recommendation: A for now, with honest relabelling.** The target must stop being
described as "Quarkus + Axon": it is *Quarkus + a hand-rolled async saga, with
Axon as a command bus*, and §9(a) must say so.

B remains open and is the only route that gives quarkus a real engine — which
matters for shape C, where A has nothing to recover. It is worth doing before any
shape-C run; it is not worth blocking shape A on.

C should not be dropped from the repo's thinking, but as a **separate labelled
target** measuring the LRA approach on its own terms with the ordering deviation
stated up front — not as the quarkus peer in a comparison whose contract requires
LIFO.

## Addendum — there IS a community Axon extension for Quarkus (checked 2026-07-31)

Raised by the maintainer: `meks77/quarkus-axonframework-extension`. Verified on
Maven Central rather than taken on trust, and it changes option B's cost.

- **Published**: group `at.meks.quarkiverse.axonframework-extension`, modules
  include `quarkus-axon`, `quarkus-axon-sagastore-jdbc`, JDBC/JPA token stores,
  Axon Server / JPA / JDBC event stores, pooled and persistent-stream event
  processors, metrics, tracing.
- **Saga support is real**: `@SagaEventHandler` / `@StartSaga` / `@EndSaga` — the
  same annotations `spring-benchmark-app`'s `OrderFulfillmentSaga` already uses.
  Saga store: InMemory (default), JDBC, JPA.
- **Targets Quarkus 3.34.3 exactly** — the version this target already runs
  (`<quarkus.version>3.34.3</quarkus.version>` in the RC29 root parent, published
  2026-04-09). No platform bump, unlike Camel.
- **Pre-1.0 and unofficial**: the Axon-4 line stops at `0.1.0-RC29` and never
  reached 1.x despite the README's stated scheme; the Axon-5 line is
  `2.0.0-alpha4`. It is one person's repository, not the Quarkiverse organisation,
  despite the `at.meks.quarkiverse` group id.

So option B is cheaper than "~150–250 lines of CDI" — it is a dependency plus
configuration. **The conclusion is unchanged**: this is not the Spring-grade
support Quarkus lacks, and a pre-1.0 community extension is not what a typical
team would run.

**Trap to respect if we ever adopt it**, straight from its own docs: the default
saga store AND the default token store are in-memory ("not recommended for
production use"). That configuration would look like a wired saga engine, would
not be durable, and would make quarkus look fast precisely because it was not
doing the work — the exact failure class this scenario keeps producing. JDBC
would have to be explicitly configured **and verified**, not assumed. The Axon
version would also have to be pinned to spring's 4.10.3, or the
"same engine, different host" claim does not hold.

### Method note on how this was nearly missed

The first check of this extension was a single fetch of its README, which
concluded sagas were "conspicuously absent, suggesting they are either unsupported
or not yet implemented". That was **wrong** — the repository tree shows
`SagaEventhandlerBeanBuildItem`, a dedicated `05-09-Sagas.adoc` docs page, and a
whole `quarkus-axon-sagastore-jdbc` module. One source, confidently summarised,
on the exact question that decides option B. Same failure mode as reading
bytecode linearly to infer control flow, and it is worth recording next to the
finding it almost inverted.

## Finding worth carrying into the report

Quarkus has no idiomatic durable saga engine that satisfies this contract on the
terms Spring gets for free:

- its **native** option (MicroProfile LRA, directly or through Camel) guarantees
  no compensation ordering, which §2 requires;
- its **Axon** path exists only as a **pre-1.0, single-maintainer community
  extension** (`0.1.0-RC29` on the Axon-4 line), against Spring's official
  `axon-spring-boot-starter` autoconfiguration.

That is a real ecosystem asymmetry, and it is a more interesting result than any
latency number this scenario has produced so far. It should be reported as such,
not buried in a deviation register.
