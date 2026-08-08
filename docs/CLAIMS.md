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

Why the two contracts differ: light runs ~55.7 k rps of single-query requests, heavy ~12.9 k
rps of three-query requests. Light does **4.3× more network round-trips per second** for far
less DB work each, so the per-round-trip NAT cost dominates its DB-cpuset time and is
negligible in heavy's.

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
- **DOMINANT UNRESOLVED CONFOUND: Jackson 3 vs Jackson 2**, a major-version difference in the
  response path of every request, previously profiled at roughly a fifth of Exeris on-CPU time
  in this scenario. A 3.7 % cpu/req gap is well inside what that alone could produce, so **do
  not attribute this gap to the runtime or the transport.** Other declared fences: HikariCP vs
  Agroal, posix-hybrid vs Netty/Vert.x, pgjdbc-over-JUL, and heavy-response key ordering
  (same 9105 bytes, `jq -S`-equal, deliberately un-normalised).
- **Load generator ruled out**, not assumed: 7.4 % / 19.4 % busy, 24/24 windows
  `loadgen_headroom_available`.
