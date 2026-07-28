# Derived JFR views — light campaign (`fixed_contract_cross_runtime_h1_single_read_v1`)

Text renderings of the per-leaf JFR recordings, committed so the report's JFR-based findings are
reproducible from the repository alone (`reproducibility_status: complete`) without shipping the
raw recordings. Companion set for the heavy campaign lives in
`../../20260721-121745-full-triad-ab-ba/jfr-views/`, which carries the full view-by-view index.

**Publication status: public-safe.** Derived views (`jfr view … > .txt`), not raw recordings —
`publish-report.sh` in `public` mode default-denies raw JFR by the `.jfr` extension and the `FLR\0`
signature; neither applies. Raw `.jfr` stays on the perf box (size, not confidentiality — these are
Community/open-core recordings).

**Naming:** `light-p<pair><order>-<target>.<view>.txt`.

**What these support:** §2's light-contract profile (Exeris's flat infrastructure-shaped profile with
no frame above 7 %; the Quarkus arms' framework bookkeeping — Narayana/Arjuna JTA records on the hot
path of a read, ARC scope checks, URI parsing), §5's GC rates, and §6's steady-state proof via the
C2 compile-queue views.

**Caveat that travels with every number here:** Exeris's high-volume telemetry overran the JFR
`maxsize` cap, so its light recording retains roughly the last **39 s** of its measurement window
while the Quarkus recordings span the whole leaf. Proportions within one recording are readable;
sample counts across recordings are not comparable (report §6).
