# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`exeris-benchmarks` is a benchmark and performance-validation lab for Exeris runtimes — JMH microbenchmarks, HTTP load scenarios (wrk/wrk2/h2load/k6), compatibility-cost reports, env capture, and history baselines. It is **not** a guard-test repo and does not gate merges into product repositories.

### Repository boundary rule (do not violate)

- Guard / perf-contract tests stay in product repos (`exeris-kernel`, `exeris-spring-runtime`, enterprise repos). Examples: allocation guards (`alloc/op <= threshold`), latency merge gates, classpath/architecture invariants.
- Exploratory / cross-repo / history benchmarks live here. Examples: kernel-vs-spring-runtime comparisons, pure-vs-compat overhead, release/history trends, richer JMH/wrk/h2load/k6 suites.

If a proposed change answers *"can this be merged safely?"* it belongs in the product repo, not here.

## Core operating constraints

These come from `.github/copilot-instructions.md` and `.github/instructions/*.md`. Apply them to every change.

- **Mission**: design, implement, verify, and report benchmarks fairly, reproducibly, and honestly. **Non-goal**: optimizing to prove Exeris is "fast".
- **Mandatory separation axes** — never collapse without explicit caveat:
  - Community vs Enterprise
  - H1 vs H2 vs H3
  - Pure vs Compatibility
  - Micro vs Runtime benchmark families
  - Guard/Regression vs Exploratory runs
- **Fairness**: matched payload, concurrency, protocol mode, and target scope before any cross-target claim. Reject apples-to-oranges comparisons.
- **Reproducibility**: every result must capture commit SHA, JDK/tool versions, JVM flags, hardware profile, scenario id, and target classification.
- **Evidence-bounded conclusions**: do not state more than the data supports. Separate descriptive metrics from causal claims.
- **Confidentiality**: treat raw JFR / flamegraphs / diagnostics as potentially sensitive. Do not leak Enterprise internals (H3, locality, enterprise targets) into public-track artifacts. The default publication mode is `public`, which default-denies raw `.jfr` (case-insensitive extension and `FLR\0` content signature).
- **Enterprise-vs-public scoping**: `targets/exeris-community-app-locality/`, the `enterprise/` tree, and H3 behavior are **excluded from the runnable/public docs path**. Operational docs (README, `docs/`) cover Community and cross-runtime tracks only. Do not promote enterprise-only behavior into Community-labeled reports.
  - **`spring-on-exeris*` is NOT excluded** (corrected 2026-08-11). This rule previously also named `targets/exeris-spring-runtime-benchmark-app-comp/` — a path that never existed in this repo (the target is `targets/exeris-spring-runtime-app-comp/`), added incidentally in an unrelated PR, with no rationale recorded anywhere in `docs/` or `.github/`. Exeris Spring Runtime is a product repo, listed above alongside `exeris-kernel` and *separately from* "enterprise repos"; it has never been confidential. Every `spring-on-exeris*` arm is `tier=community` in the pair manifest and is **publishable**.
  - **Do not confuse a separation axis with a confidentiality boundary.** Pure-vs-Compatibility is a *labelling* rule ("never collapse without explicit caveat"), exactly like H1-vs-H2 and Micro-vs-Runtime — compat results must be labelled compat, stored separately, and routed to the `compat/` track, **not** withheld from publication. The confidentiality rule is the separate bullet above and covers raw JFR/diagnostics plus Enterprise internals (H3, locality, enterprise targets). This same over-application has now happened twice: once to raw JFR for Community/open-core arms, once here. When a rule written for Enterprise appears to cover an open-core artifact, check whether it names it *by intent* or only *by adjacency*.

## Comparative-result strict gate (runtime track)

Comparative runtime runs **fail closed**. Any comparative output directory must contain:

- `stage7-gate-report.csv` (`scope,gate_id,gate_name,pass_fail,rejection_code,...`)
- `stage7-gate-summary.json`
- `claim-status.json` (final status: `comparison_eligible` or `non_eligible`)
- `rejection-codes.json`

Comparative math is valid **only** when `claim-status.json` is `comparison_eligible` AND strict gates pass. `track_id` is an isolation boundary — never aggregate across mixed tracks. Report outputs must include explicit axis labels and the track label.

## TLS comparator labels (B3/B4/B5/B6/B7)

Used in JMH TLS work and reports. Do not collapse rows across these without stating wiring differences.

| Label | Meaning |
|---|---|
| `B3` | JDK `SSLEngine` baseline (direct) |
| `B4` | Netty `SslHandler` + `EmbeddedChannel` over netty-tcnative (pipeline path; not split into B4a/B4b) |
| `B5` | Exeris `OffHeapTlsEngine` engine-level lens via neutral in-process Memory-BIO harness |
| `B6` | Exeris SPI-native `TlsEngine` under FD-owner ownership model — real loopback socket (includes kernel I/O) |
| `B7` | Exeris Memory-BIO path (in-process) |

Primary engine-level comparator set is **B3/B4/B5**; `B6` is integration-level with explicit transport-wiring caveats. Required per row: buffer model, transport model, and allocator model labels (GC-managed / pooled-direct / off-heap). Cross-row claims require: ops/s, sample-time latency (p50/p95/p99), `gc.alloc.rate.norm`, JFR `ObjectAllocationSample` stacks, CPU hotspot profile, RSS + native footprint snapshot, and RSS@`@Setup`-end vs RSS@measurement-end delta.

TLS provider/memory/cert config uses tier-specific-then-global precedence (`exeris.tls.<tier>.X` → `exeris.tls.X`, with a backward-compatible alias chain — see `micro/jmh/README.md`).

## Architecture (big picture)

The repo is a **layered harness around external target apps**, not a product.

Layer responsibilities:

- **`schemas/`** — JSON Schemas every result/env/comparative artifact must validate against. Touching artifact shape almost always means touching a schema.
- **`scenarios/<name>/`** — framework-agnostic workload definitions (path/payload/concurrency). Configs per driver: `wrk.lua`+`wrk.env`, `k6.js`, `h2load.flags`, `hyperfoil.yaml`. Scenario catalog is `docs/scenario-catalog.md`.
- **`runtime/drivers/`** + **`scripts/run-*.sh`** — execution harnesses (wrk, wrk2, h2load, k6, Hyperfoil, custom probes) that drive a scenario against a *pre-launched* target.
- **`targets/`** — runnable benchmark apps. Targets are launched externally (the harness does not start them); `targets/launcher-sync-wrapper.sh` only synchronizes readiness for two pre-launched targets and writes timestamps. Common contract: `EXERIS_DB_*`, `EXERIS_PORT`, `java -jar target/<artifact>.jar`.
- **`micro/jmh/`** — standalone Maven module producing `target/benchmarks.jar` (uber-jar with JMH launcher). It imports Exeris artifacts as dependencies and contains no product source. Stubs marked `// TODO: replace with ExerisXxx(...)` are intentionally wired against snapshots from GitHub Packages.
- **`compat/`** — pure-mode vs compatibility-mode overhead measurements; results from the two modes **must be stored separately** and labeled.
- **`results/`** — `raw/` holds unmodified tool output and is committed for traceability; the sibling directories are derived or per-track archives.
- **`baselines/<repo>/<mode>/<hardware>.json`** — regression references. Update policy in `docs/regression-policy.md`. **Never** update silently to hide a regression.
- **`tools/`** — `tools/bench/` manifest-driven runners (TLS/JMH), `tools/matrix/` matrix manifests, plus standalone helpers.
- **`enterprise/`** — parallel tree mirroring the public one, for the Enterprise track. Subject to confidentiality guard; not part of the public docs path.

The cross-cutting invariant: **every artifact must be traceable to a scenario id, target classification, tier, protocol mode, and reproducibility metadata**. The schemas in `schemas/` enforce this — if you find yourself wanting to skip a field, fix the schema or fix the data, don't bypass the validator.

## Common commands

Concrete invocations — JMH, GitHub Packages auth, the wrk/wrk2/h2load/k6 drivers, campaigns
and matrices, capture/validate/publish, the `tools/` helpers, and baseline updates — live in
the `benchmark-commands` skill (`.claude/skills/benchmark-commands/SKILL.md`), which loads on
demand. The rules that constrain them stay here:

- **JMH publishable runs need `-f 3` minimum.** `-f 1` is iteration-only — never use it for
  anything published into `baselines/`. Standard JVM flags for the JMH module are
  `-XX:+UseG1GC -XX:+AlwaysPreTouch -Xms256m -Xmx256m` (fixed heap prevents GC-mode switching
  across forks; bump for larger working sets).
- **Targets are launched externally.** The harness never starts them; drivers assume a
  pre-launched target, and `targets/launcher-sync-wrapper.sh` only synchronizes readiness.
- **`eu.exeris:*` snapshots resolve from GitHub Packages, not Maven Central** — local builds
  need a PAT with package read access and `-s .github/maven-settings-gpr.xml`.
- **`publish-report.sh` defaults to `--publication-mode public`**, which **blocks raw JFR** by
  extension (case-insensitive `.jfr`) and content signature (`FLR\0`). Use `internal-only` to
  permit raw JFR for restricted publication, or `redacted` to permit only non-`.jfr`
  JFR-derived artifacts. Generated reports stamp `publication_mode`,
  `confidentiality_status`, and `jfr_handling`.
- **Never refresh a baseline to mask a regression** — follow `docs/regression-policy.md`.

Never derive a heap/non-heap split by subtracting `-Xmx` from RSS — without `AlwaysPreTouch`,
`-Xms` commits pages it never touches, so resident < committed and the subtraction can go
negative (measured: −23 096 kB). And never sum across the two footprint tools
(`extract-footprint-decomposition.sh`, `extract-nmt-category-breakdown.sh`): one reports
resident bytes, the other committed. NMT has no per-category residency, so a category's
committed size is only an upper bound on its resident size — quote the coverage ratio
alongside any category claim so the unattributed remainder stays visible.

## Reporting checklist (before publishing or claiming)

- Tier (Community / Enterprise), protocol mode (H1/H2/H3), benchmark family (Micro/Runtime/Compat), and comparison axis are explicitly labeled.
- Pure mode and compat mode are separated; H3-only Enterprise behavior is not stated as Community capability.
- For comparative runtime: `claim-status.json` is `comparison_eligible` and strict gates pass; `track_id` is consistent.
- For TLS rows: buffer / transport / allocator model labels populated; B3 vs B4 not framed as handler-free apples-to-apples; B3/B4 vs B5/B6 differences stated.
- Reproducibility metadata captured (SHA, JDK/tool versions, JVM flags, hardware profile, scenario id).
- Confidentiality reviewed: raw JFR/flamegraphs/diagnostics not leaked into public artifacts.
- **All four summarizing surfaces swept** when any section changed — frontmatter `summary:`, TL;DR, revision history, conclusions. A correct section body does not imply correct summaries: three consecutive review rounds on the triad report found every remaining defect living *only* in these four places. Watch two specifics — a summary must not strengthen the body's quantifier ("rises to 39–59 %" ≠ "dominates"), and a bound must be the one measured on the axis being claimed (a ≤ 2 % throughput order-effect says nothing about RSS, where the same control read +13.5 %). Cross-cutting facts such as the pgjdbc fetch-config normalization belong on this sweep too. The revision-history leg includes **all three dated bylines** (frontmatter `updated:`, the `*By … (updated …)*` line, the `**Updated:**` metadata field) — they drift apart, and two of them sat two days stale through two edit rounds.

## Where to read more

- `docs/benchmark-philosophy.md` — why this repo exists and how to read results
- `docs/methodology.md` — warmup, measurement, statistics
- `docs/scenario-catalog.md` — every scenario, payload, conditions
- `docs/protocol-comparison-matrix.md` — formal within-tier and cross-tier protocol matrix
- `docs/tls-zero-copy-benchmark-matrix.md` — TLS A/B/C/D MUST-SHOULD-STRETCH matrix and `scripts/run-tls-matrix.sh` mapping
- `docs/result-interpretation.md`, `docs/regression-policy.md`, `docs/hardware-profiles.md`
- `.github/copilot-instructions.md` and `.github/instructions/exeris-bench-{core,runtime,reporting}.instructions.md` — authoritative operating rules; on conflict, prefer the **stricter** fairness/reproducibility/confidentiality interpretation
