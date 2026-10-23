#!/usr/bin/env python3
"""Tabulate a run-drift-check.sh directory: one row per cell, then each factor's effect on A_iso.

A factor's effect compares A_iso's trials at its two levels pooled over the other factor's levels
(10 against 10 at REPS=5), with the exact two-sided Mann-Whitney test from stats.py; each level of
the other factor is also shown on its own, so an interaction is visible rather than averaged away.

Usage: summarize_drift.py <drift-dir>   writes summary.md into it.
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

from stats import mann_whitney

MEASUREMENT_EXCLUDED = ("load", "harness_clean", "host_shielded", "host_untracked")


def main(root):
    root = Path(root)
    cells = defaultdict(list)
    invalid = []
    for p in sorted(root.glob("r*/trial.json")):
        t = json.loads(p.read_text())
        _, arm, pool, limits = p.parent.name.split("-")
        if not all(g["pass"] for k, g in t["gates"].items() if k not in MEASUREMENT_EXCLUDED):
            invalid.append(p.parent.name)
            continue
        cells[(arm, pool[4:], limits[2:])].append(t)
    failed = sorted(d.name for d in root.iterdir() if d.is_dir() and d.name.startswith("r")
                    and not (d / "trial.json").exists())

    def p99s(ts):
        return sorted(t["load"]["percentiles_ms"]["p99"] for t in ts if t["gates"]["load"]["pass"])

    def med(v):
        v = [x for x in v if x is not None]
        return statistics.median(v) if v else None

    out = [f"# Drift check `{root.name}`", "", (root / "plan.txt").read_text().strip(), "",
           "p99 over sustained trials; carrier CPU, wait and CPUs utilised are medians over valid trials.", "",
           "| arm | pool | limits | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | "
           "carrier wait max % | CPUs (perf) | cs/s |",
           "|:--|:--|:--|:--|--:|:--|--:|--:|--:|--:|--:|"]
    for key in sorted(cells):
        ts = cells[key]
        v = p99s(ts)
        c = [t["pidstat"]["carriers"] for t in ts]
        perf = [t["perf_stat"] or {} for t in ts]
        out.append(f"| {key[0]} | {key[1]} | {key[2]} | {len(ts)} / {len(v)} | "
                   f"{med(v) if v else '—'} | {', '.join(f'{x:.2f}' for x in v)} | "
                   f"{med([x['cpu_pct'] for x in c])} | {med([x['sys_pct'] for x in c])} | "
                   f"{med([x['wait_pct_max'] for x in c])} | {med([x.get('cpus_utilized') for x in perf])} | "
                   f"{med([x.get('context_switches_per_s') for x in perf])} |")

    out += ["", "## A_iso: each factor at its two levels", "",
            "| factor | compared | n | p99 medians | exact MW p | P(first > second) |", "|:--|:--|:--|:--|--:|--:|"]

    def row(label, cmp, a, b):
        x, y = p99s(a), p99s(b)
        if len(x) < 2 or len(y) < 2:
            out.append(f"| {label} | {cmp} | {len(x)} vs {len(y)} | — | — | — |")
            return
        p, d = mann_whitney(x, y)
        out.append(f"| {label} | {cmp} | {len(x)} vs {len(y)} | {med(x):.2f} vs {med(y):.2f} | {p:.2g} | {d:.2f} |")

    g = lambda pool, lim: cells.get(("A_iso", pool, lim), [])
    row("pool", "old vs new, both limits", g("old", "old") + g("old", "new"), g("new", "old") + g("new", "new"))
    for lim in ("old", "new"):
        row("pool", f"old vs new, limits {lim}", g("old", lim), g("new", lim))
    row("limits", "old vs new, both pools", g("old", "old") + g("new", "old"), g("old", "new") + g("new", "new"))
    for pool in ("old", "new"):
        row("limits", f"old vs new, pool {pool}", g(pool, "old"), g(pool, "new"))
    if invalid or failed:
        out += ["", f"Invalid trials: {', '.join(invalid) or 'none'}. Trials without a record: {', '.join(failed) or 'none'}."]
    (root / "summary.md").write_text("\n".join(out) + "\n")
    print(root / "summary.md")


if __name__ == "__main__":
    main(sys.argv[1])
