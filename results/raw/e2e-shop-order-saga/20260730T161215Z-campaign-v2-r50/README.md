# e2e-shop-order-saga — v2 comparison-set campaign, 50 sessions/s

First campaign under the corrected v2 contracts. Three
stacks × 3 repeats, full contract windows (120 s warmup / 180 s measurement /
30 s cooldown), perf-box-amd64.

Contracts: `exeris_community_h1_v2`, `quarkus_axon_neo4j_h1_v2`,
`spring_boot_axon_neo4j_h1_v2`.
Workload profile key: `e2e-shop-order-saga-community-h1-loopback-runtime-k6-inline-r50-v2`.

## Results — 9/9 reps PASS

| target | saga median | p99 | req/s | cores | peak RSS | §4.1 gate |
|---|---|---|---|---|---|---|
| exeris-community | 23 / 23 / 23 ms | 39–41 | 241.4 | 0.34 | 454–475 MB | 497/497 ×3 |
| quarkus-hibernate | 31 / 31 / 31 ms | 52–55 | 242 | 0.24 | 872–913 MB | 497/497 ×3 |
| spring-hibernate | 34 / 34 / 34 ms | 86–91 | 242 | 0.57 | 1403–1562 MB | 497/497 ×3 |

Medians identical across repeats; every rep issued ~16 370 orders and matched
the exact expected compensation count of 497.

Whole-deployment CPU per saga (target JVM + Postgres + Neo4j + Axon Server):
**quarkus 10.5 ms, exeris 20.6 ms, spring 20.9 ms.**

> **Superseded figures.** This file previously reported 6.85 / 11.7 / 14.8 ms.
> Those were wrong: the footprint rollup derived each container's CPU-seconds
> from the stats-CSV *row count*, assuming the sampler ticked at 1 Hz because its
> loop says `sleep 1`. `docker stats --no-stream` takes ~2 s itself, so the real
> interval is ~3 s — measured, 113 rows spanning 335.7 s = 2.97 s per sample.
> Every container's CPU was understated ~3×. Fixed to use the recorded epoch
> timestamps. The correction changes the ordering: spring is not the most
> expensive, it is level with exeris.

## NOT A VALID CROSS-STACK COMPARISON — read before citing anything

**These numbers are descriptive per stack only.** The three stacks do not execute
the same work in this shape (CONTRACT-v2 §2.1 shape A0): quarkus-hibernate runs
the whole saga synchronously on the request thread, spring-hibernate runs it
asynchronously through Axon Server, exeris-community through the flow scheduler.
All three return the terminal outcome inline, so they share an observable
contract — but that is not equivalent execution, and the table above must NOT be
read as "exeris is faster than quarkus".

This was briefly mislabelled comparison-eligible while these runs were taken. The
label was lifted on the grounds that the resolution model had been made uniform;
resolution uniformity does not imply execution equivalence. Reverted.

Superseded by shape A (minimal park), in which every stack must implement
dispatch -> park -> external event -> wake and therefore does the same shape of
work.

## Further caveats

**1. This workload is not really a saga.** Every step returns
`CONTINUE`/`COMPLETE`/`FAIL`; nothing awaits an external system, so nothing
parks. Structurally it is a transaction script with compensation — which is
exactly what `quarkus-hibernate` implements, and why its approach is competitive
here. The numbers are a valid measurement of the request path; they do NOT
support a claim about saga orchestration. See
`../../../scenarios/e2e-shop-order-saga/PROPOSAL-parking-payment-step.md`.

**2. `campaign-gate-summary.json` says `not_evaluated`, and that is correct
output, not a stale file.** It was written when the campaign ended 8 pass +
1 absent. `spring-hibernate-rep-3` failed its DB seed and was re-run standalone
afterwards; its artifacts here are from that clean re-run. The runner's original
verdict is preserved deliberately rather than overwritten — see
`campaign-completion-note.json` for the full sequence.

**3. The rep-3 failure was a security incident, not flakiness.** The seed failed
because the box's internet-exposed Postgres had been accessed and the `postgres`
role password altered. Remediated in commit `56e3e95` (ports bound to
127.0.0.1, rogue superuser roles `wog` and `postgres `-with-trailing-space
dropped, connection logging enabled). Results taken while a third party held
superuser access are not above suspicion; the internal consistency above
(identical medians, exact gate matches, populations within 6 sessions) argues
the workload data was intact.

**4. CPU is not a clean win for any stack.** quarkus uses the least target-JVM
CPU (0.24 cores) and the least whole-deployment CPU per saga, despite carrying
Axon Server. A large part of exeris's higher figure is the Neo4j N+1 traversal
forced by the graph SPI (2.6× the Neo4j CPU, ~2.4 ms of the gap) — API
expressiveness, not runtime efficiency.

**5. Not through the comparative strict gate.** No `stage7-*` artifacts here;
this is per-run v2 evidence, not a gated comparative claim. Per-step scope also
applies: `recommend_latency_ms` is platform-natural only.

## Excluded from the repo

`k6-output.json` (~296 MB per rep), `*.jfr`, `resource-samples.csv` and
`k6-timeseries.csv` stay on the perf box. Everything needed to reproduce the
tables above — summaries, gates, resource metrics, deployment footprints,
Postgres connection counts, docker stats — is here.
