---
title: "METHODOLOGY REVIEW: Status & Claim Eligibility"
subtitle: "Evidence-First Fence to Prevent Partial/Empty Runs from Appearing as Valid Comparisons"
review_date: 2026-03-18
status: PENDING_SIGN_OFF
applies_to: "all benchmark classification and evidence aggregation"
---

# METHODOLOGY REVIEW
## Status & Claim Eligibility for Benchmark Evidence Integrity

---

## EXECUTIVE SUMMARY

**Issue Identified:** Current benchmark status model allows partial/empty runs to be misclassified as valid comparison-eligible results. A benchmark that exits 0 with empty JSON can be marked "ok" or "partial" instead of "failed", causing evidence lab to include zero-result data in comparison analyses.

**Solution:** Formalize exact semantics for runner_status (3 values), reproducibility_status (4 values), final_reason (9 codes), and claim_scope (4 values). **Enforce hard gates** that prevent any run with empty JSON or incomplete reproducibility from being used for comparison claims.

**Status:** ✅ **METHODOLOGY SOUND** (conditional on implementation of gating logic)

---

## METHODOLOGY VERDICT

### **SOUND**

This methodology is **sound** IF AND ONLY IF:
1. ✅ Exact semantics documented (COMPLETE — see `docs/status-and-claim-eligibility.md`)
2. ✅ CSV schema committed with claim_scope field (COMPLETE)
3. ✅ Hard gates enforced in evidence lab (IMPLEMENTATION REQUIRED)
4. ✅ Test matrix validates all 10 cases (IMPLEMENTATION REQUIRED)
5. ✅ Verification script runs on every status.csv (IMPLEMENTATION REQUIRED)

**Without enforcement (Phase 3-5), verdict downgrades to CONDITIONALLY_SOUND.**

---

## COMPARISON AXIS

**WITHIN_TIER_SAME_PROTOCOL**

The methodology is designed to prevent overclaiming within a single tier and protocol by:
- Defining exact runner_status semantics (no ambiguous "ok" or "partial")
- Separating comparison claims (fully valid evidence) from descriptive claims (incomplete evidence)
- Enforcing that claim_scope="comparison_eligible" requires ALL three: runner=success, repro=complete, final_reason=ok

**Cross-tier and cross-protocol comparisons still require matching protocol_mode and benchmark_family per existing rules.**

---

## MAIN RISKS & ACCEPTANCE CRITERIA

### RISK 1: Partial Runs Included in Comparison Aggregations
**Status:** ❌ **CRITICAL** — Currently possible; gating logic will prevent

**Evidence:**
- Current status.sh produces runner_status="partial" but CSV does not enforce its non-eligibility
- Evidence lab (compare-results.sh) does not check claim_scope before including runs
- No validation prevents averaging partial + complete runs

**Fix:** (Phase 3 implementation)
- Add claim_scope check in compare-results.sh: skip non-comparison_eligible runs
- Add test case: verify partial run excluded from regression analysis
- Extract rejected reasons to log for audit trail

**Acceptance:** ✅ Gating code committed + test passes + partial run correctly excluded

---

### RISK 2: Empty JSON Misrepresented as Valid
**Status:** ❌ **CRITICAL** — Currently possible; exact semantics will prevent

**Evidence:**
- B7-wrapUnwrapRoundTrip(16384) warms up, fails, exits 0 → json_rows=0, completed_cases=0
- Current classifier might mark runner_status="ok" if json_row_count check is missing
- CSV doesn't capture "actually zero useful results" as distinct from "some results"

**Fix:** (Phase 1 implementation)
- Update runner_status logic: if json_rows == 0 → always runner="failed" (regardless of exit code)
- Update reproducibility_status logic: if runner="failed" → always repro="not_assessable"
- Update claim_scope logic: if runner="failed" → always claim="none"

**Acceptance:** ✅ Classification logic correctly produces runner=failed for empty JSON

---

### RISK 3: Missing Metadata Allows Unrepeatable Baselines
**Status:** ⚠️ **MEDIUM** — Existing rule (incomplete_metadata) but not enforced

**Evidence:**
- Baseline created without hardware_profile or jvm_flags
- run stored as comparison_eligible but reproducibility_status=incomplete_metadata
- Future run on different hardware appears to regress vs unrepeatable baseline

**Fix:** (Phase 1 implementation)
- reproducibility_status must be "complete" for claim_scope="comparison_eligible"
- Verify all of commit_sha, jdk_version, hardware_profile, jvm_flags, scenario_id present
- Update final_reason to "missing_metadata" when incomplete

**Acceptance:** ✅ Baseline with missing metadata gets claim_scope=descriptive_only (not comparison_eligible)

---

### RISK 4: Missing Artifacts (JFR, Metrics) Block Claims Silently
**Status:** ⚠️ **MEDIUM** — Existing check but not enforced for claim_scope

**Evidence:**
- Run attempts zero-allocation benchmark but JFR recording fails (JVM crash before flush)
- runner_status=success, but jfr_expected=true, jfr_collected=false
- Evidence lab might still include in allocation analysis

**Fix:** (Phase 2 implementation)
- reproducibility_status: if (jfr_expected AND NOT jfr_collected) or (metrics_expected AND NOT metrics_collected) → incomplete_artifacts
- claim_scope: if reproducibility_status != complete → NOT comparison_eligible
- final_reason: missing_jfr or missing_metrics (with priority)

**Acceptance:** ✅ Run with missing JFR correctly marked claim_scope=descriptive_only

---

### RISK 5: Fuzzy Status Codes Allow Interpretation Drift
**Status:** ✅ **RESOLVED** — Exact semantics defined

**Evidence:**
- Old status.sh had: "ok", "benchmark_failed", "postprocess_failed", "jfr_missing", "incomplete_metrics", "incomplete_jvm_metadata"
- No clear semantics → different tools interprets differently
- Examples: "partial" was sometimes "ok with warnings", sometimes "unusable"

**Fix:** (PHASE 1 — COMPLETE IN METHODOLOGY DOC)
- runner_status: exactly 3 values (success | partial | failed) with precise conditions
- reproducibility_status: exactly 4 values (complete | incomplete_artifacts | incomplete_metadata | not_assessable)
- final_reason: exactly 9 codes in priority order (ok, partial_json, empty_json, invalid_json, benchmark_exit_nonzero, postprocess_exit_nonzero, missing_jfr, missing_metrics, missing_metadata)
- claim_scope: exactly 4 values (comparison_eligible | descriptive_partial | descriptive_only | none)

**Acceptance:** ✅ Semantics documented in status-and-claim-eligibility.md

---

## MINIMAL CORRECTIONS REQUIRED

### 1. **Implement Classification Functions** (tools/bench/lib/status.sh)
- ✅ Specification: [docs/implementation-spec-status-classification.md](docs/implementation-spec-status-classification.md)
- [ ] Implement: compute_runner_status(), compute_reproducibility_status(), compute_final_reason(), compute_claim_scope()
- [ ] Update classify_bench_status() call signature to accept metadata parameters
- **Timeline:** Phase 1 (implementation)

### 2. **Update CSV Schema & Functions** (tools/bench/lib/csv-writer.sh)
- ✅ Schema: [docs/status-and-claim-eligibility.md § CSV Schema](#csv-schema-statuscsv)
- [ ] Add 30 new columns to Header
- [ ] Update write_status_csv() to accept all fields
- [ ] Ensure timestamp, benchmark_id, tier, protocol_mode, execution_class captured
- **Timeline:** Phase 2 (implementation)

### 3. **Add Verification Script** (tools/verify-classification.sh)
- ✅ Script: [tools/verify-classification.sh](../../tools/verify-classification.sh)
- [ ] Run on every status.csv generation in CI
- [ ] Fail build if any hard rule violated
- [ ] Report errors with row numbers + field values
- **Timeline:** Phase 2 (implementation)

### 4. **Update Benchmark Runners** (tools/bench/run-jmh-case.sh, runtime drivers)
- [ ] Pass new parameters to classify_bench_status():
  - jfr_expected (boolean)
  - metrics_expected (boolean)
  - commit_sha, jdk_version, hardware_profile, jvm_flags, scenario_id
- [ ] Capture metadata from capture-env.sh output
- [ ] Compute expected_case_count correctly
- **Timeline:** Phase 2 (implementation)

### 5. **Add Gating in Evidence Lab** (scripts/compare-results.sh, dashboard)
- ✅ Rules: [docs/status-and-claim-eligibility.md § Claim Eligibility Rules](#claim-eligibility-rules-hard-gates)
- [ ] Reject comparisons if any run has claim_scope ≠ "comparison_eligible"
- [ ] Log rejection reason + final_reason code
- [ ] Prevent arithmetic (mean, stddev, regression) on mixed claim_scope
- **Timeline:** Phase 3 (implementation)

### 6. **Test Matrix Validation** (tools/bench/tests/test-classification.sh)
- ✅ Test spec: [docs/implementation-spec-status-classification.md § Test Execution](#test-execution)
- [ ] All 10 matrix cases pass
- [ ] Verify exact output of runner_status, reproducibility_status, final_reason, claim_scope for each
- [ ] Test added to CI: runs with every benchmark execution
- **Timeline:** Phase 2 (implementation)

### 7. **Update Documentation**
- ✅ Main doc: [docs/status-and-claim-eligibility.md](docs/status-and-claim-eligibility.md)
- ✅ Implementation spec: [docs/implementation-spec-status-classification.md](docs/implementation-spec-status-classification.md)
- [ ] Update docs/result-interpretation.md with link + summary of claim_scope rules
- [ ] Update README.md with pointer to methodology
- **Timeline:** Phase 4 (documentation)

---

## FAIRNESS & REPRODUCIBILITY ASSESSMENT

### Fairness ✅ SOUND

**Does this methodology prevent apples-to-oranges claims?**
- ✅ YES: Claim eligibility requires protocol_mode + benchmark_family matching (existing rule preserved)
- ✅ YES: Tier explicitly stated; claim_scope prevents cross-tier rollup without caveat
- ✅ YES: Empty/partial runs excluded from any comparison, not reweighted as "unknown"

### Reproducibility ✅ SOUND

**Does this capture enough metadata for future reproduction?**
- ✅ YES: reproducibility_status requires commit_sha, jdk_vendor, jdk_version, hardware_profile, jvm_flags, scenario_id
- ✅ YES: claim_scope=comparison_eligible iff reproducibility_status=complete
- ✅ YES: Missing metadata explicitly tracked (final_reason=missing_metadata, claim_scope=descriptive_only)

### Evidence Integrity ✅ SOUND

**Does this prevent false claims?**
- ✅ YES: runner_status=failed + claim_scope=none → zero claims allowed
- ✅ YES: runner_status=partial + claim_scope=descriptive_partial → no regression/improvement claims
- ✅ YES: reproducibility_status!=complete + claim_scope!=comparison_eligible → no baseline claims

---

## CONSTRAINT ALIGNMENT

**Exeris Bench Core Instructions (mandatory):**
- [x] Mission: "Do not produce claims that exceed benchmark evidence" — **ENFORCED:** claim_scope=none prevents any claim on empty/failed runs
- [x] Mandatory Separation Axes: "Never collapse conclusions across axes without explicit caveats" — **ENFORCED:** protocol_mode + benchmark_family matching required; tier explicit in CSV
- [x] Fairness Rules: "Match payload, concurrency, protocol mode for comparisons" — **PRESERVED:** existing rule; claim scope adds "AND metadata must be complete"
- [x] Reproducibility Rules: "Capture commit SHA, JDK/tool versions, JVM flags, hardware profile, scenario id" — **ENFORCED:** reproducibility_status requires all; final_reason marks missing

**Exeris Bench Reporting Instructions (guided):**
- [x] "Honest interpretation" — claim_scope prevents honest misinterpretation of partial as complete
- [x] "Explicit labels" — final_reason + claim_scope provide exact label for every result
- [x] "Confidence in data" — empty/partial runs downgraded to descriptive_only or none

---

## TEST CASES & VERIFICATION

### Test Matrix (10 Cases) — See docs/status-and-claim-eligibility.md § Test Matrix

All cases MUST classify correctly:

| # | exit_code | json_rows | metadata | artifacts | runner | repro | reason | scope | Status |
|---|-----------|-----------|----------|-----------|--------|-------|--------|-------|--------|
| 1 | 0 | >0 | ✓ | ✓ | success | complete | ok | comparison_eligible | ✅ Perfect |
| 2 | 0 | >0 | ✓ | ✗ | success | incomplete_artifacts | missing_jfr | descriptive_only | ⚠️ Artifact missing |
| 3 | 0 | >0 | ✗ | ✓ | success | incomplete_metadata | missing_metadata | descriptive_only | ⚠️ Metadata missing |
| 4 | 0 | >0 | ✗ | ✗ | success | incomplete_metadata | missing_metadata | descriptive_only | ⚠️ Both missing |
| 5 | 0 | 0 | ✓ | ✓ | **failed** | not_assessable | **empty_json** | **none** | 🚫 No results (KEY FIX) |
| 6 | 0 | 0 | ✓ | ✗ | failed | not_assessable | empty_json | none | 🚫 No results |
| 7 | N | >0 | ✓ | ✓ | **partial** | complete | **partial_json** | **descriptive_partial** | ⚠️ Some results (KEY FIX) |
| 8 | N | >0 | ✓ | ✗ | partial | incomplete_artifacts | partial_json | descriptive_partial | ⚠️ Partial + missing artifact |
| 9 | N | 0 | ✓ | ✓ | failed | not_assessable | benchmark_exit_nonzero | none | 🚫 Crashed |
| 10 | 0 | >0 | ✓ | ✓ (pp_rc≠0) | partial | complete | postprocess_exit_nonzero | descriptive_partial | ⚠️ Results OK, extraction failed |

**Key Fixes (Bold):**
- **Case 5:** Exit 0 with empty JSON now correctly → runner=failed (was potentially "ok")
- **Case 7:** Exit nonzero with some rows now correctly → runner=partial, claim=descriptive_partial (was potentially "ok")

---

## HARD GATES — ENFORCEMENT RULES

**These rules are non-negotiable. Violation = failed build in CI.**

1. ✅ **No claim_scope="comparison_eligible" unless runner=success AND repro=complete AND final_reason=ok**
   - Gating location: Evidence lab (compare-results.sh, dashboard query)
   - Test: Attempt comparison with partial run → rejected + logged

2. ✅ **No arithmetic/averaging across different claim_scope values**
   - Gating location: Chart/dashboard aggregation functions
   - Test: Dashboard attempts to average [descriptive_partial, comparison_eligible] → rejected

3. ✅ **Every status.csv row MUST pass verification script**
   - Gating location: CI pipeline (post-generation validation)
   - Test: Run verify-classification.sh; exit 0 = pass, exit 1 = build fails

4. ✅ **No performance claim can be made on runner_status=failed**
   - Gating location: Report template, dashboard
   - Test: Display rule prevents displaying performance number for failed run

---

## SIGN-OFF REQUIREMENTS

**Methodology is LOCKED for sign-off when ALL of the following are true:**

- [x] **A. Exact semantics defined**
  - [x] runner_status: 3 values (success, partial, failed) with precise conditions ← documented in status-and-claim-eligibility.md
  - [x] reproducibility_status: 4 values (complete, incomplete_artifacts, incomplete_metadata, not_assessable) ← documented
  - [x] final_reason: 9 codes in priority order ← documented
  - [x] claim_scope: 4 values (comparison_eligible, descriptive_partial, descriptive_only, none) ← documented

- [ ] **B. CSV schema committed & enforced**
  - [ ] Header includes all 30 fields ← PENDING: Phase 2 implementation
  - [ ] Field definitions precise + non-optional ← PENDING: Phase 2
  - [ ] No ambiguous encoding (e.g., use "true"/"false" not "yes"/"no") ← PENDING: Phase 2

- [ ] **C. Classification logic implemented**
  - [ ] classify_bench_status() computes exact runner_status ← PENDING: Phase 1
  - [ ] Reproducibility_status computed from metadata presence ← PENDING: Phase 1
  - [ ] final_reason applied in priority order ← PENDING: Phase 1
  - [ ] claim_scope derived automatically ← PENDING: Phase 1

- [ ] **D. Test matrix validation**
  - [ ] All 10 cases classify correctly ← PENDING: Phase 2 + test
  - [ ] Test runs in CI on every benchmark ← PENDING: Phase 2 + CI config
  - [ ] Automated verification catches violations ← verify-classification.sh ready, PENDING: Phase 2 + CI

- [ ] **E. Gating enforced in evidence lab**
  - [ ] compare-results.sh rejects non-comparison_eligible runs ← PENDING: Phase 3
  - [ ] Dashboard/report template only reads comparison_eligible for regression sections ← PENDING: Phase 4
  - [ ] Metrics/statistics functions reject mixed claim_scope ← PENDING: Phase 3

- [ ] **F. No status.csv row violates rules**
  - [ ] claim_scope="comparison_eligible" ⟹ final_reason="ok" ← automated verification
  - [ ] runner="failed" ⟹ claim_scope="none" ← automated verification
  - [ ] json_rows=0 ⟹ runner="failed" ← automated verification
  - [ ] repro≠complete ⟹ claim_scope≠comparison_eligible ← automated verification

- [ ] **G. Documentation updated**
  - [ ] docs/result-interpretation.md references this methodology ← PENDING: Phase 4
  - [ ] README.md points to claim eligibility rules ← PENDING: Phase 4
  - [x] Implementation spec provided ← docs/implementation-spec-status-classification.md ✓

---

## MINIMAL IMPACT ANALYSIS

**What breaks if we implement this?**

1. **CSV format changes** (backward-incompatible)
   - Old scripts that parse status.csv must handle new columns
   - Remediation: Update compare-results.sh, dashboard query, report generators
   - Risk: LOW — changes are additive (new claim_scope column); old tools can ignore

2. **Baseline comparison may reject old runs**
   - Baseline stored without metadata/JFR → reproducibility_status=incomplete_metadata → claim_scope=descriptive_only
   - Cannot be used for regression comparison
   - Remediation: Recapture baseline with full metadata
   - Risk: MEDIUM — may need to rebuild some baselines; one-time cost

3. **Partial runs now excluded from averaging**
   - Old reports that averaged all runs now exclude partial runs
   - Results may shift slightly if partial runs were outliers
   - Remediation: Document exclusion in report; explain why more accurate
   - Risk: LOW — exclusion is correct behavior; removes noise

---

## FINAL ASSESSMENT

### Methodology Verdict: **✅ SOUND (Conditionally)**

**Why Sound:**
- Exact, unambiguous semantics prevent misclassification (e.g., empty JSON → failed, not ok)
- Hard gates prevent partial/empty runs from appearing in comparison claims
- Reproducibility captured and enforced for comparison eligibility
- Test matrix covers all important cases
- Aligns with core constraints (evidence-first, fairness, reproducibility)

**Why Conditional:**
- Gating logic (Phase 3-5) not yet implemented in evidence lab
- Until that implementation, methodology is guidance + not enforced
- Verdict will upgrade to **UNEQUIVOCALLY SOUND** after Phases 1-5 complete

### Risk Summary

| Risk | Severity | Addressed By |
|------|----------|--------------|
| Partial runs in comparisons | CRITICAL | Hard gate in Phase 3 |
| Empty JSON misclassified | CRITICAL | Exact semantics Phase 1 |
| Missing metadata → unrepeatable | MEDIUM | Metadata completeness check Phase 1 |
| Missing artifacts → false zero-alloc claims | MEDIUM | Artifact completeness check Phase 2 |
| Fuzzy status codes | HIGH | Enum semantics Phase 1 ✓ |

---

## NEXT STEPS

### Immediate (This Week)

1. ✅ Finalize methodology document (status-and-claim-eligibility.md) ← COMPLETE
2. ✅ Finalize implementation spec (implementation-spec-status-classification.md) ← COMPLETE
3. ✅ Finalize verification script (tools/verify-classification.sh) ← COMPLETE
4. Review & approve methodology by Benchmark Architecture team

### Phase 1 (Next Sprint)

- Implement classification functions in tools/bench/lib/status.sh
- Update classifier call sites (run-jmh-case.sh, runtime drivers)
- Test: All 10 matrix cases pass

### Phase 2-5 (Following Sprints)

- See: [docs/implementation-spec-status-classification.md § Implementation Roadmap](docs/implementation-spec-status-classification.md)

---

## SIGN-OFF

**Current Status:** 🔴 **PENDING SIGN-OFF** (awaiting approvals below)

**Approvals Required:**

- [ ] Benchmark Architecture Review — Verify methodology soundness
- [ ] Implementation Lead — Confirm Phase 1-5 feasible, resource-leveled
- [ ] Evidence Lab Owner — Commit to Phase 3 gating enforcement
- [ ] Reporting/Dashboard Owner — Commit to Phase 4 UI constraints

---

## APPENDICES

### Appendix A: Related Documents

- [docs/status-and-claim-eligibility.md](status-and-claim-eligibility.md) — Main methodology (421 lines)
- [docs/implementation-spec-status-classification.md](implementation-spec-status-classification.md) — Code changes (5 phases)
- [tools/verify-classification.sh](../../tools/verify-classification.sh) — Verification script (hard gates)
- [docs/methodology.md](methodology.md) — Existing methodology (benchmark design, warmup, JVM flags)
- [.github/instructions/exeris-bench-core.instructions.md](../../.github/instructions/exeris-bench-core.instructions.md) — Core fairness/reproducibility rules

### Appendix B: Glossary

- **runner_status**: Did the benchmark harness produce evidence (JSON rows)?
- **reproducibility_status**: Do all required metadata + artifacts exist?
- **final_reason**: Specific failure code explaining why run cannot be used for comparison
- **claim_scope**: What claims (if any) can be made from this run?
- **claim_eligibility**: Hard gate determining if run can be included in comparison/regression analysis
- **comparison_eligible**: Run produces valid evidence, has complete metadata, can be compared to other comparison_eligible runs
- **partial**: Benchmark produced some result rows but exited abnormally or had post-processing failure
- **failed**: Benchmark produced zero result rows (no evidence)

---

**Document Prepared By:** Benchmark Methodology/Results Agent  
**Date:** 2026-03-18  
**Version:** 1.0 (READY FOR REVIEW)  
**Status:** PENDING SIGN-OFF

