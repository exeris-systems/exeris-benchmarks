#!/usr/bin/env python3
"""Render the three SVG charts for the 2026-08-11 Spring hosting/ORM report.

WHY A SCRIPT AND NOT HAND-DRAWN SVG

Every number in that report is re-derivable from committed artefacts, and a chart is a claim
like any other. These read the same leaves the prose reads, so a chart cannot silently drift
from the table above it. Run it after any campaign re-analysis and diff the output.

    tools/render-report-charts-20260811.py [--out results/reports/assets]

Charts, and what each is FOR (a chart that only decorates is not worth its bytes):

  1. chart-2026-08-11-latency-ladder.svg
     §7.1/7.2. The finding is a SHAPE across six rungs -- spring-jdbc flat, spring-hibernate
     rising -- and a shape is the one thing a 36-cell table communicates badly. p99 is drawn as
     an ab-ba BAND, never a point, per §7's reporting rule; the four outlying cells are ringed
     rather than smoothed, per §7.1.

  2. chart-2026-08-11-footprint-states.svg
     §6b. Idle RSS is not one number per arm -- it depends on whether the process has ever
     served -- and the 1.9x-5.5x spread is what the prose needs three paragraphs to establish.
     spring-hibernate's missing first-touch bar is drawn as an explicit gap, not omitted.

  3. chart-2026-08-11-hot-methods.svg
     §5. Deliberately NOT a flamegraph. Frame width in a flame reads as cost attribution, and
     §5's whole point is that the pair moves two things (Hibernate AND Spring Data projection
     proxies) whose split is UNMEASURED (L10). A ranked bar chart shows the same evidence
     without implying a complete decomposition. Raw .jfr lives on the perf box, not in this
     repo; the committed jfr-views/*.hot-methods.txt is the input here.

House style follows the 2026-07-2x assets: 1200px, slate-900 ground, Verdana stack.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "results", "raw", "entity-read-by-id")
CURVE = os.path.join(RAW, "20260811T063920Z-l5-curve-orm")
LADDER = os.path.join(RAW, "20260806T183034Z-spring-ladder-n3")
ORM = os.path.join(RAW, "20260810T131208Z-hibernate-vs-jdbc-n3")

BG, FG, DIM, GRID = "#0f172a", "#f8fafc", "#94a3b8", "#334155"
TXT = "#cbd5e1"
COLOR = {
    "spring-hibernate": "#f59e0b",
    "spring-jdbc": "#22d3ee",
    "spring-on-exeris-pure": "#a78bfa",
    "spring-on-exeris-pure-native": "#34d399",
    "exeris-community": "#f472b6",
}
SHORT = {
    "spring-hibernate": "spring-hibernate",
    "spring-jdbc": "spring-jdbc",
    "spring-on-exeris-pure": "on-exeris-pure",
    "spring-on-exeris-pure-native": "on-exeris-pure-native",
    "exeris-community": "exeris-community",
}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def head(w, h, label):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" font-family="Verdana,Helvetica,sans-serif" '
        f'role="img" aria-label="{esc(label)}">\n<rect width="{w}" height="{h}" fill="{BG}"/>\n'
    )


def title(x, y, t, sub):
    s = f'<text x="{x}" y="{y}" font-size="17" font-weight="bold" fill="{FG}">{esc(t)}</text>\n'
    s += f'<text x="{x}" y="{y+20}" font-size="11" fill="{DIM}">{esc(sub)}</text>\n'
    return s


# --------------------------------------------------------------------------- data


def jq(path, expr):
    out = subprocess.run(["jq", "-r", expr, path], capture_output=True, text=True)
    return out.stdout.strip()


def load_latency():
    """(contract, rung, arm) -> {metric: [ab, ba]} from the wrk2 curve leaves."""
    d = defaultdict(lambda: defaultdict(list))
    for ct in ("heavy", "light"):
        base = os.path.join(CURVE, ct)
        if not os.path.isdir(base):
            continue
        for rd in sorted(os.listdir(base)):
            m = re.match(r"rung-(\d+)rps", rd)
            if not m:
                continue
            rung = int(m.group(1))
            for direction in ("ab", "ba"):
                for slot in ("target-a", "target-b"):
                    f = os.path.join(base, rd, "1-hibernate-vs-jdbc", "run01",
                                     direction, slot, "result.json")
                    if not os.path.isfile(f):
                        continue
                    with open(f) as fh:
                        r = json.load(fh)
                    arm = r["run_config"]["target_contract"]["target_id"]
                    mt = r["metrics"]
                    d[(ct, rung, arm)]["p50"].append(mt["latency_p50_us"] / 1000.0)
                    d[(ct, rung, arm)]["p99"].append(mt["latency_p99_us"] / 1000.0)
    return d


def load_rss():
    """(state, arm) -> mean MB. States: FIRSTTOUCH, SERVED, LOADED (heavy contract)."""
    acc = defaultdict(list)
    for root, _dirs, files in os.walk(LADDER):
        if "/heavy/" not in root + "/":
            continue
        if "resource-metrics.json" in files and "result.json" in files:
            with open(os.path.join(root, "result.json")) as fh:
                arm = json.load(fh)["run_config"]["target_contract"]["target_id"]
            with open(os.path.join(root, "resource-metrics.json")) as fh:
                acc[("LOADED", arm)].append(json.load(fh)["rss_kb_avg"] / 1024.0)
        if "neighbour-resource-metrics.meta.json" in files:
            parent, slot = os.path.split(root)
            direction = os.path.basename(parent)
            other = "target-b" if slot == "target-a" else "target-a"
            sib = os.path.join(parent, other, "result.json")
            if not os.path.isfile(sib):
                continue
            with open(sib) as fh:
                arm = json.load(fh)["run_config"]["target_contract"]["target_id"]
            # A never-served neighbour is observable in exactly one position: the FIRST window
            # of the ab direction, which samples target-b. Instances persist across ab/ba, so
            # ba yields no cold reading at all (see the report's 6b).
            state = "FIRSTTOUCH" if (direction == "ab" and slot == "target-a") else "SERVED"
            with open(os.path.join(root, "neighbour-resource-metrics.json")) as fh:
                acc[(state, arm)].append(json.load(fh)["rss_kb_avg"] / 1024.0)
    return {k: sum(v) / len(v) for k, v in acc.items() if v}


def load_hot(arm, top=10):
    f = os.path.join(ORM, "jfr-views", f"repeat01-heavy-ab-{arm}.hot-methods.txt")
    rows = []
    with open(f) as fh:
        for line in fh:
            m = re.match(r"^(\S.*?)\s{2,}([\d,]+)\s+([\d.]+)%\s*$", line.rstrip())
            if m:
                rows.append((m.group(1).strip(), float(m.group(3))))
    return rows[:top]


# --------------------------------------------------------------------------- chart 1


def chart_latency(data, out):
    W, H = 1200, 560
    s = head(W, H, "Service-time latency ladder, ORM axis, both contracts")
    s += title(24, 34,
               "Service-time latency across the rate ladder — the arms diverge in headroom, not in cost",
               "open-loop wrk2, 36/36 leaves comparison_eligible, min rate_attainment 99.55 % · "
               "p99 drawn as an ab–ba RANGE, never a point (n=2 per cell = two directions, "
               "not two repeats — no restart variance, see §2.4)")

    panels = [("heavy", 70, "heavy contract (3 queries, ~9.2 KB)", 16.0),
              ("light", 640, "light contract (1 PK row, ~125 B)", 4.5)]
    plot_y0, plot_h = 130, 340

    for ct, px, ptitle, ymax in panels:
        pw = 470
        rungs = sorted({r for (c, r, _a) in data if c == ct})
        s += f'<text x="{px}" y="{plot_y0-22}" font-size="13" font-weight="bold" fill="{FG}">{esc(ptitle)}</text>\n'
        # grid + y axis
        steps = 8
        for i in range(steps + 1):
            v = ymax * i / steps
            y = plot_y0 + plot_h - plot_h * i / steps
            s += f'<line x1="{px}" y1="{y:.1f}" x2="{px+pw}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>\n'
            s += f'<text x="{px-8}" y="{y+4:.1f}" font-size="10" fill="{DIM}" text-anchor="end">{v:.1f}</text>\n'
        s += f'<text x="{px-46}" y="{plot_y0-6}" font-size="10" fill="{DIM}">ms</text>\n'

        def X(i):
            return px + 34 + (pw - 60) * i / max(1, len(rungs) - 1)

        def Y(v):
            return plot_y0 + plot_h - plot_h * min(v, ymax) / ymax

        for i, r in enumerate(rungs):
            s += (f'<text x="{X(i):.1f}" y="{plot_y0+plot_h+18}" font-size="10" fill="{DIM}" '
                  f'text-anchor="middle">{r:,}</text>\n'.replace(",", " "))
        s += (f'<text x="{px+pw/2:.0f}" y="{plot_y0+plot_h+38}" font-size="10" fill="{DIM}" '
              f'text-anchor="middle">offered rps</text>\n')

        for arm in ("spring-jdbc", "spring-hibernate"):
            col = COLOR[arm]
            band, mid, p50 = [], [], []
            for i, r in enumerate(rungs):
                cell = data.get((ct, r, arm))
                if not cell:
                    continue
                lo, hi = min(cell["p99"]), max(cell["p99"])
                band.append((X(i), Y(lo), Y(hi)))
                mid.append((X(i), Y(sum(cell["p99"]) / len(cell["p99"]))))
                p50.append((X(i), Y(sum(cell["p50"]) / len(cell["p50"]))))
            if not band:
                continue
            up = " ".join(f"{x:.1f},{hi:.1f}" for x, _lo, hi in band)
            dn = " ".join(f"{x:.1f},{lo:.1f}" for x, lo, _hi in reversed(band))
            s += f'<polygon points="{up} {dn}" fill="{col}" fill-opacity="0.18"/>\n'
            s += ('<polyline points="' + " ".join(f"{x:.1f},{y:.1f}" for x, y in mid) +
                  f'" fill="none" stroke="{col}" stroke-width="2.5"/>\n')
            s += ('<polyline points="' + " ".join(f"{x:.1f},{y:.1f}" for x, y in p50) +
                  f'" fill="none" stroke="{col}" stroke-width="1.6" stroke-dasharray="4,3"/>\n')
            for x, lo, hi in band:
                s += f'<line x1="{x:.1f}" y1="{lo:.1f}" x2="{x:.1f}" y2="{hi:.1f}" stroke="{col}" stroke-width="1.6"/>\n'
            # ring the outlying cells: ab-ba p99 ratio far outside its neighbours'
            for i, r in enumerate(rungs):
                cell = data.get((ct, r, arm))
                if not cell:
                    continue
                lo, hi = min(cell["p99"]), max(cell["p99"])
                if lo > 0 and hi / lo >= 1.6:
                    s += (f'<circle cx="{X(i):.1f}" cy="{Y(hi):.1f}" r="6" fill="none" '
                          f'stroke="{FG}" stroke-width="1.6"/>\n')

    lx, ly = 70, 522
    s += f'<line x1="{lx}" y1="{ly-4}" x2="{lx+26}" y2="{ly-4}" stroke="{COLOR["spring-hibernate"]}" stroke-width="2.5"/>'
    s += f'<text x="{lx+34}" y="{ly}" font-size="11" fill="{TXT}">spring-hibernate — p99 (band = ab–ba)</text>'
    s += f'<line x1="{lx+330}" y1="{ly-4}" x2="{lx+356}" y2="{ly-4}" stroke="{COLOR["spring-jdbc"]}" stroke-width="2.5"/>'
    s += f'<text x="{lx+364}" y="{ly}" font-size="11" fill="{TXT}">spring-jdbc — p99</text>'
    s += (f'<line x1="{lx+540}" y1="{ly-4}" x2="{lx+566}" y2="{ly-4}" stroke="{TXT}" stroke-width="1.6" '
          f'stroke-dasharray="4,3"/><text x="{lx+574}" y="{ly}" font-size="11" fill="{TXT}">p50 (mean)</text>')
    s += (f'<circle cx="{lx+700}" cy="{ly-4}" r="6" fill="none" stroke="{FG}" stroke-width="1.6"/>'
          f'<text x="{lx+712}" y="{ly}" font-size="11" fill="{TXT}">single-leaf excursion — §7.1, no claim rests on these</text>')
    s += "</svg>\n"
    with open(out, "w") as fh:
        fh.write(s)
    return out


# --------------------------------------------------------------------------- chart 2


def chart_rss(rss, out):
    W, H = 1200, 470
    s = head(W, H, "Footprint by traffic history and under load")
    s += title(24, 34,
               'Footprint — "idle RSS" is not one number per arm',
               "ladder campaign, bridge, 48/48 units comparison_eligible · every arm pinned "
               "-Xms1280m -Xmx1280m with AlwaysPreTouch off, so bars are pages TOUCHED at a common "
               "committed heap, not memory required · loaded = heavy contract")

    arms = ["exeris-community", "spring-on-exeris-pure-native", "spring-on-exeris-pure", "spring-hibernate"]
    states = [("FIRSTTOUCH", "resident, never served", 0.30),
              ("SERVED", "resident, after serving", 0.62),
              ("LOADED", "under load (heavy)", 1.0)]
    x0, y0, ph, gw = 90, 110, 250, 250
    ymax = 1800.0
    for i in range(7):
        v = ymax * i / 6
        y = y0 + ph - ph * i / 6
        s += f'<line x1="{x0}" y1="{y:.1f}" x2="{x0+4*gw-30}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>\n'
        s += f'<text x="{x0-8}" y="{y+4:.1f}" font-size="10" fill="{DIM}" text-anchor="end">{v:.0f}</text>\n'
    s += f'<text x="{x0-60}" y="{y0-8}" font-size="10" fill="{DIM}">RSS MB</text>\n'
    # committed heap reference
    yh = y0 + ph - ph * 1280.0 / ymax
    s += (f'<line x1="{x0}" y1="{yh:.1f}" x2="{x0+4*gw-30}" y2="{yh:.1f}" stroke="{FG}" '
          f'stroke-width="1.2" stroke-dasharray="6,4"/>\n'
          f'<text x="{x0+4*gw-26}" y="{yh+4:.1f}" font-size="10" fill="{FG}">1280 MB committed heap</text>\n')

    bw = 56
    for ai, arm in enumerate(arms):
        gx = x0 + 22 + ai * gw
        for si, (st, _lbl, shade) in enumerate(states):
            v = rss.get((st, arm))
            bx = gx + si * (bw + 10)
            if v is None:
                s += (f'<rect x="{bx}" y="{y0+ph-46}" width="{bw}" height="46" fill="none" '
                      f'stroke="{DIM}" stroke-width="1.2" stroke-dasharray="3,3"/>\n')
                s += (f'<text x="{bx+bw/2:.0f}" y="{y0+ph-52}" font-size="9" fill="{DIM}" '
                      f'text-anchor="middle">not</text>'
                      f'<text x="{bx+bw/2:.0f}" y="{y0+ph-42}" font-size="9" fill="{DIM}" '
                      f'text-anchor="middle">observable</text>\n')
                continue
            bh = ph * v / ymax
            s += (f'<rect x="{bx}" y="{y0+ph-bh:.1f}" width="{bw}" height="{bh:.1f}" '
                  f'fill="{COLOR[arm]}" fill-opacity="{shade}"/>\n')
            s += (f'<text x="{bx+bw/2:.0f}" y="{y0+ph-bh-6:.1f}" font-size="10" fill="{TXT}" '
                  f'text-anchor="middle">{v:.0f}</text>\n')
        ft, sv = rss.get(("FIRSTTOUCH", arm)), rss.get(("SERVED", arm))
        ratio = f"{sv/ft:.1f}× on traffic history" if ft and sv else "no first-touch reading"
        s += (f'<text x="{gx+(3*bw+20)/2:.0f}" y="{y0+ph+20}" font-size="11" font-weight="bold" '
              f'fill="{FG}" text-anchor="middle">{esc(SHORT[arm])}</text>\n')
        s += (f'<text x="{gx+(3*bw+20)/2:.0f}" y="{y0+ph+36}" font-size="10" fill="{DIM}" '
              f'text-anchor="middle">{esc(ratio)}</text>\n')

    ly = 418
    for si, (_st, lbl, shade) in enumerate(states):
        lx = 90 + si * 340
        s += f'<rect x="{lx}" y="{ly-10}" width="16" height="12" fill="{TXT}" fill-opacity="{shade}"/>'
        s += f'<text x="{lx+24}" y="{ly}" font-size="11" fill="{TXT}">{esc(lbl)}</text>'
    s += (f'<text x="24" y="452" font-size="10" fill="{DIM}">'
          + esc("spring-hibernate has no never-served reading: that state is observable only in the first "
                "window of the ab direction, which samples target-b, and it is target-a in both its pairs. "
                "Alternating target-a across repeats would close the gap at no cost.")
          + "</text>")
    s += "</svg>\n"
    with open(out, "w") as fh:
        fh.write(s)
    return out


# --------------------------------------------------------------------------- chart 3


SPRING_RE = re.compile(r"^org\.springframework\.(aop|core)\.")


def chart_hot(hib, jdbc, out):
    W, H = 1200, 560
    s = head(W, H, "Top on-CPU Java methods, ORM pair, heavy contract")
    s += title(24, 34,
               "Where the heavy request actually spends CPU — top on-CPU Java methods",
               "JFR ExecutionSample, repeat01 heavy ab, 874 s window, 20 chunks (not rotated) · "
               "percentages are share of Java on-CPU samples, NOT cost attribution · "
               "deliberately not a flamegraph — see the note below")

    for col, (rows, arm) in enumerate([(hib, "spring-hibernate"), (jdbc, "spring-jdbc")]):
        px = 40 + col * 590
        pw = 540
        s += (f'<text x="{px}" y="104" font-size="13" font-weight="bold" fill="{COLOR[arm]}">'
              f'{esc(arm)}</text>\n')
        vmax = max(r[1] for r in rows) if rows else 1.0
        for i, (name, pct) in enumerate(rows):
            y = 126 + i * 38
            short = name if len(name) <= 74 else name[:71] + "…"
            hi = SPRING_RE.match(name) is not None
            s += (f'<text x="{px}" y="{y}" font-size="10" '
                  f'fill="{FG if hi else TXT}">{esc(short)}</text>\n')
            bw = (pw - 60) * pct / vmax
            s += (f'<rect x="{px}" y="{y+5}" width="{bw:.1f}" height="12" fill="{COLOR[arm]}" '
                  f'fill-opacity="{0.95 if hi else 0.45}"/>\n')
            s += (f'<text x="{px+bw+8:.1f}" y="{y+15}" font-size="10" fill="{TXT}">{pct:.2f}%</text>\n')

    s += (f'<text x="40" y="506" font-size="11" fill="{FG}">'
          + esc("Highlighted rows are org.springframework.aop / .core frames — Spring Data's "
                "projection-proxy machinery, above Hibernate's own tuple materialisation.")
          + "</text>")
    s += (f'<text x="40" y="528" font-size="10" fill="{DIM}">'
          + esc("This is NOT a flamegraph on purpose. Frame width in a flame reads as a complete cost "
                "decomposition, and the pair moves TWO things at once — Hibernate and Spring Data "
                "projections — whose split is unmeasured (L10, §8). A ranked list shows the same evidence "
                "without implying the split.")
          + "</text>")
    s += (f'<text x="40" y="546" font-size="10" fill="{DIM}">'
          + esc("Source: committed jfr-views/*.hot-methods.txt. Raw .jfr is on the perf box, not in this "
                "repo (size); it is available on request and a flamegraph can be generated from it.")
          + "</text>")
    s += "</svg>\n"
    with open(out, "w") as fh:
        fh.write(s)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "results", "reports", "assets"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    lat = load_latency()
    if not lat:
        print("ERROR: no latency leaves found under " + CURVE, file=sys.stderr)
        return 1
    rss = load_rss()
    hib, jdbc = load_hot("spring-hibernate"), load_hot("spring-jdbc")

    for p in (
        chart_latency(lat, os.path.join(a.out, "chart-2026-08-11-latency-ladder.svg")),
        chart_rss(rss, os.path.join(a.out, "chart-2026-08-11-footprint-states.svg")),
        chart_hot(hib, jdbc, os.path.join(a.out, "chart-2026-08-11-hot-methods.svg")),
    ):
        print(f"wrote {os.path.relpath(p, REPO)}  ({os.path.getsize(p):,} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
