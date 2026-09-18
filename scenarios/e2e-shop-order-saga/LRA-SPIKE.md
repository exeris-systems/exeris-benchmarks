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

## Blocker found when wiring it for real — 2026-08-18

D1 was decided on the LRA route and it was implemented (`0ce0a2e4`): coordinator in
compose, `lra_id` on the orders row, single participant, LIFO unwind in application
code. The coordinator starts and answers. The build passes. **The first request
fails.**

```
NoClassDefFoundError: org/jboss/resteasy/concurrent/ContextualExecutors
  at io.narayana.lra.client.NarayanaLRAClient.createCoordinatorClient(:1310)
  at io.narayana.lra.filter.ServerLRAFilter.startLRA(:790)
```

`quarkus-narayana-lra` reaches for **RESTEasy Classic** at runtime. This target runs
**Quarkus REST** (`quarkus-rest-jackson`, formerly RESTEasy Reactive). The build step
is satisfied by either client — its own message says
*"can only work if 'quarkus-rest-client' or 'quarkus-resteasy-client' is present"* —
so the mismatch is not caught until a request actually starts an LRA.

Two things this establishes, neither of them cosmetic:

1. The extension's **preview** support level is not a formality. A first-party
   extension that build-passes and then throws `NoClassDefFoundError` on the first
   request is exactly what preview means.
2. Making it work means putting **RESTEasy Classic** into this target — i.e. changing
   its whole REST layer, which is the layer under measurement. That is not a
   dependency tweak; every resource in the app is on Quarkus REST, and a stack whose
   HTTP layer differs from the one all the other arms use is a different measurement.

**This reopens D1** and the options are now:

- **swap the quarkus arm to RESTEasy Classic** — LRA works, but the arm's HTTP layer
  is no longer the same one the other Quarkus-family measurements used, and that has
  to be declared and probably re-baselined;
- **community Axon extension** (`0.1.0-RC29`) — pre-1.0 and single-maintainer, but it
  targets Quarkus 3.34.3 exactly and does not touch the REST layer;
- **leave quarkus engineless** and label it out of the durable comparison, as §2.1
  already permits — a valid reference point for "what a stack with no orchestration
  engine costs", never tabulated against the durable arms.

The work done is not wasted under any of these: the participant, the `lra_id` binding,
the coordinator wiring and the LIFO unwind are all reusable if the REST-layer swap is
chosen.

## RETRACTED — the blocker was mine, not the stack's (2026-08-18, later)

The section above concluded that `quarkus-narayana-lra` requires RESTEasy Classic and
that D1 was reopened. **That conclusion was wrong**, and the maintainer said so: the
extension works with the reactive Quarkus REST stack. Verified end to end on the perf
box.

Two things were actually wrong, neither of them the stack:

1. **Version.** On Quarkus 3.34.3 the runtime threw
   `NoClassDefFoundError: org/jboss/resteasy/concurrent/ContextualExecutors`. On
   **3.38.2** it does not. The dependency set that works is
   `quarkus-rest-jackson` (reactive server) + `quarkus-rest-client` +
   `quarkus-rest-client-jackson`. Both client artifacts are needed: the LRA build step
   checks for `quarkus-rest-client` **by name** and a transitive copy via `-jackson`
   does not satisfy it, while `-jackson` is what supplies the reactive client with JSON.
2. **My configuration.** After the version bump the failure became
   `Connection refused: localhost/127.0.0.1:50000` — the extension's built-in default
   coordinator port. I had set `mp.lra.coordinator.url` (the MicroProfile name) but the
   extension reads `quarkus.lra.coordinator-url`. Both are now pinned, because a
   coordinator URL that silently falls back to a default is indistinguishable from a
   coordinator outage.

**Result, measured:**

```
vocabulary preflight decline: observed 'COMPENSATED' on 'status' as declared.
vocabulary preflight success: observed 'COMPLETED' on 'status' as declared.
saga_issued_total: 568        correctness gate: pass
```

The decline case is compensated by the **coordinator** invoking `@Compensate`, which is
the point: this arm now has a durable saga engine, and §8's cross-tier prohibition no
longer excludes it from the comparison.

**Why keeping the reactive stack matters here**, and it is not incidental: `@Compensate`
and `@Complete` run on the Vert.x event loop rather than pinning a worker thread per
in-flight coordinator round trip. A parking saga benchmark at a fixed arrival rate is
built to expose exactly that exhaustion mode, so measuring the arm on RESTEasy Classic
would have understated it by construction.

**Carried cost:** this arm is now on **Quarkus 3.38.2**, not 3.34.3. That is a change to
the runtime under measurement and must be recorded in the reproducibility metadata; the
JDBC variant (`quarkus-benchmark-app-tuned`) needs the same bump in P5, or the two
Quarkus arms are not comparable with each other.

**Method note.** I called it a blocker after two failed builds and one runtime error,
and recommended reopening a settled decision. The evidence at that moment was real but
the conclusion outran it — the untested variable was the version, and the maintainer
named it immediately. Worth recording next to the other direction-of-error notes in this
file: I have been quick to escalate an integration failure to an architectural verdict.
