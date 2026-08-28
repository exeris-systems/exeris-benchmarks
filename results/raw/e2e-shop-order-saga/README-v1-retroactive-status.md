# e2e-shop-order-saga — v1 raw runs: retroactive status under CONTRACT-v2 §10

**Applies to:** every run directory under `results/raw/e2e-shop-order-saga/`
listed below.
**Authority:** `scenarios/e2e-shop-order-saga/CONTRACT-v2.md` §10 (Retroactive
validity of v1 results).
**Status:** these are **v1-era** runs. They MUST NOT be aggregated, averaged,
or tabulated together with any CONTRACT-v2 run.

---

## Why these are classified v1 (evidence, not date alone)

None of the run directories below contain any v2 artifact or marker:

- no `fault_class` / `--fault-mode` label (`terminal` vs `transient`, §4);
- no `durability_tier` / `durability_tier_source` stamp (§8);
- no exact-compensation correctness-gate JSON (`expected_declines` /
  `observed_compensations`, §7 / §4.1);
- no deterministic FNV-1a decline oracle (`fnv1a64` / `stableHash64`);
- no outcome-split latency trends (`saga_completed_duration` /
  `saga_compensated_duration`, §8).

They were produced by the pre-v2 harness (probabilistic
`payment_fail_rate = 0.03` injected per-attempt, single mixed-population
latency), all dated before the v2 machinery landed (2026-07-17, PR #20). The
classification here is by **absence of the v2 gate artifacts above**, verified
against the run contents, not inferred from the timestamp.

## Run inventory

**Baseline runs (15)** — `*-baseline`, dated 2026-05-04 / 2026-05-05:

```
20260504T143931Z-baseline  20260504T144943Z-baseline  20260504T171127Z-baseline
20260504T175222Z-baseline  20260504T180828Z-baseline  20260505T074104Z-baseline
20260505T074158Z-baseline  20260505T074245Z-baseline  20260505T110828Z-baseline
20260505T110841Z-baseline  20260505T111119Z-baseline  20260505T114501Z-baseline
20260505T115008Z-baseline  20260505T115722Z-baseline  20260505T120906Z-baseline
```

**Campaign runs (8)** — `*-campaign`, dated 2026-05-17:

```
20260517T152203Z-campaign  20260517T152826Z-campaign  20260517T154049Z-campaign
20260517T154447Z-campaign  20260517T155416Z-campaign  20260517T155444Z-campaign
20260517T155532Z-campaign  20260517T161437Z-campaign
```

## Status of each v1 result class (CONTRACT-v2 §10)

| v1 result class | Status under v2 | Action for these dirs |
|---|---|---|
| Environment / client symmetry, protocol notes (`env.json`, transport labels) | **valid, carried over** | citable as-is with axis labels |
| Happy-path latency / throughput (`result.json`, `k6-summary.json`) | **conditionally valid** | must be re-labelled as `COMPLETED`-population metrics; a §8 outcome-split re-run is recommended before any latency claim |
| Compensation-correctness observations (e.g. any v1 Axon "zero compensations" note) | **superseded** | must be re-tested under §4.1 deterministic terminal fault; v2 turns the anomaly into a pass/fail assertion. Do not cite the v1 observation as a finding |
| Any mixed-population latency table (COMPLETED + COMPENSATED blended) | **invalid under v2** | do not cite in any report |

## Hard rules

1. **No cross-version aggregation.** A v1 run and a v2 run must never appear in
   the same table, average, CI, or trend series. `contract_revision` is an
   isolation boundary for this scenario exactly as `track_id` is for tracks.
2. **No mixed-population latency claims** from these runs (v1 blended
   COMPLETED + COMPENSATED into one latency distribution).
3. **No compensation-correctness claims** from these runs; the v1 fault model
   was probabilistic per-attempt, not the deterministic per-`orderId` decline
   the v2 oracle asserts against.
4. Happy-path descriptive throughput/p50 remains citable **only** when
   re-labelled `COMPLETED`-population and carrying the standard axis +
   loopback caveats.

Raw artifacts are retained unmodified for traceability. This file only
re-classifies how they may be cited; it does not alter their contents.
