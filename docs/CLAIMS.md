# CLAIMS.md — benchmark claim registry

Claims derived from campaigns in this repo, with the fences each one carries.
**Consumers copy, never paraphrase.** This is not the portfolio copy registry
(`arkstack-dev/portfolio:CLAIMS.md`), which holds public EN/PL marketing strings and
has no schema for open items, retractions or track labels. A claim marked
`track: internal` here **must not** be promoted there.

Classification follows the lab vocabulary: `comparison-eligible` / `exploratory` /
`descriptive-only` / `fact`. Every entry states tier, contract, n, and the fences.

**Before quoting anything from this file, read two sections: the
[retraction register](#retraction-register-every-claim-this-series-has-withdrawn-and-whether-it-travelled)
for what has been withdrawn, and the [citation canon](#citation-canon-what-to-quote-and-what-never-to-quote-alone)
for how to quote what remains.**

**Standing fence — bridge networking.** Every campaign up to and including
`20260806T183034Z-spring-ladder-n3` ran with the DB on Docker **bridge** networking
(`backend_network_mode: bridge` in all 48 leaves). The June measurement of that tax on
this same box is `+20.5 %` rps host-net vs bridge, at **unchanged application cpu/req**
(0.357 → 0.358 ms), with target-thread `%wait` falling 265 % → 57 %
([June report §2](../results/reports/2026-06-20-entity-read-by-id-steady-state-and-cost-per-request.md)).
The tax is charged per DB round-trip, so the faster arm — which issues 2.8× (light) to
3.6× (heavy) more round-trips per second — pays proportionally more of it. **Every
Exeris-favourable number below is therefore a floor, not a point estimate.**

> **Provenance caveat, added 2026-08-11.** The `+20.5 %` / `0.357 → 0.358 ms` figures exist in the
> June report's prose and nowhere else. Every committed `results/raw/guided/*/result.json` records
> `backend_network_mode: host`, so **the bridge leg is not in the repository**, and the run does not
> appear in that report's own run index. Quote it as the origin of the fence, not as a reproducible
> measurement. The fence itself does not depend on the magnitude: `scripts/compare-results.sh`
> refuses a mode-crossing comparison outright, and the direction (bridge penalises the chattier arm)
> is what the "floor, not a point estimate" reading rests on.

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

## Retraction register — every claim this series has withdrawn, and whether it travelled

Added 2026-08-11. Retractions were previously appended to the entries they affected, which is
right for the reader of an entry and useless for the reader who wants to know *what this lab has
been wrong about*. They are collected here as well; the per-entry text stays where it is and
remains authoritative for detail.

**Why a register rather than a list of mistakes.** Twenty-one withdrawals are recorded below, and
**none of them was ever carried by a distributed artefact in its wrong form.** Two came close and
are flagged ⚠ rather than cleared:

- **#14** sat in a *finished* report — the 2026-07-21 triad, non-DRAFT, `comparison_eligible`,
  `reproducibility_status: complete` — for **~1.6 days across four PRs** before it was corrected.
  That report was later distributed outside this repo, but **only after `ae333638` promoted the
  corrected table**, which is the last commit it ever received. What left the repo was the
  corrected report carrying its own retraction in the body; the superseded figures left only in
  git history.
- **#1** had reached the **EN copy string** — the line this file instructs consumers to copy
  verbatim. No report carried it, but a copy string is a distribution surface of a different kind.

**#15–#21 were found after the 2026-08-11 Spring report reached what was then its final shape.**
That report is still DRAFT and has **not** been distributed, so they are caught-before-shipping
like the other thirteen — but they are a useful warning about this column: *"has not travelled"*
is a fact about a moment, not a property of a claim. It is the only column here that decays.

**#18–#21 came from an independent re-derivation** that rebuilt every headline figure from
`results/raw/entity-read-by-id/` without reading the report — the second derivation
`reproducibility_status: incomplete` was waiting for. **Every headline number survived it**; what
did not survive were one derivation error (#18), two over-stated scopes (#19, #20) and one
internally contradictory constant (#21). That is the distribution you want from a second pass:
the findings hold, the bookkeeping does not.

> **"Carried by a finished report" is not the same as "released", and this column only claims the
> first.** Whether any report in this repo was ever distributed outside it — a post, a deck, the
> portfolio registry — is **not checkable from here**, for any of the fourteen. What is checkable
> is whether a non-DRAFT report ever contained the figure, and that is what the column reports.
> Read a clear cell as *"no finished artefact in this repo carried it"*, never as *"nobody saw
> it"*: the remote is public, so git history carried everything.
>
> This distinction was itself wrong on first writing — the register said "reached a published
> report", conflating the two — and is corrected here. #13 in the table below is the same class
> of error, two days apart.

That ratio is not luck and it is not modesty: it is the measurable output of the review loop
running ahead of the publication loop. A lab that never retracts anything is not more careful
than one that retracts before publishing; it is only less observed.

**The "travelled?" column, and what it can and cannot tell you.** Three exposure surfaces exist,
and only two are checkable from inside this repo:

- **Public git history.** `github.com/exeris-systems/exeris-benchmarks` is a **public** remote,
  so every figure below was visible in commit history from the moment it was pushed. "Did not
  travel" never means "was never visible" — it means no *reader-facing artefact* carried it.
- **A finished report** — anything in `results/reports/` not marked DRAFT. Checkable, and checked
  across all six. This is the column's actual subject; see the caveat above on why that is weaker
  than "released".
- **The external portfolio registry** (`arkstack-dev/portfolio:CLAIMS.md`) **and outreach drafts.**
  **Not verifiable from here.** The two planned foojay articles are drafted for Sept–Oct 2026 and
  have not shipped, so the exposure window is small — but anything marked ⚠ below should be
  checked against the portfolio registry before it is assumed contained.

| # | what was claimed | withdrawn | what replaced it | travelled? |
|---|---|---|---|---|
| 1 | *"Hibernate is 67 % of the cost"* — the plain-"ORM" label on the L3 pool | 2026-08-11 | *"the Spring Data JPA + Hibernate repository layer"*; largest identified contributor is projection proxies, split **unmeasured** (L10) | ⚠ **the EN copy string in L3** — the one surface this registry tells consumers to copy verbatim. Old string kept struck-through and labelled DO NOT COPY. No finished report carried it. |
| 2 | **×1.127** hosting rung | 2026-08-11 | **≈ 89–96 µs, ×1.09–1.10** — 23.3 % of the step was Spring Security (L11) | no finished report; canon says do not quote it at all |
| 3 | **×1.488 / 67.2 %** Amdahl ceiling quoted for Tomcat | 2026-08-11 | **×1.338 / 74.7 %** measured directly on Tomcat; ×1.488 survives, *named to* the Exeris-hosted derivation | no |
| 4 | **±2.80 %** cpu/req error budget (4 summed rows) | 2026-08-11 | **±2.52 % heavy / ±3.71 % light**, per contract, quadrature, derived by `tools/derive-error-budget.sh` | no — draft only |
| 5 | a bare **"18×"** idle-CPU ratio | 2026-08-11 | absolute **~0.027 cores / ~0.67 % of a 4-core pin**; the ratio is 18.1–29.6× depending on the comparator | no |
| 6 | L8's idle-RSS column read as a **footprint** | 2026-08-11 | a **rank**, not a footprint: it averages never-served and after-serving states, which differ 1.9×–5.5× | no |
| 7 | *"the two arms' responses were byte-identical"* | 2026-08-11 | **bodies only**; never covered full responses on **any auth-crossing pair**, across all four ladder arms + `comp-native` | no |
| 8 | light-contract DB busy **87–89 % = Postgres utilisation** | 2026-08-08 | **~37 %** on host — the bridged figure was Postgres *plus* container networking (55 of 87 points `sys`+`soft`) | no |
| 9 | L2's first explanation of the contract difference: *"light does 4.3× more round-trips"* | 2026-08-08 | arithmetic error — heavy issues **three queries per request**, so the true ratio is **1.43×**. Mechanism left **open** rather than re-explained | no |
| 10 | L4's prediction that overlapping rungs make the light gap exceed the heavy gap | 2026-08-06 | the axes compose; the residual is drift, not interaction | no — marked *never published* at the time |
| 11 | L4's closure justification: *"+2.0 % is inside the counterbalanced arm-order control (≤ ~2 %)"* | 2026-08-11 | +2.0 % is inside the **±2.52 % combined** envelope but **not** the arm-order term alone (1.00 %). Claim stands, justification did not | no |
| 12 | L5: *"worst p99 of all four arms"*, *"p99/p50 = 6.26× vs 5.05×"*, *"12.49 ms"* | 2026-08-11 | open-loop: tracks the native baseline within 5–22 % to 40 000 rps; **3.2× vs 2.4×**; **4.51–5.00 ms** — closed loop inflated it ~2.5× | no |
| 13 | *"idle cores are state-invariant to three decimal places"* | 2026-08-11 | **to within ~2 %** — 0.0286 vs 0.0278 does not survive three decimals. Finding unaffected. (The `0.0280` first quoted alongside it was the heavy-only served figure against a pooled first-touch; pooled on both sides it is 0.0278, −2.8 %.) | no — corrected one commit after it landed |
| 14 | the **agent-laden RSS profiles** (284/346/430 MiB light) | 2026-07-30 | agent-free medians, n=3: **233/276/352 MiB**; the agent tax is arm-dependent (~51/70/78 MiB) and **understated** Exeris's advantage | ⚠ **the closest call.** It sat in the 2026-07-21 triad — non-DRAFT, `comparison_eligible`, `reproducibility_status: complete` — for **~1.6 days across four PRs** (`cf7f4df9` → `ae333638`, 28–30 Jul), in the body, TL;DR **and** conclusions. **The triad was later distributed outside this repo — but after `ae333638`, its last commit, which is the correction.** So the wrong figures never left in a distributed artefact; the corrected report did, with the retraction visible in it. |
| 15 | *"×3.95 cpu/req on the **DB-bound aggregate**"* (report TL;DR) | 2026-08-12 | *"on the **~200-row aggregate**"*. On heavy `spring-hibernate` runs at **98.7 % of its own pin against a database at 26.4 %** — CPU-bound on its own repository work. Heavy is DB-bound for the **fast** arms only (L2) | no — the Spring report is still DRAFT and undistributed. Caught in review after it reached what was then final shape; precisely the inversion L2 forbids, and it was in the TL;DR |
| 16 | L3's *"on a **DB-bound workload** the repositories go first"* | 2026-08-12 | the layer dominates where the arm is **not yet** DB-bound; DB-bound is where you *arrive* once it is gone. Restated without either term: the layer is **74.7 % of a heavy request and 14.7 % of a light one** — same code, **5.1× different share**. **Migration order is a property of the row count in the contract, not of the stack** | ⚠ **this file** — L3 has carried the inverted phrasing since 2026-08-06 and the draft report quoted it. No distributed artefact carried it |
| 17 | §6's ladder table: two rungs shown against a *"whole stack ×5.118 direct"* row | 2026-08-12 | the third rung was missing — `pure-native` → `exeris-community`, **×1.100**, dropping Spring itself. Shown rungs multiplied to **×4.646**, a silent **10.2 %** gap. All three now shown; closes to **+0.2 %** | no — draft only. But a reader multiplying the visible rows got a different number from the one printed beside them, with no footnote |
| 18 | §6's decomposition *"product ×5.109 vs directly measured ×5.118 — closes to +0.2 %"* | 2026-08-12 | **there was no check.** The three rungs are consecutive ratios of the same four pooled arm-means, so they **telescope**: their product *is* the end ratio, ×5.110, identically. The ×5.118 came from **L4**, a different derivation. §6 now presents the table as an accounting identity and points at L4 for the real, non-tautological closure — rungs measured in their own pair runs, **×5.222 product vs ×5.118 direct, +2.0 %** | no — draft only |
| 19 | *"the artefacts stamp `latency_percentile_eligibility.publishable=false`"* | 2026-08-12 | **42 of the ladder's 48 units** do; the other **6** stamp `true` with reason `below_saturation` (heavy `purenative-vs-native`, neither arm at its knee). No claim rested on those six | no — draft only |
| 20 | §4.2's *"the two ORM-free stacks sit within roughly **5–15 %**"* | 2026-08-12 | the upper bound had no source. Derivable: **5.0 %** net of the light security term, **3.1 %** using its heavy variant, **17.2 %** unsubtracted — a **3–17 % band whose width is entirely the security assumption**, not a measurement spread | no — draft only |
| 21 | Setup's light contract *"~125 B"* | 2026-08-12 | the measured body is **30 B** (`{"id":"1","username":"user_1"}`) — 144 B on the wire without Spring Security's headers, 314 B with them. The figure contradicted §6 inside the same document and matched neither the body nor either full response | no — draft only |

**Two entries are worth reading as a pair, because they run in opposite directions.** #14 moved
*in Exeris's favour*, which
is the case where the incentive to leave it alone is strongest. Separately, the
`spring-on-exeris*` `internal` mislabel at the top of this file is the inverse of a retraction:
it did not release a wrong number, it **withheld eight correct ones** for a rule that never
applied. Both directions cost something, and only one of them looks like carelessness.

**Standing instruction.** When a retraction is added here, fill the travelled? column at the same
time. It is the only column that decays — a claim that had not travelled when it was withdrawn
can travel later if the register is not kept current.

---

## Citation canon — what to quote, and what never to quote alone

Added 2026-08-11, after the open-loop campaign changed which sentence is both the truest and the
most interesting one available. This section is for anyone copying from this registry into a
report, a deck, a post or a conversation.

**The flagship sentence** is *"the Spring Data repository layer does not make a request slower —
it makes the arm run out of headroom sooner."* It is the only formulation that survives **both**
contracts. It is supported by two instruments that disagree in magnitude and agree in direction:
×3.95 cpu/req on heavy against a heavy median gap of only ×1.43 at low load, with the arms
indistinguishable on light until 88 % of capacity (L10, and the report's §4/§7).

**The number for a non-specialist audience** is the whole-stack **×5.118 cpu/req**, quoted as
*"the same Spring application, the same SQL contracts, with the repository layer rewritten"*. It
is a cpu/req figure, so it survives the L2 ceiling rule that makes heavy throughput unquotable.

**Never quote these alone:**

- **×3.95** without the contract it belongs to and without "it is not simply Hibernate". Both
  omissions are things this registry has formally retracted (L10, register #1).
- **"×3.95 slower."** It is false on both contracts. The ratio is cost, not latency.
- **×1.127** — **superseded, do not quote it at all** (register #2). The security term inside it is measured
  (L11): 23.3 % of the step was Spring Security, not hosting. The current figure is
  **≈ 89–96 µs, ×1.09–1.10**, and it still travels with two fences — the cross-contract
  subtraction is an assumption, and 170 bytes of security response headers sit inside the
  subtracted term. It remains the smallest effect in the series; quote it only when the hosting
  axis is specifically the subject.
- **Any p99 as a point.** Tails in the open-loop campaign are far more order-sensitive than
  throughput (5.25 vs 15.07 ms at one offered rate); quote the ab–ba range.
- **Any heavy throughput ratio between a fast and a slow arm.** It reads the Postgres ceiling
  (L2). Use cpu/req.

**The objection this canon will attract, and the honest answer.** A careful reader will say: *your
own benchmark says the runtime is optimising the smaller third.* That is exactly what it says, and
it should be conceded rather than deflected. The answer is structural, not rhetorical: the
kernel-native persistence arm **is** the answer to the larger two thirds, L3's migration order is
the brownfield adoption path, and a benchmark that tells a customer *"do the cheap step first, the
one that needs none of our software"* is the same discipline as the retractions in this file,
applied at product level rather than at claim level.

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

## L3 — Amdahl ceiling on runtime work while the repository layer stays

- **EN:** `With the Spring Data JPA + Hibernate repository layer in the request path, no runtime work can exceed ×1.34 on this contract — that layer is 75% of the cost (measured directly on Tomcat)`
- **SUPERSEDED EN, do not copy:** ~~`With Hibernate in the request path, no runtime work can exceed ×1.49 on this contract — Hibernate is 67% of the cost`~~ — wrong on both halves. The attribution to Hibernate alone is retracted (L10), and ×1.49 / 67 % came from transferring the component across hosts; measured on Tomcat it is ×1.34 / 75 %. Keep quoting ×1.49 / 67 % **only** for the Exeris-hosted derivation, and say so.
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

- **THAT ASSUMPTION IS NOW MEASURED, AND IT WAS OPTIMISTIC (2026-08-11).** The arm this entry
  says does not exist was built: `spring-jdbc` is ORM-free **on Tomcat**
  (`20260810T131208Z-hibernate-vs-jdbc-n3`, host, 12/12 `comparison_eligible`), so the
  repository component no longer has to be transferred across hosts.

  | | measured on | repository layer | % of Tomcat's request | ceiling |
  |---|---|---:|---:|---:|
  | transferred (above) | Exeris-hosted, `pure − pure-native` | 723.97 µs | 67.20 % | **×1.488** |
  | **direct** | **Tomcat, `spring-hibernate − spring-jdbc`** (1074.74 − 271.75) | **802.99 µs** | **74.71 %** | **×1.338** |

  The transfer was **low by 10.9 %**. Hosted on Tomcat the repository layer is **three quarters**
  of the request, not two thirds, and the ceiling on runtime work is **×1.34, not ×1.49**.

  **Quote ×1.34 for a Tomcat deployment and ×1.49 only for the Exeris-hosted derivation**, naming
  which. The correction moves *against* the runtime — L3 overstated how much runtime work can win
  — and *strengthens* this entry's own migration-order conclusion: a repository layer that is 75 %
  of the request goes first even more clearly than one that is 67 %.

  The cross-campaign join is validated by the arm both campaigns share: `spring-hibernate` reads
  **1077.40 µs** on the bridged ladder and **1074.74 µs** on the host ORM campaign — **0.25 %
  apart**, which also reproduces the network fence's own claim that bridge-vs-host leaves cpu/req
  alone. Residual caveat: both subtractions replace JPA with a *different* hand-written data layer
  (`JdbcTemplate` vs the kernel-native repository API) and both keep pgjdbc + HikariCP, so they
  measure the same layer, not the same replacement.

  **Interaction with the security correction below — the two nearly cancel.** "Share of the
  addressable pool already captured" was 121.52/353.43 = **34.4 %**; L11 cuts the numerator to
  93.21 µs giving **26.4 %**; this correction cuts the denominator to 271.75 µs, returning it to
  **34.3 %**. Both terms fell ~23 % independently. Quote the ratio only with **both** corrections
  applied, and note it recombines a rung measured *on* the ORM stack with a remainder measured
  *off* it. Full derivation: the 2026-08-11 report §4.1.
- **SECURITY-TERM CORRECTION 2026-08-11 — the hosting step is ×1.09–1.10, not ×1.127.** The
  measured hosting rung (Tomcat → pure, 121.52 µs) contained an unmeasured servlet
  `SecurityFilterChain` difference: the Tomcat arm runs a per-request authorization decision, the
  Exeris arm carries no Spring Security at all. **Now measured (L11): +28.31 ± 3.25 µs/req, 23.3 %
  of the step.** Corrected, the rung is ≈ 89–96 µs (×1.09–1.10) and the share of the addressable
  pool already captured drops from 34.4 % to roughly 25–27 %. The ×1.488 ceiling and the
  migration-order conclusion are unaffected — both rest on the ORM component, not on this rung.
  Subtracting a light-contract figure from a heavy rung is a stated assumption, not a measurement;
  see L11's fences.
- **ATTRIBUTION CAVEAT 2026-08-11 — see L10 before calling this pool "Hibernate".** The ORM
  component is a subtraction between an arm that uses Spring Data JPA repositories with **interface
  projections** and one that uses none, so it contains the Spring Data projection-proxy cost as
  well as Hibernate's. JFR on the new `spring-hibernate__spring-jdbc` pair puts Spring AOP /
  reflection frames *above* Hibernate's own tuple materialisation. The 723.97 µs pool, the ×1.488
  ceiling and the migration-order conclusion are unaffected — that cost is real and it does leave
  with the repositories — but "Hibernate is 67 % of the cost" overstates what the arms separate.
  Prefer: *"the Spring Data JPA + Hibernate repository layer is 67 % of the cost"*.
- ~~Migration-order consequence: on a DB-bound workload the repositories go first.~~
  **RESTATED 2026-08-11 — the old phrasing inverted its own mechanism.** The workload where the
  repository layer dominates is precisely the one that is **not yet** DB-bound: `spring-hibernate`
  on heavy runs at **98.7 % of its own pin against a database at 26.4 %** (L2). DB-bound is where
  you *arrive* once the layer is gone (`spring-jdbc`: 97.4 % DB-busy), not the regime in which it
  is the bottleneck. Read the other way round it becomes the sentence L2 explicitly forbids.

  **Correct form, which needs neither "DB-bound" nor "Hibernate":** the repository layer is
  **74.7 % of a heavy request and 14.7 % of a light one** (802.99/1074.74 vs 21.1/143.6) — the same
  code, a **5.1× different share**. **Migration order is a property of the row count in the
  contract, not of the stack.** On a ~200-row aggregate the repositories go first by a wide margin;
  on a single-row read they are the third thing to look at and the runtime rung (×1.09–1.10) is
  comparable to them. Until the repository layer leaves a *heavy* path, runtime work is optimising
  a quarter of the request.

## L4 — the ladder decomposition closes, and cpu/req is the metric to close it on

- Class: fact (measured) · Tier: Community · Track: **public-eligible** (was: internal, on the void `spring-on-exeris*` exclusion)
- Product of the three rungs vs the directly-measured end-to-end pair:

  | | product | direct | drift |
  |---|---:|---:|---:|
  | heavy cpu/req | 5.222 | 5.118 | **+2.0 %** |
  | heavy rps | 3.717 | 3.581 | +3.8 % |
  | light cpu/req | 3.016 | 2.890 | +4.4 % |
  | light rps | 2.891 | 2.773 | +4.3 % |

- The ceiling-free metric closes at +2.0 %, inside the **±2.52 % heavy single-comparison
  envelope** (`tools/derive-error-budget.sh`, 2026-08-11). The decomposition is therefore sound as
  an **attribution instrument**, not merely a heuristic. Drift is systematically larger on rps than
  on cpu/req (3.8 vs 2.0 on heavy) — the same ceiling seen a third way.
  **Check ladder closure on cpu/req.**
  - **CORRECTION 2026-08-11.** This previously read "inside the counterbalanced arm-order control
    (≤ ~2 %)". That control was an n=1 exploratory cell on another configuration; re-derived over
    six `-n3` campaigns the arm-order term is **1.00 % heavy / 2.71 % light (p95)**, so +2.0 % is
    **not** inside the arm-order layer alone. It is inside the combined envelope once the
    restart layer is included — i.e. the residual is the size of a relaunch, not of a reordering.
    The closure claim stands; its justification was wrong.
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
read p99 5.25 against 15.07 ms in one cell at the same offered rate), and the arm-order term in the
cpu/req error budget (**1.00 % heavy / 2.71 % light**, p95) is measured on cpu/req and **does not
transfer to tails**. Measured size of the gap: on one runtime-snapshot pair p99 moved 16.9 % where
cpu/req moved 0.20 % — **83×** — on the light contract (heavy: 2.1×), and both percentiles were
closed-loop, i.e. queue occupancy rather than service time.

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

- **BRIDGE CONFOUND CLEARED, AND THE RATIO RE-SCOPED (2026-08-11).** The table above is from the
  **bridge** ladder, where an unpinned `docker-proxy` can land on either cpuset. The test that
  cleared `docker-proxy` for L9 — cycle-stealing predicts *fewer cores at constant cpu/req*,
  observed flat cores at higher cpu/req — **cannot run on an idle arm**: it serves nothing, so
  there is no denominator and stolen cycles would look exactly like signal. The co-resident
  sampler runs on every campaign, so this was answered by reading, not by a new run —
  `tools/extract-idle-coresidence.sh`, **264 idle windows over seven campaigns and both network
  modes** (96 bridge, 168 host):

  | idle arm | hosting model | bridge | host |
  |---|---|---:|---:|
  | spring-on-exeris-pure | Spring-on-Exeris | 0.0280 | — |
  | spring-on-exeris-pure-native | Spring-on-Exeris | 0.0270 | **0.0252 / 0.0271 / 0.0276** |
  | spring-on-exeris-comp-native | Spring-on-Exeris | — | 0.0267 |
  | spring-hibernate | Tomcat | 0.0015 | **0.0015** / 0.0053 / 0.0078 |
  | spring-hibernate-nosec | Tomcat | — | 0.0075 |
  | spring-jdbc | Tomcat | — | 0.0012 / 0.0048 |
  | exeris-community | native Exeris | 0.0020 | 0.0041 |
  | quarkus-tuned | Quarkus | — | **0.0009** |

  **Confound ruled out.** A `docker-proxy` next to the Spring-on-Exeris arm would inflate its
  *bridge* figure specifically. It does not move: 0.0270–0.0280 bridge against 0.0252–0.0276
  host — a 5 % spread across seven campaigns and both modes, with the *lowest* value on host. On
  the matched `-n3` designs the ratio **reproduces on host-net**: 0.0271 against
  spring-hibernate's 0.0015 is **18.1×**, 22.6× against spring-jdbc, and **29.6× against
  quarkus-tuned**, the quietest arm measured.

  **RE-SCOPE THE RATIO, NOT THE FINDING.** The numerator is invariant (0.0252-0.0280, 5 %
  spread); the denominator is not — quiet arms read **0.0009-0.0078 depending on campaign
  design**, an 8.7× range, unrelated to network mode. The ratio therefore inherits a variability
  the finding does not have. **Quote `~0.027 cores / ~0.67 % of a 4-core pin`, which is the
  reproducible quantity; give a ratio only with the pair and campaign it was measured against.**
  A bare "18×" is not citable.
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

**MECHANISM FOUND, 2026-08-11 — and the idle-RSS column above averages two different states.**
Whether the resident arm has **ever served traffic** changes its idle RSS by up to 5.5×:

| idle arm | first touch (never served) | after serving | ratio |
|---|---:|---:|---:|
| exeris-community | **194 MB** | 1066 MB | **5.5×** |
| spring-on-exeris-pure-native | **312 MB** | 1100 MB | **3.5×** |
| spring-on-exeris-pure | **629 MB** | 1221 MB | **1.9×** |
| spring-hibernate | *not observable in this campaign* | 1248 (light) / 1679 (heavy) | — |

So **the 630 MB quoted for exeris-community above is (194 + 1066) / 2 — a value the process is
never at.** The 1464 MB for spring-hibernate likewise averages a 1248/1679 contract split. Read
the column as a rank, never as a footprint.

Two riders. (a) **Idle CPU is state-invariant to within ~2 %** (pure 0.0286 vs 0.0278, pure-native 0.0274 vs
0.0268, community 0.0020 vs 0.0020), so everything this entry claims about idle *CPU* is
unaffected — the composition starts burning cycles before the first request. (b)
`spring-hibernate` has no first-touch figure because a never-served neighbour is observable only
in the first window of the `ab` direction, which samples `target-b`, and spring-hibernate is
`target-a` in both pairs it appears in. **Alternating `target-a` across repeats would close that
gap at no cost** — worth doing before any density campaign.

Full derivation and the loaded-RSS counterpart: the 2026-08-11 report §6b.

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
  proxies". The Amdahl ceiling and the migration-order conclusion ("the repositories go
  first") are **unaffected in direction** — that pool of cost is real and it does leave the path
  when the repositories do — but the *attribution to Hibernate specifically* is not established by
  the current arms. (The ceiling itself moved for an unrelated reason: measured directly on Tomcat
  rather than transferred, it is **×1.34 against 75 %**, not ×1.49 against 67 % — see L3. Both
  corrections point the same way: the repository layer matters more, and is less exclusively
  Hibernate, than the original claim said.)
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

## L11 — the servlet SecurityFilterChain costs 28.31 us/req, and it was 23 % of the hosting rung

- **EN:** `A permitAll Spring Security servlet filter chain costs 28.31 +/- 3.25 us of CPU per request on a single-row read - 24% of the request's own cost, and 23% of the Tomcat-to-Exeris hosting gain it was silently inflating`
- Class: **comparison-eligible** · Tier: Community · Track: **public-eligible**
- Contract: `fixed_contract_cross_runtime_h1_single_read_v1` · Campaign:
  `20260811T114140Z-security-confound-n3`, **12/12 leaves `comparison_eligible`**, n=3 complete
  repeats (full JVM restart, both directions; partial repeats excluded)
- **One jar, one variable.** Both arms launch the identical
  `spring-benchmark-app-1.0.0-SNAPSHOT.jar` with the same `artifact_sha256`, separated only by
  `benchmark.security.filter-chain.enabled=false` plus seven Boot 4 security auto-configuration
  exclusions. Classpath, loaded classes and metaspace are constant, so RSS stays comparable.

  | contract | repeat01 | repeat02 | repeat03 | mean | sd | share of the 121.52 us step |
  |---|---:|---:|---:|---:|---:|---:|
  | **light** (the measurement) | +26.23 | +26.64 | +32.06 | **+28.31 us** | 3.25 (11 %) | **23.3 %** |
  | heavy (transferability check) | +40.40 | +21.99 | +35.35 | +32.58 us | 9.52 (29 %) | 26.8 % |

- **Light is the measurement by design.** A 10-30 us effect is 0.93-2.78 % of heavy's 1077 us
  baseline against a **+/-2.52 % heavy envelope** — straddling the floor, i.e. unresolvable — and
  6.8-20.5 % of light's 147 us against **+/-3.71 %**, clear of it across almost the whole range.
  Heavy could never have resolved it, and its 29 % relative uncertainty confirms that the limit is
  the ratio of effect to layer variance, not the repeat count. (Envelopes re-derived 2026-08-11 by
  `tools/derive-error-budget.sh` over six `-n3` campaigns; they replace a `+/-2.80 %` figure that
  had been quoted forward from an n=1 cell on another configuration.)

### Fences — three, and none is optional

1. **Contract-dependence is NOT established, so the subtraction is an assumption.** The intervals
   overlap ([25.1, 31.6] against [23.1, 42.1]). The data are consistent with a constant absolute
   per-request cost and do not prove one. Any use of the light figure against a heavy rung must say
   so.
2. **Part of the 28.31 us is bytes, not authorization.** `HeaderWriterFilter` adds six response
   headers the nosec arm omits (`X-Content-Type-Options`, `X-XSS-Protection`, `Cache-Control`,
   `Pragma`, `Expires`, `X-Frame-Options`): **170 bytes against a 30-byte light body**, so the
   stock arm writes 314 bytes per response where the other writes 144 - **2.18x**. The split is
   **not quantified and deliberately not estimated**. For *"what does removing Spring Security
   save"* the full figure is right, because `spring-on-exeris-pure` does not emit those headers
   either. For *"what does the authorization decision cost"* it is an over-estimate by an unknown
   amount.

   **Scope correction, 2026-08-11 — this is wider than the nosec pair.** The response-checksum
   control in this series (heavy `sha256/16 82f9bcdf2852bd5e`, 9105 bytes, reported as matching
   across **all four ladder arms plus `comp-native`**, and used as a fairness control against
   serialisation-volume effects) was computed on **response bodies only**. Ladder arms 1-3 carry
   Spring Security and emit the six headers above; arms 4-5 do not. The checksum therefore
   **never covered full responses on any auth-crossing pair** - not merely on
   `spring-hibernate` / `-nosec`. It stands as a **content** control (the arms return the same
   payload) and must no longer be cited as evidence of equal **bytes on the wire** wherever the
   auth axis is crossed. The ORM pair (`spring-hibernate` x `spring-jdbc`) is unaffected: one
   shared `SecurityConfig`, identical headers, so bodies *and* headers match there.

   **Propagation — this entry is the only carrier that needed changing.**
   `runtime/drivers/target-asset-matrix.json` and
   `scenarios/entity-read-by-id/comparative-pair-manifest.json` both already say *body*
   ("body byte-identical to all four ladder arms", "confirmed equal by response-body checksum"),
   and the manifest's pair (`pure-native` x `comp-native`) does not cross the auth axis at all -
   neither arm carries Spring Security. The defect was in prose that dropped the word *body* when
   quoting the artefacts, not in the artefacts. Anyone citing `82f9bcdf2852bd5e` as evidence of
   wire-equal responses across an auth-crossing pair is over-reading it.
3. **Not a general Spring Security figure.** This is one application's permitAll chain on Tomcat
   under one contract. The Exeris-side equivalent (`ExerisSecurityContextFilter`) is a different
   mechanism, separately measured at +0.14 %, and the two must not be swapped.

### Unexplained, recorded rather than dropped

On heavy the arm **with** the filter chain is markedly more reproducible across repeats
(sd 0.21 %) than the arm without it (0.82 %, range 15 us). The configuration with fewer layers is
the less stable one. n=3, no mechanism proposed, and no claim rests on it.
