#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCENARIO_JSON="${REPO_ROOT}/scenarios/entity-read-by-id/scenario.json"
PROFILES_JSON="${REPO_ROOT}/runtime/profiles/runtime-execution-profiles.json"
BASE_RUNNER="${REPO_ROOT}/scripts/run-entity-read-by-id.sh"

EXECUTION_PROFILE_ID="runtime-constrained-256m-1vcpu-v1"
CONTRACT_ID="fixed_contract_runtime_h1_constrained_smoke_256m_1vcpu_v1"
TARGET_RUNTIME="community"
TARGET_BUILD="jvm"
# Load driver / transport overrides forwarded to the base runner. Empty = the
# base runner's defaults (wrk, H1). The constrained run stays exploratory, so the
# exploratory-only h2load h2c axis is permitted here. TLS is orthogonal and rides
# in via BENCHMARK_TLS_ENABLED / EXERIS_SSL_* in the environment (preserved across
# the systemd-run relaunch below).
DRIVER_OVERRIDE="${DRIVER_OVERRIDE:-}"
H2LOAD_AXIS_OVERRIDE="${H2LOAD_AXIS_OVERRIDE:-}"
BACKEND_MODE_OVERRIDE="${BACKEND_MODE_OVERRIDE:-}"
# Operator JVM-overlay overrides. The cgroup fixes the hard memory ceiling, but the
# profile-derived GC (serial) + heap can be too tight for some targets (e.g. Quarkus
# won't survive serial GC at the auto-derived -Xmx). These win over the profile's
# jvm.* values; empty = keep the profile/auto-derived overlay. -Xmx/-Xms in MB.
JVM_GC_OVERRIDE_CLI="${JVM_GC_OVERRIDE_CLI:-}"
JVM_XMS_MB_CLI="${JVM_XMS_MB_CLI:-}"
JVM_XMX_MB_CLI="${JVM_XMX_MB_CLI:-}"
CPU_AFFINITY="${CPU_AFFINITY:-}"
ENABLE_JFR="${BENCHMARK_ENABLE_JFR:-false}"
JFR_SETTINGS="${BENCHMARK_JFR_SETTINGS:-profile}"
BENCHMARK_SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-1}"
UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_NAMESPACE="results/constrained/entity-read-by-id/${UTC_STAMP}-constrained-smoke"
OUTPUT_DIR="${REPO_ROOT}/${RESULT_NAMESPACE}"

usage() {
  cat <<EOF
Usage: scripts/run-entity-read-by-id-constrained.sh [--execution-profile-id ID] [--contract-id ID] [--target-runtime <community|locality|spring|spring-runtime-on-exeris|quarkus|quarkus-tuned>] [--target-build <jvm|native>] [--cpu-affinity <cpuset>] [--output-dir PATH]

Defaults:
  --execution-profile-id runtime-constrained-256m-1vcpu-v1
  --contract-id fixed_contract_runtime_h1_constrained_smoke_256m_1vcpu_v1
  --profiles-json <path>   override runtime-execution-profiles.json (default: runtime/profiles/runtime-execution-profiles.json)
  --scenario-json <path>   override the scenario contract file (default: scenarios/entity-read-by-id/scenario.json)
  --target-runtime <community|locality|spring|spring-runtime-on-exeris|quarkus|quarkus-tuned> (default: community)
  --target-build <jvm|native> (default: jvm)
  --driver <wrk|wrk2|h2load>   load driver forwarded to the base runner (default: base runner default = wrk H1)
  --h2load-axis <h1|h2c>       h2load transport axis (h2c = HTTP/2; with TLS => h2-over-TLS). Only meaningful with --driver h2load
  --backend-mode <mode>        backend mode forwarded to the base runner (e.g. default-vt)
  --jvm-gc <serial|g1|parallel|z|shenandoah>  override the profile GC (default: profile's, = serial). Non-serial needs more cgroup headroom
  --jvm-xms-mb <int>           override -Xms (MB); wins over the profile/auto-derived value
  --jvm-xmx-mb <int>           override -Xmx (MB); wins over the profile/auto-derived value. Keep well below the cgroup ceiling
  --cpu-affinity <cpuset>  pin the target app to this cpuset via taskset (e.g. 0-1); empty = no pin
  --enable-jfr             record a JFR of the target during measurement (default off)
  --jfr-settings <name>    JFR settings preset (default: profile)
  --output-dir <repo>/results/constrained/entity-read-by-id/<utc-timestamp>-constrained-smoke
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execution-profile-id)
      EXECUTION_PROFILE_ID="$2"
      shift 2
      ;;
    --contract-id)
      CONTRACT_ID="$2"
      shift 2
      ;;
    --profiles-json)
      PROFILES_JSON="$2"
      shift 2
      ;;
    --scenario-json)
      SCENARIO_JSON="$2"
      shift 2
      ;;
    --driver)
      DRIVER_OVERRIDE="$2"
      shift 2
      ;;
    --h2load-axis)
      H2LOAD_AXIS_OVERRIDE="$2"
      shift 2
      ;;
    --backend-mode)
      BACKEND_MODE_OVERRIDE="$2"
      shift 2
      ;;
    --jvm-gc)
      JVM_GC_OVERRIDE_CLI="$2"
      shift 2
      ;;
    --jvm-xms-mb)
      JVM_XMS_MB_CLI="$2"
      shift 2
      ;;
    --jvm-xmx-mb)
      JVM_XMX_MB_CLI="$2"
      shift 2
      ;;
    --target-runtime)
      TARGET_RUNTIME="$2"
      shift 2
      ;;
    --target-build)
      TARGET_BUILD="$2"
      shift 2
      ;;
    --cpu-affinity)
      CPU_AFFINITY="$2"
      shift 2
      ;;
    --enable-jfr)
      ENABLE_JFR="true"
      shift
      ;;
    --no-jfr)
      ENABLE_JFR="false"
      shift
      ;;
    --jfr-settings)
      JFR_SETTINGS="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      RESULT_NAMESPACE="${OUTPUT_DIR#${REPO_ROOT}/}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Mirror the base runner's accepted set: the constrained runner passes
# --target-runtime straight through to run-entity-read-by-id.sh, which resolves
# quarkus-tuned (and its legacy aliases). Constrained runs are exploratory /
# descriptive_only, so a target's comparative-pair eligibility is irrelevant here —
# anything the base runner can launch is fair game for a constrained smoke.
case "$TARGET_RUNTIME" in
  community|locality|spring|spring-runtime-on-exeris|quarkus|quarkus-tuned|quarkus-jdbc|quarkus-jdbc-jsse)
    ;;
  *)
    echo "ERROR: Invalid --target-runtime '$TARGET_RUNTIME' (allowed: community|locality|spring|spring-runtime-on-exeris|quarkus|quarkus-tuned; legacy: quarkus-jdbc, quarkus-jdbc-jsse)" >&2
    exit 1
    ;;
esac

case "$TARGET_BUILD" in
  jvm|native)
    ;;
  *)
    echo "ERROR: Invalid --target-build '$TARGET_BUILD' (allowed: jvm|native)" >&2
    exit 1
    ;;
esac

case "$DRIVER_OVERRIDE" in
  ""|wrk|wrk2|h2load)
    ;;
  *)
    echo "ERROR: Invalid --driver '$DRIVER_OVERRIDE' (allowed: wrk|wrk2|h2load)" >&2
    exit 1
    ;;
esac

case "$H2LOAD_AXIS_OVERRIDE" in
  ""|h1|h2c)
    ;;
  *)
    echo "ERROR: Invalid --h2load-axis '$H2LOAD_AXIS_OVERRIDE' (allowed: h1|h2c)" >&2
    exit 1
    ;;
esac

case "$JVM_GC_OVERRIDE_CLI" in
  ""|serial|g1|parallel|z|shenandoah)
    ;;
  *)
    echo "ERROR: Invalid --jvm-gc '$JVM_GC_OVERRIDE_CLI' (allowed: serial|g1|parallel|z|shenandoah)" >&2
    exit 1
    ;;
esac

if [[ -n "$JVM_XMS_MB_CLI" ]] && ! [[ "$JVM_XMS_MB_CLI" =~ ^[0-9]+$ && "$JVM_XMS_MB_CLI" -ge 1 ]]; then
  echo "ERROR: --jvm-xms-mb must be a positive integer (MB), got: '$JVM_XMS_MB_CLI'" >&2
  exit 1
fi
if [[ -n "$JVM_XMX_MB_CLI" ]] && ! [[ "$JVM_XMX_MB_CLI" =~ ^[0-9]+$ && "$JVM_XMX_MB_CLI" -ge 1 ]]; then
  echo "ERROR: --jvm-xmx-mb must be a positive integer (MB), got: '$JVM_XMX_MB_CLI'" >&2
  exit 1
fi

if [[ "$BENCHMARK_SKIP_TARGET_BUILD" != "0" && "$BENCHMARK_SKIP_TARGET_BUILD" != "1" ]]; then
  echo "ERROR: BENCHMARK_SKIP_TARGET_BUILD must be 0 or 1 (got: $BENCHMARK_SKIP_TARGET_BUILD)" >&2
  exit 1
fi

if [[ ! -f "$SCENARIO_JSON" ]]; then
  echo "ERROR: Missing scenario contract file: $SCENARIO_JSON" >&2
  exit 1
fi
if [[ ! -f "$PROFILES_JSON" ]]; then
  echo "ERROR: Missing runtime execution profile file: $PROFILES_JSON" >&2
  exit 1
fi
if [[ ! -x "$BASE_RUNNER" ]]; then
  echo "ERROR: Missing executable base runner: $BASE_RUNNER" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

CG_MEMORY_MAX_RAW="unknown"
CG_CPU_MAX_RAW="unknown"
CG_MEMORY_MAX_BYTES="unknown"
CG_CPU_QUOTA_US="unknown"
CG_CPU_PERIOD_US="unknown"
CGROUP_DIR="unknown"

config_error() {
  local msg="$1"
  echo "CONFIG_ERROR: $msg" >&2
  echo "output_dir=$OUTPUT_DIR"
  echo "cgroup_path=${CGROUP_DIR}"
  echo "cgroup_memory_max_bytes=${CG_MEMORY_MAX_BYTES} cgroup_cpu_quota_us=${CG_CPU_QUOTA_US} cgroup_cpu_period_us=${CG_CPU_PERIOD_US}"
  echo "outcome=limit_mismatch rc=64"
  exit 64
}

ensure_constrained_scope() {
  local reason="$1"

  if [[ "${BENCHMARK_CONSTRAINED_SCOPE_ACTIVE:-0}" == "1" ]]; then
    config_error "$reason"
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then
    config_error "${reason}; systemd-run unavailable for auto-enforcement"
  fi

  local cpu_quota_pct
  cpu_quota_pct="$(awk -v v="$VCPU" 'BEGIN { printf "%.0f", v * 100 }')"

  echo "[info] ${reason}"
  echo "[info] Relaunching constrained run in user scope with MemoryMax=${LIMIT_MB}M CPUQuota=${cpu_quota_pct}%"

  local relaunch_args=(
    --execution-profile-id "$EXECUTION_PROFILE_ID"
    --contract-id "$CONTRACT_ID"
    --profiles-json "$PROFILES_JSON"
    --scenario-json "$SCENARIO_JSON"
    --target-runtime "$TARGET_RUNTIME"
    --target-build "$TARGET_BUILD"
    --output-dir "$OUTPUT_DIR"
  )
  [[ -n "$DRIVER_OVERRIDE" ]]       && relaunch_args+=(--driver "$DRIVER_OVERRIDE")
  [[ -n "$H2LOAD_AXIS_OVERRIDE" ]]  && relaunch_args+=(--h2load-axis "$H2LOAD_AXIS_OVERRIDE")
  [[ -n "$BACKEND_MODE_OVERRIDE" ]] && relaunch_args+=(--backend-mode "$BACKEND_MODE_OVERRIDE")
  [[ -n "$JVM_GC_OVERRIDE_CLI" ]]   && relaunch_args+=(--jvm-gc "$JVM_GC_OVERRIDE_CLI")
  [[ -n "$JVM_XMS_MB_CLI" ]]        && relaunch_args+=(--jvm-xms-mb "$JVM_XMS_MB_CLI")
  [[ -n "$JVM_XMX_MB_CLI" ]]        && relaunch_args+=(--jvm-xmx-mb "$JVM_XMX_MB_CLI")
  if [[ -n "$CPU_AFFINITY" ]]; then
    relaunch_args+=(--cpu-affinity "$CPU_AFFINITY")
  fi
  if [[ "$ENABLE_JFR" == "true" ]]; then
    relaunch_args+=(--enable-jfr --jfr-settings "$JFR_SETTINGS")
  fi

  # systemd-run --scope forks the command from systemd-run, so most of the caller's
  # environment is inherited — but make the transport-defining vars EXPLICIT so a
  # TLS / protocol-override run never silently degrades to cleartext H1 after the
  # relaunch. Only forward those that are actually set (an empty `env VAR=` would
  # override an inherited value with empty). The base runner reads BENCHMARK_TLS_ENABLED
  # (client scheme + target TLS launch), EXERIS_SSL_ENABLED + cert/key paths (target
  # TLS launch), and BENCH_PROTOCOL_MODE_OVERRIDE (protocol lib).
  local env_passthrough=(
    BENCHMARK_CONSTRAINED_SCOPE_ACTIVE=1
    BENCHMARK_SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD}"
    BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE="${CONSTRAINED_DB_POOL_MIN_SIZE}"
    BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE="${CONSTRAINED_DB_POOL_MAX_SIZE}"
    BENCHMARK_CONSTRAINED_DB_CONNECTION_TIMEOUT_MS="${CONSTRAINED_DB_CONNECTION_TIMEOUT_MS}"
    ENTITY_READ_ENDPOINT_PATH="${ENTITY_READ_ENDPOINT_PATH}"
  )
  # These vars are all fairness-defining and must survive the systemd-run relaunch:
  #  - DB_HOST_NETWORK / BENCH_BACKEND_NETWORK / BENCH_DB_TUNED: backend container
  #    network mode is a comparison fairness gate (docs/methodology.md) so a host-net
  #    Postgres choice can never silently degrade to bridge/NAT.
  #  - EXERIS_SUBSYSTEMS: subsystem selection (e.g. dropping the unused crypto
  #    subsystem in a plaintext sweep) is a footprint/fairness control; it must not
  #    revert to the http,persistence,crypto default after relaunch.
  #  - EXERIS_ENABLE_TELEMETRY_SUBSYSTEM / EXERIS_TELEMETRY_JFR_ENABLED: Exeris-only
  #    overhead toggles; an explicit =false must not be inherited-on.
  # Forwarded only-if-set, so runtimes/arms that don't set them are unaffected.
  local v
  for v in BENCHMARK_TLS_ENABLED EXERIS_SSL_ENABLED EXERIS_TRANSPORT_CERT_PATH \
           EXERIS_TRANSPORT_KEY_PATH BENCH_PROTOCOL_MODE_OVERRIDE \
           DB_HOST_NETWORK BENCH_BACKEND_NETWORK BENCH_DB_TUNED \
           EXERIS_SUBSYSTEMS EXERIS_ENABLE_TELEMETRY_SUBSYSTEM EXERIS_TELEMETRY_JFR_ENABLED; do
    [[ -n "${!v:-}" ]] && env_passthrough+=("${v}=${!v}")
  done

  exec systemd-run --user --scope \
    -p "MemoryMax=${LIMIT_MB}M" \
    -p "MemorySwapMax=0" \
    -p "CPUQuota=${cpu_quota_pct}%" \
    env \
      "${env_passthrough[@]}" \
      "$0" \
      "${relaunch_args[@]}"
}

CONTRACT_JSON="$(jq -ce --arg id "$CONTRACT_ID" '.fixed_contracts[$id] // empty' "$SCENARIO_JSON")" \
  || { echo "ERROR: Contract '$CONTRACT_ID' not found in scenario file" >&2; exit 1; }

CONTRACT_EXECUTION_PROFILE_ID="$(jq -r '.execution_profile_id // empty' <<<"$CONTRACT_JSON")"
if [[ -z "$CONTRACT_EXECUTION_PROFILE_ID" ]]; then
  echo "ERROR: Contract '$CONTRACT_ID' is missing execution_profile_id" >&2
  exit 1
fi
if [[ "$CONTRACT_EXECUTION_PROFILE_ID" != "$EXECUTION_PROFILE_ID" ]]; then
  echo "ERROR: Contract '$CONTRACT_ID' execution_profile_id='$CONTRACT_EXECUTION_PROFILE_ID' does not match selected profile '$EXECUTION_PROFILE_ID'" >&2
  exit 1
fi

THREADS="$(jq -r '.threads' <<<"$CONTRACT_JSON")"
CONNECTIONS="$(jq -r '.connections' <<<"$CONTRACT_JSON")"
WARMUP_SECONDS="$(jq -r '.warmup_seconds' <<<"$CONTRACT_JSON")"
DURATION_SECONDS="$(jq -r '.duration_seconds' <<<"$CONTRACT_JSON")"
# Request path the base runner should drive. Derived from the contract's "GET /path"
# endpoint (last whitespace field, mirroring run-comparative.sh's
# extract_endpoint_path_from_method_endpoint), defaulting to the aggregate read so
# every pre-existing constrained contract (endpoint "GET /api/v1/users") is byte-for-
# byte unchanged. The single-read matrix contracts carry "GET /api/v1/user?id=1", so
# without this forward the base runner would silently measure the aggregate under a
# single-read label. Exported (inherited by the base runner) and passed through the
# systemd-run relaunch below.
CONTRACT_ENDPOINT="$(jq -r '.endpoint // empty' <<<"$CONTRACT_JSON")"
if [[ -n "$CONTRACT_ENDPOINT" ]]; then
  ENTITY_READ_ENDPOINT_PATH="$(awk '{print $NF}' <<<"$CONTRACT_ENDPOINT")"
else
  ENTITY_READ_ENDPOINT_PATH="/api/v1/users"
fi
case "$ENTITY_READ_ENDPOINT_PATH" in
  /*) ;;
  *)
    echo "ERROR: Contract '$CONTRACT_ID' endpoint '$CONTRACT_ENDPOINT' did not yield an absolute request path (got: '$ENTITY_READ_ENDPOINT_PATH')" >&2
    exit 1
    ;;
esac
export ENTITY_READ_ENDPOINT_PATH
# Size the pool to the contract's offered concurrency. Do NOT defer to an ambient
# EXERIS_DB_POOL_* (a sourced runtime env file, e.g. exeris-community-runtime.env,
# sets EXERIS_DB_POOL_MAX_SIZE=256): inheriting 256 into a 128M/0.5vCPU cgroup
# overwhelms connection establishment. But a too-SMALL pool is just as fatal: with
# max=8 and the contract offering 16 client connections, half the in-flight reads
# can never acquire a connection and the run drowns in connectionExhausted. So the
# floor is the contract's `connections` (every concurrent request gets one
# connection, no queuing). Pair this with a generous connection-acquisition timeout
# (below) so transient queuing under CPU throttling does not fail-fast.
CONSTRAINED_DB_POOL_MIN_SIZE="${BENCHMARK_CONSTRAINED_DB_POOL_MIN_SIZE:-2}"
if [[ "$CONNECTIONS" =~ ^[0-9]+$ ]] && (( CONNECTIONS >= 1 )); then
  CONSTRAINED_DB_POOL_MAX_DEFAULT="$CONNECTIONS"
else
  CONSTRAINED_DB_POOL_MAX_DEFAULT=16
fi
CONSTRAINED_DB_POOL_MAX_SIZE="${BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE:-$CONSTRAINED_DB_POOL_MAX_DEFAULT}"
# Connection-acquisition timeout (ms). The kernel's constrained fail-fast (~250ms)
# trips on any momentary queuing under 0.5 vCPU; give it real headroom.
CONSTRAINED_DB_CONNECTION_TIMEOUT_MS="${BENCHMARK_CONSTRAINED_DB_CONNECTION_TIMEOUT_MS:-5000}"
if [[ -n "${EXERIS_DB_POOL_MAX_SIZE:-}" && "${EXERIS_DB_POOL_MAX_SIZE}" != "$CONSTRAINED_DB_POOL_MAX_SIZE" ]]; then
  echo "[info] Ignoring ambient EXERIS_DB_POOL_MAX_SIZE=${EXERIS_DB_POOL_MAX_SIZE}; constrained smoke forces max=${CONSTRAINED_DB_POOL_MAX_SIZE} (=contract connections; override with BENCHMARK_CONSTRAINED_DB_POOL_MAX_SIZE)"
fi
if (( CONSTRAINED_DB_POOL_MAX_SIZE < CONNECTIONS )); then
  echo "[warn] Constrained DB pool max=${CONSTRAINED_DB_POOL_MAX_SIZE} is below the contract's connections=${CONNECTIONS}; expect connectionExhausted under load."
fi

if ! [[ "$CONSTRAINED_DB_POOL_MIN_SIZE" =~ ^[0-9]+$ && "$CONSTRAINED_DB_POOL_MAX_SIZE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: constrained DB pool sizes must be numeric" >&2
  exit 1
fi
if ! [[ "$CONSTRAINED_DB_CONNECTION_TIMEOUT_MS" =~ ^[0-9]+$ ]] || (( CONSTRAINED_DB_CONNECTION_TIMEOUT_MS < 1 )); then
  echo "ERROR: constrained DB connection timeout must be a positive integer (ms)" >&2
  exit 1
fi
if (( CONSTRAINED_DB_POOL_MIN_SIZE < 1 )); then
  CONSTRAINED_DB_POOL_MIN_SIZE=1
fi
if (( CONSTRAINED_DB_POOL_MAX_SIZE < CONSTRAINED_DB_POOL_MIN_SIZE )); then
  CONSTRAINED_DB_POOL_MAX_SIZE="$CONSTRAINED_DB_POOL_MIN_SIZE"
fi

PROFILE_JSON="$(jq -ce --arg id "$EXECUTION_PROFILE_ID" '.profiles[] | select(.execution_profile_id == $id)' "$PROFILES_JSON")" \
  || { echo "ERROR: Execution profile '$EXECUTION_PROFILE_ID' not found" >&2; exit 1; }

LIMIT_MB="$(jq -r '.memory_limit.limit_mb // empty' <<<"$PROFILE_JSON")"
VCPU="$(jq -r '.cpu_limit.vcpu // empty' <<<"$PROFILE_JSON")"
REQUIRED_TRACK_ID="$(jq -r '.required_track_id // empty' <<<"$PROFILE_JSON")"
JVM_GC="$(jq -r '.jvm.gc // empty' <<<"$PROFILE_JSON")"
JVM_ACTIVE_PROCESSOR_COUNT="$(jq -r '.jvm.active_processor_count // empty' <<<"$PROFILE_JSON")"
JVM_MAX_RAM_MB="$(jq -r '.jvm.max_ram_mb // empty' <<<"$PROFILE_JSON")"
# Optional min-footprint overlay (e.g. the 128MB profile): C1-only JIT plus
# capped code-cache/metaspace/heap so the JVM fits below a tight cgroup ceiling.
# Absent on roomier profiles, which keep the default tiered-JIT heap ergonomics.
JVM_TIERED_STOP_AT_LEVEL="$(jq -r '.jvm.tiered_stop_at_level // empty' <<<"$PROFILE_JSON")"
JVM_RESERVED_CODE_CACHE_MB="$(jq -r '.jvm.reserved_code_cache_mb // empty' <<<"$PROFILE_JSON")"
JVM_MAX_METASPACE_MB="$(jq -r '.jvm.max_metaspace_mb // empty' <<<"$PROFILE_JSON")"
JVM_XMS_MB_OVERRIDE="$(jq -r '.jvm.xms_mb // empty' <<<"$PROFILE_JSON")"
JVM_XMX_MB_OVERRIDE="$(jq -r '.jvm.xmx_mb // empty' <<<"$PROFILE_JSON")"
JIT_REPRESENTATIVENESS="$(jq -r '.jit_representativeness // "representative"' <<<"$PROFILE_JSON")"

# Operator GC override wins over the profile's gc. Applied before the required-field
# check so it can stand in for a (hypothetically) gc-less profile too.
if [[ -n "$JVM_GC_OVERRIDE_CLI" ]]; then
  [[ -n "$JVM_GC" && "$JVM_GC" != "$JVM_GC_OVERRIDE_CLI" ]] \
    && echo "[info] Overriding profile GC '${JVM_GC}' with operator-chosen '${JVM_GC_OVERRIDE_CLI}'"
  JVM_GC="$JVM_GC_OVERRIDE_CLI"
fi

if [[ -z "$LIMIT_MB" || -z "$VCPU" || -z "$REQUIRED_TRACK_ID" || -z "$JVM_GC" || -z "$JVM_ACTIVE_PROCESSOR_COUNT" || -z "$JVM_MAX_RAM_MB" ]]; then
  echo "ERROR: Execution profile '$EXECUTION_PROFILE_ID' is missing required constrained fields" >&2
  exit 1
fi

CGROUP_ROOT="/sys/fs/cgroup"
if [[ ! -f "${CGROUP_ROOT}/cgroup.controllers" ]]; then
  config_error "cgroup v2 is required: missing ${CGROUP_ROOT}/cgroup.controllers"
fi
CGROUP_REL_PATH="$(awk -F: '$1=="0" { print $3; exit }' /proc/self/cgroup 2>/dev/null || true)"
if [[ -z "$CGROUP_REL_PATH" || "$CGROUP_REL_PATH" == "/" ]]; then
  CGROUP_DIR="$CGROUP_ROOT"
else
  CGROUP_DIR="${CGROUP_ROOT}${CGROUP_REL_PATH}"
fi

if [[ ! -f "${CGROUP_DIR}/memory.max" || ! -f "${CGROUP_DIR}/cpu.max" ]]; then
  ensure_constrained_scope "cgroup v2 required files memory.max and cpu.max are missing"
fi

CG_MEMORY_MAX_RAW="$(<"${CGROUP_DIR}/memory.max")"
if [[ "$CG_MEMORY_MAX_RAW" == "max" ]]; then
  ensure_constrained_scope "memory.max is unlimited; expected finite cap <= ${LIMIT_MB}MB"
fi
if ! [[ "$CG_MEMORY_MAX_RAW" =~ ^[0-9]+$ ]]; then
  config_error "memory.max has non-numeric value '$CG_MEMORY_MAX_RAW'"
fi
CG_MEMORY_MAX_BYTES="$CG_MEMORY_MAX_RAW"
REQUIRED_MEMORY_MAX_BYTES="$((LIMIT_MB * 1024 * 1024))"
if (( CG_MEMORY_MAX_BYTES > REQUIRED_MEMORY_MAX_BYTES )); then
  ensure_constrained_scope "memory.max=${CG_MEMORY_MAX_BYTES} exceeds profile limit ${REQUIRED_MEMORY_MAX_BYTES}"
fi

CG_CPU_MAX_RAW="$(<"${CGROUP_DIR}/cpu.max")"
read -r CG_CPU_QUOTA_US CG_CPU_PERIOD_US <<<"$CG_CPU_MAX_RAW"
if [[ -z "${CG_CPU_QUOTA_US:-}" || -z "${CG_CPU_PERIOD_US:-}" ]]; then
  config_error "cpu.max has unexpected format '$CG_CPU_MAX_RAW'"
fi
if [[ "$CG_CPU_QUOTA_US" == "max" ]]; then
  ensure_constrained_scope "cpu.max is unlimited; expected finite quota/period <= ${VCPU}"
fi
if ! [[ "$CG_CPU_QUOTA_US" =~ ^[0-9]+$ && "$CG_CPU_PERIOD_US" =~ ^[0-9]+$ ]]; then
  config_error "cpu.max values must be numeric, got '$CG_CPU_MAX_RAW'"
fi

CG_EFFECTIVE_VCPU="$(LC_ALL=C awk -v q="$CG_CPU_QUOTA_US" -v p="$CG_CPU_PERIOD_US" 'BEGIN { if (p == 0) { print "nan" } else { printf "%.6f", q/p } }')"
if [[ "$CG_EFFECTIVE_VCPU" == "nan" ]]; then
  config_error "cpu.max period is zero"
fi
CPU_OVER_LIMIT="$(LC_ALL=C awk -v q="$CG_CPU_QUOTA_US" -v p="$CG_CPU_PERIOD_US" -v expected="$VCPU" 'BEGIN { if (p == 0) { print 1 } else { print ((q / p) > (expected + 1e-9)) ? 1 : 0 } }')"
if [[ "$CPU_OVER_LIMIT" == "1" ]]; then
  ensure_constrained_scope "cpu quota/period=${CG_EFFECTIVE_VCPU} exceeds profile vcpu=${VCPU}"
fi

JVM_OVERLAY_FLAGS=()
case "$JVM_GC" in
  serial)     JVM_OVERLAY_FLAGS+=("-XX:+UseSerialGC") ;;
  g1)         JVM_OVERLAY_FLAGS+=("-XX:+UseG1GC") ;;
  parallel)   JVM_OVERLAY_FLAGS+=("-XX:+UseParallelGC") ;;
  z)          JVM_OVERLAY_FLAGS+=("-XX:+UseZGC") ;;
  shenandoah) JVM_OVERLAY_FLAGS+=("-XX:+UseShenandoahGC") ;;
  *)
    echo "ERROR: Unsupported constrained JVM gc value '$JVM_GC' (allowed: serial|g1|parallel|z|shenandoah)" >&2
    exit 1
    ;;
esac
# serial is the smallest-footprint collector; the others trade native/heap headroom
# for throughput and can OOM a tight cgroup. Surfacing this keeps a tuned run honest.
if [[ "$JVM_GC" != "serial" ]]; then
  echo "[info] Non-serial GC '${JVM_GC}' under a ${LIMIT_MB}MB cgroup: needs more native/heap headroom than serial — if it OOM-kills, lower -Xmx or revert to serial."
fi

JVM_XMS_MB="$(awk -v max_ram="$JVM_MAX_RAM_MB" 'BEGIN {
  x = int(max_ram / 4)
  if (x < 64) x = 64
  if (x > max_ram - 32) x = max_ram - 32
  if (x < 32) x = 32
  print x
}')"
JVM_XMX_MB="$(awk -v max_ram="$JVM_MAX_RAM_MB" 'BEGIN {
  x = int((max_ram * 3) / 4)
  if (x < 96) x = 96
  if (x >= max_ram) x = max_ram - 16
  if (x < 64) x = 64
  print x
}')"
# Explicit heap overrides win over the max_ram-derived ergonomics. The 128MB
# profile pins a 64MB heap so heap + non-heap (metaspace/code-cache/stacks)
# stays under the cgroup ceiling instead of being OOM-killed mid-warmup.
if [[ -n "$JVM_XMX_MB_OVERRIDE" ]]; then
  JVM_XMX_MB="$JVM_XMX_MB_OVERRIDE"
fi
if [[ -n "$JVM_XMS_MB_OVERRIDE" ]]; then
  JVM_XMS_MB="$JVM_XMS_MB_OVERRIDE"
fi
# Operator CLI heap overrides win over both the derived ergonomics and the profile's
# jvm.xms_mb/xmx_mb. This is the escape hatch for targets the auto-derived heap can't
# keep alive under the cgroup ceiling.
[[ -n "$JVM_XMX_MB_CLI" ]] && JVM_XMX_MB="$JVM_XMX_MB_CLI"
[[ -n "$JVM_XMS_MB_CLI" ]] && JVM_XMS_MB="$JVM_XMS_MB_CLI"
if (( JVM_XMS_MB > JVM_XMX_MB )); then
  JVM_XMS_MB="$JVM_XMX_MB"
fi
# Heap alone at/above the cgroup ceiling leaves nothing for non-heap (metaspace, code
# cache, thread stacks, native/off-heap) and will OOM-kill on startup — warn loudly.
if (( JVM_XMX_MB >= LIMIT_MB )); then
  echo "[warn] -Xmx${JVM_XMX_MB}m is >= the ${LIMIT_MB}MB cgroup ceiling: no room for non-heap memory; the JVM will almost certainly be OOM-killed. Lower -Xmx well below ${LIMIT_MB}MB."
fi

JVM_OVERLAY_FLAGS+=("-XX:ActiveProcessorCount=${JVM_ACTIVE_PROCESSOR_COUNT}")
JVM_OVERLAY_FLAGS+=("-XX:MaxRAM=${JVM_MAX_RAM_MB}m")
JVM_OVERLAY_FLAGS+=("-Xms${JVM_XMS_MB}m")
JVM_OVERLAY_FLAGS+=("-Xmx${JVM_XMX_MB}m")
# Min-footprint caps (optional, profile-driven). TieredStopAtLevel=1 disables the
# C2 compiler whose arena allocation OOM-kills the target at 128MB; the code-cache
# and metaspace caps bound the largest non-heap consumers. These make throughput
# non-perf-representative (see jit_representativeness), which is recorded in the
# evidence artifact and the run README.
if [[ -n "$JVM_TIERED_STOP_AT_LEVEL" ]]; then
  JVM_OVERLAY_FLAGS+=("-XX:TieredStopAtLevel=${JVM_TIERED_STOP_AT_LEVEL}")
fi
if [[ -n "$JVM_RESERVED_CODE_CACHE_MB" ]]; then
  JVM_OVERLAY_FLAGS+=("-XX:ReservedCodeCacheSize=${JVM_RESERVED_CODE_CACHE_MB}m")
fi
if [[ -n "$JVM_MAX_METASPACE_MB" ]]; then
  JVM_OVERLAY_FLAGS+=("-XX:MaxMetaspaceSize=${JVM_MAX_METASPACE_MB}m")
fi

OVERLAY_JOINED="${JVM_OVERLAY_FLAGS[*]}"
if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
  export JAVA_TOOL_OPTIONS="${OVERLAY_JOINED} ${JAVA_TOOL_OPTIONS}"
else
  export JAVA_TOOL_OPTIONS="${OVERLAY_JOINED}"
fi

export BENCHMARK_EXECUTION_PROFILE_ID="$EXECUTION_PROFILE_ID"
export BENCHMARK_TRACK_ID="track-c"
export BENCHMARK_SKIP_TARGET_BUILD
export EXERIS_DB_POOL_MIN_SIZE="$CONSTRAINED_DB_POOL_MIN_SIZE"
export EXERIS_DB_POOL_MAX_SIZE="$CONSTRAINED_DB_POOL_MAX_SIZE"
export EXERIS_DB_CONNECTION_TIMEOUT_MS="$CONSTRAINED_DB_CONNECTION_TIMEOUT_MS"

if [[ "$BENCHMARK_SKIP_TARGET_BUILD" == "1" ]]; then
  echo "[info] BENCHMARK_SKIP_TARGET_BUILD=1 active: constrained mode will use prebuilt target artifacts only"
fi

echo "[info] Constrained DB pool sizing: min=${EXERIS_DB_POOL_MIN_SIZE} max=${EXERIS_DB_POOL_MAX_SIZE} (contract connections=${CONNECTIONS}) connection_timeout_ms=${EXERIS_DB_CONNECTION_TIMEOUT_MS}"
if [[ "$JIT_REPRESENTATIVENESS" != "representative" ]]; then
  echo "[warn] Profile '${EXECUTION_PROFILE_ID}' runs a min-footprint JVM (jit_representativeness=${JIT_REPRESENTATIVENESS}): ${JVM_OVERLAY_FLAGS[*]}"
  echo "[warn] This is a 'does it fit in ${LIMIT_MB}MB and stay up' probe only — throughput is NOT comparable to full-tier (C2) runs. Do not use for cross-target throughput claims."
fi

LAUNCH_COMMAND=(
  "./scripts/run-entity-read-by-id.sh"
  "--claim-scope" "exploratory"
  "--profile" "dev-laptop"
  "--output-dir" "$OUTPUT_DIR"
  "--target-runtime" "$TARGET_RUNTIME"
  "--target-build" "$TARGET_BUILD"
  "--threads" "$THREADS"
  "--connections" "$CONNECTIONS"
  "--warmup" "${WARMUP_SECONDS}s"
  "--duration" "${DURATION_SECONDS}s"
)
# Forward the operator-chosen load driver / transport. The base runner derives the
# wire protocol from --driver (+ --h2load-axis) and TLS from BENCHMARK_TLS_ENABLED;
# without these the constrained run silently defaults to wrk H1 cleartext.
[[ -n "$DRIVER_OVERRIDE" ]]       && LAUNCH_COMMAND+=("--driver" "$DRIVER_OVERRIDE")
[[ -n "$H2LOAD_AXIS_OVERRIDE" ]]  && LAUNCH_COMMAND+=("--h2load-axis" "$H2LOAD_AXIS_OVERRIDE")
[[ -n "$BACKEND_MODE_OVERRIDE" ]] && LAUNCH_COMMAND+=("--backend-mode" "$BACKEND_MODE_OVERRIDE")
if [[ -n "$CPU_AFFINITY" ]]; then
  # Base runner pins the target app to this cpuset via taskset (server-side pin,
  # orthogonal to the scope CPUQuota).
  LAUNCH_COMMAND+=("--cpu-affinity" "$CPU_AFFINITY")
fi
if [[ "$ENABLE_JFR" == "true" ]]; then
  LAUNCH_COMMAND+=("--enable-jfr" "--jfr-settings" "$JFR_SETTINGS")
fi

# Authoritative cgroup OOM signal. memory.events carries a monotonic oom_kill counter
# the kernel bumps when it SIGKILLs a process in this scope — the JVM gets no chance to
# log anything, so the old grep for 'OutOfMemoryError|Killed' missed every hard cgroup
# kill. Snapshot before the run and diff after: a positive delta is proof the OOM-killer
# fired here, independent of exit code or log strings.
MEM_EVENTS_FILE="${CGROUP_DIR}/memory.events"
read_mem_event() { # $1 = key; prints the counter, or 0 if absent/non-numeric
  local v
  v="$(awk -v k="$1" '$1==k {print $2; exit}' "$MEM_EVENTS_FILE" 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'
}
OOM_KILL_BEFORE="$(read_mem_event oom_kill)"
OOM_BEFORE="$(read_mem_event oom)"
OOM_GROUP_KILL_BEFORE="$(read_mem_event oom_group_kill)"
MAX_EVENT_BEFORE="$(read_mem_event max)"

# Marker for scoping crash-artifact (hs_err/replay/core) and dmesg scans to THIS run only.
RUN_START_MARKER="$(mktemp)"
RUN_START_EPOCH="$(date +%s)"

set +e
(
  cd "$REPO_ROOT"
  "${LAUNCH_COMMAND[@]}"
)
BENCHMARK_RC=$?
set -e

mem_event_delta() { # $1 after, $2 before -> max(after-before, 0)
  local a="$1" b="$2"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || { printf '0'; return; }
  (( a > b )) && printf '%s' "$(( a - b ))" || printf '0'
}
OOM_KILL_DELTA="$(mem_event_delta "$(read_mem_event oom_kill)" "$OOM_KILL_BEFORE")"
OOM_DELTA="$(mem_event_delta "$(read_mem_event oom)" "$OOM_BEFORE")"
OOM_GROUP_KILL_DELTA="$(mem_event_delta "$(read_mem_event oom_group_kill)" "$OOM_GROUP_KILL_BEFORE")"
MAX_EVENT_DELTA="$(mem_event_delta "$(read_mem_event max)" "$MAX_EVENT_BEFORE")"

# Phase attribution. The inner runner overwrites phase.state at each productive phase
# boundary (setup -> launch -> readiness -> warmup -> measure -> measure_complete); the
# file survives a SIGKILL, so its last value is the furthest phase reached. teardown.state
# records whether the target was still alive when cleanup began.
PHASE_REACHED="unknown"
if [[ -f "${OUTPUT_DIR}/phase.state" ]]; then
  PHASE_REACHED="$(awk '{print $1; exit}' "${OUTPUT_DIR}/phase.state" 2>/dev/null || echo unknown)"
  [[ -n "$PHASE_REACHED" ]] || PHASE_REACHED="unknown"
fi
TARGET_ALIVE_AT_TEARDOWN="unknown"
if [[ -f "${OUTPUT_DIR}/teardown.state" ]]; then
  TARGET_ALIVE_AT_TEARDOWN="$(awk -F'[= ]' '/target_alive_at_teardown/{print $2; exit}' "${OUTPUT_DIR}/teardown.state" 2>/dev/null || echo unknown)"
  [[ "$TARGET_ALIVE_AT_TEARDOWN" =~ ^[01]$ ]] || TARGET_ALIVE_AT_TEARDOWN="unknown"
fi

TARGET_APP_LOG="${OUTPUT_DIR}/target-app.log"
READINESS_FAILED=0
HEAP_OOM_LOG=0
if [[ -f "$TARGET_APP_LOG" ]]; then
  grep -Eqi 'readiness check failed|failed readiness check' "$TARGET_APP_LOG" && READINESS_FAILED=1
  grep -Eq 'OutOfMemoryError' "$TARGET_APP_LOG" && HEAP_OOM_LOG=1
fi

# Third-source corroboration. memory.events is authoritative for cgroup kills, but it
# cannot see a JVM-internal fatal crash (SIGSEGV / native-OOM the JVM detects itself —
# the kernel did NOT do the killing, so oom_kill stays flat). hs_err_pid*.log is exactly
# that complementary signal. dmesg corroborates a cgroup kill with the killed pid/RSS,
# but is strictly best-effort: under a --user systemd scope the ring buffer is usually
# unreadable (no CAP_SYSLOG), so absence proves nothing.
CRASH_ARTIFACT_DIR="${OUTPUT_DIR}/crash-artifacts"
HS_ERR_PRESENT=0
HS_ERR_REL_PATHS_JSON='[]'
HS_ERR_CAUSE=""
REPLAY_PRESENT=0
CORE_PRESENT=0
{
  hs_list=()
  while IFS= read -r _f; do [[ -n "$_f" ]] && hs_list+=("$_f"); done < <(
    {
      find "$REPO_ROOT" -maxdepth 1 -type f -name 'hs_err_pid*.log' -newer "$RUN_START_MARKER" 2>/dev/null
      find "$OUTPUT_DIR" -maxdepth 3 -type f -name 'hs_err_pid*.log' -newer "$RUN_START_MARKER" 2>/dev/null
    } | sort -u
  )
  if (( ${#hs_list[@]} > 0 )); then
    HS_ERR_PRESENT=1
    mkdir -p "$CRASH_ARTIFACT_DIR" 2>/dev/null || true
    rels=()
    for _hs in "${hs_list[@]}"; do
      cp -f "$_hs" "$CRASH_ARTIFACT_DIR/" 2>/dev/null || true
      rels+=("crash-artifacts/$(basename "$_hs")")
    done
    HS_ERR_REL_PATHS_JSON="$(printf '%s\n' "${rels[@]}" | jq -R . | jq -s .)"
    # Fatal cause from the hs_err header (e.g. "SIGSEGV", "Out of Memory Error").
    HS_ERR_CAUSE="$(grep -m1 -oaE 'SIG[A-Z]+|Out of Memory Error|Internal Error|EXCEPTION_[A-Z_]+' "${hs_list[0]}" 2>/dev/null || true)"
  fi
  find "$REPO_ROOT" -maxdepth 1 -type f -name 'replay_pid*.log' -newer "$RUN_START_MARKER" 2>/dev/null | grep -q . && REPLAY_PRESENT=1
  find "$REPO_ROOT" -maxdepth 1 -type f -name 'core' -newer "$RUN_START_MARKER" 2>/dev/null | grep -q . && CORE_PRESENT=1
} || true

DMESG_AVAILABLE=false
DMESG_OOM_INVOKED=null
DMESG_MATCH_COUNT=0
DMESG_SAMPLE_JSON='[]'
_dmesg_out=""
if _dmesg_out="$( { dmesg --since "@${RUN_START_EPOCH}" 2>/dev/null || dmesg 2>/dev/null; } )" && [[ -n "$_dmesg_out" ]]; then
  DMESG_AVAILABLE=true
  _dlines=()
  while IFS= read -r _dl; do [[ -n "$_dl" ]] && _dlines+=("$_dl"); done < <(
    printf '%s\n' "$_dmesg_out" | grep -iE 'out of memory|oom-kill:|killed process|memory cgroup out of memory' | tail -n 15
  )
  DMESG_MATCH_COUNT="${#_dlines[@]}"
  if (( DMESG_MATCH_COUNT > 0 )); then
    DMESG_OOM_INVOKED=true
    DMESG_SAMPLE_JSON="$(printf '%s\n' "${_dlines[@]}" | jq -R . | jq -s .)"
  else
    DMESG_OOM_INVOKED=false
  fi
fi
rm -f "$RUN_START_MARKER" 2>/dev/null || true

HS_ERR_IS_OOM=0
[[ "$HS_ERR_CAUSE" == *"Out of Memory"* ]] && HS_ERR_IS_OOM=1

# Pure decision table (sourced so it can be unit-tested without a real run).
# shellcheck source=../tools/bench/lib/constrained-classify.sh
source "${REPO_ROOT}/tools/bench/lib/constrained-classify.sh"
IFS=$'\t' read -r OUTCOME FAILED_PHASE OOM_AFTER_MEASUREMENT < <(
  classify_constrained_outcome "$BENCHMARK_RC" "$OOM_KILL_DELTA" "$PHASE_REACHED" "$READINESS_FAILED" "$HEAP_OOM_LOG"
)
MEMORY_FAILURE_KIND="$(derive_memory_failure_kind "$OOM_KILL_DELTA" "$HS_ERR_PRESENT" "$HS_ERR_IS_OOM" "$HEAP_OOM_LOG")"

echo "[constrained] outcome=${OUTCOME} phase_reached=${PHASE_REACHED} failed_phase=${FAILED_PHASE} memory_failure_kind=${MEMORY_FAILURE_KIND} oom_kill_delta=${OOM_KILL_DELTA} hs_err=${HS_ERR_PRESENT} dmesg_oom=${DMESG_OOM_INVOKED} oom_after_measurement=${OOM_AFTER_MEASUREMENT} target_alive_at_teardown=${TARGET_ALIVE_AT_TEARDOWN} rc=${BENCHMARK_RC}"

CG_MEMORY_PEAK_BYTES="unknown"
if [[ -f "${CGROUP_DIR}/memory.peak" ]]; then
  CG_MEMORY_PEAK_BYTES="$(<"${CGROUP_DIR}/memory.peak")"
elif [[ -f "${CGROUP_DIR}/memory.current" ]]; then
  CG_MEMORY_PEAK_BYTES="$(<"${CGROUP_DIR}/memory.current")"
fi

CPU_STAT_NR_PERIODS="0"
CPU_STAT_NR_THROTTLED="0"
CPU_STAT_THROTTLED_USEC="0"
if [[ -f "${CGROUP_DIR}/cpu.stat" ]]; then
  CPU_STAT_NR_PERIODS="$(awk '$1=="nr_periods" {print $2}' "${CGROUP_DIR}/cpu.stat" | head -n1)"
  CPU_STAT_NR_THROTTLED="$(awk '$1=="nr_throttled" {print $2}' "${CGROUP_DIR}/cpu.stat" | head -n1)"
  CPU_STAT_THROTTLED_USEC="$(awk '$1=="throttled_usec" {print $2}' "${CGROUP_DIR}/cpu.stat" | head -n1)"
  CPU_STAT_NR_PERIODS="${CPU_STAT_NR_PERIODS:-0}"
  CPU_STAT_NR_THROTTLED="${CPU_STAT_NR_THROTTLED:-0}"
  CPU_STAT_THROTTLED_USEC="${CPU_STAT_THROTTLED_USEC:-0}"
fi

EVIDENCE_FILE="${OUTPUT_DIR}/constrained-execution-evidence.json"
LAUNCH_OVERLAY_FILE="${OUTPUT_DIR}/constrained-launch-overlay.env"
GENERATED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

JVM_FLAGS_JSON="$(printf '%s\n' "${JVM_OVERLAY_FLAGS[@]}" | jq -R . | jq -s .)"
LAUNCH_COMMAND_JSON="$(printf '%s\n' "${LAUNCH_COMMAND[@]}" | jq -R . | jq -s .)"

jq -n \
  --arg execution_profile_id "$EXECUTION_PROFILE_ID" \
  --arg contract_id "$CONTRACT_ID" \
  --arg target_runtime "$TARGET_RUNTIME" \
  --arg target_build "$TARGET_BUILD" \
  --argjson benchmark_skip_target_build "$BENCHMARK_SKIP_TARGET_BUILD" \
  --arg required_track_id "$REQUIRED_TRACK_ID" \
  --arg track_id "track-c" \
  --arg result_namespace "$RESULT_NAMESPACE" \
  --arg memory_max_bytes "$CG_MEMORY_MAX_BYTES" \
  --arg cpu_quota_us "$CG_CPU_QUOTA_US" \
  --arg cpu_period_us "$CG_CPU_PERIOD_US" \
  --arg memory_peak_bytes "$CG_MEMORY_PEAK_BYTES" \
  --arg nr_periods "$CPU_STAT_NR_PERIODS" \
  --arg nr_throttled "$CPU_STAT_NR_THROTTLED" \
  --arg throttled_usec "$CPU_STAT_THROTTLED_USEC" \
  --arg oom_kill_delta "$OOM_KILL_DELTA" \
  --arg oom_delta "$OOM_DELTA" \
  --arg oom_group_kill_delta "$OOM_GROUP_KILL_DELTA" \
  --arg max_event_delta "$MAX_EVENT_DELTA" \
  --arg phase_reached "$PHASE_REACHED" \
  --arg failed_phase "$FAILED_PHASE" \
  --argjson oom_after_measurement "$OOM_AFTER_MEASUREMENT" \
  --arg target_alive_at_teardown "$TARGET_ALIVE_AT_TEARDOWN" \
  --arg memory_failure_kind "$MEMORY_FAILURE_KIND" \
  --argjson hs_err_present "$( ((HS_ERR_PRESENT)) && echo true || echo false )" \
  --argjson hs_err_paths "$HS_ERR_REL_PATHS_JSON" \
  --arg hs_err_cause "$HS_ERR_CAUSE" \
  --argjson replay_present "$( ((REPLAY_PRESENT)) && echo true || echo false )" \
  --argjson core_present "$( ((CORE_PRESENT)) && echo true || echo false )" \
  --argjson dmesg_available "$DMESG_AVAILABLE" \
  --argjson dmesg_oom_invoked "$DMESG_OOM_INVOKED" \
  --argjson dmesg_match_count "$DMESG_MATCH_COUNT" \
  --argjson dmesg_sample "$DMESG_SAMPLE_JSON" \
  --argjson jvm_overlay_flags "$JVM_FLAGS_JSON" \
  --argjson launch_command "$LAUNCH_COMMAND_JSON" \
  --argjson benchmark_exit_code "$BENCHMARK_RC" \
  --arg outcome "$OUTCOME" \
  --arg jit_representativeness "$JIT_REPRESENTATIVENESS" \
  --arg generated_at_utc "$GENERATED_AT_UTC" \
  '{
    execution_profile_id: $execution_profile_id,
    jit_representativeness: $jit_representativeness,
    contract_id: $contract_id,
    target_runtime: $target_runtime,
    target_build: $target_build,
    benchmark_skip_target_build: $benchmark_skip_target_build,
    required_track_id: $required_track_id,
    track_id: $track_id,
    result_namespace: $result_namespace,
    cgroup_effective: {
      memory_max_bytes: ($memory_max_bytes|tonumber?),
      cpu_quota_us: ($cpu_quota_us|tonumber?),
      cpu_period_us: ($cpu_period_us|tonumber?),
      memory_peak_bytes: ($memory_peak_bytes|tonumber?),
      cpu_stat: {
        nr_periods: ($nr_periods|tonumber?),
        nr_throttled: ($nr_throttled|tonumber?),
        throttled_usec: ($throttled_usec|tonumber?)
      },
      memory_events: {
        oom_kill: ($oom_kill_delta|tonumber?),
        oom: ($oom_delta|tonumber?),
        oom_group_kill: ($oom_group_kill_delta|tonumber?),
        max: ($max_event_delta|tonumber?)
      }
    },
    phase_reached: $phase_reached,
    failed_phase: (if $failed_phase == "null" then null else $failed_phase end),
    oom_after_measurement: $oom_after_measurement,
    target_alive_at_teardown: (if $target_alive_at_teardown == "unknown" then null else ($target_alive_at_teardown|tonumber?) end),
    memory_failure_kind: $memory_failure_kind,
    crash_artifacts: {
      hs_err_present: $hs_err_present,
      hs_err_paths: $hs_err_paths,
      hs_err_cause: (if $hs_err_cause == "" then null else $hs_err_cause end),
      replay_present: $replay_present,
      core_present: $core_present
    },
    dmesg_oom: {
      available: $dmesg_available,
      oom_killer_invoked: $dmesg_oom_invoked,
      matched_line_count: $dmesg_match_count,
      sample_lines: $dmesg_sample,
      note: "best-effort kernel ring-buffer scan; commonly empty/unavailable under a --user systemd scope (no CAP_SYSLOG). memory.events.oom_kill is the authoritative cgroup signal."
    },
    jvm_overlay_flags: $jvm_overlay_flags,
    launch_command: $launch_command,
    benchmark_exit_code: $benchmark_exit_code,
    outcome: $outcome,
    generated_at_utc: $generated_at_utc
  }' > "$EVIDENCE_FILE"

# Validate the evidence shape against its schema — but WARN-only, never abort. This file
# is most valuable precisely on the failure paths (OOM in warmup/teardown); a validator
# gap or a schema-drift must not swallow the one artifact that records what happened.
EVIDENCE_SCHEMA="${REPO_ROOT}/schemas/constrained-execution-evidence.schema.json"
if [[ -f "$EVIDENCE_SCHEMA" ]]; then
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$EVIDENCE_SCHEMA" "$EVIDENCE_FILE" \
      || echo "[constrained] WARN: constrained-execution-evidence.json failed schema validation (kept anyway; see above)" >&2
  elif command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$EVIDENCE_SCHEMA" -d "$EVIDENCE_FILE" \
      || echo "[constrained] WARN: constrained-execution-evidence.json failed schema validation (kept anyway)" >&2
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    python3 -c 'import json,sys,jsonschema; jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))' \
      "$EVIDENCE_SCHEMA" "$EVIDENCE_FILE" \
      || echo "[constrained] WARN: constrained-execution-evidence.json failed schema validation (kept anyway)" >&2
  fi
fi

{
  printf 'export JAVA_TOOL_OPTIONS=%q\n' "$JAVA_TOOL_OPTIONS"
  printf 'export BENCHMARK_EXECUTION_PROFILE_ID=%q\n' "$BENCHMARK_EXECUTION_PROFILE_ID"
  printf 'export BENCHMARK_TRACK_ID=%q\n' "$BENCHMARK_TRACK_ID"
  printf 'export EXERIS_DB_POOL_MIN_SIZE=%q\n' "$EXERIS_DB_POOL_MIN_SIZE"
  printf 'export EXERIS_DB_POOL_MAX_SIZE=%q\n' "$EXERIS_DB_POOL_MAX_SIZE"
  printf 'export EXERIS_DB_CONNECTION_TIMEOUT_MS=%q\n' "$EXERIS_DB_CONNECTION_TIMEOUT_MS"
} > "$LAUNCH_OVERLAY_FILE"

RESULT_FILE="${OUTPUT_DIR}/result.json"
if [[ -f "$RESULT_FILE" ]]; then
  TMP_RESULT="$(mktemp)"
  jq \
    --arg execution_profile_id "$EXECUTION_PROFILE_ID" \
    --arg contract_id "$CONTRACT_ID" \
    --arg track_id "track-c" \
    --arg result_namespace "$RESULT_NAMESPACE" \
    --arg jit_representativeness "$JIT_REPRESENTATIVENESS" \
    '.run_config = ((.run_config // {}) + {
      execution_profile_id: $execution_profile_id,
      contract_id: $contract_id,
      track_id: $track_id,
      result_namespace: $result_namespace,
      jit_representativeness: $jit_representativeness
    })' "$RESULT_FILE" > "$TMP_RESULT"
  mv "$TMP_RESULT" "$RESULT_FILE"

  TMP_RESULT_TRACK="$(mktemp)"
  if jq 'try (. + {run_track: "constrained"}) catch .' "$RESULT_FILE" > "$TMP_RESULT_TRACK"; then
    mv "$TMP_RESULT_TRACK" "$RESULT_FILE"
  else
    rm -f "$TMP_RESULT_TRACK"
  fi
fi

REPRO_FILE="${OUTPUT_DIR}/reproducibility-metadata.json"
if [[ -f "$REPRO_FILE" ]]; then
  TMP_REPRO="$(mktemp)"
  jq \
    --arg contract_id "$CONTRACT_ID" \
    --arg jit_representativeness "$JIT_REPRESENTATIVENESS" \
    '.axis_labels = ((.axis_labels // {}) + {
      claim_scope: "descriptive_only",
      execution_class: "exploratory",
      jit_representativeness: $jit_representativeness
    })
    | .contract = $contract_id' "$REPRO_FILE" > "$TMP_REPRO"
  mv "$TMP_REPRO" "$REPRO_FILE"
fi

echo "output_dir=$OUTPUT_DIR"
echo "cgroup_memory_max_bytes=$CG_MEMORY_MAX_BYTES cgroup_cpu_quota_us=$CG_CPU_QUOTA_US cgroup_cpu_period_us=$CG_CPU_PERIOD_US"
echo "outcome=$OUTCOME rc=$BENCHMARK_RC"

exit "$BENCHMARK_RC"
