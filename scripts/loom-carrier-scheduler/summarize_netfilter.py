#!/usr/bin/env python3
"""Tabulate a run-netfilter-check.sh directory: one row per cell, then tracked against notrack per arm.

Each arm's two levels are compared with the exact two-sided Mann-Whitney test from stats.py. A trial
whose recorded raw table disagrees with its cell (the rules missing under notrack, or present under
tracked) is listed and left out.

Usage: summarize_netfilter.py <netfilter-dir>   writes summary.md into it.
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

from stats import mann_whitney

MEASUREMENT_EXCLUDED = ("load", "harness_clean", "host_shielded", "host_untracked")
TAG = "loom-carrier-scheduler-notrack"


def med(v):
    v = [x for x in v if x is not None]
    return statistics.median(v) if v else None


def main(root):
    root = Path(root)
    cells = defaultdict(list)
    invalid, mismatched = [], []
    for p in sorted(root.glob("r*/trial.json")):
        t = json.loads(p.read_text())
        _, arm, track = p.parent.name.split("-")
        raw = Path(f"{p.parent}.raw-table.txt")
        rules = raw.read_text().count(TAG) if raw.exists() else -1
        if (track == "notrack") != (rules == 2):
            mismatched.append(p.parent.name)
            continue
        if not all(g["pass"] for k, g in t["gates"].items() if k not in MEASUREMENT_EXCLUDED):
            invalid.append(p.parent.name)
            continue
        cells[(arm, track)].append(t)
    failed = sorted(d.name for d in root.iterdir() if d.is_dir() and d.name.startswith("r")
                    and not (d / "trial.json").exists())

    def p99s(ts):
        return sorted(t["load"]["percentiles_ms"]["p99"] for t in ts if t["gates"]["load"]["pass"])

    def counter(ts, k):
        return med([float(c) for t in ts
                    if (c := ((t["host"].get("counters") or {}).get("start") or {}).get(k)) not in (None, "", "n/a")])

    out = [f"# Netfilter check `{root.name}`", "", (root / "plan.txt").read_text().strip(), "",
           "p99 over sustained trials; carrier CPU, wait, CPUs utilised and conntrack entries are medians over valid trials.", "",
           "| arm | loopback | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | "
           "carrier wait max % | CPUs (perf) | conntrack entries |",
           "|:--|:--|:--|--:|:--|--:|--:|--:|--:|--:|"]
    for key in sorted(cells):
        ts = cells[key]
        v = p99s(ts)
        c = [t["pidstat"]["carriers"] for t in ts]
        perf = [t["perf_stat"] or {} for t in ts]
        out.append(f"| {key[0]} | {key[1]} | {len(ts)} / {len(v)} | {med(v) if v else '—'} | "
                   f"{', '.join(f'{x:.2f}' for x in v)} | {med([x['cpu_pct'] for x in c])} | "
                   f"{med([x['sys_pct'] for x in c])} | {med([x['wait_pct_max'] for x in c])} | "
                   f"{med([x.get('cpus_utilized') for x in perf])} | {counter(ts, 'conntrack_count')} |")

    out += ["", "## tracked against notrack", "",
            "| arm | n | p99 medians | exact MW p | P(tracked > notrack) |", "|:--|:--|:--|--:|--:|"]
    for arm in sorted({a for a, _ in cells}):
        x, y = p99s(cells.get((arm, "tracked"), [])), p99s(cells.get((arm, "notrack"), []))
        if len(x) < 2 or len(y) < 2:
            out.append(f"| {arm} | {len(x)} vs {len(y)} | — | — | — |")
            continue
        p, d = mann_whitney(x, y)
        out.append(f"| {arm} | {len(x)} vs {len(y)} | {med(x):.2f} vs {med(y):.2f} | {p:.2g} | {d:.2f} |")
    if invalid or failed or mismatched:
        out += ["", f"Invalid trials: {', '.join(invalid) or 'none'}. Trials without a record: {', '.join(failed) or 'none'}. "
                f"Rules not as the cell requires: {', '.join(mismatched) or 'none'}."]
    (root / "summary.md").write_text("\n".join(out) + "\n")
    print(root / "summary.md")


if __name__ == "__main__":
    main(sys.argv[1])
