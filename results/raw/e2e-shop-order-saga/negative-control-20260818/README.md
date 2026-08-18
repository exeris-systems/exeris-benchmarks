# Negative control for the O0 detector — 2026-08-18

CONTRACT-v2 §7 requires the `detector_fault` mechanism to be **demonstrated, not
asserted**: a check that has never been observed to fire is not evidence that it
would. This is that demonstration, plus the positive control it has to be read
against.

perf-box-amd64, `exeris-community`, shape-A parking workload (gateway delay 1 ms),
short windows (5 s warmup / 15 s measurement / 5 s cooldown). Correctness only —
**no performance figure from these runs may be cited.**

## Results

| run | mode | expected | observed | exit |
|---|---|---|---|---|
| positive | true declaration | gate PASS, observed == expected | **PASS**, 13 == 13 over 566 issued | 0 |
| negative A | `preflight` — declaration falsified everywhere | §3.1 preflight rejects before the window | **rejected**: expected `__NEGATIVE_CONTROL_WRONG_TOKEN__`, observed `COMPENSATED` | 80 |
| negative B | `detector` — only k6's copy falsified | `detector_fault`, never a compensation figure | **detector_fault**: 13 of 566 (2.29 %) unresolved | 5 |

Negative B is the one that matters. The preflight **passed** — the stack really does
emit `COMPENSATED` — and the detector alone was blind, which is the v1 shape exactly.
Its compensation count was **0 against an expected 13**, and the harness refused to
report that as a result.

## What the control found on its first execution

The §3.1 preflight was written to catch declaration drift. On its very first run it
instead caught a **real defect in the parking implementation**, which no amount of
review had found:

`RuntimeFlowInstance.beginScheduleAfterWake()` returns `currentStep + 1` — a woken
flow resumes at the step **after** the one that parked. It does not re-enter it. The
original single-step design read the settled payment outcome at the top of the
parking step and assumed re-entry, so on wake that read was skipped entirely: a
**DECLINED payment continued to confirm-order and the saga completed successfully.**

Evidence at the time: the gateway reported `declined: 2, authorized: 0`, the callback
was delivered (`callbacks_ok: 1`), and the order row was `COMPLETED` with both
`PAYMENT_REQUESTED` and `ORDER_CONFIRMED` in the outbox.

Fixed by splitting the pivot into `request-payment` (writes + dispatch, CONTINUE — so
its compensation is pushed) → `await-payment` (PARK) → `settle-payment` (reads the
persisted outcome, CONTINUE or FAIL). `applyParkOutcome` does not push a
compensation, which is why the dispatch step must CONTINUE rather than PARK, or
`refund-payment` would silently drop out of the LIFO chain.

Both Exeris arms were affected, since `spring-on-exeris` runs the same engine.

## Limitation of the unresolved bound, measured rather than assumed

A fully blind detector produces `unresolved ≈ the decline rate`. At the contract's
3 % rate this run landed at **2.29 %** — over the 2 % bound, but only just. At a 1 %
decline rate the same total blindness would slip **under** it.

So the unresolved bound is not sufficient on its own. A second `detector_fault`
condition was added after seeing this: **zero compensations observed where the oracle
expects a non-zero count**. That is the v1 signature directly, and it is reported as
`detector_fault` rather than gate FAIL on purpose — the run cannot distinguish "did
not compensate" from "could not see it", and saying so is honest where either verdict
would be a guess.

## Reproducing

```bash
BENCH_NEGATIVE_CONTROL=detector BENCH_PAYMENT_PARKING=1 PAYMENT_STUB_DELAY_MS=1 \
  ./scripts/run-e2e-shop-order-saga-baseline.sh \
  --target-app exeris-community --contract-id exeris_community_h1_v2 \
  --output-dir /tmp/ctl-neg-det
```

`BENCH_NEGATIVE_CONTROL=preflight` for negative A; omit it for the positive control.
