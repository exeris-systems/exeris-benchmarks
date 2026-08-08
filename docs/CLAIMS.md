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

---

## L1 — cpu/req reduction, exeris-community vs Tomcat (light)

- **EN:** `65.3% less CPU per request than Spring Boot on Tomcat, same contract, same box (50.9 µs vs 146.7 µs, n=12 per arm)`
- **PL:** `65,3% mniej CPU na żądanie niż Spring Boot na Tomcacie, ten sam kontrakt, ta sama maszyna (50,9 µs vs 146,7 µs, n=12 na ramię)`
- Class: comparison-eligible · Tier: Community · Track: **public-eligible**
- Contract: `fixed_contract_cross_runtime_h1_single_read_v1` · Campaign: `20260806T183034Z-spring-ladder-n3`
- Note: pair 4 (`spring-hibernate` ↔ `exeris-community`) only — both arms are outside the
  `spring-on-exeris*` internal track, which is what makes this one publishable.
  Iso-heap 1280 MB, version-aligned (Boot 4.1.0, Jackson 3, kernel 0.10.2), DB pinned
  4-7,12-15. Heavy equivalent is −80.4 %, but see **L2**: on heavy the throughput side of
  this pair reads the DB ceiling, so quote cpu/req there or nothing. Bridge fence applies —
  this is a floor.
- Supersedes the June n=3 dev-laptop measurement (h2+TLS, Boot 3.5). Three measurements,
  two environments, two Spring generations, same direction.

## L2 — the heavy contract is DB-bound *for the fast arms only*

- **EN:** `DB saturation is a property of the stack that reaches the database, not of the workload: at the same offered load Postgres sits at 99.8% for the two fastest arms and 30–35% for the two slowest`
- Class: fact (measured) · Tier: Community + internal arms · Track: **internal** (names internal arms)
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
- Class: exploratory · Tier: internal arms · Track: **internal** (derived from `spring-on-exeris-pure`)
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
- Migration-order consequence: on a DB-bound workload the repositories go first. Until the
  ORM leaves the path, runtime work is optimising 33 % of the request.

## L4 — the ladder decomposition closes, and cpu/req is the metric to close it on

- Class: fact (measured) · Track: **internal**
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

## L5 — OPEN: pure-native's light-contract tail

- Class: descriptive-only, **unresolved** · Track: internal
- pure-native has the second-best median and the **worst p99 of all four arms**, worse than
  Tomcat, on light only:

  | arm (light) | p50 | p99 | p99/p50 |
  |---|---:|---:|---:|
  | spring-hibernate | 4.83 | 8.97 | 1.86 |
  | spring-on-exeris-pure | 2.95 | 7.83 | 2.66 |
  | **spring-on-exeris-pure-native** | **2.00** | **12.49** | **6.26** |
  | exeris-community | 1.48 | 7.46 | 5.05 |

- Two hypotheses already eliminated by the data:
  - *Not a fixed-cost event masked by a larger median.* The excess is **absent** on heavy
    (pure-native − community = **+0.17 ms**, vs **+5.04 ms** on light). Regime-dependent,
    not scale-dependent.
  - *Not a load-fraction artifact.* pure at 96.41 % of pin gives p99 7.83; pure-native at
    96.90 % gives 12.49. Half a point of saturation, +60 % of tail.
- What is left is localisation, not mechanism: the excess appears only where Spring **and**
  native persistence are both in the path **and** the arm is CPU-saturated. Neither alone
  shows it. Same pair of layers as the `PERSISTENCE_ENGINE` / `KernelProviderBinder.bind`
  scope work — a place to look, not a diagnosis.
- Next step unchanged: open-loop wrk2 below saturation. These p99 are still queue tails
  (p50 agrees with Little's law within a few percent in all eight cells).

### ESCALATED 2026-08-08 — reproduced against a different comparator, on different networking

Run B (n=6, host-net, quarkus-tuned as the comparator) reproduces it and makes it worse:

| light | p50 | p99 | p99/p50 |
|---|---:|---:|---:|
| quarkus-tuned | 2.09 | **5.91** | 2.8× |
| pure-native | 1.88 | **16.59** | **8.8×** |

**2.81× the comparator's tail**, on an arm with the *better* median. This is no longer a
property of the Spring ladder: different campaign, different opponent, different DB
networking, same arm, same excess.

Two readings, both supported:
- **Saturation aggravates it.** pure-native at 96.9 % of pin → 12.49 ms; at 99.7 % → 16.59 ms.
- **Saturation does not cause it.** At ~96 % matched utilisation the arm still sits at 12.49
  against quarkus's 5.91 and pure's 7.83.

quarkus-tuned is a useful new control: no ORM and no Spring, and the tightest tail in the whole
dataset. That is consistent with the localisation — the excess needs Spring *and* native
persistence in the same path — and it now rests on two independent comparators rather than one.

**Heavy remains clean and is now the sharper contrast**: p99 14.34 (pure-native) vs 15.78
(quarkus), i.e. pure-native's tail is *better* there. Whatever this is, it does not appear when
the arm has 22 % of its pin idle.

### The condition is a CONJUNCTION, and that narrows the suspect list

| contract | pure-native % pin | pure-native p99 | comparator p99 |
|---|---:|---:|---:|
| heavy | ~78 % | **14.34** | 15.78 (quarkus) |
| light | 96.9 % | 12.49 | 5.87 / 7.83 |
| light | 99.7 % | **16.59** | 5.91 (quarkus) |

Neither condition alone produces it. Not the stack: at 78 % of pin the same stack has the
*better* tail. Not saturation: quarkus-tuned at 95.7 % has the tightest tail in the dataset.
The trigger is **(Spring + native persistence) ∧ CPU saturation**.

That shape matters. A fixed per-request cost would be visible at 78 % of pin on heavy, and it is
not. Appearing only under saturation is the signature of **contention for a shared resource**,
not of extra work per request.

**Two discriminators, both from artefacts already on disk — no new campaign:**

1. **`jdk.VirtualThreadPinned` from the existing JFR recordings.** If something on the Spring MVC
   path pins a carrier, then under saturation the carrier pool becomes the constraint and the
   tail inflates in exactly this pattern. JDK 26 removed `synchronized` pinning (JEP 491), so the
   remaining candidates are native frames — a short list. One JFR view.
2. **GC + safepoint logs at matched ~96 % of pin**, using the recipe from the triad report §7 tail
   diagnostic (which cleared GC there: longest pause 23 ms, safepoint 28 ms). If it clears here
   too, scheduling is what is left, and (1) becomes the only surviving candidate.

Order is (1) then (2): cheaper, and aimed at the better hypothesis. Queued behind run A —
extracting JFR on the box during a measurement window is itself CPU work.

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
- Class: comparison-eligible · Tier: internal arms · Track: **internal** (names `spring-on-exeris-pure-native`)
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

- Class: fact (measured) · Track: **internal** · Campaign: `20260806T183034Z-spring-ladder-n3`, n=24 windows per identity
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
  idles hot. Diagnosis needs one 60-second JFR on a single idle instance — whatever burns
  0.027 cores is the entire profile, since nothing else is running. Queued behind run A; it
  cannot be done on this workstation, which has no local Postgres and where starting the Docker
  daemon would resurrect an unrelated protected stack.

## L9 — OPEN: inter-pair drift is a per-request cost increase, not CPU starvation

- Class: descriptive-only, **unresolved** · Track: internal
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
