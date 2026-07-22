#!/usr/bin/env bash
# =============================================================================
# entity-read-by-id — memory-FLOOR binary search (single-read, fixed arrival rate)
#
# Finds the minimal memory.max at which each (arm, mode) sustains a FIXED ~1000 rps
# for the full measurement window without OOM and under a p99 gate. Four floors:
#   {exeris-community, quarkus-tuned} x {plaintext, TLS}.
#
# Driver: wrk2 open-loop at WRK2_TARGET_RPS with WRK2_SKIP_DISCOVERY=1 (the closed-loop
# saturation + warmup passes are MAX-load and would OOM a floor-sized cgroup, inflating
# the floor). @4 vCPU, tuned-PG reused external, disjoint partition target 0-1,8-9 /
# loadgen 2-3,10-11 / DB 4-7,12-15.
#
# Search: a pre-generated fine memory grid (arbitrary memory.max isn't overridable in the
# constrained runner, so a grid of profiles+contracts is generated here at startup). A
# standard binary search over grid indices finds the SMALLEST index whose trial succeeds.
#
# Success at grid[i] := rc==0 AND achieved rps >= 0.95*target AND error_rate <= 1% AND
# p99 <= FLOOR_P99_GATE_MS. Anything else (OOM, readiness fail, throttled below rate,
# tail blowout) is a fail -> search higher. A budget where an arm cannot start is a RESULT.
#
# Post-fence (9f2b182/1bf4767): pgjdbc protocol equalized + exeris admission ratio raised
# in the base runner; these floors are on post-equalization jars.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSTRAINED_RUNNER="${REPO_ROOT}/scripts/run-entity-read-by-id-constrained.sh"
CERTS_LIB="${REPO_ROOT}/tools/bench/lib/certs.sh"

VCPU=4
TARGET_CPUS="0-1,8-9"; LOADGEN_CPUS="2-3,10-11"
TARGET_RPS="${FLOOR_TARGET_RPS:-1000}"
CONNECTIONS="${FLOOR_CONNECTIONS:-32}"
THREADS="${FLOOR_THREADS:-4}"
DURATION_S="${FLOOR_DURATION_S:-300}"
POOL="${FLOOR_POOL:-16}"
P99_GATE_MS="${FLOOR_P99_GATE_MS:-50}"
HEAP_FRAC_COMMUNITY="${FLOOR_HEAP_FRAC_COMMUNITY:-0.25}"
HEAP_FRAC_QUARKUS="${FLOOR_HEAP_FRAC_QUARKUS:-0.75}"
SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-1}"
ALLOW_EXTERNAL_DB="${FLOOR_ALLOW_EXTERNAL_DB:-1}"
EXERIS_SUBSYSTEMS_PLAINTEXT="${FLOOR_EXERIS_SUBSYSTEMS_PLAINTEXT:-http,persistence}"
EXERIS_SUBSYSTEMS_TLS="${FLOOR_EXERIS_SUBSYSTEMS_TLS:-http,persistence,crypto}"
ADMISSION_RATIO="${FLOOR_ADMISSION_RATIO:-32}"
CERT_DIR="${FLOOR_CERT_DIR:-/tmp/exeris-bench-certs}"
CERT_PATH="${EXERIS_TRANSPORT_CERT_PATH:-$CERT_DIR/smoke-cert.pem}"
KEY_PATH="${EXERIS_TRANSPORT_KEY_PATH:-$CERT_DIR/smoke-key.pem}"
# Fine memory grid (MB) @4vcpu; low end dense (that's where the floors are).
MEM_GRID=(${FLOOR_MEM_GRID:-32 48 64 80 96 112 128 160 192 224 256 320 384 448 512})
DRY_RUN=0

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="${REPO_ROOT}/results/constrained/entity-read-by-id/${UTC_STAMP}-memory-floor"

# CONFIGS: mode|tls|exeris_subsystems  ; ARMS: arm|runtime|heap_frac
CONFIGS=("plaintext|0|${EXERIS_SUBSYSTEMS_PLAINTEXT}" "tls|1|${EXERIS_SUBSYSTEMS_TLS}")
ARMS=("exeris-community|community|${HEAP_FRAC_COMMUNITY}" "quarkus-tuned|quarkus-tuned|${HEAP_FRAC_QUARKUS}")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) CAMPAIGN_DIR="$2"; shift 2 ;;
    --target-rps) TARGET_RPS="$2"; shift 2 ;;
    --p99-gate-ms) P99_GATE_MS="$2"; shift 2 ;;
    --mem-grid) IFS=' ' read -r -a MEM_GRID <<< "$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "Usage: $0 [--target-rps N] [--p99-gate-ms N] [--mem-grid '32 48 ..'] [--output-dir D] [--dry-run]"; exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
[[ -f "$CONSTRAINED_RUNNER" ]] || { echo "ERROR: missing $CONSTRAINED_RUNNER" >&2; exit 2; }

mkdir -p "$CAMPAIGN_DIR"
PROFILES_JSON="$CAMPAIGN_DIR/floor-profiles.json"
SCENARIO_JSON="$CAMPAIGN_DIR/floor-scenario.json"
RESULTS_JSONL="$CAMPAIGN_DIR/floor-results.jsonl"
FLOORS_JSON="$CAMPAIGN_DIR/floors.json"
: > "$RESULTS_JSONL"

# --- generate the grid profiles + contracts ---------------------------------
gen_grid() {
  local prof='[]' scen='{}'
  local m pid cid
  for m in "${MEM_GRID[@]}"; do
    pid="runtime-constrained-floor-${m}m-${VCPU}vcpu-v1"
    cid="fixed_contract_runtime_h1_constrained_floor_${m}m_${VCPU}vcpu_v1"
    prof="$(jq -c --argjson m "$m" --arg pid "$pid" --argjson vcpu "$VCPU" '. + [{
      execution_profile_id:$pid, benchmark_family:"runtime-wrk2", profile_class:"constrained-runtime",
      status:"exploratory", claim_scope:"descriptive_only", comparison_policy:"forbidden",
      result_namespace:"results/constrained", required_track_id:"track-c",
      cpu_limit:{vcpu:$vcpu, quota_us:($vcpu*100000), period_us:100000, enforcement:"cgroup-required"},
      memory_limit:{limit_mb:$m, enforcement:"cgroup-required"},
      jvm:{gc:"parallel", active_processor_count:$vcpu, max_ram_mb:$m},
      jit_representativeness:"representative",
      required_evidence:["effective-cgroup-limits","jvm-flags","peak-memory","cpu-throttling"],
      allowed_outcomes:["ok","oom_killed","readiness_timeout","limit_mismatch","startup_failed"],
      note:("memory-floor grid point "+($m|tostring)+"MB / "+($vcpu|tostring)+"vCPU, fixed-rate wrk2")
    }]' <<<"$prof")"
    scen="$(jq -c --arg cid "$cid" --arg pid "$pid" --argjson conns "$CONNECTIONS" --argjson th "$THREADS" --argjson dur "$DURATION_S" '.[$cid] = {
      tier:"community", protocol_mode:"h1", benchmark_family:"runtime-wrk2", transport_mode:"loopback-h1",
      mode:"baseline-db", endpoint:"GET /api/v1/user?id=1", threads:$th, connections:$conns,
      warmup_seconds:60, duration_seconds:$dur, payload_profile:"single-user-by-id-v1",
      execution_profile_id:$pid, claim_scope:"descriptive_only", execution_class:"exploratory",
      comparison_policy:"forbidden", constrained_family:"memory-floor", result_namespace:"results/constrained",
      required_track_id:"track-c", note:"memory-floor fixed-rate contract"
    }' <<<"$scen")"
  done
  jq -n --argjson p "$prof" '{schema_version:"1", note:"generated memory-floor grid profiles", profiles:$p}' > "$PROFILES_JSON"
  jq -n --argjson c "$scen" '{scenario_id:"entity-read-by-id", version:"1", endpoint:"GET /api/v1/user?id=1", mode:"baseline-db", tier:"community", benchmark_family:"runtime", comparison_axis:"within-tier", loopback:true, note:"generated memory-floor grid contracts", seed:{manifest_ref:"scenarios/entity-read-by-id/seed/seed-manifest.json", manifest_version:"1", verification_script:"scenarios/entity-read-by-id/seed/verify-seed.sh"}, fixed_contracts:$c}' > "$SCENARIO_JSON"
}

# --- one trial at grid[idx] for (arm,mode); prints "ok" or "fail" + records --
trial() {
  local mem="$1" arm="$2" runtime="$3" heap_frac="$4" mode="$5" tls="$6" subs="$7"
  local xmx; xmx="$(awk -v m="$mem" -v f="$heap_frac" 'BEGIN{v=int(m*f); if(v<8)v=8; print v}')"
  local run_dir="$CAMPAIGN_DIR/${mode}/${arm}/mem-${mem}m"
  local pid="runtime-constrained-floor-${mem}m-${VCPU}vcpu-v1"
  local cid="fixed_contract_runtime_h1_constrained_floor_${mem}m_${VCPU}vcpu_v1"
  local env_prefix=(
    "BENCHMARK_SKIP_TARGET_BUILD=${SKIP_TARGET_BUILD}"
    "BENCHMARK_ALLOW_EXTERNAL_DB=${ALLOW_EXTERNAL_DB}"
    "BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=${POOL}"
    "BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=${POOL}"
    "WRK2_TARGET_RPS=${TARGET_RPS}" "WRK2_SKIP_DISCOVERY=1"
  )
  [[ "$tls" == "1" ]] && env_prefix+=("BENCHMARK_TLS_ENABLED=1" "EXERIS_SSL_ENABLED=true" "EXERIS_TRANSPORT_CERT_PATH=${CERT_PATH}" "EXERIS_TRANSPORT_KEY_PATH=${KEY_PATH}")
  if [[ "$arm" == "exeris-community" ]]; then
    env_prefix+=("EXERIS_SUBSYSTEMS=${subs}" "EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false" "EXERIS_TELEMETRY_JFR_ENABLED=false" "JDK_JAVA_OPTIONS=-Dexeris.persistence.admission.queueDepthAllowanceRatio=${ADMISSION_RATIO}")
  fi
  local cmd=(env "${env_prefix[@]}" "$CONSTRAINED_RUNNER"
    --execution-profile-id "$pid" --contract-id "$cid"
    --profiles-json "$PROFILES_JSON" --scenario-json "$SCENARIO_JSON"
    --target-runtime "$runtime" --target-build jvm --jvm-gc parallel
    --jvm-xms-mb "$xmx" --jvm-xmx-mb "$xmx" --driver wrk2
    --cpu-affinity "$TARGET_CPUS" --client-cpu-affinity "$LOADGEN_CPUS"
    --output-dir "$run_dir")
  echo "  [trial] ${mode}/${arm} mem=${mem}m xmx=${xmx}m rps_target=${TARGET_RPS}" >&2
  if [[ "$DRY_RUN" == "1" ]]; then echo "ok"; return; fi
  mkdir -p "$run_dir"; set +e; "${cmd[@]}" </dev/null >/dev/null 2>&1; local rc=$?; set -e
  local rps err p99 verdict
  rps="$(jq -r '.metrics.throughput_rps // 0' "$run_dir/result.json" 2>/dev/null || echo 0)"
  err="$(jq -r '.metrics.error_rate_pct // 100' "$run_dir/result.json" 2>/dev/null || echo 100)"
  p99="$(jq -r '((.metrics.latency_p99_us // 9e9)/1000)' "$run_dir/result.json" 2>/dev/null || echo 9000000)"
  verdict="$(awk -v rc="$rc" -v rps="$rps" -v tgt="$TARGET_RPS" -v err="$err" -v p99="$p99" -v gate="$P99_GATE_MS" 'BEGIN{
    if(rc==0 && rps>=0.95*tgt && err<=1.0 && p99<=gate) print "ok"; else print "fail"}')"
  jq -cn --argjson mem "$mem" --arg arm "$arm" --arg mode "$mode" --argjson tls "$tls" \
    --argjson rc "$rc" --argjson rps "${rps:-0}" --argjson err "${err:-100}" --argjson p99 "${p99:-0}" \
    --arg verdict "$verdict" --argjson xmx "$xmx" --arg run_dir "$run_dir" \
    '{memory_max_mb:$mem, arm:$arm, mode:$mode, tls_enabled:($tls==1), xmx_mb:$xmx, rc:$rc,
      rps:$rps, error_rate_pct:$err, p99_ms:$p99, verdict:$verdict, run_dir:$run_dir}' >> "$RESULTS_JSONL"
  echo "  [trial] -> ${verdict} (rc=$rc rps=$rps err=$err% p99=${p99}ms)" >&2
  echo "$verdict"
}

# --- binary search over grid indices for the minimal successful memory -------
floor_search() {
  local arm="$1" runtime="$2" heap_frac="$3" mode="$4" tls="$5" subs="$6"
  local lo=0 hi=$((${#MEM_GRID[@]}-1)) best=-1
  # quick reject: if the largest grid point fails, there is no floor in range
  local top; top="$(trial "${MEM_GRID[$hi]}" "$arm" "$runtime" "$heap_frac" "$mode" "$tls" "$subs")"
  if [[ "$top" != "ok" ]]; then echo "-1"; return; fi
  best=$hi
  while (( lo <= hi )); do
    local mid=$(( (lo+hi)/2 ))
    local v; v="$(trial "${MEM_GRID[$mid]}" "$arm" "$runtime" "$heap_frac" "$mode" "$tls" "$subs")"
    if [[ "$v" == "ok" ]]; then best=$mid; hi=$((mid-1)); else lo=$((mid+1)); fi
  done
  echo "${MEM_GRID[$best]}"
}

gen_grid
echo "[floor] campaign : $CAMPAIGN_DIR"
echo "[floor] grid(MB) : ${MEM_GRID[*]}"
echo "[floor] rate=${TARGET_RPS}rps conns=${CONNECTIONS} pool=${POOL} dur=${DURATION_S}s p99_gate=${P99_GATE_MS}ms partition: target ${TARGET_CPUS}/loadgen ${LOADGEN_CPUS}/DB 4-7,12-15"

: > "$FLOORS_JSON.tmp"
for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r mode tls subs <<< "$cfg"
  for arm_spec in "${ARMS[@]}"; do
    IFS='|' read -r arm runtime heap_frac <<< "$arm_spec"
    echo "[floor] === searching ${mode} / ${arm} ==="
    floor="$(floor_search "$arm" "$runtime" "$heap_frac" "$mode" "$tls" "$subs")"
    echo "[floor] FLOOR ${mode}/${arm} = ${floor} MB"
    jq -cn --arg mode "$mode" --arg arm "$arm" --argjson tls "$tls" --argjson floor "${floor}" \
      '{mode:$mode, arm:$arm, tls_enabled:($tls==1), floor_memory_max_mb:(if $floor<0 then null else $floor end)}' >> "$FLOORS_JSON.tmp"
  done
done
jq -s '.' "$FLOORS_JSON.tmp" > "$FLOORS_JSON"; rm -f "$FLOORS_JSON.tmp"
echo "[floor] DONE. Floors:"; cat "$FLOORS_JSON"
