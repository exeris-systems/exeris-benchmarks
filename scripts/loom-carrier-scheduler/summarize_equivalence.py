#!/usr/bin/env python3
"""Is arm D the same arm in two kernel builds? Tabulate a run-v2-equivalence.sh directory.

For each regime the new build's D is held to B_float's reproduction rule against the earlier build's
D (stats.reproduction_check): accepted when the exact two-sided Mann-Whitney p of the new build's p99
against the earlier build's is at least 0.05 and the new build's median p99 lies inside the earlier
build's range. A regime that is not accepted names the new build's D as the control: no earlier
campaign is then compared with D2.

Only trials that are what the order file says count: the trial's kernel commit must start with the
commit the order file names, its arm must be D, its rate the plan's, and it must have run no scheduler
property. A trial that is not, or that fails a measurement gate, is listed and left out.

Usage: summarize_equivalence.py <equivalence-dir>   writes summary.md and summary.json into it.
"""
import json
import statistics
import sys
from pathlib import Path

import armcfg
from slo_ladder import MEASUREMENT_EXCLUDED, MIN_VALID, is_valid
from stats import reproduction_check


def read_plan(path):
    plan = {}
    for line in path.read_text().splitlines():
        for tok in line.split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                plan[k] = v
    return plan


def evaluate(root):
    root = Path(root)
    plan = read_plan(root / "plan.txt")
    rates = {"cpu": plan["rate_cpu"], "io": plan["rate_io"]}
    old, new = plan["kernel_old"], plan["kernel_new"]
    cells = {}
    excluded = []
    for line in (root / "order.txt").read_text().splitlines():
        rep, ktag, regime = line.split()
        name = f"{rep}-D-{ktag}-{regime}"
        path = root / name / "trial.json"
        if not path.exists():
            excluded.append({"trial": name, "reason": "no trial.json (the trial did not complete)"})
            continue
        t = json.loads(path.read_text())
        problems = []
        if not t["kernel"]["kernel_commit"].startswith(ktag[1:]):
            problems.append(f"kernel {t['kernel']['kernel_commit'][:12]}, order file says {ktag[1:]}")
        if t["arm"] != "D":
            problems.append(f"arm {t['arm']}")
        if str(t["rate"]) != rates[regime]:
            problems.append(f"rate {t['rate']}, plan says {rates[regime]}")
        if t.get("locality_properties"):
            problems.append("ran scheduler properties")
        if problems:
            excluded.append({"trial": name, "reason": "; ".join(problems)})
            continue
        if not is_valid(t):
            failed = [k for k, g in t["gates"].items() if not g["pass"] and k not in MEASUREMENT_EXCLUDED]
            excluded.append({"trial": name, "reason": "invalid: failed " + ", ".join(failed)})
            continue
        cells.setdefault((regime, ktag[1:]), []).append(t)
    for (regime, sha), ts in cells.items():
        armcfg.check_hashes(ts, f"{root.name} D {sha} {regime}")

    def p99(regime, sha):
        return [t["load"]["percentiles_ms"]["p99"] for t in cells.get((regime, sha), []) if t["gates"]["load"]["pass"]]

    result = {"kernel_old": old, "kernel_new": new, "rates": rates, "regimes": {}, "excluded": excluded}
    for regime in ("cpu", "io"):
        x, y = p99(regime, new), p99(regime, old)
        check = reproduction_check(x, y, MIN_VALID)
        sustained = lambda sha: (sum(1 for t in cells.get((regime, sha), []) if t["gates"]["load"]["pass"]),
                                 len(cells.get((regime, sha), [])))
        result["regimes"][regime] = {"rate": rates[regime], "new_p99": sorted(x), "old_p99": sorted(y),
                                     "sustained_valid_new": sustained(new), "sustained_valid_old": sustained(old),
                                     **check}
    accepted = all(r["verdict"] == "accepted" for r in result["regimes"].values())
    result["control"] = "the earlier build's campaigns" if accepted else "D from the new build"
    result["accepted"] = accepted
    return result


def render(result, name):
    old, new = result["kernel_old"], result["kernel_new"]
    out = [f"# D from two kernel builds, `{name}`", "",
           f"Earlier build `{old}`, new build `{new}`. Accepted per regime when the exact two-sided Mann-Whitney p of the "
           f"new build's p99 against the earlier build's is at least 0.05 and the new build's median p99 lies inside the "
           f"earlier build's range; at least {MIN_VALID} valid sustained trials on each side, else undecided.", "",
           "| regime | rate | new p99, sorted | earlier p99, sorted | sustained of valid (new / earlier) | p | P(new > earlier) | median inside range | verdict |",
           "|:--|--:|:--|:--|:--|--:|--:|:--|:--|"]
    for regime, r in result["regimes"].items():
        pv = f"{r['p']:.2g}" if "p" in r else "—"
        d = f"{r['direction']:.2f}" if "direction" in r else "—"
        ins = r.get("median_inside_range", "—")
        out.append(f"| {regime} | {r['rate']} | {', '.join(f'{v:.2f}' for v in r['new_p99'])} | "
                   f"{', '.join(f'{v:.2f}' for v in r['old_p99'])} | "
                   f"{r['sustained_valid_new'][0]} of {r['sustained_valid_new'][1]} / "
                   f"{r['sustained_valid_old'][0]} of {r['sustained_valid_old'][1]} | {pv} | {d} | {ins} | {r['verdict']} |")
    out += ["", f"Control for D2: **{result['control']}**."]
    if result["excluded"]:
        out += ["", "Left out:", ""] + [f"- `{e['trial']}`: {e['reason']}" for e in result["excluded"]]
    return "\n".join(out) + "\n"


def main(root):
    root = Path(root)
    result = evaluate(root)
    (root / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    plan = (root / "plan.txt").read_text().strip()
    (root / "summary.md").write_text(render(result, root.name) + "\n```\n" + plan + "\n```\n")
    print(root / "summary.md")


if __name__ == "__main__":
    main(sys.argv[1])
