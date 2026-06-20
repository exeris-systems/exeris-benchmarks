#!/usr/bin/env bash
# aggregate-k6-throughput.sh — reconstruct a per-second throughput series from a
# k6 CSV stream (--out csv=...).
#
# Why this exists: k6's --summary-export gives a single window-averaged throughput
# number. That cannot distinguish "warmup noise read as steady-state" from genuine
# steady-state. The CSV stream carries one timestamped row per sample plus a
# `scenario` column (warmup/measurement/cooldown), so we can bucket http_reqs into
# 1-second windows, isolate the measurement window, and report steady-state
# throughput and time-to-peak separately — exactly the warmup-vs-steady-state split
# docs/methodology.md requires.
#
# Usage:
#   tools/aggregate-k6-throughput.sh <k6-timeseries.csv> [out.json]
#
# Emits (stdout, or to out.json) an object matching the throughput_series /
# steady_state_throughput_rps / time_to_peak_s fields of benchmark-result.schema.json:
#   {
#     "throughput_series": [ {"t_s":0,"rps":2.0,"phase":"warmup"}, ... ],
#     "steady_state_throughput_rps": <mean over measurement buckets>,
#     "time_to_peak_s": <first t_s reaching 95% of steady mean, or null>,
#     "measurement_buckets_used": <n>,
#     "source_csv": "<path>",
#     "note": "<diagnostic>"
#   }
# Always exits 0 with valid JSON so callers can merge it unconditionally.
set -u

CSV="${1:-}"
OUT="${2:-}"

emit() {
  local payload="$1"
  if [[ -n "$OUT" ]]; then printf '%s\n' "$payload" > "$OUT"; else printf '%s\n' "$payload"; fi
  return 0
}

if [[ -z "$CSV" || ! -f "$CSV" ]]; then
  emit '{"throughput_series":[],"steady_state_throughput_rps":null,"time_to_peak_s":null,"measurement_buckets_used":0,"source_csv":"'"${CSV}"'","note":"csv missing"}'
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  emit '{"throughput_series":[],"steady_state_throughput_rps":null,"time_to_peak_s":null,"measurement_buckets_used":0,"source_csv":"'"${CSV}"'","note":"python3 unavailable; series not reconstructed"}'
  exit 0
fi

python3 - "$CSV" "$OUT" <<'PY'
import csv, json, math, sys

csv_path = sys.argv[1]
out_path = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None

def write(obj):
    s = json.dumps(obj)
    if out_path:
        with open(out_path, "w") as f:
            f.write(s + "\n")
    else:
        print(s)

# Bucket http_reqs by integer second. The `scenario` column carries the k6
# scenario name (warmup/measurement/cooldown); we tag each bucket with the
# scenario that contributed the most samples to it.
buckets = {}            # sec -> count of completed requests
bucket_scn = {}         # sec -> {scenario: count}
note = "ok"

try:
    with open(csv_path, newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if not header:
            write({"throughput_series": [], "steady_state_throughput_rps": None,
                   "time_to_peak_s": None, "measurement_buckets_used": 0,
                   "source_csv": csv_path, "note": "empty csv"})
            sys.exit(0)
        idx = {name: i for i, name in enumerate(header)}
        i_metric = idx.get("metric_name")
        i_ts = idx.get("timestamp")
        i_val = idx.get("metric_value")
        i_scn = idx.get("scenario")
        if i_metric is None or i_ts is None:
            write({"throughput_series": [], "steady_state_throughput_rps": None,
                   "time_to_peak_s": None, "measurement_buckets_used": 0,
                   "source_csv": csv_path,
                   "note": "unexpected csv header (no metric_name/timestamp)"})
            sys.exit(0)
        for row in reader:
            if len(row) <= max(i_metric, i_ts):
                continue
            if row[i_metric] != "http_reqs":
                continue
            try:
                sec = int(float(row[i_ts]))
            except (ValueError, IndexError):
                continue
            val = 1.0
            if i_val is not None and i_val < len(row):
                try:
                    val = float(row[i_val])
                except ValueError:
                    val = 1.0
            buckets[sec] = buckets.get(sec, 0.0) + val
            scn = row[i_scn] if (i_scn is not None and i_scn < len(row)) else ""
            bucket_scn.setdefault(sec, {})
            bucket_scn[sec][scn] = bucket_scn[sec].get(scn, 0) + 1
except Exception as e:  # never fail the caller; emit a valid object with the reason
    write({"throughput_series": [], "steady_state_throughput_rps": None,
           "time_to_peak_s": None, "measurement_buckets_used": 0,
           "source_csv": csv_path, "note": "parse error: %s" % e})
    sys.exit(0)

if not buckets:
    write({"throughput_series": [], "steady_state_throughput_rps": None,
           "time_to_peak_s": None, "measurement_buckets_used": 0,
           "source_csv": csv_path, "note": "no http_reqs samples"})
    sys.exit(0)

def phase_for(sec):
    counts = bucket_scn.get(sec, {})
    if not counts:
        return "unknown"
    name = max(counts, key=counts.get)
    return name if name in ("warmup", "measurement", "cooldown") else "unknown"

t0 = min(buckets)
secs = sorted(buckets)
series = [{"t_s": s - t0, "rps": round(buckets[s], 3), "phase": phase_for(s)} for s in secs]

# Steady-state mean over measurement buckets. Drop the final measurement bucket
# when there are >=3 of them: the last 1s window is usually partial (run stopped
# mid-second) and would drag the mean down.
meas = [pt for pt in series if pt["phase"] == "measurement"]
used = meas[:-1] if len(meas) >= 3 else meas
steady = round(sum(p["rps"] for p in used) / len(used), 3) if used else None

# Time-to-peak: first bucket (from load start) reaching 95% of the steady mean.
ttp = None
if steady and steady > 0:
    threshold = 0.95 * steady
    for pt in series:
        if pt["rps"] >= threshold:
            ttp = pt["t_s"]
            break

write({
    "throughput_series": series,
    "steady_state_throughput_rps": steady,
    "time_to_peak_s": ttp,
    "measurement_buckets_used": len(used),
    "source_csv": csv_path,
    "note": note,
})
PY
exit 0
