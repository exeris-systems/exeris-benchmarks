# Crash injection (CONTRACT-v2 §6 G1 / W3) — design

Status: **design + runner, no results yet.** Nothing in this document is a
measurement; it defines what will be measured and, importantly, what each
variant does and does not prove.

## Why this is needed

§6 states three guarantees; the implementation ledger concedes that **G1 has
never been exercised** — "no crash injection (W3), so G1 'despite crash
injection' is not exercised". Everything verified so far is steady-state.

That gap became load-bearing on 2026-07-30, when the whole-deployment CPU
numbers came out as:

| stack | CPU per saga | saga state written to Postgres |
|---|---|---|
| quarkus-hibernate | 6.85 ms | none (`saga_entry`/`token_entry` inserts = 0) |
| exeris-community | 11.7 ms | `exeris_saga_state`, 2 640 rows |
| spring-hibernate | 14.8 ms | none in Postgres; events in Axon Server |

Read naively that says quarkus is 1.7× cheaper than exeris. But quarkus has **no
saga** — `AxonOrderSagaCommandHandler.handle()` runs every step synchronously on
the request thread inside one method, with try/catch compensation. It persists
no saga state because it has none to persist. Cost differences between stacks are
uninterpretable until we know **what each one buys with them**. That is what
crash injection measures.

## The scope question: application-only, or whole stack?

Both, as separate fault classes, because they test different claims.

### W3a — application-process crash (PRIMARY, cross-stack comparable)

`SIGKILL` the target JVM mid-measurement; leave Postgres, Neo4j and Axon Server
running; restart the target; drain.

This is the scenario every stack implicitly claims to survive, and the one that
actually happens in production (a pod is evicted, an OOM kill, a rollout). It
tests exactly one thing: **is saga state externalised, and can an in-flight saga
resume from it?**

It is the fair comparator because each stack keeps saga state outside the app by
its own chosen mechanism — Exeris in Postgres, Axon in Axon Server, quarkus
nowhere — so no stack is advantaged by where it put that state, only by whether
it put it anywhere.

### W3b — whole-deployment crash (SECONDARY, durability-tier probe)

`SIGKILL` the target JVM **and** its state stores (Postgres, Axon Server)
together, then restart everything.

This tests the *stores'* durability rather than the application's: Postgres
`synchronous_commit=on` and Axon Server's own storage decide the outcome. It is
the empirical check on the `durability_tier` label (§8), which is currently
asserted rather than demonstrated.

Keep it separate from W3a and never merge the results: a stack can pass W3a and
fail W3b, and the two say different things.

**A labelling defect W3b should settle.** Every run today stamps
`durability_tier: T2-fsync-node-durable-postgres`. That is true of the *domain*
datastore, which really is identical across stacks — and it makes the stacks look
uniform on durability while their **saga-state** durability is not comparable at
all. The campaign rollup's `durability_tier_uniform: true` is therefore true of
the label and false of the reality.

## What is measured

Every stack writes `orders` to Postgres, so recovery is observable without any
stack-specific instrumentation:

1. **Stuck-saga count** — after crash, restart and drain, how many `orders` rows
   remain in a non-terminal status? A durable saga resumes and drives every
   in-flight order to `COMPLETED` / `CANCELLED`. A non-durable one abandons them.
   This is the headline number.
2. **Resumption, not restart** — for orders in flight at crash time, did the
   saga continue from its last completed step, or redo work? Detected via the
   outbox: duplicated `PAYMENT_REQUESTED` rows for one order mean re-execution
   (an O1 duplicate-execution violation), not resumption.
3. **Compensation completeness** — the §4.1 oracle still applies to the issued
   population; a crashed run must not lose compensations.
4. **Time to drain** after restart.

## What this will NOT prove

- Nothing about performance. Crash runs are correctness-only and must never feed
  a latency or throughput table.
- Not a full §7 oracle: still no per-`(orderId, stepId, direction)` ledger, so
  LIFO ordering remains unverified.
- W3a says nothing about store durability, and W3b says nothing about
  application-level resumption. Do not let one stand in for the other.

## RESULTS — W3a, first run, 2026-07-30

| stack | in-flight stranded after recovery | duplicate payment steps | verdict |
|---|---|---|---|
| exeris-community | 3 | 0 | stranded |
| quarkus-hibernate | 1 | 0 | stranded |
| spring-hibernate | 1 | 0 | stranded |

**No stack resumed its in-flight sagas.** Nothing was re-executed either
(duplicate payment steps = 0 everywhere), so the sagas did not redo work — they
simply stopped.

**Both predictions below were falsified.** quarkus was expected to fail and did;
exeris was expected to PASS and did not. The prediction that mattered was wrong.

**Why exeris did not pass — and why that is NOT a defect.**
`exeris_saga_state` grew by only **21 rows** across an entire run issuing
thousands of sagas (2640 → 2661), so flow state is not checkpointed per saga on
the fast path. The kernel TCK explains exactly why, and it means this test was
probing a guarantee the kernel never makes.

`exeris-kernel-tck/.../flow/AbstractSagaRecoveryTck.java` specifies recovery for
**PARKED** flows:

> *Mid-Saga Kill — engine is force-closed while a flow is PARKED; after rebuild
> the snapshot must exist and the flow must resume from the checkpoint step.*

and the test body pins the trigger — `FlowStepAction step1 = _ -> FlowOutcome.PARK`,
asserting *"FlowSnapshotStore.save() MUST be called on PARK transition"* and
*"Checkpoint state must be PARKED"*. There is also a restart-under-load variant
in which N parked instances all resume to `COMPLETED` behind an idempotency
fence. So the guarantee is real, TCK-verified, and **scoped to parked flows**.

Every step of this benchmark's saga returns `CONTINUE` / `COMPLETE` / `FAIL` —
it **never parks**. No park means no snapshot means nothing to resume. Exeris
behaved exactly as its contract says.

**The finding is therefore about the SCENARIO, not the stack.** CONTRACT-v2's
saga is straight-through: no step awaits an external system, so no step parks.
A straight-through sequence with compensation is, structurally, a transaction
script — which is precisely what quarkus implements, and why its approach is
competitive here. Saga orchestration machinery earns its keep when a step must
await an external event (park) or when the process can die mid-flight and must
resume. **This workload exercises neither**, on any stack.

Consequences:

1. W3a as run does not discriminate between the stacks and cannot. All three
   were asked to do something none of them claims.
2. To test the guarantee that actually exists, the workload needs a **parking
   step** — e.g. `charge-payment` parking while awaiting an external payment
   confirmation, which is also the realistic shape of that step. That is a
   CONTRACT-v2 §2 scenario change, not a harness change.
3. The whole-deployment CPU comparison should be read in this light: none of the
   stacks is paying for durable orchestration in this workload, so the cost
   differences are transport, ORM, graph access and event plumbing — not
   durability.

**This run is UNDER-POWERED and must not be used to rank the stacks.** At 50
sessions/s with ~25 ms sagas, Little's law puts ~1.2 sagas in flight at any
instant, so a single crash can only strand a handful — which is exactly what
happened (3 / 1 / 1). The difference between 3 and 1 here is noise, not a
durability ordering. A higher arrival rate does not fix this: these sagas are
fast, so even 500/s yields only ~12 in flight. The fix is **many crash
repetitions aggregated** (10+ per stack ≈ 30 in-flight sagas each), or a
workload variant with deliberately slower steps.

What IS supported by this run: **no stack demonstrated G1 saga resumption after
an application-process crash.** That is a negative result about all three, and
it is the first time G1 has been exercised at all.

## Expected outcomes, stated in advance

Recording predictions before running, so the result can falsify them rather than
be rationalised afterwards:

- **quarkus-hibernate** — expected to FAIL W3a. No saga state exists; every order
  in flight at crash time should be stranded in a non-terminal status.
- **exeris-community** — expected to pass W3a; flow state is in Postgres. Caveat:
  only ~2 640 snapshot rows were written against ~49 000 sagas (~5 %), so
  snapshotting is evidently not per-saga — what triggers it must be established
  first, or a pass may be luck.
- **spring-hibernate** — genuinely unknown. Events are in Axon Server, but
  `saga_entry`, `association_value_entry` and `token_entry` all show **0**
  inserts, so where its saga state lives (and whether it survives) is exactly
  what this run should reveal.
