#!/usr/bin/env python3
"""HYP-THROUGHPUT (v2) from one regime's campaign: highest sustained rate, closed-loop throughput,
and the mechanism check.

Open loop (trial directories r<n>-<arm>-<rate>): an arm sustains a rate when at least MIN_VALID of the
cell's trials are valid and every valid trial carried the rate (the load gate). An arm's highest
sustained rate is the highest rate up to which every rate is sustained. HYP-THROUGHPUT is falsified in
the regime when D2's highest sustained rate is not above B_pin's. The reading follows B_pin's rule:
D2 above B_pin is throughput the scheduler adds beyond pinning; above D but not above B_pin, v2
removes v1's cost and pinning carries the rest; not above D, v2 changes nothing measurable.

Closed loop (cl-r<n>-<arm>-c<connections>): requests per second and requests per CPU-second of the
server JVM (perf's CPUs utilised, else pidstat's process %CPU, one source for the whole campaign).
Per connection level and metric, every pair of the arms present is tested with the exact two-sided
Mann-Whitney test; the family of Holm's step-down adjustment is those pairs (six when A_iso, B_pin, D
and D2 all ran). A pair differs when its Holm-adjusted p is below 0.05 and the medians differ by at
least 2 % of the larger of the two medians.

Mechanism: in the cells at the regime's connection count, D2's context switches and cycles per request
lie inside the range of B_pin's trials (D2's median is compared with B_pin's minimum and maximum).

Rig bound (informational, never changes a verdict): a trial is labelled when the mock backend used at
least 95 % of the CPUs it may use (190 % for two, 380 for four), when requests in flight (rate x p50) reached the backend pool, or when
the rate is above connections / p50, i.e. the connections cannot carry it. A cell carries a label
that at least half of its valid trials carry.

Usage: throughput_v2.py <campaign-dir>   writes throughput.md and throughput.json into it.
"""
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import armcfg
from parse_trial import cpu_set
from slo_ladder import MIN_VALID, is_valid
from stats import V2_ARMS, V2_PAIRS, holm, mann_whitney

MOCK_CPU_SHARE = 0.95   # of 100 % per CPU the mock is given
FLOOR = 0.02
ALPHA = 0.05


def mock_cpu_pct(trial_dir):
    """The mock backend's average %CPU over the window, from pidstat-mock.txt; None if unreadable."""
    path = Path(trial_dir) / "pidstat-mock.txt"
    if not path.exists():
        return None
    header = None
    value = None
    for line in path.read_text(errors="replace").splitlines():
        cols = line.split()
        if not cols:
            continue
        # pidstat prints the header once, led by a time of day; the Average row is led by "Average:".
        if "%CPU" in cols:
            header = cols
        elif cols[0] == "Average:" and header and len(cols) >= len(header):
            try:
                value = float(cols[header.index("%CPU")])
            except ValueError:
                pass
    return value


def mock_cpu_limit(t):
    """The mock's %CPU at which it counts as at its limit: 95 % of 100 x the CPUs it may use."""
    return MOCK_CPU_SHARE * 100.0 * len(cpu_set(t["layout"]["mock"]))


def p50_ms(t):
    return t["load"]["percentiles_ms"].get("p50")


def rig_bound(t, trial_dir):
    """Reasons the rig, not the scheduler, may bound this trial."""
    reasons = []
    mock = mock_cpu_pct(trial_dir)
    if mock is not None and mock >= mock_cpu_limit(t):
        reasons.append("mock CPU")
    p50 = p50_ms(t)
    rate = float(t["rate"]) if t["rate"] != "max" else (t["load"]["requests_per_sec"] or 0.0)
    if p50 and rate:
        if rate * p50 / 1000.0 >= t["pool"]:
            reasons.append("pool")
        if rate > t["connections"] / (p50 / 1000.0):
            reasons.append("connections")
    return reasons


def cell_rig_label(trials_dirs):
    counts = defaultdict(int)
    for t, d in trials_dirs:
        for r in rig_bound(t, d):
            counts[r] += 1
    return sorted(r for r, c in counts.items() if 2 * c >= len(trials_dirs))


def cpus_of(t, source):
    if source == "perf":
        return (t.get("perf_stat") or {}).get("cpus_utilized")
    pct = (t["pidstat"].get("process") or {}).get("%CPU")
    return pct / 100.0 if pct else None


def load_trials(root):
    ladder, closed = defaultdict(list), defaultdict(list)
    for p in sorted(root.glob("*/trial.json")):
        t = json.loads(p.read_text())
        name = p.parent.name
        if t["rate"] == "max" and name.startswith("cl-"):
            closed[(t["arm"], t["connections"])].append((t, p.parent))
        elif t["rate"] != "max" and re.match(r"r\d+-", name):
            ladder[(t["arm"], int(t["rate"]))].append((t, p.parent))
    return ladder, closed


def highest_sustained(ladder, arm, rates):
    rows = []
    for rate in rates:
        ts = [t for t, _ in ladder.get((arm, rate), []) if is_valid(t)]
        sustained = [t for t in ts if t["gates"]["load"]["pass"]]
        ok = len(ts) >= MIN_VALID and len(sustained) == len(ts)
        rows.append({"rate": rate, "attempted": len(ladder.get((arm, rate), [])), "valid": len(ts),
                     "sustained": len(sustained), "ok": ok,
                     "rig_bound": cell_rig_label([(t, d) for t, d in ladder.get((arm, rate), []) if is_valid(t)])})
    top = None
    for r in rows:
        if not r["ok"]:
            break
        top = r["rate"]
    return top, rows


def pair_tests(values_by_arm):
    """Exact Mann-Whitney for every pair of arms present, Holm-adjusted over the pairs."""
    pairs = [(a, b) for a, b in V2_PAIRS if values_by_arm.get(a) and values_by_arm.get(b)]
    ps = [mann_whitney(values_by_arm[a], values_by_arm[b]) for a, b in pairs]
    adjusted, rejected = holm([p for p, _ in ps], ALPHA) if pairs else ([], [])
    rows = []
    for (a, b), (p, direction), adj, rej in zip(pairs, ps, adjusted, rejected):
        ma, mb = statistics.median(values_by_arm[a]), statistics.median(values_by_arm[b])
        rel = (ma - mb) / max(ma, mb) if max(ma, mb) else None
        rows.append({"pair": [a, b], "n": [len(values_by_arm[a]), len(values_by_arm[b])],
                     "median": [ma, mb], "relative_difference": rel, "p": p, "p_holm": adj,
                     "p_x_above": direction,
                     "differs": bool(rej and rel is not None and abs(rel) >= FLOOR)})
    return rows


def per_request(t, key):
    rps, perf = t["load"]["requests_per_sec"], t.get("perf_stat") or {}
    if not rps or not perf.get("elapsed_s"):
        return None
    if key == "cs":
        return perf["context_switches_per_s"] / rps if perf.get("context_switches_per_s") is not None else None
    return perf["cycles"] / (rps * perf["elapsed_s"]) if perf.get("cycles") else None


def evaluate(root):
    root = Path(root)
    campaign = json.loads((root / "campaign.json").read_text())
    ladder, closed = load_trials(root)
    for (arm, rate), ts in ladder.items():
        armcfg.check_hashes([t for t, _ in ts], f"{root.name} {arm} at {rate}", campaign)
    for (arm, c), ts in closed.items():
        armcfg.check_hashes([t for t, _ in ts], f"{root.name} {arm} closed at {c} connections", campaign)
    arms = [a for a in V2_ARMS if any(k[0] == a for k in list(ladder) + list(closed))]
    result = {"campaign": root.name, "arms": arms}

    rates = sorted({r for _, r in ladder})
    top = {}
    result["open_loop"] = {}
    for arm in arms:
        top[arm], rows = highest_sustained(ladder, arm, rates)
        result["open_loop"][arm] = {"highest_sustained_rps": top[arm], "rates": rows}
    if {"D2", "B_pin"} <= set(arms):
        d2, bp, d = top["D2"] or 0, top["B_pin"] or 0, top.get("D") or 0
        result["hyp_throughput"] = {
            "d2_rps": top["D2"], "b_pin_rps": top["B_pin"], "d_rps": top.get("D"),
            "falsified": not d2 > bp,
            "reading": ("D2 above B_pin: throughput the scheduler adds beyond pinning" if d2 > bp else
                        "D2 above D but not above B_pin: v2 removes v1's cost and pinning carries the rest" if d2 > d else
                        "D2 not above D: v2 changes nothing measurable")}

    result["closed_loop"] = {}
    if closed:
        conns = sorted({c for _, c in closed})
        first = campaign.get("closed_connections", "").split()
        base = int(first[0]) if first else conns[0]
        source = "perf" if all((t.get("perf_stat") or {}).get("cpus_utilized") for ts in closed.values()
                               for t, _ in ts) else "pidstat"
        result["closed_loop"]["cpu_source"] = source
        levels = {}
        for c in conns:
            level = f"{c // base}x" if c % base == 0 else f"c={c}"
            rps = {a: [t["load"]["requests_per_sec"] for t, _ in closed.get((a, c), [])
                       if is_valid(t) and t["gates"]["load"]["pass"]] for a in arms}
            rpc = {a: [t["load"]["requests_per_sec"] / cp for t, _ in closed.get((a, c), [])
                       if is_valid(t) and (cp := cpus_of(t, source))] for a in arms}
            levels[level] = {
                "connections": c,
                "requests_per_s": {"values": {a: sorted(v) for a, v in rps.items()}, "tests": pair_tests(rps)},
                "requests_per_cpu_s": {"values": {a: sorted(v) for a, v in rpc.items()}, "tests": pair_tests(rpc)},
                "rig_bound": {a: cell_rig_label([(t, d) for t, d in closed.get((a, c), []) if is_valid(t)])
                              for a in arms}}
            if c == base and {"D2", "B_pin"} <= set(arms):
                mech = {}
                for key, label in (("cs", "context_switches_per_request"), ("cycles", "cycles_per_request")):
                    vals = {a: [v for t, _ in closed.get((a, c), []) if is_valid(t)
                                and (v := per_request(t, key)) is not None] for a in ("D2", "B_pin")}
                    if vals["D2"] and vals["B_pin"]:
                        med = statistics.median(vals["D2"])
                        mech[label] = {"d2": sorted(vals["D2"]), "b_pin": sorted(vals["B_pin"]),
                                       "d2_median_inside_b_pin_range": min(vals["B_pin"]) <= med <= max(vals["B_pin"])}
                    else:
                        mech[label] = {"measured": False}
                result["mechanism"] = {"connections": c, **mech,
                                       "holds": all(m.get("d2_median_inside_b_pin_range") is True for m in mech.values())}
        result["closed_loop"]["levels"] = levels
    return result


def render(result):
    fmt = lambda v, d=1: "—" if v is None else f"{v:.{d}f}"
    out = [f"# HYP-THROUGHPUT (v2), `{result['campaign']}`", ""]
    out += ["## Open loop: highest sustained rate", "",
            "A rate is sustained by an arm when at least "
            f"{MIN_VALID} of its trials are valid and every valid trial carried it; the highest sustained rate is "
            "the highest rate up to which every rate is sustained. `rig` names what may bound the cell "
            "(informational): the mock backend's CPU (95 % of the CPUs it may use), the backend pool, the connections.", ""]
    arms = result["arms"]
    rates = sorted({r["rate"] for a in result["open_loop"].values() for r in a["rates"]})
    if rates:
        out += ["| arm | highest sustained |", "|:--|--:|"]
        for a in arms:
            out.append(f"| {a} | {result['open_loop'][a]['highest_sustained_rps'] or 'below the ladder'} |")
        out += ["", "| rate | " + " | ".join(arms) + " |", "|--:|" + ":--|" * len(arms)]
        for rate in rates:
            cells = []
            for a in arms:
                row = next((r for r in result["open_loop"][a]["rates"] if r["rate"] == rate), None)
                if not row or not row["attempted"]:
                    cells.append("—")
                    continue
                rig = f" rig: {', '.join(row['rig_bound'])}" if row["rig_bound"] else ""
                cells.append(f"{'yes' if row['ok'] else 'no'} ({row['sustained']}/{row['valid']} of {row['attempted']}){rig}")
            out.append(f"| {rate} | " + " | ".join(cells) + " |")
    h = result.get("hyp_throughput")
    if h:
        out += ["", f"HYP-THROUGHPUT in this regime: D2 {h['d2_rps'] or 'below the ladder'}, B_pin "
                f"{h['b_pin_rps'] or 'below the ladder'}, D {h['d_rps'] or 'below the ladder'}: "
                f"**{'falsified' if h['falsified'] else 'not falsified'}**. {h['reading']}."]
    cl = result["closed_loop"]
    if cl:
        out += ["", "## Closed loop", "",
                f"Requests per CPU-second use the server JVM's CPUs from {cl['cpu_source']}. Pairs: exact two-sided "
                f"Mann-Whitney, Holm-adjusted over the pairs of one level and metric; `differs` needs the adjusted p "
                f"below {ALPHA} and medians at least {FLOOR:.0%} apart, measured against the larger of the two medians."]
        for level, lv in cl["levels"].items():
            for metric, title in (("requests_per_s", "requests/s"), ("requests_per_cpu_s", "requests/CPU-s")):
                m = lv[metric]
                out += ["", f"### {level} ({lv['connections']} connections), {title}", "",
                        "| arm | n | median | values, sorted | rig |", "|:--|--:|--:|:--|:--|"]
                for a in arms:
                    v = m["values"][a]
                    out.append(f"| {a} | {len(v)} | {fmt(statistics.median(v), 0) if v else '—'} | "
                               f"{', '.join(f'{x:.0f}' for x in v)} | {', '.join(lv['rig_bound'][a]) or '—'} |")
                out += ["", "| x vs y | median x / y | difference | p | Holm p | P(x > y) | differs |", "|:--|:--|--:|--:|--:|--:|:--|"]
                for t in m["tests"]:
                    rel = "—" if t["relative_difference"] is None else f"{t['relative_difference']:+.1%}"
                    out.append(f"| {t['pair'][0]} vs {t['pair'][1]} | {t['median'][0]:.0f} / {t['median'][1]:.0f} | {rel} | "
                               f"{t['p']:.2g} | {t['p_holm']:.2g} | {t['p_x_above']:.2f} | {'yes' if t['differs'] else 'no'} |")
    mech = result.get("mechanism")
    if mech:
        out += ["", f"## Mechanism ({mech['connections']} connections, closed loop)", "",
                "D2's median against the range of B_pin's trials:", "",
                "| per request | D2, sorted | B_pin, sorted | D2 median inside B_pin's range |", "|:--|:--|:--|:--|"]
        for key in ("context_switches_per_request", "cycles_per_request"):
            m = mech[key]
            if m.get("measured") is False:
                out.append(f"| {key.replace('_', ' ')} | not measured | | |")
            else:
                g = ", ".join(f"{x:.4g}" for x in m["d2"]), ", ".join(f"{x:.4g}" for x in m["b_pin"])
                out.append(f"| {key.replace('_', ' ')} | {g[0]} | {g[1]} | {m['d2_median_inside_b_pin_range']} |")
        out += ["", f"Mechanism predicted by the idle policy: **{'holds' if mech['holds'] else 'does not hold'}**."
                + ("" if mech["holds"] else " A rate gain without it is not the idle policy's.")]
    return "\n".join(out) + "\n"


def main(root):
    root = Path(root)
    result = evaluate(root)
    (root / "throughput.json").write_text(json.dumps(result, indent=2) + "\n")
    (root / "throughput.md").write_text(render(result))
    print(root / "throughput.md")


if __name__ == "__main__":
    main(sys.argv[1])
