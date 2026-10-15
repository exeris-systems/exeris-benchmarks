#!/usr/bin/env python3
"""Render the SVG figures for the 2026-10-14 loom-carrier-scheduler report.

WHY A SCRIPT AND NOT HAND-DRAWN SVG

A chart is a claim like any other. These read the same trial.json and load.txt files the report's
tables come from, so a figure cannot drift from the table beside it. Run it after any re-analysis
of the two campaigns and diff the output.

    tools/render-report-charts-20261014.py [--out results/reports/assets]

Figures, and what each is FOR:

  1. chart-2026-10-14-topology.svg
     §1. Where every thread runs and which way a request goes. The report's mechanism discussion
     (§5) is about which thread waits on which CPU, and in pollerMode=3 the read sub-pollers live
     on the carriers, not with the other pollers: a reader needs that picture before §5 means
     anything. Not data; drawn from the harness's fixed layout.

  2. chart-2026-10-14-p99-ladder.svg
     §2-§4. Every sustained trial's p99, per arm and rate, both regimes. The finding is a shape --
     nothing separates at 50 %, complete separation at 85-90 %, D split in two at I/O-bound 70 % --
     and a per-trial strip shows separation and bimodality, which medians hide. Log scale: the
     tails span two decades. Trials that did not sustain their rate are drawn hollow at the p99
     they reported; they are outside every percentile in the text.

  3. chart-2026-10-14-wait-vs-p99.svg
     §5.1. Carrier run-queue wait against p99, per trial, in the near-capacity cells. It shows
     what the text claims and no more: pinned carriers sit at zero wait, floating carriers spread,
     and the worst cell does not follow its wait.

  5. chart-2026-10-14-mock-cpu-70.svg
     §5.3/§5.5. The mock backend's CPU per second at I/O-bound 70 %, every trial of every arm. The
     D anomaly is a fixed-time event on the backend's side, and a per-second line per trial shows
     that in one look where a table of maxima cannot.

  4. chart-2026-10-14-d70-spectrum.svg
     §5.3. The percentile spectrum of D's slowest and fastest trials at I/O-bound 70 % against
     the other arms' median trials. A stall signature (flat to p95, then a ramp to the maximum)
     is a shape in the spectrum, not a number in a table.

House style follows the earlier report assets: 1200 px wide, slate-900 ground, Verdana stack.
"""

import argparse
import json
import math
import os
import re
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "results", "raw", "loom-carrier-scheduler")
CPU = os.path.join(RAW, "20261009T040618Z-jdk-kbc26f9a0e8fc")
IO = os.path.join(RAW, "20261013T191957Z-jdk-kbc26f9a0e8fc")

BG, FG, DIM, GRID, TXT = "#0f172a", "#f8fafc", "#94a3b8", "#334155", "#cbd5e1"
BOX, BOX2 = "#1e293b", "#273449"
ARMS = ("A_iso", "C_iso", "D")
COLOR = {"A_iso": "#f59e0b", "C_iso": "#22d3ee", "D": "#34d399"}
LABEL = {"A_iso": "A_iso — stock ForkJoinPool, floating",
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


def legend(x, y, items):
    s = ""
    for arm in items:
        s += f'<circle cx="{x}" cy="{y - 4}" r="5" fill="{COLOR[arm]}"/>' + text(x + 12, y, LABEL[arm])
        x += 330
    return s


# --------------------------------------------------------------------------- data

def trials(campaign):
    out = []
    for d in sorted(os.listdir(campaign)):
        f = os.path.join(campaign, d, "trial.json")
        if not d.startswith("r") or not os.path.isfile(f):
            continue
        with open(f) as fh:
            t = json.load(fh)
        if not t["valid"]:
            continue
        out.append({"dir": d, "arm": t["arm"], "rate": int(t["rate"]),
                    "sustained": t.get("sustained", t["gates"]["load"]["pass"]),
                    "p99": t["load"]["percentiles_ms"]["p99"],
                    "wait": t["pidstat"]["carriers"]["wait_pct_max"]})
    return out


def spectrum(campaign, trial_dir):
    pts, on = [], False
    with open(os.path.join(campaign, trial_dir, "load.txt")) as fh:
        for line in fh:
            if "Detailed Percentile spectrum" in line:
                on = True
                continue
            if on:
                f = line.split()
                if len(f) == 4 and re.match(r"^[\d.]+$", f[0]) and f[3] != "inf":
                    pts.append((float(f[1]), float(f[0])))
                elif line.startswith("#[Mean"):
                    break
    return pts


# --------------------------------------------------------------------------- 1. topology

def chart_topology(out):
    W, H = 1200, 660
    s = head(W, H, "Request path and CPU layout")
    s += title(24, 34, "Where every thread runs, and which way a request goes",
               "Ryzen 5 5600, 6 cores / 12 threads (SMT siblings n and n+6) · I/O-bound regime shown: "
               "5,000 client connections, 30 ms backend, backend pool 2,048 · pollerMode=3 in every arm")
    s += ('<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
          f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{FG}"/></marker></defs>\n')

    def box(x, y, w, h, head_, cpus, lines, fill=BOX, stroke=GRID):
        r = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" '
             f'stroke-width="1.5"/>\n')
        r += text(x + 14, y + 24, head_, 13, FG, weight="bold")
        r += text(x + 14, y + 42, cpus, 10, DIM)
        for i, ln in enumerate(lines):
            ly = y + 66 + i * 18
            if isinstance(ln, tuple):
                name, t = ln
                r += text(x + 14, ly, name, 11, COLOR.get(name, TXT), weight="bold")
                r += text(x + 72, ly, t, 11, TXT)
            else:
                r += text(x + 14, ly, ln, 11, TXT)
        return r

    def num(x, y, n):
        return (f'<circle cx="{x:.1f}" cy="{y:.1f}" r="8" fill="{FG}"/>'
                + text(x, y + 4, str(n), 10, BG, "middle", "bold"))

    def path(points, n, nx, ny, label, lx, ly, anchor="start"):
        r = (f'<polyline points="{" ".join(f"{x},{y}" for x, y in points)}" fill="none" stroke="{FG}" '
             f'stroke-width="1.6" marker-end="url(#ah)"/>\n')
        return r + num(nx, ny, n) + text(lx, ly, label, 10, TXT, anchor)

    s += box(24, 90, 240, 160, "Load generator", "core 4, 5 · CPUs 4, 5, 10, 11",
             ["wrk2, 4 threads, open loop", "5,000 keep-alive connections", "fixed rate, CO-corrected"])
    s += box(330, 90, 380, 200, "Server · core 0", "CPUs 0, 6 · shared with the confined host",
             ["transport reactors ×2 (Selector, FFM I/O)", "JDK Master-Poller, Write-Poller (platform)",
              "GC, JIT, VM threads", "system.slice, user.slice, init.scope, IRQs"], stroke="#64748b")
    s += box(330, 390, 380, 200, "Server · cores 2, 3", "CPUs 2, 3 · SMT siblings 8, 9 idle",
             ["carrier 0, carrier 1", "handler virtual threads, one per request",
              "read sub-pollers (pollerMode=3): one virtual", "thread per carrier, in the same queue",
              "handlers block on java.net.Socket"], stroke=COLOR["D"])
    s += box(800, 390, 376, 200, "Mock backend · core 1", "CPUs 1, 7 · separate JVM, stock scheduler",
             ["answers GET /mock after the think time:", "30 ms here, 1 ms in the CPU-bound regime"])
    s += box(800, 90, 376, 200, "Arms · two carriers each", "what differs is the scheduler and the pinning",
             [("A_iso", "stock ForkJoinPool;"), ("", "workers float over CPUs 2, 3"),
              ("C_iso", "custom: per-carrier FIFO, no stealing;"), ("", "carriers float over CPUs 2, 3"),
              ("D", "custom; carrier 0 → CPU 2,"), ("", "carrier 1 → CPU 3")], fill=BOX2)

    s += path([(264, 150), (330, 150)], 1, 297, 134, "request", 297, 170, "middle")
    s += path([(400, 290), (400, 390)], 2, 388, 340, "unpark handler", 410, 344)
    s += path([(710, 450), (800, 450)], 3, 726, 434, "GET /mock", 790, 438, "end")
    s += path([(800, 520), (710, 520)], 4, 726, 504, "reply", 790, 508, "end")
    s += path([(530, 390), (530, 290)], 5, 518, 340, "readiness", 540, 344)
    s += path([(650, 290), (650, 390)], 6, 638, 340, "wake sub-poller", 660, 330)
    s += path([(330, 560), (144, 560), (144, 250)], 7, 237, 560, "response", 237, 580, "middle")

    s += text(24, 622, "1 a request reaches a reactor · 2 the reactor unparks a handler on a carrier · 3 the handler blocks on "
              "the backend socket · 4 the reply arrives · 5 Master-Poller sees it ready · 6 and wakes that carrier's read", 10, DIM)
    s += text(24, 638, "sub-poller, which unparks the handler · 7 the handler writes the response. Under the custom scheduler "
              "(C_iso, D) the sub-poller waits in the same per-carrier FIFO as the handlers it wakes.", 10, DIM)
    s += "</svg>\n"
    open(out, "w").write(s)


# --------------------------------------------------------------------------- 2. p99 ladder

def log_axis(lo, hi):
    ticks = []
    for e in range(int(math.floor(math.log10(lo))), int(math.ceil(math.log10(hi))) + 1):
        for m in (1, 2, 5):
            v = m * 10 ** e
            if lo <= v <= hi:
                ticks.append(v)
    return ticks


def strip_panel(px, py, pw, ph, data, rates, fractions, lo, hi, ptitle):
    s = text(px, py - 14, ptitle, 13, FG, weight="bold")

    def Y(v):
        return py + ph - (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * ph

    for v in log_axis(lo, hi):
        s += f'<line x1="{px}" y1="{Y(v):.1f}" x2="{px + pw}" y2="{Y(v):.1f}" stroke="{GRID}" stroke-width="1"/>\n'
        s += text(px - 8, Y(v) + 4, f"{v:g}", 10, DIM, "end")
    s += text(px - 8, py - 14, "p99 ms", 10, DIM, "end")
    gw = pw / len(rates)
    for i, rate in enumerate(rates):
        gx = px + i * gw
        if i:
            s += f'<line x1="{gx:.1f}" y1="{py}" x2="{gx:.1f}" y2="{py + ph}" stroke="{GRID}" stroke-dasharray="2,4"/>\n'
        s += text(gx + gw / 2, py + ph + 18, f"{fractions[i]} %", 11, TXT, "middle", "bold")
        s += text(gx + gw / 2, py + ph + 32, f"{rate:,} req/s", 9, DIM, "middle")
        for j, arm in enumerate(ARMS):
            cx = gx + gw * (j + 1) / 4
            pts = sorted((t for t in data if t["rate"] == rate and t["arm"] == arm), key=lambda t: t["dir"])
            sus = sorted(t["p99"] for t in pts if t["sustained"])
            for k, t in enumerate(pts):
                x = cx + ((k % 5) - 2) * 3.2
                y = Y(min(max(t["p99"], lo), hi))
                if t["sustained"]:
                    s += f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.6" fill="{COLOR[arm]}" fill-opacity="0.85"/>\n'
                else:
                    s += (f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4.5" fill="none" stroke="{COLOR[arm]}" '
                          f'stroke-width="1.6"/>\n')
                if t["p99"] > hi:
                    s += text(x + 8, y + 4, f"↑ {t['p99']:.0f}", 9, COLOR[arm])
            if sus:
                med = sus[len(sus) // 2] if len(sus) % 2 else (sus[len(sus) // 2 - 1] + sus[len(sus) // 2]) / 2
                s += (f'<line x1="{cx - 13:.1f}" y1="{Y(med):.1f}" x2="{cx + 13:.1f}" y2="{Y(med):.1f}" '
                      f'stroke="{FG}" stroke-width="2"/>\n')
    return s


def chart_ladder(cpu, io, out):
    W, H = 1200, 600
    s = head(W, H, "p99 per trial by arm and rate, both regimes")
    s += title(24, 34, "Near capacity the pinned arm separates; at 50 % nothing does",
               "every valid trial's wrk2 p99 (open loop, CO-corrected), 10 fresh JVMs per arm and rate · white bar = "
               "median of sustained trials · hollow = did not sustain the rate (not in any percentile)")
    s += strip_panel(90, 110, 470, 400, cpu, [38000, 53200, 64600, 68400], [50, 70, 85, 90], 1.5, 100,
                     "CPU-bound · 1 ms backend · 100 connections")
    s += strip_panel(700, 110, 470, 400, io, [30900, 43300, 52600], [50, 70, 85], 20, 1500,
                     "I/O-bound · 30 ms backend · 5,000 connections")
    s += legend(90, 576, ARMS)
    s += "</svg>\n"
    open(out, "w").write(s)


# --------------------------------------------------------------------------- 3. wait vs p99

def scatter_panel(px, py, pw, ph, data, cells, lo, hi, xmax, ptitle):
    s = text(px, py - 14, ptitle, 13, FG, weight="bold")

    def X(v):
        return px + v / xmax * pw

    def Y(v):
        return py + ph - (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * ph

    for v in log_axis(lo, hi):
        s += f'<line x1="{px}" y1="{Y(v):.1f}" x2="{px + pw}" y2="{Y(v):.1f}" stroke="{GRID}"/>\n'
        s += text(px - 8, Y(v) + 4, f"{v:g}", 10, DIM, "end")
    for v in range(0, int(xmax) + 1, 2):
        s += f'<line x1="{X(v):.1f}" y1="{py}" x2="{X(v):.1f}" y2="{py + ph}" stroke="{GRID}" stroke-dasharray="2,4"/>\n'
        s += text(X(v), py + ph + 16, f"{v}", 10, DIM, "middle")
    s += text(px + pw / 2, py + ph + 34, "carrier run-queue wait, % of window (larger of the two carriers, pidstat)", 10, DIM, "middle")
    s += text(px - 8, py - 14, "p99 ms", 10, DIM, "end")
    for rate, shape in cells:
        for t in data:
            if t["rate"] != rate or not t["sustained"]:
                continue
            x, y = X(min(t["wait"], xmax)), Y(min(max(t["p99"], lo), hi))
            c = COLOR[t["arm"]]
            if shape == "o":
                s += f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{c}" fill-opacity="0.85"/>\n'
            else:
                s += f'<rect x="{x - 4:.1f}" y="{y - 4:.1f}" width="8" height="8" fill="{c}" fill-opacity="0.85"/>\n'
    return s


def chart_wait(cpu, io, out):
    W, H = 1200, 560
    s = head(W, H, "Carrier run-queue wait against p99")
    s += title(24, 34, "Pinned carriers never wait; floating ones do, and the tail only partly follows",
               "near-capacity cells, sustained trials · ● and ■ distinguish the two rates in each panel")
    s += scatter_panel(90, 110, 470, 360, cpu, [(64600, "o"), (68400, "s")], 1.5, 100, 6,
                       "CPU-bound · ● 85 %  ■ 90 %")
    s += scatter_panel(700, 110, 470, 360, io, [(43300, "o"), (52600, "s")], 20, 1500, 12,
                       "I/O-bound · ● 70 %  ■ 85 %")
    s += legend(90, 540, ARMS)
    s += "</svg>\n"
    open(out, "w").write(s)


# --------------------------------------------------------------------------- 4. D at 70 % spectrum

def chart_spectrum(io_trials, out):
    W, H = 1200, 540
    rate = 43300
    cell = defaultdict(list)
    for t in io_trials:
        if t["rate"] == rate and t["sustained"]:
            cell[t["arm"]].append(t)
    for v in cell.values():
        v.sort(key=lambda t: t["p99"])
    lines = [("D", cell["D"][-1], "D, slowest trial", None),
             ("D", cell["D"][0], "D, fastest trial", "5,4"),
             ("A_iso", cell["A_iso"][len(cell["A_iso"]) // 2], "A_iso, median trial", None),
             ("C_iso", cell["C_iso"][len(cell["C_iso"]) // 2], "C_iso, median trial", None)]
    s = head(W, H, "Latency spectrum at I/O-bound 70 percent")
    s += title(24, 34, "D at I/O-bound 70 %: flat to p95, then a steep ramp — the shape stalls leave",
               "wrk2 detailed percentile spectrum (CO-corrected) at 43,300 req/s · x is 1/(1 − percentile) on a log scale")
    px, py, pw, ph = 90, 90, 1000, 340
    lo, hi = 1, 1e5

    def X(v):
        return px + (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * pw

    ymax = 200

    def Y(v):
        return py + ph - min(v, ymax) / ymax * ph

    for v in range(0, ymax + 1, 25):
        s += f'<line x1="{px}" y1="{Y(v):.1f}" x2="{px + pw}" y2="{Y(v):.1f}" stroke="{GRID}"/>\n'
        s += text(px - 8, Y(v) + 4, f"{v}", 10, DIM, "end")
    s += text(px - 8, py - 6, "ms", 10, DIM, "end")
    for p, lbl in ((0.5, "p50"), (0.9, "p90"), (0.99, "p99"), (0.999, "p99.9"), (0.9999, "p99.99")):
        x = X(1 / (1 - p))
        s += f'<line x1="{x:.1f}" y1="{py}" x2="{x:.1f}" y2="{py + ph}" stroke="{GRID}" stroke-dasharray="2,4"/>\n'
        s += text(x, py + ph + 16, lbl, 10, DIM, "middle")
    s += f'<line x1="{px}" y1="{Y(30):.1f}" x2="{px + pw}" y2="{Y(30):.1f}" stroke="{DIM}" stroke-dasharray="6,4"/>\n'
    s += text(px + pw - 4, Y(30) - 6, "backend think time, 30 ms", 10, DIM, "end")
    ly = 470
    lx = 90
    for arm, t, lbl, dash in lines:
        pts = [(X(1 / (1 - p)), Y(v)) for p, v in spectrum(IO, t["dir"]) if p < 1 and 1 / (1 - p) <= hi]
        da = f' stroke-dasharray="{dash}"' if dash else ""
        s += (f'<polyline points="{" ".join(f"{x:.1f},{y:.1f}" for x, y in pts)}" fill="none" '
              f'stroke="{COLOR[arm]}" stroke-width="2"{da}/>\n')
        s += (f'<line x1="{lx}" y1="{ly - 4}" x2="{lx + 26}" y2="{ly - 4}" stroke="{COLOR[arm]}" stroke-width="2.5"{da}/>'
              + text(lx + 34, ly, f"{lbl} ({t['dir']}, p99 {t['p99']:.1f} ms)"))
        lx += 520
        if lx > 700:
            lx, ly = 90, ly + 20
    s += text(90, 525, "Under coordinated-omission correction a stall of length T adds requests at every latency up to T, "
              "which draws a ramp; a standing queue would lift the median instead.", 10, DIM)
    s += "</svg>\n"
    open(out, "w").write(s)


# --------------------------------------------------------------------------- 5. mock CPU at 70 %

def mock_cpu(campaign, trial_dir):
    out = []
    with open(os.path.join(campaign, trial_dir, "pidstat-mock.txt")) as fh:
        for line in fh:
            f = line.split()
            if f and re.match(r"^\d\d:\d\d:\d\d$", f[0]) and f[-1] == "java":
                out.append(float(f[7]))
    return out


def chart_mock(io_trials, out):
    W, H = 1200, 560
    rate = 43300
    s = head(W, H, "Mock backend CPU per second at I/O-bound 70 percent")
    s += title(24, 34, "At I/O-bound 70 % the mock backend, not the server, hits its limit — and only under D",
               "mock JVM CPU per second of the 60 s window (pidstat; two CPUs, so 200 % is its ceiling) · one line per "
               "trial, 10 fresh JVMs per arm · campaign 20261013T191957Z")
    panels = [(arm, 90 + i * 370) for i, arm in enumerate(ARMS)]
    py, ph, pw = 110, 340, 320
    lo, hi = 100, 210
    for arm, px in panels:
        s += text(px, py - 14, LABEL[arm].split(" — ")[0], 13, COLOR[arm], weight="bold")

        def Y(v):
            return py + ph - (min(max(v, lo), hi) - lo) / (hi - lo) * ph

        def X(i):
            return px + i / 59 * pw
        for v in range(lo, hi + 1, 25):
            s += f'<line x1="{px}" y1="{Y(v):.1f}" x2="{px + pw}" y2="{Y(v):.1f}" stroke="{GRID}"/>\n'
            s += text(px - 6, Y(v) + 4, f"{v}", 10, DIM, "end")
        s += f'<line x1="{px}" y1="{Y(200):.1f}" x2="{px + pw}" y2="{Y(200):.1f}" stroke="{DIM}" stroke-dasharray="6,4"/>\n'
        for sec in (0, 15, 30, 45, 53, 59):
            s += text(X(sec), py + ph + 16, f"{sec}", 10, FG if sec == 53 else DIM, "middle")
        s += (f'<line x1="{X(53):.1f}" y1="{py}" x2="{X(53):.1f}" y2="{py + ph}" stroke="{DIM}" '
              f'stroke-dasharray="2,4"/>\n')
        for t in sorted((t for t in io_trials if t["arm"] == arm and t["rate"] == rate), key=lambda t: t["dir"]):
            v = mock_cpu(IO, t["dir"])[:60]
            pts = " ".join(f"{X(i):.1f},{Y(x):.1f}" for i, x in enumerate(v))
            s += (f'<polyline points="{pts}" fill="none" stroke="{COLOR[arm]}" stroke-width="1.3" '
                  f'stroke-opacity="0.75"/>\n')
        s += text(px + pw / 2, py + ph + 34, "second of the measurement window", 10, DIM, "middle")
    s += text(90, 522, "D: in 9 of 10 trials the mock jumps to 165–200 % at second 53 and stays ~11 points higher; the one "
              "trial without the jump is D's fastest (p99 39 ms).", 10, DIM)
    s += text(90, 538, "A_iso and C_iso never leave 126–149 %. The server's carriers and reactors rise in the same second; "
              "in the diagnostic trials no connection churn, GC pause or pinning accompanied it (§5.5).", 10, DIM)
    s += "</svg>\n"
    open(out, "w").write(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "results", "reports", "assets"))
    a = ap.parse_args()
    cpu, io = trials(CPU), trials(IO)
    chart_topology(os.path.join(a.out, "chart-2026-10-14-topology.svg"))
    chart_ladder(cpu, io, os.path.join(a.out, "chart-2026-10-14-p99-ladder.svg"))
    chart_wait(cpu, io, os.path.join(a.out, "chart-2026-10-14-wait-vs-p99.svg"))
    chart_spectrum(io, os.path.join(a.out, "chart-2026-10-14-d70-spectrum.svg"))
    chart_mock(io, os.path.join(a.out, "chart-2026-10-14-mock-cpu-70.svg"))
    print(f"wrote 5 charts to {a.out}")


if __name__ == "__main__":
    main()
