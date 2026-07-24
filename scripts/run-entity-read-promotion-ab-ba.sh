#!/usr/bin/env bash
# =============================================================================
# entity-read-by-id — PROMOTION through the full comparative gate
#
# exeris-community vs quarkus-tuned (flagship pair), ab/ba, through run-full-triad-ab-ba.sh
# -> run-comparative.sh stage7 -> the 4 strict-gate artifacts (stage7-gate-report.csv,
# stage7-gate-summary.json, claim-status.json, rejection-codes.json). Certifies
# comparison_eligible for BOTH endpoints (light single-read + heavy aggregate) at 256m + 1024m
# budgets, 4 vCPU pinned, tuned-PG reused.
#
# MEMORY MODEL: NATIVE comparative gate = -XX:MaxRAM=<budget> + explicit per-arm heaps (NOT a
# cgroup MemoryMax). This is the official flagship path; it does NOT reproduce the cgroup-capped
# exploratory sweeps (different track). At MaxRAM-256 quarkus does NOT hard-OOM the way it did
# under cgroup-256, so 256m yields a real head-to-head here (a separate result from the sweep's
# floor finding). Heaps kept at each runtime's fraction (exeris 0.25x / quarkus 0.75x).
#
# Order: HEAVY first (120s window) so the path validates in ~15min before the LIGHT legs (900s
# immutable window, ~20min/leaf). JFR OFF (gate artifacts are the deliverable, not diagnostics).
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
TRIAD="$REPO_ROOT/scripts/run-full-triad-ab-ba.sh"
[[ -f "$TRIAD" ]] || { echo "ERROR: missing $TRIAD" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

PAIR="${PROMOTION_PAIR:-1-exeris-vs-quarkus-tuned:exeris-community:quarkus-tuned:1:9000:9003}"

# tuned-PG creds (reused host-net PG uses benchmark/benchmark_db; target env defaults to
# 'postgres' -> HikariPool FATAL role does not exist). All arms read EXERIS_DB_* (quarkus maps
# quarkus.datasource.* from them). Matches the proven latency-curve wrapper.
export EXERIS_DB_JDBC_URL="${EXERIS_DB_JDBC_URL:-jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1}"
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"
export BENCH_DB_TUNED="${BENCH_DB_TUNED:-1}"
export BENCHMARK_ALLOW_EXTERNAL_DB="${BENCHMARK_ALLOW_EXTERNAL_DB:-1}"
# Skip the Stage-2 mvn ContractTest gate (redundant: jars contract-verified at build; endpoint
# still HTTP-200 preflighted) so its CPU burst never contaminates a measurement window.
export BENCHMARK_SKIP_ENDPOINT_CONTRACT_GATE="${BENCHMARK_SKIP_ENDPOINT_CONTRACT_GATE:-1}"
# No JFR: the promotion's deliverable is the gate artifacts, not 2-3GB/leaf diagnostics.
export BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS="${BENCH_ENABLE_SAFEPOINT_DIAGNOSTICS:-0}"

UTC="$(date -u +%Y%m%d-%H%M%S)"
ROOT="${PROMOTION_ROOT:-results/raw/entity-read-by-id/${UTC}-promotion-ab-ba}"
mkdir -p "$ROOT"
STATUS="$ROOT/promotion-status.jsonl"; : > "$STATUS"

# budget | exeris_heap | quarkus_heap | endpoint_label | contract | warmup_s | measurement_s
# (HEAVY first for fast validation. The window MUST match each contract's IMMUTABLE knobs, or the
# fail-closed contract check aborts: heavy h1_v1 = 60/120, light single_read_v1 = 300/900. The
# triad harness defaults WARMUP_SECONDS=60/MEASUREMENT_SECONDS=120 — fine for heavy, wrong for light.)
COMBOS=(
  "1024|256|768|heavy|fixed_contract_cross_runtime_h1_v1|60|120"
  "256|64|192|heavy|fixed_contract_cross_runtime_h1_v1|60|120"
  "1024|256|768|light|fixed_contract_cross_runtime_h1_single_read_v1|300|900"
  "256|64|192|light|fixed_contract_cross_runtime_h1_single_read_v1|300|900"
)
# PROMOTION_ONLY: empty = all combos; "light" / "heavy" runs just that subset (for re-running a leg).
PROMOTION_ONLY="${PROMOTION_ONLY:-}"

echo "[promotion] root: $ROOT"
echo "[promotion] pair: $PAIR"
echo "[promotion] partition: target 0-1,8-9 / loadgen 2-3,10-11 / DB 4-7,12-15 (tuned-PG, MaxRAM budgets)"

for combo in "${COMBOS[@]}"; do
  IFS='|' read -r budget eheap qheap eplabel contract warmup measure <<< "$combo"
  [[ -n "$PROMOTION_ONLY" && "$eplabel" != "$PROMOTION_ONLY" ]] && continue
  out="$ROOT/${eplabel}/budget-${budget}m"
  echo ""
  echo "############ ${eplabel} budget=${budget}m (exeris ${eheap}m / quarkus ${qheap}m heap) contract=${contract} window=${warmup}+${measure}s ############"
  WARMUP_SECONDS="$warmup" MEASUREMENT_SECONDS="$measure" \
  BENCH_TRIAD_PAIRS="$PAIR" \
  BENCH_CONTRACT_ID="$contract" \
  BENCH_TOTAL_MEMORY_MB="$budget" \
  BENCH_EXERIS_HEAP_MB="$eheap" BENCH_QUARKUS_HEAP_MB="$qheap" BENCH_SPRING_HEAP_MB="$qheap" \
  BENCH_SERVER_CPU_AFFINITY="0-1,8-9" BENCH_LOADGEN_CPU_AFFINITY="2-3,10-11" \
  BENCH_RUNS_PER_PAIR=1 \
  BENCH_CAMPAIGN_OUTPUT_DIR_OVERRIDE="$out" \
    bash "$TRIAD" || echo "  [triad rc=$?]"
  while IFS= read -r cs; do
    st="$(jq -r '.claim_status // .final_status // "?"' "$cs" 2>/dev/null)"
    printf '{"endpoint":"%s","budget":%s,"order":"%s","claim_status":"%s"}\n' \
      "$eplabel" "$budget" "$(basename "$(dirname "$cs")")" "$st" >> "$STATUS"
  done < <(find "$out" -name claim-status.json 2>/dev/null)
  echo "  [$eplabel ${budget}m] claim_status: $(find "$out" -name claim-status.json -exec jq -r '.claim_status // "?"' {} \; 2>/dev/null | sort | uniq -c | tr '\n' ' ')"
done

echo ""
echo "===== PROMOTION DONE -> $ROOT ====="
cat "$STATUS" 2>/dev/null
