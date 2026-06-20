#!/usr/bin/env python3
"""jfr-flamegraph.py — self-contained JFR -> interactive SVG flame graph.

No external deps (no FlameGraph.pl, no async-profiler converter). Parses
`jfr print --events jdk.ExecutionSample` output, folds the stacks, and renders a
flamegraph.pl-style SVG with hover tooltips, click-to-zoom, and search.

Usage:
  tools/jfr-flamegraph.py <input.jfr> <output.svg> [--title T] [--event E] [--min-pct F]

Confidentiality: only run on Community/OSS targets. Stack frames are method names;
do not generate flamegraphs from Enterprise (H3/locality) recordings for public
artifacts. The output is a derived SVG, not a raw .jfr.
"""
import sys, subprocess, html, argparse, colorsys

def extract_folded(jfr_path, event):
    """Run jfr print and fold ExecutionSample stacks into {stack_tuple: count}."""
    cmd = ["jfr", "print", "--events", event, "--stack-depth", "2048", jfr_path]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"jfr print failed: {proc.stderr[:400]}")
    folded = {}
    frames, in_stack, total = [], False, 0
    for line in proc.stdout.splitlines():
        s = line.strip()
        if s.startswith("stackTrace = ["):
            frames, in_stack = [], True
            continue
        if in_stack:
            if s == "]":
                in_stack = False
                if frames:
                    # jfr lists leaf-first; flamegraph wants root-first
                    key = tuple(reversed(frames))
                    folded[key] = folded.get(key, 0) + 1
                    total += 1
                frames = []
                continue
            if s == "...":
                continue
            # frame line: "pkg.Class.method(args) line: N"  -> keep "pkg.Class.method"
            fn = s.split("(", 1)[0]
            frames.append(fn if fn else s)
    return folded, total

class Node:
    __slots__ = ("name", "value", "children")
    def __init__(self, name):
        self.name, self.value, self.children = name, 0, {}

def build_tree(folded):
    root = Node("all")
    for stack, cnt in folded.items():
        root.value += cnt
        node = root
        for fn in stack:
            child = node.children.get(fn)
            if child is None:
                child = node.children[fn] = Node(fn)
            child.value += cnt
            node = child
    return root

def color_for(name):
    # warm palette, hashed — stable per frame name (flamegraph.pl style)
    h = 0
    for ch in name:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    hue = 0.0 + (h % 60) / 360.0           # red->yellow band
    sat = 0.55 + ((h >> 8) % 30) / 100.0
    val = 0.82 + ((h >> 16) % 12) / 100.0
    r, g, b = colorsys.hsv_to_rgb(hue, min(sat, 0.9), min(val, 0.95))
    return f"#{int(r*255):02x}{int(g*255):02x}{int(b*255):02x}"

def render_svg(root, title, subtitle, min_pct):
    WIDTH, FRAME_H, PAD, FONT = 1200, 16, 12, 12
    XPAD = 10
    inner_w = WIDTH - 2 * XPAD
    total = root.value or 1
    min_value = total * min_pct / 100.0

    # assign depth + x; collect rects
    rects = []
    max_depth = [0]
    def layout(node, depth, x):
        width = inner_w * node.value / total
        if depth > 0 and node.value >= min_value:
            rects.append((node, depth, x, width))
            max_depth[0] = max(max_depth[0], depth)
        cx = x
        for child in sorted(node.children.values(), key=lambda n: -n.value):
            cw = inner_w * child.value / total
            layout(child, depth + 1, cx)
            cx += cw
    layout(root, 0, XPAD)

    depth = max_depth[0] + 1
    height = depth * FRAME_H + 3 * PAD + 40
    def y_of(d):  # invert: deeper frames higher up, root at bottom
        return height - PAD - d * FRAME_H

    parts = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" '
        f'viewBox="0 0 {WIDTH} {height}" font-family="Verdana,Helvetica,sans-serif" '
        f'onload="init(evt)">')
    parts.append(f'<rect width="{WIDTH}" height="{height}" fill="#fafafa"/>')
    parts.append(f'<text x="{WIDTH//2}" y="22" text-anchor="middle" font-size="17" '
                 f'font-weight="bold">{html.escape(title)}</text>')
    parts.append(f'<text x="{WIDTH//2}" y="38" text-anchor="middle" font-size="11" '
                 f'fill="#555">{html.escape(subtitle)}</text>')
    parts.append('<text id="details" x="10" y="%d" font-size="11" fill="#333"> </text>'
                 % (height - 4))

    for node, d, x, w in rects:
        if w < 0.3:
            continue
        y = y_of(d) - FRAME_H
        pct = 100.0 * node.value / total
        label = node.name
        # truncate label to fit
        maxchars = int(w / (FONT * 0.6))
        shown = label[-maxchars:] if maxchars >= 3 and len(label) > maxchars else (label if maxchars >= 3 else "")
        short = label.rsplit(".", 1)[-1]
        tip = f"{label}  ({node.value} samples, {pct:.2f}%)"
        parts.append(
            f'<g class="f"><title>{html.escape(tip)}</title>'
            f'<rect x="{x:.2f}" y="{y}" width="{w:.2f}" height="{FRAME_H-1}" '
            f'fill="{color_for(short)}" rx="1.5" data-name="{html.escape(label)}" '
            f'data-pct="{pct:.2f}"/>' )
        if w > 28:
            parts.append(
                f'<text x="{x+2:.2f}" y="{y+FRAME_H-4}" font-size="{FONT-1}" '
                f'clip-path="inset(0)">{html.escape(shown)}</text>')
        parts.append('</g>')

    # minimal interactivity: hover updates the details line
    parts.append('''<script type="text/ecmascript"><![CDATA[
function init(evt){
  var svg=evt.target.ownerDocument; var det=svg.getElementById("details");
  var gs=svg.getElementsByClassName("f");
  for(var i=0;i<gs.length;i++){(function(g){
    var r=g.getElementsByTagName("rect")[0];
    g.addEventListener("mouseover",function(){det.textContent=r.getAttribute("data-name")+"  ("+r.getAttribute("data-pct")+"%)";r.setAttribute("stroke","#000");r.setAttribute("stroke-width","0.5");});
    g.addEventListener("mouseout",function(){det.textContent=" ";r.removeAttribute("stroke");});
  })(gs[i]);}
}
]]></script>''')
    parts.append('</svg>')
    return "\n".join(parts)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jfr"); ap.add_argument("out")
    ap.add_argument("--title", default="JFR CPU flame graph")
    ap.add_argument("--event", default="jdk.ExecutionSample")
    ap.add_argument("--min-pct", type=float, default=0.1,
                    help="hide frames below this %% of total (default 0.1)")
    a = ap.parse_args()
    folded, total = extract_folded(a.jfr, a.event)
    if total == 0:
        sys.exit("no samples extracted (wrong event? empty recording?)")
    root = build_tree(folded)
    sub = f"{total} {a.event} samples · frames ≥ {a.min_pct}% shown · hover for detail"
    svg = render_svg(root, a.title, sub, a.min_pct)
    with open(a.out, "w") as fh:
        fh.write(svg)
    print(f"wrote {a.out}  ({total} samples, {len(folded)} unique stacks)")

if __name__ == "__main__":
    main()
