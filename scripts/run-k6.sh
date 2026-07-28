#!/usr/bin/env bash
# run-k6.sh — Run a k6 scenario.
# Usage:
#   ./scripts/run-k6.sh <scenario-dir> [K6_ARGS...]
#
# Examples:
#   ./scripts/run-k6.sh scenarios/json-1kb
#   ./scripts/run-k6.sh scenarios/backpressure --vus 200 --duration 60s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
source "$ROOT/tools/bench/lib/k6.sh"
# protocol.sh provides bench_derive_k6_protocol_mode_from_output, used below to
# fail closed when an h2 run silently fell back to HTTP/1.1 (k6 has no h2c and
# negotiates HTTP/2 only over TLS via ALPN — a target without h2 ALPN downgrades).
source "$ROOT/tools/bench/lib/protocol.sh"

SCENARIO_DIR="${1:?Usage: run-k6.sh <scenario-dir> [k6 args]}"
shift

SCENARIO_DIR="$ROOT/$SCENARIO_DIR"
K6_SCRIPT="$SCENARIO_DIR/k6.js"

if [[ ! -f "$K6_SCRIPT" ]]; then
  echo "ERROR: k6 script not found: $K6_SCRIPT" >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$ROOT/results/raw"
mkdir -p "$RESULTS_DIR"
RESULT_JSON="$RESULTS_DIR/k6-${TIMESTAMP}.json"
# Persist the k6 console output as a first-class artifact alongside the JSON
# streams (the JSON is the data; the console log is the ground truth for what
# k6 reported — thresholds/checks/protocol — kept for honest reproducibility).
# pipefail (set above) preserves k6's exit status through the tee.
K6_CONSOLE_LOG="$RESULTS_DIR/k6-console-${TIMESTAMP}.log"
# Per-sample CSV stream (timestamped, with a `scenario` column) so the per-second
# throughput series — and thus the warmup curve — can be reconstructed instead of
# trusting a single window-averaged number. See tools/aggregate-k6-throughput.sh.
# OPT-IN (BENCH_K6_TIMESERIES=1): off by default so a standard run keeps its
# original shape and avoids concurrent per-sample CSV I/O perturbing the very
# steady-state being measured.
K6_TIMESERIES_CSV="$RESULTS_DIR/k6-timeseries-${TIMESTAMP}.csv"
K6_TIMESERIES_ENABLED="${BENCH_K6_TIMESERIES:-0}"

# Long-run disk guard (BENCH_K6_JSON_GZ=1): k6 gzips the JSON point stream
# natively when the output filename ends with .gz (~10-15x smaller). At soak
# rates the raw stream is ~100 MB/min — a 24h run would exhaust a 160 GB disk.
# Downstream consumers must zcat; the in-script consumers below are gz-aware.
K6_JSON_GZ_ENABLED="${BENCH_K6_JSON_GZ:-0}"
if [[ "$K6_JSON_GZ_ENABLED" == "1" ]]; then
  RESULT_JSON="${RESULT_JSON}.gz"
fi

echo "=== k6 scenario ==="
echo "  Script    : $K6_SCRIPT"
echo "  Output    : $RESULT_JSON"
if [[ "$K6_TIMESERIES_ENABLED" == "1" ]]; then
  echo "  Timeseries: $K6_TIMESERIES_CSV"
else
  echo "  Timeseries: (disabled — set BENCH_K6_TIMESERIES=1 to enable)"
fi
echo "  Console   : $K6_CONSOLE_LOG"
echo ""

bench_k6_assert_arrival_rate_executor "$K6_SCRIPT" || exit 1

K6_OUT_ARGS=(--out json="$RESULT_JSON" --summary-export="$RESULTS_DIR/k6-summary-${TIMESTAMP}.json")
if [[ "$K6_TIMESERIES_ENABLED" == "1" ]]; then
  K6_OUT_ARGS+=(--out csv="$K6_TIMESERIES_CSV")
fi

k6 run \
  "${K6_OUT_ARGS[@]}" \
  "$@" \
  "$K6_SCRIPT" 2>&1 | tee "$K6_CONSOLE_LOG"

if [[ -f "$RESULT_JSON" && "$K6_JSON_GZ_ENABLED" != "1" ]]; then
  if ! jq -e '.metrics.http_req_duration.values["p(99)"]' "$RESULT_JSON" >/dev/null 2>&1; then
    echo "WARN: p(99) not found in k6 output — check that enough samples were collected." >&2
  fi
fi

# Reconstruct the per-second throughput series from the CSV stream (warmup curve +
# steady-state from the measurement window only). Never fatal; emits valid JSON.
K6_THROUGHPUT_SERIES_JSON="$RESULTS_DIR/k6-throughput-series-${TIMESTAMP}.json"
if [[ -f "$K6_TIMESERIES_CSV" ]]; then
  "$ROOT/tools/aggregate-k6-throughput.sh" "$K6_TIMESERIES_CSV" "$K6_THROUGHPUT_SERIES_JSON" || true
  echo "Throughput series: $K6_THROUGHPUT_SERIES_JSON"
fi

# Honesty guard (symmetric to the h2load ALPN-fallback detector in
# run-entity-read-by-id.sh): when the caller asked for HTTP/2, confirm k6 actually
# negotiated it from the per-request proto tags. k6 has no cleartext h2c and speaks
# HTTP/2 only over TLS via ALPN, so a target that omits h2 from ALPN silently
# downgrades to HTTP/1.1 — which must not be recorded under an h2 label. Fail
# closed: anything other than confirmed HTTP/2 (h2/h2c) aborts the run.
if [[ -n "${BENCH_EXPECTED_PROTOCOL_MODE:-}" ]]; then
  case "$BENCH_EXPECTED_PROTOCOL_MODE" in
    h2|h2c)
      k6_base_url="${K6_BASE_URL:-${BASE_URL:-}}"
      if [[ "$K6_JSON_GZ_ENABLED" == "1" ]]; then
        # proto tags appear on every http_req point; a decompressed head sample
        # is enough for the label check without materializing the full stream.
        k6_proto_sample="$(mktemp)"
        zcat "$RESULT_JSON" 2>/dev/null | head -n 500000 > "$k6_proto_sample" || true
        bench_derive_k6_protocol_mode_from_output "$k6_proto_sample" "$k6_base_url"
        rm -f "$k6_proto_sample"
      else
        bench_derive_k6_protocol_mode_from_output "$RESULT_JSON" "$k6_base_url"
      fi
      case "$BENCH_K6_OBSERVED_PROTOCOL_MODE" in
        h2|h2c) echo "k6 protocol confirmed: $BENCH_K6_OBSERVED_PROTOCOL_MODE (proto tags: ${BENCH_K6_PROTO_TAGS_CSV})" ;;
        *)
          echo "ERROR: requested HTTP/2 (BENCH_EXPECTED_PROTOCOL_MODE=$BENCH_EXPECTED_PROTOCOL_MODE) but k6 observed protocol='$BENCH_K6_OBSERVED_PROTOCOL_MODE' (proto tags: ${BENCH_K6_PROTO_TAGS_CSV})." >&2
          echo "ERROR: k6 negotiates HTTP/2 only over TLS via ALPN (no cleartext h2c); the target most likely omitted h2 from ALPN and k6 fell back to HTTP/1.1. The run cannot be labeled HTTP/2." >&2
          echo "ERROR: raw k6 console: $K6_CONSOLE_LOG" >&2
          exit 1
          ;;
      esac
      ;;
  esac
fi

echo ""
echo "Result written to: $RESULT_JSON"
echo "Console log      : $K6_CONSOLE_LOG"
