#!/usr/bin/env bash
# run-tls-matrix.sh - Execute TLS matrix IDs with scoped MUST/SHOULD/STRETCH behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/.." && pwd)"

SCOPE="must"
PROFILE="dev-laptop"
OUTPUT_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/run-tls-matrix.sh [--scope must|should|stretch] [--profile <name>] [--output-dir <path>]

Options:
  --scope       Execution scope. Default: must
  --profile     Hardware profile passed to capture-env. Default: dev-laptop
  --output-dir  Optional output directory. Default: results/raw/tls-matrix/<timestamp>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="${2:-}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SCOPE" != "must" && "$SCOPE" != "should" && "$SCOPE" != "stretch" ]]; then
  echo "ERROR: --scope must be one of: must, should, stretch" >&2
  exit 2
fi

BENCH_REPO="$ROOT"
KERNEL_REPO="$WORKSPACE_ROOT/exeris-kernel"
ENTERPRISE_REPO="$WORKSPACE_ROOT/exeris-kernel-enterprise"
SPRING_REPO="$WORKSPACE_ROOT/exeris-spring-runtime"

for repo in "$BENCH_REPO" "$KERNEL_REPO" "$ENTERPRISE_REPO" "$SPRING_REPO"; do
  if [[ ! -d "$repo" ]]; then
    echo "ERROR: required repository directory not found: $repo" >&2
    exit 1
  fi
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUT_DIR="$ROOT/results/raw/tls-matrix/$TIMESTAMP"
else
  case "$OUTPUT_DIR" in
    /*) OUT_DIR="$OUTPUT_DIR" ;;
    *) OUT_DIR="$ROOT/$OUTPUT_DIR" ;;
  esac
fi

LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"

ENV_FILE="$OUT_DIR/env.json"
METADATA_FILE="$OUT_DIR/metadata.json"
STATUS_FILE="$OUT_DIR/status.csv"
COMMANDS_LOG="$OUT_DIR/commands.log"

BENCH_SHA="$(git -C "$BENCH_REPO" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
KERNEL_SHA="$(git -C "$KERNEL_REPO" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
ENTERPRISE_SHA="$(git -C "$ENTERPRISE_REPO" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
SPRING_SHA="$(git -C "$SPRING_REPO" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"

JAVA_VERSION="$(java -version 2>&1 | head -n 1 || echo UNKNOWN)"
MAVEN_VERSION="$(mvn -v 2>/dev/null | head -n 1 || echo UNKNOWN)"
JVM_FLAGS="${JVM_FLAGS:-}"

"$ROOT/scripts/capture-env.sh" --profile "$PROFILE" > "$ENV_FILE"

jq -n \
  --arg schema_version "1" \
  --arg run_id "tls-matrix-$TIMESTAMP" \
  --arg timestamp "$TIMESTAMP" \
  --arg scope "$SCOPE" \
  --arg profile "$PROFILE" \
  --arg bench_sha "$BENCH_SHA" \
  --arg kernel_sha "$KERNEL_SHA" \
  --arg enterprise_sha "$ENTERPRISE_SHA" \
  --arg spring_sha "$SPRING_SHA" \
  --arg java_version "$JAVA_VERSION" \
  --arg maven_version "$MAVEN_VERSION" \
  --arg jvm_flags "$JVM_FLAGS" \
  --arg env_file "env.json" \
  '{
    schema_version: $schema_version,
    run_id: $run_id,
    timestamp: $timestamp,
    scope: $scope,
    hardware_profile: $profile,
    repositories: {
      "exeris-benchmarks": $bench_sha,
      "exeris-kernel": $kernel_sha,
      "exeris-kernel-enterprise": $enterprise_sha,
      "exeris-spring-runtime": $spring_sha
    },
    tools: {
      java: $java_version,
      maven: $maven_version
    },
    jvm_flags: $jvm_flags,
    labels: {
      required: ["tier", "protocol_mode", "benchmark_family", "comparison_axis"]
    },
    output: {
      env_file: $env_file,
      status_file: "status.csv",
      logs_dir: "logs"
    }
  }' > "$METADATA_FILE"

# CSV with explicit labels: tier, protocol mode, benchmark family, comparison axis.
printf "matrix_id,priority,tier,protocol_mode,benchmark_family,comparison_axis,target_classification,status,reason,command,log_file\n" > "$STATUS_FILE"
: > "$COMMANDS_LOG"

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

append_status() {
  local matrix_id="$1"
  local priority="$2"
  local tier="$3"
  local protocol_mode="$4"
  local benchmark_family="$5"
  local comparison_axis="$6"
  local target_classification="$7"
  local status="$8"
  local reason="$9"
  local command="${10}"
  local log_file="${11}"

  {
    csv_escape "$matrix_id"; printf ","
    csv_escape "$priority"; printf ","
    csv_escape "$tier"; printf ","
    csv_escape "$protocol_mode"; printf ","
    csv_escape "$benchmark_family"; printf ","
    csv_escape "$comparison_axis"; printf ","
    csv_escape "$target_classification"; printf ","
    csv_escape "$status"; printf ","
    csv_escape "$reason"; printf ","
    csv_escape "$command"; printf ","
    csv_escape "$log_file"
    printf "\n"
  } >> "$STATUS_FILE"
}

run_step() {
  local matrix_id="$1"
  local priority="$2"
  local tier="$3"
  local protocol_mode="$4"
  local benchmark_family="$5"
  local comparison_axis="$6"
  local target_classification="$7"
  local cwd="$8"
  local command="$9"

  local log_file="$LOG_DIR/$matrix_id.log"
  echo "[$matrix_id] $command" >> "$COMMANDS_LOG"

  if (cd "$cwd" && bash -lc "set -euo pipefail; $command") > "$log_file" 2>&1; then
    append_status "$matrix_id" "$priority" "$tier" "$protocol_mode" "$benchmark_family" "$comparison_axis" "$target_classification" "COMPLETED" "ok" "$command" "logs/$matrix_id.log"
    return 0
  fi

  if [[ "$priority" == "MUST" ]]; then
    append_status "$matrix_id" "$priority" "$tier" "$protocol_mode" "$benchmark_family" "$comparison_axis" "$target_classification" "FAILED" "MUST step failed" "$command" "logs/$matrix_id.log"
    echo "ERROR: MUST step failed: $matrix_id (see $log_file)" >&2
    exit 1
  fi

  append_status "$matrix_id" "$priority" "$tier" "$protocol_mode" "$benchmark_family" "$comparison_axis" "$target_classification" "FAILED_NON_BLOCKING" "SHOULD/STRETCH step failed" "$command" "logs/$matrix_id.log"
  echo "WARN: non-MUST step failed: $matrix_id (see $log_file)" >&2
}

record_missing() {
  local matrix_id="$1"
  local priority="$2"
  local tier="$3"
  local protocol_mode="$4"
  local benchmark_family="$5"
  local comparison_axis="$6"
  local target_classification="$7"
  local reason="$8"

  append_status "$matrix_id" "$priority" "$tier" "$protocol_mode" "$benchmark_family" "$comparison_axis" "$target_classification" "SKIPPED_MISSING_IMPLEMENTATION" "$reason" "N/A" "N/A"
}

record_scope_skip() {
  local matrix_id="$1"
  local priority="$2"
  local tier="$3"
  local protocol_mode="$4"
  local benchmark_family="$5"
  local comparison_axis="$6"
  local target_classification="$7"
  local reason="$8"

  append_status "$matrix_id" "$priority" "$tier" "$protocol_mode" "$benchmark_family" "$comparison_axis" "$target_classification" "SKIPPED_SCOPE" "$reason" "N/A" "N/A"
}

run_should=false
run_stretch=false
if [[ "$SCOPE" == "should" ]]; then
  run_should=true
fi
if [[ "$SCOPE" == "stretch" ]]; then
  run_should=true
  run_stretch=true
fi

# -----------------------------------------------------------------------
# JFR profiler support.
# Set JFR_PROF=1 (or export before invoking) to enable JFR capture:
#   - micro/jmh steps (B3, B4): attach -prof jfr via JMH profiler.
#   - Maven benchmark and test/IT steps (B1, B2, B5, C4, D1, D5, D2): receive
#     -Dbenchmark.jvmArgs=-XX:StartFlightRecording=... via Maven property.
#   - A1/A2 manage their own JFR lifecycle and recordings are copied from
#     target/jfr-reports into jfr/<ID>/ after the Maven test step succeeds.
# -----------------------------------------------------------------------
JFR_PROF="${JFR_PROF:-0}"
JFR_DIR="$OUT_DIR/jfr"
if [[ "$JFR_PROF" == "1" ]]; then
  mkdir -p "$JFR_DIR"
  echo "JFR profiling enabled: recordings will be written to $JFR_DIR"
fi

# jfr_post_copy_args <id> <repo> <module>: copy test-managed JFR files after success when JFR_PROF=1.
jfr_post_copy_args() {
  local id="$1"
  local repo="$2"
  local module="$3"
  if [[ "$JFR_PROF" == "1" ]]; then
    mkdir -p "$JFR_DIR/$id"
    printf ' && find %q/%q/target/jfr-reports -type f -name %q -exec cp -f {} %q \;' \
      "$repo" "$module" '*.jfr' "$JFR_DIR/$id/"
  fi
}

# jfr_maven_args <id>: emit -Dbenchmark.jvmArgs JFR flag for Maven benchmark and test/IT steps when JFR_PROF=1.
jfr_maven_args() {
  local id="$1"
  if [[ "$JFR_PROF" == "1" ]]; then
    mkdir -p "$JFR_DIR/$id"
    printf ' -Dbenchmark.jvmArgs=-XX:StartFlightRecording=filename=%s/%s/%s.jfr,settings=profile,dumponexit=true' \
      "$JFR_DIR" "$id" "$id"
  fi
}

# -----------------------------------------------------------------------
# micro/jmh uber-jar: built once and reused for B3 and B4.
# -----------------------------------------------------------------------
MICRO_JMH_DIR="$BENCH_REPO/micro/jmh"
MICRO_JMH_JAR="$MICRO_JMH_DIR/target/benchmarks.jar"

build_micro_jmh() {
  echo "[micro/jmh] Building benchmark uber-jar..."
  local log="$LOG_DIR/micro-jmh-build.log"
  if ! (cd "$MICRO_JMH_DIR" && mvn clean package -DskipTests -q) > "$log" 2>&1; then
    echo "ERROR: micro/jmh build failed (see $log)" >&2
    return 1
  fi
  echo "[micro/jmh] Build complete: $MICRO_JMH_JAR"
}

# run_micro_step wraps run_step for micro/jmh uber-jar invocations.
# Usage: run_micro_step <matrix_id> <priority> <tier> <protocol> <family> <axis> <target> <bench_pattern> [extra_jmh_args...]
run_micro_step() {
  local matrix_id="$1"
  local priority="$2"
  local tier="$3"
  local protocol_mode="$4"
  local benchmark_family="$5"
  local comparison_axis="$6"
  local target_classification="$7"
  local bench_pattern="$8"
  shift 8
  local extra_args=("$@")

  local jfr_args=""
  if [[ "$JFR_PROF" == "1" ]]; then
    mkdir -p "$JFR_DIR/$matrix_id"
    jfr_args="-prof jfr:stackDepth=64;dir=$JFR_DIR/$matrix_id"
  fi

  local result_json="$OUT_DIR/${matrix_id}-jmh-result.json"
  local cmd="java -XX:+UseZGC -XX:+UnlockExperimentalVMOptions -Xms256m -Xmx256m \
    -jar $MICRO_JMH_JAR \
    $bench_pattern \
    -wi 5 -i 5 -f 1 \
    -rf json -rff $result_json \
    ${jfr_args:+$jfr_args} \
    ${extra_args[*]+\"${extra_args[@]}\"} \
    && jq -e 'length > 0' $result_json >/dev/null"

  run_step "$matrix_id" "$priority" "$tier" "$protocol_mode" \
    "$benchmark_family" "$comparison_axis" "$target_classification" \
    "$BENCH_REPO" "$cmd"
}

# -----------------------------------------------------------------------
# MUST steps: A1, A2, B1, B2, C4 — product-repo Maven invocations.
# -----------------------------------------------------------------------
run_step "A1" "MUST" "community" "tcp-tls-1.3" "A" "within-tier" "kernel-core-test" \
  "$KERNEL_REPO" \
  "mvn -pl exeris-kernel-core -am -Dtest=CoreOffHeapTlsEngineZeroAllocTckTest -Dsurefire.failIfNoSpecifiedTests=false test$(jfr_post_copy_args A1 "$KERNEL_REPO" exeris-kernel-core)"

run_step "A2" "MUST" "community" "tcp-tls-1.3" "A" "within-tier" "kernel-core-test" \
  "$KERNEL_REPO" \
  "mvn -pl exeris-kernel-core -am -Dtest=CoreOffHeapTlsEngineZeroAllocTckTest -DtrimStackTrace=false -Dsurefire.failIfNoSpecifiedTests=false test$(jfr_post_copy_args A2 "$KERNEL_REPO" exeris-kernel-core)"

run_step "B1" "MUST" "community" "tcp-tls-1.3" "B" "within-tier" "kernel-core-benchmark" \
  "$KERNEL_REPO" \
  "mvn -pl exeris-kernel-core -am -P benchmarks verify -Dbenchmark.includes=CoreOffHeapTlsEngineBenchmark -Dbenchmark.output=$OUT_DIR/B1-jmh-core-offheap-tls.json$(jfr_maven_args B1)"

run_step "B2" "MUST" "community" "tcp-tls-1.3" "B" "within-tier" "kernel-core-benchmark" \
  "$KERNEL_REPO" \
  "mvn -pl exeris-kernel-core -am -P benchmarks verify -Dbenchmark.includes=CoreTlsStateMachineBenchmark -Dbenchmark.output=$OUT_DIR/B2-jmh-core-tls-state-machine.json$(jfr_maven_args B2)"

run_step "C4" "MUST" "enterprise" "tcp-tls-1.3" "C" "within-tier" "enterprise-benchmark" \
  "$ENTERPRISE_REPO" \
  "mvn -pl exeris-kernel-enterprise -am -P benchmarks -DskipTests clean verify -Dbenchmark.includes=EnterpriseTlsEngineBenchmark -Dbenchmark.output=$OUT_DIR/C4-jmh-enterprise-tls-engine.json$(jfr_maven_args C4) && jq -e 'any(.[]; .benchmark == \"eu.exeris.kernel.enterprise.crypto.EnterpriseTlsEngineBenchmark.wrapThroughput\") and any(.[]; .benchmark == \"eu.exeris.kernel.enterprise.crypto.EnterpriseTlsEngineBenchmark.wrapUnwrapRoundTrip\")' $OUT_DIR/C4-jmh-enterprise-tls-engine.json >/dev/null"

# -----------------------------------------------------------------------
# SHOULD steps: B3 (JDK SSLEngine), B4 (netty-tcnative), B5 (Community TLS guard), D1 (loopback IT), D5 (community module loopback IT).
# Build micro/jmh once before running B3 or B4.
# -----------------------------------------------------------------------
if [[ "$run_should" == true ]]; then
  # Build micro/jmh uber-jar (needed by B3 and B4).
  if ! build_micro_jmh; then
    append_status "micro-jmh-build" "SHOULD" "community" "tcp-tls-1.3" "B" "implementation-variant" \
      "exeris-benchmarks-micro-jmh" "FAILED" "micro/jmh build failed" "mvn clean package" \
      "logs/micro-jmh-build.log"
    echo "WARN: micro/jmh build failed — B3 and B4 will be skipped" >&2
    # Mark B3 and B4 as SKIPPED due to build failure.
    record_missing "B3" "SHOULD" "community" "tcp-tls-1.3" "B" "implementation-variant" \
      "exeris-benchmarks-micro-jmh" \
      "micro/jmh build failed — cannot run SslEngineTlsBenchmark"
    record_missing "B4" "SHOULD" "community" "tcp-tls-1.3" "B" "implementation-variant" \
      "exeris-benchmarks-micro-jmh" \
      "micro/jmh build failed — cannot run NettyTcNativeTlsBenchmark"
  else
    run_micro_step "B3" "SHOULD" "community" "tcp-tls-1.3" "B" "implementation-variant" \
      "exeris-benchmarks-micro-jmh" "SslEngineTlsBenchmark"

    run_micro_step "B4" "SHOULD" "community" "tcp-tls-1.3" "B" "implementation-variant" \
      "exeris-benchmarks-micro-jmh" "NettyTcNativeTlsBenchmark"
  fi

  # B5: CommunityTlsEngineGuardBenchmark - kernel repo JMH benchmark.
  if [[ -f "$KERNEL_REPO/exeris-kernel-community/src/test/java/eu/exeris/kernel/community/crypto/CommunityTlsEngineGuardBenchmark.java" ]]; then
    run_step "B5" "SHOULD" "community" "tcp-tls-1.3" "B" "within-tier" "kernel-community-benchmark" \
      "$KERNEL_REPO" \
      "mvn -pl exeris-kernel-community -am -P benchmarks verify -Dbenchmark.includes=CommunityTlsEngineGuardBenchmark -Dbenchmark.output=$OUT_DIR/B5-jmh-community-tls-guard.json$(jfr_maven_args B5) && jq -e 'any(.[]; .benchmark == \"eu.exeris.kernel.community.crypto.CommunityTlsEngineGuardBenchmark.beginHandshakeWithoutBindGuardCost\") and any(.[]; .benchmark == \"eu.exeris.kernel.community.crypto.CommunityTlsEngineGuardBenchmark.wrapWithoutBindGuardCost\") and any(.[]; .benchmark == \"eu.exeris.kernel.community.crypto.CommunityTlsEngineGuardBenchmark.unwrapWithoutBindGuardCost\") and any(.[]; .benchmark == \"eu.exeris.kernel.community.crypto.CommunityTlsEngineGuardBenchmark.notifyBoundWithoutBindGuardCost\") and any(.[]; .benchmark == \"eu.exeris.kernel.community.crypto.CommunityTlsEngineGuardBenchmark.fullRoundTripWrapUnwrapCost\")' $OUT_DIR/B5-jmh-community-tls-guard.json >/dev/null"
  else
    record_missing "B5" "SHOULD" "community" "tcp-tls-1.3" "B" "within-tier" "kernel-community-benchmark" \
      "CommunityTlsEngineGuardBenchmark not found in exeris-kernel community"
  fi

  # D1: OffHeapTlsEngineLoopbackIT — kernel repo integration test.
  if [[ -f "$KERNEL_REPO/exeris-kernel-core/src/test/java/eu/exeris/kernel/core/crypto/tls/OffHeapTlsEngineLoopbackIT.java" ]]; then
    run_step "D1" "SHOULD" "community" "tcp-tls-1.3" "D" "within-tier" "kernel-core-it" \
      "$KERNEL_REPO" \
      "mvn -pl exeris-kernel-core -am -Dit.test=OffHeapTlsEngineLoopbackIT -Dfailsafe.failIfNoSpecifiedTests=false failsafe:integration-test failsafe:verify$(jfr_maven_args D1)"
  else
    record_missing "D1" "SHOULD" "community" "tcp-tls-1.3" "D" "within-tier" "kernel-core-it" \
      "OffHeapTlsEngineLoopbackIT not found in exeris-kernel core"
  fi

  # D5: community module integration loopback probe.
  if [[ -f "$KERNEL_REPO/exeris-kernel-community/src/test/java/eu/exeris/kernel/community/crypto/CommunityTlsEngineLoopbackIntegrationTest.java" ]]; then
    run_step "D5" "SHOULD" "community" "tcp-tls-1.3" "D" "within-tier" "kernel-community-it" \
      "$KERNEL_REPO" \
      "mvn -pl exeris-kernel-community -am -Dtest=CommunityTlsEngineLoopbackIntegrationTest -Dsurefire.failIfNoSpecifiedTests=false test$(jfr_maven_args D5)"
  else
    record_missing "D5" "SHOULD" "community" "tcp-tls-1.3" "D" "within-tier" "kernel-community-it" \
      "Neither OffHeapTlsEngineLoopbackIT nor CommunityTlsEngineLoopbackIntegrationTest found in exeris-kernel community"
  fi
else
  record_scope_skip "B3" "SHOULD" "community" "tcp-tls-1.3" "B" "implementation-variant" \
    "exeris-benchmarks-micro-jmh" "scope=must does not execute SHOULD steps"
  record_scope_skip "B4" "SHOULD" "community" "tcp-tls-1.3" "B" "implementation-variant" \
    "exeris-benchmarks-micro-jmh" "scope=must does not execute SHOULD steps"
  record_scope_skip "B5" "SHOULD" "community" "tcp-tls-1.3" "B" "within-tier" "kernel-community-benchmark" \
    "scope=must does not execute SHOULD steps"
  record_scope_skip "D1" "SHOULD" "community" "tcp-tls-1.3" "D" "within-tier" "kernel-core-it" \
    "scope=must does not execute SHOULD steps"
  record_scope_skip "D5" "SHOULD" "community" "tcp-tls-1.3" "D" "within-tier" "kernel-community-it" \
    "scope=must does not execute SHOULD steps"
fi

# -----------------------------------------------------------------------
# STRETCH steps: D2 (Enterprise loopback IT).
# -----------------------------------------------------------------------
if [[ "$run_stretch" == true ]]; then
  if [[ -f "$ENTERPRISE_REPO/exeris-kernel-enterprise/src/test/java/eu/exeris/kernel/enterprise/crypto/OffHeapTlsEngineLoopbackIT.java" ]]; then
    run_step "D2" "STRETCH" "enterprise" "tcp-tls-1.3" "D" "within-tier" "enterprise-it" \
      "$ENTERPRISE_REPO" \
      "mvn -pl exeris-kernel-enterprise -am -Dit.test=OffHeapTlsEngineLoopbackIT -Dfailsafe.failIfNoSpecifiedTests=false failsafe:integration-test failsafe:verify$(jfr_maven_args D2)"
  else
    record_missing "D2" "STRETCH" "enterprise" "tcp-tls-1.3" "D" "within-tier" "enterprise-it" \
      "OffHeapTlsEngineLoopbackIT not found in exeris-kernel-enterprise"
  fi
else
  record_scope_skip "D2" "STRETCH" "enterprise" "tcp-tls-1.3" "D" "within-tier" "enterprise-it" \
    "scope!=stretch does not execute STRETCH steps"
fi

# -----------------------------------------------------------------------
# Permanently missing IDs — tracked explicitly for article gap visibility.
# -----------------------------------------------------------------------
record_missing "D3" "SHOULD" "community" "tcp-tls-1.3" "D" "implementation-variant" "kernel-core-it" \
  "Community loopback handshake comparative benchmark is not implemented"

record_missing "D4" "STRETCH" "community" "tcp-tls-1.3" "D" "cross-tier-same-protocol" "exeris-benchmarks-runtime" \
  "Lifecycle probes are not yet implemented in exeris-benchmarks"

echo ""
echo "TLS matrix run finished"
echo "  Scope      : $SCOPE"
echo "  JFR        : ${JFR_PROF:-0} (set JFR_PROF=1 to enable)"
echo "  Output dir : $OUT_DIR"
echo "  Metadata   : $METADATA_FILE"
echo "  Status     : $STATUS_FILE"
