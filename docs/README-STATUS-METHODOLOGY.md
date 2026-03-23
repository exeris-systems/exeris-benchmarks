# Benchmark Status & Claim Eligibility — Methodology & Implementation

This directory contains the complete specification for preventing partial/empty benchmark runs from being misrepresented as valid comparison evidence.

## 📋 Core Documents

### [REPORT-INTAKE-ROUTED-BACKLOG.md](REPORT-INTAKE-ROUTED-BACKLOG.md)
Execution backlog derived from external Java performance report analysis, routed by Exeris separation axes and evidence-first claim constraints.

### [status-and-claim-eligibility.md](status-and-claim-eligibility.md) (421 lines)
**THE METHODOLOGY SPECIFICATION**

Defines exact semantics for:
- **runner_status** (3 values: success, partial, failed)
- **reproducibility_status** (4 values: complete, incomplete_artifacts, incomplete_metadata, not_assessable)
- **final_reason** (9 codes: ok, partial_json, empty_json, invalid_json, benchmark_exit_nonzero, postprocess_exit_nonzero, missing_jfr, missing_metrics, missing_metadata)
- **claim_scope** (4 values: comparison_eligible, descriptive_partial, descriptive_only, none)

Also includes:
- CSV schema with all 30 required fields
- Hard claim eligibility rules
- Test matrix (10 cases covering all classification combinations)

**Read this first.** This is the source of truth for what each status value means and when claims can be made.

---

### [implementation-spec-status-classification.md](implementation-spec-status-classification.md) (470 lines)
**HOW TO IMPLEMENT**

Step-by-step code changes for:
- Updating `tools/bench/lib/status.sh` with new classification functions
- Updating `tools/bench/lib/csv-writer.sh` to produce new CSV schema
- Creating `tools/bench/tests/test-classification.sh` to validate 10 test cases
- Adding gating in evidence lab (compare-results.sh, dashboards)

Includes:
- Exact function signatures and implementations
- Migration plan (backward-compatible rollout)
- Sign-off checklist

**Read this if you're implementing the classification logic.**

---

### [METHODOLOGY-REVIEW-STATUS-CLAIM-ELIGIBILITY.md](METHODOLOGY-REVIEW-STATUS-CLAIM-ELIGIBILITY.md) (437 lines)
**METHODOLOGY REVIEW & SIGN-OFF**

Complete methodology review in Exeris Bench Methodology/Results Review format:
- **Verdict:** ✅ SOUND (conditional on Phase 3-5 implementation)
- **Comparison Axis:** WITHIN_TIER_SAME_PROTOCOL
- **Main Risks:** Identified and addressed
- **Hard Gates:** 4 enforceable rules
- **Sign-Off Requirements:** 7 criteria with implementation phases

Ties everything together and provides the approval roadmap.

**Read this for the final sign-off verdict and implementation roadmap.**

---

### [benchmark-scenario-maturity.md](benchmark-scenario-maturity.md)
**SCENARIO MATURITY & TOOL-ROLE GUIDE**

Defines scenario maturity progression (exploratory, descriptive baseline, comparative baseline), promotion hard gates, and tool-role separation (`wrk`, `k6`, `h2load`, Hyperfoil reserve) aligned with Exeris claim/evidence vocabulary.

---

### [comparative-readiness-checklist-cross-runtime.md](comparative-readiness-checklist-cross-runtime.md)
**CROSS-RUNTIME COMPARISON READINESS CHECKLIST**

Operational guardrails for maturity, equivalence, fairness, measurement policy, and evidence-bounded claim discipline across runtime targets.

### [comparative-readiness-checklist.md](comparative-readiness-checklist.md)
Comparative readiness checklist for cross-runtime baseline eligibility.
If Spring/Quarkus launcher assets are missing for declared target profiles, classification remains non-comparative until runnable assets exist.

---

### [benchmark-target-labels-and-scenario-contracts.md](benchmark-target-labels-and-scenario-contracts.md)
**TARGET LABELS & SCENARIO CONTRACT SPEC**

Defines `target_id` and `target_descriptor`, initial runtime target labels, required scenario contract fields, and endpoint/workflow YAML templates used for strict comparison gating.

---

## Comparative Execution Machinery

Structural comparative runtime machinery now exists for the declared `entity-read-by-id` within-tier, same-protocol Community/H1/loopback runtime path.

Current comparative artifacts:

- `scripts/run-comparative.sh` orchestrates paired runtime execution for a declared scenario and contract.
- `scripts/validate-comparative-readiness.sh` applies the comparative readiness gates to both result bundles.
- `tools/compute-fairness-index.sh` produces the fairness artifact consumed by comparative outputs.
- `scripts/aggregate-comparative-results.sh` aggregates repeated comparative runs into a campaign summary.
- `scenarios/entity-read-by-id/comparative-pair-manifest.json` declares the currently allowed target pair and measurement constraints for this path.

Structural verification is in place. No claim-eligible dual-target comparative execution has yet been captured and reviewed; first publishable comparative reporting remains pending until complete run artifacts are captured and reviewed.

## 🔧 Implementation Artifact

### [tools/verify-classification.sh](../../tools/verify-classification.sh) (executable)
**VERIFICATION & ENFORCEMENT**

Bash script that validates every status.csv row for consistency:
- Enforces all 10 hard rules
- Checks enum values, semantic constraints
- Produces detailed error messages
- Used in CI/CD: must pass on every status.csv generation

**Run this after every benchmark run:**
```bash
bash tools/verify-classification.sh results/status.csv
```

---

## 🚀 Implementation Phases

| Phase | Work | Duration | Owner | Gating |
|-------|------|----------|-------|--------|
| 1 | Classification logic (status.sh) | Week 1 | Implementation | verify-classification.sh must pass 10 test cases |
| 2 | CSV schema + test matrix | Week 1 | Implementation | All benchmarks produce valid CSV |
| 3 | Evidence lab gating | Week 2 | Evidence Lab | Compare-results.sh rejects non-comparison_eligible |
| 4 | Report / Dashboard UI | Week 2 | Reporting | Dashboard only reads comparison_eligible for regression sections |
| 5 | Documentation + Testing | Week 3 | Docs/QA | All docs updated + CI validation live |

---

## 📖 How to Use These Documents

**I need to understand the exact status/claim semantics:**
→ Read [status-and-claim-eligibility.md](status-and-claim-eligibility.md) § Exact Status Semantics

**I need to implement the classification logic:**
→ Read [implementation-spec-status-classification.md](implementation-spec-status-classification.md) § Files to Modify

**I need to verify a status.csv is valid:**
→ Run `bash tools/verify-classification.sh status.csv`

**I need to identify what failed and why:**
→ Check `final_reason` and `claim_scope` columns in status.csv

**I need to know what comparisons I can make:**
→ Read [status-and-claim-eligibility.md](status-and-claim-eligibility.md) § Claim Eligibility Rules

**I need to brief leadership on the methodology:**
→ Share [METHODOLOGY-REVIEW-STATUS-CLAIM-ELIGIBILITY.md](METHODOLOGY-REVIEW-STATUS-CLAIM-ELIGIBILITY.md)

---

## 🎯 Quick Reference: Status Decision Tree

```
Benchmark ran?
├─ No (exit != 0, no JSON)
│  └─ runner_status = FAILED
│     └─ claim_scope = NONE (zero claims)
│
└─ Yes (exit == 0, JSON has rows)
   └─ runner_status = SUCCESS
      ├─ All metadata present?
      │  ├─ Yes (commit_sha, JDK, hardware, flags, scenario)
      │  │  ├─ All expected artifacts present?
      │  │  │  ├─ Yes (JFR/metrics if expected)
      │  │  │  │  └─ claim_scope = COMPARISON_ELIGIBLE ✅
      │  │  │  │
      │  │  │  └─ No (missing JFR or metrics)
      │  │  │     └─ claim_scope = DESCRIPTIVE_ONLY ⚠️
      │  │  │
      │  │  └─ final_reason = missing_metadata
      │  │     └─ claim_scope = DESCRIPTIVE_ONLY ⚠️
      │  │
      │  └─ No (missing commit_sha, hardware, etc.)
      │     └─ claim_scope = DESCRIPTIVE_ONLY ⚠️
      │
      └─ Partial results (exit != 0 but some rows)
         └─ runner_status = PARTIAL
            └─ Can only describe completed rows; no regression/improvement claims
            └─ claim_scope = DESCRIPTIVE_PARTIAL ⚠️
```

---

## ✅ Acceptance Criteria

Methodology is locked for sign-off when:

- [x] Exact semantics document written (status-and-claim-eligibility.md)
- [x] Implementation spec written (implementation-spec-status-classification.md)
- [x] Verification script written (tools/verify-classification.sh)
- [ ] Classification logic implemented (Phase 1)
- [ ] CSV schema in use (Phase 2)
- [ ] Evidence lab gating enforced (Phase 3)
- [ ] Test matrix validates 10 cases (Phase 2)
- [ ] No status.csv row violates hard rules (automated via verify-classification.sh)
- [ ] Dashboard/reports only read comparison_eligible runs (Phase 4)

---

## Questions?

- **"What does runner_status=partial mean?"** → See status-and-claim-eligibility.md § runner_status
- **"Can I compare these two runs?"** → Check both have claim_scope=comparison_eligible
- **"Why did my benchmark get claim_scope=descriptive_only?"** → Check final_reason column in status.csv
- **"How do I capture metadata for reproducibility?"** → Run `capture-env.sh` before benchmark, pass output to classifier
- **"How do I know if my implementation is correct?"** → Run verify-classification.sh; must pass all 10 test cases

---

**Last Updated:** 2026-03-18  
**Methodology Status:** PENDING SIGN-OFF  
**Implementation Status:** PHASES 1-5 NOT STARTED IN THIS STATUS-CLASSIFICATION TRACK; PHASE 6.3/6.4 COMPARATIVE MACHINERY IMPLEMENTED AND STRUCTURALLY VERIFIED; NO CLAIM-ELIGIBLE DUAL-TARGET COMPARATIVE EXECUTION EVIDENCED HERE YET

