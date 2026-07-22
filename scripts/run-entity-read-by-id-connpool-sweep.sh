#!/usr/bin/env bash
# =============================================================================
# entity-read-by-id — DB connection-pool sweep (exeris-community vs quarkus-tuned)
#
# Fixed 1024 MB / 4 vCPU, tuned-PG (host-net + cpuset 4-7,12-15, reused external).
# Sweeps the app DB pool over {4,8,16,32} with min == max (no elastic sizing), 3
# interleaved repeats, both arms. All the fairness machinery is inherited from the
# already-debugged constrained runner:
#   - BENCHMARK_ALLOW_EXTERNAL_DB=1  -> reuse the pre-launched tuned DB (never recreate,
#     cpuset preserved).
#   - "${cmd[@]}" </dev/null         -> LOAD-BEARING: the constrained runner spawns
#     children (docker/systemd-run/psql/wrk) that read stdin; without the redirect they
#     drain the `while read arm` process substitution and the loop silently runs only
#     the first arm.
#   - per-arm heap: community 0.25*budget (crypto off, off-heap), quarkus 0.75*budget;
#     Xms == Xmx (fixed heap). The pool itself lives INSIDE the app memory budget.
#
# min == max rationale (user): a fixed pool removes elastic-sizing dynamics so steady-
# state footprint is well-defined (same reasoning as the fixed heap). idleTimeout is moot
# when min==max; maxLifetime recycling cannot fire inside the 300 s window (shorter than
# any default maxLifetime), so the pool is effectively infinite-lifetime for the run.
#
# Budget accounting: the pool is COUNTED in the app cgroup budget (1024 MB). Postgres RSS
# is captured alongside (pg_rss_kb) but is OUTSIDE the budget. PG max_connections must
# exceed the largest pool; arms run sequentially so 32 < default 100 is fine.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSTRAINED_RUNNER="${REPO_ROOT}/scripts/run-entity-read-by-id-constrained.sh"
PROFILES_JSON="${REPO_ROOT}/runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json"
SCENARIO_JSON="${REPO_ROOT}/scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json"

# Fixed point: 1024 MB / 4 vCPU (reuse the sweep's 1024/4 profile+contract for every pool).
PROFILE_ID="runtime-constrained-1024m-4vcpu-v1"
CONTRACT_ID="fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1"
MEM_MB=1024
VCPU=4
# 4-vCPU disjoint tuned-PG partition (identical to the matrix vCPU<=4 partition):
TARGET_CPUS="0-1,8-9"
LOADGEN_CPUS="2-3,10-11"   # disjoint from target AND the DB cpuset 4-7,12-15

POOLS=(${CONNPOOL_POOLS:-4 8 16 32})
REPEATS="${CONNPOOL_REPEATS:-3}"
HARDWARE_PROFILE="${BENCHMARK_HARDWARE_PROFILE:-perf-box-amd64}"
SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-1}"
ALLOW_EXTERNAL_DB="${CONNPOOL_ALLOW_EXTERNAL_DB:-1}"
EXERIS_SUBSYSTEMS_COMMUNITY="${CONNPOOL_EXERIS_SUBSYSTEMS:-http,persistence}"
# ADR-035 persistence admission control: exeris admits + queues acquires while
# pendingAcquires <= ceil(poolMax * queueDepthAllowanceRatio); above that (and at
# saturation) it sheds. The DEFAULT ratio 8 gives a queue depth of only 8*pool, so at
# pool=4 (depth 32) it sheds most of a 128-connection load. To compare pool SIZE fairly
# (both runtimes must queue the offered load, as HikariCP does), set the ratio so the
# queue depth covers connections at the SMALLEST pool: ratio >= connections/minPool =
# 128/4 = 32. Injected as a -D system property on the exeris arm only (quarkus/HikariCP
# blocks by default). Validated: pool=4 goes 84% err -> 0% err, 39.2k successful rps.
ADMISSION_QUEUE_DEPTH_RATIO="${CONNPOOL_ADMISSION_RATIO:-32}"
CAPTURE_PG_RSS="${CONNPOOL_CAPTURE_PG_RSS:-1}"
DB_CONTAINER="${BENCHMARK_DB_CONTAINER:-exeris-benchmark-db}"
DRY_RUN=0

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="${REPO_ROOT}/results/constrained/entity-read-by-id/${UTC_STAMP}-connpool-sweep"

# ARMS: arm_id|target_runtime|xmx_mb  (heap fixed per arm at the 1024 MB budget)
ARM_COMMUNITY="exeris-community|community|256"       # 0.25 * 1024
ARM_QUARKUS_TUNED="quarkus-tuned|quarkus-tuned|768"  # 0.75 * 1024
ARMS=("$ARM_COMMUNITY" "$ARM_QUARKUS_TUNED")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) CAMPAIGN_DIR="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --pools) IFS=' ' read -r -a POOLS <<< "$2"; shift 2 ;;
    --hardware-profile) HARDWARE_PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--pools '4 8 16 32'] [--repeats N] [--hardware-profile P] [--output-dir DIR] [--dry-run]"; exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done

for f in "$CONSTRAINED_RUNNER" "$PROFILES_JSON" "$SCENARIO_JSON"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

mkdir -p "$CAMPAIGN_DIR"
RUNS_JSONL="$CAMPAIGN_DIR/runs.jsonl"
: > "$RUNS_JSONL"

capture_pg_rss() { # prints "<kb>\t<source>"
  if [[ "$CAPTURE_PG_RSS" != "1" ]]; then printf 'null\tdisabled\n'; return; fi
  local mem
  mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$DB_CONTAINER" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$mem" ]]; then printf 'null\tunavailable\n'; return; fi
  local num unit kb
  num="$(sed -E 's/([0-9.]+).*/\1/' <<<"$mem")"; unit="$(sed -E 's/[0-9.]+//' <<<"$mem")"
  case "$unit" in
    KiB|kB) kb="$(awk -v n="$num" 'BEGIN{printf "%d", n}')" ;;
    MiB|MB) kb="$(awk -v n="$num" 'BEGIN{printf "%d", n*1024}')" ;;
    GiB|GB) kb="$(awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024}')" ;;
    *) kb="null" ;;
  esac
  printf '%s\tdocker-stats\n' "$kb"
}

echo "[connpool] campaign : $CAMPAIGN_DIR"
echo "[connpool] point=1024m/4vcpu pools=${POOLS[*]} arms=exeris-community,quarkus-tuned repeats=$REPEATS (min==max)"
echo "[connpool] tuned-PG partition: target ${TARGET_CPUS} / loadgen ${LOADGEN_CPUS} / DB 4-7,12-15 (external, reused)"

run_count=0
for r in $(seq 1 "$REPEATS"); do
  for pool in "${POOLS[@]}"; do
    while IFS= read -r arm_spec; do
      [[ -z "$arm_spec" ]] && continue
      IFS='|' read -r arm_id target_runtime xmx_mb <<< "$arm_spec"
      run_dir="$CAMPAIGN_DIR/pool-${pool}/${arm_id}/repeat-${r}"

      env_prefix=(
        "BENCHMARK_SKIP_TARGET_BUILD=${SKIP_TARGET_BUILD}"
        "BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=${pool}"
        "BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=${pool}"
        "BENCHMARK_ALLOW_EXTERNAL_DB=${ALLOW_EXTERNAL_DB}"
      )
      exeris_subsystems="n/a"; admission_ratio="n/a"
      if [[ "$arm_id" == "exeris-community" ]]; then
        env_prefix+=(
          "EXERIS_SUBSYSTEMS=${EXERIS_SUBSYSTEMS_COMMUNITY}"
          "EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false"
          "EXERIS_TELEMETRY_JFR_ENABLED=false"
          "JDK_JAVA_OPTIONS=-Dexeris.persistence.admission.queueDepthAllowanceRatio=${ADMISSION_QUEUE_DEPTH_RATIO}"
        )
        exeris_subsystems="$EXERIS_SUBSYSTEMS_COMMUNITY"
        admission_ratio="$ADMISSION_QUEUE_DEPTH_RATIO"
      fi

      cmd=(
        env "${env_prefix[@]}"
        "$CONSTRAINED_RUNNER"
          --execution-profile-id "$PROFILE_ID"
          --contract-id "$CONTRACT_ID"
          --profiles-json "$PROFILES_JSON"
          --scenario-json "$SCENARIO_JSON"
          --target-runtime "$target_runtime"
          --target-build jvm
          --jvm-gc parallel
          --jvm-xms-mb "$xmx_mb"
          --jvm-xmx-mb "$xmx_mb"
          --cpu-affinity "$TARGET_CPUS"
          --client-cpu-affinity "$LOADGEN_CPUS"
          --output-dir "$run_dir"
      )

      run_count=$((run_count + 1))
      echo
      echo "[connpool] === run ${run_count}: pool=${pool} arm=${arm_id} repeat=${r}/${REPEATS} xmx=${xmx_mb}m subsystems=${exeris_subsystems} admission_ratio=${admission_ratio} target=${TARGET_CPUS} loadgen=${LOADGEN_CPUS} ==="
      if [[ "$DRY_RUN" == "1" ]]; then
        printf '[connpool][dry-run] %q ' "${cmd[@]}"; echo
        continue
      fi

      mkdir -p "$run_dir"
      set +e
      "${cmd[@]}" </dev/null   # </dev/null: stop child procs draining the arm loop's stdin
      rc=$?
      set -e

      if [[ "$rc" -eq 64 ]]; then
        echo "ERROR: constrained runner returned rc=64 (CONFIG_ERROR/limit_mismatch) for pool=${pool} arm=${arm_id}. Fail-closed abort." >&2
        exit 64
      fi

      IFS=$'\t' read -r pg_rss_kb pg_rss_source < <(capture_pg_rss)
      result_json="$(cat "$run_dir/result.json" 2>/dev/null || echo '{}')"
      resource_json="$(cat "$run_dir/resource-metrics.json" 2>/dev/null || echo '{}')"
      [[ -z "$result_json" ]] && result_json='{}'
      [[ -z "$resource_json" ]] && resource_json='{}'
      jq -cn \
        --argjson result "$result_json" --argjson resource "$resource_json" \
        --argjson pool "$pool" --argjson vcpu "$VCPU" --argjson mem "$MEM_MB" \
        --arg arm "$arm_id" --arg target_runtime "$target_runtime" --argjson repeat "$r" \
        --arg run_dir "$run_dir" --argjson rc "$rc" \
        --argjson xmx "$xmx_mb" --arg exeris_subsystems "$exeris_subsystems" --arg admission_ratio "$admission_ratio" \
        --arg pg_rss_kb "$pg_rss_kb" --arg pg_rss_source "$pg_rss_source" \
        '{db_pool_size: $pool, pool_min_equals_max: true, vcpu: $vcpu, memory_max_mb: $mem,
          arm: $arm, target_runtime: $target_runtime, repeat: $repeat, run_dir: $run_dir,
          constrained_runner_exit_code: $rc,
          jvm: {xmx_mb: $xmx, xms_equals_xmx: true},
          fairness_controls: {exeris_subsystems: (if $exeris_subsystems=="n/a" then null else $exeris_subsystems end),
                              crypto_subsystem_enabled: (if $exeris_subsystems=="n/a" then null else ($exeris_subsystems|test("(^|,)crypto(,|$)")) end),
                              exeris_admission_queue_depth_ratio: (if $admission_ratio=="n/a" then null else ($admission_ratio|tonumber) end),
                              admission_note: "ADR-035: exeris queueDepthAllowanceRatio raised so acquire-queue depth (ratio*poolMax) covers the 128 offered connections at every pool (default 8 sheds at small pools); quarkus HikariCP blocks by default"},
          cpu_partition: {target_cpuset:"0-1,8-9", loadgen_cpuset:"2-3,10-11", db_cpuset:"4-7,12-15"},
          rps: ($result.metrics.throughput_rps // null),
          total_requests: ($result.metrics.total_requests // null),
          total_errors: ($result.metrics.total_errors // null),
          error_rate_pct: ($result.metrics.error_rate_pct // null),
          latency_p50_us: ($result.metrics.latency_p50_us // null),
          latency_p99_us: ($result.metrics.latency_p99_us // null),
          latency_label: "wrk-closed-loop-coordinated-omission",
          cpu_time_seconds: ($resource.cpu_time_seconds // null),
          cpu_per_req_ms: (($result.metrics.total_requests // null) as $tr | ($resource.cpu_time_seconds // null) as $c
                           | if $tr!=null and $c!=null and $tr>0 then ($c/$tr*1000) else null end),
          avg_cores_used: ($resource.avg_cores_used // null),
          peak_rss_kb: ($resource.peak_rss_kb // null),
          smaps_rss_kb_max: ($resource.smaps_rss_kb_max // null),
          pg_rss_kb: (if $pg_rss_kb=="null" then null else ($pg_rss_kb|tonumber) end),
          pg_rss_source: $pg_rss_source,
          pg_rss_note: "postgres runs OUTSIDE the app pool budget; best-effort docker-stats snapshot"
        }' >> "$RUNS_JSONL"
      echo "[connpool] recorded: rc=${rc} pool=${pool} pg_rss_kb=${pg_rss_kb} -> $run_dir"
    done < <(printf '%s\n' "${ARMS[@]}")
  done
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[connpool] dry-run complete: ${run_count} invocations planned."; exit 0
fi

echo
echo "[connpool] DONE: ${run_count} runs -> $RUNS_JSONL"
