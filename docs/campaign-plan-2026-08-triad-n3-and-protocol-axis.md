# Campaign plan — triad n=3 (H1) + protocol axis (H2c, H2-over-TLS)

**Status:** plan / not yet executed · **Hardware:** `perf-box-amd64` · **Scenario:** `entity-read-by-id`
**Supersedes nothing.** Firms up [2026-07-21 triad](../results/reports/2026-07-21-entity-read-by-id-tuned-pg-triad-comparison-eligible.md) (n=1) and opens the protocol axis, which has **zero** data today.

---

## 0. Executability summary — read this first

| # | Campaign | Gate-eligible today? | Blocker |
|---|---|---|---|
| **C1** | H1 triad, n=3, both contracts | **Yes** — configuration only, no code | — |
| **C2** | H2c, n=3 | **No** | wrk comparative driver is h1-only; asset matrix declares every target `protocol_mode: h1` |
| **C3** | H2-over-TLS, n=1 (cost probe) | **No** | C2's blockers **+** no TLS axis in `run-comparative.sh` **+** `quarkus-tuned` VT×TLS crash risk |

C1 can start on the box as soon as the disk budget in §3.5 is settled — `scripts/run-entity-read-by-id-triad-n3.sh` is ready. C2/C3 need the harness work in §2 first — they cannot be forced through by relabelling, and the guards that stop them are correct.

**Decision (2026-07-31):** C2 will be built as a **gated** campaign (§4.1 Option B), not run exploratorily. The harness work is scheduled in §7 and is independent of C1's box time.

---

## 1. What each campaign is allowed to claim

| Campaign | Licenses | Explicitly does **not** license |
|---|---|---|
| C1 | Everything the 2026-07-21 report claims, at n=3 instead of n=1, **plus** the first DB-config-fingerprint-gated evidence for those claims | Anything about H2/H3, TLS, native-image, real network |
| C2 | H1-vs-H2c protocol delta **within one driver** (h2load), per stack | Any comparison against C1's wrk numbers — different driver, different contract windows |
| C3 | Cleartext-vs-TLS cost **at H2, within one driver**, per stack | A shared-TLS-provider claim (Exeris `OffHeapTlsEngine` vs Quarkus BoringSSL vs Spring JSSE are three different engines); any RSS comparison against C1 (see §5.3) |

`track_id` is an isolation boundary. **C1, C2 and C3 are three separate tracks and are never aggregated.** The h2c contract already carries `comparison_policy: forbidden_cross_protocol` with the note *"H2c and H1 results are not comparable. Do not compare this contract's results to any H1 wrk or wrk2 contract results."* That constraint is load-bearing for the whole plan — see §4.2.

---

## 2. Harness blockers (C2/C3) and the work they imply

### 2.1 The wrk comparative driver serves h1 only

`scripts/run-comparative.sh:92` — `COMPARATIVE_DRIVER_PROTOCOL_ALLOWLIST` defaults to `h1`. Guard (iv) at :2347 refuses any axis-derived protocol outside it:

```
CONFIG_ERROR: effective protocol_mode=h2c is not served by the wrk comparative driver
  ... refusing a label-only claim [rejection_code=PROTOCOL_DRIVER_UNSUPPORTED]
```

This guard is **right** and must not be widened by env override. wrk 4.1.0 has no HTTP/2 implementation whatsoever; raising `BENCH_COMPARATIVE_PROTOCOL_ALLOWLIST` would mint exactly the label-only h2c claim the guard exists to prevent — an h1 run wearing an h2c label.

**Required work:** an h2load-backed comparative path that emits the four strict-gate artefacts (`stage7-gate-report.csv`, `stage7-gate-summary.json`, `claim-status.json`, `rejection-codes.json`). Today `scripts/run-entity-read-by-id-h2load.sh` hardcodes `--claim-scope exploratory` and produces none of them.

### 2.2 Every target is declared `protocol_mode: h1` in the asset matrix

Guard (v) at :2357 ties the effective protocol to the resolved target-native protocol:

```
CONFIG_ERROR: effective protocol_mode=h2c does not match resolved target-native protocol=h1
  ... the run axis may not relabel a target's native protocol [rejection_code=PROTOCOL_TARGET_MISMATCH]
```

All 11 rows in `runtime/drivers/target-asset-matrix.json` say `h1`. The `exeris-community` row's own note says H2c/H2-TLS "are reached via the run-guided protocol+TLS override axis, not via a separate target_id" — but the *comparative* path asserts against the matrix, so guided's override never reaches it. The two paths disagree and that disagreement must be resolved deliberately, not patched around.

**Good news — the targets themselves are ready.** All three arms can already serve h2c today:

| Target | h2c switch | Source |
|---|---|---|
| `exeris-community` | `EXERIS_HTTP_MAX_VERSION=HTTP_2` + `EXERIS_HTTP_H2C_UPGRADE_ENABLED=true` | proven by `exeris-e2e-runtime.env` (saga runs h2c) |
| `quarkus-hibernate` / `quarkus-tuned` | `EXERIS_HTTP2_ENABLED=true` (already the default) | `quarkus-runtime.env:28` — `TARGET_PROTOCOL=h2c` |
| `spring-hibernate` | `EXERIS_HTTP2_ENABLED=true` | `spring-runtime.env:23` — `TARGET_PROTOCOL=h2c` |

So the blocker is **entirely harness-side**. No target work is needed for C2.

### 2.3 No TLS axis in the comparative path

`tls_mode` / `TLS_MODE` appears only in `scripts/run-guided.sh`. `run-comparative.sh` has no TLS knob at all. The 2026-07-22 TLS-tax campaign got its TLS legs through the *constrained/exploratory* path, not the gated one.

### 2.4 `quarkus-tuned` on H2-over-TLS is a known crasher

`quarkus-tuned` = pure JDBC + `@RunOnVirtualThread` + native epoll + **native BoringSSL**. That is precisely the combination that trips **JDK-8377715** (Loom × C2) on JDK 26 under h2-over-TLS. Cleartext h1/h2c is stable (3/3) with full C2; TLS-on-virtual-threads is not.

**Consequence for C3:** plan for `quarkus-tuned` to fail the TLS leg. Do **not** downgrade the box to JDK 25 to make it pass — that breaks JDK-version equivalence with C1/C2 and invalidates the whole comparison. Options, in order of preference:

1. Run C3 with `exeris-community` + `quarkus-hibernate` (default JSSE, no VT×BoringSSL path) and record `quarkus-tuned` as **`oom_is_a_result`-style honest exclusion** with the JBS id.
2. Add `quarkus-benchmark-app-jdbc-jsse` as the TLS-leg stand-in — but then the TLS engine axis changes (JSSE, not BoringSSL) and it is a *different target*, so it may not inherit `quarkus-tuned`'s label.

Either way the exclusion is reported, not hidden.

---

## 3. C1 — H1 triad, n=3 (executable today)

### 3.1 Corrections from the triad + sweep reports, and their status

| # | Correction | Source | Status | Action for this campaign |
|---|---|---|---|---|
| 1 | pgss "post-measurement" snapshots captured against the *next* pair's fresh Postgres → unusable | triad bug 1 | **Fixed** in `run-comparative.sh` (per-target measurement-window baseline/final/delta, :2948–3089) | Verify all three delta files are non-empty per leaf |
| 2 | Stale `READ_TOP_USERS_JSON_SQL` label in DB-diagnostics metadata | triad bug 2 | Fixed forward | Spot-check one artefact |
| 3 | `sar` 10-min cadence too coarse for the window; 2/24 windows had no attribution | triad bug 3 | **Fixed** — 1 s mpstat sidecar bracketed to each target's measurement window (:2996) | Confirm `db-cpu-mpstat` CSV present per leg |
| 4 | Exeris JFR `maxsize` rotation kept only a tail | triad bug 4 / §6 | **Fixed** — `BENCH_JFR_MAX_SIZE_MB=6144`, non-rotating | Keep default; see disk budget §3.5 |
| 5 | Strict gate could not see DB client config → fetch-config inverted a published verdict three times | triad bug 5 | **Fixed** (`518b23c`) — per-arm DB-config fingerprint, fails closed | **This is the headline upgrade: the published triad predates the gate. C1 is the first campaign actually gated on it.** |
| 6 | n=1 per (pair × order) | triad *Limitations* | **This campaign** | n=3 |
| 7 | ~8 % cold-cache penalty for whichever stack ran first in leaf 1 | triad *Limitations* | **Open** | Add a pair-level DB warm-through before leaf 1 (§3.4) |
| 8 | Repeats must be spread in time — repeat is the **outer** loop | sweep *Methodology* | **Open — `run-full-triad-ab-ba.sh` gets this wrong** | `run_pair_block` iterates `run_num` *inside* the pair (:877), so n=3 gives pair1×3 back-to-back. Invert via three outer invocations (§3.3) |
| 9 | Order-effect bound ≤ ~2 % | sweep *Controls* | **Throughput only** | Do **not** reuse this bound for RSS — the same control read **+13.5 %** on RSS. Quote the bound on the axis it was measured on |
| 10 | Harness noise floor 0.14 % rps / 0.30 % cpu/req | sweep *Controls* | Available | Read n=3 spreads against this, not against zero |
| 11 | Closed-loop wrk percentiles are CO-affected queue readings | triad *Fairness posture* 4 | Standing | Quote §2/§3 percentiles as queue shape only; service time needs the separate wrk2 open-loop curve |
| 12 | RSS minus declared heap is meaningless without `AlwaysPreTouch` | sweep + triad §5 | Standing | Any footprint decomposition must use NMT `committed` + `smaps` Rss per region |

### 3.2 Configuration — inherited verbatim from 2026-07-21

Changing any of these breaks continuity with the published report, which is the whole point of the campaign.

```bash
export HARDWARE_PROFILE=perf-box-amd64
export BENCH_DB_TUNED=1                      # host-networked PG, cpuset 4-7,12-15, asserted fail-closed
export BENCH_SERVER_CPU_AFFINITY="0-1,8-9"
export BENCH_LOADGEN_CPU_AFFINITY="2-3,10-11"
export BENCH_TOTAL_MEMORY_MB=2048            # equal budget, per-stack heap split below
export BENCH_EXERIS_HEAP_MB=256
export BENCH_QUARKUS_HEAP_MB=1280
export BENCH_DB_POOL_MIN_SIZE=16
export BENCH_DB_POOL_MAX_SIZE=256
export BENCH_ENABLE_NATIVE_MEMORY_TRACKING=1
export BENCH_NATIVE_MEMORY_TRACKING_LEVEL=summary
export BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS=1
export BENCH_TRIAD_PAIRS="1-exeris-vs-quarkus-tuned:exeris-community:quarkus-tuned:1:9000:9003;2-exeris-vs-quarkus-hibernate:exeris-community:quarkus-hibernate:2:9000:9002;3-quarkus-hibernate-vs-tuned:quarkus-hibernate:quarkus-tuned:3:9002:9003"
```

Contracts (windows 300 s warmup / 900 s measurement, `_v2`):
- light single-read — `fixed_contract_cross_runtime_h1_single_read_v1`
- heavy aggregate — `fixed_contract_cross_runtime_h1_v2`

### 3.3 Repeat structure — repeat as the OUTER loop (correction #8)

`BENCH_RUNS_PER_PAIR=3` would run the three repeats of a pair back-to-back, which controls nothing that matters: the sweep made repeat the outer loop precisely so each (pair, arm) sample is spread across hours. The campaign is therefore invoked once per repeat with `BENCH_RUNS_PER_PAIR=1`.

**Runner:** `scripts/run-entity-read-by-id-triad-n3.sh` — implements the outer loop, the config in §3.2, the warm-through, and the JFR containment in §3.5.

```bash
./scripts/run-entity-read-by-id-triad-n3.sh --dry-run     # schedule + preflight, measures nothing
./scripts/run-entity-read-by-id-triad-n3.sh               # full campaign
./scripts/run-entity-read-by-id-triad-n3.sh --repeats 03  # resume a single repeat
```

It writes `campaign-manifest.json` at the root recording repeat-loop position, JFR retention rule, warm-through seconds, pair set and commit SHA, so the report never has to reconstruct how the run was configured.

**Two supporting changes landed in `run-full-triad-ab-ba.sh`, both opt-in and no-ops when unset**, so `run-entity-read-promotion-ab-ba.sh` and `run-entity-read-by-id-latency-curve-triad.sh` are byte-for-byte unaffected:

- `BENCH_REPEAT_ID` — folds the repeat into `track_id`. Without it, three invocations at `BENCH_RUNS_PER_PAIR=1` all mint `track-<order>-01`, leaving the repeats indistinguishable in the artefacts. Since `track_id` is an isolation boundary, that is a silent-pooling hazard, not a cosmetic issue.
- `BENCH_PAIR_WARM_THROUGH_SECONDS` — the §3.4 warm-through hook.

Aggregate across `repeat*/` at report time; report **medians**, and state the per-cell spread against the 0.14 % noise floor.

### 3.4 Cold-cache warm-through (correction #7)

Before leaf 1 of each pair block, drive the endpoint against **both** arms for a short discarded window so neither stack pays the ~8 % first-touch penalty. Today the harness warms per-leg only, which leaves the pair's first stack absorbing the cold PG cache. Simplest honest form: a discarded pre-leaf warm pass at the same concurrency, logged as `warm-through` and excluded from all artefacts.

### 3.5 Time and disk budget — decide before launching

**Time.** Per leaf = 2 targets × (300 s + 900 s) ≈ 40 min of measurement, ~45 min with startup, readiness, JFR dump and diagnostics.

```
3 pairs × 2 orders × 2 contracts × 3 repeats = 36 leaves
36 × ~45 min ≈ 27 h measurement, ~30 h wall clock with infra prep and cooldowns
```

The published n=1 campaign was 12 leaves ≈ 8 h, which corroborates the per-leaf figure. **Plan for a ~30 h box reservation**, or split by contract across two days (light day / heavy day) — the contracts are separate isolation keys anyway, so splitting them costs nothing.

**Disk — this is the binding constraint.** `run-full-triad-ab-ba.sh:57` warns that complete light recordings are ~2–3 GB per target per leaf:

```
light : 3 pairs × 2 orders × 3 repeats × 2 targets = 36 dumps × 2-3 GB ≈  72-108 GB
heavy : 36 dumps × <1 GB                                              ≈      36 GB
                                                                  total ≈ 110-145 GB
```

**Do not solve this by lowering `BENCH_JFR_MAX_SIZE_MB`** — that reintroduces bug 4 (rotation keeps only a tail) and would silently un-fix a correction this campaign is supposed to honor. **Do not solve it by enabling JFR on repeat 1 only** — JFR has overhead, so repeats would no longer be same-config and the medians would be meaningless.

Correct fix: keep JFR configuration **identical across all 36 leaves**, and prune the raw artefact after per-leaf extraction:

```bash
tools/extract-jfr-metrics.sh <leaf>.jfr <leaf>-jfr-metrics.json   # derived metrics stay
```

Retain raw `.jfr` for a fixed, declared subset (suggestion: repeat01 of each (pair, contract) = 12 files ≈ 30 GB), archive the rest off-box, and **state the retention rule in the report**. Raw JFR stays out of git regardless — for size, and because `publish-report.sh` default-denies it in `public` mode.

### 3.6 Per-leaf acceptance checks

- `claim-status.json` = `comparison_eligible`; `stage7-gate-report.csv` all-pass; `rejection-codes.json` empty
- `db_config.status` = `ok` in `fairness-index.json` (**new gate** — correction #5)
- `pg_stat_statements-measurement-delta.json` non-empty for both targets
- `db-cpu-mpstat` CSV present and covering the full window
- JFR steady-state witness: C2 queue drained inside warmup, `settled=true`
- `track_id` identical across all 36 leaves

---

## 4. C2 — H2c, n=3

### 4.1 Fork: gated or exploratory — **decided: Option B (gated)**

> **Decision (2026-07-31):** C2 is built as a gated campaign. The exploratory path stays documented below as the fallback if the harness work slips, but it is not the plan of record.

| | Option A — exploratory | Option B — gated |
|---|---|---|
| Path | existing `run-entity-read-by-id-h2load.sh` + `fixed_contract_h2c_h2load_exploratory_v1` | new h2load comparative path |
| Runs today | **Yes** | No — needs §2.1 + §2.2 |
| Claim scope | `exploratory`, `comparison_policy: forbidden_cross_protocol` | `comparison_eligible` |
| Windows | 60 s warmup / 120 s measurement | would inherit 300/900 |
| Effort | zero | asset-matrix h2c rows + gate-artefact emission in the h2load runner + allowlist widened *only* once the driver genuinely speaks h2c |
| Wall clock | 3 targets × 2 protocols × 3 repeats × 180 s ≈ 1 h measurement, ~4 h realistic | ~30 h, same shape as C1 |

Option A answers *"does H2c change the picture, and roughly how much"* for the price of an afternoon. Option B answers *"by how much, certifiably"* for the price of another full box reservation plus harness work.

### 4.2 The one fairness rule that matters here

**The H1 control must run on h2load too.** Comparing an h2load h2c number against C1's wrk h1 number measures the driver difference, not the protocol difference — and the contract itself forbids it. Every C2 run is therefore a pair:

```bash
./scripts/run-entity-read-by-id-h2load.sh --axis h1  --profile perf-box-amd64 --target-runtime <t>   # control
./scripts/run-entity-read-by-id-h2load.sh --axis h2c --profile perf-box-amd64 --target-runtime <t>   # treatment
```

The reportable quantity is the **within-driver, within-stack h2c/h1 ratio**. Those ratios may then be compared across stacks; the absolute levels may not be compared to C1.

### 4.3 Controls inherited from C1

Same cpusets, same 2 GiB budget and heap split, same pool 16/256, same tuned-PG isolation, same DB-config equalization, repeat as outer loop, warm-through before the first leg. Record `max_concurrent_streams` actually used (contract default 10) in every artefact — the contract note explicitly asks for it.

---

## 5. C3 — H2-over-TLS, cost probe

### 5.1 Design: the control is h2c, not h1

The question is *"what does TLS cost at H2"*. That is a cleartext-vs-TLS delta at fixed protocol and fixed driver — exactly the shape the 2026-07-22 TLS-tax campaign used at H1 (2 modes × 2 arms × 3 interleaved repeats, 12/12 clean). Reuse that design at h2c/h2.

### 5.2 Verify you actually got TLS

h2load over `https://` is h2-over-TLS; over `http://` it is real cleartext. **Check connect times to prove which one ran** — TLS connect lands in milliseconds, cleartext in microseconds. Record the observed protocol and connect distribution per run; a label alone is not evidence.

### 5.3 Exeris crypto subsystem changes the footprint

The cleartext campaigns run `EXERIS_SUBSYSTEMS=http,persistence` with crypto **off**. The TLS legs must load `http,persistence,crypto`. That is the correct choice for a TLS run — and it means **C3's Exeris RSS is not comparable to C1's or C2's**. State it in the report rather than letting a reader diff the tables.

### 5.4 Engine labels are mandatory and are not shared

Three different TLS engines: Exeris kernel `OffHeapTlsEngine`, `quarkus-tuned` netty-tcnative/BoringSSL, `quarkus-hibernate`/Spring JSSE. There is no shared provider, so per-arm engine labels are required on every row, and the pairing must be named (native-vs-native, or native-vs-JSSE). Same certificate on all arms; record the fingerprint.

Prior art to stay consistent with: at H1 the TLS tax was **+0.0069 ms/req (Exeris OffHeapTlsEngine) vs +0.0040 ms/req (BoringSSL)** — Exeris pays the larger tax, native-vs-native. C3 should be read against that, and any H2 result that contradicts it needs explaining rather than quiet publication.

### 5.5 Expected casualty

Per §2.4, plan for `quarkus-tuned` to crash on the TLS leg (JDK-8377715). Record the crash as a result with the JBS id, exclude the arm, and do not change the JDK.

---

## 6. Reporting gates (all three campaigns)

- Tier / protocol mode / benchmark family / comparison axis labelled explicitly; `track_id` stated and never crossed
- Pure vs compat separated; no Enterprise/H3/locality leakage
- Reproducibility metadata complete: SHA, JDK + tool versions, JVM flags, hardware profile, scenario id, jar hashes
- Percentile provenance stated per table (closed-loop = queue shape; open-loop = service time)
- Any bound quoted on the axis it was measured on (correction #9)
- **All four summarizing surfaces swept** when any section changes — frontmatter `summary:`, TL;DR, revision history, conclusions. A summary must not strengthen the body's quantifier
- `publish-report.sh --publication-mode public` (default); raw `.jfr` stays out

---

## 7. Order of work (as decided 2026-07-31)

1. **C1 — run it.** Zero blockers; `scripts/run-entity-read-by-id-triad-n3.sh` is ready. Settle the disk budget (§3.5) first; the wrapper's preflight enforces a 120 GB floor.
2. **C2 harness work — build the gated h2load comparative path** (§2.1, §2.2). This is the long pole and is independent of C1's box time, so it can proceed while C1 measures. Scope:
   - h2c rows in `runtime/drivers/target-asset-matrix.json` (targets already serve h2c — §2.2)
   - gate-artefact emission in the h2load runner: `stage7-gate-report.csv`, `stage7-gate-summary.json`, `claim-status.json`, `rejection-codes.json`
   - widen `COMPARATIVE_DRIVER_PROTOCOL_ALLOWLIST` **only after** the driver genuinely speaks h2c — the guard is the last thing to touch, not the first
   - an h2c fixed contract at 300/900 windows, so C2 is not additionally confounded by window length
3. **C2 — run it**, ~30 h, with the h1 control on the same driver (§4.2).
4. **C3** — after C2, reusing its h2c control and driver wiring; plan for the `quarkus-tuned` TLS casualty (§2.4, §5.5).
