#!/usr/bin/env python3
"""Render the SVG figures for the 2026-10-16 loom-carrier-scheduler capacity report.

WHY A SCRIPT AND NOT HAND-DRAWN SVG

A chart is a claim like any other. These read the same trial.json and pidstat files the report's
tables come from, so a figure cannot drift from the table beside it. Run it after any re-analysis
of the two capacity campaigns and diff the output.

    tools/render-report-charts-20261016.py [--out results/reports/assets]

Figures, and what each is FOR:

  1. chart-2026-10-16-capacity-ladder.svg
     §2-§4. Every valid trial's p99 on both ladders, per arm and rate, with the p99 objective
     drawn across. Capacity is read off this picture: the highest rate below which every cell's
     median sits under the line and every trial kept up. Per-trial strips show what a median
     hides -- the pinned arms' split at I/O-bound 70 %, a single outlier inside a passing cell.
     Log scale: the tails span three decades. Trials that did not sustain their rate are drawn
     hollow at the p99 they reported.

  2. chart-2026-10-16-mock-cpu-70.svg
     §5. The mock backend's CPU per second at I/O-bound 70 %, every trial of every ladder arm.
     The first report saw the backend jump near second 53 under D only; the question this
     campaign could answer is whether it follows the custom scheduler or the pinning, and a
     line per trial in four panels answers it in one look.

House style follows the 2026-10-14 report's assets: 1200 px wide, slate-900 ground, Verdana stack.
"""

import argparse
import json
import math
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "results", "raw", "loom-carrier-scheduler")
CPU = os.path.join(RAW, "20261016T002844Z-jdk-kbc26f9a0e8fc")
IO = os.path.join(RAW, "20261016T034438Z-jdk-kbc26f9a0e8fc")

BG, FG, DIM, GRID, TXT = "#0f172a", "#f8fafc", "#94a3b8", "#334155", "#cbd5e1"
LADDER_ARMS = ("A_iso", "B_pin", "C_iso", "D")
COLOR = {"A_iso": "#f59e0b", "B_float": "#f472b6", "B_pin": "#a78bfa", "C_iso": "#22d3ee", "D": "#34d399"}
LABEL = {"A_iso": "A_iso — stock pool, floating",
         "B_float": "B_float — stock pool via the SPI, floating",
         "B_pin": "B_pin — stock pool, pinned 1:1",
         "C_iso": "C_iso — custom scheduler, floating",
         "D": "D — custom scheduler, pinned 1:1"}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def head(w, h, label):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
            f'font-family="Verdana,Helvetica,sans-serif" role="img" aria-label="{esc(label)}">\n'
            f'<rect width="{w}" height="{h}" fill="{BG}"/>\n')


def title(x, y, t, sub):
    return (f'<text x="{x}" y="{y}" font-size="17" font-weight="bold" fill="{FG}">{esc(t)}</text>\n'
            f'<text x="{x}" y="{y + 20}" font-size="11" fill="{DIM}">{esc(sub)}</text>\n')


def text(x, y, t, size=11, fill=TXT, anchor="start", weight="normal"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" text-anchor="{anchor}" '
            f'font-weight="{weight}">{esc(t)}</text>\n')


def legend(x, y, items, step=225):
    s = ""
    for arm in items:
        s += f'<circle cx="{x}" cy="{y - 4}" r="5" fill="{COLOR[arm]}"/>' + text(x + 12, y, LABEL[arm], 10)
        x += step
    return s


def median(v):
    v = sorted(v)
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


# --------------------------------------------------------------------------- data

def campaign(path):
    with open(os.path.join(path, "campaign.json")) as fh:
        c = json.load(fh)
    return c, [int(r) for r in c["rates"].split()], [round(float(f) * 100) for f in c["fractions"].split()]


def trials(path):
    out = []
    for d in sorted(os.listdir(path)):
        f = os.path.join(path, d, "trial.json")
        if not d.startswith("r") or not os.path.isfile(f):
            continue
        with open(f) as fh:
            t = json.load(fh)
        if not t["valid"]:
            continue
        out.append({"dir": d, "arm": t["arm"], "rate": int(t["rate"]),
                    "sustained": t.get("sustained", t["gates"]["load"]["pass"]),
                    "p99": t["load"]["percentiles_ms"]["p99"]})
    return out


def mock_cpu(path, trial_dir):
    out = []
    with open(os.path.join(path, trial_dir, "pidstat-mock.txt")) as fh:
        for line in fh:
            f = line.split()
            if f and re.match(r"^\d\d:\d\d:\d\d$", f[0]) and f[-1] == "java":
                out.append(float(f[7]))
    return out


# --------------------------------------------------------------------------- 1. capacity ladder

def log_axis(lo, hi):
    ticks = []
    for e in range(int(math.floor(math.log10(lo))), int(math.ceil(math.log10(hi))) + 1):
        for m in (1, 2, 5):
            v = m * 10 ** e
            if lo <= v <= hi:
                ticks.append(v)
    return ticks


def ladder_panel(px, py, pw, ph, data, rates, fractions, slo, lo, hi, ptitle):
    s = text(px, py - 14, ptitle, 13, FG, weight="bold")

    def Y(v):
        return py + ph - (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * ph

    for v in log_axis(lo, hi):
        s += f'<line x1="{px}" y1="{Y(v):.1f}" x2="{px + pw}" y2="{Y(v):.1f}" stroke="{GRID}" stroke-width="1"/>\n'
        s += text(px - 8, Y(v) + 4, f"{v:g}", 10, DIM, "end")
    s += text(px - 8, py - 14, "p99 ms", 10, DIM, "end")
    s += (f'<line x1="{px}" y1="{Y(slo):.1f}" x2="{px + pw}" y2="{Y(slo):.1f}" stroke="{FG}" '
          f'stroke-width="1.4" stroke-dasharray="8,5"/>\n')
    s += text(px + pw - 4, Y(slo) - 6, f"objective: p99 ≤ {slo:g} ms", 10, FG, "end", "bold")
    gw = pw / len(rates)
    for i, rate in enumerate(rates):
        gx = px + i * gw
        if i:
            s += f'<line x1="{gx:.1f}" y1="{py}" x2="{gx:.1f}" y2="{py + ph}" stroke="{GRID}" stroke-dasharray="2,4"/>\n'
        s += text(gx + gw / 2, py + ph + 18, f"{fractions[i]} %", 11, TXT, "middle", "bold")
        s += text(gx + gw / 2, py + ph + 32, f"{rate:,}", 9, DIM, "middle")
        arms = [a for a in ("A_iso", "B_float", "B_pin", "C_iso", "D")
                if any(t["rate"] == rate and t["arm"] == a for t in data)]
        for j, arm in enumerate(arms):
            cx = gx + gw * (j + 1) / (len(arms) + 1)
            pts = sorted((t for t in data if t["rate"] == rate and t["arm"] == arm), key=lambda t: t["dir"])
            for k, t in enumerate(pts):
                x = cx + ((k % 5) - 2) * 2.6
                y = Y(min(max(t["p99"], lo), hi))
                if t["sustained"]:
                    s += f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.2" fill="{COLOR[arm]}" fill-opacity="0.85"/>\n'
                else:
                    s += (f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="none" stroke="{COLOR[arm]}" '
                          f'stroke-width="1.5"/>\n')
            sus = [t["p99"] for t in pts if t["sustained"]]
            if sus:
                m = median(sus)
                s += (f'<line x1="{cx - 9:.1f}" y1="{Y(min(m, hi)):.1f}" x2="{cx + 9:.1f}" y2="{Y(min(m, hi)):.1f}" '
                      f'stroke="{FG}" stroke-width="2"/>\n')
    return s


def chart_ladder(out):
    (ccpu, rcpu, fcpu), (cio, rio, fio) = campaign(CPU), campaign(IO)
    W, H = 1200, 900
    s = head(W, H, "p99 per trial on the capacity ladders, both regimes")
    s += title(24, 34, "Both pinned arms hold the objective to 95 % with a 1 ms backend; the floating arms stop at 50 %",
               "every valid trial's wrk2 p99 (open loop, CO-corrected), 5 fresh JVMs per arm and rate · white bar = "
               "median of sustained trials · hollow = did not sustain the rate · rates are fractions of A_iso's "
               "saturation in the same campaign")
    s += ladder_panel(90, 112, 1080, 300, trials(CPU), rcpu, fcpu, ccpu["slo_p99_ms"], 1.5, 3000,
                      "CPU-bound · 1 ms backend · 100 connections · campaign 20261016T002844Z")
    s += ladder_panel(90, 512, 1080, 300, trials(IO), rio, fio, cio["slo_p99_ms"], 20, 10000,
                      "I/O-bound · 30 ms backend · 5,000 connections · campaign 20261016T034438Z")
    s += legend(90, 872, ("A_iso", "B_float", "B_pin", "C_iso", "D"))
    s += "</svg>\n"
    with open(out, "w") as fh:
        fh.write(s)


# --------------------------------------------------------------------------- 2. mock CPU at 70 %

def chart_mock(out):
    _, rates, _ = campaign(IO)
    rate = rates[1]
    io = trials(IO)
    W, H = 1200, 560
    s = head(W, H, "Mock backend CPU per second at I/O-bound 70 percent")
    s += title(24, 34, "At I/O-bound 70 % the backend jumps under both pinned arms, and under neither floating one",
               f"mock JVM CPU per second of the measurement window (pidstat; two CPUs, so 200 % is its ceiling) · "
               f"one line per trial, 5 fresh JVMs per arm, {rate:,} req/s · campaign 20261016T034438Z")
    py, ph, pw = 110, 340, 240
    lo, hi = 100, 210
    for i, arm in enumerate(LADDER_ARMS):
        px = 80 + i * 285
        s += text(px, py - 14, LABEL[arm], 11, COLOR[arm], weight="bold")

        def Y(v):
            return py + ph - (min(max(v, lo), hi) - lo) / (hi - lo) * ph

        def X(k):
            return px + k / 59 * pw
        for v in range(lo, hi + 1, 25):
            s += f'<line x1="{px}" y1="{Y(v):.1f}" x2="{px + pw}" y2="{Y(v):.1f}" stroke="{GRID}"/>\n'
            s += text(px - 6, Y(v) + 4, f"{v}", 10, DIM, "end")
        s += f'<line x1="{px}" y1="{Y(200):.1f}" x2="{px + pw}" y2="{Y(200):.1f}" stroke="{DIM}" stroke-dasharray="6,4"/>\n'
        for sec in (0, 15, 30, 45, 53, 59):
            s += text(X(sec), py + ph + 16, f"{sec}", 10, FG if sec == 53 else DIM, "middle")
        s += (f'<line x1="{X(53):.1f}" y1="{py}" x2="{X(53):.1f}" y2="{py + ph}" stroke="{DIM}" '
              f'stroke-dasharray="2,4"/>\n')
        for t in sorted((t for t in io if t["arm"] == arm and t["rate"] == rate), key=lambda t: t["dir"]):
            v = mock_cpu(IO, t["dir"])[:60]
            pts = " ".join(f"{X(k):.1f},{Y(x):.1f}" for k, x in enumerate(v))
            s += (f'<polyline points="{pts}" fill="none" stroke="{COLOR[arm]}" stroke-width="1.3" '
                  f'stroke-opacity="0.8"/>\n')
        s += text(px + pw / 2, py + ph + 34, "second of the measurement window", 10, DIM, "middle")
    s += text(80, 522, "B_pin: all five trials rise from ~130 % to 159–199 % between seconds 47 and 53; D: four of five to 182–198 % at second 53, "
              "and the fifth, without the jump, is D's fastest trial.", 10, DIM)
    s += text(80, 538, "A_iso and C_iso never exceed 146 %. At 75 % and above no arm's mock jumps; "
              "the event belongs to pinned carriers at this rate, not to the custom scheduler.", 10, DIM)
    s += "</svg>\n"
    with open(out, "w") as fh:
        fh.write(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "results", "reports", "assets"))
    a = ap.parse_args()
    chart_ladder(os.path.join(a.out, "chart-2026-10-16-capacity-ladder.svg"))
    chart_mock(os.path.join(a.out, "chart-2026-10-16-mock-cpu-70.svg"))
    print(f"wrote 2 charts to {a.out}")


if __name__ == "__main__":
    main()
