# Editorial notes for published reports

Notes for whoever edits a report next: the places where an earlier pass got something wrong, or
where the obvious summary is wider than the evidence. They live here rather than in each report's
frontmatter for two reasons.

**They are read by strangers.** A report's raw view is one click from any link to it, so anything
in the source is effectively published. A note written as an instruction — *"the summary must not
say X"* — reads in isolation as message discipline rather than accuracy, whatever its author
meant, and is quotable against the work. Every note below is therefore phrased as what the
evidence supports, which is the same constraint stated so that it survives being quoted.

**They outgrew the field they annotated.** These started as one-line traps beside a frontmatter
key and became an argument with a source path attached. That is a section, not an annotation.

They are worth keeping in some form: across the Valhalla report's ten passes, four errors were
caught because a note sat close enough to the body to contradict it — and one *was* the error,
having gone stale while the body moved on. Notes date; check each against the section it names
before trusting it, and correct it in the same pass that corrects the body.

---

## `2026-08-26-valhalla-carrier-sweep-on-an-off-heap-runtime.md`

### Scope of the conclusion

The arms cannot support a claim about Valhalla in general; keep the summary scoped to this class
of runtime. What the body establishes is narrower and stronger than a verdict on the feature: on a
runtime whose data lives off-heap behind a sealed, 9-leaf `MemorySegment`, the current model has
nothing to flatten, and the sweep is net-negative on footprint. §6 states that the arms cannot
speak for heap-resident workloads at all, which is most of the JVM ecosystem.

### The −1.21 % throughput result is not promotable

On the E→F leg its interval excludes zero by 0.09 pp, out of four independent tests on the same
six pairs. §3.2 declines to promote it and §2.3 shows the run-set drift that explains it. A
marginal exclusion under that much multiplicity does not support a finding, and the summary is
written accordingly.

### Which number travels alone

The +1.15 MB code-cache figure is the only headline whose interval is wide (CI [+5.93 %,
+7.63 %]) while its component, `adaptorCount`, is far tighter. That tightness is not a licence to
send the adapter count out on its own: it is campaign-specific, so best-attributed and most
portable point at different rows here.

When one number has to travel alone it is the **+0.18 MB of Metaspace at an unchanged
loaded-class count** — 6 of 6 pairs, interval excluding zero, attribution closed by the flat class
count, and the only finding §7 promotes.

### If the adapter count is quoted anyway

Quote it as **150**, do not call it deterministic, and do not let it travel without naming its
campaign. Two things bound it.

1. **The pair of values is not a property of the runtime.** Within campaign 20260818 each arm sits
   at one of two states 7 apart — E {820, 827}, D″ {805, 812}, F {970, 977} — but the
   `-Xlog:class+load` probe found D″ at 803 as well, so "one of exactly two values" describes the
   campaign's conditions. What *is* a runtime property is that the count is additive over the
   distinct **signatures** a conditionally-loaded cluster contributes. That unit is measured, not
   inferred: 60 classes sharing one signature cost 1 adapter, 60 classes with 60 uncached
   signatures cost 61 (`tools/probes/adapter-signature-unit/`). A third value therefore reads as a
   promotion of that model, not a retraction of it.
2. **The number is campaign-specific.** The telemetry-silenced campaign puts the same arms at
   E 828 / F 972, delta 144, so `adaptorCount` depends on the JFR configuration and the two
   campaigns' adapter figures are not comparable. Per-pair deltas in 20260818 are
   [150, 150, 150, 150, 157, 150]; 150 is the difference of the fullest observed states, and the
   mean 151.2 corresponds to no observation. See §4.1.

### Why `reproducibility_status: partial`

Deliberate, and the blockquote under the title states it in the rendered document too. Every
figure in §§2–4 was re-derived from
`results/raw/kernel-version-axis/20260818T062534Z-light-valhalla-carriers/` by an independent pass
over `result.json` and the JFR recordings, not read out of a prior analysis. §5's JDK-level facts
were measured on the same `/opt/jdk28` build that ran the arms.

What is *not* complete: §3 was re-measured on a second campaign (20260826T070108Z) after the first
proved to be a rotated 2 % tail, and the two are not poolable because silencing the kernel's JFR
telemetry also changes the workload — so the allocation delta rests on one campaign, not two
agreeing ones. No second person has re-derived anything.

---

## `2026-08-11-entity-read-by-id-spring-hosting-and-orm-axis.md`

### What the `summary` is written from, and why ×3.95 is not in it

The summary is written from §7.1 (service time), not from §4 (cost). ×3.95 is the most
quotable figure in the report and the body establishes that it holds on **neither** contract, so
the summary — the one surface that travels to aggregators, RSS and search detached from the
fences that qualify it — states what survives that detachment. This is a constraint on the
summary's accuracy when read alone, not on which findings the report carries: §4 and §5 carry
×3.95 in full, with its conditions.

### The Hibernate attribution is not resolved, and the summary must not resolve it

§5 states that attributing the gap to Hibernate specifically *"is not established by these arms"*,
and §8 carries the split as an open item. **"Largest identified contributor … split is
unmeasured"** is the strongest form the data supports. *"It is X rather than Y"* is not, however
much better it reads.

### There is deliberately no `claim_scope` field

Removed 2026-08-11. A whole-file claim scope is the wrong shape for a report, and for this one it
would be false in every available value. The file mixes 108 gated units that are
`comparison_eligible`; two pairs that are `non_eligible` **by design**, because they cross the
Pure-vs-Compat axis; an exploratory-class Amdahl derivation (§L3); and descriptive footprint data.
`comparison_eligible` would over-claim the compat pairs, `exploratory` would under-claim 108 gated
units, and any single value erases the axis separation the report exists to maintain.

Eligibility in this repo is a per-campaign, per-pair property, and it is stated at every data table
with its campaign id and unit count. That is where a reader should look, and a frontmatter field
that contradicts or flattens those statements is worse than no field. Nothing consumes it either:
`publish-report.sh` reads `claim_scope` from the **result JSON**, not from report frontmatter, and
`2026-06-20-entity-read-by-id-artifacts.md` already carries none.

### Why `reproducibility_status: complete` — read the definition before relying on it

Flipped 2026-08-12. Every headline figure was re-derived a second time directly from
`results/raw/entity-read-by-id/`, without reading this report's text, using independent queries
over the artefacts. That pass found one derivation error (§6 presented a telescoping identity as a
closure check), one mislabelled column (§7.1), and a set of scope and unit slips — all fixed, and
recorded in `docs/CLAIMS.md`'s retraction register (#18–#21) and in the report's revision history.

**What that is not: third-party review.** The re-derivation was performed on the author's side,
independently of the pass that wrote the prose, but not by an unaffiliated reviewer. An earlier
version of this note set the bar as "someone *else* re-derives" and then claimed the flip met
"exactly the condition this comment used to set" — an assertion of equivalence between *a second
pass* and *a second person* that the facts did not support. The bar is stated here as what was
done, not as what it sounded like.

Flip it back if the report gains a section that pass did not cover.
