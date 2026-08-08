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
