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
import sys, os, re, subprocess, html, argparse, colorsys

# Allowlists used to validate untrusted CLI input before it reaches the `jfr`
# OS command or the filesystem. _EVENT_RE = dotted identifier (jdk.ExecutionSample);
# _PATH_SAFE_RE = no leading '-' (so an arg can't be read as an option) and no
# shell-meta / whitespace. This regex validation is the sanitization boundary.
_EVENT_RE = re.compile(r"[A-Za-z][\w.]*\Z")
_PATH_SAFE_RE = re.compile(r"[\w./@+][\w./@+-]*\Z")

def validate_inputs(jfr_path, event):
    """Reject any untrusted value that isn't a plain event id / safe file path
    before it is passed to the OS command."""
    if not _EVENT_RE.fullmatch(event):
        sys.exit(f"invalid event name: {event!r}")
    if not _PATH_SAFE_RE.fullmatch(jfr_path):
        sys.exit(f"unsafe jfr path: {jfr_path!r}")
    if not os.path.isfile(jfr_path):
        sys.exit(f"not a readable file: {jfr_path!r}")

def fold_stacks(stdout):
    """Fold `jfr print` stackTrace blocks into {root-first stack tuple: count}."""
    folded, frames, in_stack, total = {}, [], False, 0
    for line in stdout.splitlines():
        s = line.strip()
        if s.startswith("stackTrace = ["):
            frames, in_stack = [], True
        elif not in_stack:
            continue
        elif s == "]":
            in_stack = False
            if frames:
                key = tuple(reversed(frames))  # jfr is leaf-first; flamegraph wants root-first
                folded[key] = folded.get(key, 0) + 1
                total += 1
            frames = []
        elif s != "...":
            fn = s.split("(", 1)[0]  # "pkg.Class.method(args) line: N" -> "pkg.Class.method"
            frames.append(fn if fn else s)
    return folded, total

def extract_folded(jfr_path, event):
    """Run jfr print and fold ExecutionSample stacks into {stack_tuple: count}."""
    validate_inputs(jfr_path, event)
    cmd = ["jfr", "print", "--events", event, "--stack-depth", "2048", jfr_path]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"jfr print failed: {proc.stderr[:400]}")
    return fold_stacks(proc.stdout)

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

# flamegraph.pl-style interactive JS: click-to-zoom, regexp search + "Matched %",
# Reset Zoom, hover detail. Faithful adaptation of Brendan Gregg's flamegraph.pl
# (CDDL/Apache-2.0) to the SVG structure this script emits.
FLAMEGRAPH_JS = r'''
var details, searchbtn, unzoombtn, matchedtxt, svg, searching;
var nametype = "Function:", fontsize = 11, fontwidth = 0.59,
    xpad = 10, inverted = 0, searchcolor = "rgb(230,0,230)";
function init(evt) {
    details = document.getElementById("details").firstChild;
    searchbtn = document.getElementById("search");
    unzoombtn = document.getElementById("unzoom");
    matchedtxt = document.getElementById("matched");
    svg = document.getElementsByTagName("svg")[0];
    searching = 0;
}
function s(node) { details.nodeValue = nametype + " " + g_to_text(node); }
function c() { details.nodeValue = " "; }
function find_child(node, sel) { var c = node.querySelectorAll(sel); return c.length ? c[0] : undefined; }
function orig_save(e, attr, val) {
    if (e.getAttribute("_orig_" + attr) != null) return;
    if (e.getAttribute(attr) == null) return;
    if (val == undefined) val = e.getAttribute(attr);
    e.setAttribute("_orig_" + attr, val);
}
function orig_load(e, attr) {
    if (e.getAttribute("_orig_" + attr) == null) return;
    e.setAttribute(attr, e.getAttribute("_orig_" + attr));
    e.removeAttribute("_orig_" + attr);
}
function g_to_text(e) { return find_child(e, "title").firstChild.nodeValue; }
function g_to_func(e) { var f = g_to_text(e); if (f != null) f = f.replace(/ .*/, ""); return f; }
function update_text(e) {
    var r = find_child(e, "rect"), t = find_child(e, "text");
    if (!r || !t) return;
    var w = parseFloat(r.getAttribute("width")) - 3;
    var txt = find_child(e, "title").textContent.replace(/ .*/, "");
    t.setAttribute("x", parseFloat(r.getAttribute("x")) + 3);
    if (w < 2 * fontsize * fontwidth) { t.textContent = ""; return; }
    t.textContent = txt;
    var sl = t.getSubStringLength(0, txt.length);
    if (/^ *$/.test(txt) || sl < w) return;
    for (var x = txt.length - 2; x > 0; x--) {
        if (t.getSubStringLength(0, x + 2) <= w) { t.textContent = txt.substring(0, x) + ".."; return; }
    }
    t.textContent = "";
}
function zoom_reset(e) {
    if (e.attributes != undefined) { orig_load(e, "x"); orig_load(e, "width"); }
    if (e.childNodes == undefined) return;
    for (var i = 0, c = e.childNodes; i < c.length; i++) zoom_reset(c[i]);
}
function zoom_child(e, x, ratio) {
    if (e.attributes != undefined) {
        if (e.getAttribute("x") != null) {
            orig_save(e, "x");
            e.setAttribute("x", (parseFloat(e.getAttribute("x")) - x - xpad) * ratio + xpad);
            if (e.tagName == "text")
                e.setAttribute("x", parseFloat(find_child(e.parentNode, "rect[x]").getAttribute("x")) + 3);
        }
        if (e.getAttribute("width") != null) {
            orig_save(e, "width");
            e.setAttribute("width", parseFloat(e.getAttribute("width")) * ratio);
        }
    }
    if (e.childNodes == undefined) return;
    for (var i = 0, c = e.childNodes; i < c.length; i++) zoom_child(c[i], x - xpad, ratio);
}
function zoom_parent(e) {
    if (e.attributes) {
        if (e.getAttribute("x") != null) { orig_save(e, "x"); e.setAttribute("x", xpad); }
        if (e.getAttribute("width") != null) {
            orig_save(e, "width");
            e.setAttribute("width", parseInt(svg.width.baseVal.value) - xpad * 2);
        }
    }
    if (e.childNodes == undefined) return;
    for (var i = 0, c = e.childNodes; i < c.length; i++) zoom_parent(c[i]);
}
function zoom(node) {
    var attr = find_child(node, "rect");
    var width = parseFloat(attr.getAttribute("width"));
    var xmin = parseFloat(attr.getAttribute("x"));
    var xmax = xmin + width;
    var ymin = parseFloat(attr.getAttribute("y"));
    var ratio = (svg.width.baseVal.value - 2 * xpad) / width;
    var fudge = 0.0001;
    unzoombtn.classList.remove("hide");
    var el = document.getElementsByTagName("g");
    for (var i = 0; i < el.length; i++) {
        var e = el[i], a = find_child(e, "rect");
        if (!a) continue;
        var ex = parseFloat(a.getAttribute("x")), ew = parseFloat(a.getAttribute("width"));
        var upstack = inverted == 0 ? parseFloat(a.getAttribute("y")) > ymin
                                    : parseFloat(a.getAttribute("y")) < ymin;
        if (upstack) {
            if (ex <= xmin && (ex + ew + fudge) >= xmax) { e.classList.add("parent"); zoom_parent(e); update_text(e); }
            else e.classList.add("hide");
        } else {
            if (ex < xmin || ex + fudge >= xmax) e.classList.add("hide");
            else { zoom_child(e, xmin, ratio); update_text(e); }
        }
    }
}
function unzoom() {
    unzoombtn.classList.add("hide");
    var el = document.getElementsByTagName("g");
    for (var i = 0; i < el.length; i++) {
        el[i].classList.remove("parent"); el[i].classList.remove("hide");
        zoom_reset(el[i]); update_text(el[i]);
    }
}
function reset_search() {
    var el = document.querySelectorAll("rect");
    for (var i = 0; i < el.length; i++) orig_load(el[i], "fill");
}
function search_prompt() {
    if (!searching) {
        var term = prompt("Enter a search term (regexp allowed, e.g. ^jdk\\.proxy or Postgres)", "");
        if (term != null) search(term);
    } else {
        reset_search(); searching = 0;
        searchbtn.firstChild.nodeValue = "Search";
        searchbtn.style.opacity = "0.4";
        matchedtxt.classList.add("hide"); matchedtxt.firstChild.nodeValue = "";
    }
}
function search(term) {
    var re = new RegExp(term);
    var el = document.getElementsByTagName("g"), matches = {}, maxwidth = 0;
    for (var i = 0; i < el.length; i++) {
        var e = el[i];
        if (e.getAttribute("class") != "func_g") continue;
        var func = g_to_func(e), rect = find_child(e, "rect");
        if (func == null || rect == null) continue;
        var w = parseFloat(rect.getAttribute("width"));
        if (w > maxwidth) maxwidth = w;
        if (func.match(re)) {
            var x = parseFloat(rect.getAttribute("x"));
            orig_save(rect, "fill"); rect.setAttribute("fill", searchcolor);
            if (matches[x] == undefined || w > matches[x]) matches[x] = w;
            searching = 1;
        }
    }
    if (!searching) return;
    searchbtn.firstChild.nodeValue = "Reset Search";
    searchbtn.style.opacity = "1.0";
    var count = 0, lastx = -1, lastw = 0, keys = [];
    for (var k in matches) if (matches.hasOwnProperty(k)) keys.push(k);
    keys.sort(function(a, b) { return a - b; });
    var fudge = 0.0001;
    for (var k in keys) {
        var x = parseFloat(keys[k]), w = matches[keys[k]];
        if (x >= lastx + lastw - fudge) { count += w; lastx = x; lastw = w; }
    }
    matchedtxt.classList.remove("hide");
    var pct = 100 * count / maxwidth;
    matchedtxt.firstChild.nodeValue = "Matched: " + (pct == 100 ? "100" : pct.toFixed(1)) + "%";
}
'''

def render_svg(root, title, subtitle, min_pct):
    WIDTH, FRAME_H, PAD, FONT = 1200, 16, 12, 11
    XPAD = 10
    inner_w = WIDTH - 2 * XPAD
    total = root.value or 1
    min_value = total * min_pct / 100.0

    # assign depth + x; collect rects (root frame at depth 0 included, like flamegraph.pl)
    rects = []
    max_depth = [0]
    def layout(node, depth, x):
        if node.value >= min_value:
            rects.append((node, depth, x, inner_w * node.value / total))
            max_depth[0] = max(max_depth[0], depth)
        cx = x
        for child in sorted(node.children.values(), key=lambda n: -n.value):
            layout(child, depth + 1, cx)
            cx += inner_w * child.value / total
    layout(root, 0, XPAD)

    n_levels = max_depth[0] + 1
    top_ui = 56                               # room for title/subtitle/buttons
    height = n_levels * FRAME_H + top_ui + 2 * PAD + 18
    def y_of(d):  # invert: deeper frames higher up, root at bottom
        return height - PAD - 18 - d * FRAME_H

    e = html.escape
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" '
        f'viewBox="0 0 {WIDTH} {height}" onload="init(evt)">',
        '<style>\n'
        '  text { font-family: Verdana, Helvetica, sans-serif; }\n'
        '  .func_g { cursor: pointer; }\n'
        '  .func_g:hover rect { stroke: #000; stroke-width: 0.5; }\n'
        '  .hide { display: none; }\n'
        '  #search, #unzoom { font-size: 12px; fill: #0a3; font-weight: bold; cursor: pointer; }\n'
        '  #search { opacity: 0.4; }\n'
        '  #matched { font-size: 11px; fill: #333; }\n'
        '</style>',
        f'<rect width="{WIDTH}" height="{height}" fill="#fafafa"/>',
        f'<text x="{WIDTH//2}" y="22" text-anchor="middle" font-size="17" font-weight="bold">{e(title)}</text>',
        f'<text x="{WIDTH//2}" y="38" text-anchor="middle" font-size="11" fill="#555">{e(subtitle)}</text>',
        f'<text id="details" x="10" y="{height-5}"> </text>',
        '<text id="unzoom" class="hide" onclick="unzoom()" x="10" y="50">Reset Zoom</text>',
        f'<text id="search" onclick="search_prompt()" x="{WIDTH-90}" y="50">Search</text>',
        f'<text id="matched" class="hide" x="{WIDTH-340}" y="{height-5}"> </text>',
    ]

    for node, d, x, w in rects:
        if w < 0.2:
            continue
        y = y_of(d) - FRAME_H
        pct = 100.0 * node.value / total
        label = node.name
        short = label.rsplit(".", 1)[-1]
        # flamegraph.pl-style prefix truncation; JS update_text re-truncates on zoom
        maxchars = int(w / (FONT * 0.59))
        if w < 2 * FONT * 0.59:
            shown = ""
        elif len(label) > maxchars:
            shown = (label[:maxchars - 2] + "..") if maxchars > 2 else ""
        else:
            shown = label
        tip = f"{label} ({node.value} samples, {pct:.2f}%)"
        parts.append(
            f'<g class="func_g" onmouseover="s(this)" onmouseout="c()" onclick="zoom(this)">'
            f'<title>{e(tip)}</title>'
            f'<rect x="{x:.2f}" y="{y}" width="{w:.2f}" height="{FRAME_H-1}" '
            f'fill="{color_for(short)}" rx="1.5"/>'
            f'<text x="{x+3:.2f}" y="{y+FRAME_H-4}" font-size="{FONT-1}">{e(shown)}</text>'
            f'</g>')

    parts.append('<script><![CDATA[' + FLAMEGRAPH_JS + ']]></script>')
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
    sub = (f"{total} {a.event} samples · frames ≥ {a.min_pct}% shown · "
           f"click to zoom · Search for regexp highlight · Reset Zoom to restore")
    svg = render_svg(root, a.title, sub, a.min_pct)
    # Validate the (untrusted) output path before touching the filesystem: same
    # allowlist as the inputs, and its parent directory must already exist.
    if not _PATH_SAFE_RE.fullmatch(a.out):
        sys.exit(f"unsafe output path: {a.out!r}")
    out_dir = os.path.dirname(os.path.abspath(a.out)) or "."
    if not os.path.isdir(out_dir):
        sys.exit(f"output directory does not exist: {out_dir}")
    with open(a.out, "w") as fh:
        fh.write(svg)
    print(f"wrote {a.out}  ({total} samples, {len(folded)} unique stacks)")

if __name__ == "__main__":
    main()
