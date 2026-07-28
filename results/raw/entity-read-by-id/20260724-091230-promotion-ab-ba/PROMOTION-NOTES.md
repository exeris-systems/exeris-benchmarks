# Promotion — exeris-community vs quarkus-tuned through the full comparative strict gate

Flagship comparison_eligible certification (item 6). Wrapper `scripts/run-entity-read-promotion-ab-ba.sh`.
**exeris-community vs quarkus-tuned**, 4 vCPU pinned (target 0-1,8-9 / loadgen 2-3,10-11 / DB 4-7,12-15),
tuned-PG reused, ab/ba, 128 conns / 4 threads, JFR off. Not a merge gate.

## Certified result — exeris leads BOTH endpoints (all 8 leaves comparison_eligible, 4/4 artifacts, 0 errors)

| endpoint | budget | exeris rps (ab/ba) | quarkus-tuned rps (ab/ba) | exeris lead |
|---|---|---|---|---|
| **heavy** (aggregate) | 1024m | 13,593 / 13,463 | 12,835 / 12,836 | **+5%** |
| heavy | 256m | 13,453 / 13,481 | 12,560 / 12,580 | **+7%** |
| **light** (single-read) | 1024m | 79,475 / 79,164 | 55,452 / 55,709 | **+43%** |
| light | 256m | 77,770 / 77,867 | 54,703 / 54,147 | **+43%** |

Heavy p99 ~15-18ms both arms; light p99 exeris ~10-11ms / quarkus ~5ms. Heavy ran the full 120s window
(~1.6M requests/leg); light the immutable 900s window.

## MEMORY MODEL — native comparative gate (NOT the cgroup sweeps)

Budget = `-XX:MaxRAM=<budget>m` + explicit heaps (exeris 0.25x = 256/64m, quarkus 0.75x = 768/192m), NOT a
cgroup MemoryMax. So **256m here is a real head-to-head** (quarkus does not hard-OOM under MaxRAM, unlike
cgroup-256m where it did) and the numbers do NOT tie to the constrained cgroup sweeps — a separate, official
comparative track. Both budgets give the same ranking (exeris ahead on both endpoints).

## PROVENANCE — two source campaigns (why)

- **HEAVY = this campaign `20260724-091230`** (DB-normalized). The FIRST promotion run (`20260724-054802`,
  superseded) ran the heavy legs with an un-equalized pgjdbc config (`EXERIS_DB_JDBC_URL` carried only
  `prepareThreshold=1`), which handicapped exeris on the multi-row aggregate: exeris 11.2k, quarkus WRONGLY
  ahead at 13.2k. Fix `d1032c8` pins the full fair set (`defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended`)
  on the shared url -> exeris recovers to ~13.5k and LEADS (+6%). Verified: fair params present in these
  leaves (`grep -rl defaultRowFetchSize=0` > 0), absent in the superseded run.
- **LIGHT = `20260724-054802/light`** (kept from the first run; NOT re-normalized). Light single-read returns
  ONE row, and the params normalization changed (`defaultRowFetchSize`/`adaptiveFetch`) are multi-row fetch
  controls that physically cannot affect a 1-row result; `preferQueryMode=extended` is the pgjdbc default and
  `prepareThreshold=1` was in both. So 054802's light IS a normalized light — re-running it would cost ~2.5h
  for identical numbers. exeris +43% is config-agnostic here.

## Three harness gaps fixed while doing this (all pre-existing, affected the curve/triad too)

1. `de90ba4` — run-comparative.sh wrote `rejection-codes.json` only on the FAILURE branches; every
   comparison_eligible leaf ever was missing 1 of the 4 CLAUDE.md-required artifacts. Now written on the
   passing path. These 8 leaves' rejection-codes.json were **backfilled** (the box still ran the pre-fix
   harness during the campaign; content is `[]`, mirroring each gate summary).
2. `af1f4c0` — the per-contract immutable window (light 300/900) was not applied (harness defaulted 60/120),
   aborting the light legs fail-closed. Now carried per combo.
3. `d1032c8` — DB normalization (above).
