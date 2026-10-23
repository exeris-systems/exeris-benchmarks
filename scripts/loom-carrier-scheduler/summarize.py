#!/usr/bin/env python3
"""Summarise a loom-carrier-scheduler campaign directory into summary.md and summary.json.

Cells report every sustained trial's value next to the median, and the worst-trial p99 with its n.
A valid trial that could not carry the target rate is a result about its arm: it is counted in its
cell ("sustained k of n") and listed with the rate it reached, but its latency stays out of the
percentiles. Invalid trials — a measurement gate failed — are listed and never used.

Validity is derived from the gates, so trial.json files written before the distinction still read
the same way.
"""
import json
import statistics

MEASUREMENT_EXCLUDED = ("load", "harness_clean", "host_shielded", "host_untracked")


def is_valid(t):
    return all(g["pass"] for k, g in t["gates"].items() if k not in MEASUREMENT_EXCLUDED)


def is_sustained(t):
    return t["gates"]["load"]["pass"]


def is_evidence(t):
    return all(g["pass"] for k, g in t["gates"].items() if k != "load")
import sys
from collections import defaultdict
from pathlib import Path

import armcfg


def med(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 3) if values else None


def fmt(v, digits=2):
    return "—" if v is None else f"{v:.{digits}f}"


def main(campaign_dir):
    root = Path(campaign_dir)
    campaign = json.loads((root / "campaign.json").read_text()) if (root / "campaign.json").exists() else {}
    trials = [json.loads(p.read_text()) for p in sorted(root.glob("*/trial.json"))]
    cells = defaultdict(list)
    attempted = defaultdict(list)
    invalid = []
    unsustained = []
    by_cell = defaultdict(list)
    for t in trials:
        # Pilot cells of arm Dv are told apart by the property file they ran.
        by_cell[(t["backend"], t["rate"], t["arm"] + (":" + t["variant"] if t.get("variant") else ""))].append(t)
    for key, ts in by_cell.items():
        armcfg.check_hashes(ts, f"{root.name} {key[2]} at {key[1]}", campaign)
    for t in trials:
        key = (t["backend"], t["rate"], t["arm"] + (":" + t["variant"] if t.get("variant") else ""))
        if not is_valid(t):
            failed = [k for k, g in t["gates"].items() if not g["pass"] and k not in MEASUREMENT_EXCLUDED]
            invalid.append({"trial": t["trial_dir"], "failed": failed,
                            "detail": {k: t["gates"][k] for k in failed}})
            continue
        attempted[key].append(t)
        if is_sustained(t):
            cells[key].append(t)
        else:
            g = t["gates"]["load"]
            unsustained.append({"trial": t["trial_dir"], "backend": key[0], "rate": key[1], "arm": key[2],
                                "achieved_ratio": g.get("achieved_ratio"), "reason": g.get("reason")})
    for key in attempted:
        cells.setdefault(key, [])

    summary = {"campaign": campaign, "cells": [], "invalid_trials": invalid, "unsustained_trials": unsustained,
               "evidence_eligible": bool(trials) and all(is_evidence(t) for t in trials)}
    for (backend, rate, arm), ts in sorted(cells.items(), key=lambda kv: (kv[0][0], kv[0][1] != "max",
                                                                         0 if kv[0][1] == "max" else int(kv[0][1]), kv[0][2])):
        p = lambda k: [t["load"]["percentiles_ms"].get(k) for t in ts]
        perf = [t["perf_stat"] for t in ts if t.get("perf_stat")]
        cell = {
            "backend": backend, "rate": rate, "arm": arm, "n": len(ts),
            "attempted": len(attempted[(backend, rate, arm)]),
            "rps": [t["load"]["requests_per_sec"] for t in ts],
            "p50_ms": p("p50"), "p90_ms": p("p90"), "p99_ms": p("p99"), "p99.9_ms": p("p99.9"),
            "carrier_cpu_pct": [t["pidstat"]["carriers"]["cpu_pct"] for t in ts],
            "carrier_wait_max_pct": [t["pidstat"]["carriers"]["wait_pct_max"] for t in ts],
            "reactor_cpu_pct": [t["pidstat"]["reactors"]["cpu_pct"] for t in ts],
            "cpus_utilized": [x["cpus_utilized"] for x in perf],
            "ipc": [x["ipc"] for x in perf],
            "context_switches_per_s": [x["context_switches_per_s"] for x in perf],
        }
        cell["median"] = {k: med(cell[k]) for k in ("rps", "p50_ms", "p90_ms", "p99_ms", "p99.9_ms",
                                                    "carrier_cpu_pct", "carrier_wait_max_pct", "reactor_cpu_pct",
                                                    "cpus_utilized", "ipc", "context_switches_per_s")}
        cell["worst_p99_ms"] = max((v for v in cell["p99_ms"] if v is not None), default=None)
        summary["cells"].append(cell)

    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    lines = [f"# loom-carrier-scheduler campaign `{root.name}`", ""]
    if campaign:
        lines += [f"- backend: `{campaign.get('backend')}`, arms: `{campaign.get('arms')}`, reps: {campaign.get('reps')}",
                  f"- ladder base (median A_iso saturation): {campaign.get('ladder_base_a_iso_rps')} req/s; rates: {campaign.get('rates')}",
                  f"- seed: `{campaign.get('seed')}`; extra trial args: `{campaign.get('trial_args', '').strip()}`"]
    ident = trials[0]["kernel"] if trials else {}
    shielded = sum(1 for t in trials if t["gates"].get("host_shielded", {}).get("pass"))
    untracked = sum(1 for t in trials if t["gates"].get("host_untracked", {}).get("pass", True))
    states = [t.get("host", {}).get("state", {}) for t in trials]
    boots = {s["boot_id"] for s in states if s.get("boot_id")}
    uptimes = [int(s["uptime_s"]) for s in states if s.get("uptime_s")]
    uptime_line = (f"- host boots: {len(boots)}; uptime at the trials {min(uptimes) / 3600:.1f}-"
                   f"{max(uptimes) / 3600:.1f} h ({len(uptimes)} of {len(trials)} trials recorded it)"
                   if uptimes else "- host boot and uptime: not recorded")
    lines += [f"- kernel: `{ident.get('kernel_commit')}`; JDK: {ident.get('jdk_build')}",
              f"- host shielded (host-shield.sh, no graphical session): {shielded} of {len(trials)} trials",
              f"- no connection tracking loaded (or not recorded): {untracked} of {len(trials)} trials",
              uptime_line,
              f"- evidence-eligible (every trial's measurement valid, harness committed, host shielded, "
              f"no connection tracking): "
              f"**{summary['evidence_eligible']}**", ""]
    lines += ["| backend | rate | arm | sustained | req/s (median) | p50 | p90 | p99 (median) | p99 all trials | worst p99 | p99.9 "
              "| carrier CPU % | carrier %wait max | CPUs (perf) | IPC | cs/s |",
              "|:--|---:|:--|--:|--:|--:|--:|--:|:--|--:|--:|--:|--:|--:|--:|--:|"]
    for c in summary["cells"]:
        m = c["median"]
        lines.append(
            f"| {c['backend']} | {c['rate']} | {c['arm']} | {c['n']} of {c['attempted']} | {fmt(m['rps'], 0)} | {fmt(m['p50_ms'])} | {fmt(m['p90_ms'])} "
            f"| {fmt(m['p99_ms'])} | {', '.join(fmt(v) for v in c['p99_ms'])} | {fmt(c['worst_p99_ms'])} "
            f"| {fmt(m['p99.9_ms'])} | {fmt(m['carrier_cpu_pct'], 1)} | {fmt(m['carrier_wait_max_pct'], 1)} "
            f"| {fmt(m['cpus_utilized'])} | {fmt(m['ipc'])} | {fmt(m['context_switches_per_s'], 0)} |")
    lines += ["", "Latencies in ms. Percentiles from wrk2 (open loop, coordinated-omission corrected) for numeric "
              "rates and from wrk (closed loop) for `max`; closed-loop latency is not a latency result.", ""]
    if unsustained:
        lines += ["## Trials that did not sustain the target rate", "",
                  "A result about the arm: counted under *sustained* in its cell, kept out of the percentiles.", ""]
        for u in unsustained:
            lines.append(f"- `{u['trial']}` ({u['arm']} at {u['rate']}): {u['reason']} "
                         f"(ratio {u['achieved_ratio']})")
        lines.append("")
    if invalid:
        lines += ["## Invalid trials (a measurement gate failed; excluded from every statistic)", ""]
        for i in invalid:
            lines.append(f"- `{i['trial']}`: failed {', '.join(i['failed'])} — {json.dumps(i['detail'])}")
    (root / "summary.md").write_text("\n".join(lines) + "\n")
    print(root / "summary.md")


if __name__ == "__main__":
    main(sys.argv[1])
