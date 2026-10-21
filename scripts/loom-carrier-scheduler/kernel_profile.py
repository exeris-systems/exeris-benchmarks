#!/usr/bin/env python3
"""Summarise a run-kernel-profile.sh directory, or compare two of them.

    kernel_profile.py summary <run-dir>            writes summary.md into it
    kernel_profile.py compare <run-a> <run-b>      prints a comparison (markdown) to stdout

A run's state is described by its clean A_iso trials (p99, carrier CPU and kernel share), its host
counters, and the kernel symbols of its profiled trials. Symbol shares are percentages of all
samples on the carrier CPUs, averaged over a cell's profiled trials, so a symbol that grows
between two runs is extra time spent there, not a reshuffle of a fixed kernel share. Profiled
trials carry a recorder; their latencies are not compared with anything.
"""
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

LINE = re.compile(r"^\s+([\d.]+)%\s+(\S+)\s+\[([k.])\]\s+(.+?)\s*$")
COUNTERS = ("conntrack_count", "cgroup_dying_root", "cgroup_dying_bench_slice", "slab_kb", "sunreclaim_kb",
            "tcp_sockets", "tcp_timewait")


def med(v):
    v = [x for x in v if x is not None]
    return statistics.median(v) if v else None


def symbols(trial_dir):
    """Share of samples per (kind, symbol) in one profiled trial; kind 'k' is the kernel."""
    out = defaultdict(float)
    f = trial_dir / "perf-record-report.txt"
    if not f.exists():
        return None
    for line in f.read_text(errors="replace").splitlines():
        m = LINE.match(line)
        if m:
            out[(m.group(3), m.group(4))] += float(m.group(1))
    return out


def load(root):
    root = Path(root)
    cells = defaultdict(list)
    for p in sorted(root.glob("r*/trial.json")):
        t = json.loads(p.read_text())
        _, arm, kind = p.parent.name.split("-")
        t["_dir"] = p.parent
        cells[(arm, kind)].append(t)
    plan = (root / "plan.txt").read_text().strip() if (root / "plan.txt").exists() else ""
    return root, plan, cells


def state(cells):
    clean = cells.get(("A_iso", "clean"), [])
    c = [t["pidstat"]["carriers"] for t in clean]
    everyone = [t for ts in cells.values() for t in ts]
    counters = {k: med([float(t["host"]["counters"]["start"][k]) for t in everyone
                        if (t["host"].get("counters") or {}).get("start", {}).get(k, "n/a") not in ("n/a", "")])
                for k in COUNTERS}
    uptimes = [int(t["host"]["state"]["uptime_s"]) for t in everyone if t["host"]["state"].get("uptime_s")]
    return {"n_clean": len(clean),
            "p99": sorted(t["load"]["percentiles_ms"]["p99"] for t in clean if t["gates"]["load"]["pass"]),
            "carrier_cpu": med([x["cpu_pct"] for x in c]), "carrier_sys": med([x["sys_pct"] for x in c]),
            "carrier_wait": med([x["wait_pct_max"] for x in c]),
            "uptime_h": (min(uptimes) / 3600, max(uptimes) / 3600) if uptimes else None,
            "counters": counters}


def profile(cells, arm):
    per = [s for s in (symbols(t["_dir"]) for t in cells.get((arm, "profiled"), [])) if s is not None]
    if not per:
        return None, 0
    keys = set().union(*per)
    return {k: sum(s.get(k, 0.0) for s in per) / len(per) for k in keys}, len(per)


def fmt(v, d=2):
    return "—" if v is None else f"{v:.{d}f}"


def state_lines(name, s):
    up = f"{s['uptime_h'][0]:.1f}–{s['uptime_h'][1]:.1f} h" if s["uptime_h"] else "not recorded"
    return [f"- **{name}**: uptime {up}; clean `A_iso` p99 {', '.join(f'{x:.2f}' for x in s['p99']) or '—'} ms "
            f"(n = {s['n_clean']}); carrier CPU {fmt(s['carrier_cpu'])} %, sys {fmt(s['carrier_sys'])} %, "
            f"wait {fmt(s['carrier_wait'])} %",
            "  - host counters at window start (median): "
            + ", ".join(f"{k} {fmt(v, 0)}" for k, v in s["counters"].items())]


def summary(root):
    root, plan, cells = load(root)
    s = state(cells)
    out = [f"# Kernel profile `{root.name}`", "", plan, ""] + state_lines("state", s) + [""]
    for arm in ("A_iso", "D"):
        prof, n = profile(cells, arm)
        if not prof:
            continue
        kernel = sum(v for (k, _), v in prof.items() if k == "k")
        out += [f"## `{arm}`, profiled (n = {n}): kernel {kernel:.1f} % of carrier-CPU samples", "",
                "| symbol | kind | % of samples |", "|:--|:--|--:|"]
        for (kind, sym), v in sorted(prof.items(), key=lambda kv: -kv[1])[:25]:
            out.append(f"| `{sym}` | {'kernel' if kind == 'k' else 'user'} | {v:.2f} |")
        out.append("")
    (root / "summary.md").write_text("\n".join(out) + "\n")
    print(root / "summary.md")


def compare(a, b):
    ra, _, ca = load(a)
    rb, _, cb = load(b)
    out = [f"# Kernel profile: `{ra.name}` (A) against `{rb.name}` (B)", ""]
    out += state_lines("A", state(ca)) + state_lines("B", state(cb)) + [""]
    for arm in ("A_iso", "D"):
        pa, na = profile(ca, arm)
        pb, nb = profile(cb, arm)
        if not pa or not pb:
            continue
        ka = sum(v for (k, _), v in pa.items() if k == "k")
        kb = sum(v for (k, _), v in pb.items() if k == "k")
        out += [f"## `{arm}`: kernel {ka:.1f} % (A, n = {na}) against {kb:.1f} % (B, n = {nb}) of carrier-CPU samples",
                "", "Kernel symbols by growth from A to B, in points of all carrier-CPU samples.", "",
                "| symbol | A % | B % | B − A |", "|:--|--:|--:|--:|"]
        keys = {k for k in set(pa) | set(pb) if k[0] == "k"}
        rows = sorted(((pb.get(k, 0.0) - pa.get(k, 0.0), k) for k in keys), reverse=True)
        for d, k in rows[:20] + [r for r in rows[-5:] if r not in rows[:20]]:
            out.append(f"| `{k[1]}` | {pa.get(k, 0.0):.2f} | {pb.get(k, 0.0):.2f} | {d:+.2f} |")
        out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "summary":
        summary(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
