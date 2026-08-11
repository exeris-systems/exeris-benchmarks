# CLAIMS.md — benchmark claim registry

Claims derived from campaigns in this repo, with the fences each one carries.
**Consumers copy, never paraphrase.** This is not the portfolio copy registry
(`arkstack-dev/portfolio:CLAIMS.md`), which holds public EN/PL marketing strings and
has no schema for open items, retractions or track labels. A claim marked
`track: internal` here **must not** be promoted there.

Classification follows the lab vocabulary: `comparison-eligible` / `exploratory` /
`descriptive-only` / `fact`. Every entry states tier, contract, n, and the fences.

**Standing fence — bridge networking.** Every campaign up to and including
`20260806T183034Z-spring-ladder-n3` ran with the DB on Docker **bridge** networking
(`backend_network_mode: bridge` in all 48 leaves). The June measurement of that tax on
this same box is `+20.5 %` rps host-net vs bridge, at **unchanged application cpu/req**
(0.357 → 0.358 ms), with target-thread `%wait` falling 265 % → 57 %
([June report §2](../results/reports/2026-06-20-entity-read-by-id-steady-state-and-cost-per-request.md)).
The tax is charged per DB round-trip, so the faster arm — which issues 2.8× (light) to
3.6× (heavy) more round-trips per second — pays proportionally more of it. **Every
Exeris-favourable number below is therefore a floor, not a point estimate.**

**Correction 2026-08-11 — `spring-on-exeris*` was never confidential, and eight entries below
were mislabelled `Track: internal` because of it.** The stamp traced to a CLAUDE.md scoping line
naming `targets/exeris-spring-runtime-benchmark-app-comp/`, a path that has never existed in this
repo (the target is `targets/exeris-spring-runtime-app-comp/`); it entered in an unrelated PR with
no rationale recorded in `docs/` or `.github/`. Exeris Spring Runtime is a product repo, listed in
CLAUDE.md separately from "enterprise repos", and every `spring-on-exeris*` arm is `tier=community`
in the pair manifest. What was really being enforced is the Pure-vs-Compat **labelling** axis, which
still binds in full: never collapse a compat row into a pure one, and route compat overhead to the
`compat/` track. Labelling is not secrecy. **Consumers who copied these entries while they read
`internal` may republish them as `public-eligible`** — the numbers did not change, only the void
restriction on them.

---

## L1 — cpu/req reduction, exeris-community vs Tomcat (light)

- **EN:** `65.3% less CPU per request than Spring Boot on Tomcat, same contract, same box (50.9 µs vs 146.7 µs, n=12 per arm)`
- **PL:** `65,3% mniej CPU na żądanie niż Spring Boot na Tomcacie, ten sam kontrakt, ta sama maszyna (50,9 µs vs 146,7 µs, n=12 na ramię)`
- Class: comparison-eligible · Tier: Community · Track: **public-eligible**
- Contract: `fixed_contract_cross_runtime_h1_single_read_v1` · Campaign: `20260806T183034Z-spring-ladder-n3`
- Note: pair 4 (`spring-hibernate` ↔ `exeris-community`) only — neither arm is a
  `spring-on-exeris*` arm. That distinction was previously given as the reason this claim is
  publishable, on the belief those arms were internal; they never were (see the correction note
  at the top), so it carries no weight. L1 is publishable because it is a gated Community
  measurement, like everything else in this registry.
  Iso-heap 1280 MB, version-aligned (Boot 4.1.0, Jackson 3, kernel 0.10.2), DB pinned
  4-7,12-15. Heavy equivalent is −80.4 %, but see **L2**: on heavy the throughput side of
  this pair reads the DB ceiling, so quote cpu/req there or nothing. Bridge fence applies —
  this is a floor.
- Supersedes the June n=3 dev-laptop measurement (h2+TLS, Boot 3.5). Three measurements,
  two environments, two Spring generations, same direction.
- **Scope note (L10):** this is a whole-stack claim and stays valid as one — the Spring arm is
  idiomatic Spring Data JPA, which is what a Spring team ships. But part of its cost is
  Spring-side-addressable (projection proxies, L10), so it is *not* a claim that the remaining
  gap is irreducible for Spring. State it as measured stacks, never as "Spring cannot do better".

## L2 — the heavy contract is DB-bound *for the fast arms only*

- **EN:** `DB saturation is a property of the stack that reaches the database, not of the workload: at the same offered load Postgres sits at 99.8% for the two fastest arms and 30–35% for the two slowest`
- Class: fact (measured) · Tier: Community · Track: **public-eligible** (was: internal, on the void `spring-on-exeris*` exclusion)
- Mean DB-cpuset utilisation over each arm's own measurement window, n=12, `%steal` 0.00:

  | arm | rps | own pin | idle | DB busy | actually limited by |
  |---|---:|---:|---:|---:|---|
  | spring-hibernate | 3 664 | 98.7 % | 1.3 % | 30.5 % | own CPU |
  | spring-on-exeris-pure | 4 131 | 98.7 % | 1.3 % | 34.9 % | own CPU |
  | spring-on-exeris-pure-native | 12 645 | 73.3 % | 26.7 % | 99.8 % | the database |
  | exeris-community | 13 107 | 69.1 % | 30.9 % | 99.8 % | the database |

- Consequences, as bounds:
  - Throughput ratios **between the two fast arms** on heavy measure Postgres. Use cpu/req.
  - Fast-vs-slow heavy ratios are **lower bounds** (one side capped, other side with 2/3 of
    the DB idle).
  - A faster database (replica, better plan, more DB cores) is worth up to **+36 %** to
    pure-native and **+45 %** to community, and **≤ 1.3 %** to Tomcat, compat and pure —
    they are already at 98.7 % of their own pin. That bound is the claim; "nothing" is not.
- Do **not** write "when the DB is the bottleneck the stack stops mattering". Correct form:
  *the differences stop being visible in throughput; they remain in cpu/req, RSS and CPU
  headroom, and return as throughput the moment the database stops being the limit.*

### CORRECTION 2026-08-08 — the light-contract DB reading above was a bridge artifact

The table's LIGHT figures (87–89 % DB busy, "near saturation … roughly an eighth in reserve")
were measured on a **bridged** DB and are **not Postgres utilisation**. Run B re-measured the
same arm, same contract, same cpuset, same pins, at the same throughput, on **host**
networking. The component split shows where the difference lived:

| pure-native, light | DB busy | `%usr` | `%sys+%soft` | rps |
|---|---:|---:|---:|---:|
| ladder, **bridge**, n=12 | 87.36 % | 32.22 | **55.14** | 55 363 |
| run B, **host**, n=6 | **37.34 %** | 17.62 | **19.69** | 55 736 |

Same delivered throughput, ~50 points less DB-cpuset busy. Under bridge, **55 of the 87 points
were `sys`+`soft`** — kernel networking, not query execution — and part of the `%usr` was
`docker-proxy`, a userspace relay, rather than Postgres.

Corrected reading: on the light contract Postgres runs at **~37 %** and the arms have roughly
**two thirds of the DB in reserve**. Light is purely own-CPU-bound; the "DB close behind"
qualifier is withdrawn.

**HEAVY is unaffected and is in fact strengthened**: 99.80 % → 99.84 %, `%usr` 87.33 → 87.25,
`%sys+%soft` 12.47 → 12.60 — unchanged to within noise. Heavy's wall is genuine query
execution, which is exactly what **L6** predicted and what removing the NAT hop confirms.

**Why the contracts differ is NOT yet explained — the first explanation offered here was wrong.**
It claimed light does "4.3× more network round-trips per second". That used the *request* ratio
and forgot that heavy issues **three queries per request**. The actual DB round-trip rates are
55 736/s (light) and 12 958 × 3 = 38 874/s (heavy) — a ratio of **1.43×**, not 4.3×. A 1.43×
difference in round-trips cannot produce a 50-point difference in effect.

The per-round-trip figures make that plain:

| pure-native | DB-side `sys+soft` per request | per DB round-trip |
|---|---:|---:|
| light, bridge | 79.7 µs | **79.7 µs** |
| light, host | 28.3 µs | **28.3 µs** |
| heavy, bridge | 78.9 µs | **26.3 µs** |
| heavy, host | 77.8 µs | **25.9 µs** |

On host both contracts converge to ~26–28 µs of DB-side kernel time per round-trip. On bridge,
heavy was *already* at 26.3 — the NAT hop cost it nothing measurable — while light paid 79.7.
So the bridge tax was not levied per round-trip at a uniform rate; it landed on one contract and
not the other. Placement is the likely lever (softirq and the unpinned `docker-proxy` are
scheduled, not pinned, so which cpuset absorbs them is not fixed), but this data cannot
establish it. **Recorded as an observation with the mechanism open**, rather than given a
plausible story.

**Consequence for every bridged campaign in this repo:** a bridge-mode DB-busy figure is
Postgres *plus* container networking and overstates database load — materially so on
high-rps/low-work contracts. The slow arms' bridged heavy figures (30.5 %, 34.9 %) are
inflated too, though not enough to change their reading: they had ample headroom either way.

## L3 — Amdahl ceiling on runtime work while the ORM stays

- **EN:** `With Hibernate in the request path, no runtime work can exceed ×1.49 on this contract — Hibernate is 67% of the cost`
- Class: exploratory · Tier: Community · Track: **public-eligible** (was: internal, on the void `spring-on-exeris*` exclusion). Publish as *exploratory* — the gate here is the evidence class and the L10 attribution caveat, not confidentiality.
- Derivation, heavy contract, cpu/req arm-means (n=12):
  - ORM component = `pure − pure-native` = 955.88 − 231.91 = **723.97 µs** = **67.20 %** of Tomcat's 1077.40 µs
  - runtime-addressable remainder = **353.43 µs** (32.80 %)
  - ceiling if runtime cost went to zero = 1077.40 / 723.97 = **×1.488**
  - measured hosting step (Tomcat → pure) = 121.52 µs = ×1.127, i.e. **34.4 %** of the
    addressable pool already captured
- **Load-bearing assumption, stated not hidden:** the ORM component is measured on the
  Exeris-hosted arm and applied to Tomcat. There is no `tomcat-native` arm, so
  host-independence of the Hibernate cost is assumed. It is supported, not proven, by **L4**:
  the axes compose to +2.0 % on the ceiling-free metric, which is what host-independent
  layer costs would produce.
- **ATTRIBUTION CAVEAT 2026-08-11 — see L10 before calling this pool "Hibernate".** The ORM
  component is a subtraction between an arm that uses Spring Data JPA repositories with **interface
  projections** and one that uses none, so it contains the Spring Data projection-proxy cost as
  well as Hibernate's. JFR on the new `spring-hibernate__spring-jdbc` pair puts Spring AOP /
  reflection frames *above* Hibernate's own tuple materialisation. The 723.97 µs pool, the ×1.488
  ceiling and the migration-order conclusion are unaffected — that cost is real and it does leave
  with the repositories — but "Hibernate is 67 % of the cost" overstates what the arms separate.
  Prefer: *"the Spring Data JPA + Hibernate repository layer is 67 % of the cost"*.
- Migration-order consequence: on a DB-bound workload the repositories go first. Until the
  ORM leaves the path, runtime work is optimising 33 % of the request.

## L4 — the ladder decomposition closes, and cpu/req is the metric to close it on

- Class: fact (measured) · Tier: Community · Track: **public-eligible** (was: internal, on the void `spring-on-exeris*` exclusion)
- Product of the three rungs vs the directly-measured end-to-end pair:

  | | product | direct | drift |
  |---|---:|---:|---:|
  | heavy cpu/req | 5.222 | 5.118 | **+2.0 %** |
  | heavy rps | 3.717 | 3.581 | +3.8 % |
  | light cpu/req | 3.016 | 2.890 | +4.4 % |
  | light rps | 2.891 | 2.773 | +4.3 % |

- The ceiling-free metric closes at +2.0 %, inside the counterbalanced arm-order control
  (≤ ~2 %). The decomposition is therefore sound as an **attribution instrument**, not merely
  a heuristic. Drift is systematically larger on rps than on cpu/req (3.8 vs 2.0 on heavy) —
  the same ceiling seen a third way. **Check ladder closure on cpu/req.**
- **RETRACTED** (never published): the prediction that overlapping rungs would make the light
  gap exceed the heavy gap. Light drift (+4.3 %) exceeds heavy (+2.0 %), but on the
  ceiling-free metric the axes compose; the residual is drift, not interaction.

## L5 — RESOLVED 2026-08-11: pure-native's light tail is a capacity-approach behaviour

- **EN:** `Approaching capacity on the single-row read, spring-on-exeris-pure-native's tail degrades earlier and faster than the native baseline's: p99.9 is within 1.34x of exeris-community at 40k rps and 2.85x at 50k (91% of its saturation), while both arms are indistinguishable below 30k`
- Class: **comparison-eligible** (was: descriptive-only, unresolved) · Tier: Community ·
  Track: **public-eligible**
- Contract: `fixed_contract_p99_stable_h1_wrk2_single_read_v1` (wrk2 open loop, CO-free) ·
  Campaign: `20260811T063920Z-l5-curve-tail`, 12/12 leaves `comparison_eligible`, n=2 per cell
  (ab+ba), every rung `publishable=true` with `rate_attainment_pct` >= 99.55 %
- Measured, p50 as mean, tails as ab-ba range (ms):

  | offered rps | community p99 | pure-native p99 | community p99.9 | pure-native p99.9 | p99.9 ratio |
  |---:|---:|---:|---:|---:|---:|
  | 10 000 | 1.86-1.88 | 1.97 | 2.04 | 2.27 | 1.11x |
  | 20 000 | 1.73-1.91 | 2.00-2.01 | 2.10-2.22 | 2.37-2.39 | 1.10x |
  | 30 000 | 2.17-2.18 | 2.57-2.73 | 2.55-2.57 | 3.21-3.25 | 1.26x |
  | 40 000 | 2.71-2.73 | 3.24-3.26 | 3.12-3.14 | 4.19-4.22 | 1.34x |
  | 45 000 | 2.69-2.83 | 3.96-4.02 | 3.20-3.33 | 6.85-7.38 | **2.18x** |
  | 50 000 | 3.12-3.14 | 4.51-5.00 | 3.74-3.76 | 9.81-11.56 | **2.85x** |

### What the open-loop measurement RETRACTS from the original L5

The original entry rested entirely on closed-loop wrk at saturation, whose percentiles are queue
occupancy. Three of its statements do not survive a CO-free measurement:

- **"The worst p99 of all four arms, worse than Tomcat."** At matched sub-saturation load
  pure-native tracks the native baseline within 5-22 % up to 40 000 rps.
- **"p99/p50 = 6.26x versus community's 5.05x."** Open loop at the top rung gives **3.2x** for
  pure-native and **2.4x** for community. The shape difference is far smaller than closed loop
  implied.
- **The magnitude.** 12.49 ms becomes **4.51-5.00 ms** at the highest sustainable rate: the
  closed-loop figure was inflated roughly 2.5x by queueing.

Run B's escalation ("2.81x the comparator's tail" against quarkus-tuned) is **not retracted and
not confirmed** — that pair was dropped from the open-loop campaign as a Quarkus reference inside
a Spring-series report, so no CO-free reproduction of it exists. Treat the 2.81x as a closed-loop
number with the same inflation caveat until someone runs it.

### What survives, and why both original hypotheses were wrong

The excess is **real but load-dependent**: absent below ~30 000 rps, widening in p99, and turning
sharp in the far tail above ~80 % of capacity.

- *"Queueing artefact"* is wrong: the effect reproduces open-loop at a sustained fixed rate.
- *"Service-time property"* is wrong: a per-request property would be present at moderate load,
  and it is not.

It is a **capacity-approach behaviour**, and only a rate ladder can see it — a saturating driver
reports the endpoint and a single sub-saturation point reports nothing. That is the methodological
finding, and it generalises beyond this arm.

### What is still open

The **mechanism**. L5's original localisation stands unchallenged: the excess appears where Spring
and kernel-native persistence are both in the path, and neither alone shows it. What is now
unexplained is why the divergence starts around 30 000 rps on this contract and this box. Nothing
in the current artefacts distinguishes the candidates.

**Fence for anyone quoting this entry:** percentiles here are **ab-ba ranges, not points**. Tail
metrics in this campaign proved far more order-sensitive than throughput (the sibling ORM phase
read p99 5.25 against 15.07 ms in one cell at the same offered rate), and the +/-2.00 % arm-order
term in the cpu/req error budget is measured on cpu/req and **does not transfer to tails**.

## L6 — PRE-REGISTERED PREDICTION: what host networking does to the heavy ceiling

Recorded **2026-08-08, before run B landed**, so the distinction between prediction and
post-hoc explanation survives.

At DB busy 99.8 % the component split is `%usr` ≈ 87, i.e. **~13 pp of the DB cpuset is
sys+soft rather than query execution**. Host networking should remove part of that.

- If pure-native's heavy ceiling stays ≈ 12.6 k → the wall is genuinely query execution in
  Postgres, and **L2** and **L3** stand unchanged.
- If it rises by ≈ 10 % or more → part of what three reports have called "the Postgres
  ceiling" was container networking, and the heavy reading must be rewritten.

Run B (`20260808T065528Z-purenative-vs-quarkustuned-n3`, host-net, same pins, same PG
settings) measures pure-native heavy directly and settles this.

### RESOLVED 2026-08-08 — the ceiling is query execution. L2 and L3 stand.

| pure-native, heavy | rps |
|---|---:|
| ladder, bridge, n=12 | 12 645 |
| run B, host, n=6 | **12 958** |
| change | **+2.5 %** |

Against a **+10 %** rewrite threshold. Part of even that 2.5 % is the comparator changing from
community to quarkus-tuned, which the ladder measured as a 2.3–3.9 % neighbour effect.

The component split is the stronger evidence: `%usr` on the DB cpuset was **87.33 % bridged and
87.25 % host** — removing the NAT hop did not move the wall by a tenth of a point, because the
wall is Postgres executing queries. `%steal` 0.00 throughout. pure-native still leaves 21.9 % of
its own pin idle at that ceiling, so the DB-bound regime survived the network change intact.

The prediction's *other* branch turned out to matter for a contract it did not name: on
**light**, removing the NAT hop moved DB busy by 50 points — see the correction under **L2**.
The prediction was right about heavy and silent about light, where the effect was large.

## L7 — pure-native vs quarkus-tuned, ORM removed on both sides

- **EN:** `With the ORM removed from both stacks, Exeris pure-native and hand-tuned Quarkus land within 0.7% on throughput; Exeris spends 3.7% more CPU per request on the light contract and holds 4% more RSS`
- Class: comparison-eligible · Tier: Community · Track: **public-eligible** (was: internal, on the void `spring-on-exeris*` exclusion)
- Campaign: `20260808T065528Z-purenative-vs-quarkustuned-n3`, n=6 per arm per contract, host-net, iso-heap 1280 MB, DB pinned 4-7,12-15, 12/12 comparison_eligible.

| | rps | cpu/req | % pin | RSS | off-heap | p50 | p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| **heavy** pure-native | 12 958 | 241.02 µs | 78.1 % | 1108 MB | 189 MB | 9.83 | 14.34 |
| **heavy** quarkus-tuned | 12 862 | 239.45 µs | 77.0 % | 1062 MB | 186 MB | 9.89 | 15.78 |
| **light** pure-native | 55 736 | 71.58 µs | 99.7 % | 1091 MB | 186 MB | 1.88 | 16.59 |
| **light** quarkus-tuned | 55 490 | 69.02 µs | 95.7 % | 1048 MB | 185 MB | 2.09 | 5.91 |

- **Heavy is not a stack comparison.** Both arms sat at 99.8 % / 99.4 % DB busy — the same wall.
  The +0.7 % is two runtimes queueing behind one Postgres, and it licenses nothing.
- **Light is the result, and it is close.** +0.4 % throughput to pure-native, but at **+3.7 %
  cpu/req** and 4 points more of the pin (99.7 % vs 95.7 %). Pure-native buys its marginal
  throughput with CPU rather than efficiency. Within-leaf paired ratio 0.9957 (spread
  0.9716–1.0288) agrees with the arm means.
- **Footprint:** +4.1 % RSS, +0.8 % off-heap. Both iso-heap; neither is a large effect.
- **Tail is the one large difference** — 2.81× on light. See **L5**.
- **The Jackson confound has a KNOWN SIGN, and it runs against pure-native.** An earlier draft of
  this entry used the confound's *magnitude* (~⅕ of Exeris on-CPU time is serialisation) to
  decline to attribute the gap. That was an error of method: it never checked the direction.
  `JacksonVersionSerializationBenchmark`, on the identical 10×10×10 payload, measures
  **Jackson 3 at 15.77 µs/op against Jackson 2 at 17.78 µs/op — Jackson 3 is ~11 % FASTER**, at
  effectively identical allocation (18 005 vs 17 998 B/op) and byte-identical output
  ([triad report §4](../results/reports/2026-07-21-entity-read-by-id-tuned-pg-triad-comparison-eligible.md)).
  pure-native therefore runs the *faster* serialiser and is *still* 3.7 % more expensive per
  request. Taking serialisation at ~20 % of on-CPU, the Jackson 3 advantage is worth ~2.2 % of
  total, so pure-native's non-serialisation work is roughly **6 % more expensive, not 3.7 %**.
  The confound does not excuse the gap — removing it widens it. (The ~6 % combines a profiling
  share with a microbenchmark delta and is an estimate; the *sign* does not depend on that
  arithmetic.)
- Honest form of the claim: **parity within a few percent, and the serialisation confound has a
  known direction that understates rather than flatters the gap.** That is still a strong result
  for a Spring application against hand-tuned Quarkus; it is simply not a result that may lean
  on "but Jackson".
- Other declared fences: HikariCP vs Agroal, posix-hybrid vs Netty/Vert.x, pgjdbc-over-JUL, and
  heavy-response key ordering (same 9105 bytes, `jq -S`-equal, deliberately un-normalised).
- **Load generator ruled out**, not assumed: 7.4 % / 19.4 % busy, 24/24 windows
  `loadgen_headroom_available`.

## L8 — an idle Spring-on-Exeris process is ~18× less idle than Tomcat or the native runtime

- Class: fact (measured) · Tier: Community · Track: **public-eligible** (was: internal, on the void `spring-on-exeris*` exclusion) · Campaign: `20260806T183034Z-spring-ladder-n3`, n=24 windows per identity
- The runner samples the *co-resident, launched-but-not-driven* target during each measurement
  window (`neighbour-resource-metrics.json`, `role: resident-idle`). Doing nothing costs:

  | idle arm | cores | % of the 4-core server pin |
  |---|---:|---:|
  | spring-on-exeris-pure | 0.0280 | **0.70 %** |
  | spring-on-exeris-pure-native | 0.0270 | **0.67 %** |
  | exeris-community | 0.0020 | 0.05 % |
  | spring-hibernate | 0.0015 | 0.04 % |

- The split is by **hosting model, not by runtime family**: the two Spring-on-Exeris arms burn
  ~18× what either Tomcat *or* the native Exeris arm does. exeris-community runs the same kernel
  as pure-native and is as quiet as Tomcat, so this is not "Exeris spins" — it is something in
  the Spring-hosted composition. Not diagnosed here.
- **In density terms — which is how the platform is sold — 0.028 cores is not small:**

  | idle arm | cores | threads | idle RSS | **idle instances per core** |
  |---|---:|---:|---:|---:|
  | spring-on-exeris-pure | 0.0280 | 43.9 | 1073 MB | **36** |
  | spring-on-exeris-pure-native | 0.0270 | 43.9 | 903 MB | **37** |
  | exeris-community | 0.0020 | 36.7 | 630 MB | **503** |
  | spring-hibernate | 0.0015 | 38.2 | 1464 MB | **645** |

  A Spring-on-Exeris instance that is serving nothing exhausts a core in **36 copies**, where
  the native runtime needs 503 and Tomcat 645. On any deployment where most instances idle most
  of the time — multi-tenant, edge, per-branch — that is a first-order number against exactly
  the density argument the small memory floor is meant to support.
- **Density is limited by whichever resource runs out first, and these two arms fail on
  different ones.** Tomcat holds the largest idle footprint (1464 MB) and the lowest idle CPU;
  Spring-on-Exeris holds ~40 % less memory and ~18× the CPU. A density claim that quotes only
  RSS picks the axis that flatters, and this table is why both belong.
- **Not a thread-count effect.** Idle threads differ by ~20 % (36.7–43.9) against an ~18× CPU
  difference, so this is a handful of threads doing periodic work, not more threads existing.
- **Three of the obvious Spring-side suspects are eliminated statically:** no arm declares
  `spring-boot-starter-actuator`, Micrometer, Quartz or `spring-boot-starter-integration`, and
  none sets any `management.*`, `spring.task.*` or `spring.jmx.*` property. It is also not the
  persistence mode — pure (ORM) and pure-native (kernel-native) are indistinguishable here
  (0.0280 vs 0.0270, both at 43.9 threads).
- What remains is the **composition itself**: the kernel alone is quiet (community, 0.0020) and
  Spring alone is quiet (hibernate, 0.0015); only the kernel hosted *inside* a Spring context
  idles hot.

### The density claim survives this — threshold computed

The instinct to say "quoting only RSS picks the flattering axis" is methodologically right and
**wrong on these numbers**. Memory per core at which idle CPU would start to bind before RAM:

| arm | GB/core break-even |
|---|---:|
| spring-on-exeris-pure | 37.4 |
| spring-on-exeris-pure-native | 32.7 |
| exeris-community | 307.6 |
| spring-hibernate | 953.1 |

Commodity servers run 2–8 GB/core and memory-optimised shapes 8–16. Nothing real approaches
33 GB/core, so **RAM binds first by an order of magnitude on all four arms**. Density remains
legitimately an RSS claim. The 18× idle-CPU gap is worth fixing for what it does on a *busy*
node — where those cycles compete with real work, and where it touches **L5** — not because it
limits how many idle instances fit.

Recorded with the threshold so the claim is not weakened later by the same reflex that nearly
weakened it here.

### But the instances-per-core column is DIRECTIONAL, not citable

Every arm ran a pinned `-Xms1280m -Xmx1280m` with `AlwaysPreTouch` off, so idle RSS measures
*pages touched at that heap*, not memory required:

| arm | idle RSS | % of committed heap |
|---|---:|---:|
| spring-hibernate | 1464 MB | 114 % |
| spring-on-exeris-pure | 1073 MB | 84 % |
| spring-on-exeris-pure-native | 903 MB | 71 % |
| exeris-community | 630 MB | 49 % |

community sits at 630 MB here against a 128 MiB floor established by the memory sweep — so real
density for the lean arms could be several times better than this table implies, and with touch
ratios spanning 49–114 % the **ordering itself could move**. Instances-per-core is derivable
only from a per-rung floor campaign, which does not exist yet. Until it does, this table shows
the *ordering* of idle cost, not its magnitude.

### Same structural condition as L5

| | condition | symptom |
|---|---|---|
| **L5** | (Spring + native persistence) ∧ CPU saturation | tail excess absent at 78 % of pin, 2.8× at 99.7 % |
| **L8** | (Spring + Exeris kernel), no load at all | 18× idle CPU |

Different conditions, different symptoms, one shape: the cost exists only when both components
share a process. That is not evidence of a common cause, but it is reason to look for one before
diagnosing two things separately — and there is a concrete join: something burning 0.027 cores
on an idle process is a *periodic wakeup*, and a periodic wakeup on a saturated system competes
for carriers at precisely the worst moment, which is a mechanism capable of producing a
saturation-dependent tail.

### The idle profile did not already exist — now it will

Per-target JFR brackets only that target's own window. Verified from the ladder's sidecar
timestamps: target-a recorded 23:13:44–23:33:47, target-b 23:33:47–23:53:51 — back to back,
never overlapping. (The shared suffix in both recording *names* is the leaf's launch token, not
a start time; the file mtimes are what settle it.) So the idle arm was never recorded, and this
was not sitting in the campaign's ~23 GB.

`run-comparative.sh` now arms a capped `settings=profile` recording on the co-resident target
for exactly the window its resource sampler covers (`neighbour-idle.jfr`,
`BENCH_PROFILE_IDLE_NEIGHBOUR=1` by default, best-effort — it can never fail a leaf). Same class
of change as the load-generator sampler, and it means the next campaign answers this for free
rather than needing a bespoke run.

**Two conditions on reading it, both settled before the instrument ships:**

*The profile will partly contain JFR.* On a loaded application JFR's overhead is ~1–2 % and
disappears into the background; on a process burning 0.027 cores the same absolute overhead is
proportionally enormous, and `profile` contributes its own periodic work (`jdk.CPULoad` each
second, the sampler thread, chunk rotation) which appears in the profile *as work*. The floor
comes free from the same change: exeris-community (0.0020 cores) and spring-hibernate (0.0015)
are recorded as neighbours under identical settings, so **their profiles are the instrument's
noise floor** and anything absent from them is signal. The quiet arms are the control, not
"nothing interesting" — without them the noisy profile is unreadable.

*Park intervals before hot-methods.* 0.027 cores over a 20-minute window is ~32 CPU-seconds
arriving as periodic wakeups. `ExecutionSample` will catch that but smear it across frames; a
thread parking on a **fixed interval** is the signature of a timer rather than of work. The
precedent is in this lab: triad report §7 identified Agroal pool housekeeping from
"`ThreadPark`/`JavaMonitorWait` on `agroal-*` threads with 2-minute and **exactly-2000 ms**
timers". *Exactly 2000 ms* is what names a timer; an averaged CPU figure never could. So read
repeated exact park durations first — they yield a thread name and a period — and hot-methods
second.

## L9 — OPEN: inter-pair drift is a per-request cost increase, not CPU starvation

- Class: descriptive-only, **unresolved** · Tier: Community · Track: **public-eligible** (was: internal, on the void `spring-on-exeris*` exclusion) — publishable as an open question.
- The long-standing observation: the same arm measured in different pairs differs by 1–3 %,
  reproducibly and in a consistent direction within a campaign. Slot order and neighbour identity
  were indistinguishable.
- **CPU theft is now eliminated as the mechanism.** The candidate was the unpinned `docker-proxy`
  landing on the server cpuset and stealing cycles. That predicts *fewer cores at constant
  cpu/req*. Measured, ladder n=12 per cell:

  | measured arm | contract | rps | cpu/req | cores |
  |---|---|---:|---:|---:|
  | pure | light | −3.0 % | **+3.1 %** | −0.1 % |
  | pure | heavy | −2.1 % | **+1.5 %** | −0.6 % |
  | pure-native | light | −1.2 % | **+1.6 %** | **+0.4 %** |
  | pure-native | heavy | −1.7 % | **+0.8 %** | −0.9 % |

  Cores are flat or *higher* while cpu/req rises by about what throughput loses. The arms are not
  starved; each request genuinely costs more. That rules out starvation of any kind, `docker-proxy`
  included, and it also means the drift **cannot** be corrected by normalising to cores.
- **Idle-neighbour CPU (L8) is not the explanation either, though it correlates.** Six of the
  eight arm/neighbour combinations move the right way — a noisy Spring-on-Exeris neighbour costs
  the measured arm more. But `pure-native` **inverts** in both contracts: it is worse beside the
  *quiet* community (0.002 idle cores) than beside the *noisy* pure (0.028). One clean inversion
  is enough to reject the single-variable version of the hypothesis.
- What survives: the effect is concentrated on **pair 3**, which penalises *both* its arms, and
  pair 3 is the only pair whose arms are both Exeris-kernel-backed. Slot order is ruled out by
  community, which is *worse* in the earlier pair 3 than in the later pair 4.
- Next candidates, in order of cheapness: LLC/memory-bandwidth interference from the resident
  neighbour (cpu/req rising with cores flat is the classic signature), and SMT sibling effects —
  the server pin `0-1,8-9` is two physical cores with both threads, so a co-resident process can
  land on a sibling thread of the measured one. Neither is testable from the artefacts currently
  captured; both would need per-core counters the rig does not yet sample.

## L10 — OPEN: the "ORM cost" on the Spring arms is partly Spring Data projection-proxy cost

- Class: exploratory, **unresolved** · Tier: Community · Track: **public-eligible** (was: internal, inherited from L3, whose exclusion was void)
- Campaign: `20260810T131208Z-hibernate-vs-jdbc-n3`, 12/12 `comparison_eligible`, n=6 per contract
  (3 repeats × ab/ba). Pair `spring-hibernate__spring-jdbc` — same Tomcat, same Boot 4.1.0, same
  `SecurityConfig`, same HikariCP, same normalised pgjdbc URL, same three-query SQL shapes.
- **The measured deltas, which are not in question:**

  | contract | spring-hibernate | spring-jdbc | ratio | DB busy (hib / jdbc) |
  |---|---:|---:|---:|---|
  | heavy | 1074.7 µs (±12.0) | 271.8 µs (±2.8) | **×3.95** | 26.4 % / **97.4 %** |
  | light | 143.6 µs (±2.2) | 122.5 µs (±1.3) | **×1.17** | 19.0 % / 21.9 % |

  Heavy rps is **not** quotable as an arm ratio: `spring-jdbc` saturates the DB cpuset at 97.4 %
  while `spring-hibernate` leaves it at 26.4 %, so the heavy throughput side reads the Postgres
  ceiling for one arm only (same regime as L2). Light is DB-unsaturated on both arms, so light rps
  (27 571 vs 32 190) **is** quotable. Errors 0/0 across all 12 leaves.
- **What the JFR views say the ×3.95 actually is.** `hot-methods` and `allocation-by-class` on the
  heavy leaves ([`jfr-views/`](../results/raw/entity-read-by-id/20260810T131208Z-hibernate-vs-jdbc-n3/jfr-views/),
  repeat01 and repeat03 agree to 0.05 pp on the top frame, so this is not profiler noise):

  | | spring-hibernate | spring-jdbc |
  |---|---|---|
  | top CPU frame | `DefaultAdvisorAdapterRegistry.getInterceptors(Advisor)` **9.6 %** | `pgjdbc VisibleBufferedInputStream.ensureBytes` 5.3 % |
  | next | `ResolvableType.calculateHashCode` 4.5 %, `Class.copyMethods` 4.4 % | `Invokers.checkCustomized` 5.2 %, Jackson `_verifyValueWrite` 4.9 % |
  | top allocations | `Object[]` 14.6 %, **`java.lang.reflect.Method` 11.2 %**, `ResolvableType` 7.0 % | pgjdbc + Jackson + DTOs |
  | AOP-specific allocations | `ReflectiveMethodInvocation` 3.2 %, `MethodInterceptor[]` 2.8 %, `PropertyDescriptor[]` 2.0 %, `AdvisedSupport$MethodCacheKey` 1.6 %, **`ProxyFactory` 1.5 %**, `Advisor[]` 1.4 % | none in top 25 |
  | genuine ORM row-mapping | `LinkedHashMap$Entry` 5.0 %, `NativeTupleElementImpl` 1.5 % | n/a |

  Spring AOP / reflection machinery outweighs Hibernate's own tuple materialisation in this
  profile. `ProxyFactory` being allocated at all at steady state means proxies are constructed on
  the request path, and a fresh `ProxyFactory` carries a fresh `AdvisedSupport`, so its
  `methodCache` is cold every time — which is why the *cache-miss* frame
  (`getInterceptors`) is the hottest method in the arm.
- **Mechanism, and it explains the heavy/light asymmetry.** `spring-hibernate`'s repositories
  return Spring Data **interface projections** (`FriendByUserRowProjection`,
  `InterestByUserRowProjection`); Spring Data proxies **one per returned row** and routes every
  getter through the interceptor chain. Heavy returns ~200 rows/request and reads 3–4 getters
  each ⇒ ~200 proxy constructions + ~700 proxied invocations per request. Light calls
  `findById(id)`, which returns a managed **entity** — no projection, no proxy. That is precisely
  the shape of the data: ×3.95 heavy vs ×1.17 light. `spring-jdbc` maps rows with a lambda
  `RowMapper` straight into records — no proxy on either contract.
- **Consequence for the pair's label.** `spring-hibernate__spring-jdbc` does **not** isolate ORM
  presence. It moves two things at once: Hibernate *and* the Spring Data repository/projection
  abstraction. Quote it as **"Spring Data JPA + Hibernate vs JdbcTemplate + RowMapper"** — which is
  a real and idiomatic choice a Spring team makes, and defensible as a *stack* comparison — but not
  as "the cost of the ORM".
- **This propagates to L3, and L3 is the load-bearing one.** L3's ORM component is
  `spring-on-exeris-pure − spring-on-exeris-pure-native` = 723.97 µs = 67.2 %. Verified 2026-08-11:
  `spring-on-exeris-pure` declares the **same four projection interfaces**, and
  `spring-on-exeris-pure-native` declares **none**. So L3's subtraction carries the identical
  confound — its "67 % is Hibernate" is really "67 % is Hibernate + Spring Data projection
  proxies". The ×1.49 Amdahl ceiling and the migration-order conclusion ("the repositories go
  first") are **unaffected in direction** — that pool of cost is real and it does leave the path
  when the repositories do — but the *attribution to Hibernate specifically* is not established by
  the current arms.
- **What would settle it:** one arm of Hibernate/JPA driven through `EntityManager` (or a
  constructor-expression / DTO query) with no Spring Data repository proxy, against the existing
  `spring-hibernate`. That splits the pool into ORM row-mapping vs Spring Data abstraction. Not
  built; no campaign is pending for it.
- **Instrumentation caveats.** JFR `ExecutionSample` is Java-frames-only, so this says nothing
  about the `%sys`+`%soft` half of the budget. The two arms' recordings also have different
  denominators — 874 s (spring-hibernate, ≈ its own window) vs 1213 s (spring-jdbc, which was
  resident and idle during its partner's leg), so `spring-jdbc`'s shares are diluted. Dilution
  shrinks its percentages uniformly and cannot manufacture the asymmetry, but no cross-arm share
  is quoted as a like-for-like number here. Exploratory: no `claim-status.json` rides on these
  views, and no comparative claim is made from them.
