# Shape A capacity ladders — 2026-08-21

CONTRACT-v2 §2.1 shape A (1 ms park). Five ladder runs on `perf-box-amd64`, imported from
the perf box scratch tree on 2026-08-22.

**What is here and what is not.** Only the citable artifact set: `ladder.csv`,
`deployment-footprint.json`, `post-load-settle.json`, `correctness-gate.json`,
`claim-status.json`, `run-metadata.json`, `env.json`, `k6-summary.json`,
`resource-metrics.json`. Raw JFR is excluded by CLAUDE.md's default publication mode
(`public` default-denies `.jfr` by extension and by `FLR\0` signature), and
`k6-output.json` is excluded as a per-request record with no citable content. Full runs
remain on the box: 8.4 GB against the 1.0 MB kept here.

## Directory names differ from the run directories on the box

`ladderC-20260821T174847Z` was written by ladder **C**, into a directory named
`saga-ladderA-…` — the script's `OUT` prefix was not updated when the ladder was
re-derived. Renamed on import so the directory does not misname its own contents. The
other four carried the correct prefix. Every `run-metadata.json` inside is untouched.

## What each ladder asked

| ladder | rungs | question |
|---|---|---|
| **C** `174847Z` | quarkus 80/100 at pool 128, exeris 200 at pool 32 | Does the pool bind quarkus? Arm-neutral Postgres backend sampling replaces a detector that could only see exeris. |
| **F** `181526Z` | exeris 100/125/150/200 at pool 256 | Bracket downward from a rate known to fail, with the VU pool sized off measured `iteration_duration`. |
| **G** `183426Z` | exeris 175/200/100, quarkus 70 at pool 256 | Close the exeris bracket; find where quarkus's ceiling really sits. |
| **H** `190749Z` | restate, spring-axon-jdbc, spring-axon-embedded-jdbc at 50/100/150 | First shape-A rungs for the three arms that had none. First runs with the post-load settle window. |
| **I** `200030Z` | restate 175/200, both Axon arms at 60/70 | Close the brackets ladder H opened, with the verdict logic corrected. |

## Rungs that are not results

- **`ladderF/exeris-community-r100-p256`** — the seed deadlocked (`ERROR: deadlock
  detected`, exit 79) against a target left alive by a previous ladder's kill. An
  infrastructure artifact, not a measurement. Re-run clean in ladder G.
- **`ladderF` rungs 2–4** — a target JVM from rung 1 survived its own stop (port
  released, process alive) and co-resided through the rest of the ladder, holding ~16
  Postgres backends. Throughput and latency are believed unaffected; `pg_backends_max` is
  inflated by roughly that much, and **every RSS / deployment-footprint figure from those
  three rungs is invalid**. Fixed in `runtime/drivers/stop-target.sh` by verifying the
  process, not only the port.
- **`ladderH` verdict labels** — `VU-LIMITED` fired on all six Axon rungs from a test that
  compared `vus_peak` against `maxVUs`. k6 reports `vus.max` summed across concurrently
  active scenarios, so it exceeds the ceiling legitimately; and where iteration p95 sits at
  the 30 s request timeout, dropped iterations are a symptom of the target, not the driver.
  The throughput, error and latency columns are unaffected. Ladder I carries the corrected
  verdict (`TARGET-SATURATED`).
- **`ladderH` `engine_rss_after_mb` for `spring-axon-embedded-jdbc`** — that arm has no
  external engine, and the column reported an idle container belonging to another arm.
  Fixed for ladder I, which prints `-`.

## Fences

No figure crosses these without being labelled.

| fence | date | what it invalidates before it |
|---|---|---|
| LRA `@Consumes` 415 | commit `b0779716` | quarkus-lra compensation never executed; the callback returned 415. |
| VU pool sizing | ladder F onward | Shape-A throughput measured k6's VU budget, not the target. Ladders A–E are not comparable forward. |
| post-load settle window | ladder H onward | Deployment footprint stopped sampling when load stopped, understating whatever defers work. |
| process-level stop verification | after ladder F | A stopped-but-alive target could co-reside with later rungs. |
