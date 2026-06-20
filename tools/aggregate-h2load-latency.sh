#!/usr/bin/env bash
# aggregate-h2load-latency.sh — compute latency percentiles from an h2load
# --log-file, which h2load itself does not report (it prints only min/max/mean/sd).
#
# Usage: aggregate-h2load-latency.sh <h2load-log-file> [output.json]
#
# h2load --log-file writes tab-separated per-request rows:
#   col1: start time (microseconds since epoch)
#   col2: HTTP status code (-1 for a failed stream)
#   col3: microseconds until end of response   <-- the per-request latency
#
# We compute p50/p75/p90/p95/p99/p99.9 (+min/max/mean) over col3 for SUCCESSFUL
# requests (2xx/3xx). Output is always valid JSON (empty/garbage/no-python all
# yield a well-formed object with nulls), mirroring tools/aggregate-k6-throughput.sh.
#
# IMPORTANT (coordinated omission): h2load is a CLOSED-LOOP generator — each
# connection waits for a response before sending the next request. Under saturation
# (the target near 100% CPU) these percentiles are dominated by queueing and
# approximate concurrency/throughput (Little's law), NOT the true service-time tail.
# For CO-free tail latency, run BELOW saturation at a fixed arrival rate with
# scripts/run-wrk2.sh (HdrHistogram). The caveat is stamped into the output.
set -euo pipefail

LOG_FILE="${1:?Usage: aggregate-h2load-latency.sh <h2load-log-file> [output.json]}"
OUT_FILE="${2:-}"

_emit() { if [[ -n "$OUT_FILE" ]]; then cat > "$OUT_FILE"; else cat; fi; }

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' '{"latency_source":"h2load-log-file","note":"python3 unavailable; percentiles not computed","sample_count":null,"latency_p50_us":null,"latency_p99_us":null}' | _emit
  exit 0
fi

H2LOAD_LOG_FILE="$LOG_FILE" python3 - <<'PY' | _emit
import json, os

path = os.environ["H2LOAD_LOG_FILE"]
CO_CAVEAT = ("h2load is closed-loop; under saturation these percentiles reflect "
             "queueing (~concurrency/throughput, Little's law), not the true "
             "service-time tail. Use run-wrk2.sh sub-saturation for CO-free latency.")

def empty(note):
    return {
        "latency_source": "h2load-log-file",
        "note": note,
        "co_caveat": CO_CAVEAT,
        "sample_count": 0,
        "error_count": 0,
        "latency_p50_us": None, "latency_p75_us": None, "latency_p90_us": None,
        "latency_p95_us": None, "latency_p99_us": None, "latency_p999_us": None,
        "latency_min_us": None, "latency_max_us": None, "latency_mean_us": None,
    }

try:
    lat, errors = [], 0
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            try:
                status = int(parts[1]); dur = int(parts[2])
            except ValueError:
                continue
            if status == -1 or status < 200 or status >= 400:
                errors += 1
                continue
            lat.append(dur)
    if not lat:
        print(json.dumps(empty("no successful samples in h2load log"))); raise SystemExit
    lat.sort()
    n = len(lat)
    def pct(p):
        # nearest-rank: standard for latency percentiles
        import math
        idx = max(0, min(n - 1, math.ceil(p / 100.0 * n) - 1))
        return lat[idx]
    out = {
        "latency_source": "h2load-log-file",
        "co_caveat": CO_CAVEAT,
        "sample_count": n,
        "error_count": errors,
        "latency_p50_us": pct(50), "latency_p75_us": pct(75), "latency_p90_us": pct(90),
        "latency_p95_us": pct(95), "latency_p99_us": pct(99), "latency_p999_us": pct(99.9),
        "latency_min_us": lat[0], "latency_max_us": lat[-1],
        "latency_mean_us": round(sum(lat) / n, 1),
    }
    print(json.dumps(out))
except SystemExit:
    raise
except Exception as e:
    print(json.dumps(empty("aggregation error: %s" % e)))
PY
