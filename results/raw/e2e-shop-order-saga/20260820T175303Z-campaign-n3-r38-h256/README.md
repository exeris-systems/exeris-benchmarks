# Normative-rate campaign, n=3, heap tier 256m — 2026-08-20

Five arms × three repetitions on `perf-box-amd64`, CONTRACT-v2 shape B (`*_h1_park100_v3`,
100 ms park), at the normative arrival rate of §2. This is the campaign the contract is
built around; the shape-A ladders in the sibling directories are capacity exploration and
run at 50–200/s by design.

**This is the reference campaign of the pair.** A second campaign ran the same day and the
same shape at a wider heap — `../20260820T082846Z-campaign-n3-r38-h1024`, `MaxRAM=1024m
Xmx768m`. This one runs `MaxRAM=256m Xmx192m`, which is the tier every run from 2026-08-21
onward uses, so it is the one that composes with the later data.

## Configuration, read from `campaign-manifest.json`

| | |
|---|---|
| commit | `80330016` |
| arrival rate | 37.6–37.75 /s measured (§2 normative 38) |
| repeats | 3 per arm, 5 arms |
| graph track | `none` |
| fault mode | `terminal` |
| **db pool max** | **32** |
| **server CPU affinity** | **none** — no pinning was in effect |
| cgroup limits | none |
| heap | `MaxRAM=256m Xmx192m`, identical for every arm |

Note the pool: **32**, not the 256 that CONTRACT-v2 §9(f) pins for later campaigns. Anything
compared against these figures has to run at 32 as well.

## Validity screen

| arm | iterations | rate | dropped | iteration p95 | vus peak |
|---|---|---|---|---|---|
| exeris-community ×3 | 46 741–46 743 | 37.73–37.74 | 0 | 8355–8361 ms | 270–273 |
| restate ×3 | 46 742–46 743 | 37.74 | 0 | 8630–8648 ms | 281–283 |
| spring-axon-jdbc ×3 | 46 533–46 743 | 37.23–37.74 | 0 / **210** / 0 | 8493–9077 ms | 292–688 |
| spring-axon-embedded-jdbc ×3 | 46 581–46 743 | 37.61–37.75 | **162** / 0 / 0 | 8488–9012 ms | 283–555 |
| quarkus-lra-jdbc ×3 | 46 742–46 743 | 37.73–37.74 | 0 | 8632–8653 ms | 284–290 |

**Clear of the VU fence.** Thirteen of fifteen reps drop nothing, and iteration p95 sits in
the healthy 8.3–9.1 s band rather than the 23–30 s of a saturated arm. The two reps that
drop iterations lose ~0.4 % of them alongside a VU spike — transient, not systematic.

Campaign gate rollup: 14 pass, 1 fail (`quarkus-lra-jdbc-rep-3`, `compensation_mismatch`,
1397 against 1398 expected).

## One arm is behind the 415 fence

`quarkus-lra-jdbc` ×3 **must not be quoted from this campaign.**

The `@Compensate` callback was returning HTTP 415 — a class-level `@Consumes` reached the
callback method — so the LRA-driven compensation never executed. The fix is commit
`b0779716`, committed 2026-08-21 13:58 +0200. This campaign ran 2026-08-20 17:53 UTC.

The gate did not catch it, and the reason is recorded in the artifacts: all three reps carry
`domain_corroboration: null`, because that leg did not exist yet. The count leg passed on
1398 == 1398 — a **client-visible** token. `scenario.json` records the measurement taken the
next day on a clean no-crash run of the same arm: *"311 declines, 310 client-observed
COMPENSATED, gate PASS, and 0 CANCELLED / 0 PAYMENT_REFUNDED / 0 ORDER_COMPENSATED in the
store — this arm reports a compensation it does not perform."*

So reps 1 and 2 passing means the client saw the word, not that the backward-recovery path
ran.

**The other four arms stand.** Their gates pass on the same count leg, and for them the count
leg was never in question — the fence is specific to the LRA callback.

## Re-run

`../saga-campaign-fence-rerun-*` re-runs `quarkus-lra-jdbc` ×3 with the fix, and
`exeris-community` ×3 beside it as a **control**. Re-running the broken arm alone would be a
cross-day comparison against four arms measured on 08-20; the control tests that assumption
instead of adopting it. If exeris reproduces its figures here, the cross-day comparison is
validated and the three untouched arms stand. If it does not, the campaign needs redoing in
full — and we will know rather than assume.
