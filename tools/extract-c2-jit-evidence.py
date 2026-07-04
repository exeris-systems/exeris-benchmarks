#!/usr/bin/env python3
"""Derive C2/JIT evidence from a run's raw .jfr into a committable JSON.

The raw `.jfr` recordings are kept out of git for size (see
`results/reports/2026-06-20-entity-read-by-id-artifacts.md`). This tool
distills the *compiler* signal — the part that proves "warm" and quantifies
JIT cost — into a small `c2-jit-evidence.json` that CAN be committed, so the
"C2=0 / C2 peak N" claims in the report are reproducible without the 250 MB
recording.

What survives JFR's `maxsize` rotation and what does not:
  - `jdk.CompilerStatistics` counters are CUMULATIVE (last-value-wins), so the
    total compile count / JIT CPU time reflect the whole run even when the
    recording rotated and retained only the tail.
  - `jdk.CompilerQueueUtilization` is a time series — on a rotated recording it
    only covers the retained tail, so the queue depth proves warmth at the END
    of the window, not the warmup ramp. `jfr_retained.rotated` flags this.
  - `jdk.Compilation` (per-method, duration-thresholded) is only meaningful on
    a NON-rotated recording (short runs); on rotated runs most are gone.

Usage:
  tools/extract-c2-jit-evidence.py <run-dir> [<run-dir> ...]
  tools/extract-c2-jit-evidence.py results/raw/guided/20260621T082946Z
"""
import json
import os
import re
import subprocess
import sys

EVENTS = [
    "jdk.CompilerStatistics",
    "jdk.CompilerQueueUtilization",
    "jdk.CompilerConfiguration",
    "jdk.Compilation",
    "jdk.Deoptimization",
    "jdk.CodeCacheStatistics",
]


def parse_duration(v):
    """ISO-8601 'PT38.293S' / 'PT1M2.5S' -> milliseconds (float)."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    m = re.fullmatch(r"PT(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?", str(v))
    if not m:
        return None
    mins = float(m.group(1) or 0)
    secs = float(m.group(2) or 0)
    return round((mins * 60 + secs) * 1000.0, 3)


def jfr_summary(jfr):
    out = subprocess.run(["jfr", "summary", jfr], capture_output=True, text=True).stdout
    span = chunks = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("Duration:"):
            mm = re.search(r"(\d+)\s*s", s)
            if mm:
                span = int(mm.group(1))
        elif s.startswith("Chunks:"):
            chunks = int(re.search(r"(\d+)", s).group(1))
    return span, chunks


def jfr_events(jfr, types):
    out = subprocess.run(
        ["jfr", "print", "--json", "--events", ",".join(types), jfr],
        capture_output=True, text=True,
    ).stdout
    if not out.strip():
        return []
    return json.load(__import__("io").StringIO(out))["recording"]["events"]


def target_id(run_dir):
    rj = os.path.join(run_dir, "result.json")
    if not os.path.exists(rj):
        return None
    try:
        t = json.load(open(rj)).get("target", {})
        return t.get("version") or t.get("id") or t.get("target_id")
    except Exception:
        return None


def configured_phases(run_dir):
    """Intended (warmup_seconds, measurement_seconds) for the run.

    Field naming differs across artifacts, so probe the reliable sources in
    order: steady-state-evidence.json (top-level warmup_seconds/duration_seconds,
    present on every run), then guided-run-profile.json's nested
    workload.{warmup_seconds,measurement_seconds}, then a top-level result.json
    fallback. Returns (warmup, measurement) with None where unknown.
    """
    sse = os.path.join(run_dir, "steady-state-evidence.json")
    if os.path.exists(sse):
        try:
            d = json.load(open(sse))
            warm, dur = d.get("warmup_seconds"), d.get("duration_seconds")
            if warm is not None and dur is not None:
                return int(warm), int(dur)
        except Exception:
            pass

    grp = os.path.join(run_dir, "guided-run-profile.json")
    if os.path.exists(grp):
        try:
            w = json.load(open(grp)).get("workload", {})
            warm, dur = w.get("warmup_seconds"), w.get("measurement_seconds")
            if warm is not None and dur is not None:
                return int(warm), int(dur)
        except Exception:
            pass

    rj = os.path.join(run_dir, "result.json")
    if os.path.exists(rj):
        try:
            d = json.load(open(rj))
            warm, dur = d.get("warmup_seconds"), d.get("duration_seconds")
            if warm is not None and dur is not None:
                return int(warm), int(dur)
        except Exception:
            pass
    return None, None


def derive(run_dir):
    jfrs = [f for f in os.listdir(run_dir) if f.lower().endswith(".jfr")]
    if not jfrs:
        return None, "no .jfr in run dir"
    jfr = os.path.join(run_dir, sorted(jfrs)[0])

    span, chunks = jfr_summary(jfr)
    jfr_size_mb = round(os.path.getsize(jfr) / (1024 * 1024), 1)
    warm_s, meas_s = configured_phases(run_dir)
    cfg = (warm_s + meas_s) if (warm_s is not None and meas_s is not None) else None
    rotated = bool(cfg and span and span < cfg * 0.9)
    # Rotation drops the OLDEST chunks first, so the retained window ends at the
    # run end. What matters is whether it still covers the measurement window:
    # if span >= measurement, only (part of) warmup was lost, not measured data.
    measurement_retained = (
        None if (meas_s is None or span is None) else bool(span >= meas_s)
    )

    events = jfr_events(jfr, EVENTS)
    by_type = {}
    for e in events:
        by_type.setdefault(e["type"], []).append(e["values"])

    # --- cumulative compiler statistics (last event wins) ---
    stats = {}
    cs = by_type.get("jdk.CompilerStatistics", [])
    if cs:
        v = cs[-1]
        stats = {
            "compile_count": v.get("compileCount"),
            "standard_compile_count": v.get("standardCompileCount"),
            "osr_compile_count": v.get("osrCompileCount"),
            "bailout_count": v.get("bailoutCount"),
            "invalidated_count": v.get("invalidatedCount"),
            "total_time_spent_ms": parse_duration(v.get("totalTimeSpent")),
            "peak_time_spent_ms": parse_duration(v.get("peakTimeSpent")),
            "nmethods_size_bytes": v.get("nmethodsSize"),
            "nmethod_code_size_bytes": v.get("nmethodCodeSize"),
        }

    # --- compiler queue, split by compiler (c1/c2) ---
    # CompilerQueueUtilization is a ~1 Hz time series. peak_queue_size is a
    # monotonic high-water mark (survives as a cumulative); max_live_queue_size
    # is the largest live depth seen in the RETAINED window. To judge "warm at
    # the end" we look at the tail of the series, not the whole window — on a
    # non-rotated run the window still contains the warmup burst.
    TAIL = 30  # ~last 30s at 1 Hz
    series = {}  # compiler -> ordered list of live queueSize
    queue = {}
    for v in by_type.get("jdk.CompilerQueueUtilization", []):
        c = v.get("compiler")
        q = queue.setdefault(c, {
            "samples": 0, "nonzero_samples": 0,
            "max_live_queue_size": 0, "peak_queue_size": 0,
            "total_added_count": 0,
        })
        live = v.get("queueSize", 0)
        series.setdefault(c, []).append(live)
        q["samples"] += 1
        if live:
            q["nonzero_samples"] += 1
        q["max_live_queue_size"] = max(q["max_live_queue_size"], live)
        q["peak_queue_size"] = max(q["peak_queue_size"], v.get("peakQueueSize", 0))
        q["total_added_count"] = max(q["total_added_count"], v.get("totalAddedCount", 0))
    for c, q in queue.items():
        tail = series[c][-TAIL:]
        q["tail_window_samples"] = len(tail)
        q["tail_max_live_queue_size"] = max(tail) if tail else None
        q["tail_idle"] = bool(tail) and max(tail) == 0

    # --- per-method compilation (duration-thresholded; short/non-rotated runs only) ---
    comp = by_type.get("jdk.Compilation", [])
    per_method = {
        "events_captured": len(comp),
        "by_compiler": {},
        "by_level": {},
        "max_duration_ms": None,
        "note": ("duration-thresholded — JFR emits a jdk.Compilation event only "
                 "above its configured duration threshold, so this is the count "
                 "of the heaviest compiles, not all of them. Meaningful only when "
                 "jfr_retained.rotated is false."),
    }
    if comp:
        durs = []
        for v in comp:
            per_method["by_compiler"][v.get("compiler")] = \
                per_method["by_compiler"].get(v.get("compiler"), 0) + 1
            lvl = str(v.get("compileLevel"))
            per_method["by_level"][lvl] = per_method["by_level"].get(lvl, 0) + 1
            d = parse_duration(v.get("duration"))
            if d is not None:
                durs.append(d)
        if durs:
            per_method["max_duration_ms"] = max(durs)

    # --- compiler config ---
    conf = {}
    cc = by_type.get("jdk.CompilerConfiguration", [])
    if cc:
        v = cc[0]
        conf = {
            "tiered_compilation": v.get("tieredCompilation"),
            "compiler_thread_count": v.get("threadCount"),
            "dynamic_compiler_thread_count": v.get("dynamicCompilerThreadCount"),
        }

    detail_present = {
        et.split(".")[-1]: any(e["type"] == et for e in events)
        for et in ("jdk.CompilerInlining", "jdk.CompilerPhase", "jdk.MethodTiming")
    }

    c2 = queue.get("c2", {})
    evidence = {
        "schema": "c2-jit-evidence/v1",
        "run_id": os.path.basename(run_dir.rstrip("/")),
        "target_id": target_id(run_dir),
        "source_jfr": os.path.basename(jfr),
        "tool": "tools/extract-c2-jit-evidence.py",
        "jfr_retained": {
            "jfr_size_mb": jfr_size_mb,
            "span_seconds": span,
            "chunks": chunks,
            "configured_warmup_seconds": warm_s,
            "configured_measurement_seconds": meas_s,
            "configured_run_seconds": cfg,
            "rotated": rotated,
            "covers_warmup": (not rotated) if cfg else None,
            "measurement_window_retained": measurement_retained,
        },
        "compiler_configuration": conf,
        "compiler_statistics_cumulative": stats,
        "compiler_queue": queue,
        "per_method_compilation": per_method,
        "deoptimization_events": len(by_type.get("jdk.Deoptimization", [])),
        "detail_events_present": detail_present,
        "warm_at_window_end": c2.get("tail_idle"),
        "note": ("Derived compiler signal only. Cumulative CompilerStatistics survive "
                 "JFR rotation (last-value-wins); the CompilerQueueUtilization series and "
                 "per-method Compilation events do not. When jfr_retained.rotated is true, "
                 "warm_at_window_end reflects only the retained tail, not the warmup ramp."),
    }
    return evidence, None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for run_dir in sys.argv[1:]:
        ev, err = derive(run_dir)
        if err:
            print(f"SKIP {run_dir}: {err}", file=sys.stderr)
            continue
        out = os.path.join(run_dir, "c2-jit-evidence.json")
        with open(out, "w") as f:
            json.dump(ev, f, indent=2)
            f.write("\n")
        c2 = ev["compiler_queue"].get("c2", {})
        cs = ev["compiler_statistics_cumulative"]
        print(f"WROTE {out}  target={ev['target_id']} rotated={ev['jfr_retained']['rotated']} "
              f"c2_peak={c2.get('peak_queue_size')} c2_live_max={c2.get('max_live_queue_size')} "
              f"compiles={cs.get('compile_count')} jit_ms={cs.get('total_time_spent_ms')} "
              f"per_method={ev['per_method_compilation']['events_captured']}")


if __name__ == "__main__":
    main()
