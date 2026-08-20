#!/usr/bin/env bash
# =============================================================================
# entity-read-by-id — TLS tax at a single point (1024 MB / 4 vCPU)
#
# Measures the cost of enabling TLS as a same-campaign delta: for each arm, run
# PLAINTEXT then TLS under otherwise-identical constrained conditions, 3 interleaved
# repeats. The tax is (plaintext -> TLS) per arm on rps / cpu-per-req / RSS.
#
# Fairness / wiring (all inherited from the debugged constrained runner):
#   - tuned-PG reused external (ALLOW_EXTERNAL_DB=1, cpuset 4-7,12-15 preserved).
#   - </dev/null so the arm loop runs both arms.
#   - disjoint 4-vCPU partition: target 0-1,8-9 / loadgen 2-3,10-11 / DB 4-7,12-15.
#   - fixed pool 16 (min==max), per-arm fixed heap (community 256 / quarkus 768).
#   - TLS: BENCHMARK_TLS_ENABLED=1 -> base runner launches the target with
#     EXERIS_SSL_ENABLED/SERVER_SSL_ENABLED + the pinned TLS 1.3 suite
#     (TLS_AES_128_GCM_SHA256, so exeris and quarkus negotiate the SAME cipher).
#   - A self-signed smoke cert (RSA-2048) is provisioned via tools/bench/lib/certs.sh.
#
# EXERIS crypto-subsystem asymmetry (state this when reading the tax): exeris's
# plaintext-optimal config drops the crypto subsystem (EXERIS_SUBSYSTEMS=http,persistence);
# TLS re-enables it (http,persistence,crypto). So exeris's measured tax includes turning
# the crypto subsystem back on -- the real "plaintext-optimal -> TLS" cost. Quarkus has no
# such toggle (its TLS stack is always present), so its tax is wire-only. This is a real
# capability difference, not an unfairness, but the decomposition (crypto-on plaintext) is
# a separate follow-up if you want subsystem-cost vs wire-cost split out.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSTRAINED_RUNNER="${REPO_ROOT}/scripts/run-entity-read-by-id-constrained.sh"
PROFILES_JSON="${REPO_ROOT}/runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json"
SCENARIO_JSON="${REPO_ROOT}/scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json"
CERTS_LIB="${REPO_ROOT}/tools/bench/lib/certs.sh"

PROFILE_ID="runtime-constrained-1024m-4vcpu-v1"
CONTRACT_ID="fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1"
MEM_MB=1024; VCPU=4
TARGET_CPUS="0-1,8-9"; LOADGEN_CPUS="2-3,10-11"

POOL="${TLSTAX_POOL:-16}"
REPEATS="${TLSTAX_REPEATS:-3}"
HARDWARE_PROFILE="${BENCHMARK_HARDWARE_PROFILE:-perf-box-amd64}"
SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-1}"
ALLOW_EXTERNAL_DB="${TLSTAX_ALLOW_EXTERNAL_DB:-1}"
# ADR-035 persistence admission: at 128 conns / pool 16 the default ratio=8 gives a
# queue depth of exactly 128 (16*8), leaving only ~16 slots of margin over the ~112
# steady pendingAcquires — a GC-bunched acquire spike could shed and dirty exeris's
# error rate. Pin ratio=32 for the exeris arm (matches the connpool sweep + floor:
# same post-fence exeris config across the batch). No-op when not shedding.
ADMISSION_RATIO="${TLSTAX_ADMISSION_RATIO:-32}"
CAPTURE_PG_RSS="${TLSTAX_CAPTURE_PG_RSS:-1}"
DB_CONTAINER="${BENCHMARK_DB_CONTAINER:-exeris-benchmark-db}"
CERT_DIR="${TLSTAX_CERT_DIR:-/tmp/exeris-bench-certs}"
CERT_PATH="${EXERIS_TRANSPORT_CERT_PATH:-$CERT_DIR/smoke-cert.pem}"
KEY_PATH="${EXERIS_TRANSPORT_KEY_PATH:-$CERT_DIR/smoke-key.pem}"
DRY_RUN=0

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="${REPO_ROOT}/results/constrained/entity-read-by-id/${UTC_STAMP}-tls-tax"

# CONFIGS: mode|tls_enabled|exeris_subsystems  (exeris drops crypto for plaintext, adds it for TLS)
CONFIGS=(
  "plaintext|0|http,persistence"
  "tls|1|http,persistence,crypto"
)
# ARMS: arm_id|target_runtime|xmx_mb
ARMS=(
  "exeris-community|community|256"
  "quarkus-tuned|quarkus-tuned|768"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) CAMPAIGN_DIR="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --pool) POOL="$2"; shift 2 ;;
    --hardware-profile) HARDWARE_PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "Usage: $0 [--pool N] [--repeats N] [--hardware-profile P] [--output-dir DIR] [--dry-run]"; exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done

for f in "$CONSTRAINED_RUNNER" "$PROFILES_JSON" "$SCENARIO_JSON"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

# Provision the smoke cert (once) so both TLS arms have a cert to serve.
if [[ "$DRY_RUN" != "1" ]]; then
  mkdir -p "$CERT_DIR"
  if [[ -f "$CERTS_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$CERTS_LIB"
    if command -v ensure_smoke_cert_key >/dev/null 2>&1; then
      ensure_smoke_cert_key "$CERT_PATH" "$KEY_PATH" || { echo "ERROR: smoke cert provisioning failed" >&2; exit 3; }
    fi
  fi
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl required to provision smoke cert" >&2; exit 3; }
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY_PATH" -out "$CERT_PATH" -days 30 -subj "/CN=exeris-bench-smoke" >/dev/null 2>&1 \
      || { echo "ERROR: openssl smoke cert generation failed" >&2; exit 3; }
  fi
  echo "[tls-tax] smoke cert: $CERT_PATH"
fi

mkdir -p "$CAMPAIGN_DIR"
RUNS_JSONL="$CAMPAIGN_DIR/runs.jsonl"
: > "$RUNS_JSONL"

capture_pg_rss() {
  if [[ "$CAPTURE_PG_RSS" != "1" ]]; then printf 'null\tdisabled\n'; return; fi
  local mem; mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$DB_CONTAINER" 2>/dev/null | awk '{print $1}')"
  [[ -z "$mem" ]] && { printf 'null\tunavailable\n'; return; }
  local num unit kb; num="$(sed -E 's/([0-9.]+).*/\1/' <<<"$mem")"; unit="$(sed -E 's/[0-9.]+//' <<<"$mem")"
  case "$unit" in KiB|kB) kb="$(awk -v n="$num" 'BEGIN{printf "%d",n}')";; MiB|MB) kb="$(awk -v n="$num" 'BEGIN{printf "%d",n*1024}')";; GiB|GB) kb="$(awk -v n="$num" 'BEGIN{printf "%d",n*1024*1024}')";; *) kb="null";; esac
  printf '%s\tdocker-stats\n' "$kb"
}

echo "[tls-tax] campaign : $CAMPAIGN_DIR"
echo "[tls-tax] point=1024m/4vcpu pool=${POOL} modes=plaintext,tls arms=exeris-community,quarkus-tuned repeats=$REPEATS"
echo "[tls-tax] partition: target ${TARGET_CPUS} / loadgen ${LOADGEN_CPUS} / DB 4-7,12-15; TLS suite=TLS_AES_128_GCM_SHA256"

run_count=0
for r in $(seq 1 "$REPEATS"); do
  while IFS= read -r cfg; do
    [[ -z "$cfg" ]] && continue
    IFS='|' read -r mode tls_enabled mode_subsystems <<< "$cfg"
    while IFS= read -r arm_spec; do
      [[ -z "$arm_spec" ]] && continue
      IFS='|' read -r arm_id target_runtime xmx_mb <<< "$arm_spec"
      run_dir="$CAMPAIGN_DIR/mode-${mode}/${arm_id}/repeat-${r}"

      env_prefix=(
        "BENCHMARK_SKIP_TARGET_BUILD=${SKIP_TARGET_BUILD}"
        "BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=${POOL}"
        "BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=${POOL}"
        "BENCHMARK_ALLOW_EXTERNAL_DB=${ALLOW_EXTERNAL_DB}"
        "BENCHMARK_TLS_ENABLED=${tls_enabled}"
      )
      if [[ "$tls_enabled" == "1" ]]; then
        env_prefix+=(
          "EXERIS_SSL_ENABLED=true"
          "EXERIS_TRANSPORT_CERT_PATH=${CERT_PATH}"
          "EXERIS_TRANSPORT_KEY_PATH=${KEY_PATH}"
        )
      fi
      exeris_subsystems="n/a"
      if [[ "$arm_id" == "exeris-community" ]]; then
        env_prefix+=(
          "EXERIS_SUBSYSTEMS=${mode_subsystems}"
          "EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false"
          "EXERIS_TELEMETRY_JFR_ENABLED=false"
          "JDK_JAVA_OPTIONS=-Dexeris.persistence.admission.queueDepthAllowanceRatio=${ADMISSION_RATIO}"
        )
        exeris_subsystems="$mode_subsystems"
      fi

      cmd=(
        env "${env_prefix[@]}"
        "$CONSTRAINED_RUNNER"
          --execution-profile-id "$PROFILE_ID" --contract-id "$CONTRACT_ID"
          --profiles-json "$PROFILES_JSON" --scenario-json "$SCENARIO_JSON"
          --target-runtime "$target_runtime" --target-build jvm --jvm-gc parallel
          --jvm-xms-mb "$xmx_mb" --jvm-xmx-mb "$xmx_mb"
          --cpu-affinity "$TARGET_CPUS" --client-cpu-affinity "$LOADGEN_CPUS"
          --output-dir "$run_dir"
      )

      run_count=$((run_count + 1))
      echo
      echo "[tls-tax] === run ${run_count}: mode=${mode} arm=${arm_id} repeat=${r}/${REPEATS} tls=${tls_enabled} xmx=${xmx_mb}m subsystems=${exeris_subsystems} ==="
      if [[ "$DRY_RUN" == "1" ]]; then printf '[tls-tax][dry-run] %q ' "${cmd[@]}"; echo; continue; fi

      mkdir -p "$run_dir"
      set +e
      "${cmd[@]}" </dev/null
      rc=$?
      set -e
      if [[ "$rc" -eq 64 ]]; then echo "ERROR: rc=64 (CONFIG_ERROR) mode=${mode} arm=${arm_id}. Fail-closed abort." >&2; exit 64; fi

      IFS=$'\t' read -r pg_rss_kb pg_rss_source < <(capture_pg_rss)
      result_json="$(cat "$run_dir/result.json" 2>/dev/null || echo '{}')"; [[ -z "$result_json" ]] && result_json='{}'
      resource_json="$(cat "$run_dir/resource-metrics.json" 2>/dev/null || echo '{}')"; [[ -z "$resource_json" ]] && resource_json='{}'
      jq -cn \
        --argjson result "$result_json" --argjson resource "$resource_json" \
        --arg mode "$mode" --argjson tls "$tls_enabled" --argjson pool "$POOL" --argjson vcpu "$VCPU" --argjson mem "$MEM_MB" \
        --arg arm "$arm_id" --arg target_runtime "$target_runtime" --argjson repeat "$r" \
        --arg run_dir "$run_dir" --argjson rc "$rc" --argjson xmx "$xmx_mb" --arg exeris_subsystems "$exeris_subsystems" \
        --arg pg_rss_kb "$pg_rss_kb" --arg pg_rss_source "$pg_rss_source" \
        --argjson admission_ratio "$ADMISSION_RATIO" \
        '{mode: $mode, tls_enabled: ($tls==1), db_pool_size: $pool, vcpu: $vcpu, memory_max_mb: $mem,
          arm: $arm, target_runtime: $target_runtime, repeat: $repeat, run_dir: $run_dir,
          constrained_runner_exit_code: $rc, jvm: {xmx_mb: $xmx},
          fairness_controls: {exeris_subsystems: (if $exeris_subsystems=="n/a" then null else $exeris_subsystems end),
                              crypto_subsystem_enabled: (if $exeris_subsystems=="n/a" then null else ($exeris_subsystems|test("(^|,)crypto(,|$)")) end),
                              exeris_admission_queue_depth_ratio: (if $arm=="exeris-community" then $admission_ratio else null end)},
          tls: ($result.tls // null),
          rps: ($result.metrics.throughput_rps // null),
          total_requests: ($result.metrics.total_requests // null),
          error_rate_pct: ($result.metrics.error_rate_pct // null),
          latency_p99_us: ($result.metrics.latency_p99_us // null),
          cpu_time_seconds: ($resource.cpu_time_seconds // null),
          cpu_per_req_ms: (($result.metrics.total_requests // null) as $tr | ($resource.cpu_time_seconds // null) as $c
                           | if $tr!=null and $c!=null and $tr>0 then ($c/$tr*1000) else null end),
          avg_cores_used: ($resource.avg_cores_used // null),
          peak_rss_kb: ($resource.peak_rss_kb // null),
          pg_rss_kb: (if $pg_rss_kb=="null" then null else ($pg_rss_kb|tonumber) end), pg_rss_source: $pg_rss_source
        }' >> "$RUNS_JSONL"
      echo "[tls-tax] recorded: rc=${rc} mode=${mode} arm=${arm_id} pg_rss_kb=${pg_rss_kb} -> $run_dir"
    done < <(printf '%s\n' "${ARMS[@]}")
  done < <(printf '%s\n' "${CONFIGS[@]}")
done

if [[ "$DRY_RUN" == "1" ]]; then echo "[tls-tax] dry-run complete: ${run_count} invocations planned."; exit 0; fi
echo
echo "[tls-tax] DONE: ${run_count} runs -> $RUNS_JSONL"
