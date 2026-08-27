# What `adaptorCount` counts

Settles the unit of the `jdk.CodeCacheStatistics.adaptorCount` figure that
`results/reports/2026-08-26-valhalla-carrier-sweep-on-an-off-heap-runtime.md` §4.1 reports:
adapter **blocks**, cached by HotSpot's `AdapterHandlerLibrary` on a method's basic-type
signature fingerprint — **not** per class.

Four programs, identical except for how many distinct signatures they introduce. `run.sh`
compiles them, runs each three times under a JFR recording, and sums the last
`CodeCacheStatistics` sample's `adaptorCount` across code heaps.

Measured on `/opt/jdk28` (`28-ea+10-569`), the build the report's arms ran. Three runs per
condition, identical every time:

| program | classes | distinct signatures | adapters | Δ |
|---|---|---|---|---|
| `Baseline` | 0 | — | 375 | — |
| `SameSig` | 60 | 1 (`(int)int`) | 376 | **+1** |
| `DistinctSig` | 60 | 60 (arities 1–60) | 429 | **+54** |
| `HighArity` | 60 | 60 (arities 81–140) | 436 | **+61** |

Sixty classes cost one adapter when their signatures agree. `HighArity` uses arities far above
anything reached during bootstrap, so its signatures are certainly not already cached, and it is
the cleaner measurement of the rate — essentially one adapter per novel signature.
`DistinctSig`'s +54 is the same result with roughly seven of its low arities already resident.

Why it matters for the report: the seventh revision pass had read the probe's 2-class / 2-adapter
result as "one adapter per conditionally-loaded class". `SameSig` refutes that directly. The
report's model is now "additive over the distinct signatures a conditionally-loaded cluster
contributes".

Run: `./run.sh` (needs `/opt/jdk28`; edit `J=` for another build).
