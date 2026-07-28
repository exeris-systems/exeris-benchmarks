# Derived JFR views — heavy campaign (`fixed_contract_cross_runtime_h1_v2`)

Text renderings of the per-leaf JFR recordings, committed so the report's JFR-based findings are
reproducible from the repository alone (`reproducibility_status: complete`) without shipping the
raw recordings.

**Publication status: public-safe.** These are *derived* views (`jfr view … > .txt`), not raw
recordings. `scripts/publish-report.sh` in `public` mode default-denies raw JFR by both the
case-insensitive `.jfr` extension and the `FLR\0` content signature; neither applies here. The raw
`.jfr` files (~11 GB across both campaigns) stay on the perf box — that exclusion is size logistics,
and these are Community/open-core recordings, so it is not the Enterprise confidentiality rule.

**Naming:** `<workload>-p<pair><order>-<target>.<view>.txt`, e.g. `heavy-p1ab-exeris.hot-methods.txt`
= heavy campaign, pair 1, AB order, exeris-community arm.

**Views and what each supports in the report:**

| view | used for |
|---|---|
| `hot-methods` | §4 user-space CPU attribution (the frame shares quoted per stack) |
| `allocation-by-class` | §4 allocation view (Hibernate's `LinkedHashMap$Entry` tuple-map pattern) |
| `gc` / `gc-cpu-time` | §3/§5 GC rates and pause lengths under the budget-matched heap policy |
| `compiler-statistics`, `c2queue.summary`, `c2queue.raw` | §6 steady-state proof — the C2 compile queue must be empty across every measurement window |
| `thread-cpu-load` | §3 heavy bottleneck attribution (heavy pair-1 only) |
| `recording` | window bounds and rotation status |

**Coverage is partial and deliberate:** 7 leaves of 24 (both arms of heavy pair-1 AB, exeris heavy
pair-1 BA, Hibernate heavy pair-2 AB, plus the light counterparts in the sibling campaign) — the
leaves the report actually cites. Re-extracting the rest needs no benchmark re-run, only
`jfr view` over the recordings on the box.

**Read proportions within a recording, never sample counts across recordings.** Exeris's telemetry
overran the JFR `maxsize` cap, so its recordings retain only a steady-state tail (~221 s heavy,
~39 s light) while the Quarkus recordings span the whole leaf including that JVM's idle phase — the
denominators are not comparable (report §6, and the instrumentation caveat in §4).
