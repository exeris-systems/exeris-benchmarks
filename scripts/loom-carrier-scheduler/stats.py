#!/usr/bin/env python3
"""The tests a loom-carrier-scheduler report quotes, from a campaign's trial.json files.

For every rate: per-arm median and range of p99 and p99.9 over the sustained trials, the
worst sustained trial's p99, the exact two-sided Mann-Whitney U test for each pair of arms, and the
Spearman rank correlation between a trial's carrier run-queue wait and its p99 within each cell.

The exact test enumerates the U distribution, so it is valid at n = 10 where the normal
approximation is not; with no ties it is the test the report's p values come from. Standard library
only.

Usage: stats.py <campaign-dir> [<campaign-dir>...]
"""
import json
import statistics
import sys
from functools import lru_cache
from pathlib import Path

import armcfg

ARMS = ("A_iso", "B_float", "B_pin", "C_iso", "D", "D2")
# B_pin's pairs separate the two halves of the 2x2: pinning under the stock algorithm (B_pin vs
# A_iso) and the algorithm under pinning (D vs B_pin). A pair is tested only where both arms ran.
# B_float against A_iso checks that the SPI reproduction of the built-in scheduler is the built-in.
# D2, the scheduler's second revision, is read against the arm it changes (D), the pinned stock pool
# it has to beat (B_pin) and the isolated stock pool.
PAIRS = (("D", "A_iso"), ("D", "C_iso"), ("C_iso", "A_iso"), ("B_pin", "A_iso"), ("D", "B_pin"),
         ("B_float", "A_iso"), ("D2", "D"), ("D2", "B_pin"), ("D2", "A_iso"))
# The throughput comparison runs four arms; its multiple-comparison family is their six pairs.
V2_ARMS = ("A_iso", "B_pin", "D", "D2")
V2_PAIRS = (("D2", "B_pin"), ("D2", "D"), ("D2", "A_iso"), ("D", "B_pin"), ("D", "A_iso"), ("B_pin", "A_iso"))


@lru_cache(maxsize=None)
def _count(m, n, u):
    """Arrangements of m and n observations whose U statistic equals u."""
    if u < 0:
        return 0
    if m == 0 or n == 0:
        return 1 if u == 0 else 0
    return _count(m - 1, n, u - n) + _count(m, n - 1, u)


def mann_whitney(x, y):
    """Exact two-sided p, and P(x > y) as the effect direction."""
    m, n = len(x), len(y)
    u = sum((a > b) + 0.5 * (a == b) for a in x for b in y)
    total = sum(_count(m, n, k) for k in range(m * n + 1))
    tail = min(u, m * n - u)
    p = 2 * sum(_count(m, n, k) for k in range(int(tail) + 1)) / total
    return min(1.0, p), u / (m * n)


def holm(p_values, alpha=0.05):
    """Holm's step-down adjustment: (adjusted p-values, rejected at alpha), aligned with the input.

    The i-th smallest of m p-values is multiplied by m - i + 1 (counting from 1) and the adjusted
    values are made non-decreasing, so a hypothesis is rejected exactly when its adjusted p is
    below alpha.
    """
    m = len(p_values)
    adjusted = [0.0] * m
    running = 0.0
    for rank, i in enumerate(sorted(range(m), key=lambda k: p_values[k])):
        running = max(running, (m - rank) * p_values[i])
        adjusted[i] = min(1.0, running)
    return adjusted, [a < alpha for a in adjusted]


def reproduction_check(x, y, min_valid=4):
    """Whether the trials x reproduce the reference trials y (the rule arm B_float is held to).

    Accepted when the exact two-sided Mann-Whitney p of x against y is at least 0.05 and the median
    of x lies inside the range of y; undecided when either side has fewer than min_valid trials.
    `direction` is P(x > y).
    """
    if len(x) < min_valid or len(y) < min_valid:
        return {"verdict": "undecided"}
    p, direction = mann_whitney(x, y)
    inside = min(y) <= statistics.median(x) <= max(y)
    return {"p": p, "direction": direction, "median_inside_range": inside,
            "verdict": "accepted" if p >= 0.05 and inside else "not accepted"}


def spearman(x, y):
    def ranks(v):
        # Tied values share the mean of their ranks; pidstat reports wait to 0.01 %, so ties are
        # common, and arbitrary tie order would invent a correlation.
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v)
        k = 0
        while k < len(order):
            j = k
            while j + 1 < len(order) and v[order[j + 1]] == v[order[k]]:
                j += 1
            for i in order[k:j + 1]:
                r[i] = (k + j) / 2
            k = j + 1
        return r
    rx, ry = ranks(x), ranks(y)
    mx, my = statistics.mean(rx), statistics.mean(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num / den if den else None


def load(campaign):
    cells = {}
    trials = {}
    for f in sorted(Path(campaign).glob("r*/trial.json")):
        t = json.loads(f.read_text())
        if t["rate"] == "max":
            continue
        if not t["valid"] or not t.get("sustained", t["gates"]["load"]["pass"]):
            continue
        key = (int(t["rate"]), t["arm"])
        trials.setdefault(key, []).append(t)
        cells.setdefault(key, []).append(
            (t["load"]["percentiles_ms"]["p99"], t["load"]["percentiles_ms"]["p99.9"],
             t["pidstat"]["carriers"]["wait_pct_max"]))
    meta = Path(campaign) / "campaign.json"
    info = json.loads(meta.read_text()) if meta.exists() else None
    for (rate, arm), ts in trials.items():
        armcfg.check_hashes(ts, f"{Path(campaign).name} {arm} at {rate}", info)
    return cells


def main(campaigns):
    tests = 0
    for campaign in campaigns:
        cells = load(campaign)
        print(f"# {Path(campaign).name}")
        for rate in sorted({r for r, _ in cells}):
            print(f"\n## {rate} req/s")
            for arm in ARMS:
                v = cells.get((rate, arm), [])
                if not v:
                    continue
                p99 = sorted(x[0] for x in v)
                p999 = [x[1] for x in v]
                rho = spearman([x[2] for x in v], [x[0] for x in v]) if len({x[2] for x in v}) > 1 else None
                print(f"{arm:6} n={len(v):2}  p99 median {statistics.median(p99):7.2f} [{p99[0]:.2f}-{p99[-1]:.2f}]"
                      f"  worst {p99[-1]:7.2f}  p99.9 median {statistics.median(p999):7.2f}"
                      f"  rho(wait, p99) {'n/a' if rho is None else f'{rho:+.2f}'}")
            for q, label in ((0, "p99"), (1, "p99.9")):
                for a, b in PAIRS:
                    x = [t[q] for t in cells.get((rate, a), [])]
                    y = [t[q] for t in cells.get((rate, b), [])]
                    if not x or not y:
                        continue
                    p, direction = mann_whitney(x, y)
                    tests += 1
                    print(f"  {label:5} {a} vs {b}: p = {p:.2g}  P({a} > {b}) = {direction:.2f}  (n {len(x)} vs {len(y)})")
        print()
    print(f"{tests} tests; Bonferroni threshold at alpha 0.05: {0.05 / tests:.4f}")


if __name__ == "__main__":
    main(sys.argv[1:])
