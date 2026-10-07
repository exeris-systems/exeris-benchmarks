# Benchmark claims

The registered copy strings for quoting benchmark results from this repository, the figures that
are withdrawn, and the figures that may not be quoted without their context. Descriptions,
derivations and evidence live in the linked reports.

**Consumers copy, never paraphrase.**

## Registered claims

### L1

- **copy:** `65.3% less CPU per request than Spring Boot on Tomcat, same contract, same box (50.9 µs vs 146.7 µs, n=12 per arm)`
- **fence:** light contract, `spring-hibernate` ↔ `exeris-community` only, iso-heap 1280 MB, DB on bridge networking (a floor, not a point estimate); measured stacks, never "Spring cannot do better".
- **source:** [2026-08-11 Spring report](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md), campaign [`20260806T183034Z-spring-ladder-n3`](../results/raw/entity-read-by-id/20260806T183034Z-spring-ladder-n3/)

### L2

- **copy:** `DB saturation is a property of the stack that reaches the database, not of the workload: at the same offered load Postgres sits at 99.8% for the two fastest arms and 30–35% for the two slowest`
- **fence:** heavy contract, n=12; between the two fast arms quote cpu/req, never throughput; fast-vs-slow heavy throughput ratios are lower bounds.
- **source:** [2026-08-11 Spring report §3](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md)

### L3

- **copy (ceiling):** `With the Spring Data JPA + Hibernate repository layer in the request path, no runtime work can exceed ×1.34 on this contract — that layer is 75% of the cost (measured directly on Tomcat)`
- **copy (migration order):** `the repository layer is 74.7 % of a heavy request and 14.7 % of a light one — the same code, a 5.1× different share. Migration order is a property of the row count in the contract, not of the stack.`
- **fence:** exploratory; heavy contract on Tomcat (`spring-hibernate − spring-jdbc`); ×1.49 / 67 % only for the Exeris-hosted derivation, named as such.
- **source:** [2026-08-11 Spring report §4.1](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md)

### L4

- **copy:** whole-stack `×5.118 cpu/req` — `the same Spring application, the same SQL contracts, with the repository layer rewritten`
- **fence:** heavy contract, cpu/req, per-pair AB/BA measurements; the ladder closes on cpu/req at +2.0 %.
- **source:** [2026-08-11 Spring report §6](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md)

### L5

- **copy:** `Approaching capacity on the single-row read, spring-on-exeris-pure-native's tail degrades earlier and faster than the native baseline's: p99.9 is within 1.34x of exeris-community at 40k rps and 2.85x at 50k (91% of its saturation), while both arms are indistinguishable below 30k`
- **fence:** light contract, wrk2 open loop, n=2 per cell (AB+BA); percentiles as AB–BA ranges; mechanism open.
- **source:** [2026-08-11 Spring report §7.3](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md), campaign [`20260811T063920Z-l5-curve-tail`](../results/raw/entity-read-by-id/20260811T063920Z-l5-curve-tail/)

### L6

- **copy:** none registered.
- **fence:** the heavy ceiling is Postgres query execution, not container networking.
- **source:** [2026-08-11 Spring report §3](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md), campaign [`20260808T065528Z-purenative-vs-quarkustuned-n3`](../results/raw/entity-read-by-id/20260808T065528Z-purenative-vs-quarkustuned-n3/)

### L7

- **copy:** `With the ORM removed from both stacks, Exeris pure-native and hand-tuned Quarkus land within 0.7% on throughput; Exeris spends 3.7% more CPU per request on the light contract and holds 4% more RSS`
- **fence:** n=6 per arm per contract, host networking, iso-heap 1280 MB; heavy throughput is both arms behind one Postgres, light is the comparison; the Jackson 3 vs 2 confound runs against pure-native, never in its favour.
- **source:** campaign [`20260808T065528Z-purenative-vs-quarkustuned-n3`](../results/raw/entity-read-by-id/20260808T065528Z-purenative-vs-quarkustuned-n3/)

### L8

- **copy:** `~0.027 cores / ~0.67 % of a 4-core pin`
- **fence:** an idle, never-driven Spring-on-Exeris process; any ratio names its pair and campaign; the idle-RSS column is a rank, not a footprint.
- **source:** [2026-08-11 Spring report §6b](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md)

### L9

- **copy:** not quotable — open.
- **source:** [2026-08-11 Spring report §8](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md)

### L10

- **copy (headroom):** `the Spring Data repository layer does not make a request slower — it makes the arm run out of headroom sooner.`
- **fence:** ×3.95 is heavy-contract cpu/req for Spring Data JPA + Hibernate vs JdbcTemplate + RowMapper; the split between Hibernate and Spring Data projection proxies is open, so never "the cost of the ORM".
- **source:** [2026-08-11 Spring report §5, §7](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md), campaign [`20260810T131208Z-hibernate-vs-jdbc-n3`](../results/raw/entity-read-by-id/20260810T131208Z-hibernate-vs-jdbc-n3/)

### L11

- **copy:** `A permitAll Spring Security servlet filter chain costs 28.31 +/- 3.25 us of CPU per request on a single-row read - 24% of the request's own cost, and 23% of the Tomcat-to-Exeris hosting gain it was silently inflating`
- **fence:** light contract, one jar with the chain on and off, n=3 complete repeats; applying it to a heavy rung is an assumption; it includes 170 bytes of security response headers; one permitAll chain on Tomcat, not a general Spring Security figure.
- **source:** [2026-08-11 Spring report §6](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md), campaign [`20260811T114140Z-security-confound-n3`](../results/raw/entity-read-by-id/20260811T114140Z-security-confound-n3/)

### L12

- **copy (absolute):** `Exeris Community serves a single-row Postgres read for 51.3 µs of CPU per request (HTTP/1.1, JVM, dedicated bare metal, mean of 4 gated legs)`
- **copy (comparison):** `On a single-row read, Exeris Community uses 25.6% less CPU per request than hand-tuned pure-JDBC Quarkus (51.3 vs 68.9 µs) and 33.3% less than Quarkus + Hibernate (51.3 vs 76.9 µs); both Quarkus arms in JVM mode, head-to-head AB/BA pairs on the same box`
- **copy (tail):** `Exeris Community's open-loop p99.9 on a single-row read stays within 1.95–2.61 ms from 6,000 to 30,000 requests per second`
- **copy (footprint):** `Under an equal 2 GiB memory budget Exeris Community runs in ~1/2.7 the RSS of hand-tuned Quarkus; at a matched 256 MiB heap the gap is 1.18–1.26×`
- **fence:** `perf-box-amd64`, HTTP/1.1 cleartext, host-networked Postgres, light contract only; Quarkus in JVM mode, not native; CPU/req is the comparison, not throughput; the tail is a range; n=1 per leg.
- **source:** [2026-07-21 triad report §2, §5, §7, §8](../results/reports/2026-07-21-entity-read-by-id-tuned-pg-triad-comparison-eligible.md)

### L13

- **copy (floor):** `Exeris Community serves a Postgres-backed single-row read inside a 128 MiB memory limit: 3 of 3 runs clean, 0 errors, peak cgroup memory 113.5–121.5 MiB`
- **copy (CPU/req):** `Exeris Community's CPU per single-row read does not move with its memory budget: ~54.5 µs per request (54.4–55.4 µs) from 128 MiB to 2 GiB, a 16× range`
- **copy (TLS tax):** `Enabling TLS raises Exeris Community's CPU per request by 12.7% (54.0 → 60.9 µs) and Quarkus's on netty-tcnative/BoringSSL by 5.8% (69.1 → 73.1 µs): Exeris pays the larger TLS tax, from the lower base`
- **fence:** `perf-box-amd64`, cgroup memory budgets, 4 vCPU, closed-loop wrk; per-arm facts, every cross-arm delta directional; the floor needs the lean configuration (16 MiB heap, admission ratio 32) and is quoted as the cgroup figure; Exeris's absolute TLS figures travel with the TLS-tax row.
- **source:** [2026-07-22 memory/CPU sweep report](../results/reports/2026-07-22-entity-read-by-id-memory-cpu-sweep.md)

### L14

- **copy (absolute):** `Exeris Community in JVM mode, crypto subsystem off, answers its first request 0.86 s after process spawn: ready in 0.80 s, first business response 63 ms later, 173 MB peak RSS (median of 8 cold launches, developer laptop, JDK 26)`
- **copy (comparison, evidence page only):** `From process spawn to first served request, median of 8 cold launches per arm, all in JVM mode over cleartext HTTP/1.1 on one developer laptop: Exeris Community 0.86 s, Quarkus (hand-tuned JDBC) 1.18 s, Quarkus + Hibernate 2.00 s, Spring on Exeris (compatibility mode) 4.31 s, Spring Boot + Hibernate 4.88 s. Quarkus native image was not measured.`
- **fence:** exploratory, one developer laptop, n=8, no gate; Quarkus in JVM mode, not native; Spring on Exeris is compatibility mode; the Exeris row is crypto-off; the comparison belongs on an evidence page, never in a headline.
- **source:** scenario [`cold-start-ttfr`](../scenarios/cold-start-ttfr/scenario.json), results [`results/cold-start-ttfr/`](../results/cold-start-ttfr/)

## Withdrawn

R = [2026-08-11 Spring report](../results/reports/2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md).

1. "Hibernate is 67 % of the cost" — replaced by [L3](#l3) (the Spring Data JPA + Hibernate repository layer); R §5.
2. The ×1.127 hosting rung — replaced by ≈ 89–96 µs, ×1.09–1.10; [L11](#l11), R §6.
3. The ×1.488 / 67.2 % ceiling quoted for Tomcat — replaced by ×1.338 / 74.7 %; [L3](#l3), R §4.1.
4. The ±2.80 % cpu/req error budget — replaced by ±2.52 % heavy / ±3.71 % light; R §2.2.
5. A bare "18×" idle-CPU ratio — replaced by [L8](#l8); R §6b.
6. L8's idle-RSS column read as a footprint — it is a rank; R §6b.
7. "The two arms' responses were byte-identical" — bodies only; R §6.
8. Light-contract DB busy 87–89 % as Postgres utilisation — replaced by ~37 % on host networking; R Setup.
9. "Light does 4.3× more round-trips" — the ratio is 1.43×, mechanism open; [L2](#l2).
10. The prediction that overlapping rungs make the light gap exceed the heavy gap — [L4](#l4).
11. L4's closure as "inside the arm-order control" — inside the ±2.52 % combined envelope; R §6.
12. L5's "worst p99 of all four arms", "p99/p50 = 6.26× vs 5.05×", "12.49 ms" — replaced by [L5](#l5); R §7.3.
13. "Idle cores are state-invariant to three decimal places" — to within ~3 %; R §6b.
14. The agent-laden RSS profiles (284/346/430 MiB light) — replaced by agent-free 233/276/352 MiB; [2026-07-21 triad report §5](../results/reports/2026-07-21-entity-read-by-id-tuned-pg-triad-comparison-eligible.md).
15. "×3.95 cpu/req on the DB-bound aggregate" — "on the ~200-row aggregate"; R TL;DR.
16. "On a DB-bound workload the repositories go first" — replaced by the [L3](#l3) migration-order string; R §5.
17. The two-rung ladder table against a ×5.118 row — all three rungs shown; R §6.
18. The ×5.109 vs ×5.118 "closure" — the pooled rungs are an accounting identity; the closure check is [L4](#l4); R §6.
19. "The artefacts stamp `publishable=false`" — 42 of 48 units do; R §7.
20. "The two ORM-free stacks sit within 5–15 %" and "a 3–17 % band" — 17.2 % as deployed, 3–5 % security-normalised; R §4.2.
21. The light contract as "~125 B" — the body is 30 B; R Setup.
22. `reproducibility_status: complete` as third-party review — it is a second derivation from the artefacts; R frontmatter.
23. The 2026-05-05 `e2e-shop-order-saga` v1 run: the correctness asymmetry, the `saga_unresolved` columns and the 3.4× / 4.7× density multipliers — no replacement figure; [CONTRACT-v2 §10](../scenarios/e2e-shop-order-saga/CONTRACT-v2.md), [tJUG evidence bundle](../results/reports/2026-08-22-tjug-talk-evidence.md).

## Never quote alone

- No p99 as a single point; quote the AB–BA range.
- No closed-loop percentile from a fixed-contract campaign.
- No heavy-contract throughput ratio between a fast and a slow arm; use CPU/req.
- No ×3.95 without its contract and the words "Spring Data JPA + Hibernate repository layer".
- Never "×3.95 slower"; the ratio is cost per request, not latency.
- No ×1.127 at all; quote ×1.09–1.10 only when the hosting axis is the subject.
- No ×1.49 / 67 % for a Tomcat deployment; that is the Exeris-hosted derivation.
- Never ×5.110 and ×5.118 as agreement; they are different derivations.
- No bare "18×" idle-CPU ratio; quote ~0.027 cores, or a ratio with its pair and campaign.
- Footprint ratios travel with the matched-heap qualifier.
- No bridge-mode DB-busy figure as Postgres utilisation, and none beside a host-mode one.
- An Exeris-favourable number from a bridge-networked campaign is a floor.
- Never "when the DB is the bottleneck the stack stops mattering"; the differences remain in cpu/req, RSS and CPU headroom.
- Name the comparator: quarkus-tuned is hand-tuned pure JDBC, not stock Quarkus.
- Nothing measured in JVM mode is a comparison with Quarkus native image.
- Never collapse a compat row into a pure one.
- Do not set L13's ~54.5 µs beside L12's 51.3 µs as a trend.
- Nothing from the 2026-05-05 `e2e-shop-order-saga` run; no number from it next to "Axon"; contract-v2 rows marked CITABLE in the [tJUG evidence bundle](../results/reports/2026-08-22-tjug-talk-evidence.md) are quotable under its fences.
- A contract-v2 saga comparison names its frameworks and arms and stays on an evidence page.
- Nothing from the [2026-07-30 straight-through report](../results/reports/2026-07-30-e2e-shop-order-saga-v2-straight-through.md).
