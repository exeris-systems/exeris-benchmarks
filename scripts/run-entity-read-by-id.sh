#!/usr/bin/env bash
set -euo pipefail

# Usage: run-entity-read-by-id.sh [--contract fixed_contract_v1] [--claim-scope exploratory|comparison-eligible] [--profile <hw-profile>] [--output-dir <path>] [--threads <int>] [--connections <int>] [--duration <N>s] [--warmup <N>s] [--driver wrk|h2load|wrk2] [--h2load-axis h1|h2c] [--backend-mode default-vt|locality-aware] [--target-runtime auto|community|locality|spring|spring-runtime-on-exeris|quarkus] [--target-build jvm|native] [--cpu-affinity <cpuset>] [--client-cpu-affinity <cpuset>]
#   --client-cpu-affinity pins the load driver (wrk/h2load) to a cpuset DISJOINT from --cpu-affinity, so the
#   target is the bottleneck and its CPU-efficiency shows as throughput. Local target-bound recipe on a 12-core box:
#   --cpu-affinity 0-2 --client-cpu-affinity 3-9 (target 3 cores, driver 7, leave 10-11 for OS/Postgres).
#   --driver h2load is exploratory-only (h2load H1 vs wrk H1 is not directly comparable; h2load emits no latency percentiles). --h2load-axis h2c selects the "HTTP/2, no --h1" axis (transport_mode=loopback-h2); whether the wire is cleartext h2c or h2-over-TLS depends on BENCHMARK_TLS_ENABLED and is recorded in result.json `tls`.
#
# Orchestrates the entity-read-by-id E2E benchmark run:
#   1. Validate claim-scope
#   2. Start DB (Docker Compose)
#   3. Apply seed (psql entities.sql)
#   4. Verify seed (verify-seed.sh) — abort on failure
#   5. Capture env
#   6. Warmup (60s, discarded)
#   7. Measure (duration per claim-scope)
#   8. Write result artifact with transport_mode, seed_ref, claim_scope
#   9. Schema-validate result artifact

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
READINESS_LIB="${REPO_ROOT}/tools/bench/lib/readiness.sh"
if [[ ! -f "$READINESS_LIB" ]]; then
  echo "ERROR: readiness library not found: $READINESS_LIB"
  exit 1
fi

# shellcheck source=/dev/null
source "$READINESS_LIB"

JFR_LIB="${REPO_ROOT}/tools/bench/lib/jfr.sh"
# shellcheck source=/dev/null
[[ -f "$JFR_LIB" ]] && source "$JFR_LIB"

RESOURCE_SAMPLER_LIB="${REPO_ROOT}/tools/bench/lib/resource-sampler.sh"
# shellcheck source=/dev/null
[[ -f "$RESOURCE_SAMPLER_LIB" ]] && source "$RESOURCE_SAMPLER_LIB"
OS_SAMPLER_LIB="${REPO_ROOT}/tools/bench/lib/os-sampler.sh"
# shellcheck source=/dev/null
[[ -f "$OS_SAMPLER_LIB" ]] && source "$OS_SAMPLER_LIB"

CLAIM_SCOPE="${CLAIM_SCOPE:-exploratory}"
PROFILE="${PROFILE:-dev-laptop}"
OUTPUT_DIR="${OUTPUT_DIR:-results/raw/entity-read-by-id/$(date +%Y%m%d-%H%M%S)}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
EXERIS_DB_POOL_MIN_SIZE="${EXERIS_DB_POOL_MIN_SIZE:-16}"
EXERIS_DB_POOL_MAX_SIZE="${EXERIS_DB_POOL_MAX_SIZE:-256}"
# DB connection-acquisition timeout (ms). Defaults to 30000 to match Spring
# Hikari (~30 s) and Quarkus Agroal, so cold-start / latency-spike pool
# contention surfaces as latency on ALL targets instead of fail-fast
# connectionExhausted → HTTP 500 only on the kernel-backed targets (community /
# spring-on-exeris). This is a fairness leveler: without it the Exeris targets
# are handicapped at the harness layer, not the runtime layer. The constrained
# wrapper overrides this (it sets a short timeout on purpose, to tolerate
# transient queuing under CPU throttling) and that explicit value wins via :-.
#
# REGRESSION/BASELINE CALLOUT (docs/regression-policy.md): this default changed
# from "unset" (framework default) to 30000 and applies to ALL targets
# (community / spring / spring-on-exeris / quarkus), not just the kernel-backed
# ones. Any baseline captured BEFORE this default was introduced predates a
# harness-config change, so old-vs-new comparisons cross that change and are NOT
# directly comparable — re-capture the affected baselines rather than diffing
# across the boundary. Export an explicit EXERIS_DB_CONNECTION_TIMEOUT_MS to pin
# the prior behavior for a controlled before/after.
EXERIS_DB_CONNECTION_TIMEOUT_MS="${EXERIS_DB_CONNECTION_TIMEOUT_MS:-30000}"
WARMUP="${WARMUP:-60s}"
BACKEND_MODE="${BACKEND_MODE:-default-vt}"
TARGET_RUNTIME="${TARGET_RUNTIME:-auto}"
TARGET_BUILD="${TARGET_BUILD:-jvm}"
CPU_AFFINITY="${CPU_AFFINITY:-}"
CLIENT_CPU_AFFINITY="${CLIENT_CPU_AFFINITY:-}"
PERF_STAT_REQUIRED="${BENCHMARK_REQUIRE_PERF_STAT:-0}"
BACKEND_EVIDENCE_REQUIRED="${BENCHMARK_REQUIRE_BACKEND_EVIDENCE:-0}"
ALLOW_EXTERNAL_DB="${BENCHMARK_ALLOW_EXTERNAL_DB:-0}"
LOCALITY_MODE_ENABLED="${BENCHMARK_ENABLE_LOCALITY_MODE:-0}"
BENCHMARK_LOCALITY_STRICT="${BENCHMARK_LOCALITY_STRICT:-0}"
SKIP_TARGET_BUILD="${BENCHMARK_SKIP_TARGET_BUILD:-0}"
ENTITY_READ_PREFLIGHT_TIMEOUT="${ENTITY_READ_PREFLIGHT_TIMEOUT:-60}"
# /health readiness does not imply the data endpoint is warm: under constrained
# CPU (e.g. 0.5 vCPU) the first /api/v1/users hit can transiently 500 while the
# request/persistence path finishes warming. Poll the data endpoint until it is
# actually serving 200, instead of aborting on a single early miss.
ENTITY_READ_PREFLIGHT_READY_SECONDS="${ENTITY_READ_PREFLIGHT_READY_SECONDS:-30}"
# JFR recording of the target during measurement (opt-in; default off so existing
# callers are unchanged). Community track is OSS, so the raw .jfr is kept as-is.
ENABLE_JFR="${BENCHMARK_ENABLE_JFR:-false}"
JFR_SETTINGS="${BENCHMARK_JFR_SETTINGS:-profile}"
ALLOW_EXTERNAL_TARGET="${BENCHMARK_ALLOW_EXTERNAL_TARGET:-0}"
TARGET_PORT="${BENCHMARK_TARGET_PORT:-8080}"
DURATION_OVERRIDE=""
CONTRACT_NAME=""
# Load driver. wrk (default) drives H1 over wrk.lua and yields a full latency
# distribution (p50/p75/p90/p99). h2load drives H1 (--h1 -m 1, mirrors the wrk
# contract) or H2c (-m N) and yields throughput + min/max/mean/sd only — h2load
# has NO percentile output, so p50/p75/p90/p99 are recorded as null (honest, not
# faked). wrk2/k6 are handled by their own runners (run-wrk2.sh / run-k6.sh).
DRIVER="${DRIVER:-wrk}"
# Transport axis when DRIVER=h2load. h1 = cleartext HTTP/1.1 (loopback-h1),
# h2c = the "HTTP/2, no --h1" axis. Its real wire protocol depends on the endpoint
# scheme: cleartext http:// -> true h2c (loopback-h2c); TLS https:// -> h2 over TLS
# via ALPN (loopback-h2-tls). h2c is exploratory-only per
# scenarios/entity-read-by-id/h2load.flags (not comparable to H1 or wrk).
H2LOAD_AXIS="${ENTITY_READ_H2LOAD_AXIS:-h1}"
H2LOAD_AXIS_LABEL="$H2LOAD_AXIS"   # human label, refined once TLS state is known
H2LOAD_H2C_MAX_CONCURRENT_STREAMS="${H2LOAD_H2C_MAX_CONCURRENT_STREAMS:-10}"
# TLS toggle. When the guided launcher (or any caller) sets BENCHMARK_TLS_ENABLED=1
# the managed target is launched with TLS (it inherits EXERIS_SSL_ENABLED /
# EXERIS_TRANSPORT_CERT_PATH from the environment), so the client must speak https
# and tolerate the self-signed smoke cert. Default (unset/0) is plain HTTP — byte
# identical to the pre-toggle behavior.
TLS_ENABLED="${BENCHMARK_TLS_ENABLED:-0}"
if [[ "$TLS_ENABLED" == "1" ]]; then TARGET_SCHEME="https"; CURL_INSECURE_OPT="-k"; else TARGET_SCHEME="http"; CURL_INSECURE_OPT=""; fi
BASE_URL="${BASE_URL:-${TARGET_SCHEME}://localhost:${TARGET_PORT}}"
SCENARIO_DIR="scenarios/entity-read-by-id"
DB_COMPOSE_FILE="runtime/compose/entity-read-by-id-db.yml"
# Backend container network mode (fairness gate). entity-read-by-id is a CROSS-STACK
# comparison (exeris vs spring vs quarkus against the same Postgres), so bridge/NAT
# taxes chattier runtimes asymmetrically. DB_HOST_NETWORK=1 (or BENCH_BACKEND_NETWORK=host)
# layers the host-net override so the DB shares the host network. Recorded in result.json.
DB_COMPOSE_HOSTNET_OVERRIDE="runtime/compose/entity-read-by-id-db.host-net.yml"
if [[ "${DB_HOST_NETWORK:-0}" == "1" || "${BENCH_BACKEND_NETWORK:-}" == "host" ]]; then
  BACKEND_NETWORK_MODE="host"
else
  BACKEND_NETWORK_MODE="bridge"
fi
DB_INIT_SQL_FILE="${REPO_ROOT}/runtime/compose/entity-read-by-id-init.sql"
TARGET_MODULE_POM_COMMUNITY="targets/exeris-community-app/pom.xml"
TARGET_JAR_GLOB_COMMUNITY="targets/exeris-community-app/target/exeris-community-app-*.jar"
TARGET_NATIVE_BIN_GLOB_COMMUNITY="targets/exeris-community-app/target/exeris-community-app"
TARGET_APP_NAME_COMMUNITY="exeris-community-app"
TARGET_MODULE_POM_LOCALITY="targets/exeris-community-app-locality/pom.xml"
TARGET_JAR_GLOB_LOCALITY="targets/exeris-community-app-locality/target/exeris-community-app-locality-*.jar"
TARGET_NATIVE_BIN_GLOB_LOCALITY="targets/exeris-community-app-locality/target/exeris-community-app-locality"
TARGET_APP_NAME_LOCALITY="exeris-community-app-locality"
TARGET_MODULE_POM_SPRING="targets/spring-benchmark-app/pom.xml"
TARGET_JAR_GLOB_SPRING="targets/spring-benchmark-app/target/spring-benchmark-app-*.jar"
TARGET_NATIVE_BIN_GLOB_SPRING="targets/spring-benchmark-app/target/spring-benchmark-app"
TARGET_APP_NAME_SPRING="spring-benchmark-app"
# Spring MVC hosted on exeris-spring-runtime (Compat Mode) — distinct module from the
# Tomcat/Axon spring-benchmark-app. The jar shares the spring-benchmark-app artifact name
# but lives under a different module path, so the glob below is unambiguous.
TARGET_MODULE_POM_SPRING_ON_EXERIS="targets/exeris-spring-runtime-app-comp/pom.xml"
TARGET_JAR_GLOB_SPRING_ON_EXERIS="targets/exeris-spring-runtime-app-comp/target/spring-benchmark-app-*.jar"
TARGET_NATIVE_BIN_GLOB_SPRING_ON_EXERIS="targets/exeris-spring-runtime-app-comp/target/spring-benchmark-app"
TARGET_APP_NAME_SPRING_ON_EXERIS="exeris-spring-runtime-app-comp"
TARGET_MODULE_POM_QUARKUS="targets/quarkus-benchmark-app/pom.xml"
TARGET_JAR_GLOB_QUARKUS="targets/quarkus-benchmark-app/target/quarkus-benchmark-app-*-runner.jar"
TARGET_NATIVE_BIN_GLOB_QUARKUS="targets/quarkus-benchmark-app/target/quarkus-benchmark-app-*-runner"
TARGET_APP_NAME_QUARKUS="quarkus-benchmark-app"
TARGET_MODULE_POM="$TARGET_MODULE_POM_COMMUNITY"
TARGET_JAR_GLOB="$TARGET_JAR_GLOB_COMMUNITY"
TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_COMMUNITY"
TARGET_APP_NAME="$TARGET_APP_NAME_COMMUNITY"
TARGET_RUNTIME_EFFECTIVE="community"
CAPTURE_DB_DIAGNOSTICS_SCRIPT="$SCENARIO_DIR/capture-db-diagnostics.sh"
DB_PORT="${DB_PORT:-5432}"
TARGET_APP_LOG=""
TARGET_APP_PID=""
TARGET_APP_STARTED=0
TARGET_PID_FILE="/tmp/${TARGET_APP_NAME}-benchmark.pid"
COMPOSE_BIN=""
DB_LAUNCH_MODE=""
DB_CONTAINER_NAME="exeris-benchmark-db"
DB_MANAGED=0

CONTRACT_FIXED_THREADS=4
CONTRACT_FIXED_CONNECTIONS=128
CONTRACT_FIXED_WARMUP_SECONDS=60
CONTRACT_FIXED_DURATION_SECONDS=120
CONTRACT_FIXED_PROFILE="perf-box-amd64"
CONTRACT_FIXED_CLAIM_SCOPE="comparison-eligible"

# --- GraalVM auto-resolution for native builds ----------------------------
# A native build (mvn -Pnative) needs a GraalVM whose JDK MAJOR matches the
# target's required Java version — preview features (this app uses
# --enable-preview) only compile on the exact same major. The ambient JAVA_HOME
# is often a plain JDK, so resolve a matching GraalVM and scope it to the build.
graalvm_major() {
  local home="$1" v=""
  if [[ -r "$home/release" ]]; then
    v="$(awk -F'"' '/^JAVA_VERSION=/{print $2; exit}' "$home/release" 2>/dev/null)"
  fi
  if [[ -z "$v" && -x "$home/bin/java" ]]; then
    v="$("$home/bin/java" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
  fi
  v="${v%%.*}"
  printf '%s\n' "$v"
}

# resolve_graalvm_home <want_major> -> prints a GraalVM home with native-image and
# (if want_major non-empty) matching JDK major. Precedence: BENCHMARK_GRAALVM_HOME,
# GRAALVM_HOME, sdkman candidates, native-image on PATH.
resolve_graalvm_home() {
  local want="$1" cand best=""
  for cand in "${BENCHMARK_GRAALVM_HOME:-}" "${GRAALVM_HOME:-}"; do
    [[ -n "$cand" && -x "$cand/bin/native-image" ]] || continue
    if [[ -z "$want" || "$(graalvm_major "$cand")" == "$want" ]]; then
      printf '%s\n' "$cand"; return 0
    fi
  done
  for cand in "$HOME"/.sdkman/candidates/java/*/; do
    cand="${cand%/}"
    [[ -x "$cand/bin/native-image" ]] || continue
    if [[ -z "$want" || "$(graalvm_major "$cand")" == "$want" ]]; then
      best="$cand"
    fi
  done
  if [[ -n "$best" ]]; then printf '%s\n' "$best"; return 0; fi
  if command -v native-image >/dev/null 2>&1; then
    cand="$(dirname "$(dirname "$(command -v native-image)")")"
    if [[ -z "$want" || "$(graalvm_major "$cand")" == "$want" ]]; then
      printf '%s\n' "$cand"; return 0
    fi
  fi
  return 1
}

# List GraalVM homes + majors found, for diagnostics on failure.
list_graalvm_candidates() {
  local cand
  for cand in "$HOME"/.sdkman/candidates/java/*/; do
    cand="${cand%/}"
    [[ -x "$cand/bin/native-image" ]] && printf '    %s (Java %s)\n' "$cand" "$(graalvm_major "$cand")"
  done
}

require_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    echo "ERROR: $name must be a positive integer (got: $value)"
    exit 1
  fi
}

require_duration_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+s$ ]]; then
    echo "ERROR: $name must match <N>s (got: $value)"
    exit 1
  fi
}

to_us() {
  local token="$1"
  if [[ -z "$token" ]]; then
    echo ""
    return 0
  fi

  if [[ "$token" =~ ^([0-9]*\.?[0-9]+)(us|ms|s)$ ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    LC_ALL=C awk -v v="$value" -v u="$unit" 'BEGIN {
      if (u == "us") {
        printf "%.6f", v
      } else if (u == "ms") {
        printf "%.6f", v * 1000
      } else if (u == "s") {
        printf "%.6f", v * 1000000
      }
    }'
    return 0
  fi

  echo ""
}

assert_contract_match() {
  local flag_name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: --contract $CONTRACT_NAME requires $flag_name=$expected (got: $actual)"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT_NAME="$2"; shift 2 ;;
    --claim-scope) CLAIM_SCOPE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --duration) DURATION_OVERRIDE="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --backend-mode) BACKEND_MODE="$2"; shift 2 ;;
    --driver) DRIVER="$2"; shift 2 ;;
    --h2load-axis) H2LOAD_AXIS="$2"; shift 2 ;;
    --target-runtime) TARGET_RUNTIME="$2"; shift 2 ;;
    --target-build) TARGET_BUILD="$2"; shift 2 ;;
    --cpu-affinity) CPU_AFFINITY="$2"; shift 2 ;;
    --client-cpu-affinity) CLIENT_CPU_AFFINITY="$2"; shift 2 ;;
    --enable-jfr) ENABLE_JFR="true"; shift ;;
    --no-jfr) ENABLE_JFR="false"; shift ;;
    --jfr-settings) JFR_SETTINGS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

case "$BACKEND_MODE" in
  default-vt|locality-aware)
    ;;
  *)
    echo "ERROR: --backend-mode must be default-vt or locality-aware (got: $BACKEND_MODE)"
    exit 1
    ;;
esac

case "$TARGET_RUNTIME" in
  auto|community|locality|spring|spring-runtime-on-exeris|quarkus)
    ;;
  *)
    echo "ERROR: --target-runtime must be auto, community, locality, spring, spring-runtime-on-exeris, or quarkus (got: $TARGET_RUNTIME)"
    exit 1
    ;;
esac

case "$TARGET_BUILD" in
  jvm|native)
    ;;
  *)
    echo "ERROR: --target-build must be jvm or native (got: $TARGET_BUILD)"
    exit 1
    ;;
esac

# --- Load-driver resolution ------------------------------------------------
# Derive the tool/transport/protocol labels up front so env capture and every
# result artifact stamp the driver that ACTUALLY ran. This runner is wrk- and
# wrk + h2load measured inline; wrk2 is launched-then-DELEGATED to run-wrk2.sh for
# the CO-free latency measurement (this script does not reimplement its semantics).
# k6 still has its own dedicated runner (different output/parser).
case "$DRIVER" in
  wrk)
    TOOL_NAME="wrk"
    TRANSPORT_MODE="loopback-h1"
    PROTOCOL="h1"
    BENCHMARK_FAMILY="runtime-wrk"
    ;;
  h2load)
    if ! command -v h2load >/dev/null 2>&1; then
      echo "ERROR: --driver h2load requires the h2load command (nghttp2)"
      exit 1
    fi
    case "$H2LOAD_AXIS" in
      h1)
        TRANSPORT_MODE="loopback-h1"
        PROTOCOL="h1"
        H2LOAD_AXIS_LABEL="h1 (cleartext)"
        ;;
      h2c)
        # H2c is exploratory-only and NOT comparable to H1 or to wrk results
        # (scenarios/entity-read-by-id/h2load.flags). Refuse to mint a
        # comparison-eligible artifact over it.
        if [[ "$CLAIM_SCOPE" == "comparison-eligible" ]]; then
          echo "ERROR: --driver h2load --h2load-axis h2c is exploratory-only (not comparable to H1/wrk); use --claim-scope exploratory."
          exit 1
        fi
        # The h2load "h2c" axis means "HTTP/2, no --h1". transport_mode is the schema
        # enum value (loopback-h2) for both; TLS vs cleartext is orthogonal and is
        # carried by the `tls` field, NOT by faking an "h2c" transport label when the
        # endpoint is actually TLS. The human axis label below reflects the real wire.
        #   - cleartext http://  -> true h2c (prior-knowledge)
        #   - TLS      https:// -> h2 negotiated via ALPN
        # The post-load ALPN-fallback guard below still fails the run if the server
        # did NOT actually negotiate h2, so an H1-only target can never be H2.
        TRANSPORT_MODE="loopback-h2"
        PROTOCOL="h2"
        if [[ "$TLS_ENABLED" == "1" ]]; then
          H2LOAD_AXIS_LABEL="h2 (TLS/ALPN)"
        else
          H2LOAD_AXIS_LABEL="h2c (cleartext prior-knowledge)"
        fi
        ;;
      *)
        echo "ERROR: --h2load-axis must be h1 or h2c (got: $H2LOAD_AXIS)"
        exit 1
        ;;
    esac
    # h2load H1 vs wrk H1 are NOT directly comparable without a cross-driver
    # caveat; the comparison-eligible contract is wrk-defined, so block the mix.
    if [[ "$CLAIM_SCOPE" == "comparison-eligible" ]]; then
      echo "ERROR: --driver h2load is not comparison-eligible (the fixed contract is wrk-defined; h2load H1 vs wrk H1 needs a cross-driver caveat). Use --claim-scope exploratory."
      exit 1
    fi
    TOOL_NAME="h2load"
    BENCHMARK_FAMILY="runtime-h2load"
    ;;
  wrk2)
    # wrk2 is a CO-free sub-saturation LATENCY experiment (HTTP/1.1). This runner
    # does not reimplement it: it launches the target + seeds the DB as usual, then
    # DELEGATES the measurement phase to scripts/run-wrk2.sh (saturation-discovery
    # -> warmup -> wrk2 fixed -R, HdrHistogram), and reads back its result. wrk2
    # needs both wrk (discovery/warmup) and wrk2 (measurement).
    if ! command -v wrk2 >/dev/null 2>&1 || ! command -v wrk >/dev/null 2>&1; then
      echo "ERROR: --driver wrk2 requires both wrk2 and wrk in PATH (wrk drives saturation discovery + warmup)."
      exit 1
    fi
    # CO-free latency at a sub-saturation rate is a different measurement than the
    # wrk-defined throughput contract; never mint a comparison-eligible artifact.
    if [[ "$CLAIM_SCOPE" == "comparison-eligible" ]]; then
      echo "ERROR: --driver wrk2 is exploratory-only (CO-free sub-saturation latency, not the wrk-defined throughput contract). Use --claim-scope exploratory."
      exit 1
    fi
    TOOL_NAME="wrk2"
    TRANSPORT_MODE="loopback-h1"
    PROTOCOL="h1"
    BENCHMARK_FAMILY="runtime-wrk2"
    ;;
  k6)
    echo "ERROR: --driver k6 is not supported by this runner. Use scripts/run-k6.sh."
    exit 1
    ;;
  *)
    echo "ERROR: --driver must be wrk, h2load, or wrk2 (got: $DRIVER)"
    exit 1
    ;;
esac

if [[ "$BACKEND_MODE" == "locality-aware" ]] && [[ "$TARGET_RUNTIME" == "spring" || "$TARGET_RUNTIME" == "spring-runtime-on-exeris" || "$TARGET_RUNTIME" == "quarkus" ]]; then
  echo "ERROR: --backend-mode locality-aware is Exeris-only and cannot be combined with --target-runtime $TARGET_RUNTIME"
  exit 1
fi

if [[ "$BACKEND_MODE" == "locality-aware" ]]; then
  if [[ "$BENCHMARK_LOCALITY_STRICT" == "1" ]] && [[ "$LOCALITY_MODE_ENABLED" != "1" ]]; then
    echo "ERROR: --backend-mode locality-aware in strict mode requires BENCHMARK_ENABLE_LOCALITY_MODE=1 (VT scheduler API not verified available)."
    echo "       Unset BENCHMARK_LOCALITY_STRICT or set BENCHMARK_ENABLE_LOCALITY_MODE=1."
    exit 1
  fi
  if [[ "$BENCHMARK_LOCALITY_STRICT" == "0" ]]; then
    echo "WARN: [locality] Running locality-aware in non-strict mode; VT scheduler override may fall back to default scheduler if API unavailable."
  fi
fi

if [[ "${BENCHMARK_REQUIRE_CPU_PINNING:-0}" == "1" ]] && [[ -z "$CPU_AFFINITY" ]]; then
  echo "ERROR: BENCHMARK_REQUIRE_CPU_PINNING=1 requires --cpu-affinity <cpuset>"
  exit 1
fi

if [[ -n "$CPU_AFFINITY" ]] && ! command -v taskset >/dev/null 2>&1; then
  echo "ERROR: --cpu-affinity requires taskset command"
  exit 1
fi

if [[ -n "$CLIENT_CPU_AFFINITY" ]] && ! command -v taskset >/dev/null 2>&1; then
  echo "ERROR: --client-cpu-affinity requires taskset command"
  exit 1
fi

if [[ "$PERF_STAT_REQUIRED" == "1" ]] && ! command -v perf >/dev/null 2>&1; then
  echo "ERROR: BENCHMARK_REQUIRE_PERF_STAT=1 requires perf command"
  exit 1
fi

if [[ "$BACKEND_EVIDENCE_REQUIRED" != "0" && "$BACKEND_EVIDENCE_REQUIRED" != "1" ]]; then
  echo "ERROR: BENCHMARK_REQUIRE_BACKEND_EVIDENCE must be 0 or 1 (got: $BACKEND_EVIDENCE_REQUIRED)"
  exit 1
fi

if [[ "$ALLOW_EXTERNAL_DB" != "0" && "$ALLOW_EXTERNAL_DB" != "1" ]]; then
  echo "ERROR: BENCHMARK_ALLOW_EXTERNAL_DB must be 0 or 1 (got: $ALLOW_EXTERNAL_DB)"
  exit 1
fi

if [[ "$LOCALITY_MODE_ENABLED" != "0" && "$LOCALITY_MODE_ENABLED" != "1" ]]; then
  echo "ERROR: BENCHMARK_ENABLE_LOCALITY_MODE must be 0 or 1 (got: $LOCALITY_MODE_ENABLED)"
  exit 1
fi

if [[ "$BENCHMARK_LOCALITY_STRICT" != "0" && "$BENCHMARK_LOCALITY_STRICT" != "1" ]]; then
  echo "ERROR: BENCHMARK_LOCALITY_STRICT must be 0 or 1 (got: $BENCHMARK_LOCALITY_STRICT)"
  exit 1
fi

if [[ "$SKIP_TARGET_BUILD" != "0" && "$SKIP_TARGET_BUILD" != "1" ]]; then
  echo "ERROR: BENCHMARK_SKIP_TARGET_BUILD must be 0 or 1 (got: $SKIP_TARGET_BUILD)"
  exit 1
fi

if [[ "$ALLOW_EXTERNAL_TARGET" != "0" && "$ALLOW_EXTERNAL_TARGET" != "1" ]]; then
  echo "ERROR: BENCHMARK_ALLOW_EXTERNAL_TARGET must be 0 or 1 (got: $ALLOW_EXTERNAL_TARGET)"
  exit 1
fi

require_positive_int "BENCHMARK_TARGET_PORT" "$TARGET_PORT"

require_positive_int "--threads" "$THREADS"
require_positive_int "--connections" "$CONNECTIONS"
require_duration_seconds "--warmup" "$WARMUP"
if [[ -n "$DURATION_OVERRIDE" ]]; then
  require_duration_seconds "--duration" "$DURATION_OVERRIDE"
fi

if [[ -n "$CONTRACT_NAME" ]]; then
  case "$CONTRACT_NAME" in
    fixed_contract_v1|fixed_contract_backend_mode_h1_v1)
      ;;
    *)
      echo "ERROR: Unsupported contract '$CONTRACT_NAME'. Supported: fixed_contract_v1, fixed_contract_backend_mode_h1_v1"
      exit 1
      ;;
  esac

  if [[ -n "$DURATION_OVERRIDE" ]]; then
    echo "ERROR: --duration override is not allowed with --contract $CONTRACT_NAME"
    exit 1
  fi

  assert_contract_match "--threads" "$THREADS" "$CONTRACT_FIXED_THREADS"
  assert_contract_match "--connections" "$CONNECTIONS" "$CONTRACT_FIXED_CONNECTIONS"
  assert_contract_match "--warmup" "$WARMUP" "${CONTRACT_FIXED_WARMUP_SECONDS}s"
  assert_contract_match "--claim-scope" "$CLAIM_SCOPE" "$CONTRACT_FIXED_CLAIM_SCOPE"
  assert_contract_match "--profile" "$PROFILE" "$CONTRACT_FIXED_PROFILE"

  if [[ "$CONTRACT_NAME" == "fixed_contract_backend_mode_h1_v1" ]]; then
    if [[ "$TARGET_RUNTIME" != "auto" && "$TARGET_RUNTIME" != "locality" ]]; then
      echo "ERROR: --contract fixed_contract_backend_mode_h1_v1 only supports --target-runtime auto or locality (got: $TARGET_RUNTIME)"
      exit 1
    fi
    if [[ -z "$CPU_AFFINITY" ]]; then
      echo "ERROR: --contract fixed_contract_backend_mode_h1_v1 requires --cpu-affinity (requires_cpu_pinning=true)"
      exit 1
    fi
    BACKEND_EVIDENCE_REQUIRED=0
  fi
fi

# claim_scope enforcement
case "$CLAIM_SCOPE" in
  exploratory)
    DURATION=30s
    ;;
  comparison-eligible)
    DURATION=60s
    if [[ "$PROFILE" != "perf-box-amd64" ]]; then
      echo "ERROR: comparison-eligible requires --profile perf-box-amd64 (got: $PROFILE)"
      exit 1
    fi
    if [[ -z "$CPU_AFFINITY" ]] && [[ "${BENCHMARK_WAIVE_CPU_AFFINITY:-0}" != "1" ]]; then
      echo "ERROR: comparison-eligible requires --cpu-affinity <cpuset> for reproducible pinning (set BENCHMARK_WAIVE_CPU_AFFINITY=1 to waive)"
      exit 1
    fi
    ;;
  p99-stable)
    echo "ERROR: p99-stable requires wrk2 (CO-free). wrk is INELIGIBLE. Use run-wrk2.sh."
    exit 1
    ;;
  *)
    echo "ERROR: Unknown claim-scope: $CLAIM_SCOPE. Valid: exploratory, comparison-eligible, p99-stable"
    exit 1
    ;;
esac

if [[ -n "$DURATION_OVERRIDE" ]]; then
  if [[ "$CLAIM_SCOPE" != "exploratory" ]]; then
    echo "ERROR: --duration override is only allowed with --claim-scope exploratory"
    exit 1
  fi
  DURATION="$DURATION_OVERRIDE"
fi

if [[ -n "$CONTRACT_NAME" ]]; then
  assert_contract_match "duration" "$DURATION" "${CONTRACT_FIXED_DURATION_SECONDS}s"
fi

if [[ "$TARGET_RUNTIME" == "auto" ]]; then
  if [[ "$CONTRACT_NAME" == "fixed_contract_backend_mode_h1_v1" ]] || [[ "$BACKEND_MODE" == "locality-aware" ]]; then
    TARGET_MODULE_POM="$TARGET_MODULE_POM_LOCALITY"
    TARGET_JAR_GLOB="$TARGET_JAR_GLOB_LOCALITY"
    TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_LOCALITY"
    TARGET_APP_NAME="$TARGET_APP_NAME_LOCALITY"
    TARGET_RUNTIME_EFFECTIVE="locality"
  else
    TARGET_MODULE_POM="$TARGET_MODULE_POM_COMMUNITY"
    TARGET_JAR_GLOB="$TARGET_JAR_GLOB_COMMUNITY"
    TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_COMMUNITY"
    TARGET_APP_NAME="$TARGET_APP_NAME_COMMUNITY"
    TARGET_RUNTIME_EFFECTIVE="community"
  fi
else
  case "$TARGET_RUNTIME" in
    community)
      TARGET_MODULE_POM="$TARGET_MODULE_POM_COMMUNITY"
      TARGET_JAR_GLOB="$TARGET_JAR_GLOB_COMMUNITY"
      TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_COMMUNITY"
      TARGET_APP_NAME="$TARGET_APP_NAME_COMMUNITY"
      TARGET_RUNTIME_EFFECTIVE="community"
      ;;
    locality)
      TARGET_MODULE_POM="$TARGET_MODULE_POM_LOCALITY"
      TARGET_JAR_GLOB="$TARGET_JAR_GLOB_LOCALITY"
      TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_LOCALITY"
      TARGET_APP_NAME="$TARGET_APP_NAME_LOCALITY"
      TARGET_RUNTIME_EFFECTIVE="locality"
      ;;
    spring)
      TARGET_MODULE_POM="$TARGET_MODULE_POM_SPRING"
      TARGET_JAR_GLOB="$TARGET_JAR_GLOB_SPRING"
      TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_SPRING"
      TARGET_APP_NAME="$TARGET_APP_NAME_SPRING"
      TARGET_RUNTIME_EFFECTIVE="spring"
      ;;
    spring-runtime-on-exeris)
      TARGET_MODULE_POM="$TARGET_MODULE_POM_SPRING_ON_EXERIS"
      TARGET_JAR_GLOB="$TARGET_JAR_GLOB_SPRING_ON_EXERIS"
      TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_SPRING_ON_EXERIS"
      TARGET_APP_NAME="$TARGET_APP_NAME_SPRING_ON_EXERIS"
      TARGET_RUNTIME_EFFECTIVE="spring-runtime-on-exeris"
      ;;
    quarkus)
      TARGET_MODULE_POM="$TARGET_MODULE_POM_QUARKUS"
      TARGET_JAR_GLOB="$TARGET_JAR_GLOB_QUARKUS"
      TARGET_NATIVE_BIN_GLOB="$TARGET_NATIVE_BIN_GLOB_QUARKUS"
      TARGET_APP_NAME="$TARGET_APP_NAME_QUARKUS"
      TARGET_RUNTIME_EFFECTIVE="quarkus"
      ;;
  esac
fi

if [[ "$TARGET_BUILD" == "native" ]] && [[ "$TARGET_RUNTIME_EFFECTIVE" == "locality" ]]; then
  echo "ERROR: --target-build native is not supported for effective runtime locality (targets/exeris-community-app-locality)"
  exit 1
fi
if [[ "$TARGET_BUILD" == "native" ]] && [[ "$TARGET_RUNTIME_EFFECTIVE" == "spring-runtime-on-exeris" ]]; then
  echo "ERROR: --target-build native is not supported for effective runtime spring-runtime-on-exeris (targets/exeris-spring-runtime-app-comp is JVM-only for entity-read-by-id)"
  exit 1
fi
if [[ "$TLS_ENABLED" == "1" ]] && [[ "$TARGET_RUNTIME_EFFECTIVE" == "spring-runtime-on-exeris" ]]; then
  # The compat target is H1-plaintext only: it does NOT honor EXERIS_SSL_ENABLED /
  # EXERIS_TRANSPORT_CERT_PATH (see targets/exeris-spring-runtime-app-comp/README.md
  # "Removed (no longer honored)"). With TLS on we would point an https client at an
  # http-only server and get connection failures that look like a target fault. Fail
  # closed rather than emit a confusing/invalid run.
  echo "ERROR: BENCHMARK_TLS_ENABLED=1 is not supported for spring-runtime-on-exeris (H1-plaintext only; the target ignores the TLS env). Unset BENCHMARK_TLS_ENABLED for this target."
  exit 1
fi
TARGET_PID_FILE="/tmp/${TARGET_APP_NAME}-benchmark.pid"

DURATION_SECONDS="${DURATION%s}"
WARMUP_SECONDS="${WARMUP%s}"

mkdir -p "$OUTPUT_DIR"
TARGET_APP_LOG="$OUTPUT_DIR/target-app.log"

resolve_db_launcher() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN="docker compose"
    DB_LAUNCH_MODE="compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_BIN="docker-compose"
    DB_LAUNCH_MODE="compose"
  elif command -v docker >/dev/null 2>&1; then
    DB_LAUNCH_MODE="docker-run"
  else
    echo "ERROR: Neither compose nor docker runtime is available"
    exit 1
  fi
}

compose_db() {
  # Layer the host-net override when host mode is requested (fairness gate). Applies
  # to every compose subcommand; harmless for non-up commands (same project/services).
  local _net_args=()
  if [[ "${BACKEND_NETWORK_MODE:-bridge}" == "host" && -f "$DB_COMPOSE_HOSTNET_OVERRIDE" ]]; then
    _net_args=( -f "$DB_COMPOSE_HOSTNET_OVERRIDE" )
  fi
  if [[ "$COMPOSE_BIN" == "docker compose" ]]; then
    docker compose -f "$DB_COMPOSE_FILE" "${_net_args[@]}" "$@"
  else
    docker-compose -f "$DB_COMPOSE_FILE" "${_net_args[@]}" "$@"
  fi
}

start_db() {
  if db_accepting_connections; then
    if [[ "$ALLOW_EXTERNAL_DB" == "1" ]]; then
      echo "[step 2/9] Reusing already-running local benchmark DB on localhost:$DB_PORT"
      DB_LAUNCH_MODE="external"
      DB_MANAGED=0
      return 0
    fi

    echo "[step 2/9] WARN: External DB detected on localhost:$DB_PORT but reuse is disabled (BENCHMARK_ALLOW_EXTERNAL_DB=0); launching managed DB for reproducibility"
  fi

  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    if [[ "$DB_PORT" == "5432" ]] && port_reachable 5432 && [[ "$ALLOW_EXTERNAL_DB" != "1" ]]; then
      DB_LAUNCH_MODE="docker-run"
      echo "[step 2/9] WARN: localhost:5432 is occupied and external DB reuse is disabled; switching from compose to docker-run fallback"
    fi
  fi

  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db up -d
    DB_MANAGED=1
  else
    # Network args for the docker-run fallback. Host mode binds 5432 directly on the
    # host (no -p, no port remap); if 5432 is occupied this fails loudly — which is
    # correct, host networking cannot share an occupied port.
    local _run_net_args=()
    if [[ "${BACKEND_NETWORK_MODE:-bridge}" == "host" ]]; then
      echo "[step 2/9] WARN: docker-run fallback with host networking (DB binds host:5432 directly)."
      _run_net_args=( --network host )
    else
      if [[ "$DB_PORT" == "5432" ]] && port_reachable 5432; then
        DB_PORT=55432
        echo "[step 2/9] WARN: localhost:5432 is occupied by a different service; using localhost:$DB_PORT"
      fi
      _run_net_args=( -p "$DB_PORT":5432 )
    fi
    echo "[step 2/9] WARN: Using docker-run fallback for managed benchmark DB"
    docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$DB_CONTAINER_NAME" \
      -e POSTGRES_DB=benchmark_db \
      -e POSTGRES_USER=benchmark \
      -e POSTGRES_PASSWORD=benchmark \
      "${_run_net_args[@]}" \
      --mount "type=bind,source=$DB_INIT_SQL_FILE,target=/docker-entrypoint-initdb.d/01-pg-stat-statements-init.sql,readonly" \
      --health-cmd 'pg_isready -U benchmark -d benchmark_db' \
      --health-interval 5s \
      --health-timeout 5s \
      --health-retries 10 \
      --tmpfs /var/lib/postgresql/data \
      postgres:16.2 \
      postgres -c max_connections=300 -c shared_buffers=256MB -c work_mem=8MB -c shared_preload_libraries=pg_stat_statements >/dev/null
    DB_MANAGED=1
  fi
}

db_accepting_connections() {
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD=benchmark psql -h localhost -p "$DB_PORT" -U benchmark -d benchmark_db -c 'SELECT 1' >/dev/null 2>&1
    return $?
  fi

  if [[ "$DB_LAUNCH_MODE" == "docker-run" ]] && docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    docker exec -e PGPASSWORD=benchmark "$DB_CONTAINER_NAME" psql -U benchmark -d benchmark_db -c 'SELECT 1' >/dev/null 2>&1
    return $?
  fi

  return 1
}

apply_seed_sql() {
  local seed_apply="$REPO_ROOT/runtime/db/seed/seed-apply.sh"

  if [[ "$DB_LAUNCH_MODE" == "docker-run" ]] && docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    DB_CONTAINER_NAME="$DB_CONTAINER_NAME" \
    PGUSER=benchmark PGDATABASE=benchmark_db PGPASSWORD=benchmark \
    bash "$seed_apply"
    return 0
  fi

  if command -v psql >/dev/null 2>&1; then
    PGHOST=localhost PGPORT="$DB_PORT" PGUSER=benchmark \
    PGDATABASE=benchmark_db PGPASSWORD=benchmark \
    bash "$seed_apply"
    return 0
  fi

  echo "ERROR: psql is required when benchmark DB is not managed by docker-run"
  return 1
}

query_seed_user_count() {
  if command -v psql >/dev/null 2>&1; then
    PGPASSWORD=benchmark psql -h localhost -p "$DB_PORT" -U benchmark -d benchmark_db -t -A -c "SELECT COUNT(*) FROM users"
    return 0
  fi

  if [[ "$DB_LAUNCH_MODE" == "docker-run" ]] && docker ps --format '{{.Names}}' | grep -Fxq "$DB_CONTAINER_NAME"; then
    docker exec -e PGPASSWORD=benchmark "$DB_CONTAINER_NAME" psql -U benchmark -d benchmark_db -t -A -c "SELECT COUNT(*) FROM users"
    return 0
  fi

  echo "ERROR: psql is required to verify seed user count when DB is external"
  return 1
}

verify_seed_fallback() {
  local manifest="$SCENARIO_DIR/seed/seed-manifest.json"
  local seed_file="$REPO_ROOT/runtime/db/seed/v1_core.sql"
  local expected_count expected_sha256 actual_sha256 actual_count

  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed"
    return 1
  fi

  expected_count=$(jq -r '.user_count // .entity_count' "$manifest")
  expected_sha256=$(jq -r '.seed_file_sha256' "$manifest")
  if [[ -n "$expected_sha256" && "$expected_sha256" != "skip" ]]; then
    actual_sha256=$(sha256sum "$seed_file" | awk '{print $1}')
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      echo "SEED FILE HASH MISMATCH: expected $expected_sha256 got $actual_sha256"
      return 1
    fi
  else
    echo "SEED FILE HASH CHECK: skipped (manifest seed_file_sha256=$expected_sha256)"
  fi

  actual_count=$(query_seed_user_count)
  if ! [[ "$actual_count" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not query user count. Output: $actual_count"
    return 1
  fi

  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "SEED USER COUNT MISMATCH: expected $expected_count, got $actual_count"
    return 1
  fi

  echo "SEED VERIFIED: users=$actual_count, hash OK, migration V1 (fallback)"
  return 0
}

is_db_healthy() {
  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db ps | grep -q "healthy"
  elif [[ "$DB_LAUNCH_MODE" == "external" ]]; then
    db_accepting_connections || port_reachable "$DB_PORT"
  else
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER_NAME" 2>/dev/null || true)" == "healthy" ]]
  fi
}

stop_db() {
  if [[ "$DB_MANAGED" -ne 1 ]]; then
    return 0
  fi

  if [[ "$DB_LAUNCH_MODE" == "compose" ]]; then
    compose_db down --remove-orphans >/dev/null 2>&1 || true
  else
    docker rm -f "$DB_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

target_reachable() {
  if curl -sf $CURL_INSECURE_OPT "$BASE_URL/health" >/dev/null 2>&1; then
    return 0
  fi
  if curl -sf $CURL_INSECURE_OPT "$BASE_URL/health/ready" >/dev/null 2>&1; then
    return 0
  fi
  if bench_port_reachable "$TARGET_PORT"; then
    return 0
  fi
  return 1
}

port_reachable() {
  local port="$1"
  if (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wait_for_target() {
  # Heavier targets (Spring Boot, Quarkus+Hibernate) under constrained CPU
  # (e.g. 0.5 vCPU) can take well over 60s to become reachable; allow override.
  local timeout="${ENTITY_READ_TARGET_READINESS_SECONDS:-60}"
  for _ in $(seq 1 "$timeout"); do
    if target_reachable; then
      return 0
    fi
    sleep 1
  done
  return 1
}

resolve_target_artifact() {
  TARGET_APP_JAR=""
  TARGET_APP_BIN=""

  if [[ "$TARGET_BUILD" == "jvm" ]]; then
    TARGET_APP_JAR=$(ls -1 $TARGET_JAR_GLOB 2>/dev/null | grep -Ev '(\\.original$|-sources\\.jar$|-javadoc\\.jar$)' | sort | tail -n 1 || true)
    [[ -n "$TARGET_APP_JAR" ]]
    return $?
  fi

  TARGET_APP_BIN=$(ls -1 $TARGET_NATIVE_BIN_GLOB 2>/dev/null | grep -Ev '(\\.txt$|\\.jar$|\\.original$)' | while IFS= read -r candidate; do
    if [[ -f "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
    fi
  done | sort | tail -n 1 || true)
  [[ -n "$TARGET_APP_BIN" ]]
}

stop_stale_local_target_if_any() {
  if [[ ! -f "$TARGET_PID_FILE" ]]; then
    return 0
  fi

  local stale_pid
  stale_pid="$(cat "$TARGET_PID_FILE" 2>/dev/null || true)"
  if [[ -z "$stale_pid" ]]; then
    rm -f "$TARGET_PID_FILE"
    return 0
  fi

  if kill -0 "$stale_pid" >/dev/null 2>&1; then
    echo "[step 6/9] WARN: Stopping stale local benchmark target process (pid=$stale_pid)"
    kill "$stale_pid" >/dev/null 2>&1 || true
    wait "$stale_pid" 2>/dev/null || true
  fi

  rm -f "$TARGET_PID_FILE"
}

verify_backend_mode_evidence() {
  local timeout=20
  local descriptor_token="Backend mode evidence: descriptorBackendMode=$BACKEND_MODE"
  local manifest_token="startupManifestBackendMode=$BACKEND_MODE"

  if [[ ! -f "$TARGET_APP_LOG" ]]; then
    echo "ERROR: Target log not found for backend mode evidence: $TARGET_APP_LOG"
    return 1
  fi

  for _ in $(seq 1 "$timeout"); do
    if grep -Fq "$descriptor_token" "$TARGET_APP_LOG" && grep -Fq "$manifest_token" "$TARGET_APP_LOG"; then
      echo "[step 6/9] Backend mode evidence verified: $BACKEND_MODE"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: backend mode evidence missing or mismatched after ${timeout}s (expected mode=$BACKEND_MODE)"
  echo "ERROR: expected tokens: '$descriptor_token' and '$manifest_token'"
  if [[ -f "$TARGET_APP_LOG" ]]; then
    echo "---- backend-mode evidence lines ----"
    grep -E "descriptorBackendMode=|startupManifestBackendMode=" "$TARGET_APP_LOG" || true
    echo "---- end backend-mode evidence lines ----"
  fi
  return 1
}

cleanup() {
  local exit_code=$?
  # Stop the target resource sampler first so an interrupted run never leaks an
  # orphaned sampler subshell polling a now-dead /proc/<pid>.
  if command -v bench_stop_resource_sampler >/dev/null 2>&1; then
    bench_stop_resource_sampler || true
  fi
  # Stop OS sidecars on any exit path (guarded: trap may fire before assignment).
  if [[ -n "${TARGET_PIDSTAT_PID:-}" ]]; then
    bench_stop_pidstat_sampler "$TARGET_PIDSTAT_PID" "${TARGET_PIDSTAT_CSV:-/dev/null}" 2>/dev/null || true
    TARGET_PIDSTAT_PID=""
  fi
  if [[ -n "${HOST_MPSTAT_PID:-}" ]]; then
    bench_stop_mpstat_sampler "$HOST_MPSTAT_PID" "${HOST_MPSTAT_CSV:-/dev/null}" 2>/dev/null || true
    HOST_MPSTAT_PID=""
  fi
  if [[ "$TARGET_APP_STARTED" -eq 1 ]] && [[ -n "$TARGET_APP_PID" ]] && kill -0 "$TARGET_APP_PID" >/dev/null 2>&1; then
    echo "[cleanup] Stopping benchmark target app (pid=$TARGET_APP_PID)..."
    kill "$TARGET_APP_PID" >/dev/null 2>&1 || true
    wait "$TARGET_APP_PID" 2>/dev/null || true
  fi
  rm -f "$TARGET_PID_FILE"
  echo "[cleanup] Stopping benchmark DB..."
  stop_db
  trap - EXIT
  exit "$exit_code"
}

resolve_db_launcher
trap cleanup EXIT

echo "[entity-read-by-id] claim_scope=$CLAIM_SCOPE profile=$PROFILE driver=$DRIVER transport=$TRANSPORT_MODE duration=$DURATION warmup=$WARMUP threads=$THREADS connections=$CONNECTIONS target_runtime=$TARGET_RUNTIME target_build=$TARGET_BUILD effective_runtime=$TARGET_RUNTIME_EFFECTIVE target_app=$TARGET_APP_NAME skip_target_build=$SKIP_TARGET_BUILD db_pool_min=$EXERIS_DB_POOL_MIN_SIZE db_pool_max=$EXERIS_DB_POOL_MAX_SIZE db_conn_timeout_ms=${EXERIS_DB_CONNECTION_TIMEOUT_MS:-<default>} output=$OUTPUT_DIR"

# Step 2: Start DB
echo "[step 2/9] Starting benchmark DB..."
start_db
echo "[step 2/9] Waiting for DB to be healthy..."
for i in $(seq 1 30); do
  if is_db_healthy; then
    break
  fi
  sleep 2
done

if ! is_db_healthy; then
  echo "ERROR: benchmark DB failed to become healthy"
  exit 1
fi

# Step 3: Apply seed
echo "[step 3/9] Applying seed..."
apply_seed_sql

# Step 4: Verify seed — abort on failure
echo "[step 4/9] Verifying seed..."
if command -v psql >/dev/null 2>&1; then
  PGPASSWORD=benchmark PGPORT="$DB_PORT" bash "$SCENARIO_DIR/seed/verify-seed.sh"
else
  verify_seed_fallback
fi

BENCH_SCENARIO_DIAGNOSTICS_DIR="$OUTPUT_DIR/db-diagnostics"
mkdir -p "$BENCH_SCENARIO_DIAGNOSTICS_DIR"
echo "[diag] Capturing PostgreSQL diagnostics..."
PGHOST="${PGHOST:-localhost}" \
PGPORT="$DB_PORT" \
PGDATABASE="${PGDATABASE:-benchmark_db}" \
PGUSER="${PGUSER:-benchmark}" \
PGPASSWORD="${PGPASSWORD:-benchmark}" \
BENCH_SCENARIO_DIAGNOSTICS_DIR="$BENCH_SCENARIO_DIAGNOSTICS_DIR" \
BENCH_CAPTURE_DB_EXPLAIN="${BENCH_CAPTURE_DB_EXPLAIN:-0}" \
bash "$CAPTURE_DB_DIAGNOSTICS_SCRIPT"

# Step 5: Capture env
echo "[step 5/9] Capturing environment..."
./scripts/capture-env.sh --profile "$PROFILE" --tool "$TOOL_NAME" > "$OUTPUT_DIR/env.json"

# Step 6: Warmup
echo "[step 6/9] Ensuring benchmark target app is available..."
if [[ "$ALLOW_EXTERNAL_TARGET" != "1" ]]; then
  stop_stale_local_target_if_any
  if bench_port_reachable "$TARGET_PORT"; then
    requested_target_port="$TARGET_PORT"
    TARGET_PORT="$(bench_find_available_local_port "$TARGET_PORT")"
    BASE_URL="${TARGET_SCHEME}://localhost:${TARGET_PORT}"
    echo "[step 6/9] WARN: localhost:$requested_target_port is occupied and external target reuse is disabled; using managed target on localhost:$TARGET_PORT"
  fi
fi

if target_reachable; then
  if [[ "$ALLOW_EXTERNAL_TARGET" != "1" ]]; then
    echo "ERROR: benchmark target already reachable at $BASE_URL and BENCHMARK_ALLOW_EXTERNAL_TARGET is not 1"
    echo "ERROR: external target is disallowed for backendMode integrity"
    exit 1
  fi
  if [[ "$BACKEND_EVIDENCE_REQUIRED" == "1" ]]; then
    echo "ERROR: external target reuse cannot satisfy mandatory backend mode evidence in this script path"
    echo "ERROR: set BENCHMARK_REQUIRE_BACKEND_EVIDENCE=0 to allow external target with warning-only evidence semantics"
    exit 1
  fi
  echo "[step 6/9] WARN: Reusing externally managed target at $BASE_URL (BENCHMARK_ALLOW_EXTERNAL_TARGET=1); backend mode evidence cannot be guaranteed"
fi

if ! target_reachable; then
  artifact_found=0
  if resolve_target_artifact; then
    artifact_found=1
  fi

  if [[ "$SKIP_TARGET_BUILD" == "1" ]]; then
    if [[ "$artifact_found" -ne 1 ]]; then
      echo "ERROR: BENCHMARK_SKIP_TARGET_BUILD=1 requires prebuilt target artifacts (runtime=$TARGET_RUNTIME_EFFECTIVE build=$TARGET_BUILD)"
      if [[ "$TARGET_BUILD" == "jvm" ]]; then
        echo "ERROR: prebuild command: mvn -f \"$TARGET_MODULE_POM\" -DskipTests package"
      else
        case "$TARGET_RUNTIME_EFFECTIVE" in
          community|spring)
            echo "ERROR: prebuild command: mvn -f \"$TARGET_MODULE_POM\" -Pnative -DskipTests native:compile"
            ;;
          quarkus)
            echo "ERROR: prebuild command: mvn -f \"$TARGET_MODULE_POM\" -Pnative -Dquarkus.native.enabled=true -DskipTests package"
            ;;
          *)
            echo "ERROR: unsupported effective runtime for native build: $TARGET_RUNTIME_EFFECTIVE"
            ;;
        esac
      fi
      exit 1
    fi
    if [[ "$TARGET_BUILD" == "jvm" ]]; then
      echo "[step 6/9] Using prebuilt benchmark target jar (BENCHMARK_SKIP_TARGET_BUILD=1): $TARGET_APP_JAR"
    else
      echo "[step 6/9] Using prebuilt benchmark target binary (BENCHMARK_SKIP_TARGET_BUILD=1): $TARGET_APP_BIN"
    fi
  else
    echo "[step 6/9] Building benchmark target app..."
    if [[ "$TARGET_BUILD" == "jvm" ]]; then
      mvn -f "$TARGET_MODULE_POM" -DskipTests package
    else
      # native-image needs multiple GB — it cannot build inside the constrained
      # cgroup scope. Refuse fast with the prebuild path instead of OOMing.
      if [[ "${BENCHMARK_CONSTRAINED_SCOPE_ACTIVE:-0}" == "1" ]]; then
        echo "ERROR: cannot build a native image inside the constrained cgroup scope (native-image needs GBs)." >&2
        echo "  Prebuild ONCE unconstrained, then re-run constrained (which will use the prebuilt binary):" >&2
        echo "    scripts/run-entity-read-by-id.sh --target-runtime $TARGET_RUNTIME_EFFECTIVE --target-build native --claim-scope exploratory --duration 1s   # builds + smoke" >&2
        echo "  or: GRAALVM auto-selected — mvn -f $TARGET_MODULE_POM -Pnative -DskipTests native:compile (with JAVA_HOME=a Java-matching GraalVM)." >&2
        exit 1
      fi
      # Required Java major for this target (drives GraalVM selection; preview
      # features need an exact-major GraalVM). Fall back to empty = accept any.
      APP_JAVA_MAJOR="$(grep -oE '<java\.version>[0-9]+' "$TARGET_MODULE_POM" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
      if [[ -z "$APP_JAVA_MAJOR" ]]; then
        APP_JAVA_MAJOR="$(grep -oE '<maven\.compiler\.release>[0-9]+' "$TARGET_MODULE_POM" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
      fi
      GRAALVM_BUILD_HOME="$(resolve_graalvm_home "$APP_JAVA_MAJOR" || true)"
      if [[ -z "$GRAALVM_BUILD_HOME" ]]; then
        echo "ERROR: --target-build native requires a GraalVM with native-image${APP_JAVA_MAJOR:+ for Java $APP_JAVA_MAJOR}, but none was found." >&2
        echo "  Checked: BENCHMARK_GRAALVM_HOME, GRAALVM_HOME, ~/.sdkman/candidates/java/*, native-image on PATH." >&2
        echo "  GraalVM installs detected:" >&2
        list_graalvm_candidates >&2 || true
        echo "  Fix: 'sdk install java <ver>-graal' matching Java ${APP_JAVA_MAJOR:-N}, or set BENCHMARK_GRAALVM_HOME=/path/to/graalvm." >&2
        exit 1
      fi
      echo "[step 6/9] native build using GraalVM: $GRAALVM_BUILD_HOME (Java $(graalvm_major "$GRAALVM_BUILD_HOME"))"
      # Scope GraalVM to the build only; clear JAVA_TOOL_OPTIONS so a constrained
      # run's -Xmx/-XX heap flags don't cripple the (memory-hungry) native-image
      # compile. The produced binary is self-contained and needs no JDK to run.
      case "$TARGET_RUNTIME_EFFECTIVE" in
        community|spring)
          env GRAALVM_HOME="$GRAALVM_BUILD_HOME" JAVA_HOME="$GRAALVM_BUILD_HOME" JAVA_TOOL_OPTIONS= \
            mvn -f "$TARGET_MODULE_POM" -Pnative -DskipTests native:compile
          ;;
        quarkus)
          env GRAALVM_HOME="$GRAALVM_BUILD_HOME" JAVA_HOME="$GRAALVM_BUILD_HOME" JAVA_TOOL_OPTIONS= \
            mvn -f "$TARGET_MODULE_POM" -Pnative -Dquarkus.native.enabled=true -DskipTests package
          ;;
        locality)
          echo "ERROR: --target-build native is not supported for effective runtime locality"
          exit 1
          ;;
        *)
          echo "ERROR: unsupported effective runtime for native build: $TARGET_RUNTIME_EFFECTIVE"
          exit 1
          ;;
      esac
    fi

    if ! resolve_target_artifact; then
      if [[ "$TARGET_BUILD" == "jvm" ]]; then
        echo "ERROR: benchmark target jar not found after build (glob: $TARGET_JAR_GLOB)"
      else
        echo "ERROR: benchmark target native binary not found/executable after build (glob: $TARGET_NATIVE_BIN_GLOB)"
      fi
      exit 1
    fi
  fi

  echo "[step 6/9] Starting benchmark target app..."
  TARGET_CMD=(env \
    EXERIS_PORT="$TARGET_PORT" \
    EXERIS_HTTP_PORT="$TARGET_PORT" \
    EXERIS_DB_JDBC_URL="jdbc:postgresql://localhost:$DB_PORT/benchmark_db" \
    EXERIS_DB_USERNAME=benchmark \
    EXERIS_DB_PASSWORD=benchmark \
    EXERIS_DB_POOL_MIN_SIZE="$EXERIS_DB_POOL_MIN_SIZE" \
    EXERIS_DB_POOL_MAX_SIZE="$EXERIS_DB_POOL_MAX_SIZE" \
    SPRING_DATASOURCE_URL="jdbc:postgresql://localhost:$DB_PORT/benchmark_db" \
    SPRING_DATASOURCE_USERNAME=benchmark \
    SPRING_DATASOURCE_PASSWORD=benchmark \
    SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE="$EXERIS_DB_POOL_MIN_SIZE" \
    SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE="$EXERIS_DB_POOL_MAX_SIZE" \
    QUARKUS_DATASOURCE_JDBC_MIN_SIZE="$EXERIS_DB_POOL_MIN_SIZE" \
    QUARKUS_DATASOURCE_JDBC_MAX_SIZE="$EXERIS_DB_POOL_MAX_SIZE")

  # TLS: when enabled, force the kernel/Spring TLS switches on the launched target.
  # The cert/key paths (EXERIS_TRANSPORT_CERT_PATH/KEY_PATH) are inherited from the
  # environment (the guided launcher provisions a smoke cert); warn if absent.
  if [[ "$TLS_ENABLED" == "1" ]]; then
    TARGET_CMD+=(
      EXERIS_SSL_ENABLED=true
      EXERIS_INSECURE_REQUESTS=disabled
      SERVER_SSL_ENABLED=true
      # Cross-stack fairness: pin the TLS 1.3 suite so every target negotiates the
      # same AES-128-GCM-SHA256 Exeris uses natively (the Quarkus target defaults to
      # the JDK's pick — AES-256 — which would pay more crypto CPU). Applied here on
      # the comparative path, not baked into the target's own config. Overridable.
      "EXERIS_TLS_CIPHER_SUITES=${EXERIS_TLS_CIPHER_SUITES:-TLS_AES_128_GCM_SHA256}"
    )
    if [[ -z "${EXERIS_TRANSPORT_CERT_PATH:-}" || ! -f "${EXERIS_TRANSPORT_CERT_PATH:-/nonexistent}" ]]; then
      echo "[step 6/9] WARN: BENCHMARK_TLS_ENABLED=1 but EXERIS_TRANSPORT_CERT_PATH is unset/missing; the HTTPS target may fail to start. Set EXERIS_TRANSPORT_CERT_PATH/KEY_PATH (or launch via run-guided.sh, which auto-provisions a smoke cert)."
    fi
  fi

  # HTTP/2 posture for the launched target — set ONLY for an h2 run. The Quarkus
  # and Spring targets default http2 OFF (quarkus.http.http2 / server.http2.enabled
  # = ${EXERIS_HTTP2_ENABLED:false}), so the HARNESS must enable h2 for an h2 run,
  # exactly as run-e2e-shop-order-saga-baseline.sh does — without it an h2 run
  # launches an H1-only server (over TLS it omits h2 from ALPN -> silent fallback;
  # over cleartext it rejects the h2c preface).
  #
  # For h1 we deliberately set NOTHING here and let every target keep its defaults:
  # Quarkus/Spring default http2 off (pure H1), and the Exeris kernel defaults
  # maxVersion=HTTP_2 / h2cUpgrade=true and serves H1 to an H1 client. Forcing
  # EXERIS_HTTP_MAX_VERSION=HTTP_1_1 here previously broke the kernel's H1+TLS path
  # (regression) — never override the kernel's HTTP version on the H1 baseline.
  if [[ "$PROTOCOL" == "h2" ]]; then
    TARGET_CMD+=(
      EXERIS_HTTP2_ENABLED=true
      SERVER_HTTP2_ENABLED=true
      EXERIS_HTTP_MAX_VERSION=HTTP_2
    )
    if [[ "$TLS_ENABLED" == "1" ]]; then
      TARGET_CMD+=(EXERIS_HTTP_H2C_UPGRADE_ENABLED=false)
    else
      TARGET_CMD+=(EXERIS_HTTP_H2C_UPGRADE_ENABLED=true)
    fi
  fi

  # Optional connection-acquisition timeout. Mapped per target family in the
  # native unit each expects: Exeris/Hikari take milliseconds; Quarkus Agroal
  # takes a Duration, so convert ms -> ISO-8601 (e.g. 5000 -> PT5S). Only appended
  # when explicitly set, so unconstrained runs keep framework defaults.
  if [[ -n "${EXERIS_DB_CONNECTION_TIMEOUT_MS:-}" ]]; then
    # LC_ALL=C so the decimal separator is a dot, not a locale comma (PT2.5S, not PT2,5S).
    QUARKUS_ACQ_TIMEOUT="$(LC_ALL=C awk -v ms="$EXERIS_DB_CONNECTION_TIMEOUT_MS" 'BEGIN { printf "PT%gS", ms / 1000 }')"
    TARGET_CMD+=(
      "EXERIS_DB_CONNECTION_TIMEOUT_MS=$EXERIS_DB_CONNECTION_TIMEOUT_MS"
      "SPRING_DATASOURCE_HIKARI_CONNECTION_TIMEOUT=$EXERIS_DB_CONNECTION_TIMEOUT_MS"
      "QUARKUS_DATASOURCE_JDBC_ACQUISITION_TIMEOUT=$QUARKUS_ACQ_TIMEOUT"
    )
  fi

  if [[ "$TARGET_BUILD" == "jvm" ]]; then
    TARGET_CMD+=(java)
    # exeris-spring-runtime-app-comp embeds the Exeris kernel in-process (web/tx/
    # data/flow), whose classes are compiled with preview features and need native
    # access + module opens — exactly like the standalone community/locality targets.
    # Without these the JVM refuses to load the kernel ("Preview features are not
    # enabled"). The plain Tomcat "spring" runtime does NOT need them. Same flag set
    # as community here (entity-read defaults to the pgq graph backend, so the
    # Neo4j-only jdk.internal.module open used on the saga path is not required).
    if [[ "$TARGET_RUNTIME_EFFECTIVE" == "community" || "$TARGET_RUNTIME_EFFECTIVE" == "locality" || "$TARGET_RUNTIME_EFFECTIVE" == "spring-runtime-on-exeris" ]]; then
      TARGET_CMD+=(--add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --enable-native-access=ALL-UNNAMED)
      TARGET_CMD+=(--enable-preview)
    fi
    if [[ "$TARGET_RUNTIME_EFFECTIVE" == "community" || "$TARGET_RUNTIME_EFFECTIVE" == "locality" ]]; then
      TARGET_CMD+=(-Dexeris.backend.mode="$BACKEND_MODE")
      TARGET_CMD+=(-Dexeris.backend.mode.strict="$BENCHMARK_LOCALITY_STRICT")
    fi
    TARGET_CMD+=(-jar "$TARGET_APP_JAR")
  else
    TARGET_CMD+=("$TARGET_APP_BIN")
    if [[ "$TARGET_RUNTIME_EFFECTIVE" == "community" ]]; then
      TARGET_CMD+=(-Dexeris.backend.mode="$BACKEND_MODE")
      TARGET_CMD+=(-Dexeris.backend.mode.strict="$BENCHMARK_LOCALITY_STRICT")
    fi
  fi

  if [[ -n "$CPU_AFFINITY" ]]; then
    echo "[step 6/9] Applying CPU affinity via taskset: $CPU_AFFINITY"
    TARGET_CMD=(taskset -c "$CPU_AFFINITY" "${TARGET_CMD[@]}")
  fi

  "${TARGET_CMD[@]}" > "$TARGET_APP_LOG" 2>&1 &
  TARGET_APP_PID=$!
  echo "$TARGET_APP_PID" > "$TARGET_PID_FILE"
  TARGET_APP_STARTED=1
fi

echo "[step 6/9] Waiting for target readiness (<=${ENTITY_READ_TARGET_READINESS_SECONDS:-60}s)..."
if ! wait_for_target; then
  echo "ERROR: benchmark target app failed readiness check within ${ENTITY_READ_TARGET_READINESS_SECONDS:-60}s"
  if [[ -f "$TARGET_APP_LOG" ]]; then
    echo "---- target-app.log (tail) ----"
    tail -n 60 "$TARGET_APP_LOG" || true
    echo "---- end target-app.log ----"
  fi
  exit 1
fi

PREFLIGHT_BODY_FILE="$OUTPUT_DIR/preflight-users-aggregate.json"
preflight_ok=0
preflight_deadline=$(( SECONDS + ENTITY_READ_PREFLIGHT_READY_SECONDS ))
preflight_attempts=0
while :; do
  preflight_attempts=$(( preflight_attempts + 1 ))
  if bench_run_endpoint_preflight "$BASE_URL/api/v1/users" "$PREFLIGHT_BODY_FILE" "$ENTITY_READ_PREFLIGHT_TIMEOUT"; then
    preflight_ok=1
    break
  fi
  if (( SECONDS >= preflight_deadline )); then
    break
  fi
  # Endpoint reachable but not serving 200 yet (data path still warming) — retry.
  sleep 1
done
if [[ "$preflight_ok" -ne 1 ]]; then
  echo "[step 6/9] Endpoint preflight status: $BENCH_PREFLIGHT_HTTP_CODE (after ${preflight_attempts} attempt(s) over ${ENTITY_READ_PREFLIGHT_READY_SECONDS}s)"
  echo "ERROR: endpoint preflight failed for $BASE_URL/api/v1/users (status=$BENCH_PREFLIGHT_HTTP_CODE)"
  echo "ERROR: preflight response body saved at $PREFLIGHT_BODY_FILE"
  exit 1
fi
echo "[step 6/9] Endpoint preflight status: $BENCH_PREFLIGHT_HTTP_CODE (ready after ${preflight_attempts} attempt(s))"

echo "[step 6/9] Payload preflight preview (/api/v1/users):"
bench_print_preflight_payload_preview "$PREFLIGHT_BODY_FILE" 512

if [[ "$TARGET_APP_STARTED" -eq 1 && "$BACKEND_EVIDENCE_REQUIRED" == "1" ]]; then
  verify_backend_mode_evidence
elif [[ "$TARGET_APP_STARTED" -eq 0 && "$BACKEND_EVIDENCE_REQUIRED" == "1" ]]; then
  echo "ERROR: backend mode evidence is mandatory but no local target was started; no local log evidence is available"
  exit 1
fi

# Optional JFR recording of the target during warmup+measurement (jcmd-based;
# only meaningful when this runner manages a local JVM target).
JFR_FILE=""
if [[ "$ENABLE_JFR" == "true" ]]; then
  if ! command -v bench_start_jfr_recording >/dev/null 2>&1; then
    echo "WARN: --enable-jfr requested but jfr lib not available; skipping JFR"
    ENABLE_JFR="false"
  elif [[ "$TARGET_APP_STARTED" -ne 1 || -z "$TARGET_APP_PID" ]]; then
    echo "WARN: --enable-jfr requested but no locally-managed target (external/native?); skipping JFR"
    ENABLE_JFR="false"
  else
    JFR_LOGS_DIR="$OUTPUT_DIR/logs"
    mkdir -p "$JFR_LOGS_DIR"
    JFR_FILE="$OUTPUT_DIR/target-entity-read-by-id-$(date -u +%Y%m%dT%H%M%SZ).jfr"
    echo "[step 6/9] Starting JFR recording (settings=$JFR_SETTINGS) on target pid=$TARGET_APP_PID"
    bench_start_jfr_recording "$TARGET_APP_PID" "$JFR_LOGS_DIR" "entity-read-by-id" "$JFR_SETTINGS" || true
  fi
fi

# h2load transport flags for the resolved axis (empty for wrk). --h1 forces
# cleartext HTTP/1.1 with one request per connection (-m 1) to mirror wrk H1;
# h2c uses HTTP/2 prior-knowledge with -m <streams>.
H2LOAD_FLAGS=()
if [[ "$DRIVER" == "h2load" ]]; then
  if [[ "$H2LOAD_AXIS" == "h1" ]]; then
    H2LOAD_FLAGS=(--h1 -m 1)
  else
    H2LOAD_FLAGS=(-m "$H2LOAD_H2C_MAX_CONCURRENT_STREAMS")
  fi
fi

echo "[step 6/9] Warmup ($WARMUP, driver=$DRIVER)..."
if [[ "$DRIVER" == "h2load" ]]; then
  h2load "${H2LOAD_FLAGS[@]}" -c "$CONNECTIONS" -t "$THREADS" -D "$WARMUP_SECONDS" "$BASE_URL/api/v1/users" > /dev/null 2>&1 || true
else
  wrk -t "$THREADS" -c "$CONNECTIONS" -d "$WARMUP" --script "$SCENARIO_DIR/wrk.lua" "$BASE_URL/api/v1/users" > /dev/null || true
fi

# Step 6.5: Reset pg_stat_statements counters before measurement
PG_STAT_STATEMENTS_WRAPPER_SCRIPT="$SCENARIO_DIR/pg_stat_statements-wrapper.sh"
if [[ -f "$PG_STAT_STATEMENTS_WRAPPER_SCRIPT" ]]; then
  source "$PG_STAT_STATEMENTS_WRAPPER_SCRIPT"
  echo "[step 6.5/9] Resetting pg_stat_statements counters before measurement..."
  pg_stat_statements_reset || true
fi

# Step 6.6: Start target resource sampler (target-side CPU/RSS/threads + JVM heap/
# NMT breakdown). Started here — after warmup, immediately before measurement — so
# the summarized cpu_time/RSS reflect the measurement window only, not warmup. This
# is what lets unconstrained runs express results per resource (rps/effective-core,
# rps/MB-RSS) and be compared across stacks (community/spring/quarkus).
RESOURCE_SAMPLES_CSV="$OUTPUT_DIR/resource-samples.csv"
RESOURCE_METRICS_JSON="$OUTPUT_DIR/resource-metrics.json"
RESOURCE_TARGET_PID=""
if command -v bench_start_resource_sampler >/dev/null 2>&1; then
  if [[ "$TARGET_APP_STARTED" -eq 1 && -n "$TARGET_APP_PID" ]]; then
    RESOURCE_TARGET_PID="$TARGET_APP_PID"
  else
    # External/reused target: no managed PID, so resolve it from the listening port.
    RESOURCE_TARGET_PID="$(bench_detect_pid_for_port "$TARGET_PORT" 2>/dev/null || true)"
  fi
  if [[ -n "$RESOURCE_TARGET_PID" && -d "/proc/$RESOURCE_TARGET_PID" ]]; then
    echo "[step 6.6/9] Starting target resource sampler for pid=$RESOURCE_TARGET_PID"
    bench_start_resource_sampler "$RESOURCE_TARGET_PID" "$RESOURCE_SAMPLES_CSV"
  else
    echo "[step 6.6/9] WARN: target pid not resolved (external/native?); resource-metrics.json will record pid-undetected"
    RESOURCE_TARGET_PID=""
  fi
fi

# OS-level sidecars (opt-in via BENCH_OS_SIDECARS=1, default OFF). entity-read is a
# cross-stack comparison, so per-thread %wait (C2 starvation) and per-CPU %sys/%soft
# (network/softirq burn) matter here too. See tools/bench/lib/os-sampler.sh.
OS_SIDECARS_LOGS_DIR="$OUTPUT_DIR/logs"
TARGET_PIDSTAT_CSV="$OS_SIDECARS_LOGS_DIR/target-pidstat.csv"
HOST_MPSTAT_CSV="$OS_SIDECARS_LOGS_DIR/host-mpstat.csv"
TARGET_PIDSTAT_PID=""
HOST_MPSTAT_PID=""
if [[ "${BENCH_OS_SIDECARS:-0}" == "1" ]] && command -v bench_start_pidstat_sampler >/dev/null 2>&1; then
  mkdir -p "$OS_SIDECARS_LOGS_DIR"
  if [[ -n "$RESOURCE_TARGET_PID" ]]; then
    TARGET_PIDSTAT_PID="$(bench_start_pidstat_sampler "$RESOURCE_TARGET_PID" "$TARGET_PIDSTAT_CSV" 1)"
    [[ -n "$TARGET_PIDSTAT_PID" ]] && echo "[step 6.6/9] pidstat sidecar → $TARGET_PIDSTAT_CSV"
  fi
  HOST_MPSTAT_PID="$(bench_start_mpstat_sampler "$HOST_MPSTAT_CSV" 1)"
  [[ -n "$HOST_MPSTAT_PID" ]] && echo "[step 6.6/9] mpstat sidecar → $HOST_MPSTAT_CSV"
fi

# Step 7: Measure
echo "[step 7/9] Measuring ($DURATION)..."
PERF_STAT_FILE="$OUTPUT_DIR/perf-stat.csv"
if [[ "$DRIVER" == "wrk2" ]]; then
  # wrk2 path: the target is already up + seeded (above); DELEGATE the measurement
  # to run-wrk2.sh (saturation-discovery -> warmup -> wrk2 fixed -R, HdrHistogram).
  # JFR + OS sidecars (started around this section) wrap the whole delegated run, so
  # they cover discovery+warmup+measure, not just the measurement window. perf-stat
  # is not wired for the delegated path. WRK2_TARGET_RPS (env) pins the rate; else
  # run-wrk2.sh auto-derives ~75% of observed saturation.
  WRK2_LATENCY_JSON="$OUTPUT_DIR/wrk2-latency.json"
  WRK2_RAW_FILE="${WRK2_LATENCY_JSON%.json}.raw.txt"
  echo "[step 7/9] Delegating CO-free latency measurement to run-wrk2.sh (HTTP/1.1, sub-saturation)"
  set +e
  LOAD_OUT=$(
    WRK_BASE_URL_OVERRIDE="$BASE_URL" \
    WRK_PATH_OVERRIDE="/api/v1/users" \
    WRK2_THREADS_OVERRIDE="$THREADS" \
    WRK2_CONNECTIONS_OVERRIDE="$CONNECTIONS" \
    WRK2_DURATION_OVERRIDE="$DURATION" \
    WRK2_CLIENT_CPU_AFFINITY="$CLIENT_CPU_AFFINITY" \
    WRK2_RESULT_JSON_OVERRIDE="$WRK2_LATENCY_JSON" \
    WRK2_TARGET_RPS="${WRK2_TARGET_RPS:-}" \
    HARDWARE_PROFILE="$PROFILE" \
    "$REPO_ROOT/scripts/run-wrk2.sh" "scenarios/entity-read-by-id" "scenarios/entity-read-by-id" 2>&1
  )
  WRK2_EXIT_CODE=$?
  set -e
  echo "$LOAD_OUT"
  if [[ "$WRK2_EXIT_CODE" -ne 0 || ! -f "$WRK2_LATENCY_JSON" ]]; then
    echo "ERROR: delegated wrk2 measurement failed (exit=$WRK2_EXIT_CODE); see output above."
    exit 1
  fi
else
  if [[ "$DRIVER" == "h2load" ]]; then
    # --log-file captures per-request timings (start_us, status, dur_us) for the
    # MEASUREMENT run only (the warmup h2load above is not logged), so the latency
    # percentiles h2load itself omits can be computed offline. See
    # tools/aggregate-h2load-latency.sh (closed-loop / coordinated-omission caveat).
    H2LOAD_LOG_FILE="$OUTPUT_DIR/h2load-requests.log"
    LOAD_CMD=(h2load "${H2LOAD_FLAGS[@]}" -c "$CONNECTIONS" -t "$THREADS" -D "$DURATION_SECONDS" --log-file="$H2LOAD_LOG_FILE" "$BASE_URL/api/v1/users")
  else
    LOAD_CMD=(wrk -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" --script "$SCENARIO_DIR/wrk.lua" --latency "$BASE_URL/api/v1/users")
  fi

  # Pin the load driver to a cpuset disjoint from the target (--cpu-affinity) so the driver does not
  # steal the target's cores. Wrapping LOAD_CMD covers both the perf-stat and plain execution paths.
  if [[ -n "$CLIENT_CPU_AFFINITY" ]]; then
    echo "[step 7/9] Pinning load driver via taskset: $CLIENT_CPU_AFFINITY (keep disjoint from target $CPU_AFFINITY)"
    LOAD_CMD=(taskset -c "$CLIENT_CPU_AFFINITY" "${LOAD_CMD[@]}")
  fi

  if [[ "$PERF_STAT_REQUIRED" == "1" || "${BENCHMARK_CAPTURE_PERF_STAT:-0}" == "1" ]]; then
    if ! command -v perf >/dev/null 2>&1; then
      echo "ERROR: perf-stat capture requested but perf command is unavailable"
      exit 1
    fi
    PERF_NO_SCALE="${BENCHMARK_PERF_NO_SCALE:-1}"
    if [[ "$PERF_NO_SCALE" != "0" && "$PERF_NO_SCALE" != "1" ]]; then
      echo "ERROR: BENCHMARK_PERF_NO_SCALE must be 0 or 1 (got '$PERF_NO_SCALE')"
      exit 1
    fi
    PERF_ARGS=(-x, -o "$PERF_STAT_FILE")
    if [[ "$PERF_NO_SCALE" == "1" ]]; then
      if perf stat --help 2>&1 | grep -q -- '--no-scale'; then
        PERF_ARGS=(--no-scale "${PERF_ARGS[@]}")
      else
        echo "WARN: perf --no-scale not supported by this perf version; running perf stat with scaling enabled"
      fi
    fi
    echo "[step 7/9] Capturing perf stat to $PERF_STAT_FILE"
    set +e
    LOAD_OUT=$(perf stat "${PERF_ARGS[@]}" -- "${LOAD_CMD[@]}" 2>&1)
    PERF_EXIT_CODE=$?
    set -e
    if [[ "$PERF_EXIT_CODE" -ne 0 ]]; then
      PERF_ERROR_LOG="$OUTPUT_DIR/perf-error.log"
      printf '%s\n' "$LOAD_OUT" > "$PERF_ERROR_LOG"
      echo "ERROR: perf stat execution failed (exit_code=$PERF_EXIT_CODE)"
      echo "ERROR: perf diagnostics saved to $PERF_ERROR_LOG"
      echo "$LOAD_OUT"
      exit "$PERF_EXIT_CODE"
    fi
  else
    LOAD_OUT=$("${LOAD_CMD[@]}" 2>&1)
  fi
  echo "$LOAD_OUT"
fi

# Persist the driver's raw output as a first-class run artifact, the same way the
# target's stdout is kept in target-app.log. The parsed result.json is a lossy
# projection of this; the raw log is the ground truth for what the load client
# (and which HTTP version/axis) actually did — needed for honest reproducibility.
# Extract the TLS negotiation h2load prints (ground truth for what the wire did).
# Empty for cleartext / for drivers that don't report it (wrk/wrk2).
TLS_PROTOCOL="$(printf '%s\n' "$LOAD_OUT" | sed -n 's/^TLS Protocol:[[:space:]]*//p' | head -1)"
TLS_CIPHER="$(printf '%s\n' "$LOAD_OUT" | sed -n 's/^Cipher:[[:space:]]*//p' | head -1)"
TLS_ALPN="$(printf '%s\n' "$LOAD_OUT" | sed -n 's/^Application protocol:[[:space:]]*//p' | head -1)"

if [[ -n "${OUTPUT_DIR:-}" ]]; then
  DRIVER_LOG="$OUTPUT_DIR/driver-${DRIVER}.log"
  {
    printf '# driver: %s  protocol: %s  transport: %s  tls: %s' \
      "$DRIVER" "${PROTOCOL:-?}" "${TRANSPORT_MODE:-?}" \
      "$([[ "$TLS_ENABLED" == "1" ]] && echo on || echo off)"
    [[ "$DRIVER" == "h2load" ]] && printf '  h2load-axis: %s' "${H2LOAD_AXIS_LABEL:-${H2LOAD_AXIS:-?}}"
    [[ -n "$TLS_PROTOCOL" ]] && printf '  negotiated: %s/%s/%s' "$TLS_PROTOCOL" "${TLS_ALPN:-?}" "$TLS_CIPHER"
    printf '\n# command: %s\n\n' "${LOAD_CMD[*]}"
    printf '%s\n' "$LOAD_OUT"
  } > "$DRIVER_LOG" 2>/dev/null \
    && echo "[entity-read-by-id] driver raw output saved: $DRIVER_LOG" \
    || echo "WARN: could not write driver log to $DRIVER_LOG" >&2
fi

# Honesty guard (defense in depth): when h2load runs over TLS it negotiates the
# HTTP version via ALPN and SILENTLY falls back to HTTP/1.1 if the server omits h2.
# If we asked for HTTP/2 but h2 did not negotiate, the measured traffic was H1 —
# fail rather than record an H1 run under an H2 (PROTOCOL=h2) label.
if [[ "$DRIVER" == "h2load" && "$PROTOCOL" == "h2" ]]; then
  # (1) Negative signal: an explicit ALPN fallback to HTTP/1.1 (covers the TLS path).
  if printf '%s\n' "$LOAD_OUT" | grep -Eq 'Server does not support ALPN|Falling back to HTTP/1\.1|No protocol negotiated'; then
    echo "ERROR: h2load requested HTTP/2 but the server did not negotiate h2 (ALPN fallback to HTTP/1.1 detected in the driver output)." >&2
    echo "ERROR: the measured traffic ran HTTP/1.1, so it cannot be labeled HTTP/2 ('$BASE_URL' served TLS without advertising h2 via ALPN)." >&2
    echo "ERROR: this target does not speak HTTP/2 over TLS; use a cleartext h2c endpoint (TLS off) against an h2c-capable target. Raw driver output: ${DRIVER_LOG:-<unsaved>}" >&2
    exit 1
  fi
  # (2) Positive signal (TLS only): require h2load to report it negotiated h2 via
  # ALPN. This fails closed even if a future nghttp2 reworded the fallback notice
  # above — absence of the positive marker is treated as not-h2. Cleartext h2c uses
  # prior-knowledge (no ALPN, no "Application protocol" line), so assert under TLS only.
  if [[ "$TLS_ENABLED" == "1" ]] \
     && ! printf '%s\n' "$LOAD_OUT" | grep -Eiq 'Application protocol:[[:space:]]*h2([[:space:]]|$)'; then
    echo "ERROR: h2load requested HTTP/2 over TLS but did not report 'Application protocol: h2' (ALPN did not confirm h2)." >&2
    echo "ERROR: refusing to label the run HTTP/2 without positive h2 negotiation evidence. Raw driver output: ${DRIVER_LOG:-<unsaved>}" >&2
    exit 1
  fi
fi

# Stop the resource sampler the moment measurement ends, so the sampled window is
# exactly the measurement window (summarize/augment happen below while the target
# is still alive, before cleanup tears it down).
if command -v bench_stop_resource_sampler >/dev/null 2>&1; then
  bench_stop_resource_sampler || true
fi
# Stop OS sidecars at the same boundary (converts raw tool output to CSV; no-op if
# not started).
if [[ -n "${TARGET_PIDSTAT_PID:-}" ]]; then
  bench_stop_pidstat_sampler "$TARGET_PIDSTAT_PID" "$TARGET_PIDSTAT_CSV"; TARGET_PIDSTAT_PID=""
fi
if [[ -n "${HOST_MPSTAT_PID:-}" ]]; then
  bench_stop_mpstat_sampler "$HOST_MPSTAT_PID" "$HOST_MPSTAT_CSV"; HOST_MPSTAT_PID=""
fi

# Fail loudly if the target died during measurement or no requests completed: a
# crashed/unreachable target must NOT be written out as a successful result.
if [[ "$TARGET_APP_STARTED" -eq 1 && -n "$TARGET_APP_PID" ]] && ! kill -0 "$TARGET_APP_PID" 2>/dev/null; then
  echo "ERROR: benchmark target (pid=$TARGET_APP_PID) died during measurement — run is INVALID (not a result)."
  echo "ERROR: inspect $TARGET_APP_LOG and any hs_err_pid*.log / core dump in $REPO_ROOT."
  [[ "$ENABLE_JFR" == "true" ]] && echo "NOTE: JFR was enabled. A SIGSEGV in JfrStorage::flush_regular_buffer from a virtual-thread frame is NOT a JDK flake — it means a custom JFR event was held (begin -> blocking op -> commit) across a virtual-thread unmount, flushing a stale carrier-bound buffer (reproducible on JDK 26 GA 26+35). --no-jfr is only a workaround to keep the run going, NOT a diagnosis. Fix is kernel-side: emit such events single-phase, after the blocking op. Check the target frame in hs_err_pid*.log (e.g. fixed for ConnectionAcquireEvent)."
  exit 1
fi
if [[ "$DRIVER" == "h2load" ]]; then
  # h2load: "requests: N total, N started, N done, ..."
  _LOAD_COMPLETED_REQUESTS="$(printf '%s\n' "$LOAD_OUT" | sed -nE 's/^requests:[[:space:]]*[0-9]+ total,[[:space:]]*[0-9]+ started,[[:space:]]*([0-9]+) done.*/\1/p' | head -1)"
else
  # wrk: "N requests in 2.00m, ..."
  _LOAD_COMPLETED_REQUESTS="$(printf '%s\n' "$LOAD_OUT" | sed -nE 's/^[[:space:]]*([0-9]+) requests in .*/\1/p' | head -1)"
fi
if [[ -n "$_LOAD_COMPLETED_REQUESTS" && "$_LOAD_COMPLETED_REQUESTS" -eq 0 ]]; then
  echo "ERROR: measurement completed 0 requests (target unreachable or crashed) — run is INVALID (not a result)."
  echo "ERROR: inspect $TARGET_APP_LOG (socket errors above indicate the target was not serving)."
  exit 1
fi

# Summarize target resource samples (and, for a live JVM, augment with heap/NMT
# breakdown via jcmd) while the target is still alive — cleanup kills it on exit.
if command -v bench_summarize_resource_samples >/dev/null 2>&1 && [[ -f "$RESOURCE_SAMPLES_CSV" ]]; then
  echo "[step 7.5/9] Summarizing target resource usage -> $RESOURCE_METRICS_JSON"
  bench_summarize_resource_samples "$RESOURCE_SAMPLES_CSV" "$RESOURCE_METRICS_JSON" || true
  if [[ -f "$RESOURCE_METRICS_JSON" ]]; then
    if [[ -n "$RESOURCE_TARGET_PID" && -d "/proc/$RESOURCE_TARGET_PID" ]] \
       && command -v bench_augment_resource_metrics_with_jvm_breakdown >/dev/null 2>&1; then
      bench_augment_resource_metrics_with_jvm_breakdown "$RESOURCE_TARGET_PID" "$RESOURCE_METRICS_JSON" || true
    elif command -v jq >/dev/null 2>&1; then
      # Native image / external target / undetected pid: no jcmd surface for a heap
      # breakdown — record the reason so the sidecar is unambiguous, not silently bare.
      tmp_rm="$(mktemp)"
      if jq '. + {jvm_breakdown_note: "jcmd heap/NMT breakdown unavailable (native image, external target, or pid undetected)"}' \
           "$RESOURCE_METRICS_JSON" > "$tmp_rm" 2>/dev/null; then
        mv "$tmp_rm" "$RESOURCE_METRICS_JSON"
      else
        rm -f "$tmp_rm"
      fi
    fi
  fi
fi

# Dump + stop JFR while the target is still alive (before cleanup kills it).
if [[ "$ENABLE_JFR" == "true" && -n "$JFR_FILE" ]]; then
  echo "[step 7/9] Dumping JFR recording to $JFR_FILE"
  bench_capture_jfr_metadata "$TARGET_APP_PID" "$JFR_LOGS_DIR" "$JFR_FILE" || true
  if [[ -f "$JFR_FILE" ]]; then
    echo "[step 7/9] JFR recording saved: $JFR_FILE ($(du -h "$JFR_FILE" 2>/dev/null | cut -f1))"
  else
    echo "WARN: JFR dump did not produce a file (see $JFR_LOGS_DIR/jfr-*.json)"
  fi
fi

# Capture post-measurement pg_stat_statements snapshot
if [[ -f "$PG_STAT_STATEMENTS_WRAPPER_SCRIPT" ]]; then
  PG_STAT_STATEMENTS_POST_FILE="$BENCH_SCENARIO_DIAGNOSTICS_DIR/pg_stat_statements-post-measurement.json"
  echo "[step 7.5/9] Capturing pg_stat_statements post-measurement snapshot..."
  pg_stat_statements_snapshot "$PG_STAT_STATEMENTS_POST_FILE" "measurement" || true
fi

if [[ "$DRIVER" == "wrk2" ]]; then
  # Metrics from the delegated run-wrk2.sh artifacts: rps + CO-free HdrHistogram
  # percentiles from the JSON; request/error counts from the measurement raw (run-wrk2
  # tees ONLY the wrk2 measurement there, so discovery/warmup do not contaminate them).
  THROUGHPUT_RPS=$(jq -r '.requests_per_sec // empty' "$WRK2_LATENCY_JSON" 2>/dev/null)
  _wrk2_pct() { jq -r --arg p "$1" '(.latency_percentiles[]? | select(.percentile==$p) | .latency_us) // empty' "$WRK2_LATENCY_JSON" 2>/dev/null | head -1; }
  LATENCY_P50_US=$(_wrk2_pct p50)
  LATENCY_P75_US=$(_wrk2_pct p75)
  LATENCY_P90_US=$(_wrk2_pct p90)
  LATENCY_P99_US=$(_wrk2_pct p99)
  LATENCY_P999_US=$(_wrk2_pct p99.9)
  LATENCY_MEAN_US=""   # wrk2 JSON exposes percentiles, not mean/stdev/max
  LATENCY_STDEV_US=""
  LATENCY_MAX_US=""
  TOTAL_REQUESTS=""
  NON2XX_ERRORS=0
  SOCKET_ERRORS=0
  if [[ -f "$WRK2_RAW_FILE" ]]; then
    TOTAL_REQUESTS=$(awk '/requests in/ {gsub(/,/,"",$1); print $1; exit}' "$WRK2_RAW_FILE")
    _n2=$(awk '/Non-2xx or 3xx responses:/ {print $5; exit}' "$WRK2_RAW_FILE"); [[ -n "$_n2" ]] && NON2XX_ERRORS=$_n2
    _se=$(awk -F'[:, ]+' '/Socket errors:/ {print ($4 + $6 + $8 + $10); exit}' "$WRK2_RAW_FILE"); [[ -n "$_se" ]] && SOCKET_ERRORS=$_se
  fi
  TOTAL_ERRORS=$((NON2XX_ERRORS + SOCKET_ERRORS))
  echo "[step 7/9] wrk2 latency: $WRK2_LATENCY_JSON (p50=${LATENCY_P50_US:-na}us p99=${LATENCY_P99_US:-na}us p99.9=${LATENCY_P999_US:-na}us; CO-free sub-saturation — check load_fraction/at_saturation in the JSON)"
elif [[ "$DRIVER" == "h2load" ]]; then
  # h2load summary:
  #   finished in 120.05s, 3328.80 req/s, 29.21MB/s
  #   requests: N total, N started, N done, N succeeded, N failed, N errored, N timeout
  #   status codes: N 2xx, N 3xx, N 4xx, N 5xx
  #   <hdr> min max mean sd +/- sd
  #   time for request:  <min> <max> <mean> <sd> <+/-sd>
  # h2load's own summary has NO percentiles; we recover p50/p75/p90/p99/p999 from
  # the --log-file via tools/aggregate-h2load-latency.sh (closed-loop CO caveat
  # recorded in the sidecar). If the log/aggregator is unavailable they stay null.
  THROUGHPUT_RPS=$(sed -nE 's/.*finished in [0-9.]+(m|ms|s|us|h), ([0-9.]+) req\/s,.*/\2/p' <<<"$LOAD_OUT" | head -1)
  H2_TFR_LINE=$(printf '%s\n' "$LOAD_OUT" | awk '/time for request:/ {print; exit}')
  LATENCY_MEAN_US=$(to_us "$(awk '{print $6}' <<<"$H2_TFR_LINE")")
  LATENCY_MAX_US=$(to_us "$(awk '{print $5}' <<<"$H2_TFR_LINE")")
  LATENCY_STDEV_US=$(to_us "$(awk '{print $7}' <<<"$H2_TFR_LINE")")
  LATENCY_P50_US=""
  LATENCY_P75_US=""
  LATENCY_P90_US=""
  LATENCY_P99_US=""
  LATENCY_P999_US=""
  # Offline percentiles from the per-request log. Never fatal; emits valid JSON.
  if [[ -n "${H2LOAD_LOG_FILE:-}" && -f "$H2LOAD_LOG_FILE" ]]; then
    H2LOAD_LATENCY_JSON="$OUTPUT_DIR/h2load-latency.json"
    if "$REPO_ROOT/tools/aggregate-h2load-latency.sh" "$H2LOAD_LOG_FILE" "$H2LOAD_LATENCY_JSON" 2>/dev/null; then
      LATENCY_P50_US=$(jq -r '.latency_p50_us // empty' "$H2LOAD_LATENCY_JSON" 2>/dev/null)
      LATENCY_P75_US=$(jq -r '.latency_p75_us // empty' "$H2LOAD_LATENCY_JSON" 2>/dev/null)
      LATENCY_P90_US=$(jq -r '.latency_p90_us // empty' "$H2LOAD_LATENCY_JSON" 2>/dev/null)
      LATENCY_P99_US=$(jq -r '.latency_p99_us // empty' "$H2LOAD_LATENCY_JSON" 2>/dev/null)
      LATENCY_P999_US=$(jq -r '.latency_p999_us // empty' "$H2LOAD_LATENCY_JSON" 2>/dev/null)
      echo "[step 7/9] h2load latency percentiles: $H2LOAD_LATENCY_JSON (p50=${LATENCY_P50_US:-na}us p99=${LATENCY_P99_US:-na}us, closed-loop/CO caveat applies)"
    fi
  fi
  H2_REQ_LINE=$(printf '%s\n' "$LOAD_OUT" | awk '/^requests:/ {print; exit}')
  TOTAL_REQUESTS=$(sed -nE 's/^requests:[[:space:]]*([0-9]+) total.*/\1/p' <<<"$H2_REQ_LINE")
  H2_FAILED=$(sed -nE 's/.*[, ]([0-9]+) failed,.*/\1/p' <<<"$H2_REQ_LINE")
  H2_ERRORED=$(sed -nE 's/.*[, ]([0-9]+) errored,.*/\1/p' <<<"$H2_REQ_LINE")
  H2_TIMEOUT=$(sed -nE 's/.*[, ]([0-9]+) timeout.*/\1/p' <<<"$H2_REQ_LINE")
  H2_STATUS_LINE=$(printf '%s\n' "$LOAD_OUT" | awk '/^status codes:/ {print; exit}')
  H2_4XX=$(sed -nE 's/.*[, ]([0-9]+) 4xx.*/\1/p' <<<"$H2_STATUS_LINE")
  H2_5XX=$(sed -nE 's/.*[, ]([0-9]+) 5xx.*/\1/p' <<<"$H2_STATUS_LINE")
  for _v in H2_FAILED H2_ERRORED H2_TIMEOUT H2_4XX H2_5XX; do
    [[ -z "${!_v}" ]] && printf -v "$_v" '%s' 0
  done
  # Transport/protocol failures plus non-success status codes, mirroring wrk's
  # Non-2xx + socket-error accounting.
  TOTAL_ERRORS=$((H2_FAILED + H2_ERRORED + H2_TIMEOUT + H2_4XX + H2_5XX))
else
  THROUGHPUT_RPS=$(awk '/Requests\/sec:/ {print $2; exit}' <<<"$LOAD_OUT")
  LATENCY_STATS_LINE=$(printf '%s\n' "$LOAD_OUT" | awk '/Thread Stats/{in_stats=1;next} in_stats && /^[[:space:]]*Latency[[:space:]]/ {print; exit}')
  LATENCY_MEAN_US=$(to_us "$(awk '{print $2}' <<<"$LATENCY_STATS_LINE")")
  LATENCY_STDEV_US=$(to_us "$(awk '{print $3}' <<<"$LATENCY_STATS_LINE")")
  LATENCY_MAX_US=$(to_us "$(awk '{print $4}' <<<"$LATENCY_STATS_LINE")")
  LATENCY_P50_US=$(to_us "$(awk '$1 == "50%" {print $2; exit}' <<<"$LOAD_OUT")")
  LATENCY_P75_US=$(to_us "$(awk '$1 == "75%" {print $2; exit}' <<<"$LOAD_OUT")")
  LATENCY_P90_US=$(to_us "$(awk '$1 == "90%" {print $2; exit}' <<<"$LOAD_OUT")")
  LATENCY_P99_US=$(to_us "$(awk '$1 == "99%" {print $2; exit}' <<<"$LOAD_OUT")")
  LATENCY_P999_US=""   # wrk --latency reports 50/75/90/99 only; p99.9 needs wrk2 (run-wrk2.sh)
  TOTAL_REQUESTS=$(awk '/requests in/ {gsub(/,/, "", $1); print $1; exit}' <<<"$LOAD_OUT")
  NON2XX_ERRORS=$(awk '/Non-2xx or 3xx responses:/ {print $5; exit}' <<<"$LOAD_OUT")
  SOCKET_ERRORS=$(awk -F'[:, ]+' '/Socket errors:/ {print ($4 + $6 + $8 + $10); exit}' <<<"$LOAD_OUT")

  if [[ -z "$NON2XX_ERRORS" ]]; then
    NON2XX_ERRORS=0
  fi
  if [[ -z "$SOCKET_ERRORS" ]]; then
    SOCKET_ERRORS=0
  fi

  TOTAL_ERRORS=$((NON2XX_ERRORS + SOCKET_ERRORS))
fi
ERROR_RATE_PCT=$(LC_ALL=C awk -v errors="$TOTAL_ERRORS" -v total="${TOTAL_REQUESTS:-0}" 'BEGIN {
  if (total > 0) {
    printf "%.6f", (errors * 100.0) / total
  } else {
    printf "0.000000"
  }
}')

RUN_CONFIG_JSON=$(jq -n \
  --argjson duration_seconds "$DURATION_SECONDS" \
  --argjson warmup_seconds "$WARMUP_SECONDS" \
  --argjson threads "$THREADS" \
  --argjson connections "$CONNECTIONS" \
  --arg backend_network_mode "${BACKEND_NETWORK_MODE:-bridge}" \
  '{
    duration_seconds: $duration_seconds,
    warmup_seconds: $warmup_seconds,
    threads: $threads,
    connections: $connections,
    backend_network_mode: $backend_network_mode
  }')

METRICS_JSON=$(jq -n \
  --arg throughput_rps "$THROUGHPUT_RPS" \
  --arg latency_mean_us "$LATENCY_MEAN_US" \
  --arg latency_stdev_us "$LATENCY_STDEV_US" \
  --arg latency_max_us "$LATENCY_MAX_US" \
  --arg latency_p50_us "$LATENCY_P50_US" \
  --arg latency_p75_us "$LATENCY_P75_US" \
  --arg latency_p90_us "$LATENCY_P90_US" \
  --arg latency_p99_us "$LATENCY_P99_US" \
  --arg latency_p999_us "$LATENCY_P999_US" \
  --arg total_requests "$TOTAL_REQUESTS" \
  --arg total_errors "$TOTAL_ERRORS" \
  --arg error_rate_pct "$ERROR_RATE_PCT" \
  '
  def num_or_null($v):
    if ($v == null) then null
    else (($v|tostring|gsub(",";".")|gsub("^[[:space:]]+|[[:space:]]+$";"")) as $t
      | if $t=="" then null else (($t|tonumber?) // null) end)
    end;

  {
    throughput_rps: num_or_null($throughput_rps),
    latency_mean_us: num_or_null($latency_mean_us),
    latency_stdev_us: num_or_null($latency_stdev_us),
    latency_max_us: num_or_null($latency_max_us),
    latency_p50_us: num_or_null($latency_p50_us),
    latency_p75_us: num_or_null($latency_p75_us),
    latency_p90_us: num_or_null($latency_p90_us),
    latency_p99_us: num_or_null($latency_p99_us),
    latency_p999_us: num_or_null($latency_p999_us),
    total_requests: num_or_null($total_requests),
    total_errors: num_or_null($total_errors),
    error_rate_pct: num_or_null($error_rate_pct)
  }
  # Drop unmeasured metrics (e.g. h2load has no latency percentiles) rather than
  # emitting null: the schema types these as number, so null would fail and a
  # faked 0 would lie. Absent = honestly not measured by this driver.
  | with_entries(select(.value != null))')

# Step 8: Write result artifact
echo "[step 8/9] Writing result artifact..."
RESULT_FILE="$OUTPUT_DIR/result.json"
COMMIT_SHA=$(git -C . rev-parse HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_ID="entity-read-by-id-$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Map claim_scope to schema enum value
case "$CLAIM_SCOPE" in
  exploratory)          RESULT_CLAIM_SCOPE="exploratory" ;;
  comparison-eligible)  RESULT_CLAIM_SCOPE="comparison_eligible" ;;
  *)                    RESULT_CLAIM_SCOPE="descriptive_only" ;;
esac

# Map execution_class for reproducibility axis labels.
case "$CLAIM_SCOPE" in
  comparison-eligible) EXECUTION_CLASS="guard" ;;
  exploratory)         EXECUTION_CLASS="exploratory" ;;
  *)                   EXECUTION_CLASS="exploratory" ;;
esac

# TLS provenance: record whether TLS was on and what the wire actually negotiated
# (from the h2load output). Provider is the target's choice and not asserted here.
if [[ "$TLS_ENABLED" == "1" ]]; then
  TLS_JSON=$(jq -n --arg p "$TLS_PROTOCOL" --arg c "$TLS_CIPHER" --arg a "$TLS_ALPN" \
    '{enabled:true}
     + (if $p!="" then {protocol:$p} else {} end)
     + (if $c!="" then {cipher:$c} else {} end)
     + (if $a!="" then {alpn:$a} else {} end)')
else
  TLS_JSON='{"enabled":false}'
fi

cat > "$RESULT_FILE" <<EOF
{
  "schema_version": "1",
  "run_id": "$RUN_ID",
  "timestamp": "$TIMESTAMP",
  "scenario": "entity-read-by-id",
  "tool": "$TOOL_NAME",
  "env_ref": "$OUTPUT_DIR/env.json",
  "claim_scope": "$RESULT_CLAIM_SCOPE",
  "execution_class": "$EXECUTION_CLASS",
  "comparison_axis": "within-tier",
  "runner_status": "success",
  "reproducibility_status": "complete",
  "final_reason": "ok",
  "transport_mode": "$TRANSPORT_MODE",
  "tls": $TLS_JSON,
  "target": {
    "repo": "exeris-benchmarks",
    "version": "$TARGET_APP_NAME",
    "tier": "community",
    "mode": "baseline-db",
    "protocol": "$PROTOCOL",
    "commit_sha": "$COMMIT_SHA"
  },
  "seed_ref": {
    "manifest_version": "1",
    "scenario_id": "entity-read-by-id",
    "schema_migration_version": "V1",
    "entity_count": 1000,
    "verified": true
  },
  "run_config": $RUN_CONFIG_JSON,
  "metrics": $METRICS_JSON,
  "notes": "backendMode=$BACKEND_MODE targetRuntimeEffective=$TARGET_RUNTIME_EFFECTIVE targetBuild=$TARGET_BUILD cpuAffinity=${CPU_AFFINITY:-none} clientCpuAffinity=${CLIENT_CPU_AFFINITY:-none}",
  "tags": ["backend-mode:$BACKEND_MODE", "target-runtime-effective:$TARGET_RUNTIME_EFFECTIVE", "target-build:$TARGET_BUILD"],
  "raw_output": $(echo "$LOAD_OUT" | jq -Rs .)
}
EOF

REPRO_FILE="$OUTPUT_DIR/reproducibility-metadata.json"
STEADY_STATE_FILE="$OUTPUT_DIR/steady-state-evidence.json"
TOOL_VERSION_LINE="$("$TOOL_NAME" --version 2>&1 | head -1 || true)"
if [[ -z "$TOOL_VERSION_LINE" ]]; then
  TOOL_VERSION_LINE="unknown"
fi

if [[ -f "$OUTPUT_DIR/env.json" ]]; then
  JDK_VENDOR="$(jq -r '.jdk.vendor // "unknown"' "$OUTPUT_DIR/env.json")"
  JDK_VERSION="$(jq -r '.jdk.version // "unknown"' "$OUTPUT_DIR/env.json")"
  HARDWARE_PROFILE_REF="$(jq -r '.hardware_profile // "unknown"' "$OUTPUT_DIR/env.json")"
  JVM_FLAGS_JSON="$(jq -c '.jvm_flags // []' "$OUTPUT_DIR/env.json")"
  # hardware_profile does not pin the kernel/scheduler; surface both into repro metadata.
  KERNEL_VERSION="$(jq -r '.kernel // "unknown"' "$OUTPUT_DIR/env.json")"
  OS_SCHEDULER="$(jq -r '.os_scheduler // "unknown"' "$OUTPUT_DIR/env.json")"
else
  JDK_VENDOR="unknown"
  JDK_VERSION="unknown"
  HARDWARE_PROFILE_REF="$PROFILE"
  JVM_FLAGS_JSON="[]"
  KERNEL_VERSION="unknown"
  OS_SCHEDULER="unknown"
fi

jq -n \
  --arg timestamp "$TIMESTAMP" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg scenario_id "entity-read-by-id" \
  --arg scenario_classification "runtime-baseline-db-read-path" \
  --arg contract "${CONTRACT_NAME:-none}" \
  --arg jdk_vendor "$JDK_VENDOR" \
  --arg jdk_version "$JDK_VERSION" \
  --arg hardware_profile_ref "$HARDWARE_PROFILE_REF" \
  --arg kernel_version "${KERNEL_VERSION:-unknown}" \
  --arg os_scheduler "${OS_SCHEDULER:-unknown}" \
  --arg tool "$TOOL_NAME" \
  --arg tool_version "$TOOL_VERSION_LINE" \
  --arg tier "community" \
  --arg protocol_mode "$PROTOCOL" \
  --arg benchmark_family "$BENCHMARK_FAMILY" \
  --arg transport_mode "$TRANSPORT_MODE" \
  --arg execution_class "$EXECUTION_CLASS" \
  --arg comparison_axis "within-tier" \
  --arg claim_scope "$RESULT_CLAIM_SCOPE" \
  --arg mode "baseline-db" \
  --arg wiring_model "backend-mode:$BACKEND_MODE target-runtime-effective:$TARGET_RUNTIME_EFFECTIVE target-build:$TARGET_BUILD" \
  --arg seed_manifest_ref "$SCENARIO_DIR/seed/seed-manifest.json" \
  --arg seed_manifest_version "1" \
  --argjson jvm_flags "$JVM_FLAGS_JSON" \
  --argjson threads "$THREADS" \
  --argjson connections "$CONNECTIONS" \
  --argjson warmup_seconds "$WARMUP_SECONDS" \
  --argjson duration_seconds "$DURATION_SECONDS" \
  --arg backend_network_mode "${BACKEND_NETWORK_MODE:-bridge}" \
  '{
    timestamp: $timestamp,
    benchmark_commit_sha: $commit_sha,
    target_commit_sha: $commit_sha,
    scenario_id: $scenario_id,
    scenario_classification: $scenario_classification,
    contract: $contract,
    jdk: {
      vendor: $jdk_vendor,
      version: $jdk_version
    },
    jvm_flags: $jvm_flags,
    hardware_profile_ref: $hardware_profile_ref,
    kernel_version: $kernel_version,
    os_scheduler: $os_scheduler,
    tool: {
      name: $tool,
      version: $tool_version
    },
    axis_labels: {
      tier: $tier,
      protocol_mode: $protocol_mode,
      benchmark_family: $benchmark_family,
      transport_mode: $transport_mode,
      execution_class: $execution_class,
      comparison_axis: $comparison_axis,
      claim_scope: $claim_scope
    },
    mode: $mode,
    wiring_model: $wiring_model,
    run_config: {
      threads: $threads,
      connections: $connections,
      warmup_seconds: $warmup_seconds,
      duration_seconds: $duration_seconds,
      backend_network_mode: $backend_network_mode
    },
    seed_manifest_refs: {
      manifest_ref: $seed_manifest_ref,
      manifest_version: $seed_manifest_version
    }
  }' > "$REPRO_FILE"

jq -n \
  --arg throughput_rps "${THROUGHPUT_RPS:-}" \
  --arg latency_mean_us "${LATENCY_MEAN_US:-}" \
  --arg latency_p99_us "${LATENCY_P99_US:-}" \
  --arg duration_seconds "$DURATION_SECONDS" \
  --arg warmup_seconds "$WARMUP_SECONDS" \
  --arg note "Window-level evidence derived from measured run window only; warmup is excluded from metric aggregation." \
  '
  def num_or_null($v):
    if ($v == null) then null
    else (($v|tostring|gsub(",";".")|gsub("^[[:space:]]+|[[:space:]]+$";"")) as $t
      | if $t=="" then null else (($t|tonumber?) // null) end)
    end;

  {
    throughput_rps: num_or_null($throughput_rps),
    latency_mean_us: num_or_null($latency_mean_us),
    latency_p99_us: num_or_null($latency_p99_us),
    duration_seconds: num_or_null($duration_seconds),
    warmup_seconds: num_or_null($warmup_seconds),
    note: $note
  }' > "$STEADY_STATE_FILE"

echo "[step 9/9] Validating result artifact against schema..."
SCHEMA_FILE="schemas/benchmark-result.schema.json"
if command -v check-jsonschema >/dev/null 2>&1; then
  check-jsonschema --schemafile "$SCHEMA_FILE" "$RESULT_FILE" \
    && echo "[step 9/9] Schema validation PASSED" \
    || { echo "ERROR: result artifact failed schema validation — see above"; exit 1; }
elif command -v ajv >/dev/null 2>&1; then
  ajv validate -s "$SCHEMA_FILE" -d "$RESULT_FILE" \
    && echo "[step 9/9] Schema validation PASSED" \
    || { echo "ERROR: result artifact failed schema validation"; exit 1; }
elif command -v python3 >/dev/null 2>&1; then
  set +e
  python3 - "$SCHEMA_FILE" "$RESULT_FILE" <<'PY'
import json
import sys

schema_path = sys.argv[1]
data_path = sys.argv[2]

try:
    import jsonschema
except Exception:
    print("ERROR: python3 fallback requires the 'jsonschema' module (install via: python3 -m pip install jsonschema)", file=sys.stderr)
    sys.exit(2)

with open(schema_path, "r", encoding="utf-8") as f:
    schema = json.load(f)

with open(data_path, "r", encoding="utf-8") as f:
    data = json.load(f)

try:
    jsonschema.validate(instance=data, schema=schema)
except jsonschema.exceptions.ValidationError as e:
    instance_path = ".".join(str(p) for p in e.path) if e.path else "$"
    schema_path_str = ".".join(str(p) for p in e.schema_path) if e.schema_path else "$"
    print(f"ERROR: Schema validation failed: {e.message}", file=sys.stderr)
    print(f"  instance path: {instance_path}", file=sys.stderr)
    print(f"  schema path: {schema_path_str}", file=sys.stderr)
    sys.exit(1)

print("Schema validation PASSED (python3+jsonschema)")
sys.exit(0)
PY
  PYTHON_SCHEMA_RC=$?
  set -e

  case "$PYTHON_SCHEMA_RC" in
    0)
      echo "[step 9/9] Schema validation PASSED"
      ;;
    1)
      echo "ERROR: result artifact failed schema validation"
      exit 1
      ;;
    2)
      echo "ERROR: python3 fallback unavailable because the 'jsonschema' module is not installed"
      exit 1
      ;;
    *)
      echo "ERROR: python3 schema validation failed with unexpected exit code: $PYTHON_SCHEMA_RC"
      exit 1
      ;;
  esac
else
  echo "ERROR: No schema validator available. Tried in order: check-jsonschema, ajv, python3+jsonschema"
  exit 1
fi

if [[ -f "$RESOURCE_METRICS_JSON" ]]; then
  echo "Target resource usage (measurement window): $RESOURCE_METRICS_JSON"
fi
echo "Done. claim_scope=$CLAIM_SCOPE -> $RESULT_CLAIM_SCOPE | results in $OUTPUT_DIR"
echo "Done. claim_scope=$CLAIM_SCOPE -- results in $OUTPUT_DIR"
