# Kernel-version axis: 0.10.2 vs 0.11.0 vs preview/0.11.0

**Axis id:** `kernel-version-0.10.2-vs-0.11.0`
**Tier:** Community · **Protocol:** H1 · **Mode:** Pure · **Family:** Runtime · **Track:** Exploratory, within-tier
**Manifest:** `runtime/drivers/kernel-version-axis-arms.json`

The 0.11 release ships under two coordinates: `eu.exeris:0.11.0` for JDK 25 LTS without preview
features, and `eu.exeris.preview:0.11.0` for JDK 28 EA with preview features enabled (Valhalla value
classes and `StructuredTaskScope`). This document describes how they are compared against the
previous line, `eu.exeris:0.10.2`, and why the comparison is a ladder rather than a three-way.

## Why this is not a three-way comparison

The three coordinates cannot run on the same JVM. Measured from the published jars:

| Coordinate | Class-file major | Preview classes | Runs on |
|---|---|---|---|
| `eu.exeris:exeris-kernel-core:0.10.2` | 70 | 9 / 285 | **JDK 26 only**, `--enable-preview` required |
| `eu.exeris:exeris-kernel-core:0.11.0` | 69 | 0 / 309 | JDK 25, 26, 27, 28 — no flag |
| `eu.exeris.preview:exeris-kernel-core:0.11.0` | 72 | 95 / 306 | **JDK 28 EA only**, `--enable-preview` required |

A preview-marked class file loads only on a JVM whose feature release matches its major version
exactly, so the two end points are each pinned to one JDK, and those JDKs differ. Putting 0.10.2
next to preview/0.11.0 therefore moves the kernel version, the JDK feature release, and the
language/runtime feature set simultaneously. Whatever difference came out could not be attributed to
any of the three, which makes it unusable under this repo's fairness rule.

Mainline 0.11.0 is the only coordinate that loads on more than one JDK. That makes it the bridge:
every comparison below holds everything constant except one named variable, and the end-to-end
figure is assembled from them rather than measured directly.

Two facts make the ladder cheap to build. The public SPI of mainline and preview 0.11.0 is identical
apart from four records that become `value class` — `TlsHandshakeResult`, `TlsShutdownResult`,
`EventEngineStats`, `MemoryStats` — so **no application source differs across any arm**. And the app
compiles unchanged against 0.11.0, so there is no source-level 0.10.2-to-0.11.0 migration confound
either.

## Arms

Eight arms, all running `targets/exeris-community-app` against the same scenario and database. An arm
is identified by the **triple** (staged jar, JDK, preview flag) — four arms share a single staged
jar, so the jar path alone does not identify a run.

| Arm | Kernel | JDK | Preview flag | App release | Staged jar |
|---|---|---|---|---|---|
| A | `eu.exeris` 0.10.2 | 26 | on | 26 | `…-k0.10.2-r26p.jar` |
| B | `eu.exeris` 0.11.0 | 26 | on | 26 | `…-k0.11.0-r26p.jar` |
| C′ | `eu.exeris` 0.11.0 | 26 | off | 25 | `…-k0.11.0-r25.jar` |
| C | `eu.exeris` 0.11.0 | 25 LTS | off | 25 | `…-k0.11.0-r25.jar` |
| D | `eu.exeris` 0.11.0 | 28 EA | off | 25 | `…-k0.11.0-r25.jar` |
| D′ | `eu.exeris` 0.11.0 | 28 EA | on | 25 | `…-k0.11.0-r25.jar` |
| D″ | `eu.exeris` 0.11.0 | 28 EA | on | 28 | `…-k0.11.0-r28p.jar` |
| E | `eu.exeris.preview` 0.11.0 | 28 EA | on | 28 | `…-kpv0.11.0-r28p.jar` |

Arm C is the configuration that actually ships on the LTS. Arm E is the only one carrying Valhalla
value classes and `StructuredTaskScope`.

## Legs

Only these seven pairings are measurements. Everything else mixes variables.

| Leg | Isolates | Held constant |
|---|---|---|
| A → B | kernel 0.10.2 → 0.11.0 | app release, JDK, flag |
| B → C′ | app release 26 → 25, flag off | kernel, JDK |
| C′ → C | JDK 26 → 25 | byte-identical jar, kernel, flag |
| C′ → D | JDK 26 → 28 EA | byte-identical jar, kernel, flag |
| D → D′ | the preview flag alone | byte-identical jar, kernel, JDK |
| D′ → D″ | app recompiled at release 28 | kernel, JDK, flag |
| D″ → E | **Valhalla value classes + `StructuredTaskScope`** | app build, JDK, flag |

Three of these are controls rather than headline numbers, and they exist because of effects that are
easy to misattribute:

- **D → D′ (flag tax).** `--enable-preview` is not free — it changes what the JVM will share from
  the default CDS archive. Without this leg that cost lands inside the Valhalla number.
- **D′ → D″ (recompile tax).** Compiling the *unchanged* app source at release 28 with preview turns
  30 of its 40 class files into preview-marked bytecode, because JEP 401 changes how the class-file
  format is interpreted. That cost belongs to the recompile, not to the preview kernel.
- **B → C′ (bridge).** Connects the JDK-26 pair to the JDK ladder. A large effect here means the
  ladder legs cannot be chained onto the release delta, and the two halves must be reported apart.

## Workload contracts

The axis runs **both** contracts of `entity-read-by-id`, in separate result trees, never averaged
together:

| Key | Contract | Endpoint | Window (per target) |
|---|---|---|---|
| `light` | `fixed_contract_cross_runtime_h1_single_read_v1` | `GET /api/v1/user?id=1` | 300 s warmup + 900 s |
| `heavy` | `fixed_contract_cross_runtime_h1_v1` | `GET /api/v1/users` | 60 s warmup + 120 s |

They answer different questions and neither substitutes for the other. On the heavy aggregate read
most of the response time is Postgres, so kernel-internal effects compress toward zero — but that is
what a user's aggregate endpoint actually experiences. The light single-row read is where a Valhalla
or JIT difference can show at all. Its 300 s warmup is not padding: this path is JIT-sensitive, which
is also why the short `-debug` contracts are pipeline checks only and never results.

The request path is derived from the contract's own `endpoint` field, so a contract cannot be driven
at another contract's path.

## Running it

```bash
# 1. Build and stage the five app variants (verifies class-file version and preview bit of each)
scripts/build-kernel-version-axis-jars.sh

# 2. Regenerate driver wiring from the manifest; --check asserts no drift
scripts/generate-kernel-version-axis-wiring.sh
scripts/generate-kernel-version-axis-wiring.sh --check

# 3. Hard entry condition: every arm must boot, serve both contracts, and prove its identity
scripts/verify-kernel-version-axis-boot.sh

# 4. Pipeline check on the short debug contracts before committing the real run
scripts/run-kernel-version-axis-campaign.sh --legs "D-double-prime->E" \
  --contracts light-debug --repeats 1 --output-dir /tmp/axis-pipeline-smoke

# 5. The campaign (re-runs boot verification itself unless --skip-boot-verify)
scripts/run-kernel-version-axis-campaign.sh --repeats 3
scripts/run-kernel-version-axis-campaign.sh --contracts heavy --repeats 3
```

JDK locations are overridden with `JDK25_HOME`, `JDK26_HOME`, `JDK28_HOME`. On the perf box these are
`/opt/jdk25` (Temurin 25.0.4+7 LTS), `/opt/jdk26` (Temurin 26.0.1+8) and `/opt/jdk28` (28-ea+10-569).
Every contract for this scenario requires `required_profile=perf-box-amd64`, so the comparative stage
only runs there; steps 1–3 run anywhere.

**Wall-clock.** Both targets are measured sequentially, so one comparative invocation costs
`2 × (warmup + duration)`: 40 min on `light`, 6 min on `heavy`. Across 7 legs × 2 orders that is
roughly **28 h light + 4 h heavy per repeat-set of 3**, and about 54 h at 5 repeats. Plan the run
against that, or split it by contract.

### pgjdbc normalization is mandatory

Stage 8's DB-config gate rejects any run whose JDBC URL leaves `prepareThreshold`,
`defaultRowFetchSize`, `adaptiveFetch` or `preferQueryMode` to the driver's defaults. Both arms of a
leg inherit one environment here, so equality alone proves nothing — the parameters have to be pinned
explicitly. The campaign defaults `EXERIS_DB_JDBC_URL` to the normalized form and refuses to start if
an overriding URL is missing any of the four, rather than letting a multi-hour run reach Stage 8 and
be rejected wholesale:

```
jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended
```

### Eligibility is read from the verdict, not the exit code

`run-comparative.sh` can exit 0 on a step whose `claim-status.json` is `non_eligible` — the gates
passed but a precondition did not. The campaign reads `claim_status` after every step and counts
anything other than `comparison_eligible` as a failure, so a run cannot be reported complete while
banking steps whose comparative math is invalid.

The campaign runs each leg in both orders (A/B and B/A) per repeat, and **refuses any pair that is
not a declared leg**. The same discipline is registered in the scenario's
`comparative-pair-manifest.json`, so calling `run-comparative.sh` directly cannot produce an
undeclared cross-JDK number either — the A-vs-E end-point pair is listed under `forbidden_pairs`.

## Guards

Four arms differ only by JDK and JVM flag while sharing one staged jar. If a launcher resolved the
wrong `JAVA_HOME`, they would all run one JVM, the campaign would complete, every gate would pass,
and the axis would report a JDK effect that does not exist. Two checks make that failure loud:

- `scripts/verify-kernel-version-axis-boot.sh` — boots every arm, requires `/health` 200, requires
  both the light single-row read **and** the aggregate read to return 200 with a body, requires a
  404 for an absent row, and re-derives the arm's triple from `/proc`. A 404 on the light contract
  is the GET-with-query defect, not a missing row, and is indistinguishable from one at the driver.
- `tools/verify-kernel-version-axis-identity.sh` — the same identity check against an already
  running target, by PID resolved from the listening socket rather than from a pid file. The
  campaign calls it after starting each arm.

## What the preview coordinate actually changes (measured 2026-08-12)

Before reading any D''->E result, know how much Valhalla is in the build. Counted with `javap` over
the published jars:

| artifact | `value class` | classes |
|---|---|---|
| `exeris-kernel-spi` | 4 | 285 |
| `exeris-kernel-core` | 2 | 306 |
| `exeris-kernel-community` | 0 | 302 |
| benchmark app | 0 | 40 |

Six value classes in 893 — and none of them is reachable on this scenario's request path:

- `TlsHandshakeResult`, `TlsShutdownResult` — TLS only; these runs are cleartext H1.
- `EventEngineStats`, `MemoryStats` — telemetry; `EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false`.
- `TransactionRetryPolicy`, `SyscallHandles` — configuration/startup objects, not per-request.

StructuredTaskScope is the same story. Three core classes use it: `InMemoryEventBus` and
`OutboxOrchestrator` (the **events** subsystem) and `SubsystemOrchestrator` (bootstrap, once). The
measured arms log `Selector resolved 4 subsystem(s): memory, crypto, persistence, http` — events is
never initialized.

**So a null on D''->E is the expected result, not a finding about Valhalla.** The leg compares two
builds that are functionally identical on the exercised path. What it does establish is worth
keeping: the preview build carries no measurable penalty for *being* a preview build — neither the
preview-marked bytecode nor the `--enable-preview` flag costs anything on throughput or CPU/req.

**Do not read the preview-marked class count as adoption.** Core is 95/306 preview-marked but only
2/306 are value classes, and the app is 30/40 marked with **zero** value classes from source that
uses no preview feature at all. Marking follows JEP 401's reinterpretation of the class-file format
(`ACC_IDENTITY`), not usage. Reading it as adoption overstates by roughly 50x.

Testing the footprint claim needs value classes on per-request allocation paths — buffers,
request/response objects, `RouteMatch`, header entries. As of 0.11.0-preview none of those are value
classes, so no window length or repeat count can make this axis answer the question.

## Metric selection on a DB-bound contract

Throughput cannot discriminate this axis on `heavy`: Postgres saturates its cpuset (measured 91.65 %
mean, median sample 100 %) while the server sits at 2.93 of 4 pinned cores, so every arm reports the
database's ceiling. **CPU per request** stays valid — it is normalised per request, so it remains a
property of the runtime while throughput is externally pinned — and is well conditioned here
(CV 0.54-1.01 % against 0.33-0.71 % for rps).

**RSS is NOT a footprint measurement unless the heap is matched and fixed.** The arms as generated
carry no `-Xms`/`-Xmx`, so on a 62 GB box the default ergonomic heap is ~15.5 GB and RSS records
whatever the collector happened to commit: CV 2.6-5.6 %, confidence intervals near +/-10 %. The
2026-07-29 footprint work used a matched `-Xms256m -Xmx256m` on every arm for exactly this reason.
Add the same before quoting any RSS number from this axis.

## Known confounds

- **EA vs GA.** JDK 28 is `28-ea+10-569`; JDK 25 and 26 are GA. Every leg crossing into JDK 28
  inherits an early-access-vs-GA difference that no arm here separates out. This applies to
  `C′ → D`, and therefore to any figure chained through it, including the headline.
- **The release delta is only measurable at JDK 26.** Arm A cannot be moved, so `A → B` is a
  JDK-26 statement and does not by itself say what 0.11.0 does on the LTS.
- **DB-bound compression.** Community persistence is JDBC over HikariCP, so on the heavy aggregate
  contract most of the response time is Postgres and kernel-internal effects compress toward zero.
  Read `light` before `heavy` when attributing a delta to the kernel, and do not carry a `light`
  conclusion onto `heavy` or the reverse.
- **Build host vs run host.** The staged jars are built on the developer box and run on the perf box,
  so the javac that produced arm A/B's release-26 classes was Oracle 26 while the perf box runs
  Temurin 26.0.1. The same jar serves both arms of every leg, so this cannot bias a leg — but it does
  mean the artifacts are not reproducible from the perf box alone without the same build inputs.

## Reporting rules

- The end-to-end 0.10.2 → preview/0.11.0 figure is **a sum of legs, never a measured pair**. Publish
  it only alongside its decomposition.
- Label every row with the kernel coordinate *and* the JDK *and* the preview flag. "0.11.0" alone is
  ambiguous between arms B, C′, C, D, D′ and D″.
- Do not call arm E's delta "Valhalla" without the flag tax and recompile tax subtracted — those are
  legs `D → D′` and `D′ → D″`, and they are part of what a user adopting the preview line pays.
- This is a within-tier, within-exeris ladder. No arm here is a cross-runtime number.
