---
title: "Evidence bundle: Every Benchmark Measures Two Systems (tJUG)"
date: 2026-08-22 00:00:00 UTC
categories:
  - benchmarking
  - jvm
  - saga
summary: "Every load-bearing figure in the tJUG talk, keyed to the run-sheet segment that uses it, with its artifact path and the validity fence it sits after. Nothing here is a new measurement: the bundle exists so that a figure on a slide can be traced to a file in one step, and so that figures which are NOT citable are named rather than discovered. Four states are separated deliberately — citable (an artifact exists in this repo), observed-but-unartifacted (measured, reproducible, and unusable under this repo's own traceability rule), retracted (an earlier reading a later artifacted measurement does not reproduce, kept visible so it cannot re-enter from an old note), and forbidden (the retired straight-through report, whose retirement note bars forward quotation of every number in it, including its own corrections). The coordinator's resting footprint moved from unartifacted to retracted on the day this bundle was written: re-measured with an artifact it is 319-381 MB, not the 1 055 MB an ad-hoc terminal reading had produced, though the forced-GC result reproduces exactly. The talk's four abstract promises map to six of eight segments; the crash-resilience promise is paid as a named fidelity, not as a counted result — the 2026-08-25 correction in Segment 3 decomposes the uniform verdict by pre-crash state: parked-on-a-lost-wake stranded on every arm, pre-dispatch work resolved wherever it existed."
authors:
  - Arkadiusz Przychocki
track: Community
benchmark_family: Runtime
scenario: e2e-shop-order-saga
claim_scope: exploratory
reproducibility_status: complete
comparison_axis: within-tier-cross-framework
hardware_profile: perf-box-amd64
---

# Evidence bundle — tJUG talk

Run sheet: eight segments, 30:00. This bundle answers one question per figure: **where
does it come from, and is it allowed on a slide.**

Four states, used consistently below:

- **CITABLE** — an artifact exists in this repository, at the path given.
- **UNARTIFACTED** — measured and reproducible, but the reading exists only as terminal
  output. Under this repo's traceability rule that is not citable. Named here rather than
  quietly used.
- **RETRACTED** — an earlier reading that a later artifacted measurement does not reproduce.
  Kept in the table rather than deleted, so the figure cannot re-enter from an old note.
- **FORBIDDEN** — barred by an explicit retirement.

One figure moved from UNARTIFACTED to RETRACTED on 2026-08-22, which is the point of keeping
the three states apart: an un-artifacted reading is not a small procedural debt, it is a
number nobody has checked.

---

## Segment 2 (3:30) — Where the wait lives

**Claim.** The same framework, deployed two ways — one with its server as a separate
process, one with no server at all — reaches the same ceiling. The cost is the store
round-trip, not the process boundary.

| figure | value | artifact | state |
|---|---|---|---|
| server-backed arm, ceiling | fails at 60/s, passes 50/s | `…/ladderH-…/spring-axon-jdbc-r50-p256/`, `…-r100-p256/`; `…/ladderI-…/spring-axon-jdbc-r60-p256/` | CITABLE |
| serverless arm, ceiling | fails at 70/s, saturated at 60/s | `…/ladderH-…/spring-axon-embedded-jdbc-r50-p256/`; `…/ladderI-…/spring-axon-embedded-jdbc-r60-p256/`, `…-r70-p256/` | CITABLE |
| serverless arm has no external engine | deployment unit = Postgres + gateway only | `…/ladderH-…/spring-axon-embedded-jdbc-r50-p256/deployment-footprint.json` → `components[]` | CITABLE |

**Run-to-run variance to disclose if a Quarkus figure is questioned.** `quarkus-lra-jdbc`
at 70/s passed in ladder G (0.44 % errors, gate pass) and failed in ladder J (0.74 %, gate
fail). n=1 each way; the arm sits on its edge at that rate.

**Scope sentence that must be said aloud.** This is one framework against itself, not a
cross-stack comparison. The trust note disclaims the second; this is the first.

---

## Segment 3 (7:30) — Three guarantees, three fidelities

**Claim.** Crash resilience is measured *under injected failure* — a named fidelity, not a
counted result.

| figure | value | artifact | state |
|---|---|---|---|
| verdict, every arm | `sagas_stranded_after_recovery` | `…/20260821T101236Z-w3a-crash-app-scope/<arm>/crash-recovery.json` | CITABLE |
| crash scope | app JVM only; backing services and coordinators stayed up | same, `crash_scope`, `coordinators_crashed: []` | CITABLE |
| the wake is never redelivered | by design, documented in source | `targets/payment-gateway-stub/payment_stub.py` lines 112–116 | CITABLE |
| cohort resumption, per arm | exeris 0/5 · restate 1/8 · spring-axon 10/14 · spring-axon-embedded 5/8 | same, `in_flight_cohort_at_crash` | CITABLE, n too small to conclude from |
| quarkus in this run | 132-order cohort, no `CANCELLED` at all, 120 stuck at `PAYMENT_DECLINED` | same | **BEHIND THE 415 FENCE — exclude** |

**The verdict is uniform; the behaviour is not.** The rule is
`still_nonterminal > 0 → stranded`, which collapses 71 % resumption and 0 % resumption into
the same word. Both Axon arms resumed the majority of their in-flight sagas after the JVM
was killed. The in-process arm resumed none of five.

**What the gateway stub does and does not explain — corrected 2026-08-25.** This note
previously ended: "It does not account for the difference between 10/14 and 0/5. Something
resumed on the Axon arms." That reading is withdrawn: the `order_status_pre_crash` /
`order_status_post_drain` fields in the same artifacts decompose the difference. Everything
parked at `PAYMENT_PROCESSING` before the kill stayed stranded, on every arm — with a
~100 ms park (shape B), every pre-kill wake fired into the outage, and the stub never
redelivers, so those sagas are unrecoverable on any engine by harness construction. What
resolved — on the arms where anything did — was pre-dispatch, mid-pipeline work
(`CONFIRMED`, `INVENTORY_RESERVED`, `SAGA_INITIATED`) that the store-backed engines
re-drove after restart, dispatching payment late enough for the callback to land on a live
app; the dedicated-server arm resolved one saga and additionally left pre-dispatch work
unresolved (post-drain census: `INVENTORY_RESERVED=1`, `SAGA_INITIATED=1`), so
"resolved = pre-dispatch" is a property of the store-backed arms, not of all four. The in-process arm's census never catches a saga between
start and park — its cohort was lost wakes and nothing else — so 0/5 exercises the
harness's wake-at-most-once policy, not restore-after-crash; the engine's wake-driven
restore path (checkpoint → rebuild → wake → resume; `AbstractSagaRecoveryTck` at
kernel@424ddea — every resume test delivers a wake explicitly) had zero opportunities in
this run. What survives against the in-process engine is narrower and real: no lost-wake
reconciliation exists — recovery is wake-driven and timeout is evaluated on the next step
run (`docs/subsystems/flow.md`) — and the store-backed arms did not solve it either; their
parked sagas stayed equally stranded (server-backed: 4 parked pre-kill, the same 4
non-terminal post-drain). Cohort-capture note: the cohort id list and the census breakdown
are captured moments apart at 38/s, which is why cohort size (5) can exceed the census
non-terminal count (2); both precede the kill.

**So: injected, fails closed, and carrying a signal that runs against my own engine on a
sample of five to fourteen.** That is what gets said at minute eight, and nothing is claimed
from it. An earlier reading of this data as "a uniform verdict, therefore a harness
property" was too quick and is withdrawn: the uniformity was in the label, not in the
measurement.

**Fence.** The quarkus artifact was generated `2026-08-21T10:27:54Z`; the `@Consumes` fix
was committed `2026-08-21 13:58:50 +0200`. That arm's row measures the 415 defect, not crash
resilience, and must not be placed beside the others.

---

## Segment 4 (11:30) — The zero

Every figure here is repo-internal. Nothing needs transferring; everything needs quoting
exactly.

| figure | value | artifact | state |
|---|---|---|---|
| terminal set the poller used | `{COMPLETED, COMPENSATED, FAILED}` | `k6.js` @ `45a9239d` line 37 | CITABLE |
| compensation test | `sagaStatus === 'COMPENSATED'`, read from `body.status` | same, lines 453, 277 | CITABLE |
| what the Quarkus arm returned on the run date | raw `orders.status`, unmapped | `AxonOrderSagaProjection` @ `34f898b9` lines 18, 33 | CITABLE |
| what the compensation path writes | `CANCELLED` | `OrderSagaStepService:168,219`; `InventoryService:69` | CITABLE |
| the Spring arm did the same in v1 | stated in source | javadoc, `spring-benchmark-app/.../AxonOrderSagaProjection` | CITABLE |
| both arms gained contract vocabulary | one commit, two routes | `cf7f4df9`, 2026-07-28 | CITABLE |
| published compensation column | 3.32 % · 0 % · 0 % | the May article | CITABLE, with the correction block attached |

**Added 2026-08-25 — verbatim rows for quotes spoken on stage**, each re-read from source
this day, because a quotation outside this bundle is a number nobody has checked:

- the line-37 comment in `k6.js @ 45a9239d` reads, in full: `// COMPENSATING is
  non-terminal: saga rollback still in progress` — CITABLE;
- the projection SQL at `AxonOrderSagaProjection @ 34f898b9` (constant at lines 17–18)
  reads: `SELECT status, saga_id FROM orders WHERE saga_id = ? AND user_id = ?` — CITABLE;
- the full `verdict_guards` text in every `crash-recovery.json` begins: "An empty orders
  table is NOT a pass: the 2026-08-21 run reported all_sagas_reached_terminal_state for an
  arm whose 3.1 preflight had aborted before a single order was issued." — CITABLE;
- the roster correction in `CONTRACT-v2 §1` reads: "'Quarkus + Axon' was wrong in v2.0:
  the Quarkus arm has never run an Axon saga — Axon was present only as a command bus,
  with the saga hand-rolled." — CITABLE;
- the Axon Server container's presence beside the May Quarkus arm is itself artifacted:
  `20260505T115008Z-baseline/logs/axonserver-docker-stats.csv` — CITABLE;
- the gateway-stub comment at `targets/payment-gateway-stub/payment_stub.py:112–116`
  reads, in full: "A failed callback strands a parked saga. Counted, never retried:
  retrying here would silently mask a target that cannot accept the callback, and the
  stub must not be the thing that hides that." — CITABLE;
- roster fact for the backup deck: `spring-on-exeris` is **listed and pending** — contract
  id `spring_on_exeris_h1_park100_v3` against `exeris-spring-runtime` 0.7.0, no run under
  that id yet (`CONTRACT-v2 §1`) — CITABLE.

**Slide risk.** The metrics table is safe: its columns are labelled by host runtime. The
stack table above it is not — it attributes an event-sourced saga to the arm the roster
correction says never ran one. This is the slide that gets photographed.

---

## Segment 5 (17:30) — Why it survived a day

| figure | value | artifact | state |
|---|---|---|---|
| the two arms did not share an architecture | the Quarkus arm never ran an Axon saga | `CONTRACT-v2 §1`, roster correction | CITABLE |
| the shared vocabulary is mandated | every stack writes the same domain state | `CONTRACT-v2 §2` | CITABLE |
| the oracle would have been immune | stated before the defect was found | `CONTRACT-v2 §7` | CITABLE |
| the fiction's own prediction | longer windows would improve the numbers | the May article, limitations section | CITABLE |

**Not to be quoted.** The 1.22 % / 1.82 % unresolved rates against a 3 % population.
That run injected per attempt; `CONTRACT-v2 §4.1` pins per-`orderId` selection only from
v2 onward. The reconciliation is not owed — it is undefined for that epoch.

---

## Segment 6 (21:30) — What an oracle has to do

| figure | value | artifact | state |
|---|---|---|---|
| the declined subset is an exact integer | FNV-1a, per-`orderId`, `mod 1000 < 30` | `CONTRACT-v2 §4.1` | CITABLE, normative |
| O0 refusing to report | 768 of 6698 (11.46 %) above the 2 % bound; "an unresolved saga is an observation failure, not an outcome" | `…/ladderG-…/exeris-community-r200-p256/correctness-gate.json` → `reason`, `status: detector_fault` | CITABLE |
| the empty-table guard | "An empty orders table is NOT a pass" | any `crash-recovery.json`, `verdict_guards` | CITABLE |
| the false-pass case (Q&A only) | domain-corroborated compensations 0 → 190 | commit `b0779716` and the gate before/after | CITABLE |

**Corrected 2026-08-25.** An earlier revision of the O0 row read "768 of 6644 (11.55 %)",
quoted a phrase — "an instrument failure, not a measurement" — that appears in no artifact,
and pointed at ladderC, which holds no `exeris-community-r200-p256` rung. The artifacted
gate lives in ladderG and its `reason` reads, in full: "O0: 768 of 6698 issued sagas
(11.46%) reached no terminal outcome the detector recognises, above the 2% bound. An
unresolved saga is an observation failure, not an outcome, so the compensation count cannot
be trusted in either direction. First thing to check: this stack's declared terminal_tokens
(CONTRACT-v2 §3.1) against what it actually emits." The correction is kept visible rather
than silently applied, for the same reason the RETRACTED state exists: a quotation nobody
re-checked is a number nobody has checked.

---

## Segment 7 (25:00) — The trade, with a price tag

The segment where the strongest number was un-artifacted until 2026-08-22, and where re-measuring it cost one of my own figures.

| figure | value | artifact | state |
|---|---|---|---|
| coordinator, in-window peak RSS | 341.4 MB | `…/20260821-shape-a-capacity/ladderG-…/quarkus-lra-jdbc-r70-p256/deployment-footprint.json` | CITABLE |
| coordinator CPU, in-window | 30.91 % avg, 102.3 % max, **39.66 core-s** | same | CITABLE |
| Postgres in the same run, for contrast | 32.80 core-s | same | CITABLE |
| coordinator resting anon, after a 70/s run | **319 MB**; a forced full GC moves it to 320 | `…/20260822T081030Z-shape-a-settle-completion/quarkus-lra-jdbc-r70-p256/post-load-settle.json` → `retention` | CITABLE |
| coordinator resting anon, after a 50/s run | **378 MB**; forced GC → 381 | `…/quarkus-lra-jdbc-r50-p256/post-load-settle.json` | CITABLE |
| Axon Server, post-load resident | 1 075.2 MB | `…/ladderI-…/spring-axon-jdbc-r60-p256/post-load-settle.json` | CITABLE |
| restate-server, post-load resident | 508.0 MB | `…/ladderI-…/restate-r200-p256/post-load-settle.json` | CITABLE |
| **the symmetric pair, both arms at 50/s** | exeris target JVM 347 → **322 MB** after forced GC; quarkus target 505 → **446 MB** plus a coordinator at 378 → 381 | `…/20260822T081030Z-shape-a-settle-completion/` | CITABLE |
| coordinator at ~1 GB, ~130 KB retained per saga | — | — | **RETRACTED** |

**Retracted, and by our own re-measurement.** An ad-hoc terminal reading on 2026-08-21 put
the coordinator at 1 055 MB anon roughly seventeen minutes after a 70/s rung. The artifacted
run at the same rate and nearly the same order count measures **319 MB** ninety-eight seconds
after load stops. The qualitative finding reproduces — a forced full GC releases nothing —
and the magnitude does not. The difference is the horizon, and whether the coordinator keeps
growing past the point where the settle gate declares it quiet is an open question this
window stops watching by design. Do not put 1 GB on a slide.

**Two limits of the instrument, to be stated if the figures are questioned.**

- The settle gate never converges for an idle JVM: both exeris rungs hit the 600 s cap with
  `settled=false`, because the target sat flat at 3.00–3.67 % and never cleared a 3.0 %
  threshold. That is JVM background activity at jiffy resolution, not saga work.
  `settled=false` there is a threshold artifact and says nothing about the arm.
- The probe reads the target as RSS from `/proc` and containers as `anon` from cgroup.
  Comparisons within one interface are clean; summing across them is not, and no figure
  above does.

**What the segment now leans on.** The coordinator burns more CPU in the measurement window
than the Postgres beside it, and at rest it holds 319–381 MB that a forced collection does
not reclaim — a component the in-process arm does not have at all. The in-process arm's own
resting cost is measured on the same day at the same rate, and it is smaller: 322 MB against
446 plus a coordinator.

**Disclose without being asked — corrected 2026-08-25.** This note previously read: "That
coordinator runs `-Xmx1536m` where every target JVM in the campaign runs `-Xmx192m`."
Neither value survives its own citation: no `Xmx` string exists anywhere in this repository
or in any artifact of these runs. What the artifacts do support: the targets run with **no
heap flags at all**, by documented design — the launcher's own comment block ("Intentionally
no -XX:MaxRAM / -XX:MaxRAMPercentage flags here"; the constraint model is a cgroup applied
after startup), and every rung's `env.json` records `jvm_flags: []` — while the shape-A
rungs additionally record cgroup `memory_limit: "unknown"`. The coordinator is an
off-the-shelf container the harness samples (`docker inspect` for identity, docker-stats
for cost) and never introspects, so its JVM configuration sits in no artifact. Both halves
of the old sentence are therefore **UNARTIFACTED** and withdrawn from citable material. The
disclosable asymmetry is one of *observability*: the targets' configuration is provable
from artifacts, the coordinator's is not — read the footprint comparison with that caveat.

---

## The fence re-run — measured, and not in this repository

`saga-campaign-fence-rerun-20260822T092623Z` on the perf box: `quarkus-lra-jdbc` ×3 with the
415 fix, and `exeris-community` ×3 beside it as a control, at the normative rate, shape B,
pool 32, heap 256m — the reference campaign's own configuration, read from its manifest.

**Its citable subset was never imported. The box went offline first.** The artifacts are
presumably intact on it; that cannot be confirmed until it returns, so this is pending
import rather than lost. Every figure below is therefore **UNARTIFACTED** — read from a
terminal and not checkable by anyone, including me.

| reading | value | state |
|---|---|---|
| all six reps | `runner=clean`, `gate=pass` | UNARTIFACTED |
| quarkus domain corroboration | **1399 compensated rows on each of three reps** (0 before the fix) | UNARTIFACTED |
| control, exeris | reps 2 and 3 reproduce 08-20 to the millisecond (124/128 ms); **rep 1 runs 13 % high** (140/146) and is unexplained | UNARTIFACTED |
| quarkus completed-path p50 | **376 → 232 ms** across the fence | UNARTIFACTED |

**Two consequences, and neither is comfortable.**

The fence is wider than the compensation column. The completed path does not compensate, and
it got 38 % faster when the compensation callback stopped returning 415. The leading
candidate is coordinator retry traffic from the failing callback taxing the whole arm — a
hypothesis, checkable in the coordinator logs, and not checked. Until it is, **no latency
figure for that arm from before the fence is usable either**, not just its compensation
count. Quoting 376 ms as the cost of the LRA architecture would be quoting the cost of our
own defect in someone else's arm.

And the control validation is itself unartifacted, so the conclusion it was run to support —
that the three untouched arms of the 08-20 campaign stand — is **provisional**. It is the
reading I would most like to rely on and the one I am least entitled to.

**What closes it:** import the citable subset when the box returns. If the run directory did
not survive, re-run it — the configuration is recorded in this bundle and in the reference
campaign's manifest.

## The gap at the normative rate

CONTRACT-v2 §2 pins **38 sessions/s** as the normative arrival rate. Nothing in this bundle
runs there except the W3a crash campaign, and that campaign has one arm behind the 415
fence. The shape-A ladders run 50–200/s by design — they are capacity exploration, not the
normative comparison.

There is therefore **no valid five-arm dataset at the contract's own normative rate**. The
nearest full campaign, `20260730T152447Z-all5-rate50`, predates both the re-rating to 38/s
(2026-08-19) and the fence (2026-08-21).

The talk does not need it: its claims are correctness, and the correctness artifacts are the
crash campaign, the contract sections and the source citations. The campaign does need it,
and it is the first thing to run when experiments resume.

## Forbidden

`results/reports/2026-07-30-e2e-shop-order-saga-v2-straight-through.md` is **RETIRED**
(2026-07-31). Its own note bars forward quotation of every number in it, *including the
numbers it presents as corrections*, in a later report, a talk, a slide, or a summary.

Checked: no figure in this bundle originates there. The talk's capacity and footprint
figures come from the 2026-08-21 ladders; the zero-compensation figures come from the May
article and from source at named commits; the contract figures come from CONTRACT-v2.

---

## Fences every figure sits after

| fence | marker | what it invalidates before it |
|---|---|---|
| LRA `@Consumes` 415 | `b0779716` | quarkus-lra never executed compensation |
| VU pool sizing | ladder F | shape-A throughput measured k6's VU budget |
| post-load settle window | ladder H | footprint understated deferred work |
| process-level stop verification | after ladder F | a stopped-but-alive target co-resided with later rungs |
| deterministic decline | CONTRACT-v2 §4.1, v2.0 | expected compensation was a rate, not a count |
| retention probe | ladder J, 2026-08-22 | resting-footprint readings taken by hand, with no artifact and no forced-GC control |
