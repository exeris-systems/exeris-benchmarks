#!/usr/bin/env python3
"""Summarise a loom-carrier-scheduler campaign directory into summary.md and summary.json.

Cells report every valid trial's value next to the median, and the worst-trial p99 with its n.
Invalid trials are listed with the gate they failed and are never folded into a statistic.
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


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
    invalid = []
    for t in trials:
        if t["valid"]:
            cells[(t["backend"], t["rate"], t["arm"])].append(t)
        else:
            failed = [k for k, g in t["gates"].items()
                      if not g["pass"] and k not in ("harness_clean", "host_shielded")]
            invalid.append({"trial": t["trial_dir"], "failed": failed,
                            "detail": {k: t["gates"][k] for k in failed}})

    summary = {"campaign": campaign, "cells": [], "invalid_trials": invalid,
               "evidence_eligible": bool(trials) and all(t["evidence"] for t in trials)}
    for (backend, rate, arm), ts in sorted(cells.items(), key=lambda kv: (kv[0][0], kv[0][1] != "max",
                                                                         0 if kv[0][1] == "max" else int(kv[0][1]), kv[0][2])):
        p = lambda k: [t["load"]["percentiles_ms"].get(k) for t in ts]
        perf = [t["perf_stat"] for t in ts if t.get("perf_stat")]
        cell = {
            "backend": backend, "rate": rate, "arm": arm, "n": len(ts),
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
    lines += [f"- kernel: `{ident.get('kernel_commit')}`; JDK: {ident.get('jdk_build')}",
              f"- host shielded (host-shield.sh, no graphical session): {shielded} of {len(trials)} trials",
              f"- evidence-eligible (every trial valid, harness committed, host shielded): "
              f"**{summary['evidence_eligible']}**", ""]
    lines += ["| backend | rate | arm | n | req/s (median) | p50 | p90 | p99 (median) | p99 all trials | worst p99 | p99.9 "
              "| carrier CPU % | carrier %wait max | CPUs (perf) | IPC | cs/s |",
              "|:--|---:|:--|--:|--:|--:|--:|--:|:--|--:|--:|--:|--:|--:|--:|--:|"]
    for c in summary["cells"]:
        m = c["median"]
        lines.append(
            f"| {c['backend']} | {c['rate']} | {c['arm']} | {c['n']} | {fmt(m['rps'], 0)} | {fmt(m['p50_ms'])} | {fmt(m['p90_ms'])} "
            f"| {fmt(m['p99_ms'])} | {', '.join(fmt(v) for v in c['p99_ms'])} | {fmt(c['worst_p99_ms'])} "
            f"| {fmt(m['p99.9_ms'])} | {fmt(m['carrier_cpu_pct'], 1)} | {fmt(m['carrier_wait_max_pct'], 1)} "
            f"| {fmt(m['cpus_utilized'])} | {fmt(m['ipc'])} | {fmt(m['context_switches_per_s'], 0)} |")
    lines += ["", "Latencies in ms. Percentiles from wrk2 (open loop, coordinated-omission corrected) for numeric "
              "rates and from wrk (closed loop) for `max`; closed-loop latency is not a latency result.", ""]
    if invalid:
        lines += ["## Invalid trials (excluded from every statistic)", ""]
        for i in invalid:
            lines.append(f"- `{i['trial']}`: failed {', '.join(i['failed'])} — {json.dumps(i['detail'])}")
    (root / "summary.md").write_text("\n".join(lines) + "\n")
    print(root / "summary.md")


if __name__ == "__main__":
    main(sys.argv[1])
