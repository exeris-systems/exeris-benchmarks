#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-entity-read-by-id-memory-cpu-matrix.sh
#
# Constrained memory x CPU sweep on the entity-read-by-id SINGLE-READ workload
# (GET /api/v1/user?id=1 -> the runtime-bound single-row indexed read). Produces
# the "memory budget curve": RSS / throughput / latency / CPU-per-request vs the
# cgroup memory budget, plus a perpendicular CPU cut.
#
# AXES (a cross, NOT a full grid -> 7 unique points):
#   Memory axis @ 4 vCPU : 128, 256, 512, 1024, 2048 MB      (5 points)
#   vCPU cut    @ 1024 MB: 2, 4, 8 vCPU                       (3 points)
#   1024MB/4vCPU is shared by both axes                       => 7 unique
#   + 8th reference measurement: quarkus-hibernate @ 1024/4 only
#     (NOT swept; one reference point for its known ~+12% CPU/req offset).
#
# ARMS:
#   exeris-community + quarkus-tuned across all 7 points;
#   quarkus-hibernate ONLY at the 1024MB/4vCPU anchor.
#
# FIXED per point (locked decisions, forwarded to the constrained runner):
#   workload   : single-read GET /api/v1/user?id=1 (via the sweep contract endpoint)
#   load model : saturation, 128 connections / 4 threads, closed-loop wrk
#   window     : warmup 120s / measurement 300s (from the fixed contract)
#   GC         : ParallelGC (--jvm-gc parallel; 2026-06-23 dossier survivor:
#                Serial->SIGSEGV, ZGC->OOM under cap, Parallel stayed up)
#   DB pool    : fixed min == max == 16 (this is the matrix, not the pool sweep)
#   memory.max : caps the APP only; Postgres runs OUTSIDE the budget (its RSS is
#                reported alongside, never inside the app budget).
#   repeats    : n=3, INTERLEAVED (repeat is the outer loop) so each point's 3
#                samples are spread across the campaign -> honest CV%.
#
# HEAP POLICY (user decision): per-arm architecture-appropriate heap FRACTION of
# memory.max, applied per point, passed via --jvm-xmx-mb (NOT the identical
# ~3/4*MaxRAM auto-derivation). exeris-community uses 0.25 (crypto off + off-heap
# design => tiny heap need, ~16MB fits 128MB, so 0.25 = 32MB @128MB with floor
# headroom); quarkus-tuned and the quarkus-hibernate reference use 0.75 (the
# JVM-heap-standard, ~ the container ergonomic). Fractions are env-overridable
# (MATRIX_HEAP_FRAC_COMMUNITY / MATRIX_HEAP_FRAC_QUARKUS); a per-arm absolute
# MATRIX_XMX_MB_* wins over the fraction. Every row DECLARES jvm.xmx_mb +
# jvm.heap_fraction_of_budget + arm. No upward clamp: a tiny computed Xmx is
# passed as-is so a JVM OOM / fail-to-start at a low budget is a recorded RESULT
# (the floor), not a harness error.
#
# FAIRNESS CONTROL (Exeris-only overhead, plaintext H1): the exeris-community arm
# runs with EXERIS_SUBSYSTEMS=http,persistence (crypto OUT; ExerisCommunityApplication
# default is http,persistence,crypto). Crypto is unused native memory Quarkus never
# allocates in a plaintext sweep and is what blocks exeris from the 128MB floor, so
# dropping it is a fairness + footprint correction, configurable via
# MATRIX_EXERIS_SUBSYSTEMS. Belt-and-suspenders, also exports
# EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false and EXERIS_TELEMETRY_JFR_ENABLED=false
# (telemetry is not in the default subsystem set; harmless). All forwarded
# explicitly through the systemd-run relaunch so they can't be inherited-on, and
# set ONLY for the community arm (Quarkus ignores these vars). (Benchmark JFR is
# already off on the constrained path.)
#
# OUTCOME POLICY: a budget where an arm OOMs / will-not-start is a RESULT (the
# curve's floor for that arm), recorded from constrained-execution-evidence.json,
# NOT a harness failure. Only a CONFIG_ERROR / limit-mismatch (rc 64) from the
# constrained runner is fail-closed: it means the cgroup budget was not enforced,
# so the campaign aborts rather than record un-capped numbers.
#
# CLASSIFICATION: Community tier, H1, pure (no compat layer), constrained,
# track-c, claim_scope=descriptive_only, comparison_policy=forbidden. wrk is
# closed-loop, so the recorded p99 is a COORDINATED-OMISSION figure
# (queueing ~= concurrency/throughput) for rank-ordering only, NOT a service-time
# tail. Cross-arm throughput comparison is NOT eligible here; route any
# comparative claim to exeris-benchmarks-verification with a perf-box
# comparison-eligible run.
#
# ENVIRONMENT: author POSIX-ish bash; RUNS on a Linux perf-box with cgroup v2 +
# systemd-run (the constrained runner relaunches each target under
# `systemd-run --user --scope -p MemoryMax=.. -p CPUQuota=..`). Do NOT run on
# Windows. Use --dry-run to print every planned invocation without executing.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONSTRAINED_RUNNER="${REPO_ROOT}/scripts/run-entity-read-by-id-constrained.sh"
PROFILES_JSON="${REPO_ROOT}/runtime/profiles/entity-read-by-id-memory-cpu-sweep-profiles.json"
SCENARIO_JSON="${REPO_ROOT}/scenarios/entity-read-by-id/memory-cpu-sweep-scenario.json"

REPEATS="${MATRIX_REPEATS:-3}"
# Target/client CPU pins. Left EMPTY by default so the sweep auto-derives a per-point
# disjoint partition from each point's vCPU (see matrix_affinity_for_vcpu). Setting
# either var forces a manual override of that pin for EVERY point (advanced; you own
# keeping target and client disjoint).
CPU_AFFINITY="${MATRIX_CPU_AFFINITY:-}"
CLIENT_CPU_AFFINITY="${MATRIX_CLIENT_CPU_AFFINITY:-}"
HARDWARE_PROFILE="${BENCHMARK_HARDWARE_PROFILE:-perf-box-amd64}"
DB_POOL_SIZE="${MATRIX_DB_POOL_SIZE:-16}"
SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-1}"
CAPTURE_PG_RSS="${MATRIX_CAPTURE_PG_RSS:-1}"
# The matrix REQUIRES a pre-launched tuned Postgres (host-net + fixed cpuset 4-7,12-15)
# bound to :5432 — a wiring the base runner's managed-DB path cannot reproduce (its
# docker-run fallback is host-net but cpuset-less). So reuse-external is the matrix
# default: the base runner must adopt the running tuned DB, never recreate it (which
# would silently drop the cpuset mid-sweep). Set MATRIX_ALLOW_EXTERNAL_DB=0 only if you
# deliberately want the base runner to manage its own (untuned) DB.
ALLOW_EXTERNAL_DB="${MATRIX_ALLOW_EXTERNAL_DB:-1}"
# Per-arm heap fraction of memory.max (user decision; see HEAP POLICY header).
# community 0.25: with crypto off + exeris's off-heap design its heap need is tiny
# (empirically ~16MB fits a 128MB budget), so 0.25 (32MB @128MB) is a safe default
# with headroom over the floor. quarkus 0.75: JVM-heap-standard.
HEAP_FRAC_COMMUNITY="${MATRIX_HEAP_FRAC_COMMUNITY:-0.25}"
HEAP_FRAC_QUARKUS="${MATRIX_HEAP_FRAC_QUARKUS:-0.75}"
# Exeris subsystem selection for the community arm. ExerisCommunityApplication
# boots DEFAULT_SUBSYSTEMS="http,persistence,crypto" (selectable via EXERIS_SUBSYSTEMS).
# This is a PLAINTEXT H1 sweep, so crypto is unused native memory Quarkus never
# allocates (and the thing that blocks exeris from reaching the 128MB floor) -> drop
# it. telemetry is not in the default set. Community-only (Quarkus ignores the var).
EXERIS_SUBSYSTEMS_COMMUNITY="${MATRIX_EXERIS_SUBSYSTEMS:-http,persistence}"
DRY_RUN=0
UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="${REPO_ROOT}/results/constrained/entity-read-by-id/${UTC_STAMP}-memory-cpu-matrix"

usage() {
  cat <<EOF
Usage: scripts/run-entity-read-by-id-memory-cpu-matrix.sh [options]

  --output-dir <path>        campaign dir (default: ${CAMPAIGN_DIR})
  --repeats <n>              interleaved repeats per (point,arm) (default: ${REPEATS})
  --cpu-affinity <cpuset>    server-side taskset pin forwarded to each run (e.g. 0-7).
                             Must span >= the point's vCPU (the 8vCPU point needs >=8 CPUs).
                             Empty = no pin; the systemd-run CPUQuota is the enforced budget.
  --profiles-json <path>     sweep execution profiles (default: ${PROFILES_JSON##*/})
  --scenario-json <path>     sweep fixed contracts (default: ${SCENARIO_JSON##*/})
  --hardware-profile <id>    documentation label recorded in provenance (default: ${HARDWARE_PROFILE})
  --db-pool-size <n>         fixed min==max DB pool per run (default: ${DB_POOL_SIZE})
  --no-pg-rss                skip the best-effort Postgres RSS snapshot
  --dry-run                  print every planned invocation; execute nothing (safe on Windows)
  -h | --help                this help

Env knobs (heap + fairness; see HEAP POLICY / FAIRNESS CONTROL header):
  MATRIX_HEAP_FRAC_COMMUNITY   community heap fraction of memory.max (default 0.25)
  MATRIX_HEAP_FRAC_QUARKUS     quarkus (tuned + hibernate) heap fraction (default 0.75)
  MATRIX_XMX_MB_COMMUNITY / MATRIX_XMX_MB_QUARKUS_TUNED / MATRIX_XMX_MB_QUARKUS_HIBERNATE
    per-arm ABSOLUTE -Xmx (MB); HIGHER precedence than the fraction when set.
  MATRIX_EXERIS_SUBSYSTEMS     EXERIS_SUBSYSTEMS for the community arm (default
    http,persistence => crypto OUT for the plaintext H1 sweep). Community-only.
  BENCHMARK_SKIP_TARGET_BUILD  (default 1) use prebuilt target jars only.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) CAMPAIGN_DIR="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --cpu-affinity) CPU_AFFINITY="$2"; shift 2 ;;
    --client-cpu-affinity) CLIENT_CPU_AFFINITY="$2"; shift 2 ;;
    --profiles-json) PROFILES_JSON="$2"; shift 2 ;;
    --scenario-json) SCENARIO_JSON="$2"; shift 2 ;;
    --hardware-profile) HARDWARE_PROFILE="$2"; shift 2 ;;
    --db-pool-size) DB_POOL_SIZE="$2"; shift 2 ;;
    --no-pg-rss) CAPTURE_PG_RSS=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || (( REPEATS < 1 )); then
  echo "ERROR: --repeats must be a positive integer (got: $REPEATS)" >&2; exit 1
fi
if ! [[ "$DB_POOL_SIZE" =~ ^[0-9]+$ ]] || (( DB_POOL_SIZE < 1 )); then
  echo "ERROR: --db-pool-size must be a positive integer (got: $DB_POOL_SIZE)" >&2; exit 1
fi
if [[ "$SKIP_TARGET_BUILD" != "0" && "$SKIP_TARGET_BUILD" != "1" ]]; then
  echo "ERROR: BENCHMARK_SKIP_TARGET_BUILD must be 0 or 1 (got: $SKIP_TARGET_BUILD)" >&2; exit 1
fi
# Fractions must be positive decimals; absolute overrides (if set) positive ints.
for fv in "$HEAP_FRAC_COMMUNITY" "$HEAP_FRAC_QUARKUS"; do
  if ! LC_ALL=C awk -v f="$fv" 'BEGIN{exit (f ~ /^[0-9]*\.?[0-9]+$/ && f+0 > 0) ? 0 : 1}'; then
    echo "ERROR: heap fraction must be a positive decimal (got: '$fv'); check MATRIX_HEAP_FRAC_*" >&2; exit 1
  fi
done
for xv in COMMUNITY QUARKUS_TUNED QUARKUS_HIBERNATE; do
  en="MATRIX_XMX_MB_${xv}"; ev="${!en:-}"
  if [[ -n "$ev" ]] && ! [[ "$ev" =~ ^[0-9]+$ && "$ev" -ge 1 ]]; then
    echo "ERROR: ${en}='${ev}' must be a positive integer (MB)" >&2; exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2; exit 1
fi
if [[ ! -x "$CONSTRAINED_RUNNER" ]]; then
  echo "ERROR: constrained runner not found/executable: $CONSTRAINED_RUNNER" >&2; exit 1
fi
for f in "$PROFILES_JSON" "$SCENARIO_JSON"; do
  if [[ ! -f "$f" ]]; then echo "ERROR: missing spec file: $f" >&2; exit 1; fi
  if ! jq -e . "$f" >/dev/null 2>&1; then echo "ERROR: invalid JSON: $f" >&2; exit 1; fi
done

# -----------------------------------------------------------------------------
# Point + arm model. POINTS: mem_mb|vcpu|axis|profile_id|contract_id
# -----------------------------------------------------------------------------
POINTS=(
  "128|4|memory|runtime-constrained-128m-4vcpu-v1|fixed_contract_runtime_h1_constrained_single_read_128m_4vcpu_v1"
  "256|4|memory|runtime-constrained-256m-4vcpu-v1|fixed_contract_runtime_h1_constrained_single_read_256m_4vcpu_v1"
  "512|4|memory|runtime-constrained-512m-4vcpu-v1|fixed_contract_runtime_h1_constrained_single_read_512m_4vcpu_v1"
  "1024|4|shared|runtime-constrained-1024m-4vcpu-v1|fixed_contract_runtime_h1_constrained_single_read_1024m_4vcpu_v1"
  "2048|4|memory|runtime-constrained-2048m-4vcpu-v1|fixed_contract_runtime_h1_constrained_single_read_2048m_4vcpu_v1"
  "1024|2|cpu|runtime-constrained-1024m-2vcpu-v1|fixed_contract_runtime_h1_constrained_single_read_1024m_2vcpu_v1"
  "1024|8|cpu|runtime-constrained-1024m-8vcpu-v1|fixed_contract_runtime_h1_constrained_single_read_1024m_8vcpu_v1"
)

# ARMS: arm_id|target_runtime|xmx_env_key|frac_key|jar_glob
#   xmx_env_key -> MATRIX_XMX_MB_<key> absolute override (per-arm)
#   frac_key    -> COMMUNITY|QUARKUS fraction bucket (both quarkus arms share QUARKUS)
ARM_COMMUNITY="exeris-community|community|COMMUNITY|COMMUNITY|targets/exeris-community-app/target/exeris-community-app-*.jar"
ARM_QUARKUS_TUNED="quarkus-tuned|quarkus-tuned|QUARKUS_TUNED|QUARKUS|targets/quarkus-benchmark-app-tuned/target/quarkus-benchmark-app-tuned-*-runner.jar"
ARM_QUARKUS_HIBERNATE="quarkus-hibernate|quarkus|QUARKUS_HIBERNATE|QUARKUS|targets/quarkus-benchmark-app/target/quarkus-benchmark-app-*-runner.jar"

arms_for_point() { # $1=mem $2=vcpu -> prints one ARM_* spec per line
  printf '%s\n' "$ARM_COMMUNITY" "$ARM_QUARKUS_TUNED"
  if [[ "$1" == "1024" && "$2" == "4" ]]; then
    printf '%s\n' "$ARM_QUARKUS_HIBERNATE"   # single reference measurement
  fi
}

# ---------------------------------------------------------------------------
# Per-point CPU partition (tuned-PG isolation) on this 16-logical / 8-physical
# box. Postgres is externally pinned to 4-7,12-15 (4 phys) and reused across every
# point (BENCHMARK_ALLOW_EXTERNAL_DB). The target app and the load driver each get a
# taskset pin, sized to the point's vCPU and kept DISJOINT so wrk can never steal
# cycles from the measured process — the constrained RSS + CPU/req readings are the
# durable output and must be uncontaminated.
#
#   vCPU <= 4 : target 0-1,8-9 (2 phys / 4 logical; the scope CPUQuota caps actual use
#               at the point's vCPU), loadgen 2-3,10-11 (2 phys). Target, loadgen, and
#               DB are all mutually disjoint — the SAME clean partition as the 2026-07
#               tuned-PG comparative triad. This covers the entire 5-point memory curve
#               plus the 2-vCPU cut (6 of 7 points).
#   vCPU = 8  : the target needs 4 physical cores -> 0-3,8-11 (8 logical), which swallows
#               the loadgen's 2-3,10-11. On an 8-phys box there is no fourth disjoint
#               partition, so at THIS ONE point the load driver co-locates on the DB
#               cpuset (4-7,12-15). Target cores stay isolated (RSS + CPU/req remain
#               clean); only throughput is DB+loadgen-contention-bounded here. Recorded
#               per-point as affinity_note="loadgen-colocated-with-db", never hidden.
matrix_affinity_for_vcpu() { # $1=vcpu -> prints "<target_cpuset>\t<client_cpuset>\t<note>"
  local vcpu="$1"
  if [[ "$vcpu" -le 4 ]]; then
    printf '0-1,8-9\t2-3,10-11\tdisjoint\n'
  else
    printf '0-3,8-11\t4-7,12-15\tloadgen-colocated-with-db\n'
  fi
}

# resolve_xmx <xmx_env_key> <frac_key> <mem_mb> -> "xmx_mb\theap_fraction\txmx_source"
# Absolute MATRIX_XMX_MB_<key> wins over the fraction. No upward clamp: the
# computed value is passed as-is (a tiny Xmx -> JVM OOM/fail-to-start = a result).
resolve_xmx() {
  local xmx_key="$1" frac_key="$2" mem="$3"
  local abs_env="MATRIX_XMX_MB_${xmx_key}" abs frac xmx source hf
  abs="${!abs_env:-}"
  case "$frac_key" in
    COMMUNITY) frac="$HEAP_FRAC_COMMUNITY" ;;
    QUARKUS)   frac="$HEAP_FRAC_QUARKUS" ;;
    *)         frac="0.25" ;;   # unreachable guard (frac_key is always COMMUNITY|QUARKUS)
  esac
  if [[ -n "$abs" ]]; then
    xmx="$abs"
    source="absolute-override:${abs_env}"
  else
    xmx="$(LC_ALL=C awk -v f="$frac" -v m="$mem" 'BEGIN{printf "%.0f", f*m}')"
    source="fraction:${frac}"
  fi
  hf="$(LC_ALL=C awk -v x="$xmx" -v m="$mem" 'BEGIN{ if (m>0) printf "%.4f", x/m; else printf "0" }')"
  printf '%s\t%s\t%s\n' "$xmx" "$hf" "$source"
}

# -----------------------------------------------------------------------------
# Provenance helpers
# -----------------------------------------------------------------------------
resolve_and_hash_jar() { # $1=glob -> "path\tsha256\tsize_bytes\tmtime_epoch" or "\t\t\t"
  local glob="$1" path sha size mtime
  path="$(ls -1 ${glob} 2>/dev/null | sort | tail -n1 || true)"
  if [[ -z "$path" || ! -f "$path" ]]; then printf '\t\t\t\n'; return 0; fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha="$(sha256sum "$path" 2>/dev/null | awk '{print $1}')"
  else
    sha=""
  fi
  size="$(wc -c < "$path" 2>/dev/null | tr -d ' ' || echo '')"
  mtime="$(date -r "$path" +%s 2>/dev/null || echo '')"
  printf '%s\t%s\t%s\t%s\n' "$path" "$sha" "$size" "$mtime"
}

mem_to_kb() { # "45.6MiB" / "1.9GiB" / "512KiB" / "1024B" -> KB integer
  local s="$1" num unit
  num="$(printf '%s' "$s" | sed -E 's/^([0-9.]+).*/\1/')"
  unit="$(printf '%s' "$s" | sed -E 's/^[0-9.]+//')"
  [[ "$num" =~ ^[0-9.]+$ ]] || { printf ''; return 0; }
  LC_ALL=C awk -v n="$num" -v u="$unit" 'BEGIN{
    u=tolower(u); f="";
    if(u=="b")f=1/1024; else if(u=="kib"||u=="kb"||u=="k")f=1;
    else if(u=="mib"||u=="mb"||u=="m")f=1024; else if(u=="gib"||u=="gb"||u=="g")f=1024*1024;
    if(f=="")exit 1; printf "%.0f", n*f
  }' 2>/dev/null || printf ''
}

capture_pg_rss() { # -> "pg_rss_kb\tsource"  ("null\tnone" if unavailable)
  local names mem kb
  if [[ "$CAPTURE_PG_RSS" != "1" ]] || ! command -v docker >/dev/null 2>&1; then
    printf 'null\tnone\n'; return 0
  fi
  names="$(docker ps --filter 'ancestor=postgres:16.2' --format '{{.Names}}' 2>/dev/null | head -n1)"
  [[ -z "$names" ]] && names="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($0) ~ /postgres/ {print $1; exit}')"
  [[ -z "$names" ]] && { printf 'null\tnone\n'; return 0; }
  mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$names" 2>/dev/null | awk '{print $1}')"
  [[ -z "$mem" ]] && { printf 'null\tnone\n'; return 0; }
  kb="$(mem_to_kb "$mem")"
  [[ -z "$kb" ]] && { printf 'null\tnone\n'; return 0; }
  printf '%s\tdocker-stats:%s\n' "$kb" "$names"
}

read_json_or_empty() { [[ -f "$1" ]] && jq -c . "$1" 2>/dev/null || echo '{}'; }

collect_run_record() {
  local mem="$1" vcpu="$2" axis="$3" arm="$4" target_runtime="$5" repeat="$6"
  local run_dir="$7" rc="$8" pg_rss_kb="$9" pg_rss_source="${10}"
  local profile_id="${11}" contract_id="${12}"
  local xmx_mb="${13}" heap_frac="${14}" xmx_source="${15}"
  local telemetry_subsystem="${16}" telemetry_jfr="${17}" exeris_subsystems="${18}"
  local target_cpuset="${19}" client_cpuset="${20}" affinity_note="${21}"
  local result_json evidence_json resource_json
  result_json="$(read_json_or_empty "$run_dir/result.json")"
  evidence_json="$(read_json_or_empty "$run_dir/constrained-execution-evidence.json")"
  resource_json="$(read_json_or_empty "$run_dir/resource-metrics.json")"

  # -c: one compact JSON object per line so runs.jsonl is true JSON Lines.
  jq -cn \
    --argjson result "$result_json" \
    --argjson evidence "$evidence_json" \
    --argjson resource "$resource_json" \
    --arg mem "$mem" --arg vcpu "$vcpu" --arg axis "$axis" \
    --arg arm "$arm" --arg target_runtime "$target_runtime" \
    --arg repeat "$repeat" --arg run_dir "$run_dir" --arg rc "$rc" \
    --arg pg_rss_kb "$pg_rss_kb" --arg pg_rss_source "$pg_rss_source" \
    --arg profile_id "$profile_id" --arg contract_id "$contract_id" \
    --arg xmx_mb "$xmx_mb" --arg heap_frac "$heap_frac" --arg xmx_source "$xmx_source" \
    --arg telemetry_subsystem "$telemetry_subsystem" --arg telemetry_jfr "$telemetry_jfr" \
    --arg exeris_subsystems "$exeris_subsystems" \
    --arg target_cpuset "$target_cpuset" --arg client_cpuset "$client_cpuset" \
    --arg affinity_note "$affinity_note" \
    '
    ($result.metrics.total_requests // null) as $tr
    | ($resource.cpu_time_seconds // null) as $cpu
    | ($evidence.cgroup_effective.cpu_stat.nr_periods // null) as $np
    | ($evidence.cgroup_effective.cpu_stat.nr_throttled // null) as $nt
    | (($evidence.jvm_overlay_flags // [])
        | map(select(type == "string" and test("^-Xmx[0-9]+m$")))
        | if length > 0 then (.[0] | ltrimstr("-Xmx") | rtrimstr("m") | tonumber) else null end) as $xmx_eff
    | {
        memory_max_mb: ($mem|tonumber),
        vcpu: ($vcpu|tonumber),
        axis: $axis,
        arm: $arm,
        target_runtime: $target_runtime,
        repeat: ($repeat|tonumber),
        run_dir: $run_dir,
        constrained_runner_exit_code: ($rc|tonumber),
        execution_profile_id: $profile_id,
        contract_id: $contract_id,
        endpoint_path: ($result.run_config.endpoint_path // null),
        outcome: ($evidence.outcome // "unknown"),
        memory_failure_kind: ($evidence.memory_failure_kind // null),
        phase_reached: ($evidence.phase_reached // null),
        oom_after_measurement: ($evidence.oom_after_measurement // null),
        oom_kill_delta: ($evidence.cgroup_effective.memory_events.oom_kill // null),
        hs_err_present: ($evidence.crash_artifacts.hs_err_present // null),
        jit_representativeness: ($evidence.jit_representativeness // ($result.run_config.jit_representativeness // null)),
        jvm: {
          xmx_mb: ($xmx_mb|tonumber),
          heap_fraction_of_budget: ($heap_frac|tonumber),
          xmx_source: $xmx_source,
          xmx_mb_effective: $xmx_eff
        },
        fairness_controls: {
          exeris_subsystems: (if $exeris_subsystems == "n/a" then null else $exeris_subsystems end),
          crypto_subsystem_enabled:
            (if $exeris_subsystems == "n/a" then null
             else ($exeris_subsystems | test("(^|,)crypto(,|$)")) end),
          exeris_telemetry_subsystem_enabled:
            (if $telemetry_subsystem == "false" then false
             elif $telemetry_subsystem == "n/a" then null else true end),
          exeris_telemetry_jfr_enabled:
            (if $telemetry_jfr == "false" then false
             elif $telemetry_jfr == "n/a" then null else true end)
        },
        cpu_partition: {
          target_cpuset: $target_cpuset,
          loadgen_cpuset: $client_cpuset,
          db_cpuset: "4-7,12-15",
          affinity_note: $affinity_note,
          loadgen_disjoint_from_target: ($affinity_note | test("disjoint")),
          note: "DB externally pinned to 4-7,12-15 (reused, tuned-PG). target+loadgen disjoint for vCPU<=4; at vCPU=8 loadgen co-locates with the DB cpuset so throughput is DB+loadgen-bound there while target RSS+CPU/req stay isolated."
        },
        rps: ($result.metrics.throughput_rps // null),
        total_requests: $tr,
        total_errors: ($result.metrics.total_errors // null),
        error_rate_pct: ($result.metrics.error_rate_pct // null),
        latency_p50_us: ($result.metrics.latency_p50_us // null),
        latency_p99_us: ($result.metrics.latency_p99_us // null),
        latency_label: "wrk-closed-loop-coordinated-omission",
        cpu_time_seconds: $cpu,
        cpu_per_req_ms: (if ($tr != null and $cpu != null and $tr > 0) then ($cpu / $tr * 1000) else null end),
        avg_cores_used: ($resource.avg_cores_used // null),
        peak_rss_kb: ($resource.peak_rss_kb // null),
        smaps_rss_kb_max: ($resource.smaps_rss_kb_max // null),
        heap_committed_kb: ($resource.jvm.heap_committed_kb // null),
        offheap_kb_estimate: ($resource.jvm.offheap_kb_estimate // null),
        cgroup_memory_peak_kb: (($evidence.cgroup_effective.memory_peak_bytes // null) | if . == null then null else (. / 1024 | floor) end),
        cgroup_memory_max_bytes: ($evidence.cgroup_effective.memory_max_bytes // null),
        nr_periods: $np,
        throttled_periods: $nt,
        throttled_usec: ($evidence.cgroup_effective.cpu_stat.throttled_usec // null),
        cpu_throttle_ratio: (if ($np != null and $np > 0 and $nt != null) then ($nt / $np) else null end),
        pg_rss_kb: (if $pg_rss_kb == "null" then null else ($pg_rss_kb|tonumber) end),
        pg_rss_source: $pg_rss_source,
        pg_rss_note: "postgres runs OUTSIDE the app cgroup budget; best-effort post-run docker-stats snapshot; NEVER counted in the app memory budget"
      }'
}

# -----------------------------------------------------------------------------
# Provenance manifest (jar sha256 per target + heap policy + fairness + repro)
# -----------------------------------------------------------------------------
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
mkdir -p "$CAMPAIGN_DIR"
RUNS_JSONL="$CAMPAIGN_DIR/runs.jsonl"
: > "$RUNS_JSONL"
MANIFEST_FILE="$CAMPAIGN_DIR/campaign-manifest.json"

build_target_provenance_json() {
  local specs=("$ARM_COMMUNITY" "$ARM_QUARKUS_TUNED" "$ARM_QUARKUS_HIBERNATE")
  local out="[]" spec arm_id target_runtime xmx_key frac_key jar_glob path sha size mtime
  for spec in "${specs[@]}"; do
    IFS='|' read -r arm_id target_runtime xmx_key frac_key jar_glob <<< "$spec"
    IFS=$'\t' read -r path sha size mtime < <(resolve_and_hash_jar "${REPO_ROOT}/${jar_glob}")
    if [[ -z "$path" ]]; then
      echo "WARN: target jar not found for arm '$arm_id' (glob: ${jar_glob}); provenance sha256 will be recorded at run time on the perf-box." >&2
    fi
    out="$(jq -c \
      --arg arm "$arm_id" --arg tr "$target_runtime" --arg glob "$jar_glob" \
      --arg path "$path" --arg sha "$sha" --arg size "$size" --arg mtime "$mtime" \
      '. + [{
         arm: $arm, target_runtime: $tr, jar_glob: $glob,
         jar_path: (if $path == "" then null else $path end),
         jar_sha256: (if $sha == "" then null else $sha end),
         jar_size_bytes: (if $size == "" then null else ($size|tonumber) end),
         jar_mtime_epoch: (if $mtime == "" then null else ($mtime|tonumber) end)
       }]' <<< "$out")"
  done
  printf '%s' "$out"
}

build_heap_table_json() {
  # Deterministic per-(arm,memory) resolved heap, using the same resolve_xmx logic.
  # Xmx depends only on memory.max, so the CPU-cut points reuse the 1024MB row.
  local out="[]" spec arm_id tr xmx_key frac_key jar_glob mem xmx hf src
  for spec in "$ARM_COMMUNITY" "$ARM_QUARKUS_TUNED"; do
    IFS='|' read -r arm_id tr xmx_key frac_key jar_glob <<< "$spec"
    for mem in 128 256 512 1024 2048; do
      IFS=$'\t' read -r xmx hf src < <(resolve_xmx "$xmx_key" "$frac_key" "$mem")
      out="$(jq -c --arg arm "$arm_id" --argjson mem "$mem" --argjson xmx "$xmx" \
        --arg hf "$hf" --arg src "$src" \
        '. + [{arm:$arm, memory_max_mb:$mem, xmx_mb:$xmx, heap_fraction_of_budget:($hf|tonumber), xmx_source:$src}]' <<<"$out")"
    done
  done
  IFS='|' read -r arm_id tr xmx_key frac_key jar_glob <<< "$ARM_QUARKUS_HIBERNATE"
  IFS=$'\t' read -r xmx hf src < <(resolve_xmx "$xmx_key" "$frac_key" 1024)
  out="$(jq -c --arg arm "$arm_id" --argjson mem 1024 --argjson xmx "$xmx" \
    --arg hf "$hf" --arg src "$src" \
    '. + [{arm:$arm, memory_max_mb:$mem, xmx_mb:$xmx, heap_fraction_of_budget:($hf|tonumber), xmx_source:$src, reference_point_only:true}]' <<<"$out")"
  printf '%s' "$out"
}

TARGET_PROVENANCE_JSON="$(build_target_provenance_json)"
HEAP_TABLE_JSON="$(build_heap_table_json)"

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg campaign_dir "$CAMPAIGN_DIR" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg hardware_profile "$HARDWARE_PROFILE" \
  --arg profiles_json "$PROFILES_JSON" \
  --arg scenario_json "$SCENARIO_JSON" \
  --arg cpu_affinity_target_override "${CPU_AFFINITY:-none}" \
  --arg cpu_affinity_client_override "${CLIENT_CPU_AFFINITY:-none}" \
  --argjson repeats "$REPEATS" \
  --argjson db_pool_size "$DB_POOL_SIZE" \
  --argjson skip_target_build "$SKIP_TARGET_BUILD" \
  --arg heap_frac_community "$HEAP_FRAC_COMMUNITY" \
  --arg heap_frac_quarkus "$HEAP_FRAC_QUARKUS" \
  --arg xmx_abs_community "${MATRIX_XMX_MB_COMMUNITY:-none}" \
  --arg xmx_abs_quarkus_tuned "${MATRIX_XMX_MB_QUARKUS_TUNED:-none}" \
  --arg xmx_abs_quarkus_hibernate "${MATRIX_XMX_MB_QUARKUS_HIBERNATE:-none}" \
  --arg exeris_subsystems_community "$EXERIS_SUBSYSTEMS_COMMUNITY" \
  --argjson heap_table "$HEAP_TABLE_JSON" \
  --argjson target_provenance "$TARGET_PROVENANCE_JSON" \
  '{
    schema_version: "1",
    matrix: "entity-read-by-id-memory-cpu",
    generated_at: $generated_at,
    campaign_dir: $campaign_dir,
    separation_axes: {
      tier: "community",
      protocol_mode: "h1",
      transport_mode: "loopback-h1",
      benchmark_family: "runtime-wrk",
      mode: "baseline-db",
      purity: "pure",
      execution_class: "exploratory-constrained",
      track_id: "track-c",
      claim_scope: "descriptive_only",
      comparison_policy: "forbidden",
      comparison_axis: "within-tier"
    },
    reproducibility: {
      benchmark_commit_sha: $commit_sha,
      hardware_profile: $hardware_profile,
      jvm_gc: "parallel",
      db_pool_min_size: $db_pool_size,
      db_pool_max_size: $db_pool_size,
      warmup_seconds: 120,
      duration_seconds: 300,
      threads: 4,
      connections: 128,
      endpoint: "GET /api/v1/user?id=1",
      repeats: $repeats,
      repeat_ordering: "interleaved (repeat is the outer loop)",
      cpu_partition_policy: {
        model: "per-point disjoint tuned-PG partition derived from each point vCPU (matrix_affinity_for_vcpu)",
        db_cpuset: "4-7,12-15 (externally pinned, reused across all points)",
        vcpu_le_4: "target 0-1,8-9 / loadgen 2-3,10-11 (fully disjoint; = 2026-07 tuned-PG triad partition)",
        vcpu_eq_8: "target 0-3,8-11 / loadgen 4-7,12-15 (loadgen co-located with DB; target isolated, throughput DB-bound at this point only)",
        target_override: (if $cpu_affinity_target_override == "none" then null else $cpu_affinity_target_override end),
        client_override: (if $cpu_affinity_client_override == "none" then null else $cpu_affinity_client_override end)
      },
      skip_target_build: $skip_target_build,
      profiles_json: $profiles_json,
      scenario_json: $scenario_json
    },
    heap_policy: {
      model: "per-arm architecture-appropriate heap fraction of memory.max, applied per point, passed via --jvm-xmx-mb (user decision; replaces the identical ~3/4*MaxRAM auto-derivation)",
      community_fraction_of_budget: ($heap_frac_community|tonumber),
      quarkus_fraction_of_budget: ($heap_frac_quarkus|tonumber),
      rationale: "exeris-community 0.25 (crypto off + off-heap design => tiny heap need, ~16MB fits a 128MB budget; 0.25 gives 32MB @128MB with floor headroom); quarkus-tuned + quarkus-hibernate 0.75 (JVM-heap-standard, ~ container ergonomic).",
      absolute_overrides_mb: {
        "exeris-community": (if $xmx_abs_community == "none" then null else ($xmx_abs_community|tonumber) end),
        "quarkus-tuned": (if $xmx_abs_quarkus_tuned == "none" then null else ($xmx_abs_quarkus_tuned|tonumber) end),
        "quarkus-hibernate": (if $xmx_abs_quarkus_hibernate == "none" then null else ($xmx_abs_quarkus_hibernate|tonumber) end)
      },
      precedence: "absolute MATRIX_XMX_MB_<arm> overrides the fraction when set",
      floor_policy: "no upward clamp; a tiny computed Xmx is passed as-is so a JVM OOM / fail-to-start at a low budget is a recorded RESULT (the floor), not a harness error",
      xms_policy: "Xms == Xmx per arm (fixed heap, both arms): -Xms and -Xmx are both set to the per-arm resolved value, so neither arm resizes its heap during measurement. Eliminates growth dynamics so steady-state RSS is well-defined and sampling-independent (same rationale as the min=max DB pool). Community fixed at 0.25*mem, quarkus fixed at 0.75*mem.",
      resolved: $heap_table
    },
    fairness_controls: {
      applies_to: ["exeris-community"],
      exeris_subsystems_community: $exeris_subsystems_community,
      crypto_subsystem_disabled_for_community: ($exeris_subsystems_community | test("(^|,)crypto(,|$)") | not),
      exeris_telemetry_disabled_for_community: true,
      flags: [
        ("EXERIS_SUBSYSTEMS=" + $exeris_subsystems_community),
        "EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false",
        "EXERIS_TELEMETRY_JFR_ENABLED=false"
      ],
      rationale: "Plaintext H1 sweep: the crypto subsystem is unused native memory Quarkus never allocates (ExerisCommunityApplication default is http,persistence,crypto) and is what blocks exeris from the 128MB floor, so EXERIS_SUBSYSTEMS drops it (default http,persistence). Exeris telemetry is disabled belt-and-suspenders (not in the default subsystem set; harmless). Applied ONLY to the exeris-community arm (Quarkus ignores these vars) and forwarded explicitly through the systemd-run relaunch so they cannot be inherited-on. Benchmark JFR is already off on the constrained path."
    },
    target_provenance: $target_provenance,
    caveats: {
      latency: "wrk is closed-loop: recorded p99/p50 are COORDINATED-OMISSION figures (queueing ~= concurrency/throughput), for rank-ordering only, NOT a service-time tail. CO-free p99 needs wrk2 on a perf-box.",
      heap: "per-arm architecture-appropriate heaps (community 0.25, quarkus 0.75 of memory.max), declared per row (jvm.xmx_mb / jvm.heap_fraction_of_budget) - user decision. This is NOT an identical-knob configuration across arms; it is intentional and must be stated when reading the curve.",
      pg_rss: "postgres runs OUTSIDE the app cgroup budget; pg_rss_kb is a best-effort post-run docker-stats snapshot and is NEVER counted in the app memory budget.",
      comparison: "constrained/descriptive_only/track-c: cross-arm throughput comparison is NOT eligible here. Route comparative claims to a perf-box comparison-eligible run.",
      oom_is_a_result: "a point where an arm OOMs / will-not-start is recorded (outcome from constrained-execution-evidence.json), not a harness error."
    }
  }' > "$MANIFEST_FILE"

echo "[matrix] campaign_dir : $CAMPAIGN_DIR"
echo "[matrix] manifest     : $MANIFEST_FILE"
echo "[matrix] points=7 arms=exeris-community,quarkus-tuned (+quarkus-hibernate @1024/4) repeats=$REPEATS interleaved dry_run=$DRY_RUN"
echo "[matrix] gc=parallel db_pool=${DB_POOL_SIZE} (min==max) warmup=120s duration=300s 128c/4t endpoint=GET /api/v1/user?id=1"
echo "[matrix] heap: community=${HEAP_FRAC_COMMUNITY} quarkus=${HEAP_FRAC_QUARKUS} of memory.max (per-arm --jvm-xmx-mb); exeris telemetry OFF for community"
echo "[matrix] cpu partition (per-point, tuned-PG): DB=4-7,12-15 (external, reused); vCPU<=4 -> target 0-1,8-9 / loadgen 2-3,10-11 (disjoint); vCPU=8 -> target 0-3,8-11 / loadgen 4-7,12-15 (loadgen co-located w/ DB, target isolated)"
if [[ -n "$CPU_AFFINITY" ]]; then
  echo "[matrix] WARN: target pin OVERRIDDEN for every point -> $CPU_AFFINITY (ensure it spans >= each point vCPU and stays disjoint from loadgen)"
fi
if [[ -n "$CLIENT_CPU_AFFINITY" ]]; then
  echo "[matrix] WARN: loadgen pin OVERRIDDEN for every point -> $CLIENT_CPU_AFFINITY (ensure disjoint from target)"
fi

# -----------------------------------------------------------------------------
# Interleaved run loop: repeat OUTER so each (point,arm) sample is spread in time.
# -----------------------------------------------------------------------------
run_count=0
for r in $(seq 1 "$REPEATS"); do
  for point in "${POINTS[@]}"; do
    IFS='|' read -r mem vcpu axis profile_id contract_id <<< "$point"

    # Per-point disjoint CPU partition (see matrix_affinity_for_vcpu). Manual overrides
    # apply to every point if the operator set them.
    IFS=$'\t' read -r target_cpuset client_cpuset affinity_note < <(matrix_affinity_for_vcpu "$vcpu")
    if [[ -n "$CPU_AFFINITY" ]]; then target_cpuset="$CPU_AFFINITY"; affinity_note="${affinity_note}+target-override"; fi
    if [[ -n "$CLIENT_CPU_AFFINITY" ]]; then client_cpuset="$CLIENT_CPU_AFFINITY"; affinity_note="${affinity_note}+client-override"; fi

    while IFS= read -r arm_spec; do
      [[ -z "$arm_spec" ]] && continue
      IFS='|' read -r arm_id target_runtime xmx_key frac_key jar_glob <<< "$arm_spec"

      run_dir="$CAMPAIGN_DIR/point-${mem}m-${vcpu}vcpu/${arm_id}/repeat-${r}"

      # Per-arm per-point heap (Xmx), always passed as --jvm-xmx-mb.
      IFS=$'\t' read -r xmx_mb heap_frac xmx_source < <(resolve_xmx "$xmx_key" "$frac_key" "$mem")

      # Fairness (plaintext H1): for the community arm ONLY, drop the crypto
      # subsystem (unused native memory Quarkus never allocates) via EXERIS_SUBSYSTEMS,
      # and belt-and-suspenders disable Exeris telemetry. Quarkus ignores these vars.
      env_prefix=(
        "BENCHMARK_SKIP_TARGET_BUILD=${SKIP_TARGET_BUILD}"
        "BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE=${DB_POOL_SIZE}"
        "BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE=${DB_POOL_SIZE}"
        "BENCHMARK_ALLOW_EXTERNAL_DB=${ALLOW_EXTERNAL_DB}"
      )
      telemetry_subsystem="n/a"; telemetry_jfr="n/a"; exeris_subsystems="n/a"
      if [[ "$arm_id" == "exeris-community" ]]; then
        env_prefix+=(
          "EXERIS_SUBSYSTEMS=${EXERIS_SUBSYSTEMS_COMMUNITY}"
          "EXERIS_ENABLE_TELEMETRY_SUBSYSTEM=false"
          "EXERIS_TELEMETRY_JFR_ENABLED=false"
        )
        telemetry_subsystem="false"; telemetry_jfr="false"
        exeris_subsystems="$EXERIS_SUBSYSTEMS_COMMUNITY"
      fi

      cmd=(
        env "${env_prefix[@]}"
        "$CONSTRAINED_RUNNER"
          --execution-profile-id "$profile_id"
          --contract-id "$contract_id"
          --profiles-json "$PROFILES_JSON"
          --scenario-json "$SCENARIO_JSON"
          --target-runtime "$target_runtime"
          --target-build jvm
          --jvm-gc parallel
          --jvm-xms-mb "$xmx_mb"
          --jvm-xmx-mb "$xmx_mb"
          --output-dir "$run_dir"
      )
      cmd+=(--cpu-affinity "$target_cpuset" --client-cpu-affinity "$client_cpuset")

      run_count=$((run_count + 1))
      echo
      echo "[matrix] === run ${run_count}: point=${mem}m/${vcpu}vcpu arm=${arm_id} repeat=${r}/${REPEATS} xmx=${xmx_mb}m (${xmx_source}) subsystems=${exeris_subsystems} telemetry=${telemetry_subsystem} target_cpus=${target_cpuset} loadgen_cpus=${client_cpuset} (${affinity_note}) ==="
      if [[ "$DRY_RUN" == "1" ]]; then
        printf '[matrix][dry-run] %q ' "${cmd[@]}"; echo
        continue
      fi

      mkdir -p "$run_dir"
      set +e
      "${cmd[@]}"
      rc=$?
      set -e

      # Fail-closed: a CONFIG_ERROR / limit-mismatch (rc 64) means the cgroup budget
      # was not enforced -> the numbers would be un-capped. Abort rather than record.
      if [[ "$rc" -eq 64 ]]; then
        echo "ERROR: constrained runner returned CONFIG_ERROR/limit_mismatch (rc=64) for point=${mem}m/${vcpu}vcpu arm=${arm_id}. Fail-closed abort (fix the cgroup/systemd-run environment)." >&2
        exit 64
      fi

      IFS=$'\t' read -r pg_rss_kb pg_rss_source < <(capture_pg_rss)
      collect_run_record "$mem" "$vcpu" "$axis" "$arm_id" "$target_runtime" "$r" \
        "$run_dir" "$rc" "$pg_rss_kb" "$pg_rss_source" "$profile_id" "$contract_id" \
        "$xmx_mb" "$heap_frac" "$xmx_source" "$telemetry_subsystem" "$telemetry_jfr" \
        "$exeris_subsystems" "$target_cpuset" "$client_cpuset" "$affinity_note" \
        >> "$RUNS_JSONL"
      echo "[matrix] recorded: rc=${rc} xmx=${xmx_mb}m subsystems=${exeris_subsystems} pg_rss_kb=${pg_rss_kb} -> $run_dir"
    done < <(arms_for_point "$mem" "$vcpu")
  done
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "[matrix] dry-run complete: ${run_count} invocations planned (nothing executed, no aggregate written)."
  exit 0
fi

# -----------------------------------------------------------------------------
# Curve-ready aggregate keyed by (memory_max_mb, vcpu, arm).
# -----------------------------------------------------------------------------
CURVE_JSON="$CAMPAIGN_DIR/memory-cpu-curve.json"
CURVE_CSV="$CAMPAIGN_DIR/memory-cpu-curve.csv"
MANIFEST_JSON="$(jq -c . "$MANIFEST_FILE")"

jq -s \
  --argjson manifest "$MANIFEST_JSON" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '
  def stats($arr):
    ($arr | map(select(. != null))) as $a
    | ($a | length) as $n
    | if $n == 0 then {n:0, mean:null, stddev:null, cv_pct:null, min:null, max:null}
      else ($a | add / $n) as $mean
        | (if $n > 1 then ((($a | map((. - $mean) * (. - $mean)) | add) / ($n - 1)) | sqrt) else 0 end) as $sd
        | {n:$n, mean:$mean, stddev:$sd,
           cv_pct: (if $mean != 0 then ($sd / $mean * 100) else null end),
           min: ($a | min), max: ($a | max)}
      end;
  def arm_summary($runs):
    ($runs | map(select(.outcome == "ok"))) as $ok
    | {
        target_runtime: ($runs[0].target_runtime),
        execution_profile_id: ($runs[0].execution_profile_id),
        contract_id: ($runs[0].contract_id),
        endpoint_path: ($runs[0].endpoint_path),
        heap: {
          xmx_mb: ($runs[0].jvm.xmx_mb),
          heap_fraction_of_budget: ($runs[0].jvm.heap_fraction_of_budget),
          xmx_source: ($runs[0].jvm.xmx_source),
          xmx_mb_effective: ($runs | map(.jvm.xmx_mb_effective) | map(select(. != null)) | unique)
        },
        fairness_controls: ($runs[0].fairness_controls),
        n_total: ($runs | length),
        n_ok: ($ok | length),
        n_oom: ($runs | map(select(.outcome == "oom_killed")) | length),
        n_startup_failed: ($runs | map(select(.outcome == "startup_failed")) | length),
        n_readiness_timeout: ($runs | map(select(.outcome == "readiness_timeout")) | length),
        outcomes: ($runs | map(.outcome)),
        memory_failure_kinds: ($runs | map(.memory_failure_kind) | map(select(. != null)) | unique),
        jit_representativeness: ($runs | map(.jit_representativeness) | map(select(. != null)) | unique),
        rps: stats($ok | map(.rps)),
        cpu_per_req_ms: stats($ok | map(.cpu_per_req_ms)),
        peak_rss_kb: stats($ok | map(.peak_rss_kb)),
        cgroup_memory_peak_kb: stats($ok | map(.cgroup_memory_peak_kb)),
        avg_cores_used: stats($ok | map(.avg_cores_used)),
        throttled_periods: stats($ok | map(.throttled_periods)),
        cpu_throttle_ratio: stats($ok | map(.cpu_throttle_ratio)),
        pg_rss_kb: stats($runs | map(.pg_rss_kb)),
        latency_p99_us: {
          label: "wrk-closed-loop-coordinated-omission",
          values: ($ok | map(.latency_p99_us)),
          median: ($ok | map(.latency_p99_us) | map(select(. != null)) | sort
                   | if length == 0 then null else .[(length/2|floor)] end)
        },
        repeats: ($runs | sort_by(.repeat) | map({
          repeat, outcome, rps, total_requests, error_rate_pct,
          cpu_time_seconds, cpu_per_req_ms, peak_rss_kb, cgroup_memory_peak_kb,
          xmx_mb: .jvm.xmx_mb, xmx_mb_effective: .jvm.xmx_mb_effective,
          latency_p99_us, throttled_periods, cpu_throttle_ratio,
          oom_kill_delta, hs_err_present, phase_reached, pg_rss_kb, run_dir
        }))
      };
  {
    schema_version: "1",
    matrix: "entity-read-by-id-memory-cpu",
    generated_at: $generated_at,
    manifest: $manifest,
    curve_reading: {
      memory_budget_curve: "filter points where vcpu == 4, order by memory_max_mb, read each arm summary (rps / cgroup_memory_peak_kb / cpu_per_req_ms). Heap fraction differs per arm (community 0.25, quarkus 0.75) by design - read heap.xmx_mb alongside.",
      cpu_cut: "filter points where memory_max_mb == 1024, order by vcpu, read each arm summary.",
      shared_point: "1024MB/4vCPU is on both axes."
    },
    points: (
      group_by([.memory_max_mb, .vcpu])
      | map(
          (.[0]) as $p
          | {
              memory_max_mb: $p.memory_max_mb,
              vcpu: $p.vcpu,
              axis: $p.axis,
              on_memory_axis: ($p.vcpu == 4),
              on_cpu_axis: ($p.memory_max_mb == 1024),
              arms: (group_by(.arm) | map({ key: (.[0].arm), value: arm_summary(.) }) | from_entries)
            }
        )
      | sort_by(.vcpu, .memory_max_mb)
    )
  }
  ' "$RUNS_JSONL" > "$CURVE_JSON"

# Flat per-run CSV for spreadsheets / quick plotting.
jq -rs '
  (["memory_max_mb","vcpu","axis","arm","repeat","outcome","memory_failure_kind","phase_reached",
    "xmx_mb","heap_fraction_of_budget","xmx_source","exeris_subsystems","exeris_telemetry_subsystem_enabled",
    "rps","total_requests","error_rate_pct","cpu_time_seconds","cpu_per_req_ms",
    "peak_rss_kb","cgroup_memory_peak_kb","latency_p99_us","latency_label",
    "throttled_periods","nr_periods","cpu_throttle_ratio","oom_kill_delta","hs_err_present",
    "pg_rss_kb","jit_representativeness","run_dir"]),
  (.[] | [
    .memory_max_mb, .vcpu, .axis, .arm, .repeat, .outcome, .memory_failure_kind, .phase_reached,
    .jvm.xmx_mb, .jvm.heap_fraction_of_budget, .jvm.xmx_source, .fairness_controls.exeris_subsystems, .fairness_controls.exeris_telemetry_subsystem_enabled,
    .rps, .total_requests, .error_rate_pct, .cpu_time_seconds, .cpu_per_req_ms,
    .peak_rss_kb, .cgroup_memory_peak_kb, .latency_p99_us, .latency_label,
    .throttled_periods, .nr_periods, .cpu_throttle_ratio, .oom_kill_delta, .hs_err_present,
    .pg_rss_kb, .jit_representativeness, .run_dir
  ])
  | @csv
' "$RUNS_JSONL" > "$CURVE_CSV"

echo
echo "[matrix] runs recorded : $(wc -l < "$RUNS_JSONL" | tr -d ' ')"
echo "[matrix] curve JSON    : $CURVE_JSON"
echo "[matrix] curve CSV     : $CURVE_CSV"
echo "[matrix] runs (jsonl)  : $RUNS_JSONL"
echo "[matrix] done."
