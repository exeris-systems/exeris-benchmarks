#!/usr/bin/env python3
"""aggregate-runs.py — firm up single runs into mean ± stdev across repetitions.

Point it at several run directories (same target/config, ideally interleaved A,B,A,B
to average box drift) and it reports per-metric mean, stdev, and coefficient of
variation (CV%) — so you can see whether a difference survives the noise.

Usage:
  tools/aggregate-runs.py <run-dir> [<run-dir> ...]
  tools/aggregate-runs.py results/raw/guided/2026*Z          # globs expand in shell

Pulls per run:
  - throughput_rps, latency_p50/p99/p999_us  from result.json (or wrk2-latency.json)
  - cpu_per_req_ms  = process %CPU / throughput  from logs/target-pidstat.csv (if present)
  - load_fraction / at_saturation              from wrk2-latency.json (if present)

Emits a markdown table to stdout and a JSON summary to stderr-free stdout tail.
No external deps. CV% > ~10 means the metric is noise-dominated on this box.
"""
import sys, os, json, csv, math, glob

def pidstat_cpu_per_req(run_dir, rps):
    csvp = os.path.join(run_dir, "logs", "target-pidstat.csv")
    if not (os.path.isfile(csvp) and rps):
        return None
    proc_cpu, n = 0.0, 0
    with open(csvp) as fh:
        r = csv.reader(fh)
        header = next(r, None)
        for row in r:
            if len(row) < 13:
                continue
            # process-summary row has TID column == "-"
            if row[3] == "-":
                try:
                    proc_cpu += float(row[8]); n += 1   # %CPU col
                except ValueError:
                    pass
    if n == 0:
        return None
    return (proc_cpu / n) / 100.0 / rps * 1000.0   # ms of CPU per request

def load_run(run_dir):
    out = {"dir": os.path.basename(run_dir.rstrip("/"))}
    res = os.path.join(run_dir, "result.json")
    if os.path.isfile(res):
        m = json.load(open(res)).get("metrics", {})
        out["throughput_rps"] = m.get("throughput_rps")
        for p in ("p50", "p99", "p999"):
            out[f"latency_{p}_ms"] = (m.get(f"latency_{p}_us") or 0) / 1000.0 or None
    w2 = os.path.join(run_dir, "wrk2-latency.json")
    if os.path.isfile(w2):
        j = json.load(open(w2))
        out["load_fraction"] = j.get("load_fraction")
        out["at_saturation"] = j.get("at_saturation")
        out.setdefault("throughput_rps", j.get("requests_per_sec"))
        # only if result.json didn't already carry merged percentiles (avoid dup cols)
        if not any(k.startswith("latency_p") for k in out):
            for pe in j.get("latency_percentiles", []):
                k = pe["percentile"].replace(".", "")
                out[f"latency_{k}_ms"] = pe["latency_us"] / 1000.0
    if out.get("throughput_rps"):
        cpr = pidstat_cpu_per_req(run_dir, out["throughput_rps"])
        if cpr:
            out["cpu_per_req_ms"] = round(cpr, 4)
    return out

def stats(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    if not vals:
        return None
    n = len(vals); mean = sum(vals) / n
    sd = math.sqrt(sum((v - mean) ** 2 for v in vals) / (n - 1)) if n > 1 else 0.0
    cv = (sd / mean * 100.0) if mean else 0.0
    return {"n": n, "mean": mean, "stdev": sd, "cv_pct": cv,
            "min": min(vals), "max": max(vals)}

def main():
    dirs = [d for a in sys.argv[1:] for d in (glob.glob(a) if any(c in a for c in "*?[") else [a])]
    dirs = [d for d in dirs if os.path.isdir(d)]
    if not dirs:
        sys.exit("usage: aggregate-runs.py <run-dir> [<run-dir> ...]")
    runs = [load_run(d) for d in dirs]
    metrics = ["throughput_rps", "cpu_per_req_ms", "latency_p50_ms",
               "latency_p99_ms", "latency_p999_ms", "load_fraction"]
    present = [m for m in metrics if any(m in r for r in runs)]

    print(f"# Aggregate of {len(runs)} run(s)\n")
    print("| run | " + " | ".join(present) + " |")
    print("|" + "---|" * (len(present) + 1))
    for r in runs:
        row = [r["dir"]] + [f'{r.get(m):g}' if isinstance(r.get(m), (int, float)) else str(r.get(m, "")) for m in present]
        print("| " + " | ".join(row) + " |")

    print("\n**Summary (mean ± stdev, CV%):**\n")
    print("| metric | mean | stdev | CV% | min | max |")
    print("|---|---|---|---|---|---|")
    summary = {}
    for m in present:
        s = stats([r.get(m) for r in runs])
        if not s:
            continue
        summary[m] = s
        flag = "  ⚠ noisy" if s["cv_pct"] > 10 else ""
        print(f"| {m} | {s['mean']:.4g} | {s['stdev']:.3g} | {s['cv_pct']:.1f}%{flag} | {s['min']:.4g} | {s['max']:.4g} |")
    print("\n_CV% > 10 ⇒ metric is noise-dominated on this hardware; a between-stack "
          "difference smaller than the CV is not real. Interleave A,B,A,B reps._")
    print("\n```json\n" + json.dumps(summary, indent=2) + "\n```")

if __name__ == "__main__":
    main()
