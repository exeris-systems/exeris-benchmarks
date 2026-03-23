#!/usr/bin/env bash
# run-jmh.sh — Build and run JMH microbenchmarks.
# Usage:
#   ./scripts/run-jmh.sh [BENCH_REGEX] [EXTRA_JMH_ARGS...]
#
# Examples:
#   ./scripts/run-jmh.sh                                # all benchmarks, default config
#   ./scripts/run-jmh.sh RouteRegistry                  # pattern filter
#   ./scripts/run-jmh.sh JsonCodec -wi 5 -i 10 -f 3    # custom JMH args
#   ./scripts/run-jmh.sh --with-alloc JsonCodec        # GC alloc profiler (-prof gc)
#   ./scripts/run-jmh.sh JsonCodec -prof async          # async-profiler flame graph
#   ./scripts/run-jmh.sh JsonCodec -prof perfnorm       # CPU perf counters (Linux+perf)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JMH_DIR="$SCRIPT_DIR/../micro/jmh"
RESULTS_DIR="$SCRIPT_DIR/../results/raw"
mkdir -p "$RESULTS_DIR"

BENCH_REGEX="${1:-}"
shift || true

# Optional: -prof gc for allocation rate tracking.
ALLOC_PROFILING=false
if [[ "$BENCH_REGEX" == "--with-alloc" ]]; then
  ALLOC_PROFILING=true
  BENCH_REGEX="${1:-}"
  shift || true
elif [[ "${1:-}" == "--with-alloc" ]]; then
  ALLOC_PROFILING=true
  shift || true
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_JSON="$RESULTS_DIR/jmh-${TIMESTAMP}.json"

echo "=== Exeris JMH Benchmark Run ==="
echo "  Module : $JMH_DIR"
echo "  Pattern: ${BENCH_REGEX:-<all>}"
echo "  Output : $RESULT_JSON"
echo ""

# Build
echo "[1/2] Building micro/jmh module..."
mvn -f "$JMH_DIR/pom.xml" clean package -DskipTests -q

# Run
echo "[2/2] Running benchmarks..."
EXTRA_PROFILERS=()
if [[ "$ALLOC_PROFILING" == "true" ]]; then
  EXTRA_PROFILERS=(-prof gc)
fi

java \
  -XX:+UseG1GC \
  -XX:+AlwaysPreTouch \
  -Xms512m -Xmx512m \
  -jar "$JMH_DIR/target/benchmarks.jar" \
  ${BENCH_REGEX:+"$BENCH_REGEX"} \
  -wi 5 -i 10 -f 3 \
  -rf json -rff "$RESULT_JSON" \
  "${EXTRA_PROFILERS[@]}" \
  "$@"

echo ""
echo "Results written to: $RESULT_JSON"
echo "Validate with: jq -r '.[].primaryMetric | \"\(.score | tostring) ± \(.scoreError | tostring) \(.scoreUnit)\"' $RESULT_JSON"
