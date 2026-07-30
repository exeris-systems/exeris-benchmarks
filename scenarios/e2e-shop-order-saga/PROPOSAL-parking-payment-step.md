# Proposal: park on `charge-payment` awaiting an external response event

Status: **proposal, not agreed.** Nothing here is implemented. It is a
CONTRACT-v2 §2/§4 scenario change affecting every target app, so it needs a
decision before any code moves.

## Why

The current saga is **straight-through**: every step returns
`CONTINUE`/`COMPLETE`/`FAIL`, nothing awaits an external system, nothing parks.
Structurally that is a transaction script with compensation — which is exactly
what `quarkus-hibernate` implements, and why that approach is competitive here.

Consequences established on 2026-07-30:

- **W3a crash injection cannot discriminate.** The kernel's recovery guarantee
  (`AbstractSagaRecoveryTck`) is scoped to **PARKED** flows —
  `FlowSnapshotStore.save()` fires on the PARK transition. A saga that never
  parks has no snapshot and nothing to resume, so asking any stack to recover
  one is asking for a guarantee none of them makes. All three stranded their
  in-flight sagas; the test was aimed wrong.
- **The orchestration engines never earn their keep.** Durable saga machinery
  pays off when a step awaits an external event, or when the process can die
  mid-flight and resume. This workload exercises neither.
- **The cost comparison is therefore narrower than it looks.** exeris 11.7 ms
  vs quarkus 6.85 ms of CPU per saga is transport, ORM, graph access and event
  plumbing — not durability, because nobody is buying durability here.

A real payment step does not answer synchronously. It dispatches a request and
waits for a response event: continue on authorisation, compensate on decline.

## Shape

1. `charge-payment` dispatches a payment request to an **external payment
   stub** and returns `FlowOutcome.PARK` (Exeris) / awaits the response event
   (Axon) / `ctx.awakeable()` (Restate).
2. The stub responds asynchronously after a configured delay, calling back into
   the target: `POST /api/v1/payments/callback`.
3. The saga unparks: authorised → `CONTINUE` to `confirm-order`; declined →
   `FAIL` → LIFO compensation, exactly as today.

The §4.1 decline rule is unchanged and moves into the stub: same FNV-1a 64
`decline(orderId) := fnv1a64(orderId) mod 1000 < 30`, so the deterministic
population and the exact-compensation oracle keep working untouched.

## What it fixes beyond realism

- **Exercises the guarantee that exists.** Parked flows are what the kernel TCK
  verifies; the benchmark would finally test the thing the product claims.
- **Fixes the crash-test power problem for free.** Parked sagas accumulate:
  parked concurrency ≈ arrival rate × callback delay. At 50/s with a 200 ms
  delay that is ~10 parked at any instant; at 500 ms, ~25. Compare with today's
  ~1.2 in-flight, which is why W3a could only ever strand 1–3.
- **Surfaces the real architectural cost.** A transaction script facing an async
  payment must either block a request thread for the callback delay — throughput
  collapses — or be restructured into an actual saga. That trade-off is the
  thing worth measuring, and today's scenario hides it.

## Decisions needed

1. **Who runs the stub?** A separate process is fairer (every stack pays the
   same external latency and it is part of the deployment unit, §1). In-target
   async would be cheaper to build but lets each stack shortcut differently.
2. **Callback delay** — fixed or distributed, and what value? It sets parked
   concurrency, so it is a real workload parameter, not an implementation
   detail. It must be identical across stacks.
3. **Contract version.** This changes the workload materially, so it is a new
   `workload_profile_key` and new contract ids at minimum. Results under the
   current straight-through model must never aggregate with it.
4. **What happens to quarkus?** Two honest options, and they measure different
   things:
   - restructure it into a genuine async saga (comparable orchestration, more
     work), or
   - leave it synchronous and let it block a thread across the callback — a
     legitimate "platform-natural" answer that would show the cost of not having
     orchestration, but it must then be labelled as a different architecture,
     not a peer implementation.
5. **Does `spring-on-exeris` come along?** It runs the same Flow engine as
   exeris-community, so it gets parking for free and would become the cleanest
   hosting-cost isolation in the scenario.

## Cost

Touches all five target apps, the k6 script (callback wiring is server-side, so
possibly not), the compose stack (new stub service), §2 and §4 of the contract,
and invalidates the current campaign for comparison against future runs. It is
the largest change proposed so far — and the first one that would make the
scenario measure saga orchestration rather than a sequence of HTTP calls.
