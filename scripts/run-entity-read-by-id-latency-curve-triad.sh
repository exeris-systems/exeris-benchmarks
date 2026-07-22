#!/usr/bin/env bash
# =============================================================================
# entity-read-by-id — wrk2 CO-free latency-load CURVE over the cross-runtime triad
#
# Comparison-eligible p99 latency vs offered load, for the quarkus-focused triad
# (exeris-community + quarkus-tuned + quarkus-hibernate), LIGHT and HEAVY endpoints,
# swept across a ladder of fixed offered rates (wrk2 open loop -> percentiles = true
# service time). Delegates to run-full-triad-ab-ba.sh once per (endpoint, rung) with
# BENCH_DRIVER_MODE=open + BENCH_OFFERED_RPS. Each harness invocation runs all 3 pairs
# in both orders (ab/ba), BENCH_RUNS_PER_PAIR=1.
#
# Shape: 3 pairs x (ab,ba) x 5 rungs x 2 endpoints = 60 leaves. 120s window
# (60s warmup + 120s measure) via the wrk2 p99_stable contracts.
#
# Endpoint contracts (immutable window/endpoint; contract_id is the isolation key):
#   heavy: fixed_contract_p99_stable_h1_wrk2_v1             (GET /api/v1/users, aggregate)
#   light: fixed_contract_p99_stable_h1_wrk2_single_read_v1 (GET /api/v1/user?id=1, single)
#
# Rate ladders MUST stay below each endpoint's slowest-target saturation (open loop
# backs up -> CO past saturation). Heavy tops ~11k closed-loop (quarkus-hibernate);
# light saturation for quarkus-hibernate must be DISCOVERED before trusting the top
# light rung. Both ladders are env-overridable.
# =============================================================================
set -uo pipefail   # NOT -e: one bad rung must log and continue, not kill a ~7.5h curve.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TRIAD_HARNESS="${REPO_ROOT}/scripts/run-full-triad-ab-ba.sh"
[[ -f "$TRIAD_HARNESS" ]] || { echo "ERROR: missing $TRIAD_HARNESS" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

# All 3 runtimes, quarkus-focused triad. name:target_a:target_b:label:port_a:port_b
TRIAD_PAIRS="${LATENCY_TRIAD_PAIRS:-1-exeris-vs-quarkus-tuned:exeris-community:quarkus-tuned:1:9000:9003;2-exeris-vs-quarkus-hibernate:exeris-community:quarkus-hibernate:2:9000:9002;3-quarkus-hibernate-vs-tuned:quarkus-hibernate:quarkus-tuned:3:9002:9003}"

HEAVY_CONTRACT="${LATENCY_HEAVY_CONTRACT:-fixed_contract_p99_stable_h1_wrk2_v1}"
LIGHT_CONTRACT="${LATENCY_LIGHT_CONTRACT:-fixed_contract_p99_stable_h1_wrk2_single_read_v1}"

# Offered-rate ladders (rps). Heavy bounded by ~11k (quarkus-hibernate closed-loop max).
# Light default is a PLACEHOLDER — discover quarkus-hibernate's single-read saturation and
# override LATENCY_LIGHT_RUNGS so the top rung stays sub-saturation.
read -r -a HEAVY_RUNGS <<< "${LATENCY_HEAVY_RUNGS:-2000 4000 6000 8000 10000}"
read -r -a LIGHT_RUNGS <<< "${LATENCY_LIGHT_RUNGS:-5000 10000 15000 20000 25000}"

# tuned-PG baseline (host-net + PG cpuset), matching 60707c4; the box already has it up.
export BENCH_DB_TUNED="${BENCH_DB_TUNED:-1}"
export BENCHMARK_ALLOW_EXTERNAL_DB="${BENCHMARK_ALLOW_EXTERNAL_DB:-1}"

# Skip run-comparative.sh's Stage-2 endpoint-contract test gate (a `mvn -Dtest=...ContractTest
# test` compile+test cycle it runs for the heavy /api/v1/users endpoint). It is redundant here
# (the target jars are contract-verified at build time and the first leaf passed the gate) and
# its maven CPU burst risks contaminating a wrk2 LATENCY measurement (p99 is spike-sensitive; no
# CPU pinning on this box). Skipping does NOT affect comparison-eligibility (the stage7 gates
# G1-G10 don't include it) — the endpoint is still HTTP-200 preflighted at Stage 4.
export BENCHMARK_SKIP_ENDPOINT_CONTRACT_GATE="${BENCHMARK_SKIP_ENDPOINT_CONTRACT_GATE:-1}"

# The reused tuned-PG (host-net + cpuset, created by the constrained runs) uses db/role
# 'benchmark_db'/'benchmark'; the runtime/drivers/env/*.env target files default DB creds to
# 'postgres' -> HikariPool 'FATAL: role "postgres" does not exist' and the target never passes
# /health. Point all 3 targets at the tuned PG. All read EXERIS_DB_* (quarkus maps
# quarkus.datasource.{url,username,password}=${EXERIS_DB_*}; exeris reads them natively).
# prepareThreshold=1 is the triad's proven heavy param; identical on the SHARED url across every
# arm -> pgjdbc-equalized (post-fence). Overridable if a different tuned PG is provisioned.
export EXERIS_DB_JDBC_URL="${EXERIS_DB_JDBC_URL:-jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1}"
export EXERIS_DB_USERNAME="${EXERIS_DB_USERNAME:-benchmark}"
export EXERIS_DB_PASSWORD="${EXERIS_DB_PASSWORD:-benchmark}"

UTC="$(date -u +%Y%m%d-%H%M%S)"
CURVE_ROOT="${LATENCY_CURVE_ROOT:-results/raw/entity-read-by-id/${UTC}-latency-curve-triad}"
mkdir -p "$CURVE_ROOT"
STATUS_JSONL="$CURVE_ROOT/curve-status.jsonl"
: > "$STATUS_JSONL"

# Provenance manifest for the whole curve.
jq -n \
  --arg utc "$UTC" --arg pairs "$TRIAD_PAIRS" \
  --arg hc "$HEAVY_CONTRACT" --arg lc "$LIGHT_CONTRACT" \
  --argjson heavy "$(printf '%s\n' "${HEAVY_RUNGS[@]}" | jq -R 'tonumber' | jq -s '.')" \
  --argjson light "$(printf '%s\n' "${LIGHT_RUNGS[@]}" | jq -R 'tonumber' | jq -s '.')" \
  '{campaign:("latency-curve-triad "+$utc), driver:"wrk2-open-loop", claim:"comparison-eligible p99 (p99_stable)",
    window:"120s (60s warmup + 120s measure)", runs_per_pair:1, order:"ab+ba",
    triad_pairs:$pairs, contracts:{heavy:$hc, light:$lc},
    rate_ladders:{heavy_rps:$heavy, light_rps:$light},
    note:"wrk2 fixed offered rate per rung (BENCH_DRIVER_MODE=open). Percentiles = true service time. Rungs are sub-saturation; open loop backs up past saturation. light ladder must be bounded by quarkus-hibernate single-read saturation."}' \
  > "$CURVE_ROOT/curve-manifest.json"

echo "[curve] root      : $CURVE_ROOT"
echo "[curve] triad     : $TRIAD_PAIRS"
echo "[curve] heavy rungs: ${HEAVY_RUNGS[*]} rps  (contract $HEAVY_CONTRACT)"
echo "[curve] light rungs: ${LIGHT_RUNGS[*]} rps  (contract $LIGHT_CONTRACT)"
echo "[curve] leaves     : 3 pairs x ab/ba x ($(( ${#HEAVY_RUNGS[@]} + ${#LIGHT_RUNGS[@]} )) rungs) = $(( 6 * (${#HEAVY_RUNGS[@]} + ${#LIGHT_RUNGS[@]}) ))"

run_rung() {
  local endpoint="$1" contract="$2" rps="$3"
  local out="$CURVE_ROOT/${endpoint}/rung-${rps}rps"
  mkdir -p "$out"
  echo ""
  echo "############################################################"
  echo "[curve] endpoint=${endpoint} offered=${rps}rps contract=${contract}"
  echo "[curve] -> $out"
  echo "############################################################"
  local rc=0
  BENCH_DRIVER_MODE=open BENCH_OFFERED_RPS="$rps" \
  BENCH_CONTRACT_ID="$contract" BENCH_RUNS_PER_PAIR=1 \
  BENCH_TRIAD_PAIRS="$TRIAD_PAIRS" \
  BENCH_CAMPAIGN_OUTPUT_DIR_OVERRIDE="$out" \
    bash "$TRIAD_HARNESS" || rc=$?
  local eligible; eligible="$(find "$out" -name claim-status.json -exec jq -r '.final_status // .status // empty' {} \; 2>/dev/null | sort -u | tr '\n' ',')"
  jq -cn --arg ep "$endpoint" --arg c "$contract" --argjson rps "$rps" --argjson rc "$rc" --arg elig "$eligible" --arg out "$out" \
    '{endpoint:$ep, offered_rps:$rps, contract:$c, rc:$rc, claim_status_values:$elig, out:$out}' >> "$STATUS_JSONL"
  echo "[curve] rung done: endpoint=${endpoint} rps=${rps} rc=${rc} claim_status={${eligible}}"
}

for rps in "${HEAVY_RUNGS[@]}"; do run_rung heavy "$HEAVY_CONTRACT" "$rps"; done
for rps in "${LIGHT_RUNGS[@]}"; do run_rung light "$LIGHT_CONTRACT" "$rps"; done

echo ""
echo "============================================================"
echo "[curve] CURVE COMPLETE -> $CURVE_ROOT"
jq -c '{endpoint,offered_rps,rc,claim_status_values}' "$STATUS_JSONL" 2>/dev/null || cat "$STATUS_JSONL"
echo "============================================================"
