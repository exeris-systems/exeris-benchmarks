---
title: "Benchmark Status & Claim Eligibility Methodology"
description: "Exact semantics for runner_status, reproducibility_status, final_reason, and claim_scope. Hard gates preventing partial/empty runs from appearing as valid comparisons."
applies_to: "all benchmark runs and evidence aggregation"
---

# Benchmark Status & Claim Eligibility

## Mission

Prevent **any** partial, empty, or incomplete benchmark run from being misrepresented as a valid comparison-eligible result. All claim eligibility decisions must be automated, explicit, and enforceable.

## Core Constraint: Evidence-First

From [exeris-bench-core.instructions.md](exeris-bench-core.instructions.md):
- Do not optimize for proving Exeris is "fast".
- **Do not produce claims that exceed benchmark evidence.**

**This document is the evidence fence.** No evidence = no claim.

---

## Exact Status Semantics

### runner_status (3 values, REQUIRED)

Describes whether the benchmark harness successfully produced evidence (JSON result rows).

| Value | Condition | Semantics |
|-------|-----------|-----------|
| `success` | `benchmark_exit_code == 0` AND `json_array.length > 0` AND JSON is valid | Benchmark ran, all warmup/measurement completed, at least one valid result row produced. **Eligible for reproducibility_status check.** |
| `partial` | `json_array.length > 0` AND (`benchmark_exit_code != 0` OR `postprocess_exit_code != 0`) | Benchmark produced some result rows but exited abnormally OR post-processing (JFR extraction, metrics collection) failed. **Can describe completed rows only; cannot compare.** |
| `failed` | `json_array.length == 0` OR invalid JSON OR `benchmark_exit_code != 0` with no rows | Benchmark produced zero valid result rows. **Zero evidence. No claims.** |

**Key rule:** A benchmark that exits 0 but has empty JSON is `failed`, not `success`.

---

### reproducibility_status (4 values, REQUIRED when runner_status ≠ "failed")

Describes whether all required metadata and artifacts are present to satisfy reproducibility constraints.

| Value | Condition | Semantics |
|-------|-----------|-----------|
| `complete` | runner_status="success" AND all of: commit_sha, jdk_vendor, jdk_version, hardware_profile, jvm_flags, scenario_id, scenario_classification present AND (jfr_expected → jfr_collected=true) AND (metrics_expected → metrics_collected=true) | All metadata and expected artifacts captured. **Candidate for claim_eligibility = "comparison_eligible".** |
| `incomplete_artifacts` | runner_status in ["success", "partial"] AND (jfr_expected AND NOT jfr_collected) OR (metrics_expected AND NOT metrics_collected) | Some evidence artifacts missing or empty when expected. **Can describe completed rows but cannot make regression/improvement claims.** |
| `incomplete_metadata` | runner_status in ["success", "partial"] AND missing any of: commit_sha, jdk_version, hardware_profile, jvm_flags, scenario_id | Required reproducibility metadata missing. **Results are not trustworthy for future reproduction.** |
| `not_assessable` | runner_status="failed" | No evidence produced; reproducibility of empty results is moot. **Use final_reason to explain the failure.** |

---

### final_reason (9 codes, priority order, REQUIRED)

Specific failure/limitation code explaining why a run cannot be used for comparison claims. Applied in priority order (first matching code wins).

| Code | When | Example |
|------|------|---------|
| `ok` | runner_status="success" AND reproducibility_status="complete" | Run is fully valid and comparison-eligible. |
| `partial_json` | runner_status="partial" | 5 of 10 benchmark cases completed; 5 failed mid-measurement. Can describe the 5 completed rows only. |
| `empty_json` | runner_status="failed" AND json_array.length == 0 | Benchmark warmup or measurement never reached completion. |
| `invalid_json` | runner_status="failed" AND JSON parse error | Result JSON corrupted or malformed. |
| `benchmark_exit_nonzero` | runner_status="failed" AND benchmark_exit_code != 0 | JVM exited abnormally; check log for crash/OOM/timeout. |
| `postprocess_exit_nonzero` | runner_status="partial" AND postprocess_exit_code != 0 | Benchmark completed but JFR/metrics extraction tool failed. |
| `missing_jfr` | reproducibility_status="incomplete_artifacts" AND jfr_expected=true AND jfr_collected=false | JFR file expected (zero-alloc validation phase) but not produced. |
| `missing_metrics` | reproducibility_status="incomplete_artifacts" AND metrics_expected=true AND metrics_collected=false | Metrics JSON expected but not produced. |
| `missing_metadata` | reproducibility_status="incomplete_metadata" | commit_sha, JDK version, hardware profile, or scenario_id missing. |

**Implementation:** When classifying a run, apply **first matching** code in this order. Do not emit multiple codes.

---

### claim_scope (4 values, REQUIRED)

Describes what kinds of claims (if any) can be made from this benchmark run.

| Value | When | What can be claimed | What cannot be claimed |
|-------|------|-------------------|------------------------|
| `comparison_eligible` | runner_status="success" AND reproducibility_status="complete" AND final_reason="ok" | Regression/improvement vs other comparison_eligible runs. Time-series analysis. Baseline comparison. | Anything about partial/incomplete phases. |
| `descriptive_partial` | runner_status="partial" | Description of *only the completed rows* (e.g., "3 of 10 cases succeeded"). Historical note of partial result. | Regression claims. Improvement claims. Cross-run averaging. |
| `descriptive_only` | runner_status="success" AND reproducibility_status != "complete" | Description of results without reproducibility evidence (e.g., "we observed X on unknown hardware"). | Regression claims. Comparison claims. Any future reproduction based on this result. |
| `none` | runner_status="failed" | Only factual statement of failure reason (e.g., "benchmark exited with code 139"). | All substantive performance claims. |

Canonical handling for tooling:
- `comparison_eligible` is the only accepted value for comparative sections.
- Any other `claim_scope` value is excluded from comparative sections with an explicit exclusion reason.
- Legacy synonyms are invalid and must fail validation; tools must not map them silently.

---

## CSV Schema (status.csv)

Every benchmark run MUST produce a `status.csv` with the following columns. This CSV is the primary gate for evidence lab and dashboard consumption.

### Required Fields

```
timestamp
phase
benchmark_id
tier
implementation_variant
benchmark_family
protocol_mode
execution_class
runner_status
reproducibility_status
final_reason
claim_scope
benchmark_exit_code
postprocess_exit_code
expected_case_count
json_row_count
failed_case_count
log_failure_count
jfr_expected
jfr_collected
metrics_expected
metrics_collected
metadata_complete
log_file
json_file
jfr_file
metrics_file
cmd_file
jvm_args_file
reproducibility_metadata_file
```

### Field Definitions

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | ISO8601 | UTC run start time |
| `phase` | string | warmup / measurement / postprocess |
| `benchmark_id` | string | Tool-internal benchmark name (e.g., `wrapUnwrapRoundTrip(16384)`) |
| `tier` | enum | community (enterprise labels may exist in internal-only artifacts) |
| `implementation_variant` | string | e.g., "Community TLS NIO", "Spring H1", "Quarkus H2" |
| `benchmark_family` | enum | micro-jmh / runtime-wrk / runtime-h2load / runtime-k6 |
| `protocol_mode` | enum | h1 / h2 / h3 / n-a (for JMH) |
| `execution_class` | enum | exploratory / guard / regression |
| `runner_status` | enum | success / partial / failed |
| `reproducibility_status` | enum | complete / incomplete_artifacts / incomplete_metadata / not_assessable |
| `final_reason` | enum | ok / partial_json / empty_json / invalid_json / benchmark_exit_nonzero / postprocess_exit_nonzero / missing_jfr / missing_metrics / missing_metadata |
| `claim_scope` | enum | comparison_eligible / descriptive_partial / descriptive_only / none |
| `benchmark_exit_code` | integer | 0 = success; nonzero = failure |
| `postprocess_exit_code` | integer | JFR/metrics extraction result; 0 = success |
| `expected_case_count` | integer | JMH: sum of (warmup_iterations + measurement_iterations) * forks. wrk/k6: total requests. |
| `json_row_count` | integer | Actual rows in result JSON array. Must equal expected_case_count for runner_status="success". |
| `failed_case_count` | integer | JMH benchmark() invocation count that threw or failed to complete. |
| `log_failure_count` | integer | Count of "Benchmark.*failed", "Exception", "<failure>" patterns in logfile. |
| `jfr_expected` | boolean | Was JFR recording enabled for this phase? |
| `jfr_collected` | boolean | Is JFR file present and non-empty? |
| `metrics_expected` | boolean | Should -prof gc / -prof async metrics be present? |
| `metrics_collected` | boolean | Is metrics JSON present and non-empty? |
| `metadata_complete` | boolean | All of commit_sha, jdk_vendor, jdk_version, hardware_profile, jvm_flags, scenario_id present? |
| `log_file` | path | Relative or absolute path to benchmark.log (may be /dev/null) |
| `json_file` | path | Path to result JSON array |
| `jfr_file` | path | Path to .jfr file (empty string if not collected) |
| `metrics_file` | path | Path to metrics JSON (empty string if not collected) |
| `cmd_file` | path | Path to command line executed (for audit) |
| `jvm_args_file` | path | Path to JVM flags file (for reproducibility) |
| `reproducibility_metadata_file` | path | Path to JSON with commit_sha, jdk_version, hardware_profile, etc. |

### Example Rows

**✅ Fully valid:**
```
2026-03-18T09:15:00Z,measurement,wrapUnwrapRoundTrip(16384),community,Community Kernel TLS,micro-jmh,n-a,guard,success,complete,ok,comparison_eligible,0,0,30,30,0,0,true,true,true,true,true,./run-20260318/wrap_16k.log,./run-20260318/wrap_16k.json,./run-20260318/wrap_16k.jfr,./run-20260318/wrap_16k-metrics.json,./run-20260318/wrap_16k.cmd,./run-20260318/wrap_16k-jvm.txt,./run-20260318/wrap_16k-repro.json
```

**⚠️ Partial (5 of 10 cases succeeded):**
```
2026-03-18T09:30:00Z,measurement,json-1kb,community,Community NIO,runtime-wrk,h1,exploratory,partial,incomplete_artifacts,partial_json,descriptive_partial,1,5,10,5,3,2,true,false,true,false,false,./run-20260318/json1k.log,./run-20260318/json1k.json,,./run-20260318/json1k-metrics.json,./run-20260318/json1k.cmd,./run-20260318/json1k-jvm.txt,./run-20260318/json1k-repro.json
```

**❌ Empty:**
```
2026-03-18T09:45:00Z,measurement,routing-404,community,Community Kernel,runtime-k6,h1,regression,failed,not_assessable,empty_json,none,0,0,100000,0,0,0,false,false,false,false,true,./run-20260318/route404.log,,,,./run-20260318/route404.cmd,./run-20260318/route404-jvm.txt,./run-20260318/route404-repro.json
```

---

## Claim Eligibility Rules (Hard Gates)

**THESE ARE ENFORCEABLE RULES. Evidence lab and dashboards MUST reject claimed comparisons that violate these rules.**

### Rule 1: Comparison Claims

**A comparison claim can be made IF AND ONLY IF:**
- `runner_status = "success"` ← at least one valid result row
- `reproducibility_status = "complete"` ← all metadata and expected artifacts present
- `final_reason = "ok"` ← no exceptions
- `claim_scope = "comparison_eligible"` ← derived from above
- **AND** the compared runs must have:
  - Same `protocol_mode` (do not compare h1 to h2)
  - Same `benchmark_family` (do not compare micro-jmh to runtime-wrk)
  - Explicitly stated `tier` in report (e.g., "Community vs Community", never unlabeled)

Operational exclusion behavior (compare tooling):
- The compare gate evaluates baseline first, then current.
- If either side has `claim_scope != comparison_eligible`, comparative evaluation stops immediately.
- Output must include file label plus observed `claim_scope` and `execution_class` (and `final_reason` when present) and a concrete exclusion reason.

**Violation example:**
```
Claim: "Enterprise TLS improved by 15% on handshake."
Sources: 
  - 2026-03-18: runner_status=success, claim_scope=comparison_eligible ✓
  - 2026-03-10: runner_status=partial, claim_scope=descriptive_partial ✗
RESULT: NO COMPARISON. Can only state "old run was incomplete."
```

### Rule 2: Partial Runs

**Partial runs (runner_status="partial") can ONLY:**
- Describe the completed rows (e.g., "3 of 10 test cases succeeded; results: …")
- Be reported with label: `[INCOMPLETE]`
- **NEVER** be averaged with other runs
- **NEVER** be compared for regression/improvement
- **NEVER** be aggregated into statistical rollups like "median across all H1 runs"

**Violation example:**
```
Report: "Average H1 latency = 500µs across all recent runs"
Includes: partial run (5 of 20 cases)
RESULT: NOT ALLOWED. Must exclude partial run or recompute as "average of 
         complete runs" with explicit caveat.
```

### Rule 3: Failed Runs

**Failed runs (runner_status="failed") can ONLY:**
- Cite the failure reason from `final_reason`
- Investigate failure using log + reproducibility metadata + command
- **NEVER** make any performance claim
- **NEVER** be included in any numerical analysis

**Violation example:**
```
Dashboard shows: [No Data] for Community H2, runner_status=failed
Attempt: Include in "fastest tier" ranking
RESULT: NOT ALLOWED. That run produced zero evidence.
```

### Rule 4: Metadata Incompleteness

**If reproducibility_status != "complete"** (e.g., = "incomplete_metadata"):
- Can describe the result *values* (e.g., "observed 312M req/s")
- **CANNOT** make regression/improvement claims (no baseline for future comparison)
- **CANNOT** compare to other runs (unknown if environments match)
- **MUST** note what metadata is missing in the report

**Violation example:**
```
Baseline created without recording hardware profile:
  runner_status=success, reproducibility_status=incomplete_metadata, 
  final_reason=missing_metadata, claim_scope=descriptive_only
Attempt: Compare next run to this baseline
RESULT: NOT ALLOWED via automated gating. Must first capture 
        the missing hardware profile on next run, then create new baseline.
```

### Rule 5: Artifact Incompleteness

**If reproducibility_status="incomplete_artifacts"** (e.g., missing expected JFR):
- Can describe the result rows that exist
- **CANNOT** make claims about zero-allocation or other allocation-dependent properties
- Can investigate failure (why JFR not collected)
- **MUST** note in report: "Zero-alloc validation phase incomplete"

**Violation example:**
```
Run attempted zero-alloc benchmark on cold-start path:
  jfr_expected=true, jfr_collected=false (JVM crashed before JFR flush)
Attempt: Claim "verified zero-alloc on cold-start"
RESULT: NOT ALLOWED. Missing evidence. Can only state 
        "cold-start completed but allocation instrumentation failed."
```

---

## Test Matrix: Status Classification Verification

This matrix defines all valid combinations and verifies that classification produces correct `final_reason` and `claim_scope`.

### Matrix Legend

| Column | Values |
|--------|--------|
| `exit_code` | 0 (success) / N (nonzero) |
| `json_rows` | >0 (has results) / 0 (empty) |
| `metadata` | ✓ (complete) / ✗ (missing) |
| `artifacts` | ✓ (jfr/metrics present as expected) / ✗ (missing) |

### Classification Test Cases

| # | exit_code | json_rows | metadata | artifacts | Expected runner_status | Expected repro_status | Expected final_reason | Expected claim_scope | Scenario |
|---|-----------|-----------|----------|-----------|------------------------|------------------------|-----------------------|----------------------|----------|
| 1 | 0 | >0 | ✓ | ✓ | success | complete | ok | comparison_eligible | ✅ Perfect run |
| 2 | 0 | >0 | ✓ | ✗ | success | incomplete_artifacts | missing_jfr | descriptive_only | Metadata OK but JFR missing |
| 3 | 0 | >0 | ✗ | ✓ | success | incomplete_metadata | missing_metadata | descriptive_only | Artifacts OK but commit_sha/hardware missing |
| 4 | 0 | >0 | ✗ | ✗ | success | incomplete_metadata | missing_metadata | descriptive_only | Both metadata and artifacts missing |
| 5 | 0 | 0 | ✓ | ✓ | failed | not_assessable | empty_json | none | Exit 0 but no results (warmup loop issue) |
| 6 | 0 | 0 | ✓ | ✗ | failed | not_assessable | empty_json | none | Exit 0, no results, JFR not even attempted |
| 7 | N | >0 | ✓ | ✓ | partial | complete | partial_json | descriptive_partial | Benchmark crashed mid-measurement but some rows exist |
| 8 | N | >0 | ✓ | ✗ | partial | incomplete_artifacts | partial_json | descriptive_partial | Partial results, metadata OK, but JFR missing |
| 9 | N | 0 | ✓ | ✓ | failed | not_assessable | benchmark_exit_nonzero | none | Benchmark crashed immediately (no rows) |
| 10 | 0 | >0 | ✓ | ✓ (but pp_rc≠0) | partial | complete | postprocess_exit_nonzero | descriptive_partial | Results OK but metrics extraction tool failed |

### Automated Verification Script

Every status.csv generation MUST run this check after classification:

```bash
# verify_classification.sh - Run after writing status.csv
validate_classification() {
  local csv_row="$1"
  local runner_status=$(echo "$csv_row" | cut -d, -f9)
  local repro_status=$(echo "$csv_row" | cut -d, -f10)
  local final_reason=$(echo "$csv_row" | cut -d, -f11)
  local claim_scope=$(echo "$csv_row" | cut -d, -f12)
  local json_rows=$(echo "$csv_row" | cut -d, -f17)

  # Rule 1: If runner=success, must have claim_scope != "none"
  if [[ "$runner_status" == "success" && "$claim_scope" == "none" ]]; then
    echo "ERROR: runner_status=success but claim_scope=none"
    return 1
  fi

  # Rule 2: If runner=failed, must have claim_scope=none
  if [[ "$runner_status" == "failed" && "$claim_scope" != "none" ]]; then
    echo "ERROR: runner_status=failed but claim_scope=$claim_scope (must be none)"
    return 1
  fi

  # Rule 3: If json_rows=0, must have runner=failed
  if [[ "$json_rows" == "0" && "$runner_status" != "failed" ]]; then
    echo "ERROR: json_rows=0 but runner_status=$runner_status (must be failed)"
    return 1
  fi

  # Rule 4: If final_reason=ok, must have runner=success AND repro=complete
  if [[ "$final_reason" == "ok" ]]; then
    if [[ "$runner_status" != "success" || "$repro_status" != "complete" ]]; then
      echo "ERROR: final_reason=ok but runner=$runner_status repro=$repro_status"
      return 1
    fi
  fi

  # Rule 5: claim_scope=comparison_eligible iff runner=success AND repro=complete AND final_reason=ok
  if [[ "$claim_scope" == "comparison_eligible" ]]; then
    if [[ "$runner_status" != "success" || "$repro_status" != "complete" || "$final_reason" != "ok" ]]; then
      echo "ERROR: claim_scope=comparison_eligible but status/reason don't match"
      return 1
    fi
  fi

  return 0
}
```

---

## Implementation Note

This document is normative (policy/spec), not a delivery roadmap.
Implementation details, rollout sequencing, and CI task tracking should live in
tooling tickets/PRs and not in this policy file.

---

## Related Documents

- [exeris-bench-core.instructions.md](exeris-bench-core.instructions.md) — Core fairness/reproducibility rules
- [methodology.md](methodology.md) — Benchmark design (warmup, JVM flags, etc.)
- [result-interpretation.md](result-interpretation.md) — How to read and report results
- `schemas/benchmark-result.schema.json` — Result data structure
- `schemas/benchmark-env.schema.json` — Environment/metadata structure

---

**Last Updated:** 2026-04-12

