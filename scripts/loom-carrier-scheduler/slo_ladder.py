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

Usage: slo_ladder.py <campaign-dir>   writes slo.md and slo.json into the campaign directory.
"""
import json
import statistics
import sys
from pathlib import Path

from stats import mann_whitney

ARMS = ("A_iso", "B_pin", "C_iso", "D")
MEASUREMENT_EXCLUDED = ("load", "harness_clean", "host_shielded", "host_untracked")
MIN_VALID = 4


def is_valid(t):
    return all(g["pass"] for k, g in t["gates"].items() if k not in MEASUREMENT_EXCLUDED)


def main(campaign_dir):
    root = Path(campaign_dir)
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
        cells.setdefault((t["arm"], int(t["rate"])), []).append(t)

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
        if len(x) < MIN_VALID or len(y) < MIN_VALID:
            checks.append({"rate": rate, "verdict": "undecided", "b_float_p99": sorted(x), "a_iso_p99": sorted(y)})
            continue
        p, direction = mann_whitney(x, y)
        inside = min(y) <= statistics.median(x) <= max(y)
        checks.append({"rate": rate, "b_float_p99": sorted(x), "a_iso_p99": sorted(y),
                       "b_float_sustained": sus("B_float"), "a_iso_sustained": sus("A_iso"),
                       "p": p, "p_b_float_above": direction, "median_inside_a_iso_range": inside,
                       "verdict": "accepted" if p >= 0.05 and inside else "not accepted"})
    result["reproduction_check"] = checks

    (root / "slo.json").write_text(json.dumps(result, indent=2) + "\n")

    def frac(rate):
        return f"{rate / base:.0%}" if rate and base else "—"

    out = [f"# Capacity at p99 ≤ {slo} ms, `{root.name}`", "",
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
    (root / "slo.md").write_text("\n".join(out) + "\n")
    print(root / "slo.md")


if __name__ == "__main__":
    main(sys.argv[1])
