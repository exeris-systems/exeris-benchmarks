#!/usr/bin/env python3
"""Tabulate a run-v2-pilot.sh directory. The pilot is not evidence: this reports what the registered
property set and rig configuration are chosen from, and states no hypothesis result.

Sections:
  - the cells at each rate: throughput, p99, CPU per request, context switches and futex calls per
    request (with the carriers' share), from perf stat and perf stat --per-thread;
  - the idle spin's cost: P01 against P0, in carrier CPU at 50 % and in requests per CPU-second at
    saturation;
  - the scheduler counters: how many threads each placement path placed, timed parks per request;
  - whether stealing removes D's tail advantage at 85 %, and whether the I/O-bound 70 % rung is
    bimodal;
  - rig headroom: rungs of 100-130 % and the connection and pool sweeps for B_pin and the full set,
    with the mock's CPU, the carriers' CPU and p50, and which resource is at its limit first.

Usage: summarize_v2_pilot.py <pilot-dir>   writes summary.md and summary.json into it.
"""
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import armcfg
from throughput_v2 import mock_cpu_limit, mock_cpu_pct, rig_bound

CARRIER_CPU_LIMIT = 190.0   # of 200 % for two carriers
PLACEMENT = ("start.factory", "start.poller.preferred", "start.poller.name", "start.current.mounted",
             "start.current.scope", "start.p2c", "start.p2c.other", "start.random", "start.builtin")


def med(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def fmt(v, digits=2):
    return "—" if v is None else f"{v:,.{digits}f}"


def read_plan(path):
    plan = {}
    for line in path.read_text().splitlines():
        for tok in line.split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                plan[k] = v
    return plan


# Every trial of the pilot fails unperturbed by construction; the measurement gates that remain decide
# whether its numbers are used.
NOT_MEASUREMENT = ("load", "unperturbed", "harness_clean", "host_shielded", "host_untracked")


def pilot_valid(t):
    return all(g["pass"] for k, g in t["gates"].items() if k not in NOT_MEASUREMENT)


def metrics(t, d):
    """Per-trial quantities the tables take medians of."""
    rps = t["load"]["requests_per_sec"]
    duration = t["duration_s"]
    requests = rps * duration if rps else None
    perf = t.get("perf_stat") or {}
    pt = t.get("perf_threads") or {}
    cpus = perf.get("cpus_utilized")
    if cpus is None:
        pct = (t["pidstat"].get("process") or {}).get("%CPU")
        cpus = pct / 100.0 if pct else None
    carriers = t["pidstat"]["carriers"]

    def per_req(total):
        return total / requests if total is not None and requests else None

    futex = None
    if pt:
        parts = [pt[g].get("futex_calls") for g in ("carriers", "reactors", "other") if pt.get(g)]
        futex = sum(p for p in parts if p is not None) if any(p is not None for p in parts) else None
    carrier_cs = pt["carriers"].get("context_switches") if pt and pt.get("carriers") else None
    if carrier_cs is None and carriers.get("cswch_per_s") is not None and rps:
        carrier_cs_per_req = carriers["cswch_per_s"] / rps
    else:
        carrier_cs_per_req = per_req(carrier_cs)
    stats = (t.get("scheduler_stats") or {})
    return {
        "rps": rps, "p50": t["load"]["percentiles_ms"].get("p50"), "p99": t["load"]["percentiles_ms"].get("p99"),
        "sustained": t["gates"]["load"]["pass"], "valid": pilot_valid(t),
        "req_per_cpu": rps / cpus if rps and cpus else None,
        "cpu_ms_per_req": 1000.0 * cpus / rps if rps and cpus else None,
        "cs_per_req": (perf["context_switches_per_s"] / rps) if perf.get("context_switches_per_s") is not None and rps else None,
        "carrier_cs_per_req": carrier_cs_per_req,
        "futex_per_req": per_req(futex),
        "carrier_cpu": carriers["cpu_pct"], "mock_cpu": mock_cpu_pct(d),
        "rig": rig_bound(t, d), "delta": stats.get("delta") or {}, "per_request": stats.get("per_request") or {},
        "connections": t["connections"], "pool": t["pool"],
        # Recorded layout, not the directory name.
        "mock_cpus": t["layout"]["mock"], "mock_limit": mock_cpu_limit(t),
    }


def load(root):
    trials = []
    for p in sorted(root.glob("*/trial.json")):
        t = json.loads(p.read_text())
        block = p.parent.name.split("-", 1)[0]
        cell = t.get("variant") or t["arm"]
        trials.append({"block": block, "cell": cell, "rate": t["rate"], "t": t, "dir": p.parent,
                       "m": metrics(t, p.parent)})
    return trials


def bimodal(values):
    v = sorted(values)
    if len(v) < 3:
        return None
    gap = max(b - a for a, b in zip(v, v[1:]))
    return gap > 0.5 * statistics.median(v)


def main(root):
    root = Path(root)
    plan = read_plan(root / "plan.txt")
    base = float(plan.get("base_rps", "0").split("(")[0] or 0)
    trials = load(root)
    for key in {(x["cell"], x["rate"], x["m"]["connections"], x["m"]["pool"]) for x in trials}:
        armcfg.check_hashes([x["t"] for x in trials if (x["cell"], x["rate"], x["m"]["connections"], x["m"]["pool"]) == key],
                            f"{root.name} {key[0]} at {key[1]}")
    result = {"plan": plan, "evidence_trials": sum(1 for x in trials if x["t"]["evidence"]), "trials": len(trials)}

    def frac(rate):
        return "saturation" if rate == "max" else (f"{int(rate) / base:.0%}" if base else rate)

    def rate_key(rate):
        return (1, 0) if rate == "max" else (0, int(rate))

    out = [f"# Scheduler v2 pilot `{root.name}`", "",
           "Not evidence: every trial carries the `v2 pilot` marker, so the unperturbed gate fails. "
           f"Trials: {len(trials)}; trials that are evidence: {result['evidence_trials']}.", "",
           "```", (root / "plan.txt").read_text().strip(), "```", ""]

    # --- the cells at each rate -------------------------------------------------------------------------
    var = [x for x in trials if x["block"] == "var"]
    cells = defaultdict(list)
    for x in var:
        cells[(x["rate"], x["cell"])].append(x)
    order = list(dict.fromkeys(x["cell"] for x in sorted(var, key=lambda x: x["dir"].name)))
    out += ["## Cells at each rate", "",
            "Medians over the cell's valid trials; p99 over sustained ones. Per request: perf stat's context switches of "
            "the whole server JVM, the carriers' switches and the JVM's futex calls from the per-thread count.", "",
            "| rate | cell | valid / sustained of n | req/s | p99 ms | req per CPU-s | CPU ms per req | cs / req | carrier cs / req | futex / req | carrier CPU % |",
            "|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|"]
    summary_cells = []
    for rate in sorted({r for r, _ in cells}, key=rate_key):
        for cell in order:
            xs = cells.get((rate, cell), [])
            if not xs:
                continue
            ok = [x["m"] for x in xs if x["m"]["valid"]]
            sus = [m for m in ok if m["sustained"]]
            row = {k: med([m[k] for m in ok]) for k in ("rps", "req_per_cpu", "cpu_ms_per_req", "cs_per_req",
                                                          "carrier_cs_per_req", "futex_per_req", "carrier_cpu")}
            row["p99"] = med([m["p99"] for m in sus])
            out.append(f"| {frac(rate)} | {cell} | {len(ok)} / {len(sus)} of {len(xs)} | {fmt(row['rps'], 0)} | {fmt(row['p99'])} | "
                       f"{fmt(row['req_per_cpu'], 0)} | {fmt(row['cpu_ms_per_req'], 4)} | {fmt(row['cs_per_req'], 3)} | "
                       f"{fmt(row['carrier_cs_per_req'], 3)} | {fmt(row['futex_per_req'], 3)} | {fmt(row['carrier_cpu'], 1)} |")
            summary_cells.append({"rate": rate, "cell": cell, **row})
    result["cells"] = summary_cells

    # --- the idle spin's cost ------------------------------------------------------------------------------
    def cell_med(rate, cell, key):
        return med([x["m"][key] for x in cells.get((rate, cell), []) if x["m"]["valid"]])

    lo = next((r for r in sorted({r for r, _ in cells if r != "max"}, key=int) if base and abs(int(r) / base - 0.5) < 0.02), None)
    out += ["", "## The idle spin's cost (P01 against P0)", ""]
    if lo and cells.get((lo, "P0")) and cells.get((lo, "P01")):
        c0, c1 = cell_med(lo, "P0", "carrier_cpu"), cell_med(lo, "P01", "carrier_cpu")
        r0, r1 = cell_med("max", "P0", "req_per_cpu"), cell_med("max", "P01", "req_per_cpu")
        out += [f"- carrier CPU at 50 %: P0 {fmt(c0, 1)} %, P01 {fmt(c1, 1)} % ({fmt(None if None in (c0, c1) else c1 - c0, 1)} points)",
                f"- requests per CPU-second at saturation: P0 {fmt(r0, 0)}, P01 {fmt(r1, 0)} "
                f"({'—' if None in (r0, r1) else f'{(r1 - r0) / r0:+.1%}'})"]
        result["spin_cost"] = {"carrier_cpu_50": [c0, c1], "req_per_cpu_max": [r0, r1]}
    else:
        out.append("not measured (P0 or P01 missing at 50 % or saturation)")

    # --- scheduler counters ----------------------------------------------------------------------------------
    out += ["", "## Placement paths and timed parks (scheduler counters)", "",
            "Threads started through each path, median over trials of the window's delta; timed parks per request.", "",
            "| rate | cell | " + " | ".join(k.replace("start.", "") for k in PLACEMENT) + " | timer.scheduled / req | timer.cancelled / req |",
            "|:--|:--|" + "--:|" * len(PLACEMENT) + "--:|--:|"]
    for rate in sorted({r for r, _ in cells}, key=rate_key):
        for cell in order:
            xs = [x for x in cells.get((rate, cell), []) if x["m"]["delta"]]
            if not xs:
                continue
            out.append(f"| {frac(rate)} | {cell} | "
                       + " | ".join(fmt(med([x["m"]["delta"].get(k) for x in xs]), 0) for k in PLACEMENT)
                       + f" | {fmt(med([x['m']['per_request'].get('timer.scheduled') for x in xs]), 4)} | "
                       f"{fmt(med([x['m']['per_request'].get('timer.cancelled') for x in xs]), 4)} |")

    # --- stealing at 85 % and the 70 % rung -----------------------------------------------------------------
    def at_fraction(f):
        return next((r for r in sorted({r for r, _ in cells if r != "max"}, key=int) if base and abs(int(r) / base - f) < 0.02), None)

    out += ["", "## Tail at 85 % (does stealing remove D's advantage?)", "",
            "| cell | sustained of n | p99 ms, sorted | median |", "|:--|:--|:--|--:|"]
    r85 = at_fraction(0.85)
    for cell in order:
        xs = cells.get((r85, cell), []) if r85 else []
        if xs:
            v = sorted(x["m"]["p99"] for x in xs if x["m"]["valid"] and x["m"]["sustained"] and x["m"]["p99"] is not None)
            out.append(f"| {cell} | {len(v)} of {len(xs)} | {', '.join(f'{p:.2f}' for p in v)} | {fmt(med(v))} |")
    r70 = at_fraction(0.70)
    out += ["", "## The 70 % rung (bimodality; a gap larger than half the median, n is small)", ""]
    if r70 and any(cells.get((r70, c)) for c in order):
        out += ["| cell | p99 ms, sorted | bimodal |", "|:--|:--|:--|"]
        for cell in order:
            xs = cells.get((r70, cell), [])
            v = sorted(x["m"]["p99"] for x in xs if x["m"]["valid"] and x["m"]["sustained"] and x["m"]["p99"] is not None)
            if v:
                b = bimodal(v)
                out.append(f"| {cell} | {', '.join(f'{p:.2f}' for p in v)} | {'—' if b is None else 'yes' if b else 'no'} |")
    else:
        out.append("not run in this regime")

    # --- rig headroom ------------------------------------------------------------------------------------------------
    out += ["", "## Rig headroom", "",
            "Per cell: which resource is at its limit — the mock backend (≥ 95 % of the CPUs it may use: 190 % for "
            f"two, 380 % for four), the carriers (≥ {CARRIER_CPU_LIMIT:.0f} % of two), the backend pool or the connections (the labels of "
            "throughput_v2.py). `none` means no listed resource is at its limit.", "",
            "| cell | rate | connections | pool | mock CPUs | valid / sustained of n | req/s | p50 ms | mock CPU % | carrier CPU % | at its limit |",
            "|:--|:--|--:|--:|:--|:--|--:|--:|--:|--:|:--|"]
    head = [x for x in trials if x["block"] in ("rung", "conn", "pool", "mock")]
    # The default-configuration cells at saturation belong to the variants block; include them.
    head += [x for x in var if x["rate"] == "max" and x["cell"] in {y["cell"] for y in trials if y["block"] != "var"}]
    groups = defaultdict(list)
    for x in head:
        groups[(x["cell"], x["m"]["connections"], x["m"]["pool"], x["m"]["mock_cpus"], x["rate"])].append(x)
    limits = {}
    for key in sorted(groups, key=lambda k: (k[0], k[1], k[2], k[3], rate_key(k[4]))):
        cell, conn, pool, mock_cpus, rate = key
        xs = groups[key]
        ok = [x["m"] for x in xs if x["m"]["valid"]]
        sus = [m for m in ok if m["sustained"]]
        mock, car = med([m["mock_cpu"] for m in ok]), med([m["carrier_cpu"] for m in ok])
        at = []
        if mock is not None and ok and mock >= ok[0]["mock_limit"]:
            at.append("mock")
        if car is not None and car >= CARRIER_CPU_LIMIT:
            at.append("carriers")
        reasons = {r for m in ok for r in m["rig"] if sum(1 for q in ok if r in q["rig"]) * 2 >= len(ok)}
        at += sorted(r for r in reasons if r != "mock CPU")
        limits[key] = at
        out.append(f"| {cell} | {frac(rate)} | {conn} | {pool} | {mock_cpus} | {len(ok)} / {len(sus)} of {len(xs)} | "
                   f"{fmt(med([m['rps'] for m in ok]), 0)} | {fmt(med([m['p50'] for m in ok]))} | {fmt(mock, 0)} | "
                   f"{fmt(car, 0)} | {', '.join(at) or 'none'} |")
    result["headroom"] = [{"cell": k[0], "connections": k[1], "pool": k[2], "mock_cpus": k[3], "rate": k[4], "at_limit": v}
                          for k, v in limits.items()]

    errors = [x for x in trials if not x["t"]["gates"]["errors"]["pass"]]
    out += ["", f"Trials with errors or non-2xx (a starved caller under the custom scheduler shows as a timeout or 502): "
            f"{', '.join(x['dir'].name for x in errors) or 'none'}.",
            f"Trials invalid for a measurement gate: "
            f"{', '.join(x['dir'].name for x in trials if not x['m']['valid']) or 'none'}."]
    (root / "summary.json").write_text(json.dumps(result, indent=2, default=str) + "\n")
    (root / "summary.md").write_text("\n".join(out) + "\n")
    print(root / "summary.md")


if __name__ == "__main__":
    main(sys.argv[1])
