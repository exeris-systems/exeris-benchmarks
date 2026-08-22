# Shape A settle completion — 2026-08-22

Four rungs on `perf-box-amd64`, shape A (1 ms park), pool 256. Not another capacity ladder:
the brackets were already closed in `../20260821-shape-a-capacity/`. This run exists to
measure **post-load settle and retention** on the two arms the settle window never reached.

## Why these two arms

The settle window landed between ladder G, which had the Quarkus rung, and ladder H, which
did not. Ladders H and I were built to give the three arms that had never had a shape-A
rung their first one, so Quarkus was excluded — correctly for the question those ladders
asked — and so was exeris, whose bracket already existed. The result was fifteen settle
artifacts covering restate and both Axon arms, and none covering either the LRA coordinator
or the in-process engine.

That asymmetry is not neutral: it measures the resting cost of the other stacks and not our
own. 50/s is the one rate at which all five arms run clean, so the two 50/s rungs here
complete a five-arm comparable set. The second rung of each arm is its own ceiling rung.

## New in this run: the retention probe

`logs/post-load-retention.csv` and the `retention` block in `post-load-settle.json`. Once
the engines go quiet, the probe reads the cgroup `anon` / `file` split, requests a full GC,
and reads again. A resting footprint that survives a forced collection is retained state,
not uncollected garbage, and not reclaimable page cache. The target JVM is probed on the
same terms as any engine container — otherwise the arm whose saga engine runs in-process is
the one arm whose retention goes unmeasured.

## Results

| rung | verdict | settle | engine retention (anon, before → after GC) | target JVM RSS (before → after GC) |
|---|---|---|---|---|
| `exeris-community-r50-p256` | CLEAN | 609 s, **not settled** | no engine container | 347 → 322 MB |
| `quarkus-lra-jdbc-r50-p256` | CLEAN | 98 s, settled | coordinator 378 → **381 MB** | 505 → 446 MB |
| `exeris-community-r150-p256` | CLEAN | 610 s, **not settled** | no engine container | 410 → 395 MB |
| `quarkus-lra-jdbc-r70-p256` | FAILED (gate) | 98 s, settled | coordinator 319 → **320 MB** | 572 → 519 MB |

## Two limits of the instrument, not of the arms

**The settle gate never converges for an idle JVM.** Both exeris rungs hit the 600 s cap
with `settled=false`. The target JVM sat flat at 3.00–3.67 % for the whole window and never
cleared the 3.0 % idle threshold. The values are quantised at 0.33 % because a 3-second
sample at `CLK_TCK=100` resolves to one jiffy per 0.33 %, so 3.33 % is a tenth of a second
of CPU per three seconds — JVM background activity, not saga work. `settled=false` here is
a threshold artifact and must not be read as "this arm never goes quiet." The threshold
wants to be defined relative to the same process's pre-load baseline rather than as an
absolute percentage.

**The probe mixes two interfaces.** The target is measured as RSS from `/proc`, containers
as `anon` from their cgroup. RSS includes file-backed pages; `anon` does not. Comparisons
within one interface are clean — exeris's target against Quarkus's target. Summing across
them is not, and no figure here does.

## One figure retracted by this run

An ad-hoc terminal reading on 2026-08-21 put the coordinator at **1 055 MB anon** roughly
seventeen minutes after a 70/s rung, with a forced GC releasing nothing. This run, at the
same rate and nearly the same order count (8 341 against 8 403), measures **319 MB** ninety-
eight seconds after the load stops, with a forced GC releasing nothing.

The qualitative finding reproduces; the magnitude does not. The difference is the horizon.
Whether the coordinator continues to grow past the point where the settle gate declares it
quiet is now an open question that this window, by design, stops watching. The 1 055 MB
figure had no artifact and is not citable; the figures in the table above are.

## Run-to-run variance at the Quarkus ceiling

`quarkus-lra-jdbc` at 70/s **failed** here (0.74 % errors, gate fail) and **passed** in
ladder G at the same rate (0.44 % errors, gate pass). n=1 each way. The arm sits on its edge
at that rate and must be described that way.
