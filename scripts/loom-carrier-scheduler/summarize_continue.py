#!/usr/bin/env python3
"""Tabulate a run-continue-check.sh directory: B_pin with a lazy onContinue against B_pin with one
that calls execute(), per regime.

Each regime's two modes are compared with the rule the reproduction arm B_float is held to
(stats.reproduction_check): the lazy trials reproduce the execute trials when the exact two-sided
Mann-Whitney p is at least 0.05 and the lazy median lies inside the execute trials' range. A trial
whose echoed mode differs from its cell fails the pinned_continue gate and is left out.

Usage: summarize_continue.py <continue-dir>   writes summary.md into it.
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

from stats import reproduction_check

MEASUREMENT_EXCLUDED = ("load", "harness_clean", "host_shielded", "host_untracked")


def med(v):
    v = [x for x in v if x is not None]
    return statistics.median(v) if v else None


def fmt(x, nd=2):
    return "—" if x is None else f"{x:,.{nd}f}"


def main(root):
    root = Path(root)
    cells = defaultdict(list)
    invalid = []
    for p in sorted(root.glob("r*/trial.json")):
        t = json.loads(p.read_text())
        _, _, mode, regime = p.parent.name.split("-")
        if t.get("pinned_continue") != mode or not all(
                g["pass"] for k, g in t["gates"].items() if k not in MEASUREMENT_EXCLUDED):
            invalid.append(p.parent.name)
            continue
        cells[(regime, mode)].append(t)
    failed = sorted(d.name for d in root.iterdir() if d.is_dir() and d.name.startswith("r")
                    and not (d / "trial.json").exists())

    def p99s(ts):
        return sorted(t["load"]["percentiles_ms"]["p99"] for t in ts if t["gates"]["load"]["pass"])

    def per_req(t, key):
        perf, rps = t.get("perf_stat") or {}, t["load"]["requests_per_sec"]
        return perf[key] / rps if perf.get(key) is not None and rps else None

    out = [f"# onContinue check `{root.name}`", "", (root / "plan.txt").read_text().strip(), "",
           "p99 over sustained trials; carrier CPU, CPUs utilised and context switches per request are medians "
           "over valid trials.", "",
           "| regime | onContinue | valid / sustained | p99 median | p99, sorted | carrier CPU % | carrier sys % | "
           "CPUs (perf) | context switches / req |",
           "|:--|:--|:--|--:|:--|--:|--:|--:|--:|"]
    for key in sorted(cells):
        ts = cells[key]
        v = p99s(ts)
        c = [t["pidstat"]["carriers"] for t in ts]
        out.append(f"| {key[0]} | {key[1]} | {len(ts)} / {len(v)} | {fmt(med(v))} | "
                   f"{', '.join(f'{x:.2f}' for x in v)} | {fmt(med([x['cpu_pct'] for x in c]))} | "
                   f"{fmt(med([x['sys_pct'] for x in c]))} | "
                   f"{fmt(med([(t['perf_stat'] or {}).get('cpus_utilized') for t in ts]), 3)} | "
                   f"{fmt(med([per_req(t, 'context_switches_per_s') for t in ts]), 3)} |")

    out += ["", "## lazy against execute", "",
            "The lazy trials against the execute trials, by B_float's reproduction rule (accepted: p ≥ 0.05 and "
            "the lazy median inside the execute range).", "",
            "| regime | n | p99 medians, lazy vs execute | exact MW p | P(lazy > execute) | lazy median inside range | verdict |",
            "|:--|:--|:--|--:|--:|:--|:--|"]
    for regime in sorted({r for r, _ in cells}):
        x, y = p99s(cells.get((regime, "lazy"), [])), p99s(cells.get((regime, "execute"), []))
        r = reproduction_check(x, y)
        if r["verdict"] == "undecided":
            out.append(f"| {regime} | {len(x)} vs {len(y)} | — | — | — | — | undecided |")
            continue
        out.append(f"| {regime} | {len(x)} vs {len(y)} | {med(x):.2f} vs {med(y):.2f} | {r['p']:.2g} | "
                   f"{r['direction']:.2f} | {'yes' if r['median_inside_range'] else 'no'} | **{r['verdict']}** |")
    if invalid or failed:
        out += ["", f"Invalid trials or a mode other than the cell's: {', '.join(invalid) or 'none'}. "
                f"Trials without a record: {', '.join(failed) or 'none'}."]
    (root / "summary.md").write_text("\n".join(out) + "\n")
    print(root / "summary.md")


if __name__ == "__main__":
    main(sys.argv[1])
