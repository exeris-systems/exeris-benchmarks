# Source artifacts — *When throughput lies* (entity-read-by-id, 2026-06-20)

Reproducibility bundle for [the report](2026-06-20-entity-read-by-id-steady-state-and-cost-per-request.md).
Every run cited in the report ships its **structured** artifacts here so the numbers can be
re-derived independently. All runs: `entity-read-by-id`, `dev-laptop`, JDK 26, kernel `7.0.0-22`
(EEVDF), host-net unless the report says otherwise.

**Claim scope:** `exploratory` · **Reproducibility:** `complete` · **Comparison axis:** within-tier.

## What is included per run (under `results/raw/guided/<timestamp>/`)

| File | Purpose |
|---|---|
| `result.json` | normalized metrics (throughput, latency percentiles, errors) + run config + classification |
| `steady-state-evidence.json` | window-level throughput/latency for the **measured** window only (warmup excluded). **Note:** this file carries *no* compiler data — the warm/JIT signal lives in `c2-jit-evidence.json` (below) |
| `c2-jit-evidence.json` | **C2/JIT compiler signal distilled from the raw `.jfr`** (`tools/extract-c2-jit-evidence.py`): C1/C2 queue depth (live `max_live_queue_size` + cumulative `peak_queue_size`), tail-idle warm proof (`warm_at_window_end`), cumulative compile count + C1/C2 split + total JIT CPU time, code-cache/nmethod size, deopt count, and per-method `jdk.Compilation` counts. Carries a `jfr_retained.rotated` flag — see the C2/JIT caveat below |
| `h2load-latency.json` / `wrk2-latency.json` (+ `.raw.txt`) | derived percentiles; wrk2 carries `at_saturation` + `load_fraction` |
| `resource-metrics.json` | aggregated per run: `cpu_time_seconds` (the source for **CPU-per-request**), RSS (`peak_rss_kb`, `rss_kb_avg`, `smaps_rss_kb_max`), VmHWM, thread count, JVM heap used/committed/reserved — the **CPU-efficiency + memory-footprint** evidence |
| `env.json`, `reproducibility-metadata.json` | SHA, JDK/tool versions, JVM flags, hardware profile |
| `guided-run-profile.json` | affinity, network mode, warmup/measure, driver options |
| `postgres-version.txt`, `postgres-settings.tsv`, `pg_stat_statements-*.json` | DB-side reproducibility |
| `preflight-users-aggregate.json`, `users-endpoint-query-metadata.txt` | workload / dataset shape |

## What is **excluded**, and why

- **Raw `.jfr` recordings** — kept out of git for **size**, not confidentiality. These are
  Community / open-core recordings (the code is open; no Enterprise H3 / locality content), so
  they are not secret — but they are large and uneven: ~240–250 MB each for Exeris (its
  high-volume custom telemetry hits JFR's 250 MB `maxsize` cap), ~135–155 MB for Quarkus, ~62 MB
  for Spring — ~3.3 GB for the set, and git is the wrong place for that. The published form is
  the **derived** interactive flame graphs (`assets/flame-*.svg`);
  the raw recordings are available on request (or as download/release assets). The `.jfr`
  default-deny in `public` mode is the **Enterprise**-track confidentiality rule.
- **`h2load-requests.log`** (per-request `--log-file` dumps, 100+ MB each) and other `*.log` —
  excluded by size/`.gitignore`. The percentiles they feed are already in `h2load-latency.json`.
- **Per-sample sidecar CSVs** — `logs/target-pidstat.csv` (per-thread `%CPU`/`%wait`),
  `logs/host-mpstat.csv` (per-CPU `%sys`/`%soft`/`%wait` — the bridge-tax signal), and
  `resource-samples.csv` (the RSS time series). These are 20K–35K-row raw streams that dominate
  the diff; they are kept out of git for **size** (same policy as `.jfr`) and available on
  request. Everything cited in the report is derived from them into `resource-metrics.json`
  (CPU-per-request, peak RSS) and the steady-state/latency JSON, which **are** committed.

## C2/JIT evidence — what the `.jfr` actually proves (and what it doesn't)

`tools/extract-c2-jit-evidence.py <run-dir>` distills the compiler signal from each
raw `.jfr` into a committed `c2-jit-evidence.json`, so the report's `C2=0` / `C2 peak 97`
claims are reproducible without shipping the 250 MB recording. Read it with these limits in mind:

- **Rotation is asymmetric across targets, and the cap bites differently by run length.**
  JFR's `maxsize=250MB` rotates the oldest chunks first (the retained window always ends at
  run end). Exeris' high-volume custom telemetry emits **≈241 MB in ≈132 s** (≈1.8 MB/s, ~10×
  Quarkus, whose same-workload recording is 16–22 MB at 180 s / 150 MB at 900 s), so:
  - On the **long (900 s) runs**, the cap is badly insufficient: only the last ≈120–128 s of
    the **600 s measurement window** survives (`rotated:true`, `measurement_window_retained:false`).
  - On the **short (180 s) runs** the cap is sufficient *for the measurement window*: the
    retained ≈132 s covers the full 120 s measure plus ≈12 s of warmup tail
    (`rotated:true` **but** `measurement_window_retained:true`). Only ≈48 s of the early 60 s
    warmup ramp is lost. So "250 MB is enough for short Exeris runs" is true **for the measured
    window** — it is *not* true in the sense of "doesn't rotate": it still clips warmup.

  Quarkus/Spring never rotate here (`rotated:false`, full timeline). **Consequence:** the
  headline `C2=0` (Exeris) vs `C2 peak 97` (Quarkus) is **`max_live_queue_size`** — live queue
  depth *in the retained window*. On the long Exeris run that window is the warm tail only, so
  0 reflects "warm tail" as much as "low queue"; Quarkus' full window includes its warmup peak.
  Apples-to-oranges windows, not a like-for-like queue comparison.
- **What survives rotation and *is* a fair cross-target metric:** the cumulative
  `compiler_statistics_cumulative` counters (last-value-wins) — total compile count, C1/C2
  split, total JIT CPU time, nmethod/code-cache size — and `compiler_queue.*.peak_queue_size`
  (monotonic high-water). On those, Exeris is genuinely lighter but **not zero**: C2
  `peak_queue_size` ≈ **52–77** (Exeris) vs **90–125** (Quarkus); ≈ **7.0k** compiles /
  **19–22 s** JIT CPU (Exeris) vs ≈ **14k** / **48–56 s** (Quarkus) vs **19.6k** / **29 s** (Spring).
- **Warm proof that works for both:** `warm_at_window_end` = C2 live queue idle across the
  **last ≈30 s** of the retained series. It is `true` for every run here (both targets reach
  steady state); it does **not** depend on the rotation asymmetry above.
- **Per-method / inlining / tier-transition detail is mostly absent.** `jdk.CompilerInlining`,
  `jdk.CompilerPhase`, and `jdk.MethodTiming` are off in the recording profile (0 events).
  `jdk.Compilation` (duration-thresholded, heaviest compiles only) is present **only on
  non-rotated runs** — so per-method JIT data exists for Quarkus/Spring (and the short 0621
  runs below), but the Exeris long runs show `per_method=0` because that window rotated out.

### Companion short runs (0621) — non-rotated, capture the warmup ramp

The **60 s warmup / 120 s measure** runs from 2026-06-21 are short enough that — for
Quarkus/Spring — the recording stays well under the cap, and even for Exeris the retained
window covers the **full measurement window** (`measurement_window_retained:true`), unlike the
long runs. They carry the same `c2-jit-evidence.json`:

| Timestamp (UTC) | Target | JFR MB | rotated | meas. window retained | C2 peak | per-method compiles |
|---|---|---|---|---|---|---|
| `20260621T073250Z` | Quarkus | 22 | no | yes | 63 | 66 |
| `20260621T073641Z` | Exeris (Community) | **241** | **yes** | **yes** | 52 | 10 |
| `20260621T082946Z` | Quarkus | 22 | no | yes | 68 | 75 |
| `20260621T084522Z` | Quarkus (JDBC) | 16 | no | yes | 44 | 51 |
| `20260621T084337Z` | (aborted — no `.jfr`/`result.json`, env+profile only) | — | — | — | — | — |

`20260621T073641Z` (Exeris) emits **241 MB in ≈132 s** — so it still rotates ≈48 s of the 60 s
**warmup** off the front even at 180 s, but the retained 132 s does cover the full 120 s
measurement window. So 250 MB is "enough" for the *measured* window on a short Exeris run, not
enough to keep the warmup ramp. Fully capturing an Exeris warmup ramp requires either raising
`maxsize` (≈1.5 GB headroom for a 600 s run at ≈1.8 MB/s, or `maxsize=0`/`maxage`-bounded) or
trimming Exeris' custom JFR event volume in the recording profile.

## Run index

| Timestamp (UTC) | Target | Driver | Key figures (see report) |
|---|---|---|---|
| `20260620T111404Z` | Spring (reference) | h2load | 3 052 rps, CPU/req 0.956 ms |
| `20260620T114151Z` | Exeris (Community) | h2load | 8 844 rps, CPU/req 0.390 ms, C2=0 (live, retained tail — see caveat; C2 cumulative peak 52) |
| `20260620T121411Z` | Quarkus | h2load | 7 836 rps, CPU/req 0.552 ms, C2 peak 97 (live, full timeline; cumulative peak 101) |
| `20260620T123114Z` | Exeris | wrk2 | 75%-own-sat — p50 2.95, p99 8.19 ms |
| `20260620T123720Z` | Quarkus | wrk2 | 75%-own-sat — p50 9.03, p99 14.73 ms |
| `20260620T125344Z` | Exeris | wrk2 | matched 6 000 rps — p50 6.73, p99 18.05 ms |
| `20260620T130014Z` | Quarkus | wrk2 | matched 6 000 rps — p50 6.48, p99 46.78 ms |
| `20260620T134826Z` | Exeris | h2load | firm-up #1 — 9 454 rps, CPU/req 0.359 ms, RSS 0.961 GiB |
| `20260620T140518Z` | Quarkus | h2load | firm-up #1 — 8 158 rps, CPU/req 0.534 ms, RSS 3.446 GiB |
| `20260620T142125Z` | Exeris | h2load | firm-up #2 — 9 296 rps, CPU/req 0.358 ms, RSS 0.939 GiB |
| `20260620T143724Z` | Quarkus | h2load | firm-up #2 — 7 952 rps, CPU/req 0.550 ms, RSS 3.522 GiB |
| `20260620T145345Z` | Exeris | h2load | firm-up #3 — 9 373 rps, CPU/req 0.359 ms, RSS 0.992 GiB |
| `20260620T151001Z` | Quarkus | h2load | firm-up #3 — 8 096 rps, CPU/req 0.539 ms, RSS 3.405 GiB |
| `20260620T173152Z` | Exeris | h2load | **TLS control: cleartext** (`tls.enabled:false`, h2c) — 9 578 rps, CPU/req 0.337 ms, RSS 0.835 GiB |
| `20260620T174756Z` | Quarkus | h2load | **TLS control: cleartext** (`tls.enabled:false`, h2c) — 8 270 rps, CPU/req 0.513 ms, RSS 3.282 GiB |
| `20260620T180704Z` | Exeris | wrk2 | **latency TLS control: TLS on**, h1, 6 000 rps CO-corrected — p50 1.83, p99 5.53 ms |
| `20260620T184831Z` | Exeris | wrk2 | **latency TLS control: cleartext**, h1, 6 000 rps CO-corrected — p50 1.76, p99 4.80 ms |
| `20260620T183109Z` | Quarkus | wrk2 | **latency TLS control: TLS on**, h1, 6 000 rps CO-corrected — p50 1.75, p99 4.62 ms |
| `20260620T190612Z` | Quarkus | wrk2 | **latency TLS control: cleartext**, h1, 6 000 rps CO-corrected — p50 1.74, p99 4.38 ms |

The firm-up set (`…134826Z`–`…151001Z`) is interleaved A,B,A,B,A,B, host-net, warmed (C2=0),
target pinned `0-4` / driver `5-9`; **peak RSS** (firmed with throughput/CPU at n=3) comes from
each run's `resource-metrics.json` `peak_rss_kb`, at matched `-Xmx`. The **cleartext control pair**
(`…173152Z` / `…174756Z`) repeats the h2load comparison with TLS off (same warmup/pinning/host-net,
µs-scale connect) to show the throughput/CPU/RSS gap is provider-independent; the **latency TLS-control
quartet** (`…180704Z` / `…184831Z` / `…183109Z` / `…190612Z`) does the same for latency on **h1** (wrk2,
matched 6 000 rps, CO-corrected, TLS on vs off per stack) — both feed report disclaimer #6. Bridge-vs-host
(§2) and the warmup progression (§1) draw on additional earlier runs in the same session under
`results/raw/guided/`.

## Reproduce the headline numbers

```bash
# n=3 interleaved means ± CV%  (throughput + CPU-per-request)
tools/aggregate-runs.py results/raw/guided/{20260620T134826Z,20260620T142125Z,20260620T145345Z}   # Exeris
tools/aggregate-runs.py results/raw/guided/{20260620T140518Z,20260620T143724Z,20260620T151001Z}   # Quarkus

# Re-derive C2/JIT evidence from a run's raw .jfr (writes c2-jit-evidence.json into the run dir)
tools/extract-c2-jit-evidence.py results/raw/guided/20260620T121411Z   # Quarkus: C2 live max 97, cumulative peak 101
tools/extract-c2-jit-evidence.py results/raw/guided/20260620T114151Z   # Exeris (rotated tail): C2 cumulative peak 52

# Re-derive flame graphs from a raw .jfr (internal-only artifact)
tools/jfr-flamegraph.py <run>/target-*.jfr out.svg --title "..."

# Re-aggregate h2load percentiles from a raw --log-file (internal-only)
tools/aggregate-h2load-latency.sh <run>/h2load-requests.log
```
