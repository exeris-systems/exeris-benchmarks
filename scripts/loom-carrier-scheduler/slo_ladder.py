#!/usr/bin/env python3
"""Capacity at a fixed p99: the highest ladder rate each arm carries inside the campaign's SLO.

The SLO and the rule are fixed before the campaign runs and recorded in campaign.json
(`slo_p99_ms`); this script only applies them.

A rate passes for an arm when
  - at least MIN_VALID of the cell's trials are valid (a measurement gate failing makes a trial
    invalid; fewer valid trials leave the cell undecided, never passed),
  - every valid trial sustained the target rate, and
  - the median p99 of the valid trials is at most the SLO.

An arm's capacity is the highest rate up to which every ladder rate passes: a service running at
that rate also runs at every rate below it. The highest passing rate is reported beside it, and the
two differ only when a lower rate fails or is undecided. The capacity is the primary result; the
highest passing rate is supplementary. Below the lowest rung the capacity is reported as below
the ladder.

Where the campaign ran extra cells of B_float (PinnedForkJoinScheduler with the binding off), the
reproduction check compares them with A_iso at the same rate: the reproduction is accepted when
B_float's p99 does not separate from A_iso's (exact two-sided Mann-Whitney p >= 0.05) and B_float's
median p99 lies inside the range of A_iso's trials. If it is not accepted, B_pin is read against
B_float instead of A_iso: both go through the SPI, so pinning is still the one difference.

When the campaign ran arm D2 beside D, the scheduler's second revision is held to one more rule: it
is rejected in a regime where D2's capacity is below D's (a capacity below the ladder counts as
zero). D2's p99 at every rung is also tabulated against D and B_pin, the tail follow-up.

Usage: slo_ladder.py <campaign-dir>   writes slo.md and slo.json into the campaign directory.
The same logic is importable: evaluate(root) returns the result dict, render(result, root_name)
the markdown; write(root) does both.
"""
import json
import statistics
import sys
from pathlib import Path

import armcfg
from stats import mann_whitney, reproduction_check

ARMS = ("A_iso", "B_pin", "C_iso", "D", "D2")
MEASUREMENT_EXCLUDED = ("load", "harness_clean", "host_shielded", "host_untracked")
MIN_VALID = 4


def is_valid(t):
    return all(g["pass"] for k, g in t["gates"].items() if k not in MEASUREMENT_EXCLUDED)


def evaluate(root):
    """Apply the rule to a campaign directory; the result is what slo.json holds."""
    root = Path(root)
    campaign = json.loads((root / "campaign.json").read_text())
    slo = campaign.get("slo_p99_ms")
    if slo is None:
        sys.exit("campaign.json records no slo_p99_ms; this campaign was not run against an SLO")
    base = campaign.get("ladder_base_a_iso_rps")
    rates = [int(r) for r in campaign["rates"].split()]
    arms = [a for a in ARMS if a in campaign["arms"].split()]

    cells = {}
    for p in sorted(root.glob("r*/trial.json")):
        t = json.loads(p.read_text())
        if t["rate"] == "max":
            continue
        cells.setdefault((t["arm"], int(t["rate"])), []).append(t)
    for (arm, rate), ts in cells.items():
        armcfg.check_hashes(ts, f"{root.name} {arm} at {rate}", campaign)

    result = {"slo_p99_ms": slo, "ladder_base_a_iso_rps": base, "min_valid": MIN_VALID, "arms": {}}
    for arm in arms:
        rows = []
        for rate in rates:
            ts = cells.get((arm, rate), [])
            valid = [t for t in ts if is_valid(t)]
            sustained = [t for t in valid if t["gates"]["load"]["pass"]]
            p99 = sorted(t["load"]["percentiles_ms"]["p99"] for t in valid
                         if t["load"]["percentiles_ms"].get("p99") is not None)
            median = statistics.median(p99) if p99 else None
            if len(valid) < MIN_VALID:
                verdict = "undecided"
            elif len(sustained) < len(valid):
                verdict = "fail (rate not sustained)"
            elif median is None or median > slo:
                verdict = "fail (p99 above SLO)"
            else:
                verdict = "pass"
            rows.append({"rate": rate, "fraction": round(rate / base, 3) if base else None,
                         "attempted": len(ts), "valid": len(valid), "sustained": len(sustained),
                         "p99_ms_sorted": p99, "p99_median_ms": median, "verdict": verdict})
        capacity = None
        for r in rows:
            if r["verdict"] != "pass":
                break
            capacity = r["rate"]
        highest = max((r["rate"] for r in rows if r["verdict"] == "pass"), default=None)
        result["arms"][arm] = {"capacity_rps": capacity, "highest_passing_rps": highest, "rates": rows}

    extra = [c.split("@") for c in campaign.get("extra_cells", "").split()]
    checks = []
    for arm, rate in extra:
        if arm != "B_float":
            continue
        rate = int(rate)
        x = [t["load"]["percentiles_ms"]["p99"] for t in cells.get(("B_float", rate), []) if is_valid(t)]
        y = [t["load"]["percentiles_ms"]["p99"] for t in cells.get(("A_iso", rate), []) if is_valid(t)]
        sus = lambda a: sum(1 for t in cells.get((a, rate), []) if is_valid(t) and t["gates"]["load"]["pass"])
        check = reproduction_check(x, y, MIN_VALID)
        if check["verdict"] == "undecided":
            checks.append({"rate": rate, "verdict": "undecided", "b_float_p99": sorted(x), "a_iso_p99": sorted(y)})
            continue
        checks.append({"rate": rate, "b_float_p99": sorted(x), "a_iso_p99": sorted(y),
                       "b_float_sustained": sus("B_float"), "a_iso_sustained": sus("A_iso"),
                       "p": check["p"], "p_b_float_above": check["direction"],
                       "median_inside_a_iso_range": check["median_inside_range"],
                       "verdict": check["verdict"]})
    result["reproduction_check"] = checks

    if "D2" in result["arms"] and "D" in result["arms"]:
        d2, d = result["arms"]["D2"]["capacity_rps"], result["arms"]["D"]["capacity_rps"]
        result["v2_rejection"] = {"d2_capacity_rps": d2, "d_capacity_rps": d,
                                  "rejected": (d2 or 0) < (d or 0)}
        tail = []
        for rate in rates:
            for ref in ("D", "B_pin"):
                x = [t["load"]["percentiles_ms"]["p99"] for t in cells.get(("D2", rate), [])
                     if is_valid(t) and t["gates"]["load"]["pass"]]
                y = [t["load"]["percentiles_ms"]["p99"] for t in cells.get((ref, rate), [])
                     if is_valid(t) and t["gates"]["load"]["pass"]]
                if x and y and ref in result["arms"]:
                    p, direction = mann_whitney(x, y)
                    tail.append({"rate": rate, "against": ref, "n": [len(x), len(y)],
                                 "p99_median_ms": [statistics.median(x), statistics.median(y)],
                                 "p": p, "p_d2_above": direction})
        result["v2_tail"] = tail
    return result


def write(root):
    """Evaluate a campaign and write slo.json and slo.md into it."""
    root = Path(root)
    result = evaluate(root)
    (root / "slo.json").write_text(json.dumps(result, indent=2) + "\n")
    (root / "slo.md").write_text(render(result, root.name))
    return root / "slo.md"


def render(result, root_name):
    slo, base, checks = result["slo_p99_ms"], result["ladder_base_a_iso_rps"], result["reproduction_check"]

    def frac(rate):
        return f"{rate / base:.0%}" if rate and base else "—"

    out = [f"# Capacity at p99 ≤ {slo} ms, `{root_name}`", "",
           f"Ladder base (median `A_iso` saturation): {base} req/s. A rate passes when at least "
           f"{MIN_VALID} trials are valid, every valid trial sustained the rate, and their median p99 is "
           f"at most {slo} ms. Capacity is the highest rate up to which every rate passes.", "",
           "| arm | capacity | highest passing rate |", "|:--|--:|--:|"]
    for arm, a in result["arms"].items():
        cap = f"{a['capacity_rps']} ({frac(a['capacity_rps'])})" if a["capacity_rps"] else "below the ladder"
        hi = f"{a['highest_passing_rps']} ({frac(a['highest_passing_rps'])})" if a["highest_passing_rps"] else "—"
        out.append(f"| {arm} | {cap} | {hi} |")
    out += ["", "| arm | rate | of base | valid / sustained | p99 median | p99, sorted | verdict |",
            "|:--|--:|--:|:--|--:|:--|:--|"]
    for arm, a in result["arms"].items():
        for r in a["rates"]:
            med = "—" if r["p99_median_ms"] is None else f"{r['p99_median_ms']:.2f}"
            out.append(f"| {arm} | {r['rate']} | {frac(r['rate'])} | {r['valid']} / {r['sustained']} of "
                       f"{r['attempted']} | {med} | {', '.join(f'{v:.2f}' for v in r['p99_ms_sorted'])} | "
                       f"{r['verdict']} |")
    if checks:
        out += ["", "## Reproduction check: B_float against A_iso", "",
                "Accepted when the exact two-sided Mann-Whitney p >= 0.05 and B_float's median p99 lies inside "
                "A_iso's range; if not, B_pin is read against B_float.", "",
                "| rate | B_float p99, sorted | A_iso p99, sorted | sustained B_float / A_iso | p | verdict |",
                "|--:|:--|:--|:--|--:|:--|"]
        for c in checks:
            pv = f"{c['p']:.2g}" if "p" in c else "—"
            sus = f"{c.get('b_float_sustained', '—')} / {c.get('a_iso_sustained', '—')}"
            out.append(f"| {c['rate']} | {', '.join(f'{v:.2f}' for v in c['b_float_p99'])} | "
                       f"{', '.join(f'{v:.2f}' for v in c['a_iso_p99'])} | {sus} | {pv} | {c['verdict']} |")
    v2 = result.get("v2_rejection")
    if v2:
        cap = lambda v: f"{v} ({frac(v)})" if v else "below the ladder"
        out += ["", "## Scheduler v2 (arm D2)", "",
                f"Capacity: D2 {cap(v2['d2_capacity_rps'])}, D {cap(v2['d_capacity_rps'])}. "
                f"**v2 is {'rejected' if v2['rejected'] else 'not rejected'}** by the rule that it is rejected "
                "where D2's capacity is below D's.", "",
                "D2's p99 at each rung against D and B_pin (sustained trials; exact two-sided Mann-Whitney, "
                "not corrected for the number of rungs):", "",
                "| rate | against | n | p99 median D2 / ref | p | P(D2 > ref) |", "|--:|:--|:--|:--|--:|--:|"]
        for t in result["v2_tail"]:
            out.append(f"| {t['rate']} | {t['against']} | {t['n'][0]} / {t['n'][1]} | "
                       f"{t['p99_median_ms'][0]:.2f} / {t['p99_median_ms'][1]:.2f} | {t['p']:.2g} | "
                       f"{t['p_d2_above']:.2f} |")
    return "\n".join(out) + "\n"


def main(campaign_dir):
    print(write(campaign_dir))


if __name__ == "__main__":
    main(sys.argv[1])
