#!/usr/bin/env python3
"""Generate the SVG charts for the 2026-06-20 entity-read-by-id report.

Self-contained (no matplotlib). Data is inlined from the run artifacts under
results/raw/guided/<ts>/ (timestamps cited per series). Re-run to regenerate:
    python3 results/reports/assets/make-charts.py
"""
import os, html
OUT = os.path.dirname(os.path.abspath(__file__))

def hbar(fname, title, rows, unit, note="", lower_is_better=False):
    """rows: list of (label, value, color). Horizontal bars."""
    W, rowh, top, left, right = 760, 46, 70, 210, 90
    H = top + rowh * len(rows) + 50
    vmax = max(v for _, v, _ in rows) * 1.18
    barw = W - left - right
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'font-family="Verdana,Helvetica,sans-serif" viewBox="0 0 {W} {H}">']
    p.append(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
    p.append(f'<text x="{W//2}" y="28" text-anchor="middle" font-size="16" font-weight="bold">{html.escape(title)}</text>')
    arrow = "lower is better ↓" if lower_is_better else "higher is better ↑"
    p.append(f'<text x="{W//2}" y="46" text-anchor="middle" font-size="11" fill="#666">{arrow}</text>')
    for i, (label, val, color) in enumerate(rows):
        y = top + i * rowh
        w = barw * val / vmax
        p.append(f'<text x="{left-10}" y="{y+22}" text-anchor="end" font-size="12">{html.escape(label)}</text>')
        p.append(f'<rect x="{left}" y="{y+6}" width="{w:.1f}" height="26" fill="{color}" rx="2"/>')
        p.append(f'<text x="{left+w+8:.1f}" y="{y+24}" font-size="12" font-weight="bold" fill="#222">{val:g} {unit}</text>')
    if note:
        p.append(f'<text x="{left}" y="{H-16}" font-size="10.5" fill="#888">{html.escape(note)}</text>')
    p.append('</svg>')
    open(os.path.join(OUT, fname), "w").write("\n".join(p))
    print("wrote", fname)

def grouped_log_latency(fname, title, percentiles, series, note=""):
    """series: list of (name, color, {pct: ms}). Log-y grouped bars over percentiles."""
    import math
    W, top, left, bottom = 820, 70, 70, 70
    plot_h, H = 360, 70 + 360 + bottom
    plot_w = W - left - 30
    allv = [v for _, _, d in series for v in d.values() if v > 0]
    vmin, vmax = min(allv), max(allv)
    lo, hi = math.floor(math.log10(vmin)), math.ceil(math.log10(vmax))
    def y(v):
        if v <= 0: v = vmin
        return top + plot_h * (1 - (math.log10(v) - lo) / (hi - lo))
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'font-family="Verdana,Helvetica,sans-serif" viewBox="0 0 {W} {H}">']
    p.append(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
    p.append(f'<text x="{W//2}" y="28" text-anchor="middle" font-size="16" font-weight="bold">{html.escape(title)}</text>')
    p.append(f'<text x="{W//2}" y="46" text-anchor="middle" font-size="11" fill="#666">log scale · latency in ms · lower is better ↓</text>')
    # gridlines (decades)
    for e in range(lo, hi + 1):
        gy = y(10**e); val = 10**e
        lbl = f"{val:g} ms" if val >= 1 else f"{val*1000:g} µs"
        p.append(f'<line x1="{left}" y1="{gy:.1f}" x2="{left+plot_w}" y2="{gy:.1f}" stroke="#eee"/>')
        p.append(f'<text x="{left-8}" y="{gy+4:.1f}" text-anchor="end" font-size="10" fill="#999">{lbl}</text>')
    n_groups, n_series = len(percentiles), len(series)
    gw = plot_w / n_groups
    bw = gw * 0.72 / n_series
    for gi, pct in enumerate(percentiles):
        gx = left + gi * gw + gw * 0.14
        p.append(f'<text x="{left+gi*gw+gw/2:.1f}" y="{top+plot_h+18}" text-anchor="middle" font-size="11">{html.escape(pct)}</text>')
        for si, (sname, color, d) in enumerate(series):
            v = d.get(pct)
            if not v: continue
            bx = gx + si * bw; by = y(v); bh = top + plot_h - by
            p.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bw-2:.1f}" height="{bh:.1f}" fill="{color}" rx="1"><title>{html.escape(sname)} {pct}: {v} ms</title></rect>')
    # legend
    lx = left + 10
    for sname, color, _ in series:
        p.append(f'<rect x="{lx}" y="{top+4}" width="12" height="12" fill="{color}"/>')
        p.append(f'<text x="{lx+16}" y="{top+14}" font-size="11">{html.escape(sname)}</text>')
        lx += 14 + 8 * len(sname) + 24
    if note:
        p.append(f'<text x="{left}" y="{H-16}" font-size="10.5" fill="#888">{html.escape(note)}</text>')
    p.append('</svg>')
    open(os.path.join(OUT, fname), "w").write("\n".join(p))
    print("wrote", fname)

EX, QK, SP = "#2563eb", "#dc2626", "#9ca3af"  # exeris blue, quarkus red, spring grey

# 1. CPU per request (the durable differentiator) — n=3 interleaved, host-net, warmed, 5 cores
hbar("chart-cpu-per-request.svg",
     "CPU per request — entity-read-by-id (host-net, warmed, n=3)",
     [("Exeris", 0.3585, EX), ("Quarkus", 0.541, QK), ("Spring", 0.956, SP)],
     "ms/req", lower_is_better=True,
     note="process %CPU / throughput, pidstat aggregate · Exeris/Quarkus mean of 3 interleaved (CV<1.5%) · Spring single ref · dev-laptop")

# 2. Throughput — same n=3 interleaved set
hbar("chart-throughput.svg",
     "Throughput — entity-read-by-id (h2load, saturation, host-net, warmed, n=3)",
     [("Exeris", 9374, EX), ("Quarkus", 8068, QK), ("Spring", 3052, SP)],
     "rps",
     note="h2load saturation · Exeris/Quarkus mean of 3 interleaved (CV<1.3%) · Exeris not app-CPU-bound (69%) so this is a lower bound · Spring single ref")

# 3. Coordinated omission: same Exeris target, two experiments
grouped_log_latency("chart-coordinated-omission.svg",
     "Same target, two experiments: why a saturated percentile isn't latency (Exeris)",
     ["p50", "p99"],
     [("h2load @ saturation (closed-loop)", "#f59e0b", {"p50": 146.0, "p99": 247.0}),
      ("wrk2 sub-saturation (CO-free)", EX, {"p50": 2.95, "p99": 8.19})],
     note="h2load p50≈in-flight/throughput (Little's law: 1276≈1280 streams) — queueing, not service time · runs 114151Z vs 123114Z")

# 4. CO-free latency Exeris vs Quarkus, matched 6000 rps
grouped_log_latency("chart-latency-matched.svg",
     "CO-free latency at matched load (6000 rps) — Exeris vs Quarkus",
     ["p50", "p90", "p99", "p99.9"],
     [("Exeris", EX, {"p50": 6.73, "p90": 11.29, "p99": 18.05, "p99.9": 43.26}),
      ("Quarkus", QK, {"p50": 6.48, "p90": 11.18, "p99": 46.78, "p99.9": 142.46})],
     note="wrk2, at_saturation=false · median ≈ equal (noise-dominated), tail favors Exeris · runs 125344Z vs 130014Z")

print("done")
