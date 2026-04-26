#!/usr/bin/env bash
set -euo pipefail
cd /home/arkstack/exeris-systems/exeris-benchmarks
TRANSCRIPT="/tmp/spring-native-graal26-smoke-$(date -u +%Y%m%dT%H%M%SZ).log"

echo "TRANSCRIPT=$TRANSCRIPT"

echo "+ select_graal"
CANDIDATES_DIR="$HOME/.sdkman/candidates/java"
SELECTED=""
for c in 26.ea.13-graal 26.ea.35-open 25.0.2-graal; do
  if [[ -d "$CANDIDATES_DIR/$c" ]]; then
    SELECTED="$c"
    break
  fi
done
if [[ -z "$SELECTED" ]]; then
  echo "ERROR: None of preferred JDKs found under $CANDIDATES_DIR" | tee -a "$TRANSCRIPT"
  exit 11
fi
export JAVA_HOME="$CANDIDATES_DIR/$SELECTED"
export PATH="$JAVA_HOME/bin:$PATH"
echo "SELECTED_JAVA=$SELECTED" | tee -a "$TRANSCRIPT"
echo "JAVA_HOME=$JAVA_HOME" | tee -a "$TRANSCRIPT"

echo "+ java -version" | tee -a "$TRANSCRIPT"
java -version 2>&1 | tee -a "$TRANSCRIPT"
echo "+ native-image --version" | tee -a "$TRANSCRIPT"
native-image --version 2>&1 | tee -a "$TRANSCRIPT"

echo "+ mvn -f targets/spring-benchmark-app/pom.xml -Pnative -DskipTests package" | tee -a "$TRANSCRIPT"
mvn -f targets/spring-benchmark-app/pom.xml -Pnative -DskipTests package 2>&1 | tee -a "$TRANSCRIPT"

BIN_PATH="targets/spring-benchmark-app/target/spring-benchmark-app"
if [[ -f "$BIN_PATH" ]]; then
  echo "BUILD_BINARY_PRESENT=1" | tee -a "$TRANSCRIPT"
  echo "BUILD_BINARY_PATH=$BIN_PATH" | tee -a "$TRANSCRIPT"
else
  echo "BUILD_BINARY_PRESENT=0" | tee -a "$TRANSCRIPT"
  echo "BUILD_BINARY_PATH=$BIN_PATH" | tee -a "$TRANSCRIPT"
fi

echo "+ constrained smoke" | tee -a "$TRANSCRIPT"
set +e
BENCHMARK_SKIP_TARGET_BUILD=1 ./scripts/run-entity-read-by-id-constrained.sh --target-runtime spring --target-build native 2>&1 | tee -a "$TRANSCRIPT"
CONSTRAINED_RC=${PIPESTATUS[0]}
set -e
echo "CONSTRAINED_RC=$CONSTRAINED_RC" | tee -a "$TRANSCRIPT"

FALLBACK_RUN=0
FALLBACK_RC=0
if [[ $CONSTRAINED_RC -ne 0 ]]; then
  LATEST_CONSTRAINED_DIR=$(ls -1dt results/constrained/entity-read-by-id/* 2>/dev/null | head -n1 || true)
  echo "LATEST_CONSTRAINED_DIR=$LATEST_CONSTRAINED_DIR" | tee -a "$TRANSCRIPT"
  CGROUP_ONLY=0
  if [[ -n "${LATEST_CONSTRAINED_DIR:-}" && -d "$LATEST_CONSTRAINED_DIR" ]]; then
    if rg -i "cgroup|cpu\.max|memory\.max|memory\.current|/sys/fs/cgroup|No such file|Operation not permitted|Permission denied" "$LATEST_CONSTRAINED_DIR" >/dev/null 2>&1; then
      if ! rg -i "Exception|Caused by:|ERROR|BindException|ConnectException|OutOfMemoryError|Failed to execute goal" "$LATEST_CONSTRAINED_DIR" >/dev/null 2>&1; then
        CGROUP_ONLY=1
      fi
    fi
  fi
  echo "CGROUP_ONLY=$CGROUP_ONLY" | tee -a "$TRANSCRIPT"
  if [[ $CGROUP_ONLY -eq 1 ]]; then
    FALLBACK_RUN=1
    echo "+ fallback smoke" | tee -a "$TRANSCRIPT"
    set +e
    BENCHMARK_SKIP_TARGET_BUILD=1 ./scripts/run-entity-read-by-id.sh --target-runtime spring --target-build native --threads 2 --connections 16 --warmup 10s --duration 20s --claim-scope exploratory 2>&1 | tee -a "$TRANSCRIPT"
    FALLBACK_RC=${PIPESTATUS[0]}
    set -e
  else
    echo "FALLBACK_SKIPPED=1" | tee -a "$TRANSCRIPT"
  fi
fi

echo "FALLBACK_RUN=$FALLBACK_RUN" | tee -a "$TRANSCRIPT"
echo "FALLBACK_RC=$FALLBACK_RC" | tee -a "$TRANSCRIPT"
LATEST_CONSTRAINED_DIR=$(ls -1dt results/constrained/entity-read-by-id/* 2>/dev/null | head -n1 || true)
LATEST_REGULAR_DIR=$(ls -1dt results/runtime/entity-read-by-id/* 2>/dev/null | head -n1 || true)
echo "LATEST_CONSTRAINED_DIR=$LATEST_CONSTRAINED_DIR" | tee -a "$TRANSCRIPT"
echo "LATEST_REGULAR_DIR=$LATEST_REGULAR_DIR" | tee -a "$TRANSCRIPT"
echo "DONE" | tee -a "$TRANSCRIPT"
