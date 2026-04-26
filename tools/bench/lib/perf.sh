#!/usr/bin/env bash
set -u

BENCH_PERF_STAT_PID="${BENCH_PERF_STAT_PID:-}"

bench_start_perf_stat() {
  local pid="$1"
  local csv_file="$2"

  BENCH_PERF_STAT_PID=""

  if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
    return 0
  fi

  if ! command -v perf >/dev/null 2>&1; then
    echo "Warning: perf not available; skipping perf stat collection." >&2
    return 0
  fi

  local no_scale_arg=""
  if perf stat --help 2>&1 | grep -q -- '--no-scale'; then
    no_scale_arg="--no-scale"
  fi

  # shellcheck disable=SC2086
  perf stat -p "$pid" -x, -o "$csv_file" $no_scale_arg &
  BENCH_PERF_STAT_PID="$!"
}

bench_stop_perf_stat() {
  if [[ -n "$BENCH_PERF_STAT_PID" ]]; then
    kill -INT "$BENCH_PERF_STAT_PID" 2>/dev/null || true
    wait "$BENCH_PERF_STAT_PID" 2>/dev/null || true
    BENCH_PERF_STAT_PID=""
  fi
}
